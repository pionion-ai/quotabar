# Re-login Affordance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a provider's auth fails, show a per-provider button in the dashboard popover that opens Terminal running the correct login CLI.

**Architecture:** A pure `AuthRecovery` enum decides *whether* a button appears and *what it says* from `(FetchError, providerID)` — unit-tested directly, like the existing `DashboardCoordinator.aggregate`. A thin `TerminalLauncher` performs the OS side effect through two injected seams (`baseDirectory`, `open`), matching the `tokenReader`/`transport` pattern used by every provider client. `GaugesView` only renders what `AuthRecovery` returns. The dashboard notices the new token by refreshing when the popover opens.

**Tech Stack:** Swift 5.9, SwiftUI (`MenuBarExtra`), XCTest, SwiftPM (`dashboard/Package.swift`, macOS 13+).

## Global Constraints

- Working directory for all commands: the repo's `dashboard/` directory.
- Build/test command: `swift test` (there is no other runner). Build the app with `./build-app.sh`.
- Spec: `docs/superpowers/specs/2026-07-26-relogin-affordance-design.md`. It is authoritative; this plan implements it exactly.
- Provider ids are the existing `DashboardCoordinator.ProviderEntry.id` values, exactly: `"claude"`, `"codex"`, `"gemini"`. No new field is added to `ProviderEntry`.
- Login commands, verbatim: `claude` → `claude`; `codex` → `codex login`; `gemini` → `gemini`.
- A button appears **only** for `FetchError.authExpired` and `FetchError.notLoggedIn`. Never for `.rateLimited`, `.network`, `.decode`.
- An unrecognised provider id returns `nil` — fail closed rather than offer a wrong command.
- The dashboard must never write to a credential store (`~/.codex/auth.json`, `~/.gemini/oauth_creds.json`, the Keychain). This feature only *reads* error state and *launches* a CLI.
- Never log or interpolate token material. The only string written to the launch script is a compile-time constant from `AuthRecovery`.
- No AppleScript / Apple Events — that would require `NSAppleEventsUsageDescription` and a TCC consent dialog. Use `NSWorkspace.open`.
- No view tests. The existing suite has none; keep it that way and test the pure layer instead.
- Out of scope: proactive `expiresAt` warnings, faster retry while 401-ing, clipboard fallback, any token refresh.

---

## File Structure

| File | Responsibility |
|---|---|
| `Sources/Dashboard/AuthRecovery.swift` (new) | Pure: does this error deserve a button, and what does it say? |
| `Sources/Dashboard/TerminalLauncher.swift` (new) | Side effect: write a `.command` script and open it |
| `Sources/Dashboard/GaugesView.swift` (modify) | Render the prompt in both the error view and the stale hint |
| `Sources/Dashboard/DashboardCoordinator.swift` (modify) | `refreshAll()` |
| `Sources/Dashboard/DashboardApp.swift` (modify) | Refresh on popover open |
| `Tests/DashboardTests/AuthRecoveryTests.swift` (new) | Decision table coverage |
| `Tests/DashboardTests/TerminalLauncherTests.swift` (new) | Script contents + mode, temp dir |
| `Tests/DashboardTests/DashboardCoordinatorTests.swift` (modify) | `refreshAll()` |
| `dashboard/README.md` (modify) | Document the affordance and its limits |

Task order: 1 (AuthRecovery) → 2 (TerminalLauncher) → 3 (GaugesView) → 4 (refresh on open) → 5 (docs). Tasks 1 and 2 are independent of each other; 3 consumes both.

---

### Task 1: AuthRecovery — the pure decision

**Files:**
- Create: `Sources/Dashboard/AuthRecovery.swift`
- Test: `Tests/DashboardTests/AuthRecoveryTests.swift`

**Interfaces:**
- Consumes: `FetchError` (already defined in `Sources/Dashboard/UsageClient.swift:3-9`, cases `.notLoggedIn`, `.authExpired`, `.rateLimited`, `.network(String)`, `.decode`).
- Produces:
  - `struct ReloginPrompt: Equatable { let message: String; let buttonTitle: String; let command: String }`
  - `enum AuthRecovery { static func prompt(for: FetchError, provider: String) -> ReloginPrompt?; static func staleMessage(for: FetchError, provider: String) -> String }`

