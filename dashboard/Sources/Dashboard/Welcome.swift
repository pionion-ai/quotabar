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

/// The words on the first-run screen. Pure, so each flavor's copy is tested.
struct WelcomeContent: Equatable {
    let title: String
    let subtitle: String
    let passwordHeading: String
    let passwordBody: String
    let usageHeading: String
    let usageBullets: [String]

    static func make(appStore: Bool) -> WelcomeContent {
        let subtitle = appStore
            ? "Your Claude Code and Codex usage limits, live in the menu bar — look for ◔."
            : "Your Claude Code, Codex, Gemini and Cursor usage limits, live in the menu bar — look for ◔."

        let password = appStore
            ? """
              QuotaBar reads the login the Claude Code CLI saved in your Keychain. \
              macOS asks you to approve that: enter your Mac password and choose \
              “Always Allow” so it doesn’t ask again. Codex’s login is read from \
              ~/.codex/auth.json — no prompt needed.
              """
            : """
              QuotaBar reads the login the Claude Code CLI saved in your Keychain \
              (through macOS’s “security” tool). macOS asks you to approve that: \
              enter your Mac password and choose “Always Allow” so it doesn’t ask \
              again. Other logins are read from their own files: Codex \
              ~/.codex/auth.json, Gemini ~/.gemini/oauth_creds.json, Cursor the \
              Cursor app’s settings database.
              """

        return WelcomeContent(
            title: "Welcome to QuotaBar",
            subtitle: subtitle,
            passwordHeading: "Next, macOS will ask for your password",
            passwordBody: password,
            usageHeading: "How your logins are used",
            usageBullets: [
                "Read-only: never changed, copied, or stored by QuotaBar.",
                "Each login is sent only to its own provider, to fetch your usage. No servers of ours, no analytics.",
            ] + (appStore
                 // Only the App Store build pauses after a Keychain Deny (UsageStore.retry).
                 ? ["Clicking Deny is fine — you can allow access later from the menu."]
                 : []))
    }
}
