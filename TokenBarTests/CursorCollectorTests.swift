import Foundation
import SQLite3
import Testing

@testable import TokenBar

@Suite("CursorCollector", .serialized)
struct CursorCollectorTests {
    private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?
        private static let lock = NSLock()

        static func setHandler(_ handler: @escaping (URLRequest) throws -> (Int, Data)) {
            lock.lock()
            self.handler = handler
            lock.unlock()
        }

        static func clear() {
            lock.lock()
            handler = nil
            lock.unlock()
        }

        override class func canInit(with request: URLRequest) -> Bool {
            request.url?.host == "cursor.com"
        }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.lock.lock()
            let handler = Self.handler
            Self.lock.unlock()
            guard let handler else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            do {
                let (status, data) = try handler(request)
                let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                               httpVersion: nil, headerFields: nil)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }

        override func stopLoading() {}
    }

    private struct Harness {
        let root: URL
        let databaseURL: URL
        let stateDirectory: URL
        let breakdownDirectory: URL
        let session: URLSession
        let state: CollectorStateStore
        let breakdown: CursorBreakdownStore

        init(withCredential: Bool = true, expired: Bool = false) throws {
            root = FileManager.default.temporaryDirectory
                .appending(path: "cursor-collector-\(UUID().uuidString)", directoryHint: .isDirectory)
            databaseURL = root.appending(path: "state.vscdb")
            stateDirectory = root.appending(path: "state", directoryHint: .isDirectory)
            breakdownDirectory = root.appending(path: "breakdown", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if withCredential {
                let exp = expired ? 1 : 9_999_999_999
                try Self.writeDatabase(at: databaseURL, token: CursorCollectorTests.jwt(
                    sub: "google-oauth2|user_prueba", exp: TimeInterval(exp)))
            }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [StubURLProtocol.self]
            session = URLSession(configuration: configuration)
            state = CollectorStateStore(directory: stateDirectory)
            breakdown = CursorBreakdownStore(directory: breakdownDirectory)
        }

        func collector() -> CursorCollector {
            CursorCollector(store: state, breakdown: breakdown, databaseURL: databaseURL, session: session)
        }

        func cleanUp() {
            session.invalidateAndCancel()
            try? FileManager.default.removeItem(at: root)
            StubURLProtocol.clear()
        }

        private static func writeDatabase(at url: URL, token: String) throws {
            var database: OpaquePointer?
            guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
                throw CocoaError(.fileWriteUnknown)
            }
            defer { sqlite3_close(database) }
            guard sqlite3_exec(database,
                               "CREATE TABLE ItemTable (key TEXT UNIQUE, value BLOB)",
                               nil, nil, nil) == SQLITE_OK else {
                throw CocoaError(.fileWriteUnknown)
            }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database,
                                     "INSERT INTO ItemTable (key, value) VALUES (?, ?)",
                                     -1, &statement, nil) == SQLITE_OK else {
                throw CocoaError(.fileWriteUnknown)
            }
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(statement, 1, "cursorAuth/accessToken", -1, transient)
            token.withCString { pointer in
                sqlite3_bind_blob(statement, 2, pointer, Int32(strlen(pointer)), transient)
            }
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
    }

    private static func jwt(sub: String, exp: TimeInterval) -> String {
        func segment(_ object: [String: Any]) -> String {
            let data = try! JSONSerialization.data(withJSONObject: object)
            return data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        }
        return "\(segment(["alg": "HS256"])).\(segment(["sub": sub, "exp": exp])).firma"
    }

    /// Arma un evento con la forma real de `get-filtered-usage-events`. `tokenUsage: nil`
    /// omite el campo por completo, como hacen los eventos que no son de tokens.
    /// `cacheWrite` solo se incluye si se pasa: la API real lo omite casi siempre.
    private static func eventJSON(timestampMs: Int64, model: String = "default",
                                  isHeadless: Bool = false, conversationId: String? = "conv-1",
                                  input: Int = 0, output: Int = 0, cacheRead: Int = 0,
                                  cacheWrite: Int? = nil,
                                  totalCents: Double? = nil,
                                  hasTokenUsage: Bool = true) -> [String: Any] {
        var json: [String: Any] = [
            "timestamp": String(timestampMs),
            "model": model,
            "kind": "USAGE_EVENT_KIND_INCLUDED_IN_PRO_PLUS",
            "isTokenBasedCall": true,
            "isHeadless": isHeadless,
            "requestsCosts": 19.6,
            "chargedCents": 39.12,
            "subscriptionProductId": "pro-plus",
            "owningUser": 72_128_665
        ]
        if let conversationId { json["conversationId"] = conversationId }
        if hasTokenUsage {
            var usage: [String: Any] = ["inputTokens": input, "outputTokens": output,
                                        "cacheReadTokens": cacheRead]
            if let cacheWrite { usage["cacheWriteTokens"] = cacheWrite }
            if let totalCents { usage["totalCents"] = totalCents }
            json["tokenUsage"] = usage
        }
        return json
    }

    private static func responseData(events: [[String: Any]], total: Int? = nil) -> Data {
        let body: [String: Any] = [
            "totalUsageEventsCount": total ?? events.count,
            "usageEventsDisplay": events
        ]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    /// `URLProtocol` entrega el cuerpo como `httpBodyStream`, no como `httpBody`, para
    /// las peticiones que atraviesa un `URLProtocol` a medida; hay que leerlo de ahí.
    private static func requestBody(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4_096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }

    private static func requestJSON(_ request: URLRequest) -> [String: Any] {
        guard let body = requestBody(request),
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return [:]
        }
        return json
    }

    private static func requestPage(_ request: URLRequest) -> Int {
        requestJSON(request)["page"] as? Int ?? 1
    }

    private static func requestStartMs(_ request: URLRequest) -> Int64? {
        (requestJSON(request)["startDate"] as? String).flatMap(Int64.init)
    }

    private static func requestEndMs(_ request: URLRequest) -> Int64? {
        (requestJSON(request)["endDate"] as? String).flatMap(Int64.init)
    }

    /// Simula el endpoint real filtrando por `[startDate, endDate]` (inclusive) y paginando
    /// sobre el resultado filtrado — a diferencia de los handlers de arriba, que ignoran la
    /// ventana pedida, este SÍ la respeta: hace falta para probar que la ventana se encoge
    /// de verdad de un ciclo al siguiente, no que sigue siendo la misma.
    private static func windowedHandler(events: [[String: Any]]) -> (URLRequest) throws -> (Int, Data) {
        { request in
            let startMs = requestStartMs(request) ?? 0
            let endMs = requestEndMs(request) ?? Int64.max
            let page = requestPage(request)
            let matching = events.filter { event in
                guard let text = event["timestamp"] as? String, let ts = Int64(text) else { return false }
                return ts >= startMs && ts <= endMs
            }.sorted { lhs, rhs in
                let lhsMs = Int64(lhs["timestamp"] as? String ?? "") ?? 0
                let rhsMs = Int64(rhs["timestamp"] as? String ?? "") ?? 0
                return lhsMs > rhsMs
            }
            let pageStart = (page - 1) * CursorCollector.Endpoint.pageSize
            guard pageStart < matching.count else {
                return (200, responseData(events: [], total: matching.count))
            }
            let pageEnd = min(pageStart + CursorCollector.Endpoint.pageSize, matching.count)
            return (200, responseData(events: Array(matching[pageStart..<pageEnd]), total: matching.count))
        }
    }

    // MARK: - Tests

    @Test("parsea el evento real y calcula el costo desde totalCents")
    func parseaEventoReal() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let timestamp: Int64 = 1_790_281_605_036
        StubURLProtocol.setHandler { request in
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Origin") == "https://cursor.com")
            #expect(request.value(forHTTPHeaderField: "Referer") == "https://cursor.com/dashboard")
            let cookie = try #require(request.value(forHTTPHeaderField: "Cookie"))
            #expect(cookie.hasPrefix("WorkosCursorSessionToken="))
            let event = Self.eventJSON(timestampMs: timestamp, model: "cursor-grok-4.6-high",
                                       isHeadless: false, conversationId: "0152068b-abcd",
                                       input: 67_972, output: 4_520, cacheRead: 456_384,
                                       totalCents: 78.25)
            return (200, Self.responseData(events: [event]))
        }

        let result = await harness.collector().collect()

        #expect(result.status == .ok)
        #expect(result.records.count == 1)
        let record = try #require(result.records.first)
        #expect(record.source == .cursor)
        #expect(record.inputTokens == 67_972)
        #expect(record.outputTokens == 4_520)
        #expect(record.cacheCreationTokens == 0)
        #expect(record.cacheReadTokens == 456_384)
        #expect(abs(record.costUSD - 0.7825) < 1e-9)
        #expect(record.day == DayKey.string(from: Date(timeIntervalSince1970: Double(timestamp) / 1000)))
    }

    @Test("modelRecords: un registro por modelo (nombre corto) que cumple el invariante")
    func modelRecordsPorModelo() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        StubURLProtocol.setHandler { _ in
            let events = [
                Self.eventJSON(timestampMs: now, model: "cursor-grok-4.6-high",
                               conversationId: "c1", input: 100, output: 20, cacheRead: 300,
                               totalCents: 50),
                Self.eventJSON(timestampMs: now - 1_000, model: "cursor-grok-4.6-high",
                               isHeadless: true, conversationId: "c2", input: 10, output: 2),
                Self.eventJSON(timestampMs: now - 2_000, model: "default",
                               conversationId: "c3", input: 7, output: 3, totalCents: 1)
            ]
            return (200, Self.responseData(events: events))
        }

        let result = await harness.collector().collect()

        #expect(result.status == .ok)
        StatsSupport.expectInvariant(result)
        #expect(StatsSupport.total(result) == 442)
        let grok = try #require(result.modelRecords.first { $0.model == "grok-4.6-high" })
        #expect(grok.source == .cursor)
        #expect(grok.totalTokens == 432)
        #expect(result.modelRecords.contains { $0.model == "default" })
    }

    @Test("un evento sin tokenUsage no se cuenta pero no rompe el parseo")
    func eventoSinTokenUsage() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        StubURLProtocol.setHandler { _ in
            let sinTokens = Self.eventJSON(timestampMs: now - 1_000, conversationId: "conv-sin-tokens",
                                           hasTokenUsage: false)
            let conTokens = Self.eventJSON(timestampMs: now, conversationId: "conv-con-tokens",
                                           input: 10, output: 5)
            return (200, Self.responseData(events: [sinTokens, conTokens]))
        }

        let result = await harness.collector().collect()

        #expect(result.status == .ok)
        #expect(result.records.count == 1)
        #expect(result.records.first?.totalTokens == 15)
    }

    @Test("isHeadless separa CLI y app en el desglose por origen")
    func isHeadlessSeparaOrigen() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        StubURLProtocol.setHandler { _ in
            let cli = Self.eventJSON(timestampMs: now - 1_000, model: "composer-2.5",
                                     isHeadless: true, conversationId: "conv-cli",
                                     input: 100, output: 50)
            let app = Self.eventJSON(timestampMs: now, model: "composer-2.5",
                                     isHeadless: false, conversationId: "conv-app",
                                     input: 30, output: 20)
            return (200, Self.responseData(events: [cli, app]))
        }

        let result = await harness.collector().collect()
        #expect(result.status == .ok)

        let split = await harness.breakdown.originSplit(windowDays: 30)
        #expect(split.cliTokens == 150)
        #expect(split.cliEvents == 1)
        #expect(split.appTokens == 50)
        #expect(split.appEvents == 1)

        let byModel = await harness.breakdown.totalsByModel(windowDays: 30)
        #expect(byModel == [CursorBreakdownStore.ModelTotal(model: "composer-2.5", tokens: 200)])
    }

    @Test("pagina hasta agotar el total declarado")
    func paginaHastaAgotarElTotal() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        // Página 1 llena (pageSize = 200) y página 2 con el resto: 203 eventos en total.
        let firstPage = (0..<200).map { index in
            Self.eventJSON(timestampMs: now - Int64(1_000 - index), conversationId: "conv-p1-\(index)",
                           input: 1, output: 0)
        }
        let secondPage = (0..<3).map { index in
            Self.eventJSON(timestampMs: now - Int64(3 - index), conversationId: "conv-p2-\(index)",
                           input: 1, output: 0)
        }
        var requestedPages: [Int] = []
        StubURLProtocol.setHandler { request in
            let page = Self.requestPage(request)
            requestedPages.append(page)
            switch page {
            case 1: return (200, Self.responseData(events: firstPage, total: 203))
            case 2: return (200, Self.responseData(events: secondPage, total: 203))
            default:
                Issue.record("no debía pedir la página \(page)")
                return (200, Self.responseData(events: []))
            }
        }

        let result = await harness.collector().collect()

        #expect(requestedPages == [1, 2])
        #expect(result.status == .ok)
        #expect(result.records.reduce(0) { $0 + $1.totalTokens } == 203)
    }

    @Test("deduplica eventos repetidos por conversationId y timestamp")
    func deduplicaPorConversationIdYTimestamp() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        StubURLProtocol.setHandler { _ in
            // El mismo evento repetido (misma conversationId + timestamp): solo debe
            // contarse una vez, como si el servidor lo hubiera devuelto dos veces.
            let event = Self.eventJSON(timestampMs: now, conversationId: "conv-duplicado",
                                       input: 40, output: 10)
            return (200, Self.responseData(events: [event, event]))
        }

        let result = await harness.collector().collect()
        #expect(result.status == .ok)
        #expect(result.records.reduce(0) { $0 + $1.totalTokens } == 50)
    }

    @Test("atribuye cada evento al día de su timestamp, no al de hoy")
    func atribucionPorDiaDelEvento() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let fiveDaysAgo = Date().addingTimeInterval(-5 * 86_400)
        let millis = Int64(fiveDaysAgo.timeIntervalSince1970 * 1000)
        await harness.state.load()
        // Marca de agua ya avanzada, para que la ventana consultada cubra el pasado.
        await harness.state.advanceCursorLastEventTimestamp(to: millis - 60_000)
        StubURLProtocol.setHandler { _ in
            let event = Self.eventJSON(timestampMs: millis, conversationId: "conv-viejo",
                                       input: 5, output: 5)
            return (200, Self.responseData(events: [event]))
        }

        let result = await harness.collector().collect()

        #expect(result.status == .ok)
        #expect(result.records.first?.day == DayKey.string(from: fiveDaysAgo))
        #expect(result.records.first?.day != DayKey.today())
    }

    @Test("sin credencial queda no configurado y no hace red")
    func sinCredencial() async throws {
        let harness = try Harness(withCredential: false)
        defer { harness.cleanUp() }
        StubURLProtocol.setHandler { _ in
            Issue.record("no debía hacer una petición")
            return (500, Data())
        }

        let result = await harness.collector().collect()
        #expect(result.status == .notConfigured)
        #expect(result.records.isEmpty)
    }

    @Test("un error de lectura es .failed con el código SQLite, no no-configurado, y no hace red")
    func errorDeLectura() async throws {
        let harness = try Harness(withCredential: false)
        defer { harness.cleanUp() }
        try Data("no es una base".utf8).write(to: harness.databaseURL)
        StubURLProtocol.setHandler { _ in
            Issue.record("no debía hacer una petición")
            return (500, Data())
        }

        let result = await harness.collector().collect()
        #expect(result.status == .failed("No se pudo leer la sesión de Cursor (SQLite 26)"))
        #expect(result.records.isEmpty)
    }

    @Test("un fallo de lectura usa la credencial del ciclo anterior del mismo collector")
    func credencialRecordada() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        StubURLProtocol.setHandler { _ in (200, Data("{}".utf8)) }
        let collector = harness.collector()

        #expect(await collector.collect().status == .ok)

        try Data("no es una base".utf8).write(to: harness.databaseURL)
        #expect(await collector.collect().status == .ok)

        // Otro collector sin historia sí reporta el fallo.
        #expect(await harness.collector().collect().status
                == .failed("No se pudo leer la sesión de Cursor (SQLite 26)"))
    }

    @Test("un JWT vencido reporta credenciales inválidas sin red")
    func jwtVencido() async throws {
        let harness = try Harness(expired: true)
        defer { harness.cleanUp() }
        StubURLProtocol.setHandler { _ in
            Issue.record("no debía hacer una petición")
            return (500, Data())
        }

        let result = await harness.collector().collect()
        #expect(result.status == .invalidCredentials)
    }

    @Test("401 reporta credenciales inválidas")
    func status401() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        StubURLProtocol.setHandler { _ in (401, Data()) }

        let result = await harness.collector().collect()
        #expect(result.status == .invalidCredentials)
        #expect(result.records.isEmpty)
    }

    @Test("un formato desconocido falla suave sin inventar cifras")
    func formatoDesconocido() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        StubURLProtocol.setHandler { _ in (200, Data(#"{"algoInesperado":true}"#.utf8)) }

        let result = await harness.collector().collect()
        #expect(result.status == .failed("formato de respuesta desconocido"))
        #expect(result.records.isEmpty)
    }

    @Test("una cuenta sin actividad devuelve cero registros sin fallar")
    func cuentaSinActividad() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        StubURLProtocol.setHandler { _ in (200, Data("{}".utf8)) }

        let result = await harness.collector().collect()
        #expect(result.status == .ok)
        #expect(result.records.isEmpty)
    }

    @Test("el nombre para mostrar limpia el prefijo cursor- y deja el resto igual")
    func nombreParaMostrar() {
        #expect(CursorCollector.displayName(forModel: "cursor-grok-4.6-high") == "grok-4.6-high")
        #expect(CursorCollector.displayName(forModel: "composer-2.5") == "composer-2.5")
        #expect(CursorCollector.displayName(forModel: "default") == "default")
    }

    // MARK: - P1: la marca de agua deja solapamiento para eventos tardíos

    @Test("retoma desde la marca de agua con solapamiento hacia atrás")
    func marcaDeAguaConSolapamiento() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        await harness.state.load()
        let watermark: Int64 = 1_790_000_000_000
        await harness.state.advanceCursorLastEventTimestamp(to: watermark)

        var seenStartMs: Int64?
        StubURLProtocol.setHandler { request in
            seenStartMs = Self.requestStartMs(request)
            return (200, Self.responseData(events: []))
        }

        _ = await harness.collector().collect()

        let overlap: Int64 = 2 * 86_400 * 1000
        #expect(seenStartMs == watermark - overlap)
    }

    @Test("un evento tardío con timestamp anterior a la marca sí se cuenta")
    func eventoTardioSeCuenta() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        await harness.state.load()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        // La marca ya avanzó más allá de este evento (llegó tarde, publicado después de
        // que el ciclo anterior ya había visto eventos más nuevos).
        await harness.state.advanceCursorLastEventTimestamp(to: now)
        let lateTimestamp = now - 6 * 3_600_000 // 6 horas antes de la marca

        StubURLProtocol.setHandler { _ in
            let event = Self.eventJSON(timestampMs: lateTimestamp, conversationId: "conv-tardio",
                                       input: 7, output: 3)
            return (200, Self.responseData(events: [event]))
        }

        let result = await harness.collector().collect()
        #expect(result.status == .ok)
        #expect(result.records.reduce(0) { $0 + $1.totalTokens } == 10)
    }

    // MARK: - P1: tokenUsage irreconocible falla en vez de perder el consumo en silencio

    @Test("tokenUsage con campos irreconocibles falla como formato desconocido y no avanza la marca")
    func tokenUsageIrreconocible() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        await harness.state.load()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        StubURLProtocol.setHandler { _ in
            // Cursor renombró los campos de tokenUsage: ya no hay inputTokens/outputTokens/
            // cacheReadTokens reconocibles, pero el evento sigue trayendo timestamp.
            var event = Self.eventJSON(timestampMs: now, conversationId: "conv-renombrado")
            event["tokenUsage"] = ["promptTokens": 100, "completionTokens": 50]
            return (200, Self.responseData(events: [event]))
        }

        let result = await harness.collector().collect()

        #expect(result.status == .failed("formato de respuesta desconocido"))
        #expect(result.records.isEmpty)
        #expect(await harness.state.cursorLastEventTimestamp() == nil)
    }

    @Test("un contador ausente entre otros reconocibles vale 0: la página no falla y la marca avanza")
    func unContadorAusenteValeCero() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        await harness.state.load()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        StubURLProtocol.setHandler { _ in
            // Como en la API real (2026-10-06): `tokenUsage` sin `cacheReadTokens`. Antes se
            // trataba como esquema desconocido y la marca de agua quedaba clavada ciclo
            // tras ciclo (6 eventos así en 40 días bloqueaban TODO el consumo posterior).
            var event = Self.eventJSON(timestampMs: now, conversationId: "conv-sin-cache-read")
            event["tokenUsage"] = ["inputTokens": 40, "outputTokens": 10, "totalCents": 2.0]
            return (200, Self.responseData(events: [event]))
        }

        let result = await harness.collector().collect()

        #expect(result.status == .ok)
        let record = try #require(result.records.first)
        #expect(record.inputTokens == 40)
        #expect(record.outputTokens == 10)
        #expect(record.cacheReadTokens == 0)
        #expect(record.cacheCreationTokens == 0)
        #expect(abs(record.costUSD - 0.02) < 1e-9)
        #expect(await harness.state.cursorLastEventTimestamp() == now)
    }

    @Test("un contador presente pero no numérico sigue siendo formato desconocido")
    func contadorPresenteNoNumericoFalla() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        await harness.state.load()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        StubURLProtocol.setHandler { _ in
            // El campo existe pero cambió de forma: no hay manera segura de leerlo como 0.
            var event = Self.eventJSON(timestampMs: now, conversationId: "conv-no-numerico")
            event["tokenUsage"] = ["inputTokens": 40, "outputTokens": ["value": 10]]
            return (200, Self.responseData(events: [event]))
        }

        let result = await harness.collector().collect()

        #expect(result.status == .failed("formato de respuesta desconocido"))
        #expect(result.records.isEmpty)
        #expect(await harness.state.cursorLastEventTimestamp() == nil)
    }

    @Test("cacheWriteTokens llega a cacheCreationTokens y entra en el costo estimado")
    func cacheWriteTokensLlegaACacheCreation() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        StubURLProtocol.setHandler { _ in
            let event = Self.eventJSON(timestampMs: now, model: "claude-4.5-sonnet",
                                       conversationId: "conv-cache-write",
                                       input: 100, output: 10, cacheRead: 1_000, cacheWrite: 200)
            return (200, Self.responseData(events: [event]))
        }

        let result = await harness.collector().collect()

        #expect(result.status == .ok)
        StatsSupport.expectInvariant(result)
        let record = try #require(result.records.first)
        #expect(record.cacheCreationTokens == 200)
        #expect(record.totalTokens == 1_310)
        // Sin `totalCents`, el costo se estima con `Pricing` incluyendo la caché de escritura.
        let expected = Pricing.cost(model: "claude-4.5-sonnet", inputTokens: 100, outputTokens: 10,
                                    cacheCreationTokens: 200, cacheReadTokens: 1_000)
        #expect(expected > 0)
        #expect(abs(record.costUSD - expected) < 1e-9)
        let model = try #require(result.modelRecords.first)
        #expect(model.cacheCreationTokens == 200)
    }

    @Test("un tokenUsage explícitamente en cero se reconoce y no cuenta, sin fallar")
    func tokenUsageExplicitamenteEnCero() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        StubURLProtocol.setHandler { _ in
            let zero = Self.eventJSON(timestampMs: now, conversationId: "conv-cero",
                                      input: 0, output: 0, cacheRead: 0)
            return (200, Self.responseData(events: [zero]))
        }

        let result = await harness.collector().collect()
        #expect(result.status == .ok)
        #expect(result.records.isEmpty)
    }

    // MARK: - Crecimiento en sitio (2026-10-06): cada relectura suma solo lo que creció

    @Test("un evento que crece entre ciclos se cuenta por deltas: el total es la última foto, no la suma de fotos")
    func eventoQueCreceSeCuentaPorDeltas() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        await harness.state.load()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        // Mismo conversationId + timestamp en ambos ciclos: Cursor publica el evento al
        // arrancar el turno y le va sumando tokens y centavos en sitio.
        var snapshot = (input: 100, output: 10, cacheRead: 1_000, cacheWrite: 0, cents: 9.0)
        StubURLProtocol.setHandler { _ in
            let event = Self.eventJSON(timestampMs: now, model: "gpt-5.6-sol-high",
                                       conversationId: "conv-crece",
                                       input: snapshot.input, output: snapshot.output,
                                       cacheRead: snapshot.cacheRead, cacheWrite: snapshot.cacheWrite,
                                       totalCents: snapshot.cents)
            return (200, Self.responseData(events: [event]))
        }

        let first = await harness.collector().collect()
        #expect(first.status == .ok)
        #expect(StatsSupport.total(first) == 1_110)

        snapshot = (100, 25, 5_000, 200, 17.1)
        let second = await harness.collector().collect()
        #expect(second.status == .ok)
        StatsSupport.expectInvariant(second)
        let delta = try #require(second.records.first)
        #expect(delta.inputTokens == 0)
        #expect(delta.outputTokens == 15)
        #expect(delta.cacheReadTokens == 4_000)
        #expect(delta.cacheCreationTokens == 200)

        // Suma de ambos ciclos: exactamente la última foto, no la suma de las dos.
        let total = first.records + second.records
        #expect(total.reduce(0) { $0 + $1.inputTokens } == 100)
        #expect(total.reduce(0) { $0 + $1.outputTokens } == 25)
        #expect(total.reduce(0) { $0 + $1.cacheReadTokens } == 5_000)
        #expect(total.reduce(0) { $0 + $1.cacheCreationTokens } == 200)
        #expect(abs(total.reduce(0) { $0 + $1.costUSD } - 0.171) < 1e-9)
        // El desglose por modelo también va por deltas: un solo evento, 5 325 tokens.
        let byModel = await harness.breakdown.totalsByModel(windowDays: 30)
        #expect(byModel == [CursorBreakdownStore.ModelTotal(model: "gpt-5.6-sol-high", tokens: 5_325)])
        let split = await harness.breakdown.originSplit(windowDays: 30)
        #expect(split.appEvents == 1)
        #expect(split.appTokens == 5_325)

        // Una tercera lectura sin cambios no suma nada.
        let third = await harness.collector().collect()
        #expect(third.status == .ok)
        #expect(third.records.isEmpty)
    }

    @Test("un evento que solo sube en costo suma el ajuste de centavos al día y al modelo")
    func eventoQueSoloSubeEnCosto() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        await harness.state.load()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        var cents = 10.0
        StubURLProtocol.setHandler { _ in
            let event = Self.eventJSON(timestampMs: now, conversationId: "conv-centavos",
                                       input: 100, output: 10, cacheRead: 1_000, totalCents: cents)
            return (200, Self.responseData(events: [event]))
        }

        let first = await harness.collector().collect()
        #expect(abs(first.records.reduce(0) { $0 + $1.costUSD } - 0.10) < 1e-9)

        // Mismos tokens, más centavos: el ajuste final de costo de un turno ya cerrado.
        cents = 25.0
        let second = await harness.collector().collect()
        #expect(second.status == .ok)
        StatsSupport.expectInvariant(second)
        let delta = try #require(second.records.first)
        #expect(delta.totalTokens == 0)
        #expect(abs(delta.costUSD - 0.15) < 1e-9)
        #expect(abs((second.modelRecords.first?.costUSD ?? 0) - 0.15) < 1e-9)
        let total = (first.records + second.records).reduce(0) { $0 + $1.costUSD }
        #expect(abs(total - 0.25) < 1e-9)

        // Y no se vuelve a sumar en la siguiente lectura.
        let third = await harness.collector().collect()
        #expect(third.records.isEmpty)
    }

    @Test("un evento que baja en un campo no resta ni vuelve a sumar")
    func eventoQueBajaNoResta() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        await harness.state.load()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        var output = 10
        StubURLProtocol.setHandler { _ in
            let event = Self.eventJSON(timestampMs: now, conversationId: "conv-baja",
                                       input: 100, output: output, cacheRead: 1_000, totalCents: 9)
            return (200, Self.responseData(events: [event]))
        }

        let first = await harness.collector().collect()
        #expect(StatsSupport.total(first) == 1_110)

        output = 5
        let second = await harness.collector().collect()
        #expect(second.status == .ok)
        #expect(second.records.isEmpty)

        // Si luego vuelve a subir por encima del máximo guardado, solo se suma ese exceso.
        output = 12
        let third = await harness.collector().collect()
        #expect(StatsSupport.total(third) == 2)
    }

    @Test("las fotos sobreviven a un reinicio: tras recargar state.json solo se suma el crecimiento")
    func fotosSobrevivenAlReinicio() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        await harness.state.load()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        var cacheRead = 1_000
        StubURLProtocol.setHandler { _ in
            let event = Self.eventJSON(timestampMs: now, conversationId: "conv-reinicio",
                                       input: 100, output: 10, cacheRead: cacheRead)
            return (200, Self.responseData(events: [event]))
        }

        let first = await harness.collector().collect()
        #expect(StatsSupport.total(first) == 1_110)
        await harness.state.save()

        let reloadedState = CollectorStateStore(directory: harness.stateDirectory)
        await reloadedState.load()
        let reloadedCollector = CursorCollector(store: reloadedState, breakdown: harness.breakdown,
                                                databaseURL: harness.databaseURL, session: harness.session)
        cacheRead = 1_500
        let second = await reloadedCollector.collect()
        #expect(StatsSupport.total(second) == 500)
    }

    @Test("state.json v3: un evento ya visto como booleano no se vuelve a sumar y el estado se guarda en v4")
    func stateV3NoVuelveASumarLoVisto() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        // Antes de v4 el collector guardaba `cursor:<conversationId>:<timestamp>` en
        // `seenMessageIDs`. Ese evento ya se contó con su primera foto: aunque hoy traiga
        // más tokens, no hay contra qué calcular el delta y NO debe sumarse entero otra vez.
        let seenID = "cursor:conv-v3:\(now - 1_000)"
        let v3 = """
        {"version":3,"bootstrapped":["cursor"],"cursors":{},
         "seenMessageIDs":["\(seenID)","otro-collector-1"],"claudeMessages":[],
         "cursorLastEventTimestampMs":\(now - 1_000),
         "codexResponseIDsBySource":{},"codexModelByPath":{},
         "commandCodeMessageIDs":[],"openCodeFinalizedMessageIDs":[]}
        """
        try FileManager.default.createDirectory(at: harness.stateDirectory, withIntermediateDirectories: true)
        let stateURL = harness.stateDirectory.appending(path: "state.json")
        try Data(v3.utf8).write(to: stateURL)
        await harness.state.load()
        StubURLProtocol.setHandler { _ in
            let visto = Self.eventJSON(timestampMs: now - 1_000, conversationId: "conv-v3",
                                       input: 500, output: 50)
            let nuevo = Self.eventJSON(timestampMs: now, conversationId: "conv-nuevo",
                                       input: 7, output: 3)
            return (200, Self.responseData(events: [visto, nuevo]))
        }

        let result = await harness.collector().collect()
        #expect(result.status == .ok)
        #expect(StatsSupport.total(result) == 10)
        // El id de otro collector sigue en el dedup general.
        #expect(await harness.state.markSeen(messageID: "otro-collector-1"))

        await harness.state.save()
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL))
            as? [String: Any])
        #expect(object["version"] as? Int == 4)
        #expect(object["cursorSeenWithoutSnapshot"] as? [String] == [seenID])
        #expect(object["seenMessageIDs"] as? [String] == ["otro-collector-1"])
        let snapshots = try #require(object["cursorEventSnapshots"] as? [String: Any])
        #expect(snapshots.keys.sorted() == ["cursor:conv-nuevo:\(now)"])
    }

    // MARK: - P2: al topar el tope de páginas, cuenta lo ya leído y no avanza la marca

    @Test("al topar el tope de páginas cuenta lo ya leído en vez de tirarlo, y no avanza la marca")
    func topeDePaginasCuentaLoLeido() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        await harness.state.load()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        // Cada página viene llena (pageSize = 200) y el total declarado es enorme, así que
        // el ciclo topa con maxPages (50) sin terminar la ventana: 50 × 200 = 10 000 eventos
        // con token, todos deberían contarse aunque la ventana quede incompleta.
        func fullPage(_ index: Int) -> [[String: Any]] {
            (0..<200).map { offset in
                Self.eventJSON(timestampMs: now - Int64(index * 200 + offset),
                               conversationId: "conv-\(index)-\(offset)", input: 1)
            }
        }
        var requestedPages: [Int] = []
        StubURLProtocol.setHandler { request in
            let page = Self.requestPage(request)
            requestedPages.append(page)
            return (200, Self.responseData(events: fullPage(page), total: 100_000))
        }

        let result = await harness.collector().collect()

        // Falla suave (la ventana no se completó)... pero SÍ trae los tokens ya leídos —
        // tirarlos haría que una API sostenidamente lenta nunca registrara nada.
        #expect(result.status == .failed("más de 10000 eventos en la ventana"))
        #expect(result.records.reduce(0) { $0 + $1.totalTokens } == 50 * 200)
        #expect(requestedPages == Array(1...50))
        // La marca de agua no avanza: el próximo ciclo vuelve a pedir la ventana completa
        // (el dedup, no la marca, es lo que evita contar dos veces — ver el test siguiente).
        #expect(await harness.state.cursorLastEventTimestamp() == nil)
    }

    @Test("dos ciclos seguidos sobre la misma ventana no duplican el total, incluso tras recargar el estado")
    func dosCiclosSobreLaMismaVentanaNoDuplican() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        await harness.state.load()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        func fullPage(_ index: Int) -> [[String: Any]] {
            (0..<200).map { offset in
                Self.eventJSON(timestampMs: now - Int64(index * 200 + offset),
                               conversationId: "conv-\(index)-\(offset)", input: 1)
            }
        }
        StubURLProtocol.setHandler { request in
            let page = Self.requestPage(request)
            return (200, Self.responseData(events: fullPage(page), total: 100_000))
        }

        let first = await harness.collector().collect()
        #expect(first.records.reduce(0) { $0 + $1.totalTokens } == 50 * 200)
        await harness.state.save()

        // Un store NUEVO sobre el mismo directorio, como pasaría tras reiniciar la app:
        // el dedup persistido en disco (`seenMessageIDs`) es lo que debe evitar el doble
        // conteo, no un estado que solo viviera en memoria.
        let reloadedState = CollectorStateStore(directory: harness.stateDirectory)
        await reloadedState.load()
        let reloadedCollector = CursorCollector(store: reloadedState, breakdown: harness.breakdown,
                                                databaseURL: harness.databaseURL, session: harness.session)

        let second = await reloadedCollector.collect()
        // La ventana pide exactamente los mismos 10 000 eventos (misma marca nula, mismos
        // conversationId+timestamp): el dedup los filtra todos y el total no se duplica.
        #expect(second.records.reduce(0) { $0 + $1.totalTokens } == 0)
        #expect(second.status == .failed("más de 10000 eventos en la ventana"))
    }

    // MARK: - P2: el ciclo tiene un presupuesto total, no solo por página

    @Test("un presupuesto de ciclo agotado corta la paginación sin bloquear 250 segundos")
    func presupuestoDeCicloCorta() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        var requestedPages: [Int] = []
        // Páginas LLENAS (pageSize = 200): con una sola página corta, `shortPage` la
        // tomaría como la última y el ciclo terminaría "bien" tras una sola petición,
        // sin llegar nunca al presupuesto de tiempo que este test quiere ejercitar.
        func fullPage(_ index: Int) -> [[String: Any]] {
            (0..<200).map { offset in
                Self.eventJSON(timestampMs: now - Int64(index * 200 + offset),
                               conversationId: "conv-lento-\(index)-\(offset)", input: 1)
            }
        }
        StubURLProtocol.setHandler { request in
            let page = Self.requestPage(request)
            requestedPages.append(page)
            // Cada respuesta tarda más que el presupuesto total del ciclo (8 s), simulando
            // una API lenta: el ciclo debe cortar mucho antes de las 50 páginas.
            Thread.sleep(forTimeInterval: 4.2)
            return (200, Self.responseData(events: fullPage(page), total: 100_000))
        }

        // ContinuousClock, no Date: es monótono, así que un ajuste del reloj de pared
        // durante el test no falsea la medición (mismo motivo que en la producción).
        let clock = ContinuousClock()
        let started = clock.now
        let result = await harness.collector().collect()
        let elapsed = clock.now - started

        // Falla suave, igual que el tope de páginas... pero cuenta las páginas que sí
        // alcanzó a leer antes del corte, no las tira.
        #expect(result.status == .failed("tiempo agotado paginando la ventana"))
        #expect(result.records.reduce(0) { $0 + $1.totalTokens } == requestedPages.count * 200)
        #expect(!result.records.isEmpty)
        #expect(elapsed < .seconds(15)) // muy por debajo de los 50 × 5 s = 250 s del peor caso anterior
        #expect(requestedPages.count < 50)
    }

    // MARK: - P2: CursorBreakdownStore carga el histórico antes de grabar

    @Test("el desglose por modelo carga el histórico antes de grabar, no lo pisa")
    func desgloseCargaAntesDeGrabar() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        // Simula una corrida previa: el desglose ya tiene datos en disco.
        await harness.breakdown.record(day: "2026-09-01", model: "composer-2.5",
                                       isHeadless: false, tokens: 500)
        await harness.breakdown.save()

        // Una instancia NUEVA del store (como pasaría tras reiniciar la app), apuntando al
        // mismo directorio, sin haber llamado a load() todavía.
        let freshBreakdown = CursorBreakdownStore(directory: harness.breakdownDirectory)
        let collector = CursorCollector(store: harness.state, breakdown: freshBreakdown,
                                        databaseURL: harness.databaseURL, session: harness.session)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        StubURLProtocol.setHandler { _ in
            let event = Self.eventJSON(timestampMs: now, model: "composer-2.5",
                                       conversationId: "conv-nuevo", input: 10, output: 5)
            return (200, Self.responseData(events: [event]))
        }

        _ = await collector.collect()

        let totals = await freshBreakdown.totalsByModel(windowDays: 90)
        #expect(totals == [CursorBreakdownStore.ModelTotal(model: "composer-2.5", tokens: 515)])
    }

    // MARK: - P1 (ronda 4): la ventana se encoge entre ciclos en vez de repetirse

    @Test("con una ventana que siempre topa, varios ciclos completan el total sin duplicar ni perder eventos")
    func continuacionCompletaVariosCiclosSinDuplicarNiPerder() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        await harness.state.load()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        // 10 050 eventos, uno por milisegundo, del más nuevo (`now`) al más viejo: más de un
        // ciclo completo (maxPages(50) × pageSize(200) = 10 000) pero menos de dos, así que
        // hacen falta EXACTAMENTE dos llamadas a `collect()` para agotar la ventana.
        let total = 10_050
        let allEvents: [[String: Any]] = (0..<total).map { index in
            Self.eventJSON(timestampMs: now - Int64(index), conversationId: "conv-\(index)", input: 1)
        }
        var requestedWindows: [(startMs: Int64, endMs: Int64)] = []
        let handler = Self.windowedHandler(events: allEvents)
        StubURLProtocol.setHandler { request in
            requestedWindows.append((Self.requestStartMs(request) ?? 0, Self.requestEndMs(request) ?? Int64.max))
            return try handler(request)
        }

        let first = await harness.collector().collect()
        #expect(first.status == .failed("más de 10000 eventos en la ventana"))
        #expect(first.records.reduce(0) { $0 + $1.totalTokens } == 10_000)
        // La ventana no se completó: la marca de agua todavía no puede avanzar.
        #expect(await harness.state.cursorLastEventTimestamp() == nil)

        let second = await harness.collector().collect()
        #expect(second.status == .ok)
        // Los 50 eventos que faltaban, ni uno más (repetido) ni uno menos (perdido).
        #expect(second.records.reduce(0) { $0 + $1.totalTokens } == 50)
        // La marca salta al máximo de TODA la ventana (el evento más nuevo, `now`), no solo
        // al máximo del último tramo (que ronda el evento más viejo, cerca de `startMs`).
        #expect(await harness.state.cursorLastEventTimestamp() == now)

        // El segundo ciclo consultó una ventana estrictamente más vieja que la del primero:
        // la continuación retrocedió en vez de repetir la misma ventana desde la página 1.
        let firstEndMs = try #require(requestedWindows.first?.endMs)
        let secondEndMs = try #require(requestedWindows.last?.endMs)
        #expect(secondEndMs < firstEndMs)

        // Sin duplicados y sin huecos: la suma de ambos ciclos es exactamente el total real.
        let combined = first.records.reduce(0) { $0 + $1.totalTokens } + second.records.reduce(0) { $0 + $1.totalTokens }
        #expect(combined == total)
    }

    @Test("mientras la continuación está activa, la marca de agua no avanza ni retrocede")
    func continuacionActivaNoTocaLaMarca() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        await harness.state.load()
        let watermark: Int64 = 1_790_000_000_000
        await harness.state.advanceCursorLastEventTimestamp(to: watermark)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let total = 10_050
        let allEvents: [[String: Any]] = (0..<total).map { index in
            Self.eventJSON(timestampMs: now - Int64(index), conversationId: "conv-marca-\(index)", input: 1)
        }
        StubURLProtocol.setHandler(Self.windowedHandler(events: allEvents))

        _ = await harness.collector().collect()

        // Topó de nuevo: la marca vieja se queda intacta, ni avanza (faltan eventos por
        // confirmar) ni retrocede.
        #expect(await harness.state.cursorLastEventTimestamp() == watermark)
        #expect(await harness.state.cursorContinuation() != nil)
    }

    @Test("reiniciar la app a mitad de una continuación no rompe nada: retoma igual desde disco")
    func reinicioAMitadDeContinuacion() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        await harness.state.load()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let total = 10_050
        let allEvents: [[String: Any]] = (0..<total).map { index in
            Self.eventJSON(timestampMs: now - Int64(index), conversationId: "conv-r-\(index)", input: 1)
        }
        StubURLProtocol.setHandler(Self.windowedHandler(events: allEvents))

        let first = await harness.collector().collect()
        #expect(first.status == .failed("más de 10000 eventos en la ventana"))
        await harness.state.save()

        // Un store y un collector NUEVOS sobre el mismo directorio: como si la app se
        // hubiera reiniciado con la continuación a medio camino.
        let reloadedState = CollectorStateStore(directory: harness.stateDirectory)
        await reloadedState.load()
        let reloadedCollector = CursorCollector(store: reloadedState, breakdown: harness.breakdown,
                                                databaseURL: harness.databaseURL, session: harness.session)

        let second = await reloadedCollector.collect()
        #expect(second.status == .ok)
        #expect(second.records.reduce(0) { $0 + $1.totalTokens } == 50)
        #expect(await reloadedState.cursorLastEventTimestamp() == now)
        #expect(await reloadedState.cursorContinuation() == nil)
    }

    @Test("una página entera empatada en el mismo timestamp que endMs no traba la continuación")
    func empateDeTimestampNoTrabaLaContinuacion() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        await harness.state.load()
        let startMs: Int64 = 1_790_000_000_000
        let frontier: Int64 = 1_790_500_000_000
        // Continuación ya sembrada, como si un ciclo anterior hubiera dejado esto pendiente:
        // así el `endMs` de este ciclo es exactamente `frontier`, sin depender del reloj.
        await harness.state.setCursorContinuation(
            CursorContinuation(startMs: startMs, frontierMs: frontier, ceilingMs: nil))
        // Más eventos que un ciclo completo (maxPages(50) × pageSize(200) = 10 000), TODOS
        // con el MISMO timestamp exacto que `endMs`. Sin la salvaguarda, `minTimestampMs`
        // de este ciclo sería igual a `frontier` y la continuación quedaría IDÉNTICA a como
        // estaba: el próximo ciclo pediría la misma ventana para siempre.
        let tiedCount = 10_050
        let tiedEvents: [[String: Any]] = (0..<tiedCount).map { index in
            Self.eventJSON(timestampMs: frontier, conversationId: "conv-empate-\(index)", input: 1)
        }
        var requestedEndMs: [Int64] = []
        let handler = Self.windowedHandler(events: tiedEvents)
        StubURLProtocol.setHandler { request in
            requestedEndMs.append(Self.requestEndMs(request) ?? Int64.max)
            return try handler(request)
        }

        let first = await harness.collector().collect()
        #expect(first.status == .failed("más de 10000 eventos en la ventana"))
        // La salvaguarda fuerza el techo a bajar al menos 1 ms, aunque todo lo leído
        // comparta el mismo timestamp que `endMs`.
        let continuationAfterFirst = try #require(await harness.state.cursorContinuation())
        #expect(continuationAfterFirst.frontierMs == frontier - 1)

        let second = await harness.collector().collect()
        // El segundo ciclo consultó un techo ESTRICTAMENTE menor — no repitió la ventana.
        #expect(requestedEndMs.last == frontier - 1)
        // Y el proceso termina: la ventana [startMs, frontier-1] no tiene eventos (todos
        // comparten exactamente `frontier`), así que se completa y limpia la continuación
        // en vez de quedar atascado pidiendo lo mismo para siempre.
        #expect(second.status == .ok)
        #expect(await harness.state.cursorContinuation() == nil)
    }

    @Test("un state.json sin el campo de continuación carga bien (retrocompatibilidad)")
    func stateJsonSinContinuacionCargaBien() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "cursor-state-compat-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacy = """
        {"version":2,"bootstrapped":[],"cursors":{},"seenMessageIDs":[],"claudeMessages":[],
         "cursorLastEventTimestampMs":1790000000000}
        """
        try Data(legacy.utf8).write(to: directory.appending(path: "state.json"))

        let state = CollectorStateStore(directory: directory)
        await state.load()

        #expect(await state.cursorLastEventTimestamp() == 1_790_000_000_000)
        #expect(await state.cursorContinuation() == nil)
    }
}
