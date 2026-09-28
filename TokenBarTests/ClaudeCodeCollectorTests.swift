import Foundation
import Testing

@testable import TokenBar

// MARK: - Fixture

/// Entrada del transcript de ejemplo que SÍ debe contarse.
/// Los tokens y el costo están calculados a mano contra `Fixtures/sample-transcript.jsonl`.
private struct FixtureEntry {
    let timestamp: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreationTokens: Int
    let cacheReadTokens: Int
    let costUSD: Double
}

/// msg_A (opus) y msg_B (sonnet) el día 1; msg_D (sonnet) el día 2.
/// Quedan fuera: la línea `user`, la basura, el assistant sin `usage` y el duplicado de msg_A.
private let fixtureEntries: [FixtureEntry] = [
    // opus: (100*5.00 + 25*25.00 + 50*6.25 + 200*0.50) / 1e6
    FixtureEntry(timestamp: "2026-08-03T14:05:00.000Z", inputTokens: 100, outputTokens: 25,
                 cacheCreationTokens: 50, cacheReadTokens: 200, costUSD: 0.0015375),
    // sonnet: (1000*3 + 500*15 + 0*3.75 + 4000*0.30) / 1e6
    FixtureEntry(timestamp: "2026-08-03T15:30:00.000Z", inputTokens: 1000, outputTokens: 500,
                 cacheCreationTokens: 0, cacheReadTokens: 4000, costUSD: 0.0117),
    // sonnet: (200*3 + 50*15 + 100*3.75 + 0*0.30) / 1e6
    FixtureEntry(timestamp: "2026-08-04T09:00:00.000Z", inputTokens: 200, outputTokens: 50,
                 cacheCreationTokens: 100, cacheReadTokens: 0, costUSD: 0.001725)
]

/// 1100 + 525 + 50 + 4200 el día 1, más 200 + 50 + 100 el día 2.
private let fixtureTotalTokens = 6225

private enum FixtureError: Error { case notFound }

/// El fixture se busca primero en el bundle de tests y, si no está copiado ahí,
/// junto a este archivo fuente.
private func fixtureURL() throws -> URL {
    if let bundle = Bundle.allBundles.first(where: { $0.bundlePath.hasSuffix(".xctest") }),
       let url = bundle.url(forResource: "sample-transcript", withExtension: "jsonl") {
        return url
    }
    let source = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appending(path: "Fixtures/sample-transcript.jsonl", directoryHint: .notDirectory)
    guard FileManager.default.fileExists(atPath: source.path) else { throw FixtureError.notFound }
    return source
}

// MARK: - Helpers

private func makeTemporaryDirectory() -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func removeDirectory(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

private func approxEqual(_ lhs: Double, _ rhs: Double, tolerance: Double = 1e-9) -> Bool {
    abs(lhs - rhs) <= tolerance
}

/// Copia el fixture a `<root>/<proyecto>/<uuid>.jsonl` y devuelve la ruta destino.
@discardableResult
private func stageFixture(in root: URL, project: String = "proyecto",
                          modified: Date = Date()) throws -> URL {
    let directory = root.appending(path: project, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let destination = directory
        .appending(path: "\(UUID().uuidString).jsonl", directoryHint: .notDirectory)
    try FileManager.default.copyItem(at: fixtureURL(), to: destination)
    try FileManager.default.setAttributes([.modificationDate: modified],
                                          ofItemAtPath: destination.path)
    return destination
}

/// Escribe un transcript arbitrario en `<root>/<proyecto>/<uuid>.jsonl`.
@discardableResult
private func writeTranscript(_ contents: String, in root: URL, project: String,
                             modified: Date = Date()) throws -> URL {
    let directory = root.appending(path: project, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let destination = directory
        .appending(path: "\(UUID().uuidString).jsonl", directoryHint: .notDirectory)
    try Data(contents.utf8).write(to: destination)
    try FileManager.default.setAttributes([.modificationDate: modified],
                                          ofItemAtPath: destination.path)
    return destination
}

private func append(_ text: String, to url: URL, newline: Bool = true) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data((newline ? text + "\n" : text).utf8))
}

/// Línea `assistant` con `usage`, con la forma real de los transcripts de Claude Code.
private func assistantLine(messageID: String, requestID: String, model: String,
                           timestamp: String, input: Int, output: Int,
                           cacheCreation: Int, cacheRead: Int) -> String {
    """
    {"parentUuid":null,"isSidechain":false,"userType":"external","cwd":"/Users/dev/proyecto",\
    "sessionId":"33333333-3333-4333-8333-333333333333","version":"2.0.14","gitBranch":"main",\
    "type":"assistant","message":{"id":"\(messageID)","type":"message","role":"assistant",\
    "model":"\(model)","content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn",\
    "stop_sequence":null,"usage":{"input_tokens":\(input),\
    "cache_creation_input_tokens":\(cacheCreation),"cache_read_input_tokens":\(cacheRead),\
    "output_tokens":\(output),"service_tier":"standard"}},"requestId":"\(requestID)",\
    "uuid":"\(UUID().uuidString)","timestamp":"\(timestamp)"}
    """
}

private func isoDate(_ text: String) throws -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return try #require(formatter.date(from: text))
}

