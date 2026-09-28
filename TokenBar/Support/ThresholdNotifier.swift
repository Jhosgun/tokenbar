import Foundation
import OSLog
// `@preconcurrency`: el SDK de Xcode 26 marca `UNUserNotificationCenter` como `Sendable`,
// pero el de Xcode 16 —el de los runners de CI— todavía no, y ahí `await center.add(...)`
// desde el MainActor se rechaza con "sending 'center' risks causing data races". Con esto
// compila igual en ambos; el acceso real sigue confinado a este actor.
@preconcurrency import UserNotifications

/// Notifica una vez al día cuando el total de tokens del día supera el umbral configurado.
@MainActor
final class ThresholdNotifier {

    private static let enabledKey = "notifyEnabled"
    private static let thresholdKey = "notifyThreshold"
    /// Día ("yyyy-MM-dd") en el que ya se disparó la notificación.
    private static let lastFiredDayKey = "notifyLastFiredDay"

    static let defaultThreshold = 1_000_000

    /// Persistido en `UserDefaults` bajo "notifyEnabled". Por defecto apagado.
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Persistido en `UserDefaults` bajo "notifyThreshold". Sin valor guardado (o valor
    /// inválido) cae en `defaultThreshold`.
    static var threshold: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: thresholdKey)
            return stored > 0 ? stored : defaultThreshold
        }
        set { UserDefaults.standard.set(max(1, newValue), forKey: thresholdKey) }
    }

    private let log = Logger(subsystem: "io.github.jhosgun.tokenbar", category: "notify")
    private var didRequestAuthorization = false
    private var isAuthorized = false

    init() {}

    /// Pide autorización (.alert, .sound) una sola vez por instancia. El sistema solo muestra
    /// el diálogo la primera vez de por vida; en arranques posteriores devuelve el permiso
    /// vigente sin molestar al usuario. Nunca lanza.
    func requestAuthorizationIfNeeded() async {
        guard !didRequestAuthorization else { return }
        didRequestAuthorization = true

        guard let center = Self.center() else { return }
        do {
            isAuthorized = try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            isAuthorized = false
            log.error("autorización rechazada: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Llamar después de cada refresh con el total de HOY y el día actual ("yyyy-MM-dd").
    ///
    /// Dispara la notificación solo si está habilitada, el total alcanza el umbral y no se
    /// notificó ya ese día. Sin permiso del usuario no hace nada.
    ///
    /// Anti-spam: el día notificado queda guardado en "notifyLastFiredDay". Si el usuario
    /// BAJA el umbral después de que ya se notificó hoy, NO se vuelve a notificar hasta
    /// mañana — el aviso es "cruzaste tu umbral", no "sigues por encima".
    func evaluate(todayTotal: Int, day: String) async {
        guard Self.isEnabled else { return }

        let threshold = Self.threshold
        guard todayTotal >= threshold else { return }
        guard UserDefaults.standard.string(forKey: Self.lastFiredDayKey) != day else { return }

        await requestAuthorizationIfNeeded()
        guard isAuthorized, let center = Self.center() else { return }

        let content = UNMutableNotificationContent()
        content.title = "TokenBar"
        content.body = "Superaste \(TokenFormatter.short(threshold)) tokens hoy "
            + "(\(TokenFormatter.short(todayTotal)))."
        content.sound = .default

        // Trigger nil = entrega inmediata.
        let request = UNNotificationRequest(
            identifier: "threshold-\(day)",
            content: content,
            trigger: nil
        )

        do {
            try await center.add(request)
            // Solo se marca el día si la entrega se aceptó; si falla, se reintenta en el
            // siguiente refresh.
            UserDefaults.standard.set(day, forKey: Self.lastFiredDayKey)
        } catch {
            log.error("no se pudo notificar: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// `UNUserNotificationCenter.current()` termina el proceso si el bundle no tiene
    /// identificador (tests, previews). En ese caso no hay notificaciones y se sale callado.
    private static func center() -> UNUserNotificationCenter? {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }
}
