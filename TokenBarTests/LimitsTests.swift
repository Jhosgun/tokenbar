import Foundation
import SQLite3
import Testing

@testable import TokenBar

@Suite("LimitWindow")
struct LimitWindowTests {

    @Test("el porcentaje se redondea y se acota a 0…100")
    func porcentajeAcotado() {
        #expect(LimitWindow(name: "x", utilization: 0.214).percent == 21)
        #expect(LimitWindow(name: "x", utilization: 0.215).percent == 22)
        #expect(LimitWindow(name: "x", utilization: 0).percent == 0)
        #expect(LimitWindow(name: "x", utilization: 1).percent == 100)
        // El proveedor podría reportar por encima del tope; la barra no debe desbordarse.
        #expect(LimitWindow(name: "x", utilization: 1.4).percent == 100)
        #expect(LimitWindow(name: "x", utilization: -0.2).percent == 0)
    }

    @Test("la severidad cambia en 80% y 95%")
    func severidad() {
        #expect(LimitWindow(name: "x", utilization: 0.79).severity == .normal)
        #expect(LimitWindow(name: "x", utilization: 0.80).severity == .warning)
        #expect(LimitWindow(name: "x", utilization: 0.94).severity == .warning)
        #expect(LimitWindow(name: "x", utilization: 0.95).severity == .critical)
        #expect(LimitWindow(name: "x", utilization: 1.0).severity == .critical)
    }

    @Test("la cuenta regresiva usa horas, minutos y días según la distancia")
    func cuentaRegresiva() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func remaining(_ seconds: TimeInterval) -> String? {
            LimitWindow(name: "x", utilization: 0, resetsAt: now.addingTimeInterval(seconds))
                .timeRemaining(from: now)
        }
        #expect(remaining(4 * 3600 + 15 * 60) == "4h 15m")
        #expect(remaining(12 * 60) == "12m")
        #expect(remaining(50 * 3600) == "2d 2h")
        #expect(remaining(48 * 3600) == "2d")
        // Ya pasó: no se muestran negativos.
        #expect(remaining(-60) == "ahora")
        // Sin fecha de reset no hay texto que mostrar.
        #expect(LimitWindow(name: "x", utilization: 0).timeRemaining(from: now) == nil)
    }

    @Test("worst devuelve la ventana más comprometida")
    func peorVentana() {
        let snapshot = LimitsSnapshot(
            source: .claudeCode,
            windows: [
                LimitWindow(name: "5 horas", utilization: 0.21),
                LimitWindow(name: "Semanal", utilization: 0.87),
                LimitWindow(name: "Opus", utilization: 0.40)
            ],
            planLabel: nil, status: .ok)
        #expect(snapshot.worst?.name == "Semanal")
        #expect(LimitsSnapshot.empty(.cursor, .notConfigured).worst == nil)
    }
}

@Suite("ClaudeLimitsProvider")
struct ClaudeLimitsProviderTests {

    /// Forma real de la respuesta, recortada: buckets en `null` mezclados con los válidos.
    private static let respuestaReal = """
    {"five_hour":{"utilization":21.0,"resets_at":"2026-08-17T09:50:00.414428+00:00",
     "limit_dollars":null},
     "seven_day":{"utilization":40.0,"resets_at":"2026-08-17T16:00:00.414449+00:00"},
     "seven_day_opus":null,"seven_day_sonnet":null,"tangelo":null,
     "extra_usage":{"is_enabled":false,"monthly_limit":10000,"used_credits":0.0}}
    """

