import Foundation
import ServiceManagement

enum LaunchAtLogin {
    private static let decidedKey = "launchAtLoginDecided"

    static var hasUserDecision: Bool {
        get { UserDefaults.standard.bool(forKey: decidedKey) }
        set { UserDefaults.standard.set(newValue, forKey: decidedKey) }
    }

    static func shouldRegister(status: SMAppService.Status, decided: Bool) -> Bool {
        guard !decided else { return false }
        return status == .notRegistered
    }
}