- [ ] **Step 1: Write the failing test**

Create `Tests/DashboardTests/AuthRecoveryTests.swift`:

```swift
import XCTest
@testable import Dashboard

final class AuthRecoveryTests: XCTestCase {

    // MARK: - Which errors get a button

    func testAuthErrorsProduceAPrompt() {
        for error in [FetchError.authExpired, .notLoggedIn] {
            for provider in ["claude", "codex", "gemini"] {
                XCTAssertNotNil(AuthRecovery.prompt(for: error, provider: provider),
                                "\(error) / \(provider) should offer a re-login")
            }
        }
    }

    func testNonAuthErrorsProduceNoPrompt() {
        for error in [FetchError.rateLimited, .network("offline"), .decode] {
            for provider in ["claude", "codex", "gemini"] {
                XCTAssertNil(AuthRecovery.prompt(for: error, provider: provider),
                             "\(error) / \(provider) is not fixable by re-login")
            }
        }
    }

    func testUnknownProviderFailsClosed() {
        XCTAssertNil(AuthRecovery.prompt(for: .authExpired, provider: "openai"))
        XCTAssertNil(AuthRecovery.prompt(for: .authExpired, provider: ""))
    }

    // MARK: - Commands

    func testCommandPerProvider() {
        XCTAssertEqual(AuthRecovery.prompt(for: .authExpired, provider: "claude")?.command, "claude")
        XCTAssertEqual(AuthRecovery.prompt(for: .authExpired, provider: "codex")?.command, "codex login")
        XCTAssertEqual(AuthRecovery.prompt(for: .authExpired, provider: "gemini")?.command, "gemini")
    }

    func testButtonTitleNamesTheProvider() {
        XCTAssertEqual(AuthRecovery.prompt(for: .authExpired, provider: "claude")?.buttonTitle,
                       "Re-login to Claude Code…")
        XCTAssertEqual(AuthRecovery.prompt(for: .authExpired, provider: "codex")?.buttonTitle,
                       "Re-login to Codex…")
        XCTAssertEqual(AuthRecovery.prompt(for: .authExpired, provider: "gemini")?.buttonTitle,
                       "Re-login to Gemini…")
    }

    // The bug this feature fixes: every provider used to be told to run `claude`.
    func testMessageNeverNamesTheWrongCli() {
        let codex = AuthRecovery.prompt(for: .authExpired, provider: "codex")!
        XCTAssertFalse(codex.message.contains("claude"))
        XCTAssertFalse(codex.buttonTitle.contains("Claude"))
    }

    func testExpiredAndNotLoggedInReadDifferently() {
        let expired = AuthRecovery.prompt(for: .authExpired, provider: "claude")!
        let missing = AuthRecovery.prompt(for: .notLoggedIn, provider: "claude")!
        XCTAssertEqual(expired.message, "Session expired.")
        XCTAssertEqual(missing.message, "Not signed in.")
        XCTAssertEqual(expired.command, missing.command)
    }

    // Gemini self-refreshes, so a failure there means the refresh token itself died.
    func testGeminiMessageIsWordedForItsCase() {
        let gemini = AuthRecovery.prompt(for: .notLoggedIn, provider: "gemini")!
        XCTAssertEqual(gemini.message, "Sign-in expired.")
    }

    // MARK: - Stale hint

    func testStaleMessageForNonAuthErrorsIsUnchanged() {
        XCTAssertEqual(AuthRecovery.staleMessage(for: .rateLimited, provider: "claude"),
                       "Rate limited — retrying soon")
        XCTAssertEqual(AuthRecovery.staleMessage(for: .network("x"), provider: "claude"),
                       "Couldn't refresh — showing last update")
        XCTAssertEqual(AuthRecovery.staleMessage(for: .decode, provider: "claude"),
                       "Couldn't refresh — showing last update")
    }

    func testStaleMessageForAuthErrorsSaysSo() {
        XCTAssertEqual(AuthRecovery.staleMessage(for: .authExpired, provider: "codex"),
                       "Session expired — numbers may be stale")
        XCTAssertEqual(AuthRecovery.staleMessage(for: .notLoggedIn, provider: "gemini"),
                       "Sign-in expired — numbers may be stale")
    }

    func testStaleMessageForUnknownProviderFallsBackToGenericText() {
        XCTAssertEqual(AuthRecovery.staleMessage(for: .authExpired, provider: "openai"),
                       "Couldn't refresh — showing last update")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AuthRecoveryTests`
