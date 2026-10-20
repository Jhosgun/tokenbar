import Foundation
import SwiftUI
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
    collectors: [any UsageCollector] = [],
    deadline: Duration = .seconds(30),
    clock: Clock
) -> (viewModel: UsageViewModel, directory: URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("tokenbar-vm-tests-\(UUID().uuidString)", isDirectory: true)
    let viewModel = UsageViewModel(
        store: UsageStore(directory: directory),
        state: CollectorStateStore(directory: directory),
        collectors: collectors,
        limitsProviders: providers,
        operationDeadline: deadline,
        now: { clock.now }
    )
    return (viewModel, directory)
}

private struct HangingCollector: UsageCollector {
    let source: AppSource

    func collect() async -> CollectorResult {
        await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
        return .empty(.ok)
    }
}

private struct OkCollector: UsageCollector {
    let source: AppSource

    func collect() async -> CollectorResult {
        .empty(.ok)
    }
}

private struct HangingLimitsProvider: LimitsProvider {
    let source: AppSource

    func fetch() async -> LimitsSnapshot {
        await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
        return .empty(source, .ok)
    }
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

    @Test("el primer invalidCredentials conserva la fila y el segundo la vacía")
    @MainActor
    func credencialesInvalidasRequierenConfirmacion() async {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let clock = Clock(t0)
        let provider = ScriptedLimitsProvider(source: .claudeCode, script: [
            okSnapshot(),
            .empty(.claudeCode, .invalidCredentials),
            .empty(.claudeCode, .invalidCredentials)
        ])
        let (vm, dir) = makeViewModel(providers: [provider], clock: clock)
        defer { try? FileManager.default.removeItem(at: dir) }

        await vm.refresh()
        #expect(vm.limits[.claudeCode]?.windows.count == 1)

        clock.now = t0.addingTimeInterval(301)
        await vm.refresh()
        #expect(vm.limits[.claudeCode]?.windows.count == 1)
        #expect(vm.limits[.claudeCode]?.status == .invalidCredentials)
        #expect(vm.lastGoodAt[.claudeCode] == t0)

        clock.now = t0.addingTimeInterval(602)
        await vm.refresh()
        #expect(vm.limits[.claudeCode]?.windows.isEmpty == true)
        #expect(vm.limits[.claudeCode]?.status == .invalidCredentials)
        #expect(vm.lastGoodAt[.claudeCode] == nil)
    }

    @Test("la edad aparece con estado ok cuando el dato tiene más de diez minutos")
    @MainActor
    func edadVisibleConEstadoOk() async {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let clock = Clock(t0)
        var old = okSnapshot()
        old.dataAsOf = t0.addingTimeInterval(-11 * 60)
        let provider = ScriptedLimitsProvider(source: .claudeCode, script: [old])
        let (vm, dir) = makeViewModel(providers: [provider], clock: clock)
        defer { try? FileManager.default.removeItem(at: dir) }

        await vm.refresh()
        let row = SourceRowView(
            source: .claudeCode,
            snapshot: vm.limits[.claudeCode],
            record: nil,
            series: [],
            tokensStatus: .ok,
            showCost: false,
            lastGoodAt: vm.lastGoodAt[.claudeCode],
            now: t0,
            isExpanded: .constant(false)
        )
        #expect(row.statusMessage == "hace 11m")
    }

