#!/usr/bin/env bash
# quick-terminal.sh: host-spike prototype that shows the long-lived nvim
# (spike/host/vv-host) in Ghostty's quick terminal.
#
# Usage: quick-terminal.sh launch|toggle|attach|note|draft
#   launch  ensure the server, toggle the quick terminal, attach if no UI is
#           attached to the server yet
#   toggle  show or hide the quick terminal
#   attach  type `exec <vv-host attach-cmd>` + Enter into the quick terminal
#   note    ensure the server, open a fresh note in insert mode (prints path)
#   draft   write the note, set g:voicevim_draft (prints path)
#
# Environment:
#   VOICE_VIM_SOCK, VOICE_VIM_SPIKE_NOTES, VV_HOST_NVIM_FLAGS  see vv-host
#   VV_SPIKE_DRY_RUN=1  print `would-run: …` instead of running osascript
#   VV_QT_MODE          applescript (default): `perform action`;
#                       keystroke: press Ctrl+Option+Cmd+` through System
#                       Events, for a Joe-added
#                       `keybind = global:ctrl+alt+cmd+grave=toggle_quick_terminal`
#   VV_QT_TARGET        unseen (default): attach types into the one terminal
#                       that is in no Ghostty window; front: into the focused
#                       terminal of the front window (only if the quick
#                       terminal turns out to be listed as a window)
#
# AppleScript used, all from Ghostty 1.3.1's Ghostty.sdef:
#   perform action <text> on <terminal>   ("on" is required, so the app-level
#                                         toggle is performed on any terminal)
#   input text <text> to <terminal>       (sent "as if pasted": with bracketed
#                                         paste a "\n" would not run the line,
#                                         so Enter is a separate key)
#   send key "enter" to <terminal>
#   application elements `windows`, `terminals`; window element `terminals`;
#   window `selected tab`, tab `focused terminal`; `id` on terminals
#
# Unknowns for Joe to answer (Joe check 5):
#   - Does `perform action "toggle_quick_terminal"` toggle it at all when run
#     through AppleScript on an ordinary terminal? It needs at least one
#     Ghostty terminal to target; with every window closed it errors.
#   - Is the quick terminal in the AppleScript `terminals` list? Is it also
#     in `windows`? (attach errors if it cannot find it; try VV_QT_TARGET=front)
#   - Is the quick terminal an `hs.window` Hammerspoon can focus and see?
#   - Does quick-terminal-autohide (default true) hide it when Wispr Flow's
#     overlay takes focus during dictation?
#   - Does showing it activate Ghostty, so keys go to nvim straight away?
#   - Ghostty has no quick-terminal-command, so attach types into Joe's
#     shell; does `exec` land before his prompt/plugins eat the input?
set -u

export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:$HOME/.local/bin:/usr/local/bin:$PATH"

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
host="$here/vv-host"
tmp=${TMPDIR:-/tmp}; tmp=${tmp%/}
sock=${VOICE_VIM_SOCK:-$tmp/voice-vim-spike.sock}

# Quote a string as an AppleScript string literal.
asstr() { local s=${1//\\/\\\\}; s=${s//\"/\\\"}; printf '"%s"' "$s"; }

run_osascript() { # script
  if [ "${VV_SPIKE_DRY_RUN:-}" = 1 ]; then
    printf 'would-run: osascript -e %s\n' "$1"
  else
    osascript -e "$1"
  fi
}

toggle_script() {
  if [ "${VV_QT_MODE:-applescript}" = keystroke ]; then
    # Key code 50 is the grave/backquote key on ANSI and ISO layouts.
    cat <<'EOF'
tell application "System Events" to key code 50 using {control down, option down, command down}
EOF
    return
  fi
  cat <<'EOF'
tell application "Ghostty"
	repeat 40 times
		if (count of terminals) > 0 then exit repeat
		delay 0.05
	end repeat
	if (count of terminals) is 0 then error "voice-vim spike: no Ghostty terminal to perform toggle_quick_terminal on (open a Ghostty window, or use VV_QT_MODE=keystroke)"
	if not (perform action "toggle_quick_terminal" on terminal 1) then error "voice-vim spike: perform action toggle_quick_terminal returned false"
end tell
EOF
}

attach_script() { # cmd
  local find
  if [ "${VV_QT_TARGET:-unseen}" = front ]; then
    find='		set qt to focused terminal of selected tab of front window'
  else
    # The quick terminal is not a tab in a window, so look for the terminal
    # that no window lists.
    find='		set seen to {}
		repeat with w in windows
			repeat with t in terminals of w
				set end of seen to (id of t)
			end repeat
		end repeat
		repeat with t in terminals
			if seen does not contain (id of t) then set qt to (contents of t)
		end repeat'
  fi
  cat <<EOF
tell application "Ghostty"
	set qt to missing value
	repeat 40 times
$find
		if qt is not missing value then exit repeat
		delay 0.05
	end repeat
	if qt is missing value then error "voice-vim spike: quick terminal not found in AppleScript terminals (try VV_QT_TARGET=front)"
	input text $(asstr "exec $1") to qt
	send key "enter" to qt
end tell
EOF
}

attach() { run_osascript "$(attach_script "$("$host" attach-cmd)")"; }

# Number of UIs attached to the server, or "" if it does not answer.
uis() {
  nvim --server "$sock" --remote-expr 'len(nvim_list_uis())' 2>/dev/null
}

case ${1:-} in
  launch)
    "$host" ensure >/dev/null || exit 1
    run_osascript "$(toggle_script)" || exit 1
    if [ "$(uis)" = 0 ]; then attach; else echo "quick-terminal: a UI is already attached"; fi
    ;;
  toggle) run_osascript "$(toggle_script)" ;;
  attach) attach ;;
  note)   "$host" ensure >/dev/null && "$host" new ;;
  draft)  "$host" draft ;;
  *) sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//' >&2; exit 2 ;;
esac
