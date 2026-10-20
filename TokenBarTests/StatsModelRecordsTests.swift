import Foundation
import Testing

@testable import TokenBar

/// `ClaudeCodeCollector` atribuye cada delta a su modelo y cumple el invariante: por día,
/// la suma de `modelRecords` es el `UsageRecord`. (El de Cursor vive en `CursorCollectorTests`,
/// que es dueño del arnés con la base y la red simuladas.)
@Suite("modelRecords de Claude Code")
struct StatsModelRecordsTests {

    // MARK: - Claude Code

    private func assistantLine(id: String, model: String, input: Int, output: Int,
                               cacheCreation: Int = 0, cacheRead: Int = 0,
                               daysAgo: Int = 0) -> String {
        #"{"type":"assistant","message":{"id":"\#(id)","model":"\#(model)","usage":{"input_tokens":\#(input),"cache_creation_input_tokens":\#(cacheCreation),"cache_read_input_tokens":\#(cacheRead),"output_tokens":\#(output)}},"requestId":"req_\#(id)","timestamp":"\#(StatsSupport.isoTimestamp(daysAgo: daysAgo))"}"# + "\n"
    }

    @Test("Claude Code: cada mensaje suma a su modelo y el invariante se cumple")
    func claudeInvariante() async throws {
        let root = StatsSupport.temporaryDirectory()
        let stateDirectory = StatsSupport.temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: stateDirectory)
        }
        try StatsSupport.write(
            assistantLine(id: "m1", model: "claude-opus-4-7", input: 100, output: 25,
                          cacheCreation: 50, cacheRead: 200)
                + assistantLine(id: "m2", model: "claude-sonnet-4-6", input: 1_000, output: 500,
                                cacheRead: 4_000)
                // Parcial de streaming de m1: la base ya se contó, solo suma el output extra.
                + assistantLine(id: "m1", model: "claude-opus-4-7", input: 100, output: 40,
                                cacheCreation: 50, cacheRead: 200)
                + assistantLine(id: "m3", model: "claude-sonnet-4-6", input: 10, output: 5, daysAgo: 1),
            to: root.appending(path: "proyecto/sesion.jsonl", directoryHint: .notDirectory)
        )
        let collector = ClaudeCodeCollector(rootDirectory: root,
                                            store: CollectorStateStore(directory: stateDirectory))

        let result = await collector.collect()

        #expect(result.status == .ok)
        StatsSupport.expectInvariant(result)
        #expect(StatsSupport.total(result) == 375 + 5_500 + 15 + 15)
        let today = StatsSupport.day(daysAgo: 0)
        let opus = try #require(result.modelRecords.first { $0.model == "claude-opus-4-7" && $0.day == today })
        #expect(opus.outputTokens == 40)
        #expect(opus.totalTokens == 100 + 40 + 50 + 200)
        let sonnet = result.modelRecords.filter { $0.model == "claude-sonnet-4-6" }
        #expect(sonnet.count == 2)
        #expect(result.modelRecords.allSatisfy { $0.source == .claudeCode })
    }
}
