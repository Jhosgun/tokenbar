import Foundation
import OSLog
import Darwin

/// Cuota de la suscripción de Antigravity, consultada en el endpoint de Google con la
/// credencial del CLI y, si esta no está disponible o es rechazada, mediante `agy -p /usage`.
///
/// El endpoint devuelve los buckets reales de cuota. El CLI queda como respaldo porque
/// renueva por su cuenta la credencial del llavero. Su salida son líneas tabuladas con grupo
/// de modelos, ventana, **restante** en porcentaje y fecha de reinicio ISO-8601:
///
/// ```
/// Gemini Models	Weekly Limit Remaining	100%	2026-10-04T23:18:52Z
/// Gemini Models	Five Hour Limit Remaining	100%	2026-09-28T04:18:52Z
/// Claude and GPT models	Weekly Limit Remaining	100%	2026-10-04T23:18:52Z
/// Claude and GPT models	Five Hour Limit Remaining	100%	2026-09-28T04:18:52Z
/// ```
///
/// Ojo: el porcentaje es lo que **queda**, así que la utilización es `1 - restante/100`.
/// El CLI autentica por su propio llavero; el OAuth de `~/.gemini/oauth_creds.json` está
/// vencido y no se usa.
///
/// Lanzar un proceso en cada ciclo de 5 min es caro (~6 s y un proceso nuevo), así que el
/// resultado se cachea y el CLI no corre más de una vez cada 15 min: entre corridas se
/// devuelve lo último conocido, y si un reintento falla se muestra el último dato bueno
/// marcado con su antigüedad — el mismo patrón que la válvula de `ClaudeLimitsProvider`.
struct AntigravityLimitsProvider: LimitsProvider {
    let source: AppSource = .antigravity

    /// El resultado crudo de una ejecución del CLI, ya terminada.
    struct CLIOutput: Equatable, Sendable {
        var stdout: String
        var stderr: String
        /// Código de salida; `nil` si el proceso nunca llegó a arrancar.
        var exitCode: Int32?
        /// True si hubo que matar el proceso por pasarse de `processTimeout`.
        var timedOut: Bool
    }

    /// Ejecutor del CLI. Inyectable para que los tests no lancen procesos de verdad.
    typealias CLIRunner = @Sendable (URL) async -> CLIOutput
    typealias CredentialRead = @Sendable () async -> KeychainCredentialReadResult

    struct Credential: Equatable, Sendable {
        var accessToken: String
        var expiresAt: Date
    }

    private enum EndpointResult: Sendable {
        case snapshot(LimitsSnapshot)
        case fallbackToCLI
        case failed(String)
    }

    enum Endpoint {
        static let quota = URL(string: "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary")!
    }

    /// El CLI tarda ~6 s; 30 s es margen de sobra antes de matarlo.
    static let processTimeout: TimeInterval = 30
    /// Mínimo entre ejecuciones del CLI.
    static let cliInterval: TimeInterval = 15 * 60
    /// Lo máximo que `fetch()` espera al CLI. `LimitsProvider` pide no bloquear más de
    /// ~5 s y `UsageViewModel` espera a todos los proveedores antes de cerrar el refresco:
    /// si el CLI tarda más, la ejecución sigue en segundo plano y su resultado entra en el
    /// ciclo siguiente, en vez de frenar a las demás fuentes.
    static let fetchBudget: Duration = .seconds(5)
    /// B5: el CLI tarda ~6 s, más que el presupuesto normal de 5 s. En la primera corrida
    /// tras arrancar (sin nada en caché) se espera un poco más, para que la fila no quede
    /// 5 minutos en "Consultando…" mientras el CLI termina en segundo plano.
    static let firstRunBudget: Duration = .seconds(10)

