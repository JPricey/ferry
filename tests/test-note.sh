#!/usr/bin/env bash
# Submit, Cancel and Hide in lua/voice-vim/note.lua: tests/note_spec.lua under
# headless nvim (--clean) with a recording stub host, then :q against a real
# voice-vim-host server. A recording fake `open` is first on PATH, so nothing
# reaches Hammerspoon. Temp history database and notes folder only.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# macOS socket paths max out at 104 bytes, so keep the folder short.
work=$(mktemp -d /tmp/vvn.XXXX)
[ -n "$work" ] && [ -d "$work" ] || { echo "mktemp failed" >&2; exit 1; }
export VOICE_VIM_SOCK=$work/host.sock VOICE_VIM_NOTES_DIR=$work/notes \
  VOICE_VIM_DB=$work/history.sqlite VOICE_VIM_HOST_NVIM_FLAGS=--clean
cleanup() {
  pkill -f -- "--listen $work/" 2>/dev/null
  rm -rf "$work"
}
trap cleanup EXIT

mkdir -p "$work/bin"
cat >"$work/bin/open" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$work/open.log"
[ -e "$work/open.fail" ] && exit 1
exit 0
EOF
chmod +x "$work/bin/open"
# A failing ghostty: voice-vim-host ensure finds no GUI settings.
printf '#!/bin/sh\nexit 1\n' >"$work/bin/ghostty"; chmod +x "$work/bin/ghostty"
export PATH="$work/bin:$PATH"

fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want '$2' got '$3'"; fail=1; fi; }

# --- spec: stub host, temp DB --------------------------------------------
# nvim -l prints to stderr and leaves the last line unterminated.
perl -e 'alarm 60; exec @ARGV' nvim --headless --clean -l "$root/tests/note_spec.lua" "$root" "$work" 2>&1
[ $? -eq 0 ] || fail=1
echo

# --- keys on a real voice-vim-host server --------------------------------
# Typed input (--remote-send) goes through the main loop, as in real use.
host="$root/bin/voice-vim-host"
db="$root/bin/voice-vim-db"
ask() { nvim --server "$VOICE_VIM_SOCK" --remote-expr "$1" 2>&1; }
send() { nvim --server "$VOICE_VIM_SOCK" --remote-send "$1"; }
outcome() { "$db" get "$1" 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin)["outcome"])' 2>/dev/null || echo none; }
# Wait for the fake open to log a line, then print it and clear the log.
opened() {
  for _ in $(seq 100); do [ -s "$work/open.log" ] && break; sleep 0.05; done
  cat "$work/open.log" 2>/dev/null; rm -f "$work/open.log"
}
waitrow() { for _ in $(seq 100); do [ "$(outcome "$1")" = "$2" ] && break; sleep 0.05; done; }
url_kind() { case $1 in *voicevim-submit*target=com.example.app\&window=4242*) echo submit ;; *voicevim-hide) echo hide ;; *) echo "other: $1" ;; esac; }
rm -f "$work/open.log"
"$host" ensure >/dev/null
pid=$(ask 'getpid()')

"$host" show com.example.app 4242 >/dev/null
check "after show: line 1 is the target header, insert mode on row 2" "to: app:com.example.app#4242 i 2" \
  "$(ask 'getline(1)." ".mode()." ".line(".")')"
id=$(ask 'b:voicevim.id'); waitrow "$id" open
send 'server draft<Esc>:q<CR>'
check ":q hides via voicevim-hide" hide "$(url_kind "$(opened)")"
check ":q leaves the server running" "$pid" "$(ask 'getpid()')"
check ":q keeps the draft, row stays open" "to: app:com.example.app#4242
server draft open" "$(cat "$(ask 'g:voicevim_draft')" 2>&1) $(outcome "$id")"

"$host" show com.example.app 4242 >/dev/null
send '<Esc>:wq<CR>'
check ":wq submits the resumed draft" "submit submitted" "$(url_kind "$(opened)") $(outcome "$id")"

"$host" show com.example.app 4242 >/dev/null
id=$(ask 'b:voicevim.id'); waitrow "$id" open
send 'by keys<C-x>'
check "<C-x> in insert mode submits" "submit submitted" "$(url_kind "$(opened)") $(outcome "$id")"
check "the history row's target is the header's spec" "app:com.example.app#4242" \
  "$("$db" get "$id" | python3 -c 'import json,sys;print(json.load(sys.stdin)["target"])')"

