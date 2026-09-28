import Foundation
import OSLog

/// Lee el consumo de Cursor desde la API no oficial de su dashboard web.
///
/// Cursor **no** guarda conteos de tokens utilizables en disco (ver `docs/cursor-notes.md`),
/// así que la fuente es `get-filtered-usage-events`, verificado contra la cuenta real el
/// 2026-09-27. La credencial se descubre sola desde el SQLite local de Cursor vía
/// `CursorSession` — la misma que usa `CursorLimitsProvider`; ya no se pide nada a mano.
///
/// El avance es incremental: la ventana consultada va desde la marca de agua guardada en
/// `CollectorStateStore` (epoch ms del último evento visto) hasta ahora. En el primer
/// arranque solo se pide el día de hoy, para no recontar historia. La deduplicación por
/// `conversationId` + `timestamp` hace que retraer el borde de la ventana sea inocuo.
///
/// Si un ciclo topa con el límite de páginas o de tiempo (`fetchPages` devuelve `.partial`),
/// la ventana no se completó: `CollectorStateStore.CursorContinuation` guarda por dónde
/// retomar (ver ese tipo). El ciclo siguiente consulta una ventana más angosta —no la misma
/// de siempre— hasta que por fin se completa, momento en el que la marca de agua salta de
/// una vez al máximo visto en TODA la ventana (no solo en el último tramo).
///
/// El desglose por modelo y por origen (app vs CLI, vía `isHeadless`) no cabe en
/// `UsageRecord`, así que se acumula aparte en `CursorBreakdownStore` para que la UI
/// lo muestre en el desplegable. El total oficial sigue saliendo de los `UsageRecord`.
struct CursorCollector: UsageCollector {
    let source: AppSource = .cursor

    private let store: CollectorStateStore
    private let breakdown: CursorBreakdownStore
    private let databaseURL: URL
    private let session: URLSession
    private let log = Logger(subsystem: "io.github.jhosgun.tokenbar", category: "cursor")

    init(store: CollectorStateStore,
         breakdown: CursorBreakdownStore = CursorBreakdownStore(),
         databaseURL: URL = CursorSession.defaultDatabaseURL,
         session: URLSession = .shared) {
        self.store = store
        self.breakdown = breakdown
        self.databaseURL = databaseURL
        self.session = session
    }

