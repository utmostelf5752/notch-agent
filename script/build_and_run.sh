#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Eave"
BUNDLE_ID="com.jagruth.eave"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$ROOT_DIR/build/DebugDerivedData"
APP_BUNDLE="$DERIVED_DATA/Build/Products/Debug/Eave.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/Eave"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

xcodebuild \
    -project "$ROOT_DIR/Eave.xcodeproj" \
    -scheme Eave \
    -configuration Debug \
    -derivedDataPath "$DERIVED_DATA" \
    build

open_app() {
    /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
    run)
        open_app
        ;;
    --debug|debug)
        lldb -- "$APP_BINARY"
        ;;
    --logs|logs)
        open_app
        /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
        ;;
    --telemetry|telemetry)
        open_app
        /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
        ;;
    --verify|verify)
        open_app
        sleep 1
        pgrep -x "$APP_NAME" >/dev/null
        ;;
    *)
        echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
        exit 2
        ;;
esac
