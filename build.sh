#!/bin/zsh
# Builds a proper .app bundle. A bare executable has no bundle identity, which
# makes macOS spam "com.apple.linkd.autoShortcut" / intents-registration errors
# at launch; the bundle + ad-hoc signature fixes that.
# swiftc directly because `swift build` (SPM) is broken in the CLT install.
set -e
cd "$(dirname "$0")"

APP=build/Eave.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Support/MenuBarIcon.png "$APP/Contents/Resources/MenuBarIcon.png"
cp Support/Info.plist "$APP/Contents/Info.plist"

# Expand the same build-setting placeholders that Xcode resolves when it
# builds the native app target. Keeping one plist makes shell and Xcode runs
# use the same bundle identity and metadata.
sed -i '' \
    -e 's/$(EXECUTABLE_NAME)/Eave/g' \
    -e 's/$(PRODUCT_BUNDLE_IDENTIFIER)/com.jagruth.eave/g' \
    "$APP/Contents/Info.plist"

swiftc -O -o "$APP/Contents/MacOS/Eave" \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist \
    -Xlinker Support/EmbeddedInfo.plist \
    Sources/Eave/main.swift \
    Sources/Eave/GlobalShortcut.swift \
    Sources/Eave/AppDelegate.swift \
    Sources/Eave/AppState.swift \
    Sources/Eave/AgentSession.swift \
    Sources/Eave/CursorApprovals.swift \
    Sources/Eave/CodexAppServer.swift \
    Sources/Eave/ChatGPTWeb.swift \
    Sources/Eave/MarkdownText.swift \
    Sources/Eave/Views.swift

# A stable Apple Development identity keeps macOS privacy permissions attached
# across rebuilds. CI and machines without this team's certificate retain the
# previous ad-hoc fallback so release packaging still works there.
SIGNING_IDENTITY="${EAVE_SIGN_IDENTITY:-${NOTCHAGENT_SIGN_IDENTITY:-}}"
if [ -z "$SIGNING_IDENTITY" ]; then
    SIGNING_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
        | awk '/"Apple Development:/ { print $2; exit }')
fi
if [ -z "$SIGNING_IDENTITY" ]; then
    SIGNING_IDENTITY="-"
    echo "No Apple Development certificate found; using ad-hoc signing."
else
    echo "Signing with the installed Apple Development certificate"
fi
codesign --force --sign "$SIGNING_IDENTITY" --identifier com.jagruth.eave "$APP"
echo "Built $APP"
echo "Run with: open $APP"
