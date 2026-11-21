import Foundation

enum CursorUsageDecoder {
    /// Model gauges shown individually; the rest fold into one "N others" gauge.
    static let topModels = 5

    // Protobuf-JSON: int64 fields (timestamps, token counts) arrive as strings,
    // doubles as numbers. Every field is optional so extra/missing keys don't
    // break decoding.
    struct Period: Decodable {
        struct PlanUsage: Decodable {
            let autoPercentUsed: Double?
            let apiPercentUsed: Double?
            // Cents of usage value this cycle, and what covered it.
            let totalSpend: Double?
            let includedSpend: Double?
            let bonusSpend: Double?
        }
        struct SpendLimitUsage: Decodable {
            let individualUsed: Double?
            let individualLimit: Double?
            let individualRemaining: Double?
        }
        let billingCycleStart: String?
        let billingCycleEnd: String?
        let planUsage: PlanUsage?
        let spendLimitUsage: SpendLimitUsage?

        var cycleStartMs: Int64? { billingCycleStart.flatMap { Int64($0) } }
        var cycleEnd: Date? {
            billingCycleEnd.flatMap { Double($0) }.map { Date(timeIntervalSince1970: $0 / 1000) }
        }
    }

    private struct Aggregated: Decodable {
        struct Row: Decodable {
            let modelIntent: String?
            let totalCents: Double?
        }
        let aggregations: [Row]?
    }

    /// Throws unless the payload is an object carrying a billing cycle.
    static func period(from data: Data) throws -> Period {
        let period = try JSONDecoder().decode(Period.self, from: data)
        guard period.cycleStartMs != nil, period.cycleEnd != nil else {
            throw FetchError.decode
        }
        return period
    }

    static func windows(period data: Data, models: Data?) throws -> [UsageWindow] {
        windows(period: try period(from: data), models: models)
    }

    static func windows(period: Period, models: Data?) -> [UsageWindow] {
        let resets = period.cycleEnd!  // validated in period(from:)
        var windows: [UsageWindow] = []

        // On-demand spend: a real hard cap, in dollars.
        var onDemandHasHeadroom = false
        if let spend = period.spendLimitUsage, let limit = spend.individualLimit, limit > 0 {
            let used = spend.individualUsed ?? 0
            let remaining = spend.individualRemaining ?? (limit - used)
            onDemandHasHeadroom = remaining > 0
            windows.append(UsageWindow(key: "cursor_on_demand", label: "On-demand",
                                       usedPercent: used / limit * 100, resetsAt: resets,
                                       detail: "\(dollars(used)) / \(dollars(limit, cents: false))"))
        }

        // Included pools only block usage when there's no on-demand to spill into.
        let poolStyle: WindowStyle = onDemandHasHeadroom ? .info : .limit
        let pools: [UsageWindow] = [
            period.planUsage?.apiPercentUsed.map {
                UsageWindow(key: "cursor_api", label: "API", usedPercent: $0, resetsAt: resets, style: poolStyle)
            },
            period.planUsage?.autoPercentUsed.map {
                UsageWindow(key: "cursor_auto", label: "Auto", usedPercent: $0, resetsAt: resets, style: poolStyle)
            },
        ].compactMap { $0 }
        windows.insert(contentsOf: pools, at: 0)

        if let models {
            windows += shareWindows(from: models, resets: resets, note: coverageNote(period.planUsage))
        }
        return windows
    }

    /// The per-model dollars are list-price usage value, not charges: say what
    /// covered them, e.g. "$48.82 used · $20 included + $28.82 bonus".
    private static func coverageNote(_ plan: Period.PlanUsage?) -> String? {
        guard let plan, let total = plan.totalSpend else { return nil }
        let parts = [(plan.includedSpend, "included"), (plan.bonusSpend, "bonus")]
            .compactMap { cents, name in cents.flatMap { $0 > 0 ? "\(dollars($0, cents: false)) \(name)" : nil } }
        return parts.isEmpty ? "\(dollars(total)) used" : "\(dollars(total)) used · \(parts.joined(separator: " + "))"
    }

    /// Each model's share of this cycle's usage value. A breakdown, not a quota.
    private static func shareWindows(from data: Data, resets: Date, note: String?) -> [UsageWindow] {
        guard let rows = try? JSONDecoder().decode(Aggregated.self, from: data).aggregations else { return [] }
        let spend = rows
            .map { (model: $0.modelIntent ?? "unknown", cents: $0.totalCents ?? 0) }
            .filter { $0.cents > 0 }
            .sorted { $0.cents > $1.cents }
        let total = spend.reduce(0) { $0 + $1.cents }
        guard total > 0 else { return [] }

        func share(_ key: String, _ label: String, _ cents: Double) -> UsageWindow {
            UsageWindow(key: key, label: label, usedPercent: cents / total * 100,
                        resetsAt: resets, style: .share, detail: dollars(cents), note: note)
        }

        var windows = spend.prefix(topModels).map { share("cursor_model_\($0.model)", $0.model, $0.cents) }
        let rest = spend.dropFirst(topModels)
        if !rest.isEmpty {
            let label = rest.count == 1 ? rest.first!.model : "\(rest.count) others"
            windows.append(share("cursor_model_other", label, rest.reduce(0) { $0 + $1.cents }))
        }
        return windows
    }

    /// Cents → "$42.09"; whole-dollar caps read as "$25".
    static func dollars(_ cents: Double, cents showCents: Bool = true) -> String {
        if !showCents && cents.truncatingRemainder(dividingBy: 100) == 0 {
            return "$\(Int(cents / 100))"
        }
        return String(format: "$%.2f", cents / 100)
    }
}
