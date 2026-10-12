#!/usr/bin/env bash
# Tests for install.sh. Every run uses a temp HOME, a fake Applications dir
# (VOICE_VIM_APPS_DIR) and recording fakes for brew, open, hs and pgrep first
# on PATH, so the real system (Homebrew, /Applications, ~/.hammerspoon,
# Hammerspoon itself) is never touched.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
install="$root/install.sh"
tmp=$(mktemp -d -t vv-install-test)
trap 'rm -rf "$tmp"' EXIT
export VOICE_VIM_DB="$tmp/history.sqlite"
real_nvim=$(command -v nvim || true)
fail=0
check() { # name want got
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want '$2' got '$3'"; fail=1; fi
}

# Fakes. Each records "<name> <args>" in $FAKE_CALLS. brew "installs" by
# creating the app bundle in the fake apps dir, or a fake nvim in the fake
# bin dir. pgrep reports Hammerspoon running when FAKE_HS_RUNNING=1.
fakes="$tmp/fakes"; mkdir -p "$fakes"
cat > "$fakes/brew" <<'SH'
#!/bin/bash
echo "brew $*" >> "$FAKE_CALLS"
case "$*" in
  "install --cask hammerspoon") mkdir -p "$VOICE_VIM_APPS_DIR/Hammerspoon.app" ;;
  "install --cask neovide-app") mkdir -p "$VOICE_VIM_APPS_DIR/Neovide.app" ;;
  "install neovim") printf '#!/bin/sh\nexit 0\n' > "$FAKE_BIN/nvim"; chmod +x "$FAKE_BIN/nvim" ;;
esac
SH
for name in open hs; do
  printf '#!/bin/bash\necho "%s $*" >> "$FAKE_CALLS"\n' "$name" > "$fakes/$name"