    /// Rutas donde puede vivir el binario, en orden de preferencia. No se confía en el
    /// PATH del `.app`, que lanzado desde Finder es mínimo.
    static var candidateBinaries: [URL] {
        [URL(fileURLWithPath: "/opt/homebrew/bin/agy"),
         URL(fileURLWithPath: "/usr/local/bin/agy"),
         FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin/agy")]
    }

    private static let log = Logger(subsystem: "io.github.jhosgun.tokenbar", category: "antigravity-limits")

    private let candidates: [URL]
    private let run: CLIRunner
    private let session: URLSession
    private let credentialRead: CredentialRead
    private let now: @Sendable () -> Date
    private let cache: CLICache
    private let budget: Duration
    private let firstRunBudget: Duration

    init(candidates: [URL] = AntigravityLimitsProvider.candidateBinaries,
         cliInterval: TimeInterval = AntigravityLimitsProvider.cliInterval,
         budget: Duration = AntigravityLimitsProvider.fetchBudget,
         firstRunBudget: Duration = AntigravityLimitsProvider.firstRunBudget,
         session: URLSession = .shared,
         now: @escaping @Sendable () -> Date = Date.init,
         credentialRead: CredentialRead? = nil,
         run: @escaping CLIRunner = { await AntigravityLimitsProvider.runCLI(at: $0) }) {
        self.candidates = candidates
        self.run = run
        self.session = session
        if let credentialRead {
            self.credentialRead = credentialRead
        } else {
            let reader = KeychainCredentialReader(service: "gemini", account: "antigravity")
            self.credentialRead = { await reader.read() }
        }
        self.now = now
        self.cache = CLICache(interval: cliInterval)
        self.budget = budget
        self.firstRunBudget = firstRunBudget
    }

    func fetch() async -> LimitsSnapshot {
        let runBudget = await cache.isEmpty ? firstRunBudget : budget
        let current = now()
        let work: @Sendable () async -> Void = { [self] in
            let snapshot = await fetchFresh(now: current)
            let completedAt = now()
            await cache.store(snapshot, at: completedAt)
        }
        guard let task = await cache.run(now: current, work: work) else {
            return await cache.current(now: current) ?? .empty(source, .failed("Sin datos de cuota"))
        }

        _ = await NetworkDeadline.run(budget: runBudget, cancelOnTimeout: false) {
            await task.value
        }

        return await cache.current(now: now())
            ?? .empty(source, .failed("Consultando la cuota…"))
    }

    private func fetchFresh(now current: Date) async -> LimitsSnapshot {
        if let credential = Self.credential(from: await credentialRead()),
           credential.expiresAt.timeIntervalSince(current) > 60 {
            switch await fetchEndpoint(token: credential.accessToken) {
            case .snapshot(let snapshot):
                return snapshot
            case .failed(let message):
                return .empty(source, .failed(message))
            case .fallbackToCLI:
                break
            }
        }

        guard let binary = Self.findBinary(in: candidates) else {
            return .empty(source, .notConfigured)
        }
        return Self.snapshot(from: await run(binary), now: now())
    }

    // MARK: - Endpoint

    private func fetchEndpoint(token: String) async -> EndpointResult {
        var request = URLRequest(url: Endpoint.quota)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.httpBody = Data("{}".utf8)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let configuredRequest = request

        let response = await NetworkDeadline.run(budget: Self.fetchBudget) { [session] in
            do {
                let (data, response) = try await session.data(for: configuredRequest)
                guard let response = response as? HTTPURLResponse else {
                    return EndpointResult.failed("Sin conexión")
                }
                switch response.statusCode {
                case 200..<300:
                    guard let snapshot = Self.parseEndpoint(data) else {
                        return EndpointResult.failed("Respuesta no reconocida")
                    }
                    return EndpointResult.snapshot(snapshot)
                case 401, 403:
                    return EndpointResult.fallbackToCLI
                default:
                    return EndpointResult.failed("HTTP \(response.statusCode)")
                }
            } catch {
                return EndpointResult.failed("Sin conexión")
            }
        }
        return response ?? .failed("Tiempo de espera agotado")
    }

    static func credential(from result: KeychainCredentialReadResult) -> Credential? {
        guard case .credential(let raw) = result else { return nil }
        return credential(from: raw)
    }

    static func credential(from raw: String?) -> Credential? {
        let prefix = "go-keyring-base64:"
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              raw.hasPrefix(prefix),
              let data = Data(base64Encoded: String(raw.dropFirst(prefix.count))),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = root["token"] as? [String: Any],
              let accessToken = token["access_token"] as? String, !accessToken.isEmpty,
              let expiry = token["expiry"] as? String,
              let expiresAt = resetDate(expiry) else { return nil }
        return Credential(accessToken: accessToken, expiresAt: expiresAt)
    }

    static func parseEndpoint(_ data: Data) -> LimitsSnapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let groups = root["groups"] as? [[String: Any]] else { return nil }
        var windows: [LimitWindow] = []
        var seen: Set<String> = []
        for group in groups {
            guard let displayName = group["displayName"] as? String,
                  let groupLabel = groupLabel(displayName),
                  let buckets = group["buckets"] as? [[String: Any]] else { continue }
            for bucket in buckets {
                guard let displayName = bucket["displayName"] as? String,
                      let windowLabel = windowLabel(displayName) else { continue }
                guard let raw = (bucket["remainingFraction"] as? NSNumber)?.doubleValue,
                      raw.isFinite, (0...1).contains(raw) else { return nil }
                let name = "\(groupLabel) \(windowLabel)"
                guard seen.insert(name).inserted else { continue }
                let reset = (bucket["resetTime"] as? String).flatMap(resetDate)
                windows.append(LimitWindow(name: name, utilization: 1 - raw, resetsAt: reset))
            }
        }
        guard !windows.isEmpty else { return nil }
        let ordered = windows.filter { $0.name.hasSuffix("5 horas") }
            + windows.filter { !$0.name.hasSuffix("5 horas") }
        return LimitsSnapshot(source: .antigravity, windows: ordered, planLabel: nil, status: .ok)
    }

