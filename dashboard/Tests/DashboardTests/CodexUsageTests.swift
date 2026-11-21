import XCTest
@testable import Dashboard

final class CodexUsageTests: XCTestCase {

    // MARK: - Decoder

    /// Golden fixture captured from the real `/backend-api/wham/usage` payload
    /// (sanitized). Loaded from disk via `#filePath` so the parser is exercised
    /// against a real-shaped body, not invented JSON.
    func testDecodesRealFixture() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/codex-usage-real.json")
        let data = try Data(contentsOf: url)
        let windows = try CodexUsageDecoder.windows(from: data)
        XCTAssertEqual(windows.map(\.key), ["codex_primary", "codex_secondary"])
        XCTAssertEqual(windows[0].label, "5-hour")
        XCTAssertEqual(windows[0].usedPercent, 1.0, accuracy: 0.001)
        XCTAssertEqual(windows[1].label, "7-day")
        XCTAssertEqual(windows[1].usedPercent, 0.0, accuracy: 0.001)
        XCTAssertEqual(windows[0].resetsAt, Date(timeIntervalSince1970: 1782677869))
        XCTAssertEqual(windows[1].resetsAt, Date(timeIntervalSince1970: 1783264669))
    }

    func testSkipsWindowMissingUsedPercent() throws {
        let data = """
        {"rate_limit": {
           "primary_window":   {"limit_window_seconds": 18000, "reset_at": 1782677869},
           "secondary_window": {"used_percent": 0, "limit_window_seconds": 604800, "reset_at": 1783264669}
        }}
        """.data(using: .utf8)!
        let windows = try CodexUsageDecoder.windows(from: data)
        XCTAssertEqual(windows.map(\.key), ["codex_secondary"])  // primary lacks used_percent
    }

    func testSkipsWindowMissingResetAt() throws {
        let data = """
        {"rate_limit": {
           "primary_window":   {"used_percent": 1, "limit_window_seconds": 18000},
           "secondary_window": {"used_percent": 0, "limit_window_seconds": 604800, "reset_at": 1783264669}
        }}
        """.data(using: .utf8)!
        let windows = try CodexUsageDecoder.windows(from: data)
        XCTAssertEqual(windows.map(\.key), ["codex_secondary"])  // primary lacks reset_at
    }

    func testThrowsOnGarbage() {
        XCTAssertThrowsError(try CodexUsageDecoder.windows(from: Data("not json".utf8)))
    }

    // MARK: - Client

    private let okJSON = """
    {"rate_limit": {
       "primary_window":   {"used_percent": 1, "limit_window_seconds": 18000,  "reset_at": 1782677869},
       "secondary_window": {"used_percent": 0, "limit_window_seconds": 604800, "reset_at": 1783264669}
    }}
    """.data(using: .utf8)!

    private func response(_ code: Int) -> URLResponse {
        HTTPURLResponse(url: URL(string: "https://chatgpt.com")!,
                        statusCode: code, httpVersion: nil, headerFields: nil)!
    }

    func testFetchReturnsWindowsOn200() async throws {
        let client = CodexUsageClient(authReader: { ("tok", "acct") },
                                      transport: { _ in (self.okJSON, self.response(200)) })
        let windows = try await client.fetch()
        XCTAssertEqual(windows.map(\.key), ["codex_primary", "codex_secondary"])
    }

    func testSendsAuthAccountAndUserAgentHeaders() async throws {
        let client = CodexUsageClient(authReader: { ("secret-token", "acct-123") }) { req in
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
            XCTAssertEqual(req.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "acct-123")
            XCTAssertEqual(req.value(forHTTPHeaderField: "User-Agent"), CodexUsageClient.userAgent)
            XCTAssertTrue(CodexUsageClient.userAgent.hasPrefix("codex_cli_rs/"))
            return (self.okJSON, self.response(200))
        }
        _ = try await client.fetch()
    }

    func testMaps401ToAuthExpired() async {
        let client = CodexUsageClient(authReader: { ("tok", "acct") },
                                      transport: { _ in (Data(), self.response(401)) })
        await assert(client, throws: .authExpired)
    }

    func testMaps429ToRateLimited() async {
        let client = CodexUsageClient(authReader: { ("tok", "acct") },
                                      transport: { _ in (Data(), self.response(429)) })
        await assert(client, throws: .rateLimited)
    }

    func testAuthReaderFailureIsNotLoggedIn() async {
        struct Boom: Error {}
        let client = CodexUsageClient(authReader: { throw Boom() },
                                      transport: { _ in (self.okJSON, self.response(200)) })
        await assert(client, throws: .notLoggedIn)
    }

    private func assert(_ client: CodexUsageClient, throws expected: FetchError,
                        file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await client.fetch(); XCTFail("expected throw", file: file, line: line) }
        catch let e as FetchError { XCTAssertEqual(e, expected, file: file, line: line) }
        catch { XCTFail("wrong error \(error)", file: file, line: line) }
    }
}

final class CodexPathTests: XCTestCase {
    func testAuthPathUnderGivenHome() {
        XCTAssertEqual(CodexUsageClient.authPath(home: "/Users/x"), "/Users/x/.codex/auth.json")
    }

    /// In the sandbox NSHomeDirectory() is the app container; ~/.codex must
    /// still resolve to the user's real home.
    func testRealHomeIsNotASandboxContainer() {
        let home = CodexUsageClient.realHomeDirectory()
        XCTAssertFalse(home.contains("/Library/Containers/"))
        XCTAssertTrue(home.hasPrefix("/"))
    }
}
