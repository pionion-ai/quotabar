import Foundation

/// Whether the first-run welcome screen has been acknowledged. Stored as a
/// version so a material change to what the app reads can show it again.
enum WelcomeState {
    static let currentVersion = 3  // v3: Claude via status line, no Keychain
    private static let key = "welcomeSeenVersion"

    static func hasSeen(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.integer(forKey: key) >= currentVersion
    }

    static func markSeen(_ defaults: UserDefaults = .standard) {
        defaults.set(currentVersion, forKey: key)
    }
}

/// Holds back everything that reads credentials or raises a system prompt
/// (logins, notifications) until the user has read the welcome screen.
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
            Claude Code: QuotaBar never reads your Claude login. You connect \
            Claude Code once, and QuotaBar adds a small status line to it that \
            saves only your usage limits (5-hour and weekly %) to ~/.quotabar \
            each time Claude Code updates — so the numbers refresh while Claude \
            Code is running.
            """
        let others = appStore
            ? """
              Codex: QuotaBar reads the Codex CLI’s saved login \
              (~/.codex/auth.json) and uses it only to ask OpenAI for your usage.
              """
            : """
              Codex, Gemini and Cursor: QuotaBar reads each tool’s saved login \
              (~/.codex/auth.json, ~/.gemini/oauth_creds.json, the Cursor app’s \
              settings database) and uses it only to ask that provider for your usage.
              """

        return WelcomeContent(
            title: "Welcome to QuotaBar",
            subtitle: subtitle,
            passwordHeading: "How QuotaBar gets your numbers",
            passwordBody: claude + "\n\n" + others,
            usageHeading: "How your data is used",
            usageBullets: [
                "Read-only: QuotaBar never changes, copies, or stores a login.",
                "Each login is sent only to its own provider, to fetch your usage. No servers of ours, no analytics.",
                "macOS will also ask whether QuotaBar may send notifications — used only for limit alerts.",
            ])
    }
}