Expected: FAIL — compile error, `cannot find 'AuthRecovery' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/Dashboard/AuthRecovery.swift`:

```swift
import Foundation

/// What to show a user whose provider session has died: a sentence, a button
/// label, and the shell command that fixes it.
struct ReloginPrompt: Equatable {
    let message: String
    let buttonTitle: String
    let command: String
}

/// PURE decisions about auth failures. The dashboard never refreshes tokens
/// itself — the owning CLI does — so recovery is always "go run this command".
enum AuthRecovery {

    /// The CLI that owns each provider's credentials. An unknown id yields nil
    /// so we fail closed rather than suggest the wrong tool.
    private static func cli(for provider: String) -> (name: String, command: String)? {
        switch provider {
        case "claude": return ("Claude Code", "claude")
        case "codex":  return ("Codex", "codex login")
        case "gemini": return ("Gemini", "gemini")
        default:       return nil
        }
    }

    /// Gemini mints its own access tokens on every fetch, so a failure there
    /// means the long-lived refresh token died — worded differently on purpose.
    private static func message(for error: FetchError, provider: String) -> String? {
        switch (error, provider) {
        case (.authExpired, "gemini"), (.notLoggedIn, "gemini"): return "Sign-in expired."
        case (.authExpired, _): return "Session expired."
        case (.notLoggedIn, _): return "Not signed in."
        default: return nil
        }
    }

    /// Non-nil only for failures the user can fix by re-running a CLI.
    static func prompt(for error: FetchError, provider: String) -> ReloginPrompt? {
        guard let cli = cli(for: provider),
              let message = message(for: error, provider: provider) else { return nil }
        return ReloginPrompt(message: message,
                             buttonTitle: "Re-login to \(cli.name)…",
                             command: cli.command)
    }

    /// The quiet hint under still-visible gauges after a failed refresh. Auth
    /// failures say so; everything else keeps the pre-existing wording.
    static func staleMessage(for error: FetchError, provider: String) -> String {
        if let prompt = prompt(for: error, provider: provider) {
            // "Session expired." → "Session expired — numbers may be stale"
            let stem = prompt.message.hasSuffix(".") ? String(prompt.message.dropLast()) : prompt.message
            return "\(stem) — numbers may be stale"
        }
        switch error {
        case .rateLimited: return "Rate limited — retrying soon"
        default:           return "Couldn't refresh — showing last update"
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter AuthRecoveryTests`
Expected: PASS, 10 tests.

Note `testStaleMessageForAuthErrorsSaysSo` expects `"Session expired — numbers may be stale"` for `.authExpired`/codex and `"Sign-in expired — numbers may be stale"` for `.notLoggedIn`/gemini — both fall out of the stem-stripping above. If they don't match, fix the implementation, not the test.

- [ ] **Step 5: Commit**

```bash
git add Sources/Dashboard/AuthRecovery.swift Tests/DashboardTests/AuthRecoveryTests.swift
git commit -m "feat(dashboard): AuthRecovery — pure per-provider re-login decision

Auth failures are the one FetchError a user can fix, and the fix differs per
provider. Decide message/button/command in a pure function so the view layer
stops hardcoding \`claude\` for everyone."
```

---

### Task 2: TerminalLauncher — the side effect

**Files:**
- Create: `Sources/Dashboard/TerminalLauncher.swift`
- Test: `Tests/DashboardTests/TerminalLauncherTests.swift`

**Interfaces:**
- Consumes: nothing from Task 1 (independent).
- Produces:
  - `struct TerminalLauncher { let baseDirectory: URL; let open: (URL) -> Void; init(baseDirectory:open:); func launch(command: String, providerID: String); static let live: TerminalLauncher }`

