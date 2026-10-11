#!/usr/bin/env bash
# Tests for bin/voice-vim-migrate-init on temp copies of init.lua. Never
# touches ~/.hammerspoon (HOME is pointed at a temp dir for the default path).
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d -t vv-migrate-test)
trap 'rm -rf "$tmp"' EXIT
export VOICE_VIM_DB="$tmp/history.sqlite"
migrate="$root/bin/voice-vim-migrate-init"
fail=0
check() { # name want got
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want '$2' got '$3'"; fail=1; fi
}

# The voice-vim block as install.sh wrote it into Joe's init.lua, with an
# unrelated line before it.
fixture() {
  cat <<'LUA'
hs.loadSpoon("Foo")

-- voice-vim: dictate into an ephemeral Neovim buffer, then paste back.
require("hs.ipc") -- enables the `hs` CLI for reloading and debugging
require("voice-vim").start({
  hotkey = { { "alt" }, "v" },
  autoStartFlow = false,
})
LUA
}
expected() {
  cat <<'LUA'
hs.loadSpoon("Foo")

-- voice-vim: dictate into an ephemeral Neovim buffer, then paste back.
require("hs.ipc") -- enables the `hs` CLI for reloading and debugging
require("voice-vim").start({
  autoStartFlow = false,
})
LUA
}

# First run removes the line, keeps everything else, writes an exact .bak.
d="$tmp/first"; mkdir -p "$d"; fixture > "$d/init.lua"; cp "$d/init.lua" "$d/orig.lua"
out=$("$migrate" "$d/init.lua"); st=$?
check "first run exits 0" 0 $st
check "Option+V line gone" 0 "$(grep -c '"alt"' "$d/init.lua")"
check "other lines unchanged" "$(expected)" "$(cat "$d/init.lua")"
check ".bak equals original" same "$(cmp -s "$d/orig.lua" "$d/init.lua.bak" && echo same)"
check "output names the removed line" 1 "$(grep -c 'line 6:   hotkey = { { "alt" }, "v" },' <<<"$out")"
check "output names the backup" 1 "$(grep -c "backup: $d/init.lua.bak" <<<"$out")"

# Second run: nothing changed, .bak not overwritten, no extra backup.
cp "$d/init.lua" "$d/after-first.lua"
out=$("$migrate" "$d/init.lua"); st=$?
check "second run exits 0" 0 $st
check "second run says nothing changed" 1 "$(grep -c 'nothing changed' <<<"$out")"
check "second run leaves init.lua" same "$(cmp -s "$d/after-first.lua" "$d/init.lua" && echo same)"
check "second run leaves .bak" same "$(cmp -s "$d/orig.lua" "$d/init.lua.bak" && echo same)"
check "second run makes no new backup" 1 "$(ls "$d" | grep -c '^init\.lua\.bak')"

# A custom hotkey line is kept and no backup is written.
d="$tmp/custom"; mkdir -p "$d"
fixture | sed 's/  hotkey = { { "alt" }, "v" },/  hotkey = { {"cmd"}, "j" },/' > "$d/init.lua"
cp "$d/init.lua" "$d/orig.lua"
out=$("$migrate" "$d/init.lua"); st=$?
check "custom: exits 0" 0 $st
check "custom: hotkey line kept" 1 "$(grep -c '  hotkey = { {"cmd"}, "j" },' "$d/init.lua")"
check "custom: file unchanged" same "$(cmp -s "$d/orig.lua" "$d/init.lua" && echo same)"
check "custom: no .bak" no "$([ -e "$d/init.lua.bak" ] && echo yes || echo no)"
check "custom: says nothing changed" 1 "$(grep -c 'nothing changed' <<<"$out")"

# The same line outside the voice-vim block is left alone.
d="$tmp/outside"; mkdir -p "$d"
{ echo 'other.start({'; echo '  hotkey = { { "alt" }, "v" },'; echo '})'; fixture; } > "$d/init.lua"
"$migrate" "$d/init.lua" >/dev/null
check "outside block: other module's line kept" 2 "$(grep -n '"alt"' "$d/init.lua" | head -1 | cut -d: -f1)"
check "outside block: only one line removed" 1 "$(grep -c '"alt"' "$d/init.lua")"

# An existing init.lua.bak is not clobbered; the backup gets a timestamp.
d="$tmp/oldbak"; mkdir -p "$d"; fixture > "$d/init.lua"; echo "older backup" > "$d/init.lua.bak"
out=$("$migrate" "$d/init.lua")
check "existing .bak kept" "older backup" "$(cat "$d/init.lua.bak")"
stamped=$(ls "$d" | grep '^init\.lua\.bak\.' | head -1)
check "timestamped backup equals original" same "$(fixture | cmp -s - "$d/$stamped" && echo same)"

# Default path is ~/.hammerspoon/init.lua (HOME is a temp dir here).
h="$tmp/home"; mkdir -p "$h/.hammerspoon"; fixture > "$h/.hammerspoon/init.lua"
HOME="$h" "$migrate" >/dev/null
check "default path migrated" "$(expected)" "$(cat "$h/.hammerspoon/init.lua")"
check "default path .bak written" yes "$([ -f "$h/.hammerspoon/init.lua.bak" ] && echo yes)"

# Missing file: non-zero exit, nothing created.
"$migrate" "$tmp/nope/init.lua" >/dev/null 2>&1; st=$?
check "missing file exits non-zero" 1 $st

[ $fail -eq 0 ] && echo "all ok" || echo "FAILED"
exit $fail