    @Test("un collector y un proveedor colgados no bloquean el refresco")
    @MainActor
    func plazoExteriorDesbloqueaRefresh() async {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let clock = Clock(t0)
        let (vm, dir) = makeViewModel(
            providers: [HangingLimitsProvider(source: .claudeCode)],
            collectors: [HangingCollector(source: .cursor)],
            deadline: .milliseconds(20),
            clock: clock
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        await vm.refresh()

        #expect(!vm.isRefreshing)
        #expect(vm.statuses[.cursor] == .failed("Tiempo de espera agotado"))
        #expect(vm.limits[.claudeCode]?.status == .failed("Tiempo de espera agotado"))
        #expect(vm.lastUpdate == nil)
        #expect(vm.lastErrorCount == 2)
    }

    @Test("recuperar wake o red abre la cadencia pero respeta el backoff")
    func recuperacionRespetaBackoff() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var normal = LimitsGate()
        normal.recordAttempt(now: t0)
        normal.resetCadenceUnlessBackingOff(now: t0.addingTimeInterval(10))
        #expect(normal.canForce(now: t0.addingTimeInterval(10)))

        var limited = LimitsGate()
        limited.recordRateLimit(now: t0, retryAfter: t0.addingTimeInterval(120))
        limited.resetCadenceUnlessBackingOff(now: t0.addingTimeInterval(10))
        #expect(!limited.canForce(now: t0.addingTimeInterval(10)))
    }

