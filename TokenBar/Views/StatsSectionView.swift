import SwiftUI

/// Sección de estadísticas del popover: consumo por herramienta o modelo en los últimos
/// 7, 30 o 90 días, como área acumulada o barras por día, con una tabla compacta debajo.
struct StatsSectionView: View {
    let viewModel: UsageViewModel

    @State private var range: StatsRange = .month
    @State private var grouping: StatsGrouping = .tool
    @State private var chartKind: StatsChartKind = .accumulated
    @State private var data: StatsData?
    @State private var assigner = StatsColorAssigner()
    @State private var colors: [String: Color] = [:]

    /// Lo que, al cambiar, obliga a volver a leer los stores. El tipo de gráfica no entra: se
    /// dibuja con las mismas series. El snapshot cambia cuando llega consumo nuevo.
    private struct LoadKey: Equatable {
        var snapshot: UsageSnapshot
        var range: StatsRange
        var grouping: StatsGrouping
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Estadísticas")
                .font(.caption)
                .foregroundStyle(.secondary)

            controls
            content
        }
        .task(id: LoadKey(snapshot: viewModel.snapshot, range: range, grouping: grouping)) {
            await load()
        }
    }

    private var controls: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Picker("Rango", selection: $range) {
                    ForEach(StatsRange.allCases) { value in
                        Text("\(value.rawValue) d")
                            .accessibilityLabel(value.label)
                            .tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .help("Rango de estadísticas: 7, 30 o 90 días")
                .accessibilityLabel("Rango de estadísticas")

                Picker("Tipo de gráfica", selection: $chartKind) {
                    Label("Acumulado", systemImage: "chart.line.uptrend.xyaxis")
                        .labelStyle(.iconOnly)
                        .tag(StatsChartKind.accumulated)
                    Label("Por día", systemImage: "chart.bar.xaxis")
                        .labelStyle(.iconOnly)
                        .tag(StatsChartKind.daily)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .help("Tipo de gráfica: acumulado o por día")
                .accessibilityLabel("Tipo de gráfica")
            }

            Picker("Agrupar por", selection: $grouping) {
                ForEach(StatsGrouping.allCases) { value in
                    Text(value.label).tag(value)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(maxWidth: .infinity)
            .help("Agrupar estadísticas por herramienta o por modelo")
            .accessibilityLabel("Agrupar por")
        }
    }

    @ViewBuilder
    private var content: some View {
        if let data {
            if data.isEmpty {
                Label("Sin consumo en los últimos \(range.rawValue) días", systemImage: "chart.bar.xaxis")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                StatsChartView(data: data, kind: chartKind, colors: colors)
                    .frame(height: 150)
                StatsTableView(data: data, colors: colors, showCost: viewModel.showCost)
            }
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Cargando estadísticas…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func load() async {
        let loaded = await viewModel.statsData(days: range.rawValue, grouping: grouping)
        guard !Task.isCancelled else { return }
        // Los colores se asignan antes de publicar los datos: la primera pasada ya sale pintada.
        colors = assigner.colors(for: loaded)
        data = loaded
    }
}
