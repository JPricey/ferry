#!/usr/bin/env bash
# Install voice-vim for the current user (macOS).
#  1. brew install --cask hammerspoon (if missing)
#  2. symlink hammerspoon/voice-vim.lua into ~/.hammerspoon/
#  3. add a require + start block to ~/.hammerspoon/init.lua (once)
#  4. launch/reload Hammerspoon
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
hsdir="$HOME/.hammerspoon"

if ! [ -d "/Applications/Hammerspoon.app" ]; then
  echo "Installing Hammerspoon..."
  brew install --cask hammerspoon
fi

mkdir -p "$hsdir"
ln -sfn "$root/hammerspoon/voice-vim.lua" "$hsdir/voice-vim.lua"

init="$hsdir/init.lua"
touch "$init"
if ! grep -q 'require("voice-vim")' "$init"; then
  cat >> "$init" <<LUA

-- voice-vim: dictate into an ephemeral Neovim buffer, then paste back.
require("hs.ipc") -- enables the \`hs\` CLI for reloading and debugging
require("voice-vim").start({
  hotkey = { { "alt" }, "v" },
  autoStartFlow = false,
})
LUA
  echo "Added voice-vim block to $init"
fi

# Hammerspoon reads init.lua on launch. If it is already running, reload from
# its menu bar icon (or add require("hs.ipc") to init.lua and use `hs -c`).
open -g -a Hammerspoon

cat <<MSG

voice-vim installed.
  Hotkey:   option+v (edit ~/.hammerspoon/init.lua to change)
  Module:   $hsdir/voice-vim.lua -> $root/hammerspoon/voice-vim.lua

First run: Hammerspoon needs Accessibility permission
  System Settings > Privacy & Security > Accessibility > enable Hammerspoon
then reload its config from the menu bar icon.
MSG