    func collect() async -> CollectorResult {
        guard let credential = CursorSession.credential(from: databaseURL) else {
            return .empty(.notConfigured)
        }
        if credential.isExpired { return .empty(.invalidCredentials) }

        let now = Date()
        let watermark = await store.cursorLastEventTimestamp()
        let continuation = await store.cursorContinuation()

        // Con una continuación en curso, se retoma EXACTAMENTE donde se quedó: el mismo
        // `startMs` congelado y `endMs` = el borde ya alcanzado (inclusive; el dedup absorbe
        // el evento repetido del borde). No se recalcula nada contra el reloj, así que
        // cruzar medianoche a mitad de camino no invierte la ventana.
        //
        // Sin continuación: la ventana de siempre. Primera corrida (sin marca): solo el día
        // de hoy. Después: desde el último evento visto, retraída por `lateEventOverlapMs`
        // para no perder eventos que Cursor publique tarde con un timestamp anterior al
        // máximo ya visto. La deduplicación por `conversationId`+timestamp absorbe el
        // solape.
        let startMs: Int64
        let endMs: Int64
        if let continuation {
            startMs = continuation.startMs
            endMs = continuation.frontierMs
        } else {
            startMs = watermark.map { max(0, $0 - Endpoint.lateEventOverlapMs) }
                ?? Self.startOfTodayMs(now)
            endMs = Int64(now.timeIntervalSince1970 * 1000)
        }

        // `ContinuousClock`, no `Date`: un ajuste del reloj de pared (NTP, cambio de zona)
        // no debe acortar ni alargar el presupuesto real transcurrido (mismo patrón que
        // `ClaudeCodeCollector`).
        let clock = ContinuousClock()
        let deadline = clock.now + Endpoint.cycleBudget
        switch await fetchPages(cookie: credential.cookie, startMs: startMs, endMs: endMs,
                                deadline: deadline) {
        case .unauthorized:
            return .empty(.invalidCredentials)
        case .failed(let message):
            return .empty(.failed(message))
        case .success(let events, let maxTimestampMs):
            await breakdown.load()
            let records = await applyEvents(events)
            await breakdown.save()
            // Ventana COMPLETA: si venía de una continuación, el techo real es el máximo
            // visto en TODA la ventana (`continuation.ceilingMs`), no solo el de este último
            // tramo — que por estar pegado al final suele ser el más viejo de todos.
            if let ceiling = Self.maxOptional(continuation?.ceilingMs, maxTimestampMs) {
                await store.advanceCursorLastEventTimestamp(to: ceiling)
            }
            await store.clearCursorContinuation()
            // El estado NO se persiste aquí: `UsageViewModel.refresh()` llama a
            // `state.save()` después de `store.apply()`, para que los tokens lleguen a
            // disco antes que la marca de "ya consumido".
            return CollectorResult(records: records, status: .ok)
        case .partial(let events, let minTimestampMs, let maxTimestampMs, let message):
            // La ventana no se trajo completa (tope de páginas o presupuesto de tiempo),
            // pero las páginas que SÍ se leyeron son datos completos y válidos: se cuentan
            // igual. La marca de agua NO avanza todavía — seguiría sin cubrir lo que falta
            // entre `startMs` y `minTimestampMs`. En su lugar se guarda por dónde retomar:
            // el próximo ciclo consulta una ventana más angosta (hasta `minTimestampMs`, no
            // la misma de siempre), así que cada reintento avanza hacia atrás en vez de
            // repetir el mismo tramo para siempre. Tirar este trabajo (como antes) haría que
            // una API sostenidamente lenta nunca registrara nada.
            await breakdown.load()
            let records = await applyEvents(events)
            await breakdown.save()
            if let minTimestampMs {
                let ceiling = Self.maxOptional(continuation?.ceilingMs, maxTimestampMs)
                // Salvaguarda: la API solo da resolución de milisegundo. Si una página entera
                // (o el ciclo entero) comparte el mismo timestamp que `endMs`, `minTimestampMs`
                // no baja nada — sin este tope, el próximo ciclo pediría la MISMA ventana otra
                // vez y el collector se trabaría en silencio para siempre, que es peor que
                // perder ese puñado de eventos empatados. Se fuerza a bajar al menos 1 ms,
                // sin cruzar `startMs` (cruzarlo invertiría la ventana). En el caso normal
                // (`minTimestampMs < endMs`) el `min` elige `minTimestampMs` tal cual y esto
                // no cambia nada.
                let frontier = max(startMs, min(minTimestampMs, endMs - 1))
                if frontier != minTimestampMs {
                    log.warning("empate de timestamp en el borde de la ventana; se recorta el techo y puede saltarse algún evento de ese milisegundo")
                }
                await store.setCursorContinuation(CursorContinuation(startMs: startMs,
                                                                      frontierMs: frontier,
                                                                      ceilingMs: ceiling))
            }
            return CollectorResult(records: records, status: .failed(message))
        }
    }

    /// El máximo de dos timestamps opcionales, `nil` solo si los dos lo son.
    private static func maxOptional(_ a: Int64?, _ b: Int64?) -> Int64? {
        switch (a, b) {
        case (nil, nil): return nil
        case (let x?, nil): return x
        case (nil, let y?): return y
        case (let x?, let y?): return max(x, y)
        }
    }

    /// Aplica eventos ya traídos: deduplica, agrega por día y alimenta el desglose por
    /// modelo/origen. Compartido entre la ventana completa y la parcial.
    private func applyEvents(_ events: [Event]) async -> [UsageRecord] {
        var byDay: [String: UsageRecord] = [:]
        for event in events {
            guard await store.markSeen(messageID: event.dedupeID) == false else { continue }
            let record = event.record(source: source)
            byDay[event.day] = byDay[event.day].map { $0 + record } ?? record
            await breakdown.record(day: event.day, model: event.model,
                                   isHeadless: event.isHeadless, tokens: record.totalTokens)
        }
        return byDay.values.sorted { $0.day < $1.day }
    }

    // MARK: - Red

    /// Resultado de traer todas las páginas de la ventana.
    private enum FetchResult: Sendable {
        /// Ventana COMPLETA: la marca de agua puede avanzar hasta `maxTimestampMs`.
        case success(events: [Event], maxTimestampMs: Int64?)
        /// Se topó el tope de páginas o el presupuesto de tiempo antes de terminar. Los
        /// eventos ya leídos son válidos y se cuentan. `minTimestampMs` es el timestamp más
        /// viejo leído en este ciclo — por ahí retoma el próximo (ver `CursorContinuation`).
        /// `maxTimestampMs` es el máximo de ESTE tramo únicamente; `collect()` lo combina con
        /// el techo acumulado de tramos anteriores, si los hay.
        case partial(events: [Event], minTimestampMs: Int64?, maxTimestampMs: Int64?, message: String)
        case unauthorized
        case failed(String)
    }

