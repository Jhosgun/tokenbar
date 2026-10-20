import Foundation
import OSLog
import SQLite3

/// La credencial de sesión de Cursor, descubierta sola desde su instalación local.
///
/// Cursor guarda el access token en claro en su SQLite
/// (`User/globalStorage/state.vscdb`, tabla `ItemTable`, llave `cursorAuth/accessToken`),
/// y el id de usuario va dentro del claim `sub` del propio JWT. Con ambos se arma la
/// cookie `WorkosCursorSessionToken` que esperan los endpoints del dashboard.
///
/// Lo comparten `CursorLimitsProvider` (cuota) y `CursorCollector` (tokens); vive aquí
/// para que ninguno duplique la lectura del SQLite ni el armado de la cookie.
///
/// La base se abre SIEMPRE en solo lectura e inmutable: Cursor puede estar corriendo y
/// escribir en ella, y corromperla sería inaceptable. Regla de oro: el token nunca se
/// imprime, se loguea ni se guarda en otro archivo.
enum CursorSession {

    /// Credencial lista para usar como cabecera `Cookie`.
    struct Credential: Sendable {
        /// `WorkosCursorSessionToken=<sub URL-encoded>%3A%3A<jwt>`.
        var cookie: String
        /// True si el JWT ya venció según su claim `exp`: no vale la pena consultar.
        var isExpired: Bool
    }

    static var defaultDatabaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    /// Distingue "no hay dato" (no configurado) de "no se pudo leer" (error). `readFailed`
    /// lleva el código SQLite (extendido) del último intento, para que el log y el
    /// mensaje digan la causa.
    enum ReadError: Error, Equatable {
        case missingDatabase
        case missingKey
        case readFailed(code: Int32)
    }

    /// Mensaje de estado para un error de lectura, con el código SQLite para diagnóstico.
    static func readFailureMessage(code: Int32) -> String {
        "No se pudo leer la sesión de Cursor (SQLite \(code))"
    }

    private static let log = Logger(subsystem: "io.github.jhosgun.tokenbar", category: "cursor-session")

    /// Espera máxima de `sqlite3_busy_timeout` ante un `SQLITE_BUSY`.
    static let busyTimeoutMs: Int32 = 500
    /// Pausa antes del único reintento cuando la lectura falla.
    static let retryDelay: TimeInterval = 0.2

    /// Arma la credencial a partir del JWT. `.missingKey` si no trae `sub`.
    static func makeCredential(token: String, now: Date = Date()) -> Result<Credential, ReadError> {
        guard let subject = subject(fromJWT: token) else { return .failure(.missingKey) }
        return .success(Credential(cookie: cookieHeader(subject: subject, token: token),
                                   isExpired: isExpired(token, now: now)))
    }

    /// Credencial recordada en memoria (nunca en disco) para no tumbar una fila por un
    /// fallo transitorio de lectura: si este ciclo no pudo leer la base pero un ciclo
    /// anterior de este mismo proceso sí, y ese token no ha vencido, se usa ese. Sin
    /// credencial previa, el fallo se reporta como siempre. "No hay base" o "no hay llave"
    /// (sesión cerrada) no se tapan: borran lo recordado y siguen siendo `.notConfigured`.
    ///
    /// Cada proveedor/collector tiene la suya; se crean una vez en `TokenBarApp` y viven
    /// todo el proceso.
    final class CredentialCache: @unchecked Sendable {
        private let lock = NSLock()
        private var token: String?

        init() {}

        func credentialResult(from url: URL = CursorSession.defaultDatabaseURL,
                              now: Date = Date()) async -> Result<Credential, ReadError> {
            let read = await CursorSession.accessTokenResult(from: url)
            return lock.withLock {
                switch read {
                case .success(let fresh):
                    let built = CursorSession.makeCredential(token: fresh, now: now)
                    if case .success = built { token = fresh } else { token = nil }
                    return built
                case .failure(.readFailed(let code)):
                    guard let remembered = token, !CursorSession.isExpired(remembered, now: now) else {
                        return .failure(.readFailed(code: code))
                    }
                    CursorSession.log.warning("lectura de la sesión de Cursor falló (SQLite \(code, privacy: .public)); se usa la credencial del ciclo anterior")
                    return CursorSession.makeCredential(token: remembered, now: now)
                case .failure(let error):
                    token = nil
                    return .failure(error)
                }
            }
        }
    }

