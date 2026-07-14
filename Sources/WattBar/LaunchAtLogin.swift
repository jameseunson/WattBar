import Foundation
import ServiceManagement

@MainActor
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Throws when the registration fails, most commonly because the login
    /// item needs approval in System Settings. The caller has to surface that:
    /// swallowing it leaves the toggle showing a state that isn't real.
    static func set(enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    private static let didAutoRegisterKey = "didAutoRegisterLoginItem"

    /// Registers on first launch so the app starts at login by default.
    /// Attempted once ever (not keyed off SMAppService status, which reports
    /// inconsistent states for never-registered apps), so turning the login
    /// item off afterwards — via the panel toggle or System Settings — is
    /// respected on later launches.
    static func registerIfNeeded() {
        guard Bundle.main.bundlePath.hasSuffix(".app"),
              !UserDefaults.standard.bool(forKey: didAutoRegisterKey)
        else { return }
        UserDefaults.standard.set(true, forKey: didAutoRegisterKey)
        guard !isEnabled else { return }
        do {
            try set(enabled: true)
        } catch {
            // Nothing to surface this to at launch; the panel's toggle shows
            // the real state when it opens.
            NSLog("LaunchAtLogin: %@", error.localizedDescription)
        }
    }
}
