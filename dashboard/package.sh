#!/usr/bin/env bash
# Build a distributable, Developer ID-signed Claude Usage Dashboard.dmg.
#
# Produces dist/Dashboard.app (hardened-runtime, Developer ID signed) and
# dist/ClaudeUsageDashboard.dmg (signed). Optionally notarizes + staples the
# dmg when notarization credentials are supplied.
#
# Notarization (optional): set NOTARY_PROFILE to a stored notarytool keychain
# profile name, OR set NOTARY_APPLE_ID + NOTARY_PASSWORD (app-specific) +
# NOTARY_TEAM_ID. With none set, the script signs but skips notarization and
# prints the command to run later.
set -euo pipefail
cd "$(dirname "$0")"

IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Andrei Lukin (4X2DZ3Q4SR)}"
APP="dist/Dashboard.app"
DMG="dist/ClaudeUsageDashboard.dmg"
VOLNAME="Claude Usage Dashboard"

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

# ----- optional notarization -----
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
else
  echo "==> Skipped notarization (no credentials set)."
  echo "    To notarize later, run one of:"
  echo "      NOTARY_PROFILE=<profile> ./package.sh"
  echo "      NOTARY_APPLE_ID=<id> NOTARY_PASSWORD=<app-specific> NOTARY_TEAM_ID=4X2DZ3Q4SR ./package.sh"
fi

echo
echo "Built: $DMG"
codesign -dv "$DMG" 2>&1 | grep -E "Authority|TeamIdentifier" | head -3 || true