done
cat > "$fakes/pgrep" <<'SH'
#!/bin/bash
echo "pgrep $*" >> "$FAKE_CALLS"
[ "${FAKE_HS_RUNNING:-0}" = 1 ]
SH
chmod +x "$fakes"/*

# setup <name> [fake...]: a scenario dir $s with home/, apps/, bin/ (the
# given fakes, default all four) and an empty calls log; exports the env.
setup() {
  s="$tmp/$1"; shift
  mkdir -p "$s/home" "$s/apps" "$s/bin"
  : > "$s/calls"
  local f
  for f in ${*:-brew open hs pgrep}; do cp "$fakes/$f" "$s/bin/"; done
  export HOME="$s/home" VOICE_VIM_APPS_DIR="$s/apps" FAKE_CALLS="$s/calls" \
    FAKE_BIN="$s/bin" PATH="$s/bin:/usr/bin:/bin" FAKE_HS_RUNNING=0
  unset VOICE_VIM_INSTALL_DRY_RUN
  # Guard: the system tools must resolve to the fakes, or not at all.
  for f in brew open hs pgrep nvim; do
    case "$(command -v "$f" || echo none)" in
      "$s/bin/"* | none) ;;
      *) echo "FAIL guard: $f resolves outside the fakes; aborting"; exit 1 ;;
    esac
  done
}
apps_ghostty_flow() { mkdir -p "$s/apps/Ghostty.app" "$s/apps/Wispr Flow.app"; }
# Snapshot of every file under home: path, inode and contents.
snapshot() {
  (cd "$s/home" && find . | sort | while read -r p; do
    if [ -L "$p" ]; then echo "$p link $(stat -f %i "$p") $(readlink "$p")"
    elif [ -f "$p" ]; then echo "$p file $(cksum < "$p")"
    else echo "$p dir"; fi
  done)
}
init_lua() { echo "$s/home/.hammerspoon/init.lua"; }

check "bash -n install.sh" 0 "$(bash -n "$install" >/dev/null 2>&1; echo $?)"

# Missing brew: stops non-zero with the Homebrew install command, does nothing.
setup nobrew open hs pgrep
out=$(bash "$install" 2>&1); st=$?
check "no brew: exits non-zero" 1 $st
check "no brew: prints the brew install command" 1 \
  "$(grep -c '^missing: .*raw.githubusercontent.com/Homebrew/install/HEAD/install.sh' <<<"$out")"
check "no brew: no fake calls" "" "$(cat "$s/calls")"
check "no brew: home untouched" "." "$(snapshot | cut -d' ' -f1 | tr '\n' ' ' | sed 's/ $//')"

# Fresh HOME: installs the three, links the module, adds the block once,
# runs the migration, starts Hammerspoon.
setup fresh; apps_ghostty_flow
out=$(bash "$install" 2>&1); st=$?
check "fresh: exits 0" 0 $st
check "fresh: brew asked for hammerspoon once" 1 "$(grep -cx 'brew install --cask hammerspoon' "$s/calls")"
check "fresh: brew asked for neovide-app once" 1 "$(grep -cx 'brew install --cask neovide-app' "$s/calls")"
check "fresh: brew asked for neovim once" 1 "$(grep -cx 'brew install neovim' "$s/calls")"
check "fresh: no other brew calls" 3 "$(grep -c '^brew' "$s/calls")"
check "fresh: module symlinked" "$root/hammerspoon/voice-vim.lua" "$(readlink "$s/home/.hammerspoon/voice-vim.lua")"
check "fresh: one init.lua block" 1 "$(grep -cF 'require("voice-vim")' "$(init_lua)")"
check "fresh: migration ran" 1 "$(grep -c '^ok  *no old Option+V hotkey' <<<"$out")"
check "fresh: Hammerspoon started" 1 "$(grep -cx 'open -g -a Hammerspoon' "$s/calls")"
check "fresh: no missing lines" 0 "$(grep -c '^missing:' <<<"$out")"
check "fresh: manual checklist printed" 1 "$(grep -c 'Accessibility for Hammerspoon' <<<"$out")"
check "fresh: no Ghostty Automation step" 0 "$(grep -c 'Automation for Ghostty' <<<"$out")"
check "fresh: Ghostty ok as optional" 1 "$(grep -c '^ok  *Ghostty (optional' <<<"$out")"
# The block is valid Lua and passes no settings, so the module defaults apply.
if [ -n "$real_nvim" ]; then
  cat > "$tmp/load-init.lua" <<'LUA'
local got
package.preload["hs.ipc"] = function() return {} end
package.preload["voice-vim"] = function() return { start = function(c) got = c end } end
dofile(arg[1])
io.write(type(got) == "table" and next(got) == nil and "empty" or "bad")
LUA
  check "fresh: block calls start({}) with no settings" empty "$("$real_nvim" -l "$tmp/load-init.lua" "$(init_lua)" 2>&1)"
else
  echo "skip fresh: block load (nvim not found)"
fi

# Second run on the same HOME: installs nothing and changes no file.
before=$(snapshot); : > "$s/calls"
out=$(bash "$install" 2>&1); st=$?
check "second: exits 0" 0 $st
check "second: no brew calls" 0 "$(grep -c '^brew' "$s/calls")"
check "second: no installed lines" 0 "$(grep -c '^installed' <<<"$out")"
check "second: still one init.lua block" 1 "$(grep -cF 'require("voice-vim")' "$(init_lua)")"
check "second: files, symlink and inodes unchanged" "$before" "$(snapshot)"

# --check after install: all ok, no fake calls, nothing changed.
: > "$s/calls"
out=$(bash "$install" --check 2>&1); st=$?
check "check installed: exits 0" 0 $st
check "check installed: no missing lines" 0 "$(grep -c '^missing:' <<<"$out")"
check "check installed: no fake calls" "" "$(cat "$s/calls")"
check "check installed: unchanged" "$before" "$(snapshot)"

# --check on a fresh HOME: lists what is missing, calls nothing, writes nothing.
setup checkfresh
out=$(bash "$install" --check 2>&1); st=$?
check "check fresh: exits 0" 0 $st
check "check fresh: no fake calls" "" "$(cat "$s/calls")"
check "check fresh: home untouched" "." "$(snapshot | cut -d' ' -f1 | tr '\n' ' ' | sed 's/ $//')"
check "check fresh: apps untouched" "" "$(ls "$s/apps")"
for item in Hammerspoon Neovide Neovim "Wispr Flow" "module link" "voice-vim block"; do
  check "check fresh: lists $item as missing" 1 "$(grep -c "^missing: *$item" <<<"$out")"
done
check "check fresh: Ghostty is optional, not missing" "0 1" \
  "$(grep -c '^missing: *Ghostty' <<<"$out") $(grep -c '^skipped *Ghostty not found (optional' <<<"$out")"
check "check fresh: says nothing changed" 1 "$(grep -c 'nothing was changed' <<<"$out")"

# Ghostty and Wispr Flow absent: Wispr Flow is a missing: line, Ghostty is
# optional (skipped, not counted); neither is installed.
setup noapps
out=$(bash "$install" 2>&1); st=$?
check "no apps: exits 0" 0 $st
check "no apps: Ghostty skipped as optional" 1 "$(grep -c '^skipped *Ghostty not found (optional' <<<"$out")"
check "no apps: no Ghostty missing line" 0 "$(grep -c '^missing: *Ghostty' <<<"$out")"
check "no apps: only Wispr Flow counted missing" 1 "$(grep -c '^1 item(s) need you' <<<"$out")"
check "no apps: Wispr Flow missing line" 1 "$(grep -c '^missing: *Wispr Flow: get it from https://wisprflow.ai' <<<"$out")"
check "no apps: neither installed" 0 "$(grep -ciE 'ghostty|wispr' "$s/calls")"
check "no apps: neither app created" no "$([ -e "$s/apps/Ghostty.app" ] || [ -e "$s/apps/Wispr Flow.app" ] && echo yes || echo no)"

# An init.lua with the old Option+V line: line removed with a .bak, and no
# second block is added.
setup oldkey; apps_ghostty_flow
mkdir -p "$s/home/.hammerspoon"
cat > "$(init_lua)" <<'LUA'
hs.loadSpoon("Foo")

-- voice-vim: dictate into an ephemeral Neovim buffer, then paste back.
require("hs.ipc") -- enables the `hs` CLI for reloading and debugging
require("voice-vim").start({
  hotkey = { { "alt" }, "v" },
  autoStartFlow = false,
})
LUA
cp "$(init_lua)" "$s/orig.lua"
out=$(bash "$install" 2>&1); st=$?
check "old key: exits 0" 0 $st
check "old key: Option+V line removed" 0 "$(grep -c '"alt"' "$(init_lua)")"
check "old key: .bak equals original" same "$(cmp -s "$s/orig.lua" "$(init_lua).bak" && echo same)"
check "old key: reports the removal" 1 "$(grep -c '^installed *removed the old Option+V hotkey' <<<"$out")"
check "old key: still one block" 1 "$(grep -cF 'require("voice-vim")' "$(init_lua)")"
check "old key: other lines kept" 1 "$(grep -c 'autoStartFlow = false' "$(init_lua)")"

# Hammerspoon already running with a working hs: reloads with hs -c.
setup running; apps_ghostty_flow
export FAKE_HS_RUNNING=1
out=$(bash "$install" 2>&1); st=$?
check "running: exits 0" 0 $st
check "running: hs -c reload called" 1 "$(grep -cx 'hs -t 5 -c hs.reload()' "$s/calls")"
check "running: not opened again" 0 "$(grep -c '^open' "$s/calls")"
check "running: reports reload" 1 "$(grep -c '^ok  *Hammerspoon reloaded' <<<"$out")"

# Running but no hs CLI: tells Joe to Reload Config.
setup running-nohs brew open pgrep; apps_ghostty_flow
export FAKE_HS_RUNNING=1
out=$(bash "$install" 2>&1)
check "running, no hs: Reload Config line" 1 "$(grep -c '^missing: *reload Hammerspoon: choose Reload Config' <<<"$out")"

# Dry run: prints the commands, runs none of them, writes nothing.
setup dry; apps_ghostty_flow
out=$(VOICE_VIM_INSTALL_DRY_RUN=1 bash "$install" 2>&1); st=$?
check "dry run: exits 0" 0 $st
check "dry run: prints brew install" 1 "$(grep -cx '+ brew install --cask hammerspoon' <<<"$out")"
check "dry run: prints open" 1 "$(grep -cx '+ open -g -a Hammerspoon' <<<"$out")"
check "dry run: no brew or open calls" 0 "$(grep -cE '^(brew|open|hs) ' "$s/calls")"
check "dry run: home untouched" "." "$(snapshot | cut -d' ' -f1 | tr '\n' ' ' | sed 's/ $//')"

[ $fail -eq 0 ] && echo "all ok" || echo "FAILED"
exit $fail
