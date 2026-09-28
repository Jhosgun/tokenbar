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
                    return fallback(or: .failed("Abre Codex para renovar la sesión"))
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
        let label = plan?.trimmingCharacters(in: .whitespacesAndNewlines)
        return LimitsSnapshot(source: .codex,
                              windows: parsedWindows,
                              planLabel: label?.isEmpty == false ? label : nil,
                              status: .ok)
    }

    private static func windows(from container: [String: Any],
                                prefix: String? = nil,
                                seen: inout Set<String>) -> [LimitWindow] {
        let keys = ["primary_window", "secondary_window", "primary", "secondary"]
        return keys.compactMap { key in
            guard let value = container[key] as? [String: Any],
                  let window = window(from: value, prefix: prefix),
                  seen.insert(window.name).inserted else { return nil }
            return window
        }
    }

    private static func window(from value: [String: Any], prefix: String?) -> LimitWindow? {
        guard let used = number(value["used_percent"]), used.isFinite,
              let minutes = windowMinutes(from: value) else { return nil }
        let baseName = windowName(minutes: minutes)
        let name = prefix.map { "\($0) · \(baseName)" } ?? baseName
        return LimitWindow(name: name,
                           utilization: used / 100,
                           resetsAt: resetDate(from: value["reset_at"] ?? value["resets_at"]))
    }

    private static func windowMinutes(from value: [String: Any]) -> Int? {
        if let raw = number(value["window_minutes"]), raw.isFinite,
           raw > 0, raw.rounded() == raw {
            return Int(raw)
        }
        if let seconds = number(value["limit_window_seconds"]), seconds.isFinite,
           seconds > 0, (seconds / 60).rounded() == seconds / 60 {
            return Int(seconds / 60)
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
