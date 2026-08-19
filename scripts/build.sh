#!/bin/bash
# Builds IMEModeSwitcher.app (a menu-bar-only app) from Sources/main.swift.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/IMEModeSwitcher.app"
MACOS="$APP/Contents/MacOS"

rm -rf "$APP"
mkdir -p "$MACOS"

echo "Compiling..."
swiftc -O "$ROOT/Sources/main.swift" -o "$MACOS/IMEModeSwitcher"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>IMEModeSwitcher</string>
    <key>CFBundleDisplayName</key>     <string>IME Mode Switcher</string>
    <key>CFBundleIdentifier</key>      <string>net.mossol.imemodeswitcher</string>
    <key>CFBundleVersion</key>         <string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleExecutable</key>      <string>IMEModeSwitcher</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <key>LSUIElement</key>             <true/>
</dict>
</plist>
PLIST

# Ad-hoc code signature so the global hotkey / status item behave consistently.
codesign --force --sign - "$APP" 2>/dev/null || true

echo "Built: $APP"
