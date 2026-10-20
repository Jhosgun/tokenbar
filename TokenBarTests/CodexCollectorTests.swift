import Foundation
import Testing

@testable import TokenBar

@Suite("CodexCollector")
struct CodexCollectorTests {

    private struct Harness {
        let root: URL
        let stateDirectory: URL
        let state: CollectorStateStore

        init() {
            root = StatsSupport.temporaryDirectory()
            stateDirectory = StatsSupport.temporaryDirectory()
            state = CollectorStateStore(directory: stateDirectory)
        }

        func collector(limits: JSONLScanner.Limits = .production) -> CodexCollector {
            CodexCollector(rootDirectory: root, store: state, limits: limits)
        }

        func rollout(_ name: String = "rollout-a.jsonl") -> URL {
            root.appending(path: "2026/10/04/\(name)", directoryHint: .notDirectory)
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: stateDirectory)
        }
    }

    private func context(_ model: String, daysAgo: Int = 0) -> String {
        #"{"timestamp":"\#(StatsSupport.isoTimestamp(daysAgo: daysAgo))","type":"turn_context","payload":{"turn_id":"t","model":"\#(model)"}}"# + "\n"
    }

    private func usage(_ responseID: String, input: Int, cached: Int, output: Int,
                       write: Int = 0, daysAgo: Int = 0) -> String {
        let usage = #"{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"cache_write_input_tokens":\#(write),"output_tokens":\#(output),"reasoning_output_tokens":1,"total_tokens":\#(input + output)}"#
        return #"{"timestamp":"\#(StatsSupport.isoTimestamp(daysAgo: daysAgo))","type":"token_usage_record","payload":{"turn_id":"t","response_id":"\#(responseID)","usage":\#(usage)}}"# + "\n"
    }

    private func tokenCount() -> String {
        #"{"timestamp":"\#(StatsSupport.isoTimestamp(daysAgo: 0))","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":999,"output_tokens":999}}}}"# + "\n"
    }

    @Test("input sin caché, modelo de turn_context y dedupe por response_id")
    func normalizaYDeduplica() async throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        try StatsSupport.write(
            context("gpt-5.6-sol")
                + usage("r1", input: 1_000, cached: 700, output: 50)
                + usage("r1", input: 1_000, cached: 700, output: 50)
                + tokenCount()
                + context("gpt-5.6-terra")
                + usage("r2", input: 200, cached: 500, output: 10),
            to: harness.rollout()
        )

        let result = await harness.collector().collect()

        #expect(result.status == .ok)
        let today = StatsSupport.day(daysAgo: 0)
        let sol = try #require(result.modelRecords.first { $0.model == "gpt-5.6-sol" })
        #expect(sol.day == today)
        #expect(sol.inputTokens == 300)
        #expect(sol.cacheReadTokens == 700)
        #expect(sol.outputTokens == 50)
        #expect(sol.costUSD == 0)
        // cached > input: el input sin caché se satura en 0, no queda negativo.
        let terra = try #require(result.modelRecords.first { $0.model == "gpt-5.6-terra" })
        #expect(terra.inputTokens == 0)
        #expect(terra.cacheReadTokens == 500)
        #expect(result.records.count == 1)
        StatsSupport.expectInvariant(result)
    }

    @Test("dos corridas seguidas no duplican y el modelo sobrevive entre corridas")
    func corridasIncrementales() async throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        let url = harness.rollout()
        try StatsSupport.write(context("gpt-5.6-sol") + usage("r1", input: 100, cached: 0, output: 10), to: url)

        let first = await harness.collector().collect()
        let second = await harness.collector().collect()
        #expect(StatsSupport.total(first) == 110)
        #expect(second.records.isEmpty && second.modelRecords.isEmpty)

        // Línea nueva sin turn_context propio: usa el modelo recordado del cursor.
        try StatsSupport.append(usage("r2", input: 5, cached: 0, output: 5), to: url)
        let third = await harness.collector().collect()
        #expect(StatsSupport.total(third) == 10)
        #expect(third.modelRecords.first?.model == "gpt-5.6-sol")
    }

    @Test("una cola sin salto de línea no frena los demás archivos y se cuenta al completarse")
    func colaSinSaltoDeLinea() async throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        let partial = harness.rollout("rollout-a.jsonl")
        let other = harness.rollout("rollout-b.jsonl")
        let tail = usage("r2", input: 40, cached: 0, output: 2)
        let cut = tail.index(tail.startIndex, offsetBy: 30)
        try StatsSupport.write(context("m") + usage("r1", input: 10, cached: 0, output: 1)
                               + String(tail[..<cut]), to: partial)
        try StatsSupport.write(context("m") + usage("r3", input: 100, cached: 0, output: 5), to: other)

        let first = await harness.collector().collect()
        #expect(StatsSupport.total(first) == 11 + 105)

        try StatsSupport.append(String(tail[cut...]), to: partial)
        let second = await harness.collector().collect()
        #expect(StatsSupport.total(second) == 42)
        StatsSupport.expectInvariant(second)
    }

    @Test("ignora registros de más de 90 días y los rollouts viejos del bootstrap")
    func retencion() async throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        let recent = harness.rollout("rollout-recent.jsonl")
        let old = harness.rollout("rollout-old.jsonl")
        try StatsSupport.write(
            context("m") + usage("old", input: 1_000, cached: 0, output: 0, daysAgo: 100)
                + usage("new", input: 7, cached: 0, output: 1, daysAgo: 2),
            to: recent
        )
        try StatsSupport.write(context("m") + usage("old2", input: 5_000, cached: 0, output: 0, daysAgo: 95),
                               to: old)
        try StatsSupport.setModified(Date().addingTimeInterval(-95 * 86_400), at: old)

        let result = await harness.collector().collect()

        #expect(StatsSupport.total(result) == 8)
        #expect(result.records.first?.day == StatsSupport.day(daysAgo: 2))
        #expect(await harness.state.hasBootstrapped(.codex))
    }

    @Test("el bootstrap avanza por tandas y se marca al terminar")
    func bootstrapPorTandas() async throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        for index in 1...3 {
            try StatsSupport.write(
                context("m") + usage("r\(index)", input: index * 10, cached: 0, output: 0),
                to: harness.rollout("rollout-\(index).jsonl")
            )
        }
        var limits = JSONLScanner.Limits.production
        limits.maxBytes = 1

        var totals: [Int] = []
        var bootstrapped: [Bool] = []
        for _ in 0..<4 {
            let result = await harness.collector(limits: limits).collect()
            totals.append(StatsSupport.total(result))
            bootstrapped.append(await harness.state.hasBootstrapped(.codex))
        }

        #expect(totals == [10, 20, 30, 0])
        #expect(bootstrapped == [false, false, true, true])
    }

    @Test("sin carpeta no está configurado y una línea corrupta no inventa cifras")
    func estadosYTolerancia() async throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        let missing = CodexCollector(rootDirectory: harness.root.appending(path: "nope"), store: harness.state)
        #expect(await missing.collect().status == .notConfigured)

        try StatsSupport.write(
            "{no es json token_usage_record\n" + context("m") + usage("r1", input: 3, cached: 0, output: 1),
            to: harness.rollout()
        )
        let result = await harness.collector().collect()
        #expect(result.status == .ok)
        #expect(StatsSupport.total(result) == 4)
    }

    @Test("los cursores de Codex sobreviven a la poda de Claude Code")
    func podaDeClaudeNoBorraCursores() async throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        try StatsSupport.write(context("m") + usage("r1", input: 3, cached: 0, output: 1), to: harness.rollout())
        _ = await harness.collector().collect()

        await harness.state.pruneCursors(keeping: [])
        let again = await harness.collector().collect()

        #expect(again.records.isEmpty)
    }
}
