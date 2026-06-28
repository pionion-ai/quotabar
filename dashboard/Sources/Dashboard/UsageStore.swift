import Foundation
import Combine

enum LoadState: Equatable {
    case loading
    case loaded([UsageWindow])
    case failed(FetchError)
}

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var loadState: LoadState = .loading
    @Published private(set) var lastChecked: Date?
    @Published private(set) var currentTime: Date

    var onAlerts: ([AlertEvent]) -> Void = { _ in }

    private let provider: UsageProviding
    private let now: () -> Date
    private var alertEngine: AlertEngine

    private var refreshTimer: Timer?
    private var tickTimer: Timer?
    private var isRefreshing = false
    private(set) var pendingResetRefresh: Date?

    init(provider: UsageProviding, threshold: Double?, now: @escaping () -> Date = Date.init) {
        self.provider = provider
        self.now = now
        self.alertEngine = AlertEngine(threshold: threshold)
        self.currentTime = now()
    }

    func setThreshold(_ value: Double?) { alertEngine.threshold = value }

    /// Begin the periodic refresh + countdown tick on the main run loop.
    /// Must be called once at app launch; never from unit tests (it schedules
    /// real timers).
    func start() {
        guard refreshTimer == nil else { return }
        Task { await refresh() }
        refreshTimer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        RunLoop.main.add(refreshTimer!, forMode: .common)
        tickTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in if let self { self.tick(now: self.now()) } }
        }
        RunLoop.main.add(tickTimer!, forMode: .common)
    }

    /// Advance the displayed clock and, if a loaded window's reset time has just
    /// passed, trigger a one-shot refresh so the gauge doesn't show a stale
    /// (pre-reset) percentage while the countdown reads zero.
    func tick(now: Date) {
        currentTime = now
        if let due = pendingResetRefresh, now >= due {
            pendingResetRefresh = nil          // fire once per crossing
            Task { await refresh() }
        }
    }

    func stop() {
        refreshTimer?.invalidate(); refreshTimer = nil
        tickTimer?.invalidate(); tickTimer = nil
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let windows = try await provider.fetch()
            loadState = .loaded(windows)
            pendingResetRefresh = windows.map(\.resetsAt).min()
            lastChecked = now()
            let events = alertEngine.evaluate(windows, now: now())
            if !events.isEmpty { onAlerts(events) }
        } catch let error as FetchError {
            loadState = .failed(error)
        } catch {
            loadState = .failed(.network(error.localizedDescription))
        }
    }

    private var windows: [UsageWindow] {
        if case .loaded(let w) = loadState { return w }
        return []
    }

    var menuBarColor: GaugeColor {
        switch loadState {
        case .loading, .failed: return .amber
        case .loaded:
            let reached = windows.filter { $0.usedPercent >= 100 }
            if !reached.isEmpty { return .red }
            let colors = windows.map { $0.color() }
            return colors.contains(.red) ? .red
                : colors.contains(.amber) ? .amber : .green
        }
    }

    var menuBarTitle: String {
        switch loadState {
        case .loading: return "…"
        case .failed: return "⚠"
        case .loaded:
            let reached = windows.filter { $0.usedPercent >= 100 }
            if let soonest = reached.min(by: { $0.resetsAt < $1.resetsAt }) {
                return "⛔ \(soonest.countdown(now: currentTime))"
            }
            guard let constrained = windows.min(by: { $0.remainingPercent < $1.remainingPercent }) else {
                return "◔ —"
            }
            return "◔ \(Int(constrained.usedPercent.rounded()))%"
        }
    }
}
