import Foundation

/// Recorre archivos JSONL de forma incremental para los collectors de Codex y Command Code.
///
/// Guarda un `FileCursor` por archivo: cada corrida lee solo lo nuevo. Una última línea sin
/// `\n` no se consume (se espera al siguiente ciclo) y no frena a los demás archivos. En el
/// bootstrap, los archivos sin cambios dentro de la retención se saltan por completo; los que
/// no se alcanzan a leer dentro del presupuesto continúan en los ciclos siguientes.
struct JSONLScanner: Sendable {
    struct Limits: Sendable {
        var timeBudget: Duration
        var maxBytes: Int
        var blockBytes: Int
        var maxLineBytes: Int

        static let production = Limits(
            timeBudget: .milliseconds(1_500),
            maxBytes: 64 * 1_024 * 1_024,
            blockBytes: 8 * 1_024 * 1_024,
            maxLineBytes: 32 * 1_024 * 1_024
        )
    }

    struct Outcome: Sendable {
        /// true si se recorrieron todos los archivos hasta el final dentro del presupuesto.
        var completed = true
        var filesParsed = 0
        var filesFailed = 0
        var malformedLines = 0
    }

    let source: AppSource
    let store: CollectorStateStore
    let limits: Limits

    /// `onLine` devuelve true si la línea resultó malformada (solo se cuenta para el log).
    /// `onFileStart` y `onFileEnd` dejan al collector cargar y guardar estado por archivo.
    func scan(files: [URL],
              bootstrapped: Bool,
              now: Date,
              onFileStart: (String) async -> Void = { _ in },
              onLine: (Data, String) async -> Bool,
              onFileEnd: (String) async -> Void = { _ in }) async -> Outcome {
        let clock = ContinuousClock()
        let deadline = clock.now + limits.timeBudget
        let retentionStart = Calendar.current.date(byAdding: .day, value: -UsageRetention.days, to: now)
            ?? now
        var outcome = Outcome()
        var bytesRead = 0
        var visited: Set<String> = []

        for url in files {
            let path = url.path
            visited.insert(path)
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let rawSize = values.fileSize, let modified = values.contentModificationDate else {
                outcome.filesFailed += 1
                continue
            }
            let size = UInt64(rawSize)
            let cursorKey = CollectorStateStore.cursorKey(forPath: path, source: source)
            let cursor = await store.cursor(forPath: cursorKey)

            if let cursor, cursor.offset >= size, cursor.size == size,
               abs(cursor.modified.timeIntervalSince(modified)) < 1 {
                continue
            }
            if !bootstrapped, cursor == nil, modified < retentionStart {
                await store.setCursor(FileCursor(offset: size, size: size, modified: modified),
                                      forPath: cursorKey)
                continue
            }
            if outcome.filesParsed > 0, Task.isCancelled || clock.now >= deadline || bytesRead >= limits.maxBytes {
                outcome.completed = false
                break
            }

            var offset = cursor?.offset ?? 0
            if size < offset { offset = 0 }

            guard let handle = try? FileHandle(forReadingFrom: url) else {
                outcome.filesFailed += 1
                continue
            }
            outcome.filesParsed += 1
            await onFileStart(path)

            var stoppedByBudget = false
            blocks: while offset < size {
                guard let block = readBlock(handle: handle, offset: offset) else {
                    outcome.filesFailed += 1
                    break
                }
                bytesRead += block.bytesRead
                var consumed = block.skippedBytes
                if block.skippedBytes > 0 { outcome.malformedLines += 1 }
                for line in block.lines {
                    if Task.isCancelled || clock.now >= deadline {
                        stoppedByBudget = true
                        break
                    }
                    if await onLine(line.data, path) { outcome.malformedLines += 1 }
                    consumed += line.consumedBytes
                }
                offset += consumed
                if stoppedByBudget { break blocks }
                // Sin líneas completas nuevas: cola sin `\n`, se reintenta en el próximo ciclo.
                if consumed == 0 { break blocks }
                if bytesRead >= limits.maxBytes, offset < size {
                    stoppedByBudget = true
                    break blocks
                }
            }
            try? handle.close()
            await onFileEnd(path)
            await store.setCursor(FileCursor(offset: offset, size: size, modified: modified),
                                  forPath: cursorKey)
            if stoppedByBudget {
                outcome.completed = false
                break
            }
        }

        if outcome.completed, !Task.isCancelled {
            await store.pruneCursors(keeping: visited, source: source)
        } else {
            outcome.completed = false
        }
        return outcome
    }

    // MARK: - Lectura por bloques

    struct Line {
        var data: Data
        var consumedBytes: UInt64
    }

    private struct Block {
        var lines: [Line]
        var bytesRead: Int
        /// Bytes de una línea más larga que el tope: se descartan enteros (cuenta como malformada).
        var skippedBytes: UInt64
    }

    private func readBlock(handle: FileHandle, offset: UInt64) -> Block? {
        do {
            try handle.seek(toOffset: offset)
            guard var data = try handle.read(upToCount: limits.blockBytes), !data.isEmpty else {
                return Block(lines: [], bytesRead: 0, skippedBytes: 0)
            }
            let newline = UInt8(ascii: "\n")
            while !data.contains(newline), data.count < limits.maxLineBytes,
                  let more = try handle.read(upToCount: 1_024 * 1_024), !more.isEmpty {
                data.append(more)
            }
            guard data.contains(newline) else {
                if data.count >= limits.maxLineBytes {
                    return Block(lines: [], bytesRead: data.count, skippedBytes: UInt64(data.count))
                }
                return Block(lines: [], bytesRead: data.count, skippedBytes: 0)
            }

            var lines: [Line] = []
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var start = 0
                while start < raw.count,
                      let found = memchr(base + start, Int32(newline), raw.count - start) {
                    let end = base.distance(to: found)
                    lines.append(Line(data: Data(bytes: base + start, count: end - start),
                                      consumedBytes: UInt64(end - start + 1)))
                    start = end + 1
                }
            }
            return Block(lines: lines, bytesRead: data.count, skippedBytes: 0)
        } catch {
            return nil
        }
    }
}

extension Data {
    /// Búsqueda de bytes sin decodificar: filtra rápido las líneas que ni vale la pena parsear.
    func containsBytes(of needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, count >= needle.count else { return false }
        return withUnsafeBytes { raw in
            needle.withUnsafeBytes { target in
                memmem(raw.baseAddress, raw.count, target.baseAddress, target.count) != nil
            }
        }
    }
}
