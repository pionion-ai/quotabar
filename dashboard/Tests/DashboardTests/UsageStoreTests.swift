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

    /// Counts fetches and lets the test flip between success and a thrown error.
    private final class FlippableProvider: UsageProviding {
        private(set) var fetchCount = 0
        var result: Result<[UsageWindow], FetchError>
        init(result: Result<[UsageWindow], FetchError>) { self.result = result }
        func fetch() async throws -> [UsageWindow] {
            fetchCount += 1
            return try result.get()
        }
    }

    /// An unsupported provider is gone for good: drop even last-good data and
    /// never call the endpoint again.
    func testUnsupportedRetiresProvider() async {
        let provider = FlippableProvider(result: .success([win("five_hour", "5-hour session", used: 8, resetsIn: 3600)]))
        let store = UsageStore(provider: provider, threshold: nil, now: { self.now })
        await store.refresh()

        provider.result = .failure(.unsupported("gone"))
        await store.refresh()
        XCTAssertEqual(store.loadState, .failed(.unsupported("gone")))
        XCTAssertTrue(store.isRetired)

        provider.result = .success([])
        await store.refresh()
        XCTAssertEqual(provider.fetchCount, 2)
        XCTAssertEqual(store.loadState, .failed(.unsupported("gone")))
    }

    func testKeepsLastGoodDataOnTransientError() async {
        let good = [win("five_hour", "5-hour session", used: 8, resetsIn: 3600)]
        let provider = FlippableProvider(result: .success(good))
        let store = UsageStore(provider: provider, threshold: nil, now: { self.now })

        await store.refresh()
        XCTAssertEqual(store.loadState, .loaded(good))

        provider.result = .failure(.rateLimited)
        await store.refresh()

        // Last-good gauges stay visible; only the error hint changes.
        XCTAssertEqual(store.loadState, .loaded(good))
        XCTAssertEqual(store.lastError, .rateLimited)
    }

    func testColdFailureShowsFailedState() async {
        let provider = FlippableProvider(result: .failure(.rateLimited))
        let store = UsageStore(provider: provider, threshold: nil, now: { self.now })

        await store.refresh()

        XCTAssertEqual(store.loadState, .failed(.rateLimited))
        XCTAssertEqual(store.lastError, .rateLimited)
    }

    func testRateLimitBacksOff() async {
        var clock = now
        let good = [win("five_hour", "5-hour session", used: 8, resetsIn: 3600)]
        let provider = FlippableProvider(result: .success(good))
        let store = UsageStore(provider: provider, threshold: nil, now: { clock })

        await store.refresh()
        XCTAssertEqual(provider.fetchCount, 1)

        provider.result = .failure(.rateLimited)
        await store.refresh()
        XCTAssertEqual(provider.fetchCount, 2)   // hit the network, set backoff

        // Same clock: backoff active → fetch is skipped.
        await store.refresh()
        XCTAssertEqual(provider.fetchCount, 2)

        // Advance past the 5-minute backoff window → fetch resumes.
        clock = now.addingTimeInterval(301)
        await store.refresh()
        XCTAssertEqual(provider.fetchCount, 3)
    }

    func testSuccessClearsErrorAndBackoff() async {
        var clock = now
        let good = [win("five_hour", "5-hour session", used: 8, resetsIn: 3600)]
        let provider = FlippableProvider(result: .success(good))
        let store = UsageStore(provider: provider, threshold: nil, now: { clock })

        await store.refresh()                    // count 1, success
        provider.result = .failure(.rateLimited)
        await store.refresh()                    // count 2, backoff set
        XCTAssertEqual(store.lastError, .rateLimited)

        // Recover: flip back to success and advance past the backoff.
        provider.result = .success(good)
        clock = now.addingTimeInterval(301)
        await store.refresh()                    // count 3, success clears state
        XCTAssertNil(store.lastError)

        // Backoff is gone: a same-clock refresh fetches again.
        await store.refresh()                    // count 4
        XCTAssertEqual(provider.fetchCount, 4)
    }

    /// Mimics URLSession: stays in flight until the surrounding Task is
    /// cancelled, then fails the way a cancelled request does.
    private struct CancellationAwareProvider: UsageProviding {
        func fetch() async throws -> [UsageWindow] {
            while !Task.isCancelled { await Task.yield() }
            throw FetchError.network("cancelled")
        }
    }

    // The popover's .task is cancelled when the popover closes. A refresh cut
    // short that way is NOT a failure — recording it would leave a bogus
    // "Couldn't refresh" hint on screen while every endpoint is healthy.
    func testCancelledRefreshIsNotRecordedAsAnError() async {
        let store = UsageStore(provider: CancellationAwareProvider(), threshold: nil, now: { self.now })

        let task = Task { await store.refresh() }
        task.cancel()
        await task.value

        XCTAssertNil(store.lastError)
        XCTAssertEqual(store.loadState, .loading)   // not flipped to .failed
    }

    /// Succeeds on the first fetch, then hangs until cancelled — the shape of
    /// "gauges loaded, popover closed mid-refresh".
    private final class SucceedThenHangProvider: UsageProviding {
        let windows: [UsageWindow]
        private var first = true
        init(windows: [UsageWindow]) { self.windows = windows }
        func fetch() async throws -> [UsageWindow] {
            if first { first = false; return windows }
            while !Task.isCancelled { await Task.yield() }
            throw FetchError.network("cancelled")
        }
    }

    // A cancelled refresh must also leave previously loaded gauges untouched.
    func testCancelledRefreshKeepsLastGoodStateClean() async {
        let good = [win("five_hour", "5-hour session", used: 8, resetsIn: 3600)]
        let store = UsageStore(provider: SucceedThenHangProvider(windows: good),
                               threshold: nil, now: { self.now })
        await store.refresh()
        XCTAssertEqual(store.loadState, .loaded(good))

        let task = Task { await store.refresh() }
        task.cancel()
        await task.value

        XCTAssertEqual(store.loadState, .loaded(good))
        XCTAssertNil(store.lastError)
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

    // A reset time already in the past (server lag / clock skew at a window
    // boundary) must NOT arm pendingResetRefresh, otherwise the 1s tick would
    // immediately cross it and fire a ~1Hz refresh burst.
    func testNoReArmWhenResetTimeAlreadyPast() async {
        // Only a past-reset window: must not arm at all.
        let pastOnly = UsageStore(
            provider: FakeProvider(result: .success([win("five_hour", "5-hour", used: 8, resetsIn: -60)])),
            threshold: nil, now: { self.now })
        await pastOnly.refresh()
        XCTAssertNil(pastOnly.pendingResetRefresh)

        // Mix of past and future resets: must arm to the future one.
        let futureResetsAt = now.addingTimeInterval(300)
        let mixed = UsageStore(
            provider: FakeProvider(result: .success([
                win("five_hour", "5-hour", used: 8, resetsIn: -60),
                UsageWindow(key: "weekly", label: "Weekly", usedPercent: 8, resetsAt: futureResetsAt)
            ])),
            threshold: nil, now: { self.now })
        await mixed.refresh()
        XCTAssertEqual(mixed.pendingResetRefresh, futureResetsAt)
    }

    // MARK: - Stale data after a failed refresh (review findings)

    private final class SwitchProvider: UsageProviding {
        var result: Result<[UsageWindow], FetchError>
        init(_ r: Result<[UsageWindow], FetchError>) { result = r }
        func fetch() async throws -> [UsageWindow] { try result.get() }
    }

    /// Uninstalling the bridge deletes the file: old gauges must not linger.
    func testNotConnectedDropsLastGoodData() async {
        let p = SwitchProvider(.success([win("five_hour", "5-hour", used: 40, resetsIn: 3600)]))
        let store = UsageStore(provider: p, threshold: nil, now: { self.now })
        await store.refresh()
        p.result = .failure(.notConnected)
        await store.refresh()
        XCTAssertEqual(store.loadState, .failed(.notConnected))
    }

    /// A failing refresh after a reset must not keep showing the pre-reset %.
    func testFailedRefreshDropsWindowsPastTheirReset() async {
        var clock = now
        let p = SwitchProvider(.success([win("five_hour", "5-hour", used: 90, resetsIn: 60),
                                         win("seven_day", "7-day", used: 10, resetsIn: 86_400)]))
        let store = UsageStore(provider: p, threshold: nil, now: { clock })
        await store.refresh()
        clock = now.addingTimeInterval(120)
        p.result = .failure(.decode)
        await store.refresh()
        XCTAssertEqual(store.loadState, .loaded([win("seven_day", "7-day", used: 10, resetsIn: 86_400)]))
    }
}
