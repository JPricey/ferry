#!/usr/bin/env bash
# bin/ferry-host and lua/ferry/note.lua against headless nvim
# servers on a temp socket (--clean). Never touches Joe's server, the real
# history database or the real notes folder.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
host="$root/bin/ferry-host"
# macOS socket paths max out at 104 bytes, so keep the folder short.
work=$(mktemp -d /tmp/ferryh.XXXX)
[ -n "$work" ] && [ -d "$work" ] || { echo "mktemp failed" >&2; exit 1; }
export FERRY_SOCK=$work/host.sock FERRY_NOTES_DIR=$work/notes \
  FERRY_DB=$work/history.sqlite FERRY_HOST_NVIM_FLAGS=--clean \
  FERRY_INDEX=$work/index.sqlite FERRY_OUTBOX=$work/outbox
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want '$2' got '$3'"; fail=1; fi; }
ask() { nvim --server "$FERRY_SOCK" --remote-expr "$1" 2>&1; }
servers() { pgrep -f -- "--listen $FERRY_SOCK" | wc -l | tr -d ' '; }
gone() { test -e "$FERRY_SOCK" && echo present || echo gone; }
uipids=
# A note file's body (after the frontmatter), and a frontmatter value.
fbody() { awk 'NR == 1 && $0 == "---" { f = 1; next } f && $0 == "---" { f = 0; next } !f' "$1" 2>&1; }
fkey() { sed -n "/^$2: /{s/^$2: //p;q;}" "$1" 2>/dev/null; }
cleanup() {
  pkill -f -- "--listen $work/" 2>/dev/null
  for p in $uipids; do kill "$p" 2>/dev/null; done
  rm -rf "$work"
}
trap cleanup EXIT

# A fake ghostty first on PATH: prints Ghostty-style config, fails (mode
# file says fail) or hangs (hang). The real one is never run.
mkdir -p "$work/bin" "$work/colors"
cat >"$work/bin/ghostty" <<EOF
#!/bin/sh
case \$(cat "$work/ghostty.mode" 2>/dev/null) in
  fail) exit 1 ;;
  hang) exec sleep 10 ;;
esac
echo "font-family = Test Mono"
echo "font-size = 13"
echo "background = #001e27"
EOF
chmod +x "$work/bin/ghostty"
# A recording fake `open`: Flow's deep links (talk, release) never reach
# Wispr Flow.
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s/open.log"\n' "$work" >"$work/bin/open"
chmod +x "$work/bin/open"
export PATH="$work/bin:$PATH"
# A transparent colorscheme, like Joe's NeoSolarized: Normal without guibg.
printf 'hi clear\nhi Normal guifg=#839496 guibg=NONE\nlet g:colors_name = "ferrytest"\n' >"$work/colors/ferrytest.vim"

# --- status / show while down --------------------------------------------
check "status prints down with no server" down "$("$host" status)"
"$host" show com.example.app 4242 >/dev/null 2>&1
check "show fails while the server is down" 1 $?

# --- ensure starts one server, a second ensure reuses it -----------------
"$host" ensure >/dev/null
pid=$(ask 'getpid()')
"$host" ensure >/dev/null
check "two ensures start one server" "1 $pid" "$(servers) $(ask 'getpid()')"
check "server has the repo on its runtimepath" 1 "$(ask "index(nvim_list_runtime_paths(), '$root') >= 0")"
check "status prints up uis=0" "up uis=0" "$("$host" status)"

# --- show: fresh note -----------------------------------------------------
a=$("$host" show com.example.app 4242)
check "show prints a note path in the notes dir" yes \
  "$(case $a in "$FERRY_NOTES_DIR"/*.md) echo yes ;; *) echo "no ($a)" ;; esac)"
check "after show com.example.app 4242: mode i, filetype markdown" "i markdown" "$(ask 'mode()." ".&filetype')"
check "b:ferry.target and .window are set" "com.example.app 4242" "$(ask 'b:ferry.target." ".b:ferry.window')"
check "b:ferry.id is a uuid; the file is <date>-<time>-<id8>.md" "yes yes" \
  "$(ask 'b:ferry.id' | grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' && echo yes) $(basename "$a" | grep -Eq "^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}-$(ask 'b:ferry.id' | cut -c1-8)\.md\$" && echo yes)"
