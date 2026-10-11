#!/usr/bin/env bash
# ghostty-window.sh: host spike option "dedicated Ghostty window". The
# long-lived nvim server (vv-host) is shown in its own Ghostty window, which
# runs `nvim --server <sock> --remote-ui`. nvim sets the window title to
# voice-vim-host so Hammerspoon can find the window again.
#
# Usage: ghostty-window.sh launch|note|draft
#   launch  ensure the server, then open the Ghostty window attached to it
#   note    ensure the server and open a fresh note in insert mode
#   draft   write the note and set g:voicevim_draft
#
# Environment: as vv-host (VOICE_VIM_SOCK, VOICE_VIM_SPIKE_NOTES,
# VV_HOST_NVIM_FLAGS), plus VV_SPIKE_DRY_RUN=1 to print `would-run: …`
# instead of running osascript.
set -u

# Called from Hammerspoon we inherit a bare launchd PATH. Append (not
# prepend) Homebrew, so a caller's PATH (e.g. test fakes) still wins.
export PATH="$PATH:/opt/homebrew/bin:/opt/homebrew/sbin:$HOME/.local/bin:/usr/local/bin"

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
host="$here/vv-host"
tmp=${TMPDIR:-/tmp}; tmp=${tmp%/}
sock=${VOICE_VIM_SOCK:-$tmp/voice-vim-spike.sock}
title=voice-vim-host

run() {
  if [ "${VV_SPIKE_DRY_RUN:-}" = 1 ]; then printf 'would-run:'; printf ' %q' "$@"; echo; else "$@"; fi
}

# Quote a string as an AppleScript string literal.
asstr() { local s=${1//\\/\\\\}; s=${s//\"/\\\"}; printf '"%s"' "$s"; }

launch() {
  "$host" ensure >/dev/null || return 1
  echo "ghostty-window: server on $sock"
  nvim --server "$sock" --remote-expr "execute('set title titlestring=$title')" >/dev/null || return 1
  local cmd; cmd=$("$host" attach-cmd) || return 1
  run osascript -e "tell application \"Ghostty\"
  set cfg to {command:$(asstr "$cmd"), wait after command:false}
  set w to new window with configuration cfg
  activate window w
end tell"
}

case ${1:-} in
  launch) launch ;;
  note)   "$host" ensure >/dev/null && "$host" new ;;
  draft)  "$host" draft ;;
  *) sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//' >&2; exit 2 ;;
esac
