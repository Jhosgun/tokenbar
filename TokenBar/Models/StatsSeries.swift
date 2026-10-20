import Foundation

/// Cómo se reparten las bandas de la gráfica de Estadísticas.
enum StatsGrouping: String, CaseIterable, Identifiable, Sendable {
    case tool
    case model

    var id: String { rawValue }

    var label: String {
        switch self {
        case .tool: "Herramienta"
        case .model: "Modelo"
        }
    }
}

/// Los cuatro tipos de token de una serie.
struct StatsTokenBreakdown: Equatable, Sendable {
    var input = 0
    var output = 0
    var cacheWrite = 0
    var cacheRead = 0

    var total: Int { input + output + cacheWrite + cacheRead }

    mutating func add(_ record: UsageRecord) {
        input += record.inputTokens
        output += record.outputTokens
        cacheWrite += record.cacheCreationTokens
        cacheRead += record.cacheReadTokens
    }

    mutating func add(_ record: ModelUsageRecord) {
        input += record.inputTokens
        output += record.outputTokens
        cacheWrite += record.cacheCreationTokens
        cacheRead += record.cacheReadTokens
    }

    static func + (lhs: Self, rhs: Self) -> Self {
        Self(input: lhs.input + rhs.input, output: lhs.output + rhs.output,
             cacheWrite: lhs.cacheWrite + rhs.cacheWrite, cacheRead: lhs.cacheRead + rhs.cacheRead)
    }

    /// Componente a componente, sin bajar de cero: el desglose de lo que un total tiene de más
    /// sobre lo atribuido a modelos.
    func subtractingClamped(_ other: Self) -> Self {
        Self(input: max(0, input - other.input), output: max(0, output - other.output),
             cacheWrite: max(0, cacheWrite - other.cacheWrite),
             cacheRead: max(0, cacheRead - other.cacheRead))
    }
}

/// Una banda de la gráfica: una herramienta, un modelo, "Otros" o el consumo de una
/// herramienta que todavía no se podía atribuir a un modelo.
struct StatsSeries: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case tool(AppSource)
        case model(String)
        /// Los modelos fuera del top, agrupados.
        case other
        /// Tokens de una herramienta anteriores a que emitiera desglose por modelo.
        case undisclosed(AppSource)
    }

    var kind: Kind
    var name: String
    /// Tokens de cada día de `StatsData.days`, en el mismo orden.
    var daily: [Int]
    var breakdown: StatsTokenBreakdown
    var costUSD: Double

    var id: String {
        switch kind {
        case .tool(let source): "tool:\(source.rawValue)"
        case .model(let model): "model:\(model)"
        case .other: "other"
        case .undisclosed(let source): "undisclosed:\(source.rawValue)"
        }
    }

    var totalTokens: Int { daily.reduce(0, +) }

    /// Tokens acumulados hasta cada día.
    var cumulative: [Int] {
        var running = 0
        return daily.map { running += $0; return running }
    }
}

/// Las series de un rango de días, listas para graficar y para la tabla.
struct StatsData: Equatable, Sendable {
    /// Días del rango del más viejo al más nuevo, con los vacíos incluidos.
    var days: [String]
    var series: [StatsSeries]

    var totalTokens: Int { series.reduce(0) { $0 + $1.totalTokens } }
    var isEmpty: Bool { totalTokens == 0 }
}

enum StatsBuilder {
    /// Modelos con nombre propio; el resto se agrupa en "Otros".
    static let maxModels = 8

