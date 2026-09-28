import Foundation
import OSLog

/// Lee los límites reales de la suscripción de Claude.
///
/// **Fuente primaria: la caché local.** Claude Code deja la utilización de la cuenta en
/// `~/.claude.json`, clave `cachedUsageUtilization`, cada vez que corre. Es la misma cifra
/// que devuelve `api.anthropic.com/api/oauth/usage`, pero sin su rate limit: ese endpoint
/// responde 429 durante horas aunque se consulte cada 5 min, así que la red queda como
/// **respaldo** — solo cuando no hay caché o tiene más de 2 h, y nunca más de una vez cada
/// 15 min (el dato cambia en horas).
///
/// Del archivo solo se lee `cachedUsageUtilization`: el resto es configuración e historial
/// del usuario. Para la red, el token OAuth está en el llavero bajo el service
/// `Claude Code-credentials` y se pide con `User-Agent: claude-code/<versión>` — CodexBar
/// documentó en su CHANGELOG que con el UA del CLI, y no con uno de navegador, el endpoint
/// deja de castigar las consultas.
struct ClaudeLimitsProvider: LimitsProvider {
    let source: AppSource = .claudeCode

    enum Endpoint {
        static let usage = URL(string: "https://api.anthropic.com/api/oauth/usage")!
        static let oauthBeta = "oauth-2025-04-20"
    }

