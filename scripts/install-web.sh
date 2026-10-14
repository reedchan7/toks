#!/bin/bash
# Web installer: downloads the latest release and runs the bundled installer.
#   curl -fsSL https://raw.githubusercontent.com/reedchan7/toks/main/scripts/install-web.sh | bash
set -euo pipefail

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> Downloading the latest Toks release"
curl -fsSL -o "$TMP/Toks.zip" \
  https://github.com/reedchan7/toks/releases/latest/download/Toks.zip
unzip -q "$TMP/Toks.zip" -d "$TMP"

# The bundled installer stages Toks.app into ~/Applications before this temp
# directory is removed.
sh "$TMP/Toks.app/Contents/Resources/install.sh"
