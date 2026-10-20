import Foundation
import Testing

@testable import TokenBar

@Suite("CommandCodeLimitsProvider", .serialized)
struct CommandCodeLimitsProviderTests {
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

        override class func canInit(with request: URLRequest) -> Bool { true }
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
        let authURL: URL
        let session: URLSession

        init(auth: String? = #"{"apiKey":"key-falsa"}"#) throws {
            root = FileManager.default.temporaryDirectory
                .appending(path: "command-code-limits-\(UUID().uuidString)", directoryHint: .isDirectory)
            authURL = root.appending(path: "auth.json")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if let auth { try Data(auth.utf8).write(to: authURL) }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [StubURLProtocol.self]
            session = URLSession(configuration: configuration)
        }

        func provider() -> CommandCodeLimitsProvider {
            CommandCodeLimitsProvider(authURL: authURL, session: session)
        }

        func cleanUp() {
            session.invalidateAndCancel()
            try? FileManager.default.removeItem(at: root)
            StubURLProtocol.clear()
        }
    }

    private static let whoami = #"{"success":true,"org":{"id":"org-falsa"}}"#
    // `monthlyCredits` es lo que queda del mes; el cupo es restante + usado del summary.
    private static let credits = """
    {"credits":{"planId":"pro","monthlyCredits":760,"purchasedCredits":10,"freeCredits":5},
     "windowLimits":{"limited":true,
       "fiveHour":{"used":25,"cap":100,"resetAt":1790089200000},
       "weekly":{"used":60,"cap":200,"resetAt":1790683200}}}
    """
    private static let subscriptions = """
    {"data":{"planId":"pro","status":"active",
     "currentPeriodStart":"2026-09-01T00:00:00Z","currentPeriodEnd":"2026-10-01T00:00:00Z"}}
    """
    private static let summary = """
    {"totalCount":128,"totalCost":12.5,"totalCredits":250,"totalMonthlyCredits":240,
     "periodBasis":"subscription"}
    """

    @Test("Command Code se limita a la sección de cuotas")
    func clasificacionDeFuente() {
        #expect(!AppSource.allCases.contains(.commandCode))
        #expect(AppSource.limitsCases.suffix(2) == [.commandCode, .opencode])
        #expect(AppSource.commandCode.displayName == "Command Code")
    }

    @Test("parsea ventanas, resets, mes y etiqueta del plan")
    func parseaRespuestaCompleta() throws {
        let snapshot = try #require(CommandCodeLimitsProvider.parse(
            creditsData: Data(Self.credits.utf8),
            subscriptionsData: Data(Self.subscriptions.utf8),
            summaryData: Data(Self.summary.utf8)))
        #expect(snapshot.source == .commandCode)
        #expect(snapshot.status == .ok)
        #expect(snapshot.planLabel == "pro · 128 req")
        #expect(snapshot.windows.map(\.name) == ["5 horas", "Semanal", "Mes"])
        #expect(snapshot.windows.map(\.percent) == [25, 30, 24])
        #expect(snapshot.windows[0].resetsAt == Date(timeIntervalSince1970: 1_790_089_200))
        #expect(snapshot.windows[1].resetsAt == Date(timeIntervalSince1970: 1_790_683_200))
        #expect(snapshot.windows[2].resetsAt == Date(timeIntervalSince1970: 1_790_812_800))
    }

    @Test("un usado por encima del tope se satura a 1, no se descarta")
    func usadoPorEncimaDelTopeSatura() throws {
        // Un tope excedido sí describe un estado real (sobreconsumo): la ventana se
        // muestra al 100%, no se rechaza como pasaría con un porcentaje imposible.
        let credits = """
        {"credits":{"planId":"pro","monthlyCredits":760},
         "windowLimits":{"limited":true,
          "fiveHour":{"used":150,"cap":100},"weekly":{"used":60,"cap":200}}}
        """
        let snapshot = try #require(CommandCodeLimitsProvider.parse(
            creditsData: Data(credits.utf8),
            subscriptionsData: Data(Self.subscriptions.utf8),
            summaryData: Data(Self.summary.utf8)))
        let fiveHour = try #require(snapshot.windows.first { $0.name == "5 horas" })
        #expect(fiveHour.utilization == 1)
        #expect(fiveHour.percent == 100)
    }

    @Test("omite ventanas con cap cero o nulo")
    func omiteCapsInvalidos() throws {
        let credits = """
        {"credits":{"planId":"pro","monthlyCredits":760},
         "windowLimits":{"limited":true,
          "fiveHour":{"used":25,"cap":0},"weekly":{"used":60,"cap":null}}}
        """
        let snapshot = try #require(CommandCodeLimitsProvider.parse(
            creditsData: Data(credits.utf8),
            subscriptionsData: Data(Self.subscriptions.utf8),
            summaryData: Data(Self.summary.utf8)))
        #expect(snapshot.windows.map(\.name) == ["Mes"])
        #expect(snapshot.windows.first?.percent == 24)
    }

    @Test("credencial ausente o incompleta queda no configurada sin red")
    func authAusente() async throws {
        for auth in [nil, #"{}"#, #"{"apiKey":" "}"#] as [String?] {
            let harness = try Harness(auth: auth)
            defer { harness.cleanUp() }
            StubURLProtocol.setHandler { _ in
                Issue.record("No debía hacer una petición")
                return (500, Data())
            }
            #expect(await harness.provider().fetch().status == .notConfigured)
        }
    }

    @Test("construye las cuatro peticiones requeridas")
    func peticiones() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let lock = NSLock()
        var paths: Set<String> = []
        var timeouts: [TimeInterval] = []
        StubURLProtocol.setHandler { request in
            #expect(request.httpMethod == "GET")
            #expect(request.timeoutInterval > 0)
            #expect(request.timeoutInterval <= 5)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer key-falsa")
            #expect(request.value(forHTTPHeaderField: "User-Agent") == "cli")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            let url = try #require(request.url)
            lock.lock()
            paths.insert(url.path)
            timeouts.append(request.timeoutInterval)
            lock.unlock()
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            switch url.path {
            case "/alpha/whoami":
                #expect(query.contains(URLQueryItem(name: "limits", value: "1")))
                return (200, Data(Self.whoami.utf8))
            case "/alpha/billing/credits":
                #expect(query.contains(URLQueryItem(name: "orgId", value: "org-falsa")))
                return (200, Data(Self.credits.utf8))
            case "/alpha/billing/subscriptions":
                #expect(query.contains(URLQueryItem(name: "orgId", value: "org-falsa")))
                return (200, Data(Self.subscriptions.utf8))
            case "/alpha/usage/summary":
                #expect(query.contains(URLQueryItem(name: "orgId", value: "org-falsa")))
                #expect(query.contains(URLQueryItem(name: "since", value: "2026-09-01T00:00:00Z")))
                return (200, Data(Self.summary.utf8))
            default:
                return (404, Data())
            }
        }
        let snapshot = await harness.provider().fetch()
        #expect(snapshot.status == .ok)
        #expect(paths == ["/alpha/whoami", "/alpha/billing/credits",
                          "/alpha/billing/subscriptions", "/alpha/usage/summary"])
        #expect(timeouts.count == 4)
        #expect(timeouts.allSatisfy { $0 > 0 && $0 <= 5 })
        #expect((timeouts.max() ?? 0) - (timeouts.min() ?? 0) < 1)
    }

    @Test("cuenta sin organización consulta sin orgId")
    func cuentaSinOrganizacion() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        // whoami real de una cuenta personal: "org":null
        StubURLProtocol.setHandler { request in
            let url = try #require(request.url)
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            switch url.path {
            case "/alpha/whoami":
                return (200, Data(#"{"success":true,"user":{"userName":"Jhosgun"},"org":null}"#.utf8))
            case "/alpha/billing/credits":
                #expect(!query.contains(where: { $0.name == "orgId" }))
                return (200, Data(Self.credits.utf8))
            case "/alpha/billing/subscriptions":
                #expect(!query.contains(where: { $0.name == "orgId" }))
                return (200, Data(Self.subscriptions.utf8))
            case "/alpha/usage/summary":
                #expect(!query.contains(where: { $0.name == "orgId" }))
                #expect(query.contains(URLQueryItem(name: "since", value: "2026-09-01T00:00:00Z")))
                return (200, Data(Self.summary.utf8))
            default:
                return (404, Data())
            }
        }
        let snapshot = await harness.provider().fetch()
        #expect(snapshot.status == .ok)
        #expect(snapshot.windows.map(\.name) == ["5 horas", "Semanal", "Mes"])
        #expect(snapshot.windows.map(\.percent) == [25, 30, 24])
        #expect(snapshot.planLabel == "pro · 128 req")
        #expect(CommandCodeLimitsProvider.organization(
            from: Data(#"{"org":null}"#.utf8)) == .personal)
        #expect(CommandCodeLimitsProvider.organization(
            from: Data(#"{"org":{"id":"org-1"}}"#.utf8)) == .organization("org-1"))
        #expect(CommandCodeLimitsProvider.organization(from: Data(#"{}"#.utf8)) == nil)
    }

    @Test("un 401 reporta credenciales inválidas y un 403 es transitorio")
    func unauthorized() async throws {
        // 401 es definitivo: vacía la fila.
        do {
            let harness = try Harness()
            defer { harness.cleanUp() }
            StubURLProtocol.setHandler { request in
                if request.url?.path == "/alpha/whoami" { return (200, Data(Self.whoami.utf8)) }
                return (401, Data())
            }
            let snapshot = await harness.provider().fetch()
            #expect(snapshot.status == .invalidCredentials)
            #expect(snapshot.windows.isEmpty)
        }
        // 403 es transitorio (B13): no es credencial rota.
        do {
            let harness = try Harness()
            defer { harness.cleanUp() }
            StubURLProtocol.setHandler { request in
                if request.url?.path == "/alpha/whoami" { return (200, Data(Self.whoami.utf8)) }
                return (403, Data())
            }
            let snapshot = await harness.provider().fetch()
            #expect(snapshot.status == .failed("HTTP 403"))
            #expect(snapshot.windows.isEmpty)
        }
    }

    @Test("un timeout de red se reporta como 'Tiempo de espera agotado', no 'Sin conexión'")
    func timeout() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        StubURLProtocol.setHandler { request in
            if request.url?.path == "/alpha/whoami" { throw URLError(.timedOut) }
            return (500, Data())
        }
        let snapshot = await harness.provider().fetch()
        #expect(snapshot.status == .failed("Tiempo de espera agotado"))
    }

    @Test("resetAt <= 0 se trata como 'sin fecha' y no como 1970")
    func resetAtCero() throws {
        let credits = """
        {"credits":{"planId":"pro","monthlyCredits":760},
         "windowLimits":{"limited":true,
           "fiveHour":{"used":25,"cap":100,"resetAt":0},
           "weekly":{"used":60,"cap":200,"resetAt":0}}}
        """
        let snapshot = try #require(CommandCodeLimitsProvider.parse(
            creditsData: Data(credits.utf8),
            subscriptionsData: Data(Self.subscriptions.utf8),
            summaryData: Data(Self.summary.utf8)))
        #expect(snapshot.windows.first { $0.name == "5 horas" }?.resetsAt == nil)
        #expect(snapshot.windows.first { $0.name == "Semanal" }?.resetsAt == nil)
    }

    @Test("sin suscripción ni resumen se pierden solo 'Mes' y la etiqueta")
    func suscripcionOpcional() throws {
        let credits = """
        {"credits":{"planId":"pro","monthlyCredits":760},
         "windowLimits":{"limited":true,
           "fiveHour":{"used":25,"cap":100,"resetAt":1790089200000},
           "weekly":{"used":60,"cap":200,"resetAt":1790683200}}}
        """
        let snapshot = try #require(CommandCodeLimitsProvider.parse(
            creditsData: Data(credits.utf8),
            subscriptionsData: nil,
            summaryData: nil))
        #expect(snapshot.windows.map(\.name) == ["5 horas", "Semanal"])
        #expect(snapshot.planLabel == nil)
    }

    @Test("un fallo de red o HTTP en suscripción o resumen conserva 5 horas y semanal")
    func auxiliaresFallan() async throws {
        for failing in ["/alpha/billing/subscriptions", "/alpha/usage/summary"] {
            for status in [500, 0] {
                let harness = try Harness()
                defer { harness.cleanUp() }
                StubURLProtocol.setHandler { request in
                    let path = try #require(request.url).path
                    if path == failing {
                        if status == 0 { throw URLError(.notConnectedToInternet) }
                        return (status, Data())
                    }
                    switch path {
                    case "/alpha/whoami": return (200, Data(Self.whoami.utf8))
                    case "/alpha/billing/credits": return (200, Data(Self.credits.utf8))
                    case "/alpha/billing/subscriptions": return (200, Data(Self.subscriptions.utf8))
                    default: return (200, Data(Self.summary.utf8))
                    }
                }
                let snapshot = await harness.provider().fetch()
                #expect(snapshot.status == .ok)
                #expect(snapshot.windows.map(\.name) == ["5 horas", "Semanal"])
            }
        }
    }

    @Test("un 429 activa el backoff del ViewModel")
    func rateLimited() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        StubURLProtocol.setHandler { request in
            if request.url?.path == "/alpha/whoami" { return (200, Data(Self.whoami.utf8)) }
            return (429, Data())
        }
        let snapshot = await harness.provider().fetch()
        #expect(snapshot.rateLimited)
        #expect(snapshot.status == .failed("Límite de consultas alcanzado"))
        #expect(snapshot.windows.isEmpty)
    }

    @Test("formatos desconocidos fallan suavemente")
    func formatoDesconocido() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        StubURLProtocol.setHandler { request in
            if request.url?.path == "/alpha/whoami" { return (200, Data(#"{"org":{}}"#.utf8)) }
            return (200, Data(#"{"desconocido":true}"#.utf8))
        }
        let snapshot = await harness.provider().fetch()
        #expect(snapshot.status == .failed("Respuesta no reconocida"))
        #expect(snapshot.windows.isEmpty)
        #expect(CommandCodeLimitsProvider.parse(creditsData: Data("{}".utf8),
                                                subscriptionsData: Data("{}".utf8),
                                                summaryData: Data("{}".utf8)) == nil)
    }
}
