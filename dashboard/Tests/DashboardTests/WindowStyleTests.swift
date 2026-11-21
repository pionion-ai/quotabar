import XCTest
@testable import Dashboard

/// `.info` and `.share` windows are display-only: they render as gauges but
/// never count as a limit — no "reached" state, no alerts, no menu-bar pick.
@MainActor
final class WindowStyleTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func win(_ key: String, used: Double, style: WindowStyle) -> UsageWindow {
        UsageWindow(key: key, label: key, usedPercent: used,
                    resetsAt: now.addingTimeInterval(3600), style: style)
    }

    func testDefaultStyleIsLimit() {
        let w = UsageWindow(key: "k", label: "k", usedPercent: 1, resetsAt: now)
        XCTAssertEqual(w.style, .limit)
        XCTAssertTrue(w.countsTowardLimit)
    }

    func testDisplayOnlyWindowsNeverReached() {
        XCTAssertEqual(win("i", used: 100, style: .info).state, .ok(remaining: 0))
        XCTAssertEqual(win("s", used: 100, style: .share).state, .ok(remaining: 0))
        XCTAssertEqual(win("l", used: 100, style: .limit).state, .reached(reopensAt: now.addingTimeInterval(3600)))
    }

    /// A full included pool that doesn't block (on-demand available) must not
    /// look alarming, and must not look like a blue share gauge either.
    func testInfoWindowsAreMutedAtAnyLevel() {
        XCTAssertEqual(win("i", used: 100, style: .info).color(), .muted)
        XCTAssertEqual(win("i", used: 10, style: .info).color(), .muted)
        XCTAssertEqual(win("s", used: 90, style: .share).color(), .neutral)
        XCTAssertEqual(win("l", used: 100, style: .limit).color(), .red)
    }

    func testAlertEngineIgnoresDisplayOnlyWindows() {
        var engine = AlertEngine(threshold: 80)
        let events = engine.evaluate([win("i", used: 100, style: .info),
                                      win("s", used: 90, style: .share)], now: now)
        XCTAssertEqual(events, [])
    }

    func testAggregateIgnoresDisplayOnlyWindows() {
        let result = DashboardCoordinator.aggregate([
            ProviderState(tag: "C", loadState: .loaded([win("c", used: 13, style: .limit)]), now: now),
            ProviderState(tag: "Cu", loadState: .loaded([win("api", used: 100, style: .info),
                                                         win("m", used: 86, style: .share),
                                                         win("od", used: 3, style: .limit)]), now: now),
        ])
        XCTAssertEqual(result.title, "◔ C 13%")
        XCTAssertEqual(result.color, .green)
    }

    func testAggregateWithOnlyDisplayOnlyWindowsShowsDash() {
        let result = DashboardCoordinator.aggregate([
            ProviderState(tag: "Cu", loadState: .loaded([win("m", used: 86, style: .share)]), now: now),
        ])
        XCTAssertEqual(result.title, "◔ —")
        XCTAssertEqual(result.color, .green)
    }

    private struct FakeProvider: UsageProviding {
        let windows: [UsageWindow]
        func fetch() async throws -> [UsageWindow] { windows }
    }

    func testStoreMenuBarIgnoresDisplayOnlyWindows() async {
        let store = UsageStore(provider: FakeProvider(windows: [win("api", used: 100, style: .info),
                                                                win("od", used: 3, style: .limit)]),
                               threshold: nil, now: { self.now })
        await store.refresh()
        XCTAssertEqual(store.menuBarTitle, "◔ 3%")
        XCTAssertEqual(store.menuBarColor, .green)
    }
}
