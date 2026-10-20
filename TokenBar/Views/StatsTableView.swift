import SwiftUI

/// Tabla compacta y leyenda de Estadísticas: una fila por serie con total, porcentaje y,
/// cuando está habilitado, costo. El reparto por tipo de token queda en ayuda y accesibilidad.
struct StatsTableView: View {
    let data: StatsData
    let colors: [String: Color]
    let showCost: Bool

    private var rows: [StatsSeries] {
        data.series.sorted { ($0.totalTokens, $1.name) > ($1.totalTokens, $0.name) }
    }

    var body: some View {
        let total = max(data.totalTokens, 1)
        Grid(alignment: .trailing, horizontalSpacing: 6, verticalSpacing: 5) {
            ForEach(rows) { series in
                let percentage = Double(series.totalTokens) / Double(total) * 100
                GridRow {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(colors[series.name] ?? .gray)
                            .frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                        Text(series.name)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .gridColumnAlignment(.leading)
                    Text(TokenFormatter.short(series.totalTokens))
                        .fixedSize()
                        .gridColumnAlignment(.trailing)
                    Text(Self.percentageText(percentage))
                        .fixedSize()
                        .gridColumnAlignment(.trailing)
                    if showCost {
                        Text(Self.costText(series))
                            .fixedSize()
                            .gridColumnAlignment(.trailing)
                    }
                }
                .font(.caption)
                .monospacedDigit()
                .help(Self.breakdownText(series.breakdown))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(series.name)
                .accessibilityValue(Self.accessibilityValue(
                    series: series,
                    percentage: percentage,
                    showCost: showCost
                ))
            }
        }
    }

    static func percentageText(_ percentage: Double) -> String {
        String(format: "%.1f%%", percentage)
    }

    static func breakdownText(_ breakdown: StatsTokenBreakdown) -> String {
        "Entrada: \(TokenFormatter.short(breakdown.input)); "
            + "salida: \(TokenFormatter.short(breakdown.output)); "
            + "escritura de caché: \(TokenFormatter.short(breakdown.cacheWrite)); "
            + "lectura de caché: \(TokenFormatter.short(breakdown.cacheRead))"
    }

    static func accessibilityValue(series: StatsSeries, percentage: Double, showCost: Bool) -> String {
        var parts = [
            "\(TokenFormatter.short(series.totalTokens)) tokens",
            "\(percentageText(percentage)) del total",
            breakdownText(series.breakdown)
        ]
        if showCost {
            parts.append("Costo API: \(costText(series))")
        }
        return parts.joined(separator: ". ")
    }

    /// Sin costo conocido se muestra "—" y no "$0.00": cero sería una cifra inventada.
    static func costText(_ series: StatsSeries) -> String {
        series.costUSD > 0 ? TokenFormatter.currency(series.costUSD) : "—"
    }
}
