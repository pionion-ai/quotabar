import Foundation

struct UsageWindow: Equatable {
    let key: String
    let label: String
    let usedPercent: Double
    let resetsAt: Date
}

enum WindowState: Equatable {
    case ok(remaining: Double)
    case reached(reopensAt: Date)
}

enum GaugeColor: Equatable { case green, amber, red }

extension UsageWindow {
    var remainingPercent: Double { min(100, max(0, 100 - usedPercent)) }

    var state: WindowState {
        usedPercent >= 100 ? .reached(reopensAt: resetsAt) : .ok(remaining: remainingPercent)
    }

    func color() -> GaugeColor {
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
