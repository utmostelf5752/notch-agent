#!/bin/zsh
# Fetches the prebuilt Sparkle.framework and its command-line tools into
# Support/Sparkle/ (gitignored). Pinned by version and SHA-256 so the binary
# blob stays out of git without becoming a supply-chain hole. SPM is broken
# with this machine's CLT install, so the binary release is the only way to
# link Sparkle from build.sh's raw swiftc invocation.
set -e
cd "$(dirname "$0")"

SPARKLE_VERSION=2.9.4
SPARKLE_SHA256=ce89daf967db1e1893ed3ebd67575ed82d3902563e3191ca92aaec9164fbdef9
DEST=Sparkle
STAMP="$DEST/.version"

if [ -d "$DEST/Sparkle.framework" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$SPARKLE_VERSION" ]; then
    exit 0
fi

TARBALL="$(mktemp -t sparkle).tar.xz"
trap 'rm -f "$TARBALL"' EXIT

echo "Fetching Sparkle $SPARKLE_VERSION..."
curl -fsSL -o "$TARBALL" \
    "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"

ACTUAL=$(shasum -a 256 "$TARBALL" | awk '{print $1}')
if [ "$ACTUAL" != "$SPARKLE_SHA256" ]; then
    echo "error: Sparkle download checksum mismatch" >&2
    echo "  expected $SPARKLE_SHA256" >&2
    echo "  got      $ACTUAL" >&2
    exit 1
fi

rm -rf "$DEST"
mkdir -p "$DEST"
tar -xJf "$TARBALL" -C "$DEST" ./Sparkle.framework ./bin
echo "$SPARKLE_VERSION" > "$STAMP"
echo "Sparkle $SPARKLE_VERSION ready in Support/$DEST"
