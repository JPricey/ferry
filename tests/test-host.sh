#!/usr/bin/env bash
# bin/ferry-host and lua/ferry/note.lua against headless nvim
# servers on a temp socket (--clean). Never touches Joe's server, the real
# notes folder or index, or the old history database (FERRY_DB stays a temp
# path: servers started from old trees still write it).
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
# The note api ferry-host reloads an older server's module to.
napi=$(sed -n 's/^note_api=//p' "$host")
# The history api the note module reloads an older history module to.
hapi=$(sed -n 's/^M.api = //p' "$root/lua/ferry/history.lua")
ask() { nvim --server "$FERRY_SOCK" --remote-expr "$1" 2>&1; }
servers() { pgrep -f -- "--listen $FERRY_SOCK" | wc -l | tr -d ' '; }
gone() { test -e "$FERRY_SOCK" && echo present || echo gone; }
uipids=
# A note file's body (after the frontmatter), and a frontmatter value.
fbody() { awk 'NR == 1 && $0 == "---" { f = 1; next } f && $0 == "---" { f = 0; next } !f' "$1" 2>&1; }
fkey() { sed -n "/^$2: /{s/^$2: //p;q;}" "$1" 2>/dev/null; }
# FERRY_TEST_SHOW_GAP=1.1 sleeps between shows that must not depend on
# landing in the same second (Q1).
gap() { [ -z "${FERRY_TEST_SHOW_GAP:-}" ] || sleep "$FERRY_TEST_SHOW_GAP"; }
cleanup() {
  pkill -f -- "--listen $work/" 2>/dev/null
  for p in $uipids; do kill "$p" 2>/dev/null; done
  rm -rf "$work"
}
trap cleanup EXIT
# nvim keeps its socket in a temp dir that it leaves behind when killed or
# on os.exit; keep those in ours too.
export TMPDIR=$work/tmp
mkdir -p "$TMPDIR"

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
check "seed text is the buffer (no to: line), mode i" "selected text|second line i" \
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
# A blank note with no file takes each show's time in its name, so every
# check below names the path the latest show printed.
gap
f=$("$host" show com.example.app 4242)
check "a second show keeps the sidebar and drops the new split" "history $(basename "$f")" "$(wins)"
nvim --server "$FERRY_SOCK" --remote-send '<Esc>:wincmd t<CR>'
for _ in $(seq 100); do [ "$(ask 'expand("%:t")')" = history ] && break; sleep 0.05; done
nvim --server "$FERRY_SOCK" --remote-send '<Tab>'
for _ in $(seq 100); do [ "$(ask 'expand("%:t")')" = "$(basename "$f")" ] && break; sleep 0.05; done
check "<Tab> in the sidebar jumps back to the note" "$(basename "$f")" "$(ask 'expand("%:t")')"
gap
f=$(FERRY_SIDEBAR=0 "$host" show com.example.app 4242)
check "FERRY_SIDEBAR=0: show leaves only the note" "$(basename "$f")" "$(wins)"

# --- browse: show, then the sidebar focused ------------------------------------
# The row index under the sidebar's cursor, and that row's file name.
hrow() { ask "luaeval('(function() local h = require\"ferry.history\"; local i = h.state.map[vim.api.nvim_win_get_cursor(0)[1]]; return tostring(i) .. \" \" .. (i and vim.fn.fnamemodify(h.state.rows[i].path, \":t\") or \"\") end)()')"; }
# The current note's target and window, and its file name (a blank note's
# file name takes each show's time).
notetarget() { ask "luaeval('(function() local m = vim.b[require\"ferry.note\".current().buf].ferry; return m.target .. \" \" .. m.window end)()')"; }
notefile() { ask "luaeval('vim.fn.fnamemodify(require\"ferry.note\".current().path, \":t\")')"; }
br=$(FERRY_SIDEBAR=0 "$host" browse com.browse.app 77)
nf=$(notefile)
check "FERRY_SIDEBAR=0 browse: same note (id), sidebar left, note right" "${f##*-} $nf history $nf" \
  "${br##*-} $(basename "$br") $(wins)"
check "FERRY_SIDEBAR=0 browse: the sidebar is current, mode n, cursor on the newest note row" "history n 1" \
  "$(ask 'expand("%:t")') $(ask 'mode()') $(hrow | cut -d' ' -f1)"
check "FERRY_SIDEBAR=0 browse: the note takes the new target" "com.browse.app 77" "$(notetarget)"
# Already open, with a search and the note focused in insert mode: browse
# syncs (a file written outside ferry is listed first), clears the search.
"$host" show com.example.app 4242 >/dev/null
ask "luaeval('(function() require\"ferry.history\".state.query = \"nomatchword\"; require\"ferry.history\".refresh() end)()')" >/dev/null
printf -- '---\nid: eeeeeeee-0000-4000-8000-000000000005\nstate: draft\ncreated: %s\nupdated: %s\n---\nbrowse outside\n' \
  "$(date -u -v+1M +%Y-%m-%dT%H:%M:%SZ)" "$(date -u -v+1M +%Y-%m-%dT%H:%M:%SZ)" >"$FERRY_NOTES_DIR/zz-outside.md"
