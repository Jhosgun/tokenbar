import Foundation
import OSLog

/// Lee los rollouts de Codex (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`) de forma incremental.
///
/// Cada rollout trae dos eventos con uso; se usa solo `token_usage_record` (uno por respuesta,
/// con `response_id`), deduplicado por ese id en el estado durable. Los `token_count` repiten
/// acumulados y no se leen: los rollouts anteriores a `token_usage_record` quedan fuera, y todos
/// son de hace más de 90 días.
///
/// Normalización (verificada contra los rollouts reales: `total_tokens == input + output` en el
/// 100 % de los registros y `cached + cache_write <= input` también): `input_tokens` ya incluye
/// el caché, así que el input sin caché es `input − cached − cache_write`, saturado en 0.
/// `reasoning_output_tokens` ya está dentro de `output_tokens` y no se suma aparte. El modelo
/// sale de la última línea `turn_context`. No hay tarifa confiable: `costUSD = 0`.
struct CodexCollector: UsageCollector {
    let source: AppSource = .codex

    private let rootDirectory: URL
    private let store: CollectorStateStore
    private let limits: JSONLScanner.Limits
    private let logger = Logger(subsystem: "io.github.jhosgun.tokenbar", category: "codex")

    static let defaultRootDirectory: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".codex", isDirectory: true)
        .appendingPathComponent("sessions", isDirectory: true)

    init(rootDirectory: URL = CodexCollector.defaultRootDirectory,
         store: CollectorStateStore,
         limits: JSONLScanner.Limits = .production) {
        self.rootDirectory = rootDirectory
        self.store = store
        self.limits = limits
    }

    func collect() async -> CollectorResult {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rootDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return .empty(.notConfigured)
        }

        let files = rolloutFiles()
        let bootstrapped = await store.hasBootstrapped(source)
        let cutoffDay = UsageRetention.cutoffDay()
        let formatters = ClaudeCodeCollector.TimestampFormatters()
        let scanner = JSONLScanner(source: source, store: store, limits: limits)

        var accumulator = ModelUsageAccumulator(source: source)
        var currentModel: String?

        let outcome = await scanner.scan(
            files: files,
            bootstrapped: bootstrapped,
            now: Date(),
            onFileStart: { path in
                currentModel = await store.codexModel(forPath: path)
            },
            onLine: { line, _ in
                let isContext = line.containsBytes(of: Self.turnContextMarker)
                guard isContext || line.containsBytes(of: Self.usageRecordMarker) else { return false }
                guard let entry = try? JSONDecoder().decode(Entry.self, from: line) else { return true }

                if entry.type == "turn_context" {
                    if let model = entry.payload?.model, !model.isEmpty { currentModel = model }
                    return false
                }
                guard entry.type == "token_usage_record",
                      let payload = entry.payload,
                      let usage = payload.usage,
                      let responseID = payload.responseID else { return false }
                guard let timestamp = entry.timestamp, let date = formatters.date(from: timestamp) else {
                    return true
                }
                let day = DayKey.string(from: date)
                guard day >= cutoffDay else { return false }
                if await store.markCodexResponseSeen(responseID: responseID, source: Self.dedupeSource) {
                    return false
                }

                let input = usage.inputTokens ?? 0
                let cacheRead = usage.cachedInputTokens ?? 0
                let cacheWrite = usage.cacheWriteInputTokens ?? 0
                accumulator.add(
                    day: day, model: currentModel ?? Self.unknownModel,
                    inputTokens: max(0, input - cacheRead - cacheWrite),
                    outputTokens: usage.outputTokens ?? 0,
                    cacheCreationTokens: cacheWrite, cacheReadTokens: cacheRead,
                    costUSD: 0
                )
                return false
            },
            onFileEnd: { path in
                if let currentModel { await store.setCodexModel(currentModel, forPath: path) }
            }
        )

        if !bootstrapped, outcome.completed {
            await store.setBootstrapped(source)
        }
        logger.debug("""
            \(outcome.filesParsed) rollouts leídos, \(outcome.filesFailed) fallos, \
            \(outcome.malformedLines) líneas malformadas
            """)
        if outcome.filesParsed == 0 && outcome.filesFailed > 0 {
            return .empty(.failed("No se pudieron leer los rollouts de Codex"))
        }
        return accumulator.result()
    }

    private func rolloutFiles() -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: rootDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsPackageDescendants, .skipsHiddenFiles]
        ) else { return [] }
        var files: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension == "jsonl", url.lastPathComponent.hasPrefix("rollout-"),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            files.append(url)
        }
        return files.sorted { $0.path < $1.path }
    }

    private static let dedupeSource = "token_usage_record"
    private static let unknownModel = "desconocido"
    private static let turnContextMarker = Array("\"turn_context\"".utf8)
    private static let usageRecordMarker = Array("\"token_usage_record\"".utf8)

    // MARK: - Forma del JSONL

    private struct Entry: Decodable {
        var type: String?
        var timestamp: String?
        var payload: Payload?

        struct Payload: Decodable {
            var model: String?
            var responseID: String?
            var usage: Usage?

            enum CodingKeys: String, CodingKey {
                case model, usage
                case responseID = "response_id"
            }
        }

        struct Usage: Decodable {
            var inputTokens: Int?
            var cachedInputTokens: Int?
            var cacheWriteInputTokens: Int?
            var outputTokens: Int?

            enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case cachedInputTokens = "cached_input_tokens"
                case cacheWriteInputTokens = "cache_write_input_tokens"
                case outputTokens = "output_tokens"
            }
        }
    }
}
