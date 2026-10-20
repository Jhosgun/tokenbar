import Foundation
import OSLog

/// Lee la cuota real de la suscripción de Claude.
///
/// **Fuente primaria: la red.** `GET https://api.anthropic.com/api/oauth/usage` devuelve
/// `five_hour`, `seven_day` y `limits[]` con el porcentaje usado de cada ventana. La caché
/// local de Claude Code (`cachedUsageUtilization` en `~/.claude.json`) dejó de escribirse
/// y quedó como fuente opcional: si reaparece con un dato más reciente que el último de
/// red, se usa; si no, se ignora.
///
/// **Token.** La credencial OAuth vive en el llavero bajo el service
/// `Claude Code-credentials`, pero es una entrada ajena: leerla con `SecItemCopyMatching`
/// abre un diálogo de autorización cada vez que Claude Code la recrea (6,9 s contra un
/// plazo de 5 s). Por eso se lee ejecutando `/usr/bin/security` en un subproceso — está en
/// la lista de acceso de la entrada y devuelve en ~0,02 s sin diálogo — con timeout propio
/// y kill. Se relee en cada intento de red (es barato) para recoger tokens rotados.
///
/// **Cadencia propia.** Mínimo 15 min entre GETs; tras un 429 respeta `Retry-After` o
/// escala 15 → 30 → 60 min. La válvula solo se registra cuando el servidor respondió: un
/// fallo de transporte (sin red, timeout) deja el siguiente GET a 60 s, no a 15 min.
///
/// **Persistencia.** El último snapshot bueno se guarda en `claude-limits.json`
/// (`UsageStore.defaultDirectory`), solo ventanas, plan y fecha — ningún secreto — para
/// sobrevivir al reinicio de la app y servirse mientras no toque consultar.
actor ClaudeLimitsProvider: LimitsProvider {
    nonisolated let source: AppSource = .claudeCode

    enum Endpoint {
        static let usage = URL(string: "https://api.anthropic.com/api/oauth/usage")!
        static let oauthBeta = "oauth-2025-04-20"
    }

    /// La credencial OAuth con que se firma el GET: token y su vencimiento. `expiresAt`
    /// es `nil` si la credencial no lo informa (se trata como vigente).
    struct Credential: Equatable, Sendable {
        var accessToken: String
        var expiresAt: Date?
    }

    /// Lo que se sabe de la caché local de Claude Code (`~/.claude.json`).
    struct CachedUsage: Equatable, Sendable {
        var snapshot: LimitsSnapshot
        var age: TimeInterval
    }

    /// Forma persistida de una ventana: nombre, fracción usada y reinicio.
    private struct StoredWindow: Codable {
        var name: String
        var utilization: Double
        var resetsAt: Date?
    }

    /// Forma persistida del último snapshot bueno, sin ningún secreto.
    private struct StoredSnapshot: Codable {
        var version: Int
        var windows: [StoredWindow]
        var planLabel: String?
        var dataAsOf: Date
    }

    /// Resultado acotado de un GET: respuesta HTTP, vencimiento del plazo o fallo de red.
    private enum GETResult: Sendable {
        case response(Data, HTTPURLResponse)
        case timedOut
        case networkFailure
    }

    typealias CredentialRead = @Sendable () async -> ClaudeCredentialReadResult

    static var defaultCacheURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude.json")
    }

    /// Mínimo entre consultas de red con respuesta del servidor: el dato cambia en horas.
    static let networkInterval: TimeInterval = 15 * 60
    /// Plazo absoluto del GET, más allá de `URLRequest.timeoutInterval`.
    static let fetchBudget: Duration = .seconds(5)
    /// Mínimo antes de reintentar tras un fallo de transporte (sin red o timeout): no es
    /// rate limit, así que no debe pagar 15 min, pero tampoco se martilla al servidor.
    static let minTransportRetry: TimeInterval = 60

    private static let fileName = "claude-limits.json"
    private static let formatVersion = 1
    private static let windowLabels: [(key: String, label: String)] = [
        ("five_hour", "5 horas"),
        ("seven_day", "Semanal"),
        ("seven_day_opus", "Opus semanal"),
        ("seven_day_sonnet", "Sonnet semanal")
    ]
    private static let fallbackLabels = ["session": "5 horas", "weekly_all": "Semanal"]
    private static let log = Logger(subsystem: "io.github.jhosgun.tokenbar", category: "claude-limits")

    private let cacheURL: URL
    private let session: URLSession
    private let credentialRead: CredentialRead
    private let userAgent: String
    private let now: @Sendable () -> Date
    private let directory: URL
    private let fileURL: URL

    private var loaded = false
    private var networkSnapshot: LimitsSnapshot?
    private var nextGETAt: Date?
    private var preparingGET = false
    private var rateLimitLevel = 0
    /// Token que el servidor rechazó con 401 de forma definitiva. Mientras esté presente,
    /// cada ciclo relee la credencial y muestra el último dato como inválido hasta que el
    /// usuario vuelve a iniciar sesión (el token cambia) o un 2xx confirma el token nuevo.
    private var rejectedToken: String?

    init(cacheURL: URL = ClaudeLimitsProvider.defaultCacheURL,
         session: URLSession = .shared,
         credentialRead: CredentialRead? = nil,
         userAgent: String = ClaudeLimitsProvider.userAgent(),
         directory: URL = UsageStore.defaultDirectory,
         now: @escaping @Sendable () -> Date = Date.init) {
        self.cacheURL = cacheURL
        self.session = session
        if let credentialRead {
            self.credentialRead = credentialRead
        } else {
            let reader = ClaudeCredentialReader()
            self.credentialRead = { await reader.read() }
        }
        self.userAgent = userAgent
        self.directory = directory
        self.fileURL = directory.appendingPathComponent(Self.fileName, isDirectory: false)
        self.now = now
    }

    func fetch() async -> LimitsSnapshot {
        let current = now()
        loadIfNeeded()
        let local = Self.cachedUsage(at: cacheURL, now: current)?.snapshot
        let available = bestSnapshot(local: local, now: current)

        // Rechazo en curso: se maneja antes que la válvula para que la recuperación por
        // token rotado no tenga que esperar los 15 min de un GET fallido por 401.
        if let rejected = rejectedToken {
            return await recoverFromRejection(rejected, available: available, now: current)
        }

        if preparingGET || nextGETAt.map({ current < $0 }) == true {
            return available ?? .empty(source, .failed("Sin datos de cuota"))
        }

        preparingGET = true
        let credentialResult = await credentialRead()
        guard let credential = Self.credential(from: credentialResult) else {
            preparingGET = false
            return snapshotForCredentialFailure(credentialResult, available: available, now: current)
        }
        guard credential.expiresAt.map({ $0 > current }) ?? true else {
            preparingGET = false
            return applying(.failed("Sesión vencida: abre Claude Code"), to: available, now: current)
        }

        // La válvula se registra ANTES del GET: solo importa si el servidor llegó a
        // responder (2xx/4xx/5xx). Un fallo de transporte la rebaja luego a 60 s en `resolve`.
        nextGETAt = current.addingTimeInterval(Self.networkInterval)
        let first = await performGET(token: credential.accessToken)
        let result = await resolve(first, credential: credential, available: available, now: current)
        preparingGET = false
        return result
    }

    /// Rechazo de credencial en curso: relee el token en cada ciclo (barato) y, si ya no
    /// es el rechazado y no está vencido, dispara el GET de inmediato sin esperar la
    /// válvula. Mientras siga el mismo token, devuelve el último dato marcado como
    /// inválido en vez de alternar con `.ok`.
    private func recoverFromRejection(_ rejected: String, available: LimitsSnapshot?,
                                      now current: Date) async -> LimitsSnapshot {
        // Evita que una llamada concurrente relea y dispare un GET duplicado.
        if preparingGET {
            return applying(.failed("Token inválido: abre Claude Code"), to: available, now: current)
        }
        preparingGET = true
        defer { preparingGET = false }

        let reread = await credentialRead()
        if let credential = Self.credential(from: reread),
           credential.accessToken != rejected,
           credential.expiresAt.map({ $0 > current }) ?? true {
            rejectedToken = nil
            nextGETAt = current.addingTimeInterval(Self.networkInterval)
            let first = await performGET(token: credential.accessToken)
            return await resolve(first, credential: credential, available: available, now: current)
        }
        return applying(.failed("Token inválido: abre Claude Code"), to: available, now: current)
    }

    /// Resuelve un GET (inicial o reintentado tras un 401). `retried` distingue el primer
    /// 401 —que relee la credencial y reintenta una vez si el token cambió— de un 401
    /// repetido, que ya es un rechazo definitivo.
    private func resolve(_ result: GETResult, credential: Credential,
                         available: LimitsSnapshot?, now current: Date,
                         retried: Bool = false) async -> LimitsSnapshot {
        switch result {
        case .timedOut:
            // El servidor no respondió: no es rate limit. Se deja el reintento a 60 s.
            nextGETAt = current.addingTimeInterval(Self.minTransportRetry)
            return applying(.failed("Tiempo de espera agotado"), to: available, now: current)
        case .networkFailure:
            nextGETAt = current.addingTimeInterval(Self.minTransportRetry)
            return applying(.failed("Sin conexión"), to: available, now: current)
        case .response(let data, let response):
            switch response.statusCode {
            case 200..<300:
                guard var snapshot = Self.parse(data) else {
                    Self.log.error("respuesta de cuota Claude sin ventanas reconocidas")
                    return applying(.failed("Respuesta no reconocida"), to: available, now: current)
                }
                snapshot.dataAsOf = current
                networkSnapshot = snapshot
                rateLimitLevel = 0
                persist(snapshot)
                return resetExpiredWindows(in: snapshot, now: current)

            case 401:
                // Solo el 401 es rechazo de credencial. Un token recién leído distinto se
                // reintenta una vez; si el rechazo se repite (o el token no cambió), queda
                // registrado para mostrarse como inválido hasta que el usuario inicie sesión.
                if retried {
                    rejectedToken = credential.accessToken
                    return .empty(source, .invalidCredentials)
                }
                let reread = await credentialRead()
                guard let replacement = Self.credential(from: reread),
                      replacement.accessToken != credential.accessToken,
                      replacement.expiresAt.map({ $0 > current }) ?? true else {
                    rejectedToken = credential.accessToken
                    return .empty(source, .invalidCredentials)
                }
                let retry = await performGET(token: replacement.accessToken)
                return await resolve(retry, credential: replacement, available: available,
                                     now: current, retried: true)

            case 403:
                // Un 403 no es credencial inválida: el token es válido pero la cuenta no
                // tiene acceso al recurso. Se conserva el último dato, sin relectura.
                return applying(.failed("HTTP 403"), to: available, now: current)

            case 429:
                // El endpoint limita por token. Se respeta `Retry-After` si viene y, si
                // no, se escala 15 → 30 → 60 min hasta el siguiente éxito.
                let serverDate = Self.retryAfter(from: response, now: current)
                if let serverDate {
                    nextGETAt = max(current.addingTimeInterval(Self.networkInterval), serverDate)
                } else {
                    let delays: [TimeInterval] = [15 * 60, 30 * 60, 60 * 60]
                    let delay = delays[min(rateLimitLevel, delays.count - 1)]
                    rateLimitLevel = min(rateLimitLevel + 1, delays.count - 1)
                    nextGETAt = current.addingTimeInterval(delay)
                }
                return available ?? .empty(source, .failed("Límite de consultas alcanzado"))

            default:
                return applying(.failed("HTTP \(response.statusCode)"), to: available, now: current)
            }
        }
    }

    private func performGET(token: String) async -> GETResult {
        var request = URLRequest(url: Endpoint.usage)
        request.timeoutInterval = 5
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Endpoint.oauthBeta, forHTTPHeaderField: "anthropic-beta")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let configuredRequest = request

        let result = await NetworkDeadline.run(budget: Self.fetchBudget) { [session] in
            do {
                let (data, response) = try await session.data(for: configuredRequest)
                guard let response = response as? HTTPURLResponse else { return GETResult.networkFailure }
                return GETResult.response(data, response)
            } catch {
                return GETResult.networkFailure
            }
        }
        return result ?? .timedOut
    }

    /// Traduce un fallo al leer la credencial a un estado de UI, conservando el último dato.
    private func snapshotForCredentialFailure(_ result: ClaudeCredentialReadResult,
                                              available: LimitsSnapshot?, now current: Date) -> LimitsSnapshot {
        switch result {
        case .credential:
            return applying(.failed("Credencial no reconocida"), to: available, now: current)
        case .notFound, .denied:
            guard available != nil else { return .empty(source, .notConfigured) }
            return applying(.failed("No configurado"), to: available, now: current)
        case .locked:
            return applying(.failed("Llavero bloqueado"), to: available, now: current)
        case .timedOut:
            return applying(.failed("Tiempo de espera agotado"), to: available, now: current)
        case .failed:
            return applying(.failed("No se pudo leer la sesión"), to: available, now: current)
        }
    }

    /// Aplica un estado a un snapshot (o crea uno vacío), reiniciando las ventanas que ya
    /// vencieron y limpiando las marcas de rate limit de un estado anterior.
    private func applying(_ status: CollectorStatus, to snapshot: LimitsSnapshot?,
                          now current: Date) -> LimitsSnapshot {
        guard var snapshot else { return .empty(source, status) }
        snapshot = resetExpiredWindows(in: snapshot, now: current)
        snapshot.status = status
        snapshot.rateLimited = false
        snapshot.rateLimitedUntil = nil
        return snapshot
    }

    /// Elige entre el dato local (`~/.claude.json`, opcional) y el último de red: gana el
    /// más reciente, y el elegido se devuelve sano (`.ok`, sin marcas de rate limit).
    private func bestSnapshot(local: LimitsSnapshot?, now current: Date) -> LimitsSnapshot? {
        let selected: LimitsSnapshot?
        if let local, let networkSnapshot {
            selected = (local.dataAsOf ?? .distantPast) > (networkSnapshot.dataAsOf ?? .distantPast)
                ? local : networkSnapshot
        } else {
            selected = local ?? networkSnapshot
        }
        guard var selected else { return nil }
        selected.status = .ok
        selected.rateLimited = false
        selected.rateLimitedUntil = nil
        return resetExpiredWindows(in: selected, now: current)
    }

    /// Ventanas cuyo `resetsAt` ya pasó: se muestran en 0 % porque el uso no sube con
    /// Claude inactivo y la ventana ya se reinició.
    private func resetExpiredWindows(in snapshot: LimitsSnapshot, now current: Date) -> LimitsSnapshot {
        var snapshot = snapshot
        snapshot.windows = snapshot.windows.map { window in
            guard let reset = window.resetsAt, reset <= current else { return window }
            return LimitWindow(name: window.name, utilization: 0, resetsAt: reset)
        }
        return snapshot
    }

    /// Carga una vez el snapshot persistido en disco (si existe y es válido).
    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let payload = try JSONDecoder().decode(StoredSnapshot.self, from: Data(contentsOf: fileURL))
            guard payload.version == Self.formatVersion,
                  !payload.windows.isEmpty,
                  payload.windows.allSatisfy({ $0.utilization.isFinite && (0...1).contains($0.utilization) })
            else { return }
            networkSnapshot = LimitsSnapshot(
                source: source,
                windows: payload.windows.map {
                    LimitWindow(name: $0.name, utilization: $0.utilization, resetsAt: $0.resetsAt)
                },
                planLabel: payload.planLabel,
                status: .ok,
                dataAsOf: payload.dataAsOf)
        } catch {
            Self.log.error("no se pudo leer claude-limits.json: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Guarda el último snapshot bueno en disco, sin secretos: solo ventanas, plan y fecha.
    private func persist(_ snapshot: LimitsSnapshot) {
        guard let dataAsOf = snapshot.dataAsOf else { return }
        let payload = StoredSnapshot(
            version: Self.formatVersion,
            windows: snapshot.windows.map {
                StoredWindow(name: $0.name, utilization: $0.utilization, resetsAt: $0.resetsAt)
            },
            planLabel: snapshot.planLabel,
            dataAsOf: dataAsOf)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(payload).write(to: fileURL, options: .atomic)
        } catch {
            Self.log.error("no se pudo guardar claude-limits.json: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Lee `cachedUsageUtilization` de `~/.claude.json` — la única clave del archivo que
    /// se consulta. `nil` si el archivo no existe, está corrupto o no trae ventanas
    /// conocidas: el llamador se queda entonces con el último dato de red.
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
        return CachedUsage(
            snapshot: LimitsSnapshot(source: .claudeCode, windows: windows, planLabel: nil,
                                     status: .ok, dataAsOf: fetchedAt),
            age: max(0, now.timeIntervalSince(fetchedAt)))
    }

    static func credential(from result: ClaudeCredentialReadResult) -> Credential? {
        guard case .credential(let raw) = result else { return nil }
        return credential(from: raw)
    }

    /// Parsea la credencial: un JSON con `claudeAiOauth.accessToken` (o `access_token` en
    /// la raíz) y `claudeAiOauth.expiresAt` en milisegundos epoch. Sin token, `nil`.
    static func credential(from raw: String?) -> Credential? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let container = (root["claudeAiOauth"] as? [String: Any]) ?? root
        let token = container["accessToken"] as? String ?? container["access_token"] as? String
        guard let token, !token.isEmpty else { return nil }
        let expiresAt = (container["expiresAt"] as? NSNumber).map {
            Date(timeIntervalSince1970: $0.doubleValue / 1_000)
        }
        return Credential(accessToken: token, expiresAt: expiresAt)
    }

    static func accessToken(from raw: String?) -> String? {
        credential(from: raw)?.accessToken
    }

    /// `claude-code/<versión del CLI>`: el UA con que Claude Code consulta este endpoint.
    static func userAgent(cliVersion: String = cliVersion()) -> String {
        "claude-code/\(cliVersion)"
    }

    /// Versión del CLI sin lanzar procesos: `~/.local/bin/claude` es un symlink a
    /// `~/.local/share/claude/versions/<versión>`. Si no se puede leer, usa un default.
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

    /// Convierte la respuesta del endpoint en ventanas. `nil` si no trae ninguna conocida.
    static func parse(_ data: Data) -> LimitsSnapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let windows = windows(from: root)
        guard !windows.isEmpty else { return nil }

        // Créditos extra: solo se muestran como etiqueta si están habilitados. Cifras que
        // no quepan en un Int (o no finitas) se descartan en vez de reventar la conversión.
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

    /// Las ventanas conocidas presentes en `container`, en el orden de `windowLabels`, más
    /// las que aporta `limits[]`. Tanto el endpoint como la caché local traen la
    /// utilización en porcentaje (0…100); aquí se normaliza a fracción (0…1).
    private static func windows(from container: [String: Any]) -> [LimitWindow] {
        var result: [LimitWindow] = windowLabels.compactMap { key, label in
            guard let bucket = container[key] as? [String: Any],
                  let raw = (bucket["utilization"] as? NSNumber)?.doubleValue,
                  let utilization = LimitWindow.utilization(fromPercent: raw) else { return nil }
            return LimitWindow(name: label, utilization: utilization,
                               resetsAt: date(from: bucket["resets_at"]))
        }
        var shown = Set(result.map(\.name))
        // `limits[]` respalda la respuesta cuando faltan `five_hour`/`seven_day`:
        // `session` → "5 horas", `weekly_all` → "Semanal".
        if let limits = container["limits"] as? [[String: Any]] {
            for limit in limits {
                guard let kind = limit["kind"] as? String,
                      let label = fallbackLabels[kind],
                      !shown.contains(label),
                      let percent = (limit["percent"] as? NSNumber)?.doubleValue,
                      let utilization = LimitWindow.utilization(fromPercent: percent) else { continue }
                result.append(LimitWindow(name: label, utilization: utilization,
                                          resetsAt: date(from: limit["resets_at"])))
                shown.insert(label)
            }
        }
        result += scopedWindows(from: container, alreadyShown: shown)
        return result
    }

    /// Las cuotas semanales por modelo (`limits[]` con `kind == "weekly_scoped"`), que es
    /// donde aparecen Fable, Opus o Sonnet cuando la cuenta los tiene topados aparte. Las
    /// entradas `session` y `weekly_all` ya salen como "5 horas" y "Semanal". Cada modelo
    /// usa su propio `resets_at` si viene; si no, hereda el de la ventana semanal.
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
            let reset = date(from: limit["resets_at"]) ?? weeklyReset
            return LimitWindow(name: label, utilization: utilization, resetsAt: reset)
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
}
