#!/usr/bin/env bash
# Build a distributable, Developer ID-signed QuotaBar.dmg.
#
# Produces dist/QuotaBar.app (hardened-runtime, Developer ID signed) and
# dist/QuotaBar.dmg (signed). Optionally notarizes + staples the
# dmg when notarization credentials are supplied.
#
# Required env:
#   SIGN_IDENTITY  — your "Developer ID Application: ..." signing identity.
#
# Notarization (required for release dmgs — unnotarized apps are blocked by
# Gatekeeper on modern macOS): set NOTARY_PROFILE to a stored notarytool
# keychain profile name, OR set NOTARY_APPLE_ID + NOTARY_PASSWORD
# (app-specific) + NOTARY_TEAM_ID. To build a signed-but-unnotarized dmg for
# local testing, set SKIP_NOTARIZATION=1.
set -euo pipefail
cd "$(dirname "$0")"

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  echo "error: SIGN_IDENTITY is not set." >&2
  echo '  export SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"' >&2
  echo "  (list yours with: security find-identity -v -p codesigning)" >&2
  exit 1
fi
IDENTITY="$SIGN_IDENTITY"
APP="dist/QuotaBar.app"
DMG="dist/QuotaBar.dmg"
VOLNAME="QuotaBar"

echo "==> Building release binary"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/Dashboard"

echo "==> Assembling $APP"
rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Dashboard"
cp Resources/Info.plist "$APP/Contents/Info.plist"

echo "==> Signing app (Developer ID, hardened runtime, secure timestamp)"
codesign --force --options runtime --timestamp \
  --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "==> Building $DMG"
hdiutil create -volname "$VOLNAME" -srcfolder "$APP" -ov -format UDZO "$DMG" >/dev/null

echo "==> Signing dmg"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

# ----- notarization (required unless SKIP_NOTARIZATION=1) -----
NOTARIZE_ARGS=()
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  NOTARIZE_ARGS=(--keychain-profile "$NOTARY_PROFILE")
elif [[ -n "${NOTARY_APPLE_ID:-}" && -n "${NOTARY_PASSWORD:-}" && -n "${NOTARY_TEAM_ID:-}" ]]; then
  NOTARIZE_ARGS=(--apple-id "$NOTARY_APPLE_ID" --password "$NOTARY_PASSWORD" --team-id "$NOTARY_TEAM_ID")
fi

if [[ ${#NOTARIZE_ARGS[@]} -gt 0 ]]; then
  echo "==> Submitting for notarization (this can take a few minutes)"
  xcrun notarytool submit "$DMG" "${NOTARIZE_ARGS[@]}" --wait
  echo "==> Stapling ticket"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  echo "==> Notarized + stapled."
elif [[ "${SKIP_NOTARIZATION:-}" == "1" ]]; then
  echo "==> Skipped notarization (SKIP_NOTARIZATION=1) — local testing only."
  echo "    Do NOT publish this dmg: Gatekeeper will block it on other Macs."
else
  echo "error: no notarization credentials set." >&2
  echo "  Release dmgs must be notarized. Provide one of:" >&2
  echo "    NOTARY_PROFILE=<notarytool keychain profile>" >&2
  echo "    NOTARY_APPLE_ID=<id> NOTARY_PASSWORD=<app-specific> NOTARY_TEAM_ID=<team>" >&2
  echo "  or set SKIP_NOTARIZATION=1 for a local, non-distributable build." >&2
  exit 1
fi

echo
echo "Built: $DMG"
codesign -dv "$DMG" 2>&1 | grep -E "Authority|TeamIdentifier" | head -3 || true