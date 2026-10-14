#!/bin/bash
# Removes everything install.sh set up. Keeps ~/.local/share/toks history.
set -euo pipefail

launchctl bootout "gui/$(id -u)/com.reedchan.toks.collector" 2>/dev/null || true
pkill -x Toks || true
rm -f "$HOME/Library/LaunchAgents/com.reedchan.toks.collector.plist"
rm -f "$HOME/.pi/agent/extensions/toks-reporter.ts"
rm -rf "$HOME/Applications/Toks.app"

echo "Uninstalled. Metrics history kept at ~/.local/share/toks/"
