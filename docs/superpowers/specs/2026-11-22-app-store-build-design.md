# QuotaBar — Mac App Store build (design)

Status: approved and implemented 2026-11-22 (store submission pending).

## Intent
Publish QuotaBar on the Mac App Store, showing **Claude Code and Codex only**,
while keeping today's zero-setup experience: the app must pick up the logins
users already have (no pasted tokens, no configuration). The notarized
Developer ID DMG stays as-is, with all four providers.

## Goals
- A sandboxed App Store flavor built from the same sources.
- Claude Code and Codex gauges work with the user's existing CLI logins.
- A repeatable script that produces a signed `.pkg` ready for App Store Connect.
- Store copy, privacy policy, and review notes drafted.

## Non-goals
- Gemini and Cursor in the App Store build.
- Changing the DMG build's behavior (it keeps `security` + Terminal launcher).
- An Xcode project; automatic updates (the store handles them).

## Anti-goals
- Any manual token entry or setup step.
- Writing, refreshing or copying any provider credential.

## Constraints (verified 2026-11-22 with an ad-hoc-signed sandboxed probe)
- **Claude:** a sandboxed app *can* read the `Claude Code-credentials`
  generic-password item via `SecItemCopyMatching` (status 0). The `security`
  subprocess path is not used in the sandbox.
- **Codex:** with `com.apple.security.temporary-exception.files.home-relative-path.read-only`
  = `["/.codex/"]`, a sandboxed app reads `~/.codex/auth.json` — **but only via
  the real home path** (`getpwuid(getuid())->pw_dir`); `NSHomeDirectory()`
  returns the container.
- `~/.claude/.credentials.json` is not readable in the sandbox (not needed).
- Terminal launching (`.command` files) is not viable under sandbox/review.

## Approaches considered
1. **Pasted long-lived token (`claude setup-token`)** — rejected: requires a
   manual step, violating the zero-setup requirement.
2. **Direct Keychain read + `.codex` read-only exception (chosen)** — zero
   setup; verified to work in the sandbox. Risk: App Review may question the
   temporary exception and reading another app's Keychain item.
3. **In-app OAuth reusing Claude Code's client identity** — rejected: highest
   review and terms-of-service risk.

Fallback if review rejects the `.codex` exception: a one-time folder picker for
`~/.codex` with a security-scoped bookmark.

## Design
- **Build flavor:** compile condition `APPSTORE` (`swift build -Xswiftc -DAPPSTORE`).
  Under it, `DashboardApp` registers only Claude and Codex.
- **Claude token reader:** a `SecItemCopyMatching`-based reader parsing the
  same `claudeAiOauth.accessToken` JSON; used in the APPSTORE flavor. The
  JSON parsing is shared with the existing `security` reader and unit-tested.
- **Codex path:** `CodexUsageClient.authPath()` resolves from the real home
  directory (correct in both flavors).
- **Re-login:** in APPSTORE, the re-login button copies the CLI command to the
  pasteboard and says so ("Copied `claude` — run it in Terminal"), instead of
  launching Terminal. `TerminalLauncher` stays compiled (so its tests run in
  both flavors) but is never called in that flavor — builder's call.
- **Packaging (`package-appstore.sh`):** universal (arm64 + x86_64) release
  build with `-DAPPSTORE`; bundle assembled like `package.sh`; Info.plist gains
  `LSApplicationCategoryType = public.app-category.developer-tools` and
  `ITSAppUsesNonExemptEncryption = false`; `PrivacyInfo.xcprivacy` (UserDefaults,
  reason CA92.1) copied into Resources; `embedded.provisionprofile` copied in;
  signed with `Apple Distribution` + `QuotaBar-AppStore.entitlements`
  (app-sandbox, network.client, the `.codex` exception, application-identifier,
  team-identifier); `productbuild --sign "3rd Party Mac Developer Installer…"`;
  optional upload with `xcrun altool --upload-app`. Required env vars mirror
  `package.sh` style and fail with clear messages.
- **Store materials:** `dashboard/AppStore/` with description, keywords,
  privacy policy, review notes (explain the app needs a logged-in Claude Code
  or Codex CLI; offer a demo video).

## Left to the user
Apple Distribution and Mac Installer Distribution certificates, a Mac App Store
provisioning profile for `ai.pionion.quotabar`, the App Store Connect record,
screenshots, hosting the privacy policy URL, and submitting for review.

## Left to the builder
Exact file split for the flavor switch; wording of store copy; whether the
1024px icon in `AppIcon.icns` passes upload validation (add an asset catalog
only if upload validation demands it).
