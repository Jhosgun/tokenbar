import AppKit
import SwiftUI

/// Popover principal de la barra de menú. Tamaño fijo 300×520.
struct DashboardView: View {

    @Environment(\.openWindow) private var openWindow

    private let viewModel: UsageViewModel

    /// Reloj de 1 minuto: solo mueve las cuentas regresivas de los límites, sin pedir datos.
    @State private var now = Date()
    private let clock = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    /// Qué herramientas están desplegadas. Todas empiezan plegadas: el popover muestra una
    /// línea por herramienta y el detalle se pide con un clic.
    @State private var expanded: Set<AppSource> = []

    init(viewModel: UsageViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            Divider()

            // Una fila por herramienta, plegada. La lista crece con las cuentas
            // conectadas, así que va en un scroll: el header y el footer quedan fijos y
            // siempre se puede bajar hasta la última.
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(AppSource.limitsCases) { source in
                        SourceRowView(
                            source: source,
                            snapshot: viewModel.limits[source],
                            record: viewModel.snapshot.todayByApp[source],
                            series: viewModel.snapshot.last7DaysByApp[source] ?? [],
                            tokensStatus: viewModel.statuses[source],
                            showCost: viewModel.showCost,
                            lastGoodAt: viewModel.lastGoodAt[source],
                            now: now,
                            isExpanded: expansion(for: source)
                        )
                    }
                }
            }

            Divider()

            footer
        }
        .padding(12)
        .frame(width: 300, height: 520)
        // El popover no puede crecer, así que se topa el escalado de texto y el contenido
        // se compacta (lineLimit + minimumScaleFactor) antes que desbordarse y recortarse.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .onReceive(clock) { now = $0 }
    }

    /// El despliegue de cada fila, como binding para `SourceRowView`.
    private func expansion(for source: AppSource) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(source) },
            set: { isExpanded in
                if isExpanded { expanded.insert(source) } else { expanded.remove(source) }
            }
        )
    }

    // MARK: - Secciones

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Hoy")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(TokenFormatter.short(viewModel.snapshot.todayTotalTokens))
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            headerSubtitle
        }
        .accessibilityElement(children: .combine)
    }

    /// Con el contador en cero un "$0.00" no aporta nada; se explica que aún no hay datos
    /// para que el primer arranque se lea como intencional y no como un error.
    @ViewBuilder
    private var headerSubtitle: some View {
        if viewModel.snapshot.todayTotalTokens == 0 {
            Text("Sin consumo registrado hoy")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        } else if viewModel.showCost {
            Text(TokenFormatter.currency(viewModel.snapshot.todayCostUSD))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text(lastUpdateText)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .accessibilityLabel(lastUpdateAccessibilityLabel)

            Spacer(minLength: 4)

            refreshButton
            settingsMenu
        }
    }

    private var refreshButton: some View {
        Button {
            Task { await viewModel.refresh(forceLimits: true) }
        } label: {
            if viewModel.isRefreshing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "arrow.clockwise")
            }
        }
        .buttonStyle(.borderless)
        .frame(width: 22, height: 18)
        .disabled(viewModel.isRefreshing)
        .help("Actualizar ahora")
        .accessibilityLabel("Actualizar ahora")
    }

    private var settingsMenu: some View {
        Menu {
            Button("Preferencias…") {
                // Sin activar la app, la ventana se abre detrás del popover.
                NSApplication.shared.activate()
                openWindow(id: "preferences")
            }
            Divider()
            Button("Salir") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        } label: {
            Image(systemName: "gearshape")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Preferencias y salir")
        .accessibilityLabel("Opciones: preferencias y salir")
    }

    private var lastUpdateText: String {
        guard let lastUpdate = viewModel.lastUpdate else { return "—" }
        return "Actualizado \(lastUpdate.formatted(.dateTime.hour().minute()))"
    }

    /// El guion largo del estado inicial no se lee bien en VoiceOver.
    private var lastUpdateAccessibilityLabel: String {
        viewModel.lastUpdate == nil ? "Sin actualizar todavía" : lastUpdateText
    }
}

#Preview {
    DashboardView(
        viewModel: UsageViewModel(store: UsageStore(),
                                  state: CollectorStateStore(),
                                  collectors: [])
    )
}
