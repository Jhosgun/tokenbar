import Foundation
import OSLog

/// Lee los transcripts de Claude Code (`~/.claude/projects/**/*.jsonl`) de forma incremental.
///
/// Cada archivo es JSONL: una línea = un objeto JSON. Solo interesan las de `type == "assistant"`,
/// que traen `message.usage` con los contadores de tokens.
///
/// La misma clave (`message.id` + `requestId`) aparece varias veces por el streaming. El estado
/// durable guarda una sola entrada por mensaje con el máximo `output_tokens`: la base se cuenta
/// una vez y cada parcial posterior aporta únicamente el incremento de output.
struct ClaudeCodeCollector: UsageCollector {
    let source: AppSource = .claudeCode

    struct CycleLimits: Sendable {
        var timeBudget: Duration
        var maxBytes: Int
        var maxFiles: Int
        var maxLineBytes: Int

        init(timeBudget: Duration, maxBytes: Int, maxFiles: Int,
             maxLineBytes: Int = 32 * 1_024 * 1_024) {
            self.timeBudget = timeBudget
            self.maxBytes = maxBytes
            self.maxFiles = maxFiles
            self.maxLineBytes = maxLineBytes
        }

        static let production = CycleLimits(
            timeBudget: .milliseconds(1_800),
            maxBytes: 8 * 1_024 * 1_024,
            maxFiles: 256
        )
    }

    private let rootDirectory: URL
    private let store: CollectorStateStore
    private let limits: CycleLimits
    private let logger = Logger(subsystem: "io.github.jhosgun.tokenbar", category: "claude-code")

