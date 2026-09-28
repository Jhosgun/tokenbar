import Foundation
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
    private(set) var isRefreshing: Bool = false

    /// Límites en vivo de cada cuenta, indexados por fuente. Van por su propia cadencia
    /// (5 min), más lenta que el conteo de tokens (30 s), para no saturar los endpoints.
    private(set) var limits: [AppSource: LimitsSnapshot] = [:]

    /// La ventana más comprometida de todas las cuentas: la que decide el color del ícono.
    var worstLimit: LimitWindow? {
        limits.values.compactMap(\.worst).max { $0.utilization < $1.utilization }
    }

    /// Persistido en `UserDefaults` bajo "showCost".
    var showCost: Bool {
        didSet { UserDefaults.standard.set(showCost, forKey: Self.showCostKey) }
    }

    private let store: UsageStore
    private let state: CollectorStateStore
    private let collectors: [any UsageCollector]
    private let limitsProviders: [any LimitsProvider]
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

    /// Ciclo de refresco. Su existencia es la marca de "ya arrancó".
    private var cycle: Task<Void, Never>?

    init(store: UsageStore,
         state: CollectorStateStore,
         collectors: [any UsageCollector],
         limitsProviders: [any LimitsProvider] = [],
         now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.state = state
        self.collectors = collectors
        self.limitsProviders = limitsProviders
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

        // El permiso se pide solo si la notificación de umbral ya está activada: en el
        // primer arranque, con la función apagada, no se le muestra el diálogo a nadie.
        // Si la activa después, Preferencias dispara la autorización por su cuenta.
        // Va en su propia tarea: si el usuario deja el diálogo abierto, el ciclo de datos
        // sigue corriendo.
        if ThresholdNotifier.isEnabled {
            Task { [notifier] in await notifier.requestAuthorizationIfNeeded() }
        }

        cycle = Task { [weak self] in
            guard let self else { return }
            await self.store.load()
            await self.state.load()
            // Una sola poda por arranque; la app es de larga vida pero 90 días de margen
            // hacen que un solo pase al día sea de sobra.
            await self.store.purge(olderThanDays: Self.retentionDays, summaryDays: Self.summaryRetentionDays)

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
        async let limitsTask = Self.fetchLimits(from: dueProviders)
        let results = await Self.collect(from: collectors)

        var newRecords: [UsageRecord] = []
        for (source, result) in results {
            statuses[source] = result.status
            newRecords.append(contentsOf: result.records)
        }

        let delta = await store.apply(newRecords)
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
        }
        lastUpdate = now

        if delta > 0 {
            log.debug("refresh: +\(delta) tokens")
        }

        // De último: todo lo que pinta la UI ya se publicó. `evaluate` no bloquea porque la
        // autorización se pidió en `start()`; si no está habilitada, sale de inmediato.
        await notifier.evaluate(todayTotal: snapshot.todayTotalTokens, day: DayKey.today())
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
            limits[source] = snapshot
            lastGoodLimits[source] = snapshot
            // `dataAsOf` es la fecha real del dato (una caché, un CLI que ya corrió);
            // `now` solo es correcto cuando el proveedor no la informa, es decir, cuando
            // el dato es genuinamente recién obtenido.
            lastGoodAt[source] = snapshot.dataAsOf ?? now
            gate.recordAttempt(now: now)

        case .notConfigured, .invalidCredentials:
            // Son estados definitivos (no hay token, o el token no sirve): la fila se vacía.
            limits[source] = .empty(source, snapshot.status)
            lastGoodLimits[source] = nil
            lastGoodAt[source] = nil
            gate.recordAttempt(now: now)

        case .failed:
            applyTransientFailure(snapshot, now: now, gate: &gate)
        }

        limitGates[source] = gate
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

    /// Los collectors son `Sendable` y corren fuera del MainActor.
    private static func collect(
        from collectors: [any UsageCollector]
    ) async -> [(AppSource, CollectorResult)] {
        await withTaskGroup(of: (AppSource, CollectorResult).self) { group in
            for collector in collectors {
                group.addTask { (collector.source, await collector.collect()) }
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
        from providers: [any LimitsProvider]
    ) async -> [LimitsSnapshot] {
        await withTaskGroup(of: LimitsSnapshot.self) { group in
            for provider in providers {
                group.addTask { await provider.fetch() }
            }
            var results: [LimitsSnapshot] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
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
