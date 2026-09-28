import Foundation
import OSLog

/// Lee el consumo de Cursor desde el dashboard web de cursor.com.
///
/// Cursor **no** guarda conteos de tokens utilizables en disco: los mensajes en
/// `state.vscdb` traen un campo `tokenCount` que viene en cero en el 99.8% de los casos
/// (ver `docs/cursor-notes.md`). La única fuente real es la API no oficial del dashboard,
/// autenticada con la cookie de sesión que el usuario pega una vez en Preferencias.
///
/// Se usa `get-filtered-usage-events` porque es el único endpoint que devuelve tokens
/// desglosados (input / output / cache write / cache read) **con timestamp por evento**.
/// Eso permite atribuir cada evento a su día local y deduplicar con `CollectorStateStore`,
/// evitando por completo la conversión acumulado → delta.
struct CursorCollector: UsageCollector {
    let source: AppSource = .cursor

    /// Llave del token de sesión en el llavero (ver CONTRACT.md §10).
    static let tokenKey = "cursor.sessionToken"

    private let store: CollectorStateStore
    private let session: URLSession
    private let log = Logger(subsystem: "io.github.jhosgun.tokenbar", category: "cursor")

    init(store: CollectorStateStore, session: URLSession = .shared) {
        self.store = store
        self.session = session
    }

    func collect() async -> CollectorResult {
        guard let token = Self.normalizedToken(Keychain.get(forKey: Self.tokenKey)) else {
            return .empty(.notConfigured)
        }

        // Primera corrida: 7 días para llenar el sparkline. Después solo 2 días
        // (hoy + ayer, por eventos que llegan tarde); la deduplicación evita repetidos.
        let bootstrapped = await store.hasBootstrapped(source)
        let windowDays = bootstrapped ? 2 : 7

        guard let request = Self.makeRequest(token: token, windowDays: windowDays) else {
            return .empty(.failed("URL inválida"))
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            log.error("request falló: \(error.localizedDescription, privacy: .public)")
            return .empty(.failed(Self.networkMessage(for: error)))
        }

        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200..<300:
                break
            case 401, 403:
                return .empty(.invalidCredentials)
            default:
                return .empty(.failed("HTTP \(http.statusCode)"))
            }
        }

        guard let events = Self.parse(data) else {
            log.error("respuesta no reconocida (\(data.count) bytes)")
            return .empty(.failed("formato de respuesta desconocido"))
        }

        var byDay: [String: UsageRecord] = [:]
        for event in events {
            guard await store.markSeen(messageID: event.dedupeID) == false else { continue }
            let record = event.record(source: source)
            byDay[event.day] = byDay[event.day].map { $0 + record } ?? record
        }

        if !bootstrapped {
            await store.setBootstrapped(source)
        }
        // El estado NO se persiste aquí: `UsageViewModel.refresh()` llama a `state.save()`
        // después de `store.apply()`, para que los tokens lleguen a disco antes que la marca
        // de "ya consumido".

        return CollectorResult(records: Array(byDay.values), status: .ok)
    }
}

// MARK: - Endpoint

extension CursorCollector {
    /// Único lugar a tocar si Cursor cambia el endpoint. La API es no oficial y ha
    /// cambiado varias veces (ver `docs/cursor-notes.md`).
    enum Endpoint {
        static let urlString = "https://cursor.com/api/dashboard/get-filtered-usage-events"
        static let origin = "https://cursor.com"
        static let referer = "https://cursor.com/dashboard?tab=usage"
        static let timeout: TimeInterval = 5
        static let pageSize = 500

        /// Los endpoints `/api/dashboard/*` responden 403 sin cabeceras de navegador.
        static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
            + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
    }

