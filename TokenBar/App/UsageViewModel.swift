import AppKit
import Foundation
import Network
import OSLog

/// Estado observable de la app: corre los collectors cada 30 s, acumula en el store
/// y expone lo que pintan el popover y el ícono de la barra.
@MainActor
@Observable
final class UsageViewModel {

    /// Cada cuánto corre el ciclo automático.
    private static let refreshInterval: Duration = .seconds(30)
    /// Retención del detalle por herramienta.
    private static let retentionDays = 90
    /// Retención del resumen diario (total por día, sin desglose por herramienta): más
    /// larga que el detalle porque es lo que sostiene la racha a largo plazo.
    private static let summaryRetentionDays = 365
    private static let showCostKey = "showCost"

    private(set) var snapshot: UsageSnapshot = .empty
    private(set) var statuses: [AppSource: CollectorStatus] = [:]
    private(set) var lastUpdate: Date?
    private(set) var lastErrorCount = 0
    private(set) var isRefreshing: Bool = false

    /// Límites en vivo de cada cuenta, indexados por fuente. Van por su propia cadencia
    /// (5 min), más lenta que el conteo de tokens (30 s), para no saturar los endpoints.
    private(set) var limits: [AppSource: LimitsSnapshot] = [:]

    /// La ventana más comprometida de todas las cuentas: la que decide el color del ícono.
    var worstLimit: LimitWindow? {
        let now = now()
        return limits.values.compactMap { $0.worst(at: now) }
            .max { $0.utilization < $1.utilization }
    }

    var todayTotalTokens: Int {
        Self.totalTokens(in: snapshot.todayByApp)
    }

    var todayCostUSD: Double {
        snapshot.todayByApp.values.reduce(0) { $0 + $1.costUSD }
    }

    nonisolated static func totalTokens(in records: [AppSource: UsageRecord]) -> Int {
        records.values.reduce(0) { $0 + $1.totalTokens }
    }

    /// Persistido en `UserDefaults` bajo "showCost".
    var showCost: Bool {
        didSet { UserDefaults.standard.set(showCost, forKey: Self.showCostKey) }
    }

    private let store: UsageStore
    /// Reparto por modelo para Estadísticas. `nil` en los tests que no lo ejercitan.
    private let modelStore: ModelUsageStore?
    private let state: CollectorStateStore
    private let collectors: [any UsageCollector]
    private let limitsProviders: [any LimitsProvider]
    private let operationDeadline: Duration
    /// Reloj inyectable para que los tests puedan avanzar el tiempo sin esperar.
    private let now: @Sendable () -> Date
    private let notifier = ThresholdNotifier()
    private let log = Logger(subsystem: "io.github.jhosgun.tokenbar", category: "viewmodel")

    /// Cadencia y backoff de la consulta de límites, por proveedor.
    private var limitGates: [AppSource: LimitsGate] = [:]
    /// Último snapshot `.ok` por fuente, para conservar sus ventanas ante fallos transitorios.
    private var lastGoodLimits: [AppSource: LimitsSnapshot] = [:]
    /// Cuándo se obtuvo el último snapshot `.ok` de cada fuente (para el "hace X").
    private(set) var lastGoodAt: [AppSource: Date] = [:]
    private var definitiveFailures: [AppSource: Int] = [:]
    private var loggedLimitStates: [AppSource: LimitLogState] = [:]

    /// Ciclo de refresco. Su existencia es la marca de "ya arrancó".
    private var cycle: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    private var pathMonitor: NWPathMonitor?
    private let pathQueue = DispatchQueue(label: "io.github.jhosgun.tokenbar.network-path")
    private var previousPathWasSatisfied: Bool?
    private var recoveryTask: Task<Void, Never>?

