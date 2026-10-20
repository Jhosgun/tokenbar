import Foundation
import OSLog
import SQLite3

/// Lee el consumo de OpenCode de su SQLite (`~/.local/share/opencode/opencode.db`, tabla
/// `message`) en solo lectura.
///
/// Las filas de asistente se reescriben mientras el mensaje hace streaming, así que solo se
/// cuentan las terminadas (`time.completed` presente) y cada `message.id` una sola vez, con su
/// valor final. Una fila terminada ya no vuelve a cambiar y su `time_updated` es siempre
/// posterior a `time.completed` (verificado en la base real), por eso la posición guardada es
/// el par `(time_updated, id)`: cada corrida pagina estrictamente más allá de él, sin que los
/// empates de `time_updated` puedan estancar el avance.
///
/// Normalización (verificada contra la base real): `tokens.input` no incluye el caché y
/// `tokens.total == input + output + reasoning + cache.read + cache.write` en el 100 % de las
/// filas con `reasoning > 0`, o sea que OpenCode reporta el razonamiento aparte de `output`.
/// Se suma a `outputTokens` para que el total cuadre y no se pierda consumo real. El modelo es
/// `<providerID>/<modelID>` y el costo el `cost` nativo.
struct OpenCodeCollector: UsageCollector {
    let source: AppSource = .opencode

    struct CycleLimits: Sendable {
        var timeBudget: Duration
        var batchRows: Int

        static let production = CycleLimits(timeBudget: .milliseconds(1_500), batchRows: 2_000)
    }

    private let databaseURL: URL
    private let store: CollectorStateStore
    private let limits: CycleLimits
    private let logger = Logger(subsystem: "io.github.jhosgun.tokenbar", category: "opencode")