/// Agrega los deltas devueltos por el collector en un registro por día.
private func aggregateByDay(_ records: [UsageRecord]) -> [String: UsageRecord] {
    var totals: [String: UsageRecord] = [:]
    for record in records {
        if let existing = totals[record.day] {
            totals[record.day] = existing + record
        } else {
            totals[record.day] = record
        }
    }
    return totals
}

private func stateJSON(in directory: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: directory.appending(path: "state.json"))
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

/// Lo que se espera de un conjunto de entradas, agregado por día local.
private func expectedByDay(_ entries: [FixtureEntry]) throws -> [String: UsageRecord] {
    var totals: [String: UsageRecord] = [:]
    for entry in entries {
        let date = try isoDate(entry.timestamp)
        let day = DayKey.string(from: date)
        let record = UsageRecord(source: .claudeCode, day: day,
                                 inputTokens: entry.inputTokens,
                                 outputTokens: entry.outputTokens,
                                 cacheCreationTokens: entry.cacheCreationTokens,
                                 cacheReadTokens: entry.cacheReadTokens,
                                 costUSD: entry.costUSD)
        if let existing = totals[day] {
            totals[day] = existing + record
        } else {
            totals[day] = record
        }
    }
    return totals
}

/// Compara los deltas del collector contra las entradas esperadas, día por día.
/// El día se calcula en la zona LOCAL, así que la prueba no depende de la zona horaria.
private func expectMatches(_ records: [UsageRecord], _ entries: [FixtureEntry]) throws {
    let actual = aggregateByDay(records)
    let expected = try expectedByDay(entries)

    #expect(Set(actual.keys) == Set(expected.keys))
    for (day, want) in expected {
        let got = try #require(actual[day], "falta el día \(day)")
        #expect(got.source == .claudeCode)
        #expect(got.inputTokens == want.inputTokens)
        #expect(got.outputTokens == want.outputTokens)
        #expect(got.cacheCreationTokens == want.cacheCreationTokens)
        #expect(got.cacheReadTokens == want.cacheReadTokens)
        #expect(approxEqual(got.costUSD, want.costUSD))
    }
}

/// Raíz de transcripts + estado, cada uno en su propio directorio temporal.
private struct Harness {
    let root: URL
    let stateDirectory: URL
    let state: CollectorStateStore
    let collector: ClaudeCodeCollector

    func cleanUp() {
        removeDirectory(root)
        removeDirectory(stateDirectory)
    }
}

// TODO(contract): el contrato solo fija el protocolo `UsageCollector`. Estos tests dependen
// además de `init(rootDirectory:store:)` para inyectar una raíz temporal en vez de
// `~/.claude/projects` (verificado contra la implementación actual del collector).
private func makeHarness(limits: ClaudeCodeCollector.CycleLimits = .production) -> Harness {
    let root = makeTemporaryDirectory()
    let stateDirectory = makeTemporaryDirectory()
    let state = CollectorStateStore(directory: stateDirectory)
    return Harness(root: root,
                   stateDirectory: stateDirectory,
                   state: state,
                   collector: ClaudeCodeCollector(rootDirectory: root, store: state, limits: limits))
}

// MARK: - Tests

@Suite("ClaudeCodeCollector")
struct ClaudeCodeCollectorTests {

    @Test("el source del collector es claudeCode")
    func sourceDelCollector() {
        let harness = makeHarness()
        defer { harness.cleanUp() }
        #expect(harness.collector.source == .claudeCode)
    }

    @Test("parsea el transcript de ejemplo y agrega los totales por día")
    func parseaTotalesPorDia() async throws {
        let harness = makeHarness()
        defer { harness.cleanUp() }
        try stageFixture(in: harness.root)

        await harness.state.load()
        await harness.state.setBootstrapped(.claudeCode)
        let result = await harness.collector.collect()

        #expect(result.status == .ok)
        try expectMatches(result.records, fixtureEntries)
        #expect(result.records.allSatisfy({ $0.source == .claudeCode }))
    }

