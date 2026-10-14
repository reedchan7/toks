#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP=build/Toks.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

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

# Bundle the collector as a standalone binary so the installed app has no
# bun dependency, plus the pi adapter and the self-contained installer.
BUN="${BUN:-$HOME/.bun/bin/bun}"
"$BUN" build --compile ../collector/src/main.ts --outfile "$APP/Contents/Resources/toks-collector"
cp ../adapters/pi/toks-reporter.ts "$APP/Contents/Resources/toks-reporter.ts"
cp ../scripts/install-app.sh "$APP/Contents/Resources/install.sh"
cp ../scripts/uninstall.sh "$APP/Contents/Resources/uninstall.sh"
chmod +x "$APP/Contents/Resources/install.sh" "$APP/Contents/Resources/uninstall.sh"

cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP/Contents/Resources/toks-collector"
codesign --force --sign - "$APP"

echo "Built $APP"
