#!/usr/bin/env bash
# tmux delivery and pane listing in lua/voice-vim/tmux.lua:
# tests/tmux_spec.lua under headless nvim (--clean), against a throwaway
# server `tmux -L voicevim-test -f /dev/null` that is killed on exit.
#   pane A: enables bracketed paste, then `cat -uv` into $work/a.out
#   pane B: a copy of cat named `claude`, into $work/b.out
# A spy `tmux` first on PATH logs every argv the module runs. It forwards
# only calls that start with `-L voicevim-test` to the real tmux; anything
# else (the default server) is recorded and fails, so Joe's tmux server is
# never touched.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
real=$(command -v tmux || true)
[ -x "$real" ] || real=/opt/homebrew/bin/tmux
[ -x "$real" ] || { echo "FAIL tmux not installed"; exit 1; }
work=$(mktemp -d /tmp/vvt.XXXX)
[ -n "$work" ] && [ -d "$work" ] || { echo "mktemp failed" >&2; exit 1; }
unset TMUX TMUX_PANE
T() { "$real" -L voicevim-test -f /dev/null "$@"; }
cleanup() { T kill-server 2>/dev/null; rm -rf "$work"; }
trap cleanup EXIT
T kill-server 2>/dev/null # a leftover from an aborted run

mkdir -p "$work/bin"
cat >"$work/bin/tmux" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$work/spy.log"
if [ "\$1" = "-L" ] && [ "\$2" = "voicevim-test" ]; then exec "$real" "\$@"; fi
echo "spy: record only" >&2
exit 1
EOF
chmod +x "$work/bin/tmux"
# A plain copy of a platform binary is killed on launch; re-sign it ad hoc.
cp /bin/cat "$work/claude"
codesign --force -s - "$work/claude" 2>/dev/null

: >"$work/a.out"
: >"$work/b.out"
paneA=$(T new-session -d -P -F '#{pane_id}' -s vvt -x 120 -y 30 -c "$work" \
  "stty -icanon -echo; printf '\033[?2004h'; exec cat -uv >'$work/a.out'")
paneB=$(T split-window -d -P -F '#{pane_id}' -t vvt -c "$work" \
  "stty -icanon -echo; exec '$work/claude' -u >'$work/b.out'")
T select-pane -t "$paneB" -T "B title"
# Wait until both panes run their final command (bracketed paste is on).
for _ in $(seq 100); do
  a=$(T display-message -p -t "$paneA" '#{pane_current_command}')
  b=$(T display-message -p -t "$paneB" '#{pane_current_command}')
  [ "$a" = cat ] && [ "$b" = claude ] && break
  sleep 0.05
done

export PATH="$work/bin:$PATH"
# nvim -l prints to stderr and leaves the last line unterminated.
perl -e 'alarm 60; exec @ARGV' nvim --headless --clean -l "$root/tests/tmux_spec.lua" \
  "$root" "$work" "$real" "$paneA" "$paneB" 2>&1
status=$?
echo
exit $status
