import XCTest
@testable import Dashboard

final class UsageModelTests: XCTestCase {
    private func window(used: Double, resetsIn seconds: TimeInterval = 3600) -> UsageWindow {
        UsageWindow(key: "five_hour", label: "5-hour session",
                    usedPercent: used, resetsAt: Date().addingTimeInterval(seconds))
    }

    func testRemainingPercentClamps() {
        XCTAssertEqual(window(used: 8).remainingPercent, 92, accuracy: 0.001)
        XCTAssertEqual(window(used: 130).remainingPercent, 0, accuracy: 0.001)
        XCTAssertEqual(window(used: -5).remainingPercent, 100, accuracy: 0.001)
    }

    func testStateOkBelow100() {
        if case .ok(let remaining) = window(used: 40).state {
            XCTAssertEqual(remaining, 60, accuracy: 0.001)
        } else { XCTFail("expected .ok") }
    }

    func testStateReachedAt100() {
        if case .reached = window(used: 100).state {} else { XCTFail("expected .reached") }
        if case .reached = window(used: 99.9).state { XCTFail("99.9 should be .ok") }
    }

    func testColorBuckets() {
        XCTAssertEqual(window(used: 74).color(), .green)
        XCTAssertEqual(window(used: 75).color(), .amber)
        XCTAssertEqual(window(used: 89).color(), .amber)
        XCTAssertEqual(window(used: 90).color(), .red)
        XCTAssertEqual(window(used: 100).color(), .red)
    }
}
