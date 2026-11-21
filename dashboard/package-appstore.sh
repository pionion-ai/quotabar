#!/usr/bin/env bash
# Build the Mac App Store flavor of QuotaBar (sandboxed; Claude Code + Codex).
#
# Produces dist-appstore/QuotaBar.app and, unless ADHOC=1, a signed
# dist-appstore/QuotaBar.pkg ready for App Store Connect.
#
# Required env (store build):
#   APP_SIGN_IDENTITY     "Apple Distribution: Your Name (TEAMID)"
#   INSTALLER_IDENTITY    "3rd Party Mac Developer Installer: Your Name (TEAMID)"
#                         (Xcode may list it as "Mac Installer Distribution")
#   PROVISIONING_PROFILE  path to the Mac App Store .provisionprofile for
#                         ai.pionion.quotabar
#   TEAM_ID               your 10-character Apple team id
# Optional upload (UPLOAD=1), App Store Connect API key:
#   ASC_API_KEY_ID, ASC_API_ISSUER   (key file in ~/.appstoreconnect/private_keys/)
#
# Optional: BUILD_NUMBER (CFBundleVersion — must increase on every upload) and
# VERSION (CFBundleShortVersionString), applied to the bundle's copy of
# Info.plist only; defaults come from Resources/Info.plist.
#
# Local sandbox smoke test, no Apple identities needed:
#   ADHOC=1 ./package-appstore.sh && open dist-appstore/QuotaBar.app
set -euo pipefail
cd "$(dirname "$0")"

BUNDLE_ID="ai.pionion.quotabar"
OUT="dist-appstore"
APP="$OUT/QuotaBar.app"
PKG="$OUT/QuotaBar.pkg"
ENTITLEMENTS="Resources/QuotaBar-AppStore.entitlements"
BUILD_FLAGS=(-c release --arch arm64 --arch x86_64 -Xswiftc -DAPPSTORE)

if [[ "${ADHOC:-}" != "1" ]]; then
  missing=()
  for v in APP_SIGN_IDENTITY INSTALLER_IDENTITY PROVISIONING_PROFILE TEAM_ID; do
    [[ -n "${!v:-}" ]] || missing+=("$v")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "error: missing ${missing[*]}." >&2
    echo '  export APP_SIGN_IDENTITY="Apple Distribution: Your Name (TEAMID)"' >&2
    echo '  export INSTALLER_IDENTITY="3rd Party Mac Developer Installer: Your Name (TEAMID)"' >&2
    echo '  export PROVISIONING_PROFILE=~/Downloads/QuotaBar_Mac_App_Store.provisionprofile' >&2
    echo '  export TEAM_ID=ABCDE12345' >&2
    echo "  (list identities with: security find-identity -v)" >&2
    echo "  or set ADHOC=1 for a local, unsigned-for-store sandbox build." >&2
    exit 1
  fi
  [[ -f "$PROVISIONING_PROFILE" ]] || { echo "error: no file at PROVISIONING_PROFILE=$PROVISIONING_PROFILE" >&2; exit 1; }
fi

echo "==> Building universal release binary (APPSTORE flavor)"
swift build "${BUILD_FLAGS[@]}"
BIN="$(swift build "${BUILD_FLAGS[@]}" --show-bin-path)/Dashboard"

echo "==> Assembling $APP"
rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Dashboard"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/PrivacyInfo.xcprivacy "$APP/Contents/Resources/PrivacyInfo.xcprivacy"

PLIST="$APP/Contents/Info.plist"
[[ -n "${BUILD_NUMBER:-}" ]] && /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$PLIST"
[[ -n "${VERSION:-}" ]] && /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
echo "    version $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")" \
     "build $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"

ENT_DIR="$(mktemp -d)"
trap 'rm -rf "$ENT_DIR"' EXIT
SIGN_ENT="$ENT_DIR/entitlements.plist"
cp "$ENTITLEMENTS" "$SIGN_ENT"

# Files copied from Downloads etc. carry com.apple.quarantine; App Store
# validation rejects bundles containing quarantined files.
strip_xattrs() { xattr -cr "$APP"; }

if [[ "${ADHOC:-}" == "1" ]]; then
  strip_xattrs
  echo "==> Ad-hoc signing with sandbox entitlements (local testing only)"
  codesign --force --sign - --entitlements "$SIGN_ENT" "$APP"
  codesign -d --entitlements - "$APP" 2>/dev/null | grep -q app-sandbox
  echo
  echo "Built $APP (ad-hoc, sandboxed). Run: open $APP"
  echo "Not uploadable — rerun without ADHOC=1 for the store package."
  exit 0
fi

echo "==> Embedding provisioning profile"
cp "$PROVISIONING_PROFILE" "$APP/Contents/embedded.provisionprofile"
strip_xattrs

echo "==> Adding application/team identifiers to entitlements"
/usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $TEAM_ID.$BUNDLE_ID" "$SIGN_ENT"
/usr/libexec/PlistBuddy -c "Add :com.apple.developer.team-identifier string $TEAM_ID" "$SIGN_ENT"

echo "==> Signing app (Apple Distribution, hardened runtime)"
codesign --force --options runtime --timestamp \
  --entitlements "$SIGN_ENT" --sign "$APP_SIGN_IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "==> Building signed installer package $PKG"
productbuild --component "$APP" /Applications --sign "$INSTALLER_IDENTITY" "$PKG"

if [[ "${UPLOAD:-}" == "1" ]]; then
  : "${ASC_API_KEY_ID:?set ASC_API_KEY_ID for UPLOAD=1}"
  : "${ASC_API_ISSUER:?set ASC_API_ISSUER for UPLOAD=1}"
  echo "==> Validating with App Store Connect"
  xcrun altool --validate-app -f "$PKG" -t macos --apiKey "$ASC_API_KEY_ID" --apiIssuer "$ASC_API_ISSUER"
  echo "==> Uploading to App Store Connect"
  xcrun altool --upload-app -f "$PKG" -t macos --apiKey "$ASC_API_KEY_ID" --apiIssuer "$ASC_API_ISSUER"
  echo "==> Uploaded. The build appears in App Store Connect after processing."
else
  echo
  echo "Built: $PKG"
  echo "Upload with UPLOAD=1 (API key) or drag it into Transporter.app."
fi
