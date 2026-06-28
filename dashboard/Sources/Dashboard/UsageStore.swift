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

    var onAlerts: ([AlertEvent]) -> Void = { _ in }

    private let provider: UsageProviding
    private let now: () -> Date
    private var alertEngine: AlertEngine

    init(provider: UsageProviding, threshold: Double?, now: @escaping () -> Date = Date.init) {
        self.provider = provider
        self.now = now
        self.alertEngine = AlertEngine(threshold: threshold)
    }

    func setThreshold(_ value: Double?) { alertEngine.threshold = value }

    func refresh() async {
        do {
            let windows = try await provider.fetch()
            loadState = .loaded(windows)
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
            return windows.map { $0.color() }.contains(.red) ? .red
                : windows.map { $0.color() }.contains(.amber) ? .amber : .green
        }
    }

    var menuBarTitle: String {
        switch loadState {
        case .loading: return "…"
        case .failed: return "⚠"
        case .loaded:
            let reached = windows.filter { $0.usedPercent >= 100 }
            if let soonest = reached.min(by: { $0.resetsAt < $1.resetsAt }) {
                return "⛔ \(soonest.countdown(now: now()))"
            }
            guard let lowest = windows.min(by: { $0.remainingPercent < $1.remainingPercent }) else {
                return "◔ —"
            }
            return "◔ \(Int(lowest.remainingPercent.rounded()))%"
        }
    }
}
