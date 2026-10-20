import SwiftUI

/// Sección "Semana" del popover: una barra por cada uno de los últimos 7 días (terminando
/// hoy, la misma ventana que ya usa `SparklineView` en cada fila), el total y el promedio
/// diario en la cabecera, y la racha de días consecutivos con consumo debajo.
///
/// Se usan "los últimos 7 días" en vez de lunes-domingo: es la ventana que ya existe en
/// `UsageSnapshot.last7DaysByApp` (y en cada sparkline), así que hoy siempre es la última
/// barra sin importar qué día de la semana sea, y no hace falta pedirle al store más datos
/// de los que ya trae.
struct WeekSummaryView: View {
    let snapshot: UsageSnapshot
    @State private var selectedDay: String?

    private var days: [DayTotal] { snapshot.weekTotals }
    private var maxTokens: Int { days.map(\.tokens).max() ?? 0 }
    private var today: String { DayKey.today() }
    private var selectedDayTotal: DayTotal? { days.first { $0.day == selectedDay } }

    init(snapshot: UsageSnapshot, selectedDay: String? = nil) {
        self.snapshot = snapshot
        _selectedDay = State(
            initialValue: selectedDay.flatMap { selected in
                snapshot.weekTotals.contains { $0.day == selected } ? selected : nil
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            bars
            streakLine
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - Cabecera

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Semana")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer(minLength: 4)

            Text(Self.headerText(snapshot: snapshot, selectedDay: selectedDayTotal))
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .combine)
    }

    nonisolated static func headerText(snapshot: UsageSnapshot, selectedDay: DayTotal?) -> String {
        guard let selectedDay else {
            return "\(TokenFormatter.short(snapshot.weekTotalTokens)) · prom. \(TokenFormatter.short(snapshot.weekAverageTokens))"
        }
        guard let date = DayKey.date(from: selectedDay.day) else {
            return "\(selectedDay.day) · \(TokenFormatter.short(selectedDay.tokens))"
        }
        let locale = Locale(identifier: "es")
        let weekday = date.formatted(.dateTime.weekday(.abbreviated).locale(locale))
        let dayAndMonth = date.formatted(.dateTime.day().month(.abbreviated).locale(locale))
        return "\(weekday) \(dayAndMonth) · \(TokenFormatter.short(selectedDay.tokens))"
    }

    // MARK: - Barras

    private var bars: some View {
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(days) { day in
                dayBar(day)
            }
        }
        .frame(height: 36)
    }

    private func dayBar(_ day: DayTotal) -> some View {
        let isToday = day.day == today
        let isSelected = day.day == selectedDay
        let ratio = maxTokens > 0 ? Double(day.tokens) / Double(maxTokens) : 0

        return Button {
            selectedDay = isSelected ? nil : day.day
        } label: {
            VStack(spacing: 3) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(barColor(isToday: isToday, isSelected: isSelected))
                    .overlay {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(Color.primary, lineWidth: 1)
                        }
                    }
                    .frame(height: max(2, 36 * ratio))
                    .frame(maxHeight: 36, alignment: .bottom)

                Text(weekdayLetter(day.day))
                    .font(.system(size: 8, weight: isToday || isSelected ? .semibold : .regular))
                    .foregroundStyle(isToday || isSelected ? .primary : .secondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(displayDate(day.day)): \(TokenFormatter.short(day.tokens)) tokens")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(displayDate(day.day)), \(TokenFormatter.short(day.tokens)) tokens")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func barColor(isToday: Bool, isSelected: Bool) -> Color {
        if isToday { return Color.accentColor }
        return Color.secondary.opacity(isSelected ? 0.7 : 0.35)
    }

    private func weekdayLetter(_ day: String) -> String {
        guard let date = DayKey.date(from: day) else { return "" }
        return date.formatted(.dateTime.weekday(.narrow).locale(Locale(identifier: "es")))
    }

    private func displayDate(_ day: String) -> String {
        guard let date = DayKey.date(from: day) else { return day }
        return date.formatted(
            .dateTime.day().month(.abbreviated).year().locale(Locale(identifier: "es"))
        )
    }

    // MARK: - Racha

    private var streakLine: some View {
        HStack(spacing: 4) {
            Image(systemName: "flame.fill")
                .font(.caption2)
                .foregroundStyle(snapshot.currentStreak > 0 ? .orange : .secondary)

            Text(streakText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Spacer(minLength: 4)

            if snapshot.bestStreak > 0 {
                Text("Mejor: \(snapshot.bestStreak)d")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(streakAccessibilityLabel)
    }

    private var streakText: String {
        switch snapshot.currentStreak {
        case 0: "Sin racha"
        case 1: "1 día seguido"
        default: "\(snapshot.currentStreak) días seguidos"
        }
    }

    private var streakAccessibilityLabel: String {
        snapshot.bestStreak > 0 ? "\(streakText). Mejor racha: \(snapshot.bestStreak) días" : streakText
    }
}

#Preview("Sin selección") {
    WeekSummaryView(snapshot: previewSnapshot)
        .frame(width: 276)
        .padding(12)
}

#Preview("Día seleccionado") {
    let days = DayKey.lastDays(7)
    WeekSummaryView(snapshot: previewSnapshot, selectedDay: days[3])
        .frame(width: 276)
        .padding(12)
}

private let previewSnapshot: UsageSnapshot = {
    let days = DayKey.lastDays(7)
    let tokens = [12_000, 48_000, 0, 96_000, 74_000, 15_000, 120_000]
    var byApp: [AppSource: [DayTotal]] = [:]
    for source in AppSource.allCases {
        byApp[source] = zip(days, tokens).map { DayTotal(day: $0, tokens: source == .claudeCode ? $1 : 0) }
    }

    return UsageSnapshot(
        todayByApp: [:],
        last7DaysByApp: byApp,
        todayTotalTokens: tokens.last ?? 0,
        todayCostUSD: 0,
        currentStreak: 4,
        bestStreak: 9
    )
}()
