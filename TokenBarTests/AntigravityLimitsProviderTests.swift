import Foundation
import Testing

@testable import TokenBar

@Suite("AntigravityLimitsProvider", .serialized)
struct AntigravityLimitsProviderTests {

    /// Salida real de `agy -p /usage` en este Mac (2026-09-27), con la cuota intacta.
    private static let salidaReal = """
    Gemini Models\tWeekly Limit Remaining\t100%\t2026-10-04T23:18:52Z
    Gemini Models\tFive Hour Limit Remaining\t100%\t2026-09-28T04:18:52Z
    Claude and GPT models\tWeekly Limit Remaining\t100%\t2026-10-04T23:18:52Z
    Claude and GPT models\tFive Hour Limit Remaining\t100%\t2026-09-28T04:18:52Z
    """

    private typealias CLIOutput = AntigravityLimitsProvider.CLIOutput

    private static func output(_ stdout: String,
                                stderr: String = "",
                                exitCode: Int32? = 0,
                                timedOut: Bool = false) -> CLIOutput {
        CLIOutput(stdout: stdout, stderr: stderr, exitCode: exitCode, timedOut: timedOut)
    }

    private static func salida(restanteGemini5h: Int = 100,
                               reset5h: Date,
                               resetSemanal: Date) -> String {
        let formatter = ISO8601DateFormatter()
        return """
        Gemini Models\tWeekly Limit Remaining\t100%\t\(formatter.string(from: resetSemanal))
        Gemini Models\tFive Hour Limit Remaining\t\(restanteGemini5h)%\t\(formatter.string(from: reset5h))
        Claude and GPT models\tWeekly Limit Remaining\t100%\t\(formatter.string(from: resetSemanal))
        Claude and GPT models\tFive Hour Limit Remaining\t100%\t\(formatter.string(from: reset5h))
        """
    }

