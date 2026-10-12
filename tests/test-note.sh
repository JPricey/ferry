#!/usr/bin/env bash
# Submit, Cancel and Hide in lua/ferry/note.lua: tests/note_spec.lua under
# headless nvim (--clean) with a recording stub host, then :q against a real
# ferry-host server. A recording fake `open` is first on PATH, so nothing
# reaches Hammerspoon. Temp history database, notes folder, index and
# outbox only.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# macOS socket paths max out at 104 bytes, so keep the folder short.
work=$(mktemp -d /tmp/ferryn.XXXX)
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
[ -e "$work/open.fail" ] && exit 1
exit 0
EOF
chmod +x "$work/bin/open"
# A failing ghostty: ferry-host ensure finds no GUI settings.
printf '#!/bin/sh\nexit 1\n' >"$work/bin/ghostty"; chmod +x "$work/bin/ghostty"
export PATH="$work/bin:$PATH"

fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want '$2' got '$3'"; fail=1; fi; }

# --- spec: stub host, temp DB --------------------------------------------
# nvim -l prints to stderr and leaves the last line unterminated.
perl -e 'alarm 60; exec @ARGV' nvim --headless --clean -l "$root/tests/note_spec.lua" "$root" "$work" 2>&1
[ $? -eq 0 ] || fail=1
echo

# --- keys on a real ferry-host server --------------------------------
# Typed input (--remote-send) goes through the main loop, as in real use.
host="$root/bin/ferry-host"
db="$root/bin/ferry-db"
ask() { nvim --server "$FERRY_SOCK" --remote-expr "$1" 2>&1; }
send() { nvim --server "$FERRY_SOCK" --remote-send "$1"; }
outcome() { "$db" get "$1" 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin)["outcome"])' 2>/dev/null || echo none; }
# Wait for the fake open to log a line, then print it and clear the log.
opened() {
  for _ in $(seq 100); do [ -s "$work/open.log" ] && break; sleep 0.05; done
  cat "$work/open.log" 2>/dev/null; rm -f "$work/open.log"
}
waitrow() { for _ in $(seq 100); do [ "$(outcome "$1")" = "$2" ] && break; sleep 0.05; done; }
# A note file's frontmatter value for a key, and its body joined by |.
fkey() { sed -n "/^$2: /{s/^$2: //p;q;}" "$1" 2>/dev/null; }
fbody() { awk 'NR == 1 && $0 == "---" { f = 1; next } f && $0 == "---" { f = 0; next } !f' "$1" 2>/dev/null | paste -sd'|' -; }
exists() { test -e "$1" && echo yes || echo no; }
listed() { # id: "<state> <preview>" from ferry-notes list, or none
  "$root/bin/ferry-notes" list 2>/dev/null | python3 -c 'import json,sys
r=[x for x in json.load(sys.stdin) if x["id"]==sys.argv[1]]
print(r[0]["state"]+" "+r[0]["preview"] if r else "none")' "$1" 2>/dev/null || echo none
}
url_kind() { case $1 in *ferry-submit*target=com.example.app\&window=4242*) echo submit ;; *ferry-hide) echo hide ;; *) echo "other: $1" ;; esac; }
rm -f "$work/open.log"
"$host" ensure >/dev/null
pid=$(ask 'getpid()')
# Never touch the system clipboard: a fake + and * provider on the server,
# set before anything uses a clipboard register.
ask "luaeval('(function() _G.ferryclip = {}; local c, p = {}, {}; for _, r in ipairs({\"+\", \"*\"}) do c[r] = function(l) _G.ferryclip[r] = l end; p[r] = function() return _G.ferryclip[r] or {} end end; vim.g.clipboard = { name = \"ferrytest\", copy = c, paste = p }; return 1 end)()')" >/dev/null
clipped() { ask "luaeval('table.concat(_G.ferryclip[\"+\"] or {}, \"|\")')"; }

"$host" show com.example.app 4242 >/dev/null
check "after show: line 1 is the target header, insert mode on row 2" "to: app:com.example.app#4242 i 2" \
  "$(ask 'getline(1)." ".mode()." ".line(".")')"
id=$(ask 'b:ferry.id'); waitrow "$id" open
send 'server draft<Esc>:q<CR>'
check ":q hides via ferry-hide" hide "$(url_kind "$(opened)")"
check ":q leaves the server running" "$pid" "$(ask 'getpid()')"
d=$(ask 'g:ferry_draft')
check ":q keeps the draft file (target in the frontmatter), row stays open" \
  "draft app:com.example.app#4242 server draft open" "$(fkey "$d" state) $(fkey "$d" target) $(fbody "$d") $(outcome "$id")"