"$host" show com.example.app 4242 >/dev/null
id=$(ask 'b:voicevim.id'); waitrow "$id" open
send 'via x<Esc>:x<CR>'
check ":x submits" "submit submitted" "$(url_kind "$(opened)") $(outcome "$id")"

"$host" show com.example.app 4242 >/dev/null
id=$(ask 'b:voicevim.id'); waitrow "$id" open
send 'via ZZ<Esc>ZZ'
check "ZZ submits" "submit submitted" "$(url_kind "$(opened)") $(outcome "$id")"

"$host" show com.example.app 4242 >/dev/null
id=$(ask 'b:voicevim.id'); waitrow "$id" open
send 'drop me<Esc>ZQ'
check "ZQ cancels" "hide cancelled" "$(url_kind "$(opened)") $(outcome "$id")"

# Voice keys: <C-q> cancels from insert mode; <C-s> toggles Flow (the fake
# `open` logs its URL) and stays in insert mode.
"$host" show com.example.app 4242 >/dev/null
id=$(ask 'b:voicevim.id'); waitrow "$id" open
send 'x<C-q>'
check "<C-q> in insert mode cancels" "hide cancelled" "$(url_kind "$(opened)") $(outcome "$id")"

"$host" show com.example.app 4242 >/dev/null
id=$(ask 'b:voicevim.id'); waitrow "$id" open
send '<C-s>'
check "<C-s> starts Flow and stays in insert mode" "-g wispr-flow://start-hands-free i" "$(opened) $(ask 'mode()')"
send '<C-s>'
check "<C-s> again stops Flow, still in insert mode" "-g wispr-flow://stop-hands-free i" "$(opened) $(ask 'mode()')"
send 'words<Esc><C-q>'
check "<C-q> in normal mode cancels" "hide cancelled" "$(url_kind "$(opened)") $(outcome "$id")"
check "server still running after all keys" "$pid" "$(ask 'getpid()')"

# Submit file in the outbox; after Submit, :q in that window still hides.
"$host" show com.example.app 4242 >/dev/null
id=$(ask 'b:voicevim.id'); waitrow "$id" open
send 'to outbox<Esc>ZZ'
url=$(opened)
file=$(python3 -c 'import sys, urllib.parse as u; print(u.parse_qs(u.urlsplit(sys.argv[1]).query)["file"][0])' "${url#-g }")
check "submit file path is under the outbox dir" "$VOICE_VIM_NOTES_DIR/outbox/$id.md" "$file"
check "after Submit the window shows a fresh note" "markdown 1 2" \
  "$(ask '&filetype." ".exists("b:voicevim")." ".exists(":Hide")')"
send ':q<CR>'
check "after Submit, :q in that window hides" hide "$(url_kind "$(opened)")"
check "after Submit, :q in that window leaves the server running" "$pid" "$(ask 'getpid()')"

# Note keys pressed in the history sidebar act on the tab's note. Joe's
# config maps normal <C-x> to :write globally; on the sidebar (a nofile
# buffer) that failed with E382 and nothing was sent. Same map here.
ask "luaeval('vim.keymap.set(\"n\", \"<C-x>\", vim.cmd.write) or 1')" >/dev/null
to_sidebar() {
  send '<Esc><Cmd>lua vim.api.nvim_set_current_win(require"voice-vim.history".state.win)<CR>'
  ask 'execute("let v:errmsg = \"\"")' >/dev/null
}
side_key() { # keys text: show a note, type text, press keys in the sidebar
  "$host" show com.example.app 4242 >/dev/null
  id=$(ask 'b:voicevim.id'); waitrow "$id" open
  send "$2"; to_sidebar
  side=$(ask 'bufname()')
  send "$1"
}
# Without the sidebar's own <C-x> (as before the fix), Joe's error.
"$host" show com.example.app 4242 >/dev/null
to_sidebar; ask "luaeval('vim.keymap.del(\"n\", \"<C-x>\", { buffer = 0 }) or bufname()')" >/dev/null
send '<C-x>'
check "sidebar without its <C-x> map: global :write fails (Joe's report)" \
  "voice-vim://history E5108: Error executing lua: Vim:E382: Cannot write, 'buftype' option is set" \
  "$(ask 'bufname()') $(ask 'v:errmsg' | head -1)"
sleep 0.3; rm -f "$work/open.log"
side_key '<C-x>' 'from sidebar'
check "<C-x> in the sidebar sends the note" "voice-vim://history submit submitted" \
  "$side $(url_kind "$(opened)") $(outcome "$id")"
