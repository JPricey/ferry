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
# Wait (up to $1 s, default 10) for ferry-edit to exit, then print its
# exit code.
code() {
  local end=$((SECONDS + ${1:-10}))
  while [ ! -s "$work/rc" ] && [ "$SECONDS" -lt "$end" ]; do sleep 0.05; done
  cat "$work/rc" 2>/dev/null || echo running
}
# Wait for the edit to be open in the server (start answered ok).
started() { for _ in $(seq 100); do [ "$(pending)" = true ] && break; sleep 0.05; done; }
running() { kill -0 "$fpid" 2>/dev/null && echo running || echo exited; }
fallback_log() { cat "$work/fallback.log" 2>/dev/null; rm -f "$work/fallback.log"; }
# After a check: a ferry-edit still running is killed and an edit left
# pending in the server is aborted, so one failure does not cascade into
# the next checks.
settle() {
  if [ "$(running)" = running ]; then kill -KILL "$fpid" 2>/dev/null; code 2 >/dev/null; fi
  ask "luaeval('(function() local m = require\"ferry.edit\"; local e = m.state.edit; if e then m.abort({done = e.done}) end; return 1 end)()')" >/dev/null
}
# Block the server's main loop for $1 ms (a busy Lua loop: no events run).
stall() { ask "luaeval('(function() local t = vim.uv.hrtime() + $1 * 1e6; while vim.uv.hrtime() < t do end; return 1 end)()')" >/dev/null; }

# --- shown by FocusGained, then Ctrl-X ---------------------------------------
f=$work/a.txt
printf 'hello\n' >"$f"
run "$f"
# The first run starts the server (cold), so wait for open before the 1 s.
started
for _ in $(seq 100); do [ -s "$work/open.log" ] && break; sleep 0.05; done
sleep 1
check "still blocking 1 s after open; open logged -g hammerspoon://ferry-edit" \
  "running -g hammerspoon://ferry-edit" "$(running) $(cat "$work/open.log" 2>/dev/null)"