"$host" show com.example.app 4242 >/dev/null
send '<Esc>:wq<CR>'
check ":wq submits the resumed draft" "submit submitted" "$(url_kind "$(opened)") $(outcome "$id")"

"$host" show com.example.app 4242 >/dev/null
id=$(ask 'b:ferry.id'); waitrow "$id" open
send 'by keys<C-x>'
check "<C-x> in insert mode submits" "submit submitted" "$(url_kind "$(opened)") $(outcome "$id")"
check "the history row's target is the header's spec" "app:com.example.app#4242" \
  "$("$db" get "$id" | python3 -c 'import json,sys;print(json.load(sys.stdin)["target"])')"

"$host" show com.example.app 4242 >/dev/null
id=$(ask 'b:ferry.id'); waitrow "$id" open
send 'via x<Esc>:x<CR>'
check ":x submits" "submit submitted" "$(url_kind "$(opened)") $(outcome "$id")"

"$host" show com.example.app 4242 >/dev/null
id=$(ask 'b:ferry.id'); waitrow "$id" open
send 'via ZZ<Esc>ZZ'
check "ZZ submits" "submit submitted" "$(url_kind "$(opened)") $(outcome "$id")"

"$host" show com.example.app 4242 >/dev/null
id=$(ask 'b:ferry.id'); waitrow "$id" open
send 'drop me<Esc>ZQ'
check "ZQ cancels" "hide cancelled" "$(url_kind "$(opened)") $(outcome "$id")"

# Voice keys: <C-q> cancels from insert mode; <C-s> toggles Flow (the fake
# `open` logs its URL) and stays in insert mode.
"$host" show com.example.app 4242 >/dev/null
id=$(ask 'b:ferry.id'); waitrow "$id" open
send 'x<C-q>'
check "<C-q> in insert mode cancels" "hide cancelled" "$(url_kind "$(opened)") $(outcome "$id")"

"$host" show com.example.app 4242 >/dev/null
id=$(ask 'b:ferry.id'); waitrow "$id" open
send '<C-s>'
check "<C-s> starts Flow and stays in insert mode" "-g wispr-flow://start-hands-free i" "$(opened) $(ask 'mode()')"
send '<C-s>'
check "<C-s> again stops Flow, still in insert mode" "-g wispr-flow://stop-hands-free i" "$(opened) $(ask 'mode()')"
send 'words<Esc><C-q>'
check "<C-q> in normal mode cancels" "hide cancelled" "$(url_kind "$(opened)") $(outcome "$id")"
check "server still running after all keys" "$pid" "$(ask 'getpid()')"

# Copy and hide: <C-y> in insert mode copies the body, whatever the header.
"$host" show com.example.app 4242 >/dev/null
id=$(ask 'b:ferry.id'); waitrow "$id" open
send 'copied<C-y>'
check "<C-y> in insert mode copies the body and hides" "hide submitted copied" \
  "$(url_kind "$(opened)") $(outcome "$id") $(clipped)"
check "<C-y>: the history row's target is clipboard" clipboard \
  "$("$db" get "$id" | python3 -c 'import json,sys;print(json.load(sys.stdin)["target"])')"

# Submit file in the outbox; after Submit, :q in that window still hides.
"$host" show com.example.app 4242 >/dev/null
id=$(ask 'b:ferry.id'); waitrow "$id" open
send 'to outbox<Esc>ZZ'
url=$(opened)
file=$(python3 -c 'import sys, urllib.parse as u; print(u.parse_qs(u.urlsplit(sys.argv[1]).query)["file"][0])' "${url#-g }")
check "submit file path is under \$FERRY_OUTBOX" "$FERRY_OUTBOX/$id.md" "$file"
check "after Submit the window shows a fresh note" "markdown 1 2" \
  "$(ask '&filetype." ".exists("b:ferry")." ".exists(":Hide")')"
send ':q<CR>'
check "after Submit, :q in that window hides" hide "$(url_kind "$(opened)")"
check "after Submit, :q in that window leaves the server running" "$pid" "$(ask 'getpid()')"

# --- note files: autosave, :w, Submit, Cancel ----------------------------
"$host" show com.example.app 4242 >/dev/null
id=$(ask 'b:ferry.id'); waitrow "$id" open
nf=$(ask 'expand("%:p")')
check "a fresh note has no file yet" no "$(exists "$nf")"
send 'typed by keys'
sleep 1.5
check "after typing and waiting 1.5 s: the file has state draft, the target and the text" \
  "draft|app:com.example.app#4242|typed by keys" "$(fkey "$nf" state)|$(fkey "$nf" target)|$(fbody "$nf")"
