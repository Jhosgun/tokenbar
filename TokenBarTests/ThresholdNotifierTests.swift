import Testing
import UserNotifications

@testable import TokenBar

/// El permiso de notificaciones no se cachea (C7): lo que se puede fijar con tests es el
/// mapeo desde el estado del sistema, que es la parte con criterio (provisional y
/// ephemeral también cuentan como autorizados). La consulta real no se testea porque
/// requiere el centro de notificaciones de una app de verdad.
@MainActor
struct ThresholdNotifierTests {

    @Test("el permiso se mapea desde el estado del sistema, no desde una cache")
    func permisoMapeadoDelSistema() {
        #expect(ThresholdNotifier.permission(from: .authorized) == .allowed)
        // Provisional también deja notificar. (.ephemeral es de app clips de iOS: en
        // macOS no existe y no se puede siquiera construir en un test.)
        #expect(ThresholdNotifier.permission(from: .provisional) == .allowed)
        #expect(ThresholdNotifier.permission(from: .denied) == .denied)
        #expect(ThresholdNotifier.permission(from: .notDetermined) == .notDetermined)
    }
}