    /// Trae todas las páginas de `[startMs, endMs]`. Si se topa con el límite de páginas o
    /// se acaba el presupuesto de tiempo antes de terminar, devuelve `.partial` con lo ya
    /// leído: descartarlo (como antes) haría que una API sostenidamente lenta nunca llegara
    /// a registrar nada, porque cada ciclo repetiría la misma ventana desde cero y volvería
    /// a toparse con el mismo límite. Con el volumen real de esta cuenta (~22 eventos/día)
    /// hace falta más de mil veces ese tráfico para tocar el tope; es un caso lejano, pero
    /// que si ocurre debe sumar progreso, no perderlo (ver `docs/cursor-notes.md`).
    private func fetchPages(cookie: String, startMs: Int64, endMs: Int64,
                            deadline: ContinuousClock.Instant) async -> FetchResult {
        var events: [Event] = []
        var maxTimestampMs: Int64?
        var minTimestampMs: Int64?
        var expectedTotal: Int?
        var displayed = 0
        var page = 1
        let clock = ContinuousClock()

        while true {
            guard let request = Self.makeRequest(cookie: cookie, startMs: startMs,
                                                 endMs: endMs, page: page) else {
                return .failed("URL inválida")
            }

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                log.error("request falló: \(error.localizedDescription, privacy: .public)")
                return .failed(Self.networkMessage(for: error))
            }

            if let http = response as? HTTPURLResponse {
                switch http.statusCode {
                case 200..<300:
                    break
                case 401, 403:
                    return .unauthorized
                default:
                    return .failed("HTTP \(http.statusCode)")
                }
            }

            guard let parsed = Self.parse(data) else {
                log.error("respuesta no reconocida (\(data.count) bytes)")
                return .failed("formato de respuesta desconocido")
            }

            if page == 1 { expectedTotal = parsed.totalCount }
            displayed += parsed.displayedCount
            events.append(contentsOf: parsed.events)
            if let pageMax = parsed.maxTimestampMs {
                maxTimestampMs = max(maxTimestampMs ?? 0, pageMax)
            }
            if let pageMin = parsed.minTimestampMs {
                minTimestampMs = min(minTimestampMs ?? pageMin, pageMin)
            }

            let reachedTotal = expectedTotal.map { displayed >= $0 } ?? false
            let shortPage = parsed.displayedCount < Endpoint.pageSize
            if parsed.displayedCount == 0 || reachedTotal || shortPage {
                return .success(events: events, maxTimestampMs: maxTimestampMs)
            }
            if page >= Endpoint.maxPages {
                log.warning("más de \(Endpoint.maxPages) páginas en la ventana; se cuenta lo leído y se retoma desde ahí")
                return .partial(events: events, minTimestampMs: minTimestampMs, maxTimestampMs: maxTimestampMs,
                                message: "más de \(Endpoint.maxPages * Endpoint.pageSize) eventos en la ventana")
            }
            if clock.now >= deadline {
                log.warning("presupuesto de ciclo agotado paginando; se cuenta lo leído y se retoma desde ahí")
                return .partial(events: events, minTimestampMs: minTimestampMs, maxTimestampMs: maxTimestampMs,
                                message: "tiempo agotado paginando la ventana")
            }
            page += 1
        }
    }

    /// Epoch ms del inicio del día local de `date`: la ventana del primer arranque.
    static func startOfTodayMs(_ date: Date) -> Int64 {
        Int64(Calendar.current.startOfDay(for: date).timeIntervalSince1970 * 1000)
    }
}

// MARK: - Endpoint