    static let defaultDatabaseURL: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".local/share/opencode/opencode.db", isDirectory: false)

    init(databaseURL: URL = OpenCodeCollector.defaultDatabaseURL,
         store: CollectorStateStore,
         limits: CycleLimits = .production) {
        self.databaseURL = databaseURL
        self.store = store
        self.limits = limits
    }

    func collect() async -> CollectorResult {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return .empty(.notConfigured)
        }

        let clock = ContinuousClock()
        let deadline = clock.now + limits.timeBudget
        let cutoffMs = Int64((Calendar.current.date(byAdding: .day, value: -UsageRetention.days,
                                                    to: Date()) ?? Date()).timeIntervalSince1970 * 1_000)
        var watermark = await store.openCodeWatermark()
            ?? OpenCodeWatermark(timeUpdatedMs: cutoffMs, id: "")
        var accumulator = ModelUsageAccumulator(source: source)
        var drained = false
        var failure: String?
        let cutoffDay = UsageRetention.cutoffDay()

        // Un lote por vuelta; el presupuesto se revisa entre lotes y lo pendiente sigue en el
        // próximo ciclo desde la posición guardada. Un fallo conserva lo ya leído pero se
        // reporta, para que la fila muestre que el ciclo quedó incompleto.
        batches: repeat {
            let batch: [Row]
            switch Self.readBatch(databaseURL: databaseURL, after: watermark, limit: limits.batchRows) {
            case .success(let rows): batch = rows
            case .failure(let error):
                logger.error("no se pudo leer la base de OpenCode: \(error.message, privacy: .public)")
                failure = error.message
                break batches
            }

            for row in batch {
                // Un mensaje terminado sin los campos de tokens esperados no se cuenta ni se
                // marca: se detiene aquí y se reporta, en vez de inventar un cero.
                guard row.hasValidTokens else {
                    failure = Self.unknownFormatMessage
                    break batches
                }
                if !(await store.markOpenCodeFinalized(messageID: row.id)) {
                    let day = DayKey.string(from: Date(timeIntervalSince1970: Double(row.timeCreatedMs) / 1_000))
                    if day >= cutoffDay {
                        accumulator.add(
                            day: day, model: row.model,
                            inputTokens: row.input, outputTokens: row.output + row.reasoning,
                            cacheCreationTokens: row.cacheWrite, cacheReadTokens: row.cacheRead,
                            costUSD: row.cost
                        )
                    }
                }
                watermark = OpenCodeWatermark(timeUpdatedMs: row.timeUpdatedMs, id: row.id)
                await store.setOpenCodeWatermark(watermark)
            }
            drained = batch.count < limits.batchRows
        } while !drained && !Task.isCancelled && clock.now < deadline

        if failure == nil, !(await store.hasBootstrapped(source)), drained {
            await store.setBootstrapped(source)
        }
        return accumulator.result(status: failure.map { .failed($0) } ?? .ok)
    }

    private static let unknownFormatMessage = "Formato de OpenCode desconocido"

    // MARK: - SQLite (solo lectura)

    private struct Row {
        var id: String
        var timeCreatedMs: Int64
        var timeUpdatedMs: Int64
        var model: String
        var input: Int
        var output: Int
        var reasoning: Int
        var cacheRead: Int
        var cacheWrite: Int
        var cost: Double
        /// false si algún campo de tokens requerido falta o no es numérico.
        var hasValidTokens: Bool
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private struct ReadFailure: Error {
        var message: String
    }

    private static let query = """
        SELECT id, time_created, time_updated,
               COALESCE(json_extract(data, '$.providerID'), '') || '/' ||
                   COALESCE(json_extract(data, '$.modelID'), 'desconocido'),
               COALESCE(json_extract(data, '$.tokens.input'), 0),
               COALESCE(json_extract(data, '$.tokens.output'), 0),
               COALESCE(json_extract(data, '$.tokens.reasoning'), 0),
               COALESCE(json_extract(data, '$.tokens.cache.read'), 0),
               COALESCE(json_extract(data, '$.tokens.cache.write'), 0),
               COALESCE(json_extract(data, '$.cost'), 0),
               json_type(data, '$.tokens.input') IN ('integer', 'real')
                   AND json_type(data, '$.tokens.output') IN ('integer', 'real')
                   AND json_type(data, '$.tokens.cache.read') IN ('integer', 'real')
                   AND json_type(data, '$.tokens.cache.write') IN ('integer', 'real')
                   AND COALESCE(json_type(data, '$.tokens.reasoning') IN ('integer', 'real'), 1)
                   AND COALESCE(json_type(data, '$.cost') IN ('integer', 'real'), 1)
        FROM message
        WHERE (time_updated > ?1 OR (time_updated = ?1 AND id > ?2))
          AND json_valid(data)
          AND json_extract(data, '$.role') = 'assistant'
          AND json_extract(data, '$.time.completed') IS NOT NULL
        ORDER BY time_updated, id
        LIMIT ?3
        """

    /// Abre con `mode=ro` (sin `immutable`: la base está en WAL y OpenCode escribe mientras
    /// tanto) y cierra al terminar.
    private static func readBatch(databaseURL: URL, after: OpenCodeWatermark,
                                  limit: Int) -> Result<[Row], ReadFailure> {
        var handle: OpaquePointer?
        let encodedPath = databaseURL.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            ?? databaseURL.path
        let uri = "file:\(encodedPath)?mode=ro"
        guard sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
              let db = handle else {
            if handle != nil { sqlite3_close(handle) }
            return .failure(ReadFailure(message: "No se pudo abrir la base de OpenCode"))
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 500)

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            let busy = sqlite3_errcode(db) == SQLITE_BUSY || sqlite3_errcode(db) == SQLITE_LOCKED
            return .failure(ReadFailure(message: busy ? "Base de OpenCode ocupada"
                                                      : Self.unknownFormatMessage))
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, after.timeUpdatedMs)
        sqlite3_bind_text(statement, 2, after.id, -1, Self.transient)
        sqlite3_bind_int64(statement, 3, Int64(limit))

        var rows: [Row] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else {
                let busy = code == SQLITE_BUSY || code == SQLITE_LOCKED
                return .failure(ReadFailure(message: busy ? "Base de OpenCode ocupada"
                                                          : "No se pudo leer la base de OpenCode"))
            }
            guard let idText = sqlite3_column_text(statement, 0),
                  let modelText = sqlite3_column_text(statement, 3) else { continue }
            rows.append(Row(
                id: String(cString: idText),
                timeCreatedMs: sqlite3_column_int64(statement, 1),
                timeUpdatedMs: sqlite3_column_int64(statement, 2),
                model: String(cString: modelText),
                input: max(0, Int(sqlite3_column_int64(statement, 4))),
                output: max(0, Int(sqlite3_column_int64(statement, 5))),
                reasoning: max(0, Int(sqlite3_column_int64(statement, 6))),
                cacheRead: max(0, Int(sqlite3_column_int64(statement, 7))),
                cacheWrite: max(0, Int(sqlite3_column_int64(statement, 8))),
                cost: sqlite3_column_double(statement, 9),
                hasValidTokens: sqlite3_column_int(statement, 10) != 0
            ))
        }
        return .success(rows)
    }
}
