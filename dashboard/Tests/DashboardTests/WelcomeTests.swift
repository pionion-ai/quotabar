import XCTest
@testable import Dashboard

final class WelcomeStateTests: XCTestCase {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "test-\(UUID().uuidString)")! }

    func testFreshInstallHasNotSeenWelcome() {
        XCTAssertFalse(WelcomeState.hasSeen(defaults()))
    }

    func testMarkSeenPersists() {
        let d = defaults()
        WelcomeState.markSeen(d)
        XCTAssertTrue(WelcomeState.hasSeen(d))
    }

    /// Bumping `currentVersion` re-shows the screen after a copy change.
    func testOlderSeenVersionShowsAgain() {
        let d = defaults()
        d.set(0, forKey: "welcomeSeenVersion")
        XCTAssertFalse(WelcomeState.hasSeen(d))
    }
}

final class LaunchGateTests: XCTestCase {
    private var starts = 0, shows = 0, marks = 0
    private func gate(hasSeen: Bool) -> LaunchGate {
        LaunchGate(hasSeen: hasSeen,
                   start: { self.starts += 1 },
                   showWelcome: { self.shows += 1 },
                   markSeen: { self.marks += 1 })
    }

    /// First launch: explain first — nothing that reads credentials yet.
    func testFirstLaunchShowsWelcomeAndDoesNotStart() {
        let g = gate(hasSeen: false)
        g.launch()
        XCTAssertEqual(shows, 1)
        XCTAssertEqual(starts, 0)
    }

    func testConfirmMarksSeenAndStartsOnce() {
        let g = gate(hasSeen: false)
        g.launch()
        g.confirm()
        g.confirm()
        XCTAssertEqual(marks, 1)
        XCTAssertEqual(starts, 1)
    }

    func testLaterLaunchStartsImmediately() {
        let g = gate(hasSeen: true)
        g.launch()
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(shows, 0)
    }

    /// Reopened from the footer after start: confirming must not start twice.
    func testConfirmAfterSeenLaunchDoesNotRestart() {
        let g = gate(hasSeen: true)
        g.launch()
        g.confirm()
        XCTAssertEqual(starts, 1)
    }
}

final class WelcomeContentTests: XCTestCase {
    private func allText(_ c: WelcomeContent) -> String {
        ([c.title, c.subtitle, c.passwordHeading, c.passwordBody, c.usageHeading] + c.usageBullets)
            .joined(separator: "\n")
    }

    func testTitle() {
        XCTAssertEqual(WelcomeContent.make(appStore: true).title, "Welcome to QuotaBar")
    }

    func testAppStoreCopyNamesOnlyItsProviders() {
        let text = allText(.make(appStore: true))
        for s in ["Claude Code", "Codex", "Always Allow", "~/.codex/auth.json", "password"] {
            XCTAssertTrue(text.contains(s), "missing \(s)")
        }
        for s in ["Gemini", "Cursor"] { XCTAssertFalse(text.contains(s), "should not mention \(s)") }
    }

    func testDirectCopyNamesAllProviders() {
        let text = allText(.make(appStore: false))
        for s in ["Claude Code", "Codex", "Gemini", "Cursor", "Always Allow"] {
            XCTAssertTrue(text.contains(s), "missing \(s)")
        }
        // The direct build re-prompts after Deny (via `security`), so it can't promise this.
        XCTAssertFalse(text.contains("Deny is fine"))
    }

    func testUsageBulletsStateThePromises() {
        let bullets = WelcomeContent.make(appStore: true).usageBullets.joined(separator: "\n")
        for s in ["Read-only", "only to its own provider", "Deny"] {
            XCTAssertTrue(bullets.contains(s), "missing \(s)")
        }
    }
}
