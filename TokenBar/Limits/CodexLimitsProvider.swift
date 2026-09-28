import Foundation
import OSLog

/// Lee los límites de la cuenta de ChatGPT usada por Codex CLI.
struct CodexLimitsProvider: LimitsProvider {
    let source: AppSource = .codex

    enum Endpoint {
        static let usage = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    }

    static var defaultAuthURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex/auth.json")
    }

    static var defaultSessionsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex/sessions")
    }

    static let tailByteLimit: UInt64 = 256 * 1024
    /// Plazo absoluto para la consulta de red, más allá de `URLRequest.timeoutInterval`.
    static let fetchBudget: Duration = .seconds(5)
    private static let directoryLimit = 3
    private static let dayLimit = 7
    private static let fileLimit = 8
    private static let log = Logger(subsystem: "io.github.jhosgun.tokenbar", category: "codex-limits")

    private let authURL: URL
    private let sessionsURL: URL
    private let session: URLSession

    init(authURL: URL = CodexLimitsProvider.defaultAuthURL,
         sessionsURL: URL = CodexLimitsProvider.defaultSessionsURL,
         session: URLSession = .shared) {
        self.authURL = authURL
        self.sessionsURL = sessionsURL
        self.session = session
    }

    func fetch() async -> LimitsSnapshot {
        guard let credential = Self.credential(at: authURL) else {
            return .empty(source, .notConfigured)
        }
        return await NetworkDeadline.run(budget: Self.fetchBudget) {
            await self.requestUsage(credential: credential)
        } ?? fallback(or: .failed("Tiempo de espera agotado"))
    }

    private func requestUsage(credential: Credential) async -> LimitsSnapshot {
        var request = URLRequest(url: Endpoint.usage)
        request.timeoutInterval = 5
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credential.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse {
                switch http.statusCode {
                case 200..<300:
                    if let snapshot = Self.parseUsage(data) { return snapshot }
                    return fallback(or: .failed("Respuesta no reconocida"))
                case 401, 403:
                    // Estado definitivo: hay que reautenticar, así que no tiene sentido
                    // taparlo con el rollout local.
                    return .empty(source, .invalidCredentials)
                case 429:
                    return rateLimited(retryAfter: RetryAfter.date(from: http))
                default:
                    return fallback(or: .failed("HTTP \(http.statusCode)"))
                }
            }
            if let snapshot = Self.parseUsage(data) { return snapshot }
            return fallback(or: .failed("Respuesta no reconocida"))
        } catch {
            Self.log.error("fallo de red: \(error.localizedDescription, privacy: .public)")
            return fallback(or: .failed("Sin conexión"))
        }
    }

    /// Un 429 activa el backoff del ViewModel (`rateLimited`), pero conserva las ventanas
    /// del rollout local si las hay: el endpoint saturado no tiene por qué vaciar la fila.
    private func rateLimited(retryAfter: Date?) -> LimitsSnapshot {
        guard var snapshot = Self.latestRolloutSnapshot(in: sessionsURL) else {
            return .rateLimited(source, retryAfter: retryAfter)
        }
        snapshot.status = .failed("Límite de consultas alcanzado")
        snapshot.rateLimited = true
        snapshot.rateLimitedUntil = retryAfter
        return snapshot
    }

    private func fallback(or status: CollectorStatus) -> LimitsSnapshot {
        guard var snapshot = Self.latestRolloutSnapshot(in: sessionsURL) else {
            return .empty(source, status)
        }
        snapshot.status = .failed("A la última actividad")
        return snapshot
    }

    // MARK: - Credencial

    struct Credential: Equatable, Sendable {
        let accessToken: String
        let accountID: String
    }

    private struct AuthFile: Decodable {
        struct Tokens: Decodable {
            let accessToken: String?
            let accountID: String?

            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case accountID = "account_id"
            }
        }

        let tokens: Tokens?
    }

    static func credential(at url: URL) -> Credential? {
        guard let data = try? Data(contentsOf: url),
              let auth = try? JSONDecoder().decode(AuthFile.self, from: data),
              let accessToken = auth.tokens?.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              let accountID = auth.tokens?.accountID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !accessToken.isEmpty, !accountID.isEmpty else { return nil }
        return Credential(accessToken: accessToken, accountID: accountID)
    }

    // MARK: - Parsing

    static func parseUsage(_ data: Data) -> LimitsSnapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rateLimit = root["rate_limit"] as? [String: Any] else { return nil }
        return snapshot(rateLimit: rateLimit,
                        plan: root["plan_type"] as? String,
                        additional: root["additional_rate_limits"] as? [[String: Any]])
    }

    private static func snapshot(rateLimit: [String: Any],
                                 plan: String?,
                                 additional: [[String: Any]]? = nil) -> LimitsSnapshot? {
        var seen: Set<String> = []
        var parsedWindows = windows(from: rateLimit, seen: &seen)
        for item in additional ?? [] {
            let container = (item["rate_limit"] as? [String: Any]) ?? item
            let prefix = item["limit_name"] as? String ?? item["name"] as? String
            parsedWindows.append(contentsOf: windows(from: container, prefix: prefix, seen: &seen))
        }
        guard !parsedWindows.isEmpty else { return nil }
        // Orden global por duración, la más corta primero: Codex concatena por contenedor
        // (base, luego cada `additional_rate_limits`), y eso puede dejar una semanal
        // delante de una 5 horas si al contenedor base le falta esta última.
        //
        // `sorted` no está garantizado estable en Swift, así que dos ventanas de la misma
        // duración (el caso común: la de la cuenta y la de un modelo, ambas de 5 horas)
        // podrían intercambiar su orden entre corridas. Se desempata por la posición
        // original para que la de la cuenta —la que se insertó primero— siga mandando
        // sobre la de un modelo cuando duran lo mismo.
        let ordered = parsedWindows.enumerated()
            .sorted { lhs, rhs in
                lhs.element.minutes != rhs.element.minutes
                    ? lhs.element.minutes < rhs.element.minutes
                    : lhs.offset < rhs.offset
            }
            .map(\.element.window)
        let label = plan?.trimmingCharacters(in: .whitespacesAndNewlines)
        return LimitsSnapshot(source: .codex,
                              windows: ordered,
                              planLabel: label?.isEmpty == false ? label : nil,
                              status: .ok)
    }

    private static func windows(from container: [String: Any],
                                prefix: String? = nil,
                                seen: inout Set<String>) -> [(window: LimitWindow, minutes: Int)] {
        let keys = ["primary_window", "secondary_window", "primary", "secondary"]
        return keys.compactMap { key in
            guard let value = container[key] as? [String: Any],
                  let parsed = window(from: value, prefix: prefix),
                  seen.insert(parsed.window.name).inserted else { return nil }
            return parsed
        }
    }

    private static func window(from value: [String: Any],
                               prefix: String?) -> (window: LimitWindow, minutes: Int)? {
        guard let used = number(value["used_percent"]),
              let utilization = LimitWindow.utilization(fromPercent: used),
              let minutes = windowMinutes(from: value) else { return nil }
        let baseName = windowName(minutes: minutes)
        // Junto a un modelo el nombre va en minúscula ("Codex Mini semanal"), como ya
        // hace `ClaudeLimitsProvider` con sus cuotas por modelo ("Fable semanal").
        let name = prefix.map { "\($0) \(lowercasedFirstLetter(baseName))" } ?? baseName
        let window = LimitWindow(name: name,
                                 utilization: utilization,
                                 resetsAt: resetDate(from: value["reset_at"] ?? value["resets_at"]))
        return (window, minutes)
    }

    private static func lowercasedFirstLetter(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.lowercased() + text.dropFirst()
    }

    private static func windowMinutes(from value: [String: Any]) -> Int? {
        if let raw = number(value["window_minutes"]), raw.isFinite,
           raw > 0, raw.rounded() == raw, let minutes = Int(exactly: raw) {
            return minutes
        }
        if let seconds = number(value["limit_window_seconds"]), seconds.isFinite,
           seconds > 0, (seconds / 60).rounded() == seconds / 60,
           let minutes = Int(exactly: seconds / 60) {
            return minutes
        }
        return nil
    }

    static func windowName(minutes: Int) -> String {
        switch minutes {
        case 300: return "5 horas"
        case 10_080: return "Semanal"
        case let value where value.isMultiple(of: 1_440): return "\(value / 1_440) d"
        case let value where value.isMultiple(of: 60): return "\(value / 60) h"
        default: return "\(minutes) min"
        }
    }

    static func resetDate(from value: Any?) -> Date? {
        if let seconds = number(value), seconds.isFinite, seconds >= 0, seconds < 1e12 {
            return Date(timeIntervalSince1970: seconds)
        }
        guard let text = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    // MARK: - Rollouts locales

    static func latestRolloutSnapshot(in sessionsURL: URL) -> LimitsSnapshot? {
        for file in recentRolloutFiles(in: sessionsURL) {
            guard let tail = tail(of: file) else { continue }
            var data = tail.data
            if tail.wasTruncated {
                guard let newline = data.firstIndex(of: UInt8(ascii: "\n")) else { continue }
                data = Data(data[data.index(after: newline)...])
            }
            guard let text = String(data: data, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
                guard let data = line.data(using: .utf8),
                      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let snapshot = rolloutSnapshot(from: root) else { continue }
                return snapshot
            }
        }
        return nil
    }

    private static func rolloutSnapshot(from root: [String: Any]) -> LimitsSnapshot? {
        let payload = (root["payload"] as? [String: Any]) ?? root
        guard payload["type"] as? String == "token_count" else { return nil }
        let rateLimits = payload["rate_limits"] as? [String: Any]
            ?? (payload["info"] as? [String: Any])?["rate_limits"] as? [String: Any]
        guard let rateLimits else { return nil }
        let plan = rateLimits["plan_type"] as? String ?? payload["plan_type"] as? String
        return snapshot(rateLimit: rateLimits, plan: plan)
    }

    private static func recentRolloutFiles(in root: URL) -> [URL] {
        let years = recentDirectories(in: root, limit: directoryLimit)
        let months = years.flatMap { recentDirectories(in: $0, limit: directoryLimit) }
        let days = months.flatMap { recentDirectories(in: $0, limit: dayLimit) }
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        return days.flatMap { directory -> [URL] in
            (try? FileManager.default.contentsOfDirectory(at: directory,
                                                          includingPropertiesForKeys: Array(keys),
                                                          options: [.skipsHiddenFiles])) ?? []
        }
        .filter { $0.lastPathComponent.hasPrefix("rollout-") && $0.pathExtension == "jsonl" }
        .sorted { modificationDate(of: $0) > modificationDate(of: $1) }
        .prefix(fileLimit)
        .map { $0 }
    }

    private static func recentDirectories(in root: URL, limit: Int) -> [URL] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: root,
                                                                 includingPropertiesForKeys: Array(keys),
                                                                 options: [.skipsHiddenFiles])) ?? []
        return urls.filter { (try? $0.resourceValues(forKeys: keys).isDirectory) == true }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .prefix(limit)
            .map { $0 }
    }

    private static func modificationDate(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
    }

    private struct FileTail {
        let data: Data
        let wasTruncated: Bool
    }

    private static func tail(of url: URL) -> FileTail? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let wasTruncated = size > tailByteLimit
        let start = wasTruncated ? size - tailByteLimit : 0
        do {
            try handle.seek(toOffset: start)
            guard let data = try handle.readToEnd() else { return nil }
            return FileTail(data: data, wasTruncated: wasTruncated)
        } catch {
            return nil
        }
    }
}
