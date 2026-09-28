import Foundation
import Testing

@testable import TokenBar

/// Reloj mutable y seguro para concurrencia: los tests avanzan el tiempo sin esperar.
private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Date
    init(_ start: Date) { storage = start }
    var now: Date {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); defer { lock.unlock() }; storage = newValue }
    }
}

/// Proveedor de límites de juguete: devuelve una secuencia de snapshots y cuenta las
/// llamadas a `fetch()`. Un actor porque `fetch()` corre fuera del MainActor.
private actor ScriptedLimitsProvider: LimitsProvider {
    let source: AppSource
    private var script: [LimitsSnapshot]
    private(set) var fetchCount = 0

    init(source: AppSource, script: [LimitsSnapshot]) {
        self.source = source
        self.script = script
    }

    func fetch() async -> LimitsSnapshot {
        fetchCount += 1
        return script.isEmpty ? .empty(source, .ok) : script.removeFirst()
    }
}

@MainActor
private func makeViewModel(
    providers: [any LimitsProvider],
    clock: Clock
) -> (viewModel: UsageViewModel, directory: URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("tokenbar-vm-tests-\(UUID().uuidString)", isDirectory: true)
    let viewModel = UsageViewModel(
        store: UsageStore(directory: directory),
        state: CollectorStateStore(directory: directory),
        collectors: [],
        limitsProviders: providers,
        now: { clock.now }
    )
    return (viewModel, directory)
}

private func okSnapshot(_ source: AppSource = .claudeCode) -> LimitsSnapshot {
    LimitsSnapshot(source: source,
                   windows: [LimitWindow(name: "5 horas", utilization: 0.5)],
                   planLabel: nil,
                   status: .ok)
}

@Suite("UsageViewModel — cadencia y backoff de límites")
struct UsageViewModelLimitsTests {

    @Test("no se vuelve a consultar antes de 5 min aunque haya refresh de tokens")
    @MainActor
    func noRefetchaAntesDeCincoMinutos() async {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let clock = Clock(t0)
        let provider = ScriptedLimitsProvider(source: .claudeCode, script: [okSnapshot()])
        let (vm, dir) = makeViewModel(providers: [provider], clock: clock)
        defer { try? FileManager.default.removeItem(at: dir) }

        await vm.refresh()
        #expect(await provider.fetchCount == 1)

        // +4 min: refresh de tokens, pero los límites no tocan (cadencia de 5 min).
        clock.now = t0.addingTimeInterval(4 * 60)
        await vm.refresh()
        #expect(await provider.fetchCount == 1)

        // +6 min total: ya pasó la cadencia, se consulta de nuevo.
        clock.now = t0.addingTimeInterval(6 * 60)
        await vm.refresh()
        #expect(await provider.fetchCount == 2)
    }

    @Test("tras un 429 se respeta Retry-After")
    @MainActor
    func respetaRetryAfter() async {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let clock = Clock(t0)
        // El 429 llega en t0+301 (pasada la cadencia) y pide esperar 60 s.
        let retryAfter = t0.addingTimeInterval(301 + 60)
        let provider = ScriptedLimitsProvider(source: .claudeCode, script: [
            okSnapshot(),
            .rateLimited(.claudeCode, retryAfter: retryAfter),
            okSnapshot()
        ])
        let (vm, dir) = makeViewModel(providers: [provider], clock: clock)
        defer { try? FileManager.default.removeItem(at: dir) }

        await vm.refresh()
        #expect(await provider.fetchCount == 1)

        clock.now = t0.addingTimeInterval(301)
        await vm.refresh()
        #expect(await provider.fetchCount == 2)

        // Dentro de la ventana de Retry-After ni el refresh manual fuerza la consulta.
        clock.now = t0.addingTimeInterval(330)
        await vm.refresh(forceLimits: true)
        #expect(await provider.fetchCount == 2)

        // Pasado Retry-After, el manual ya consulta.
        clock.now = t0.addingTimeInterval(362)
        await vm.refresh(forceLimits: true)
        #expect(await provider.fetchCount == 3)
    }

