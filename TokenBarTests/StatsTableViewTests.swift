import Testing

@testable import TokenBar

@Suite("Tabla compacta de Estadísticas")
struct StatsTableViewTests {

    @Test("el reparto incluye los cuatro tipos de token")
    func reparto() {
        let breakdown = StatsTokenBreakdown(input: 1_200, output: 340,
                                             cacheWrite: 5_600, cacheRead: 78_900)

        #expect(StatsTableView.breakdownText(breakdown)
                == "Entrada: 1.2K; salida: 340; escritura de caché: 5.6K; lectura de caché: 78.9K")
    }

    @Test("el porcentaje conserva un decimal")
    func porcentaje() {
        #expect(StatsTableView.percentageText(25) == "25.0%")
        #expect(StatsTableView.percentageText(0) == "0.0%")
    }

    @Test("el costo desconocido usa guion y el conocido conserva moneda")
    func costo() {
        let unknown = StatsSeries(kind: .model("sin tarifa"), name: "sin tarifa", daily: [10],
                                  breakdown: StatsTokenBreakdown(input: 10), costUSD: 0)
        let known = StatsSeries(kind: .model("con tarifa"), name: "con tarifa", daily: [10],
                                breakdown: StatsTokenBreakdown(input: 10), costUSD: 1.25)

        #expect(StatsTableView.costText(unknown) == "—")
        #expect(StatsTableView.costText(known) == "$1.25")
    }

    @Test("el valor accesible incluye el costo solo cuando se muestra")
    func valorAccesible() {
        let series = StatsSeries(kind: .model("modelo"), name: "modelo", daily: [1_000],
                                 breakdown: StatsTokenBreakdown(input: 600, output: 400), costUSD: 1.25)
        let base = "1.0K tokens. 25.0% del total. Entrada: 600; salida: 400; "
            + "escritura de caché: 0; lectura de caché: 0"

        #expect(StatsTableView.accessibilityValue(series: series, percentage: 25, showCost: false) == base)
        #expect(StatsTableView.accessibilityValue(series: series, percentage: 25, showCost: true)
                == "\(base). Costo API: $1.25")
    }
}
