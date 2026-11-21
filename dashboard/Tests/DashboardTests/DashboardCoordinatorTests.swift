import XCTest
@testable import Dashboard

@MainActor
final class DashboardCoordinatorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func win(used: Double, resetsIn s: TimeInterval) -> UsageWindow {
        UsageWindow(key: "w", label: "w", usedPercent: used, resetsAt: now.addingTimeInterval(s))
    }
    private func loaded(_ tag: String, _ windows: [UsageWindow]) -> ProviderState {
        ProviderState(tag: tag, loadState: .loaded(windows), now: now)
    }

    func testTightestAcrossProvidersWithTags() {
        // Claude 13% used (87% left) is tighter than Codex 1% used.
        let result = DashboardCoordinator.aggregate([
            loaded("C", [win(used: 13, resetsIn: 3600)]),
            loaded("X", [win(used: 1, resetsIn: 3600)]),
        ])
        XCTAssertEqual(result.title, "◔ C 13%")
        XCTAssertEqual(result.color, .green)
    }

    func testTightestPicksCodexWhenItIsTighter() {
        // Codex 78% used wins; 78 ∈ [75,90) → amber.
        let result = DashboardCoordinator.aggregate([
            loaded("C", [win(used: 13, resetsIn: 3600)]),
            loaded("X", [win(used: 78, resetsIn: 3600)]),
        ])
        XCTAssertEqual(result.title, "◔ X 78%")
        XCTAssertEqual(result.color, .amber)
    }

    func testReachedWinsAndPicksSoonest() {
        // Both reached (≥100%); Codex reopens sooner (10 min) than Claude (2h).
        let result = DashboardCoordinator.aggregate([
            loaded("C", [win(used: 100, resetsIn: 7200)]),
            loaded("X", [win(used: 100, resetsIn: 600)]),
        ])
        XCTAssertEqual(result.title, "⛔ X 0:10:00")
        XCTAssertEqual(result.color, .red)
    }

    func testReachedBeatsTighterNonReached() {
        // Claude is NON-reached but very high (95% used); Codex is REACHED (100%).
        // The reached provider must win over the tightest-non-reached one.
        let result = DashboardCoordinator.aggregate([
            loaded("C", [win(used: 95, resetsIn: 3600)]),
            loaded("X", [win(used: 100, resetsIn: 600)]),
        ])
        XCTAssertEqual(result.title, "⛔ X 0:10:00")
        XCTAssertEqual(result.color, .red)
    }

    func testSingleProviderOmitsTag() {
        let result = DashboardCoordinator.aggregate([
            loaded("C", [win(used: 40, resetsIn: 3600)]),
        ])
        XCTAssertEqual(result.title, "◔ 40%")
        XCTAssertEqual(result.color, .green)
    }

    func testSingleProviderReachedOmitsTag() {
        let result = DashboardCoordinator.aggregate([
            loaded("C", [win(used: 100, resetsIn: 3723)]),  // 1:02:03
        ])
        XCTAssertEqual(result.title, "⛔ 1:02:03")
        XCTAssertEqual(result.color, .red)
    }

    func testLoadingAndFailed() {
        // All loading → "…", amber.
        let allLoading = DashboardCoordinator.aggregate([
            ProviderState(tag: "C", loadState: .loading, now: now),
            ProviderState(tag: "X", loadState: .loading, now: now),
        ])
        XCTAssertEqual(allLoading.title, "…")
        XCTAssertEqual(allLoading.color, .amber)

        // All failed → "⚠", amber.
        let allFailed = DashboardCoordinator.aggregate([
            ProviderState(tag: "C", loadState: .failed(.authExpired), now: now),
            ProviderState(tag: "X", loadState: .failed(.rateLimited), now: now),
        ])
        XCTAssertEqual(allFailed.title, "⚠")
        XCTAssertEqual(allFailed.color, .amber)

        // loaded + failed → uses the loaded provider, ignores the failed one.
        let mixed = DashboardCoordinator.aggregate([
            loaded("C", [win(used: 22, resetsIn: 3600)]),
            ProviderState(tag: "X", loadState: .failed(.rateLimited), now: now),
        ])
        XCTAssertEqual(mixed.title, "◔ C 22%")
        XCTAssertEqual(mixed.color, .green)
    }

    // Instance test: two real UsageStores behind fake providers, refreshed (no
    // start() — that schedules real timers).
    private struct FakeProvider: UsageProviding {
        let windows: [UsageWindow]
        func fetch() async throws -> [UsageWindow] { windows }
    }

    func testCoordinatorAggregatesLiveStores() async {
        let claude = UsageStore(provider: FakeProvider(windows: [win(used: 13, resetsIn: 3600)]),
                                threshold: nil, now: { self.now })
        let codex = UsageStore(provider: FakeProvider(windows: [win(used: 55, resetsIn: 3600)]),
                               threshold: nil, now: { self.now })
        let coordinator = DashboardCoordinator(entries: [
            .init(id: "claude", displayName: "Claude Code", tag: "C", store: claude),
            .init(id: "codex", displayName: "Codex", tag: "X", store: codex),
        ])
        await claude.refresh()
        await codex.refresh()
        XCTAssertEqual(coordinator.menuBarTitle, "◔ X 55%")
        XCTAssertEqual(coordinator.menuBarColor, .green)
    }

    private struct FailingProvider: UsageProviding {
        let error: FetchError
        func fetch() async throws -> [UsageWindow] { throw error }
    }

    /// A retired provider vanishes: hidden from the popover and ignored by the
    /// menu bar (no "⚠", no tag prefix as if it were still a second provider).
    func testRetiredProviderIsHiddenAndIgnored() async {
        let claude = UsageStore(provider: FakeProvider(windows: [win(used: 13, resetsIn: 3600)]),
                                threshold: nil, now: { self.now })
        let gemini = UsageStore(provider: FailingProvider(error: .unsupported("gone")),
                                threshold: nil, now: { self.now })
        let coordinator = DashboardCoordinator(entries: [
            .init(id: "claude", displayName: "Claude Code", tag: "C", store: claude),
            .init(id: "gemini", displayName: "Gemini", tag: "G", store: gemini),
        ])
        await coordinator.refreshAll()
        XCTAssertEqual(coordinator.visibleEntries.map(\.id), ["claude"])
        XCTAssertEqual(coordinator.menuBarTitle, "◔ 13%")
        XCTAssertEqual(coordinator.menuBarColor, .green)
    }

    // Counts fetches so we can assert refreshAll() hit every store.
    private final class CountingProvider: UsageProviding, @unchecked Sendable {
        let windows: [UsageWindow]
        private(set) var fetchCount = 0
        init(windows: [UsageWindow]) { self.windows = windows }
        func fetch() async throws -> [UsageWindow] { fetchCount += 1; return windows }
    }

    func testRefreshAllRefreshesEveryStore() async {
        let claudeProvider = CountingProvider(windows: [win(used: 10, resetsIn: 3600)])
        let codexProvider = CountingProvider(windows: [win(used: 20, resetsIn: 3600)])
        let claude = UsageStore(provider: claudeProvider, threshold: nil, now: { self.now })
        let codex = UsageStore(provider: codexProvider, threshold: nil, now: { self.now })
        let coordinator = DashboardCoordinator(entries: [
            .init(id: "claude", displayName: "Claude Code", tag: "C", store: claude),
            .init(id: "codex", displayName: "Codex", tag: "X", store: codex),
        ])

        await coordinator.refreshAll()

        XCTAssertEqual(claudeProvider.fetchCount, 1)
        XCTAssertEqual(codexProvider.fetchCount, 1)
        XCTAssertEqual(coordinator.menuBarTitle, "◔ X 20%")
    }

    // MARK: - Parallel refresh

    /// Opens once; waiters before that suspend.
    private actor Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func open() { isOpen = true; waiters.forEach { $0.resume() }; waiters = [] }
    }

    private struct ClosureProvider: UsageProviding {
        let body: () async throws -> [UsageWindow]
        func fetch() async throws -> [UsageWindow] { try await body() }
    }

    /// A Claude fetch stuck behind the Keychain prompt must not hold Codex
    /// back: here Claude only finishes once Codex has fetched. Refreshing one
    /// provider after another would never complete.
    func testRefreshAllDoesNotSerializeProviders() async {
        let gate = Gate()
        let w = [win(used: 10, resetsIn: 3600)]
        let claude = UsageStore(provider: ClosureProvider { await gate.wait(); return w },
                                threshold: nil, now: { self.now })
        let codex = UsageStore(provider: ClosureProvider { await gate.open(); return w },
                               threshold: nil, now: { self.now })
        let coordinator = DashboardCoordinator(entries: [
            .init(id: "claude", displayName: "Claude Code", tag: "C", store: claude),
            .init(id: "codex", displayName: "Codex", tag: "X", store: codex),
        ])

        let done = expectation(description: "refreshAll finished")
        let task = Task { await coordinator.refreshAll(); done.fulfill() }
        await fulfillment(of: [done], timeout: 2)
        task.cancel()
        await gate.open()   // unblock a serialized run so the test process can exit
        XCTAssertEqual(codex.loadState, .loaded(w))
        XCTAssertEqual(claude.loadState, .loaded(w))
    }
}