    @Test("tras un 429 sin Retry-After se aplica backoff exponencial")
    @MainActor
    func backoffExponencialSinRetryAfter() async {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let clock = Clock(t0)
        let provider = ScriptedLimitsProvider(source: .claudeCode, script: [
            okSnapshot(),
            .rateLimited(.claudeCode, retryAfter: nil),   // primer 429 → 5 min
            .rateLimited(.claudeCode, retryAfter: nil)    // segundo 429 → 10 min
        ])
        let (vm, dir) = makeViewModel(providers: [provider], clock: clock)
        defer { try? FileManager.default.removeItem(at: dir) }

        await vm.refresh()
        #expect(await provider.fetchCount == 1)

        clock.now = t0.addingTimeInterval(301)
        await vm.refresh()
        #expect(await provider.fetchCount == 2)

        // A los 60 s del 429, el manual no se salta el backoff de 5 min.
        clock.now = t0.addingTimeInterval(301 + 60)
        await vm.refresh(forceLimits: true)
        #expect(await provider.fetchCount == 2)

        // Pasados 5 min el manual consulta y recibe el segundo 429 (nivel 2: 10 min).
        clock.now = t0.addingTimeInterval(301 + 301)
        await vm.refresh(forceLimits: true)
        #expect(await provider.fetchCount == 3)

        // A 6 min del segundo 429, el backoff de 10 min todavía lo bloquea.
        clock.now = t0.addingTimeInterval(301 + 301 + 6 * 60)
        await vm.refresh(forceLimits: true)
        #expect(await provider.fetchCount == 3)
    }

    @Test("un fallo transitorio conserva las ventanas marcadas desactualizadas")
    @MainActor
    func falloTransitorioConservaVentanas() async {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let clock = Clock(t0)
        let provider = ScriptedLimitsProvider(source: .claudeCode, script: [
            okSnapshot(),
            .empty(.claudeCode, .failed("Sin conexión"))
        ])
        let (vm, dir) = makeViewModel(providers: [provider], clock: clock)
        defer { try? FileManager.default.removeItem(at: dir) }

        await vm.refresh()
        #expect(vm.limits[.claudeCode]?.windows.count == 1)
        #expect(vm.limits[.claudeCode]?.status == .ok)

        clock.now = t0.addingTimeInterval(12 * 60)
        await vm.refresh()

        guard let snapshot = vm.limits[.claudeCode] else {
            Issue.record("faltaba la fila de Claude tras el fallo")
            return
        }
        #expect(snapshot.windows.count == 1)
        #expect(snapshot.status == .failed("Sin conexión"))
        #expect(vm.lastGoodAt[.claudeCode] == t0)
        #expect(SourceRowView.ago(t0, now: clock.now) == "hace 12m")
        clock.now = t0.addingTimeInterval(35 * 60)
        #expect(SourceRowView.ago(t0, now: clock.now) == "hace 35m")
        #expect(await provider.fetchCount == 2)
    }

    @Test("dataAsOf manda sobre 'now': un snapshot fallido con dato viejo no dice 'ahora'")
    @MainActor
    func dataAsOfMandaSobreNow() async {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let clock = Clock(t0)
        // El dato real es de hace 47 min (por ejemplo la caché de ClaudeLimitsProvider),
        // aunque la consulta que lo trae ocurra justo ahora.
        let stale = LimitsSnapshot(source: .claudeCode,
                                   windows: [LimitWindow(name: "Semanal", utilization: 0.71)],
                                   planLabel: nil, status: .failed("hace 47m"),
                                   dataAsOf: t0.addingTimeInterval(-47 * 60))
        let provider = ScriptedLimitsProvider(source: .claudeCode, script: [stale])
        let (vm, dir) = makeViewModel(providers: [provider], clock: clock)
        defer { try? FileManager.default.removeItem(at: dir) }

        await vm.refresh()
        // Antes de este arreglo, lastGoodAt quedaba en `now` (t0) y la fila decía "ahora"
        // en vez de reflejar los 47 minutos reales del dato.
        #expect(vm.lastGoodAt[.claudeCode] == t0.addingTimeInterval(-47 * 60))
        #expect(SourceRowView.ago(vm.lastGoodAt[.claudeCode]!, now: t0) == "hace 47m")
    }