check "before browse: the note is current, in insert mode" "$(notefile) i" "$(ask 'expand("%:t")') $(ask 'mode()')"
"$host" browse com.example.app 4242 >/dev/null
check "browse com.example.app 4242: the sidebar is current, mode n, cursor on the newest note row" "history n 1" \
  "$(ask 'expand("%:t")') $(ask 'mode()') $(hrow | cut -d' ' -f1)"
check "browse with the sidebar open: synced, search cleared, the outside note first" "1 zz-outside.md nil" \
  "$(hrow) $(ask "luaeval('tostring(require\"ferry.history\".state.query)')")"
check "browse: the note takes the new target, one sidebar and the note" "com.example.app 4242 history $(notefile)" \
  "$(notetarget) $(wins)"
# A pinned note is listed first (under "── Pinned"); browse still lands on
# the newest note.
printf -- '---\nid: eeeeeeee-0000-4000-8000-000000000006\nstate: draft\npinned: true\ncreated: 2020-01-01T00:00:00Z\nupdated: 2020-01-01T00:00:00Z\n---\npinned old\n' \
  >"$FERRY_NOTES_DIR/aa-pinned.md"
"$host" browse com.example.app 4242 >/dev/null
check "browse with a pinned note: row 1 is the pinned note, cursor on the newest note" "aa-pinned.md 2 zz-outside.md" \
  "$(ask "luaeval('vim.fn.fnamemodify(require\"ferry.history\".state.rows[1].path, \":t\")')") $(hrow)"
# A new note since the sidebar last listed (forget, as after a Submit): show's
# layout queues a sidebar refresh; it must not move browse's cursor back to
# the pinned row once the event loop has run.
ask "luaeval('require\"ferry.note\".forget()')" >/dev/null
"$host" browse com.example.app 4242 >/dev/null
ask 1 >/dev/null; sleep 0.2; ask 1 >/dev/null
check "browse after a new note, pinned note listed: after the loop ran, cursor still on the newest note" "history 2 zz-outside.md" \
  "$(ask 'expand("%:t")') $(hrow)"
# An older history module loaded (live upgrade): the reload queues a sidebar
# refresh too; it must not move browse's cursor back either.
ask "luaeval('(function() require\"ferry.history\".api = 4; return 1 end)()')" >/dev/null
"$host" browse com.example.app 4242 >/dev/null
ask 1 >/dev/null; sleep 0.2; ask 1 >/dev/null
check "browse with an api-4 history module: reloaded, after the loop ran, cursor still on the newest note" "$hapi history 2 zz-outside.md" \
  "$(ask 'luaeval("require\"ferry.history\".api")') $(ask 'expand("%:t")') $(hrow)"
# Flow recording (or a finish waiting for its paste): browse keeps the note
# focused in insert mode so Flow's paste lands there; the sidebar is synced.
ask "luaeval('require\"ferry.flow\".assume_recording()')" >/dev/null
"$host" browse com.example.app 4242 >/dev/null
ask 1 >/dev/null
check "browse while Flow records (assume_recording): the note stays current in insert mode, sidebar open on the newest note, notice" \
  "$(notefile) i history 2 zz-outside.md 1" \
  "$(ask 'expand("%:t")') $(ask 'mode()') $(wins | cut -d' ' -f1) $(ask "luaeval('(function() local h = require\"ferry.history\"; local i = h.state.map[vim.api.nvim_win_get_cursor(h.state.win)[1]]; return tostring(i) .. \" \" .. vim.fn.fnamemodify(h.state.rows[i].path, \":t\") end)()')") $(ask "luaeval('vim.fn.execute(\"messages\"):find(\"Flow is still recording; the note keeps focus\", 1, true) and 1 or 0')")"
ask "luaeval('(function() local f = require\"ferry.flow\"; f.state.recording, f.state.adopted = false, false end)()')" >/dev/null
rm -f "$FERRY_NOTES_DIR/zz-outside.md" "$FERRY_NOTES_DIR/aa-pinned.md"
"$host" show com.example.app 4242 >/dev/null
check "show after browse: the note is current again, in insert mode" "$(notefile) i" "$(ask 'expand("%:t")') $(ask 'mode()')"
# A draft left and resumed is the newest note, listed first (▶); browse
# skips it: the cursor goes to the newest other note.
ask "nvim_buf_set_lines(0, 0, -1, v:false, ['left as a draft'])" >/dev/null
"$host" draft >/dev/null
"$host" browse com.example.app 4242 >/dev/null
ask 1 >/dev/null; sleep 0.2; ask 1 >/dev/null
check "browse after a draft: row 1 is the open note (▶), cursor on the newest other note (row 2)" \
  "$(notefile) true history 2 $(ask "luaeval('vim.fn.fnamemodify(require\"ferry.history\".state.rows[2].path, \":t\")')")" \
  "$(ask "luaeval('vim.fn.fnamemodify(require\"ferry.history\".state.rows[1].path, \":t\")')") $(ask "luaeval('tostring(require\"ferry.history\".state.rows[1].open)')") $(ask 'expand("%:t")') $(hrow)"
"$host" show com.example.app 4242 >/dev/null

