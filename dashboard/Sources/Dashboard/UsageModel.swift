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

enum GaugeColor { case green, amber, red }

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
}
