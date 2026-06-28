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
