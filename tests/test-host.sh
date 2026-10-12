#!/usr/bin/env bash
# bin/voice-vim-host and lua/voice-vim/note.lua against headless nvim
# servers on a temp socket (--clean). Never touches Joe's server, the real
# history database or the real notes folder.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
host="$root/bin/voice-vim-host"
# macOS socket paths max out at 104 bytes, so keep the folder short.
work=$(mktemp -d /tmp/vvh.XXXX)
[ -n "$work" ] && [ -d "$work" ] || { echo "mktemp failed" >&2; exit 1; }
export VOICE_VIM_SOCK=$work/host.sock VOICE_VIM_NOTES_DIR=$work/notes \
  VOICE_VIM_DB=$work/history.sqlite VOICE_VIM_HOST_NVIM_FLAGS=--clean
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want '$2' got '$3'"; fail=1; fi; }
ask() { nvim --server "$VOICE_VIM_SOCK" --remote-expr "$1" 2>&1; }
servers() { pgrep -f -- "--listen $VOICE_VIM_SOCK" | wc -l | tr -d ' '; }
gone() { test -e "$VOICE_VIM_SOCK" && echo present || echo gone; }
cleanup() {
  pkill -f -- "--listen $work/" 2>/dev/null
  rm -rf "$work"
}
trap cleanup EXIT

# --- status / show while down --------------------------------------------
check "status prints down with no server" down "$("$host" status)"
"$host" show com.example.app 4242 >/dev/null 2>&1
check "show fails while the server is down" 1 $?

# --- ensure starts one server, a second ensure reuses it -----------------
"$host" ensure >/dev/null
pid=$(ask 'getpid()')
"$host" ensure >/dev/null
check "two ensures start one server" "1 $pid" "$(servers) $(ask 'getpid()')"
check "server has the repo on its runtimepath" 1 "$(ask "index(nvim_list_runtime_paths(), '$root') >= 0")"
check "status prints up uis=0" "up uis=0" "$("$host" status)"

# --- show: fresh note -----------------------------------------------------
a=$("$host" show com.example.app 4242)
check "show prints a note path in the notes dir" yes \
  "$(case $a in "$VOICE_VIM_NOTES_DIR"/*.md) echo yes ;; *) echo "no ($a)" ;; esac)"
check "after show com.example.app 4242: mode i, filetype markdown" "i markdown" "$(ask 'mode()." ".&filetype')"
check "b:voicevim.target and .window are set" "com.example.app 4242" "$(ask 'b:voicevim.target." ".b:voicevim.window')"
check "b:voicevim.id is a uuid and names the file" "yes yes" \
  "$(ask 'b:voicevim.id' | grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' && echo yes) $(test "$(basename "$a" .md)" = "$(ask 'b:voicevim.id')" && echo yes)"
check "note has the voice-vim buffer options" "1 1 0 0 en_us" \
  "$(ask '&l:spell." ".&l:wrap." ".&l:number." ".&l:swapfile." ".&l:spelllang')"
check "<D-v> pastes the + register in insert mode" "<C-R><C-O>+" "$(ask "maparg('<D-v>', 'i')" | cut -c1-11)"

# --- draft ------------------------------------------------------------------
ask "nvim_buf_set_lines(0, 0, -1, v:false, ['hello', 'from the host'])" >/dev/null
d=$("$host" draft)
check "draft prints the note path" "$a" "$d"
check "draft writes the file" "hello
from the host" "$(cat "$a" 2>&1)"
check "draft sets g:voicevim_draft" "$a" "$(ask 'g:voicevim_draft')"
check "draft leaves insert mode" n "$(ask 'mode()')"

# --- resume ---------------------------------------------------------------
b=$("$host" show com.other.app 99)
check "next unseeded show returns the same path" "$a" "$b"
check "resumed note keeps its text, is in insert mode" "hello|from the host i" \
  "$(ask 'join(getline(1, "$"), "|")." ".mode()')"
check "resumed note takes the new target" "com.other.app 99" "$(ask 'b:voicevim.target." ".b:voicevim.window')"
ask "nvim_input('<Esc>Gotyped')" >/dev/null
"$host" draft >/dev/null
"$host" show com.other.app 99 >/dev/null
ask "nvim_input(' more')" >/dev/null
check "typing after resume continues where the draft left off" "typed more" "$(ask 'getline("$")')"

# --- seeded show ------------------------------------------------------------
printf 'selected text\nsecond line\n' >"$work/seed.txt"
ask "nvim_buf_set_lines(0, 0, -1, v:false, ['edited after draft'])" >/dev/null
c=$("$host" show com.example.app 4242 "$work/seed.txt")
check "seeded show returns a new path" yes "$(test -n "$c" && test "$c" != "$a" && echo yes)"
check "seed text is in the buffer, mode i" "selected text|second line i" \
  "$(ask 'join(getline(1, "$"), "|")." ".mode()')"
check "b:voicevim.seed holds the seed text" "selected text|second line" "$(ask 'substitute(b:voicevim.seed, "\n", "|", "g")')"
check "switching to a seeded note saves the previous one" "edited after draft" "$(cat "$a" 2>&1)"
check "next unseeded show resumes the seeded note" "$c" "$("$host" show com.example.app 4242)"

# --- reuse of an existing server -------------------------------------------
"$host" stop
check "stop removes the socket and the server" "gone 0" "$(gone) $(servers)"
check "status prints down after stop" down "$("$host" status)"

nvim --headless --clean --listen "$VOICE_VIM_SOCK" </dev/null >/dev/null 2>&1 &
own=$!
for _ in $(seq 100); do [ "$(ask 1)" = 1 ] && break; sleep 0.05; done
"$host" ensure >/dev/null
e=$("$host" show com.example.app 4242)
check "ensure reuses an existing server and show works in it" "1 $own i com.example.app" \
  "$(servers) $(ask 'getpid()') $(ask 'mode()') $(ask 'b:voicevim.target')"
check "show on the reused server opens a fresh note" yes "$(test -n "$e" && echo yes)"
"$host" stop
for _ in $(seq 100); do kill -0 "$own" 2>/dev/null || break; sleep 0.05; done
kill -0 "$own" 2>/dev/null && { echo "FAIL stop did not quit the reused server"; fail=1; kill "$own"; }
wait "$own" 2>/dev/null
check "stop quits the reused server and removes the socket" "0 gone" "$(servers) $(gone)"

check "attach-cmd prints the remote-ui command" yes \
  "$(case $("$host" attach-cmd) in *"nvim --server $VOICE_VIM_SOCK --remote-ui") echo yes ;; *) echo no ;; esac)"

exit $fail
