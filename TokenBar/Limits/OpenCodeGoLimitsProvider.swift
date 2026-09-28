import Foundation
import OSLog

struct OpenCodeGoLimitsProvider: LimitsProvider {
    let source: AppSource = .opencode

    enum Endpoint {
        static let usage = URL(string: "https://opencode.ai/zen/go/v1/usage")!
    }

    static var defaultAuthURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".local/share/opencode/auth.json")
    }

    private static let log = Logger(subsystem: "io.github.jhosgun.tokenbar", category: "opencode-limits")
    private static let windowLabels: [(key: String, label: String)] = [
        ("rolling", "5 horas"),
        ("weekly", "Semanal"),
        ("monthly", "Mes")
    ]

    private let authURL: URL
    private let session: URLSession
    private let now: @Sendable () -> Date

    init(authURL: URL = OpenCodeGoLimitsProvider.defaultAuthURL,
         session: URLSession = .shared,
         now: @escaping @Sendable () -> Date = Date.init) {
        self.authURL = authURL
        self.session = session
        self.now = now
    }

    func fetch() async -> LimitsSnapshot {
        guard let key = Self.apiKey(at: authURL) else {
            return .empty(source, .notConfigured)
        }

        var request = URLRequest(url: Endpoint.usage)
        request.timeoutInterval = 5
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Cloudflare responde 403 a la petición sin User-Agent propio.
        request.setValue("TokenBar", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse {
                switch http.statusCode {
                case 200..<300: break
                case 401, 403: return .empty(source, .invalidCredentials)
                default: return .empty(source, .failed("HTTP \(http.statusCode)"))
                }
            }
            guard let snapshot = Self.parse(data, now: now()) else {
                return .empty(source, .failed("Respuesta no reconocida"))
            }
            return snapshot
        } catch {
            Self.log.error("fallo de red: \(error.localizedDescription, privacy: .public)")
            return .empty(source, .failed("Sin conexión"))
        }
    }

    static func apiKey(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        for name in ["opencode-go", "opencode"] {
            guard let entry = root[name] as? [String: Any],
                  entry["type"] as? String == "api",
                  let key = (entry["key"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !key.isEmpty else { continue }
            return key
        }
        return nil
    }

    static func parse(_ data: Data, now: Date) -> LimitsSnapshot? {
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // Forma real de la API: {"usage":{"rolling":{"percent":…,"resetsAt":…},…}}
            if let usage = root["usage"] as? [String: Any] {
                let windows = windowLabels.compactMap { item -> LimitWindow? in
                    guard let bucket = usage[item.key] as? [String: Any],
                          let percent = number(bucket["percent"]), percent.isFinite, percent >= 0 else {
                        return nil
                    }
                    return LimitWindow(name: item.label,
                                       utilization: percent / 100,
                                       resetsAt: date(from: bucket["resetsAt"]))
                }
                guard !windows.isEmpty else { return nil }
                return LimitsSnapshot(source: .opencode, windows: windows, planLabel: nil, status: .ok)
            }
            // Forma anterior: {"rolling":{"usagePercent":…,"resetInSec":…},…}
            let windows = windowLabels.compactMap { item -> LimitWindow? in
                guard let bucket = root[item.key] as? [String: Any],
                      let percent = number(bucket["usagePercent"]), percent.isFinite, percent >= 0,
                      let reset = number(bucket["resetInSec"]), reset.isFinite, reset >= 0 else {
                    return nil
                }
                return LimitWindow(name: item.label,
                                   utilization: percent / 100,
                                   resetsAt: now.addingTimeInterval(reset))
            }
            guard !windows.isEmpty else { return nil }
            return LimitsSnapshot(source: .opencode, windows: windows, planLabel: nil, status: .ok)
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let buckets: [String: [String: Any]] = Dictionary(uniqueKeysWithValues: windowLabels.compactMap { item in
            guard let bucket = serializedObject(named: item.key, in: text) else { return nil }
            return (item.key, bucket)
        })
        let windows = windowLabels.compactMap { item -> LimitWindow? in
            guard let bucket = buckets[item.key],
                  let percent = number(bucket["usagePercent"]), percent.isFinite, percent >= 0,
                  let reset = number(bucket["resetInSec"]), reset.isFinite, reset >= 0 else {
                return nil
            }
            return LimitWindow(name: item.label,
                               utilization: percent / 100,
                               resetsAt: now.addingTimeInterval(reset))
        }
        guard !windows.isEmpty else { return nil }
        return LimitsSnapshot(source: .opencode, windows: windows, planLabel: nil, status: .ok)
    }

    private static func date(from value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }

    private static func serializedObject(named name: String, in text: String) -> [String: Any]? {
        guard let keyRange = text.range(of: name),
              let colon = text[keyRange.upperBound...].firstIndex(of: ":"),
              let start = text[colon...].firstIndex(of: "{") else { return nil }

        var depth = 0
        var quote: Character?
        var escaped = false
        var end: String.Index?
        for index in text.indices[start...] {
            let character = text[index]
            if let activeQuote = quote {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == activeQuote {
                    quote = nil
                }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    end = text.index(after: index)
                    break
                }
            }
        }
        guard let end else { return nil }
        let object = String(text[start..<end])
        guard let usage = field("usagePercent", in: object),
              let reset = field("resetInSec", in: object) else { return nil }
        return ["usagePercent": usage, "resetInSec": reset]
    }

    private static func field(_ name: String, in object: String) -> Double? {
        guard let keyRange = object.range(of: name),
              let colon = object[keyRange.upperBound...].firstIndex(of: ":") else { return nil }
        let suffix = object[object.index(after: colon)...]
        let trimmed = suffix.drop(while: { $0.isWhitespace })
        let numberText = trimmed.prefix(while: { $0.isNumber || $0 == "." || $0 == "-" || $0 == "+" })
        guard !numberText.isEmpty else { return nil }
        return Double(numberText)
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }
}
