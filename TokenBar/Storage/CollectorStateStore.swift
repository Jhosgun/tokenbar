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

/// Ventana de Cursor que no se pudo traer completa en un solo ciclo (tope de páginas o de
/// tiempo en `CursorCollector.fetchPages`) y que el siguiente ciclo debe retomar. Los tres
/// campos salen de datos reales (timestamps de eventos), nunca de un número de página ni de
/// una lectura de reloj — eso es justo lo que hizo fallar los intentos anteriores (un
/// `endMs` congelado del reloj mientras `startMs` se recalculaba contra "hoy" invertía la
/// ventana al cruzar medianoche).
///
/// - `startMs`: borde inferior ORIGINAL de la ventana en curso. Se congela al abrir la
///   continuación, así que un ciclo posterior no lo recalcula contra el reloj — ver arriba.
/// - `frontierMs`: timestamp más viejo ya leído en la ventana, forzado a bajar al menos 1 ms
///   respecto al `endMs` que se acaba de consultar (la API solo da resolución de milisegundo;
///   sin este tope, una página entera empatada en el mismo timestamp que `endMs` dejaría
///   `frontierMs` sin moverse y el próximo ciclo repetiría la misma ventana para siempre). El
///   próximo ciclo consulta hasta aquí **inclusive**: puede releer el evento del borde, pero
///   la foto guardada (`recordCursorEvent`) lo absorbe sin inflar el total.
/// - `ceilingMs`: máximo timestamp visto en TODA la ventana hasta ahora (no solo en el
///   último tramo, que por estar pegado a `frontierMs` suele ser el más viejo). Cuando la
///   ventana por fin se completa, la marca de agua salta directo aquí.
/// Posición compuesta del collector de OpenCode: se avanza estrictamente más allá de ella.
struct OpenCodeWatermark: Codable, Hashable, Sendable {
    var timeUpdatedMs: Int64
    var id: String
}

struct CursorContinuation: Codable, Hashable, Sendable {
    var startMs: Int64
    var frontierMs: Int64
    var ceilingMs: Int64?
}

/// Lo ya contabilizado de un evento de Cursor. Cursor publica el evento de un turno cuando
/// el turno arranca y le va sumando tokens y centavos EN SITIO (mismo `conversationId` +
/// `timestamp`), así que un dedup booleano se quedaba con la primera foto y perdía todo el
/// crecimiento posterior (verificado 2026-10-06, ver `docs/cursor-notes.md` §6). Con la foto
/// guardada, cada relectura suma solo la diferencia positiva por campo.
struct CursorEventSnapshot: Codable, Hashable, Sendable {
    /// Timestamp del evento (epoch ms): decide cuándo purgar la foto.
    var timestampMs: Int64
    var inputTokens: Int
    var outputTokens: Int
    var cacheCreationTokens: Int
    var cacheReadTokens: Int
    var costUSD: Double

    var totalTokens: Int {
        inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens
    }
}

/// Lo que falta por sumar de un evento de Cursor respecto a su foto anterior.
struct CursorEventDelta: Sendable {
    /// True si el evento no tenía foto: `delta` es el evento entero.
    var isNewEvent: Bool
    var delta: CursorEventSnapshot
    /// Algún contador (o el costo) vino MENOR que en la foto guardada. No se resta nada; el
    /// collector lo registra para saber si Cursor alguna vez corrige hacia abajo.
    var shrank: Bool
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
    /// v4 (2026-10-06): fotos por evento de Cursor (`cursorEventSnapshots`) y los ids
    /// `cursor:*` que antes vivían en `seenMessageIDs` pasan a `cursorSeenWithoutSnapshot`.
    private static let formatVersion = 4
    /// Tope de ids o mensajes recordados; se podan los más viejos en `save()`.
    private static let maxSeenMessageIDs = 100_000
    /// Las fotos de eventos de Cursor más viejas que esto se purgan en `save()`: la ventana
    /// de relectura del collector (`CursorCollector.Endpoint.lateEventOverlapMs`, 2 días) es
    /// mucho menor, así que una foto más vieja nunca vuelve a compararse con nada.
    private static let cursorSnapshotRetentionMs: Int64 = 40 * 86_400 * 1000
    /// Prefijo de los ids de evento de Cursor (`CursorCollector.classify`).
    private static let cursorIDPrefix = "cursor:"

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