check "... while buffer line 1 is the to: line (no frontmatter in the buffer)" \
  "to: app:com.example.app#4242|typed by keys" "$(ask 'join(getline(1, "$"), "|")')"
send ' and saved<Esc>:w<CR>'
for _ in $(seq 40); do [ "$(fbody "$nf")" = "typed by keys and saved" ] && break; sleep 0.05; done
check ":w writes the frontmatter, then the body" "---|id: $id|typed by keys and saved|" \
  "$(sed -n 1p "$nf")|$(sed -n 2p "$nf")|$(fbody "$nf")|$(ask 'v:errmsg')"
send 'ZZ'
check "Submit keeps the file: state sent, a sent time, the body" "submit submitted sent yes typed by keys and saved" \
  "$(url_kind "$(opened)") $(outcome "$id") $(fkey "$nf" state) $(test -n "$(fkey "$nf" sent)" && echo yes) $(fbody "$nf")"
for _ in $(seq 100); do [ "$(listed "$id")" != none ] && break; sleep 0.05; done
check "ferry-notes list shows the sent note" "sent typed by keys and saved" "$(listed "$id")"

"$host" show com.example.app 4242 >/dev/null
id=$(ask 'b:ferry.id'); waitrow "$id" open
nf=$(ask 'expand("%:p")')
send 'not wanted<Esc>ZQ'
check "Cancel keeps the file as cancelled" "hide cancelled cancelled not wanted" \
  "$(url_kind "$(opened)") $(outcome "$id") $(fkey "$nf" state) $(fbody "$nf")"

"$host" show com.example.app 4242 >/dev/null
id=$(ask 'b:ferry.id'); waitrow "$id" open
nf=$(ask 'expand("%:p")')
send 'gone soon'
sleep 1.5
had=$(exists "$nf")
send '<Esc>:2,$d<CR>ZQ'
check "blank Cancel leaves no file (it had one after autosave)" "yes hide no" "$had $(url_kind "$(opened)") $(exists "$nf")"
"$host" show com.example.app 4242 >/dev/null
nf=$(ask 'expand("%:p")')
send '<Esc>:q<CR>'
check "an untouched blank note hidden with :q leaves no file" "hide no" "$(url_kind "$(opened)") $(exists "$nf")"

# Note keys pressed in the history sidebar act on the tab's note. Joe's
# config maps normal <C-x> to :write globally; on the sidebar (a nofile
# buffer) that failed with E382 and nothing was sent. Same map here.
ask "luaeval('vim.keymap.set(\"n\", \"<C-x>\", vim.cmd.write) or 1')" >/dev/null
to_sidebar() {
  send '<Esc><Cmd>lua vim.api.nvim_set_current_win(require"ferry.history".state.win)<CR>'
  ask 'execute("let v:errmsg = \"\"")' >/dev/null
}
side_key() { # keys text: show a note, type text, press keys in the sidebar
  "$host" show com.example.app 4242 >/dev/null
  id=$(ask 'b:ferry.id'); waitrow "$id" open
  send "$2"; to_sidebar
  side=$(ask 'bufname()')
  send "$1"
}
# Without the sidebar's own <C-x> (as before the fix), Joe's error.
"$host" show com.example.app 4242 >/dev/null
to_sidebar; ask "luaeval('vim.keymap.del(\"n\", \"<C-x>\", { buffer = 0 }) or bufname()')" >/dev/null
send '<C-x>'
check "sidebar without its <C-x> map: global :write fails (Joe's report)" \
  "ferry://history E5108: Error executing lua: Vim:E382: Cannot write, 'buftype' option is set" \
  "$(ask 'bufname()') $(ask 'v:errmsg' | head -1)"
sleep 0.3; rm -f "$work/open.log"
side_key '<C-x>' 'from sidebar'
check "<C-x> in the sidebar sends the note" "ferry://history submit submitted" \
  "$side $(url_kind "$(opened)") $(outcome "$id")"
