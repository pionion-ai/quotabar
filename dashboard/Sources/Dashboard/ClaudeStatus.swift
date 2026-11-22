import Foundation

/// Reads the file QuotaBar's status-line bridge writes from inside Claude
/// Code: `{"rate_limits": {five_hour, seven_day}, "written_at": <unix s>}`.
/// `rate_limits` is Claude Code's documented status-line field — the only
/// sanctioned source of subscription usage; no credential is ever read.
enum ClaudeStatusDecoder {
    private struct Window: Decodable {
        let used_percentage: Double?
        let resets_at: Double?
    }
    private struct RateLimits: Decodable {
        let five_hour: Window?
        let seven_day: Window?
    }
    private struct File: Decodable {
        let rate_limits: RateLimits
        let written_at: Double?
    }

    static func windows(from data: Data, now: Date) throws -> [UsageWindow] {
        let file = try JSONDecoder().decode(File.self, from: data)
        let note = file.written_at.map { freshness(writtenAt: Date(timeIntervalSince1970: $0), now: now) }
        let known: [(key: String, label: String, window: Window?)] = [
            ("five_hour", "5-hour", file.rate_limits.five_hour),
            ("seven_day", "7-day", file.rate_limits.seven_day),
        ]
        return known.compactMap { k in
            // A window missing a field is skipped; the other one still shows.
            guard let w = k.window, let used = w.used_percentage, let at = w.resets_at else { return nil }
            let resets = Date(timeIntervalSince1970: at)
            // Past its reset the percentage is stale (Claude Code drops it too).
            guard resets > now else { return nil }
            return UsageWindow(key: k.key, label: k.label, usedPercent: used,
                               resetsAt: resets, note: note)
        }
    }

    static func freshness(writtenAt: Date, now: Date) -> String {
        let ago = max(0, now.timeIntervalSince(writtenAt))
        let when: String
        switch ago {
        case ..<60: when = "updated just now"
        case ..<3600: when = "updated \(Int(ago / 60)) min ago"
        case ..<86_400: when = "updated \(Int(ago / 3600)) h ago"
        default: when = "updated \(Int(ago / 86_400)) d ago"
        }
        return when + " · updates while Claude Code runs"
    }
}

struct ClaudeStatusProvider: UsageProviding {
    let path: String
    let now: () -> Date

    init(path: String, now: @escaping () -> Date) {
        self.path = path
        self.now = now
    }

    func fetch() async throws -> [UsageWindow] {
        guard let data = FileManager.default.contents(atPath: path) else { throw FetchError.notConnected }
        do { return try ClaudeStatusDecoder.windows(from: data, now: now()) }
        catch { throw FetchError.decode }
    }

    static func statusPath(home: String = CodexUsageClient.realHomeDirectory()) -> String {
        (home as NSString).appendingPathComponent(".quotabar/claude-status.json")
    }

    static func live() -> ClaudeStatusProvider {
        ClaudeStatusProvider(path: statusPath(), now: Date.init)
    }
}
