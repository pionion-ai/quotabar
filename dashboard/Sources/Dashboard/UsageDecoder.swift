import Foundation

enum UsageDecoder {
    // key → label, in display order.
    static let knownWindows: [(key: String, label: String)] = [
        ("five_hour", "5-hour session"),
        ("seven_day", "7-day (all models)"),
        ("seven_day_opus", "7-day (Opus)"),
        ("seven_day_sonnet", "7-day (Sonnet)"),
    ]

    private struct Block: Decodable {
        let utilization: Double?
        let resets_at: String?
    }

    static func windows(from data: Data) throws -> [UsageWindow] {
        let blocks = try JSONDecoder().decode([String: Block].self, from: data)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        return knownWindows.compactMap { known in
            guard let block = blocks[known.key],
                  let util = block.utilization,
                  let iso = block.resets_at,
                  let date = formatter.date(from: iso)
            else { return nil }
            return UsageWindow(key: known.key, label: known.label,
                               usedPercent: util, resetsAt: date)
        }
    }
}
