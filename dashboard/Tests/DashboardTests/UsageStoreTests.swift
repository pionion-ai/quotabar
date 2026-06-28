import XCTest
@testable import Dashboard

@MainActor
final class UsageStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private struct FakeProvider: UsageProviding {
        let result: Result<[UsageWindow], FetchError>
        func fetch() async throws -> [UsageWindow] { try result.get() }
    }
    private func win(_ key: String, _ label: String, used: Double, resetsIn s: TimeInterval) -> UsageWindow {
        UsageWindow(key: key, label: label, usedPercent: used, resetsAt: now.addingTimeInterval(s))
    }

    func testRefreshSetsLoaded() async {
        let store = UsageStore(provider: FakeProvider(result: .success([win("five_hour", "5-hour session", used: 8, resetsIn: 3600)])),
                               threshold: nil, now: { self.now })
        await store.refresh()
        XCTAssertEqual(store.loadState, .loaded([win("five_hour", "5-hour session", used: 8, resetsIn: 3600)]))
        XCTAssertEqual(store.lastChecked, now)
    }

    func testRefreshSetsFailed() async {
        let store = UsageStore(provider: FakeProvider(result: .failure(.authExpired)), threshold: nil, now: { self.now })
        await store.refresh()
        XCTAssertEqual(store.loadState, .failed(.authExpired))
    }

    func testAlertsFireThroughHook() async {
        var captured: [AlertEvent] = []
        let store = UsageStore(provider: FakeProvider(result: .success([win("five_hour", "5-hour session", used: 100, resetsIn: 3600)])),
                               threshold: 85, now: { self.now })
        store.onAlerts = { captured.append(contentsOf: $0) }
        await store.refresh()
        XCTAssertEqual(captured.count, 1)
        if case .reached = captured[0] {} else { XCTFail("expected .reached") }
    }

    func testMenuBarTitlePrefersSoonestReached() async {
        let store = UsageStore(provider: FakeProvider(result: .success([
            win("five_hour", "5-hour session", used: 100, resetsIn: 7200),   // reopens later
            win("seven_day", "7-day (all models)", used: 100, resetsIn: 600) // reopens sooner
        ])), threshold: nil, now: { self.now })
        await store.refresh()
        XCTAssertEqual(store.menuBarTitle, "⛔ 0:10:00")
        XCTAssertEqual(store.menuBarColor, .red)
    }

    func testMenuBarTitleShowsLowestRemainingWhenOk() async {
        let store = UsageStore(provider: FakeProvider(result: .success([
            win("five_hour", "5-hour session", used: 8, resetsIn: 3600),     // 92% left
            win("seven_day", "7-day (all models)", used: 40, resetsIn: 3600) // 60% left
        ])), threshold: nil, now: { self.now })
        await store.refresh()
        XCTAssertEqual(store.menuBarTitle, "◔ 60%")
    }
}
