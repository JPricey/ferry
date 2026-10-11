#!/usr/bin/env bash
# Host spike: spike/host/vv-host and the launch scripts against headless
# nvim servers on temp sockets (--clean). Never touches Joe's servers or the
# history database, and never runs the real osascript/open/neovide.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
host="$root/spike/host/vv-host"
work=$(mktemp -d -t vv-spike)
[ -n "$work" ] && [ -d "$work" ] || { echo "mktemp failed" >&2; exit 1; }
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
# Fail (not hang) if stop leaves the reused server running.
for _ in $(seq 100); do kill -0 "$own" 2>/dev/null || break; sleep 0.05; done
kill -0 "$own" 2>/dev/null && { echo "FAIL stop did not quit the reused server"; fail=1; kill "$own"; }
wait "$own" 2>/dev/null
check "stop quits the reused server" "0 gone" "$(servers) $(test -e "$VOICE_VIM_SOCK" && echo present || echo gone)"

check "attach-cmd prints the remote-ui command" "yes" \
  "$(case $("$host" attach-cmd) in *"nvim --server $VOICE_VIM_SOCK --remote-ui") echo yes ;; *) echo no ;; esac)"

# --- launch scripts: ghostty-window.sh and neovide.sh ---------------------
# Recording, failing fakes so nothing real is launched even on a bug.
mkdir -p "$work/fakes"
for f in osascript open neovide; do
  printf '#!/bin/sh\necho "%s $*" >>"%s"\nexit 1\n' "$f" "$work/fake-calls" >"$work/fakes/$f"
  chmod +x "$work/fakes/$f"
done
export PATH="$work/fakes:$PATH"
calls() { cat "$work/fake-calls" 2>/dev/null; }

has() { case $2 in *"$1"*) echo yes ;; *) echo "no ($2)" ;; esac; }

for name in ghostty-window neovide; do
  script="$root/spike/host/$name.sh"
  export VOICE_VIM_SOCK=$work/$name.sock
  out=$(VV_SPIKE_DRY_RUN=1 "$script" launch 2>&1)
  check "$name: dry-run launch exits 0" 0 $?
  check "$name: dry-run launch prints the socket" yes "$(has "$VOICE_VIM_SOCK" "$out")"
  case $name in
    ghostty-window)
      check "$name: dry-run launch would run osascript with --remote-ui" "yes yes" \
        "$(has "would-run: osascript" "$out") $(has "--server $VOICE_VIM_SOCK --remote-ui" "$out")"
      check "$name: launch sets the host title" "1 voice-vim-host" "$(ask '&title') $(ask '&titlestring')" ;;
    neovide)
      check "$name: dry-run launch would run neovide --server" yes "$(has "would-run: neovide --server $VOICE_VIM_SOCK" "$out")" ;;
  esac
  check "$name: dry-run launch makes no fake calls" "" "$(calls)"

  "$script" note >/dev/null
  check "$name: after note, mode is i and filetype markdown" "i markdown" "$(ask 'mode()." ".&filetype')"
  ask "nvim_buf_set_lines(0, 0, -1, v:false, ['via $name'])" >/dev/null
  path=$("$script" draft)
  check "$name: after draft, the file holds the text" "via $name" "$(cat "$path" 2>&1)"
  check "$name: after draft, g:voicevim_draft is its path" "$path" "$(ask 'g:voicevim_draft')"
  next=$("$script" note)
  check "$name: next note is empty" "1  i $(test "$next" != "$path" && echo fresh)" \
    "$(ask 'line("$")." ".getline(1)." ".mode()') fresh"
  "$host" stop
done

# Without dry-run, launch really calls osascript (the failing fake) and fails.
export VOICE_VIM_SOCK=$work/real.sock
"$root/spike/host/ghostty-window.sh" launch >/dev/null 2>&1
check "ghostty-window: real launch calls osascript and reports its failure" "1 osascript" \
  "$? $(calls | head -1 | cut -d' ' -f1)"
"$host" stop

exit $fail
