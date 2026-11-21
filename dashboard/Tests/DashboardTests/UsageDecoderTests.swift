import XCTest
@testable import Dashboard

final class UsageDecoderTests: XCTestCase {
    private let sample = """
    {
      "five_hour":        {"utilization": 8.0,  "resets_at": "2026-06-28T18:00:00+00:00"},
      "seven_day":        {"utilization": 8.0,  "resets_at": "2026-07-01T00:00:00+00:00"},
      "seven_day_sonnet": {"utilization": 2.0,  "resets_at": "2026-07-01T00:00:00+00:00"},
      "extra_usage":      {"is_enabled": false}
    }
    """.data(using: .utf8)!

    func testParsesKnownWindowsInOrder() throws {
        let windows = try UsageDecoder.windows(from: sample)
        XCTAssertEqual(windows.map(\.key), ["five_hour", "seven_day", "seven_day_sonnet"])
        XCTAssertEqual(windows[0].label, "5-hour")
        XCTAssertEqual(windows[0].usedPercent, 8.0, accuracy: 0.001)
    }

    func testSkipsAbsentAndIncompleteWindows() throws {
        let data = """
        {"five_hour": {"resets_at": "2026-06-28T18:00:00+00:00"},
         "seven_day": {"utilization": 5.0, "resets_at": "2026-07-01T00:00:00+00:00"}}
        """.data(using: .utf8)!
        let windows = try UsageDecoder.windows(from: data)
        XCTAssertEqual(windows.map(\.key), ["seven_day"])  // five_hour lacks utilization
    }

    func testThrowsOnGarbage() {
        XCTAssertThrowsError(try UsageDecoder.windows(from: Data("not json".utf8)))
    }

    func testParsesFractionalSecondsTimestamp() throws {
        let data = """
        {"five_hour": {"utilization": 8.0, "resets_at": "2026-06-28T18:00:00.123Z"}}
        """.data(using: .utf8)!
        let windows = try UsageDecoder.windows(from: data)
        XCTAssertEqual(windows.map(\.key), ["five_hour"])  // NOT dropped
    }

    /// Golden fixture captured from the real `/oauth/usage` payload (sanitized).
    /// Loaded from disk via `#filePath` so the parser is exercised against a
    /// real-shaped body, not invented JSON. Refresh per TESTING.md.
    func testDecodesRealCapturedFixture() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/oauth-usage-real.json")
        let data = try Data(contentsOf: url)
        let windows = try UsageDecoder.windows(from: data)
        XCTAssertEqual(windows.map(\.key), ["five_hour", "seven_day", "seven_day_sonnet"])
        XCTAssertEqual(windows[0].usedPercent, 4.0, accuracy: 0.001)
    }

    func testDecodesRealisticPayloadWithNullsArraysAndScalars() throws {
        let data = """
        {
          "five_hour":            {"utilization": 40.0, "resets_at": "2026-06-28T20:00:00+00:00", "limit_dollars": 1, "used_dollars": 0.4, "remaining_dollars": 0.6},
          "seven_day":            {"utilization": 8.0,  "resets_at": "2026-07-01T00:00:00+00:00", "limit_dollars": 1, "used_dollars": 0.08, "remaining_dollars": 0.92},
          "seven_day_oauth_apps": null,
          "seven_day_opus":       null,
          "seven_day_sonnet":     {"utilization": 2.0,  "resets_at": "2026-07-01T00:00:00+00:00"},
          "seven_day_cowork":     null,
          "extra_usage":          {"is_enabled": false, "monthly_limit": null, "daily": null, "weekly": null},
          "limits":               [{"kind": "session", "percent": 40}],
          "spend":                {"used": 1, "limit": 2, "enabled": true},
          "member_dashboard_available": false
        }
        """.data(using: .utf8)!
        let windows = try UsageDecoder.windows(from: data)
        XCTAssertEqual(windows.map(\.key), ["five_hour", "seven_day", "seven_day_sonnet"])
        XCTAssertEqual(windows[0].usedPercent, 40.0, accuracy: 0.001)
    }

    // MARK: - Model-scoped weekly limits (the `limits` list)

    /// Shape captured from the live endpoint on 2026-11-22: Fable's weekly
    /// limit exists only as a `weekly_scoped` entry, not as a named key.
    private let limitsJSON = """
    {"five_hour":{"utilization":11.0,"resets_at":"2026-11-22T03:09:59.965068+00:00"},
     "seven_day":{"utilization":10.0,"resets_at":"2026-11-25T01:59:59.965086+00:00"},
     "seven_day_opus":null,"seven_day_sonnet":null,
     "limits":[
      {"kind":"session","group":"session","percent":11,"resets_at":"2026-11-22T03:09:59.965068+00:00","scope":null},
      {"kind":"weekly_all","group":"weekly","percent":10,"resets_at":"2026-11-25T01:59:59.965086+00:00","scope":null},
      {"kind":"weekly_scoped","group":"weekly","percent":11,"resets_at":"2026-11-25T01:59:59.965214+00:00",
       "scope":{"model":{"id":null,"display_name":"Fable"},"surface":null}}]}
    """

    func testModelScopedWeeklyLimitBecomesAGauge() throws {
        let windows = try UsageDecoder.windows(from: Data(limitsJSON.utf8))
        XCTAssertEqual(windows.map(\.label), ["5-hour", "7-day", "7-day Fable"])
        let fable = try XCTUnwrap(windows.last)
        XCTAssertEqual(fable.key, "weekly_scoped_fable")
        XCTAssertEqual(fable.usedPercent, 11)
        XCTAssertEqual(fable.resetsAt.timeIntervalSince1970, 1795571999.965, accuracy: 0.01)
    }

    /// A model with both a named key and a scoped entry gets one gauge.
    func testScopedEntryDoesNotDuplicateNamedModelWindow() throws {
        let json = """
        {"seven_day_sonnet":{"utilization":3.0,"resets_at":"2026-11-25T02:00:00+00:00"},
         "limits":[{"kind":"weekly_scoped","percent":3,"resets_at":"2026-11-25T02:00:00+00:00",
                    "scope":{"model":{"display_name":"Sonnet"}}}]}
        """
        let windows = try UsageDecoder.windows(from: Data(json.utf8))
        XCTAssertEqual(windows.map(\.label), ["7-day Sonnet"])
    }

    /// Malformed or partial scoped entries are skipped, never fatal.
    func testMalformedScopedEntriesAreSkipped() throws {
        let json = """
        {"five_hour":{"utilization":5.0,"resets_at":"2026-11-22T03:00:00+00:00"},
         "limits":[{"kind":"weekly_scoped","percent":7,"resets_at":"2026-11-25T02:00:00+00:00","scope":null},
                   {"kind":"weekly_scoped","resets_at":"2026-11-25T02:00:00+00:00","scope":{"model":{"display_name":"X"}}},
                   {"kind":"weekly_scoped","percent":7,"scope":{"model":{"display_name":"Y"}}},
                   "garbage"]}
        """
        XCTAssertEqual(try UsageDecoder.windows(from: Data(json.utf8)).map(\.label), ["5-hour"])
    }
}
