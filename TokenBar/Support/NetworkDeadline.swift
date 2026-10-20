import Foundation

/// Acota el tiempo total de una operación de red a un plazo absoluto.
///
/// `URLRequest.timeoutInterval` no basta: acota una sola petición, no la suma de lo que
/// tarde el proveedor en decidir que terminó (redirecciones, una respuesta que llega a
/// cuentagotas, etc.).
///
/// No se usa un `TaskGroup`: al salir de su scope espera a **todos** sus hijos, así que un
/// `work` que no coopere con la cancelación (o que tarde en notarla) mantendría el bloqueo
/// aunque venza el presupuesto — el plazo "absoluto" dejaría de serlo, y como
/// `UsageViewModel` espera a todos los proveedores, congelaría el refresco entero. Con dos
/// tareas sueltas y una compuerta que solo reanuda una vez (el mismo patrón que ya usaba
/// `AntigravityLimitsProvider` para su CLI), la espera se abandona de verdad: `work` sigue
/// corriendo en segundo plano si se pasa del presupuesto, pero quien llamó a `run` ya
/// siguió su camino.
enum NetworkDeadline {
    /// - Parameter cancelOnTimeout: si el plazo se cumple primero, cancela la tarea de
    ///   `work` (`true`, el default). Sin cancelarla, una petición de red que el servidor
    ///   mantiene abierta (o cualquier trabajo que no responda solo) seguiría corriendo y
    ///   se acumularía en cada ciclo de refresco. Pásalo en `false` únicamente cuando el
    ///   trabajo de fondo valga la pena por sí mismo más allá de esta llamada —por ejemplo
    ///   `AntigravityLimitsProvider`, que guarda el resultado de su CLI en una caché que
    ///   recoge el ciclo siguiente: cancelarlo tiraría los segundos ya invertidos en vez de
    ///   aprovecharlos.
    static func run<T: Sendable>(
        budget: Duration,
        cancelOnTimeout: Bool = true,
        _ work: @escaping @Sendable () async -> T
    ) async -> T? {
        let gate = FirstResume()
        let box = RunBox()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
                let workTask = Task {
                    let result = await work()
                    if await gate.resume(continuation, with: result) {
                        // Ganó el trabajo: no dejes al temporizador durmiendo el presupuesto
                        // entero de más.
                        box.cancelTimer()
                    }
                }
                let timerTask = Task {
                    try? await Task.sleep(for: budget)
                    // Reclama la compuerta ANTES de cancelar: todos los proveedores de red
                    // atrapan la cancelación, así que cancelar primero podría hacer que
                    // `work` termine y llame a `gate.resume` con su propio valor antes de que
                    // este `await` llegue al actor — el vencimiento se disfrazaría de un
                    // resultado normal, de forma intermitente. Resuelto el `nil` primero, la
                    // reanudación posterior de `work` (cancelado o no) ya no tiene efecto.
                    if await gate.resume(continuation, with: nil) {
                        if cancelOnTimeout { workTask.cancel() }
                    }
                }
                box.set(work: workTask, timer: timerTask)
            }
        } onCancel: {
            // La cancelación de quien llama se propaga a ambas tareas internas, en vez de
            // dejarlas huérfanas (o al temporizador durmiendo hasta que venza).
            box.cancelAll()
        }
    }

    /// Reanuda un continuation una sola vez, gane quien gane la carrera.
    private actor FirstResume {
        private var resumed = false

        func resume<T: Sendable>(_ continuation: CheckedContinuation<T, Never>, with value: T) -> Bool {
            guard !resumed else { return false }
            resumed = true
            continuation.resume(returning: value)
            return true
        }
    }

    /// Guarda las dos tareas internas para poder cancelarlas desde fuera. La cancelación
    /// puede llegar antes de que `set` corra, así que se registra la intención y se aplica
    /// en cuanto las tareas existen.
    private final class RunBox: @unchecked Sendable {
        private let lock = NSLock()
        private var workTask: Task<Void, Never>?
        private var timerTask: Task<Void, Never>?
        private var cancelled = false

        func set(work: Task<Void, Never>, timer: Task<Void, Never>) {
            lock.lock()
            workTask = work
            timerTask = timer
            let cancel = cancelled
            lock.unlock()
            if cancel {
                work.cancel()
                timer.cancel()
            }
        }

        func cancelTimer() {
            lock.lock()
            let timer = timerTask
            timerTask = nil
            lock.unlock()
            timer?.cancel()
        }

        func cancelAll() {
            lock.lock()
            cancelled = true
            let work = workTask
            let timer = timerTask
            lock.unlock()
            work?.cancel()
            timer?.cancel()
        }
    }
}
