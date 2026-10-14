#!/bin/bash
# Installs toks: builds the menu bar app, registers the collector as a
# launchd agent, and installs the pi extension adapter.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUN="${BUN:-$HOME/.bun/bin/bun}"
STATE_DIR="$HOME/.local/share/toks"
PLIST="$HOME/Library/LaunchAgents/com.reedchan.toks.collector.plist"

mkdir -p "$STATE_DIR/events" "$HOME/Library/LaunchAgents"

echo "==> Building Toks.app"
sh "$REPO/menubar/build.sh"
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/Toks.app"
cp -R "$REPO/menubar/build/Toks.app" "$HOME/Applications/Toks.app"

echo "==> Installing collector launchd agent"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.reedchan.toks.collector</string>
  <key>ProgramArguments</key>
  <array>
    <string>$BUN</string>
    <string>$REPO/collector/src/main.ts</string>
  </array>
  <key>WorkingDirectory</key><string>$REPO/collector</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$STATE_DIR/collector.log</string>
  <key>StandardErrorPath</key><string>$STATE_DIR/collector.log</string>
</dict>
</plist>
EOF
launchctl bootout "gui/$(id -u)/com.reedchan.toks.collector" 2>/dev/null || true
for i in 1 2 3 4 5; do
  launchctl bootstrap "gui/$(id -u)" "$PLIST" && break
  sleep 1  # bootout is asynchronous; bootstrap can race it
done

echo "==> Installing pi extension"
mkdir -p "$HOME/.pi/agent/extensions"
cp "$REPO/adapters/pi/toks-reporter.ts" "$HOME/.pi/agent/extensions/toks-reporter.ts"

echo "==> Launching Toks.app"
osascript -e 'quit app "Toks"' 2>/dev/null || true
sleep 1
open "$HOME/Applications/Toks.app"

echo "Done. Logs: $STATE_DIR/collector.log"
echo "Uninstall: scripts/uninstall.sh"
