#!/bin/bash
# Removes everything install.sh set up. Keeps ~/.local/share/toks history.
set -euo pipefail

launchctl bootout "gui/$(id -u)/com.reedchan.toks.collector" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/com.reedchan.toks.collector.plist"
rm -f "$HOME/.pi/agent/extensions/toks-reporter.ts"
rm -rf "$HOME/Applications/Toks.app"
osascript -e 'quit app "Toks"' 2>/dev/null || true

echo "Uninstalled. Metrics history kept at ~/.local/share/toks/"
