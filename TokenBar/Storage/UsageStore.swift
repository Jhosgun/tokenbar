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

    /// Placeholder inicial de UI: 3 apps en cero y 7 días en cero.
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
                             todayCostUSD: 0)
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

    /// Formato en disco de `usage.json`.
    private struct Payload: Codable {
        var version: Int
        var records: [UsageRecord]
    }

    private var records: [Key: UsageRecord] = [:]
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
        } catch {
            let path = fileURL.path
            let reason = error.localizedDescription
            log.warning("usage.json ilegible en \(path, privacy: .public), se arranca vacío: \(reason, privacy: .public)")
            records = [:]
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
        }
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
                             todayCostUSD: totalCost)
    }

    /// Borra los días con más de `days` de antigüedad respecto a hoy y persiste.
    /// Conserva una ventana de exactamente `days` días: `hoy - (days - 1)` … `hoy`.
    /// Si no hay nada que borrar no reescribe el archivo.
    func purge(olderThanDays days: Int) async {
        let calendar = Calendar.current
        guard let cutoffDate = calendar.date(byAdding: .day, value: -days, to: Date()) else { return }
        // "yyyy-MM-dd" es lexicográficamente ordenable, así que basta comparar strings.
        // Estricto (`>`): el día que cumple justo `days` de antigüedad ya queda fuera.
        let cutoff = DayKey.string(from: cutoffDate, calendar: calendar)
        let before = records.count
        records = records.filter { $0.key.day > cutoff }
        guard records.count != before else { return }
        persist()
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
        let payload = Payload(version: Self.formatVersion, records: sorted)
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
