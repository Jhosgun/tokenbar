import Foundation
import Testing

@testable import TokenBar

@Suite("ModelUsageStore")
struct ModelUsageStoreTests {

    private func record(_ model: String, daysAgo: Int = 0, source: AppSource = .claudeCode,
                        input: Int = 10, output: Int = 5, cost: Double = 0.1) -> ModelUsageRecord {
        ModelUsageRecord(source: source, day: StatsSupport.day(daysAgo: daysAgo), model: model,
                         inputTokens: input, outputTokens: output, costUSD: cost)
    }

    @Test("agrega por (día, herramienta, modelo) y separa lo demás")
    func agrega() async {
        let directory = StatsSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ModelUsageStore(directory: directory)
        await store.load()

        await store.apply([record("opus"), record("opus"), record("sonnet"),
                           record("opus", source: .commandCode), record("opus", daysAgo: 1)])
        await store.apply([record("opus", input: 1, output: 1, cost: 0.5)])

        let all = await store.records(fromDay: StatsSupport.day(daysAgo: 5))
        #expect(all.count == 4)
        let opusToday = all.first { $0.model == "opus" && $0.source == .claudeCode
            && $0.day == StatsSupport.day(daysAgo: 0) }
        #expect(opusToday?.inputTokens == 21)
        #expect(opusToday?.outputTokens == 11)
        #expect(abs((opusToday?.costUSD ?? 0) - 0.7) < 1e-9)
        let recent = await store.records(fromDay: StatsSupport.day(daysAgo: 0))
        #expect(recent.allSatisfy { $0.day == StatsSupport.day(daysAgo: 0) })
        #expect(recent.count == 3)
    }

    @Test("persiste a disco y otro store lo vuelve a leer")
    func persiste() async {
        let directory = StatsSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = ModelUsageStore(directory: directory)
        await first.load()
        await first.apply([record("opus"), record("sonnet", daysAgo: 2)])

        let second = ModelUsageStore(directory: directory)
        await second.load()

        let loaded = await second.records(fromDay: StatsSupport.day(daysAgo: 10))
        #expect(loaded.map(\.model).sorted() == ["opus", "sonnet"])
        #expect(FileManager.default.fileExists(
            atPath: directory.appending(path: "model-usage.json").path))
    }

    @Test("la retención de 90 días borra lo viejo al cargar y al podar")
    func retencion() async {
        let directory = StatsSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = ModelUsageStore(directory: directory)
        await first.load()
        await first.apply([record("viejo", daysAgo: 91), record("limite", daysAgo: 90),
                           record("borde", daysAgo: 89), record("hoy")])

        let second = ModelUsageStore(directory: directory)
        await second.load()

        let models = await second.records(fromDay: "0000-00-00").map(\.model).sorted()
        #expect(models == ["borde", "hoy"])

        await first.purge()
        let purged = await first.records(fromDay: "0000-00-00").map(\.model).sorted()
        #expect(purged == ["borde", "hoy"])
    }

    @Test("un archivo corrupto se aparta como .corrupt y se arranca vacío")
    func corrupto() async throws {
        let directory = StatsSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "model-usage.json")
        try StatsSupport.write("{ esto no es json", to: file)
        let store = ModelUsageStore(directory: directory)

        await store.load()

        #expect(await store.records(fromDay: "0000-00-00").isEmpty)
        let corrupt = directory.appending(path: "model-usage.json.corrupt")
        #expect(try String(contentsOf: corrupt, encoding: .utf8) == "{ esto no es json")
        #expect(!FileManager.default.fileExists(atPath: file.path))

        await store.apply([record("opus")])
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(FileManager.default.fileExists(atPath: corrupt.path))
    }

    @Test("sin archivo arranca vacío y apply vacío no escribe nada")
    func vacio() async {
        let directory = StatsSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ModelUsageStore(directory: directory)
        await store.load()
        await store.apply([])

        #expect(await store.records(fromDay: "0000-00-00").isEmpty)
        #expect(!FileManager.default.fileExists(
            atPath: directory.appending(path: "model-usage.json").path))
    }
}

/// Collector de mentira que emite siempre lo mismo.
private struct FixedCollector: UsageCollector {
    let source: AppSource = .claudeCode
    let result: CollectorResult

    func collect() async -> CollectorResult { result }
}

@Suite("UsageViewModel y las series de Estadísticas")
@MainActor
struct UsageViewModelStatsTests {

    @Test("refresh aplica los modelRecords y statsData reparte por herramienta y por modelo")
    func refreshAplicaModelRecords() async {
        let directory = StatsSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let day = StatsSupport.day(daysAgo: 0)
        let result = CollectorResult(
            records: [UsageRecord(source: .claudeCode, day: day, inputTokens: 100, outputTokens: 50)],
            status: .ok,
            modelRecords: [
                ModelUsageRecord(source: .claudeCode, day: day, model: "opus", inputTokens: 60,
                                 outputTokens: 50),
                ModelUsageRecord(source: .claudeCode, day: day, model: "sonnet", inputTokens: 40)
            ])
        let viewModel = UsageViewModel(
            store: UsageStore(directory: directory),
            modelStore: ModelUsageStore(directory: directory),
            state: CollectorStateStore(directory: directory),
            collectors: [FixedCollector(result: result)])

        await viewModel.refresh()
        let byModel = await viewModel.statsData(days: 7, grouping: .model)
        let byTool = await viewModel.statsData(days: 7, grouping: .tool)

        #expect(byModel.series.map(\.name) == ["opus", "sonnet"])
        #expect(byModel.totalTokens == 150)
        #expect(byTool.series.map(\.name) == ["Claude Code"])
        #expect(byTool.totalTokens == 150)
        #expect(byTool.days.count == 7)
    }
}

@Suite("ModelUsageStore: versión de formato")
struct ModelUsageStoreVersionTests {

    @Test("un archivo de otra versión se aparta como .corrupt y no se pisa")
    func versionDistinta() async throws {
        let directory = StatsSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "model-usage.json")
        let day = StatsSupport.day(daysAgo: 0)
        let future = #"{"version":99,"records":[{"source":"claudeCode","day":"\#(day)","model":"opus","inputTokens":1,"outputTokens":0,"cacheCreationTokens":0,"cacheReadTokens":0,"costUSD":0}],"extra":true}"#
        try StatsSupport.write(future, to: file)
        let store = ModelUsageStore(directory: directory)

        await store.load()

        #expect(await store.records(fromDay: "0000-00-00").isEmpty)
        let corrupt = directory.appending(path: "model-usage.json.corrupt")
        #expect(try String(contentsOf: corrupt, encoding: .utf8) == future)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}
