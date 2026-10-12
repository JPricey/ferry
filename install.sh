#!/usr/bin/env bash
# install.sh: set up everything ferry needs on this Mac. Safe to re-run:
# it installs only what is missing and leaves what is already right alone.
#
#   ./install.sh           install what is missing, link the module, reload
#                          Hammerspoon and list the hotkeys and URLs ferry
#                          bound; rerun it after any change
#   ./install.sh --check   report what is installed and missing; change nothing
#
# Each step prints one line: ok, installed, skipped, or missing: <what to do>.
# Overrides (used by tests/test-install.sh):
#   FERRY_APPS_DIR         where .app bundles are looked for (/Applications)
#   FERRY_BUNDLE_DIR       where ferry.app is built (~/Applications)
#   FERRY_INSTALL_DRY_RUN  1 prints each command instead of running it
#   FERRY_HS_WAIT          seconds Hammerspoon gets to answer after a reload (10)
#   HOME, PATH                 where ~/.hammerspoon and the tools are found
#
# Add any future setup step here, following the same pattern.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
apps=${FERRY_APPS_DIR:-/Applications}
dry=${FERRY_INSTALL_DRY_RUN:-0}
hsdir="$HOME/.hammerspoon"
init="$hsdir/init.lua"
module="$root/hammerspoon/ferry.lua"
link="$hsdir/ferry.lua"
bundle="${FERRY_BUNDLE_DIR:-$HOME/Applications}/ferry.app"
icon="$root/assets/ferry.png"
icns="$root/assets/ferry.icns"

check=0
case "${1:-}" in
  "") ;;
  --check) check=1 ;;
  -h | --help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "install.sh: unknown argument: $1 (try --help)" >&2; exit 2 ;;
esac

missing=0
# Print one status line: say <ok|installed|skipped|missing:> <text>.
say() {
  if [ "$1" = "missing:" ]; then missing=$((missing + 1)); fi
  printf '%-10s %s\n' "$1" "$2"
}

# Run a command, or only print it under FERRY_INSTALL_DRY_RUN=1.
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
if ! command -v brew >/dev/null 2>&1 && [ -x /opt/homebrew/bin/brew ] && [ -z "${FERRY_APPS_DIR:-}" ]; then
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

# 4. Apps we only check for: Wispr Flow (required) and Ghostty (optional:
# Neovide copies its font and background colour; never counted as missing).
if has_app Ghostty; then
  say ok "Ghostty (optional: Neovide uses its font and colour)"
else
  say skipped "Ghostty not found (optional: Neovide copies its font and colour when it is installed)"
fi
if has_app "Wispr Flow"; then
  say ok "Wispr Flow"
else
  say missing: "Wispr Flow: get it from https://wisprflow.ai"
fi

# 5. python3 with its sqlite3 module: ferry-notes, ferry-corrections and
# ferry-migrate-history use it. The sqlite3 command-line tool is not needed.
if command -v python3 >/dev/null 2>&1 && python3 -B -c 'import sqlite3' >/dev/null 2>&1; then
  say ok "python3"
else
  say missing: "python3 (with sqlite3): install the Xcode command line tools (xcode-select --install)"
fi

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

# 7. ferry.app in the user's Applications: a wrapper bundle whose
# executable is a symlink to Neovide's binary, so our window shows up as
# "ferry" with its own icon (the host launches it by direct exec). The
# binary is found like hammerspoon/hosts/neovide.lua finds it: PATH, the
# usual bin dirs, then Neovide.app, and the link points at its real path
# (Homebrew's bin/neovide is itself a link into Neovide.app). ferry.icns is
# the bundle icon Finder and the Dock show before launch; ferry.png is
# what the host passes to Neovide's --icon. A right bundle is left alone; a
# missing or wrong part (Info.plist, symlink, icon, icns) is rewritten.
find_neovide() {
  local d dirs="$PATH"
  # Tests (FERRY_APPS_DIR set) never look in the real Homebrew dirs.
  [ -n "${FERRY_APPS_DIR:-}" ] || dirs="$dirs:/opt/homebrew/bin:/usr/local/bin"
  dirs="$dirs:$HOME/.local/bin:$HOME/.cargo/bin"
  local IFS=:
  for d in $dirs; do
    if [ -n "$d" ] && [ -f "$d/neovide" ] && [ -x "$d/neovide" ]; then echo "$d/neovide"; return 0; fi
  done
  for d in "$apps/Neovide.app" "$HOME/Applications/Neovide.app"; do
    if [ -f "$d/Contents/MacOS/neovide" ] && [ -x "$d/Contents/MacOS/neovide" ]; then
      echo "$d/Contents/MacOS/neovide"; return 0
    fi
  done
  return 1
}
bundle_plist() {
  cat <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDisplayName</key>
	<string>ferry</string>
	<key>CFBundleExecutable</key>
	<string>ferry</string>
	<key>CFBundleIconFile</key>
	<string>ferry</string>
	<key>CFBundleIdentifier</key>
	<string>local.ferry</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>ferry</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
PLIST
}
plist="$bundle/Contents/Info.plist" exe="$bundle/Contents/MacOS/ferry"
bicon="$bundle/Contents/Resources/ferry.png" bicns="$bundle/Contents/Resources/ferry.icns"
nbin=$(find_neovide || true)
# The real path of the found binary; the found path when that fails.
if [ -n "$nbin" ]; then
  real=$(realpath "$nbin" 2>/dev/null || true)
  if [ -n "$real" ] && [ -f "$real" ] && [ -x "$real" ]; then nbin=$real; fi
