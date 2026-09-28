import Foundation
import Testing

@testable import TokenBar

@Suite("CodexLimitsProvider", .serialized)
struct CodexLimitsProviderTests {
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
        let sessionsURL: URL
        let session: URLSession

        init(auth: String? = #"{"tokens":{"access_token":"token-falso","account_id":"cuenta-falsa"}}"#) throws {
            root = FileManager.default.temporaryDirectory
                .appending(path: "codex-limits-\(UUID().uuidString)", directoryHint: .isDirectory)
            authURL = root.appending(path: "auth.json")
            sessionsURL = root.appending(path: "sessions", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: sessionsURL, withIntermediateDirectories: true)
            if let auth {
                try Data(auth.utf8).write(to: authURL)
            }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [StubURLProtocol.self]
            session = URLSession(configuration: configuration)
        }

        func provider() -> CodexLimitsProvider {
            CodexLimitsProvider(authURL: authURL, sessionsURL: sessionsURL, session: session)
        }

        func writeRollout(_ lines: [String], day: String = "2026/09/22",
                          name: String = "rollout-prueba.jsonl") throws -> URL {
            try writeRollout(Data((lines.joined(separator: "\n") + "\n").utf8),
                             day: day, name: name)
        }

        func writeRollout(_ data: Data, day: String = "2026/09/22",
                          name: String = "rollout-prueba.jsonl") throws -> URL {
            let directory = sessionsURL.appending(path: day, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appending(path: name)
            try data.write(to: url)
            return url
        }

        func cleanUp() {
            session.invalidateAndCancel()
            try? FileManager.default.removeItem(at: root)
            StubURLProtocol.clear()
        }
    }

    private static let remoteJSON = """
    {
      "plan_type": "pro",
      "rate_limit": {
        "primary_window": {"used_percent": 24.5, "reset_at": 1790100000, "limit_window_seconds": 18000},
        "secondary_window": {"used_percent": 67, "reset_at": "2026-09-29T12:00:00Z", "window_minutes": 10080}
      },
      "additional_rate_limits": [
        {
          "limit_name": "Codex Mini",
          "rate_limit": {
            "primary_window": {"used_percent": 40, "window_minutes": 300},
            "secondary_window": {"used_percent": 60, "window_minutes": 10080}
          }
        },
        {
          "primary_window": {"used_percent": 99, "window_minutes": 300}
        }
      ]
    }
    """

    private static let rolloutLine = """
    {"timestamp":"2026-09-22T10:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"rate_limits":{"primary":{"used_percent":31.0,"window_minutes":300,"resets_at":1790100000},"secondary":{"used_percent":72.0,"window_minutes":10080,"resets_at":1790600000},"plan_type":"pro"}}}}
    """

    @Test("Codex se limita a la sección de cuotas")
    func clasificacionDeFuente() {
        #expect(!AppSource.allCases.contains(.codex))
        #expect(AppSource.limitsCases.contains(.codex))
        #expect(AppSource.codex.displayName == "Codex")
    }

