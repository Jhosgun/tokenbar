import Foundation
import OSLog

/// Cuota de la suscripción de Antigravity, leída de su **CLI** (`agy`).
///
/// Esta fila cubre el **CLI**, no el IDE: su cuota no está en ningún archivo, vive en memoria del
/// CLI. Pero `agy -p /usage` la imprime en modo print — según el changelog del CLI es de
/// solo lectura: no inicia un turno de agente ni gasta cuota (verificado en este Mac,
/// tarda ~6 s). La salida son líneas tabuladas con grupo de modelos, ventana, **restante**
/// en porcentaje y fecha de reinicio ISO-8601:
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

    /// El CLI tarda ~6 s; 30 s es margen de sobra antes de matarlo.
    static let processTimeout: TimeInterval = 30
    /// Mínimo entre ejecuciones del CLI.
    static let cliInterval: TimeInterval = 15 * 60
    /// Lo máximo que `fetch()` espera al CLI. `LimitsProvider` pide no bloquear más de
    /// ~5 s y `UsageViewModel` espera a todos los proveedores antes de cerrar el refresco:
    /// si el CLI tarda más, la ejecución sigue en segundo plano y su resultado entra en el
    /// ciclo siguiente, en vez de frenar a las demás fuentes.
    static let fetchBudget: Duration = .seconds(5)

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
    private let cache: CLICache
    private let budget: Duration

    init(candidates: [URL] = AntigravityLimitsProvider.candidateBinaries,
         cliInterval: TimeInterval = AntigravityLimitsProvider.cliInterval,
         budget: Duration = AntigravityLimitsProvider.fetchBudget,
         run: @escaping CLIRunner = { await AntigravityLimitsProvider.runCLI(at: $0) }) {
        self.candidates = candidates
        self.run = run
        self.cache = CLICache(interval: cliInterval)
        self.budget = budget
    }

    func fetch() async -> LimitsSnapshot {
        // La detección se repite en cada ciclo: es barata (un stat por ruta) y si se
        // instala el CLI con la app abierta, la fila aparece sola sin reiniciar.
        guard let binary = Self.findBinary(in: candidates) else {
            return .empty(source, .notConfigured)
        }

        let now = Date()
        guard await cache.shouldRun(now: now) else {
            // Válvula cerrada: lo último que dio el CLI, sin lanzar nada. La marca de dato
            // viejo la pone la caché, así que sobrevive a los ciclos en que no se ejecuta.
            return await cache.current(now: now) ?? .empty(source, .failed("Sin datos de cuota"))
        }

        // La ejecución vive en su propia tarea: si se pasa del presupuesto, `fetch()`
        // devuelve lo último conocido y la tarea sigue, guardando su resultado para el
        // ciclo siguiente.
        let work = Task.detached(priority: .utility) { [run, cache] in
            await cache.store(Self.snapshot(from: await run(binary)), at: Date())
        }
        await Self.wait(for: work, upTo: budget)

        return await cache.current(now: Date())
            ?? .empty(source, .failed("Consultando la cuota…"))
    }

    /// Espera a la tarea, pero no más de `budget`. No la cancela al vencer: el CLI ya está
    /// corriendo y su resultado sirve igual para el ciclo siguiente.
    ///
    /// No se usa un `TaskGroup`: al salir espera a todos sus hijos, así que el que aguarda
    /// al CLI mantendría el bloqueo aunque venza el presupuesto. Con dos tareas sueltas y
    /// una compuerta que solo reanuda una vez, la espera se abandona de verdad.
    private static func wait(for work: Task<Void, Never>, upTo budget: Duration) async {
        let gate = FirstResume()
        await withCheckedContinuation { continuation in
            Task {
                await work.value
                await gate.resume(continuation)
            }
            Task {
                try? await Task.sleep(for: budget)
                await gate.resume(continuation)
            }
        }
    }

    /// Reanuda un continuation una sola vez, gane quien gane la carrera.
    private actor FirstResume {
        private var resumed = false

        func resume(_ continuation: CheckedContinuation<Void, Never>) {
            guard !resumed else { return }
            resumed = true
            continuation.resume()
        }
    }

    // MARK: - Binario

    /// El primer candidato que existe y es ejecutable; nil si no hay CLI instalado.
    static func findBinary(in candidates: [URL] = candidateBinaries) -> URL? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    // MARK: - Interpretación

    /// Convierte la salida cruda del CLI en un snapshot. Nunca lanza: cualquier cosa
    /// irreconocible se reporta como `.failed` en vez de inventar cifras.
    static func snapshot(from output: CLIOutput) -> LimitsSnapshot {
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
        // Las de 5 h primero: la fila plegada muestra la primera, y es la que decide si
        // puedes seguir trabajando ahora. El CLI las imprime al revés.
        let ordered = windows.filter { $0.name.hasSuffix("5 h") }
            + windows.filter { !$0.name.hasSuffix("5 h") }
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
              let remaining = remainingPercent(fields[2]) else { return nil }
        return LimitWindow(name: "\(group) \(window)",
                           utilization: 1 - remaining / 100,
                           resetsAt: fields.count >= 4 ? resetDate(fields[3]) : nil)
    }

    /// "Gemini Models" → "Gemini"; "Claude and GPT models" → "Claude/GPT".
    static func groupLabel(_ field: String) -> String? {
        let normalized = field.lowercased()
        if normalized.contains("gemini") { return "Gemini" }
        if normalized.contains("claude") || normalized.contains("gpt") { return "Claude/GPT" }
        return nil
    }

    /// "Five Hour Limit Remaining" → "5 h"; "Weekly Limit Remaining" → "semanal".
    static func windowLabel(_ field: String) -> String? {
        let normalized = field.lowercased().replacing("-", with: " ")
        if normalized.contains("five hour") || normalized.contains("5 hour") { return "5 h" }
        if normalized.contains("weekly") { return "semanal" }
        return nil
    }

    /// "100%" → 100. Se acota a 0…100 para que la utilización nunca salga de 0…1.
    static func remainingPercent(_ field: String) -> Double? {
        var text = field
        if text.hasSuffix("%") { text.removeLast() }
        guard let value = Double(text.trimmingCharacters(in: .whitespaces)),
              value.isFinite, value >= 0 else { return nil }
        return min(value, 100)
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
        await CLIRun(binary: binary, timeout: processTimeout).start()
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

        /// Devuelve true si toca ejecutar el CLI y registra el intento; false si aún no
        /// pasó `interval` desde el último.
        func shouldRun(now: Date) -> Bool {
            if let lastAttempt, now.timeIntervalSince(lastAttempt) < interval { return false }
            lastAttempt = now
            return true
        }

        func store(_ snapshot: LimitsSnapshot, at date: Date) {
            lastResult = snapshot
            if case .ok = snapshot.status { lastGood = (snapshot, date) }
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
        private var continuation: CheckedContinuation<CLIOutput, Never>?
        private var timedOut = false

        init(binary: URL, timeout: TimeInterval) {
            process.executableURL = binary
            process.arguments = ["-p", "/usage"]
            process.standardOutput = stdout
            process.standardError = stderr
            self.timeout = timeout
        }

        func start() async -> CLIOutput {
            await withCheckedContinuation { continuation in
                lock.lock()
                self.continuation = continuation
                lock.unlock()

                process.terminationHandler = { [self] process in
                    process.terminationHandler = nil
                    let out = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(),
                                     as: UTF8.self)
                    let err = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(),
                                     as: UTF8.self)
                    lock.lock()
                    let wasTimedOut = timedOut
                    lock.unlock()
                    finish(CLIOutput(stdout: out, stderr: err,
                                     exitCode: process.terminationStatus, timedOut: wasTimedOut))
                }

                // El timeout vive aparte: si el proceso sigue vivo al vencer, se mata y el
                // handler de arriba reporta la salida (vacía o parcial) como timeout.
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [self] in
                    if process.isRunning {
                        lock.lock()
                        timedOut = true
                        lock.unlock()
                        process.terminate()
                    }
                }

                do {
                    try process.run()
                } catch {
                    AntigravityLimitsProvider.log.error(
                        "no se pudo lanzar agy: \(error.localizedDescription, privacy: .public)")
                    finish(CLIOutput(stdout: "", stderr: "", exitCode: nil, timedOut: false))
                }
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
