#!/usr/bin/env bash
# bin/ferry-edit ($EDITOR mode client) against a headless ferry-host server
# on a temp socket (--clean). PATH stubs: `open` (records, never reaches
# Hammerspoon or Wispr Flow), `pgrep` (Hammerspoon running or not),
# `lsappinfo` (which app is frontmost) and a failing `ghostty`. The
# fallback editor is a recording stub. Never touches Joe's server, the real
# history database or notes folder.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fe="$root/bin/ferry-edit"
# macOS socket paths max out at 104 bytes, so keep the folder short.
work=$(mktemp -d /tmp/ferryf.XXXX)
[ -n "$work" ] && [ -d "$work" ] || { echo "mktemp failed" >&2; exit 1; }
export FERRY_SOCK=$work/host.sock FERRY_NOTES_DIR=$work/notes \
  FERRY_DB=$work/history.sqlite FERRY_HOST_NVIM_FLAGS=--clean \
  FERRY_INDEX=$work/index.sqlite FERRY_OUTBOX=$work/outbox \
  FERRY_EDIT_DIR=$work/edits FERRY_APP=$work/ferry.app \
  FERRY_EDIT_FALLBACK=$work/bin/fallback FERRY_EDIT_SHOW_TIMEOUT=3
unset FERRY_EDIT_TERMINAL SSH_CONNECTION SSH_CLIENT SSH_TTY
mkdir -p "$FERRY_APP"
pids=
cleanup() {
  for p in $pids; do kill "$p" 2>/dev/null; done
  pkill -f -- "--listen $work/" 2>/dev/null
  rm -rf "$work"
}
trap cleanup EXIT

mkdir -p "$work/bin"
cat >"$work/bin/open" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$work/open.log"
exit 0
EOF
cat >"$work/bin/pgrep" <<EOF
#!/bin/sh
[ "\$(cat "$work/pgrep.mode" 2>/dev/null)" = fail ] && exit 1
echo 4242
EOF
cat >"$work/bin/lsappinfo" <<EOF
#!/bin/sh
case \$1 in
  front) echo 'ASN:0x0-0x1234:' ;;
  info) printf '"CFBundleIdentifier"="%s"\n' "\$(cat "$work/front" 2>/dev/null || echo com.mitchellh.ghostty)" ;;
esac
EOF
cat >"$work/bin/fallback" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$work/fallback.log"
exit 7
EOF
printf '#!/bin/sh\nexit 1\n' >"$work/bin/ghostty"
chmod +x "$work/bin/"*
export PATH="$work/bin:$PATH"

fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want '$2' got '$3'"; fail=1; fi; }
ask() { nvim --server "$FERRY_SOCK" --remote-expr "$1" 2>&1; }
send() { nvim --server "$FERRY_SOCK" --remote-send "$1"; }
focus() { ask "execute('doautocmd FocusGained')" >/dev/null; }
pending() { ask "luaeval('require\"ferry.edit\".pending()')"; }
# Run ferry-edit in the background; $fpid is its pid, and a watcher writes
# its exit code to rc (so code() works inside $(...)).
run() {
  rm -f "$work/rc" "$work/pid"
  ( "$fe" "$@" 2>>"$work/err" & echo $! >"$work/pid"; wait $!; echo $? >"$work/rc" ) &
  for _ in $(seq 200); do [ -s "$work/pid" ] && break; sleep 0.01; done
  fpid=$(cat "$work/pid"); pids="$pids $fpid"
}
# Wait (up to 10 s) for ferry-edit to exit, then print its exit code.
code() {
  for _ in $(seq 200); do [ -s "$work/rc" ] && break; sleep 0.05; done
  cat "$work/rc" 2>/dev/null || echo running
}
# Wait for the edit to be open in the server (start answered ok).
started() { for _ in $(seq 100); do [ "$(pending)" = true ] && break; sleep 0.05; done; }
running() { kill -0 "$fpid" 2>/dev/null && echo running || echo exited; }
fallback_log() { cat "$work/fallback.log" 2>/dev/null; rm -f "$work/fallback.log"; }

# --- shown by FocusGained, then Ctrl-X ---------------------------------------
f=$work/a.txt
printf 'hello\n' >"$f"
run "$f"
sleep 1
check "still blocking after 1 s; open logged -g hammerspoon://ferry-edit" \
  "running -g hammerspoon://ferry-edit" "$(running) $(cat "$work/open.log" 2>/dev/null)"
check "the server edit holds the file, in insert mode" "hello i" "$(ask 'getline(1)." ".mode()')"
focus
sleep 0.3
send 'typed <C-x>'
check "FocusGained + Ctrl-X: exit 0, file edited" "0 typed hello" "$(code) $(cat "$f")"
check "no fallback ran, no done files left" "|" "$(fallback_log)|$(ls "$FERRY_EDIT_DIR")"

# --- Ctrl-Q -------------------------------------------------------------------
f=$work/b.txt
printf 'keep\n# no newline' >"$f"; cp "$f" "$work/b.orig"
# A server holding an older edit module (api 1) reloads it.
ask "luaeval('(function() require\"ferry.edit\".api = 1; return 1 end)()')" >/dev/null
run "$f"
started
check "an older loaded edit module is reloaded (api 2), the edit in its state" "2 true" \
  "$(ask "luaeval('require\"ferry.edit\".api')") $(pending)"
