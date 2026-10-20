import Foundation
import Testing

@testable import TokenBar

/// Utilidades comunes de los tests de los collectors con desglose por modelo.
/// Todo vive en directorios temporales: nunca se toca `~/Library` ni datos reales.
enum StatsSupport {
    static func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Mediodía local de hace `daysAgo` días, en ISO-8601: cae siempre en ese día local.
    static func isoTimestamp(daysAgo: Int, hour: Int = 12) -> String {
        let calendar = Calendar.current
        let base = calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: Date()))!
        let date = calendar.date(byAdding: .hour, value: hour, to: base)!
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func day(daysAgo: Int) -> String {
        let calendar = Calendar.current
        let date = calendar.date(byAdding: .day, value: -daysAgo, to: Date())!
        return DayKey.string(from: date)
    }

    static func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    static func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    static func setModified(_ date: Date, at url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    /// El invariante del contrato: por (source, día), la suma de `modelRecords` es el `UsageRecord`.
    static func expectInvariant(_ result: CollectorResult, sourceLocation: SourceLocation = #_sourceLocation) {
        var sums: [String: ModelUsageRecord] = [:]
        for model in result.modelRecords {
            let key = model.day
            let shell = ModelUsageRecord(source: model.source, day: model.day, model: "*")
            let plain = ModelUsageRecord(source: model.source, day: model.day, model: "*",
                                         inputTokens: model.inputTokens, outputTokens: model.outputTokens,
                                         cacheCreationTokens: model.cacheCreationTokens,
                                         cacheReadTokens: model.cacheReadTokens, costUSD: model.costUSD)
            sums[key] = sums[key].map { $0 + plain } ?? (shell + plain)
        }
        #expect(sums.count == result.records.count, sourceLocation: sourceLocation)
        for record in result.records {
            let sum = sums[record.day]
            #expect(sum?.inputTokens == record.inputTokens, sourceLocation: sourceLocation)
            #expect(sum?.outputTokens == record.outputTokens, sourceLocation: sourceLocation)
            #expect(sum?.cacheCreationTokens == record.cacheCreationTokens, sourceLocation: sourceLocation)
            #expect(sum?.cacheReadTokens == record.cacheReadTokens, sourceLocation: sourceLocation)
            #expect(abs((sum?.costUSD ?? -1) - record.costUSD) < 1e-9, sourceLocation: sourceLocation)
        }
    }

    static func total(_ result: CollectorResult) -> Int {
        result.records.reduce(0) { $0 + $1.totalTokens }
    }
}
