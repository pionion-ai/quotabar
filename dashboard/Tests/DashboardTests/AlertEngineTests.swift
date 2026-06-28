import XCTest
@testable import Dashboard

final class AlertEngineTests: XCTestCase {
    private let now = Date()
    private func win(_ used: Double) -> UsageWindow {
        UsageWindow(key: "five_hour", label: "5-hour session",
                    usedPercent: used, resetsAt: now.addingTimeInterval(3600))
    }

    func testFiresApproachingOnceOnCrossing() {
        var engine = AlertEngine(threshold: 85)
        XCTAssertTrue(engine.evaluate([win(80)], now: now).isEmpty)
        let events = engine.evaluate([win(86)], now: now)
        XCTAssertEqual(events.count, 1)
        if case .approaching(let label, _) = events[0] {
            XCTAssertEqual(label, "5-hour session")
        } else { XCTFail("expected .approaching") }
        // staying over the threshold emits nothing further
        XCTAssertTrue(engine.evaluate([win(88)], now: now).isEmpty)
    }

    func testFiresReachedOnceAt100() {
        var engine = AlertEngine(threshold: 85)
        _ = engine.evaluate([win(86)], now: now)            // approaching consumed
        let events = engine.evaluate([win(100)], now: now)
        XCTAssertEqual(events.count, 1)
        if case .reached = events[0] {} else { XCTFail("expected .reached") }
        XCTAssertTrue(engine.evaluate([win(100)], now: now).isEmpty)
    }

    func testResetsAfterWindowReopens() {
        var engine = AlertEngine(threshold: 85)
        _ = engine.evaluate([win(100)], now: now)
        // window reopened (low usage) — no event, but state cleared
        XCTAssertTrue(engine.evaluate([win(5)], now: now).isEmpty)
        // crossing again fires again
        XCTAssertEqual(engine.evaluate([win(90)], now: now).count, 1)
    }

    func testNoApproachingWhenThresholdNil() {
        var engine = AlertEngine(threshold: nil)
        XCTAssertTrue(engine.evaluate([win(95)], now: now).isEmpty)
        // reached still fires even with no threshold
        XCTAssertEqual(engine.evaluate([win(100)], now: now).count, 1)
    }
}
