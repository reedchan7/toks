#!/bin/bash
# Builds build/Toks.dmg from build/Toks.app (run build.sh first).
set -euo pipefail

cd "$(dirname "$0")"

DMG=build/Toks.dmg
STAGE=build/dmg-staging
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"

ditto build/Toks.app "$STAGE/Toks.app"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname Toks -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo "Built $DMG"