check "note has the ferry buffer options" "1 1 0 0 en_us" \
  "$(ask '&l:spell." ".&l:wrap." ".&l:number." ".&l:swapfile." ".&l:spelllang')"
check "<D-v> pastes the + register in insert mode" "<C-R><C-O>+" "$(ask "maparg('<D-v>', 'i')" | cut -c1-11)"

# --- draft ------------------------------------------------------------------
ask "nvim_buf_set_lines(0, 0, -1, v:false, ['hello', 'from the host'])" >/dev/null
d=$("$host" draft)
check "draft prints the note path" "$a" "$d"
check "draft writes the file: frontmatter with the captured target, then the text" "draft app:com.example.app#4242 hello
from the host" "$(fkey "$a" state) $(fkey "$a" target) $(fbody "$a")"
check "draft sets g:ferry_draft" "$a" "$(ask 'g:ferry_draft')"
check "draft leaves insert mode" n "$(ask 'mode()')"

# --- resume ---------------------------------------------------------------
b=$("$host" show com.other.app 99)
check "next unseeded show returns the same path" "$a" "$b"
check "resumed note keeps its text, is in insert mode" "hello|from the host i" \
  "$(ask 'join(getline(1, "$"), "|")." ".mode()')"
check "resumed note takes the new target" "com.other.app 99" "$(ask 'b:ferry.target." ".b:ferry.window')"
ask "nvim_input('<Esc>Gotyped')" >/dev/null
"$host" draft >/dev/null
"$host" show com.other.app 99 >/dev/null
ask "nvim_input(' more')" >/dev/null
check "typing after resume continues where the draft left off" "typed more" "$(ask 'getline("$")')"

# --- seeded show ------------------------------------------------------------
printf 'selected text\nsecond line\n' >"$work/seed.txt"
ask "nvim_buf_set_lines(0, 0, -1, v:false, ['edited after draft'])" >/dev/null
c=$("$host" show com.example.app 4242 "$work/seed.txt")
check "seeded show returns a new path" yes "$(test -n "$c" && test "$c" != "$a" && echo yes)"
check "seed text is in the buffer below the header, mode i" "to: app:com.example.app#4242|selected text|second line i" \
  "$(ask 'join(getline(1, "$"), "|")." ".mode()')"
check "b:ferry.seed holds the seed text" "selected text|second line" "$(ask 'substitute(b:ferry.seed, "\n", "|", "g")')"
check "switching to a seeded note saves the previous one" "edited after draft" "$(fbody "$a")"
check "next unseeded show resumes the seeded note" "$c" "$("$host" show com.example.app 4242)"

# --- reuse of an existing server -------------------------------------------
"$host" stop
check "stop removes the socket and the server" "gone 0" "$(gone) $(servers)"
check "status prints down after stop" down "$("$host" status)"

nvim --headless --clean --listen "$FERRY_SOCK" </dev/null >/dev/null 2>&1 &
own=$!
for _ in $(seq 100); do [ "$(ask 1)" = 1 ] && break; sleep 0.05; done
"$host" ensure >/dev/null
e=$("$host" show com.example.app 4242)
check "ensure reuses an existing server and show works in it" "1 $own i com.example.app" \
  "$(servers) $(ask 'getpid()') $(ask 'mode()') $(ask 'b:ferry.target')"
check "show on the reused server opens a fresh note" yes "$(test -n "$e" && echo yes)"
"$host" stop
for _ in $(seq 100); do kill -0 "$own" 2>/dev/null || break; sleep 0.05; done
kill -0 "$own" 2>/dev/null && { echo "FAIL stop did not quit the reused server"; fail=1; kill "$own"; }
wait "$own" 2>/dev/null
check "stop quits the reused server and removes the socket" "0 gone" "$(servers) $(gone)"

check "attach-cmd prints the remote-ui command" yes \
  "$(case $("$host" attach-cmd) in *"nvim --server $FERRY_SOCK --remote-ui") echo yes ;; *) echo no ;; esac)"

