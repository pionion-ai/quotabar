import Foundation
import ServiceManagement

/// Wraps the macOS 13+ login-item registration for THIS app bundle.
/// Only works for a real signed bundle (no-ops under `swift run`).
enum LoginItem {
    /// True only when running as a bundle (has a bundle id); SMAppService traps otherwise.
    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    static var isEnabled: Bool {
        guard isAvailable else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    /// Register/unregister the app as a login item. Throws on failure.
    static func setEnabled(_ enabled: Bool) throws {
        guard isAvailable else { return }
        if enabled {
            if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
        } else {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
        }
    }
}
