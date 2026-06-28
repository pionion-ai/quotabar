#!/usr/bin/env bash
# Build Dashboard.app — a menu-bar-only macOS app bundle.
set -euo pipefail
cd "$(dirname "$0")"

APP="Dashboard.app"
CONTENTS="$APP/Contents"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Dashboard"

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN" "$CONTENTS/MacOS/Dashboard"
cp Resources/Info.plist "$CONTENTS/Info.plist"

# Ad-hoc sign so UNUserNotificationCenter works.
codesign --force --sign - "$APP"

echo "Built $APP — run with: open $APP"