- [ ] **Step 1: Write the failing test**

Create `Tests/DashboardTests/TerminalLauncherTests.swift`:

```swift
import XCTest
@testable import Dashboard

final class TerminalLauncherTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("launcher-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testWritesAnExecutableScriptAndOpensIt() throws {
        var opened: [URL] = []
        let launcher = TerminalLauncher(baseDirectory: tempDir, open: { opened.append($0) })

        launcher.launch(command: "codex login", providerID: "codex")

        XCTAssertEqual(opened.count, 1)
        let url = try XCTUnwrap(opened.first)
        XCTAssertEqual(url.lastPathComponent, "relogin-codex.command")

        let script = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(script.hasPrefix("#!/bin/sh\n"), "script was: \(script)")
        XCTAssertTrue(script.contains("exec codex login"), "script was: \(script)")

        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.int16Value, 0o755)
    }

    func testCreatesTheBaseDirectoryOnDemand() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.path))
        let launcher = TerminalLauncher(baseDirectory: tempDir, open: { _ in })
        launcher.launch(command: "claude", providerID: "claude")
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.path))
    }

    // Fixed per-provider filename: repeat clicks overwrite rather than litter.
    func testRepeatLaunchesReuseTheSamePath() throws {
        var opened: [URL] = []
        let launcher = TerminalLauncher(baseDirectory: tempDir, open: { opened.append($0) })
        launcher.launch(command: "claude", providerID: "claude")
        launcher.launch(command: "claude", providerID: "claude")
        XCTAssertEqual(opened.count, 2)
        XCTAssertEqual(opened[0], opened[1])
        let contents = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        XCTAssertEqual(contents, ["relogin-claude.command"])
    }

    // A launch failure is swallowed: the popover keeps its existing error text.
    func testUnwritableDirectoryDoesNotOpenAnythingOrCrash() {
        var opened: [URL] = []
        let unwritable = URL(fileURLWithPath: "/System/nope-\(UUID().uuidString)")
        let launcher = TerminalLauncher(baseDirectory: unwritable, open: { opened.append($0) })
        launcher.launch(command: "claude", providerID: "claude")
        XCTAssertTrue(opened.isEmpty)
    }

    func testLiveLauncherPointsAtTheAppCacheDirectory() {
        XCTAssertTrue(TerminalLauncher.live.baseDirectory.path
            .hasSuffix("Caches/com.claudeusage.dashboard"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter TerminalLauncherTests`
Expected: FAIL — compile error, `cannot find 'TerminalLauncher' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/Dashboard/TerminalLauncher.swift`:

```swift
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
            .appendingPathComponent("com.claudeusage.dashboard"),
        open: { NSWorkspace.shared.open($0) }
    )
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter TerminalLauncherTests`
Expected: PASS, 5 tests.

- [ ] **Step 5: Manually verify a real launch**

Run:

```bash
swift build && swift -e '
import Foundation
let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("relogin-manual")
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let url = dir.appendingPathComponent("relogin-demo.command")
try! "#!/bin/sh\nexec echo hello-from-relogin\n".write(to: url, atomically: true, encoding: .utf8)
try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
print(url.path)
'
```

Then `open <printed path>`. Expected: a Terminal window appears printing `hello-from-relogin`. This confirms the `.command`-file mechanism works on this machine before wiring it to a real login. Close the window when done.

- [ ] **Step 6: Commit**

```bash
git add Sources/Dashboard/TerminalLauncher.swift Tests/DashboardTests/TerminalLauncherTests.swift
git commit -m "feat(dashboard): TerminalLauncher — open Terminal on a login CLI

Writes an executable .command file and hands it to NSWorkspace, avoiding the
Apple Events entitlement and TCC prompt that 'do script' would require."
```

---

### Task 3: Wire the button into the popover

**Files:**
- Modify: `Sources/Dashboard/GaugesView.swift` (`ProviderSection` at :10-105, `GaugesView.body` at :116-128)

