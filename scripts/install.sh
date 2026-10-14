#!/bin/bash
# Repo install: build Toks.app, then run the bundled installer (the same one
# release users get inside Toks.app/Contents/Resources/install.sh).
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> Building Toks.app"
sh "$REPO/menubar/build.sh"

sh "$REPO/menubar/build/Toks.app/Contents/Resources/install.sh"

echo "Uninstall: scripts/uninstall.sh"
