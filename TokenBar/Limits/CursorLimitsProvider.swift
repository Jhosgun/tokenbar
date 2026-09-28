import Foundation
import OSLog

/// Lee la cuota del ciclo de Cursor desde su propia cuenta.
///
/// El token de sesión NO se le pide al usuario: lo descubre `CursorSession` desde el
/// SQLite local de Cursor (ver ese archivo). De ahí sale la cookie
/// `WorkosCursorSessionToken` con la que se consulta `/api/usage-summary`.
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
        case rateLimited(Date?)
        case failed(String)
    }

    /// Plazo absoluto para la consulta de red, más allá de `URLRequest.timeoutInterval`.
    static let fetchBudget: Duration = .seconds(5)

    private static let log = Logger(subsystem: "io.github.jhosgun.tokenbar", category: "cursor-limits")

    private static var defaultDatabaseURL: URL {
        CursorSession.defaultDatabaseURL
    }

    private let databaseURL: URL
    private let session: URLSession

    init(databaseURL: URL = CursorLimitsProvider.defaultDatabaseURL,
         session: URLSession = .shared) {
        self.databaseURL = databaseURL
        self.session = session
    }

    func fetch() async -> LimitsSnapshot {
        guard let credential = CursorSession.credential(from: databaseURL) else {
            return .empty(source, .notConfigured)
        }
        if credential.isExpired { return .empty(source, .invalidCredentials) }

        let summaryResponse = await NetworkDeadline.run(budget: Self.fetchBudget) {
            await self.request(Endpoint.usageSummary, cookie: credential.cookie)
        } ?? .failed("Tiempo de espera agotado")

        let summaryData: Data
        switch summaryResponse {
        case .success(let data): summaryData = data
        case .unauthorized: return .empty(source, .invalidCredentials)
        case .rateLimited(let retryAfter): return .rateLimited(source, retryAfter: retryAfter)
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
                if http.statusCode == 429 { return .rateLimited(RetryAfter.date(from: http)) }
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

        // Los dos carriles del plan (verificado 2026-09-27 contra la cuenta real):
        // `autoPercentUsed` cubre los modelos de Cursor (Auto) y `apiPercentUsed`
        // los modelos con nombre o externos (Grok y demás). Cada uno es su propia
        // ventana; si falta el campo, simplemente no se muestra.
        if let auto = number(plan?["autoPercentUsed"]), auto >= 0 {
            extraWindows.append(LimitWindow(name: "Auto",
                                            utilization: auto / 100,
                                            resetsAt: cycleEnd))
        }
        if let api = number(plan?["apiPercentUsed"]), api >= 0 {
            extraWindows.append(LimitWindow(name: "Modelos con nombre",
                                            utilization: api / 100,
                                            resetsAt: cycleEnd))
        }

        // Cursor movió este bucket de `onDemand` a `overall` en 2026. Solo se muestra
        // cuando declara un límite explícito; gasto sin tope no es una barra honesta.
        let extra = (individual["overall"] as? [String: Any])
            ?? (individual["onDemand"] as? [String: Any])
        if let extra,
           bool(extra["enabled"]) == true,
           let used = number(extra["used"]),
           let limit = number(extra["limit"]),
           let utilization = LimitWindow.utilization(used: used, cap: limit) {
            extraWindows.append(LimitWindow(name: "Bajo demanda",
                                            utilization: utilization,
                                            resetsAt: cycleEnd))
        }

        return Summary(planLabel: planLabel,
                       utilization: utilization,
                       resetsAt: cycleEnd,
                       extraWindows: extraWindows)
    }

    private static func utilization(from bucket: [String: Any]?) -> Double? {
        guard let bucket else { return nil }
        if let percent = number(bucket["totalPercentUsed"]) {
            return LimitWindow.utilization(fromPercent: percent)
        }
        guard let used = number(bucket["used"]),
              let remaining = number(bucket["remaining"]), remaining >= 0 else {
            return nil
        }
        return LimitWindow.utilization(used: used, cap: used + remaining)
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

    // MARK: - Credencial (vive en `CursorSession`)

    /// Reenvíos conservados para no romper a quienes ya llamaban aquí (tests incluidos);
    /// la implementación única está en `CursorSession`.
    static func cookieHeader(subject: String, token: String) -> String {
        CursorSession.cookieHeader(subject: subject, token: token)
    }

    static func subject(fromJWT token: String) -> String? {
        CursorSession.subject(fromJWT: token)
    }

    static func isExpired(_ token: String, now: Date = Date()) -> Bool {
        CursorSession.isExpired(token, now: now)
    }

    static func readAccessToken(from url: URL) -> String? {
        CursorSession.readAccessToken(from: url)
    }
}
