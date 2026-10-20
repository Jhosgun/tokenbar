import AppKit
import SwiftUI
import Testing

@testable import TokenBar

/// Renderiza la gráfica y la tabla compacta de Estadísticas con datos sintéticos a PNG para
/// revisarlas a ojo. El test comprueba que cada imagen se genera y no está vacía.
@Suite("Snapshots de Estadísticas")
@MainActor
struct StatsSnapshotTests {

    static let outputDirectory = FileManager.default.temporaryDirectory
        .appending(path: "tokenbar-stats-snapshots", directoryHint: .isDirectory)

    /// Consumo determinista: cada herramienta tiene su ritmo, con días en cero y un pico.
    private static func syntheticUsage(days: [String]) -> (usage: [UsageRecord], models: [ModelUsageRecord]) {
        let scale: [AppSource: Int] = [.claudeCode: 90_000_000, .cursor: 12_000_000, .codex: 30_000_000,
                                       .commandCode: 6_000_000, .opencode: 2_500_000]
        var usage: [UsageRecord] = []
        var models: [ModelUsageRecord] = []
        let modelsByTool: [AppSource: [(String, Double)]] = [
            .claudeCode: [("claude-opus-5-5", 0.45), ("claude-sonnet-5-5", 0.3), ("claude-haiku-4-5", 0.1),
                          ("claude-fable-5-1", 0.15)],
            .cursor: [("grok-4.6-high", 0.6), ("composer-2", 0.25), ("default", 0.15)],
            .codex: [("gpt-5.6-sol", 0.8), ("gpt-5.5-mini", 0.2)],
            .commandCode: [("gpt-5.6-sol", 0.5), ("zai-org/GLM-5.2", 0.3), ("Qwen3.5-27B", 0.2)],
            .opencode: [("kimi-k3", 0.7), ("glm-5.2", 0.3)]
        ]
        let spikeIndex = days.count * 3 / 4
        for (dayIndex, day) in days.enumerated() {
            for (toolIndex, source) in AppSource.tokenSources.enumerated() {
                // Fines de semana más bajos y un día vacío por herramienta.
                if (dayIndex + toolIndex) % 11 == 0 { continue }
                let wave = 0.55 + 0.45 * sin(Double(dayIndex) * 0.7 + Double(toolIndex))
                let spike = dayIndex == spikeIndex && source == .claudeCode ? 2.2 : 1.0
                let total = Int(Double(scale[source]!) * wave * spike)
                usage.append(UsageRecord(source: source, day: day,
                                         inputTokens: total / 50, outputTokens: total / 100,
                                         cacheCreationTokens: total / 20,
                                         cacheReadTokens: total - total / 50 - total / 100 - total / 20,
                                         costUSD: source == .codex ? 0 : Double(total) / 1_000_000 * 0.4))
                // Claude Code solo trae desglose por modelo los últimos 12 días.
                if source == .claudeCode && dayIndex < days.count - 12 { continue }
                // El último modelo se lleva el resto: la suma por modelo cuadra con el total exacto.
                let base = usage.last!
                var remaining = base
                let shares = modelsByTool[source]!
                for (index, (name, share)) in shares.enumerated() {
                    let isLast = index == shares.count - 1
                    func part(_ whole: Int, _ left: Int) -> Int { isLast ? left : Int(Double(whole) * share) }
                    let record = ModelUsageRecord(
                        source: source, day: day, model: name,
                        inputTokens: part(base.inputTokens, remaining.inputTokens), outputTokens: part(base.outputTokens, remaining.outputTokens),
                        cacheCreationTokens: part(base.cacheCreationTokens, remaining.cacheCreationTokens),
                        cacheReadTokens: part(base.cacheReadTokens, remaining.cacheReadTokens),
                        costUSD: isLast ? remaining.costUSD : base.costUSD * share)
                    models.append(record)
                    remaining.inputTokens -= record.inputTokens
                    remaining.outputTokens -= record.outputTokens
                    remaining.cacheCreationTokens -= record.cacheCreationTokens
                    remaining.cacheReadTokens -= record.cacheReadTokens
                    remaining.costUSD -= record.costUSD
                }
            }
        }
        return (usage, models)
    }

    private func render(_ grouping: StatsGrouping, _ kind: StatsChartKind, _ scheme: ColorScheme,
                        range: StatsRange = .month, hoveredDayIndex: Int? = nil, name: String) throws {
        let days = DayKey.lastDays(range.rawValue)
        let input = Self.syntheticUsage(days: days)
        let data = StatsBuilder.build(days: days, usage: input.usage, models: input.models,
                                      grouping: grouping)
        var assigner = StatsColorAssigner()
        let colors = assigner.colors(for: data)
        let hoveredDay = hoveredDayIndex.flatMap { days.indices.contains($0) ? days[$0] : nil }

        let content = VStack(alignment: .leading, spacing: 10) {
            StatsChartView(data: data, kind: kind, colors: colors, hoveredDay: hoveredDay)
                .frame(height: 150)
            StatsTableView(data: data, colors: colors, showCost: true)
        }
        .padding(12)
        .frame(width: 300, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, scheme)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: Self.outputDirectory, withIntermediateDirectories: true)
        let url = Self.outputDirectory.appending(path: "\(name).png")
        try png.write(to: url)
        #expect(png.count > 10_000, "\(name).png salió vacío")
    }

    @Test("por herramienta, acumulado y por día, en claro y oscuro")
    func porHerramienta() throws {
        try render(.tool, .accumulated, .light, name: "herramienta-acumulado-claro")
        try render(.tool, .accumulated, .dark, name: "herramienta-acumulado-oscuro")
        try render(.tool, .daily, .light, name: "herramienta-diario-claro")
        try render(.tool, .daily, .dark, name: "herramienta-diario-oscuro")
    }

    @Test("por modelo, acumulado y por día, en claro y oscuro")
    func porModelo() throws {
        try render(.model, .accumulated, .light, name: "modelo-acumulado-claro")
        try render(.model, .accumulated, .dark, name: "modelo-acumulado-oscuro")
        try render(.model, .daily, .light, name: "modelo-diario-claro")
        try render(.model, .daily, .dark, name: "modelo-diario-oscuro")
    }

    @Test("con la regla del cursor y su tooltip")
    func conRegla() throws {
        try render(.tool, .accumulated, .light, hoveredDayIndex: 18,
                   name: "herramienta-acumulado-regla")
        try render(.model, .daily, .dark, hoveredDayIndex: 26,
                   name: "modelo-diario-regla-oscuro")
    }

    @Test("eje X en 7 y 90 días")
    func rangosExtremos() throws {
        try render(.tool, .daily, .light, range: .week,
                   name: "herramienta-diario-7-dias-claro")
        try render(.model, .accumulated, .dark, range: .quarter,
                   name: "modelo-acumulado-90-dias-oscuro")
    }
}
