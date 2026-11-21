import Foundation

/// How a window participates in limits. `.info` and `.share` are display-only:
/// they render as gauges but never read as "reached", never alert, and never
/// drive the menu-bar title.
enum WindowStyle: Equatable {
    case limit  // a real quota that blocks usage at 100%
    case info   // a quota that currently doesn't block (e.g. overflow billing is available)
    case share  // a slice of the whole (e.g. one model's share of spend), not a quota
}

struct UsageWindow: Equatable {
    let key: String
    let label: String
    let usedPercent: Double
    let resetsAt: Date
    var style: WindowStyle = .limit
    /// Optional extra line under the label (e.g. "$0.82 / $25").
    var detail: String? = nil
    /// Optional caption for the group this window belongs to (e.g. what the
    /// per-model dollars are covered by). Shared by every window in the group.
    var note: String? = nil
}

enum WindowState: Equatable {
    case ok(remaining: Double)
    case reached(reopensAt: Date)
}

enum GaugeColor: Equatable { case green, amber, red, neutral, muted }

extension UsageWindow {
    var remainingPercent: Double { min(100, max(0, 100 - usedPercent)) }

    var countsTowardLimit: Bool { style == .limit }

    var state: WindowState {
        countsTowardLimit && usedPercent >= 100
            ? .reached(reopensAt: resetsAt) : .ok(remaining: remainingPercent)
    }

    func color() -> GaugeColor {
        if style == .share { return .neutral }
        if style == .info { return .muted }
        switch usedPercent {
        case ..<75: return .green
        case ..<90: return .amber
        default: return .red
        }
    }

    func countdown(now: Date) -> String {
        let total = Int(resetsAt.timeIntervalSince(now))
        if total <= 0 { return "now" }

        if case .reached = state {
            let h = total / 3600, m = (total % 3600) / 60, s = total % 60
            return String(format: "%d:%02d:%02d", h, m, s)
        }

        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        var parts: [String] = []
        if days > 0 { parts.append("\(days)d") }
        if hours > 0 { parts.append("\(hours)h") }
        if minutes > 0 || parts.isEmpty { parts.append("\(minutes)m") }
        return parts.joined(separator: " ")
    }
}