    private struct PayloadV2: Decodable {
        var bootstrapped: [String]
        var cursors: [String: FileCursor]
        var seenMessageIDs: [String]
        var claudeMessages: [ClaudeMessageState]
        var cursorLastEventTimestampMs: Int64?
        var cursorContinuation: CursorContinuation?
    }

    /// Formato en disco de `state.json`.
    private struct Payload: Codable {
        var version: Int
        var bootstrapped: [String]
        var cursors: [String: FileCursor]
        var seenMessageIDs: [String]
        var claudeMessages: [ClaudeMessageState]
        var cursorLastEventTimestampMs: Int64?
        var cursorContinuation: CursorContinuation?
        var codexResponseIDsBySource: [String: [String]]
        var codexModelByPath: [String: String]
        var commandCodeMessageIDs: [String]
        var openCodeFinalizedMessageIDs: [String]
        var openCodeWatermark: OpenCodeWatermark?
        /// v4: foto por id de evento de Cursor.
        var cursorEventSnapshots: [String: CursorEventSnapshot]
        /// v4: ids de Cursor contados antes de que existieran las fotos (migrados de
        /// `seenMessageIDs`). Se tratan como "ya contados por completo": no se vuelven a
        /// sumar, aunque hayan crecido, para no inflar días ya guardados.
        var cursorSeenWithoutSnapshot: [String]

        init(version: Int, bootstrapped: [String], cursors: [String: FileCursor],
             seenMessageIDs: [String], claudeMessages: [ClaudeMessageState],
             cursorLastEventTimestampMs: Int64?, cursorContinuation: CursorContinuation?,
             codexResponseIDsBySource: [String: [String]], codexModelByPath: [String: String],
             commandCodeMessageIDs: [String], openCodeFinalizedMessageIDs: [String],
             openCodeWatermark: OpenCodeWatermark?,
             cursorEventSnapshots: [String: CursorEventSnapshot],
             cursorSeenWithoutSnapshot: [String]) {
            self.version = version
            self.bootstrapped = bootstrapped
            self.cursors = cursors
            self.seenMessageIDs = seenMessageIDs
            self.claudeMessages = claudeMessages
            self.cursorLastEventTimestampMs = cursorLastEventTimestampMs
            self.cursorContinuation = cursorContinuation
            self.codexResponseIDsBySource = codexResponseIDsBySource
            self.codexModelByPath = codexModelByPath
            self.commandCodeMessageIDs = commandCodeMessageIDs
            self.openCodeFinalizedMessageIDs = openCodeFinalizedMessageIDs
            self.openCodeWatermark = openCodeWatermark
            self.cursorEventSnapshots = cursorEventSnapshots
            self.cursorSeenWithoutSnapshot = cursorSeenWithoutSnapshot
        }

