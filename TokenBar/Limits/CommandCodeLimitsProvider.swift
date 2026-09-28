import Foundation
import OSLog

struct CommandCodeLimitsProvider: LimitsProvider {
    let source: AppSource = .commandCode

    enum Endpoint {
        static let base = URL(string: "https://api.commandcode.ai")!
    }

    static var defaultAuthURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".commandcode/auth.json")
    }

    private static let log = Logger(subsystem: "io.github.jhosgun.tokenbar", category: "command-code-limits")

    private let authURL: URL
    private let session: URLSession
    private let baseURL: URL

    init(authURL: URL = CommandCodeLimitsProvider.defaultAuthURL,
         session: URLSession = .shared,
         baseURL: URL = Endpoint.base) {
        self.authURL = authURL
        self.session = session
        self.baseURL = baseURL
    }

    func fetch() async -> LimitsSnapshot {
        guard let apiKey = Self.apiKey(at: authURL) else {
            return .empty(source, .notConfigured)
        }

        do {
            let clock = ContinuousClock()
            let deadline = clock.now + .seconds(5)
            let whoami = try await request(path: "/alpha/whoami", query: [
                URLQueryItem(name: "limits", value: "1")
            ], apiKey: apiKey, clock: clock, deadline: deadline)
            guard let organization = Self.organization(from: whoami) else {
                return .empty(source, .failed("Respuesta no reconocida"))
            }
            let organizationQuery = organization.query

            async let creditsRequest = request(path: "/alpha/billing/credits",
                                               query: organizationQuery,
                                               apiKey: apiKey,
                                               clock: clock,
                                               deadline: deadline)
            async let subscriptionsRequest = request(path: "/alpha/billing/subscriptions",
                                                     query: organizationQuery,
                                                     apiKey: apiKey,
                                                     clock: clock,
                                                     deadline: deadline)
            let (creditsData, subscriptionsData) = try await (creditsRequest, subscriptionsRequest)

            guard let subscription = Self.subscription(from: subscriptionsData) else {
                return .empty(source, .failed("Respuesta no reconocida"))
            }
            let summaryData = try await request(path: "/alpha/usage/summary", query:
                organizationQuery + [URLQueryItem(name: "since", value: subscription.currentPeriodStart)],
                apiKey: apiKey,
                clock: clock,
                deadline: deadline)

            guard let snapshot = Self.parse(creditsData: creditsData,
                                            subscriptionsData: subscriptionsData,
                                            summaryData: summaryData) else {
                return .empty(source, .failed("Respuesta no reconocida"))
            }
            return snapshot
        } catch RequestError.invalidCredentials {
            return .empty(source, .invalidCredentials)
        } catch RequestError.http(let status) {
            return .empty(source, .failed("HTTP \(status)"))
        } catch RequestError.invalidURL {
            return .empty(source, .failed("Respuesta no reconocida"))
        } catch {
            Self.log.error("fallo de red: \(error.localizedDescription, privacy: .public)")
            return .empty(source, .failed("Sin conexión"))
        }
    }

    static func apiKey(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = (root["apiKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else { return nil }
        return key
    }

    enum Organization: Equatable {
        case personal
        case organization(String)

        var query: [URLQueryItem] {
            switch self {
            case .personal: []
            case .organization(let id): [URLQueryItem(name: "orgId", value: id)]
            }
        }
    }

    static func organization(from data: Data) -> Organization? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = root["org"] else { return nil }
        if value is NSNull { return .personal }
        guard let org = value as? [String: Any],
              let id = (org["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty else { return nil }
        return .organization(id)
    }

    static func parse(creditsData: Data,
                      subscriptionsData: Data,
                      summaryData: Data) -> LimitsSnapshot? {
        guard let creditsRoot = try? JSONSerialization.jsonObject(with: creditsData) as? [String: Any],
              let credits = creditsRoot["credits"] as? [String: Any],
              let windowLimits = creditsRoot["windowLimits"] as? [String: Any],
              let subscription = subscription(from: subscriptionsData),
              let summary = try? JSONSerialization.jsonObject(with: summaryData) as? [String: Any] else {
            return nil
        }

        var windows: [LimitWindow] = []
        if let window = window(from: windowLimits["fiveHour"], name: "5 horas") {
            windows.append(window)
        }
        if let window = window(from: windowLimits["weekly"], name: "Semanal") {
            windows.append(window)
        }
        // `monthlyCredits` de credits es lo que QUEDA del mes y `totalMonthlyCredits`
        // del summary lo ya usado: el cupo mensual es la suma de ambos.
        if let used = number(summary["totalMonthlyCredits"]), used.isFinite, used >= 0,
           let remaining = number(credits["monthlyCredits"]), remaining.isFinite, remaining >= 0,
           used + remaining > 0 {
            windows.append(LimitWindow(name: "Mes",
                                       utilization: used / (used + remaining),
                                       resetsAt: date(from: subscription.currentPeriodEnd)))
        }
        guard !windows.isEmpty else { return nil }

        let plan = nonemptyString(credits["planId"]) ?? subscription.planID
        let requests = number(summary["totalCount"]).flatMap { value -> Int? in
            guard value.isFinite, value >= 0, value.rounded() == value else { return nil }
            return Int(exactly: value)
        }
        let label = [plan, requests.map { "\($0) req" }]
            .compactMap { $0 }
            .joined(separator: " · ")

        return LimitsSnapshot(source: .commandCode,
                              windows: windows,
                              planLabel: label.isEmpty ? nil : label,
                              status: .ok)
    }

    private struct Subscription {
        let planID: String?
        let currentPeriodStart: String
        let currentPeriodEnd: String?
    }

    private static func subscription(from data: Data) -> Subscription? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["data"] as? [String: Any],
              let start = nonemptyString(payload["currentPeriodStart"]) else { return nil }
        return Subscription(planID: nonemptyString(payload["planId"]),
                            currentPeriodStart: start,
                            currentPeriodEnd: nonemptyString(payload["currentPeriodEnd"]))
    }

    private static func window(from value: Any?, name: String) -> LimitWindow? {
        guard let bucket = value as? [String: Any],
              let used = number(bucket["used"]), used.isFinite, used >= 0,
              let cap = number(bucket["cap"]), cap.isFinite, cap > 0 else { return nil }
        return LimitWindow(name: name,
                           utilization: used / cap,
                           resetsAt: date(from: bucket["resetAt"]))
    }

    private static func nonemptyString(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private static func date(from value: Any?) -> Date? {
        if let timestamp = number(value), timestamp.isFinite, timestamp >= 0 {
            let seconds = timestamp > 10_000_000_000 ? timestamp / 1_000 : timestamp
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

    private enum RequestError: Error {
        case invalidCredentials
        case http(Int)
        case invalidURL
    }

    private func request(path: String,
                         query: [URLQueryItem],
                         apiKey: String,
                         clock: ContinuousClock,
                         deadline: ContinuousClock.Instant) async throws -> Data {
        let remaining = clock.now.duration(to: deadline)
        guard remaining > .zero else { throw URLError(.timedOut) }
        guard var components = URLComponents(url: baseURL.appending(path: path),
                                             resolvingAgainstBaseURL: false) else {
            throw RequestError.invalidURL
        }
        components.queryItems = query
        guard let url = components.url else { throw RequestError.invalidURL }
        var request = URLRequest(url: url)
        let parts = remaining.components
        request.timeoutInterval = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("cli", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200..<300: break
            case 401, 403: throw RequestError.invalidCredentials
            default: throw RequestError.http(http.statusCode)
            }
        }
        return data
    }
}