    init(store: UsageStore,
         modelStore: ModelUsageStore? = nil,
         state: CollectorStateStore,
         collectors: [any UsageCollector],
         limitsProviders: [any LimitsProvider] = [],
         operationDeadline: Duration = .seconds(30),
         now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.modelStore = modelStore
        self.state = state
        self.collectors = collectors
        self.limitsProviders = limitsProviders
        self.operationDeadline = operationDeadline
        self.now = now
        // `didSet` no dispara en init, así que esto no reescribe el default.
        self.showCost = UserDefaults.standard.bool(forKey: Self.showCostKey)
        // Las 3 filas existen desde el primer frame, aunque nadie haya corrido todavía.
        self.statuses = Dictionary(uniqueKeysWithValues: AppSource.allCases.map { ($0, .ok) })
    }

    /// Carga los stores, hace una corrida inmediata y arranca el ciclo de 30 s.
    /// Idempotente: llamarlo dos veces no arranca dos ciclos.
    func start() {
        guard cycle == nil else { return }

        observeRecoveryEvents()

        // El permiso se pide solo si la notificación de umbral ya está activada: en el
        // primer arranque, con la función apagada, no se le muestra el diálogo a nadie.
        // Si la activa después, Preferencias dispara la autorización por su cuenta.
        // Va en su propia tarea: si el usuario deja el diálogo abierto, el ciclo de datos
        // sigue corriendo.
        if ThresholdNotifier.isEnabled {
            Task { [notifier] in await notifier.requestAuthorization() }
        }

        cycle = Task { [weak self] in
            guard let self else { return }
            await self.store.load()
            await self.modelStore?.load()
            await self.state.load()
            // Una sola poda por arranque; la app es de larga vida pero 90 días de margen
            // hacen que un solo pase al día sea de sobra.
            await self.store.purge(olderThanDays: Self.retentionDays, summaryDays: Self.summaryRetentionDays)
            await self.modelStore?.purge()

            while !Task.isCancelled {
                await self.refresh()
                do {
                    try await Task.sleep(for: Self.refreshInterval)
                } catch {
                    break   // cancelado
                }
            }
        }
    }