    @Test("un message.id duplicado se cuenta una sola vez")
    func duplicadoSeCuentaUnaVez() async throws {
        let harness = makeHarness()
        defer { harness.cleanUp() }
        try stageFixture(in: harness.root)

        await harness.state.load()
        await harness.state.setBootstrapped(.claudeCode)
        let result = await harness.collector.collect()

        // El fixture trae msg_A dos veces (mismo requestId). Contarlo dos veces daría 6525.
        let total = result.records.reduce(0) { $0 + $1.totalTokens }
        #expect(total == fixtureTotalTokens)
    }

    @Test("las líneas malformadas, vacías y sin usage no rompen el parseo")
    func lineasIgnorablesNoRompen() async throws {
        let harness = makeHarness()
        defer { harness.cleanUp() }
        try stageFixture(in: harness.root)

        await harness.state.load()
        await harness.state.setBootstrapped(.claudeCode)
        let result = await harness.collector.collect()

        #expect(result.status == .ok)
        #expect(!result.records.isEmpty)
        // La línea `user` del fixture trae un usage de 999_999 que NO debe contarse.
        let total = result.records.reduce(0) { $0 + $1.totalTokens }
        #expect(total == fixtureTotalTokens)
    }

    @Test("una segunda corrida sobre el mismo archivo sin cambios no devuelve nada")
    func segundaCorridaSinCambios() async throws {
        let harness = makeHarness()
        defer { harness.cleanUp() }
        try stageFixture(in: harness.root)

        await harness.state.load()
        await harness.state.setBootstrapped(.claudeCode)

        let first = await harness.collector.collect()
        #expect(!first.records.isEmpty)

        let second = await harness.collector.collect()
        #expect(second.status == .ok)
        #expect(second.records.isEmpty)
    }

    @Test("al apendear una línea la siguiente corrida devuelve solo ese delta")
    func soloDevuelveElDelta() async throws {
        let harness = makeHarness()
        defer { harness.cleanUp() }
        let transcript = try stageFixture(in: harness.root)

        await harness.state.load()
        await harness.state.setBootstrapped(.claudeCode)
        _ = await harness.collector.collect()

        let timestamp = "2026-08-04T10:15:00.000Z"
        try append(assistantLine(messageID: "msg_E", requestID: "req_E",
                                 model: "claude-haiku-4-5", timestamp: timestamp,
                                 input: 10, output: 5, cacheCreation: 0, cacheRead: 0),
                   to: transcript)

        let delta = await harness.collector.collect()
        #expect(delta.status == .ok)
        // haiku: (10*1.00 + 5*5.00) / 1e6
        try expectMatches(delta.records, [
            FixtureEntry(timestamp: timestamp, inputTokens: 10, outputTokens: 5,
                         cacheCreationTokens: 0, cacheReadTokens: 0, costUSD: 0.000035)
        ])
    }

    @Test("una cola sin salto de línea no se procesa hasta que se completa")
    func colaIncompletaEsperaElSalto() async throws {
        let harness = makeHarness()
        defer { harness.cleanUp() }
        let transcript = try stageFixture(in: harness.root)

        await harness.state.load()
        await harness.state.setBootstrapped(.claudeCode)
        _ = await harness.collector.collect()

        let timestamp = "2026-08-04T11:00:00.000Z"
        let line = assistantLine(messageID: "msg_F", requestID: "req_F",
                                 model: "claude-sonnet-4-5", timestamp: timestamp,
                                 input: 300, output: 100, cacheCreation: 0, cacheRead: 0)

        // Línea a medio escribir: sin "\n" final no debe contarse todavía.
        try append(line, to: transcript, newline: false)
        let partial = await harness.collector.collect()
        #expect(partial.records.isEmpty)

        // Al llegar el salto de línea, la corrida siguiente ya la procesa.
        try append("", to: transcript)
        let completed = await harness.collector.collect()
        // sonnet: (300*3.00 + 100*15.00) / 1e6
        try expectMatches(completed.records, [
            FixtureEntry(timestamp: timestamp, inputTokens: 300, outputTokens: 100,
                         cacheCreationTokens: 0, cacheReadTokens: 0, costUSD: 0.0024)
        ])
    }

