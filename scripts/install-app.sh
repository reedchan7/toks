#!/bin/bash
# Self-contained installer, shipped inside Toks.app/Contents/Resources.
# Installs the app to ~/Applications, registers the bundled collector as a
# launchd agent, installs the pi extension, and launches the app.
set -euo pipefail

BUNDLE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP="$HOME/Applications/Toks.app"
STATE_DIR="$HOME/.local/share/toks"
PLIST="$HOME/Library/LaunchAgents/com.reedchan.toks.collector.plist"
LABEL="com.reedchan.toks.collector"

mkdir -p "$STATE_DIR/events" "$HOME/Library/LaunchAgents" "$HOME/Applications"

if [ "$BUNDLE" != "$APP" ]; then
  echo "==> Installing Toks.app to ~/Applications"
  rm -rf "$APP"
  ditto "$BUNDLE" "$APP"
fi

# Ad-hoc signed build: clear quarantine so Gatekeeper lets it run.
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

echo "==> Installing collector launchd agent"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$APP/Contents/Resources/toks-collector</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
  </dict>
  <key>WorkingDirectory</key><string>$STATE_DIR</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$STATE_DIR/collector.log</string>
  <key>StandardErrorPath</key><string>$STATE_DIR/collector.log</string>
</dict>
</plist>
EOF
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
for i in 1 2 3 4 5; do
  launchctl bootstrap "gui/$(id -u)" "$PLIST" && break
  sleep 1  # bootout is asynchronous; bootstrap can race it
done

echo "==> Installing pi extension"
mkdir -p "$HOME/.pi/agent/extensions"
cp "$APP/Contents/Resources/toks-reporter.ts" "$HOME/.pi/agent/extensions/toks-reporter.ts"

echo "==> Launching Toks.app"
osascript -e 'quit app "Toks"' 2>/dev/null || true
sleep 1
open "$APP"

echo "Done. Logs: $STATE_DIR/collector.log"