fi
wrong=""
{ [ -f "$plist" ] && [ "$(cat "$plist")" = "$(bundle_plist)" ]; } || wrong+=" Info.plist"
{ [ -n "$nbin" ] && [ -L "$exe" ] && [ "$(readlink "$exe")" = "$nbin" ]; } || wrong+=" executable"
cmp -s "$icon" "$bicon" || wrong+=" icon"
cmp -s "$icns" "$bicns" || wrong+=" icns"
if [ -z "$wrong" ]; then
  say ok "ferry.app $bundle"
elif [ -z "$nbin" ]; then
  if [ "$dry" = 1 ] && [ $check = 0 ]; then
    say skipped "ferry.app: Neovide is not installed yet (dry run)"
  else
    say missing: "ferry.app: Neovide's binary not found; install Neovide, then re-run ./install.sh"
  fi
elif [ $check = 1 ]; then
  say missing: "ferry.app $bundle (wrong or missing:$wrong): run ./install.sh"
else
  run mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
  case "$wrong" in *Info.plist*)
    if [ "$dry" = 1 ]; then echo "+ write $plist"
    else bundle_plist > "$plist.tmp" && mv -f "$plist.tmp" "$plist"; fi ;;
  esac
  case "$wrong" in *executable*) run rm -rf "$exe"; run ln -s "$nbin" "$exe" ;; esac
  case "$wrong" in *" icon"*) run cp "$icon" "$bicon" ;; esac
  case "$wrong" in *icns*) run cp "$icns" "$bicns" ;; esac
  # A new mtime tells Finder and the Dock to read the bundle again.
  run touch "$bundle"
  say installed "ferry.app $bundle (wrote$wrong; runs $nbin)"
fi

# 8. Add the ferry block to init.lua once. It sets nothing, so the
# module's defaults apply; settings go inside start({ ... }). A block
# without require("hs.ipc") gets that line above require("ferry") (the
# old file kept as init.lua.bak): the hs CLI step 10 uses needs it.
ipc_line='require("hs.ipc") -- enables the `hs` CLI for reloading and debugging'
has_ipc() { grep -v '^[[:space:]]*--' "$init" | grep -q 'require.*hs\.ipc'; }
if [ -f "$init" ] && grep -qF 'require("ferry")' "$init" && has_ipc; then
  say ok "ferry block in $init"
elif [ -f "$init" ] && grep -qF 'require("ferry")' "$init"; then
  if [ $check = 1 ]; then
    say missing: "require(\"hs.ipc\") in $init (the hs CLI needs it): run ./install.sh"
  elif [ "$dry" = 1 ]; then
    echo "+ add $ipc_line to $init"
    say installed "require(\"hs.ipc\") in $init"
  else
    bak="$init.bak"
    [ -e "$bak" ] && bak="$init.bak.$(date +%Y%m%d%H%M%S)"
    cp -p "$init" "$bak"
    awk -v line="$ipc_line" '!done && /require\("ferry"\)/ { print line; done = 1 } { print }' \
      "$bak" > "$init.tmp" && mv -f "$init.tmp" "$init"
    say installed "require(\"hs.ipc\") in $init ($bak is the backup)"
  fi
elif [ $check = 1 ]; then
  say missing: "ferry block in $init: run ./install.sh"
elif [ "$dry" = 1 ]; then
  echo "+ append the ferry block to $init"
  say installed "ferry block in $init"
else
  mkdir -p "$hsdir"
  if [ -s "$init" ]; then echo >> "$init"; fi
  cat >> "$init" <<LUA
-- ferry: dictate into Neovim with Wispr Flow, then paste back.
-- Settings go inside start({ ... }); see guide.md, "Configure".
$ipc_line
require("ferry").start({
})
LUA
  say installed "ferry block in $init"
fi

# 9. Remove the old Option+V hotkey line (bin/ferry-migrate-init keeps
# a .bak and changes nothing on a second run).
oldkey='^[[:space:]]*hotkey[[:space:]]*=[[:space:]]*\{[[:space:]]*\{[[:space:]]*"alt"[[:space:]]*\}[[:space:]]*,[[:space:]]*"v"[[:space:]]*\}'
if [ $check = 1 ]; then
  if [ -f "$init" ] && grep -qE "$oldkey" "$init"; then
    say missing: "old Option+V hotkey in $init: run ./install.sh to remove it"
  else
    say ok "no old Option+V hotkey"
  fi
elif [ "$dry" = 1 ]; then
  echo "+ $root/bin/ferry-migrate-init $init"
  say skipped "Option+V migration (dry run)"