check "<C-x> in the sidebar: no error, focus on the note" " 1" "$(ask 'v:errmsg') $(ask 'exists("b:voicevim")')"
side_key ZZ 'zz'
check "ZZ in the sidebar sends the note" "submit submitted" "$(url_kind "$(opened)") $(outcome "$id")"
side_key ':wq<CR>' 'wq'
check ":wq in the sidebar sends the note" "submit submitted" "$(url_kind "$(opened)") $(outcome "$id")"
side_key ':x<CR>' 'x'
check ":x in the sidebar sends the note" "submit submitted" "$(url_kind "$(opened)") $(outcome "$id")"
side_key '<C-q>' 'drop'
check "<C-q> in the sidebar cancels the note" "hide cancelled" "$(url_kind "$(opened)") $(outcome "$id")"
side_key ZQ 'drop'
check "ZQ in the sidebar cancels the note" "hide cancelled" "$(url_kind "$(opened)") $(outcome "$id")"
side_key ':q<CR>' 'kept'
check ":q in the sidebar hides and keeps the draft, to: line and all" "hide to: app:com.example.app#4242|kept open 2" \
  "$(url_kind "$(opened)") $(paste -sd'|' - <"$(ask 'g:voicevim_draft')" 2>&1) $(outcome "$id") $(ask 'winnr("$")')"
side_key '<C-s>' ' more'
# Joe stays in insert mode (GT 8), at the end of the body, off the to: line.
check "<C-s> in the sidebar starts Flow from the note, in insert mode at the end of the body" \
  "-g wispr-flow://start-hands-free 1 i 1 1 1" \
  "$(opened) $(ask 'exists("b:voicevim")') $(ask "mode().' '.(line('.') == line('\$')).' '.(col('.') == col('\$')).' '.(line('.') > 1)")"
send '<C-s>'; opened >/dev/null

# Live upgrade: a server running the note at api 4 with 4f113ac's history
# module (sidebar without note keys). show reloads the note to api 5; the
# sidebar reopened with q then :History or <leader>h has the note keys.
old=$work/old; mkdir -p "$old/lua/voice-vim"; ln -s "$root/bin" "$old/bin"
for m in note history; do
  git -C "$root" show "4f113ac:lua/voice-vim/$m.lua" >"$old/lua/voice-vim/$m.lua"
done
cat >"$work/old.lua" <<EOF
local h = require("voice-vim.history"); h.close()
local n = require("voice-vim.note")
local on = dofile("$old/lua/voice-vim/note.lua"); on.state = n.state
package.loaded["voice-vim.note"] = on
package.loaded["voice-vim.history"] = dofile("$old/lua/voice-vim/history.lua")
on.apply_options(vim.api.nvim_get_current_buf())
EOF
"$host" show com.example.app 4242 >/dev/null
send '<Esc>'; ask "execute('luafile $work/old.lua')" >/dev/null
send ':History<CR>'; to_sidebar
check "old server: note api 4, old sidebar has no <C-x>" "4 nil 0" \
  "$(ask 'luaeval("require\"voice-vim.note\".api")') $(ask 'luaeval("tostring(require\"voice-vim.history\".api)")') $(ask "get(maparg('<C-x>', 'n', 0, 1), 'buffer', 0)")"
upgrade_key() { # reopen: keys that reopen the sidebar from the note
  "$host" show com.example.app 4242 >/dev/null
  id=$(ask 'b:voicevim.id'); waitrow "$id" open
  send "upgraded"; to_sidebar; send 'q'
  send "<Esc>$1"; to_sidebar
  side="$(ask 'winnr("$")') $(ask 'bufname()')"
  send '<C-x>'
}
upgrade_key ':History<CR>'
check "after upgrade: q then :History, <C-x> in the sidebar sends the note" \
  "5 2 voice-vim://history submit submitted " \
  "$(ask 'luaeval("require\"voice-vim.note\".api")') $side $(url_kind "$(opened)") $(outcome "$id") $(ask 'v:errmsg')"
upgrade_key '\h'
check "after upgrade: q then <leader>h, <C-x> in the sidebar sends the note" \
  "2 voice-vim://history submit submitted " "$side $(url_kind "$(opened)") $(outcome "$id") $(ask 'v:errmsg')"
check "server still running after the sidebar keys" "$pid" "$(ask 'getpid()')"
"$host" stop
check "submit file survives voice-vim-host stop" "to outbox" "$(cat "$file" 2>&1)"

exit $fail
