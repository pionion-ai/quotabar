import XCTest
import SQLite3
@testable import Dashboard

final class CursorUsageTests: XCTestCase {

    private func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name)")
        return try Data(contentsOf: url)
    }

    private let cycleEnd = Date(timeIntervalSince1970: 1790352978)

    // MARK: - Decoder

    /// Golden fixtures captured from the real `GetCurrentPeriodUsage` /
    /// `GetAggregatedUsageEvents` responses of a Pro account with on-demand
    /// usage enabled.
    func testDecodesRealFixtures() throws {
        let windows = try CursorUsageDecoder.windows(period: fixture("cursor-period-real.json"),
                                                     models: fixture("cursor-models-real.json"))
        XCTAssertEqual(Array(windows.map(\.key).prefix(3)),
                       ["cursor_api", "cursor_auto", "cursor_on_demand"])

        let api = windows[0], auto = windows[1], onDemand = windows[2]
        XCTAssertEqual(api.label, "API")
        XCTAssertEqual(api.usedPercent, 100, accuracy: 0.001)
        XCTAssertEqual(auto.label, "Auto")
        XCTAssertEqual(auto.usedPercent, 0.842, accuracy: 0.001)
        XCTAssertEqual(onDemand.label, "On-demand")
        XCTAssertEqual(onDemand.usedPercent, 82.0 / 2500 * 100, accuracy: 0.001)
        XCTAssertEqual(onDemand.detail, "$0.82 / $25")
        for w in windows { XCTAssertEqual(w.resetsAt, cycleEnd) }
    }

    /// With on-demand spend available, an exhausted included pool doesn't block
    /// anything — it must not read as "limit reached" or drive alerts.
    func testIncludedPoolsAreInformationalWhileOnDemandHasHeadroom() throws {
        let windows = try CursorUsageDecoder.windows(period: fixture("cursor-period-real.json"), models: nil)
        XCTAssertEqual(windows[0].style, .info)
        XCTAssertEqual(windows[1].style, .info)
        XCTAssertEqual(windows[2].style, .limit)
        XCTAssertEqual(windows[0].state, .ok(remaining: 0))
    }

    func testIncludedPoolsAreLimitsWithoutOnDemand() throws {
        let data = """
        {"billingCycleStart":"1787674578000","billingCycleEnd":"1790352978000",
         "planUsage":{"autoPercentUsed":3,"apiPercentUsed":100}}
        """.data(using: .utf8)!
        let windows = try CursorUsageDecoder.windows(period: data, models: nil)
        XCTAssertEqual(windows.map(\.key), ["cursor_api", "cursor_auto"])
        XCTAssertEqual(windows[0].style, .limit)
        XCTAssertEqual(windows[0].state, .reached(reopensAt: cycleEnd))
    }

    func testOnDemandExhaustedMakesIncludedPoolsLimitsAgain() throws {
        let data = """
        {"billingCycleStart":"1787674578000","billingCycleEnd":"1790352978000",
         "planUsage":{"autoPercentUsed":3,"apiPercentUsed":100},
         "spendLimitUsage":{"individualUsed":2500,"individualLimit":2500,"individualRemaining":0}}
        """.data(using: .utf8)!
        let windows = try CursorUsageDecoder.windows(period: data, models: nil)
        XCTAssertEqual(windows[0].style, .limit)
        XCTAssertEqual(windows[2].usedPercent, 100, accuracy: 0.001)
    }

    func testModelShareGaugesTopFivePlusOther() throws {
        let windows = try CursorUsageDecoder.windows(period: fixture("cursor-period-real.json"),
                                                     models: fixture("cursor-models-real.json"))
        let shares = windows.filter { $0.style == .share }
        XCTAssertEqual(shares.map(\.label), [
            "gpt-5.6-sol-high", "cursor-grok-4.6-high-fast", "cursor-grok-4.6-high",
            "claude-opus-5-thinking-high", "claude-fable-5-1-thinking-max", "6 others",
        ])
        let total = 4881.3240
        XCTAssertEqual(shares[0].usedPercent, 4208.77107 / total * 100, accuracy: 0.01)
        XCTAssertEqual(shares[0].detail, "$42.09")
        XCTAssertEqual(shares.map(\.usedPercent).reduce(0, +), 100, accuracy: 0.01)
        XCTAssertEqual(shares[5].detail, "$1.62")
    }

    /// Per-model dollars are list-price usage value, mostly covered by the plan
    /// and Cursor's free bonus — the note says so, so they don't read as charges.
    func testShareWindowsCarryPlanCoverageNote() throws {
        let windows = try CursorUsageDecoder.windows(period: fixture("cursor-period-real.json"),
                                                     models: fixture("cursor-models-real.json"))
        let shares = windows.filter { $0.style == .share }
        XCTAssertFalse(shares.isEmpty)
        for w in shares { XCTAssertEqual(w.note, "$48.82 used · $20 included + $28.82 bonus") }
        for w in windows where w.style != .share { XCTAssertNil(w.note) }
    }

    func testPlanCoverageNoteOmitsZeroBonus() throws {
        let period = """
        {"billingCycleStart":"1787674578000","billingCycleEnd":"1790352978000",
         "planUsage":{"totalSpend":1250,"includedSpend":1250,"bonusSpend":0,"apiPercentUsed":62}}
        """.data(using: .utf8)!
        let models = #"{"aggregations":[{"modelIntent":"m","totalCents":1250}]}"#.data(using: .utf8)!
        let shares = try CursorUsageDecoder.windows(period: period, models: models).filter { $0.style == .share }
        XCTAssertEqual(shares.first?.note, "$12.50 used · $12.50 included")
    }

    func testModelSharesSkippedWhenNoSpendOrUnreadable() throws {
        let period = try fixture("cursor-period-real.json")
        let zero = #"{"aggregations":[{"modelIntent":"default","totalCents":0}]}"#.data(using: .utf8)!
        XCTAssertTrue(try CursorUsageDecoder.windows(period: period, models: zero).allSatisfy { $0.style != .share })
        let garbage = Data("nope".utf8)
        XCTAssertTrue(try CursorUsageDecoder.windows(period: period, models: garbage).allSatisfy { $0.style != .share })
    }

    func testThrowsOnGarbagePeriod() {
        XCTAssertThrowsError(try CursorUsageDecoder.windows(period: Data("not json".utf8), models: nil))
        XCTAssertThrowsError(try CursorUsageDecoder.windows(period: Data("{}".utf8), models: nil))
    }

    // MARK: - Client

    private func client(
        token: String? = "tok",
        handler: @escaping (URLRequest) throws -> (Int, Data)
    ) -> CursorUsageClient {
        CursorUsageClient(
            tokenReader: {
                guard let token else { throw FetchError.notLoggedIn }
                return token
            },
            transport: { req in
                let (status, body) = try handler(req)
                return (body, HTTPURLResponse(url: req.url!, statusCode: status,
                                              httpVersion: nil, headerFields: nil)!)
            },
            now: { Date(timeIntervalSince1970: 1789000000) }
        )
    }

    func testFetchCallsBothEndpointsWithBearer() async throws {
        let period = try fixture("cursor-period-real.json")
        let models = try fixture("cursor-models-real.json")
        var seen: [String] = []
        let c = client { req in
            XCTAssertEqual(req.httpMethod, "POST")
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
            let method = req.url!.lastPathComponent
            seen.append(method)
            if method == "GetAggregatedUsageEvents" {
                let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: String]
                XCTAssertEqual(body["startDate"], "1787674578000")
                XCTAssertEqual(body["endDate"], "1789000000000")
                return (200, models)
            }
            return (200, period)
        }
        let windows = try await c.fetch()
        XCTAssertEqual(seen, ["GetCurrentPeriodUsage", "GetAggregatedUsageEvents"])
        XCTAssertTrue(windows.contains { $0.style == .share })
    }

    func testModelEndpointFailureIsNonFatal() async throws {
        let period = try fixture("cursor-period-real.json")
        let c = client { req in
            req.url!.lastPathComponent == "GetAggregatedUsageEvents" ? (500, Data()) : (200, period)
        }
        let windows = try await c.fetch()
        XCTAssertEqual(windows.map(\.key), ["cursor_api", "cursor_auto", "cursor_on_demand"])
    }

    /// Closing the popover cancels the refresh. A model call cut short that way
    /// must not be mistaken for "no breakdown" and stored as a success.
    func testCancellationDuringModelCallPropagates() async throws {
        let period = try fixture("cursor-period-real.json")
        let c = client { req in
            if req.url!.lastPathComponent == "GetAggregatedUsageEvents" {
                withUnsafeCurrentTask { $0?.cancel() }
                throw URLError(.cancelled)
            }
            return (200, period)
        }
        do {
            _ = try await c.fetch()
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
    }

    func testMissingTokenIsNotLoggedIn() async {
        await assertThrows(client(token: nil) { _ in (200, Data()) }, .notLoggedIn)
    }

    func testStatusMapping() async {
        await assertThrows(client { _ in (401, Data()) }, .authExpired)
        await assertThrows(client { _ in (403, Data()) }, .authExpired)
        await assertThrows(client { _ in (429, Data()) }, .rateLimited)
        await assertThrows(client { _ in (500, Data()) }, .network("HTTP 500"))
        await assertThrows(client { _ in (200, Data("x".utf8)) }, .decode)
    }

    private func assertThrows(_ c: CursorUsageClient, _ expected: FetchError,
                              file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await c.fetch()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? FetchError, expected, file: file, line: line)
        }
    }

    // MARK: - Auth recovery

    func testReloginOpensCursorApp() {
        let prompt = AuthRecovery.prompt(for: .authExpired, provider: "cursor")
        XCTAssertEqual(prompt, ReloginPrompt(message: "Session expired.",
                                             buttonTitle: "Re-login to Cursor…",
                                             command: "open -a Cursor"))
        XCTAssertNotNil(AuthRecovery.installHint(for: .notLoggedIn, provider: "cursor"))
    }

    // MARK: - Token reader

    private func makeStateDB(token: String?) throws -> String {
        let path = NSTemporaryDirectory() + "cursor-state-\(UUID().uuidString).vscdb"
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "create table ItemTable (key text primary key, value blob)", nil, nil, nil), SQLITE_OK)
        if let token {
            let sql = "insert into ItemTable values ('cursorAuth/accessToken', '\(token)')"
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        }
        return path
    }

    func testReadTokenFromStateDB() throws {
        let path = try makeStateDB(token: "abc.def.ghi")
        XCTAssertEqual(try CursorUsageClient.readToken(dbPath: path), "abc.def.ghi")
    }

    func testReadTokenMissingKeyOrFile() throws {
        let path = try makeStateDB(token: nil)
        XCTAssertThrowsError(try CursorUsageClient.readToken(dbPath: path))
        XCTAssertThrowsError(try CursorUsageClient.readToken(dbPath: "/nonexistent/state.vscdb"))
    }
}