else
  out=$("$root/bin/ferry-migrate-init" "$init")
  case "$out" in
    *"nothing changed"*) say ok "no old Option+V hotkey" ;;
    *) say installed "removed the old Option+V hotkey ($(echo "$out" | sed -n 's/^backup: //p' | head -1) is the backup)" ;;
  esac
fi

# 10. Start Hammerspoon, or reload it so it picks up the module and block
# (this is the one update command: never Reload Config by hand). Then wait
# until it answers again and ask ferry what it bound (M.status() in
# hammerspoon/ferry.lua): one ok line per hotkey and URL, or missing:
# with the failure.
#
# The ferry nvim server is never restarted: bin/ferry-host and
# lua/ferry/note.lua reload their modules in a running server when the
# module's api version changes (note.api, flow.api, gui.api), keeping the
# open note. A change that must reach a running server bumps that api; a
# restart would only lose the note's unsaved typing.
hs_wait=${FERRY_HS_WAIT:-10} # seconds Hammerspoon gets to answer after a (re)load
if [ -d /opt/homebrew/bin ]; then cli='hs.ipc.cliInstall("/opt/homebrew")'; else cli='hs.ipc.cliInstall()'; fi
hs_cli="in the Hammerspoon console run $cli once, then re-run ./install.sh"
# Ask Hammerspoon (Lua); prints its answer (any colour codes dropped), fails
# when it does not answer (pipefail keeps hs's status).
esc=$(printf '\033')
hs_ask() { hs -t 1 -c "$1" </dev/null 2>/dev/null | sed -e "s/$esc\[[0-9;]*m//g"; }
# Wait until a fresh Lua state answers: the reload command sets a global
# that the old state keeps and the new one lacks.
hs_wait_fresh() {
  local i=0
  while [ $i -lt $((hs_wait * 4)) ]; do
    [ "$(hs_ask 'return _G.ferryInstallReload == nil' || true)" = true ] && return 0
    sleep 0.25; i=$((i + 1))
  done
  return 1
}
# Print ferry's status lines as install.sh lines.
hs_bound() {
  local out line
  out=$(hs_ask 'local f = package.loaded.ferry; if type(f) == "table" and f.status then return f.status() end; return "missing: ferry did not load in Hammerspoon; open its console for the error"' || true)
  [ -n "$out" ] || { say missing: "ferry's hotkeys: Hammerspoon gave no answer; open its console"; return; }
  while IFS= read -r line; do
    case "$line" in
      "ok "*) say ok "${line#ok }" ;;
      "skipped "*) say skipped "${line#skipped }" ;;
      "missing: "*) say missing: "${line#missing: }" ;;
      *) say missing: "ferry's hotkeys: unexpected answer: $line" ;;
    esac
  done <<<"$out"
}
if [ $check = 1 ]; then
  say skipped "start or reload Hammerspoon (--check changes nothing)"
elif ! pgrep -xq Hammerspoon; then
  run open -g -a Hammerspoon
  say ok "Hammerspoon started"
  if [ "$dry" = 1 ]; then :
  elif ! command -v hs >/dev/null 2>&1; then
    say missing: "the hs CLI (lets ./install.sh reload Hammerspoon and check ferry's hotkeys): $hs_cli"
  elif hs_wait_fresh; then
    hs_bound
  else
    say missing: "Hammerspoon did not answer within ${hs_wait}s of starting: open its console for the error, then re-run ./install.sh"
  fi
elif [ "$dry" = 1 ]; then
  echo "+ hs -t 5 -c _G.ferryInstallReload = true; hs.reload()"
  say ok "Hammerspoon reloaded"
elif ! command -v hs >/dev/null 2>&1; then
  say missing: "the hs CLI: $hs_cli; until then choose Reload Config from Hammerspoon's menu bar icon"
elif ! hs_ask 'return true' >/dev/null; then
  say missing: "reload Hammerspoon: the hs CLI got no answer (init.lua loads hs.ipc on the next reload); choose Reload Config from its menu bar icon once, then re-run ./install.sh"
else
  # The reload drops the connection hs waits on, so its status is ignored.
  hs -t 5 -c '_G.ferryInstallReload = true; hs.reload()' </dev/null >/dev/null 2>&1 || true
  if hs_wait_fresh; then
    say ok "Hammerspoon reloaded"
    hs_bound
  else
    say missing: "Hammerspoon did not answer within ${hs_wait}s of the reload: open its console for the error, then re-run ./install.sh"
  fi
fi

# 11. The steps no script can do.
cat <<MSG

Once, by hand (macOS allows no script to do these):
  1. Accessibility for Hammerspoon: System Settings > Privacy & Security >
     Accessibility > enable Hammerspoon. Then quit and relaunch Hammerspoon;
     it only checks at launch.
  2. Open Neovide once (open -a Neovide) and click Open if macOS asks, so
     it starts without a prompt later. Quit it again.

Hotkey: Ctrl+Option+V. Settings: the ferry block in $init.
MSG

if [ $check = 1 ]; then
  echo "--check: $missing missing; nothing was changed."
elif [ $missing -gt 0 ]; then
  echo "$missing item(s) need you; see the missing: lines above."
else
  echo "Everything is installed."
fi
