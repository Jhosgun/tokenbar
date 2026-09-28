import Foundation
import OSLog

/// Cachea en memoria un secreto leído del llavero para no volver a consultarlo en cada ciclo.
///
/// Leer una entrada de otra app hace que macOS pida autorización al usuario. Consultarla
/// cada 30 s significa un diálogo cada 30 s, que es exactamente lo que NO debe pasar: se
/// lee una sola vez por arranque y solo se vuelve a intentar si el token resultó inválido.
///
/// Tampoco se reintenta cuando el usuario deniega: si la primera lectura devuelve `nil`,
/// se recuerda ese "no" hasta el siguiente arranque de la app. Insistir sería acosarlo con
/// el mismo diálogo para siempre.
actor KeychainTokenCache {

    private let read: @Sendable () -> String?
    private let log = Logger(subsystem: "io.github.jhosgun.tokenbar", category: "keychain-cache")

    /// `.some(nil)` significa "ya se intentó y no hay token" — distinto de "aún no se intentó".
    private var cached: String??

    init(read: @escaping @Sendable () -> String?) {
        self.read = read
    }

    /// Conveniencia para el caso normal: leer un service del llavero.
    init(service: String) {
        self.init(read: { Keychain.readForeign(service: service) })
    }

    /// Devuelve el token, consultando el llavero solo la primera vez.
    func token() -> String? {
        if let cached { return cached }
        let value = read()
        cached = .some(value)
        if value == nil {
            log.debug("sin token disponible; no se reintenta hasta el próximo arranque")
        }
        return value
    }

    /// Olvida lo cacheado para que la próxima llamada vuelva a leer el llavero.
    ///
    /// Se usa cuando el servidor rechaza el token (401/403): puede que la app dueña lo haya
    /// rotado y una relectura consiga el nuevo. No se llama en errores de red, porque ahí
    /// el token sigue siendo válido y releer solo provocaría otro diálogo.
    func invalidate() {
        cached = nil
    }
}