# --- layout: the note and the history sidebar, nothing else ---------------
wins() { ask 'join(map(range(1, winnr("$")), "fnamemodify(bufname(winbufnr(v:val)), \":t\")"), " ")'; }
"$host" ensure >/dev/null
check "ensure reads the GUI settings from ghostty" "{'bg': '#001e27', 'font': 'Test Mono:h13'}" "$(ask 'string(g:ferry_gui)')"
ask "execute('vsplit | split | vnew | setlocal buftype=nofile | file FakeTree')" >/dev/null
f=$("$host" show com.example.app 4242)
check "show closes extra splits and a file tree: sidebar left, note right" "history $(basename "$f")" "$(wins)"
check "after show the note window is current, in insert mode" "$f i" "$(ask 'expand("%:p")') $(ask 'mode()')"
ask "execute('vsplit')" >/dev/null
"$host" show com.example.app 4242 >/dev/null
check "a second show keeps the sidebar and drops the new split" "history $(basename "$f")" "$(wins)"
nvim --server "$FERRY_SOCK" --remote-send '<Esc>:wincmd t<CR>'
for _ in $(seq 100); do [ "$(ask 'expand("%:t")')" = history ] && break; sleep 0.05; done
nvim --server "$FERRY_SOCK" --remote-send '<Tab>'
for _ in $(seq 100); do [ "$(ask 'expand("%:t")')" = "$(basename "$f")" ] && break; sleep 0.05; done
check "<Tab> in the sidebar jumps back to the note" "$(basename "$f")" "$(ask 'expand("%:t")')"
check "FERRY_SIDEBAR=0: show leaves only the note" "$(basename "$f")" \
  "$(FERRY_SIDEBAR=0 "$host" show com.example.app 4242 >/dev/null; wins)"

# --- GUI appearance ------------------------------------------------------------
# A stand-in UI over the socket (raw msgpack): with a name it first names its
# client so (Neovide names itself "neovide"); without, it is like a terminal
# --remote-ui. It attaches, then drains redraws until killed.
cat > "$work/ui.py" <<'PY'
import socket, sys
def fs(b): return bytes([0xa0 | len(b)]) + b
s = socket.socket(socket.AF_UNIX)
s.connect(sys.argv[1])
if len(sys.argv) > 2:
    s.sendall(bytes([0x94, 0, 1]) + fs(b"nvim_set_client_info") + bytes([0x95])
              + fs(sys.argv[2].encode()) + bytes([0x80]) + fs(b"ui") + bytes([0x80, 0x80]))
s.sendall(bytes([0x94, 0, 2]) + fs(b"nvim_ui_attach") + bytes([0x93, 80, 24, 0x80]))
while s.recv(65536):
    pass
PY
ui() { python3 "$work/ui.py" "$FERRY_SOCK" "$@" </dev/null >/dev/null 2>&1 & uipid=$!; uipids="$uipids $uipid"; }
uis() { ask 'len(nvim_list_uis())'; }
waitfor() { for _ in $(seq 60); do [ "$($1)" = "$2" ] && break; sleep 0.05; done; }
bg() { ask "synIDattr(synIDtrans(hlID('Normal')), 'bg#', 'gui')"; }
ask "execute('set rtp+=$work | colorscheme ferrytest')" >/dev/null
"$host" show com.example.app 4242 >/dev/null
check "without a GUI: guifont and Normal guibg untouched" "'' ''" "'$(ask '&guifont')' '$(bg)'"
title() { ask "&title.' '.&titlestring"; }
check "without a GUI: window title untouched" "0 " "$(title)"
ask "execute('colorscheme ferrytest')" >/dev/null
check "without a GUI: a ColorScheme leaves Normal without guibg" "''" "'$(bg)'"
ask "execute('let g:neovide = v:true | doautocmd UIEnter')" >/dev/null
check "GUI attached: guifont from Ghostty" "Test Mono:h13" "$(ask '&guifont')"
check "GUI attached: Normal gets Ghostty's background" "#001e27" "$(bg)"
check "GUI attached: Normal keeps its guifg" "#839496" "$(ask "synIDattr(synIDtrans(hlID('Normal')), 'fg#', 'gui')")"
ask "execute('colorscheme ferrytest')" >/dev/null
check "after a colorscheme change the background is re-applied" "#001e27" "$(bg)"
ask "execute('highlight Normal guibg=#123456 | doautocmd UIEnter')" >/dev/null
check "an existing Normal guibg is left alone" "#123456" "$(bg)"
check "g:neovide set but no Neovide UI listed: window title untouched" "0 " "$(title)"
ui neovide; nvui=$uipid
waitfor title "1 ferry"
check "Neovide UI attached: window title is ferry" "1 ferry" "$(title)"
# A server that loaded gui.lua before the listed-only title (api 1): ensure
# reloads it, and the title is set at once (a Neovide UI is listed).
ask "luaeval('(function() local g = require\"ferry.gui\"; g.api = 1; g.old = true; return 1 end)()')" >/dev/null
"$host" ensure >/dev/null
check "old gui module: ensure reloads it" "2 true" \
  "$(ask 'luaeval("require\"ferry.gui\".api")') $(ask 'luaeval("require\"ferry.gui\".old == nil")')"
