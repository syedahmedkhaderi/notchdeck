#!/bin/bash
# Builds NotchDeck.app from the Swift sources.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/NotchDeck.app"
SDK="$(xcrun --show-sdk-path --sdk macosx)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

SOURCES=$(find "$ROOT/Sources" -name '*.swift' | sort)

# shellcheck disable=SC2086
xcrun swiftc \
    -swift-version 5 \
    -O \
    -sdk "$SDK" \
    -target arm64-apple-macosx14.0 \
    -framework AppKit -framework SwiftUI -framework Combine \
    -framework AVFoundation -framework EventKit -framework IOKit \
    -framework CoreGraphics -framework UniformTypeIdentifiers \
    -o "$APP/Contents/MacOS/NotchDeck" \
    $SOURCES

cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Sign with a stable identity when one is available: privacy permissions are tied
# to it, so they survive rebuilds (ad-hoc signatures do not).
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(.*\)"/\1/p' | head -1)"
if [ -n "$IDENTITY" ] && codesign --force --sign "$IDENTITY" "$APP" >/dev/null 2>&1; then
    echo "Signed with $IDENTITY"
else
    codesign --force --sign - "$APP" >/dev/null 2>&1 || true
    echo "Signed ad-hoc"
fi
echo "Built $APP"
