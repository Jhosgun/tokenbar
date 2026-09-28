import Foundation
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

    /// Lee la credencial completa. `nil` si no hay base, no hay token o el JWT no trae
    /// `sub` — el llamador reporta `notConfigured`. La expiración se informa aparte.
    static func credential(from url: URL = defaultDatabaseURL, now: Date = Date()) -> Credential? {
        guard let token = readAccessToken(from: url),
              let subject = subject(fromJWT: token) else {
            return nil
        }
        return Credential(cookie: cookieHeader(subject: subject, token: token),
                          isExpired: isExpired(token, now: now))
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

    /// Abre la base de Cursor en modo inmutable y saca el access token.
    /// Nunca escribe: Cursor puede estar corriendo sobre este mismo archivo.
    static func readAccessToken(from url: URL) -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        var handle: OpaquePointer?
        let encodedPath = url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.path
        let uri = "file:\(encodedPath)?mode=ro&immutable=1"
        guard sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
              let db = handle else {
            if handle != nil { sqlite3_close(handle) }
            return nil
        }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        let sql = "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken' LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW,
              let bytes = sqlite3_column_blob(statement, 0) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, 0))
        guard count > 0 else { return nil }
        let raw = String(decoding: UnsafeRawBufferPointer(start: bytes, count: count), as: UTF8.self)
        let token = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\" \n\t"))
        return token.isEmpty ? nil : token
    }
}