extension CursorCollector {
    /// Único lugar a tocar si Cursor cambia el endpoint. La API es no oficial y ha
    /// cambiado varias veces (ver `docs/cursor-notes.md`); esquema verificado 2026-09-27.
    enum Endpoint {
        static let urlString = "https://cursor.com/api/dashboard/get-filtered-usage-events"
        static let origin = "https://cursor.com"
        static let referer = "https://cursor.com/dashboard"
        static let timeout: TimeInterval = 5
        /// 200 por página: verificado contra la cuenta real (651 eventos en 30 días).
        static let pageSize = 200
        /// Salvavidas contra una API que nunca deje de devolver páginas llenas
        /// (`maxPages * pageSize` = 10 000 eventos en la ventana). Si se topa, el ciclo
        /// falla suave y el siguiente retoma una ventana más angosta (no la misma), hasta
        /// completarla — ver `CursorContinuation` y `fetchPages`.
        static let maxPages = 50
        /// Solapamiento hacia atrás al retomar desde la marca de agua: cubre eventos que
        /// Cursor publique tarde (con timestamp anterior al máximo ya visto). El dedup por
        /// `conversationId`+timestamp hace que pedir de más sea inocuo; lo que sí sería
        /// irrecuperable es no pedirlos nunca.
        static let lateEventOverlapMs: Int64 = 2 * 86_400 * 1000
        /// Presupuesto de pared para TODA la paginación de un ciclo, no por página: sin
        /// esto, 50 páginas × 5 s de timeout serían 250 s y bloquearían el refresh entero.
        /// Se revisa entre páginas, así que al menos la primera petición siempre sale.
        static let cycleBudget: Duration = .seconds(8)

        /// Los endpoints `/api/dashboard/*` responden 403 sin cabeceras de navegador.
        static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
            + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
    }

