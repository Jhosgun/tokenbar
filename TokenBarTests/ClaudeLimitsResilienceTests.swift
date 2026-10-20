import Foundation
import Testing

@testable import TokenBar

@Suite("ClaudeLimitsProvider — resiliencia", .serialized)
struct ClaudeLimitsResilienceTests {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: Date

        init(_ date: Date) { storage = date }
        var now: Date { lock.lock(); defer { lock.unlock() }; return storage }
        func advance(_ seconds: TimeInterval) {
            lock.lock()
            storage = storage.addingTimeInterval(seconds)
            lock.unlock()
        }
    }

    private final class CredentialSequence: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [ClaudeCredentialReadResult]
        private var readsStorage = 0

        init(_ values: [ClaudeCredentialReadResult]) { self.values = values }
        var reads: Int { lock.lock(); defer { lock.unlock() }; return readsStorage }
        func next() -> ClaudeCredentialReadResult {
            lock.lock()
            defer { lock.unlock() }
            readsStorage += 1
            return values.isEmpty ? .notFound : values.removeFirst()
        }
    }

    private final class StubProtocol: URLProtocol, @unchecked Sendable {
        struct Reply: Sendable {
            var status: Int
            var headers: [String: String] = [:]
            var body = Data()
            var networkFailure = false
        }

        private static let lock = NSLock()
        nonisolated(unsafe) private static var replies: [Reply] = []
        nonisolated(unsafe) private static var requestsStorage: [URLRequest] = []

        static func configure(_ replies: [Reply]) {
            lock.lock()
            self.replies = replies
            requestsStorage = []
            lock.unlock()
        }

        static var requests: [URLRequest] {
            lock.lock()
            defer { lock.unlock() }
            return requestsStorage
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.lock.lock()
            Self.requestsStorage.append(request)
            let reply = Self.replies.isEmpty
                ? Reply(status: 500)
                : Self.replies.removeFirst()
            Self.lock.unlock()
            if reply.networkFailure {
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
                return
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status,
                                           httpVersion: nil, headerFields: reply.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.body)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private static let response = Data(#"{"five_hour":{"utilization":21,"resets_at":"2030-01-01T01:00:00Z"},"seven_day":{"utilization":42,"resets_at":"2030-01-07T00:00:00Z"}}"#.utf8)

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "claude-limits-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func missingCache() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "claude-cache-\(UUID().uuidString).json")
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func credential(_ token: String, expiresAt: Date? = nil) -> ClaudeCredentialReadResult {
        var oauth: [String: Any] = ["accessToken": token]
        if let expiresAt { oauth["expiresAt"] = expiresAt.timeIntervalSince1970 * 1_000 }
        let data = try! JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth])
        return .credential(String(decoding: data, as: UTF8.self))
    }

    @Test("sin caché local conserva el snapshot de red durante la válvula")
    func conservaSnapshotDuranteValvula() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let credentials = CredentialSequence([credential("token-1")])
        StubProtocol.configure([.init(status: 200, body: Self.response)])
        let provider = ClaudeLimitsProvider(cacheURL: missingCache(), session: session(),
            credentialRead: { credentials.next() }, userAgent: "claude-code/test",
            directory: dir, now: { clock.now })

        let first = await provider.fetch()
        clock.advance(5 * 60)
        let second = await provider.fetch()

        #expect(first.status == .ok)
        #expect(second == first)
        #expect(first.dataAsOf == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(StubProtocol.requests.count == 1)
        #expect(credentials.reads == 1)
    }

    @Test("un fallo al leer token no consume la válvula")
    func tokenLentoNoConsumeValvula() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let credentials = CredentialSequence([.timedOut, credential("token-1")])
        StubProtocol.configure([.init(status: 200, body: Self.response)])
        let provider = ClaudeLimitsProvider(cacheURL: missingCache(), session: session(),
            credentialRead: { credentials.next() }, directory: dir, now: { clock.now })

        #expect(await provider.fetch().status == .failed("Tiempo de espera agotado"))
        #expect(await provider.fetch().status == .ok)
        #expect(StubProtocol.requests.count == 1)
        #expect(credentials.reads == 2)
    }

    @Test("dos 429 elevan la espera de 15 a 30 minutos")
    func escalera429() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let credentials = CredentialSequence([credential("token-1"), credential("token-1"), credential("token-1")])
        StubProtocol.configure([.init(status: 429), .init(status: 429), .init(status: 200, body: Self.response)])
        let provider = ClaudeLimitsProvider(cacheURL: missingCache(), session: session(),
            credentialRead: { credentials.next() }, directory: dir, now: { clock.now })

        _ = await provider.fetch()
        clock.advance(14 * 60)
        _ = await provider.fetch()
        #expect(StubProtocol.requests.count == 1)
        clock.advance(60)
        _ = await provider.fetch()
        #expect(StubProtocol.requests.count == 2)
        clock.advance(29 * 60)
        _ = await provider.fetch()
        #expect(StubProtocol.requests.count == 2)
        clock.advance(60)
        #expect(await provider.fetch().status == .ok)
        #expect(StubProtocol.requests.count == 3)
    }

    @Test("401 relee y reintenta solo cuando el token cambió")
    func reintenta401ConTokenNuevo() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let credentials = CredentialSequence([credential("token-1"), credential("token-2")])
        StubProtocol.configure([.init(status: 401), .init(status: 200, body: Self.response)])
        let provider = ClaudeLimitsProvider(cacheURL: missingCache(), session: session(),
            credentialRead: { credentials.next() }, directory: dir, now: { clock.now })

        #expect(await provider.fetch().status == .ok)
        #expect(StubProtocol.requests.count == 2)
        #expect(StubProtocol.requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer token-1")
        #expect(StubProtocol.requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer token-2")
    }

    @Test("401 repetido con credencial recién leída es inválido")
    func rechazo401Repetido() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let credentials = CredentialSequence([credential("token-1"), credential("token-2")])
        StubProtocol.configure([.init(status: 401), .init(status: 401)])
        let provider = ClaudeLimitsProvider(cacheURL: missingCache(), session: session(),
            credentialRead: { credentials.next() }, directory: dir)

        #expect(await provider.fetch().status == .invalidCredentials)
        #expect(StubProtocol.requests.count == 2)
    }

    @Test("token vencido evita la red y conserva el último dato")
    func tokenVencido() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let firstCredentials = CredentialSequence([credential("token-1")])
        StubProtocol.configure([.init(status: 200, body: Self.response)])
        let first = ClaudeLimitsProvider(cacheURL: missingCache(), session: session(),
            credentialRead: { firstCredentials.next() }, directory: dir, now: { clock.now })
        _ = await first.fetch()

        StubProtocol.configure([])
        let expired = CredentialSequence([credential("token-vencido", expiresAt: clock.now.addingTimeInterval(-1))])
        let second = ClaudeLimitsProvider(cacheURL: missingCache(), session: session(),
            credentialRead: { expired.next() }, directory: dir, now: { clock.now })
        let snapshot = await second.fetch()

        #expect(snapshot.status == .failed("Sesión vencida: abre Claude Code"))
        #expect(snapshot.windows.count == 2)
        #expect(StubProtocol.requests.isEmpty)
    }

    @Test("un proveedor nuevo carga el snapshot persistido y reinicia ventanas vencidas")
    func persistenciaYResetVencido() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let firstDate = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = Clock(firstDate)
        let body = Data(#"{"five_hour":{"utilization":80,"resets_at":"2027-01-15T08:00:01Z"},"seven_day":{"utilization":40,"resets_at":"2030-01-07T00:00:00Z"}}"#.utf8)
        let credentials = CredentialSequence([credential("token-1")])
        StubProtocol.configure([.init(status: 200, body: body)])
        let first = ClaudeLimitsProvider(cacheURL: missingCache(), session: session(),
            credentialRead: { credentials.next() }, directory: dir, now: { clock.now })
        _ = await first.fetch()

        clock.advance(2)
        StubProtocol.configure([])
        let absent = CredentialSequence([.notFound])
        let second = ClaudeLimitsProvider(cacheURL: missingCache(), session: session(),
            credentialRead: { absent.next() }, directory: dir, now: { clock.now })
        let restored = await second.fetch()
        let disk = try String(contentsOf: dir.appending(path: "claude-limits.json"), encoding: .utf8)

        #expect(restored.windows[0].percent == 0)
        #expect(restored.windows[1].percent == 40)
        #expect(restored.dataAsOf == firstDate)
        #expect(!disk.contains("token-1"))
        #expect(!disk.contains("Authorization"))
        #expect(StubProtocol.requests.isEmpty)
    }

    @Test("Retry-After prolonga la espera más allá del mínimo")
    func respetaRetryAfter() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let credentials = CredentialSequence([credential("token-1"), credential("token-1")])
        StubProtocol.configure([
            .init(status: 429, headers: ["Retry-After": "1800"]),
            .init(status: 200, body: Self.response)
        ])
        let provider = ClaudeLimitsProvider(cacheURL: missingCache(), session: session(),
            credentialRead: { credentials.next() }, directory: dir, now: { clock.now })

        _ = await provider.fetch()
        clock.advance(29 * 60)
        _ = await provider.fetch()
        #expect(StubProtocol.requests.count == 1)
        clock.advance(60)
        #expect(await provider.fetch().status == .ok)
        #expect(StubProtocol.requests.count == 2)
    }

    @Test("llamadas concurrentes no duplican la lectura ni el GET")
    func llamadasConcurrentes() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let credentials = CredentialSequence([credential("token-1")])
        StubProtocol.configure([.init(status: 200, body: Self.response)])
        let provider = ClaudeLimitsProvider(cacheURL: missingCache(), session: session(),
            credentialRead: {
                try? await Task.sleep(for: .milliseconds(20))
                return credentials.next()
            }, directory: dir)

        async let first = provider.fetch()
        async let second = provider.fetch()
        _ = await (first, second)

        #expect(credentials.reads == 1)
        #expect(StubProtocol.requests.count == 1)
    }

    @Test("la caché local solo gana cuando es más reciente que la red")
    func prioridadPorFecha() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let cache = dir.appending(path: "claude.json")
        let credentials = CredentialSequence([credential("token-1")])
        StubProtocol.configure([.init(status: 200, body: Self.response)])
        let provider = ClaudeLimitsProvider(cacheURL: cache, session: session(),
            credentialRead: { credentials.next() }, directory: dir, now: { clock.now })
        let network = await provider.fetch()

        let newer = clock.now.addingTimeInterval(60)
        let local = """
        {"cachedUsageUtilization":{"fetchedAtMs":\(Int(newer.timeIntervalSince1970 * 1000)),
        "utilization":{"five_hour":{"utilization":88},"seven_day":{"utilization":77}}}}
        """
        try Data(local.utf8).write(to: cache)
        clock.advance(5 * 60)
        let selected = await provider.fetch()

        #expect(network.windows[0].percent == 21)
        #expect(selected.windows[0].percent == 88)
        #expect(selected.dataAsOf == newer)
        #expect(StubProtocol.requests.count == 1)
    }

    @Test("parsea una respuesta formada solo por limits y respeta reset por modelo")
    func soloLimits() throws {
        let data = Data(#"{"limits":[{"kind":"session","percent":12,"resets_at":"2030-01-01T01:00:00Z"},{"kind":"weekly_all","percent":34,"resets_at":"2030-01-07T00:00:00Z"},{"kind":"weekly_scoped","percent":56,"resets_at":"2030-01-03T00:00:00Z","scope":{"model":{"display_name":"Opus"}}}]}"#.utf8)
        let snapshot = try #require(ClaudeLimitsProvider.parse(data))

        #expect(snapshot.windows.map(\.name) == ["5 horas", "Semanal", "Opus semanal"])
        #expect(snapshot.windows.map(\.percent) == [12, 34, 56])
        #expect(snapshot.windows[2].resetsAt != snapshot.windows[1].resetsAt)
    }

    @Test("una credencial lenta no consume el plazo del GET")
    func credencialLentaNoConsumePlazo() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let credentials = CredentialSequence([credential("token-1")])
        StubProtocol.configure([.init(status: 200, body: Self.response)])
        let provider = ClaudeLimitsProvider(cacheURL: missingCache(), session: session(),
            credentialRead: {
                try? await Task.sleep(for: .seconds(6))
                return credentials.next()
            }, directory: dir, now: { clock.now })

        let snapshot = await provider.fetch()

        #expect(snapshot.status == .ok)
        #expect(StubProtocol.requests.count == 1)
    }

    @Test("401 con el mismo token al releer no reintenta y es inválido")
    func rechazo401MismoToken() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let credentials = CredentialSequence([credential("token-1"), credential("token-1")])
        StubProtocol.configure([.init(status: 401)])
        let provider = ClaudeLimitsProvider(cacheURL: missingCache(), session: session(),
            credentialRead: { credentials.next() }, directory: dir)

        #expect(await provider.fetch().status == .invalidCredentials)
        #expect(StubProtocol.requests.count == 1)
        #expect(credentials.reads == 2)
    }

    @Test("una respuesta sin ventanas reconocidas falla suave")
    func respuestaNoReconocida() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let credentials = CredentialSequence([credential("token-1")])
        StubProtocol.configure([.init(status: 200, body: Data(#"{"desconocido":true}"#.utf8))])
        let provider = ClaudeLimitsProvider(cacheURL: missingCache(), session: session(),
            credentialRead: { credentials.next() }, directory: dir)

        #expect(await provider.fetch().status == .failed("Respuesta no reconocida"))
    }

    @Test("textos de error: HTTP inesperado y fallo de transporte")
    func textosDeError() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let httpCredentials = CredentialSequence([credential("token-1")])
        StubProtocol.configure([.init(status: 502)])
        let httpProvider = ClaudeLimitsProvider(cacheURL: missingCache(), session: session(),
            credentialRead: { httpCredentials.next() }, directory: dir)
        #expect(await httpProvider.fetch().status == .failed("HTTP 502"))

        let transportCredentials = CredentialSequence([credential("token-1")])
        StubProtocol.configure([.init(status: 0, networkFailure: true)])
        let transportProvider = ClaudeLimitsProvider(cacheURL: missingCache(), session: session(),
            credentialRead: { transportCredentials.next() }, directory: dir)
        #expect(await transportProvider.fetch().status == .failed("Sin conexión"))
    }

    @Test("un fallo de transporte no consume la válvula de 15 minutos")
    func falloTransporteNoConsumeValvula() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let credentials = CredentialSequence([credential("token-1"), credential("token-1")])
        StubProtocol.configure([
            .init(status: 0, networkFailure: true),
            .init(status: 200, body: Self.response)
        ])
        let provider = ClaudeLimitsProvider(cacheURL: missingCache(), session: session(),
            credentialRead: { credentials.next() }, directory: dir, now: { clock.now })

        #expect(await provider.fetch().status == .failed("Sin conexión"))
        // 61 s después (no 15 min) el siguiente GET ya puede salir.
        clock.advance(61)
        #expect(await provider.fetch().status == .ok)
        #expect(StubProtocol.requests.count == 2)
    }

    @Test("un rechazo de credencial queda visible y se recupera al cambiar el token")
    func rechazoVisibleYRecupera() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let credentials = CredentialSequence([
            credential("token-1"),   // semilla
            credential("token-1"),   // intento del 401
            credential("token-1"),   // relectura del 401 (mismo token)
            credential("token-1"),   // ciclo en espera (sigue rechazado)
            credential("token-2"),   // token rotado -> GET inmediato
        ])
        StubProtocol.configure([
            .init(status: 200, body: Self.response),   // semilla
            .init(status: 401),                         // rechazo definitivo
            .init(status: 200, body: Self.response),   // recuperación
        ])
        let provider = ClaudeLimitsProvider(cacheURL: missingCache(), session: session(),
            credentialRead: { credentials.next() }, directory: dir, now: { clock.now })

        #expect(await provider.fetch().status == .ok)
        // Se abre la válvula para que el siguiente ciclo llegue al GET del 401.
        clock.advance(16 * 60)
        #expect(await provider.fetch().status == .invalidCredentials)

        // Dentro de la válvula, el rechazo no alterna con ".ok": sigue inválido y conserva
        // el último dato.
        clock.advance(5 * 60)
        let waiting = await provider.fetch()
        #expect(waiting.status == .failed("Token inválido: abre Claude Code"))
        #expect(waiting.windows.count == 2)
        #expect(StubProtocol.requests.count == 2)

        // Al rotar el token, el GET sale de inmediato sin esperar los 15 min.
        clock.advance(60)
        #expect(await provider.fetch().status == .ok)
        #expect(StubProtocol.requests.count == 3)
        #expect(credentials.reads == 5)
    }

    @Test("un 403 no es credencial inválida y conserva el último dato")
    func cuarentaYTresNoEsCredencial() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let credentials = CredentialSequence([credential("token-1"), credential("token-1")])
        StubProtocol.configure([
            .init(status: 200, body: Self.response),   // semilla
            .init(status: 403),
        ])
        let provider = ClaudeLimitsProvider(cacheURL: missingCache(), session: session(),
            credentialRead: { credentials.next() }, directory: dir, now: { clock.now })

        #expect(await provider.fetch().status == .ok)
        clock.advance(16 * 60)
        let snapshot = await provider.fetch()
        #expect(snapshot.status == .failed("HTTP 403"))
        #expect(snapshot.windows.count == 2)
        // El 403 no relee la credencial: el token se leyó una vez por fetch.
        #expect(credentials.reads == 2)
    }
}
