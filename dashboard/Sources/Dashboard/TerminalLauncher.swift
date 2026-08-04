import Foundation
import AppKit

/// Opens Terminal.app running a login CLI.
///
/// Deliberately NOT AppleScript: `tell app "Terminal" to do script` needs
/// NSAppleEventsUsageDescription plus an Automation consent dialog. Writing an
/// executable `.command` file and handing it to NSWorkspace needs neither —
/// the app is not sandboxed.
struct TerminalLauncher {
    let baseDirectory: URL
    let open: (URL) -> Void

    init(baseDirectory: URL, open: @escaping (URL) -> Void) {
        self.baseDirectory = baseDirectory
        self.open = open
    }

    /// Writes `relogin-<providerID>.command` and opens it. The command comes
    /// from AuthRecovery — a compile-time constant, never user input.
    ///
    /// Failures are swallowed: the button is a convenience, and the popover
    /// still shows the underlying auth error if nothing launches.
    func launch(command: String, providerID: String) {
        let url = baseDirectory.appendingPathComponent("relogin-\(providerID).command")
        let script = "#!/bin/sh\nexec \(command)\n"
        do {
            try FileManager.default.createDirectory(at: baseDirectory,
                                                    withIntermediateDirectories: true)
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                  ofItemAtPath: url.path)
        } catch {
            return
        }
        open(url)
    }

    /// Real wiring: the app's cache directory, opened via NSWorkspace.
    static let live = TerminalLauncher(
        baseDirectory: FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ai.pionion.quotabar"),
        open: { NSWorkspace.shared.open($0) }
    )
}
