import AppKit
import SwiftUI

@main
struct TokenBarApp: App {

    @State private var viewModel: UsageViewModel

    init() {
        // Una sola instancia del store: los collectors comparten cursores y dedupe.
        let state = CollectorStateStore()
        let viewModel = UsageViewModel(
            store: UsageStore(),
            state: state,
            collectors: [
                ClaudeCodeCollector(store: state),
                CursorCollector(store: state)
            ],
            // Los límites vienen de la cuenta, no de los transcripts: son fuentes
            // independientes y por eso van por su propio carril.
            limitsProviders: [
                ClaudeLimitsProvider(),
                CursorLimitsProvider(),
                AntigravityLimitsProvider(),
                CodexLimitsProvider(),
                CommandCodeLimitsProvider(),
                OpenCodeGoLimitsProvider()
            ]
        )
        _viewModel = State(initialValue: viewModel)
        // Arranca aquí, no en un `.task` de la vista: el popover puede no abrirse nunca
        // y el ícono igual tiene que reaccionar.
        viewModel.start()
    }

    var body: some Scene {
        MenuBarExtra {
            DashboardView(viewModel: viewModel)
        } label: {
            // El ícono señala presión de cuota, no actividad: lo accionable es que te
            // estés quedando sin ventana, no que acabes de gastar tokens.
            Image(nsImage: MenuBarIcon.image(severity: viewModel.worstLimit?.severity))
                // `.original` conserva el color de alerta; `.template` deja que la barra
                // tiña el glifo y se adapte sola a modo claro/oscuro.
                .renderingMode(viewModel.worstLimit?.severity == .normal
                               || viewModel.worstLimit == nil ? .template : .original)
        }
        .menuBarExtraStyle(.window)

        Window("Preferencias", id: "preferences") {
            PreferencesView(viewModel: viewModel)
        }
        .windowResizability(.contentSize)
    }
}

/// Ícono de la barra de menú.
///
/// `MenuBarExtra(systemImage:)` renderiza siempre como template y descarta el color, así
/// que el glifo se arma a mano con `NSImage`: las variantes de alerta llevan una
/// `SymbolConfiguration(paletteColors:)` y `isTemplate = false` para que el color
/// sobreviva; la normal queda template y hereda el color del sistema.
@MainActor
private enum MenuBarIcon {

    /// Tamaño estándar de glifo de barra de menú.
    private static let pointSize: CGFloat = 15

    /// `nil` (sin datos de límite todavía) se trata como normal.
    static func image(severity: LimitWindow.Severity?) -> NSImage {
        switch severity {
        case .warning:  warningImage
        case .critical: criticalImage
        default:        normalImage
        }
    }

    private static let normalImage: NSImage = {
        let image = base(with: NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular))
        image.isTemplate = true
        return image
    }()

    private static let warningImage = tinted(.systemOrange)
    private static let criticalImage = tinted(.systemRed)

    private static func tinted(_ color: NSColor) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let image = base(with: configuration)
        image.isTemplate = false
        return image
    }

    private static func base(with configuration: NSImage.SymbolConfiguration) -> NSImage {
        guard let symbol = NSImage(systemSymbolName: "chart.bar.fill",
                                   accessibilityDescription: "Consumo de tokens") else {
            return NSImage()
        }
        return symbol.withSymbolConfiguration(configuration) ?? symbol
    }
}