check "old gui module: title set after the reload" "1 ferry" "$(title)"
# The Neovide UI leaves (g:neovide stays set): restored.
kill "$nvui"; waitfor uis 0
waitfor title "0 "
check "no Neovide UI left: window title restored" "0 " "$(title)"
# A later terminal --remote-ui (g:neovide still set) keeps its own title.
ui; termui=$uipid
waitfor uis 1
sleep 0.2
check "terminal UI after Neovide: window title untouched" "0 1" "$(title)$(uis)"
kill "$termui"; waitfor uis 0

# --- a server started before this change gets layout and GUI on show ---------
g=$("$host" show com.example.app 4242)
ask "luaeval('(function() local n = require\"ferry.note\"; n.api = 7; n.old = true; vim.g.ferry_gui = nil; vim.cmd(\"vsplit | split\"); return 1 end)()')" >/dev/null
"$host" draft >/dev/null
h=$("$host" show com.example.app 4242)
check "old server (note api 7): show reloads the note module to 9 and keeps the draft" "9 true $g" \
  "$(ask 'luaeval("require\"ferry.note\".api")') $(ask 'luaeval("require\"ferry.note\".old == nil")') $h"
check "old server: show applies the layout" "history $(basename "$g")" "$(wins)"
check "old server: show loads the GUI settings" "{'bg': '#001e27', 'font': 'Test Mono:h13'}" "$(ask 'string(g:ferry_gui)')"

# --- hold to talk: show --talk, talk, release ----------------------------------
lua() { ask "luaeval('tostring($1)')"; }
rec() { lua 'require"ferry.flow".recording()'; }
cur() { ask 'line(".").":".(col(".") - 1)." ".mode()'; }
opened() { cat "$work/open.log" 2>/dev/null; rm -f "$work/open.log"; }
# Flow's paste into the note (a bracketed paste reaches nvim as vim.paste),
# then wait for flow's release wait to end.
paste() {
  ask "luaeval('vim.paste({\"$1\"}, -1)')" >/dev/null
  for _ in $(seq 100); do [ "$(lua 'require"ferry.flow".state.waiting')" = nil ] && break; sleep 0.05; done
}
rm -f "$work/open.log"
ask "luaeval('require\"ferry.note\".forget()')" >/dev/null
t=$("$host" show --talk com.example.app 4242)
check "show --talk com.example.app 4242: mode i on row 2, Flow recording, no URL opened" "2:0 i true " \
  "$(cur) $(rec) $(opened)"
check "release: prints released, one stop-hands-free" "released|-g wispr-flow://stop-hands-free" \
  "$("$host" release)|$(sleep 0.3; opened)"
paste "talked"
check "after Flow's paste the text is in the body; a second release prints idle, opens nothing" \
  "to: app:com.example.app#4242|talked idle " "$(ask 'join(getline(1, "$"), "|")') $("$host" release) $(opened)"