    // MARK: - Binario

    /// El primer candidato que existe y es ejecutable; nil si no hay CLI instalado.
    static func findBinary(in candidates: [URL] = candidateBinaries) -> URL? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    // MARK: - Interpretación

    /// Convierte la salida cruda del CLI en un snapshot. Nunca lanza: cualquier cosa
    /// irreconocible se reporta como `.failed` en vez de inventar cifras.
    static func snapshot(from output: CLIOutput, now: Date = Date()) -> LimitsSnapshot {
        // Si salieron ventanas parseables, ese dato manda aunque el proceso se quejara.
        if let parsed = parse(output.stdout) {
            return parsed
        }
        // Sin sesión el CLI lo dice en texto plano (por stderr o stdout) y suele salir con
        // código de error — por ejemplo "not logged into Antigravity".
        if isSessionMissing(output.stdout + "\n" + output.stderr) {
            return .empty(.antigravity, .invalidCredentials)
        }
        if output.timedOut {
            return .empty(.antigravity, .failed("El CLI no respondió"))
        }
        guard let exitCode = output.exitCode else {
            return .empty(.antigravity, .failed("No se pudo ejecutar agy"))
        }
        if exitCode != 0 {
            return .empty(.antigravity, .failed("agy falló (código \(exitCode))"))
        }
        return .empty(.antigravity, .failed("Respuesta no reconocida"))
    }

    /// Frases con las que el CLI avisa que no hay sesión iniciada. En minúsculas; la
    /// comparación es case-insensitive.
    private static let sessionNeedles = [
        "not logged in", "not authenticated", "no active session",
        "login required", "please log in"
    ]

    static func isSessionMissing(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        return sessionNeedles.contains { lowercased.contains($0) }
    }

    // MARK: - Parsing