    static let defaultRootDirectory: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".claude", isDirectory: true)
        .appendingPathComponent("projects", isDirectory: true)

    init(rootDirectory: URL = ClaudeCodeCollector.defaultRootDirectory,
         store: CollectorStateStore,
         limits: CycleLimits = .production) {
        self.rootDirectory = rootDirectory
        self.store = store
        self.limits = limits
    }

    // MARK: - Ciclo principal

    func collect() async -> CollectorResult {
        let clock = ContinuousClock()
        let started = clock.now
        let deadline = started + limits.timeBudget

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rootDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return .empty(.notConfigured)
        }

        let bootstrapped = await store.hasBootstrapped(source)
        var visitedPaths: Set<String> = []

        let now = Date()
        let todayKey = DayKey.string(from: now)
        let calendar = Calendar.current
        let formatters = TimestampFormatters()

        var totals: [String: UsageRecord] = [:]
        var malformedLines = 0
        var filesScanned = 0
        var filesParsed = 0
        var filesFailed = 0
        var bytesRead = 0
        var completedScan = true

        let files = TranscriptEnumerator(rootDirectory: rootDirectory, logger: logger)
        for entry in files {
            if filesScanned > 0, shouldStop(clock: clock, deadline: deadline) {
                completedScan = false
                break
            }
            filesScanned += 1

            guard case .file(let file) = entry else {
                filesFailed += 1
                // No se pudo determinar si el archivo sigue existiendo: se marca como visto
                // para que un recorrido completo no pode su cursor por error.
                if case .failed(let url) = entry {
                    visitedPaths.insert(url.path)
                }
                continue
            }

            let path = file.url.path
            visitedPaths.insert(path)
            let cursor = await store.cursor(forPath: path)

            if let cursor, cursor.offset >= file.size, cursor.size == file.size,
               abs(cursor.modified.timeIntervalSince(file.modified)) < 1 {
                continue
            }

            if !bootstrapped, !calendar.isDate(file.modified, inSameDayAs: now) {
                await store.setCursor(
                    FileCursor(offset: file.size, size: file.size, modified: file.modified),
                    forPath: path
                )
                continue
            }

            guard filesParsed < limits.maxFiles, bytesRead < limits.maxBytes else {
                completedScan = false
                break
            }

            var offset = cursor?.offset ?? 0
            if file.size < offset {
                offset = 0
            }

            let remainingBytes = limits.maxBytes - bytesRead
            guard let chunk = readNewBytes(at: file.url, from: offset, maximumBytes: remainingBytes) else {
                filesFailed += 1
                continue
            }
            filesParsed += 1
            bytesRead += chunk.bytesRead
            malformedLines += chunk.discardedLines

            var consumedBytes = chunk.discardedBytes
            for line in chunk.lines {
                if consumedBytes > 0, shouldStop(clock: clock, deadline: deadline) {
                    completedScan = false
                    break
                }
                switch await accumulate(
                    line: line.data,
                    into: &totals,
                    todayKey: todayKey,
                    formatters: formatters
                ) {
                case .counted, .skipped:
                    break
                case .malformed:
                    malformedLines += 1
                }
                consumedBytes += line.consumedBytes
            }

            await store.setCursor(
                FileCursor(offset: offset + consumedBytes,
                           size: file.size,
                           modified: file.modified),
                forPath: path
            )

            if consumedBytes < chunk.completeBytes {
                completedScan = false
                break
            }
            if offset + consumedBytes < file.size {
                completedScan = false
                break
            }
        }

        // Un recorrido cortado por cancelación (no por presupuesto) tampoco es un recorrido
        // completo: no debe disparar la poda de cursores ni marcar el bootstrap como hecho.
        if files.stoppedEarly {
            completedScan = false
        }

        if !bootstrapped, completedScan {
            await store.setBootstrapped(source)
        }
        // La poda de cursores huérfanos solo corre tras un recorrido COMPLETO: nunca sobre un
        // ciclo cortado por presupuesto o cancelación, para no perder el cursor de un archivo
        // que simplemente no se llegó a visitar este turno.
        if completedScan {
            await store.pruneCursors(keeping: visitedPaths)
        }

        let elapsed = clock.now - started
        logger.debug("""
            ciclo en \(elapsed.milliseconds, format: .fixed(precision: 1)) ms — \
            \(filesScanned) archivos vistos, \(filesParsed) leídos, \(bytesRead) bytes, \
            \(totals.count) días tocados, \(malformedLines) líneas malformadas
            """)

        if filesParsed == 0 && filesFailed > 0 {
            logger.error("no se pudo leer ningún transcript (\(filesFailed) fallos)")
            return .empty(.failed("No se pudieron leer los transcripts"))
        }

        let records = totals.values
            .filter { $0.totalTokens > 0 }
            .sorted { $0.day < $1.day }
        return CollectorResult(records: records, status: .ok)
    }

    private func shouldStop(clock: ContinuousClock, deadline: ContinuousClock.Instant) -> Bool {
        Task.isCancelled || clock.now >= deadline
    }

    // MARK: - Enumeración de archivos

    private struct TranscriptFile {
        let url: URL
        let size: UInt64
        let modified: Date
    }

    private enum TranscriptEntry {
        case file(TranscriptFile)
        /// Se encontró un `.jsonl` regular pero no se pudieron leer sus claves de recurso
        /// (por ejemplo, se borró entre que se listó y se consultó).
        case failed(URL)
    }

    /// Recorre el árbol de forma perezosa: cada `next()` avanza un paso y pide las cuatro claves
    /// de recurso (regular/symlink/tamaño/fecha) en una sola pasada, en vez de enumerar el árbol
    /// completo primero y volver a pedir tamaño y fecha archivo por archivo. Como quien consume
    /// la secuencia (`collect()`) comprueba el presupuesto en cada iteración, dejar de pedir
    /// `next()` también detiene el recorrido: no se paga el costo de estadísticas de archivos
    /// que el presupuesto ya no alcanza a procesar.
    private final class TranscriptEnumerator: Sequence, IteratorProtocol {
        private static let keys: [URLResourceKey] = [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey
        ]
        private static let keySet = Set(keys)

        private let enumerator: FileManager.DirectoryEnumerator?
        /// true si el recorrido se cortó por cancelación antes de agotar el árbol: en ese caso
        /// el ciclo no puede tratarse como un recorrido completo (afecta poda y bootstrap).
        private(set) var stoppedEarly = false

        init(rootDirectory: URL, logger: Logger) {
            enumerator = FileManager.default.enumerator(
                at: rootDirectory,
                includingPropertiesForKeys: Self.keys,
                options: [.skipsPackageDescendants, .skipsHiddenFiles]
            )
            if enumerator == nil {
                logger.error("no se pudo enumerar \(rootDirectory.path, privacy: .public)")
            }
        }

        func next() -> TranscriptEntry? {
            guard let enumerator else { return nil }
            while let url = enumerator.nextObject() as? URL {
                if Task.isCancelled {
                    stoppedEarly = true
                    return nil
                }
                guard url.pathExtension == "jsonl" else { continue }
                guard let values = try? url.resourceValues(forKeys: Self.keySet) else {
                    return .failed(url)
                }
                guard values.isSymbolicLink != true, values.isRegularFile == true else { continue }
                guard let size = values.fileSize, let modified = values.contentModificationDate else {
                    return .failed(url)
                }
                return .file(TranscriptFile(url: url, size: UInt64(size), modified: modified))
            }
            return nil
        }
    }

    // MARK: - Lectura parcial

    private struct ChunkLine {
        var data: Data
        var consumedBytes: UInt64
    }

    private struct Chunk {
        var lines: [ChunkLine]
        var completeBytes: UInt64
        var bytesRead: Int
        var discardedBytes: UInt64
        var discardedLines: Int
    }

    private func readNewBytes(at url: URL, from offset: UInt64, maximumBytes: Int) -> Chunk? {
        guard maximumBytes > 0,
              let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }

        do {
            try handle.seek(toOffset: offset)
            guard var data = try handle.read(upToCount: min(maximumBytes, limits.maxLineBytes)),
                  !data.isEmpty else {
                return Chunk(lines: [], completeBytes: 0, bytesRead: 0,
                             discardedBytes: 0, discardedLines: 0)
            }

            let newline = UInt8(ascii: "\n")
            let extensionSize = 64 * 1_024
            if !data.contains(newline) {
                while data.count < limits.maxLineBytes,
                      let additional = try handle.read(upToCount: min(extensionSize,
                                                                      limits.maxLineBytes - data.count)),
                      !additional.isEmpty {
                    data.append(additional)
                    if additional.contains(newline) { break }
                }
            }

            if data.count >= limits.maxLineBytes, !data.contains(newline) {
                var discardedBytes = UInt64(data.count)
                while let additional = try handle.read(upToCount: extensionSize), !additional.isEmpty {
                    if let index = additional.firstIndex(of: newline) {
                        discardedBytes += UInt64(additional.distance(from: additional.startIndex,
                                                                     to: index) + 1)
                        break
                    }
                    discardedBytes += UInt64(additional.count)
                }
                return Chunk(lines: [], completeBytes: discardedBytes,
                             bytesRead: Int(min(discardedBytes, UInt64(Int.max))),
                             discardedBytes: discardedBytes,
                             discardedLines: 1)
            }

            var lines: [ChunkLine] = []
            var lineStart = data.startIndex
            for index in data.indices where data[index] == newline {
                lines.append(ChunkLine(
                    data: Data(data[lineStart..<index]),
                    consumedBytes: UInt64(data.distance(from: lineStart, to: index) + 1)
                ))
                lineStart = data.index(after: index)
                if data.count > maximumBytes { break }
            }
            let completeBytes = lines.reduce(UInt64(0)) { $0 + $1.consumedBytes }
            return Chunk(lines: lines, completeBytes: completeBytes, bytesRead: data.count,
                         discardedBytes: 0, discardedLines: 0)
        } catch {
            return nil
        }
    }

    // MARK: - Parseo y acumulación

    private enum LineOutcome {
        case counted
        case skipped
        case malformed
    }

    private func accumulate(
        line: Data,
        into totals: inout [String: UsageRecord],
        todayKey: String,
        formatters: TimestampFormatters
    ) async -> LineOutcome {
        guard line.contains(subsequence: Self.assistantMarker) else { return .skipped }

        guard let entry = try? JSONDecoder().decode(Entry.self, from: line) else {
            return .malformed
        }
        guard entry.type == "assistant",
              let message = entry.message,
              let usage = message.usage,
              let messageID = message.id else {
            return .skipped
        }

        let day: String
        if let timestamp = entry.timestamp {
            guard let date = formatters.date(from: timestamp) else {
                return .malformed
            }
            day = DayKey.string(from: date)
        } else {
            day = todayKey
        }

        let key = entry.requestId.map { "\(messageID)|\($0)" } ?? messageID
        let stateDelta = await store.recordClaudeMessage(
            key: key,
            output: usage.outputTokens ?? 0
        )
        let input = stateDelta.isNewMessage ? (usage.inputTokens ?? 0) : 0
        let cacheCreation = stateDelta.isNewMessage ? (usage.cacheCreationInputTokens ?? 0) : 0
        let cacheRead = stateDelta.isNewMessage ? (usage.cacheReadInputTokens ?? 0) : 0

        guard input > 0 || stateDelta.outputTokens > 0 || cacheCreation > 0 || cacheRead > 0 else {
            return .skipped
        }

        let cost = Pricing.cost(
            model: message.model ?? "",
            inputTokens: input,
            outputTokens: stateDelta.outputTokens,
            cacheCreationTokens: cacheCreation,
            cacheReadTokens: cacheRead
        )

        let delta = UsageRecord(
            source: source, day: day,
            inputTokens: input, outputTokens: stateDelta.outputTokens,
            cacheCreationTokens: cacheCreation, cacheReadTokens: cacheRead,
            costUSD: cost
        )
        totals[day] = totals[day].map { $0 + delta } ?? delta
        return .counted
    }

    private static let assistantMarker = Array("assistant".utf8)

    /// Se acepta ISO-8601 con o sin fracciones. Un timestamp presente pero inválido omite la
    /// línea como malformada; solo la ausencia del campo conserva el fallback histórico a hoy.
    final class TimestampFormatters: @unchecked Sendable {
        private let fractional: ISO8601DateFormatter
        private let wholeSeconds: ISO8601DateFormatter

        init() {
            fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            wholeSeconds = ISO8601DateFormatter()
            wholeSeconds.formatOptions = [.withInternetDateTime]
        }

        func date(from text: String) -> Date? {
            fractional.date(from: text) ?? wholeSeconds.date(from: text)
        }
    }

    // MARK: - Forma del JSONL

    private struct Entry: Decodable {
        var type: String?
        var requestId: String?
        var timestamp: String?
        var message: Message?

        struct Message: Decodable {
            var id: String?
            var model: String?
            var usage: Usage?
        }

        struct Usage: Decodable {
            var inputTokens: Int?
            var outputTokens: Int?
            var cacheCreationInputTokens: Int?
            var cacheReadInputTokens: Int?

            enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case outputTokens = "output_tokens"
                case cacheCreationInputTokens = "cache_creation_input_tokens"
                case cacheReadInputTokens = "cache_read_input_tokens"
            }
        }
    }
}

private extension Data {
    func contains(subsequence needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, count >= needle.count else { return false }
        return withUnsafeBytes { raw -> Bool in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return false }
            let first = needle[0]
            for start in 0...(count - needle.count) where base[start] == first {
                var matched = true
                for offset in 1..<needle.count {
                    if base[start + offset] != needle[offset] {
                        matched = false
                        break
                    }
                }
                if matched { return true }
            }
            return false
        }
    }
}

private extension Duration {
    var milliseconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) * 1000 + Double(attoseconds) / 1e15
    }
}