check "the server edit holds the file, in insert mode" "hello i" "$(ask 'getline(1)." ".mode()')"
focus
sleep 0.3
send 'typed <C-x>'
check "FocusGained + Ctrl-X: exit 0, file edited" "0 typed hello" "$(code) $(cat "$f")"
check "no fallback ran, no done files left" "|" "$(fallback_log)|$(ls "$FERRY_EDIT_DIR")"
records() { grep -l '^target: editor:' "${1:-$FERRY_NOTES_DIR}"/*.md 2>/dev/null; }
check "Ctrl-X: the edit is kept as a sent note (target editor:a.txt)" "state: sent|target: editor:a.txt" \
  "$(grep -h '^state:' $(records))|$(grep -h '^target:' $(records))"

# --- Ctrl-Q -------------------------------------------------------------------
f=$work/b.txt
printf 'keep\n# no newline' >"$f"; cp "$f" "$work/b.orig"
# A server holding an older edit module (api 1) reloads it.
ask "luaeval('(function() require\"ferry.edit\".api = 1; return 1 end)()')" >/dev/null
run "$f"
started
check "an older loaded edit module is reloaded (api 4), the edit in its state" "4 true" \
  "$(ask "luaeval('require\"ferry.edit\".api')") $(pending)"
focus; sleep 0.3
send 'junk<C-q>'
check "Ctrl-Q: exit 1, file unchanged" "1 same" \
  "$(code) $(cmp -s "$f" "$work/b.orig" && echo same || echo changed)"

# --- ferry already frontmost: no FocusGained needed -------------------------
f=$work/c.txt
printf 'front\n' >"$f"
echo local.ferry >"$work/front"
# The server (started with FERRY_NOTES_DIR=$work/notes, as Hammerspoon's
# notesDir does) owns the notes folder. This client has FERRY_NOTES_DIR
# unset, so its own default would be $HOME/notes/scratchpads.
mkdir -p "$work/home"
unset FERRY_NOTES_DIR
HOME=$work/home run "$f"
export FERRY_NOTES_DIR=$work/notes
started; sleep 0.5
check "ferry frontmost (lsappinfo), no FocusGained: shown, no fallback" "running shown" \
  "$(running) $(ask "luaeval('require\"ferry.edit\".state.edit.shown and \"shown\" or \"pending\"')")"
send 'x<C-x>'
check "then Ctrl-X: exit 0" "0 xfront" "$(code) $(cat "$f")"
check "client FERRY_NOTES_DIR unset: the record lands in the server's folder, none in the client's default" \
  "2 absent" "$(records | grep -c .) $([ -e "$work/home/notes" ] && echo present || echo absent)"
# A client FERRY_NOTES_DIR different from the server's is ignored too.
printf 'front2\n' >"$f"
FERRY_NOTES_DIR=$work/notes2 run "$f"
started; sleep 0.5
send 'y<C-x>'
check "client FERRY_NOTES_DIR=notes2: exit 0, the record still in the server's folder" "0 3 absent" \
  "$(code) $(records | grep -c .) $([ -e "$work/notes2" ] && echo present || echo absent)"
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
# /bin/bash is 3.2 on macOS: "${args[@]}" of an empty array fails there
# under set -u.
/bin/bash "$fe" 2>>"$work/err"; rc=$?
check "zero arguments (under /bin/bash $(/bin/bash -c 'echo $BASH_VERSION' | cut -d. -f1-2)): the fallback ran with none" \
  "7 ran ''" "$rc $([ -e "$work/fallback.log" ] && echo ran || echo not-run) '$(fallback_log)'"
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

# A socket that accepts but never answers: ensure hangs on it, so it is cut
# off (FERRY_EDIT_ENSURE_TIMEOUT) and its hung nvim client killed.
fake=$work/fake.sock
perl -MIO::Socket::UNIX -e 'my $s = IO::Socket::UNIX->new(Type => SOCK_STREAM(), Local => $ARGV[0], Listen => 5) or die; my @c; while (my $c = $s->accept) { push @c, $c }' "$fake" &
pids="$pids $!"
for _ in $(seq 100); do [ -S "$fake" ] && break; sleep 0.05; done
t0=$SECONDS
FERRY_SOCK=$fake FERRY_EDIT_ENSURE_TIMEOUT=2 run "$f"
r=$(code 8); t=$((SECONDS - t0))
check "non-answering socket: fallback within the 2 s ensure bound (+1 s)" "7 $f yes" \
  "$r $(fallback_log) $([ "$t" -le 3 ] && echo yes || echo "no: ${t} s")"
check "  and no nvim client is left hanging on it" "none" \
  "$(/usr/bin/pgrep -f -- "--server $fake" >/dev/null && echo left || echo none)"
# A signal during that ensure: the trap runs at once (armed before ensure).
FERRY_SOCK=$fake FERRY_EDIT_ENSURE_TIMEOUT=10 run "$f"
sleep 0.5
t0=$SECONDS
kill -TERM "$fpid"
r=$(code 8); t=$((SECONDS - t0))
check "kill -TERM during a hung ensure: exit 130 within 1 s, no fallback, no client left" "130 yes '' none" \
  "$r $([ "$t" -le 1 ] && echo yes || echo "no: ${t} s") '$(fallback_log)' $(/usr/bin/pgrep -f -- "--server $fake" >/dev/null && echo left || echo none)"
settle

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
  t0=$SECONDS
  kill -"$sig" "$fpid"
  r=$(code); t=$((SECONDS - t0))
  check "kill -$sig: exit 130 within 2 s, edit aborted, file unchanged" "130 yes false sig" \
    "$r $([ "$t" -le 2 ] && echo yes || echo "no: ${t} s") $(pending) $(cat "$f")"
  settle
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
settle
run "$f"
started
check "the next ferry-edit starts (not busy)" "running" "$(running)"
focus; sleep 0.3
send '<C-q>'
code >/dev/null
settle

# --- a stalled server ----------------------------------------------------------------
# One status call cut off (3 s) is not "gone": two in a row are needed.
f=$work/stall.txt
printf 'stall\n' >"$f"
run "$f"
started; focus; sleep 0.3
stall 3500
sleep 1.5
check "server stalls 3.5 s while shown: ferry-edit still waiting, edit pending" "running true" \
  "$(running) $(pending)"
send 'ok<C-x>'
check "  then Ctrl-X: exit 0, file edited" "0 okstall" "$(code) $(cat "$f")"
settle

# Two misses in a row: ferry-edit tries an abort before it exits 1, so a
# server that was only stalled does not keep the edit pending.
f=$work/stall2.txt
printf 'stall2\n' >"$f"
run "$f"
started; focus; sleep 0.3
stall 9000 &
sp=$!
r=$(code 16)
wait "$sp"
check "server stalls 9 s while shown: exit 1, then the queued abort ended the edit, file unchanged" \
  "1 false stall2" "$r $(pending) $(cat "$f")"
settle

# --- server death after shown ------------------------------------------------------
f=$work/death.txt
printf 'death\n' >"$f"
run "$f"
started; focus; sleep 0.3
pkill -f -- "--listen $FERRY_SOCK"
check "server dies while shown: exit 1, file unchanged" "1 death" "$(code) $(cat "$f")"

exit $fail