    /// Parsea la salida tabulada. Tolera líneas de más o de menos: lo irreconocible (basura
    /// intercalada, grupos o ventanas desconocidos, porcentajes ilegibles) se ignora, y las
    /// ventanas repetidas conservan su primera aparición. Si no queda ninguna ventana, nil.
    static func parse(_ text: String) -> LimitsSnapshot? {
        var seen: Set<String> = []
        let windows = text.split(separator: "\n").compactMap { line -> LimitWindow? in
            guard let window = window(fromLine: String(line)),
                  seen.insert(window.name).inserted else { return nil }
            return window
        }
        guard !windows.isEmpty else { return nil }
        // Las de 5 horas primero: la fila plegada muestra la primera, y es la que decide
        // si puedes seguir trabajando ahora. El CLI las imprime al revés.
        let ordered = windows.filter { $0.name.hasSuffix("5 horas") }
            + windows.filter { !$0.name.hasSuffix("5 horas") }
        return LimitsSnapshot(source: .antigravity, windows: ordered, planLabel: nil, status: .ok)
    }

    /// Una línea "grupo \t ventana \t restante% \t reset ISO-8601" → su ventana de límite.
    /// El porcentaje es lo que **queda**: la utilización es `1 - restante/100`. Una fecha
    /// ilegible no invalida la línea: la ventana se muestra sin cuenta regresiva.
    static func window(fromLine line: String) -> LimitWindow? {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard fields.count >= 3,
              let group = groupLabel(fields[0]),
              let window = windowLabel(fields[1]),
              let remaining = remainingPercent(fields[2]),
              let utilization = LimitWindow.utilization(fromPercent: 100 - remaining) else { return nil }
        return LimitWindow(name: "\(group) \(window)",
                           utilization: utilization,
                           resetsAt: fields.count >= 4 ? resetDate(fields[3]) : nil)
    }

    /// "Gemini Models" → "Gemini"; "Claude and GPT models" → "Claude/GPT".
    static func groupLabel(_ field: String) -> String? {
        let normalized = field.lowercased()
        if normalized.contains("gemini") { return "Gemini" }
        if normalized.contains("claude") || normalized.contains("gpt") { return "Claude/GPT" }
        return nil
    }

    /// "Five Hour Limit Remaining" → "5 horas"; "Weekly Limit Remaining" → "semanal".
    static func windowLabel(_ field: String) -> String? {
        let normalized = field.lowercased().replacing("-", with: " ")
        if normalized.contains("five hour") || normalized.contains("5 hour") { return "5 horas" }
        if normalized.contains("weekly") { return "semanal" }
        return nil
    }

    /// "100%" → 100. Fuera de 0…100 el dato es imposible (nadie tiene un "130% restante")
    /// y se rechaza en vez de acotarse: acotarlo inventaría un usado que no es real.
    static func remainingPercent(_ field: String) -> Double? {
        var text = field
        if text.hasSuffix("%") { text.removeLast() }
        guard let value = Double(text.trimmingCharacters(in: .whitespaces)),
              value.isFinite, value >= 0, value <= 100 else { return nil }
        return value
    }

