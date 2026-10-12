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
id=$(ask 'b:voicevim.id'); waitrow "$id" open
send 'server draft<Esc>:q<CR>'
check ":q hides via voicevim-hide" hide "$(url_kind "$(opened)")"
check ":q leaves the server running" "$pid" "$(ask 'getpid()')"
check ":q keeps the draft, row stays open" "server draft open" "$(cat "$(ask 'g:voicevim_draft')" 2>&1) $(outcome "$id")"

"$host" show com.example.app 4242 >/dev/null
send '<Esc>:wq<CR>'
check ":wq submits the resumed draft" "submit submitted" "$(url_kind "$(opened)") $(outcome "$id")"

"$host" show com.example.app 4242 >/dev/null
id=$(ask 'b:voicevim.id'); waitrow "$id" open
send 'by keys<C-x>'
check "<C-x> in insert mode submits" "submit submitted" "$(url_kind "$(opened)") $(outcome "$id")"

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
"$host" stop
check "submit file survives voice-vim-host stop" "to outbox" "$(cat "$file" 2>&1)"

exit $fail