    @Test("parsea las ventanas conocidas y convierte el porcentaje a fracción")
    func parseaVentanas() throws {
        let snapshot = try #require(
            ClaudeLimitsProvider.parse(Data(Self.respuestaReal.utf8)))
        #expect(snapshot.source == .claudeCode)
        #expect(snapshot.status == .ok)
        #expect(snapshot.windows.count == 2)
        #expect(snapshot.windows[0].name == "5 horas")
        #expect(abs(snapshot.windows[0].utilization - 0.21) < 0.0001)
        #expect(snapshot.windows[1].name == "Semanal")
        #expect(abs(snapshot.windows[1].utilization - 0.40) < 0.0001)
        #expect(snapshot.windows[0].resetsAt != nil)
    }

    @Test("los buckets en null se omiten en vez de aparecer en cero")
    func omiteBucketsNulos() throws {
        let snapshot = try #require(
            ClaudeLimitsProvider.parse(Data(Self.respuestaReal.utf8)))
        #expect(!snapshot.windows.contains { $0.name == "Opus semanal" })
        #expect(!snapshot.windows.contains { $0.name == "Sonnet semanal" })
    }

    @Test("los créditos extra solo se muestran si están habilitados")
    func creditosDeshabilitados() throws {
        let sinCreditos = try #require(
            ClaudeLimitsProvider.parse(Data(Self.respuestaReal.utf8)))
        #expect(sinCreditos.planLabel == nil)

        let conCreditos = """
        {"five_hour":{"utilization":5.0},
         "extra_usage":{"is_enabled":true,"monthly_limit":10000,"used_credits":250.0}}
        """
        let snapshot = try #require(ClaudeLimitsProvider.parse(Data(conCreditos.utf8)))
        #expect(snapshot.planLabel == "créditos 250/10000")
    }

    @Test("un porcentaje fuera de 0…100 se rechaza en vez de mostrar una cifra imposible")
    func porcentajeFueraDeRango() {
        // -5% o 250% no pueden ser un consumo real: la ventana se omite en vez de
        // acotarse a un valor inventado.
        let negativo = #"{"five_hour":{"utilization":-5.0},"seven_day":{"utilization":40.0}}"#
        let snapshotNegativo = ClaudeLimitsProvider.parse(Data(negativo.utf8))
        #expect(snapshotNegativo?.windows.map(\.name) == ["Semanal"])

        let excesivo = #"{"five_hour":{"utilization":250.0}}"#
        #expect(ClaudeLimitsProvider.parse(Data(excesivo.utf8)) == nil)
    }

    @Test("un crédito extra que no cabe en un Int no revienta la conversión")
    func creditoQueNoCabeEnInt() throws {
        // 10^20 es un Double finito, pero no cabe en un Int (tope ~9.2×10^18).
        let json = """
        {"five_hour":{"utilization":5.0},
         "extra_usage":{"is_enabled":true,"monthly_limit":10000,"used_credits":1e20}}
        """
        let snapshot = try #require(ClaudeLimitsProvider.parse(Data(json.utf8)))
        // La cifra imposible se descarta: no hay etiqueta de créditos, pero la ventana de
        // 5 horas —que no depende de esto— sigue apareciendo.
        #expect(snapshot.planLabel == nil)
        #expect(snapshot.windows.count == 1)
    }

    @Test("una respuesta sin ninguna ventana conocida se rechaza")
    func respuestaSinVentanas() {
        #expect(ClaudeLimitsProvider.parse(Data("{}".utf8)) == nil)
        #expect(ClaudeLimitsProvider.parse(Data("{\"otra_cosa\":1}".utf8)) == nil)
        #expect(ClaudeLimitsProvider.parse(Data("no es json".utf8)) == nil)
    }

    @Test("el token se extrae del JSON de credenciales de Claude Code")
    func extraeToken() {
        let anidado = #"{"claudeAiOauth":{"accessToken":"sk-ant-oat-abc","refreshToken":"x"}}"#
        #expect(ClaudeLimitsProvider.accessToken(from: anidado) == "sk-ant-oat-abc")

        let plano = #"{"access_token":"tok-123"}"#
        #expect(ClaudeLimitsProvider.accessToken(from: plano) == "tok-123")

        // Si no es JSON se asume que ya viene el token pelado.
        #expect(ClaudeLimitsProvider.accessToken(from: "  tok-pelado  ") == "tok-pelado")

        #expect(ClaudeLimitsProvider.accessToken(from: nil) == nil)
        #expect(ClaudeLimitsProvider.accessToken(from: "") == nil)
        #expect(ClaudeLimitsProvider.accessToken(from: #"{"sin":"token"}"#) == nil)
    }
}

@Suite("ClaudeLimitsProvider — caché local")
struct ClaudeLocalCacheTests {

