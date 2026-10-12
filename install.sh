#!/usr/bin/env bash
# install.sh: set up everything voice-vim needs on this Mac. Safe to re-run:
# it installs only what is missing and leaves what is already right alone.
#
#   ./install.sh           install what is missing, link the module, reload
#   ./install.sh --check   report what is installed and missing; change nothing
#
# Each step prints one line: ok, installed, skipped, or missing: <what to do>.
# Overrides (used by tests/test-install.sh):
#   VOICE_VIM_APPS_DIR         where .app bundles are looked for (/Applications)
#   VOICE_VIM_INSTALL_DRY_RUN  1 prints each command instead of running it
#   HOME, PATH                 where ~/.hammerspoon and the tools are found
#
# Add any future setup step here, following the same pattern.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
apps=${VOICE_VIM_APPS_DIR:-/Applications}
dry=${VOICE_VIM_INSTALL_DRY_RUN:-0}
hsdir="$HOME/.hammerspoon"
init="$hsdir/init.lua"
module="$root/hammerspoon/voice-vim.lua"
link="$hsdir/voice-vim.lua"

check=0
case "${1:-}" in
  "") ;;
  --check) check=1 ;;
  -h | --help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "install.sh: unknown argument: $1 (try --help)" >&2; exit 2 ;;
esac

missing=0
# Print one status line: say <ok|installed|skipped|missing:> <text>.
say() {
  if [ "$1" = "missing:" ]; then missing=$((missing + 1)); fi
  printf '%-10s %s\n' "$1" "$2"
}

# Run a command, or only print it under VOICE_VIM_INSTALL_DRY_RUN=1.
run() {
  if [ "$dry" = 1 ]; then echo "+ $*"; else "$@"; fi
}

# True if <name>.app is in the apps dir or ~/Applications.
has_app() {
  [ -d "$apps/$1.app" ] || [ -d "$HOME/Applications/$1.app" ]
}

# Install a cask unless its app is already there: cask <App name> <cask>.
cask() {
  if has_app "$1"; then
    say ok "$1"
  elif [ $check = 1 ]; then
    say missing: "$1: run ./install.sh (brew install --cask $2)"
  else
    run brew install --cask "$2"
    say installed "$1 (brew install --cask $2)"
  fi
}

# 1. Homebrew installs everything else, so stop here without it.
# Apple Silicon installs it in /opt/homebrew/bin, which may not be on PATH yet.
if ! command -v brew >/dev/null 2>&1 && [ -x /opt/homebrew/bin/brew ] && [ -z "${VOICE_VIM_APPS_DIR:-}" ]; then
  PATH="/opt/homebrew/bin:$PATH"
fi
if command -v brew >/dev/null 2>&1; then
  say ok "Homebrew"
else
  say missing: 'Homebrew: install it with /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)", then re-run ./install.sh'
  if [ $check = 0 ]; then exit 1; fi
fi

# 2. Hammerspoon (hotkey and paste) and Neovide (the one window), as casks.
cask Hammerspoon hammerspoon
cask Neovide neovide-app

# 3. Neovim, the editor inside the window.
if command -v nvim >/dev/null 2>&1; then
  say ok "Neovim"
elif [ $check = 1 ]; then
  say missing: "Neovim: run ./install.sh (brew install neovim)"
else
  run brew install neovim
  say installed "Neovim (brew install neovim)"
fi

# 4. Apps we only check for: Ghostty (session windows) and Wispr Flow.
if has_app Ghostty; then
  say ok "Ghostty"
else
  say missing: "Ghostty: get it from https://ghostty.org (session windows use it)"
fi
if has_app "Wispr Flow"; then
  say ok "Wispr Flow"
else
  say missing: "Wispr Flow: get it from https://wisprflow.ai"
fi

# 5. Tools the scripts use: python3 and sqlite3 (history database).
for tool in python3 sqlite3; do
  if command -v "$tool" >/dev/null 2>&1; then
    say ok "$tool"
  else
    say missing: "$tool: install the Xcode command line tools (xcode-select --install)"
  fi
done

# 6. Link the Hammerspoon module into ~/.hammerspoon. A correct link is
# left alone; a regular file is never overwritten.
if [ -L "$link" ] && [ "$(readlink "$link")" = "$module" ]; then
  say ok "module link $link"
