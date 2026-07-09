import Foundation
import ServiceManagement

@MainActor
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func set(enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("LaunchAtLogin: %@", error.localizedDescription)
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
        if !isEnabled {
            set(enabled: true)
        }
    }
}
