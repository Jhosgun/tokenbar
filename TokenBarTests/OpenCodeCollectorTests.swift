import Foundation
import SQLite3
import Testing

@testable import TokenBar

@Suite("OpenCodeCollector")
struct OpenCodeCollectorTests {

    private final class Database {
        let url: URL
        private var handle: OpaquePointer?

        init(directory: URL, createTable: Bool = true) {
            url = directory.appending(path: "opencode.db", directoryHint: .notDirectory)
            sqlite3_open(url.path, &handle)
            if createTable {
                exec("CREATE TABLE message (id text PRIMARY KEY, session_id text NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL)")
            }
        }

        deinit { sqlite3_close(handle) }

        func exec(_ sql: String) {
            #expect(sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK)
        }

        /// `completed: false` imita un mensaje a medio streaming (sin `time.completed`).
        /// Mensaje terminado con `tokens.input` de tipo texto: formato que no se entiende.
        func upsertWithTextTokens(id: String, updatedMs: Int64) {
            let data = #"{"role":"assistant","providerID":"p","modelID":"m","cost":0,"time":{"created":1,"completed":\#(updatedMs)},"tokens":{"input":"12","output":1,"reasoning":0,"cache":{"read":0,"write":0}}}"#
            exec("INSERT OR REPLACE INTO message VALUES ('\(id)', 's1', 1, \(updatedMs), '\(data)')")
        }

        func upsert(id: String, role: String = "assistant", model: String = "kimi-k3",
                    provider: String = "opencode-go", input: Int = 0, output: Int = 0, reasoning: Int = 0,
                    read: Int = 0, write: Int = 0, cost: Double = 0, completed: Bool = true,
                    createdDaysAgo: Int = 0, updatedMs: Int64? = nil) {
            let created = Int64((Date().timeIntervalSince1970 - Double(createdDaysAgo) * 86_400) * 1_000)
            let updated = updatedMs ?? max(created, Int64(Date().timeIntervalSince1970 * 1_000))
            let time = completed ? #"{"created":\#(created),"completed":\#(updated)}"# : #"{"created":\#(created)}"#
            let total = input + output + reasoning + read + write
            let data = #"{"role":"\#(role)","providerID":"\#(provider)","modelID":"\#(model)","cost":\#(cost),"time":\#(time),"tokens":{"input":\#(input),"output":\#(output),"reasoning":\#(reasoning),"total":\#(total),"cache":{"read":\#(read),"write":\#(write)}}}"#
            exec("INSERT OR REPLACE INTO message VALUES ('\(id)', 's1', \(created), \(updated), '\(data)')")
        }
    }

    private struct Harness {
        let directory = StatsSupport.temporaryDirectory()
        let stateDirectory = StatsSupport.temporaryDirectory()
        let state: CollectorStateStore

        init() {
            state = CollectorStateStore(directory: stateDirectory)
        }

