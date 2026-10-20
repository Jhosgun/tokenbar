import Foundation

/// Agrupa deltas por (día, modelo) y arma el `CollectorResult` de un collector con desglose.
///
/// Garantiza el invariante del contrato: `records` sale de sumar `modelRecords` por día,
/// así que para cada (source, día) ambos coinciden siempre.
struct ModelUsageAccumulator {
    private struct Key: Hashable {
        var day: String
        var model: String
    }

    let source: AppSource
    private var byKey: [Key: ModelUsageRecord] = [:]

    init(source: AppSource) {
        self.source = source
    }

    var isEmpty: Bool { byKey.isEmpty }

    /// Ignora los deltas sin tokens ni costo: no aportan nada a ninguna gráfica. (Un delta
    /// con costo y sin tokens solo lo produce Cursor, cuando un evento ya cerrado ajusta
    /// sus centavos; en los demás collectors el costo sale de los tokens.)
    mutating func add(day: String, model: String, inputTokens: Int, outputTokens: Int,
                      cacheCreationTokens: Int, cacheReadTokens: Int, costUSD: Double) {
        let delta = ModelUsageRecord(
            source: source, day: day, model: model,
            inputTokens: inputTokens, outputTokens: outputTokens,
            cacheCreationTokens: cacheCreationTokens, cacheReadTokens: cacheReadTokens,
            costUSD: costUSD
        )
        guard delta.totalTokens > 0 || delta.costUSD > 0 else { return }
        let key = Key(day: day, model: model)
        byKey[key] = byKey[key].map { $0 + delta } ?? delta
    }

    func result(status: CollectorStatus = .ok) -> CollectorResult {
        let modelRecords = byKey.values.sorted { ($0.day, $0.model) < ($1.day, $1.model) }
        var byDay: [String: UsageRecord] = [:]
        for model in modelRecords {
            let delta = UsageRecord(
                source: source, day: model.day,
                inputTokens: model.inputTokens, outputTokens: model.outputTokens,
                cacheCreationTokens: model.cacheCreationTokens,
                cacheReadTokens: model.cacheReadTokens, costUSD: model.costUSD
            )
            byDay[model.day] = byDay[model.day].map { $0 + delta } ?? delta
        }
        let records = byDay.values.sorted { $0.day < $1.day }
        return CollectorResult(records: records, status: status, modelRecords: modelRecords)
    }
}

/// Retención de `UsageStore`: lo anterior a esta fecha se ignora, también en el bootstrap.
enum UsageRetention {
    static let days = 90

    /// Primer día (inclusive) que se conserva, en "yyyy-MM-dd" local.
    static func cutoffDay(now: Date = Date(), calendar: Calendar = .current) -> String {
        let cutoff = calendar.date(byAdding: .day, value: -days, to: now) ?? now
        return DayKey.string(from: cutoff, calendar: calendar)
    }
}