# --- GUI appearance ------------------------------------------------------------
# A stand-in UI over the socket (raw msgpack): with a name it first names its
# client so (Neovide names itself "neovide"); without, it is like a terminal
# --remote-ui. It attaches (UIW columns, default 80), then drains redraws
# until killed.
cat > "$work/ui.py" <<'PY'
import os, socket, sys
def fs(b): return bytes([0xa0 | len(b)]) + b
s = socket.socket(socket.AF_UNIX)
s.connect(sys.argv[1])
if len(sys.argv) > 2:
    s.sendall(bytes([0x94, 0, 1]) + fs(b"nvim_set_client_info") + bytes([0x95])
              + fs(sys.argv[2].encode()) + bytes([0x80]) + fs(b"ui") + bytes([0x80, 0x80]))
s.sendall(bytes([0x94, 0, 2]) + fs(b"nvim_ui_attach") + bytes([0x93, int(os.environ.get("UIW", "80")), 24, 0x80]))
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

# --- notices: one screen line (Q2c) ---------------------------------------------
# In a 40-column UI a notice longer than the command line would stop at a
# Press ENTER prompt (mode r; the server answers nothing until Enter, so
# askt gives up after 3 s and prints blocked). A long notice shows cut to
# one line instead; :messages keeps the full text.
askt() {
  local r
  r=$({ perl -e 'alarm 3; exec @ARGV' nvim --server "$FERRY_SOCK" --remote-expr "$1" & wait $!; } 2>/dev/null) \
    && printf '%s\n' "$r" || echo blocked
}
# After a failed check: press Enter at a prompt so the rest can run.
dismiss() {
  for _ in 1 2 3; do
    [ "$(askt 1)" = blocked ] || return 0
    nvim --server "$FERRY_SOCK" --remote-send '<CR>'
  done
}
UIW=40 ui; narrow=$uipid
waitfor uis 1
n=$("$host" show com.example.app 4242)
ask "nvim_buf_set_lines(0, 0, -1, v:false, ['notice draft'])" >/dev/null
"$host" draft >/dev/null
long="ferry: an error notice far longer than forty columns, cut to one line"
ask "luaeval('vim.schedule(function() require\"ferry.notice\".notify(_A, vim.log.levels.ERROR) end) or 1', '$long')" >/dev/null
sleep 0.3
check "columns=40, a long error notice in normal mode: no Press ENTER (mode n), full text in :messages" \
  "40 n yes" "$(askt '&columns') $(askt 'mode(1)') $(askt "execute('messages')" | grep -qF "$long" && echo yes)"
dismiss
check "the cut line fits the command line and ends in …" "yes" \
  "$(askt "luaeval('(function() local c = require\"ferry.notice\".cut(_A, 28); return vim.fn.strdisplaywidth(c) <= 28 and vim.endswith(c, \"…\") and \"yes\" or c end)()', '$long')")"
# The longest note notice, in insert mode: the file changed outside while
# typing, so checktime forks the typing to a conflict file. It is raised
# inside the autosave's `silent write`, which used to swallow it.
"$host" show com.example.app 4242 >/dev/null
perl -pi -e 's/^notice draft$/edited outside/' "$n"
ask "nvim_input('typed ')" >/dev/null
sleep 0.1
ask "execute('checktime')" >/dev/null
sleep 0.5
check "columns=40, the fork notice in insert mode: mode i, the typing kept, full notice in :messages" \
  "i typed notice draft yes" \
  "$(askt 'mode(1)') $(askt 'getline(1)') $(askt "execute('messages')" | grep -qF "ferry: $(basename "$n") was changed outside ferry and is kept as it is; your text is in $(basename "$n" .md).conflict-" && echo yes)"
dismiss
kill "$narrow"; waitfor uis 0

# --- a server started before this change gets layout and GUI on show ---------
g=$("$host" show com.example.app 4242)
ask "nvim_buf_set_lines(0, 0, -1, v:false, ['api 7 draft'])" >/dev/null
ask "luaeval('(function() local n = require\"ferry.note\"; n.api = 7; n.old = true; vim.g.ferry_gui = nil; vim.cmd(\"vsplit | split\"); return 1 end)()')" >/dev/null
"$host" draft >/dev/null
gap
h=$("$host" show com.example.app 4242)
check "old server (note api 7): show reloads the note module to the current api and keeps the draft" "$napi true $g api 7 draft" \
  "$(ask 'luaeval("require\"ferry.note\".api")') $(ask 'luaeval("require\"ferry.note\".old == nil")') $h $(ask 'join(getline(1, "$"), "|")')"
check "old server: show applies the layout" "history $(basename "$g")" "$(wins)"
check "old server: show loads the GUI settings" "{'bg': '#001e27', 'font': 'Test Mono:h13'}" "$(ask 'string(g:ferry_gui)')"

# --- hold to talk: show --talk, talk, release ----------------------------------
lua() { ask "luaeval('tostring($1)')"; }
rec() { lua 'require"ferry.flow".recording()'; }
cur() { ask 'line(".").":".(col(".") - 1)." ".mode()'; }
opened() { cat "$work/open.log" 2>/dev/null; rm -f "$work/open.log"; }
# The fake open runs async (flow's queue): wait up to 2 s for it to log $1
# lines (default 1), then print and clear the log like opened.
opened_wait() {
  for _ in $(seq 40); do
    [ "$(cat "$work/open.log" 2>/dev/null | wc -l | tr -d ' ')" -ge "${1:-1}" ] && break
    sleep 0.05
  done
  opened
}
# Flow's paste into the note (a bracketed paste reaches nvim as vim.paste),
# then wait for flow's release wait to end.
paste() {
  ask "luaeval('vim.paste({\"$1\"}, -1)')" >/dev/null
  for _ in $(seq 100); do [ "$(lua 'require"ferry.flow".state.waiting')" = nil ] && break; sleep 0.05; done
}
rm -f "$work/open.log"
ask "luaeval('require\"ferry.note\".forget()')" >/dev/null
t=$("$host" show --talk com.example.app 4242)
check "show --talk com.example.app 4242: mode i on row 1, Flow recording, no URL opened" "1:0 i true " \
  "$(cur) $(rec) $(opened)"
