#!/bin/bash
# Build Dikta.app from the SwiftPM product — no Xcode required.
# Usage: scripts/bundle.sh [identity]   (identity defaults to "dikta-dev",
# falling back to ad-hoc "-" if that certificate doesn't exist)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Dikta.app"
IDENTITY="${1:-dikta-dev}"

if [ "$IDENTITY" != "-" ] && ! security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    echo "note: signing identity '$IDENTITY' not found — using ad-hoc signing." >&2
    echo "      (run scripts/make-cert.sh once so TCC permissions survive rebuilds)" >&2
    IDENTITY="-"
fi

echo "==> swift build -c release"
cd "$ROOT"
swift build -c release --arch arm64

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$ROOT/.build/release/Dikta" "$APP/Contents/MacOS/Dikta"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp -R "$ROOT/Vendor/whisper.xcframework/macos-arm64_x86_64/whisper.framework" \
      "$APP/Contents/Frameworks/whisper.framework"

# SwiftPM's rpath points at the build dir; add the bundle's Frameworks dir.
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Dikta" 2>/dev/null || true

echo "==> codesigning (identity: $IDENTITY)"
codesign --force --sign "$IDENTITY" "$APP/Contents/Frameworks/whisper.framework"
codesign --force --sign "$IDENTITY" "$APP"

codesign --verify --deep "$APP" && echo "==> OK: $APP"