    @Test("parsea uso remoto, plan, porcentajes y resets")
    func parseaUsoRemoto() throws {
        let snapshot = try #require(CodexLimitsProvider.parseUsage(Data(Self.remoteJSON.utf8)))
        #expect(snapshot.source == .codex)
        #expect(snapshot.status == .ok)
        #expect(snapshot.planLabel == "pro")
        // Orden global por duración: las dos de 5 horas (300 min) antes que las dos
        // semanales (10 080 min), no agrupadas por contenedor.
        #expect(snapshot.windows.map(\.name) == [
            "5 horas", "Codex Mini 5 horas", "Semanal", "Codex Mini semanal"
        ])
        #expect(snapshot.windows.map(\.percent) == [25, 40, 67, 60])
        #expect(abs(snapshot.windows[0].utilization - 0.245) < 0.0001)
        #expect(abs(snapshot.windows[2].utilization - 0.67) < 0.0001)
        #expect(snapshot.windows[0].resetsAt == Date(timeIntervalSince1970: 1_790_100_000))
        #expect(snapshot.windows[2].resetsAt == ISO8601DateFormatter().date(from: "2026-09-29T12:00:00Z"))
        #expect(snapshot.windows[1].resetsAt == nil)
        #expect(snapshot.windows[3].resetsAt == nil)
    }

    @Test("el orden es global por duración aunque el contenedor base no traiga las 5 horas")
    func ordenGlobalPorDuracion() throws {
        // El contenedor base solo trae la semanal; el de "Codex Mini" sí trae la de 5
        // horas. Concatenar por contenedor dejaría la semanal delante.
        let json = """
        {
          "plan_type": "pro",
          "rate_limit": {"secondary_window": {"used_percent": 50, "window_minutes": 10080}},
          "additional_rate_limits": [
            {"limit_name": "Codex Mini",
             "rate_limit": {"primary_window": {"used_percent": 20, "window_minutes": 300}}}
          ]
        }
        """
        let snapshot = try #require(CodexLimitsProvider.parseUsage(Data(json.utf8)))
        #expect(snapshot.windows.map(\.name) == ["Codex Mini 5 horas", "Semanal"])
    }

    @Test("un empate de duración lo desempata la posición: la ventana de la cuenta manda")
    func empatePorDuracionMandaLaDeLaCuenta() throws {
        // La ventana base y la de "Codex Mini" duran lo mismo (300 min). `sorted` no está
        // garantizado estable, así que sin desempate explícito la del modelo podría colarse
        // primero — y la fila plegada, que muestra `windows.first`, mostraría la cuota del
        // modelo en vez de la de la cuenta.
        let json = """
        {
          "plan_type": "pro",
          "rate_limit": {"primary_window": {"used_percent": 20, "window_minutes": 300}},
          "additional_rate_limits": [
            {"limit_name": "Codex Mini",
             "rate_limit": {"primary_window": {"used_percent": 50, "window_minutes": 300}}}
          ]
        }
        """
        let snapshot = try #require(CodexLimitsProvider.parseUsage(Data(json.utf8)))
        #expect(snapshot.windows.map(\.name) == ["5 horas", "Codex Mini 5 horas"])
    }

    @Test("nombra ventanas conocidas y duraciones genéricas")
    func nombresDeVentana() {
        #expect(CodexLimitsProvider.windowName(minutes: 300) == "5 horas")
        #expect(CodexLimitsProvider.windowName(minutes: 10_080) == "Semanal")
        #expect(CodexLimitsProvider.windowName(minutes: 2_880) == "2 d")
        #expect(CodexLimitsProvider.windowName(minutes: 180) == "3 h")
        #expect(CodexLimitsProvider.windowName(minutes: 90) == "90 min")
    }

    @Test("rechaza epoch en milisegundos y acepta ISO con fracciones")
    func formatosDeReset() {
        #expect(CodexLimitsProvider.resetDate(from: 1_790_100_000_000 as NSNumber) == nil)
        #expect(CodexLimitsProvider.resetDate(from: "2026-09-29T12:00:00.123Z") ==
                Date(timeIntervalSince1970: 1_790_683_200.123))
    }

    @Test("un porcentaje fuera de 0…100 rechaza la ventana en vez de mostrar una cifra imposible")
    func porcentajeFueraDeRango() {
        let json = """
        {"plan_type":"pro",
         "rate_limit":{"primary_window":{"used_percent":140,"window_minutes":300},
                       "secondary_window":{"used_percent":20,"window_minutes":10080}}}
        """
        let snapshot = CodexLimitsProvider.parseUsage(Data(json.utf8))
        #expect(snapshot?.windows.map(\.name) == ["Semanal"])
    }

    @Test("un window_minutes que no cabe en un Int no revienta la conversión")
    func minutosQueNoCabenEnInt() {
        // 10^20 es un Double finito y entero, pero no cabe en un Int.
        let json = """
        {"plan_type":"pro",
         "rate_limit":{"primary_window":{"used_percent":20,"window_minutes":1e20},
                       "secondary_window":{"used_percent":40,"window_minutes":10080}}}
        """
        let snapshot = CodexLimitsProvider.parseUsage(Data(json.utf8))
        #expect(snapshot?.windows.map(\.name) == ["Semanal"])
    }

    @Test("rechaza formatos remotos desconocidos")
    func formatoRemotoDesconocido() {
        #expect(CodexLimitsProvider.parseUsage(Data("{}".utf8)) == nil)
        #expect(CodexLimitsProvider.parseUsage(Data(#"{"rate_limit":{}}"#.utf8)) == nil)
        #expect(CodexLimitsProvider.parseUsage(Data("no es json".utf8)) == nil)
    }

    @Test("extrae únicamente la credencial requerida")
    func credencial() throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let credential = try #require(CodexLimitsProvider.credential(at: harness.authURL))
        #expect(credential.accessToken == "token-falso")
        #expect(credential.accountID == "cuenta-falsa")
    }

    @Test("auth ausente o incompleto queda no configurado sin red")
    func authAusente() async throws {
        for auth in [nil, #"{"tokens":{}}"#, #"{"tokens":{"access_token":"x"}}"#] as [String?] {
            let harness = try Harness(auth: auth)
            defer { harness.cleanUp() }
            StubURLProtocol.setHandler { _ in
                Issue.record("No debía hacer una petición")
                return (500, Data())
            }
            let snapshot = await harness.provider().fetch()
            #expect(snapshot.status == .notConfigured)
        }
    }

    @Test("construye la petición requerida y respeta cinco segundos")
    func request() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        StubURLProtocol.setHandler { request in
            #expect(request.url == CodexLimitsProvider.Endpoint.usage)
            #expect(request.httpMethod == "GET")
            #expect(request.timeoutInterval == 5)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token-falso")
            #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "cuenta-falsa")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            return (200, Data(Self.remoteJSON.utf8))
        }
        #expect(await harness.provider().fetch().status == .ok)
    }

    @Test("lee el último token_count válido del rollout")
    func fallbackDesdeRollout() throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        _ = try harness.writeRollout([
            #"{"payload":{"type":"token_count","info":{"rate_limits":{"primary":{"used_percent":10,"window_minutes":300}}}}}"#,
            #"{"payload":{"type":"mensaje","texto":"ignorar"}}"#,
            Self.rolloutLine
        ])
        let snapshot = try #require(CodexLimitsProvider.latestRolloutSnapshot(in: harness.sessionsURL))
        #expect(snapshot.planLabel == "pro")
        #expect(snapshot.windows.map(\.percent) == [31, 72])
    }

    @Test("encuentra el evento al final de una cola acotada")
    func colaAcotada() throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let prefix = String(repeating: #"{"payload":{"type":"otro"}}"# + "\n",
                            count: Int(CodexLimitsProvider.tailByteLimit / 20))
        _ = try harness.writeRollout([prefix, Self.rolloutLine])
        let snapshot = try #require(CodexLimitsProvider.latestRolloutSnapshot(in: harness.sessionsURL))
        #expect(snapshot.windows.first?.percent == 31)
    }

    @Test("un archivo de exactamente el límite conserva la primera línea")
    func archivoExactamenteDelLimite() throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        var data = Data((Self.rolloutLine + "\n").utf8)
        data.append(Data(repeating: UInt8(ascii: " "),
                         count: Int(CodexLimitsProvider.tailByteLimit) - data.count))
        #expect(data.count == Int(CodexLimitsProvider.tailByteLimit))
        _ = try harness.writeRollout(data)
        let snapshot = try #require(CodexLimitsProvider.latestRolloutSnapshot(in: harness.sessionsURL))
        #expect(snapshot.windows.first?.percent == 31)
    }

    @Test("401 y 403 son credenciales inválidas, con o sin rollout local")
    func unauthorized() async throws {
        for code in [401, 403] {
            let harness = try Harness()
            defer { harness.cleanUp() }
            _ = try harness.writeRollout([Self.rolloutLine])
            StubURLProtocol.setHandler { _ in (code, Data()) }
            let snapshot = await harness.provider().fetch()
            // Es un estado definitivo: manda aunque el rollout local tenga ventanas.
            #expect(snapshot.status == .invalidCredentials)
            #expect(snapshot.windows.isEmpty)
        }
    }

    @Test("un 429 activa el backoff y conserva el rollout local si lo hay")
    func rateLimitedConFallback() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        _ = try harness.writeRollout([Self.rolloutLine])
        StubURLProtocol.setHandler { _ in (429, Data()) }
        let snapshot = await harness.provider().fetch()
        #expect(snapshot.status == .failed("Límite de consultas alcanzado"))
        #expect(snapshot.rateLimited)
        #expect(snapshot.windows.count == 2)
    }

    @Test("un 429 sin rollout local queda sin ventanas pero marcado para el backoff")
    func rateLimitedSinFallback() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        StubURLProtocol.setHandler { _ in (429, Data()) }
        let snapshot = await harness.provider().fetch()
        #expect(snapshot.rateLimited)
        #expect(snapshot.windows.isEmpty)
    }

    @Test("red caída y formato remoto desconocido usan fallback")
    func fallosConFallback() async throws {
        for response in ["red", "formato"] {
            let harness = try Harness()
            defer { harness.cleanUp() }
            _ = try harness.writeRollout([Self.rolloutLine])
            StubURLProtocol.setHandler { _ in
                if response == "red" { throw URLError(.notConnectedToInternet) }
                return (200, Data(#"{"desconocido":true}"#.utf8))
            }
            #expect(await harness.provider().fetch().status == .failed("A la última actividad"))
        }
    }

    @Test("formato remoto y local desconocido falla suavemente")
    func formatoDesconocidoSinFallback() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        _ = try harness.writeRollout([#"{"payload":{"type":"otro"}}"#])
        StubURLProtocol.setHandler { _ in (200, Data(#"{"desconocido":true}"#.utf8)) }
        let snapshot = await harness.provider().fetch()
        #expect(snapshot.status == .failed("Respuesta no reconocida"))
        #expect(snapshot.windows.isEmpty)
    }
}
