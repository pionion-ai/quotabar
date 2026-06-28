import XCTest
@testable import Dashboard

final class SettingsTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let d = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        return d
    }

    func testRoundTripThreshold() {
        let d = defaults()
        Settings(threshold: 85).save(d)
        XCTAssertEqual(Settings.load(d).threshold, 85)
    }

    func testNilThresholdMeansOff() {
        let d = defaults()
        Settings(threshold: nil).save(d)
        XCTAssertNil(Settings.load(d).threshold)
    }

    func testNotificationBodyForReached() {
        let (title, body) = Notifier.body(for: .reached(label: "5-hour session", countdown: "1:11:48"))
        XCTAssertEqual(title, "Claude Code Usage")
        XCTAssertEqual(body, "5-hour session limit reached · available in 1:11:48")
    }

    func testNotificationBodyForApproaching() {
        let (_, body) = Notifier.body(for: .approaching(label: "7-day (all models)", countdown: "1h 12m"))
        XCTAssertEqual(body, "7-day (all models) at threshold · resets in 1h 12m")
    }
}