focus; sleep 0.3
send 'junk<C-q>'
check "Ctrl-Q: exit 1, file unchanged" "1 same" \
  "$(code) $(cmp -s "$f" "$work/b.orig" && echo same || echo changed)"

# --- ferry already frontmost: no FocusGained needed -------------------------
f=$work/c.txt
printf 'front\n' >"$f"
echo local.ferry >"$work/front"
run "$f"
started; sleep 0.5
check "ferry frontmost (lsappinfo), no FocusGained: shown, no fallback" "running shown" \
  "$(running) $(ask "luaeval('require\"ferry.edit\".state.edit.shown and \"shown\" or \"pending\"')")"
send 'x<C-x>'
check "then Ctrl-X: exit 0" "0 xfront" "$(code) $(cat "$f")"
rm -f "$work/front"

# --- fallbacks ------------------------------------------------------------------
f=$work/d.txt
printf 'd\n' >"$f"
rm -f "$work/open.log"
echo fail >"$work/pgrep.mode"
run "$f"
check "failing pgrep (no Hammerspoon): fallback ran with the file, its exit code" \
  "7 $f" "$(code) $(fallback_log)"
rm -f "$work/pgrep.mode"
check "no Hammerspoon: no open, no edit pending" "none false" \
  "$(cat "$work/open.log" 2>/dev/null || echo none) $(pending)"

run "$f" "$work/other.txt"
check "two file arguments: fallback with both" "7 $f $work/other.txt" "$(code) $(fallback_log)"
FERRY_EDIT_TERMINAL=1 run "$f"
check "FERRY_EDIT_TERMINAL=1: fallback" "7 $f" "$(code) $(fallback_log)"
SSH_CONNECTION="1.2.3.4 5 6.7.8.9 22" run "$f"
check "SSH session: fallback" "7 $f" "$(code) $(fallback_log)"
if [ -d /Applications/Neovide.app ]; then
  echo "skip no ferry.app or Neovide.app (/Applications/Neovide.app exists)"
else
  FERRY_APP=$work/missing.app HOME=$work/nohome run "$f"
  check "no ferry.app or Neovide.app: fallback" "7 $f" "$(code) $(fallback_log)"
fi
FERRY_SOCK=$work/nodir/x.sock run "$f"
check "ensure fails: fallback" "7 $f" "$(code) $(fallback_log)"

# busy: an edit already pending in the server.
ask "luaeval('require\"ferry.edit\".start(_A)', {'file': '$work/e1.txt', 'done': '$work/e1.done'})" >/dev/null
run "$f"
check "ferry busy (an edit pending): fallback, the other edit kept" "7 $f true" \
  "$(code) $(fallback_log) $(pending)"
ask "luaeval('require\"ferry.edit\".abort(_A)', {'done': '$work/e1.done'})" >/dev/null

# Not shown in time.
FERRY_EDIT_SHOW_TIMEOUT=1 run "$f"
started
check "no FocusGained in the (1 s) timeout: fallback ran, no edit pending, file unchanged" \
  "7 $f false d" "$(code) $(fallback_log) $(pending) $(cat "$f")"

# --- signals ---------------------------------------------------------------------
for sig in TERM HUP; do
  f=$work/s$sig.txt
  printf 'sig\n' >"$f"
  run "$f"
  started; focus; sleep 0.3
  send 'dropped '
  sleep 0.2
  kill -"$sig" "$fpid"
  check "kill -$sig: exit 130, edit aborted, file unchanged" "130 false sig" \
    "$(code) $(pending) $(cat "$f")"
done

# Flow recording in the edit at TERM: Flow is stopped, the edit ends after
# its paste, and the next ferry-edit is not busy.
f=$work/flow.txt
printf 'flow\n' >"$f"
rm -f "$work/open.log"
run "$f"
started; focus; sleep 0.3
send '<C-s>'
sleep 0.3
kill -TERM "$fpid"
sleep 0.3
ask "luaeval('vim.paste({\" late\"}, -1)')" >/dev/null
check "kill -TERM while Flow records: exit 130, Flow stopped, file unchanged" \
  "130 stop-hands-free flow" \
  "$(code) $(grep -o 'stop-hands-free' "$work/open.log" | head -1) $(cat "$f")"
check "after that, Flow idle and no edit pending" "false false" \
  "$(ask "luaeval('require\"ferry.flow\".recording()')") $(pending)"
run "$f"
started
check "the next ferry-edit starts (not busy)" "running" "$(running)"
focus; sleep 0.3
send '<C-q>'
code >/dev/null

# --- server death after shown ------------------------------------------------------
f=$work/death.txt
printf 'death\n' >"$f"
run "$f"
started; focus; sleep 0.3
pkill -f -- "--listen $FERRY_SOCK"
check "server dies while shown: exit 1, file unchanged" "1 death" "$(code) $(cat "$f")"

exit $fail