    /// Contador con candado, seguro para capturar en closures @Sendable.
    private final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return storage }
        func increment() { lock.lock(); defer { lock.unlock() }; storage += 1 }
    }

    /// URLProtocol que intercepta y aborta cualquier intento de red: los caminos bajo
    /// prueba no deben tocarla. Si el contador queda en cero, no hubo consulta.
    private final class NeverProtocol: URLProtocol {
        static let calls = LockedCounter()

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            NeverProtocol.calls.increment()
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        }
        override func stopLoading() {}

        static func makeSession() -> URLSession {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [NeverProtocol.self]
            return URLSession(configuration: configuration)
        }
    }

    private func write(_ json: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "claude-cache-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: url)
        return url
    }

    /// Fixture sintética con la forma real: la clave va acompañada de otras ajenas que
    /// no se deben leer (configuración e historial del usuario).
    private static func fixture(fetchedAtMs: UInt64, utilization: String) -> String {
        """
        {"cachedUsageUtilization":{"fetchedAtMs":\(fetchedAtMs),"accountUuid":"sintetico",
         "utilization":\(utilization)},
         "userID":"privado","history":["privado"]}
        """
    }

    private static func ms(_ date: Date) -> UInt64 {
        UInt64(date.timeIntervalSince1970 * 1_000)
    }

    @Test("las cuotas por modelo de limits[] salen como ventanas propias")
    func cuotasPorModelo() throws {
        let now = Date(timeIntervalSince1970: 1_790_544_000)
        let utilization = """
        {"five_hour":{"utilization":9,"resets_at":"2026-09-28T02:29:59.534742+00:00"},
         "seven_day":{"utilization":72,"resets_at":"2026-09-28T15:59:59.534769+00:00"},
         "limits":[{"kind":"session","group":"session","percent":9,"severity":"normal"},
                   {"kind":"weekly_all","group":"weekly","percent":72,"severity":"normal"},
                   {"kind":"weekly_scoped","group":"weekly","percent":100,"severity":"critical",
                    "scope":{"model":{"display_name":"Fable"}}},
                   {"kind":"weekly_scoped","group":"weekly","percent":40,
                    "scope":{"model":{"display_name":"Opus"}}}]}
        """
        let url = try write(Self.fixture(fetchedAtMs: Self.ms(now), utilization: utilization))
        defer { try? FileManager.default.removeItem(at: url) }

        let cached = try #require(ClaudeLimitsProvider.cachedUsage(at: url, now: now))
        #expect(cached.snapshot.windows.map(\.name)
            == ["5 horas", "Semanal", "Fable semanal", "Opus semanal"])
        // `session` y `weekly_all` no se repiten: ya salen como "5 horas" y "Semanal".
        let fable = try #require(cached.snapshot.windows.first { $0.name == "Fable semanal" })
        #expect(fable.percent == 100)
        #expect(fable.severity == .critical)
        // La cuota por modelo acota la ventana semanal, así que hereda su reinicio.
        #expect(fable.resetsAt == cached.snapshot.windows[1].resetsAt)
    }

    @Test("una cuota por modelo sin nombre, o repetida, no agrega ventanas de más")
    func cuotasPorModeloIgnoradas() throws {
        let now = Date(timeIntervalSince1970: 1_790_544_000)
        let utilization = """
        {"five_hour":{"utilization":9,"resets_at":"2026-09-28T02:29:59Z"},
         "limits":[{"kind":"weekly_scoped","percent":50,"scope":{"model":{}}},
                   {"kind":"weekly_scoped","percent":50},
                   {"kind":"weekly_scoped","percent":10,"scope":{"model":{"display_name":"Fable"}}},
                   {"kind":"weekly_scoped","percent":90,"scope":{"model":{"display_name":"Fable"}}}]}
        """
        let url = try write(Self.fixture(fetchedAtMs: Self.ms(now), utilization: utilization))
        defer { try? FileManager.default.removeItem(at: url) }

        let cached = try #require(ClaudeLimitsProvider.cachedUsage(at: url, now: now))
        #expect(cached.snapshot.windows.map(\.name) == ["5 horas", "Fable semanal"])
        // De las dos entradas de Fable se conserva la primera; sin `seven_day` no hay reinicio.
        #expect(cached.snapshot.windows[1].percent == 10)
        #expect(cached.snapshot.windows[1].resetsAt == nil)
    }

    @Test("mapea five_hour y seven_day con escala 0…100 y fechas con microsegundos y offset")
    func mapeaVentanas() throws {
        let now = Date(timeIntervalSince1970: 1_790_544_000)
        let utilization = """
        {"five_hour":{"utilization":21.0,"resets_at":"2026-09-28T02:30:00.124848+00:00",
                      "limit_dollars":null,"used_dollars":null},
         "seven_day":{"utilization":71,"resets_at":"2026-09-28T16:00:00.124874+00:00"},
         "seven_day_opus":{"utilization":5.5,"resets_at":"2026-09-28T16:00:00+00:00"}}
        """
        let url = try write(Self.fixture(fetchedAtMs: Self.ms(now), utilization: utilization))
        defer { try? FileManager.default.removeItem(at: url) }

        let cached = try #require(ClaudeLimitsProvider.cachedUsage(at: url, now: now))
        #expect(cached.age == 0)
        #expect(cached.snapshot.status == .ok)
        #expect(cached.snapshot.windows.map(\.name) == ["5 horas", "Semanal", "Opus semanal"])
        // La escala original es 0…100 y queda normalizada a fracción.
        #expect(abs(cached.snapshot.windows[0].utilization - 0.21) < 0.0001)
        #expect(abs(cached.snapshot.windows[1].utilization - 0.71) < 0.0001)
        // Con microsegundos y offset explícito.
        let reset5h = try #require(cached.snapshot.windows[0].resetsAt)
        let resetSemanal = try #require(cached.snapshot.windows[1].resetsAt)
        #expect(abs(reset5h.timeIntervalSince1970 - 1_790_562_600.124848) < 0.001)
        #expect(abs(resetSemanal.timeIntervalSince1970 - 1_790_611_200.124874) < 0.001)
        // Sin fracciones de segundo también parsea.
        #expect(cached.snapshot.windows[2].resetsAt != nil)
    }

    @Test("las claves con utilization null se omiten, y las desconocidas también")
    func omiteNulosYDesconocidas() throws {
        let now = Date(timeIntervalSince1970: 1_790_544_000)
        let utilization = """
        {"five_hour":{"utilization":0,"resets_at":null},
         "seven_day":null,
         "seven_day_sonnet":{"utilization":null,"resets_at":null},
         "nimbus_quill":{"utilization":0,"resets_at":null},
         "tangelo":null}
        """
        let url = try write(Self.fixture(fetchedAtMs: Self.ms(now), utilization: utilization))
        defer { try? FileManager.default.removeItem(at: url) }

        let cached = try #require(ClaudeLimitsProvider.cachedUsage(at: url, now: now))
        // `nimbus_quill` trae valor pero no es una ventana conocida: tampoco se inventa.
        #expect(cached.snapshot.windows.map(\.name) == ["5 horas"])
    }

    @Test("seven_day_opus y seven_day_sonnet se muestran cuando están")
    func muestraOpusYSonnet() throws {
        let now = Date(timeIntervalSince1970: 1_790_544_000)
        let utilization = """
        {"five_hour":{"utilization":10.0},
         "seven_day":{"utilization":20.0},
         "seven_day_opus":{"utilization":30.0,"resets_at":"2026-09-28T16:00:00.124874+00:00"},
         "seven_day_sonnet":{"utilization":40.0}}
        """
        let url = try write(Self.fixture(fetchedAtMs: Self.ms(now), utilization: utilization))
        defer { try? FileManager.default.removeItem(at: url) }

        let cached = try #require(ClaudeLimitsProvider.cachedUsage(at: url, now: now))
        #expect(cached.snapshot.windows.map(\.name)
            == ["5 horas", "Semanal", "Opus semanal", "Sonnet semanal"])
        #expect(abs(cached.snapshot.windows[3].utilization - 0.40) < 0.0001)
    }

    @Test("fetchedAtMs con más de 30 min marca el dato desactualizado, no lo oculta")
    func marcaDesactualizado() throws {
        let now = Date(timeIntervalSince1970: 1_790_544_000)
        let utilization = #"{"five_hour":{"utilization":21.0},"seven_day":{"utilization":71}}"#

        let reciente = try write(Self.fixture(fetchedAtMs: Self.ms(now.addingTimeInterval(-29 * 60)),
                                              utilization: utilization))
        defer { try? FileManager.default.removeItem(at: reciente) }
        let cachedReciente = try #require(ClaudeLimitsProvider.cachedUsage(at: reciente, now: now))
        #expect(cachedReciente.snapshot.status == .ok)

        let viejo47 = try write(Self.fixture(fetchedAtMs: Self.ms(now.addingTimeInterval(-47 * 60)),
                                             utilization: utilization))
        defer { try? FileManager.default.removeItem(at: viejo47) }
        let cached47 = try #require(ClaudeLimitsProvider.cachedUsage(at: viejo47, now: now))
        #expect(cached47.snapshot.status == .failed("hace 47m"))
        #expect(cached47.snapshot.windows.count == 2)
        #expect(abs(cached47.age - 47 * 60) < 1)

        let viejo2h = try write(Self.fixture(fetchedAtMs: Self.ms(now.addingTimeInterval(-(2 * 3600 + 5 * 60))),
                                             utilization: utilization))
        defer { try? FileManager.default.removeItem(at: viejo2h) }
        let cached2h = try #require(ClaudeLimitsProvider.cachedUsage(at: viejo2h, now: now))
        #expect(cached2h.snapshot.status == .failed("hace 2h 5m"))
    }

    @Test("archivo ausente, corrupto o sin la clave devuelve nil, y fetch reporta error sin crashear")
    func archivoProblematico() async throws {
        let now = Date(timeIntervalSince1970: 1_790_544_000)
        let inexistente = FileManager.default.temporaryDirectory
            .appending(path: "no-existe-\(UUID().uuidString).json")
        #expect(ClaudeLimitsProvider.cachedUsage(at: inexistente, now: now) == nil)

        let corrupto = try write("{no es json")
        defer { try? FileManager.default.removeItem(at: corrupto) }
        #expect(ClaudeLimitsProvider.cachedUsage(at: corrupto, now: now) == nil)

        let sinClave = try write(#"{"otraCosa":1}"#)
        defer { try? FileManager.default.removeItem(at: sinClave) }
        #expect(ClaudeLimitsProvider.cachedUsage(at: sinClave, now: now) == nil)

        // Sin caché usable ni token, fetch reporta un estado de error y no toca la red.
        let session = NeverProtocol.makeSession()
        let provider = ClaudeLimitsProvider(cacheURL: corrupto,
                                            session: session,
                                            tokenCache: KeychainTokenCache(read: { nil }),
                                            userAgent: "claude-code/test")
        let snapshot = await provider.fetch()
        #expect(snapshot.status == .notConfigured)
        #expect(snapshot.windows.isEmpty)
        #expect(NeverProtocol.calls.value == 0)
    }

    @Test("con caché fresca fetch no toca la red ni el llavero")
    func cacheFrescaNoTocaRed() async throws {
        let utilization = #"{"five_hour":{"utilization":21.0},"seven_day":{"utilization":71}}"#
        let url = try write(Self.fixture(fetchedAtMs: Self.ms(Date()), utilization: utilization))
        defer { try? FileManager.default.removeItem(at: url) }

        let keychainReads = LockedCounter()
        let session = NeverProtocol.makeSession()
        let provider = ClaudeLimitsProvider(
            cacheURL: url,
            session: session,
            tokenCache: KeychainTokenCache(read: { keychainReads.increment(); return "tok" }),
            userAgent: "claude-code/test")
        let snapshot = await provider.fetch()
        #expect(snapshot.status == .ok)
        #expect(snapshot.windows.count == 2)
        #expect(keychainReads.value == 0)
        #expect(NeverProtocol.calls.value == 0)
    }

    @Test("caché entre 30 min y 2 h se muestra marcada sin ir a la red")
    func cacheMarcadaSinRed() async throws {
        let utilization = #"{"five_hour":{"utilization":21.0},"seven_day":{"utilization":71}}"#
        let vieja47 = try write(Self.fixture(fetchedAtMs: Self.ms(Date().addingTimeInterval(-47 * 60)),
                                             utilization: utilization))
        defer { try? FileManager.default.removeItem(at: vieja47) }

        let session = NeverProtocol.makeSession()
        let provider = ClaudeLimitsProvider(cacheURL: vieja47,
                                            session: session,
                                            tokenCache: KeychainTokenCache(read: { nil }),
                                            userAgent: "claude-code/test")
        let snapshot = await provider.fetch()
        #expect(snapshot.status == .failed("hace 47m"))
        #expect(snapshot.windows.count == 2)
        #expect(NeverProtocol.calls.value == 0)
    }

    /// URLProtocol que responde siempre con un código fijo, para simular un 401/403 de red.
    private final class FixedStatusProtocol: URLProtocol {
        nonisolated(unsafe) static var statusCode = 401
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let response = HTTPURLResponse(url: request.url!, statusCode: Self.statusCode,
                                           httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data())
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}

        static func makeSession() -> URLSession {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [FixedStatusProtocol.self]
            return URLSession(configuration: configuration)
        }
    }

    @Test("un token rechazado por la red manda sobre la caché vieja, aunque tenga ventanas")
    func credencialInvalidaMandaSobreCache() async throws {
        let utilization = #"{"five_hour":{"utilization":21.0},"seven_day":{"utilization":71}}"#
        let vieja3h = try write(Self.fixture(fetchedAtMs: Self.ms(Date().addingTimeInterval(-3 * 3600)),
                                             utilization: utilization))
        defer { try? FileManager.default.removeItem(at: vieja3h) }

        FixedStatusProtocol.statusCode = 401
        let provider = ClaudeLimitsProvider(
            cacheURL: vieja3h,
            session: FixedStatusProtocol.makeSession(),
            tokenCache: KeychainTokenCache(read: { "tok" }),
            userAgent: "claude-code/test")
        let snapshot = await provider.fetch()
        // Antes de este arreglo, esto devolvía la caché de 3 h marcada "hace 3h" en vez de
        // avisar que hay que volver a iniciar sesión.
        #expect(snapshot.status == .invalidCredentials)
        #expect(snapshot.windows.isEmpty)
    }

    @Test("caché de más de 2 h intenta la red; sin token se muestra la caché marcada")
    func cacheViejaSinToken() async throws {
        let utilization = #"{"five_hour":{"utilization":21.0},"seven_day":{"utilization":71}}"#
        let vieja3h = try write(Self.fixture(fetchedAtMs: Self.ms(Date().addingTimeInterval(-3 * 3600)),
                                             utilization: utilization))
        defer { try? FileManager.default.removeItem(at: vieja3h) }

        let keychainReads = LockedCounter()
        let session = NeverProtocol.makeSession()
        let provider = ClaudeLimitsProvider(
            cacheURL: vieja3h,
            session: session,
            tokenCache: KeychainTokenCache(read: { keychainReads.increment(); return nil }),
            userAgent: "claude-code/test")
        let snapshot = await provider.fetch()
        // Sin token no hay consulta posible; la caché vieja se muestra con su marca.
        #expect(snapshot.status == .failed("hace 3h"))
        #expect(snapshot.windows.count == 2)
        #expect(keychainReads.value == 1)
        #expect(NeverProtocol.calls.value == 0)
    }

    @Test("la válvula deja pasar la red solo una vez cada 15 min")
    func valvulaDeRed() async {
        let throttle = ClaudeLimitsProvider.NetworkThrottle(interval: 15 * 60)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        #expect(await throttle.tryAttempt(now: t0))
        #expect(await !throttle.tryAttempt(now: t0.addingTimeInterval(14 * 60)))
        #expect(await throttle.tryAttempt(now: t0.addingTimeInterval(15 * 60)))
    }

    @Test("el User-Agent es el del CLI de Claude Code")
    func userAgentDelCLI() {
        #expect(ClaudeLimitsProvider.userAgent(cliVersion: "2.1.283") == "claude-code/2.1.283")
        #expect(ClaudeLimitsProvider.versionFromLinkDestination(
            "/Users/j/.local/share/claude/versions/2.1.283") == "2.1.283")
        #expect(ClaudeLimitsProvider.versionFromLinkDestination("../versions/2.0.31") == "2.0.31")
        #expect(ClaudeLimitsProvider.versionFromLinkDestination("/usr/local/bin/claude") == nil)
        #expect(ClaudeLimitsProvider.versionFromLinkDestination(nil) == nil)
        // El detectado en este Mac (o el default) siempre lleva el prefijo del CLI.
        #expect(ClaudeLimitsProvider.userAgent().hasPrefix("claude-code/"))
    }
}