    /// Cookie que espera el dashboard: `<sub URL-encoded>::<jwt>`, con `::` escapado.
    static func cookieHeader(subject: String, token: String) -> String {
        let encoded = subject.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? subject
        return "WorkosCursorSessionToken=\(encoded)%3A%3A\(token)"
    }

    static func subject(fromJWT token: String) -> String? {
        claims(fromJWT: token)?["sub"] as? String
    }

    static func isExpired(_ token: String, now: Date = Date()) -> Bool {
        guard let exp = (claims(fromJWT: token)?["exp"] as? NSNumber)?.doubleValue else { return false }
        return exp < now.timeIntervalSince1970
    }

    private static func claims(fromJWT token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: - SQLite (solo lectura)

    /// Abre la base de Cursor en solo lectura y saca el access token. `nil` si no hay
    /// base, no hay llave o hubo un error de lectura (sin distinguirlos).
    /// Nunca escribe: Cursor puede estar corriendo sobre este mismo archivo.
    static func readAccessToken(from url: URL) async -> String? {
        try? await accessTokenResult(from: url).get()
    }

    /// Como `readAccessToken(from:)`, pero distingue la causa del `nil`.
    ///
    /// B10: se abre con `mode=ro` (sin `immutable=1`, que le dice a SQLite que ignore el
    /// WAL y deja invisible un token recién renovado). Los errores de apertura/lectura no
    /// se funden con "no hay base o no hay llave".
    ///
    /// Escenario reproducido en producción (2026-10-08): la base está en modo WAL y la
    /// abren a la vez dos conexiones de este proceso (`CursorCollector` y
    /// `CursorLimitsProvider` corren en paralelo). Sin Cursor corriendo, cada apertura
    /// "primera" rehace el índice del WAL y la segunda conexión recibe
    /// `SQLITE_BUSY_RECOVERY` (261) en `sqlite3_prepare_v2`, en ~37 % de los intentos con
    /// dos hilos. `sqlite3_busy_timeout` lo resuelve. El caso general (un escritor que
    /// retiene la base: `SQLITE_BUSY`, 5, en rollback journal) lo cubre el test de bloqueo
    /// sostenido; el reintento único tras 200 ms cubre cualquier otro fallo pasajero.
    /// Es `async` para que la pausa no bloquee un hilo del pool cooperativo.
    static func accessTokenResult(from url: URL) async -> Result<String, ReadError> {
        let first = readAccessTokenOnce(from: url)
        guard case .failure(.readFailed(let firstCode)) = first else { return first }
        try? await Task.sleep(for: .milliseconds(Int(retryDelay * 1000)))
        let second = readAccessTokenOnce(from: url)
        if case .failure(.readFailed(let secondCode)) = second {
            log.error("no se pudo leer la sesión de Cursor: SQLite \(firstCode, privacy: .public) y, al reintentar, SQLite \(secondCode, privacy: .public)")
        }
        return second
    }

    /// Un solo intento de apertura y lectura.
    private static func readAccessTokenOnce(from url: URL) -> Result<String, ReadError> {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .failure(.missingDatabase)
        }

        var handle: OpaquePointer?
        let encodedPath = url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.path
        let uri = "file:\(encodedPath)?mode=ro"
        let opened = sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        guard opened == SQLITE_OK, let db = handle else {
            let code = handle.map { sqlite3_extended_errcode($0) } ?? opened
            if handle != nil { sqlite3_close(handle) }
            return .failure(.readFailed(code: code))
        }
        defer { sqlite3_close(db) }
        sqlite3_extended_result_codes(db, 1)
        sqlite3_busy_timeout(db, busyTimeoutMs)

        var statement: OpaquePointer?
        let sql = "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken' LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return .failure(.readFailed(code: sqlite3_extended_errcode(db)))
        }
        defer { sqlite3_finalize(statement) }

        let step = sqlite3_step(statement)
        guard step == SQLITE_ROW else {
            return step == SQLITE_DONE ? .failure(.missingKey)
                                       : .failure(.readFailed(code: sqlite3_extended_errcode(db)))
        }
        guard let bytes = sqlite3_column_blob(statement, 0) else { return .failure(.missingKey) }
        let count = Int(sqlite3_column_bytes(statement, 0))
        guard count > 0 else { return .failure(.missingKey) }
        let raw = String(decoding: UnsafeRawBufferPointer(start: bytes, count: count), as: UTF8.self)
        let token = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\" \n\t"))
        return token.isEmpty ? .failure(.missingKey) : .success(token)
    }
}
