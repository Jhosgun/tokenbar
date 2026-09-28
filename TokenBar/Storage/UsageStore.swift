import Foundation
import OSLog

/// Total de tokens de un día, listo para graficar en un sparkline.
struct DayTotal: Codable, Hashable, Sendable, Identifiable {
    var day: String
    var tokens: Int

    var id: String { day }
}

/// Vista inmutable del consumo, lista para pintar la UI.
struct UsageSnapshot: Sendable, Equatable {
    /// Consumo de hoy por app. Siempre trae las 3 claves de `AppSource.allCases`.
    var todayByApp: [AppSource: UsageRecord]
    /// Serie de 7 días por app, del más viejo al más nuevo, con ceros incluidos.
    var last7DaysByApp: [AppSource: [DayTotal]]
    var todayTotalTokens: Int
    var todayCostUSD: Double
    /// Días consecutivos con consumo, terminando hoy o ayer. Ver `Streak.current`.
    var currentStreak: Int
    /// La racha más larga vista hasta ahora. Nunca decrece, ni cuando la actual se rompe.
    var bestStreak: Int

    /// Total de tokens de cada uno de los últimos 7 días, sumando todas las apps. Se deriva
    /// de `last7DaysByApp`, que ya trae la misma ventana de días para todas: no hace falta
    /// guardar esto aparte.
    var weekTotals: [DayTotal] {
        guard let days = last7DaysByApp.values.first?.map(\.day) else { return [] }
        return days.enumerated().map { index, day in
            let total = last7DaysByApp.values.reduce(0) { partial, series in
                guard series.indices.contains(index) else { return partial }
                return partial + series[index].tokens
            }
            return DayTotal(day: day, tokens: total)
        }
    }

    var weekTotalTokens: Int { weekTotals.reduce(0) { $0 + $1.tokens } }

    /// Redondeado hacia abajo, como el resto de los conteos enteros de la app.
    var weekAverageTokens: Int {
        weekTotals.isEmpty ? 0 : weekTotalTokens / weekTotals.count
    }

    /// Placeholder inicial de UI: 3 apps en cero, 7 días en cero y racha en cero.
    /// Ojo: se evalúa una sola vez, así que no sirve como "hoy" tras cambiar de día.
    static let empty: UsageSnapshot = {
        let today = DayKey.today()
        let days = DayKey.lastDays(7)
        var byApp: [AppSource: UsageRecord] = [:]
        var series: [AppSource: [DayTotal]] = [:]
        for source in AppSource.allCases {
            byApp[source] = UsageRecord(source: source, day: today)
            series[source] = days.map { DayTotal(day: $0, tokens: 0) }
        }
        return UsageSnapshot(todayByApp: byApp,
                             last7DaysByApp: series,
                             todayTotalTokens: 0,
                             todayCostUSD: 0,
                             currentStreak: 0,
                             bestStreak: 0)
    }()
}

