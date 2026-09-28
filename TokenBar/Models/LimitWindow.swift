import Foundation

/// Una ventana de límite de una cuenta: cuánto se lleva usado y cuándo se reinicia.
///
/// A diferencia de `UsageRecord` —que se calcula leyendo transcripts locales— esto viene
/// directo de la cuenta del proveedor, así que es la cifra autoritativa: es la que decide
/// si te bloquean.
struct LimitWindow: Identifiable, Hashable, Sendable {
    /// Nombre corto para la UI: "5 horas", "Semanal", "Opus semanal"…
    var name: String
    /// 0…1. Viene normalizado; el proveedor se encarga de convertir desde su escala.
    var utilization: Double
    /// Cuándo se reinicia la ventana. `nil` si el proveedor no lo informa.
    var resetsAt: Date?

    var id: String { name }

    /// Porcentaje entero para mostrar, acotado a 0…100.
    var percent: Int { Int((min(max(utilization, 0), 1) * 100).rounded()) }

    /// Severidad para colorear la barra y el ícono de la barra de menú.
    enum Severity: Sendable { case normal, warning, critical }

    var severity: Severity {
        switch utilization {
        case ..<0.80: .normal
        case ..<0.95: .warning
        default:      .critical
        }
    }

    /// Tiempo restante hasta el reset, en formato corto ("4h 15m", "12m", "ahora").
    /// `nil` si no hay fecha de reset.
    func timeRemaining(from now: Date = Date()) -> String? {
        guard let resetsAt else { return nil }
        let seconds = resetsAt.timeIntervalSince(now)
        guard seconds > 0 else { return "ahora" }
        let totalMinutes = Int(seconds / 60)
        let (hours, minutes) = (totalMinutes / 60, totalMinutes % 60)
        if hours >= 24 {
            let (days, restHours) = (hours / 24, hours % 24)
            return restHours > 0 ? "\(days)d \(restHours)h" : "\(days)d"
        }
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }
}

/// Lo que un proveedor de límites sabe de una cuenta en un momento dado.
struct LimitsSnapshot: Equatable, Sendable {
    var source: AppSource
    /// Ventanas activas, en el orden en que deben mostrarse.
    var windows: [LimitWindow]
    /// Texto libre para el estado del plan ("pro", "max 20x"…). `nil` si no aplica.
    var planLabel: String?
    var status: CollectorStatus
    /// True si el proveedor respondió 429 (`rate_limit_error`) y limitó las consultas.
    /// Distinto de `rateLimitedUntil`, que solo se rellena si vino `Retry-After`.
    var rateLimited: Bool = false
    /// Si `rateLimited` y el servidor informó `Retry-After`, hora mínima de reintento.
    var rateLimitedUntil: Date? = nil

    static func empty(_ source: AppSource, _ status: CollectorStatus) -> LimitsSnapshot {
        LimitsSnapshot(source: source, windows: [], planLabel: nil, status: status)
    }

    /// Snapshot de "el proveedor nos limitó las consultas" (429). `retryAfter` viene del
    /// header `Retry-After`; `nil` si el servidor no lo informó y toca backoff exponencial.
    static func rateLimited(_ source: AppSource, retryAfter: Date?) -> LimitsSnapshot {
        LimitsSnapshot(source: source, windows: [], planLabel: nil,
                       status: .failed("Límite de consultas alcanzado"),
                       rateLimited: true, rateLimitedUntil: retryAfter)
    }

    /// La ventana más comprometida, que es la que manda en el color del ícono.
    var worst: LimitWindow? {
        windows.max { $0.utilization < $1.utilization }
    }

    /// La ventana que representa a la fuente cuando la fila está plegada: **la primera**.
    /// Cada proveedor las devuelve en orden de urgencia —la más corta primero (5 h antes
    /// que semanal)— porque es la que decide si puedes seguir trabajando ahora mismo. No
    /// se usa `worst`: una cuota por modelo al 100% taparía la de 5 h, que es la que
    /// importa de un vistazo.
    var primary: LimitWindow? { windows.first }

    /// La ventana crítica o en aviso que **no** es la principal, si la hay: la fila
    /// plegada la señala con un punto para que un tope por modelo no pase desapercibido.
    var hiddenAlert: LimitWindow? {
        guard let worst, worst.severity != .normal, worst.id != primary?.id else { return nil }
        return worst
    }
}

/// Fuente de límites de una cuenta. Paralelo a `UsageCollector`, pero para el estado
/// actual del plan en vez del consumo histórico.
protocol LimitsProvider: Sendable {
    var source: AppSource { get }
    /// Nunca lanza. Nunca bloquea más de ~5 s. Los errores se reportan vía `CollectorStatus`.
    func fetch() async -> LimitsSnapshot
}
