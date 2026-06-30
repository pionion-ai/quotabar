import Foundation

enum GeminiUsageDecoder {
    // A bucket from retrieveUserQuota. All fields optional: `remainingAmount`
    // is omitted when a bucket is full, and any extra/missing field must not
    // break decoding. `remainingFraction` is the source of truth.
    private struct Bucket: Decodable {
        let modelId: String?
        let remainingFraction: Double?
        let resetTime: String?
        let tokenType: String?
    }

    private struct Payload: Decodable {
        let buckets: [Bucket]?
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

    // A model family: which buckets belong to it and how it's surfaced.
    private struct Family {
        let key: String
        let label: String
        let matches: (String) -> Bool
    }

    // Order matters for both matching (Pro is checked before Flash) and output
    // (Pro window emitted first, then Flash).
    private static let families: [Family] = [
        Family(key: "gemini_pro",   label: "Pro")   { $0.contains("pro") },
        Family(key: "gemini_flash", label: "Flash") { $0.contains("flash") },
    ]

    static func windows(from data: Data) throws -> [UsageWindow] {
        // Throws if the top level is not a JSON object (preserves garbage-throws behavior).
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        let buckets = payload.buckets ?? []

        return families.compactMap { family in
            // Only buckets with both a fraction and a reset time are usable;
            // assign each to the first family it matches.
            let usable = buckets.compactMap { bucket -> (fraction: Double, date: Date)? in
                guard let model = bucket.modelId?.lowercased(),
                      let fraction = bucket.remainingFraction,
                      let iso = bucket.resetTime,
                      let date = parseDate(iso)
                else { return nil }
                // First-match family assignment: a "pro" model never lands in Flash.
                let assigned = families.first { $0.matches(model) }
                guard assigned?.key == family.key else { return nil }
                return (fraction, date)
            }

            // Tightest = lowest remainingFraction (closest to exhausted).
            guard let tightest = usable.min(by: { $0.fraction < $1.fraction }) else {
                return nil
            }
            let usedPercent = (100 * (1 - tightest.fraction)).rounded()
            return UsageWindow(key: family.key, label: family.label,
                               usedPercent: usedPercent, resetsAt: tightest.date)
        }
    }
}