    @Test("una línea mayor que maxBytes progresa y permite completar el bootstrap")
    func lineaMayorQueMaxBytesProgresa() async throws {
        let harness = makeHarness(limits: .init(timeBudget: .seconds(30),
                                                 maxBytes: 128,
                                                 maxFiles: 10))
        defer { harness.cleanUp() }
        let oversized = assistantLine(messageID: "msg_LARGE", requestID: "req_LARGE",
                                      model: "claude-haiku-4-5", timestamp: "2026-08-04T11:30:00Z",
                                      input: 10, output: 20, cacheCreation: 0, cacheRead: 0)
        let later = assistantLine(messageID: "msg_LATER", requestID: "req_LATER",
                                  model: "claude-haiku-4-5", timestamp: "2026-08-04T11:31:00Z",
                                  input: 30, output: 40, cacheCreation: 0, cacheRead: 0)
        #expect(Data((oversized + "\n").utf8).count > 128)
        try writeTranscript(oversized + "\n", in: harness.root, project: "primero")
        try writeTranscript(later + "\n", in: harness.root, project: "despues")
        await harness.state.load()

        var records: [UsageRecord] = []
        for _ in 0..<5 {
            records.append(contentsOf: await harness.collector.collect().records)
        }

        #expect(records.reduce(0) { $0 + $1.totalTokens } == 100)
        #expect(await harness.state.hasBootstrapped(.claudeCode))
        #expect((await harness.collector.collect()).records.isEmpty)
    }

    @Test("descarta una línea sobre la cota y procesa la siguiente")
    func descartaLineaSobreLaCota() async throws {
        let harness = makeHarness(limits: .init(timeBudget: .seconds(30),
                                                 maxBytes: 128,
                                                 maxFiles: 10,
                                                 maxLineBytes: 768))
        defer { harness.cleanUp() }
        let valid = assistantLine(messageID: "msg_OK", requestID: "req_OK",
                                  model: "claude-haiku-4-5", timestamp: "2026-08-04T11:32:00Z",
                                  input: 10, output: 20, cacheCreation: 0, cacheRead: 0)
        _ = try writeTranscript(String(repeating: "x", count: 1_024) + "\n" + valid + "\n",
                                in: harness.root, project: "grande")
        await harness.state.load()
        await harness.state.setBootstrapped(.claudeCode)

        #expect((await harness.collector.collect()).records.isEmpty)
        let result = await harness.collector.collect()
        #expect(result.records.reduce(0) { $0 + $1.totalTokens } == 30)
    }

    @Test("una cola sobre la cota sin salto avanza hasta EOF")
    func colaSobreLaCotaSinSaltoAvanza() async throws {
        let harness = makeHarness(limits: .init(timeBudget: .seconds(30),
                                                 maxBytes: 128,
                                                 maxFiles: 10,
                                                 maxLineBytes: 768))
        defer { harness.cleanUp() }
        let transcript = try writeTranscript(String(repeating: "x", count: 1_024),
                                             in: harness.root, project: "incompleta",
                                             modified: Date())
        await harness.state.load()
        await harness.state.setBootstrapped(.claudeCode)

        #expect((await harness.collector.collect()).records.isEmpty)
        #expect((await harness.collector.collect()).records.isEmpty)

        let valid = assistantLine(messageID: "msg_AFTER", requestID: "req_AFTER",
                                  model: "claude-haiku-4-5", timestamp: "2026-08-04T11:33:00Z",
                                  input: 15, output: 25, cacheCreation: 0, cacheRead: 0)
        try append("", to: transcript)
        try append(valid, to: transcript)
        var records: [UsageRecord] = []
        for _ in 0..<5 {
            records.append(contentsOf: await harness.collector.collect().records)
        }
        #expect(records.reduce(0) { $0 + $1.totalTokens } == 40)
    }

    @Test("el primer arranque solo lee archivos modificados hoy")
    func primerArranqueSoloArchivosDeHoy() async throws {
        let harness = makeHarness()
        defer { harness.cleanUp() }

        try stageFixture(in: harness.root, project: "reciente", modified: Date())
        let old = assistantLine(messageID: "msg_OLD", requestID: "req_OLD",
                                model: "claude-haiku-4-5", timestamp: "2026-07-20T10:00:00.000Z",
                                input: 999, output: 1, cacheCreation: 0, cacheRead: 0)
        try writeTranscript(old + "\n", in: harness.root, project: "viejo",
                            modified: Date().addingTimeInterval(-10 * 86_400))

        // Sin `setBootstrapped`: esta es la rama de primer arranque.
        await harness.state.load()
        let bootstrappedBefore = await harness.state.hasBootstrapped(.claudeCode)
        #expect(!bootstrappedBefore)

        let result = await harness.collector.collect()
        #expect(result.status == .ok)

        // Solo entra el archivo de hoy; los 1000 tokens del viejo quedan fuera.
        let total = result.records.reduce(0) { $0 + $1.totalTokens }
        #expect(total == fixtureTotalTokens)
        try expectMatches(result.records, fixtureEntries)

        // TODO(contract): el contrato no lo exige, pero el primer arranque debe dejar marcado
        // el bootstrap para no repetir el filtro por mtime (así lo hace la implementación).
        let bootstrappedAfter = await harness.state.hasBootstrapped(.claudeCode)
        #expect(bootstrappedAfter)
    }

