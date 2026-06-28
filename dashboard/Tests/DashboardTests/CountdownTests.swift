import XCTest
@testable import Dashboard

final class CountdownTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func window(used: Double, resetsIn s: TimeInterval) -> UsageWindow {
        UsageWindow(key: "k", label: "l", usedPercent: used,
                    resetsAt: now.addingTimeInterval(s))
    }

    func testLooseFormatWhenOk() {
        // 4h 53m = 17580s
        XCTAssertEqual(window(used: 8, resetsIn: 4 * 3600 + 53 * 60).countdown(now: now), "4h 53m")
        XCTAssertEqual(window(used: 8, resetsIn: 3 * 86400 + 2 * 3600).countdown(now: now), "3d 2h")
        XCTAssertEqual(window(used: 8, resetsIn: 40).countdown(now: now), "0m")
    }

    func testPreciseFormatWhenReached() {
        // reached (used >= 100) → H:MM:SS, here 1h 11m 48s
        XCTAssertEqual(window(used: 100, resetsIn: 3600 + 11 * 60 + 48).countdown(now: now), "1:11:48")
        XCTAssertEqual(window(used: 100, resetsIn: 9).countdown(now: now), "0:00:09")
    }

    func testNowWhenPast() {
        XCTAssertEqual(window(used: 100, resetsIn: -5).countdown(now: now), "now")
        XCTAssertEqual(window(used: 8, resetsIn: 0).countdown(now: now), "now")
    }
}