        private enum CodingKeys: String, CodingKey {
            case version, bootstrapped, cursors, seenMessageIDs, claudeMessages
            case cursorLastEventTimestampMs, cursorContinuation, codexResponseIDsBySource
            case codexModelByPath, commandCodeMessageIDs, openCodeFinalizedMessageIDs
            case openCodeWatermark, cursorEventSnapshots, cursorSeenWithoutSnapshot
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
            bootstrapped = try container.decode([String].self, forKey: .bootstrapped)
            cursors = try container.decode([String: FileCursor].self, forKey: .cursors)
            seenMessageIDs = try container.decode([String].self, forKey: .seenMessageIDs)
            claudeMessages = try container.decode([ClaudeMessageState].self, forKey: .claudeMessages)
            cursorLastEventTimestampMs = try container.decodeIfPresent(
                Int64.self, forKey: .cursorLastEventTimestampMs
            )
            cursorContinuation = try container.decodeIfPresent(
                CursorContinuation.self, forKey: .cursorContinuation
            )
            codexResponseIDsBySource = try container.decodeIfPresent(
                [String: [String]].self, forKey: .codexResponseIDsBySource
            ) ?? [:]
            codexModelByPath = try container.decodeIfPresent(
                [String: String].self, forKey: .codexModelByPath
            ) ?? [:]
            commandCodeMessageIDs = try container.decodeIfPresent(
                [String].self, forKey: .commandCodeMessageIDs
            ) ?? []
            openCodeFinalizedMessageIDs = try container.decodeIfPresent(
                [String].self, forKey: .openCodeFinalizedMessageIDs
            ) ?? []
            openCodeWatermark = try container.decodeIfPresent(
                OpenCodeWatermark.self, forKey: .openCodeWatermark
            )
            cursorEventSnapshots = try container.decodeIfPresent(
                [String: CursorEventSnapshot].self, forKey: .cursorEventSnapshots
            ) ?? [:]
            cursorSeenWithoutSnapshot = try container.decodeIfPresent(
                [String].self, forKey: .cursorSeenWithoutSnapshot
            ) ?? []
        }
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
    /// Epoch en ms del evento de Cursor más reciente ya visto; el collector consulta
    /// desde aquí en vez de retraer una ventana fija.
    private var cursorLastEventTimestampMs: Int64?
    /// Ventana de Cursor a medio traer (tope de páginas o de tiempo); `nil` si la última
    /// ventana se completó sin toparse.
    private var cursorWindowContinuation: CursorContinuation?
    /// Foto por id de evento de Cursor (ver `CursorEventSnapshot`).
    private var cursorSnapshots: [String: CursorEventSnapshot] = [:]
    /// Ids de Cursor contados ANTES de v4, cuando solo se guardaba un booleano por evento
    /// (`seenMessageIDs`). No hay foto contra qué comparar, así que se tratan como ya
    /// contados por completo y nunca se vuelven a sumar: lo contrario inflaría los días
    /// ya guardados con el evento entero otra vez. Se purgan por edad igual que las fotos.
    private var cursorSeenWithoutSnapshot: Set<String> = []
    private var codexResponseIDsBySource: [String: Set<String>] = [:]
    private var codexResponseOrderBySource: [String: [String]] = [:]
    private var codexModelsByPath: [String: String] = [:]
    private var commandCodeIDs: Set<String> = []
    private var commandCodeIDOrder: [String] = []
    private var openCodeFinalizedIDs: Set<String> = []
    private var openCodeFinalizedIDOrder: [String] = []
    /// Marca de agua de OpenCode: `time_updated` (epoch ms) del último mensaje terminado visto.
    private var openCodeWatermarkValue: OpenCodeWatermark?
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
            case 2:
                loadV2(try decoder.decode(PayloadV2.self, from: data))
                isDirty = true
            case 3:
                // Mismas claves que v4 menos las fotos de Cursor: los ids `cursor:*` de
                // `seenMessageIDs` pasan a `cursorSeenWithoutSnapshot` en `restoreSeen`.
                loadV3(try decoder.decode(Payload.self, from: data))
                isDirty = true
            case Self.formatVersion:
                loadV3(try decoder.decode(Payload.self, from: data))
            case let futureVersion where futureVersion > Self.formatVersion:
                loadV3(try decoder.decode(Payload.self, from: data))
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

    /// Marca de agua del collector de Cursor; `nil` si nunca ha corrido (primer arranque).
    func cursorLastEventTimestamp() async -> Int64? {
        cursorLastEventTimestampMs
    }

    /// Avanza la marca de Cursor; es monótona: nunca retrocede aunque las páginas
    /// lleguen desordenadas.
    func advanceCursorLastEventTimestamp(to timestampMs: Int64) async {
        guard timestampMs >= 0,
              timestampMs > (cursorLastEventTimestampMs ?? -1) else { return }
        cursorLastEventTimestampMs = timestampMs
        isDirty = true
    }

    /// Ventana de Cursor a medio traer; `nil` si la última se completó sin toparse.
    func cursorContinuation() async -> CursorContinuation? {
        cursorWindowContinuation
    }

    /// Reemplaza (o crea) la continuación en curso: el ciclo topó con el límite de páginas
    /// o de tiempo antes de terminar la ventana.
    func setCursorContinuation(_ continuation: CursorContinuation) async {
        guard cursorWindowContinuation != continuation else { return }
        cursorWindowContinuation = continuation
        isDirty = true
    }

    /// Limpia la continuación: la ventana se completó, ya no hace falta retomarla.
    func clearCursorContinuation() async {
        guard cursorWindowContinuation != nil else { return }
        cursorWindowContinuation = nil
        isDirty = true
    }