**Interfaces:**
- Consumes: `AuthRecovery.prompt(for:provider:) -> ReloginPrompt?`, `AuthRecovery.staleMessage(for:provider:) -> String` (Task 1); `TerminalLauncher.live` and `launch(command:providerID:)` (Task 2); `DashboardCoordinator.ProviderEntry.id` (existing, `DashboardCoordinator.swift:8`).
- Produces: `ProviderSection` gains `let providerID: String` and `let launch: (String, String) -> Void`. `GaugesView` gains `var launch: (String, String) -> Void` defaulting to `TerminalLauncher.live.launch(command:providerID:)`.

There is no view test in this codebase and this task does not add one — Task 1 covers the decision, Task 2 covers the side effect, and this task is the plumbing between them. Verification is a build plus the manual check in Step 5.

- [ ] **Step 1: Add the two new properties to `ProviderSection`**

In `Sources/Dashboard/GaugesView.swift`, replace:

```swift
private struct ProviderSection: View {
    @ObservedObject var store: UsageStore
    let title: String
```

with:

```swift
private struct ProviderSection: View {
    @ObservedObject var store: UsageStore
    let title: String
    let providerID: String
    /// (command, providerID) — injected so the real Terminal launch stays out
    /// of previews and any future view test.
    let launch: (String, String) -> Void
```

- [ ] **Step 2: Replace the stale hint with the AuthRecovery version**

Replace this block at the end of `content(_:)`:

```swift
        if let err = store.lastError {
            Label(staleMessage(err), systemImage: "exclamationmark.triangle")
                .font(.caption2).foregroundStyle(.secondary)
        }
```

with:

```swift
        if let err = store.lastError {
            VStack(alignment: .leading, spacing: 4) {
                Label(AuthRecovery.staleMessage(for: err, provider: providerID),
                      systemImage: "exclamationmark.triangle")
                    .font(.caption2).foregroundStyle(.secondary)
                if let prompt = AuthRecovery.prompt(for: err, provider: providerID) {
                    reloginButton(prompt)
                }
            }
        }
```

- [ ] **Step 3: Delete the now-dead private `staleMessage`**

Delete this entire method (it moved to `AuthRecovery`):

```swift
    private func staleMessage(_ error: FetchError) -> String {
        switch error {
        case .rateLimited: return "Rate limited — retrying soon"
        default:           return "Couldn't refresh — showing last update"
        }
    }
```

- [ ] **Step 4: Rewrite `errorView` and add the shared button**

Replace:

```swift
    private func errorView(_ error: FetchError) -> some View {
        let message: String
        switch error {
        case .authExpired: message = "Token expired — run `claude` once to refresh."
        case .notLoggedIn: message = "Not logged in to Claude Code."
        case .rateLimited: message = "Rate limited — pausing for a few minutes."
        case .network(let m): message = "Network error: \(m)"
        case .decode: message = "Couldn't read the usage response."
        }
        return Label(message, systemImage: "wifi.exclamationmark")
            .font(.callout).foregroundStyle(.secondary)
    }
```

with:

```swift
    @ViewBuilder private func errorView(_ error: FetchError) -> some View {
        // Auth failures are the only ones the user can act on, and the action
        // differs per provider — AuthRecovery owns both decisions.
        if let prompt = AuthRecovery.prompt(for: error, provider: providerID) {
            VStack(alignment: .leading, spacing: 6) {
                Label(prompt.message, systemImage: "person.crop.circle.badge.exclamationmark")
                    .font(.callout).foregroundStyle(.secondary)
                reloginButton(prompt)
            }
        } else {
            Label(unactionableMessage(error), systemImage: "wifi.exclamationmark")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func unactionableMessage(_ error: FetchError) -> String {
        switch error {
        case .rateLimited: return "Rate limited — pausing for a few minutes."
        case .network(let m): return "Network error: \(m)"
        case .decode: return "Couldn't read the usage response."
        // Auth errors are handled above; an unknown provider id lands here.
        case .authExpired, .notLoggedIn: return "Sign-in needed — run the CLI for \(title)."
        }
    }

    private func reloginButton(_ prompt: ReloginPrompt) -> some View {
        Button(prompt.buttonTitle) { launch(prompt.command, providerID) }
            .font(.caption)
    }
```