    static func makeRequest(token: String, windowDays: Int) -> URLRequest? {
        guard let url = URL(string: Endpoint.urlString) else { return nil }

        let now = Date()
        let start = Calendar.current.date(byAdding: .day, value: -max(windowDays, 1), to: now) ?? now
        let body: [String: Any] = [
            "teamId": 0,
            "startDate": String(Int(start.timeIntervalSince1970 * 1000)),
            "endDate": String(Int(now.timeIntervalSince1970 * 1000)),
            "page": 1,
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
        request.setValue("WorkosCursorSessionToken=\(token)", forHTTPHeaderField: "Cookie")
        request.setValue(Endpoint.origin, forHTTPHeaderField: "Origin")
        request.setValue(Endpoint.referer, forHTTPHeaderField: "Referer")
        request.setValue(Endpoint.userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    /// Acepta lo que el usuario pegue: el valor crudo de la cookie, con `::` literal o
    /// con `%3A%3A`, y opcionalmente con el prefijo `WorkosCursorSessionToken=`.
    static func normalizedToken(_ raw: String?) -> String? {
        guard var token = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            return nil
        }
        if let range = token.range(of: "WorkosCursorSessionToken=") {
            token = String(token[range.upperBound...])
        }
        token = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"; "))
        guard !token.isEmpty else { return nil }
        // El servidor acepta ambas formas; se envía la codificada, que es la que
        // el navegador guarda realmente.
        return token.replacingOccurrences(of: "::", with: "%3A%3A")
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
}

// MARK: - Parsing

extension CursorCollector {
    /// Un evento de uso ya normalizado. Prefijado por módulo: no toca el contrato.
    struct Event: Sendable {
        var day: String
        var dedupeID: String
        var model: String
        var inputTokens: Int
        var outputTokens: Int
        var cacheCreationTokens: Int
        var cacheReadTokens: Int
        /// Costo reportado por Cursor. `nil` -> se estima con `Pricing`.
        var costUSD: Double?

        func record(source: AppSource) -> UsageRecord {
            let cost = costUSD ?? Pricing.cost(model: model,
                                               inputTokens: inputTokens,
                                               outputTokens: outputTokens,
                                               cacheCreationTokens: cacheCreationTokens,
                                               cacheReadTokens: cacheReadTokens)
            return UsageRecord(source: source,
                               day: day,
                               inputTokens: inputTokens,
                               outputTokens: outputTokens,
                               cacheCreationTokens: cacheCreationTokens,
                               cacheReadTokens: cacheReadTokens,
                               costUSD: cost)
        }
    }

    /// Decodifica la respuesta del endpoint. Punto de ajuste si cambia el esquema.
    ///
    /// - Returns: los eventos con tokens, `[]` si la respuesta es válida pero vacía,
    ///   o `nil` si el formato no se reconoce.
    static func parse(_ data: Data) -> [Event]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        // Cuentas sin actividad devuelven `{}`: formato válido, cero eventos.
        if root.isEmpty { return [] }
        guard let raw = root["usageEventsDisplay"] as? [[String: Any]] else { return nil }
        return raw.compactMap(event(from:))
    }

    private static func event(from json: [String: Any]) -> Event? {
        guard let millis = epochMillis(json["timestamp"]) else { return nil }

        let usage = json["tokenUsage"] as? [String: Any] ?? [:]
        let input = int(usage["inputTokens"])
        let output = int(usage["outputTokens"])
        let cacheWrite = int(usage["cacheWriteTokens"])
        let cacheRead = int(usage["cacheReadTokens"])
        // Eventos sin tokens no aportan nada y solo inflarían `seenMessageIDs`.
        guard input != 0 || output != 0 || cacheWrite != 0 || cacheRead != 0 else { return nil }

        let model = (json["model"] as? String) ?? ""
        let date = Date(timeIntervalSince1970: TimeInterval(millis) / 1000)

        // Cursor no da id de evento. La combinación timestamp + modelo + tokens es
        // estable entre corridas; el riesgo de colisión (dos eventos idénticos en el
        // mismo milisegundo) es despreciable.
        let dedupeID = "cursor:\(millis):\(model):\(input):\(output):\(cacheWrite):\(cacheRead)"

        var cost: Double?
        if let cents = double(usage["totalCents"]) {
            cost = cents / 100
        }

        return Event(day: DayKey.string(from: date),
                     dedupeID: dedupeID,
                     model: model,
                     inputTokens: input,
                     outputTokens: output,
                     cacheCreationTokens: cacheWrite,
                     cacheReadTokens: cacheRead,
                     costUSD: cost)
    }

    /// El timestamp llega como epoch en milisegundos, normalmente dentro de un string.
    private static func epochMillis(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        if let text = value as? String { return Int64(text) }
        return nil
    }

    private static func int(_ value: Any?) -> Int {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) ?? 0 }
        return 0
    }

    private static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }
}
