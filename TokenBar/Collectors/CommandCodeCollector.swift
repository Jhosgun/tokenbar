import Foundation
import OSLog

/// Lee las sesiones de Command Code (`~/.commandcode/projects/<slug>/<uuid>.jsonl`) de forma
/// incremental, sin los `*.checkpoints.jsonl` (no traen uso).
///
/// Cada mensaje de asistente trae `usage{inputTokens, outputTokens, cacheReadTokens,
/// cacheWriteTokens, costUsd}`, `model`, `timestamp` ISO e `id`. El id se deduplica en el estado
/// durable junto con el nombre de la sesión (los ids son hex cortos).
///
/// Normalización (verificada contra las sesiones reales: `cacheRead + cacheWrite <= inputTokens`
/// en el 100 % de los registros, y el `costUsd` solo cuadra con las tarifas del modelo si el
/// input facturado a precio normal es `inputTokens − cacheRead − cacheWrite`): `inputTokens`
/// incluye los dos cachés, así que el input sin caché es esa resta, saturada en 0.
struct CommandCodeCollector: UsageCollector {
    let source: AppSource = .commandCode

    private let rootDirectory: URL
    private let store: CollectorStateStore
    private let limits: JSONLScanner.Limits
    private let logger = Logger(subsystem: "io.github.jhosgun.tokenbar", category: "command-code")

    static let defaultRootDirectory: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".commandcode", isDirectory: true)
        .appendingPathComponent("projects", isDirectory: true)

    init(rootDirectory: URL = CommandCodeCollector.defaultRootDirectory,
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

        let files = sessionFiles()
        let bootstrapped = await store.hasBootstrapped(source)
        let cutoffDay = UsageRetention.cutoffDay()
        let formatters = ClaudeCodeCollector.TimestampFormatters()
        let scanner = JSONLScanner(source: source, store: store, limits: limits)

        var accumulator = ModelUsageAccumulator(source: source)

        let outcome = await scanner.scan(
            files: files,
            bootstrapped: bootstrapped,
            now: Date(),
            onLine: { line, path in
                guard line.containsBytes(of: Self.usageMarker) else { return false }
                guard let entry = try? JSONDecoder().decode(Entry.self, from: line) else { return true }
                guard let usage = entry.usage, let id = entry.id else { return false }
                guard let timestamp = entry.timestamp, let date = formatters.date(from: timestamp) else {
                    return true
                }
                let day = DayKey.string(from: date)
                guard day >= cutoffDay else { return false }
                let session = URL(fileURLWithPath: path).lastPathComponent
                if await store.markCommandCodeSeen(messageID: "\(session)#\(id)") { return false }

                let input = usage.inputTokens ?? 0
                let cacheRead = usage.cacheReadTokens ?? 0
                let cacheWrite = usage.cacheWriteTokens ?? 0
                accumulator.add(
                    day: day, model: entry.model ?? Self.unknownModel,
                    inputTokens: max(0, input - cacheRead - cacheWrite),
                    outputTokens: usage.outputTokens ?? 0,
                    cacheCreationTokens: cacheWrite, cacheReadTokens: cacheRead,
                    costUSD: usage.costUsd ?? 0
                )
                return false
            }
        )

        if !bootstrapped, outcome.completed {
            await store.setBootstrapped(source)
        }
        logger.debug("""
            \(outcome.filesParsed) sesiones leídas, \(outcome.filesFailed) fallos, \
            \(outcome.malformedLines) líneas malformadas
            """)
        if outcome.filesParsed == 0 && outcome.filesFailed > 0 {
            return .empty(.failed("No se pudieron leer las sesiones de Command Code"))
        }
        return accumulator.result()
    }

    private func sessionFiles() -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: rootDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsPackageDescendants, .skipsHiddenFiles]
        ) else { return [] }
        var files: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension == "jsonl",
                  !url.lastPathComponent.hasSuffix(".checkpoints.jsonl"),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            files.append(url)
        }
        return files.sorted { $0.path < $1.path }
    }

    private static let unknownModel = "desconocido"
    private static let usageMarker = Array("\"usage\"".utf8)

    // MARK: - Forma del JSONL

    private struct Entry: Decodable {
        var id: String?
        var timestamp: String?
        var model: String?
        var usage: Usage?

        struct Usage: Decodable {
            var inputTokens: Int?
            var outputTokens: Int?
            var cacheReadTokens: Int?
            var cacheWriteTokens: Int?
            var costUsd: Double?
        }
    }
}