ask "nvim_buf_set_lines(0, 1, -1, v:false, ['hello world'])" >/dev/null
"$host" draft >/dev/null
ask "nvim_win_set_cursor(0, [2, 4])" >/dev/null
check "talk in normal mode on hello world col 4: talk <path>, insert col 5, Flow recording, no new note" \
  "talk $t 2:5 i true $t" "$("$host" talk) $(cur) $(rec) $(ask 'g:ferry_draft')"
"$host" release >/dev/null; paste " big"
check "Flow's paste after talk lands at the cursor" "hello big world" "$(ask 'getline(2)')"
"$host" draft >/dev/null
ask "nvim_win_set_cursor(0, [1, 3])" >/dev/null
check "talk with the cursor on the to: header: insert at the end of line 2" "talk $t 2:15 i" "$("$host" talk) $(cur)"
"$host" release >/dev/null; paste "!"
check "Flow's paste never lands in the header" "to: app:com.example.app#4242|hello big world!" \
  "$(ask 'join(getline(1, "$"), "|")')"
"$host" draft >/dev/null
ask "nvim_win_set_cursor(0, [1, 0])" >/dev/null
"$host" draft >/dev/null
check "show --talk resuming a draft whose cursor was on the header: insert at the end of line 2" \
  "$t 2:16 i true" "$("$host" show --talk com.example.app 4242) $(cur) $(rec)"
"$host" release >/dev/null; paste "?"
check "each of the three releases above sent one stop" 3 "$(opened | grep -c stop-hands-free)"
ask "luaeval('require\"ferry.note\".forget()')" >/dev/null
check "talk without a note prints no note, Flow untouched" "no note false " "$("$host" talk) $(rec) $(opened)"
check "flow-state while idle prints idle; release --force prints forced, one stop, then waiting" \
  "idle forced waiting|-g wispr-flow://stop-hands-free" \
  "$("$host" flow-state) $("$host" release --force) $("$host" flow-state)|$(sleep 0.3; opened)"
paste "forced"
ask "luaeval('require\"ferry.flow\".assume_recording()')" >/dev/null
check "flow-state while recording prints recording; release --force then prints released, one stop" \
  "recording released|-g wispr-flow://stop-hands-free" \
  "$("$host" flow-state) $("$host" release --force)|$(sleep 0.3; opened)"
paste "x"
check "after the paste: flow-state idle" idle "$("$host" flow-state)"

# A server holding the API-3 note module (and a flow module from before
# hold to talk) reloads both on talk, keeping the draft and its target.
u=$("$host" show com.example.app 4242)
ask "nvim_buf_set_lines(0, 1, -1, v:false, ['upgrade draft'])" >/dev/null
"$host" draft >/dev/null
ask "luaeval('(function() require\"ferry.note\".api = 3; local f = require\"ferry.flow\"; f.api = nil; f.adopt_start = nil; return 1 end)()')" >/dev/null
check "API-3 server: talk reloads note (api 9) and flow (api 4), keeps the draft and its target" \
  "talk $u 9 4 to: app:com.example.app#4242|upgrade draft com.example.app 4242 true" \
  "$("$host" talk) $(lua 'require"ferry.note".api') $(lua 'require"ferry.flow".api') $(ask 'join(getline(1, "$"), "|")') $(ask 'b:ferry.target." ".b:ferry.window') $(rec)"
check "API-3 server: release after the upgrade sends one stop" "released|-g wispr-flow://stop-hands-free" \
  "$("$host" release)|$(sleep 0.3; opened)"
paste " done"
"$host" stop

