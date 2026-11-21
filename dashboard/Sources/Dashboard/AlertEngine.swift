import Foundation

enum AlertEvent: Equatable {
    case approaching(label: String, countdown: String)
    case reached(label: String, countdown: String)
}

struct AlertEngine {
    var threshold: Double?

    // Highest band each window has alerted at: 0 none, 1 approaching, 2 reached.
    private enum Level: Int { case none, approaching, reached }
    private var lastLevel: [String: Level] = [:]

    init(threshold: Double?) {
        self.threshold = threshold
    }

    private func band(for w: UsageWindow) -> Level {
        if w.usedPercent >= 100 { return .reached }
        if let t = threshold, w.usedPercent >= t { return .approaching }
        return .none
    }

    mutating func evaluate(_ windows: [UsageWindow], now: Date) -> [AlertEvent] {
        var events: [AlertEvent] = []
        for w in windows where w.countsTowardLimit {
            let current = band(for: w)
            let previous = lastLevel[w.key] ?? .none
            if current.rawValue > previous.rawValue {
                switch current {
                case .approaching:
                    events.append(.approaching(label: w.label, countdown: w.countdown(now: now)))
                case .reached:
                    events.append(.reached(label: w.label, countdown: w.countdown(now: now)))
                case .none:
                    break
                }
            }
            lastLevel[w.key] = current
        }
        return events
    }
}
