import Foundation
import OSLog

/// Posición de lectura incremental de un archivo de log/transcript.
struct FileCursor: Codable, Hashable, Sendable {
    /// Bytes ya consumidos.
    var offset: UInt64
    /// Tamaño del archivo cuando se guardó el cursor (sirve para detectar truncados).
    var size: UInt64
    var modified: Date
}

/// Estado interno de los collectors: bootstrap, cursores por archivo y dedupe de mensajes.
actor CollectorStateStore {

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

    private static let fileName = "state.json"
    private static let formatVersion = 2
    /// Tope de ids o mensajes recordados; se podan los más viejos en `save()`.
    private static let maxSeenMessageIDs = 100_000

    private let log = Logger(subsystem: "io.github.jhosgun.tokenbar", category: "storage")
    private let directory: URL
    private let fileURL: URL

    private struct VersionHeader: Decodable {
        var version: Int
    }

    /// Formato legado: Claude guardaba la clave base y una `clave#output` por parcial.
    private struct PayloadV1: Decodable {
        var bootstrapped: [String]
        var cursors: [String: FileCursor]
        var seenMessageIDs: [String]
    }

    /// Formato en disco de `state.json`.
    private struct Payload: Codable {
        var version: Int
        var bootstrapped: [String]
        var cursors: [String: FileCursor]
        var seenMessageIDs: [String]
        var claudeMessages: [ClaudeMessageState]
    }

    private struct ClaudeMessageState: Codable, Equatable {
        var key: String
        var output: Int
    }

    struct ClaudeMessageDelta: Sendable {
        var isNewMessage: Bool
        var outputTokens: Int
    }

    private var bootstrapped: Set<AppSource> = []
    private var cursors: [String: FileCursor] = [:]
    /// Set para consultas O(1)...
    private var seenIDs: Set<String> = []
    /// ...y array paralelo en orden de inserción, para poder podar los más viejos.
    private var seenOrder: [String] = []
    /// Una sola entrada durable por mensaje de Claude, con su máximo output contabilizado.
    private var claudeOutputs: [String: Int] = [:]
    private var claudeOrder: [String] = []
    /// Evita que un `load()` tardío pise cursores/ids que un refresh concurrente ya escribió
    /// (si no, los collectors re-parsean desde offset 0 y el día se cuenta doble).
    private var isLoaded = false
    /// Los collectors llaman a `save()` al final de cada ciclo de 30 s, pero en régimen
    /// estacionario no hay nada que persistir. Sin este flag se reescribirían cientos de KB
    /// de JSON cada medio minuto, contra el presupuesto de <100 ms por ciclo del plan.
    private var isDirty = false

    init(directory: URL = CollectorStateStore.defaultDirectory) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent(CollectorStateStore.fileName, isDirectory: false)
    }

    /// Crea el directorio si falta y carga `state.json`.
    /// Archivo ausente o corrupto: se arranca vacío y se registra un warning.
    /// Idempotente: las llamadas posteriores a la primera no hacen nada.
    func load() async {
        guard !isLoaded else { return }
        isLoaded = true
        ensureDirectory()
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = Self.makeDecoder()
            let version = try decoder.decode(VersionHeader.self, from: data).version
            switch version {
            case 1:
                try loadV1(decoder.decode(PayloadV1.self, from: data))
                isDirty = true
            case Self.formatVersion:
                loadV2(try decoder.decode(Payload.self, from: data))
            case let futureVersion where futureVersion > Self.formatVersion:
                loadV2(try decoder.decode(Payload.self, from: data))
                log.error("state.json usa la versión futura \(futureVersion); se conservaron los campos compatibles")
            default:
                throw StateError.unsupportedVersion(version)
            }
        } catch {
            let path = fileURL.path
            let reason = error.localizedDescription
            log.warning("state.json ilegible en \(path, privacy: .public), se arranca vacío: \(reason, privacy: .public)")
            resetState()
        }
    }

    /// ¿Ya se hizo la carga inicial (histórico) de esta app?
    func hasBootstrapped(_ source: AppSource) async -> Bool {
        bootstrapped.contains(source)
    }

    func setBootstrapped(_ source: AppSource) async {
        guard bootstrapped.insert(source).inserted else { return }
        isDirty = true
    }

    func cursor(forPath path: String) async -> FileCursor? {
        cursors[path]
    }

    /// No persiste: el collector llama a `save()` una vez al final de su ciclo.
    func setCursor(_ cursor: FileCursor, forPath path: String) async {
        guard cursors[path] != cursor else { return }
        cursors[path] = cursor
        isDirty = true
    }

    /// Test-and-set: devuelve true si el id YA se había visto; si no, lo marca y devuelve false.
    func markSeen(messageID: String) async -> Bool {
        guard seenIDs.insert(messageID).inserted else { return true }
        seenOrder.append(messageID)
        isDirty = true
        return false
    }

    /// Registra de forma atómica la base y el máximo output contabilizado de un mensaje Claude.
    func recordClaudeMessage(key: String, output: Int) async -> ClaudeMessageDelta {
        let previous = claudeOutputs[key]
        let isNewMessage = previous == nil
        let outputDelta = max(0, output - (previous ?? 0))
        guard isNewMessage || outputDelta > 0 else {
            return ClaudeMessageDelta(isNewMessage: false, outputTokens: 0)
        }
        if isNewMessage {
            claudeOrder.append(key)
        }
        claudeOutputs[key] = max(previous ?? 0, output)
        isDirty = true
        return ClaudeMessageDelta(isNewMessage: isNewMessage, outputTokens: outputDelta)
    }

    /// Poda a los `maxSeenMessageIDs` más recientes y persiste `state.json` de forma atómica.
    /// Sale temprano si nada cambió desde el último guardado.
    func save() async {
        guard isDirty else { return }
        pruneSeenIDs()
        ensureDirectory()
        let claudeMessages = claudeOrder.compactMap { key in
            claudeOutputs[key].map { ClaudeMessageState(key: key, output: $0) }
        }
        let payload = Payload(version: Self.formatVersion,
                              bootstrapped: bootstrapped.map(\.rawValue).sorted(),
                              cursors: cursors,
                              seenMessageIDs: seenOrder,
                              claudeMessages: claudeMessages)
        do {
            let data = try Self.makeEncoder().encode(payload)
            try data.write(to: fileURL, options: [.atomic])
            isDirty = false
        } catch {
            let path = fileURL.path
            let reason = error.localizedDescription
            log.warning("No se pudo escribir \(path, privacy: .public): \(reason, privacy: .public)")
        }
    }

    // MARK: - Interno

    private func pruneSeenIDs() {
        if seenOrder.count > Self.maxSeenMessageIDs {
            let kept = Array(seenOrder.suffix(Self.maxSeenMessageIDs))
            seenOrder = kept
            seenIDs = Set(kept)
        }
        if claudeOrder.count > Self.maxSeenMessageIDs {
            let stale = claudeOrder.prefix(claudeOrder.count - Self.maxSeenMessageIDs)
            for key in stale { claudeOutputs[key] = nil }
            claudeOrder = Array(claudeOrder.suffix(Self.maxSeenMessageIDs))
        }
    }

    private func loadV1(_ payload: PayloadV1) throws {
        bootstrapped = Set(payload.bootstrapped.compactMap(AppSource.init(rawValue:)))
        cursors = payload.cursors

        let allIDs = Set(payload.seenMessageIDs)
        var migratedKeys = Set<String>()
        var migratedOutputs: [String: Int] = [:]
        for id in payload.seenMessageIDs {
            guard let partial = Self.legacyClaudePartial(from: id), allIDs.contains(partial.key) else {
                continue
            }
            migratedKeys.insert(partial.key)
            migratedOutputs[partial.key] = max(migratedOutputs[partial.key] ?? 0, partial.output)
        }

        restoreSeen(payload.seenMessageIDs.filter { id in
            guard migratedKeys.contains(id) == false else { return false }
            guard let partial = Self.legacyClaudePartial(from: id) else { return true }
            return migratedKeys.contains(partial.key) == false
        })
        var orderedKeys = Set<String>()
        claudeOrder = payload.seenMessageIDs.filter {
            migratedKeys.contains($0) && orderedKeys.insert($0).inserted
        }
        claudeOutputs = migratedOutputs
    }

    private func loadV2(_ payload: Payload) {
        bootstrapped = Set(payload.bootstrapped.compactMap(AppSource.init(rawValue:)))
        cursors = payload.cursors
        restoreSeen(payload.seenMessageIDs)
        var keys = Set<String>()
        claudeOrder = []
        claudeOutputs = [:]
        for message in payload.claudeMessages where keys.insert(message.key).inserted {
            claudeOrder.append(message.key)
            claudeOutputs[message.key] = max(0, message.output)
        }
    }

    private func restoreSeen(_ ids: [String]) {
        var unique = Set<String>()
        seenOrder = []
        seenOrder.reserveCapacity(ids.count)
        for id in ids where unique.insert(id).inserted {
            seenOrder.append(id)
        }
        seenIDs = unique
    }

    private func resetState() {
        bootstrapped = []
        cursors = [:]
        seenIDs = []
        seenOrder = []
        claudeOutputs = [:]
        claudeOrder = []
        isDirty = false
    }

    private static func legacyClaudePartial(from id: String) -> (key: String, output: Int)? {
        guard let separator = id.lastIndex(of: "#"), separator < id.index(before: id.endIndex),
              let output = Int(id[id.index(after: separator)...]), output >= 0 else {
            return nil
        }
        let key = String(id[..<separator])
        let components = key.split(separator: "|", omittingEmptySubsequences: false)
        guard components.count <= 2,
              components[0].hasPrefix("msg_"),
              components.count == 1 || components[1].hasPrefix("req_") else {
            return nil
        }
        return (key, output)
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

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private enum StateError: LocalizedError {
        case unsupportedVersion(Int)

        var errorDescription: String? {
            switch self {
            case let .unsupportedVersion(version):
                "versión de estado no compatible: \(version)"
            }
        }
    }
}