    @Test("una raíz vacía devuelve cero registros sin fallar")
    func raizVacia() async throws {
        let harness = makeHarness()
        defer { harness.cleanUp() }

        await harness.state.load()
        await harness.state.setBootstrapped(.claudeCode)
        let result = await harness.collector.collect()

        #expect(result.records.isEmpty)
        #expect(result.status == .ok)
    }

    @Test("una raíz inexistente no crashea ni devuelve registros")
    func raizInexistente() async throws {
        let harness = makeHarness()
        defer { harness.cleanUp() }
        removeDirectory(harness.root)

        await harness.state.load()
        await harness.state.setBootstrapped(.claudeCode)
        let result = await harness.collector.collect()

        #expect(result.records.isEmpty)
    }

    @Test("recorre subdirectorios y suma varios transcripts")
    func recorreVariosProyectos() async throws {
        let harness = makeHarness()
        defer { harness.cleanUp() }

        try stageFixture(in: harness.root, project: "proyecto-uno")
        let extra = assistantLine(messageID: "msg_G", requestID: "req_G",
                                  model: "claude-haiku-4-5", timestamp: "2026-08-04T12:00:00.000Z",
                                  input: 40, output: 60, cacheCreation: 0, cacheRead: 0)
        try writeTranscript(extra + "\n", in: harness.root, project: "proyecto-dos")

        await harness.state.load()
        await harness.state.setBootstrapped(.claudeCode)
        let result = await harness.collector.collect()

        let total = result.records.reduce(0) { $0 + $1.totalTokens }
        #expect(total == fixtureTotalTokens + 100)
    }

    @Test("un modelo fable se tarifa con su propia tabla")
    func modeloFable() async throws {
        let harness = makeHarness()
        defer { harness.cleanUp() }

        let timestamp = "2026-08-04T13:00:00.000Z"
        let line = assistantLine(messageID: "msg_H", requestID: "req_H",
                                 model: "claude-fable-5", timestamp: timestamp,
                                 input: 100, output: 20, cacheCreation: 0, cacheRead: 1000)
        try writeTranscript(line + "\n", in: harness.root, project: "proyecto-fable")

        await harness.state.load()
        await harness.state.setBootstrapped(.claudeCode)
        let result = await harness.collector.collect()

        // fable: (100*10.00 + 20*50.00 + 0*12.50 + 1000*1.00) / 1e6
        try expectMatches(result.records, [
            FixtureEntry(timestamp: timestamp, inputTokens: 100, outputTokens: 20,
                         cacheCreationTokens: 0, cacheReadTokens: 1000, costUSD: 0.003)
        ])
    }

    @Test("un modelo desconocido cuenta tokens pero con costo 0")
    func modeloDesconocidoCuestaCero() async throws {
        let harness = makeHarness()
        defer { harness.cleanUp() }

        let timestamp = "2026-08-04T14:00:00.000Z"
        let line = assistantLine(messageID: "msg_I", requestID: "req_I",
                                 model: "<synthetic>", timestamp: timestamp,
                                 input: 5, output: 5, cacheCreation: 0, cacheRead: 0)
        try writeTranscript(line + "\n", in: harness.root, project: "proyecto-sintetico")

        await harness.state.load()
        await harness.state.setBootstrapped(.claudeCode)
        let result = await harness.collector.collect()

        try expectMatches(result.records, [
            FixtureEntry(timestamp: timestamp, inputTokens: 5, outputTokens: 5,
                         cacheCreationTokens: 0, cacheReadTokens: 0, costUSD: 0)
        ])
    }

