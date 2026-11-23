#!/bin/zsh
# One-step install for fconv:
#   1. builds the binary
#   2. copies it to ~/.local/bin
#   3. puts ~/.local/bin on your PATH (shell startup file) if it isn't already
#   4. adds the "Convert Images…" Quick Action to Finder's right-click menu
# Safe to run again; it replaces the previous install.
set -euo pipefail
cd "${0:A:h}"

BIN="$HOME/.local/bin"
SERVICE="$HOME/Library/Services/Convert Images.workflow"

# /usr/bin/swiftc exists even without developer tools (it is a stub that opens
# an install prompt), so ask xcode-select instead.
if ! xcode-select -p >/dev/null 2>&1; then
  echo "fconv needs the Swift compiler. Install Apple's Command Line Tools, then run this again:" >&2
  echo "  xcode-select --install" >&2
  exit 1
fi

echo "building…"
mkdir -p build "$BIN"
swiftc -O main.swift -o build/fconv
install -m 755 build/fconv "$BIN/fconv"
echo "✓ binary        $BIN/fconv"

mkdir -p "$HOME/Library/Services"
rm -rf "$SERVICE"
cp -R "quick-action/Convert Images.workflow" "$SERVICE"
/System/Library/CoreServices/pbs -update 2>/dev/null || true
echo "✓ Quick Action  $SERVICE"

# PATH: only touch a startup file when ~/.local/bin is genuinely missing.
case ":$PATH:" in
  *":$BIN:"*)
    echo "✓ PATH          already includes $BIN"
    ;;
  *)
    case "${SHELL:t}" in
      fish)
        rc="$HOME/.config/fish/config.fish"
        line='fish_add_path "$HOME/.local/bin"'
        ;;
      bash)
        rc="$HOME/.bash_profile"
        line='export PATH="$HOME/.local/bin:$PATH"'
        ;;
      *)
        rc="${ZDOTDIR:-$HOME}/.zshrc"
        line='export PATH="$HOME/.local/bin:$PATH"'
        ;;
    esac
    if [[ -f "$rc" ]] && grep -qF "$line" "$rc"; then
      echo "✓ PATH          $rc already sets it"
    else
      mkdir -p "${rc:h}"
      printf '\n# fconv\n%s\n' "$line" >> "$rc"
      echo "✓ PATH          added $BIN to $rc"
    fi
    echo "  open a new terminal window (or run: source $rc) to use 'fconv'"
    ;;
esac

echo
echo "try it:    fconv png photo.heic"
echo "in Finder: right-click images > Quick Actions > Convert Images…"
echo "uninstall: rm '$BIN/fconv' && rm -rf '$SERVICE'"