    private func observeRecoveryEvents() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleRecovery() }
        }

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let isSatisfied = path.status == .satisfied
                defer { self.previousPathWasSatisfied = isSatisfied }
                if self.previousPathWasSatisfied == false, isSatisfied {
                    self.scheduleRecovery()
                }
            }
        }
        pathMonitor = monitor
        monitor.start(queue: pathQueue)
    }

    private func scheduleRecovery() {
        recoveryTask?.cancel()
        recoveryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                return
            }
            guard let self else { return }
            let now = self.now()
            for source in self.limitGates.keys {
                self.limitGates[source]?.resetCadenceUnlessBackingOff(now: now)
            }
            await self.refresh(forceLimits: true)
        }
    }

    /// Corre los collectors en paralelo y aplica lo que traigan. Los límites van por su
    /// propia cadencia: en un ciclo normal solo se consultan los proveedores que tocan.
    /// `forceLimits` es el refresh manual del botón: consulta los límites sin esperar la
    /// cadencia de 5 min, pero respetando el backoff de un proveedor que devolvió 429.
    func refresh(forceLimits: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        // Conteo y límites (solo los que tocan) van en paralelo: son fuentes independientes
        // y ninguna debe retrasar a la otra.
        let dueProviders = limitsProvidersToFetch(force: forceLimits)
        async let limitsTask = Self.fetchLimits(from: dueProviders, deadline: operationDeadline)
        let results = await Self.collect(from: collectors, deadline: operationDeadline)

        var newRecords: [UsageRecord] = []
        var newModelRecords: [ModelUsageRecord] = []
        var successfulSources: Set<AppSource> = []
        for (source, result) in results {
            statuses[source] = result.status
            newRecords.append(contentsOf: result.records)
            newModelRecords.append(contentsOf: result.modelRecords)
            if result.status == .ok {
                successfulSources.insert(source)
            }
        }

        let delta = await store.apply(newRecords)
        // En el mismo paso que `records`, para que el total por herramienta y su reparto por
        // modelo no se separen si la app se cierra entre un ciclo y el siguiente.
        await modelStore?.apply(newModelRecords)
        // El orden importa: primero los tokens (`apply` escribe `usage.json` de forma
        // atómica), y solo después la marca de "ya consumido" (`state.json`: cursores e ids
        // vistos). Al revés, un crash entre ambas escrituras dejaría el estado diciendo que
        // esas líneas ya se contaron mientras los tokens nunca llegaron a disco — y el cursor
        // no retrocede, así que se perderían para siempre.
        // `save()` sale temprano si nada cambió, así que en régimen estacionario no cuesta nada.
        await state.save()
        snapshot = await store.snapshot()

        let now = self.now()
        for snapshot in await limitsTask {
            applyLimits(snapshot, now: now)
            if snapshot.status == .ok {
                successfulSources.insert(snapshot.source)
            }
        }
        // Los errores se cuentan de los estados persistidos, no de este ciclo: un proveedor
        // de límites caído no se reconsulta en 5 min y su fallo debe seguir contando.
        var failedSources = Set(statuses.filter { $0.value != .ok }.keys)
        failedSources.formUnion(limits.filter { $0.value.status != .ok }.keys)
        lastErrorCount = failedSources.count
        if !successfulSources.isEmpty {
            lastUpdate = now
        }

        if delta > 0 {
            log.debug("refresh: +\(delta) tokens")
        }

        // De último: todo lo que pinta la UI ya se publicó. `evaluate` no bloquea porque la
        // autorización se pidió en `start()`; si no está habilitada, sale de inmediato.
        await notifier.evaluate(todayTotal: todayTotalTokens, day: DayKey.today())
    }

    /// Series de los últimos `days` días (terminando hoy) para la ventana de Estadísticas.
    func statsData(days: Int, grouping: StatsGrouping) async -> StatsData {
        let range = DayKey.lastDays(days, endingAt: now())
        guard let firstDay = range.first else { return StatsData(days: [], series: []) }
        let usage = await store.records(fromDay: firstDay)
        let models = await modelStore?.records(fromDay: firstDay) ?? []
        return StatsBuilder.build(days: range, usage: usage, models: models, grouping: grouping)
    }

    /// Proveedores de límites a los que toca consultar en este ciclo, según cadencia y backoff.
    private func limitsProvidersToFetch(force: Bool) -> [any LimitsProvider] {
        let now = now()
        return limitsProviders.filter { provider in
            let gate = limitGates[provider.source, default: LimitsGate()]
            return force ? gate.canForce(now: now) : gate.isDue(now: now)
        }
    }

    /// Aplica el resultado de un proveedor de límites manteniendo la cadencia y conservando
    /// el último valor bueno ante fallos transitorios.
    private func applyLimits(_ snapshot: LimitsSnapshot, now: Date) {
        let source = snapshot.source
        var gate = limitGates[source, default: LimitsGate()]

        switch snapshot.status {
        case .ok:
            definitiveFailures[source] = 0
            limits[source] = snapshot
            lastGoodLimits[source] = snapshot
            // `dataAsOf` es la fecha real del dato (una caché, un CLI que ya corrió);
            // `now` solo es correcto cuando el proveedor no la informa, es decir, cuando
            // el dato es genuinamente recién obtenido.
            lastGoodAt[source] = snapshot.dataAsOf ?? now
            gate.recordAttempt(now: now)

        case .notConfigured, .invalidCredentials:
            let failures = definitiveFailures[source, default: 0] + 1
            definitiveFailures[source] = failures
            if failures == 1, var good = lastGoodLimits[source], lastGoodAt[source] != nil {
                good.status = snapshot.status
                limits[source] = good
            } else {
                limits[source] = .empty(source, snapshot.status)
                lastGoodLimits[source] = nil
                lastGoodAt[source] = nil
            }
            gate.recordAttempt(now: now)

        case .failed:
            definitiveFailures[source] = 0
            applyTransientFailure(snapshot, now: now, gate: &gate)
        }

        limitGates[source] = gate
        logLimitTransition(snapshot, gate: gate, now: now)
    }

    /// Un fallo transitorio (429, red, 5xx, respuesta no reconocida) no tira lo que ya se
    /// tenía: conserva las ventanas del último `.ok` y las marca desactualizadas. El backoff
    /// solo se aplica si el proveedor respondió 429.
    ///
    /// Excepción: si el snapshot fallido trae ventanas propias (dato en caché desactualizado
    /// que el proveedor prefiere mostrar antes que ocultar), se muestran tal cual con su
    /// marca y pasan a ser el último bueno.
    private func applyTransientFailure(_ snapshot: LimitsSnapshot, now: Date, gate: inout LimitsGate) {
        let source = snapshot.source
        if !snapshot.windows.isEmpty {
            limits[source] = snapshot
            var good = snapshot
            good.status = .ok
            lastGoodLimits[source] = good
            // Si el snapshot trae su propia fecha (una caché o un CLI de hace rato), esa
            // es la antigüedad real: sobrescribir con `now` haría decir "ahora" de un dato
            // que puede tener minutos.
            lastGoodAt[source] = snapshot.dataAsOf ?? now
        } else if var good = lastGoodLimits[source], lastGoodAt[source] != nil {
            good.status = snapshot.status
            limits[source] = good
        } else {
            limits[source] = .empty(source, snapshot.status)
        }

        if snapshot.rateLimited {
            gate.recordRateLimit(now: now, retryAfter: snapshot.rateLimitedUntil)
        } else {
            gate.recordAttempt(now: now)
        }
    }

    private func logLimitTransition(_ snapshot: LimitsSnapshot, gate: LimitsGate, now: Date) {
        let state = LimitLogState(status: snapshot.status, rateLimited: snapshot.rateLimited)
        let line = LimitLogState.transitionLine(
            source: snapshot.source,
            previous: loggedLimitStates[snapshot.source],
            current: state,
            message: snapshot.status.uiMessage,
            nextAttempt: gate.nextAttempt(after: now)
        )
        loggedLimitStates[snapshot.source] = state
        guard let line else { return }
        log.notice("\(line, privacy: .public)")
    }

    /// Los collectors son `Sendable` y corren fuera del MainActor.
    private static func collect(
        from collectors: [any UsageCollector],
        deadline: Duration
    ) async -> [(AppSource, CollectorResult)] {
        await withTaskGroup(of: (AppSource, CollectorResult).self) { group in
            for collector in collectors {
                group.addTask {
                    let result = await NetworkDeadline.run(budget: deadline) {
                        await collector.collect()
                    } ?? .empty(.failed("Tiempo de espera agotado"))
                    return (collector.source, result)
                }
            }
            var results: [(AppSource, CollectorResult)] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
    }

    /// Los proveedores de límites también son `Sendable` y corren fuera del MainActor.
    private static func fetchLimits(
        from providers: [any LimitsProvider],
        deadline: Duration
    ) async -> [LimitsSnapshot] {
        await withTaskGroup(of: LimitsSnapshot.self) { group in
            for provider in providers {
                group.addTask {
                    await NetworkDeadline.run(budget: deadline) {
                        await provider.fetch()
                    } ?? .empty(provider.source, .failed("Tiempo de espera agotado"))
                }
            }
            var results: [LimitsSnapshot] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
    }
}

/// Estado de una fuente de límites tal como se loguea (E3). `Equatable` decide qué
/// cuenta como transición: el status (con su mensaje, si trae) y si fue 429. No es
/// `private` a propósito: los tests fijan la línea de rastro.
struct LimitLogState: Equatable {
    var status: CollectorStatus
    var rateLimited: Bool

    var label: String {
        switch status {
        case .ok: "ok"
        case .notConfigured: "no configurado"
        case .invalidCredentials: "credenciales inválidas"
        case .failed: "fallo"
        }
    }

    /// Línea de `log.notice` para un cambio de estado de una fuente de límites (E3):
    /// fuente, estado, mensaje, si fue 429 y próximo intento. `nil` si el estado no
    /// cambió — solo transiciones, no cada ciclo. Función pura para testear la decisión
    /// y el contenido sin capturar OSLog.
    static func transitionLine(
        source: AppSource,
        previous: LimitLogState?,
        current: LimitLogState,
        message: String?,
        nextAttempt: Date?
    ) -> String? {
        guard previous != current else { return nil }
        let attempt = nextAttempt.map { $0.formatted(.iso8601) } ?? "ahora"
        return "cuota fuente=\(source.displayName) estado=\(current.label) "
            + "mensaje=\(message ?? "—") 429=\(current.rateLimited ? "sí" : "no") próximo=\(attempt)"
    }
}

/// Controla cuándo toca consultar los límites de un proveedor y su backoff ante 429.
///
/// La cadencia normal es de 5 minutos por proveedor; el conteo de tokens (30 s) no la
/// acelera. Ante un 429 se respeta `Retry-After` si viene, y si no, se sube una escalera
/// exponencial (5 → 10 → 20 → 30 min, tope 30). Un intento sin 429 resetea la escalera.
struct LimitsGate: Sendable {
    /// Cadencia normal entre consultas.
    static let interval: TimeInterval = 5 * 60
    /// Escalera de backoff exponencial ante 429, en segundos.
    static let backoffSteps: [TimeInterval] = [5 * 60, 10 * 60, 20 * 60, 30 * 60]

    /// Último intento (exitoso o fallido) registrado.
    var lastAttempt: Date?
    /// Nivel de backoff actual: 0 = sin backoff; n = posición 1…N en `backoffSteps`.
    private(set) var backoffLevel = 0
    /// Fecha exacta de reintento dictada por `Retry-After`. Tiene prioridad sobre la escalera.
    private(set) var hardBackoffUntil: Date?

    /// Paso actual de la escalera (0 si no hay backoff).
    private var step: TimeInterval {
        guard backoffLevel > 0 else { return 0 }
        return Self.backoffSteps[min(backoffLevel - 1, Self.backoffSteps.count - 1)]
    }

    private func isBackingOff(now: Date) -> Bool {
        if let hardBackoffUntil, now < hardBackoffUntil { return true }
        guard step > 0, let lastAttempt else { return false }
        return now.timeIntervalSince(lastAttempt) < step
    }

    /// ¿Toca consultar en el ciclo automático? Respeta cadencia y backoff.
    func isDue(now: Date) -> Bool {
        guard !isBackingOff(now: now) else { return false }
        guard let lastAttempt else { return true }
        return now.timeIntervalSince(lastAttempt) >= Self.interval
    }

    /// ¿Puede consultar un refresh manual? Ignora la cadencia, respeta el backoff.
    func canForce(now: Date) -> Bool {
        !isBackingOff(now: now)
    }

    func nextAttempt(after now: Date) -> Date? {
        if let hardBackoffUntil, hardBackoffUntil > now { return hardBackoffUntil }
        guard let lastAttempt else { return nil }
        let delay = max(step, Self.interval)
        let next = lastAttempt.addingTimeInterval(delay)
        return next > now ? next : nil
    }

    mutating func resetCadenceUnlessBackingOff(now: Date) {
        guard !isBackingOff(now: now) else { return }
        lastAttempt = nil
    }

    /// Registra un intento sin 429: resetea el backoff.
    mutating func recordAttempt(now: Date) {
        backoffLevel = 0
        hardBackoffUntil = nil
        lastAttempt = now
    }

    /// Registra un 429. Con `Retry-After` se respeta tal cual; sin él, sube la escalera.
    mutating func recordRateLimit(now: Date, retryAfter: Date?) {
        lastAttempt = now
        if let retryAfter, retryAfter > now {
            hardBackoffUntil = retryAfter
        } else {
            hardBackoffUntil = nil
            backoffLevel = min(backoffLevel + 1, Self.backoffSteps.count)
        }
    }
}
