import XCTest
@testable import Dashboard

final class UsageClientTests: XCTestCase {
    private let okJSON = """
    {"five_hour": {"utilization": 8.0, "resets_at": "2026-06-28T18:00:00+00:00"}}
    """.data(using: .utf8)!

    private func response(_ code: Int) -> URLResponse {
        HTTPURLResponse(url: URL(string: "https://api.anthropic.com")!,
                        statusCode: code, httpVersion: nil, headerFields: nil)!
    }

    func testFetchReturnsWindowsOn200() async throws {
        let client = UsageClient(tokenReader: { "tok" },
                                 transport: { _ in (self.okJSON, self.response(200)) })
        let windows = try await client.fetch()
        XCTAssertEqual(windows.map(\.key), ["five_hour"])
    }

    func testSendsBearerAndBetaHeaders() async throws {
        let client = UsageClient(tokenReader: { "secret-token" }) { req in
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
            XCTAssertEqual(req.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
            XCTAssertEqual(req.value(forHTTPHeaderField: "User-Agent"), UsageClient.userAgent)
            XCTAssertTrue(UsageClient.userAgent.hasPrefix("claude-code/"))
            return (self.okJSON, self.response(200))
        }
        _ = try await client.fetch()
    }

    func testMaps401ToAuthExpired() async {
        let client = UsageClient(tokenReader: { "tok" },
                                 transport: { _ in (Data(), self.response(401)) })
        await assert(client, throws: .authExpired)
    }

    func testTokenReaderFailureIsNotLoggedIn() async {
        struct Boom: Error {}
        let client = UsageClient(tokenReader: { throw Boom() },
                                 transport: { _ in (self.okJSON, self.response(200)) })
        await assert(client, throws: .notLoggedIn)
    }

    func testTransportThrowingIsNetworkError() async {
        struct Boom: Error {}
        let client = UsageClient(tokenReader: { "tok" },
                                 transport: { _ in throw Boom() })
        do { _ = try await client.fetch(); XCTFail("expected throw") }
        catch let e as FetchError {
            guard case .network = e else { return XCTFail("expected .network, got \(e)") }
        } catch { XCTFail("wrong error \(error)") }
    }

    func testMaps429ToRateLimited() async {
        let client = UsageClient(tokenReader: { "tok" },
                                 transport: { _ in (Data(), self.response(429)) })
        await assert(client, throws: .rateLimited)
    }

    func testHTTP500IsNetworkNotAuthExpired() async {
        let client = UsageClient(tokenReader: { "tok" },
                                 transport: { _ in (Data(), self.response(500)) })
        do { _ = try await client.fetch(); XCTFail("expected throw") }
        catch let e as FetchError {
            guard case .network = e else { return XCTFail("expected .network, got \(e)") }
        } catch { XCTFail("wrong error \(error)") }
    }

    func testUndecodableBodyIsDecodeError() async {
        let client = UsageClient(tokenReader: { "tok" },
                                 transport: { _ in (Data("not json".utf8), self.response(200)) })
        await assert(client, throws: .decode)
    }

    private func assert(_ client: UsageClient, throws expected: FetchError,
                        file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await client.fetch(); XCTFail("expected throw", file: file, line: line) }
        catch let e as FetchError { XCTAssertEqual(e, expected, file: file, line: line) }
        catch { XCTFail("wrong error \(error)", file: file, line: line) }
    }
}

// MARK: - Credentials parsing + Keychain status mapping

final class ClaudeCredentialsTests: XCTestCase {
    func testParsesClaudeCredentials() throws {
        let json = #"{"claudeAiOauth":{"accessToken":"abc","refreshToken":"r","expiresAt":1}}"#
        XCTAssertEqual(try UsageClient.token(fromCredentials: Data(json.utf8)), "abc")
    }

    /// API-key users have a credentials item without `claudeAiOauth`.
    func testCredentialsWithoutOAuthAreNotLoggedIn() {
        for body in [#"{"mcpOAuth":{}}"#, "garbage", ""] {
            XCTAssertThrowsError(try UsageClient.token(fromCredentials: Data(body.utf8))) {
                XCTAssertEqual($0 as? FetchError, .notLoggedIn, "body: \(body)")
            }
        }
    }

    /// Missing item, the user clicking Deny, or no UI allowed all read as
    /// "Not signed in." — the popover then offers the login command.
    func testKeychainFailuresAreNotLoggedIn() {
        for s in [errSecItemNotFound, errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed] {
            XCTAssertEqual(UsageClient.keychainError(for: s), .notLoggedIn, "status \(s)")
        }
    }
}