    @Test("un fallo con ventanas las muestra marcadas y las vuelve el último bueno")
    @MainActor
    func falloConVentanasLasMuestra() async {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let clock = Clock(t0)
        // La caché local de Claude llega marcada como desactualizada pero con ventanas.
        let stale = LimitsSnapshot(source: .claudeCode,
                                   windows: [LimitWindow(name: "Semanal", utilization: 0.71)],
                                   planLabel: nil, status: .failed("hace 47m"))
        let provider = ScriptedLimitsProvider(source: .claudeCode, script: [
            stale,
            .empty(.claudeCode, .failed("Sin conexión"))
        ])
        let (vm, dir) = makeViewModel(providers: [provider], clock: clock)
        defer { try? FileManager.default.removeItem(at: dir) }

        await vm.refresh()
        #expect(vm.limits[.claudeCode]?.windows.count == 1)
        #expect(vm.limits[.claudeCode]?.status == .failed("hace 47m"))

        // Un fallo posterior sin ventanas conserva esas ventanas como último bueno.
        clock.now = t0.addingTimeInterval(6 * 60)
        await vm.refresh()
        #expect(vm.limits[.claudeCode]?.windows.count == 1)
        #expect(vm.limits[.claudeCode]?.status == .failed("Sin conexión"))
        #expect(SourceRowView.ago(vm.lastGoodAt[.claudeCode]!, now: clock.now) == "hace 6m")
    }

    @Test("un 429 con ventanas en caché las conserva y aplica backoff")
    @MainActor
    func rateLimitConVentanasAplicaBackoff() async {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let clock = Clock(t0)
        var rateLimited = LimitsSnapshot(source: .claudeCode,
                                         windows: [LimitWindow(name: "Semanal", utilization: 0.71)],
                                         planLabel: nil, status: .failed("hace 2h"))
        rateLimited.rateLimited = true
        let provider = ScriptedLimitsProvider(source: .claudeCode, script: [
            rateLimited,
            okSnapshot()
        ])
        let (vm, dir) = makeViewModel(providers: [provider], clock: clock)
        defer { try? FileManager.default.removeItem(at: dir) }

        await vm.refresh()
        #expect(vm.limits[.claudeCode]?.windows.count == 1)
        #expect(vm.limits[.claudeCode]?.status == .failed("hace 2h"))

        // El backoff de 5 min del 429 se aplica aunque hubiera ventanas que mostrar.
        clock.now = t0.addingTimeInterval(4 * 60)
        await vm.refresh(forceLimits: true)
        #expect(await provider.fetchCount == 1)

        clock.now = t0.addingTimeInterval(6 * 60)
        await vm.refresh(forceLimits: true)
        #expect(await provider.fetchCount == 2)
        #expect(vm.limits[.claudeCode]?.status == .ok)
    }

    @Test("invalidCredentials sí vacía la fila")
    @MainActor
    func credencialesInvalidasVacianLaFila() async {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let clock = Clock(t0)
        let provider = ScriptedLimitsProvider(source: .claudeCode, script: [
            okSnapshot(),
            .empty(.claudeCode, .invalidCredentials)
        ])
        let (vm, dir) = makeViewModel(providers: [provider], clock: clock)
        defer { try? FileManager.default.removeItem(at: dir) }

        await vm.refresh()
        #expect(vm.limits[.claudeCode]?.windows.count == 1)

        clock.now = t0.addingTimeInterval(301)
        await vm.refresh()
        #expect(vm.limits[.claudeCode]?.windows.isEmpty == true)
        #expect(vm.limits[.claudeCode]?.status == .invalidCredentials)
    }
}

@Suite("ClaudeLimitsProvider — Retry-After")
struct ClaudeRetryAfterTests {

    @Test("acepta delta-segundos, fecha HTTP y ausencia")
    func parseaRetryAfter() {
        let url = URL(string: "https://api.anthropic.com")!
        let now = Date(timeIntervalSince1970: 1_000_000)

        let delta = HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil,
                                    headerFields: ["Retry-After": "60"])!
        #expect(ClaudeLimitsProvider.retryAfter(from: delta, now: now) == now.addingTimeInterval(60))

        let httpDate = HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil,
                                       headerFields: ["Retry-After": "Wed, 21 Oct 2026 07:28:00 GMT"])!
        #expect(ClaudeLimitsProvider.retryAfter(from: httpDate, now: now) != nil)

        let none = HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil, headerFields: [:])!
        #expect(ClaudeLimitsProvider.retryAfter(from: none, now: now) == nil)
    }
}
