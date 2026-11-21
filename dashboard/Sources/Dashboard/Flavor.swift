import Foundation

/// Which distribution this binary was built for. The Mac App Store build is
/// compiled with `-Xswiftc -DAPPSTORE` (see package-appstore.sh): it runs in
/// the App Sandbox and offers only the providers that work there.
enum Flavor {
    #if APPSTORE
    static let isAppStore = true
    #else
    static let isAppStore = false
    #endif

    /// Provider ids this flavor registers, in display order. Gemini and Cursor
    /// need file/process access the sandbox doesn't grant.
    static func providerIDs(appStore: Bool) -> [String] {
        appStore ? ["claude", "codex"] : ["claude", "codex", "gemini", "cursor"]
    }
}
