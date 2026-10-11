#!/usr/bin/env bash
# Host spike: spike/host/vv-host against headless nvim servers on temp
# sockets (--clean). Never touches Joe's servers or the history database.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
host="$root/spike/host/vv-host"
work=$(mktemp -d -t vv-spike)
export VOICE_VIM_SOCK=$work/host.sock VOICE_VIM_SPIKE_NOTES=$work/notes VV_HOST_NVIM_FLAGS=--clean
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want '$2' got '$3'"; fail=1; fi; }
ask() { nvim --server "$VOICE_VIM_SOCK" --remote-expr "$1" 2>&1; }
servers() { pgrep -f -- "--listen $VOICE_VIM_SOCK" | wc -l | tr -d ' '; }
cleanup() {
  pkill -f -- "--listen $work/" 2>/dev/null
  rm -rf "$work"
}
trap cleanup EXIT

# --- ensure starts one server, a second ensure reuses it -----------------
"$host" ensure >/dev/null
pid=$(ask 'getpid()')
"$host" ensure >/dev/null
check "ensure starts one server, second ensure does not start another" "1 $pid" "$(servers) $(ask 'getpid()')"

# --- new / draft ----------------------------------------------------------
"$host" new >/dev/null
check "after new, mode is i and filetype markdown" "i markdown" "$(ask 'mode()." ".&filetype')"
ask "nvim_buf_set_lines(0, 0, -1, v:false, ['hello', 'from the spike'])" >/dev/null
path=$("$host" draft)
check "after draft, the file holds the text" "hello
from the spike" "$(cat "$path" 2>&1)"
check "after draft, g:voicevim_draft is its path" "$path" "$(ask 'g:voicevim_draft')"
next=$("$host" new)
check "next new is an empty note" "1  i $(test "$next" != "$path" && echo fresh)" \
  "$(ask 'line("$")." ".getline(1)." ".mode()') fresh"

# --- stop -----------------------------------------------------------------
"$host" stop
check "stop removes the socket and the server" "gone 0" "$(test -e "$VOICE_VIM_SOCK" && echo present || echo gone) $(servers)"

# --- ensure reuses an existing headless server ----------------------------
nvim --headless --clean --listen "$VOICE_VIM_SOCK" </dev/null >/dev/null 2>&1 &
own=$!
for _ in $(seq 100); do [ "$(ask 1)" = 1 ] && break; sleep 0.05; done
"$host" ensure >/dev/null
"$host" new >/dev/null
check "ensure reuses an existing headless server" "1 $own i" "$(servers) $(ask 'getpid()') $(ask 'mode()')"
"$host" stop
wait "$own"
check "stop quits the reused server" "0 gone" "$(servers) $(test -e "$VOICE_VIM_SOCK" && echo present || echo gone)"

check "attach-cmd prints the remote-ui command" "yes" \
  "$(case $("$host" attach-cmd) in *"nvim --server $VOICE_VIM_SOCK --remote-ui") echo yes ;; *) echo no ;; esac)"

exit $fail
