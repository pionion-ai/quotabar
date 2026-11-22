#!/usr/bin/env bash
# Build QuotaBar.app — a menu-bar-only macOS app bundle.
set -euo pipefail
cd "$(dirname "$0")"

APP="QuotaBar.app"
CONTENTS="$APP/Contents"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Dashboard"

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN" "$CONTENTS/MacOS/Dashboard"
cp Resources/Info.plist "$CONTENTS/Info.plist"
cp Resources/AppIcon.icns "$CONTENTS/Resources/AppIcon.icns"
install -m 755 Resources/quotabar-statusline "$CONTENTS/Resources/quotabar-statusline"

# Ad-hoc sign so UNUserNotificationCenter works.
codesign --force --sign - "$APP"

echo "Built $APP — run with: open $APP"