check "release: prints released, one stop-hands-free" "released|-g wispr-flow://stop-hands-free" \
  "$("$host" release)|$(opened_wait)"
paste "talked"
check "after Flow's paste the text is in the body; a second release prints idle, opens nothing" \
  "talked idle " "$(ask 'join(getline(1, "$"), "|")') $("$host" release) $(opened)"

ask "nvim_buf_set_lines(0, 0, -1, v:false, ['hello world'])" >/dev/null
"$host" draft >/dev/null
ask "nvim_win_set_cursor(0, [1, 4])" >/dev/null
check "talk in normal mode on hello world col 4: talk <path>, insert col 5, Flow recording, no new note" \
  "talk $t 1:5 i true $t" "$("$host" talk) $(cur) $(rec) $(ask 'g:ferry_draft')"
"$host" release >/dev/null; paste " big"
check "Flow's paste after talk lands at the cursor" "hello big world" "$(ask 'getline(1)')"
"$host" draft >/dev/null
ask "nvim_win_set_cursor(0, [1, 0])" >/dev/null
"$host" draft >/dev/null
check "show --talk resuming a draft: insert where the draft left the cursor" \
  "$t 1:0 i true" "$("$host" show --talk com.example.app 4242) $(cur) $(rec)"
"$host" release >/dev/null; paste "?"
check "each of the two releases above sent one stop" 2 "$(opened_wait 2 | grep -c stop-hands-free)"
ask "luaeval('require\"ferry.note\".forget()')" >/dev/null
check "talk without a note prints no note, Flow untouched" "no note false " "$("$host" talk) $(rec) $(opened)"
check "flow-state after the talk releases' pastes prints stopped; release --force prints forced, one stop, then waiting" \
  "stopped forced waiting|-g wispr-flow://stop-hands-free" \
  "$("$host" flow-state) $("$host" release --force) $("$host" flow-state)|$(opened_wait)"
paste "forced"
ask "luaeval('require\"ferry.flow\".assume_recording()')" >/dev/null
check "flow-state while recording prints recording; release --force then prints released, one stop" \
  "recording released|-g wispr-flow://stop-hands-free" \
  "$("$host" flow-state) $("$host" release --force)|$(opened_wait)"
paste "x"
check "after the paste of a stop not of a talk hold: flow-state idle" idle "$("$host" flow-state)"
# P5: a talk hold ended by a Submit's stop: stopped once its paste landed,
# while the stray paste before it leaves the hold recording.
"$host" show --talk com.example.app 4242 >/dev/null
paste "stray"
check "talk, then a stray paste: flow-state recording" recording "$("$host" flow-state)"
ask "luaeval('(function() require\"ferry.note\".host = { submit = function() vim.g.ferry_sub = 1 end, hide = function() end }; return 1 end)()')" >/dev/null
ask "luaeval('require\"ferry.note\".submit()')" >/dev/null
check "Submit during the hold: flow-state waiting, one stop" "waiting|-g wispr-flow://stop-hands-free" \
  "$("$host" flow-state)|$(opened_wait)"
paste "held"
check "after the Submit's paste: submitted, flow-state stopped, no other URL" "1 stopped " \
  "$(ask 'get(g:, "ferry_sub", 0)') $("$host" flow-state) $(opened)"
ask "luaeval('(function() local n = require\"ferry.note\"; n.host = n.default_host; return 1 end)()')" >/dev/null

# A server holding the API-3 note module (and a flow module from before
# hold to talk) reloads both on talk, keeping the draft and its target.
u=$("$host" show com.example.app 4242)
ask "nvim_buf_set_lines(0, 0, -1, v:false, ['upgrade draft'])" >/dev/null
"$host" draft >/dev/null
ask "luaeval('(function() require\"ferry.note\".api = 3; local f = require\"ferry.flow\"; f.api = nil; f.adopt_start = nil; return 1 end)()')" >/dev/null
check "API-3 server: talk reloads note (current api) and flow (api 6), keeps the draft and its target" \
  "talk $u $napi 6 upgrade draft com.example.app 4242 true" \
  "$("$host" talk) $(lua 'require"ferry.note".api') $(lua 'require"ferry.flow".api') $(ask 'join(getline(1, "$"), "|")') $(ask 'b:ferry.target." ".b:ferry.window') $(rec)"
check "API-3 server: release after the upgrade sends one stop" "released|-g wispr-flow://stop-hands-free" \
  "$("$host" release)|$(opened_wait)"
paste " done"
"$host" stop

