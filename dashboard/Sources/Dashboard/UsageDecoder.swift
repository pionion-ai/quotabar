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

        return knownWindows.compactMap { known in
            guard let block = payload.blocks[known.key],
                  let util = block.utilization,
                  let iso = block.resets_at,
                  let date = parseDate(iso)
            else { return nil }
            return UsageWindow(key: known.key, label: known.label,
                               usedPercent: util, resetsAt: date)
        }
    }
}
