import Foundation
import OSLog
import SQLite3

/// Lee la cuota del ciclo de Cursor desde su propia cuenta.
///
/// El token de sesión NO se le pide al usuario: Cursor lo guarda en claro en su SQLite
/// local (`ItemTable`, llave `cursorAuth/accessToken`), y el id de usuario va dentro del
/// claim `sub` del propio JWT. De ahí se arma la cookie `WorkosCursorSessionToken`.
///
/// La base se abre SIEMPRE en solo lectura e inmutable: Cursor puede estar corriendo y
/// escribir en ella, y corromperla sería inaceptable.
struct CursorLimitsProvider: LimitsProvider {
    let source: AppSource = .cursor

    enum Endpoint {
        static let usageSummary = URL(string: "https://cursor.com/api/usage-summary")!
        static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
            + "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
    }

    struct Summary: Sendable {
        var planLabel: String
        var utilization: Double?
        var resetsAt: Date
        var extraWindows: [LimitWindow]
    }

    private enum Response: Sendable {
        case success(Data)
        case unauthorized
        case failed(String)
    }

    private static let log = Logger(subsystem: "io.github.jhosgun.tokenbar", category: "cursor-limits")

    private static var defaultDatabaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    private let databaseURL: URL
    private let session: URLSession

    init(databaseURL: URL = CursorLimitsProvider.defaultDatabaseURL,
         session: URLSession = .shared) {
        self.databaseURL = databaseURL
        self.session = session
    }

    func fetch() async -> LimitsSnapshot {
        guard let token = Self.readAccessToken(from: databaseURL),
              let subject = Self.subject(fromJWT: token) else {
            return .empty(source, .notConfigured)
        }
        if Self.isExpired(token) { return .empty(source, .invalidCredentials) }

        let cookie = Self.cookieHeader(subject: subject, token: token)
        let summaryResponse = await request(Endpoint.usageSummary, cookie: cookie)

        let summaryData: Data
        switch summaryResponse {
        case .success(let data): summaryData = data
        case .unauthorized: return .empty(source, .invalidCredentials)
        case .failed(let message): return .empty(source, .failed(message))
        }

        guard let summary = Self.parseSummary(summaryData) else {
            return .empty(source, .failed("Respuesta no reconocida"))
        }

        guard let utilization = summary.utilization else {
            return .empty(source, .failed("Respuesta no reconocida"))
        }

        let cycle = LimitWindow(name: "Ciclo",
                                utilization: utilization,
                                resetsAt: summary.resetsAt)
        return LimitsSnapshot(source: source,
                              windows: [cycle] + summary.extraWindows,
                              planLabel: summary.planLabel,
                              status: .ok)
    }

    // MARK: - Red

    private func request(_ url: URL, cookie: String) async -> Response {
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.httpShouldHandleCookies = false
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(Endpoint.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse {
                if http.statusCode == 401 || http.statusCode == 403 { return .unauthorized }
                guard (200..<300).contains(http.statusCode) else {
                    return .failed("HTTP \(http.statusCode)")
                }
            }
            return .success(data)
        } catch {
            Self.log.error("fallo de red: \(error.localizedDescription, privacy: .public)")
            return .failed("Sin respuesta")
        }
    }

    // MARK: - Parsing

    /// Esquema verificado de `GET /api/usage-summary` el 2026-09-27.
    static func parseSummary(_ data: Data) -> Summary? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let planLabel = nonEmptyString(root["membershipType"]),
              let cycleEnd = date(root["billingCycleEnd"]),
              let individual = root["individualUsage"] as? [String: Any] else {
            return nil
        }

        let plan = individual["plan"] as? [String: Any]
        let utilization = utilization(from: plan)
        var extraWindows: [LimitWindow] = []

        // Cursor movió este bucket de `onDemand` a `overall` en 2026. Solo se muestra
        // cuando declara un límite explícito; gasto sin tope no es una barra honesta.
        let extra = (individual["overall"] as? [String: Any])
            ?? (individual["onDemand"] as? [String: Any])
        if let extra,
           bool(extra["enabled"]) == true,
           let used = number(extra["used"]),
           let limit = number(extra["limit"]),
           used >= 0, limit > 0 {
            extraWindows.append(LimitWindow(name: "Bajo demanda",
                                            utilization: used / limit,
                                            resetsAt: cycleEnd))
        }

        return Summary(planLabel: planLabel,
                       utilization: utilization,
                       resetsAt: cycleEnd,
                       extraWindows: extraWindows)
    }

    private static func utilization(from bucket: [String: Any]?) -> Double? {
        guard let bucket else { return nil }
        if let percent = number(bucket["totalPercentUsed"]), percent >= 0 {
            return percent / 100
        }
        guard let used = number(bucket["used"]),
              let remaining = number(bucket["remaining"]),
              used >= 0, remaining >= 0, used + remaining > 0 else {
            return nil
        }
        return used / (used + remaining)
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        let result = number.doubleValue
        return result.isFinite ? result : nil
    }

    private static func bool(_ value: Any?) -> Bool? {
        (value as? NSNumber)?.boolValue
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        return value
    }

    private static func date(_ value: Any?) -> Date? {
        guard let value = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = fractional.date(from: value) { return parsed }
        return ISO8601DateFormatter().date(from: value)
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
