import Foundation

/// Herramienta de IA cuyo consumo de tokens rastrea TokenBar.
enum AppSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case claudeCode
    case cursor
    case antigravity
    case codex
    case commandCode
    case opencode

    static let allCases: [AppSource] = [.claudeCode, .cursor, .antigravity]
    static let limitsCases: [AppSource] = [
        .claudeCode, .cursor, .antigravity, .codex, .commandCode, .opencode
    ]

    var id: String { rawValue }

    /// Nombre visible en la UI.
    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .cursor: return "Cursor"
        case .antigravity: return "Antigravity"
        case .codex: return "Codex"
        case .commandCode: return "Command Code"
        case .opencode: return "OpenCode"
        }
    }

    /// Bundle id de la app de escritorio de la herramienta, cuando existe: de ahí sale su
    /// logo real. Las herramientas que solo son CLI (Command Code, OpenCode, el `agy` de
    /// Antigravity) no tienen app instalada y caen en su SF Symbol.
    var bundleIdentifier: String? {
        switch self {
        case .claudeCode: return "com.anthropic.claudefordesktop"
        case .cursor: return "com.todesktop.230313mzl4w4u92"
        case .codex: return "com.openai.codex"
        case .antigravity, .commandCode, .opencode: return nil
        }
    }

    /// Si la herramienta tiene de dónde leer tokens consumidos. Antigravity no persiste
    /// consumo en ninguna parte, y Codex, Command Code y OpenCode solo exponen cuota: sus
    /// filas muestran ventanas, no tokens. Un día en cero **sí** es consumo válido, así que
    /// esto no depende de cuántos tokens haya hoy.
    var hasTokenSource: Bool {
        switch self {
        case .claudeCode, .cursor: return true
        case .antigravity, .codex, .commandCode, .opencode: return false
        }
    }

    /// SF Symbol que representa la app en la lista.
    var symbolName: String {
        switch self {
        case .claudeCode: return "terminal.fill"
        case .cursor: return "cursorarrow.rays"
        case .antigravity: return "arrow.up.circle.fill"
        case .codex: return "apple.terminal"
        case .commandCode: return "chevron.left.forwardslash.chevron.right"
        case .opencode: return "shippingbox.fill"
        }
    }
}
