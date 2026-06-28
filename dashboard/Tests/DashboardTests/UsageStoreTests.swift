import XCTest
@testable import Dashboard

@MainActor
final class UsageStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private struct FakeProvider: UsageProviding {
        let result: Result<[UsageWindow], FetchError>
        func fetch() async throws -> [UsageWindow] { try result.get() }
    }
    private struct ThrowingProvider: UsageProviding {
        struct Boom: Error {}
        func fetch() async throws -> [UsageWindow] { throw Boom() }
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

    func testRefreshWrapsGenericErrorAsNetwork() async {
        let store = UsageStore(provider: ThrowingProvider(), threshold: nil, now: { self.now })
        await store.refresh()
        guard case .failed(.network) = store.loadState else {
            return XCTFail("expected .failed(.network), got \(store.loadState)")
        }
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

    func testMenuBarTitleShowsHighestUsedWhenOk() async {
        let store = UsageStore(provider: FakeProvider(result: .success([
            win("five_hour", "5-hour session", used: 8, resetsIn: 3600),     // 92% left
            win("seven_day", "7-day (all models)", used: 40, resetsIn: 3600) // 60% left, most constrained
        ])), threshold: nil, now: { self.now })
        await store.refresh()
        XCTAssertEqual(store.menuBarTitle, "◔ 40%")
    }

    private final class CountingProvider: UsageProviding {
        private(set) var fetchCount = 0
        let windows: [UsageWindow]
        init(windows: [UsageWindow]) { self.windows = windows }
        func fetch() async throws -> [UsageWindow] {
            fetchCount += 1
            return windows
        }
    }

    func testTickRefreshesWhenWindowResetTimePasses() async {
        let resetsAt = now.addingTimeInterval(300)   // window resets 5 minutes from base
        let provider = CountingProvider(windows: [
            UsageWindow(key: "five_hour", label: "5-hour", usedPercent: 8, resetsAt: resetsAt)
        ])
        let store = UsageStore(provider: provider, threshold: nil, now: { self.now })

        await store.refresh()
        XCTAssertEqual(provider.fetchCount, 1)

        // A tick before the reset time must not trigger another fetch.
        store.tick(now: resetsAt.addingTimeInterval(-1))
        XCTAssertEqual(provider.fetchCount, 1)

        // A tick at/after the reset time fires a one-shot refresh. Assert the
        // synchronous effect (pendingResetRefresh cleared) deterministically.
        XCTAssertNotNil(store.pendingResetRefresh)
        store.tick(now: resetsAt)
        XCTAssertNil(store.pendingResetRefresh)
    }
}
