import Foundation

/// What to show a user whose provider session has died: a sentence, a button
/// label, and the shell command that fixes it.
struct ReloginPrompt: Equatable {
    let message: String
    let buttonTitle: String
    let command: String
}

/// PURE decisions about auth failures. The dashboard never refreshes tokens
/// itself — the owning CLI does — so recovery is always "go run this command".
enum AuthRecovery {

    /// The CLI that owns each provider's credentials. An unknown id yields nil
    /// so we fail closed rather than suggest the wrong tool.
    private static func cli(for provider: String) -> (name: String, command: String)? {
        switch provider {
        case "claude": return ("Claude Code", "claude")
        case "codex":  return ("Codex", "codex login")
        case "gemini": return ("Gemini", "gemini")
        default:       return nil
        }
    }

    /// Gemini mints its own access tokens on every fetch, so a failure there
    /// means the long-lived refresh token died — worded differently on purpose.
    private static func message(for error: FetchError, provider: String) -> String? {
        switch (error, provider) {
        case (.authExpired, "gemini"), (.notLoggedIn, "gemini"): return "Sign-in expired."
        case (.authExpired, _): return "Session expired."
        case (.notLoggedIn, _): return "Not signed in."
        default: return nil
        }
    }

    /// Non-nil only for failures the user can fix by re-running a CLI.
    static func prompt(for error: FetchError, provider: String) -> ReloginPrompt? {
        guard let cli = cli(for: provider),
              let message = message(for: error, provider: provider) else { return nil }
        return ReloginPrompt(message: message,
                             buttonTitle: "Re-login to \(cli.name)…",
                             command: cli.command)
    }

    /// The quiet hint under still-visible gauges after a failed refresh. Auth
    /// failures say so; everything else keeps the pre-existing wording.
    static func staleMessage(for error: FetchError, provider: String) -> String {
        if let prompt = prompt(for: error, provider: provider) {
            // "Session expired." → "Session expired — numbers may be stale"
            let stem = prompt.message.hasSuffix(".") ? String(prompt.message.dropLast()) : prompt.message
            return "\(stem) — numbers may be stale"
        }
        switch error {
        case .rateLimited: return "Rate limited — retrying soon"
        default:           return "Couldn't refresh — showing last update"
        }
    }
}
