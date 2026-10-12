#!/usr/bin/env bash
# $EDITOR mode in lua/ferry/edit.lua: tests/edit_spec.lua under headless
# nvim (--clean) with a recording stub host, then typed keys against a real
# ferry-host server. A recording fake `open` is first on PATH, so nothing
# reaches Hammerspoon or Wispr Flow. Temp history database, notes folder,
# index and outbox only.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# macOS socket paths max out at 104 bytes, so keep the folder short.
work=$(mktemp -d /tmp/ferrye.XXXX)
[ -n "$work" ] && [ -d "$work" ] || { echo "mktemp failed" >&2; exit 1; }
export FERRY_SOCK=$work/host.sock FERRY_NOTES_DIR=$work/notes \
  FERRY_DB=$work/history.sqlite FERRY_HOST_NVIM_FLAGS=--clean \
  FERRY_INDEX=$work/index.sqlite FERRY_OUTBOX=$work/outbox
cleanup() {
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
chmod +x "$work/bin/open"
# A failing ghostty: ferry-host ensure finds no GUI settings.
printf '#!/bin/sh\nexit 1\n' >"$work/bin/ghostty"; chmod +x "$work/bin/ghostty"
export PATH="$work/bin:$PATH"

fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want '$2' got '$3'"; fail=1; fi; }

# --- spec: stub host -------------------------------------------------------
# nvim -l prints to stderr and leaves the last line unterminated.
perl -e 'alarm 60; exec @ARGV' nvim --headless --clean -l "$root/tests/edit_spec.lua" "$root" "$work" 2>&1
[ $? -eq 0 ] || fail=1
echo

# --- keys on a real ferry-host server --------------------------------------
host="$root/bin/ferry-host"
ask() { nvim --server "$FERRY_SOCK" --remote-expr "$1" 2>&1; }
send() { nvim --server "$FERRY_SOCK" --remote-send "$1"; }
edit() { ask "luaeval('require\"ferry.edit\".$1(_A)', {'file': '$2', 'done': '$3'})"; }
# Wait for the done file, then print it.
done_code() { for _ in $(seq 100); do [ -s "$1" ] && break; sleep 0.05; done; cat "$1" 2>/dev/null || echo none; }
# Hide URLs the fake open logged. open runs in the background: wait for
# the count to reach one, then a little more for any extra.
hides() {
  local c
  for _ in $(seq 40); do
    c=$(grep -c 'hammerspoon://ferry-hide' "$work/open.log" 2>/dev/null)
    [ "${c:-0}" -ge 1 ] && break; sleep 0.05
  done
  sleep 0.2
  c=$(grep -c 'hammerspoon://ferry-hide' "$work/open.log" 2>/dev/null)
  echo "${c:-0}"
}
rm -f "$work/open.log"
"$host" ensure >/dev/null

# Start from a note in insert mode, as after the hotkey.
"$host" show com.example.app 4242 >/dev/null
send 'note text'
f=$work/k1.txt d=$work/done/k1
printf 'hello\n' >"$f"
r=$(edit start "$f" "$d")
# The note's insert mode ends just after start returns; the edit's starts then.
sleep 0.3
check "start from a note in insert mode: ok, edit buffer current, insert mode" "ok hello i" \
  "$r $(ask 'getline(1)." ".mode()')"
send 'typed <C-x>'
check "Ctrl-X after typing: file holds the text, done=0, one hide" "typed hello|0|1" \
  "$(cat "$f")|$(done_code "$d")|$(hides)"
check "after Ctrl-X the note is back with its draft" "note text" "$(ask 'getline(1)')"

rm -f "$work/open.log"
f=$work/k2.txt d=$work/done/k2
printf 'keep\n# no newline' >"$f"; cp "$f" "$work/k2.orig"
edit start "$f" "$d" >/dev/null
send 'junk<C-q>'
check "Ctrl-Q: file bytes unchanged, done=1, one hide" "same|1|1" \
  "$(cmp -s "$f" "$work/k2.orig" && echo same || echo changed)|$(done_code "$d")|$(hides)"

rm -f "$work/open.log"
f=$work/k3.txt d=$work/done/k3
printf 'one\n' >"$f"
edit start "$f" "$d" >/dev/null
send 'two <Esc>:q<CR>'
check ":q hides and the edit stays pending" "1 pending" \
  "$(hides) $(edit status "$f" "$d")"
send ':wq<CR>'
check ":wq writes and ends the edit" "two one|0" "$(cat "$f")|$(done_code "$d")"

f=$work/k4.txt d=$work/done/k4
printf 'zz\n' >"$f"
edit start "$f" "$d" >/dev/null
send 'a<Esc>ZZ'
check "ZZ writes and ends the edit" "azz|0" "$(cat "$f")|$(done_code "$d")"
f=$work/k5.txt d=$work/done/k5
printf 'zq\n' >"$f"
edit start "$f" "$d" >/dev/null
send 'a<Esc>ZQ'
check "ZQ leaves the file and ends the edit with 1" "zq|1" "$(cat "$f")|$(done_code "$d")"


# --- a pending edit wins the hotkey (ferry-host show/talk/release/draft) ----
bufname() { ask "fnamemodify(resolve(bufname('%')), ':p')"; }
paste() { ask "luaeval('vim.paste({_A}, -1)', '$1')" >/dev/null; }
flow_state() { "$host" flow-state; }
# Wait until flow-state prints $1 (a release wait ends after the paste settles).
wait_flow() { for _ in $(seq 60); do [ "$(flow_state)" = "$1" ] && break; sleep 0.05; done; flow_state; }
rf() { (cd "$(dirname "$1")" && printf '%s/%s\n' "$(pwd -P)" "$(basename "$1")"); }
notel1() { ask "luaeval('vim.fn.getbufline(vim.fn.bufnr(_A), 1)[1]', '$npath')"; }
"$host" show com.example.app 4242 >/dev/null
send '<Esc>'
npath=$(ask 'luaeval("require\"ferry.note\".current().path")')
f=$work/k6.txt d=$work/done/k6
printf 'edit me\n' >"$f"
edit start "$f" "$d" >/dev/null
sleep 0.3
rm -f "$work/open.log"
r=$("$host" draft)
check "draft during an edit: prints the edit file, no hide, edit still pending, normal mode" \
  "$f 0 pending n" "$r $(grep -c ferry-hide "$work/open.log" 2>/dev/null || echo 0) $(edit status "$f" "$d") $(ask 'mode()')"
ask "execute('tabnext 1')" >/dev/null
r=$("$host" show com.other.app 7)
check "show x 1 during an edit: prints the edit file, edit buffer current, insert mode" \
  "$f $(rf "$f") i" "$r $(bufname) $(ask 'mode()')"
check "show during an edit leaves the note's captured target and draft alone" \
  "com.example.app 4242 note text" \
  "$(ask 'luaeval("require\"ferry.note\".state.captured.target")') $(ask 'luaeval("require\"ferry.note\".state.captured.window")') $(notel1)"

