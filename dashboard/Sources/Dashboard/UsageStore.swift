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
    /// The most recent fetch error, or nil after a success. Drives the quiet
    /// "stale" hint while last-good gauges remain visible.
    @Published private(set) var lastError: FetchError?

    /// When set and still in the future, `refresh()` skips the network call to
    /// avoid hammering a rate-limited endpoint.
    private var backoffUntil: Date?

    /// Set after `.accessDenied`: every fetch would raise the Keychain dialog
    /// again, so automatic refreshes stop until `retry()`.
    private var pausedForAccess = false

    /// Set once the provider reports `.unsupported`: the store stops polling
    /// and the popover hides it.
    var isRetired: Bool { if case .failed(.unsupported) = loadState { return true }; return false }

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

        if isRetired || pausedForAccess { return }
        // Skip the network call while a rate-limit backoff is active.
        if let until = backoffUntil, now() < until { return }

        do {
            let windows = try await provider.fetch()
            loadState = .loaded(windows)
            pendingResetRefresh = windows.map(\.resetsAt).filter { $0 > now() }.min()
            lastChecked = now()
            lastError = nil
            backoffUntil = nil
            let events = alertEngine.evaluate(windows, now: now())
            if !events.isEmpty { onAlerts(events) }
        } catch {
            // The popover's refresh runs in a SwiftUI .task, which is cancelled
            // when the popover closes. A fetch cut short that way tells us
            // nothing about the endpoint — recording it would leave a bogus
            // "Couldn't refresh" hint on screen until the next successful poll.
            if Task.isCancelled { return }

            let fetchError = (error as? FetchError) ?? .network(error.localizedDescription)
            lastError = fetchError
            if fetchError == .accessDenied { pausedForAccess = true }
            // Permanent: last-good data will never refresh again, so drop it.
            if case .unsupported = fetchError { loadState = .failed(fetchError); return }
            // Keep last-good gauges visible on a transient failure; only blank
            // to the error view when we have no prior loaded data.
            if !hasLoadedData { loadState = .failed(fetchError) }
            // Back off on rate limits so we stop hammering the endpoint.
            if fetchError == .rateLimited { backoffUntil = now().addingTimeInterval(300) }
        }
    }

    /// User-initiated: ask again after an `.accessDenied` pause.
    func retry() async {
        pausedForAccess = false
        await refresh()
    }

    private var hasLoadedData: Bool {
        if case .loaded = loadState { return true }
        return false
    }

    /// Windows that count as limits; display-only ones never drive the menu bar.
    private var windows: [UsageWindow] {
        if case .loaded(let w) = loadState { return w.filter(\.countsTowardLimit) }
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
