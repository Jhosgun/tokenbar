import Testing

@testable import TokenBar

@Suite("Resumen semanal")
struct WeekSummaryViewTests {

    @Test("sin selección muestra total y promedio")
    func sinSeleccion() {
        #expect(WeekSummaryView.headerText(snapshot: snapshot, selectedDay: nil)
                == "489.5M · prom. 69.9M")
    }

    @Test("con selección muestra la fecha corta y sus tokens")
    func conSeleccion() {
        let day = DayTotal(day: "2026-10-04", tokens: 180_200_000)

        #expect(WeekSummaryView.headerText(snapshot: snapshot, selectedDay: day)
                == "dom 4 oct · 180.2M")
    }

    @Test("un día seleccionado sin consumo muestra cero")
    func seleccionEnCero() {
        let day = DayTotal(day: "2026-10-02", tokens: 0)

        #expect(WeekSummaryView.headerText(snapshot: snapshot, selectedDay: day)
                == "vie 2 oct · 0")
    }

    private var snapshot: UsageSnapshot {
        let days = [
            DayTotal(day: "2026-09-29", tokens: 50_000_000),
            DayTotal(day: "2026-09-30", tokens: 60_000_000),
            DayTotal(day: "2026-10-01", tokens: 70_000_000),
            DayTotal(day: "2026-10-02", tokens: 0),
            DayTotal(day: "2026-10-03", tokens: 80_000_000),
            DayTotal(day: "2026-10-04", tokens: 180_200_000),
            DayTotal(day: "2026-10-05", tokens: 49_300_000)
        ]
        return UsageSnapshot(
            todayByApp: [:],
            last7DaysByApp: [.claudeCode: days],
            todayTotalTokens: days.last?.tokens ?? 0,
            todayCostUSD: 0,
            currentStreak: 3,
            bestStreak: 8
        )
    }
}