@Suite("CursorLimitsProvider", .serialized)
struct CursorLimitsProviderTests {
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
        let session: URLSession

        init(withCredential: Bool = true) throws {
            root = FileManager.default.temporaryDirectory
                .appending(path: "cursor-limits-\(UUID().uuidString)", directoryHint: .isDirectory)
            databaseURL = root.appending(path: "state.vscdb")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if withCredential {
                try Self.writeDatabase(at: databaseURL, token: CursorLimitsProviderTests.jwt(
                    sub: "google-oauth2|user_prueba", exp: 9_999_999_999))
            }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [StubURLProtocol.self]
            session = URLSession(configuration: configuration)
        }

        func provider() -> CursorLimitsProvider {
            CursorLimitsProvider(databaseURL: databaseURL, session: session)
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

    private static let summary = """
    {"billingCycleStart":"2026-09-07T02:26:43.000Z",
     "billingCycleEnd":"2026-10-07T02:26:43.000Z",
     "membershipType":"pro_plus",
     "individualUsage":{
       "plan":{"enabled":true,"used":7000,"limit":7000,"remaining":0,
               "totalPercentUsed":66.54809160305344,
               "breakdown":{"included":7000,"bonus":80178,"total":87178}},
       "onDemand":{"enabled":false,"used":0,"limit":null,"remaining":null}}}
    """

    private static func jwt(sub: String, exp: TimeInterval) -> String {
        func segment(_ object: [String: Any]) -> String {
            let data = try! JSONSerialization.data(withJSONObject: object)
            return data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(segment(["alg": "HS256"])).\(segment(["sub": sub, "exp": exp])).firma"
    }

    @Test("parsea la cuota real del ciclo, el plan y el reset")
    func parseaResumen() throws {
        let summary = try #require(CursorLimitsProvider.parseSummary(Data(Self.summary.utf8)))
        #expect(summary.planLabel == "pro_plus")
        #expect(abs(try #require(summary.utilization) - 0.6654809160305344) < 0.0001)
        #expect(summary.resetsAt == Date(timeIntervalSince1970: 1_791_340_003))
        #expect(summary.extraWindows.isEmpty)
    }

    @Test("Auto y Modelos con nombre aparecen como ventanas propias junto al ciclo")
    func autoYModelosConNombre() throws {
        let json = """
        {"billingCycleEnd":"2026-10-07T02:26:43Z","membershipType":"pro_plus",
         "individualUsage":{"plan":{"totalPercentUsed":66.5,"autoPercentUsed":66.4,
                                    "apiPercentUsed":67.9}}}
        """
        let summary = try #require(CursorLimitsProvider.parseSummary(Data(json.utf8)))
        #expect(summary.utilization == 0.665)
        #expect(summary.extraWindows.map(\.name) == ["Auto", "Modelos con nombre"])
        #expect(summary.extraWindows[0].percent == 66)
        #expect(summary.extraWindows[1].percent == 68)
    }

    @Test("sin autoPercentUsed ni apiPercentUsed no hay ventanas extra")
    func sinAutoNiApi() throws {
        let summary = try #require(CursorLimitsProvider.parseSummary(Data(Self.summary.utf8)))
        #expect(summary.extraWindows.isEmpty)
    }

    @Test("muestra bajo demanda solo cuando tiene un tope explícito")
    func bajoDemanda() throws {
        let json = """
        {"billingCycleEnd":"2026-10-07T02:26:43Z","membershipType":"ultra",
         "individualUsage":{"plan":{"used":25,"remaining":75},
         "overall":{"enabled":true,"used":20,"limit":100,"remaining":80}}}
        """
        let summary = try #require(CursorLimitsProvider.parseSummary(Data(json.utf8)))
        #expect(summary.utilization == 0.25)
        #expect(summary.extraWindows.map(\.name) == ["Bajo demanda"])
        #expect(summary.extraWindows.first?.percent == 20)
    }

    @Test("un resumen sin porcentaje falla sin hacer una segunda petición")
    func periodoActual() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let summarySinPorcentaje = """
        {"billingCycleEnd":"2026-10-07T02:26:43Z","membershipType":"pro",
         "individualUsage":{"plan":{"enabled":true}}}
        """
        var paths: [String] = []
        StubURLProtocol.setHandler { request in
            paths.append(request.url!.path)
            #expect(request.url == CursorLimitsProvider.Endpoint.usageSummary)
            return (200, Data(summarySinPorcentaje.utf8))
        }
        let snapshot = await harness.provider().fetch()
        #expect(snapshot.status == .failed("Respuesta no reconocida"))
        #expect(snapshot.windows.isEmpty)
        #expect(paths == ["/api/usage-summary"])
    }

    @Test("el resumen completo evita la segunda petición y construye la cookie")
    func requestPrincipal() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        var requests = 0
        StubURLProtocol.setHandler { request in
            requests += 1
            #expect(request.url == CursorLimitsProvider.Endpoint.usageSummary)
            #expect(request.httpMethod == "GET")
            #expect(request.timeoutInterval == 5)
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            #expect(request.value(forHTTPHeaderField: "User-Agent") == CursorLimitsProvider.Endpoint.userAgent)
            let cookie = try #require(request.value(forHTTPHeaderField: "Cookie"))
            #expect(cookie.hasPrefix("WorkosCursorSessionToken=google%2Doauth2%7Cuser%5Fprueba%3A%3A"))
            #expect(!cookie.contains("|"))
            return (200, Data(Self.summary.utf8))
        }
        let snapshot = await harness.provider().fetch()
        #expect(snapshot.status == .ok)
        #expect(snapshot.planLabel == "pro_plus")
        #expect(snapshot.windows.map(\.name) == ["Ciclo"])
        #expect(requests == 1)
    }

