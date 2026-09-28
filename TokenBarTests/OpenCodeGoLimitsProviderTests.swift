import Foundation
import Testing

@testable import TokenBar

@Suite("OpenCodeGoLimitsProvider", .serialized)
struct OpenCodeGoLimitsProviderTests {
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

        init(auth: String? = #"{"opencode-go":{"type":"api","key":"key-go-falsa"}}"#) throws {
            root = FileManager.default.temporaryDirectory
                .appending(path: "opencode-limits-\(UUID().uuidString)", directoryHint: .isDirectory)
            authURL = root.appending(path: "auth.json")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if let auth { try Data(auth.utf8).write(to: authURL) }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [StubURLProtocol.self]
            session = URLSession(configuration: configuration)
        }

        func provider(now: Date = Date(timeIntervalSince1970: 1_000_000)) -> OpenCodeGoLimitsProvider {
            OpenCodeGoLimitsProvider(authURL: authURL, session: session, now: { now })
        }

        func cleanUp() {
            session.invalidateAndCancel()
            try? FileManager.default.removeItem(at: root)
            StubURLProtocol.clear()
        }
    }

    private static let json = """
    {"rolling":{"usagePercent":20,"resetInSec":3600},
     "weekly":{"usagePercent":50.5,"resetInSec":86400},
     "monthly":{"usagePercent":75,"resetInSec":172800}}
    """

    @Test("OpenCode se limita a la sección de cuotas")
    func clasificacionDeFuente() {
        #expect(!AppSource.allCases.contains(.opencode))
        #expect(AppSource.limitsCases.last == .opencode)
        #expect(AppSource.opencode.displayName == "OpenCode")
    }

    @Test("parsea JSON con las tres ventanas")
    func parseaJSON() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let snapshot = try #require(OpenCodeGoLimitsProvider.parse(Data(Self.json.utf8), now: now))
        #expect(snapshot.source == .opencode)
        #expect(snapshot.status == .ok)
        #expect(snapshot.windows.map(\.name) == ["5 horas", "Semanal", "Mes"])
        #expect(snapshot.windows.map(\.percent) == [20, 51, 75])
        #expect(snapshot.windows[0].resetsAt == now.addingTimeInterval(3600))
        #expect(snapshot.windows[1].resetsAt == now.addingTimeInterval(86400))
    }

    @Test("parsea la respuesta real de la API con usage y resetsAt absolutos")
    func parseaRespuestaReal() throws {
        // Respuesta real de GET /zen/go/v1/usage (2026-09-21)
        let real = """
        {"usage":{"rolling":{"status":"ok","percent":35,"resetsAt":"2026-09-22T07:46:47.307Z"},
         "weekly":{"status":"ok","percent":14,"resetsAt":"2026-09-28T00:00:00.000Z"},
         "monthly":{"status":"ok","percent":32,"resetsAt":"2026-10-09T18:38:32.000Z"}}}
        """
        let snapshot = try #require(OpenCodeGoLimitsProvider.parse(
            Data(real.utf8), now: Date(timeIntervalSince1970: 0)))
        #expect(snapshot.source == .opencode)
        #expect(snapshot.status == .ok)
        #expect(snapshot.windows.map(\.name) == ["5 horas", "Semanal", "Mes"])
        #expect(snapshot.windows.map(\.percent) == [35, 14, 32])
        #expect(snapshot.windows.map(\.resetsAt) == [
            Date(timeIntervalSince1970: 1_790_063_207.307),
            Date(timeIntervalSince1970: 1_790_553_600),
            Date(timeIntervalSince1970: 1_791_571_112)
        ])
    }

    @Test("parsea objeto JavaScript serializado")
    func parseaJavaScript() throws {
        let text = "export default { rolling: { usagePercent: 12.5, resetInSec: 60 }, "
            + "weekly: { usagePercent: 44, resetInSec: 120 }, "
            + "monthly: { usagePercent: 88, resetInSec: 180 } };"
        let snapshot = try #require(OpenCodeGoLimitsProvider.parse(
            Data(text.utf8), now: Date(timeIntervalSince1970: 0)))
        #expect(snapshot.windows.map(\.percent) == [13, 44, 88])
        #expect(snapshot.windows.map { $0.resetsAt?.timeIntervalSince1970 } == [60, 120, 180])
    }

    @Test("prioriza opencode-go y usa opencode como fallback")
    func prioridadDeCredencial() throws {
        let both = try Harness(auth: """
        {"opencode-go":{"type":"api","key":"go"},"opencode":{"type":"api","key":"base"}}
        """)
        defer { both.cleanUp() }
        #expect(OpenCodeGoLimitsProvider.apiKey(at: both.authURL) == "go")

        let fallback = try Harness(auth: #"{"opencode":{"type":"api","key":"base"}}"#)
        defer { fallback.cleanUp() }
        #expect(OpenCodeGoLimitsProvider.apiKey(at: fallback.authURL) == "base")
    }

    @Test("credencial ausente o inválida queda no configurada sin red")
    func authAusente() async throws {
        for auth in [nil, #"{}"#, #"{"opencode-go":{"type":"oauth","key":"x"}}"#] as [String?] {
            let harness = try Harness(auth: auth)
            defer { harness.cleanUp() }
            StubURLProtocol.setHandler { _ in
                Issue.record("No debía hacer una petición")
                return (500, Data())
            }
            #expect(await harness.provider().fetch().status == .notConfigured)
        }
    }

    @Test("construye la petición requerida y respeta cinco segundos")
    func request() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        StubURLProtocol.setHandler { request in
            #expect(request.url == OpenCodeGoLimitsProvider.Endpoint.usage)
            #expect(request.httpMethod == "GET")
            #expect(request.timeoutInterval == 5)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer key-go-falsa")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            #expect(request.value(forHTTPHeaderField: "User-Agent") == "TokenBar")
            return (200, Data(Self.json.utf8))
        }
        #expect(await harness.provider().fetch().status == .ok)
    }

    @Test("401 y 403 reportan credenciales inválidas")
    func unauthorized() async throws {
        for code in [401, 403] {
            let harness = try Harness()
            defer { harness.cleanUp() }
            StubURLProtocol.setHandler { _ in (code, Data()) }
            let snapshot = await harness.provider().fetch()
            #expect(snapshot.status == .invalidCredentials)
            #expect(snapshot.windows.isEmpty)
        }
    }

    @Test("formatos desconocidos y cifras inválidas fallan suavemente")
    func formatoDesconocido() async throws {
        for body in ["sin objeto", "{ rolling: { usagePercent: 10 } }",
                     #"{"rolling":{"usagePercent":-1,"resetInSec":60}}"#] {
            #expect(OpenCodeGoLimitsProvider.parse(Data(body.utf8), now: Date()) == nil)
        }

        let harness = try Harness()
        defer { harness.cleanUp() }
        StubURLProtocol.setHandler { _ in (200, Data("desconocido".utf8)) }
        let snapshot = await harness.provider().fetch()
        #expect(snapshot.status == .failed("Respuesta no reconocida"))
        #expect(snapshot.windows.isEmpty)
    }
}
