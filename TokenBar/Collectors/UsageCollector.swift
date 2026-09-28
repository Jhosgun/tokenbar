import Foundation

/// Estado de una fuente de datos, tal como lo ve la UI.
enum CollectorStatus: Equatable, Sendable {
    case ok
    case notConfigured
    case invalidCredentials
    case failed(String)

    /// Texto corto para mostrar en la fila de la app. `nil` cuando todo está bien.
    var uiMessage: String? {
        switch self {
        case .ok:                   nil
        case .notConfigured:        "No configurado"
        case .invalidCredentials:   "Token inválido"
        case .failed(let message):  message
        }
    }
}

/// Lo que devuelve un collector en cada corrida.
struct CollectorResult: Sendable {
    /// SOLO deltas nuevos desde la última corrida, ya agrupados por día.
    var records: [UsageRecord]
    var status: CollectorStatus

    static func empty(_ status: CollectorStatus) -> CollectorResult {
        CollectorResult(records: [], status: status)
    }
}

protocol UsageCollector: Sendable {
    var source: AppSource { get }

    /// Nunca lanza. Nunca bloquea más de ~2 s. Los errores se reportan vía `CollectorStatus`.
    func collect() async -> CollectorResult
}
