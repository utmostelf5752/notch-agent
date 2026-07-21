#!/bin/zsh
# Builds a proper .app bundle. A bare executable has no bundle identity, which
# makes macOS spam "com.apple.linkd.autoShortcut" / intents-registration errors
# at launch; the bundle + ad-hoc signature fixes that.
# swiftc directly because `swift build` (SPM) is broken in the CLT install.
set -e
cd "$(dirname "$0")"

./Support/fetch-sparkle.sh

APP=build/Eave.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Support/MenuBarIcon.png "$APP/Contents/Resources/MenuBarIcon.png"
cp Support/Info.plist "$APP/Contents/Info.plist"

# Sparkle compares CFBundleVersion between the installed app and the appcast,
# so it must increase monotonically with every build; the commit count does
# exactly that. Falls back to 1 outside a git checkout (release tarballs).
BUILD_NUMBER=$(git rev-list --count HEAD 2>/dev/null || echo 1)
MARKETING_VERSION="0.1.$BUILD_NUMBER"

# Expand the same build-setting placeholders that Xcode resolves when it
# builds the native app target. Keeping one plist makes shell and Xcode runs
# use the same bundle identity and metadata. The embedded plist (bare-binary
# fallback identity) gets the same expansion into build/ so the linked copy
# carries real versions.
EXPAND_PLACEHOLDERS=(
    -e 's/$(EXECUTABLE_NAME)/Eave/g'
    -e 's/$(PRODUCT_BUNDLE_IDENTIFIER)/com.jagruth.eave/g'
    -e "s/\$(MARKETING_VERSION)/$MARKETING_VERSION/g"
    -e "s/\$(CURRENT_PROJECT_VERSION)/$BUILD_NUMBER/g"
)
sed -i '' "${EXPAND_PLACEHOLDERS[@]}" "$APP/Contents/Info.plist"
sed "${EXPAND_PLACEHOLDERS[@]}" Support/EmbeddedInfo.plist > build/EmbeddedInfo.plist

cp -R Support/Sparkle/Sparkle.framework "$APP/Contents/Frameworks/"

swiftc -O -o "$APP/Contents/MacOS/Eave" \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist \
    -Xlinker build/EmbeddedInfo.plist \
    -F Support/Sparkle -framework Sparkle \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    Sources/Eave/main.swift \
    Sources/Eave/GlobalShortcut.swift \
    Sources/Eave/AppDelegate.swift \
    Sources/Eave/AppState.swift \
    Sources/Eave/AgentSession.swift \
    Sources/Eave/Updater.swift \
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
# The nested framework is signed first and the app last; --deep is deprecated
# and re-signs nested code with the outer identifier, which breaks Sparkle's
# XPC services.
codesign --force --sign "$SIGNING_IDENTITY" "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --sign "$SIGNING_IDENTITY" --identifier com.jagruth.eave "$APP"
echo "Built $APP"
echo "Run with: open $APP"
