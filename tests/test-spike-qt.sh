#!/usr/bin/env bash
# Host spike: spike/host/quick-terminal.sh. Fake osascript/open on PATH
# record every call and fail, so nothing reaches Ghostty or other apps. The
# nvim server runs on a temp socket (--clean).
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
qt="$root/spike/host/quick-terminal.sh"
work=$(mktemp -d -t vv-spike-qt)
[ -n "$work" ] && [ -d "$work" ] || { echo "mktemp failed" >&2; exit 1; }
export VOICE_VIM_SOCK=$work/host.sock VOICE_VIM_SPIKE_NOTES=$work/notes VV_HOST_NVIM_FLAGS=--clean
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want '$2' got '$3'"; fail=1; fi; }
has() { case $2 in *"$1"*) echo yes ;; *) echo "no ($1)" ;; esac; }
ask() { nvim --server "$VOICE_VIM_SOCK" --remote-expr "$1" 2>&1; }
cleanup() {
  pkill -f -- "--listen $work/" 2>/dev/null
  rm -rf "$work"
}
trap cleanup EXIT

mkdir -p "$work/fakes"
for f in osascript open; do
  printf '#!/bin/sh\n{ echo "CALL %s"; echo "$*"; } >> "%s/calls"\nexit 1\n' "$f" "$work" > "$work/fakes/$f"
  chmod +x "$work/fakes/$f"
done
export PATH="$work/fakes:$PATH"
: > "$work/calls"
calls() { grep -c '^CALL ' "$work/calls"; }

# --- dry-run launch prints both snippets with the socket, calls nothing -----
out=$(VV_SPIKE_DRY_RUN=1 "$qt" launch 2>&1)
check "dry-run launch prints the toggle snippet" yes \
  "$(has 'perform action "toggle_quick_terminal" on terminal 1' "$out")"
check "dry-run launch prints the attach snippet with the socket" yes \
  "$(has "input text \"exec $(command -v nvim) --server $VOICE_VIM_SOCK --remote-ui\" to qt" "$out")"
check "dry-run attach presses Enter separately" yes "$(has 'send key "enter" to qt' "$out")"
check "dry-run launch prints two would-run lines" 2 "$(grep -c '^would-run: osascript' <<<"$out")"
check "dry-run launch started the server" 1 "$(ask 1)"
check "dry-run launch: fakes record no calls" 0 "$(calls)"

out=$(VV_SPIKE_DRY_RUN=1 VV_QT_MODE=keystroke "$qt" toggle 2>&1)
check "keystroke mode presses Ctrl+Option+Cmd+grave" yes \
  "$(has 'key code 50 using {control down, option down, command down}' "$out")"
out=$(VV_SPIKE_DRY_RUN=1 VV_QT_TARGET=front "$qt" attach 2>&1)
check "VV_QT_TARGET=front targets the front window" yes \
  "$(has 'focused terminal of selected tab of front window' "$out")"
check "dry-run toggle/attach: fakes record no calls" 0 "$(calls)"

# --- without dry run, osascript is called and its failure is passed on -----
"$qt" toggle >/dev/null 2>&1
check "toggle runs osascript and fails with it" "1 1" "$? $(calls)"
check "toggle passes the snippet to osascript" yes "$(has toggle_quick_terminal "$(cat "$work/calls")")"

# --- note / draft (task 1 checks) ------------------------------------------
"$qt" note >/dev/null
check "after note, mode is i and filetype markdown" "i markdown" "$(ask 'mode()." ".&filetype')"
ask "nvim_buf_set_lines(0, 0, -1, v:false, ['quick', 'terminal'])" >/dev/null
path=$("$qt" draft)
check "after draft, the file holds the text" "quick
terminal" "$(cat "$path" 2>&1)"
check "after draft, g:voicevim_draft is its path" "$path" "$(ask 'g:voicevim_draft')"
"$qt" note >/dev/null
check "next note is empty, in insert mode" "1  i" "$(ask 'line("$")." ".getline(1)." ".mode()')"
check "note/draft: fakes record no more calls" 1 "$(calls)"

"$root/spike/host/vv-host" stop
exit $fail
