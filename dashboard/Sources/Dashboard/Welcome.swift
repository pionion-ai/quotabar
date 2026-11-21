import Foundation

/// Whether the first-run welcome screen has been acknowledged. Stored as a
/// version so a material change to what the app reads can show it again.
enum WelcomeState {
    static let currentVersion = 1
    private static let key = "welcomeSeenVersion"

    static func hasSeen(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.integer(forKey: key) >= currentVersion
    }

    static func markSeen(_ defaults: UserDefaults = .standard) {
        defaults.set(currentVersion, forKey: key)
    }
}

/// Holds back everything that reads credentials or raises a system prompt
/// (Keychain, notifications) until the user has read the welcome screen.
final class LaunchGate {
    private let hasSeen: Bool
    private let start: () -> Void
    private let showWelcome: () -> Void
    private let markSeen: () -> Void
    private var started = false

    init(hasSeen: Bool, start: @escaping () -> Void,
         showWelcome: @escaping () -> Void, markSeen: @escaping () -> Void) {
        self.hasSeen = hasSeen
        self.start = start
        self.showWelcome = showWelcome
        self.markSeen = markSeen
    }

    func launch() {
        if hasSeen { startOnce() } else { showWelcome() }
    }

    /// The user pressed Continue.
    func confirm() {
        guard !started else { return }
        markSeen()
        startOnce()
    }

    private func startOnce() {
        guard !started else { return }
        started = true
        start()
    }
}