- [ ] **Step 5: Pass the new values from `GaugesView`**

Add the injected launcher to `GaugesView`'s properties, immediately after `var onQuit: () -> Void`:

```swift
    var launch: (String, String) -> Void = { command, providerID in
        TerminalLauncher.live.launch(command: command, providerID: providerID)
    }
```

Then replace the `ProviderSection` construction in `body`:

```swift
                ProviderSection(store: entry.store, title: entry.displayName)
```

with:

```swift
                ProviderSection(store: entry.store,
                                title: entry.displayName,
                                providerID: entry.id,
                                launch: launch)
```

- [ ] **Step 6: Build and run the full suite**

Run: `swift test`
Expected: PASS, all tests including the 15 added in Tasks 1-2. No compile warnings about unused `staleMessage`.

- [ ] **Step 7: Manually verify in the real app**

Run: `./build-app.sh && open Dashboard.app`

Expected: the popover renders normally, with gauges for each configured provider and no button (you are logged in). To see the button without waiting for a token to expire, temporarily point Claude's reader at a bad token:

```bash
# In Sources/Dashboard/UsageClient.swift, temporarily replace the body of
# readKeychainToken with:  throw FetchError.notLoggedIn
./build-app.sh && open Dashboard.app
```

Expected: the Claude Code section shows "Not signed in." and a **Re-login to Claude Code…** button; clicking it opens a Terminal window running `claude`. **Revert that edit before committing** (`git checkout Sources/Dashboard/UsageClient.swift`) and rebuild.

- [ ] **Step 8: Commit**

```bash
git add Sources/Dashboard/GaugesView.swift
git commit -m "feat(dashboard): per-provider re-login button in the popover

Both the blank error view and the stale hint now offer the right CLI for the
provider that failed, replacing text that told every user to run \`claude\`."
```

---

### Task 4: Refresh when the popover opens

**Files:**
- Modify: `Sources/Dashboard/DashboardCoordinator.swift:27` (next to `startAll()`)
- Modify: `Sources/Dashboard/DashboardApp.swift:51-65` (the `MenuBarExtra` content closure)
- Test: `Tests/DashboardTests/DashboardCoordinatorTests.swift`

**Interfaces:**
- Consumes: `UsageStore.refresh() async` (existing, `UsageStore.swift:75`), `DashboardCoordinator.entries` (existing).
- Produces: `DashboardCoordinator.refreshAll() async`.

- [ ] **Step 1: Write the failing test**

Append to `Tests/DashboardTests/DashboardCoordinatorTests.swift`, inside the class, after `testCoordinatorAggregatesLiveStores`:

```swift
    // Counts fetches so we can assert refreshAll() hit every store.
    private final class CountingProvider: UsageProviding, @unchecked Sendable {
        let windows: [UsageWindow]
        private(set) var fetchCount = 0
        init(windows: [UsageWindow]) { self.windows = windows }
        func fetch() async throws -> [UsageWindow] { fetchCount += 1; return windows }
    }

    func testRefreshAllRefreshesEveryStore() async {
        let claudeProvider = CountingProvider(windows: [win(used: 10, resetsIn: 3600)])
        let codexProvider = CountingProvider(windows: [win(used: 20, resetsIn: 3600)])
        let claude = UsageStore(provider: claudeProvider, threshold: nil, now: { self.now })
        let codex = UsageStore(provider: codexProvider, threshold: nil, now: { self.now })
        let coordinator = DashboardCoordinator(entries: [
            .init(id: "claude", displayName: "Claude Code", tag: "C", store: claude),
            .init(id: "codex", displayName: "Codex", tag: "X", store: codex),
        ])

        await coordinator.refreshAll()

        XCTAssertEqual(claudeProvider.fetchCount, 1)
        XCTAssertEqual(codexProvider.fetchCount, 1)
        XCTAssertEqual(coordinator.menuBarTitle, "◔ X 20%")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter testRefreshAllRefreshesEveryStore`
Expected: FAIL — compile error, `value of type 'DashboardCoordinator' has no member 'refreshAll'`.

- [ ] **Step 3: Write minimal implementation**

