import Foundation

enum UsageDecoder {
    // key → label, in display order.
    static let knownWindows: [(key: String, label: String)] = [
        ("five_hour", "5-hour"),
        ("seven_day", "7-day"),
        ("seven_day_opus", "7-day Opus"),
        ("seven_day_sonnet", "7-day Sonnet"),
    ]

    private struct Block: Decodable {
        let utilization: Double?
        let resets_at: String?
    }

    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static func parseDate(_ s: String) -> Date? {
        isoFractional.date(from: s) ?? isoPlain.date(from: s)
    }

    private struct DynamicKey: CodingKey {
        let stringValue: String
        init(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        init?(intValue: Int) { nil }
    }

    private struct Payload: Decodable {
        let blocks: [String: Block]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)
            var result: [String: Block] = [:]
            for known in UsageDecoder.knownWindows {
                let key = DynamicKey(stringValue: known.key)
                // decodeIfPresent → nil for an absent key OR a JSON null;
                // try? swallows a type mismatch on a wrong-typed value.
                if let block = try? container.decodeIfPresent(Block.self, forKey: key) {
                    result[known.key] = block
                }
            }
            self.blocks = result
        }
    }

    static func windows(from data: Data) throws -> [UsageWindow] {
        // Throws if the top level is not a JSON object (preserves garbage-throws behavior).
        let payload = try JSONDecoder().decode(Payload.self, from: data)

        let named: [UsageWindow] = knownWindows.compactMap { known in
            guard let block = payload.blocks[known.key],
                  let util = block.utilization,
                  let iso = block.resets_at,
                  let date = parseDate(iso)
            else { return nil }
            return UsageWindow(key: known.key, label: known.label,
                               usedPercent: util, resetsAt: date)
        }
        // A model with its own named key (e.g. seven_day_sonnet) keeps that gauge.
        let namedLabels = Set(named.map(\.label))
        return named + modelScopedWeekly(from: data).filter { !namedLabels.contains($0.label) }
    }

    /// Per-model weekly limits that exist only in the `limits` list, e.g.
    /// `{"kind":"weekly_scoped","percent":11,"resets_at":…,
    ///   "scope":{"model":{"display_name":"Fable"}}}` → "7-day Fable".
    /// Read leniently: any malformed entry is skipped.
    private static func modelScopedWeekly(from data: Data) -> [UsageWindow] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limits = root["limits"] as? [Any] else { return [] }
        var seen = Set<String>()
        return limits.compactMap { item in
            guard let entry = item as? [String: Any],
                  entry["kind"] as? String == "weekly_scoped",
                  let percent = (entry["percent"] as? NSNumber)?.doubleValue,
                  let iso = entry["resets_at"] as? String, let date = parseDate(iso),
                  let scope = entry["scope"] as? [String: Any],
                  let model = scope["model"] as? [String: Any],
                  let name = (model["display_name"] as? String)?.trimmingCharacters(in: .whitespaces),
                  !name.isEmpty
            else { return nil }
            let key = "weekly_scoped_" + name.lowercased().replacingOccurrences(of: " ", with: "_")
            guard seen.insert(key).inserted else { return nil }
            return UsageWindow(key: key, label: "7-day \(name)", usedPercent: percent, resetsAt: date)
        }
    }
}
