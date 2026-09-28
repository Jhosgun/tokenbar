import Foundation
import Testing

@testable import TokenBar

@Suite("NetworkDeadline")
struct NetworkDeadlineTests {

    /// Bandera con candado, segura para capturar en closures @Sendable.
    private final class LockedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = false
        var value: Bool { lock.lock(); defer { lock.unlock() }; return storage }
        func set(_ newValue: Bool) { lock.lock(); defer { lock.unlock() }; storage = newValue }
    }

    @Test("un trabajo rápido devuelve su valor sin esperar el presupuesto")
    func trabajoRapido() async {
        let resultado = await NetworkDeadline.run(budget: .seconds(5)) { 42 }
        #expect(resultado == 42)
    }

    @Test("un trabajo que ignora la cancelación no bloquea: run vuelve dentro del presupuesto")
    func noEsperaUnTrabajoQueIgnoraLaCancelacion() async {
        // Antes del arreglo, `run` usaba un `TaskGroup`, que al salir de su scope espera a
        // TODOS sus hijos —cancelados o no—. `usleep` (a diferencia de `Task.sleep`) no
        // coopera con la cancelación de Swift, así que simula justo el caso que rompía eso:
        // un trabajo que el temporizador no puede interrumpir.
        let terminado = LockedFlag()
        let inicio = ContinuousClock.now
        let resultado = await NetworkDeadline.run(budget: .milliseconds(50)) {
            usleep(400_000)
            terminado.set(true)
            return 42
        }
        let transcurrido = ContinuousClock.now - inicio
        #expect(resultado == nil)
        // Con el `TaskGroup` esto habría tardado ~400 ms, esperando al trabajo.
        #expect(transcurrido < .milliseconds(300))
        #expect(terminado.value == false)

        // El trabajo sigue en segundo plano: termina después, aunque a nadie le importe ya.
        try? await Task.sleep(for: .milliseconds(500))
        #expect(terminado.value == true)
    }

    @Test("por defecto, al vencer el plazo se cancela la tarea de trabajo")
    func porDefectoCancelaAlVencer() async {
        let cancelado = LockedFlag()
        let terminado = LockedFlag()
        // El `catch` devuelve -1, un valor distinguible del `42` del camino feliz: si
        // `run` cancelara antes de reclamar la compuerta para el timeout (el orden que
        // tenía el bug), el trabajo cancelado podría colarse con -1 antes que el `nil`
        // del temporizador, y `resultado == nil` pasaría solo por suerte de scheduling.
        let resultado = await NetworkDeadline.run(budget: .milliseconds(50)) {
            do {
                try await Task.sleep(for: .milliseconds(200))
                terminado.set(true)
                return 42
            } catch {
                // `Task.sleep` lanza en cuanto se cancela la tarea que lo contiene.
                cancelado.set(true)
                return -1
            }
        }
        #expect(resultado == nil)

        // Da tiempo a que la cancelación se propague y el `catch` corra.
        try? await Task.sleep(for: .milliseconds(300))
        #expect(cancelado.value == true)
        #expect(terminado.value == false)
    }

    @Test("con cancelOnTimeout: false, el trabajo no se cancela y termina por su cuenta")
    func sinCancelarElTrabajoTerminaPorSuCuenta() async {
        let cancelado = LockedFlag()
        let terminado = LockedFlag()
        let resultado = await NetworkDeadline.run(budget: .milliseconds(50), cancelOnTimeout: false) {
            do {
                try await Task.sleep(for: .milliseconds(200))
                terminado.set(true)
                return 42
            } catch {
                cancelado.set(true)
                return -1
            }
        }
        #expect(resultado == nil)  // el plazo sigue venciendo primero para quien llamó a `run`

        // Sin cancelar, el `Task.sleep` de adentro no se interrumpe: termina por su cuenta,
        // y su resultado queda disponible aunque `run` ya haya vuelto.
        try? await Task.sleep(for: .milliseconds(300))
        #expect(cancelado.value == false)
        #expect(terminado.value == true)
    }
}
