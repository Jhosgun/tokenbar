import Foundation
import Testing

@testable import TokenBar

@Suite("AntigravityLimitsProvider")
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

    /// Ruta a un ejecutable real que nunca se lanza: el runner va inyectado.
    private static let binarioFalso = URL(fileURLWithPath: "/bin/ls")

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
        let provider = AntigravityLimitsProvider(candidates: [inexistente]) { _ in
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
        let provider = AntigravityLimitsProvider(candidates: [Self.binarioFalso]) { _ in
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
                                                 cliInterval: 0) { _ in
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
                                                 cliInterval: 0) { _ in
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
                                                 budget: .milliseconds(50)) { _ in
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
}