    /// Registra la foto actual de un evento de Cursor y devuelve lo que falta por sumar
    /// (mismo patrón que `recordClaudeMessage`, pero con los cuatro contadores y el costo).
    ///
    /// - Sin foto previa: el evento entero es el delta.
    /// - Con foto previa: el delta es la diferencia positiva por campo; la foto guardada
    ///   queda en el máximo por campo. Un campo que BAJA no resta (`shrank` lo avisa).
    /// - Id contado antes de v4 (`cursorSeenWithoutSnapshot`): delta en cero, sin crear
    ///   foto — ver la nota de esa propiedad.
    /// Un costo que sube sin que suban los tokens también cuenta (delta con tokens en 0):
    /// es el ajuste final de centavos de un turno que ya no crece y, si se ignorara, se
    /// perdería para siempre.
    func recordCursorEvent(id: String, snapshot: CursorEventSnapshot) async -> CursorEventDelta {
        let zero = CursorEventSnapshot(timestampMs: snapshot.timestampMs, inputTokens: 0, outputTokens: 0,
                                       cacheCreationTokens: 0, cacheReadTokens: 0, costUSD: 0)
        if cursorSeenWithoutSnapshot.contains(id) {
            return CursorEventDelta(isNewEvent: false, delta: zero, shrank: false)
        }
        guard let previous = cursorSnapshots[id] else {
            cursorSnapshots[id] = snapshot
            isDirty = true
            return CursorEventDelta(isNewEvent: true, delta: snapshot, shrank: false)
        }
        let delta = CursorEventSnapshot(
            timestampMs: snapshot.timestampMs,
            inputTokens: max(0, snapshot.inputTokens - previous.inputTokens),
            outputTokens: max(0, snapshot.outputTokens - previous.outputTokens),
            cacheCreationTokens: max(0, snapshot.cacheCreationTokens - previous.cacheCreationTokens),
            cacheReadTokens: max(0, snapshot.cacheReadTokens - previous.cacheReadTokens),
            costUSD: max(0, snapshot.costUSD - previous.costUSD)
        )
        let shrank = snapshot.inputTokens < previous.inputTokens
            || snapshot.outputTokens < previous.outputTokens
            || snapshot.cacheCreationTokens < previous.cacheCreationTokens
            || snapshot.cacheReadTokens < previous.cacheReadTokens
            || snapshot.costUSD < previous.costUSD
        guard delta.totalTokens > 0 || delta.costUSD > 0 else {
            return CursorEventDelta(isNewEvent: false, delta: zero, shrank: shrank)
        }
        cursorSnapshots[id] = CursorEventSnapshot(
            timestampMs: previous.timestampMs,
            inputTokens: max(previous.inputTokens, snapshot.inputTokens),
            outputTokens: max(previous.outputTokens, snapshot.outputTokens),
            cacheCreationTokens: max(previous.cacheCreationTokens, snapshot.cacheCreationTokens),
            cacheReadTokens: max(previous.cacheReadTokens, snapshot.cacheReadTokens),
            costUSD: max(previous.costUSD, snapshot.costUSD)
        )
        isDirty = true
        return CursorEventDelta(isNewEvent: false, delta: delta, shrank: shrank)
    }

    func markCodexResponseSeen(responseID: String, source: String) async -> Bool {
        var ids = codexResponseIDsBySource[source, default: []]
        guard ids.insert(responseID).inserted else { return true }
        codexResponseIDsBySource[source] = ids
        codexResponseOrderBySource[source, default: []].append(responseID)
        isDirty = true
        return false
    }

    func codexModel(forPath path: String) async -> String? {
        codexModelsByPath[path]
    }

    func setCodexModel(_ model: String, forPath path: String) async {
        guard codexModelsByPath[path] != model else { return }
        codexModelsByPath[path] = model
        isDirty = true
    }

    func markCommandCodeSeen(messageID: String) async -> Bool {
        guard commandCodeIDs.insert(messageID).inserted else { return true }
        commandCodeIDOrder.append(messageID)
        isDirty = true
        return false
    }

    func markOpenCodeFinalized(messageID: String) async -> Bool {
        guard openCodeFinalizedIDs.insert(messageID).inserted else { return true }
        openCodeFinalizedIDOrder.append(messageID)
        isDirty = true
        return false
    }

    func openCodeWatermark() async -> OpenCodeWatermark? {
        openCodeWatermarkValue
    }

