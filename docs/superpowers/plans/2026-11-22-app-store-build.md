# QuotaBar Mac App Store Build Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A sandboxed App Store flavor of QuotaBar (Claude Code + Codex only, zero setup) plus a script that produces a signed `.pkg` for App Store Connect.

**Architecture:** One codebase; the compile condition `APPSTORE` selects the flavor. Pure, unit-tested decisions (which providers, credential parsing, paths, re-login mode) live in small functions; the flavor switch only picks between them at the wiring points (`DashboardApp`, `UsageClient.live`, `GaugesView`'s re-login action).

**Tech Stack:** Swift 5.9 SwiftPM, SwiftUI `MenuBarExtra`, Security.framework, `codesign`/`productbuild`/`xcrun altool`.

**Spec:** `docs/superpowers/specs/2026-11-22-app-store-build-design.md`

## Global Constraints
- App Store flavor shows only providers `claude` and `codex`; DMG flavor behavior unchanged (all four, `security` subprocess, Terminal launcher).
- No manual token entry; never write, refresh or copy credentials.
- Claude Keychain item: service `Claude Code-credentials`; token at `claudeAiOauth.accessToken`.
- Codex file: `<real home>/.codex/auth.json`, real home from `getpwuid(getuid())`, never `NSHomeDirectory()`.
- Entitlements: `com.apple.security.app-sandbox`, `com.apple.security.network.client`, `com.apple.security.temporary-exception.files.home-relative-path.read-only` = `["/.codex/"]`.
- Info.plist: `LSApplicationCategoryType` = `public.app-category.developer-tools`, `ITSAppUsesNonExemptEncryption` = false.
- Privacy manifest: UserDefaults access, reason `CA92.1`; no tracking, no collected data.
- Tests run with `arch -arm64 swift test` (shell runs under Rosetta) and must pass in both flavors: also `arch -arm64 swift test -Xswiftc -DAPPSTORE`.

## Review Focus
1. Keychain read denied by the user ("Deny" in the dialog) → `.notLoggedIn` UI with the copy-command button, not a crash or a spinner (Task 2: status→error mapping test).
2. Codex not installed (`~/.codex/auth.json` absent) in App Store flavor → Codex section hidden, Claude still shown (Task 3: `isAvailable` uses real home; Task 1 registration test).
3. Codex rewrites `auth.json` atomically on token refresh → next fetch reads the new file (path-based read, no cached handle; covered by design, verify in Task 6 smoke test).
4. Claude item exists but JSON lacks `claudeAiOauth` (API-key users) → `.notLoggedIn` (Task 2 parse test).
5. Re-login copy in sandbox → pasteboard holds exactly the CLI command (`claude` / `codex login`) and the UI says it was copied (Task 4).

---

### Task 0: Checkpoint the Cursor branch work
The working tree holds uncommitted Cursor-provider work plus the review fixes. **Ask the user before committing it**; the App Store tasks edit the same files.

- [ ] **Step 1:** Run `arch -arm64 swift test` → expect all pass (122).
- [ ] **Step 2 (with user OK):** `git add -A dashboard README.md docs && git commit -m "feat(dashboard): Cursor provider + review fixes"`

### Task 1: Flavor switch and provider registration

**Files:**
- Create: `dashboard/Sources/Dashboard/Flavor.swift`
- Modify: `dashboard/Sources/Dashboard/DashboardApp.swift:12-50`
- Test: `dashboard/Tests/DashboardTests/FlavorTests.swift`

**Interfaces:**
- Produces: `enum Flavor { static let isAppStore: Bool }` (true iff compiled with `-DAPPSTORE`); `static func providerIDs(appStore: Bool) -> [String]`.

- [ ] **Step 1: Failing tests**
```swift
func testAppStoreFlavorHasOnlyClaudeAndCodex() {
    XCTAssertEqual(Flavor.providerIDs(appStore: true), ["claude", "codex"])
}
func testDirectFlavorHasAllProviders() {
    XCTAssertEqual(Flavor.providerIDs(appStore: false), ["claude", "codex", "gemini", "cursor"])
}
```
- [ ] **Step 2:** `arch -arm64 swift test --filter FlavorTests` → FAIL (no `Flavor`).
- [ ] **Step 3:** Implement `Flavor` (`#if APPSTORE` for `isAppStore`). In `DashboardApp.init`, build each provider entry only if its id is in `Flavor.providerIDs(appStore: Flavor.isAppStore)` (still gated by `isAvailable()` for codex/gemini/cursor).
- [ ] **Step 4:** Run tests in both flavors → PASS.
- [ ] **Step 5:** Commit `feat(dashboard): APPSTORE flavor limits providers to Claude + Codex`.

### Task 2: Claude token via Security.framework

**Files:**
- Modify: `dashboard/Sources/Dashboard/UsageClient.swift:60-86`
- Test: `dashboard/Tests/DashboardTests/UsageClientTests.swift`

**Interfaces:**
- Produces: `static func token(fromCredentials data: Data) throws -> String` (throws `FetchError.notLoggedIn`); `static func keychainError(for status: OSStatus) -> FetchError` (every non-success → `.notLoggedIn`); `static func readKeychainItemToken() throws -> String` (SecItemCopyMatching on generic password, service `Claude Code-credentials`, return data, limit one).
- `readKeychainToken()` (existing, `security` subprocess) reuses `token(fromCredentials:)`.
- `live()` uses `readKeychainItemToken` when `Flavor.isAppStore`, else `readKeychainToken`.

- [ ] **Step 1: Failing tests**
```swift
func testParsesClaudeCredentials() throws {
    let json = #"{"claudeAiOauth":{"accessToken":"abc","refreshToken":"r","expiresAt":1}}"#
    XCTAssertEqual(try UsageClient.token(fromCredentials: Data(json.utf8)), "abc")
}
func testCredentialsWithoutOAuthAreNotLoggedIn() {
    for body in [#"{"mcpOAuth":{}}"#, "garbage", ""] {
        XCTAssertThrowsError(try UsageClient.token(fromCredentials: Data(body.utf8))) {
            XCTAssertEqual($0 as? FetchError, .notLoggedIn)
        }
    }
}
func testKeychainFailuresAreNotLoggedIn() {
    for s in [errSecItemNotFound, errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed] {
        XCTAssertEqual(UsageClient.keychainError(for: s), .notLoggedIn)
    }
}
```
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Implement the three functions; refactor `readKeychainToken` onto `token(fromCredentials:)`.
- [ ] **Step 4:** Both flavors → PASS.
- [ ] **Step 5:** Commit `feat(dashboard): read Claude token via SecItemCopyMatching in APPSTORE flavor`.

### Task 3: Codex path from the real home directory

**Files:**
- Modify: `dashboard/Sources/Dashboard/CodexUsageClient.swift:50-56`
- Test: `dashboard/Tests/DashboardTests/CodexUsageTests.swift`

**Interfaces:**
- Produces: `static func realHomeDirectory() -> String` (from `getpwuid(getuid())`, fallback `NSHomeDirectory()`); `static func authPath(home: String = realHomeDirectory()) -> String`. `isAvailable()` and `readAuth()` use `authPath()`.

- [ ] **Step 1: Failing tests**
```swift
func testAuthPathUnderGivenHome() {
    XCTAssertEqual(CodexUsageClient.authPath(home: "/Users/x"), "/Users/x/.codex/auth.json")
}
func testRealHomeIsNotASandboxContainer() {
    XCTAssertFalse(CodexUsageClient.realHomeDirectory().contains("/Library/Containers/"))
    XCTAssertTrue(CodexUsageClient.realHomeDirectory().hasPrefix("/"))
}
```
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Both flavors → PASS.
- [ ] **Step 5:** Commit `fix(dashboard): resolve ~/.codex from the real home (sandbox-safe)`.

### Task 4: Re-login copies the command in the App Store flavor

**Files:**
- Modify: `dashboard/Sources/Dashboard/AuthRecovery.swift`, `dashboard/Sources/Dashboard/GaugesView.swift:17-19,154-170`
- Test: `dashboard/Tests/DashboardTests/AuthRecoveryTests.swift`

**Interfaces:**
- Produces: `enum ReloginMode { case launchTerminal, copyCommand }`; `AuthRecovery.prompt(for:provider:mode: ReloginMode = .launchTerminal) -> ReloginPrompt?`; `AuthRecovery.copiedConfirmation(command: String) -> String`.
- `GaugesView`'s default `launch` closure: `Flavor.isAppStore` → write `command` to `NSPasteboard.general` (clear first) and show `copiedConfirmation` in the section for ~4 s; otherwise `TerminalLauncher.live.launch` as today. `TerminalLauncher` stays compiled but unused in APPSTORE (its tests keep running).

- [ ] **Step 1: Failing tests**
```swift
func testCopyModeButtonTitle() {
    let p = AuthRecovery.prompt(for: .notLoggedIn, provider: "codex", mode: .copyCommand)
    XCTAssertEqual(p?.buttonTitle, "Copy login command")
    XCTAssertEqual(p?.command, "codex login")
    XCTAssertEqual(p?.message, "Not signed in.")
}
func testLaunchModeUnchanged() {
    XCTAssertEqual(AuthRecovery.prompt(for: .authExpired, provider: "claude")?.buttonTitle, "Re-login to Claude Code…")
}
func testCopiedConfirmation() {
    XCTAssertEqual(AuthRecovery.copiedConfirmation(command: "claude"), "Copied “claude” — paste it in Terminal")
}
```
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Implement; GaugesView passes `mode: Flavor.isAppStore ? .copyCommand : .launchTerminal` at both `AuthRecovery.prompt` call sites.
- [ ] **Step 4:** Both flavors → PASS.
- [ ] **Step 5:** Commit `feat(dashboard): copy-command re-login for the sandboxed flavor`.

### Task 5: App Store packaging

**Files:**
- Create: `dashboard/Resources/QuotaBar-AppStore.entitlements`, `dashboard/Resources/PrivacyInfo.xcprivacy`, `dashboard/package-appstore.sh`
- Modify: `dashboard/Resources/Info.plist` (add the two Global-Constraints keys; harmless for the DMG flavor), `.gitignore` (`*.provisionprofile`, `dist-appstore/`)

**Script contract (`package-appstore.sh`):**
- Env: `APP_SIGN_IDENTITY` ("Apple Distribution: …"), `INSTALLER_IDENTITY` ("3rd Party Mac Developer Installer: …"), `PROVISIONING_PROFILE` (path), `TEAM_ID`; optional `UPLOAD=1` with `ASC_API_KEY_ID` + `ASC_API_ISSUER` (altool `--apiKey/--apiIssuer`). `ADHOC=1` skips all four identities/profile: ad-hoc sign with the entitlements minus `application-identifier`/`team-identifier`, no pkg — for local sandbox smoke tests.
- Build: `swift build -c release --arch arm64 --arch x86_64 -Xswiftc -DAPPSTORE`; bin path from `--show-bin-path` with the same flags.
- Assemble `dist-appstore/QuotaBar.app` like `package.sh`, plus `PrivacyInfo.xcprivacy` → `Contents/Resources/`, profile → `Contents/embedded.provisionprofile`.
- Entitlements at sign time = the file + `com.apple.application-identifier` = `$TEAM_ID.ai.pionion.quotabar` and `com.apple.developer.team-identifier` = `$TEAM_ID` (merge into a temp plist with `PlistBuddy`).
- `codesign --force --options runtime --timestamp --entitlements <merged> --sign "$APP_SIGN_IDENTITY"`; `productbuild --component dist-appstore/QuotaBar.app /Applications --sign "$INSTALLER_IDENTITY" dist-appstore/QuotaBar.pkg`; `UPLOAD=1` → `xcrun altool --upload-app -f … -t macos …`. Missing env → clear error like `package.sh`.

- [ ] **Step 1:** Write files and script.
- [ ] **Step 2:** `bash -n package-appstore.sh`; `plutil -lint Resources/*.plist Resources/*.entitlements Resources/PrivacyInfo.xcprivacy` → OK.
- [ ] **Step 3:** `ADHOC=1 ./package-appstore.sh` → builds; `lipo -archs dist-appstore/QuotaBar.app/Contents/MacOS/Dashboard` → `x86_64 arm64`; `codesign -d --entitlements - dist-appstore/QuotaBar.app` shows app-sandbox and `/.codex/`.
- [ ] **Step 4:** Missing-env run (no ADHOC, no vars) exits 1 with the identity hint.
- [ ] **Step 5:** Commit `build(dashboard): package-appstore.sh, entitlements, privacy manifest`.

### Task 6: Sandboxed smoke test, store materials, docs

**Files:**
- Create: `dashboard/AppStore/description.md`, `dashboard/AppStore/privacy-policy.md`, `dashboard/AppStore/review-notes.md`
- Modify: `dashboard/README.md` (new "Mac App Store build" section: what differs, how to run `package-appstore.sh`, user-side setup checklist), design doc status line.

- [ ] **Step 1: Smoke test (manual, with the user):** `open dist-appstore/QuotaBar.app` (ADHOC build) → menu bar item appears; Claude and Codex gauges load (after one Keychain prompt); no Gemini/Cursor; `ps`/Activity Monitor shows "Sandbox: Yes".
- [ ] **Step 2:** Write store materials. Description: unofficial, not affiliated with Anthropic/OpenAI, needs a logged-in Claude Code or Codex CLI, reads but never writes credentials. Privacy policy: no data collected; tokens read locally and sent only to each provider's own usage endpoint; settings in UserDefaults. Review notes: why the Keychain read and the `.codex` read-only exception are needed, how to reproduce (install CLI, log in), offer a demo video.
- [ ] **Step 3:** README section; `arch -arm64 swift test` both flavors → PASS.
- [ ] **Step 4:** Commit `docs(dashboard): App Store materials and build instructions`.
