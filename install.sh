#!/bin/zsh
# Builds fconv, installs it to ~/.local/bin, and adds the "Convert Images…"
# Quick Action to Finder's right-click > Quick Actions / Services menu.
set -euo pipefail
cd "${0:A:h}"

BIN="$HOME/.local/bin"
SERVICE="$HOME/Library/Services/Convert Images.workflow"

mkdir -p build "$BIN"
swiftc -O main.swift -o build/fconv
install -m 755 build/fconv "$BIN/fconv"

rm -rf "$SERVICE"
cp -R "quick-action/Convert Images.workflow" "$SERVICE"
/System/Library/CoreServices/pbs -update

echo "installed $BIN/fconv"
echo "installed $SERVICE"
echo "uninstall: rm '$BIN/fconv' && rm -rf '$SERVICE'"