# Live upgrade from main 1dd6f9b (note api 8, notes as raw scratch files in
# ${TMPDIR}/ferry-notes): a server started from that commit's tree keeps
# running while the tree under it moves to this code. The next call reloads
# note to the current api, keeps the draft (text and target, without its to: line), and
# the draft gets a note file in the notes folder on its next change. The
# old scratch file is left as it was.
body() { ask 'join(getline(1, "$"), "|")'; }
upgrade() { cp -R "$root/lua" "$root/bin" "$1/"; }
old_tree() { mkdir -p "$2"; git -C "$root" archive "$1" | tar -x -C "$2"; } # <commit> <dir>
live=$work/live; old_tree 1dd6f9b "$live"
FERRY_NOTES_DIR=$work/oldnotes "$live/bin/ferry-host" ensure >/dev/null
FERRY_NOTES_DIR=$work/oldnotes "$live/bin/ferry-host" show com.example.app 4242 >/dev/null
ask "nvim_buf_set_lines(0, 1, -1, v:false, ['api 8 draft'])" >/dev/null
old=$(FERRY_NOTES_DIR=$work/oldnotes "$live/bin/ferry-host" draft)
check "1dd6f9b server: note api 8, raw draft file in the old folder" "8 $work/oldnotes to: app:com.example.app#4242|api 8 draft" \
  "$(lua 'require"ferry.note".api') $(dirname "$old") $(command paste -sd'|' - <"$old")"
upgrade "$live"
mkdir -p "$FERRY_NOTES_DIR"; before=$(ls "$FERRY_NOTES_DIR" | wc -l | tr -d ' ')
new=$("$live/bin/ferry-host" show com.example.app 4242)
check "upgrade from api 8: show reloads to the current api, keeps the draft without its to: line and the target, names a note file in the notes folder" \
  "$napi api 8 draft com.example.app 4242 yes" \
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

# Live upgrade from 901e856 (note api 9, H3: note files) and from 3f82b91
# (note api 10, P5): neither keeps a record of ferry's last write. The next
# call reloads note to the current api and keeps the draft (without its to: line) and its
# file. Its file counts
# as ferry's, so the next change saves to the same file; from then on an
# outside edit with typing forks to a conflict file.
conflicts() { ls "$FERRY_NOTES_DIR" | grep -c '\.conflict-'; }
for old in "901e856 9" "3f82b91 10"; do
  read -r rev n <<<"$old"
  live=$work/live-$rev; old_tree "$rev" "$live"
  "$live/bin/ferry-host" ensure >/dev/null
  p9=$("$live/bin/ferry-host" show com.example.app 4242)
  ask "nvim_buf_set_lines(0, 1, -1, v:false, ['api $n draft'])" >/dev/null
  "$live/bin/ferry-host" draft >/dev/null
  c0=$(conflicts)
  check "$rev server: note api $n, the draft's file written" "$n draft api $n draft" \
    "$(lua 'require"ferry.note".api') $(fkey "$p9" state) $(fbody "$p9")"
  upgrade "$live"
  check "upgrade from api $n: show reloads to the current api, keeps the draft without its to: line, and its file" \
    "$p9 $napi api $n draft com.example.app 4242" \
    "$("$live/bin/ferry-host" show com.example.app 4242) $(lua 'require"ferry.note".api') $(body) $(ask 'b:ferry.target." ".b:ferry.window')"
  ask "nvim_input('<Esc>A kept')" >/dev/null
  sleep 1.5
  check "upgrade from api $n: the next change saves to the same file, no conflict file" \
    "draft api $n draft kept $c0" "$(fkey "$p9" state) $(fbody "$p9") $(conflicts)"
  perl -pi -e "s/^api $n draft kept\$/edited outside/" "$p9"
  ask "nvim_input(' more')" >/dev/null
  sleep 1.5
  cf9=$(ls "$FERRY_NOTES_DIR"/"$(basename "$p9" .md)".conflict-*.md 2>/dev/null)
  check "upgrade from api $n: then an outside edit + typing keeps both (file, conflict file)" \
    "edited outside|api $n draft kept more $((c0 + 1))" "$(fbody "$p9")|$(fbody "$cf9") $(conflicts)"
  "$live/bin/ferry-host" stop
done

# Live upgrade from 9ac5f89 (note api 11, T2-T4: the to: header on line 1):
# the next show reloads note to the current api and drops the header from the draft; the
# text stays, the cursor stays on the same text, and the file keeps its
# target. Ctrl-X then sends the whole buffer to the captured target.
live=$work/live-api11; old_tree 9ac5f89 "$live"
"$live/bin/ferry-host" ensure >/dev/null
p11=$("$live/bin/ferry-host" show com.example.app 4242)
ask "nvim_buf_set_lines(0, 1, -1, v:false, ['api 11 draft', 'second'])" >/dev/null
ask "nvim_win_set_cursor(0, [3, 3])" >/dev/null
"$live/bin/ferry-host" draft >/dev/null
check "9ac5f89 server: note api 11, a to: header above the draft, the file stores its target" \
  "11 to: app:com.example.app#4242|api 11 draft|second draft app:com.example.app#4242 api 11 draft|second" \
  "$(lua 'require"ferry.note".api') $(body) $(fkey "$p11" state) $(fkey "$p11" target) $(fbody "$p11" | command paste -sd'|' -)"
upgrade "$live"
check "upgrade from api 11: show reloads to the current api, only the body is left, cursor on the same text" \
  "$p11 $napi api 11 draft|second 2:3 i" \
  "$("$live/bin/ferry-host" show com.example.app 4242) $(lua 'require"ferry.note".api') $(body) $(cur)"
