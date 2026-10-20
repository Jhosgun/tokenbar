import Foundation
import OSLog

/// Acumulador persistente del consumo por modelo, agregado por (día, herramienta, modelo).
///
/// Es el hermano de `UsageStore` para la ventana de Estadísticas: `UsageStore` sigue siendo la
/// fuente autoritativa del total por herramienta y este solo guarda cómo se reparte entre
/// modelos. Mismo patrón: un actor, `model-usage.json` en el directorio de la app, escritura
/// atómica y 90 días de retención.
actor ModelUsageStore {

    private static let fileName = "model-usage.json"
    private static let formatVersion = 1

    private let log = Logger(subsystem: "io.github.jhosgun.tokenbar", category: "model-usage")
    private let directory: URL
    private let fileURL: URL

    /// Clave de agregación: un registro por día, herramienta y modelo.
    private struct Key: Hashable {
        var day: String
        var source: AppSource
        var model: String
    }

    /// Formato en disco de `model-usage.json`.
    private struct Payload: Codable {
        var version: Int
        var records: [ModelUsageRecord]
    }

    private enum LoadError: Error, LocalizedError {
        case unsupportedVersion(Int)

        var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let version): "versión de formato no soportada: \(version)"
            }
        }
    }

    private var records: [Key: ModelUsageRecord] = [:]
    /// Evita que un `load()` tardío pise deltas ya aplicados por un refresh concurrente.
    private var isLoaded = false

    init(directory: URL = UsageStore.defaultDirectory) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent(Self.fileName, isDirectory: false)
    }

    /// Crea el directorio si falta y carga `model-usage.json`, descartando lo que ya excede la
    /// retención. Un archivo ilegible se aparta como `.corrupt` (no se pisa) y se arranca
    /// vacío. Idempotente: las llamadas posteriores a la primera no hacen nada.
    func load() async {
        guard !isLoaded else { return }
        isLoaded = true
        ensureDirectory()
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            // Un archivo de otra versión (p. ej. de una app más nueva) no se interpreta con la
            // semántica actual ni se pisa: se aparta igual que uno corrupto.
            guard payload.version == Self.formatVersion else {
                throw LoadError.unsupportedVersion(payload.version)
            }
            var loaded: [Key: ModelUsageRecord] = [:]
            for record in payload.records {
                let key = Key(day: record.day, source: record.source, model: record.model)
                // Un archivo con duplicados se colapsa sumando, no se descarta.
                loaded[key] = loaded[key].map { $0 + record } ?? record
            }
            // Los deltas que `apply` haya metido antes de que terminara la carga se conservan.
            for (key, record) in records {
                loaded[key] = loaded[key].map { $0 + record } ?? record
            }
            records = loaded
            if purgeExpired() { persist() }
        } catch {
            quarantineCorruptFile(error)
        }
    }

    /// Acumula por (día, herramienta, modelo) sumando componente a componente. Con array
    /// vacío no toca el disco.
    func apply(_ newRecords: [ModelUsageRecord]) async {
        guard !newRecords.isEmpty else { return }
        for record in newRecords {
            let key = Key(day: record.day, source: record.source, model: record.model)
            records[key] = records[key].map { $0 + record } ?? record
        }
        persist()
    }

    /// Registros con `day >= firstDay`, ordenados por día, herramienta y modelo.
    func records(fromDay firstDay: String) async -> [ModelUsageRecord] {
        records.values
            .filter { $0.day >= firstDay }
            .sorted { ($0.day, $0.source.rawValue, $0.model) < ($1.day, $1.source.rawValue, $1.model) }
    }

    /// Borra lo anterior a la retención. Si no hay nada que borrar, no reescribe el archivo.
    func purge() async {
        if purgeExpired() { persist() }
    }

    // MARK: - Retención

    /// Mismo criterio que `UsageStore.purge`: el día que cumple justo 90 de antigüedad ya
    /// queda fuera. Devuelve si quitó algo.
    private func purgeExpired() -> Bool {
        let cutoff = UsageRetention.cutoffDay()
        let before = records.count
        records = records.filter { $0.key.day > cutoff }
        return records.count != before
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

    /// Renombra el archivo ilegible a `model-usage.json.corrupt` para no perderlo: el
    /// siguiente `persist()` escribe uno nuevo y el viejo queda para inspección.
    private func quarantineCorruptFile(_ error: Error) {
        let path = fileURL.path
        let reason = error.localizedDescription
        log.warning("model-usage.json ilegible en \(path, privacy: .public), se aparta y se arranca vacío: \(reason, privacy: .public)")
        let corruptURL = fileURL.appendingPathExtension("corrupt")
        try? FileManager.default.removeItem(at: corruptURL)
        do {
            try FileManager.default.moveItem(at: fileURL, to: corruptURL)
        } catch {
            let moveReason = error.localizedDescription
            log.warning("No se pudo apartar \(path, privacy: .public): \(moveReason, privacy: .public)")
        }
    }

    /// Escritura atómica. Un fallo se loguea; nunca se propaga al llamador.
    private func persist() {
        ensureDirectory()
        // Orden estable para que el archivo no cambie sin motivo entre corridas.
        let sorted = records.values.sorted {
            ($0.day, $0.source.rawValue, $0.model) < ($1.day, $1.source.rawValue, $1.model)
        }
        let payload = Payload(version: Self.formatVersion, records: sorted)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(payload).write(to: fileURL, options: [.atomic])
        } catch {
            let path = fileURL.path
            let reason = error.localizedDescription
            log.warning("No se pudo escribir \(path, privacy: .public): \(reason, privacy: .public)")
        }
    }
}
