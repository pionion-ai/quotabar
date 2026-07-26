import Foundation
import Combine

@MainActor
final class DashboardCoordinator: ObservableObject {
    struct ProviderEntry: Identifiable {
        let id: String          // "claude", "codex"
        let displayName: String // "Claude Code", "Codex"
        let tag: String         // "C", "X" — shown in the aggregated menu-bar title
        let store: UsageStore
    }

    let entries: [ProviderEntry]
    private var cancellables: Set<AnyCancellable> = []

    init(entries: [ProviderEntry]) {
        self.entries = entries
        // Re-publish whenever ANY child store changes so the MenuBarExtra label and
        // the popover update together.
        for e in entries {
            e.store.objectWillChange
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &cancellables)
        }
    }

    func startAll() { for e in entries { e.store.start() } }

    /// Refresh every provider now — used when the popover opens, so a token
    /// the user just renewed shows up without waiting for the 60s tick.
    /// `UsageStore.refresh()` is re-entrancy guarded and honours the rate-limit
    /// backoff, so repeated opens cannot stampede an endpoint.
    func refreshAll() async {
        for e in entries { await e.store.refresh() }
    }
    func setThresholdAll(_ value: Double?) { for e in entries { e.store.setThreshold(value) } }

    var menuBarTitle: String { Self.aggregate(states).title }
    var menuBarColor: GaugeColor { Self.aggregate(states).color }

    /// Snapshot of each provider's current state for aggregation.
    private var states: [ProviderState] {
        entries.map { ProviderState(tag: $0.tag, loadState: $0.store.loadState, now: $0.store.currentTime) }
    }
}

struct ProviderState {
    let tag: String
    let loadState: LoadState
    let now: Date
}

extension DashboardCoordinator {
    /// PURE aggregation of every provider's state into a single menu-bar
    /// title + color: the "tightest window across all tools" decision.
    static func aggregate(_ states: [ProviderState]) -> (title: String, color: GaugeColor) {
        // With a single provider we drop the tag to match the existing
        // single-provider look ("◔ 13%" rather than "◔ C 13%").
        let multi = states.count > 1
        func tagPrefix(_ tag: String) -> String { multi ? "\(tag) " : "" }

        // Candidate windows: only providers with loaded data contribute.
        struct Candidate { let tag: String; let window: UsageWindow; let now: Date }
        var candidates: [Candidate] = []
        var anyLoading = false
        for s in states {
            switch s.loadState {
            case .loaded(let windows):
                for w in windows { candidates.append(Candidate(tag: s.tag, window: w, now: s.now)) }
            case .loading:
                anyLoading = true
            case .failed:
                break
            }
        }

        // No loaded data anywhere: surface loading vs. all-failed, color amber.
        guard !candidates.isEmpty else {
            return (anyLoading ? "…" : "⚠", .amber)
        }

        let reached = candidates.filter { $0.window.usedPercent >= 100 }
        let anyRed = reached.isEmpty == false || candidates.contains { $0.window.color() == .red }
        let anyAmber = candidates.contains { $0.window.color() == .amber }
        let color: GaugeColor = anyRed ? .red : (anyAmber ? .amber : .green)

        // Reached first: among reached windows pick the one reopening SOONEST.
        if let soonest = reached.min(by: { $0.window.resetsAt < $1.window.resetsAt }) {
            return ("⛔ \(tagPrefix(soonest.tag))\(soonest.window.countdown(now: soonest.now))", color)
        }

        // Else tightest: max usedPercent (≡ min remaining) across all candidates.
        let tightest = candidates.max(by: { $0.window.usedPercent < $1.window.usedPercent })!  // candidates non-empty (guarded above)
        return ("◔ \(tagPrefix(tightest.tag))\(Int(tightest.window.usedPercent.rounded()))%", color)
    }
}