ask "nvim_input('<Esc>A!')" >/dev/null
sleep 1.5
check "upgrade from api 11: the next save keeps the target in the file, the body without the to: line" \
  "draft app:com.example.app#4242 api 11 draft|second!" \
  "$(fkey "$p11" state) $(fkey "$p11" target) $(fbody "$p11" | command paste -sd'|' -)"
ask "luaeval('(function() require\"ferry.note\".host = { submit = function(p) vim.g.ferry_sub = p.target .. \" \" .. p.window .. \" \" .. table.concat(vim.fn.readfile(p.file), \"|\") end, hide = function() end }; return 1 end)()')" >/dev/null
ask "luaeval('require\"ferry.note\".submit()')" >/dev/null
check "upgrade from api 11: Submit sends the whole buffer to the captured target" \
  "com.example.app 4242 api 11 draft|second!" "$(ask 'get(g:, "ferry_sub", "")')"
"$live/bin/ferry-host" stop

# Live upgrade from af9efd3 (note api 12, flow api 5): the next show
# reloads note to the current api and flow to 6 (Q1, Q2c), keeping the draft.
live=$work/live-api12; old_tree af9efd3 "$live"
"$live/bin/ferry-host" ensure >/dev/null
p12=$("$live/bin/ferry-host" show com.example.app 4242)
ask "nvim_buf_set_lines(0, 0, -1, v:false, ['api 12 draft'])" >/dev/null
"$live/bin/ferry-host" draft >/dev/null
check "af9efd3 server: note api 12, flow api 5" "12 5" "$(lua 'require"ferry.note".api') $(lua 'require"ferry.flow".api')"
upgrade "$live"
check "upgrade from api 12: show reloads note to the current api and flow to 6, keeps the draft and its target" \
  "$p12 $napi 6 api 12 draft com.example.app 4242" \
  "$("$live/bin/ferry-host" show com.example.app 4242) $(lua 'require"ferry.note".api') $(lua 'require"ferry.flow".api') $(body) $(ask 'b:ferry.target." ".b:ferry.window')"
"$live/bin/ferry-host" stop

# Live upgrade from 57e7b8c (main at H5: note api 14, flow api 5, history
# api 4): the next show reloads note to the current api, flow to 6 and
# history to the current api, keeping the draft.
live=$work/live-api14; old_tree 57e7b8c "$live"
"$live/bin/ferry-host" ensure >/dev/null
p14=$("$live/bin/ferry-host" show com.example.app 4242)
ask "nvim_buf_set_lines(0, 0, -1, v:false, ['api 14 draft'])" >/dev/null
"$live/bin/ferry-host" draft >/dev/null
check "57e7b8c server: note api 14, flow api 5, history api 4" "14 5 4" "$(lua 'require"ferry.note".api') $(lua 'require"ferry.flow".api') $(lua 'require"ferry.history".api')"
upgrade "$live"
check "upgrade from api 14: show reloads note to the current api, flow to 6 and history to the current api, keeps the draft and its target" \
  "$p14 $napi 6 $hapi api 14 draft com.example.app 4242" \
  "$("$live/bin/ferry-host" show com.example.app 4242) $(lua 'require"ferry.note".api') $(lua 'require"ferry.flow".api') $(lua 'require"ferry.history".api') $(body) $(ask 'b:ferry.target." ".b:ferry.window')"
"$live/bin/ferry-host" stop

# Live upgrade from af9efd3 with the history sidebar open (history api 2:
# rows of the old history database, <CR> inserts, p sends): the reload to
# the current history api rebinds the open sidebar's keys and lists it
# again from the notes index, so <CR> opens a note file.
# One row in the old database (its sessions table), which the af9efd3
# sidebar lists.
python3 - "$FERRY_DB" <<'PY'
import sqlite3, sys
from datetime import datetime, timezone
con = sqlite3.connect(sys.argv[1])
con.execute("CREATE TABLE IF NOT EXISTS sessions (id TEXT PRIMARY KEY, started_at TEXT NOT NULL,"
            " ended_at TEXT, target TEXT, seed_text TEXT, final_text TEXT, outcome TEXT NOT NULL)")
now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
con.execute("INSERT INTO sessions VALUES (?,?,?,?,?,?,?)",
            ("hist-row", now, now, "com.example.app", "", "hist one\nhist two\n", "submitted"))
con.commit()
PY
mkdir -p "$FERRY_NOTES_DIR"
hfile=$FERRY_NOTES_DIR/2026-10-01-090000-0f0f0f0f.md
printf -- '---\nid: 0f0f0f0f-0000-4000-8000-000000000000\nstate: sent\nupdated: 2026-10-01T09:00:00-07:00\ntarget: app:com.example.app\n---\nhist file\n' >"$hfile"
"$root/bin/ferry-notes" index "$hfile"
# How many of the sidebar's own keys call the loaded history module, and
# whether an old p key is left.
cat >"$work/hkeys.lua" <<'EOF'
local h = require("ferry.history")
local want = { ["<CR>"] = h.open_note, s = h.send, y = h.yank, P = h.pin, d = h.delete, K = h.preview,
  i = h.insert, ["/"] = h.search, R = h.reset, ["<Tab>"] = h.focus_main, q = h.close,
  ["<Esc>"] = h.close_preview }