    /// Arma las series de `days` a partir de lo que guardan `UsageStore` (total por
    /// herramienta, autoritativo) y `ModelUsageStore` (reparto por modelo).
    ///
    /// Al agrupar por modelo, lo que una herramienta tiene de más sobre lo atribuido a sus
    /// modelos ese día (nunca negativo) sale como la serie "<Herramienta> · sin desglose": así
    /// la suma de la gráfica por modelo coincide con la de la gráfica por herramienta.
    static func build(days: [String], usage: [UsageRecord], models: [ModelUsageRecord],
                      grouping: StatsGrouping) -> StatsData {
        let index = Dictionary(uniqueKeysWithValues: days.enumerated().map { ($1, $0) })
        let usage = usage.filter { index[$0.day] != nil && $0.source.hasTokenSource }
        let series: [StatsSeries]
        switch grouping {
        case .tool:
            series = toolSeries(days: days, index: index, usage: usage)
        case .model:
            let models = models.filter { index[$0.day] != nil }
            series = modelSeries(days: days, index: index, usage: usage, models: models)
        }
        return StatsData(days: days, series: series.filter { $0.totalTokens > 0 })
    }

    private static func toolSeries(days: [String], index: [String: Int],
                                   usage: [UsageRecord]) -> [StatsSeries] {
        AppSource.tokenSources.map { source in
            var series = StatsSeries(kind: .tool(source), name: source.displayName,
                                     daily: Array(repeating: 0, count: days.count),
                                     breakdown: StatsTokenBreakdown(), costUSD: 0)
            for record in usage where record.source == source {
                series.daily[index[record.day]!] += record.totalTokens
                series.breakdown.add(record)
                series.costUSD += record.costUSD
            }
            return series
        }
    }

    private static func modelSeries(days: [String], index: [String: Int], usage: [UsageRecord],
                                    models: [ModelUsageRecord]) -> [StatsSeries] {
        let empty = StatsSeries(kind: .other, name: "Otros",
                                daily: Array(repeating: 0, count: days.count),
                                breakdown: StatsTokenBreakdown(), costUSD: 0)

        // Un acumulado por nombre de modelo (el mismo modelo en dos herramientas es una banda).
        var byModel: [String: StatsSeries] = [:]
        // Lo ya atribuido a modelos por (herramienta, día), para restarlo del total.
        var attributed: [AppSource: [String: (tokens: Int, breakdown: StatsTokenBreakdown, cost: Double)]] = [:]
        for record in models {
            var series = byModel[record.model] ?? {
                var fresh = empty
                fresh.kind = .model(record.model)
                fresh.name = record.model
                return fresh
            }()
            series.daily[index[record.day]!] += record.totalTokens
            series.breakdown.add(record)
            series.costUSD += record.costUSD
            byModel[record.model] = series

            var cell = attributed[record.source, default: [:]][record.day]
                ?? (tokens: 0, breakdown: StatsTokenBreakdown(), cost: 0)
            cell.tokens += record.totalTokens
            cell.breakdown.add(record)
            cell.cost += record.costUSD
            attributed[record.source, default: [:]][record.day] = cell
        }

        // Los de más tokens primero; el nombre desempata para que el orden sea estable.
        let ranked = byModel.values.sorted {
            ($0.totalTokens, $1.name) > ($1.totalTokens, $0.name)
        }
        var result = Array(ranked.prefix(maxModels))
        var rest = empty
        for series in ranked.dropFirst(maxModels) {
            rest.daily = zip(rest.daily, series.daily).map(+)
            rest.breakdown = rest.breakdown + series.breakdown
            rest.costUSD += series.costUSD
        }
        if rest.totalTokens > 0 { result.append(rest) }

        for source in AppSource.tokenSources {
            var series = empty
            series.kind = .undisclosed(source)
            series.name = "\(source.displayName) · sin desglose"
            var total: [String: (breakdown: StatsTokenBreakdown, cost: Double)] = [:]
            for record in usage where record.source == source {
                var cell = total[record.day] ?? (StatsTokenBreakdown(), 0)
                cell.breakdown.add(record)
                cell.cost += record.costUSD
                total[record.day] = cell
            }
            for (day, cell) in total {
                let known = attributed[source]?[day]
                series.daily[index[day]!] = max(0, cell.breakdown.total - (known?.tokens ?? 0))
                series.breakdown = series.breakdown
                    + cell.breakdown.subtractingClamped(known?.breakdown ?? StatsTokenBreakdown())
                series.costUSD += max(0, cell.cost - (known?.cost ?? 0))
            }
            result.append(series)
        }
        return result
    }
}
