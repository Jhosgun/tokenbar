import Foundation
import Testing

@testable import TokenBar

@Suite("StatsBuilder")
struct StatsSeriesTests {

    private let days = (0..<5).reversed().map { StatsSupport.day(daysAgo: $0) }

    private func usage(_ source: AppSource, _ daysAgo: Int, input: Int, output: Int = 0,
                       cost: Double = 0) -> UsageRecord {
        UsageRecord(source: source, day: StatsSupport.day(daysAgo: daysAgo),
                    inputTokens: input, outputTokens: output, costUSD: cost)
    }

    private func model(_ name: String, _ source: AppSource, _ daysAgo: Int, input: Int,
                       output: Int = 0, cost: Double = 0) -> ModelUsageRecord {
        ModelUsageRecord(source: source, day: StatsSupport.day(daysAgo: daysAgo), model: name,
                         inputTokens: input, outputTokens: output, costUSD: cost)
    }

    @Test("por herramienta: relleno de ceros, orden fijo y acumulado")
    func porHerramienta() {
        let data = StatsBuilder.build(
            days: days,
            usage: [usage(.opencode, 0, input: 5), usage(.claudeCode, 3, input: 100, output: 20, cost: 1),
                    usage(.claudeCode, 1, input: 50), usage(.cursor, 1, input: 7)],
            models: [], grouping: .tool)

        #expect(data.series.map(\.name) == ["Claude Code", "Cursor", "OpenCode"])
        let claude = data.series[0]
        #expect(claude.daily == [0, 120, 0, 50, 0])
        #expect(claude.cumulative == [0, 120, 120, 170, 170])
        #expect(claude.breakdown.input == 150)
        #expect(claude.breakdown.output == 20)
        #expect(claude.costUSD == 1)
        #expect(data.totalTokens == 182)
    }

    @Test("ignora lo que cae fuera del rango")
    func fueraDeRango() {
        let data = StatsBuilder.build(
            days: days, usage: [usage(.claudeCode, 30, input: 999), usage(.claudeCode, 0, input: 1)],
            models: [model("x", .claudeCode, 30, input: 999)], grouping: .tool)

        #expect(data.totalTokens == 1)
    }

    @Test("sin datos en el rango está vacío")
    func vacio() {
        let data = StatsBuilder.build(days: days, usage: [], models: [], grouping: .model)

        #expect(data.isEmpty)
        #expect(data.series.isEmpty)
        #expect(data.days.count == 5)
    }

    @Test("por modelo: top 8 y el resto en Otros")
    func top8YOtros() {
        let models = (1...10).map { model("m\($0)", .claudeCode, 0, input: $0 * 10) }
        let data = StatsBuilder.build(
            days: days, usage: [usage(.claudeCode, 0, input: 550)], models: models, grouping: .model)

        let names = data.series.map(\.name)
        #expect(names == ["m10", "m9", "m8", "m7", "m6", "m5", "m4", "m3", "Otros"])
        #expect(data.series.last?.kind == .other)
        #expect(data.series.last?.totalTokens == 30)
        #expect(data.totalTokens == 550)
    }

    @Test("el mismo modelo en dos herramientas es una sola banda")
    func mismoModelo() {
        let data = StatsBuilder.build(
            days: days,
            usage: [usage(.claudeCode, 0, input: 10), usage(.commandCode, 0, input: 5)],
            models: [model("opus", .claudeCode, 0, input: 10), model("opus", .commandCode, 0, input: 5)],
            grouping: .model)

        #expect(data.series.map(\.name) == ["opus"])
        #expect(data.series[0].totalTokens == 15)
    }

    @Test("sin desglose: lo no atribuido a modelos, nunca negativo, y la suma coincide")
    func sinDesglose() {
        let usageRecords = [
            usage(.claudeCode, 3, input: 100, cost: 2),          // historia sin modelos
            usage(.claudeCode, 0, input: 60, output: 40, cost: 1),
            usage(.codex, 0, input: 30)                          // atribuido de más
        ]
        let models = [
            model("opus", .claudeCode, 0, input: 50, output: 40, cost: 0.4),
            model("gpt", .codex, 0, input: 45)
        ]

        let byModel = StatsBuilder.build(days: days, usage: usageRecords, models: models, grouping: .model)
        let byTool = StatsBuilder.build(days: days, usage: usageRecords, models: [], grouping: .tool)

        let claude = byModel.series.first { $0.kind == .undisclosed(.claudeCode) }
        #expect(claude?.name == "Claude Code · sin desglose")
        #expect(claude?.daily == [0, 100, 0, 0, 10])
        #expect(abs((claude?.costUSD ?? 0) - 2.6) < 1e-9)
        #expect(byModel.series.first { $0.kind == .undisclosed(.codex) } == nil)
        // Con el exceso de Codex (45 atribuidos contra 30 de total) las sumas difieren en 15.
        #expect(byModel.totalTokens == byTool.totalTokens + 15)
    }

    @Test("la suma por modelo iguala la suma por herramienta cuando los modelos no se pasan")
    func sumasIguales() {
        let usageRecords = [usage(.claudeCode, 4, input: 80), usage(.claudeCode, 0, input: 100),
                            usage(.cursor, 0, input: 20), usage(.opencode, 2, input: 9)]
        let models = [model("opus", .claudeCode, 0, input: 70), model("grok", .cursor, 0, input: 20)]

        let byModel = StatsBuilder.build(days: days, usage: usageRecords, models: models, grouping: .model)
        let byTool = StatsBuilder.build(days: days, usage: usageRecords, models: [], grouping: .tool)

        #expect(byModel.totalTokens == byTool.totalTokens)
        for index in days.indices {
            let model = byModel.series.reduce(0) { $0 + $1.daily[index] }
            let tool = byTool.series.reduce(0) { $0 + $1.daily[index] }
            #expect(model == tool)
        }
    }
}
