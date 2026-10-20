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
        /// B16: un plan ilimitado no tiene barras que pintar, pero sí etiqueta.
        var isUnlimited: Bool = false
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
    /// Credencial del ciclo anterior, solo en memoria: un fallo transitorio de lectura
    /// no tumba la fila si ya había una (ver `CursorSession.CredentialCache`).
    private let credentials = CursorSession.CredentialCache()

    init(databaseURL: URL = CursorLimitsProvider.defaultDatabaseURL,
         session: URLSession = .shared) {
        self.databaseURL = databaseURL
        self.session = session
    }

    func fetch() async -> LimitsSnapshot {
        let credential: CursorSession.Credential
        switch await credentials.credentialResult(from: databaseURL) {
        case .success(let value): credential = value
        case .failure(.missingDatabase), .failure(.missingKey):
            return .empty(source, .notConfigured)
        case .failure(.readFailed(let code)):
            // B10: un error de lectura no es "no configurado".
            return .empty(source, .failed(CursorSession.readFailureMessage(code: code)))
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

        // B16: un plan ilimitado es válido aunque no tenga ninguna barra.
        if summary.isUnlimited {
            return LimitsSnapshot(source: source, windows: [],
                                  planLabel: summary.planLabel, status: .ok)
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
                if http.statusCode == 401 { return .unauthorized }
                if http.statusCode == 403 { return .failed("HTTP 403") }   // B13: transitorio
                if http.statusCode == 429 { return .rateLimited(RetryAfter.date(from: http)) }
                guard (200..<300).contains(http.statusCode) else {
                    return .failed("HTTP \(http.statusCode)")
                }
            }
            return .success(data)
        } catch {
            Self.log.error("fallo de red: \(error.localizedDescription, privacy: .public)")
            return .failed("Sin conexión")
        }
    }

    // MARK: - Parsing

    /// Esquema verificado de `GET /api/usage-summary` el 2026-09-27.
    static func parseSummary(_ data: Data) -> Summary? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let planLabel = nonEmptyString(root["membershipType"]),
              let cycleEnd = date(root["billingCycleEnd"]) else {
            return nil
        }

        // B16: en planes de equipo el consumo vive en `teamUsage`, no en `individualUsage`.
        let limitType = nonEmptyString(root["limitType"])
        let usage = (limitType == "team" ? root["teamUsage"] : root["individualUsage"])
            as? [String: Any] ?? (root["individualUsage"] as? [String: Any])
        guard let usage else { return nil }

        let plan = usage["plan"] as? [String: Any]

        // B16: plan ilimitado → sin barras, pero con etiqueta.
        if bool(root["isUnlimited"]) == true || bool(plan?["isUnlimited"]) == true {
            return Summary(planLabel: planLabel, utilization: nil,
                           resetsAt: cycleEnd, extraWindows: [], isUnlimited: true)
        }

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
        let extra = (usage["overall"] as? [String: Any])
            ?? (usage["onDemand"] as? [String: Any])
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
        guard let used = number(bucket["used"]) else { return nil }
        // B11: sin `totalPercentUsed`, el tope es `breakdown.total` (incluye el bono), no
        // `used + remaining` — que ignora el bono y muestra un 100 % falso.
        if let breakdown = bucket["breakdown"] as? [String: Any],
           let total = number(breakdown["total"]), total > 0 {
            return LimitWindow.utilization(used: used, cap: total)
        }
        guard let remaining = number(bucket["remaining"]), remaining >= 0 else {
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

    static func readAccessToken(from url: URL) async -> String? {
        await CursorSession.readAccessToken(from: url)
    }
}