    @Test("sin credencial queda no configurado y no hace red")
    func credencialAusente() async throws {
        let harness = try Harness(withCredential: false)
        defer { harness.cleanUp() }
        StubURLProtocol.setHandler { _ in
            Issue.record("No debía hacer una petición")
            return (500, Data())
        }
        let snapshot = await harness.provider().fetch()
        #expect(snapshot.status == .notConfigured)
        #expect(snapshot.windows.isEmpty)
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

    @Test("un 429 activa el backoff del ViewModel, no un .failed pelado")
    func rateLimited() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        StubURLProtocol.setHandler { _ in (429, Data()) }
        let snapshot = await harness.provider().fetch()
        #expect(snapshot.rateLimited)
        #expect(snapshot.status == .failed("Límite de consultas alcanzado"))
        #expect(snapshot.windows.isEmpty)
    }

    @Test("formatos desconocidos fallan sin inventar cifras")
    func formatoDesconocido() async throws {
        for body in ["no es json", "{}", #"{"membershipType":"pro"}"#,
                     #"{"billingCycleEnd":"mal","membershipType":"pro","individualUsage":{}}"#] {
            #expect(CursorLimitsProvider.parseSummary(Data(body.utf8)) == nil)
        }

        let harness = try Harness()
        defer { harness.cleanUp() }
        StubURLProtocol.setHandler { _ in (200, Data(#"{"desconocido":true}"#.utf8)) }
        let snapshot = await harness.provider().fetch()
        #expect(snapshot.status == .failed("Respuesta no reconocida"))
        #expect(snapshot.windows.isEmpty)
    }

    @Test("saca el subject, detecta expiración y escapa la cookie")
    func credencial() {
        let token = Self.jwt(sub: "google-oauth2|user_01ABC", exp: 2_000_000)
        #expect(CursorLimitsProvider.subject(fromJWT: token) == "google-oauth2|user_01ABC")
        #expect(CursorLimitsProvider.subject(fromJWT: "no-es-un-jwt") == nil)
        #expect(CursorLimitsProvider.isExpired(token,
                                               now: Date(timeIntervalSince1970: 1_000_000)) == false)
        #expect(CursorLimitsProvider.isExpired(token,
                                               now: Date(timeIntervalSince1970: 3_000_000)) == true)
        let header = CursorLimitsProvider.cookieHeader(subject: "google-oauth2|user_01",
                                                        token: "abc.def.ghi")
        #expect(header == "WorkosCursorSessionToken=google%2Doauth2%7Cuser%5F01%3A%3Aabc.def.ghi")
    }

    @Test("un token sin exp se considera vigente")
    func credencialSinExp() {
        #expect(CursorLimitsProvider.isExpired("no-es-un-jwt") == false)
    }
}