    func setOpenCodeWatermark(_ value: OpenCodeWatermark) async {
        guard openCodeWatermarkValue != value else { return }
        openCodeWatermarkValue = value
        isDirty = true
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

    /// Elimina los cursores de archivos que ya no aparecen en `seenPaths`. Llamar solo tras un
    /// recorrido COMPLETO del árbol: con un ciclo cortado por presupuesto (o por cancelación),
    /// `seenPaths` no cubre todos los archivos vivos y podar borraría cursores de archivos que
    /// simplemente no se visitaron.
    func pruneCursors(keeping seenPaths: Set<String>) async {
        // Los cursores con espacio de nombres son de otro collector: no se podan aquí.
        let stale = cursors.keys.filter { !seenPaths.contains($0) && Self.namespace(ofCursorKey: $0) == nil }
        guard !stale.isEmpty else { return }
        for path in stale { cursors[path] = nil }
        isDirty = true
    }

    /// Clave de cursor propia de una fuente. Evita que la poda de Claude Code (que ve solo
    /// sus rutas) borre los cursores de Codex o Command Code, y viceversa.
    static func cursorKey(forPath path: String, source: AppSource) -> String {
        "\(source.rawValue):\(path)"
    }

    private static func namespace(ofCursorKey key: String) -> AppSource? {
        // `allCases` solo trae Claude, Cursor y Antigravity: se suman las fuentes con collector.
        let sources = Set(AppSource.allCases).union(AppSource.tokenSources).union(AppSource.limitsCases)
        return sources.first { key.hasPrefix("\($0.rawValue):") }
    }

    /// Poda los cursores de una fuente cuyas rutas ya no existen. `seenPaths` son rutas crudas.
    func pruneCursors(keeping seenPaths: Set<String>, source: AppSource) async {
        let keptKeys = Set(seenPaths.map { Self.cursorKey(forPath: $0, source: source) })
        let prefix = "\(source.rawValue):"
        let stale = cursors.keys.filter { $0.hasPrefix(prefix) && !keptKeys.contains($0) }
        let staleModels = codexModelsByPath.keys.filter { source == .codex && !seenPaths.contains($0) }
        guard !stale.isEmpty || !staleModels.isEmpty else { return }
        for key in stale { cursors[key] = nil }
        for path in staleModels { codexModelsByPath[path] = nil }
        isDirty = true
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
        let codexResponseIDs = codexResponseOrderBySource.mapValues { $0 }
        let payload = Payload(version: Self.formatVersion,
                              bootstrapped: bootstrapped.map(\.rawValue).sorted(),
                              cursors: cursors,
                              seenMessageIDs: seenOrder,
                              claudeMessages: claudeMessages,
                              cursorLastEventTimestampMs: cursorLastEventTimestampMs,
                              cursorContinuation: cursorWindowContinuation,
                              codexResponseIDsBySource: codexResponseIDs,
                              codexModelByPath: codexModelsByPath,
                              commandCodeMessageIDs: commandCodeIDOrder,
                              openCodeFinalizedMessageIDs: openCodeFinalizedIDOrder,
                              openCodeWatermark: openCodeWatermarkValue,
                              cursorEventSnapshots: cursorSnapshots,
                              cursorSeenWithoutSnapshot: cursorSeenWithoutSnapshot.sorted())
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
        for source in Array(codexResponseOrderBySource.keys) {
            guard let order = codexResponseOrderBySource[source],
                  order.count > Self.maxSeenMessageIDs else { continue }
            let kept = Array(order.suffix(Self.maxSeenMessageIDs))
            codexResponseOrderBySource[source] = kept
            codexResponseIDsBySource[source] = Set(kept)
        }
        if commandCodeIDOrder.count > Self.maxSeenMessageIDs {
            let kept = Array(commandCodeIDOrder.suffix(Self.maxSeenMessageIDs))
            commandCodeIDOrder = kept
            commandCodeIDs = Set(kept)
        }
        if openCodeFinalizedIDOrder.count > Self.maxSeenMessageIDs {
            let kept = Array(openCodeFinalizedIDOrder.suffix(Self.maxSeenMessageIDs))
            openCodeFinalizedIDOrder = kept
            openCodeFinalizedIDs = Set(kept)
        }
        pruneCursorSnapshots(now: Date())
    }

    /// Purga las fotos de Cursor (y los ids sin foto) más viejos que
    /// `cursorSnapshotRetentionMs`. Los ids sin foto no guardan timestamp aparte, pero el
    /// id lo lleva al final (`cursor:<conversationId>:<epoch ms>`); si no se puede leer,
    /// el id se conserva.
    private func pruneCursorSnapshots(now: Date) {
        let cutoffMs = Int64(now.timeIntervalSince1970 * 1000) - Self.cursorSnapshotRetentionMs
        cursorSnapshots = cursorSnapshots.filter { $0.value.timestampMs >= cutoffMs }
        cursorSeenWithoutSnapshot = cursorSeenWithoutSnapshot.filter { id in
            guard let separator = id.lastIndex(of: ":"),
                  let millis = Int64(id[id.index(after: separator)...]) else { return true }
            return millis >= cutoffMs
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

    private func loadV2(_ payload: PayloadV2) {
        restoreCommonState(bootstrapped: payload.bootstrapped,
                           cursors: payload.cursors,
                           seenMessageIDs: payload.seenMessageIDs,
                           claudeMessages: payload.claudeMessages,
                           cursorLastEventTimestampMs: payload.cursorLastEventTimestampMs,
                           cursorContinuation: payload.cursorContinuation)
    }

    private func loadV3(_ payload: Payload) {
        restoreCommonState(bootstrapped: payload.bootstrapped,
                           cursors: payload.cursors,
                           seenMessageIDs: payload.seenMessageIDs,
                           claudeMessages: payload.claudeMessages,
                           cursorLastEventTimestampMs: payload.cursorLastEventTimestampMs,
                           cursorContinuation: payload.cursorContinuation)
        codexResponseOrderBySource = payload.codexResponseIDsBySource.mapValues(Self.unique)
        codexResponseIDsBySource = codexResponseOrderBySource.mapValues(Set.init)
        codexModelsByPath = payload.codexModelByPath
        commandCodeIDOrder = Self.unique(payload.commandCodeMessageIDs)
        commandCodeIDs = Set(commandCodeIDOrder)
        openCodeFinalizedIDOrder = Self.unique(payload.openCodeFinalizedMessageIDs)
        openCodeFinalizedIDs = Set(openCodeFinalizedIDOrder)
        openCodeWatermarkValue = payload.openCodeWatermark
        cursorSnapshots = payload.cursorEventSnapshots
        // Unión, no reemplazo: `restoreSeen` ya pudo haber movido ids `cursor:*` de
        // `seenMessageIDs` (archivo v3) a este set.
        cursorSeenWithoutSnapshot.formUnion(payload.cursorSeenWithoutSnapshot)
    }

    private func restoreCommonState(bootstrapped rawBootstrapped: [String],
                                    cursors loadedCursors: [String: FileCursor],
                                    seenMessageIDs: [String],
                                    claudeMessages: [ClaudeMessageState],
                                    cursorLastEventTimestampMs loadedTimestamp: Int64?,
                                    cursorContinuation loadedContinuation: CursorContinuation?) {
        bootstrapped = Set(rawBootstrapped.compactMap(AppSource.init(rawValue:)))
        cursors = loadedCursors
        restoreSeen(seenMessageIDs)
        var keys = Set<String>()
        claudeOrder = []
        claudeOutputs = [:]
        for message in claudeMessages where keys.insert(message.key).inserted {
            claudeOrder.append(message.key)
            claudeOutputs[message.key] = max(0, message.output)
        }
        cursorLastEventTimestampMs = loadedTimestamp
        cursorWindowContinuation = loadedContinuation
    }

    private static func unique(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    /// Hasta v3, Cursor deduplicaba con un booleano por evento en `seenMessageIDs`. Esos ids
    /// (`cursor:*`) se separan a `cursorSeenWithoutSnapshot`: ya se contaron con su primera
    /// foto y no hay contra qué calcular un delta, así que no se vuelven a sumar.
    private func restoreSeen(_ ids: [String]) {
        var unique = Set<String>()
        seenOrder = []
        seenOrder.reserveCapacity(ids.count)
        cursorSeenWithoutSnapshot = []
        for id in ids {
            if id.hasPrefix(Self.cursorIDPrefix) {
                cursorSeenWithoutSnapshot.insert(id)
            } else if unique.insert(id).inserted {
                seenOrder.append(id)
            }
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
        cursorLastEventTimestampMs = nil
        cursorWindowContinuation = nil
        cursorSnapshots = [:]
        cursorSeenWithoutSnapshot = []
        codexResponseIDsBySource = [:]
        codexResponseOrderBySource = [:]
        codexModelsByPath = [:]
        commandCodeIDs = []
        commandCodeIDOrder = []
        openCodeFinalizedIDs = []
        openCodeFinalizedIDOrder = []
        openCodeWatermarkValue = nil
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