    /// Contador con candado, seguro para capturar en closures @Sendable.
    private final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return storage }
        func increment() { lock.lock(); defer { lock.unlock() }; storage += 1 }
    }

    /// Bandera con candado, para que el runner inyectado cambie de comportamiento a mitad.
    private final class LockedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = false
        var value: Bool { lock.lock(); defer { lock.unlock() }; return storage }
        func set(_ newValue: Bool) { lock.lock(); defer { lock.unlock() }; storage = newValue }
    }

    private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
        struct Reply: Sendable {
            var status: Int
            var body = Data()
        }

        private static let lock = NSLock()
        nonisolated(unsafe) private static var replies: [Reply] = []
        nonisolated(unsafe) private static var requestsStorage: [URLRequest] = []
        nonisolated(unsafe) private static var bodiesStorage: [Data] = []

        static func configure(_ replies: [Reply]) {
            lock.lock()
            self.replies = replies
            requestsStorage = []
            bodiesStorage = []
            lock.unlock()
        }

        static var requests: [URLRequest] {
            lock.lock()
            defer { lock.unlock() }
            return requestsStorage
        }

        static var bodies: [Data] {
            lock.lock()
            defer { lock.unlock() }
            return bodiesStorage
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let body: Data
            if let httpBody = request.httpBody {
                body = httpBody
            } else if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var collected = Data()
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1_024)
                defer { buffer.deallocate() }
                while stream.hasBytesAvailable {
                    let count = stream.read(buffer, maxLength: 1_024)
                    guard count > 0 else { break }
                    collected.append(buffer, count: count)
                }
                body = collected
            } else {
                body = Data()
            }
            Self.lock.lock()
            Self.requestsStorage.append(request)
            Self.bodiesStorage.append(body)
            let reply = Self.replies.isEmpty ? Reply(status: 500) : Self.replies.removeFirst()
            Self.lock.unlock()
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status,
                                           httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.body)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private static let endpointResponse = Data(#"{"groups":[{"displayName":"Gemini Models","buckets":[{"displayName":"Weekly Limit Remaining","resetTime":"2030-01-08T00:00:00Z","remainingFraction":1},{"displayName":"Five Hour Limit Remaining","resetTime":"2030-01-01T05:00:00Z","remainingFraction":0.37}]},{"displayName":"Claude and GPT models","buckets":[{"displayName":"Weekly Limit Remaining","resetTime":"2030-01-08T00:00:00Z","remainingFraction":0.8},{"displayName":"Five Hour Limit Remaining","resetTime":"2030-01-01T05:00:00Z","remainingFraction":0.6}]}]}"#.utf8)

    /// Ruta a un ejecutable real que nunca se lanza: el runner va inyectado.
    private static let binarioFalso = URL(fileURLWithPath: "/bin/ls")

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func keychainCredential(token: String = "token-sintetico",
                                           expiry: String = "2030-01-01T12:00:00.123456-05:00") -> KeychainCredentialReadResult {
        let json = #"{"token":{"access_token":"\#(token)","expiry":"\#(expiry)"},"auth_method":"consumer"}"#
        return .credential("go-keyring-base64:\(Data(json.utf8).base64EncodedString())")
    }

    // MARK: - Parsing

    @Test("parsea las 4 líneas reales: restante 100% → utilización 0 y fechas exactas")
    func parseaSalidaReal() throws {
        let snapshot = try #require(AntigravityLimitsProvider.parse(Self.salidaReal))
        #expect(snapshot.source == .antigravity)
        #expect(snapshot.status == .ok)
        #expect(snapshot.planLabel == nil)
        // Las de 5 horas van primero: la fila plegada muestra la primera.
        #expect(snapshot.windows.map(\.name)
            == ["Gemini 5 horas", "Claude/GPT 5 horas", "Gemini semanal", "Claude/GPT semanal"])
        // 100% restante → nada usado.
        #expect(snapshot.windows.allSatisfy { $0.utilization == 0 })
        #expect(snapshot.windows[0].resetsAt == Date(timeIntervalSince1970: 1_790_569_132))
        #expect(snapshot.windows[1].resetsAt == Date(timeIntervalSince1970: 1_790_569_132))
        #expect(snapshot.windows[2].resetsAt == Date(timeIntervalSince1970: 1_791_155_932))
        #expect(snapshot.windows[3].resetsAt == Date(timeIntervalSince1970: 1_791_155_932))
    }

    @Test("la utilización es 1 - restante/100, y el restante se acota a 0…100")
    func porcentajeInvertido() throws {
        let a45 = try #require(AntigravityLimitsProvider.parse(
            "Gemini Models\tFive Hour Limit Remaining\t45%\t2026-09-28T04:18:52Z"))
        #expect(abs(a45.windows[0].utilization - 0.55) < 0.0001)

        // 0% restante = ventana agotada.
        let agotada = try #require(AntigravityLimitsProvider.parse(
            "Gemini Models\tFive Hour Limit Remaining\t0%\t2026-09-28T04:18:52Z"))
        #expect(agotada.windows[0].utilization == 1)

        // Por encima de 100 es un dato imposible (nadie tiene un "130% restante"): se
        // rechaza en vez de acotarse a un 0% usado inventado.
        #expect(AntigravityLimitsProvider.parse(
            "Gemini Models\tFive Hour Limit Remaining\t130%\t2026-10-04T23:18:52Z") == nil)
    }

    @Test("tolera líneas de más, desconocidas o repetidas, y una fecha ilegible no tira la línea")
    func tolerancia() throws {
        let salida = """
        basura sin tabs
        Otro grupo\tWeekly Limit Remaining\t50%\t2026-10-04T23:18:52Z
        Gemini Models\tVentana rara\t50%\t2026-10-04T23:18:52Z
        Gemini Models\tWeekly Limit Remaining\t80%\tno-es-fecha
        Gemini Models\tWeekly Limit Remaining\t10%\t2099-01-01T00:00:00Z
        """
        let snapshot = try #require(AntigravityLimitsProvider.parse(salida))
        // Solo la línea conocida cuenta; la repetida no pisa a la primera.
        #expect(snapshot.windows.map(\.name) == ["Gemini semanal"])
        #expect(abs(snapshot.windows[0].utilization - 0.2) < 0.0001)
        #expect(snapshot.windows[0].resetsAt == nil)
    }

    @Test("salida vacía, basura o porcentaje mal formado no producen ninguna ventana")
    func parseRechaza() {
        #expect(AntigravityLimitsProvider.parse("") == nil)
        #expect(AntigravityLimitsProvider.parse("no es la salida del cli") == nil)
        #expect(AntigravityLimitsProvider.parse(
            "Gemini Models\tWeekly Limit Remaining\tcien%\t2026-10-04T23:18:52Z") == nil)

        // Un porcentaje malo ignora su línea pero no tira las buenas.
        let mixta = """
        Gemini Models\tWeekly Limit Remaining\tXX%\t2026-10-04T23:18:52Z
        Gemini Models\tFive Hour Limit Remaining\t45%\t2026-09-28T04:18:52Z
        """
        #expect(AntigravityLimitsProvider.parse(mixta)?.windows.map(\.name) == ["Gemini 5 horas"])
    }

    // MARK: - Interpretación de la salida cruda

    @Test("acepta 100% con resets relativos como cuota real")
    func cuotaRealSinUso() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let stdout = Self.salida(reset5h: now.addingTimeInterval(5 * 60 * 60),
                                  resetSemanal: now.addingTimeInterval(7 * 24 * 60 * 60))
        let snapshot = AntigravityLimitsProvider.snapshot(from: Self.output(stdout), now: now)
        #expect(snapshot.status == .ok)
        #expect(snapshot.windows.count == 4)
        #expect(snapshot.windows.allSatisfy { $0.utilization == 0 })
    }

    @Test("decodifica la credencial base64 y su expiry con fracciones y offset")
    func decodificaCredencial() throws {
        let credential = try #require(AntigravityLimitsProvider.credential(
            from: Self.keychainCredential(token: "token-sintetico-123")))
        #expect(credential.accessToken == "token-sintetico-123")
        #expect(credential.expiresAt == AntigravityLimitsProvider.resetDate(
            "2030-01-01T12:00:00.123456-05:00"))
        #expect(AntigravityLimitsProvider.credential(from: "sin-prefijo") == nil)
    }

    @Test("el endpoint mapea las cuatro ventanas y construye el POST esperado")
    func endpointDirecto() async throws {
        StubURLProtocol.configure([.init(status: 200, body: Self.endpointResponse)])
        let ejecuciones = LockedCounter()
        let provider = AntigravityLimitsProvider(candidates: [Self.binarioFalso], session: session(),
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            credentialRead: { Self.keychainCredential() }) { _ in
                ejecuciones.increment()
                return Self.output(Self.salidaReal)
            }

        let snapshot = await provider.fetch()
        #expect(snapshot.status == .ok)
        #expect(snapshot.windows.map(\.name)
            == ["Gemini 5 horas", "Claude/GPT 5 horas", "Gemini semanal", "Claude/GPT semanal"])
        #expect(abs(snapshot.windows[0].utilization - 0.63) < 0.0001)
        #expect(abs(snapshot.windows[1].utilization - 0.4) < 0.0001)
        #expect(snapshot.windows[2].utilization == 0)
        #expect(abs(snapshot.windows[3].utilization - 0.2) < 0.0001)
        #expect(ejecuciones.value == 0)

        let request = try #require(StubURLProtocol.requests.first)
        #expect(request.url == AntigravityLimitsProvider.Endpoint.quota)
        #expect(request.httpMethod == "POST")
        #expect(request.timeoutInterval == 5)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token-sintetico")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(StubURLProtocol.bodies.first == Data("{}".utf8))
    }

    @Test("remainingFraction ausente falla sin ejecutar el CLI")
    func fraccionAusente() async {
        let response = Data(#"{"groups":[{"displayName":"Gemini Models","buckets":[{"displayName":"Five Hour Limit Remaining","resetTime":"2030-01-01T05:00:00Z"}]}]}"#.utf8)
        StubURLProtocol.configure([.init(status: 200, body: response)])
        let ejecuciones = LockedCounter()
        let provider = AntigravityLimitsProvider(candidates: [Self.binarioFalso], session: session(),
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            credentialRead: { Self.keychainCredential() }) { _ in
                ejecuciones.increment()
                return Self.output(Self.salidaReal)
            }

        #expect(await provider.fetch().status == .failed("Respuesta no reconocida"))
        #expect(ejecuciones.value == 0)
    }

    @Test("un token vencido usa el CLI sin hacer red")
    func tokenVencidoUsaCLI() async {
        StubURLProtocol.configure([])
        let ejecuciones = LockedCounter()
        let provider = AntigravityLimitsProvider(candidates: [Self.binarioFalso], session: session(),
            now: { AntigravityLimitsProvider.resetDate("2026-10-07T12:00:00Z")! },
            credentialRead: { Self.keychainCredential(expiry: "2026-10-07T12:00:30Z") }) { _ in
                ejecuciones.increment()
                return Self.output(Self.salidaReal)
            }

        #expect(await provider.fetch().status == .ok)
        #expect(StubURLProtocol.requests.isEmpty)
        #expect(ejecuciones.value == 1)
    }

    @Test("401 y 403 usan el CLI como respaldo")
    func rechazoUsaCLI() async {
        for status in [401, 403] {
            StubURLProtocol.configure([.init(status: status)])
            let ejecuciones = LockedCounter()
            let provider = AntigravityLimitsProvider(candidates: [Self.binarioFalso], session: session(),
                now: { Date(timeIntervalSince1970: 1_800_000_000) },
                credentialRead: { Self.keychainCredential() }) { _ in
                    ejecuciones.increment()
                    return Self.output(Self.salidaReal)
                }

            #expect(await provider.fetch().status == .ok)
            #expect(StubURLProtocol.requests.count == 1)
            #expect(ejecuciones.value == 1)
        }
    }

    @Test("salidas problemáticas reportan error sin crashear")
    func salidasProblematicas() {
        for stdout in ["", "basura",
                       "Gemini Models\tWeekly Limit Remaining\tXX%\t2026-10-04T23:18:52Z"] {
            let snapshot = AntigravityLimitsProvider.snapshot(from: Self.output(stdout))
            #expect(snapshot.status == .failed("Respuesta no reconocida"))
            #expect(snapshot.windows.isEmpty)
        }

        let conError = AntigravityLimitsProvider.snapshot(from: Self.output("basura", exitCode: 1))
        #expect(conError.status == .failed("agy falló (código 1)"))

        let timeout = AntigravityLimitsProvider.snapshot(from: Self.output("", exitCode: nil,
                                                                           timedOut: true))
        #expect(timeout.status == .failed("El CLI no respondió"))

        let sinLanzar = AntigravityLimitsProvider.snapshot(from: Self.output("", exitCode: nil))
        #expect(sinLanzar.status == .failed("No se pudo ejecutar agy"))
    }

    @Test("un aviso de sesión no iniciada reporta credenciales inválidas")
    func sesionNoIniciada() {
        let porStderr = AntigravityLimitsProvider.snapshot(from:
            Self.output("", stderr: "Error: not logged into Antigravity", exitCode: 1))
        #expect(porStderr.status == .invalidCredentials)
        #expect(porStderr.windows.isEmpty)

        let porStdout = AntigravityLimitsProvider.snapshot(from:
            Self.output("Please log in to Antigravity first", exitCode: 1))
        #expect(porStdout.status == .invalidCredentials)

        // La salida de cuota real no dispara el detector.
        #expect(!AntigravityLimitsProvider.isSessionMissing(Self.salidaReal))
    }

    // MARK: - fetch con runner inyectado

    @Test("binario ausente → no configurado, y el CLI no se ejecuta")
    func binarioAusente() async {
        let inexistente = FileManager.default.temporaryDirectory
            .appending(path: "agy-\(UUID().uuidString)")
        let ejecuciones = LockedCounter()
        let provider = AntigravityLimitsProvider(candidates: [inexistente], credentialRead: { .notFound }) { _ in
            ejecuciones.increment()
            return Self.output(Self.salidaReal)
        }
        let snapshot = await provider.fetch()
        #expect(snapshot.status == .notConfigured)
        #expect(snapshot.windows.isEmpty)
        #expect(ejecuciones.value == 0)
    }

    @Test("la válvula de 15 min: dos llamadas seguidas ejecutan el CLI una sola vez")
    func valvulaDe15Min() async {
        let ejecuciones = LockedCounter()
        let provider = AntigravityLimitsProvider(candidates: [Self.binarioFalso], credentialRead: { .notFound }) { _ in
            ejecuciones.increment()
            return Self.output(Self.salidaReal)
        }
        let primero = await provider.fetch()
        let segundo = await provider.fetch()
        #expect(primero.status == .ok)
        #expect(primero.windows.count == 4)
        #expect(segundo == primero)
        #expect(ejecuciones.value == 1)
    }

    @Test("un fallo transitorio conserva el último dato bueno, marcado con su antigüedad")
    func falloConservaUltimoBueno() async {
        let falla = LockedFlag()
        // Válvula abierta en cada llamada (intervalo 0) para forzar el reintento.
        let provider = AntigravityLimitsProvider(candidates: [Self.binarioFalso],
                                                 cliInterval: 0,
                                                 credentialRead: { .notFound }) { _ in
            falla.value ? Self.output("", stderr: "boom", exitCode: 1)
                        : Self.output(Self.salidaReal)
        }
        let bueno = await provider.fetch()
        #expect(bueno.status == .ok)

        falla.set(true)
        let marcado = await provider.fetch()
        #expect(marcado.windows.count == 4)
        // La edad real es ~0 s, así que la marca es "ahora".
        #expect(marcado.status == .failed("ahora"))
        // `dataAsOf` lleva la fecha real del último dato bueno, no la del intento fallido:
        // así el ViewModel no la sobrescribe con "ahora" cuando en realidad es vieja.
        #expect(marcado.dataAsOf != nil)
    }

    // MARK: - Búsqueda del binario

    @Test("el binario se busca por rutas candidatas, no por el PATH")
    func busquedaDeBinario() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "agy-bin-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Ninguna ruta existe.
        #expect(AntigravityLimitsProvider.findBinary(in: [dir.appending(path: "a"),
                                                          dir.appending(path: "b")]) == nil)

        // Existe pero no es ejecutable: se salta al siguiente candidato.
        let noEjecutable = dir.appending(path: "agy-deco")
        _ = FileManager.default.createFile(atPath: noEjecutable.path, contents: Data())
        let ejecutable = dir.appending(path: "agy")
        _ = FileManager.default.createFile(atPath: ejecutable.path, contents: Data(),
                                           attributes: [.posixPermissions: 0o755])
        #expect(AntigravityLimitsProvider.findBinary(in: [noEjecutable, ejecutable]) == ejecutable)
    }

    // MARK: - Hallazgos de la revisión de Codex (2026-09-27)

    @Test("la marca de dato viejo sobrevive a los ciclos con la válvula cerrada")
    func marcaSobreviveALaValvula() async {
        let falla = LockedFlag()
        // Intervalo 0 para el primer reintento; luego se cierra la válvula a mano.
        let provider = AntigravityLimitsProvider(candidates: [Self.binarioFalso],
                                                 cliInterval: 0,
                                                 credentialRead: { .notFound }) { _ in
            falla.value ? Self.output("", stderr: "boom", exitCode: 1)
                        : Self.output(Self.salidaReal)
        }
        #expect(await provider.fetch().status == .ok)
        falla.set(true)
        let marcado = await provider.fetch()
        #expect(marcado.windows.count == 4)
        #expect(marcado.status == .failed("ahora"))

        // Una consulta más, también con la válvula abierta: antes de este arreglo la
        // segunda devolvía el fallo pelado y se perdían las ventanas.
        let siguiente = await provider.fetch()
        #expect(siguiente.windows.count == 4)
        if case .failed = siguiente.status {} else {
            Issue.record("se esperaba el dato bueno marcado, fue \(siguiente.status)")
        }
    }

    @Test("un CLI lento no bloquea el refresco más allá del presupuesto")
    func cliLentoNoBloquea() async {
        let terminado = LockedFlag()
        let provider = AntigravityLimitsProvider(candidates: [Self.binarioFalso],
                                                 cliInterval: 0,
                                                 budget: .milliseconds(50),
                                                 firstRunBudget: .milliseconds(50),
                                                 credentialRead: { .notFound }) { _ in
            try? await Task.sleep(for: .milliseconds(400))
            terminado.set(true)
            return Self.output(Self.salidaReal)
        }

        let inicio = ContinuousClock.now
        let primero = await provider.fetch()
        let esperado = ContinuousClock.now - inicio
        // Devuelve enseguida, sin ventanas todavía y sin haber esperado al CLI.
        #expect(esperado < .milliseconds(300))
        #expect(primero.windows.isEmpty)
        #expect(terminado.value == false)

        // La ejecución siguió en segundo plano: su resultado entra en la consulta siguiente.
        try? await Task.sleep(for: .milliseconds(600))
        #expect(terminado.value == true)
        let segundo = await provider.fetch()
        #expect(segundo.windows.count == 4)
    }

    @Test("la válvula de 15 min solo se cierra tras un resultado .ok")
    func valvulaSoloTrasOk() async {
        let cache = AntigravityLimitsProvider.CLICache(interval: 15 * 60)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        // Sin resultado previo, corre.
        #expect(await cache.shouldRun(now: t0))
        // Un fallo no cierra la válvula: el siguiente ciclo vuelve a correr.
        await cache.store(.empty(.antigravity, .failed("boom")), at: t0)
        #expect(await cache.shouldRun(now: t0.addingTimeInterval(60)))
        // Un .ok sí cierra la válvula durante el intervalo.
        await cache.store(.empty(.antigravity, .ok), at: t0.addingTimeInterval(60))
        #expect(await !cache.shouldRun(now: t0.addingTimeInterval(120)))
        // Pasado el intervalo vuelve a abrir.
        #expect(await cache.shouldRun(now: t0.addingTimeInterval(60 + 15 * 60 + 1)))
    }

    @Test("la primera corrida espera al CLI en vez de dejar la fila en Consultando")
    func primeraCorridaEspera() async {
        let provider = AntigravityLimitsProvider(candidates: [Self.binarioFalso],
                                                 cliInterval: 0,
                                                 budget: .milliseconds(20),
                                                 firstRunBudget: .milliseconds(300),
                                                 credentialRead: { .notFound }) { _ in
            try? await Task.sleep(for: .milliseconds(80))
            return Self.output(Self.salidaReal)
        }
        let snapshot = await provider.fetch()
        #expect(snapshot.status == .ok)
        #expect(snapshot.windows.count == 4)
    }

    @Test("el dato servido desde caché lleva dataAsOf")
    func cacheLlevaDataAsOf() async {
        let provider = AntigravityLimitsProvider(candidates: [Self.binarioFalso],
                                                 cliInterval: 15 * 60,
                                                 credentialRead: { .notFound }) { _ in
            Self.output(Self.salidaReal)
        }
        let primero = await provider.fetch()
        #expect(primero.status == .ok)
        // La segunda consulta, con la válvula cerrada, sirve el dato en caché y debe
        // llevar su fecha real (dataAsOf), no parecer recién obtenido.
        let segundo = await provider.fetch()
        #expect(segundo == primero)
        #expect(segundo.dataAsOf != nil)
    }

    @Test("lee la salida mientras corre, sin bloquearse con más de 64 KB")
    func lecturaMientrasCorre() async {
        // `yes` escribe sin parar y `head` corta a los 200 KB: si nadie drenara la tubería
        // mientras corre, el proceso se quedaría bloqueado al llenarse el buffer y solo lo
        // sacaría el timeout.
        let output = await AntigravityLimitsProvider.runCommand(
            binary: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "yes xxxxxxxxxx | head -c 200000"],
            timeout: 10)
        #expect(output.exitCode == 0)
        #expect(output.stdout.utf8.count == 200000)
    }

    @Test("la salida escrita justo antes de salir no se pierde")
    func salidaAlTerminar() async {
        // El proceso escribe y sale al instante: el handler de terminación puede correr
        // antes que el último callback de lectura. Se repite para ejercitar la carrera.
        for _ in 0..<30 {
            let output = await AntigravityLimitsProvider.runCommand(
                binary: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf 'fin-de-salida'; printf 'fin-de-error' >&2"],
                timeout: 10)
            #expect(output.stdout == "fin-de-salida")
            #expect(output.stderr == "fin-de-error")
        }
    }

    @Test("un hijo que hereda la tubería no cuelga la corrida")
    func hijoHeredaTuberia() async {
        let inicio = ContinuousClock.now
        let output = await AntigravityLimitsProvider.runCommand(
            binary: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 'listo'; sleep 5 &"],
            timeout: 10)
        #expect(output.stdout == "listo")
        #expect(ContinuousClock.now - inicio < .seconds(3))
    }

    @Test("un refresco durante una corrida lenta espera a esa corrida, sin lanzar otra")
    func corridaEnCursoNoSeSolapa() async {
        let lanzados = LockedCounter()
        let provider = AntigravityLimitsProvider(candidates: [Self.binarioFalso],
                                                 cliInterval: 15 * 60,
                                                 budget: .milliseconds(30),
                                                 firstRunBudget: .milliseconds(30),
                                                 credentialRead: { .notFound }) { _ in
            lanzados.increment()
            try? await Task.sleep(for: .milliseconds(300))
            return Self.output(Self.salidaReal)
        }
        let primero = await provider.fetch()
        #expect(primero.windows.isEmpty)
        // Refresco manual mientras la primera corrida sigue: no lanza una segunda.
        let segundo = await provider.fetch()
        #expect(lanzados.value == 1)
        #expect(segundo.windows.isEmpty)

        try? await Task.sleep(for: .milliseconds(500))
        let tercero = await provider.fetch()
        #expect(lanzados.value == 1)
        #expect(tercero.windows.count == 4)
    }

    @Test("un fallo libera la corrida: el siguiente ciclo la reintenta")
    func falloEsReintentable() async {
        let lanzados = LockedCounter()
        let provider = AntigravityLimitsProvider(candidates: [Self.binarioFalso],
                                                 cliInterval: 15 * 60,
                                                 credentialRead: { .notFound }) { _ in
            lanzados.increment()
            return Self.output("", exitCode: 1)
        }
        _ = await provider.fetch()
        _ = await provider.fetch()
        #expect(lanzados.value == 2)
    }
}