local n, p = 0, 0
for _, m in ipairs(vim.api.nvim_buf_get_keymap(h.state.buf, "n")) do
  if want[m.lhs] and m.callback == want[m.lhs] then n = n + 1 end
  if m.lhs == "p" then p = p + 1 end
end
return n .. " p=" .. p
EOF
# <CR> on the hist file row; returns the current note's file name.
cat >"$work/hopen.lua" <<'EOF'
local h = require("ferry.history")
vim.api.nvim_set_current_win(h.state.win)
for ln, l in ipairs(vim.api.nvim_buf_get_lines(h.state.buf, 0, -1, false)) do
  if l:find("hist file", 1, true) then vim.api.nvim_win_set_cursor(h.state.win, { ln, 0 }) end
end
vim.api.nvim_feedkeys(vim.keycode("<CR>"), "mx", false)
return vim.fn.fnamemodify(require("ferry.note").current().path, ":t") .. " " .. vim.fn.getline(1)
EOF
live=$work/live-hist; old_tree af9efd3 "$live"
"$live/bin/ferry-host" ensure >/dev/null
"$live/bin/ferry-host" show com.example.app 4242 >/dev/null
check "af9efd3 server: the sidebar is open under history api 2, listing the old database's rows" "2 true true" \
  "$(lua 'require"ferry.history".api') $(lua 'require"ferry.history".is_open()') $(lua 'vim.fn.join(vim.api.nvim_buf_get_lines(require"ferry.history".state.buf, 0, -1, false)):find("hist one", 1, true) ~= nil')"
upgrade "$live"
"$live/bin/ferry-host" show com.example.app 4242 >/dev/null
ask "nvim_input('<Esc>')" >/dev/null; sleep 0.3
check "upgrade from history api 2: the open sidebar's 12 keys call the current history api, no p" "$hapi 12 p=0" \
  "$(lua 'require"ferry.history".api') $(ask "luaeval('dofile(\"$work/hkeys.lua\")')")"
check "upgrade from history api 2: the open sidebar lists the notes index" "true false" \
  "$(lua 'vim.fn.join(vim.api.nvim_buf_get_lines(require"ferry.history".state.buf, 0, -1, false)):find("hist file", 1, true) ~= nil') $(lua 'vim.fn.join(vim.api.nvim_buf_get_lines(require"ferry.history".state.buf, 0, -1, false)):find("hist one", 1, true) ~= nil')"
check "upgrade from history api 2: <CR> opens the note file as the current note" \
  "$(basename "$hfile") hist file" "$(ask "luaeval('dofile(\"$work/hopen.lua\")')")"
"$live/bin/ferry-host" stop
rm -f "$hfile"; "$root/bin/ferry-notes" index "$hfile"

# Live upgrade from 20f9461 (H4: note api 13, history api 3, the old
# history database still written) with the sidebar open and unsaved typing,
# as Joe's server runs: the next show reloads note and history, keeps the
# text, rebinds the sidebar's keys (/ searches), and nothing writes the old
# database from then on.
kfile=$FERRY_NOTES_DIR/2026-10-02-090000-0e0e0e0e.md
printf -- '---\nid: 0e0e0e0e-0000-4000-8000-000000000000\nstate: sent\nupdated: 2026-10-02T09:00:00-07:00\ntarget: app:com.example.app\n---\nkubernetes upgrade note\n' >"$kfile"
"$root/bin/ferry-notes" index "$kfile"
live=$work/live-h4; old_tree 20f9461 "$live"
"$live/bin/ferry-host" ensure >/dev/null
p13=$("$live/bin/ferry-host" show com.example.app 4242)
ask "nvim_input('typed under api 13')" >/dev/null
sleep 0.5
check "20f9461 server: note api 13, history api 3, the sidebar open, the typing in the note" \
  "13 3 true typed under api 13" \
  "$(lua 'require"ferry.note".api') $(lua 'require"ferry.history".api') $(lua 'require"ferry.history".is_open()') $(body)"
dbsum=$(shasum "$FERRY_DB" | cut -d' ' -f1)
upgrade "$live"
check "upgrade from note api 13: show reloads note and history, same note, the typing kept" \
  "$p13 $napi $hapi typed under api 13" \
  "$("$live/bin/ferry-host" show com.example.app 4242) $(lua 'require"ferry.note".api') $(lua 'require"ferry.history".api') $(body)"
ask "nvim_input('<Esc>')" >/dev/null; sleep 0.3
check "upgrade from history api 3: the open sidebar's 12 keys call the current history api, no error" "12 p=0 " \
  "$(ask "luaeval('dofile(\"$work/hkeys.lua\")')") $(ask 'v:errmsg')"
ask "nvim_input('<Cmd>lua vim.api.nvim_set_current_win(require\"ferry.history\".state.win)<CR>/kubernetes<CR>')" >/dev/null
sleep 0.3
check "upgrade from history api 3: / in the open sidebar lists only the matching note" \
  "/kubernetes 1 kubernetes upgrade" \
  "$(lua 'vim.api.nvim_buf_get_lines(require"ferry.history".state.buf, 0, 1, false)[1]') $(lua 'vim.tbl_count(require"ferry.history".state.map)') $(lua 'require"ferry.history".state.rows[1].preview:sub(1, 18)')"