In `Sources/Dashboard/DashboardCoordinator.swift`, directly below `startAll()`:

```swift
    /// Refresh every provider now — used when the popover opens, so a token
    /// the user just renewed shows up without waiting for the 60s tick.
    /// `UsageStore.refresh()` is re-entrancy guarded and honours the rate-limit
    /// backoff, so repeated opens cannot stampede an endpoint.
    func refreshAll() async {
        for e in entries { await e.store.refresh() }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter testRefreshAllRefreshesEveryStore`
Expected: PASS.

- [ ] **Step 5: Call it when the popover opens**

In `Sources/Dashboard/DashboardApp.swift`, add a `.task` modifier to the `GaugesView` inside `MenuBarExtra`. Replace:

```swift
                onQuit: { NSApplication.shared.terminate(nil) }
            )
        } label: {
```

with:

```swift
                onQuit: { NSApplication.shared.terminate(nil) }
            )
            .task { await coordinator.refreshAll() }
        } label: {
```

- [ ] **Step 6: Run the full suite and build the app**

Run: `swift test && ./build-app.sh`
Expected: all tests PASS; `Built Dashboard.app`.

- [ ] **Step 7: Commit**

```bash
git add Sources/Dashboard/DashboardCoordinator.swift Sources/Dashboard/DashboardApp.swift Tests/DashboardTests/DashboardCoordinatorTests.swift
git commit -m "feat(dashboard): refresh every provider when the popover opens

Closes the re-login loop: log in, click the menu bar, see fresh gauges instead
of waiting out the 60s timer."
```

---

### Task 5: Document the affordance and its limits

**Files:**
- Modify: `dashboard/README.md`

**Interfaces:**
- Consumes: the behaviour built in Tasks 1-4.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Read the surrounding section**

Run: `sed -n '20,40p' README.md`

Locate the existing sentence about the expected error state (`"Token expired" — that is the expected error state, not a failure.`, around line 30).

- [ ] **Step 2: Add the documentation**

Insert a new section after the paragraph containing that sentence, matching the file's existing heading level and tone:

```markdown
### Re-login

When a provider's session dies, its section shows a **Re-login to …** button.
Clicking it opens Terminal running that provider's CLI — `claude`, `codex
login`, or `gemini`. Finish the login there, then reopen the popover: it
refreshes on open, so the gauges heal immediately.

The dashboard never refreshes or writes tokens itself. It only reads the
credential store each CLI owns, so the button is a shortcut for typing the
command — it cannot verify that the login succeeded. If the session is still
dead afterwards, the same button reappears.

Gemini is the exception that proves the rule: it mints a short-lived access
token from a long-lived refresh token on every fetch, so it rarely asks. When
it does, the refresh token itself has expired.
```

- [ ] **Step 3: Verify the surrounding prose still reads correctly**

Run: `sed -n '20,60p' README.md`
Expected: the new section sits after the error-state paragraph, does not duplicate it, and heading levels match neighbours.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs(dashboard): document the re-login button and what it can't do"
```

---

## Verification

After all five tasks:

- [ ] `swift test` — full suite passes.
- [ ] `./build-app.sh && open Dashboard.app` — popover renders, gauges load, no button while logged in.
- [ ] `git log --oneline -6` — five feature/docs commits on top of the spec commit.
- [ ] `git status` — clean; in particular the temporary `UsageClient.swift` edit from Task 3 Step 7 is reverted.

## Self-Review Notes

Spec coverage checked section by section: `AuthRecovery` (Task 1), `TerminalLauncher` (Task 2), `GaugesView` error view + stale hint (Task 3), `refreshAll` + popover `.task` (Task 4), README (Task 5). Error handling — swallowed launch failures — is covered by Task 2 Step 1's `testUnwritableDirectoryDoesNotOpenAnythingOrCrash`. All three testing bullets from the spec map to concrete test code above.

One deviation from the spec, resolved deliberately: the spec sketched
`staleMessage(for:)` taking only an error; it takes `(for:provider:)` here
because the auth wording is per-provider, matching `prompt(for:provider:)`. The
spec's own "worded for its case" requirement for Gemini forces this.