# Live upgrade from main 54d10b6 (note api 5, flow api 2, history api 1): a
# server started from that code keeps running while the repo under it moves
# to this code (note 9, flow 4). The next host call reloads both modules.
# Draft, target and to: line are kept, a recording in progress and a pending
# release wait survive, each release sends exactly one stop, and a paste the
# old and the new paste hook both report counts once.
waiting() { lua 'require"ferry.flow".state.waiting ~= nil'; }
vpaste() { ask "luaeval('vim.paste({\"$1\"}, -1)')" >/dev/null; sleep 0.4; }
apis() { echo "$(lua 'require"ferry.note".api') $(lua 'require"ferry.flow".api')"; }
body() { ask 'join(getline(1, "$"), "|")'; }
# old_tree <commit> <dir>: that commit's tree in <dir>. Commits before the
# rename to ferry used another name: it is read from the commit's lua/
# folder and mapped to ferry in paths and file contents.
old_tree() {
  mkdir -p "$2"; git -C "$root" archive "$1" | tar -x -C "$2"
  local was flat upper p
  was=$(git -C "$root" ls-tree --name-only "$1" lua/ | sed 's#^lua/##')
  [ "$was" = ferry ] && return
  flat=${was//-/}; upper=$(echo "${was//-/_}" | tr '[:lower:]' '[:upper:]')
  find "$2" -depth -name "*$was*" | while read -r p; do
    mv "$p" "$(dirname "$p")/$(basename "$p" | sed "s/$was/ferry/g")"
  done
  find "$2" -type f -exec perl -pi -e "s/\Q$was\E/ferry/g; s/\Q$flat\E/ferry/g; s/\Q$upper\E/FERRY/g" {} +
}
old_server() { # dir: 54d10b6's tree there, its host shows a note with a draft
  old_tree 54d10b6 "$1"
  "$1/bin/ferry-host" ensure >/dev/null
  "$1/bin/ferry-host" show com.example.app 4242 >/dev/null
  ask "nvim_buf_set_lines(0, 1, -1, v:false, ['live draft'])" >/dev/null
  "$1/bin/ferry-host" draft >/dev/null
  check "54d10b6 server: note api 5, flow api 2" "5 2" "$(apis)"
}
upgrade() { cp -R "$root/lua" "$root/bin" "$1/"; }
opened >/dev/null

# A recording in progress at the upgrade.
live=$work/live1; old_server "$live"
"$live/bin/ferry-host" talk >/dev/null
upgrade "$live"
check "upgrade with a recording: release reloads to note 9, flow 4, keeps draft, to: line and target, one stop" \
  "released 9 4 to: app:com.example.app#4242|live draft com.example.app 4242 true|-g wispr-flow://stop-hands-free" \
  "$("$live/bin/ferry-host" release) $(apis) $(body) $(ask 'b:ferry.target." ".b:ferry.window') $(waiting)|$(sleep 0.3; opened)"
# A quick second hold during that wait: the new talk adds the new paste hook
# beside the old one, so the first paste is reported twice.
"$live/bin/ferry-host" talk >/dev/null
check "upgrade: a quick second hold's release sends one stop" "released|-g wispr-flow://stop-hands-free" \
  "$("$live/bin/ferry-host" release)|$(sleep 0.3; opened)"
vpaste " one"
check "upgrade: the first paste, reported by both hooks, counts once (still waiting for the second)" \
  "true false" "$(waiting) $(rec)"
# A third hold before the second paste: that paste ends the wait but must
# not clear the new recording (the old hook forwards to the new module).
"$live/bin/ferry-host" talk >/dev/null
vpaste " two"
check "upgrade: the second paste ends the wait and keeps the third hold recording" \
  "false true" "$(waiting) $(rec)"
check "upgrade: the third hold's release sends one stop" "released|-g wispr-flow://stop-hands-free" \
  "$("$live/bin/ferry-host" release)|$(sleep 0.3; opened)"
vpaste " three"
check "upgrade: the last paste ends its wait, each paste in the note once" \
  "false false 1 1 1" "$(waiting) $(rec) $(echo $(for w in one two three; do body | grep -o $w | grep -c .; done))"
"$live/bin/ferry-host" stop

# A pending release wait (the old module already sent its stop) at the upgrade.
live=$work/live2; old_server "$live"
"$live/bin/ferry-host" talk >/dev/null
"$live/bin/ferry-host" release >/dev/null
check "54d10b6 server: release sends one stop and waits" "true -g wispr-flow://stop-hands-free" \
  "$(waiting) $(sleep 0.3; opened)"
upgrade "$live"
check "upgrade with a pending release wait: release reloads, keeps draft and target, the wait, sends no second stop" \
  "released 9 4 to: app:com.example.app#4242|live draft com.example.app 4242 true " \
  "$("$live/bin/ferry-host" release) $(apis) $(body) $(ask 'b:ferry.target." ".b:ferry.window') $(waiting) $(sleep 0.3; opened)"
vpaste " landed"
check "upgrade: Flow's paste ends the old wait, lands once, recording off" \
  "false false 1" "$(waiting) $(rec) $(body | grep -o landed | grep -c .)"
"$live/bin/ferry-host" stop

# Live upgrade from main 1dd6f9b (note api 8, notes as raw scratch files in
# ${TMPDIR}/ferry-notes): the next call with this code reloads note to 9,
# keeps the draft (to: line, text, target), and the draft gets a note file
# in the notes folder on its next change. The old scratch file is left as
# it was.
live=$work/live3; old_tree 1dd6f9b "$live"
FERRY_NOTES_DIR=$work/oldnotes "$live/bin/ferry-host" ensure >/dev/null
FERRY_NOTES_DIR=$work/oldnotes "$live/bin/ferry-host" show com.example.app 4242 >/dev/null
ask "nvim_buf_set_lines(0, 1, -1, v:false, ['api 8 draft'])" >/dev/null
old=$(FERRY_NOTES_DIR=$work/oldnotes "$live/bin/ferry-host" draft)
check "1dd6f9b server: note api 8, raw draft file in the old folder" "8 $work/oldnotes to: app:com.example.app#4242|api 8 draft" \
  "$(lua 'require"ferry.note".api') $(dirname "$old") $(command paste -sd'|' - <"$old")"
upgrade "$live"
mkdir -p "$FERRY_NOTES_DIR"; before=$(ls "$FERRY_NOTES_DIR" | wc -l | tr -d ' ')
new=$("$live/bin/ferry-host" show com.example.app 4242)
check "upgrade from api 8: show reloads to 9, keeps the draft and target, names a note file in the notes folder" \
  "9 to: app:com.example.app#4242|api 8 draft com.example.app 4242 yes" \
  "$(lua 'require"ferry.note".api') $(body) $(ask 'b:ferry.target." ".b:ferry.window') $(case $new in "$FERRY_NOTES_DIR"/????-??-??-??????-*.md) echo yes ;; *) echo "no ($new)" ;; esac)"
ask "nvim_input('<Esc>A and more')" >/dev/null
sleep 1.5
check "upgrade from api 8: the draft's next change writes its note file (frontmatter, body)" \
  "draft app:com.example.app#4242 $(ask 'b:ferry.id') api 8 draft and more" \
  "$(fkey "$new" state) $(fkey "$new" target) $(fkey "$new" id) $(fbody "$new")"
check "upgrade from api 8: the old scratch file is left alone; one new file in the notes folder" \
  "to: app:com.example.app#4242|api 8 draft $((before + 1))" "$(command paste -sd'|' - <"$old") $(ls "$FERRY_NOTES_DIR" | wc -l | tr -d ' ')"
check "upgrade from api 8: draft prints the new path" "$new" "$("$live/bin/ferry-host" draft)"
"$live/bin/ferry-host" stop

# --- overrides and a missing or hung ghostty ------------------------------------
FERRY_GUI_FONT='Other Font:h15' FERRY_GUI_BG='#112233' "$host" ensure >/dev/null
check "FERRY_GUI_FONT and FERRY_GUI_BG win over Ghostty" "{'bg': '#112233', 'font': 'Other Font:h15'}" "$(ask 'string(g:ferry_gui)')"
FERRY_GUI_FONT='Other Font:h15' "$host" ensure >/dev/null
check "a font override alone keeps Ghostty's background" "{'bg': '#001e27', 'font': 'Other Font:h15'}" "$(ask 'string(g:ferry_gui)')"
"$host" stop
echo fail >"$work/ghostty.mode"
"$host" ensure >/dev/null
check "ghostty failing: ensure works, no GUI settings" "0 {'bg': '', 'font': ''}" "$? $(ask 'string(g:ferry_gui)')"
"$host" stop
echo hang >"$work/ghostty.mode"
t0=$(date +%s)
"$host" ensure >/dev/null
check "ghostty hanging: ensure works within 4 s, no GUI settings" "0 yes {'bg': '', 'font': ''}" \
  "$? $([ $(($(date +%s) - t0)) -le 4 ] && echo yes) $(ask 'string(g:ferry_gui)')"
"$host" stop
rm -f "$work/ghostty.mode"

# --- a config that resets the runtimepath, like lazy.nvim ----------------------
# Plain init: rtp is reset during startup, dropping `--cmd 'set rtp^=<repo>'`.
printf 'vim.opt.rtp = vim.env.VIMRUNTIME\n' >"$work/init.lua"
nvim --headless -u "$work/init.lua" --listen "$FERRY_SOCK" --cmd "set rtp^=$root" </dev/null >/dev/null 2>&1 &
for _ in $(seq 100); do [ "$(ask v:vim_did_enter)" = 1 ] && break; sleep 0.05; done
check "lazy-style init: the server lost the repo from its runtimepath" 0 "$(ask "index(nvim_list_runtime_paths(), '$root') >= 0")"
i=$("$host" show com.example.app 4242 2>&1)
check "lazy-style init: show works without a prior ensure" "yes i com.example.app" \
  "$(case $i in "$FERRY_NOTES_DIR"/*.md) echo yes ;; *) echo "no ($i)" ;; esac) $(ask 'mode()') $(ask 'b:ferry.target')"
check "lazy-style init: show loads the GUI settings" "{'bg': '#001e27', 'font': 'Test Mono:h13'}" "$(ask 'string(g:ferry_gui)')"
"$host" stop
nvim --headless -u "$work/init.lua" --listen "$FERRY_SOCK" </dev/null >/dev/null 2>&1 &
for _ in $(seq 100); do [ "$(ask v:vim_did_enter)" = 1 ] && break; sleep 0.05; done
check "lazy-style init: draft works without a prior ensure or show" "$FERRY_NOTES_DIR yes" \
  "$("$host" show com.example.app 4242 >/dev/null; d=$("$host" draft 2>&1); dirname "$d") $(test -n "$(ask 'g:ferry_draft')" && echo yes)"
"$host" stop
# vim.wait lets the server answer requests mid-init, before the reset (as
# lazy can while it loads), so an ensure that does not wait for VimEnter
# fixes rtp too early.
printf 'vim.wait(1000)\nvim.opt.rtp = vim.env.VIMRUNTIME\n' >"$work/init.lua"
FERRY_HOST_NVIM_FLAGS="-u $work/init.lua" "$host" ensure >/dev/null
r=$?
for _ in $(seq 100); do [ "$(ask v:vim_did_enter)" = 1 ] && break; sleep 0.05; done
check "lazy-style init: after ensure on a fresh start and VimEnter the repo is on rtp" "0 1" \
  "$r $(ask "index(nvim_list_runtime_paths(), '$root') >= 0")"
j=$("$host" show com.example.app 4242 2>&1)
check "lazy-style init: ensure on a fresh start, then show works" "yes i" \
  "$(case $j in "$FERRY_NOTES_DIR"/*.md) echo yes ;; *) echo "no ($j)" ;; esac) $(ask 'mode()')"
"$host" stop
# VimEnter variant: the reset happens in a VimEnter autocmd.
printf 'vim.api.nvim_create_autocmd("VimEnter", { callback = function() vim.opt.rtp = vim.env.VIMRUNTIME end })\n' >"$work/init.lua"
FERRY_HOST_NVIM_FLAGS="-u $work/init.lua" "$host" ensure >/dev/null
k=$("$host" show com.example.app 4242 2>&1)
check "VimEnter rtp reset: ensure on a fresh start, then show works" "yes 1" \
  "$(case $k in "$FERRY_NOTES_DIR"/*.md) echo yes ;; *) echo "no ($k)" ;; esac) $(ask "index(nvim_list_runtime_paths(), '$root') >= 0")"
"$host" stop

exit $fail