        func collector(databaseURL: URL, limits: OpenCodeCollector.CycleLimits = .production) -> OpenCodeCollector {
            OpenCodeCollector(databaseURL: databaseURL, store: state, limits: limits)
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: stateDirectory)
        }
    }

    @Test("un mensaje reescrito con más tokens se cuenta una vez con su valor final")
    func mensajeReescrito() async throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        let database = Database(directory: harness.directory)
        database.upsert(id: "m1", input: 10, output: 5, completed: false)

        let streaming = await harness.collector(databaseURL: database.url).collect()
        #expect(streaming.records.isEmpty)

        database.upsert(id: "m1", input: 100, output: 50, reasoning: 20, read: 30, write: 4, cost: 0.25)
        let final = await harness.collector(databaseURL: database.url).collect()
        let again = await harness.collector(databaseURL: database.url).collect()

        let record = try #require(final.modelRecords.first)
        #expect(record.model == "opencode-go/kimi-k3")
        #expect(record.inputTokens == 100)
        // El razonamiento va aparte de `output` en OpenCode: se suma para que el total cuadre.
        #expect(record.outputTokens == 70)
        #expect(record.cacheReadTokens == 30)
        #expect(record.cacheCreationTokens == 4)
        #expect(record.totalTokens == 204)
        #expect(abs(record.costUSD - 0.25) < 1e-9)
        #expect(final.modelRecords.count == 1)
        #expect(again.records.isEmpty)
        StatsSupport.expectInvariant(final)
    }

    @Test("distingue proveedores, ignora mensajes de usuario y de más de 90 días")
    func proveedoresYRetencion() async throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        let database = Database(directory: harness.directory)
        database.upsert(id: "a", model: "x-free", provider: "opencode", input: 7)
        database.upsert(id: "b", model: "x-free", provider: "opencode-go", input: 3)
        database.upsert(id: "c", role: "user", input: 9_999)
        database.upsert(id: "d", input: 5_000, createdDaysAgo: 100)

        let result = await harness.collector(databaseURL: database.url).collect()

        #expect(Set(result.modelRecords.map(\.model)) == ["opencode/x-free", "opencode-go/x-free"])
        #expect(StatsSupport.total(result) == 10)
        #expect(await harness.state.hasBootstrapped(.opencode))
        StatsSupport.expectInvariant(result)
    }

    @Test("el bootstrap avanza por lotes sin duplicar ni saltarse mensajes")
    func bootstrapPorLotes() async throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        let database = Database(directory: harness.directory)
        let base = Int64(Date().timeIntervalSince1970 * 1_000) - 10_000
        for index in 1...5 {
            database.upsert(id: "m\(index)", input: index, updatedMs: base + Int64(index) * 100)
        }
        let limits = OpenCodeCollector.CycleLimits(timeBudget: .zero, batchRows: 3)

        var totals: [Int] = []
        for _ in 0..<4 {
            let result = await harness.collector(databaseURL: database.url, limits: limits).collect()
            totals.append(StatsSupport.total(result))
        }

        #expect(totals.reduce(0, +) == 15)
        #expect(totals.first == 6)
        #expect(await harness.state.hasBootstrapped(.opencode))
    }

    @Test("sin base no está configurado; formato desconocido falla sin inventar cifras")
    func estados() async {
        let harness = Harness()
        defer { harness.cleanUp() }
        let missing = await harness.collector(databaseURL: harness.directory.appending(path: "no.db")).collect()
        #expect(missing.status == .notConfigured)

        let database = Database(directory: harness.directory, createTable: false)
        database.exec("CREATE TABLE otra (x integer)")
        let unknown = await harness.collector(databaseURL: database.url).collect()
        #expect(unknown.records.isEmpty)
        if case .failed = unknown.status {} else { Issue.record("esperaba .failed, llegó \(unknown.status)") }
    }

    @Test("más filas que un lote con el mismo time_updated no estancan el avance")
    func empatesDeTimeUpdated() async throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        let database = Database(directory: harness.directory)
        let tied = Int64(Date().timeIntervalSince1970 * 1_000) - 10_000
        for index in 1...7 {
            database.upsert(id: "m\(index)", input: 1, updatedMs: tied)
        }
        database.upsert(id: "later", input: 100, updatedMs: tied + 500)
        let limits = OpenCodeCollector.CycleLimits(timeBudget: .zero, batchRows: 3)

        var total = 0
        for _ in 0..<6 {
            total += StatsSupport.total(await harness.collector(databaseURL: database.url, limits: limits).collect())
        }

        #expect(total == 107)
        #expect(await harness.state.hasBootstrapped(.opencode))
    }

    @Test("un mensaje terminado con tokens de tipo inválido falla sin contarse ni marcarse")
    func tokensInvalidos() async throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        let database = Database(directory: harness.directory)
        let base = Int64(Date().timeIntervalSince1970 * 1_000) - 10_000
        database.upsert(id: "ok", input: 5, updatedMs: base)
        database.upsertWithTextTokens(id: "bad", updatedMs: base + 100)

        let first = await harness.collector(databaseURL: database.url).collect()
        let second = await harness.collector(databaseURL: database.url).collect()

        #expect(first.status == .failed("Formato de OpenCode desconocido"))
        #expect(StatsSupport.total(first) == 5)
        #expect(second.status == .failed("Formato de OpenCode desconocido"))
        #expect(second.records.isEmpty)
        #expect(!(await harness.state.hasBootstrapped(.opencode)))

        // Al corregirse el formato de la fila, se cuenta una sola vez.
        database.upsert(id: "bad", input: 9, updatedMs: base + 100)
        let fixed = await harness.collector(databaseURL: database.url).collect()
        #expect(fixed.status == .ok)
        #expect(StatsSupport.total(fixed) == 9)
    }

    @Test("si un lote posterior falla se conserva lo leído pero el estado es .failed")
    func falloEnLoteTardio() async throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        let database = Database(directory: harness.directory)
        let base = Int64(Date().timeIntervalSince1970 * 1_000) - 10_000
        database.upsert(id: "m1", input: 1, updatedMs: base)
        database.upsert(id: "m2", input: 2, updatedMs: base + 100)
        database.upsertWithTextTokens(id: "m3", updatedMs: base + 200)
        let limits = OpenCodeCollector.CycleLimits(timeBudget: .seconds(5), batchRows: 2)

        let result = await harness.collector(databaseURL: database.url, limits: limits).collect()

        #expect(StatsSupport.total(result) == 3)
        #expect(result.status == .failed("Formato de OpenCode desconocido"))
        StatsSupport.expectInvariant(result)
    }
}
