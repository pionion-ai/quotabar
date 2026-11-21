import Foundation

/// Whether the first-run welcome screen has been acknowledged. Stored as a
/// version so a material change to what the app reads can show it again.
enum WelcomeState {
    static let currentVersion = 2  // v2: Keychain read no longer prompts
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

        let claude = """
            Claude Code: QuotaBar reads the login the Claude CLI saved in your \
            Keychain, through macOS’s built-in “security” tool — the same tool the \
            CLI saves it with — so no password is needed. If macOS ever does ask, \
            choose “Always Allow” so it doesn’t ask again.
            """
        let others = appStore
            ? "Codex: read from ~/.codex/auth.json."
            : "Codex: ~/.codex/auth.json · Gemini: ~/.gemini/oauth_creds.json · Cursor: the Cursor app’s settings database."

        return WelcomeContent(
            title: "Welcome to QuotaBar",
            subtitle: subtitle,
            passwordHeading: "How QuotaBar reads your logins",
            passwordBody: claude + "\n\n" + others,
            usageHeading: "How your logins are used",
            usageBullets: [
                "Read-only: never changed, copied, or stored by QuotaBar.",
                "Each login is sent only to its own provider, to fetch your usage. No servers of ours, no analytics.",
                "macOS will also ask whether QuotaBar may send notifications — used only for limit alerts.",
            ] + (appStore
                 // Only the App Store build pauses after a Keychain Deny (UsageStore.retry).
                 ? ["If macOS asks and you click Deny, you can allow access later from the menu."]
                 : []))
    }
}
