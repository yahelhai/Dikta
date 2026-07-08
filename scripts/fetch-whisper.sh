#!/bin/bash
# Download the prebuilt whisper.cpp XCFramework (with embedded Metal) into Vendor/.
set -euo pipefail

VERSION="v1.9.1"
URL="https://github.com/ggml-org/whisper.cpp/releases/download/${VERSION}/whisper-${VERSION}-xcframework.zip"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/Vendor"

if [ -d "$VENDOR/whisper.xcframework" ]; then
    echo "whisper.xcframework already present in Vendor/ — skipping (rm -rf Vendor/whisper.xcframework to re-fetch)"
    exit 0
fi

mkdir -p "$VENDOR"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Downloading whisper.cpp ${VERSION} xcframework..."
curl -fL --progress-bar -o "$TMP/whisper.zip" "$URL"
unzip -q "$TMP/whisper.zip" -d "$TMP/unzipped"

FRAMEWORK_PATH="$(find "$TMP/unzipped" -maxdepth 3 -name 'whisper.xcframework' -type d | head -1)"
if [ -z "$FRAMEWORK_PATH" ]; then
    echo "ERROR: whisper.xcframework not found in the archive" >&2
    find "$TMP/unzipped" -maxdepth 3 >&2
    exit 1
fi

mv "$FRAMEWORK_PATH" "$VENDOR/whisper.xcframework"
echo "Installed $VENDOR/whisper.xcframework"