    /// Las fechas van como epoch en milisegundos **en string**; así lo verificamos.
    static func makeRequest(cookie: String, startMs: Int64, endMs: Int64, page: Int) -> URLRequest? {
        guard let url = URL(string: Endpoint.urlString) else { return nil }

        let body: [String: Any] = [
            "teamId": 0,
            "startDate": String(startMs),
            "endDate": String(endMs),
            "page": page,
            "pageSize": Endpoint.pageSize
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = payload
        request.timeoutInterval = Endpoint.timeout
        // La cookie va explícita en la cabecera; no queremos que URLSession la mezcle
        // con su almacén compartido.
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(Endpoint.origin, forHTTPHeaderField: "Origin")
        request.setValue(Endpoint.referer, forHTTPHeaderField: "Referer")
        request.setValue(Endpoint.userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    static func networkMessage(for error: Error) -> String {
        guard let urlError = error as? URLError else { return "error de red" }
        switch urlError.code {
        case .timedOut: return "tiempo agotado"
        case .notConnectedToInternet, .networkConnectionLost: return "sin conexión"
        case .cancelled: return "cancelado"
        default: return "error de red"
        }
    }

    /// Nombre para mostrar de un modelo: el prefijo `cursor-` es de la casa y estorba
    /// (`cursor-grok-4.6-high` se lee mejor como `grok-4.6-high`). El id crudo se
    /// conserva en el desglose; esto es solo para pintarlo.
    static func displayName(forModel model: String) -> String {
        model.hasPrefix("cursor-") ? String(model.dropFirst("cursor-".count)) : model
    }
}

// MARK: - Parsing

extension CursorCollector {
    /// Un evento de uso ya normalizado. Prefijado por módulo: no toca el contrato.
    struct Event: Sendable {
        var day: String
        var dedupeID: String
        var model: String
        /// True si vino del CLI (`cursor-agent`); false si vino de la app.
        var isHeadless: Bool
        var inputTokens: Int
        var outputTokens: Int
        var cacheReadTokens: Int
        /// Costo reportado por Cursor. `nil` -> se estima con `Pricing`.
        var costUSD: Double?

        /// Cursor no informa caché de escritura en este endpoint: ese campo queda en 0.
        func record(source: AppSource) -> UsageRecord {
            let cost = costUSD ?? Pricing.cost(model: model,
                                               inputTokens: inputTokens,
                                               outputTokens: outputTokens,
                                               cacheCreationTokens: 0,
                                               cacheReadTokens: cacheReadTokens)
            return UsageRecord(source: source,
                               day: day,
                               inputTokens: inputTokens,
                               outputTokens: outputTokens,
                               cacheCreationTokens: 0,
                               cacheReadTokens: cacheReadTokens,
                               costUSD: cost)
        }
    }

    /// Una respuesta decodificada: los eventos con tokens, cuántos venían en la página
    /// (para saber si hay más), el total declarado y los timestamps extremos de la página.
    struct Page: Sendable {
        var events: [Event]
        var displayedCount: Int
        var totalCount: Int?
        var maxTimestampMs: Int64?
        var minTimestampMs: Int64?
    }

    /// Decodifica la respuesta del endpoint. Punto de ajuste si cambia el esquema.
    ///
    /// - Returns: la página, o `nil` si el formato no se reconoce — incluido un evento con
    ///   `tokenUsage` presente pero con alguno de sus tres campos irreconocible, señal de
    ///   que Cursor renombró el esquema: no hay forma segura de tratar ese campo como cero
    ///   sin arriesgarse a perder consumo real, así que la página entera se trata como
    ///   desconocida en vez de descartar el evento en silencio (eso movería la marca de
    ///   agua sobre consumo nunca contado). Una respuesta `{}` (cuenta sin actividad) es
    ///   válida y trae cero eventos.
    static func parse(_ data: Data) -> Page? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if root.isEmpty {
            return Page(events: [], displayedCount: 0, totalCount: 0, maxTimestampMs: nil, minTimestampMs: nil)
        }
        guard let raw = root["usageEventsDisplay"] as? [[String: Any]] else { return nil }

        var events: [Event] = []
        var maxTimestampMs: Int64?
        var minTimestampMs: Int64?
        for json in raw {
            switch classify(json) {
            case .malformed:
                return nil
            case .skipped:
                // No es un evento de tokens (o trae los tres contadores explícitamente en
                // cero): no aporta, pero sí se reconoció el esquema. Seguro avanzar la
                // marca sobre él.
                if let millis = epochMillis(json["timestamp"]) {
                    maxTimestampMs = max(maxTimestampMs ?? 0, millis)
                    minTimestampMs = min(minTimestampMs ?? millis, millis)
                }
            case .tokenized(let event):
                if let millis = epochMillis(json["timestamp"]) {
                    maxTimestampMs = max(maxTimestampMs ?? 0, millis)
                    minTimestampMs = min(minTimestampMs ?? millis, millis)
                }
                events.append(event)
            }
        }
        return Page(events: events,
                    displayedCount: raw.count,
                    totalCount: int(root["totalUsageEventsCount"]),
                    maxTimestampMs: maxTimestampMs,
                    minTimestampMs: minTimestampMs)
    }

    /// Cómo se interpretó un evento crudo.
    private enum EventOutcome {
        /// Evento con tokens, ya normalizado.
        case tokenized(Event)
        /// Sin `tokenUsage`, sin timestamp, o con los tres contadores reconocidos en 0:
        /// no aporta, pero el esquema sí se entendió.
        case skipped
        /// `tokenUsage` viene, pero al menos uno de sus tres campos no se pudo leer: posible
        /// cambio de esquema (p. ej. `outputTokens` renombrado a `completionTokens`). No hay
        /// forma segura de tratarlo como cero sin arriesgarse a perder consumo real, así que
        /// se exige que LOS TRES sean reconocibles antes de dar el esquema por válido.
        case malformed
    }

    private static func classify(_ json: [String: Any]) -> EventOutcome {
        guard let usage = json["tokenUsage"] as? [String: Any] else { return .skipped }

        guard let inputValue = int(usage["inputTokens"]),
              let outputValue = int(usage["outputTokens"]),
              let cacheReadValue = int(usage["cacheReadTokens"]) else { return .malformed }
        guard inputValue != 0 || outputValue != 0 || cacheReadValue != 0 else { return .skipped }

        guard let millis = epochMillis(json["timestamp"]) else { return .skipped }

        let model = (json["model"] as? String) ?? ""
        let date = Date(timeIntervalSince1970: TimeInterval(millis) / 1000)

        // No hay id de evento: la llave durable es `conversationId` + timestamp.
        // Sin conversación se cae al modelo y los contadores, estables entre corridas.
        let conversation = (json["conversationId"] as? String)
            ?? "\(model):\(inputValue):\(outputValue):\(cacheReadValue)"
        let dedupeID = "cursor:\(conversation):\(millis)"

        var cost: Double?
        if let cents = double(usage["totalCents"]) {
            cost = cents / 100
        }

        return .tokenized(Event(day: DayKey.string(from: date),
                                dedupeID: dedupeID,
                                model: model,
                                isHeadless: (json["isHeadless"] as? Bool) ?? false,
                                inputTokens: inputValue,
                                outputTokens: outputValue,
                                cacheReadTokens: cacheReadValue,
                                costUSD: cost))
    }

    /// El timestamp llega como epoch en milisegundos, como string o como número.
    private static func epochMillis(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        if let text = value as? String { return Int64(text) }
        return nil
    }

    private static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }

    private static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }
}
