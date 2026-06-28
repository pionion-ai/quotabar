import Foundation

struct Settings {
    var threshold: Double?   // nil = alerts off

    private static let key = "alertThresholdPercent"  // store -1 for "off"

    static func load(_ defaults: UserDefaults = .standard) -> Settings {
        guard defaults.object(forKey: key) != nil else { return Settings(threshold: nil) }
        let v = defaults.double(forKey: key)
        return Settings(threshold: v >= 0 ? v : nil)
    }

    func save(_ defaults: UserDefaults = .standard) {
        defaults.set(threshold ?? -1, forKey: Self.key)
    }
}
