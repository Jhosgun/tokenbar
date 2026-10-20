import Charts
import SwiftUI

/// La gráfica de Estadísticas: área apilada de tokens acumulados o barras apiladas por día,
/// una banda por serie y una regla con el valor de cada serie al pasar el cursor. No sabe de
/// datos en vivo: recibe las series ya armadas y sus colores.
struct StatsChartView: View {
    let data: StatsData
    let kind: StatsChartKind
    let colors: [String: Color]

    @State private var hoveredIndex: Int?

    /// `hoveredDay` fija la regla desde el inicio: lo usan las vistas previas y el snapshot.
    init(data: StatsData, kind: StatsChartKind, colors: [String: Color], hoveredDay: String? = nil) {
        self.data = data
        self.kind = kind
        self.colors = colors
        _hoveredIndex = State(initialValue: hoveredDay.flatMap { data.days.firstIndex(of: $0) })
    }

    private static let spanish = Locale(identifier: "es")

    /// Un día como `Date` (mediodía local) por cada día del rango. Si el calendario no lo
    /// resuelve, ese día cae en el epoch y simplemente no se ve: no rompe la gráfica.
    private var dates: [Date] {
        data.days.map { DayKey.date(from: $0) ?? Date(timeIntervalSince1970: 0) }
    }

    private struct Point: Identifiable {
        var series: String
        var date: Date
        var tokens: Int
        var yStart: Int
        var yEnd: Int
        var id: String { "\(series)|\(date.timeIntervalSince1970)" }
    }

    /// Un punto por serie y día, con el valor que dibuja la gráfica elegida.
    private var points: [Point] {
        let dates = dates
        if kind == .daily {
            return data.series.flatMap { series -> [Point] in
                zip(dates, series.daily).map {
                    Point(series: series.name, date: $0, tokens: $1, yStart: 0, yEnd: $1)
                }
            }
        }

        var totals = Array(repeating: 0, count: dates.count)
        return data.series.flatMap { series -> [Point] in
            zip(dates.indices, zip(dates, series.cumulative)).map { index, value in
                let yStart = totals[index]
                totals[index] += value.1
                return Point(series: series.name, date: value.0, tokens: value.1,
                             yStart: yStart, yEnd: totals[index])
            }
        }
    }

    /// Tres fechas representativas dejan espacio suficiente a los rótulos en 276 pt.
    /// En barras la marca va a mediodía: ahí queda centrada la barra del día, no su borde.
    private var tickDates: [Date] {
        guard !dates.isEmpty else { return [] }
        let last = dates.count - 1
        let rightInset = max(1, dates.count / 6)
        let right = max(0, last - rightInset)
        let indices = Array(Set([0, last / 2, right])).sorted()
        let shift: TimeInterval = kind == .daily ? 12 * 3600 : 0
        return indices.map { dates[$0].addingTimeInterval(shift) }
    }

    var body: some View {
        chart
    }

    private var chart: some View {
        let names = data.series.map(\.name)
        let palette = names.map { colors[$0] ?? .gray }
        return Chart {
            ForEach(points) { point in
                switch kind {
                case .accumulated:
                    AreaMark(x: .value("Día", point.date),
                             yStart: .value("Inicio", point.yStart),
                             yEnd: .value("Fin", point.yEnd))
                        .foregroundStyle(by: .value("Serie", point.series))
                        .interpolationMethod(.linear)
                        .opacity(0.55)
                case .daily:
                    BarMark(x: .value("Día", point.date, unit: .day),
                            y: .value("Tokens", point.tokens),
                            width: .ratio(0.8))
                        .foregroundStyle(by: .value("Serie", point.series))
                        .opacity(0.55)
                }
            }
            if kind == .accumulated {
                ForEach(points) { point in
                    LineMark(x: .value("Día", point.date),
                             y: .value("Tokens", point.yEnd))
                        .foregroundStyle(by: .value("Serie", point.series))
                        .interpolationMethod(.linear)
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
            if let index = hoveredIndex, dates.indices.contains(index) {
                RuleMark(x: .value("Día", dates[index], unit: .day))
                    .foregroundStyle(.secondary.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, spacing: 4,
                                overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        tooltip(at: index)
                    }
            }
        }
        .chartForegroundStyleScale(domain: names, range: palette)
        .chartLegend(.hidden)
        .chartPlotStyle { $0.padding(.horizontal, 8) }
        .chartXAxis {
            AxisMarks(values: tickDates) { value in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisTick().foregroundStyle(.quaternary)
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(date.formatted(.dateTime.day().month(.abbreviated).locale(Self.spanish)))
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel {
                    if let tokens = value.as(Int.self) {
                        Text(TokenFormatter.short(tokens)).monospacedDigit()
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let plot = proxy.plotFrame else { return }
                            let x = location.x - geometry[plot].origin.x
                            hoveredIndex = proxy.value(atX: x, as: Date.self).flatMap(nearestIndex)
                        case .ended:
                            hoveredIndex = nil
                        }
                    }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(kind == .accumulated ? "Tokens acumulados por día" : "Tokens por día")
        .accessibilityValue("\(TokenFormatter.short(data.totalTokens)) tokens en \(data.days.count) días")
    }

    /// "Jueves, 1 de octubre": el formato en español va en minúsculas y solo se sube la inicial.
    private static func dayTitle(_ date: Date) -> String {
        let text = date.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(spanish))
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    /// Índice del día más cercano a la fecha bajo el cursor.
    private func nearestIndex(to date: Date) -> Int? {
        dates.indices.min { abs(dates[$0].timeIntervalSince(date)) < abs(dates[$1].timeIntervalSince(date)) }
    }

    /// Valor de cada serie con consumo ese día (o hasta ese día, en el acumulado).
    private func tooltip(at index: Int) -> some View {
        let rows = data.series
            .map { (series: $0, value: kind == .accumulated ? $0.cumulative[index] : $0.daily[index]) }
            .filter { $0.value > 0 }
            .sorted { $0.value > $1.value }
        let total = rows.reduce(0) { $0 + $1.value }
        let visibleRows = Array(rows.prefix(5))
        return VStack(alignment: .leading, spacing: 2) {
            Text(Self.dayTitle(dates[index]))
                .font(.caption.weight(.semibold))
            ForEach(visibleRows, id: \.series.id) { row in
                HStack(spacing: 6) {
                    Circle().fill(colors[row.series.name] ?? .gray).frame(width: 8, height: 8)
                    Text(row.series.name)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 6)
                    Text(TokenFormatter.short(row.value))
                        .monospacedDigit()
                        .fixedSize()
                }
                .font(.caption)
            }
            if rows.count > visibleRows.count {
                Text("y \(rows.count - visibleRows.count) más")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if rows.count > 1 {
                Divider()
                HStack {
                    Text("Total")
                    Spacer(minLength: 12)
                    Text(TokenFormatter.short(total)).monospacedDigit()
                }
                .font(.caption.weight(.semibold))
            }
        }
        .padding(8)
        .frame(width: 210)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(.quaternary))
    }
}
