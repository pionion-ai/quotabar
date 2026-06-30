import XCTest
@testable import Dashboard

final class GeminiUsageTests: XCTestCase {

    // MARK: - Decoder

    /// Golden fixture captured from the real `v1internal:retrieveUserQuota`
    /// payload (sanitized). Loaded from disk via `#filePath` so the parser is
    /// exercised against a real-shaped body, not invented JSON.
    func testDecodesRealFixture() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/gemini-quota-real.json")
        let data = try Data(contentsOf: url)
        let windows = try GeminiUsageDecoder.windows(from: data)

        XCTAssertEqual(windows.map(\.key), ["gemini_pro", "gemini_flash"])
        XCTAssertEqual(windows[0].label, "Pro")
        XCTAssertEqual(windows[1].label, "Flash")
        XCTAssertEqual(windows[0].usedPercent, 0.0, accuracy: 0.001)
        XCTAssertEqual(windows[1].usedPercent, 0.0, accuracy: 0.001)

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let expected = iso.date(from: "2026-07-01T09:24:28Z")
        XCTAssertEqual(windows[0].resetsAt, expected)
        XCTAssertEqual(windows[1].resetsAt, expected)
    }

    func testPicksTightestPerFamily() throws {
        let data = """
        {"buckets": [
          {"modelId": "gemini-2.5-pro",        "remainingFraction": 0.8, "resetTime": "2026-07-01T09:24:28Z"},
          {"modelId": "gemini-3.1-pro",        "remainingFraction": 0.5, "resetTime": "2026-07-01T09:24:28Z"},
          {"modelId": "gemini-2.5-flash",      "remainingFraction": 0.9, "resetTime": "2026-07-01T09:24:28Z"},
          {"modelId": "gemini-2.5-flash-lite", "remainingFraction": 0.2, "resetTime": "2026-07-01T09:24:28Z"}
        ]}
        """.data(using: .utf8)!
        let windows = try GeminiUsageDecoder.windows(from: data)

        XCTAssertEqual(windows.map(\.key), ["gemini_pro", "gemini_flash"])
        // Tightest = lowest remaining: pro 0.5 → 50% used; flash 0.2 → 80% used.
        XCTAssertEqual(windows[0].usedPercent, 50, accuracy: 0.001)
        XCTAssertEqual(windows[1].usedPercent, 80, accuracy: 0.001)
    }

    func testThrowsOnGarbage() {
        XCTAssertThrowsError(try GeminiUsageDecoder.windows(from: Data("not json".utf8)))
    }

    // MARK: - Client

    private let refreshJSON = """
    {"access_token": "fresh-token-123", "expires_in": 3599, "token_type": "Bearer"}
    """.data(using: .utf8)!

    private let quotaJSON = """
    {"buckets": [
      {"modelId": "gemini-2.5-pro",   "remainingFraction": 1, "resetTime": "2026-07-01T09:24:28Z"},
      {"modelId": "gemini-2.5-flash", "remainingFraction": 1, "resetTime": "2026-07-01T09:24:28Z"}
    ]}
    """.data(using: .utf8)!

    private func response(_ url: URL, _ code: Int) -> URLResponse {
        HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!
    }

    private func isTokenURL(_ req: URLRequest) -> Bool {
        req.url == GeminiUsageClient.tokenEndpoint
    }

    func testRefreshThenQuotaReturnsWindows() async throws {
        let client = GeminiUsageClient(credsReader: { ("rt", "proj-1") }) { req in
            if self.isTokenURL(req) {
                return (self.refreshJSON, self.response(req.url!, 200))
            }
            return (self.quotaJSON, self.response(req.url!, 200))
        }
        let windows = try await client.fetch()
        XCTAssertEqual(windows.map(\.key), ["gemini_pro", "gemini_flash"])
    }

    func testQuotaCarriesRefreshedBearer() async throws {
        let client = GeminiUsageClient(credsReader: { ("rt", "proj-1") }) { req in
            if self.isTokenURL(req) {
                return (self.refreshJSON, self.response(req.url!, 200))
            }
            // The quota request must carry the access_token from the refresh response.
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer fresh-token-123")
            return (self.quotaJSON, self.response(req.url!, 200))
        }
        _ = try await client.fetch()
    }

    func testRefreshFailureIsNotLoggedIn() async {
        let client = GeminiUsageClient(credsReader: { ("rt", "proj-1") }) { req in
            if self.isTokenURL(req) {
                return (Data(), self.response(req.url!, 400))
            }
            return (self.quotaJSON, self.response(req.url!, 200))
        }
        await assert(client, throws: .notLoggedIn)
    }

    func testQuota429IsRateLimited() async {
        let client = GeminiUsageClient(credsReader: { ("rt", "proj-1") }) { req in
            if self.isTokenURL(req) {
                return (self.refreshJSON, self.response(req.url!, 200))
            }
            return (Data(), self.response(req.url!, 429))
        }
        await assert(client, throws: .rateLimited)
    }

    func testCredsReaderFailureIsNotLoggedIn() async {
        struct Boom: Error {}
        let client = GeminiUsageClient(credsReader: { throw Boom() }) { req in
            (self.refreshJSON, self.response(req.url!, 200))
        }
        await assert(client, throws: .notLoggedIn)
    }

    private func assert(_ client: GeminiUsageClient, throws expected: FetchError,
                        file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await client.fetch(); XCTFail("expected throw", file: file, line: line) }
        catch let e as FetchError { XCTAssertEqual(e, expected, file: file, line: line) }
        catch { XCTFail("wrong error \(error)", file: file, line: line) }
    }
}
