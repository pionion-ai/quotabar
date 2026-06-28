import Foundation

enum CodexUsageDecoder {
    // limit_window_seconds → label. Windows are distinguished by their
    // configured window length, not key order, so order in the JSON is irrelevant.
    static let windowLabels: [Int: String] = [18000: "5-hour", 604800: "7-day"]

    private static func label(forWindowSeconds seconds: Int?) -> String {
        guard let seconds else { return "window" }
        return windowLabels[seconds] ?? "\(seconds)s window"
    }

    private struct Window: Decodable {
        let used_percent: Double?
        let limit_window_seconds: Int?
        let reset_at: Double?
    }

    private struct RateLimit: Decodable {
        let primary_window: Window?
        let secondary_window: Window?
    }

    // All-optional fields: the many extra/null top-level keys (credits,
    // spend_control, promo, additional_rate_limits, …) must not break decoding.
    private struct Payload: Decodable {
        let rate_limit: RateLimit?
    }

    static func windows(from data: Data) throws -> [UsageWindow] {
        // Throws if the top level is not a JSON object (preserves garbage-throws behavior).
        let payload = try JSONDecoder().decode(Payload.self, from: data)

        // Display order: primary first, then secondary.
        let entries: [(key: String, window: Window?)] = [
            ("codex_primary", payload.rate_limit?.primary_window),
            ("codex_secondary", payload.rate_limit?.secondary_window),
        ]

        return entries.compactMap { entry in
            guard let window = entry.window,
                  let used = window.used_percent,
                  let resetAt = window.reset_at
            else { return nil }
            return UsageWindow(key: entry.key,
                               label: label(forWindowSeconds: window.limit_window_seconds),
                               usedPercent: Double(used),
                               resetsAt: Date(timeIntervalSince1970: resetAt))
        }
    }
}