    /// Archivo donde Claude Code cachea la utilización de la cuenta.
    static var defaultCacheURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude.json")
    }

    /// Service del llavero donde Claude Code guarda su credencial OAuth.
    static let keychainService = "Claude Code-credentials"

    /// Caché con más de 30 min se muestra marcada como desactualizada, no oculta.
    static let staleAge: TimeInterval = 30 * 60
    /// Caché con más de 2 h intenta renovarse por red.
    static let networkFallbackAge: TimeInterval = 2 * 3600
    /// Mínimo entre consultas de red: el dato cambia en horas.
    static let networkInterval: TimeInterval = 15 * 60
    /// Plazo absoluto para la consulta de red, más allá de `URLRequest.timeoutInterval`.
    static let fetchBudget: Duration = .seconds(5)

    /// Ventanas que se muestran, en orden, con su etiqueta. La caché trae muchas más
    /// (buckets internos, la mayoría en `null`); solo interesan estas.
    private static let windowLabels: [(key: String, label: String)] = [
        ("five_hour", "5 horas"),
        ("seven_day", "Semanal"),
        ("seven_day_opus", "Opus semanal"),
        ("seven_day_sonnet", "Sonnet semanal")
    ]

    private static let log = Logger(subsystem: "io.github.jhosgun.tokenbar", category: "claude-limits")

    private let cacheURL: URL
    private let session: URLSession
    /// El llavero se consulta UNA vez por arranque: cada lectura de una entrada ajena puede
    /// abrir un diálogo de autorización, y hacerlo cada 30 s sería inaceptable.
    private let tokenCache: KeychainTokenCache
    /// Válvula de la consulta de red (ver `networkInterval`).
    private let throttle: NetworkThrottle
    private let userAgent: String

    init(cacheURL: URL = ClaudeLimitsProvider.defaultCacheURL,
         session: URLSession = .shared,
         tokenCache: KeychainTokenCache = KeychainTokenCache(service: ClaudeLimitsProvider.keychainService),
         userAgent: String = ClaudeLimitsProvider.userAgent()) {
        self.cacheURL = cacheURL
        self.session = session
        self.tokenCache = tokenCache
        self.throttle = NetworkThrottle(interval: ClaudeLimitsProvider.networkInterval)
        self.userAgent = userAgent
    }

    func fetch() async -> LimitsSnapshot {
        let now = Date()
        let cached = Self.cachedUsage(at: cacheURL, now: now)

        // La red es respaldo: sin caché, o con caché de más de 2 h, y respetando la
        // válvula de 15 min. El backoff de un 429 vigente lo impone el ViewModel: si hay
        // backoff, `fetch()` ni siquiera se llama.
        let needsNetwork = cached.map { $0.age >= Self.networkFallbackAge } ?? true
        if needsNetwork, await throttle.tryAttempt(now: now) {
            let network = await NetworkDeadline.run(budget: Self.fetchBudget) {
                await self.fetchFromNetwork()
            } ?? .empty(source, .failed("Tiempo de espera agotado"))
            if case .ok = network.status { return network }
            // Un token rotado o revocado es un estado definitivo: manda sobre la caché,
            // aunque esta todavía tenga ventanas que mostrar. Mostrarlas ocultaría que hay
            // que volver a iniciar sesión.
            if case .invalidCredentials = network.status { return network }
            // El 429 tiene que llegar al ViewModel para el backoff, pero sin tirar la
            // caché: se devuelve con las ventanas y la marca de rate limit.
            if network.rateLimited, let cached {
                var merged = cached.snapshot
                merged.rateLimited = true
                merged.rateLimitedUntil = network.rateLimitedUntil
                return merged
            }
            // Cualquier otro fallo de red deja la caché marcada como último dato bueno.
            return cached?.snapshot ?? network
        }

        if let cached { return cached.snapshot }
        // Sin caché y sin poder consultar todavía (la válvula cortó un reintento < 15 min).
        return .empty(source, .failed("Sin datos de cuota"))
    }

    // MARK: - Caché local

    /// Lo que se sabe de la caché local: el snapshot listo para mostrar y su edad.
    struct CachedUsage: Equatable, Sendable {
        var snapshot: LimitsSnapshot
        /// Segundos desde que Claude Code escribió el dato (`fetchedAtMs`).
        var age: TimeInterval
    }

    /// Lee `cachedUsageUtilization` de `~/.claude.json` — la ÚNICA clave del archivo que
    /// se consulta. Devuelve nil si el archivo no existe, está corrupto, no trae la clave
    /// o no trae ninguna ventana conocida: el llamador cae entonces al respaldo de red.
    ///
    /// La utilización viene en porcentaje (0…100) y `resets_at` en ISO-8601 con offset,
    /// con o sin microsegundos. Las claves con `utilization: null` se omiten.
    static func cachedUsage(at url: URL, now: Date) -> CachedUsage? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cached = root["cachedUsageUtilization"] as? [String: Any],
              let fetchedAtMs = (cached["fetchedAtMs"] as? NSNumber)?.doubleValue,
              fetchedAtMs.isFinite, fetchedAtMs > 0,
              let utilization = cached["utilization"] as? [String: Any] else { return nil }

        let windows = windows(from: utilization)
        guard !windows.isEmpty else { return nil }

        let fetchedAt = Date(timeIntervalSince1970: fetchedAtMs / 1_000)
        let age = max(0, now.timeIntervalSince(fetchedAt))
        // Pasados 30 min el dato se muestra, pero marcado como desactualizado.
        let status: CollectorStatus = age > staleAge ? .failed(ago(age)) : .ok
        return CachedUsage(snapshot: LimitsSnapshot(source: .claudeCode, windows: windows,
                                                    planLabel: nil, status: status,
                                                    dataAsOf: fetchedAt),
                           age: age)
    }

    /// "hace 35m", "hace 2h 5m", "hace 2d" — la marca de dato desactualizado.
    static func ago(_ age: TimeInterval) -> String {
        let minutes = Int(max(0, age) / 60)
        switch minutes {
        case 0:         return "ahora"
        case ..<60:     return "hace \(minutes)m"
        case ..<1_440:
            let hours = minutes / 60
            let rest = minutes % 60
            return rest > 0 ? "hace \(hours)h \(rest)m" : "hace \(hours)h"
        default:        return "hace \(minutes / 1_440)d"
        }
    }

    // MARK: - Red (respaldo)

    private func fetchFromNetwork() async -> LimitsSnapshot {
        guard let token = Self.accessToken(from: await tokenCache.token()) else {
            return .empty(source, .notConfigured)
        }

        var request = URLRequest(url: Endpoint.usage)
        request.timeoutInterval = 5
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Endpoint.oauthBeta, forHTTPHeaderField: "anthropic-beta")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            Self.log.error("fallo de red: \(error.localizedDescription, privacy: .public)")
            return .empty(source, .failed("Sin conexión"))
        }

        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200..<300: break
            case 401, 403:
                // El token pudo haberse rotado: se olvida el cacheado para releer el
                // llavero en el próximo ciclo. Solo aquí — en errores de red el token
                // sigue siendo bueno y releer provocaría un diálogo innecesario.
                await tokenCache.invalidate()
                return .empty(source, .invalidCredentials)
            case 429:
                // El endpoint limita las consultas por token. El ViewModel aplica backoff;
                // aquí solo se reporta el estado y, si vino, el `Retry-After`.
                return .rateLimited(source, retryAfter: Self.retryAfter(from: http))
            default:        return .empty(source, .failed("HTTP \(http.statusCode)"))
            }
        }

        guard let parsed = Self.parse(data) else {
            return .empty(source, .failed("Respuesta no reconocida"))
        }
        return parsed
    }

    /// `claude-code/<versión del CLI>`: el UA con que Claude Code consulta este endpoint.
    static func userAgent(cliVersion: String = cliVersion()) -> String {
        "claude-code/\(cliVersion)"
    }

    /// Versión del CLI sin lanzar procesos: `~/.local/bin/claude` es un symlink a
    /// `~/.local/share/claude/versions/<versión>`. Si no se puede leer (instalación no
    /// estándar), se usa un default razonable.
    static func cliVersion() -> String {
        let link = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin/claude")
        let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)
        return versionFromLinkDestination(destination) ?? "2.0.0"
    }

    /// Extrae la versión del destino del symlink (`.../versions/2.1.283` → `2.1.283`).
    static func versionFromLinkDestination(_ destination: String?) -> String? {
        guard let destination, !destination.isEmpty else { return nil }
        let candidate = URL(fileURLWithPath: destination).lastPathComponent
        let isVersion = candidate.range(of: #"^\d+(\.\d+)*$"#, options: .regularExpression) != nil
        return isVersion ? candidate : nil
    }

    // MARK: - Parsing

    /// La credencial es un JSON con la sesión de Claude Code. Se acepta tanto el objeto
    /// anidado (`claudeAiOauth.accessToken`) como un `accessToken` en la raíz, y también
    /// un token pelado por si el formato cambia.
    static func accessToken(from raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        guard raw.hasPrefix("{"),
              let data = raw.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // No es JSON: se asume que ya es el token.
            return raw
        }
        let container = (root["claudeAiOauth"] as? [String: Any]) ?? root
        let token = container["accessToken"] as? String ?? container["access_token"] as? String
        guard let token, !token.isEmpty else { return nil }
        return token
    }

    /// Convierte la respuesta del endpoint en ventanas. Las que vienen `null` o sin
    /// utilización se omiten: el endpoint expone muchos buckets que no aplican al plan.
    static func parse(_ data: Data) -> LimitsSnapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let windows = windows(from: root)
        guard !windows.isEmpty else { return nil }

        // Créditos extra: solo se muestra como etiqueta si están habilitados. Cifras que no
        // quepan en un Int (o no finitas) se descartan en vez de reventar la conversión.
        var plan: String?
        if let extra = root["extra_usage"] as? [String: Any],
           extra["is_enabled"] as? Bool == true,
           let used = (extra["used_credits"] as? NSNumber)?.doubleValue, used.isFinite,
           let limit = (extra["monthly_limit"] as? NSNumber)?.doubleValue, limit.isFinite, limit > 0,
           let usedInt = Int(exactly: used.rounded()),
           let limitInt = Int(exactly: limit.rounded()) {
            plan = "créditos \(usedInt)/\(limitInt)"
        }

        return LimitsSnapshot(source: .claudeCode, windows: windows, planLabel: plan, status: .ok)
    }

    /// Las ventanas conocidas presentes en `container`, en el orden de `windowLabels`.
    /// Tanto la respuesta del endpoint como `cachedUsageUtilization.utilization` traen
    /// la utilización en porcentaje (0…100); aquí se normaliza a fracción (0…1).
    private static func windows(from container: [String: Any]) -> [LimitWindow] {
        let known: [LimitWindow] = windowLabels.compactMap { key, label in
            guard let bucket = container[key] as? [String: Any],
                  let raw = (bucket["utilization"] as? NSNumber)?.doubleValue,
                  let utilization = LimitWindow.utilization(fromPercent: raw) else { return nil }
            return LimitWindow(name: label,
                               utilization: utilization,
                               resetsAt: date(from: bucket["resets_at"]))
        }
        return known + scopedWindows(from: container, alreadyShown: Set(known.map(\.name)))
    }

    /// Las cuotas semanales por modelo (`limits[]` con `kind == "weekly_scoped"`), que es
    /// donde aparecen Fable, Opus o Sonnet cuando la cuenta los tiene topados aparte. Las
    /// entradas `session` y `weekly_all` se omiten: ya salen como "5 horas" y "Semanal".
    /// Comparten el reinicio de la ventana semanal, que es la que acotan.
    private static func scopedWindows(from container: [String: Any],
                                      alreadyShown: Set<String>) -> [LimitWindow] {
        guard let limits = container["limits"] as? [[String: Any]] else { return [] }
        let weeklyReset = (container["seven_day"] as? [String: Any])
            .flatMap { date(from: $0["resets_at"]) }

        var seen = alreadyShown
        return limits.compactMap { limit in
            guard limit["kind"] as? String == "weekly_scoped",
                  let percent = (limit["percent"] as? NSNumber)?.doubleValue,
                  let utilization = LimitWindow.utilization(fromPercent: percent),
                  let scope = limit["scope"] as? [String: Any],
                  let model = scope["model"] as? [String: Any],
                  let name = model["display_name"] as? String, !name.isEmpty else { return nil }
            let label = "\(name) semanal"
            guard seen.insert(label).inserted else { return nil }
            return LimitWindow(name: label, utilization: utilization, resetsAt: weeklyReset)
        }
    }

    /// `resets_at` llega en ISO8601 con offset explícito, con o sin fracciones de segundo.
    private static func date(from value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }

    /// Convierte el header `Retry-After` de una respuesta 429 en una fecha de reintento.
    /// Delega en `RetryAfter`, compartido por los seis proveedores.
    static func retryAfter(from response: HTTPURLResponse, now: Date = Date()) -> Date? {
        RetryAfter.date(from: response, now: now)
    }

    /// Válvula que impide consultar la red más de una vez cada `interval`. Vive en el
    /// proveedor (no en el ViewModel) porque la cadencia de 15 min es una regla de este
    /// endpoint, no del ciclo de refresco.
    actor NetworkThrottle {
        private let interval: TimeInterval
        private var lastAttempt: Date?

        init(interval: TimeInterval) {
            self.interval = interval
        }

        /// Devuelve true si toca consultar y registra el intento; false si aún no pasó
        /// el intervalo desde el último.
        func tryAttempt(now: Date) -> Bool {
            if let lastAttempt, now.timeIntervalSince(lastAttempt) < interval { return false }
            lastAttempt = now
            return true
        }
    }
}
