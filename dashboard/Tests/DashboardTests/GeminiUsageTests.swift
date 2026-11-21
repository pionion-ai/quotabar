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

    /// A bare "HTTP 403" is undiagnosable: name the failing call and carry
    /// Google's own error message.
    func testHTTPErrorNamesCallAndGoogleMessage() async {
        let body = #"{"error":{"code":500,"message":"Internal error encountered.","status":"INTERNAL"}}"#
        let client = GeminiUsageClient(credsReader: { ("rt", "proj-1") }) { req in
            if self.isTokenURL(req) { return (self.refreshJSON, self.response(req.url!, 200)) }
            return (Data(body.utf8), self.response(req.url!, 500))
        }
        await assert(client, throws: .network("HTTP 500 (retrieveUserQuota): Internal error encountered."))
    }

    func testHTTPErrorWithoutBodyStillNamesCall() async {
        let client = GeminiUsageClient(credsReader: { ("rt", "") }) { req in
            if self.isTokenURL(req) { return (self.refreshJSON, self.response(req.url!, 200)) }
            return (Data(), self.response(req.url!, 500))
        }
        await assert(client, throws: .network("HTTP 500 (loadCodeAssist)"))
    }

    /// Real 2026-09 response for a free-tier account: Google has retired the
    /// gemini CLI for "Code Assist for individuals". Permanent, not an outage.
    func testRetiredFreeTierIsUnsupported() async {
        let body = """
        {"ineligibleTiers":[{"reasonCode":"UNSUPPORTED_CLIENT","reasonMessage":"This client is no longer supported for Gemini Code Assist for individuals.","tierId":"free-tier"}]}
        """
        var quotaCalled = false
        let client = GeminiUsageClient(credsReader: { ("rt", "") }) { req in
            if self.isTokenURL(req) { return (self.refreshJSON, self.response(req.url!, 200)) }
            if self.isLoadCodeAssist(req) { return (Data(body.utf8), self.response(req.url!, 200)) }
            quotaCalled = true
            return (self.quotaJSON, self.response(req.url!, 200))
        }
        await assert(client, throws: .unsupported("This client is no longer supported for Gemini Code Assist for individuals."))
        XCTAssertFalse(quotaCalled)
    }

    /// The quota endpoint's own refusal for the same account: a 403 means the
    /// account isn't entitled — retrying every minute won't change that.
    func testQuota403IsUnsupported() async {
        let body = #"{"error":{"code":403,"message":"You do not have a valid license of this product.","status":"PERMISSION_DENIED"}}"#
        let client = GeminiUsageClient(credsReader: { ("rt", "proj-1") }) { req in
            if self.isTokenURL(req) { return (self.refreshJSON, self.response(req.url!, 200)) }
            return (Data(body.utf8), self.response(req.url!, 403))
        }
        await assert(client, throws: .unsupported("HTTP 403 (retrieveUserQuota): You do not have a valid license of this product."))
    }

    // MARK: - Project resolution

    private func isLoadCodeAssist(_ req: URLRequest) -> Bool {
        req.url == GeminiUsageClient.loadCodeAssistEndpoint
    }

    private func project(in req: URLRequest) -> String? {
        guard let body = req.httpBody,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        return json["project"] as? String
    }

    /// With no project configured, ask the server which Code Assist project the
    /// account uses (as the gemini CLI does) and query quota for that one.
    func testResolvesProjectViaLoadCodeAssist() async throws {
        var quotaProject: String?
        let client = GeminiUsageClient(credsReader: { ("rt", "") }) { req in
            if self.isTokenURL(req) { return (self.refreshJSON, self.response(req.url!, 200)) }
            if self.isLoadCodeAssist(req) {
                XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer fresh-token-123")
                let body = #"{"currentTier":{"id":"free-tier"},"cloudaicompanionProject":"real-proj-42"}"#
                return (Data(body.utf8), self.response(req.url!, 200))
            }
            quotaProject = self.project(in: req)
            return (self.quotaJSON, self.response(req.url!, 200))
        }
        _ = try await client.fetch()
        XCTAssertEqual(quotaProject, "real-proj-42")
    }

    func testLoadCodeAssistProjectObjectForm() async throws {
        var quotaProject: String?
        let client = GeminiUsageClient(credsReader: { ("rt", "") }) { req in
            if self.isTokenURL(req) { return (self.refreshJSON, self.response(req.url!, 200)) }
            if self.isLoadCodeAssist(req) {
                return (Data(#"{"cloudaicompanionProject":{"id":"obj-proj","name":"x"}}"#.utf8),
                        self.response(req.url!, 200))
            }
            quotaProject = self.project(in: req)
            return (self.quotaJSON, self.response(req.url!, 200))
        }
        _ = try await client.fetch()
        XCTAssertEqual(quotaProject, "obj-proj")
    }

    func testConfiguredProjectSkipsLoadCodeAssist() async throws {
        var quotaProject: String?
        let client = GeminiUsageClient(credsReader: { ("rt", "env-proj") }) { req in
            if self.isTokenURL(req) { return (self.refreshJSON, self.response(req.url!, 200)) }
            if self.isLoadCodeAssist(req) { XCTFail("must not call loadCodeAssist") }
            quotaProject = self.project(in: req)
            return (self.quotaJSON, self.response(req.url!, 200))
        }
        _ = try await client.fetch()
        XCTAssertEqual(quotaProject, "env-proj")
    }

    func testLoadCodeAssist401IsAuthExpired() async {
        let client = GeminiUsageClient(credsReader: { ("rt", "") }) { req in
            if self.isTokenURL(req) { return (self.refreshJSON, self.response(req.url!, 200)) }
            if self.isLoadCodeAssist(req) { return (Data(), self.response(req.url!, 401)) }
            return (self.quotaJSON, self.response(req.url!, 200))
        }
        await assert(client, throws: .authExpired)
    }

    /// `~/.gemini/projects.json` maps local folders to short names — never a
    /// Cloud project. Only the env vars the gemini CLI honours count.
    func testConfiguredProjectComesFromEnvOnly() {
        XCTAssertEqual(GeminiUsageClient.configuredProject(env: ["GOOGLE_CLOUD_PROJECT": "p1"]), "p1")
        XCTAssertEqual(GeminiUsageClient.configuredProject(env: ["GOOGLE_CLOUD_PROJECT_ID": "p2"]), "p2")
        XCTAssertEqual(GeminiUsageClient.configuredProject(env: ["GOOGLE_CLOUD_PROJECT": ""]), "")
        XCTAssertEqual(GeminiUsageClient.configuredProject(env: [:]), "")
    }

    private func assert(_ client: GeminiUsageClient, throws expected: FetchError,
                        file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await client.fetch(); XCTFail("expected throw", file: file, line: line) }
        catch let e as FetchError { XCTAssertEqual(e, expected, file: file, line: line) }
        catch { XCTFail("wrong error \(error)", file: file, line: line) }
    }
}
