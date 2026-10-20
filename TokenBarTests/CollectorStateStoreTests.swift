import Foundation
import Testing

@testable import TokenBar

@Suite("CollectorStateStore v3")
struct CollectorStateStoreV3Tests {

    @Test("migra v2 a v3 sin perder ningún campo")
    func migracionV2SinPerdida() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let stateURL = directory.appending(path: "state.json", directoryHint: .notDirectory)
        let v2 = """
        {"version":2,"bootstrapped":["claudeCode","cursor"],
        "cursors":{"/logs/a.jsonl":{"offset":12,"size":34,"modified":"2026-10-05T12:00:00Z"}},
        "seenMessageIDs":["general-1","general-2"],
        "claudeMessages":[{"key":"msg_1|req_1","output":42}],
        "cursorLastEventTimestampMs":123456,
        "cursorContinuation":{"startMs":100,"frontierMs":150,"ceilingMs":200}}
        """
        try Data(v2.utf8).write(to: stateURL)

        let store = CollectorStateStore(directory: directory)
        await store.load()

        #expect(await store.hasBootstrapped(.claudeCode))
        #expect(await store.hasBootstrapped(.cursor))
        #expect(await store.cursor(forPath: "/logs/a.jsonl")?.offset == 12)
        #expect(await store.cursor(forPath: "/logs/a.jsonl")?.size == 34)
        #expect(await store.markSeen(messageID: "general-1"))
        let claudeDelta = await store.recordClaudeMessage(key: "msg_1|req_1", output: 42)
        #expect(!claudeDelta.isNewMessage)
        #expect(claudeDelta.outputTokens == 0)
        #expect(await store.cursorLastEventTimestamp() == 123456)
        #expect(await store.cursorContinuation() == CursorContinuation(
            startMs: 100, frontierMs: 150, ceilingMs: 200
        ))

        await store.save()
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL))
            as? [String: Any])
        #expect(object["version"] as? Int == 4)
        #expect(object["bootstrapped"] as? [String] == ["claudeCode", "cursor"])
        #expect((object["seenMessageIDs"] as? [String])?.contains("general-2") == true)
        #expect(object["codexResponseIDsBySource"] as? [String: [String]] == [:])
        #expect(object["codexModelByPath"] as? [String: String] == [:])
        #expect(object["commandCodeMessageIDs"] as? [String] == [])
        #expect(object["openCodeFinalizedMessageIDs"] as? [String] == [])
    }

    @Test("persiste y restaura el estado de los collectors nuevos")
    func roundTripEstadoNuevo() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = CollectorStateStore(directory: directory)
        await store.load()
        #expect(!(await store.markCodexResponseSeen(responseID: "response-1", source: "token_count")))
        await store.setCodexModel("gpt-5.6", forPath: "/codex/rollout.jsonl")
        #expect(!(await store.markCommandCodeSeen(messageID: "cc-1")))
        #expect(!(await store.markOpenCodeFinalized(messageID: "oc-1")))
        await store.setOpenCodeWatermark(OpenCodeWatermark(timeUpdatedMs: 123, id: "oc-2"))
        await store.save()

        let reopened = CollectorStateStore(directory: directory)
        await reopened.load()
        #expect(await reopened.markCodexResponseSeen(responseID: "response-1", source: "token_count"))
        #expect(!(await reopened.markCodexResponseSeen(responseID: "response-1", source: "token_usage_record")))
        #expect(await reopened.codexModel(forPath: "/codex/rollout.jsonl") == "gpt-5.6")
        #expect(await reopened.markCommandCodeSeen(messageID: "cc-1"))
        #expect(await reopened.markOpenCodeFinalized(messageID: "oc-1"))
        #expect(await reopened.openCodeWatermark() == OpenCodeWatermark(timeUpdatedMs: 123, id: "oc-2"))
    }

    @Test("recordCursorEvent: el primer registro es el evento entero, después solo la diferencia positiva")
    func fotoDeCursorDevuelveDeltas() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = CollectorStateStore(directory: directory)
        await store.load()
        let id = "cursor:conv-a:1790000000000"
        func snapshot(_ input: Int, _ output: Int, _ write: Int, _ read: Int, _ cost: Double) -> CursorEventSnapshot {
            CursorEventSnapshot(timestampMs: 1_790_000_000_000, inputTokens: input, outputTokens: output,
                                cacheCreationTokens: write, cacheReadTokens: read, costUSD: cost)
        }

        let first = await store.recordCursorEvent(id: id, snapshot: snapshot(100, 10, 0, 1_000, 0.09))
        #expect(first.isNewEvent)
        #expect(first.delta == snapshot(100, 10, 0, 1_000, 0.09))
        #expect(!first.shrank)

        // Crece en output, cacheRead y cacheWrite; baja en input: se suma lo que creció y
        // nada se resta, pero `shrank` lo avisa.
        let second = await store.recordCursorEvent(id: id, snapshot: snapshot(90, 25, 200, 5_000, 0.171))
        #expect(!second.isNewEvent)
        #expect(second.delta.inputTokens == 0)
        #expect(second.delta.outputTokens == 15)
        #expect(second.delta.cacheCreationTokens == 200)
        #expect(second.delta.cacheReadTokens == 4_000)
        #expect(abs(second.delta.costUSD - 0.081) < 1e-9)
        #expect(second.shrank)

        // La misma foto otra vez: nada que sumar.
        let third = await store.recordCursorEvent(id: id, snapshot: snapshot(100, 25, 200, 5_000, 0.171))
        #expect(third.delta.totalTokens == 0)
        #expect(third.delta.costUSD == 0)
        #expect(!third.shrank)

        // Sobrevive al disco: tras recargar, la foto guardada es el máximo por campo.
        await store.save()
        let reopened = CollectorStateStore(directory: directory)
        await reopened.load()
        let fourth = await reopened.recordCursorEvent(id: id, snapshot: snapshot(100, 26, 200, 5_000, 0.171))
        #expect(!fourth.isNewEvent)
        #expect(fourth.delta.totalTokens == 1)
    }

    @Test("las fotos de Cursor con más de 40 días se purgan al guardar; las recientes no")
    func purgaFotosDeCursorViejas() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let oldMs = nowMs - 41 * 86_400 * 1000
        let recentMs = nowMs - 39 * 86_400 * 1000
        func snapshot(_ timestampMs: Int64) -> CursorEventSnapshot {
            CursorEventSnapshot(timestampMs: timestampMs, inputTokens: 1, outputTokens: 0,
                                cacheCreationTokens: 0, cacheReadTokens: 0, costUSD: 0)
        }
        let v3 = """
        {"version":3,"bootstrapped":[],"cursors":{},
         "seenMessageIDs":["cursor:conv-legado-viejo:\(oldMs)","cursor:conv-legado-reciente:\(recentMs)"],
         "claudeMessages":[]}
        """
        let stateURL = directory.appending(path: "state.json", directoryHint: .notDirectory)
        try Data(v3.utf8).write(to: stateURL)

        let store = CollectorStateStore(directory: directory)
        await store.load()
        _ = await store.recordCursorEvent(id: "cursor:conv-viejo:\(oldMs)", snapshot: snapshot(oldMs))
        _ = await store.recordCursorEvent(id: "cursor:conv-reciente:\(recentMs)", snapshot: snapshot(recentMs))
        await store.save()

        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL))
            as? [String: Any])
        let snapshots = try #require(object["cursorEventSnapshots"] as? [String: Any])
        #expect(snapshots.keys.sorted() == ["cursor:conv-reciente:\(recentMs)"])
        #expect(object["cursorSeenWithoutSnapshot"] as? [String] == ["cursor:conv-legado-reciente:\(recentMs)"])

        let reopened = CollectorStateStore(directory: directory)
        await reopened.load()
        // El viejo ya no tiene foto: si volviera a aparecer se contaría como nuevo (no
        // puede: la ventana de relectura es de 2 días). El reciente sí conserva su foto.
        #expect(await reopened.recordCursorEvent(id: "cursor:conv-viejo:\(oldMs)", snapshot: snapshot(oldMs)).isNewEvent)
        #expect(!(await reopened.recordCursorEvent(id: "cursor:conv-reciente:\(recentMs)", snapshot: snapshot(recentMs)).isNewEvent))
        // El legado reciente sigue tratándose como ya contado: delta cero, sin crear foto.
        let legacy = await reopened.recordCursorEvent(id: "cursor:conv-legado-reciente:\(recentMs)", snapshot: snapshot(recentMs))
        #expect(!legacy.isNewEvent)
        #expect(legacy.delta.totalTokens == 0)
    }

    @Test("la poda de Claude Code no borra los cursores de Codex ni de Command Code")
    func podaDeClaudeRespetaCursoresAjenos() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = CollectorStateStore(directory: directory)
        await store.load()
        let cursor = FileCursor(offset: 1, size: 1, modified: Date(timeIntervalSince1970: 0))
        let codexKey = CollectorStateStore.cursorKey(forPath: "/c/rollout.jsonl", source: .codex)
        let commandKey = CollectorStateStore.cursorKey(forPath: "/c/s.jsonl", source: .commandCode)
        await store.setCursor(cursor, forPath: codexKey)
        await store.setCursor(cursor, forPath: commandKey)
        await store.setCursor(cursor, forPath: "/claude/a.jsonl")

        await store.pruneCursors(keeping: [])

        #expect(await store.cursor(forPath: codexKey) == cursor)
        #expect(await store.cursor(forPath: commandKey) == cursor)
        #expect(await store.cursor(forPath: "/claude/a.jsonl") == nil)
    }
}
