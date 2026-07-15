#!/bin/zsh
# Builds a proper .app bundle. A bare executable has no bundle identity, which
# makes macOS spam "com.apple.linkd.autoShortcut" / intents-registration errors
# at launch; the bundle + ad-hoc signature fixes that.
# swiftc directly because `swift build` (SPM) is broken in the CLT install.
set -e
cd "$(dirname "$0")"

APP=build/NotchAgent.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

swiftc -O -o "$APP/Contents/MacOS/NotchAgent" \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist \
    -Xlinker Support/EmbeddedInfo.plist \
    Sources/NotchAgent/main.swift \
    Sources/NotchAgent/AppDelegate.swift \
    Sources/NotchAgent/AppState.swift \
    Sources/NotchAgent/AgentSession.swift \
    Sources/NotchAgent/CodexAppServer.swift \
    Sources/NotchAgent/ChatGPTWeb.swift \
    Sources/NotchAgent/Views.swift

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>NotchAgent</string>
    <key>CFBundleIdentifier</key><string>com.jagruth.notchagent</string>
    <key>CFBundleName</key><string>NotchAgent</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

codesign --force --sign - "$APP"
echo "Built $APP"
echo "Run with: open $APP"