send '<Esc>'
ask "execute('tabnext 1')" >/dev/null
r=$("$host" show --talk com.other.app 7)
check "show --talk during an edit: edit buffer current, Flow recording" \
  "$f $(rf "$f") i recording" "$r $(bufname) $(ask 'mode()') $(flow_state)"
r=$("$host" release)
paste ' spoken'
check "show --talk, release: the fake paste lands in the edit buffer, Flow idle again" \
  "released  spokenedit me|stopped" "$r $(ask 'getline(1)')|$(wait_flow stopped)"
check "the note did not get the paste" "note text" "$(notel1)"
check "Flow saw a stop" "1" "$(grep -c stop-hands-free "$work/open.log" 2>/dev/null)"

send '<Esc>0'
r=$("$host" talk)
check "talk with the edit in front: talk <file>, insert after the cursor" "talk $f i" "$r $(ask 'mode()')"
r=$("$host" release)
paste 'X'
check "talk, release: the paste lands just after the edit's cursor (like a)" "released  Xspokenedit me|stopped" \
  "$r $(ask 'getline(1)')|$(wait_flow stopped)"

# The hotkey while Flow records in the edit: draft waits for the paste, then
# the edit hides itself and stays pending.
rm -f "$work/open.log"
"$host" show --talk com.other.app 7 >/dev/null
r=$("$host" draft)
paste ' late'
check "draft while Flow records in the edit: waiting for flow, paste in the edit, one hide, still pending" \
  "waiting for flow $f| X latespokenedit me|1|pending" \
  "$r|$(ask 'getline(1)')|$(hides)|$(edit status "$f" "$d")"

send '<C-x>'
check "Ctrl-X after all that: the file holds the dictation, done=0" " X latespokenedit me|0" \
  "$(cat "$f")|$(done_code "$d")"
r=$("$host" show com.example.app 4242)
check "with no edit pending, show is the note again" "$npath note text" "$r $(ask 'getline(1)')"

exit $fail
