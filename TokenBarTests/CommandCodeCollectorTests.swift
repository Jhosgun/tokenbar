import Foundation
import Testing

@testable import TokenBar

@Suite("CommandCodeCollector")
struct CommandCodeCollectorTests {

    private struct Harness {
        let root: URL
        let stateDirectory: URL
        let state: CollectorStateStore

        init() {
            root = StatsSupport.temporaryDirectory()
            stateDirectory = StatsSupport.temporaryDirectory()
            state = CollectorStateStore(directory: stateDirectory)
        }

        func collector(limits: JSONLScanner.Limits = .production) -> CommandCodeCollector {
            CommandCodeCollector(rootDirectory: root, store: state, limits: limits)
        }

        func session(_ name: String = "11111111.jsonl", slug: String = "proj") -> URL {
            root.appending(path: "\(slug)/\(name)", directoryHint: .notDirectory)
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: stateDirectory)
        }
    }

    private func message(_ id: String, model: String = "gpt-5.6-sol", input: Int, read: Int,
                         write: Int, output: Int, cost: Double = 0, daysAgo: Int = 0) -> String {
        #"{"type":"message","id":"\#(id)","timestamp":"\#(StatsSupport.isoTimestamp(daysAgo: daysAgo))","usage":{"inputTokens":\#(input),"outputTokens":\#(output),"cacheReadTokens":\#(read),"cacheWriteTokens":\#(write),"costUsd":\#(cost)},"model":"\#(model)"}"# + "\n"
    }

    private let plainLine = #"{"type":"message","id":"u1","timestamp":"2026-10-04T10:00:00.000Z","message":{"role":"user"}}"# + "\n"

    @Test("input sin los dos cachés, costo nativo y modelo propio")
    func normalizaCache() async throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        try StatsSupport.write(
            plainLine
                + message("a1", input: 20_925, read: 17_812, write: 3_110, output: 499, cost: 0.0433)
                + message("a2", model: "zai-org/GLM-5.2", input: 21_424, read: 20_992, write: 0,
                          output: 83, cost: 0.0064),
            to: harness.session()
        )

        let result = await harness.collector().collect()

        let sol = try #require(result.modelRecords.first { $0.model == "gpt-5.6-sol" })
        #expect(sol.inputTokens == 3)
        #expect(sol.cacheReadTokens == 17_812)
        #expect(sol.cacheCreationTokens == 3_110)
        #expect(sol.outputTokens == 499)
        #expect(abs(sol.costUSD - 0.0433) < 1e-9)
        let glm = try #require(result.modelRecords.first { $0.model == "zai-org/GLM-5.2" })
        #expect(glm.inputTokens == 432)
        #expect(result.records.count == 1)
        #expect(result.records[0].totalTokens == sol.totalTokens + glm.totalTokens)
        StatsSupport.expectInvariant(result)
    }

    @Test("excluye los checkpoints y no cuenta dos veces un id repetido")
    func excluyeCheckpointsYDeduplica() async throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        let line = message("a1", input: 100, read: 40, write: 0, output: 10)
        try StatsSupport.write(line + line, to: harness.session())
        try StatsSupport.write(message("c1", input: 9_999, read: 0, write: 0, output: 1),
                               to: harness.session("11111111.checkpoints.jsonl"))

        let first = await harness.collector().collect()
        let second = await harness.collector().collect()

        #expect(StatsSupport.total(first) == 110)
        #expect(second.records.isEmpty)
    }

    @Test("un id igual en otra sesión sí cuenta, y la cola sin salto de línea espera")
    func idPorSesionYCola() async throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        let first = harness.session("aaaaaaaa.jsonl")
        let second = harness.session("bbbbbbbb.jsonl", slug: "otro")
        let tail = message("t1", input: 8, read: 0, write: 0, output: 2)
        let cut = tail.index(tail.startIndex, offsetBy: 25)
        try StatsSupport.write(message("same", input: 10, read: 0, write: 0, output: 0)
                               + String(tail[..<cut]), to: first)
        try StatsSupport.write(message("same", input: 20, read: 0, write: 0, output: 0), to: second)

        let run1 = await harness.collector().collect()
        #expect(StatsSupport.total(run1) == 30)

        try StatsSupport.append(String(tail[cut...]), to: first)
        let run2 = await harness.collector().collect()
        #expect(StatsSupport.total(run2) == 10)
    }

    @Test("ignora mensajes de más de 90 días y avanza el bootstrap por tandas")
    func retencionYTandas() async throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        for index in 1...2 {
            try StatsSupport.write(
                message("old\(index)", input: 1_000, read: 0, write: 0, output: 0, daysAgo: 120)
                    + message("new\(index)", input: index, read: 0, write: 0, output: 0, daysAgo: 1),
                to: harness.session("s\(index).jsonl")
            )
        }
        var limits = JSONLScanner.Limits.production
        limits.maxBytes = 1

        let first = await harness.collector(limits: limits).collect()
        #expect(StatsSupport.total(first) == 1)
        #expect(!(await harness.state.hasBootstrapped(.commandCode)))
        let second = await harness.collector(limits: limits).collect()
        #expect(StatsSupport.total(second) == 2)
        #expect(await harness.state.hasBootstrapped(.commandCode))
        StatsSupport.expectInvariant(second)
    }

    @Test("sin carpeta no está configurado")
    func sinCarpeta() async {
        let harness = Harness()
        defer { harness.cleanUp() }
        let missing = CommandCodeCollector(rootDirectory: harness.root.appending(path: "nope"),
                                           store: harness.state)
        #expect(await missing.collect().status == .notConfigured)
    }
}
