import Foundation

struct ModelUsageRecord: Codable, Hashable, Sendable {
    var source: AppSource
    var day: String
    var model: String
    var inputTokens: Int
    var outputTokens: Int
    var cacheCreationTokens: Int
    var cacheReadTokens: Int
    var costUSD: Double

    var totalTokens: Int {
        inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens
    }

    init(source: AppSource, day: String, model: String, inputTokens: Int = 0,
         outputTokens: Int = 0, cacheCreationTokens: Int = 0,
         cacheReadTokens: Int = 0, costUSD: Double = 0) {
        self.source = source
        self.day = day
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
        self.costUSD = costUSD
    }

    static func + (lhs: ModelUsageRecord, rhs: ModelUsageRecord) -> ModelUsageRecord {
        assert(lhs.source == rhs.source && lhs.day == rhs.day && lhs.model == rhs.model,
               "ModelUsageRecord.+ requiere mismo source, día y modelo")
        return ModelUsageRecord(
            source: lhs.source,
            day: lhs.day,
            model: lhs.model,
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            cacheCreationTokens: lhs.cacheCreationTokens + rhs.cacheCreationTokens,
            cacheReadTokens: lhs.cacheReadTokens + rhs.cacheReadTokens,
            costUSD: lhs.costUSD + rhs.costUSD
        )
    }
}
