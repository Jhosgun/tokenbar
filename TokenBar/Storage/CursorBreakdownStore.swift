import Foundation
import OSLog

/// Agregado durable del consumo de Cursor por día, modelo y origen (app o CLI).
///
/// `UsageRecord` no tiene dónde guardar el modelo ni el flag `isHeadless` de cada
/// evento (ver CONTRACT.md §2), así que el desglose vive aquí: el collector lo llena
/// con cada evento nuevo y la UI lo leerá para el detalle del desplegable
/// ("tokens por modelo", "CLI vs app") sin tener que reconsultar la red.
///
/// Archivo: `cursor-breakdown.json` junto a `usage.json`. Es solo para mostrar:
/// el contador oficial sigue siendo `UsageStore`; si un crash cae entre este guardado
/// y el de `state.json`, un evento puede quedar sumado dos veces aquí — la misma
/// ventana de doble conteo que ya acepta `usage.json` por el orden tokens → marcas.
actor CursorBreakdownStore {

    /// Total de tokens de un modelo en una ventana, para el ranking del desplegable.
    struct ModelTotal: Equatable, Sendable {
        var model: String
        var tokens: Int
    }

    /// División por origen: la app de escritorio contra el CLI (`cursor-agent`).
    struct OriginSplit: Equatable, Sendable {
        var appTokens: Int
        var cliTokens: Int
        var appEvents: Int
        var cliEvents: Int

        static let zero = OriginSplit(appTokens: 0, cliTokens: 0, appEvents: 0, cliEvents: 0)
    }

    /// Tokens y eventos de un (día, modelo), separados por origen.
    private struct Bucket: Codable, Equatable {
        var appTokens = 0
        var cliTokens = 0
        var appEvents = 0
        var cliEvents = 0
    }

    private struct Payload: Codable {
        var version: Int
        /// Día "yyyy-MM-dd" → modelo → bucket.
        var days: [String: [String: Bucket]]
    }

    private static let fileName = "cursor-breakdown.json"
    private static let formatVersion = 1
    /// Misma retención que `UsageStore`: el desglose no vive más que el histórico.
    private static let retentionDays = 90

    private let log = Logger(subsystem: "com.local.tokenbar", category: "cursor-breakdown")
    private let directory: URL
    private let fileURL: URL

    private var days: [String: [String: Bucket]] = [:]
    private var isLoaded = false
    private var isDirty = false

    static let defaultDirectory: URL = UsageStore.defaultDirectory

    init(directory: URL = CursorBreakdownStore.defaultDirectory) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent(Self.fileName, isDirectory: false)
    }

    /// Carga el archivo si existe. Corrupto o de versión desconocida: se empieza vacío
    /// (es un agregado para mostrar, no el contador oficial) y se registra un warning.
    /// Idempotente: las llamadas posteriores no hacen nada.
    func load() async {
        guard !isLoaded else { return }
        isLoaded = true
        ensureDirectory()
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            guard payload.version == Self.formatVersion else { return }
            days = payload.days
        } catch {
            log.warning("cursor-breakdown.json ilegible, se arranca vacío: \(error.localizedDescription, privacy: .public)")
            days = [:]
        }
    }

    /// Suma un evento nuevo (el collector ya lo deduplicó) a su día, modelo y origen.
    /// No persiste: el collector llama a `save()` una vez al final del ciclo.
    func record(day: String, model: String, isHeadless: Bool, tokens: Int) async {
        guard tokens > 0 else { return }
        var bucket = days[day]?[model] ?? Bucket()
        if isHeadless {
            bucket.cliTokens += tokens
            bucket.cliEvents += 1
        } else {
            bucket.appTokens += tokens
            bucket.appEvents += 1
        }
        days[day, default: [:]][model] = bucket
        isDirty = true
    }

    /// Ranking de modelos por tokens en los últimos `windowDays` días, de mayor a menor.
    /// Los empates se deshacen por nombre para que el orden sea estable.
    func totalsByModel(windowDays: Int) async -> [ModelTotal] {
        var totals: [String: Int] = [:]
        for (day, models) in daysInWindow(windowDays) {
            _ = day
            for (model, bucket) in models {
                totals[model, default: 0] += bucket.appTokens + bucket.cliTokens
            }
        }
        return totals.map { ModelTotal(model: $0.key, tokens: $0.value) }
            .sorted { $0.tokens != $1.tokens ? $0.tokens > $1.tokens : $0.model < $1.model }
    }

    /// Tokens y eventos por origen en los últimos `windowDays` días.
    func originSplit(windowDays: Int) async -> OriginSplit {
        var split = OriginSplit.zero
        for (_, models) in daysInWindow(windowDays) {
            for (_, bucket) in models {
                split.appTokens += bucket.appTokens
                split.cliTokens += bucket.cliTokens
                split.appEvents += bucket.appEvents
                split.cliEvents += bucket.cliEvents
            }
        }
        return split
    }

    /// Persiste de forma atómica, podando los días con más de `retentionDays`.
    /// Sale temprano si nada cambió, como `CollectorStateStore.save()`.
    func save() async {
        guard isDirty else { return }
        prune()
        ensureDirectory()
        let payload = Payload(version: Self.formatVersion, days: days)
        do {
            let data = try JSONEncoder().encode(payload)
            try data.write(to: fileURL, options: [.atomic])
            isDirty = false
        } catch {
            log.warning("No se pudo escribir cursor-breakdown.json: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Interno

    private func daysInWindow(_ windowDays: Int) -> [(String, [String: Bucket])] {
        let cutoff = Self.cutoffDay(windowDays: windowDays)
        return days.filter { $0.key >= cutoff }.sorted { $0.key < $1.key }
    }

    private func prune() {
        let cutoff = Self.cutoffDay(windowDays: Self.retentionDays)
        days = days.filter { $0.key >= cutoff }
    }

    /// La clave de día más vieja que entra en la ventana (las claves son "yyyy-MM-dd",
    /// comparables lexicográficamente).
    private static func cutoffDay(windowDays: Int) -> String {
        let start = Calendar.current.date(byAdding: .day, value: -max(windowDays - 1, 0),
                                          to: Date()) ?? Date()
        return DayKey.string(from: start)
    }

    private func ensureDirectory() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            let path = directory.path
            let reason = error.localizedDescription
            log.warning("No se pudo crear \(path, privacy: .public): \(reason, privacy: .public)")
        }
    }
}
