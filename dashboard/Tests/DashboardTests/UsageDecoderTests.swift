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
        XCTAssertEqual(windows[0].label, "5-hour session")
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
}