    /// El reset llega en ISO-8601 ("2026-10-04T23:18:52Z"), con o sin fracciones de segundo.
    static func resetDate(_ field: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: field) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: field)
    }

    /// "ahora", "hace 35m", "hace 2h 5m" — la marca de dato desactualizado.
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

    // MARK: - El proceso

    /// Ejecuta `agy -p /usage` y captura su salida. No bloquea el hilo que la llama: la
    /// espera la hace el `terminationHandler` del proceso, y un timer lo mata a los 30 s.
    static func runCLI(at binary: URL) async -> CLIOutput {
        await CLIRun(binary: binary, arguments: ["-p", "/usage"], timeout: processTimeout).start()
    }

    /// Corrida genérica de un binario, expuesta para que los tests puedan ejercitar el
    /// manejo de tuberías y timeout sin lanzar el `agy` real.
    static func runCommand(binary: URL, arguments: [String],
                           timeout: TimeInterval = processTimeout) async -> CLIOutput {
        await CLIRun(binary: binary, arguments: arguments, timeout: timeout).start()
    }

    /// Válvula + caché del resultado: el CLI no corre más de una vez cada `interval`
    /// (15 min), y mientras la válvula está cerrada se devuelve lo último que dio.
    actor CLICache {
        private let interval: TimeInterval
        private var lastAttempt: Date?
        /// Lo último que devolvió el CLI, sea éxito o error. Los estados definitivos
        /// (`invalidCredentials`) también se recuerdan: si no, la válvula cerrada los
        /// convertiría en un "Sin datos" que cambia el mensaje de la fila.
        private(set) var lastResult: LimitsSnapshot?
        /// El último `.ok` y cuándo llegó: es lo que se muestra marcado ante un fallo.
        private(set) var lastGood: (snapshot: LimitsSnapshot, at: Date)?

        init(interval: TimeInterval) {
            self.interval = interval
        }

        /// True si todavía no hay ningún resultado guardado (primera corrida).
        var isEmpty: Bool {
            lastResult == nil
        }

        /// Devuelve true si toca ejecutar el CLI y registra el intento; false si aún no
        /// pasó `interval` desde el último `.ok`. B4: la válvula solo se cierra tras un
        /// resultado `.ok`; un fallo se reintenta en el siguiente ciclo.
        func shouldRun(now: Date) -> Bool {
            if case .ok = lastResult?.status {
                if let lastAttempt, now.timeIntervalSince(lastAttempt) < interval { return false }
            }
            lastAttempt = now
            return true
        }

        /// La corrida en curso, si la hay: un refresco manual que llega mientras el CLI
        /// sigue en segundo plano espera a esa misma corrida en vez de lanzar un segundo
        /// `agy`. Se libera al terminar, sea con éxito o con error, así que un fallo sigue
        /// siendo reintentable.
        private var inFlight: Task<Void, Never>?

        /// La corrida a esperar: la que ya está en curso o una nueva si toca ejecutar el
        /// CLI; nil si la válvula está cerrada.
        func run(now: Date, work: @escaping @Sendable () async -> Void) -> Task<Void, Never>? {
            if let inFlight { return inFlight }
            guard shouldRun(now: now) else { return nil }
            let task = Task {
                await work()
                self.finishRun()
            }
            inFlight = task
            return task
        }

        private func finishRun() {
            inFlight = nil
        }

        func store(_ snapshot: LimitsSnapshot, at date: Date) {
            // B18: el dato servido desde caché lleva su fecha real, no la de la consulta.
            var stored = snapshot
            stored.dataAsOf = date
            lastResult = stored
            if case .ok = stored.status { lastGood = (stored, date) }
        }

        /// Lo que hay que mostrar ahora: el último resultado, salvo que haya fallado sin
        /// traer ventanas y exista un dato bueno anterior — entonces se muestra ese,
        /// marcado con su antigüedad. Se recalcula en cada consulta para que la marca
        /// envejezca aunque el CLI no se vuelva a ejecutar.
        func current(now: Date) -> LimitsSnapshot? {
            guard let lastResult else { return nil }
            guard case .failed = lastResult.status, lastResult.windows.isEmpty,
                  let lastGood else { return lastResult }
            var marked = lastGood.snapshot
            marked.status = .failed(AntigravityLimitsProvider.ago(now.timeIntervalSince(lastGood.at)))
            marked.dataAsOf = lastGood.at
            return marked
        }
    }

    /// Una corrida del proceso. `Process` no es `Sendable`; aquí solo lo tocan el hilo que
    /// lo lanza, el handler de terminación y el timer del timeout, y el `NSLock` garantiza
    /// que el continuation se reanuda exactamente una vez.
    private final class CLIRun: @unchecked Sendable {
        private let process = Process()
        private let stdout = Pipe()
        private let stderr = Pipe()
        private let timeout: TimeInterval
        private let lock = NSLock()
        private let dataLock = NSLock()
        private var continuation: CheckedContinuation<CLIOutput, Never>?
        private var timedOut = false
        private var stdoutData = Data()
        private var stderrData = Data()
        /// Se libera cuando cada tubería llega a EOF: la terminación del proceso espera a
        /// que el último `readabilityHandler` haya anexado su trozo antes de armar la salida.
        private let eof = DispatchGroup()
        private var closedPipes: Set<ObjectIdentifier> = []

        /// Tiempo máximo que la terminación espera el EOF. Si un hijo heredó el descriptor
        /// la tubería no cierra nunca, y sin este tope el hijo colgaría la corrida.
        private static let eofGrace: DispatchTimeInterval = .milliseconds(500)

        init(binary: URL, arguments: [String], timeout: TimeInterval) {
            process.executableURL = binary
            process.arguments = arguments
            process.standardOutput = stdout
            process.standardError = stderr
            self.timeout = timeout
        }

        func start() async -> CLIOutput {
            await withCheckedContinuation { continuation in
                lock.lock()
                self.continuation = continuation
                lock.unlock()

                // B14: se lee mientras el proceso corre. Si nadie drenara las tuberías y la
                // salida superara el buffer (64 KB), el proceso se quedaría bloqueado
                // escribiendo y solo lo sacaría el timeout.
                eof.enter()
                stdout.fileHandleForReading.readabilityHandler = { [self] handle in
                    drain(handle, into: \.stdoutData)
                }
                eof.enter()
                stderr.fileHandleForReading.readabilityHandler = { [self] handle in
                    drain(handle, into: \.stderrData)
                }

                process.terminationHandler = { [self] process in
                    process.terminationHandler = nil
                    // B14: el proceso puede terminar antes de que el último callback de
                    // lectura anexe su trozo, así que se espera (con tope) a que ambas
                    // tuberías lleguen a EOF. No se usa `readDataToEndOfFile`: con un hijo
                    // que heredara el descriptor colgaría para siempre.
                    _ = eof.wait(timeout: .now() + Self.eofGrace)
                    stdout.fileHandleForReading.readabilityHandler = nil
                    stderr.fileHandleForReading.readabilityHandler = nil
                    dataLock.lock()
                    let out = String(decoding: stdoutData, as: UTF8.self)
                    let err = String(decoding: stderrData, as: UTF8.self)
                    dataLock.unlock()
                    try? stdout.fileHandleForReading.close()
                    try? stderr.fileHandleForReading.close()
                    lock.lock()
                    let wasTimedOut = timedOut
                    lock.unlock()
                    finish(CLIOutput(stdout: out, stderr: err,
                                     exitCode: process.terminationStatus, timedOut: wasTimedOut))
                }

                // El timeout vive aparte: SIGTERM al vencer y, si el proceso no muere a los
                // 2 s, SIGKILL de respaldo.
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [self] in
                    if process.isRunning {
                        lock.lock()
                        timedOut = true
                        lock.unlock()
                        process.terminate()
                        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [self] in
                            if process.isRunning {
                                kill(process.processIdentifier, SIGKILL)
                            }
                        }
                    }
                }

                do {
                    try process.run()
                } catch {
                    AntigravityLimitsProvider.log.error(
                        "no se pudo lanzar agy: \(error.localizedDescription, privacy: .public)")
                    stdout.fileHandleForReading.readabilityHandler = nil
                    stderr.fileHandleForReading.readabilityHandler = nil
                    finish(CLIOutput(stdout: "", stderr: "", exitCode: nil, timedOut: false))
                }
            }
        }

        /// Anexa lo disponible en la tubería; en EOF desarma el handler y libera `eof`.
        private func drain(_ handle: FileHandle, into buffer: ReferenceWritableKeyPath<CLIRun, Data>) {
            let chunk = handle.availableData
            dataLock.lock()
            defer { dataLock.unlock() }
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                // `leave` una sola vez por tubería, aunque el handler vuelva a dispararse.
                if closedPipes.insert(ObjectIdentifier(handle)).inserted { eof.leave() }
            } else {
                self[keyPath: buffer].append(chunk)
            }
        }

        /// Reanuda el continuation una sola vez; llamadas posteriores se ignoran.
        private func finish(_ output: CLIOutput) {
            lock.lock()
            guard let continuation else { lock.unlock(); return }
            self.continuation = nil
            lock.unlock()
            continuation.resume(returning: output)
        }
    }
}
