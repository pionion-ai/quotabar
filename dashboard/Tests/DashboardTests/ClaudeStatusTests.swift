import XCTest
@testable import Dashboard

final class ClaudeStatusDecoderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_795_500_000)

    private func json(fiveReset: Int = 1_795_571_999, weekReset: Int = 1_795_600_000,
                      writtenAt: Int = 1_795_499_820) -> Data {
        Data("""
        {"rate_limits":{"five_hour":{"used_percentage":11.5,"resets_at":\(fiveReset)},
                        "seven_day":{"used_percentage":10,"resets_at":\(weekReset)}},
         "written_at":\(writtenAt)}
        """.utf8)
    }

    func testDecodesBothWindows() throws {
        let w = try ClaudeStatusDecoder.windows(from: json(), now: now)
        XCTAssertEqual(w.map(\.key), ["five_hour", "seven_day"])
        XCTAssertEqual(w.map(\.label), ["5-hour", "7-day"])
        XCTAssertEqual(w[0].usedPercent, 11.5)
        XCTAssertEqual(w[0].resetsAt, Date(timeIntervalSince1970: 1_795_571_999))
        XCTAssertEqual(w[1].usedPercent, 10)
    }

    /// Claude Code drops a window once it resets; a stale percentage would lie.
    func testDropsWindowsPastTheirReset() throws {
        let w = try ClaudeStatusDecoder.windows(from: json(fiveReset: 1_795_499_000), now: now)
        XCTAssertEqual(w.map(\.key), ["seven_day"])
    }

    func testEmptyRateLimitsMeansNoWindows() throws {
        XCTAssertEqual(try ClaudeStatusDecoder.windows(from: Data(#"{"rate_limits":{}}"#.utf8), now: now), [])
    }

    func testGarbageThrows() {
        XCTAssertThrowsError(try ClaudeStatusDecoder.windows(from: Data("nope".utf8), now: now))
        XCTAssertThrowsError(try ClaudeStatusDecoder.windows(from: Data("{}".utf8), now: now))
    }

    func testWindowsCarryFreshnessNote() throws {
        let w = try ClaudeStatusDecoder.windows(from: json(writtenAt: 1_795_499_820), now: now)
        XCTAssertEqual(w.first?.note, "updated 3 min ago · updates while Claude Code runs")
    }

    func testFreshnessWording() {
        func f(_ ago: TimeInterval) -> String {
            ClaudeStatusDecoder.freshness(writtenAt: now.addingTimeInterval(-ago), now: now)
        }
        XCTAssertEqual(f(20), "updated just now · updates while Claude Code runs")
        XCTAssertEqual(f(180), "updated 3 min ago · updates while Claude Code runs")
        XCTAssertEqual(f(7_300), "updated 2 h ago · updates while Claude Code runs")
        XCTAssertEqual(f(200_000), "updated 2 d ago · updates while Claude Code runs")
    }
}

final class ClaudeStatusProviderTests: XCTestCase {
    func testMissingFileIsNotConnected() async {
        let p = ClaudeStatusProvider(path: "/nonexistent/claude-status.json", now: Date.init)
        do { _ = try await p.fetch(); XCTFail("expected throw") }
        catch { XCTAssertEqual(error as? FetchError, .notConnected) }
    }

    func testCorruptFileIsDecodeError() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cs-\(UUID()).json")
        try Data("{partial".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        do { _ = try await ClaudeStatusProvider(path: url.path, now: Date.init).fetch(); XCTFail("expected throw") }
        catch { XCTAssertEqual(error as? FetchError, .decode) }
    }

    func testStatusPathUnderHome() {
        XCTAssertEqual(ClaudeStatusProvider.statusPath(home: "/Users/x"), "/Users/x/.quotabar/claude-status.json")
    }
}

final class EmptyStateCopyTests: XCTestCase {
    /// Claude's data arrives with Claude Code activity; "none reported" would
    /// read as broken.
    func testClaudeEmptyStateExplainsWhereDataComesFrom() {
        XCTAssertEqual(ProviderSectionCopy.emptyMessage(provider: "claude"),
                       "Waiting for Claude Code — usage appears after your next message there.")
    }

    func testOtherProvidersKeepGenericEmptyState() {
        XCTAssertEqual(ProviderSectionCopy.emptyMessage(provider: "codex"), "No usage windows reported.")
    }
}
