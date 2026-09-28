import Charts
import SwiftUI

/// Mini gráfica de 7 días, sin ejes ni leyenda. Pensada para vivir dentro de una fila.
struct SparklineView: View {

    private let series: [DayTotal]
    private let tint: Color

    init(series: [DayTotal], tint: Color) {
        self.series = series
        self.tint = tint
    }

    /// Techo de la escala. Sirve también para decidir si hay algo que graficar.
    private var maxTokens: Int {
        series.map(\.tokens).max() ?? 0
    }

    /// Solo se grafica con al menos dos puntos y algo de consumo. Con un punto suelto
    /// `LineMark` no dibuja nada (una línea necesita dos extremos) y con todo en cero la
    /// gráfica queda plana contra el borde: en ambos casos se ve mejor la línea base.
    private var canDrawChart: Bool {
        series.count >= 2 && maxTokens > 0
    }

    var body: some View {
        Group {
            if canDrawChart {
                chart
            } else {
                baseline
            }
        }
        .frame(height: 24)
        .accessibilityElement()
        .accessibilityLabel(trendDescription)
    }

    private var chart: some View {
        Chart(series) { point in
            AreaMark(
                x: .value("Día", point.day),
                y: .value("Tokens", point.tokens)
            )
            .interpolationMethod(.monotone)
            .foregroundStyle(
                LinearGradient(colors: [tint.opacity(0.25), tint.opacity(0)],
                               startPoint: .top,
                               endPoint: .bottom)
            )

            LineMark(
                x: .value("Día", point.day),
                y: .value("Tokens", point.tokens)
            )
            .interpolationMethod(.monotone)
            .foregroundStyle(tint)
            .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartYScale(domain: 0...max(1, maxTokens))
    }

    private var baseline: some View {
        GeometryReader { geometry in
            Path { path in
                let y = geometry.size.height - 1
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: geometry.size.width, y: y))
            }
            .stroke(tint.opacity(0.3), style: StrokeStyle(lineWidth: 1, lineCap: .round))
        }
    }

    private var trendDescription: String {
        guard !series.isEmpty else { return "Sin datos de consumo" }
        guard maxTokens > 0 else { return "Últimos \(series.count) días sin consumo" }
        let today = series.last?.tokens ?? 0
        return "Últimos \(series.count) días. Máximo \(TokenFormatter.short(maxTokens)) tokens, hoy \(TokenFormatter.short(today))"
    }
}

#Preview {
    let days = ["2026-07-28", "2026-07-29", "2026-07-30", "2026-07-31",
                "2026-08-01", "2026-08-02", "2026-08-03"]

    return VStack(alignment: .leading, spacing: 16) {
        // Caso normal.
        SparklineView(
            series: zip(days, [12_000, 48_000, 31_000, 96_000, 74_000, 15_000, 120_000])
                .map { DayTotal(day: $0, tokens: $1) },
            tint: .orange
        )
        .frame(width: 72)

        // Casos degenerados: todo en cero, un solo punto y serie vacía.
        SparklineView(series: days.map { DayTotal(day: $0, tokens: 0) }, tint: .blue)
            .frame(width: 72)

        SparklineView(series: [DayTotal(day: days[0], tokens: 5_000)], tint: .purple)
            .frame(width: 72)

        SparklineView(series: [], tint: .secondary)
            .frame(width: 72)
    }
    .padding()
}
