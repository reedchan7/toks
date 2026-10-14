#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP=build/Toks.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

EXTRA_FLAGS=()
if [[ "${1:-}" == "debug" ]]; then
    EXTRA_FLAGS+=(-D DEBUG_WINDOW)
fi

xcrun swiftc -O \
    -target arm64-apple-macosx13.0 \
    -sdk "$(xcrun --show-sdk-path)" \
    ${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"} \
    Sources/*.swift \
    -o "$APP/Contents/MacOS/Toks"

cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"

echo "Built $APP"