    @Test("el próximo intento respeta Retry-After, la escalera y la cadencia")
    func proximoIntento() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)

        // Nunca consultado: toca ya.
        var virgen = LimitsGate()
        #expect(virgen.nextAttempt(after: t0) == nil)

        // Cadencia normal: 5 minutos desde el último intento.
        var cadencia = LimitsGate()
        cadencia.recordAttempt(now: t0)
        #expect(cadencia.nextAttempt(after: t0) == t0.addingTimeInterval(300))

        // Escalera de 429 sin Retry-After: primer peldaño, 5 minutos.
        var escalera = LimitsGate()
        escalera.recordRateLimit(now: t0, retryAfter: nil)
        #expect(escalera.nextAttempt(after: t0) == t0.addingTimeInterval(300))

        // Retry-After explícito manda sobre la escalera…
        var conRetryAfter = LimitsGate()
        conRetryAfter.recordRateLimit(now: t0, retryAfter: t0.addingTimeInterval(120))
        #expect(conRetryAfter.nextAttempt(after: t0) == t0.addingTimeInterval(120))
        // …hasta que vence: entonces toca ya.
        #expect(conRetryAfter.nextAttempt(after: t0.addingTimeInterval(999)) == nil)
    }

    @Test("el rastro de límites anota solo transiciones de estado")
    func rastroSoloEnTransiciones() {
        let ok = LimitLogState(status: .ok, rateLimited: false)
        let fallo = LimitLogState(status: .failed("Sin conexión"), rateLimited: false)
        let limitado = LimitLogState(status: .failed("Cuota de consultas"), rateLimited: true)

        // El primer estado visto deja línea.
        #expect(LimitLogState.transitionLine(
            source: .claudeCode, previous: nil, current: ok,
            message: nil, nextAttempt: nil) != nil)
        // Cada cambio también.
        #expect(LimitLogState.transitionLine(
            source: .claudeCode, previous: ok, current: fallo,
            message: "Sin conexión", nextAttempt: Date(timeIntervalSince1970: 1_000_120)) != nil)
        // El estado repetido, no: solo transiciones, no cada ciclo.
        #expect(LimitLogState.transitionLine(
            source: .claudeCode, previous: fallo, current: fallo,
            message: "Sin conexión", nextAttempt: nil) == nil)
        #expect(LimitLogState.transitionLine(
            source: .claudeCode, previous: ok, current: ok,
            message: nil, nextAttempt: nil) == nil)
        // Un 429 (aunque el texto del fallo sea el mismo) sí es transición.
        #expect(LimitLogState.transitionLine(
            source: .claudeCode, previous: fallo, current: limitado,
            message: "Cuota de consultas", nextAttempt: nil) != nil)
    }

    @Test("la línea de rastro trae fuente, estado, mensaje, 429 y próximo intento")
    func lineaDeRastro() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let limitado = LimitLogState(status: .failed("Cuota de consultas"), rateLimited: true)
        let linea = LimitLogState.transitionLine(
            source: .claudeCode,
            previous: LimitLogState(status: .ok, rateLimited: false),
            current: limitado,
            message: "Cuota de consultas",
            nextAttempt: t0.addingTimeInterval(120)
        )
        #expect(linea == "cuota fuente=Claude Code estado=fallo mensaje=Cuota de consultas "
                     + "429=sí próximo=\(t0.addingTimeInterval(120).formatted(.iso8601))")

        // Sin mensaje (.ok) y sin próximo intento: guion y "ahora", no huecos vacíos.
        let okLinea = LimitLogState.transitionLine(
            source: .codex,
            previous: nil,
            current: LimitLogState(status: .ok, rateLimited: false),
            message: nil,
            nextAttempt: nil
        )
        #expect(okLinea == "cuota fuente=Codex estado=ok mensaje=— 429=no próximo=ahora")
    }

    @Test("el total de hoy suma cualquier fuente presente en el snapshot")
    func totalDinamico() {
        let records: [AppSource: UsageRecord] = [
            .claudeCode: UsageRecord(source: .claudeCode, day: "2026-10-04", inputTokens: 10),
            .codex: UsageRecord(source: .codex, day: "2026-10-04", outputTokens: 25)
        ]
        #expect(UsageViewModel.totalTokens(in: records) == 35)
    }

    @Test("la línea de tokens no fabrica cero cuando el collector falla")
    @MainActor
    func visibilidadDeTokens() {
        let failed = SourceRowView(
            source: .claudeCode,
            snapshot: nil,
            record: UsageRecord(source: .claudeCode, day: "2026-10-04"),
            series: [],
            tokensStatus: .failed("Sin datos"),
            showCost: false,
            lastGoodAt: nil,
            now: Date(),
            isExpanded: .constant(false)
        )
        #expect(failed.tokensRecord == nil)

        let validZero = SourceRowView(
            source: .claudeCode,
            snapshot: nil,
            record: UsageRecord(source: .claudeCode, day: "2026-10-04"),
            series: [],
            tokensStatus: .ok,
            showCost: false,
            lastGoodAt: nil,
            now: Date(),
            isExpanded: .constant(false)
        )
        #expect(validZero.tokensRecord?.totalTokens == 0)
    }

    @Test("lastUpdate no avanza cuando todas las fuentes fallan")
    @MainActor
    func lastUpdateSoloAvanzaConExito() async {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let clock = Clock(t0)
        let provider = ScriptedLimitsProvider(source: .claudeCode, script: [
            okSnapshot(),
            .empty(.claudeCode, .failed("Sin conexión"))
        ])
        let (vm, dir) = makeViewModel(providers: [provider], clock: clock)
        defer { try? FileManager.default.removeItem(at: dir) }

        await vm.refresh()
        #expect(vm.lastUpdate == t0)

        clock.now = t0.addingTimeInterval(301)
        await vm.refresh()
        #expect(vm.lastUpdate == t0)
        #expect(vm.lastErrorCount == 1)
    }

    @Test("el conteo de errores sigue contando un proveedor caído que no se reconsulta en el ciclo")
    @MainActor
    func erroresPersistentesEntreCiclos() async {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let clock = Clock(t0)
        let provider = ScriptedLimitsProvider(source: .claudeCode, script: [
            .empty(.claudeCode, .failed("Sin conexión"))
        ])
        let (vm, dir) = makeViewModel(
            providers: [provider], collectors: [OkCollector(source: .codex)], clock: clock)
        defer { try? FileManager.default.removeItem(at: dir) }

        await vm.refresh()
        #expect(vm.lastErrorCount == 1)

        // 30 s después el proveedor no toca (cadencia de 5 min): solo responde el collector
        // sano, pero el fallo sigue vigente en `limits` y debe seguir en el pie.
        clock.now = t0.addingTimeInterval(30)
        await vm.refresh()
        #expect(vm.limits[.claudeCode]?.status == .failed("Sin conexión"))
        #expect(vm.lastErrorCount == 1)
        #expect(vm.lastUpdate == t0.addingTimeInterval(30))
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
