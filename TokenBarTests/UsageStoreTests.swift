import Foundation
import Testing

@testable import TokenBar

// MARK: - Helpers

/// Directorio temporal único por test. Nunca se toca `~/Library/Application Support/TokenBar`.
private func makeTemporaryDirectory() -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func removeDirectory(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

/// Espejo del formato en disco de `usage.json`, para inspeccionarlo sin usar API interna.
private struct DiskPayload: Decodable {
    var version: Int
    var records: [UsageRecord]
}

private func usageFileURL(in directory: URL) -> URL {
    directory.appending(path: "usage.json", directoryHint: .notDirectory)
}

private func readUsageFile(in directory: URL) throws -> DiskPayload {
    let data = try Data(contentsOf: usageFileURL(in: directory))
    return try JSONDecoder().decode(DiskPayload.self, from: data)
}

/// Clave de día desplazada `offset` días hacia atrás desde hoy.
private func dayKey(daysAgo offset: Int) throws -> String {
    let calendar = Calendar.current
    let date = try #require(calendar.date(byAdding: .day, value: -offset, to: Date()))
    return DayKey.string(from: date, calendar: calendar)
}

private func approxEqual(_ lhs: Double, _ rhs: Double, tolerance: Double = 1e-9) -> Bool {
    abs(lhs - rhs) <= tolerance
}

// MARK: - Tests

@Suite("UsageStore")
struct UsageStoreTests {

    @Test("crea el directorio y arranca vacío cuando no hay archivo")
    func arranqueEnLimpio() async throws {
        let root = makeTemporaryDirectory()
        defer { removeDirectory(root) }
        let directory = root.appending(path: "anidado", directoryHint: .isDirectory)

        let store = UsageStore(directory: directory)
        await store.load()

        #expect(FileManager.default.fileExists(atPath: directory.path))
        let snapshot = await store.snapshot()
        #expect(snapshot.todayTotalTokens == 0)
        #expect(approxEqual(snapshot.todayCostUSD, 0))
    }

    @Test("acumula tokens por (source, día) al aplicar dos veces")
    func acumulaAlAplicarDosVeces() async throws {
        let directory = makeTemporaryDirectory()
        defer { removeDirectory(directory) }

        let store = UsageStore(directory: directory)
        await store.load()

        let today = DayKey.today()
        let record = UsageRecord(source: .claudeCode, day: today,
                                 inputTokens: 100, outputTokens: 25,
                                 cacheCreationTokens: 50, cacheReadTokens: 200, costUSD: 0.25)

        let firstDelta = await store.apply([record])
        let secondDelta = await store.apply([record])
        #expect(firstDelta == 375)
        #expect(secondDelta == 375)

        let snapshot = await store.snapshot()
        let accumulated = try #require(snapshot.todayByApp[.claudeCode])
        #expect(accumulated.inputTokens == 200)
        #expect(accumulated.outputTokens == 50)
        #expect(accumulated.cacheCreationTokens == 100)
        #expect(accumulated.cacheReadTokens == 400)
        #expect(accumulated.totalTokens == 750)
        #expect(approxEqual(accumulated.costUSD, 0.5))
        #expect(snapshot.todayTotalTokens == 750)
        #expect(approxEqual(snapshot.todayCostUSD, 0.5))
    }

    @Test("registros de apps o días distintos no se mezclan")
    func noMezclaClaves() async throws {
        let directory = makeTemporaryDirectory()
        defer { removeDirectory(directory) }

        let store = UsageStore(directory: directory)
        await store.load()

        let today = DayKey.today()
        let yesterday = try dayKey(daysAgo: 1)
        await store.apply([
            UsageRecord(source: .claudeCode, day: today, inputTokens: 10),
            UsageRecord(source: .cursor, day: today, inputTokens: 20),
            UsageRecord(source: .claudeCode, day: yesterday, inputTokens: 40)
        ])

        let snapshot = await store.snapshot()
        #expect(snapshot.todayByApp[.claudeCode]?.inputTokens == 10)
        #expect(snapshot.todayByApp[.cursor]?.inputTokens == 20)
        #expect(snapshot.todayByApp[.antigravity]?.inputTokens == 0)
        #expect(snapshot.todayTotalTokens == 30)

        // La serie va de viejo (índice 0) a nuevo (índice 6 = hoy).
        let series = try #require(snapshot.last7DaysByApp[.claudeCode])
        #expect(series[6].tokens == 10)
        #expect(series[5].tokens == 40)
        #expect(series[4].tokens == 0)
    }

    @Test("apply con un array vacío devuelve 0 y no escribe el archivo")
    func applyVacio() async throws {
        let directory = makeTemporaryDirectory()
        defer { removeDirectory(directory) }

        let store = UsageStore(directory: directory)
        await store.load()

        let delta = await store.apply([])
        #expect(delta == 0)
        #expect(!FileManager.default.fileExists(atPath: usageFileURL(in: directory).path))
    }

    @Test("persiste y vuelve a cargar en un store nuevo sobre el mismo directorio")
    func roundTripDePersistencia() async throws {
        let directory = makeTemporaryDirectory()
        defer { removeDirectory(directory) }

        let today = DayKey.today()
        let original = UsageStore(directory: directory)
        await original.load()
        await original.apply([
            UsageRecord(source: .claudeCode, day: today, inputTokens: 100, outputTokens: 25,
                        cacheCreationTokens: 50, cacheReadTokens: 200, costUSD: 0.25),
            UsageRecord(source: .cursor, day: today, inputTokens: 1, costUSD: 0.5)
        ])
        let expected = await original.snapshot()

        let reopened = UsageStore(directory: directory)
        await reopened.load()
        let restored = await reopened.snapshot()

        #expect(restored == expected)
        #expect(restored.todayTotalTokens == 376)
        #expect(approxEqual(restored.todayCostUSD, 0.75))

        let payload = try readUsageFile(in: directory)
        #expect(payload.version == 1)
        #expect(payload.records.count == 2)
    }

    @Test("snapshot siempre trae las 3 apps y 7 días con ceros rellenados")
    func snapshotSiempreCompleto() async throws {
        let directory = makeTemporaryDirectory()
        defer { removeDirectory(directory) }

        let store = UsageStore(directory: directory)
        await store.load()
        await store.apply([UsageRecord(source: .claudeCode, day: DayKey.today(), inputTokens: 5)])

        let snapshot = await store.snapshot()
        let today = DayKey.today()
        let expectedDays = DayKey.lastDays(7)

        #expect(snapshot.todayByApp.count == AppSource.allCases.count)
        #expect(snapshot.last7DaysByApp.count == AppSource.allCases.count)

        for source in AppSource.allCases {
            let record = try #require(snapshot.todayByApp[source])
            #expect(record.source == source)
            #expect(record.day == today)

            let series = try #require(snapshot.last7DaysByApp[source])
            #expect(series.count == 7)
            #expect(series.map(\.day) == expectedDays)
        }

        // La app sin datos queda en ceros, no ausente.
        let antigravity = try #require(snapshot.last7DaysByApp[.antigravity])
        #expect(snapshot.todayByApp[.antigravity]?.totalTokens == 0)
        #expect(antigravity.allSatisfy({ $0.tokens == 0 }))
    }

    @Test("UsageSnapshot.empty trae las 3 apps y 7 días en cero")
    func snapshotVacio() throws {
        let snapshot = UsageSnapshot.empty
        #expect(snapshot.todayTotalTokens == 0)
        #expect(approxEqual(snapshot.todayCostUSD, 0))
        #expect(snapshot.todayByApp.count == AppSource.allCases.count)

        for source in AppSource.allCases {
            let series = try #require(snapshot.last7DaysByApp[source])
            #expect(series.count == 7)
            #expect(series.allSatisfy({ $0.tokens == 0 }))
            #expect(snapshot.todayByApp[source]?.totalTokens == 0)
        }
    }

    @Test("purge borra los días viejos y conserva los recientes")
    func purgeBorraViejos() async throws {
        let directory = makeTemporaryDirectory()
        defer { removeDirectory(directory) }

        let store = UsageStore(directory: directory)
        await store.load()

        let today = DayKey.today()
        let recent = try dayKey(daysAgo: 3)
        let old = try dayKey(daysAgo: 100)
        let veryOld = try dayKey(daysAgo: 400)

        await store.apply([
            UsageRecord(source: .claudeCode, day: today, inputTokens: 1),
            UsageRecord(source: .claudeCode, day: recent, inputTokens: 2),
            UsageRecord(source: .claudeCode, day: old, inputTokens: 3),
            UsageRecord(source: .cursor, day: veryOld, inputTokens: 4)
        ])
        let before = try readUsageFile(in: directory)
        #expect(before.records.count == 4)

        await store.purge(olderThanDays: 90)

        let after = try readUsageFile(in: directory)
        let days = Set(after.records.map(\.day))
        #expect(days == [today, recent])
        #expect(!days.contains(old))
        #expect(!days.contains(veryOld))

        // Lo de hoy sigue intacto tras la poda.
        let snapshot = await store.snapshot()
        #expect(snapshot.todayByApp[.claudeCode]?.inputTokens == 1)
    }

    @Test("purge persiste: el store recargado no ve los días borrados")
    func purgePersiste() async throws {
        let directory = makeTemporaryDirectory()
        defer { removeDirectory(directory) }

        let old = try dayKey(daysAgo: 100)
        let store = UsageStore(directory: directory)
        await store.load()
        await store.apply([
            UsageRecord(source: .claudeCode, day: DayKey.today(), inputTokens: 1),
            UsageRecord(source: .claudeCode, day: old, inputTokens: 3)
        ])
        await store.purge(olderThanDays: 90)

        let payload = try readUsageFile(in: directory)
        #expect(payload.records.count == 1)

        let reopened = UsageStore(directory: directory)
        await reopened.load()
        let snapshot = await reopened.snapshot()
        #expect(snapshot.todayByApp[.claudeCode]?.inputTokens == 1)
    }

    @Test("un usage.json corrupto no crashea: arranca vacío y sigue usable")
    func jsonCorrupto() async throws {
        let directory = makeTemporaryDirectory()
        defer { removeDirectory(directory) }

        try Data("{ esto no es json válido ]".utf8).write(to: usageFileURL(in: directory))

        let store = UsageStore(directory: directory)
        await store.load()

        let afterLoad = await store.snapshot()
        #expect(afterLoad.todayTotalTokens == 0)

        // El store sigue funcionando y sobrescribe el archivo corrupto.
        let delta = await store.apply([
            UsageRecord(source: .claudeCode, day: DayKey.today(), inputTokens: 7)
        ])
        #expect(delta == 7)

        let payload = try readUsageFile(in: directory)
        #expect(payload.records.count == 1)
        #expect(payload.records.first?.inputTokens == 7)
    }

    @Test("un usage.json con JSON válido pero esquema ajeno tampoco crashea")
    func esquemaAjeno() async throws {
        let directory = makeTemporaryDirectory()
        defer { removeDirectory(directory) }

        try Data(#"{"version":1,"otraCosa":[1,2,3]}"#.utf8).write(to: usageFileURL(in: directory))

        let store = UsageStore(directory: directory)
        await store.load()
        let snapshot = await store.snapshot()
        #expect(snapshot.todayTotalTokens == 0)
    }

    @Test("un archivo con duplicados de (source, día) se colapsa sumando al cargar")
    func duplicadosEnDiscoSeSuman() async throws {
        let directory = makeTemporaryDirectory()
        defer { removeDirectory(directory) }

        let today = DayKey.today()
        let duplicated = """
        {"version":1,"records":[\
        {"source":"claudeCode","day":"\(today)","inputTokens":10,"outputTokens":0,\
        "cacheCreationTokens":0,"cacheReadTokens":0,"costUSD":0.5},\
        {"source":"claudeCode","day":"\(today)","inputTokens":5,"outputTokens":1,\
        "cacheCreationTokens":0,"cacheReadTokens":0,"costUSD":0.25}]}
        """
        try Data(duplicated.utf8).write(to: usageFileURL(in: directory))

        let store = UsageStore(directory: directory)
        await store.load()
        let snapshot = await store.snapshot()

        let record = try #require(snapshot.todayByApp[.claudeCode])
        #expect(record.inputTokens == 15)
        #expect(record.outputTokens == 1)
        #expect(approxEqual(record.costUSD, 0.75))
    }
}