ask "luaeval('(function() require\"ferry.note\".host = { submit = function(p) vim.g.ferry_sub = table.concat(vim.fn.readfile(p.file), \"|\") end, hide = function() end }; return 1 end)()')" >/dev/null
ask "luaeval('require\"ferry.note\".submit(require\"ferry.note\".current().buf)')" >/dev/null
sleep 0.5
check "upgrade from note api 13: Submit sends the typing, the file says sent, the old database is unchanged" \
  "typed under api 13 sent typed under api 13 $dbsum" \
  "$(ask 'get(g:, "ferry_sub", "")') $(fkey "$p13" state) $(fbody "$p13") $(shasum "$FERRY_DB" | cut -d' ' -f1)"
"$live/bin/ferry-host" stop
rm -f "$kfile"; "$root/bin/ferry-notes" index "$kfile"

# Live upgrade from e2d0ac0 (H8 on main: note api 17, history api 5, the
# open note left out of the sidebar) with the sidebar open and a saved
# draft, as Joe's server runs: the next show reloads note and history, and
# the open sidebar lists the open note marked ▶, with its keys rebound; a
# later save updates that row.
# The sidebar's line holding $1, cut to its first character (the ▶ column),
# and how many lines are marked ▶.
hmark() { lua "(function() local n = 0; local m = \"none\"; for _, l in ipairs(vim.api.nvim_buf_get_lines(require\"ferry.history\".state.buf, 0, -1, false)) do if vim.startswith(l, \"▶\") then n = n + 1 end; if l:find(\"$1\", 1, true) then m = vim.fn.strcharpart(l, 0, 1) end end; return m .. \" \" .. n end)()"; }
live=$work/live-h8; old_tree e2d0ac0 "$live"
"$live/bin/ferry-host" ensure >/dev/null
p17=$("$live/bin/ferry-host" show com.example.app 4242)
ask "nvim_buf_set_lines(0, 0, -1, v:false, ['api 17 draft'])" >/dev/null
"$live/bin/ferry-host" draft >/dev/null
ask "luaeval('require\"ferry.history\".refresh()')" >/dev/null
check "e2d0ac0 server: note api 17, history api 5, the sidebar open, the draft's file written, its row left out" \
  "17 5 true draft none 0" \
  "$(lua 'require"ferry.note".api') $(lua 'require"ferry.history".api') $(lua 'require"ferry.history".is_open()') $(fkey "$p17" state) $(hmark 'api 17 draft')"
upgrade "$live"
check "upgrade from note api 17: show reloads note and history, same note" "$p17 $napi $hapi" \
  "$("$live/bin/ferry-host" show com.example.app 4242) $(lua 'require"ferry.note".api') $(lua 'require"ferry.history".api')"
ask 1 >/dev/null; sleep 0.3; ask 1 >/dev/null
check "upgrade from history api 5: the open sidebar lists the open note marked ▶, its 12 keys rebound" \
  "▶ 1 12 p=0" "$(hmark 'api 17 draft') $(ask "luaeval('dofile(\"$work/hkeys.lua\")')")"
ask "nvim_buf_set_lines(0, 0, -1, v:false, ['api 17 edited'])" >/dev/null
"$live/bin/ferry-host" draft >/dev/null
for _ in $(seq 40); do [ "$(hmark 'api 17 edited')" = "▶ 1" ] && break; sleep 0.05; done
check "upgrade from note api 17: a save updates the open note's row" "▶ 1 none 1" \
  "$(hmark 'api 17 edited') $(hmark 'api 17 draft')"
"$live/bin/ferry-host" stop

# Live upgrade from cb1dd2f (H9 on main: note api 18, fix-ups not wired):
# the draft's buffer has no fix-up keys and no :Corrections; the next show
# reloads note and the same buffer gains them, and :FixJoin works there.
live=$work/live-h9; old_tree cb1dd2f "$live"
"$live/bin/ferry-host" ensure >/dev/null
p18=$("$live/bin/ferry-host" show com.example.app 4242)
ask "nvim_buf_set_lines(0, 0, -1, v:false, ['hello', 'world'])" >/dev/null
"$live/bin/ferry-host" draft >/dev/null
fixmaps() { ask 'maparg("<leader>fj", "n")."|".maparg("<leader>ff", "x")."|".!empty(maparg("<leader>fw", "n", 0, 1))."|".exists(":FixJoin")."|".exists(":Corrections")'; }
check "cb1dd2f server: note api 18, no fix-up keys or :Corrections in the note" "18 ||0|0|0" \
  "$(lua 'require"ferry.note".api') $(fixmaps)"
upgrade "$live"
check "upgrade from note api 18: show reloads note, same note and buffer text" "$p18 $napi hello|world" \
  "$("$live/bin/ferry-host" show com.example.app 4242) $(lua 'require"ferry.note".api') $(body)"
check "upgrade from note api 18: the note gains <leader>fj, ff, fw, :FixJoin and :Corrections" \
  "<Cmd>FixJoin<CR>|:FixFillers<CR>|1|2|2" "$(fixmaps)"
ask "execute('FixJoin')" >/dev/null
check "upgrade from note api 18: :FixJoin on hello/world gives one line" "hello world" "$(body)"
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