check "<C-x> in the sidebar: no error, focus on the note" " 1" "$(ask 'v:errmsg') $(ask 'exists("b:ferry")')"
side_key ZZ 'zz'
check "ZZ in the sidebar sends the note" "submit submitted" "$(url_kind "$(opened)") $(outcome "$id")"
side_key ':wq<CR>' 'wq'
check ":wq in the sidebar sends the note" "submit submitted" "$(url_kind "$(opened)") $(outcome "$id")"
side_key ':x<CR>' 'x'
check ":x in the sidebar sends the note" "submit submitted" "$(url_kind "$(opened)") $(outcome "$id")"
side_key '<C-q>' 'drop'
check "<C-q> in the sidebar cancels the note" "hide cancelled" "$(url_kind "$(opened)") $(outcome "$id")"
side_key ZQ 'drop'
check "ZQ in the sidebar cancels the note" "hide cancelled" "$(url_kind "$(opened)") $(outcome "$id")"
side_key '<C-y>' 'side copy'
check "<C-y> in the sidebar copies the note and hides" "hide submitted side copy" \
  "$(url_kind "$(opened)") $(outcome "$id") $(clipped)"
side_key ':q<CR>' 'kept'
d=$(ask 'g:ferry_draft')
check ":q in the sidebar hides and keeps the draft, target and all" "hide app:com.example.app#4242 kept open 2" \
  "$(url_kind "$(opened)") $(fkey "$d" target) $(fbody "$d") $(outcome "$id") $(ask 'winnr("$")')"
side_key '<C-s>' ' more'
# Joe stays in insert mode (GT 8), at the end of the body, off the to: line.
check "<C-s> in the sidebar starts Flow from the note, in insert mode at the end of the body" \
  "-g wispr-flow://start-hands-free 1 i 1 1 1" \
  "$(opened) $(ask 'exists("b:ferry")') $(ask "mode().' '.(line('.') == line('\$')).' '.(col('.') == col('\$')).' '.(line('.') > 1)")"
send '<C-s>'; opened >/dev/null

# Live upgrade: a server running the note at api 4 with 4f113ac's history
# module (sidebar without note keys). show reloads the note to api 9; the
# sidebar reopened with q then :History or <leader>h has the note keys.
# 4f113ac predates the rename to ferry: its old name is read from its lua/
# folder and mapped to ferry in both files.
old=$work/old; mkdir -p "$old/lua/ferry"; ln -s "$root/bin" "$old/bin"
was=$(git -C "$root" ls-tree --name-only 4f113ac lua/ | sed 's#^lua/##')
for m in note history; do
  git -C "$root" show "4f113ac:lua/$was/$m.lua" |
    perl -pe "s/\Q$was\E/ferry/g; s/\Q${was//-/}\E/ferry/g" >"$old/lua/ferry/$m.lua"
done
cat >"$work/old.lua" <<EOF
local h = require("ferry.history"); h.close()
local n = require("ferry.note")
local on = dofile("$old/lua/ferry/note.lua"); on.state = n.state
package.loaded["ferry.note"] = on
package.loaded["ferry.history"] = dofile("$old/lua/ferry/history.lua")
on.apply_options(vim.api.nvim_get_current_buf())
EOF
"$host" show com.example.app 4242 >/dev/null
send '<Esc>'; ask "execute('luafile $work/old.lua')" >/dev/null
send ':History<CR>'; to_sidebar
check "old server: note api 4, old sidebar has no <C-x>" "4 nil 0" \
  "$(ask 'luaeval("require\"ferry.note\".api")') $(ask 'luaeval("tostring(require\"ferry.history\".api)")') $(ask "get(maparg('<C-x>', 'n', 0, 1), 'buffer', 0)")"
upgrade_key() { # reopen: keys that reopen the sidebar from the note
  "$host" show com.example.app 4242 >/dev/null
  id=$(ask 'b:ferry.id'); waitrow "$id" open
  send "upgraded"; to_sidebar; send 'q'
  send "<Esc>$1"; to_sidebar
  side="$(ask 'winnr("$")') $(ask 'bufname()')"
  send '<C-x>'
}
upgrade_key ':History<CR>'
check "after upgrade: q then :History, <C-x> in the sidebar sends the note" \
  "9 2 ferry://history submit submitted " \
  "$(ask 'luaeval("require\"ferry.note\".api")') $side $(url_kind "$(opened)") $(outcome "$id") $(ask 'v:errmsg')"
upgrade_key '\h'
check "after upgrade: q then <leader>h, <C-x> in the sidebar sends the note" \
  "2 ferry://history submit submitted " "$side $(url_kind "$(opened)") $(outcome "$id") $(ask 'v:errmsg')"
check "server still running after the sidebar keys" "$pid" "$(ask 'getpid()')"
"$host" stop
check "submit file survives ferry-host stop" "to outbox" "$(cat "$file" 2>&1)"

exit $fail