    @Test("migra el estado legado sin recontar transcripts")
    func migraEstadoLegadoSinRecontar() async throws {
        let harness = makeHarness()
        defer { harness.cleanUp() }
        let timestamp = "2026-08-04T15:00:00.000Z"
        let transcript = assistantLine(messageID: "msg_LEGACY", requestID: "req_LEGACY",
                                       model: "claude-sonnet-4-5", timestamp: timestamp,
                                       input: 10, output: 25, cacheCreation: 30, cacheRead: 40) + "\n"
        let url = try writeTranscript(transcript, in: harness.root, project: "legado")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let modified = try #require(attributes[.modificationDate] as? Date)
        let legacy: [String: Any] = [
            "version": 1,
            "bootstrapped": ["claudeCode"],
            "cursors": [url.path: [
                "offset": 0,
                "size": 0,
                "modified": ISO8601DateFormatter().string(from: modified)
            ]],
            "seenMessageIDs": [
                "msg_LEGACY|req_LEGACY",
                "msg_LEGACY|req_LEGACY#5",
                "msg_LEGACY|req_LEGACY#25",
                "foreign-id",
                "foreign-id#12"
            ]
        ]
        try JSONSerialization.data(withJSONObject: legacy)
            .write(to: harness.stateDirectory.appending(path: "state.json"))

        await harness.state.load()
        let result = await harness.collector.collect()
        #expect(result.records.isEmpty)
        await harness.state.save()

        let migrated = try stateJSON(in: harness.stateDirectory)
        #expect(migrated["version"] as? Int == 2)
        #expect(migrated["seenMessageIDs"] as? [String] == ["foreign-id", "foreign-id#12"])
        let messages = try #require(migrated["claudeMessages"] as? [[String: Any]])
        #expect(messages.count == 1)
        #expect(messages.first?["key"] as? String == "msg_LEGACY|req_LEGACY")
        #expect(messages.first?["output"] as? Int == 25)
    }

    @Test("una versión futura conserva los campos de estado compatibles")
    func versionFuturaConservaEstadoCompatible() async throws {
        let harness = makeHarness()
        defer { harness.cleanUp() }
        let line = assistantLine(messageID: "msg_FUTURE", requestID: "req_FUTURE",
                                 model: "claude-haiku-4-5", timestamp: "2026-08-04T15:30:00Z",
                                 input: 10, output: 25, cacheCreation: 0, cacheRead: 0) + "\n"
        let transcript = try writeTranscript(line, in: harness.root, project: "futuro")
        let attributes = try FileManager.default.attributesOfItem(atPath: transcript.path)
        let modified = try #require(attributes[.modificationDate] as? Date)
        let future: [String: Any] = [
            "version": 3,
            "bootstrapped": ["claudeCode"],
            "cursors": [transcript.path: [
                "offset": Data(line.utf8).count,
                "size": Data(line.utf8).count,
                "modified": ISO8601DateFormatter().string(from: modified)
            ]],
            "seenMessageIDs": ["foreign-future#7"],
            "claudeMessages": [["key": "msg_FUTURE|req_FUTURE", "output": 25]],
            "futureField": ["enabled": true]
        ]
        try JSONSerialization.data(withJSONObject: future)
            .write(to: harness.stateDirectory.appending(path: "state.json"))

        await harness.state.load()

        #expect(await harness.state.hasBootstrapped(.claudeCode))
        #expect(await harness.state.markSeen(messageID: "foreign-future#7"))
        let delta = await harness.state.recordClaudeMessage(key: "msg_FUTURE|req_FUTURE", output: 30)
        #expect(!delta.isNewMessage)
        #expect(delta.outputTokens == 5)
        #expect((await harness.collector.collect()).records.isEmpty)
    }

    @Test("el estado crece por mensaje y no por parcial")
    func estadoCrecePorMensaje() async throws {
        let harness = makeHarness()
        defer { harness.cleanUp() }
        let timestamp = "2026-08-04T16:00:00.000Z"
        let lines = [1, 10, 50].map { output in
            assistantLine(messageID: "msg_STREAM", requestID: "req_STREAM",
                          model: "claude-sonnet-4-5", timestamp: timestamp,
                          input: 10, output: output, cacheCreation: 20, cacheRead: 30)
        }.joined(separator: "\n") + "\n"
        try writeTranscript(lines, in: harness.root, project: "stream")

        await harness.state.load()
        await harness.state.setBootstrapped(.claudeCode)
        let result = await harness.collector.collect()
        #expect(result.records.reduce(0) { $0 + $1.totalTokens } == 110)
        await harness.state.save()

        let json = try stateJSON(in: harness.stateDirectory)
        let messages = try #require(json["claudeMessages"] as? [[String: Any]])
        #expect(messages.count == 1)
        #expect(messages.first?["output"] as? Int == 50)
    }

