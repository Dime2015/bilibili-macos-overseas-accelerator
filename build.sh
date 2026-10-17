#!/bin/zsh
# Builds "B站加速.app" into ./build and installs it to ~/Applications.
# Usage: ./build.sh [--no-install]
set -euo pipefail
cd "$(dirname "$0")"

APP="build/B站加速.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 -framework AppKit src/main.swift -o "$APP/Contents/MacOS/BiliCDN"
cp src/hook.js "$APP/Contents/Resources/hook.js"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>B站加速</string>
  <key>CFBundleDisplayName</key><string>B站加速</string>
  <key>CFBundleIdentifier</key><string>local.bilicdn.launcher</string>
  <key>CFBundleExecutable</key><string>BiliCDN</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
EOF

# Reuse 哔哩哔哩's icon so the launcher is easy to spot in the Dock.
BILI_ICON="/Applications/哔哩哔哩.app/Contents/Resources/icon.icns"
[[ -f "$BILI_ICON" ]] && cp "$BILI_ICON" "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$APP"

[[ "${1:-}" == "--no-install" ]] && { echo "Built: $APP"; exit 0; }

mkdir -p ~/Applications
rm -rf ~/Applications/B站加速.app
cp -R "$APP" ~/Applications/
echo "Installed: ~/Applications/B站加速.app"