/// Acumulador persistente del consumo, agregado por (app, día).
actor UsageStore {

    /// `~/Library/Application Support/TokenBar`, con fallback si el sistema no la resuelve.
    static let defaultDirectory: URL = {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask,
                                                 appropriateFor: nil,
                                                 create: true))
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("TokenBar", isDirectory: true)
    }()

    private static let fileName = "usage.json"
    private static let formatVersion = 1

    private let log = Logger(subsystem: "io.github.jhosgun.tokenbar", category: "storage")
    private let directory: URL
    private let fileURL: URL

    /// Clave de agregación: un registro por app y día.
    private struct Key: Hashable {
        var source: AppSource
        var day: String
    }

    /// Formato en disco de `usage.json`. `dailyTotals` y `bestStreak` son nuevos: un
    /// archivo viejo que no los trae decodifica a `[:]` / `0` en vez de fallar.
    private struct Payload: Codable {
        var version: Int
        var records: [UsageRecord]
        /// Total de tokens por día, todas las apps sumadas. A diferencia de `records`
        /// (detalle por app, 90 días) esto se conserva 365 días: es lo que sostiene la
        /// racha a largo plazo sin tener que guardar el detalle completo tanto tiempo.
        var dailyTotals: [String: Int]
        var bestStreak: Int

        init(version: Int, records: [UsageRecord], dailyTotals: [String: Int], bestStreak: Int) {
            self.version = version
            self.records = records
            self.dailyTotals = dailyTotals
            self.bestStreak = bestStreak
        }

        private enum CodingKeys: String, CodingKey {
            case version, records, dailyTotals, bestStreak
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
            records = try container.decode([UsageRecord].self, forKey: .records)
            dailyTotals = try container.decodeIfPresent([String: Int].self, forKey: .dailyTotals) ?? [:]
            bestStreak = try container.decodeIfPresent(Int.self, forKey: .bestStreak) ?? 0
        }
    }

    private var records: [Key: UsageRecord] = [:]
    /// Total de tokens por día (todas las apps), independiente de `records`. Ver `Payload`.
    private var dailyTotals: [String: Int] = [:]
    /// Mejor racha vista hasta ahora. Solo crece: `apply` la compara contra la racha actual.
    private var bestStreak = 0
    /// Evita que un `load()` tardío pise deltas ya aplicados por un refresh concurrente.
    private var isLoaded = false

    init(directory: URL = UsageStore.defaultDirectory) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent(UsageStore.fileName, isDirectory: false)
    }

    /// Crea el directorio si falta y carga `usage.json`.
    /// Archivo ausente o corrupto: se arranca vacío y se registra un warning.
    /// Idempotente: las llamadas posteriores a la primera no hacen nada.
    func load() async {
        guard !isLoaded else { return }
        isLoaded = true
        ensureDirectory()
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            records = [:]
            dailyTotals = [:]
            bestStreak = 0
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let payload = try Self.makeDecoder().decode(Payload.self, from: data)
            var loaded: [Key: UsageRecord] = [:]
            for record in payload.records {
                let key = Key(source: record.source, day: record.day)
                // Un archivo con duplicados se colapsa sumando, no se descarta.
                if let existing = loaded[key] {
                    loaded[key] = existing + record
                } else {
                    loaded[key] = record
                }
            }
            records = loaded
            // Migración tolerante: un archivo de antes de `dailyTotals` no trae el resumen
            // diario. Se reconstruye sumando lo que sí sobrevivió en `records`; no hay
            // pérdida real porque ese archivo tampoco tenía más historia que esa.
            if payload.dailyTotals.isEmpty && !payload.records.isEmpty {
                dailyTotals = Self.aggregateDailyTotals(from: loaded)
            } else {
                dailyTotals = payload.dailyTotals
            }
            bestStreak = payload.bestStreak
            // Un archivo migrado no traía `bestStreak`: sin esto se vería en 0 aunque el
            // detalle reconstruido ya implique una racha en curso. `updateBestStreak` no
            // baja nada, así que en un archivo ya migrado esto es un no-op.
            let beforeMigrationCheck = bestStreak
            updateBestStreak()
            if bestStreak != beforeMigrationCheck {
                persist()
            }
        } catch {
            let path = fileURL.path
            let reason = error.localizedDescription
            log.warning("usage.json ilegible en \(path, privacy: .public), se arranca vacío: \(reason, privacy: .public)")
            records = [:]
            dailyTotals = [:]
            bestStreak = 0
        }
    }

    /// Acumula por (source, day) sumando componente a componente.
    /// Devuelve el total de tokens NUEVOS agregados. Con array vacío no toca el disco.
    @discardableResult
    func apply(_ newRecords: [UsageRecord]) async -> Int {
        guard !newRecords.isEmpty else { return 0 }
        var added = 0
        for record in newRecords {
            added += record.totalTokens
            let key = Key(source: record.source, day: record.day)
            if let existing = records[key] {
                records[key] = existing + record
            } else {
                records[key] = record
            }
            dailyTotals[record.day, default: 0] += record.totalTokens
        }
        updateBestStreak()
        persist()
        return added
    }

    /// Arma la vista para la UI: hoy por app + serie de 7 días por app.
    func snapshot() async -> UsageSnapshot {
        let today = DayKey.today()
        let days = DayKey.lastDays(7)

        var todayByApp: [AppSource: UsageRecord] = [:]
        var last7DaysByApp: [AppSource: [DayTotal]] = [:]
        var totalTokens = 0
        var totalCost: Double = 0

        for source in AppSource.allCases {
            let record = records[Key(source: source, day: today)]
                ?? UsageRecord(source: source, day: today)
            todayByApp[source] = record
            totalTokens += record.totalTokens
            totalCost += record.costUSD

            last7DaysByApp[source] = days.map { day in
                DayTotal(day: day, tokens: records[Key(source: source, day: day)]?.totalTokens ?? 0)
            }
        }

        return UsageSnapshot(todayByApp: todayByApp,
                             last7DaysByApp: last7DaysByApp,
                             todayTotalTokens: totalTokens,
                             todayCostUSD: totalCost,
                             currentStreak: Streak.current(activeDays: activeDays(), today: today),
                             bestStreak: bestStreak)
    }

    /// Borra el detalle por herramienta con más de `days` de antigüedad y, si se da
    /// `summaryDays`, borra el resumen diario (`dailyTotals`) por separado con esa
    /// retención más larga —por defecto la misma que `days`, para no romper a quien ya
    /// llamaba a este método con una sola ventana—. Conserva `hoy - (n - 1)` … `hoy` en
    /// cada caso. Si no hay nada que borrar en ninguno de los dos, no reescribe el archivo.
    func purge(olderThanDays days: Int, summaryDays: Int? = nil) async {
        let calendar = Calendar.current
        var changed = false

        if let cutoffDate = calendar.date(byAdding: .day, value: -days, to: Date()) {
            // "yyyy-MM-dd" es lexicográficamente ordenable, así que basta comparar strings.
            // Estricto (`>`): el día que cumple justo `days` de antigüedad ya queda fuera.
            let cutoff = DayKey.string(from: cutoffDate, calendar: calendar)
            let before = records.count
            records = records.filter { $0.key.day > cutoff }
            changed = changed || records.count != before
        }

        let summaryRetention = summaryDays ?? days
        if let summaryCutoffDate = calendar.date(byAdding: .day, value: -summaryRetention, to: Date()) {
            let summaryCutoff = DayKey.string(from: summaryCutoffDate, calendar: calendar)
            let before = dailyTotals.count
            dailyTotals = dailyTotals.filter { $0.key > summaryCutoff }
            changed = changed || dailyTotals.count != before
        }

        guard changed else { return }
        persist()
    }

    // MARK: - Racha

    /// Días con consumo (> 0 tokens), según el resumen diario.
    private func activeDays() -> Set<String> {
        Set(dailyTotals.filter { $0.value > 0 }.keys)
    }

    /// Sube `bestStreak` si el historial retenido tiene una racha más larga. Usa
    /// `longestRun` (todo el historial), no `current` (solo la racha vigente): una racha
    /// vieja que ya terminó también debe quedar como mejor marca. Nunca la baja.
    private func updateBestStreak() {
        let longest = Streak.longestRun(activeDays: activeDays())
        bestStreak = max(bestStreak, longest)
    }

    /// Reconstruye el resumen diario sumando el detalle por app: lo que usa la migración
    /// desde un `usage.json` de antes de que existiera `dailyTotals`.
    private static func aggregateDailyTotals(from records: [Key: UsageRecord]) -> [String: Int] {
        var totals: [String: Int] = [:]
        for record in records.values {
            totals[record.day, default: 0] += record.totalTokens
        }
        return totals
    }

    // MARK: - Disco

    private func ensureDirectory() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            let path = directory.path
            let reason = error.localizedDescription
            log.warning("No se pudo crear \(path, privacy: .public): \(reason, privacy: .public)")
        }
    }

    /// Escritura atómica. Un fallo se loguea; nunca se propaga al llamador.
    private func persist() {
        ensureDirectory()
        // Orden estable para que el archivo no cambie sin motivo entre corridas.
        let sorted = records.values.sorted {
            ($0.source.rawValue, $0.day) < ($1.source.rawValue, $1.day)
        }
        let payload = Payload(version: Self.formatVersion, records: sorted,
                              dailyTotals: dailyTotals, bestStreak: bestStreak)
        do {
            let data = try Self.makeEncoder().encode(payload)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            let path = fileURL.path
            let reason = error.localizedDescription
            log.warning("No se pudo escribir \(path, privacy: .public): \(reason, privacy: .public)")
        }
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        JSONDecoder()
    }
}
