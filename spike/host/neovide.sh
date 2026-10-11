#!/usr/bin/env bash
# neovide.sh: host spike option "Neovide attached to nvim --listen". The
# long-lived nvim server (vv-host) is shown by Neovide, started with
# `neovide --server <sock>`. Hammerspoon shows and hides the Neovide app.
# Neovide sends Cmd+V as <D-v>; note.lua maps it to paste the + register.
#
# Usage: neovide.sh launch|note|draft
#   launch  ensure the server, then start Neovide attached to it
#   note    ensure the server and open a fresh note in insert mode
#   draft   write the note and set g:voicevim_draft
#
# Environment: as vv-host (VOICE_VIM_SOCK, VOICE_VIM_SPIKE_NOTES,
# VV_HOST_NVIM_FLAGS), plus VV_SPIKE_DRY_RUN=1 to print `would-run: …`
# instead of running neovide or open.
set -u

# Called from Hammerspoon we inherit a bare launchd PATH. Append (not
# prepend) Homebrew, so a caller's PATH (e.g. test fakes) still wins.
export PATH="$PATH:/opt/homebrew/bin:/opt/homebrew/sbin:$HOME/.local/bin:/usr/local/bin"

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
host="$here/vv-host"
tmp=${TMPDIR:-/tmp}; tmp=${tmp%/}
sock=${VOICE_VIM_SOCK:-$tmp/voice-vim-spike.sock}

run() {
  if [ "${VV_SPIKE_DRY_RUN:-}" = 1 ]; then printf 'would-run:'; printf ' %q' "$@"; echo; else "$@"; fi
}

launch() {
  "$host" ensure >/dev/null || return 1
  echo "neovide: server on $sock"
  if command -v neovide >/dev/null; then
    # Neovide forks by default; background it anyway so we never block.
    if [ "${VV_SPIKE_DRY_RUN:-}" = 1 ]; then
      run neovide --server "$sock"
    else
      nohup neovide --server "$sock" </dev/null >/dev/null 2>&1 &
    fi
  else
    # The cask may not have linked the CLI; go through the app bundle.
    run open -a Neovide --args --server "$sock"
  fi
}

case ${1:-} in
  launch) launch ;;
  note)   "$host" ensure >/dev/null && "$host" new ;;
  draft)  "$host" draft ;;
  *) sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//' >&2; exit 2 ;;
esac