@Suite("KeychainTokenCache")
struct KeychainTokenCacheTests {

    /// Contador de lecturas seguro para concurrencia.
    private actor Counter {
        private(set) var value = 0
        func increment() { value += 1 }
    }

    @Test("el llavero se consulta una sola vez aunque se pida el token muchas veces")
    func leeUnaSolaVez() async {
        let counter = Counter()
        let cache = KeychainTokenCache(read: {
            Task { await counter.increment() }
            return "tok"
        })
        // Simula 10 ciclos de refresco.
        for _ in 0..<10 {
            #expect(await cache.token() == "tok")
        }
        // Da tiempo a que los Task del contador terminen.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await counter.value == 1)
    }

    @Test("un 'no hay token' también se recuerda: no se reintenta en cada ciclo")
    func recuerdaLaAusencia() async {
        let counter = Counter()
        let cache = KeychainTokenCache(read: {
            Task { await counter.increment() }
            return nil
        })
        for _ in 0..<5 {
            #expect(await cache.token() == nil)
        }
        try? await Task.sleep(for: .milliseconds(50))
        // Si esto fuera > 1, el usuario vería un diálogo de llavero cada 30 segundos.
        #expect(await counter.value == 1)
    }

    @Test("invalidate fuerza una relectura, para cuando el token se rotó")
    func invalidateRelee() async {
        let counter = Counter()
        let cache = KeychainTokenCache(read: {
            Task { await counter.increment() }
            return "tok"
        })
        _ = await cache.token()
        _ = await cache.token()
        await cache.invalidate()
        _ = await cache.token()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await counter.value == 2)
    }
}