    @Test("un reinicio durante streaming conserva la marca de agua")
    func reinicioConservaMarcaDeAgua() async throws {
        let harness = makeHarness()
        defer { harness.cleanUp() }
        let timestamp = "2026-08-04T17:00:00.000Z"
        let transcript = try writeTranscript(
            assistantLine(messageID: "msg_RESTART", requestID: "req_RESTART",
                          model: "claude-haiku-4-5", timestamp: timestamp,
                          input: 10, output: 20, cacheCreation: 0, cacheRead: 0) + "\n",
            in: harness.root, project: "restart"
        )
        await harness.state.load()
        await harness.state.setBootstrapped(.claudeCode)
        _ = await harness.collector.collect()
        await harness.state.save()

        try append(assistantLine(messageID: "msg_RESTART", requestID: "req_RESTART",
                                 model: "claude-haiku-4-5", timestamp: timestamp,
                                 input: 10, output: 75, cacheCreation: 0, cacheRead: 0),
                   to: transcript)
        let reloadedState = CollectorStateStore(directory: harness.stateDirectory)
        await reloadedState.load()
        let reloaded = ClaudeCodeCollector(rootDirectory: harness.root, store: reloadedState)
        let delta = await reloaded.collect()
        #expect(delta.records.reduce(0) { $0 + $1.inputTokens } == 0)
        #expect(delta.records.reduce(0) { $0 + $1.outputTokens } == 55)
    }

    @Test("varios ciclos acotados convergen al total de una corrida")
    func ciclosAcotadosConvergen() async throws {
        let lines = (0..<3).map { index in
            assistantLine(messageID: "msg_LIMIT_\(index)", requestID: "req_LIMIT_\(index)",
                          model: "claude-sonnet-4-5",
                          timestamp: "2026-08-0\(3 + index)T12:00:00Z",
                          input: 10 + index, output: 20 + index,
                          cacheCreation: 30 + index, cacheRead: 40 + index)
        }
        let contents = lines.joined(separator: "\n") + "\n"
        let byteLimit = Data((lines[0] + "\n").utf8).count
        let full = makeHarness()
        let limited = makeHarness(limits: .init(timeBudget: .seconds(30),
                                                maxBytes: byteLimit,
                                                maxFiles: 10))
        defer {
            full.cleanUp()
            limited.cleanUp()
        }
        try writeTranscript(contents, in: full.root, project: "completo")
        try writeTranscript(contents, in: limited.root, project: "acotado")
        await full.state.load()
        await limited.state.load()
        await full.state.setBootstrapped(.claudeCode)
        await limited.state.setBootstrapped(.claudeCode)

        let expected = aggregateByDay(await full.collector.collect().records)
        var limitedRecords: [UsageRecord] = []
        for _ in 0..<5 {
            limitedRecords.append(contentsOf: await limited.collector.collect().records)
        }
        let actual = aggregateByDay(limitedRecords)
        #expect(actual == expected)
        #expect((await limited.collector.collect()).records.isEmpty)
    }

    @Test("un deadline agotado corta aunque ningún archivo tenga bytes nuevos")
    func deadlineAgotadoSinBytesNuevos() async throws {
        let harness = makeHarness(limits: .init(timeBudget: .zero,
                                                 maxBytes: 1_024 * 1_024,
                                                 maxFiles: 10))
        defer { harness.cleanUp() }
        let oldDate = Date().addingTimeInterval(-10 * 86_400)
        try writeTranscript("{}\n", in: harness.root, project: "viejo-uno", modified: oldDate)
        try writeTranscript("{}\n", in: harness.root, project: "viejo-dos", modified: oldDate)
        await harness.state.load()

        let result = await harness.collector.collect()

        #expect(result.records.isEmpty)
        #expect(!(await harness.state.hasBootstrapped(.claudeCode)))
    }

    @Test("un presupuesto agotado conserva progreso por línea completa")
    func presupuestoAgotadoConservaProgreso() async throws {
        let harness = makeHarness(limits: .init(timeBudget: .zero,
                                                maxBytes: 1_024 * 1_024,
                                                maxFiles: 10))
        defer { harness.cleanUp() }
        let first = assistantLine(messageID: "msg_BUDGET_1", requestID: "req_BUDGET_1",
                                  model: "claude-haiku-4-5", timestamp: "2026-08-04T18:00:00Z",
                                  input: 10, output: 20, cacheCreation: 0, cacheRead: 0)
        let second = assistantLine(messageID: "msg_BUDGET_2", requestID: "req_BUDGET_2",
                                   model: "claude-haiku-4-5", timestamp: "2026-08-04T18:00:01Z",
                                   input: 30, output: 40, cacheCreation: 0, cacheRead: 0)
        try writeTranscript(first + "\n" + second + "\n", in: harness.root, project: "presupuesto")
        await harness.state.load()
        await harness.state.setBootstrapped(.claudeCode)

        let cycle1 = await harness.collector.collect()
        let cycle2 = await harness.collector.collect()
        let cycle3 = await harness.collector.collect()
        #expect(cycle1.records.reduce(0) { $0 + $1.totalTokens } == 30)
        #expect(cycle2.records.reduce(0) { $0 + $1.totalTokens } == 70)
        #expect(cycle3.records.isEmpty)
    }