elif [ -e "$link" ] && ! [ -L "$link" ]; then
  say missing: "$link is a regular file: move it aside, then re-run ./install.sh"
elif [ $check = 1 ]; then
  say missing: "module link $link: run ./install.sh"
else
  run mkdir -p "$hsdir"
  run ln -sfn "$module" "$link"
  say installed "module link $link -> $module"
fi

# 7. Add the voice-vim block to init.lua once. It sets nothing, so the
# module's defaults apply; settings go inside start({ ... }).
if [ -f "$init" ] && grep -qF 'require("voice-vim")' "$init"; then
  say ok "voice-vim block in $init"
elif [ $check = 1 ]; then
  say missing: "voice-vim block in $init: run ./install.sh"
elif [ "$dry" = 1 ]; then
  echo "+ append the voice-vim block to $init"
  say installed "voice-vim block in $init"
else
  mkdir -p "$hsdir"
  if [ -s "$init" ]; then echo >> "$init"; fi
  cat >> "$init" <<'LUA'
-- voice-vim: dictate into Neovim with Wispr Flow, then paste back.
-- Settings go inside start({ ... }); see guide.md, "Configure".
require("hs.ipc") -- enables the `hs` CLI for reloading and debugging
require("voice-vim").start({
})
LUA
  say installed "voice-vim block in $init"
fi

# 8. Remove the old Option+V hotkey line (bin/voice-vim-migrate-init keeps
# a .bak and changes nothing on a second run).
oldkey='^[[:space:]]*hotkey[[:space:]]*=[[:space:]]*\{[[:space:]]*\{[[:space:]]*"alt"[[:space:]]*\}[[:space:]]*,[[:space:]]*"v"[[:space:]]*\}'
if [ $check = 1 ]; then
  if [ -f "$init" ] && grep -qE "$oldkey" "$init"; then
    say missing: "old Option+V hotkey in $init: run ./install.sh to remove it"
  else
    say ok "no old Option+V hotkey"
  fi
elif [ "$dry" = 1 ]; then
  echo "+ $root/bin/voice-vim-migrate-init $init"
  say skipped "Option+V migration (dry run)"
else
  out=$("$root/bin/voice-vim-migrate-init" "$init")
  case "$out" in
    *"nothing changed"*) say ok "no old Option+V hotkey" ;;
    *) say installed "removed the old Option+V hotkey ($(echo "$out" | sed -n 's/^backup: //p' | head -1) is the backup)" ;;
  esac
fi

# 9. Start Hammerspoon, or reload it so it picks up the module and block.
if [ $check = 1 ]; then
  say skipped "start or reload Hammerspoon (--check changes nothing)"
elif ! pgrep -xq Hammerspoon; then
  run open -g -a Hammerspoon
  say ok "Hammerspoon started"
elif [ "$dry" = 1 ]; then
  echo "+ hs -t 5 -c hs.reload()"
  say ok "Hammerspoon reloaded"
elif command -v hs >/dev/null 2>&1 && hs -t 5 -c 'return true' </dev/null >/dev/null 2>&1; then
  # The reload drops the connection hs waits on, so its status is ignored.
  hs -t 5 -c 'hs.reload()' </dev/null >/dev/null 2>&1 || true
  say ok "Hammerspoon reloaded (hs -c 'hs.reload()')"
else
  say missing: "reload Hammerspoon: choose Reload Config from its menu bar icon"
fi

# 10. The steps no script can do.
cat <<MSG

Once, by hand (macOS allows no script to do these):
  1. Accessibility for Hammerspoon: System Settings > Privacy & Security >
     Accessibility > enable Hammerspoon. Then quit and relaunch Hammerspoon;
     it only checks at launch.
  2. Automation for Ghostty: the first session window asks whether
     Hammerspoon may control Ghostty. Click OK.
  3. Open Neovide once (open -a Neovide) and click Open if macOS asks, so
     it starts without a prompt later. Quit it again.

Hotkey: Ctrl+Option+V. Settings: the voice-vim block in $init.
MSG

if [ $check = 1 ]; then
  echo "--check: $missing missing; nothing was changed."
elif [ $missing -gt 0 ]; then
  echo "$missing item(s) need you; see the missing: lines above."
else
  echo "Everything is installed."
fi
