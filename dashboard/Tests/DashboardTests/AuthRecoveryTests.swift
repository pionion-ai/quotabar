import XCTest
@testable import Dashboard

final class AuthRecoveryTests: XCTestCase {

    // MARK: - Which errors get a button

    func testAuthErrorsProduceAPrompt() {
        for error in [FetchError.authExpired, .notLoggedIn] {
            for provider in ["claude", "codex", "gemini"] {
                XCTAssertNotNil(AuthRecovery.prompt(for: error, provider: provider),
                                "\(error) / \(provider) should offer a re-login")
            }
        }
    }

    func testNonAuthErrorsProduceNoPrompt() {
        for error in [FetchError.rateLimited, .network("offline"), .decode] {
            for provider in ["claude", "codex", "gemini"] {
                XCTAssertNil(AuthRecovery.prompt(for: error, provider: provider),
                             "\(error) / \(provider) is not fixable by re-login")
            }
        }
    }

    func testUnknownProviderFailsClosed() {
        XCTAssertNil(AuthRecovery.prompt(for: .authExpired, provider: "openai"))
        XCTAssertNil(AuthRecovery.prompt(for: .authExpired, provider: ""))
    }

    // MARK: - Commands

    func testCommandPerProvider() {
        XCTAssertEqual(AuthRecovery.prompt(for: .authExpired, provider: "claude")?.command, "claude")
        XCTAssertEqual(AuthRecovery.prompt(for: .authExpired, provider: "codex")?.command, "codex login")
        XCTAssertEqual(AuthRecovery.prompt(for: .authExpired, provider: "gemini")?.command, "gemini")
    }

    func testButtonTitleNamesTheProvider() {
        XCTAssertEqual(AuthRecovery.prompt(for: .authExpired, provider: "claude")?.buttonTitle,
                       "Re-login to Claude Code…")
        XCTAssertEqual(AuthRecovery.prompt(for: .authExpired, provider: "codex")?.buttonTitle,
                       "Re-login to Codex…")
        XCTAssertEqual(AuthRecovery.prompt(for: .authExpired, provider: "gemini")?.buttonTitle,
                       "Re-login to Gemini…")
    }

    // The bug this feature fixes: every provider used to be told to run `claude`.
    func testMessageNeverNamesTheWrongCli() {
        let codex = AuthRecovery.prompt(for: .authExpired, provider: "codex")!
        XCTAssertFalse(codex.message.contains("claude"))
        XCTAssertFalse(codex.buttonTitle.contains("Claude"))
    }

    func testExpiredAndNotLoggedInReadDifferently() {
        let expired = AuthRecovery.prompt(for: .authExpired, provider: "claude")!
        let missing = AuthRecovery.prompt(for: .notLoggedIn, provider: "claude")!
        XCTAssertEqual(expired.message, "Session expired.")
        XCTAssertEqual(missing.message, "Not signed in.")
        XCTAssertEqual(expired.command, missing.command)
    }

    // Gemini self-refreshes, so a failure there means the refresh token itself died.
    func testGeminiMessageIsWordedForItsCase() {
        let gemini = AuthRecovery.prompt(for: .notLoggedIn, provider: "gemini")!
        XCTAssertEqual(gemini.message, "Sign-in expired.")
    }

    // MARK: - Stale hint

    func testStaleMessageForNonAuthErrorsIsUnchanged() {
        XCTAssertEqual(AuthRecovery.staleMessage(for: .rateLimited, provider: "claude"),
                       "Rate limited — retrying soon")
        XCTAssertEqual(AuthRecovery.staleMessage(for: .network("x"), provider: "claude"),
                       "Couldn't refresh — showing last update")
        XCTAssertEqual(AuthRecovery.staleMessage(for: .decode, provider: "claude"),
                       "Couldn't refresh — showing last update")
    }

    func testStaleMessageForAuthErrorsSaysSo() {
        XCTAssertEqual(AuthRecovery.staleMessage(for: .authExpired, provider: "codex"),
                       "Session expired — numbers may be stale")
        XCTAssertEqual(AuthRecovery.staleMessage(for: .notLoggedIn, provider: "gemini"),
                       "Sign-in expired — numbers may be stale")
    }

    func testStaleMessageForUnknownProviderFallsBackToGenericText() {
        XCTAssertEqual(AuthRecovery.staleMessage(for: .authExpired, provider: "openai"),
                       "Couldn't refresh — showing last update")
    }
}