    @Test("un ciclo cortado por presupuesto no poda cursores; uno completo sí")
    func cicloCortadoNoPodaPeroUnoCompletoSi() async throws {
        let root = makeTemporaryDirectory()
        let stateDirectory = makeTemporaryDirectory()
        defer {
            removeDirectory(root)
            removeDirectory(stateDirectory)
        }
        try writeTranscript("{}\n", in: root, project: "uno", modified: Date())
        try writeTranscript("{}\n", in: root, project: "dos", modified: Date())

        // Cursor "huérfano": apunta a un archivo que ya no existe en disco.
        let stalePath = root.appending(path: "borrado/fantasma.jsonl").path
        let legacy: [String: Any] = [
            "version": 2,
            "bootstrapped": ["claudeCode"],
            "cursors": [stalePath: [
                "offset": 10, "size": 10,
                "modified": ISO8601DateFormatter().string(from: Date())
            ]],
            "seenMessageIDs": [],
            "claudeMessages": []
        ]
        try JSONSerialization.data(withJSONObject: legacy)
            .write(to: stateDirectory.appending(path: "state.json"))

        // Ciclo con presupuesto agotado: no alcanza a recorrer todo el árbol (dos archivos).
        let truncatedState = CollectorStateStore(directory: stateDirectory)
        await truncatedState.load()
        #expect(await truncatedState.cursor(forPath: stalePath) != nil)
        let truncatedCollector = ClaudeCodeCollector(
            rootDirectory: root, store: truncatedState,
            limits: .init(timeBudget: .zero, maxBytes: 1_024 * 1_024, maxFiles: 10)
        )
        _ = await truncatedCollector.collect()
        await truncatedState.save()
        #expect(await truncatedState.cursor(forPath: stalePath) != nil,
                "un ciclo cortado por presupuesto no debe podar cursores de archivos que no visitó")

        // Con presupuesto normal, un recorrido completo sí poda el cursor huérfano.
        let fullState = CollectorStateStore(directory: stateDirectory)
        await fullState.load()
        let fullCollector = ClaudeCodeCollector(rootDirectory: root, store: fullState)
        _ = await fullCollector.collect()
        await fullState.save()
        #expect(await fullState.cursor(forPath: stalePath) == nil,
                "un recorrido completo debe podar cursores de archivos borrados")
    }

    @Test("acepta timestamps con y sin fracciones y omite los inválidos")
    func formatosDeTimestamp() async throws {
        let harness = makeHarness()
        defer { harness.cleanUp() }
        let fractional = assistantLine(messageID: "msg_TS_1", requestID: "req_TS_1",
                                       model: "claude-haiku-4-5",
                                       timestamp: "2026-08-04T18:00:00.123Z",
                                       input: 1, output: 2, cacheCreation: 0, cacheRead: 0)
        let whole = assistantLine(messageID: "msg_TS_2", requestID: "req_TS_2",
                                  model: "claude-haiku-4-5",
                                  timestamp: "2026-08-04T18:00:01Z",
                                  input: 3, output: 4, cacheCreation: 0, cacheRead: 0)
        let invalid = assistantLine(messageID: "msg_TS_BAD", requestID: "req_TS_BAD",
                                    model: "claude-haiku-4-5", timestamp: "no-es-fecha",
                                    input: 100, output: 200, cacheCreation: 0, cacheRead: 0)
        try writeTranscript([fractional, whole, invalid].joined(separator: "\n") + "\n",
                            in: harness.root, project: "timestamps")

        await harness.state.load()
        await harness.state.setBootstrapped(.claudeCode)
        let result = await harness.collector.collect()
        #expect(result.records.count == 1)
        #expect(result.records.first?.inputTokens == 4)
        #expect(result.records.first?.outputTokens == 6)
        #expect(result.records.first?.day == DayKey.string(from: try isoDate("2026-08-04T18:00:00.123Z")))

        let badDelta = await harness.state.recordClaudeMessage(key: "msg_TS_BAD|req_TS_BAD", output: 200)
        #expect(badDelta.isNewMessage)
    }
}
