#!/usr/bin/env bash
# bin/voice-vim-host and lua/voice-vim/note.lua against headless nvim
# servers on a temp socket (--clean). Never touches Joe's server, the real
# history database or the real notes folder.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
host="$root/bin/voice-vim-host"
# macOS socket paths max out at 104 bytes, so keep the folder short.
work=$(mktemp -d /tmp/vvh.XXXX)
[ -n "$work" ] && [ -d "$work" ] || { echo "mktemp failed" >&2; exit 1; }
export VOICE_VIM_SOCK=$work/host.sock VOICE_VIM_NOTES_DIR=$work/notes \
  VOICE_VIM_DB=$work/history.sqlite VOICE_VIM_HOST_NVIM_FLAGS=--clean
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want '$2' got '$3'"; fail=1; fi; }
ask() { nvim --server "$VOICE_VIM_SOCK" --remote-expr "$1" 2>&1; }
servers() { pgrep -f -- "--listen $VOICE_VIM_SOCK" | wc -l | tr -d ' '; }
gone() { test -e "$VOICE_VIM_SOCK" && echo present || echo gone; }
cleanup() {
  pkill -f -- "--listen $work/" 2>/dev/null
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
printf 'hi clear\nhi Normal guifg=#839496 guibg=NONE\nlet g:colors_name = "vvtest"\n' >"$work/colors/vvtest.vim"

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
  "$(case $a in "$VOICE_VIM_NOTES_DIR"/*.md) echo yes ;; *) echo "no ($a)" ;; esac)"
check "after show com.example.app 4242: mode i, filetype markdown" "i markdown" "$(ask 'mode()." ".&filetype')"
check "b:voicevim.target and .window are set" "com.example.app 4242" "$(ask 'b:voicevim.target." ".b:voicevim.window')"
check "b:voicevim.id is a uuid and names the file" "yes yes" \
  "$(ask 'b:voicevim.id' | grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' && echo yes) $(test "$(basename "$a" .md)" = "$(ask 'b:voicevim.id')" && echo yes)"
check "note has the voice-vim buffer options" "1 1 0 0 en_us" \
  "$(ask '&l:spell." ".&l:wrap." ".&l:number." ".&l:swapfile." ".&l:spelllang')"
check "<D-v> pastes the + register in insert mode" "<C-R><C-O>+" "$(ask "maparg('<D-v>', 'i')" | cut -c1-11)"

# --- draft ------------------------------------------------------------------
ask "nvim_buf_set_lines(0, 0, -1, v:false, ['hello', 'from the host'])" >/dev/null
d=$("$host" draft)
check "draft prints the note path" "$a" "$d"
check "draft writes the file" "hello
from the host" "$(cat "$a" 2>&1)"
check "draft sets g:voicevim_draft" "$a" "$(ask 'g:voicevim_draft')"
check "draft leaves insert mode" n "$(ask 'mode()')"

# --- resume ---------------------------------------------------------------
b=$("$host" show com.other.app 99)
check "next unseeded show returns the same path" "$a" "$b"
check "resumed note keeps its text, is in insert mode" "hello|from the host i" \
  "$(ask 'join(getline(1, "$"), "|")." ".mode()')"
check "resumed note takes the new target" "com.other.app 99" "$(ask 'b:voicevim.target." ".b:voicevim.window')"
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
check "b:voicevim.seed holds the seed text" "selected text|second line" "$(ask 'substitute(b:voicevim.seed, "\n", "|", "g")')"
check "switching to a seeded note saves the previous one" "edited after draft" "$(cat "$a" 2>&1)"
check "next unseeded show resumes the seeded note" "$c" "$("$host" show com.example.app 4242)"

# --- reuse of an existing server -------------------------------------------
"$host" stop
check "stop removes the socket and the server" "gone 0" "$(gone) $(servers)"
check "status prints down after stop" down "$("$host" status)"

nvim --headless --clean --listen "$VOICE_VIM_SOCK" </dev/null >/dev/null 2>&1 &
own=$!
for _ in $(seq 100); do [ "$(ask 1)" = 1 ] && break; sleep 0.05; done
"$host" ensure >/dev/null
e=$("$host" show com.example.app 4242)
check "ensure reuses an existing server and show works in it" "1 $own i com.example.app" \
  "$(servers) $(ask 'getpid()') $(ask 'mode()') $(ask 'b:voicevim.target')"
check "show on the reused server opens a fresh note" yes "$(test -n "$e" && echo yes)"
"$host" stop
for _ in $(seq 100); do kill -0 "$own" 2>/dev/null || break; sleep 0.05; done
kill -0 "$own" 2>/dev/null && { echo "FAIL stop did not quit the reused server"; fail=1; kill "$own"; }
wait "$own" 2>/dev/null
check "stop quits the reused server and removes the socket" "0 gone" "$(servers) $(gone)"

check "attach-cmd prints the remote-ui command" yes \
  "$(case $("$host" attach-cmd) in *"nvim --server $VOICE_VIM_SOCK --remote-ui") echo yes ;; *) echo no ;; esac)"

# --- layout: the note and the history sidebar, nothing else ---------------
wins() { ask 'join(map(range(1, winnr("$")), "fnamemodify(bufname(winbufnr(v:val)), \":t\")"), " ")'; }
"$host" ensure >/dev/null
check "ensure reads the GUI settings from ghostty" "{'bg': '#001e27', 'font': 'Test Mono:h13'}" "$(ask 'string(g:voicevim_gui)')"
ask "execute('vsplit | split | vnew | setlocal buftype=nofile | file FakeTree')" >/dev/null
f=$("$host" show com.example.app 4242)
check "show closes extra splits and a file tree: sidebar left, note right" "history $(basename "$f")" "$(wins)"
check "after show the note window is current, in insert mode" "$f i" "$(ask 'expand("%:p")') $(ask 'mode()')"
ask "execute('vsplit')" >/dev/null
"$host" show com.example.app 4242 >/dev/null
check "a second show keeps the sidebar and drops the new split" "history $(basename "$f")" "$(wins)"
nvim --server "$VOICE_VIM_SOCK" --remote-send '<Esc>:wincmd t<CR>'
for _ in $(seq 100); do [ "$(ask 'expand("%:t")')" = history ] && break; sleep 0.05; done
nvim --server "$VOICE_VIM_SOCK" --remote-send '<Tab>'
for _ in $(seq 100); do [ "$(ask 'expand("%:t")')" = "$(basename "$f")" ] && break; sleep 0.05; done
check "<Tab> in the sidebar jumps back to the note" "$(basename "$f")" "$(ask 'expand("%:t")')"
check "VOICE_VIM_SIDEBAR=0: show leaves only the note" "$(basename "$f")" \
  "$(VOICE_VIM_SIDEBAR=0 "$host" show com.example.app 4242 >/dev/null; wins)"

# --- GUI appearance ------------------------------------------------------------
bg() { ask "synIDattr(synIDtrans(hlID('Normal')), 'bg#', 'gui')"; }
ask "execute('set rtp+=$work | colorscheme vvtest')" >/dev/null
"$host" show com.example.app 4242 >/dev/null
check "without a GUI: guifont and Normal guibg untouched" "'' ''" "'$(ask '&guifont')' '$(bg)'"
ask "execute('colorscheme vvtest')" >/dev/null
check "without a GUI: a ColorScheme leaves Normal without guibg" "''" "'$(bg)'"
ask "execute('let g:neovide = v:true | doautocmd UIEnter')" >/dev/null
check "GUI attached: guifont from Ghostty" "Test Mono:h13" "$(ask '&guifont')"
check "GUI attached: Normal gets Ghostty's background" "#001e27" "$(bg)"
check "GUI attached: Normal keeps its guifg" "#839496" "$(ask "synIDattr(synIDtrans(hlID('Normal')), 'fg#', 'gui')")"
ask "execute('colorscheme vvtest')" >/dev/null
check "after a colorscheme change the background is re-applied" "#001e27" "$(bg)"
ask "execute('highlight Normal guibg=#123456 | doautocmd UIEnter')" >/dev/null
check "an existing Normal guibg is left alone" "#123456" "$(bg)"

# --- a server started before this change gets layout and GUI on show ---------
g=$("$host" show com.example.app 4242)
ask "luaeval('(function() local n = require\"voice-vim.note\"; n.api = 7; n.old = true; vim.g.voicevim_gui = nil; vim.cmd(\"vsplit | split\"); return 1 end)()')" >/dev/null
"$host" draft >/dev/null
h=$("$host" show com.example.app 4242)
check "old server (note api 7): show reloads the note module to 8 and keeps the draft" "8 true $g" \
  "$(ask 'luaeval("require\"voice-vim.note\".api")') $(ask 'luaeval("require\"voice-vim.note\".old == nil")') $h"
check "old server: show applies the layout" "history $(basename "$g")" "$(wins)"
check "old server: show loads the GUI settings" "{'bg': '#001e27', 'font': 'Test Mono:h13'}" "$(ask 'string(g:voicevim_gui)')"

# --- hold to talk: show --talk, talk, release ----------------------------------
lua() { ask "luaeval('tostring($1)')"; }
rec() { lua 'require"voice-vim.flow".recording()'; }
cur() { ask 'line(".").":".(col(".") - 1)." ".mode()'; }
opened() { cat "$work/open.log" 2>/dev/null; rm -f "$work/open.log"; }
# Flow's paste into the note (a bracketed paste reaches nvim as vim.paste),
# then wait for flow's release wait to end.
paste() {
  ask "luaeval('vim.paste({\"$1\"}, -1)')" >/dev/null
  for _ in $(seq 100); do [ "$(lua 'require"voice-vim.flow".state.waiting')" = nil ] && break; sleep 0.05; done
}
rm -f "$work/open.log"
ask "luaeval('require\"voice-vim.note\".forget()')" >/dev/null
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
  "talk $t 2:5 i true $t" "$("$host" talk) $(cur) $(rec) $(ask 'g:voicevim_draft')"
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
ask "luaeval('require\"voice-vim.note\".forget()')" >/dev/null
check "talk without a note prints no note, Flow untouched" "no note false " "$("$host" talk) $(rec) $(opened)"
check "flow-state while idle prints idle; release --force prints forced, one stop, then waiting" \
  "idle forced waiting|-g wispr-flow://stop-hands-free" \
  "$("$host" flow-state) $("$host" release --force) $("$host" flow-state)|$(sleep 0.3; opened)"
paste "forced"
ask "luaeval('require\"voice-vim.flow\".assume_recording()')" >/dev/null
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
ask "luaeval('(function() require\"voice-vim.note\".api = 3; local f = require\"voice-vim.flow\"; f.api = nil; f.adopt_start = nil; return 1 end)()')" >/dev/null
check "API-3 server: talk reloads note (api 8) and flow (api 4), keeps the draft and its target" \
  "talk $u 8 4 to: app:com.example.app#4242|upgrade draft com.example.app 4242 true" \
  "$("$host" talk) $(lua 'require"voice-vim.note".api') $(lua 'require"voice-vim.flow".api') $(ask 'join(getline(1, "$"), "|")') $(ask 'b:voicevim.target." ".b:voicevim.window') $(rec)"
check "API-3 server: release after the upgrade sends one stop" "released|-g wispr-flow://stop-hands-free" \
  "$("$host" release)|$(sleep 0.3; opened)"
paste " done"
"$host" stop

# Live upgrade from main 54d10b6 (note api 5, flow api 2, history api 1): a
# server started from that code keeps running while the repo under it moves
# to this code (note 8, flow 4). The next host call reloads both modules.
# Draft, target and to: line are kept, a recording in progress and a pending
# release wait survive, each release sends exactly one stop, and a paste the
# old and the new paste hook both report counts once.
waiting() { lua 'require"voice-vim.flow".state.waiting ~= nil'; }
vpaste() { ask "luaeval('vim.paste({\"$1\"}, -1)')" >/dev/null; sleep 0.4; }
apis() { echo "$(lua 'require"voice-vim.note".api') $(lua 'require"voice-vim.flow".api')"; }
body() { ask 'join(getline(1, "$"), "|")'; }
old_server() { # dir: 54d10b6's tree there, its host shows a note with a draft
  mkdir -p "$1"; git -C "$root" archive 54d10b6 | tar -x -C "$1"
  "$1/bin/voice-vim-host" ensure >/dev/null
  "$1/bin/voice-vim-host" show com.example.app 4242 >/dev/null
  ask "nvim_buf_set_lines(0, 1, -1, v:false, ['live draft'])" >/dev/null
  "$1/bin/voice-vim-host" draft >/dev/null
  check "54d10b6 server: note api 5, flow api 2" "5 2" "$(apis)"
}
upgrade() { cp -R "$root/lua" "$root/bin" "$1/"; }
opened >/dev/null

# A recording in progress at the upgrade.
live=$work/live1; old_server "$live"
"$live/bin/voice-vim-host" talk >/dev/null
upgrade "$live"
check "upgrade with a recording: release reloads to note 8, flow 4, keeps draft, to: line and target, one stop" \
  "released 8 4 to: app:com.example.app#4242|live draft com.example.app 4242 true|-g wispr-flow://stop-hands-free" \
  "$("$live/bin/voice-vim-host" release) $(apis) $(body) $(ask 'b:voicevim.target." ".b:voicevim.window') $(waiting)|$(sleep 0.3; opened)"
# A quick second hold during that wait: the new talk adds the new paste hook
# beside the old one, so the first paste is reported twice.
"$live/bin/voice-vim-host" talk >/dev/null
check "upgrade: a quick second hold's release sends one stop" "released|-g wispr-flow://stop-hands-free" \
  "$("$live/bin/voice-vim-host" release)|$(sleep 0.3; opened)"
vpaste " one"
check "upgrade: the first paste, reported by both hooks, counts once (still waiting for the second)" \
  "true false" "$(waiting) $(rec)"
# A third hold before the second paste: that paste ends the wait but must
# not clear the new recording (the old hook forwards to the new module).
"$live/bin/voice-vim-host" talk >/dev/null
vpaste " two"
check "upgrade: the second paste ends the wait and keeps the third hold recording" \
  "false true" "$(waiting) $(rec)"
check "upgrade: the third hold's release sends one stop" "released|-g wispr-flow://stop-hands-free" \
  "$("$live/bin/voice-vim-host" release)|$(sleep 0.3; opened)"
vpaste " three"
check "upgrade: the last paste ends its wait, each paste in the note once" \
  "false false 1 1 1" "$(waiting) $(rec) $(echo $(for w in one two three; do body | grep -o $w | grep -c .; done))"
"$live/bin/voice-vim-host" stop

# A pending release wait (the old module already sent its stop) at the upgrade.
live=$work/live2; old_server "$live"
"$live/bin/voice-vim-host" talk >/dev/null
"$live/bin/voice-vim-host" release >/dev/null
check "54d10b6 server: release sends one stop and waits" "true -g wispr-flow://stop-hands-free" \
  "$(waiting) $(sleep 0.3; opened)"
upgrade "$live"
check "upgrade with a pending release wait: release reloads, keeps draft and target, the wait, sends no second stop" \
  "released 8 4 to: app:com.example.app#4242|live draft com.example.app 4242 true " \
  "$("$live/bin/voice-vim-host" release) $(apis) $(body) $(ask 'b:voicevim.target." ".b:voicevim.window') $(waiting) $(sleep 0.3; opened)"
vpaste " landed"
check "upgrade: Flow's paste ends the old wait, lands once, recording off" \
  "false false 1" "$(waiting) $(rec) $(body | grep -o landed | grep -c .)"
"$live/bin/voice-vim-host" stop

# --- overrides and a missing or hung ghostty ------------------------------------
VOICE_VIM_GUI_FONT='Other Font:h15' VOICE_VIM_GUI_BG='#112233' "$host" ensure >/dev/null
check "VOICE_VIM_GUI_FONT and VOICE_VIM_GUI_BG win over Ghostty" "{'bg': '#112233', 'font': 'Other Font:h15'}" "$(ask 'string(g:voicevim_gui)')"
VOICE_VIM_GUI_FONT='Other Font:h15' "$host" ensure >/dev/null
check "a font override alone keeps Ghostty's background" "{'bg': '#001e27', 'font': 'Other Font:h15'}" "$(ask 'string(g:voicevim_gui)')"
"$host" stop
echo fail >"$work/ghostty.mode"
"$host" ensure >/dev/null
check "ghostty failing: ensure works, no GUI settings" "0 {'bg': '', 'font': ''}" "$? $(ask 'string(g:voicevim_gui)')"
"$host" stop
echo hang >"$work/ghostty.mode"
t0=$(date +%s)
"$host" ensure >/dev/null
check "ghostty hanging: ensure works within 4 s, no GUI settings" "0 yes {'bg': '', 'font': ''}" \
  "$? $([ $(($(date +%s) - t0)) -le 4 ] && echo yes) $(ask 'string(g:voicevim_gui)')"
"$host" stop
rm -f "$work/ghostty.mode"

# --- a config that resets the runtimepath, like lazy.nvim ----------------------
# Plain init: rtp is reset during startup, dropping `--cmd 'set rtp^=<repo>'`.
printf 'vim.opt.rtp = vim.env.VIMRUNTIME\n' >"$work/init.lua"
nvim --headless -u "$work/init.lua" --listen "$VOICE_VIM_SOCK" --cmd "set rtp^=$root" </dev/null >/dev/null 2>&1 &
for _ in $(seq 100); do [ "$(ask v:vim_did_enter)" = 1 ] && break; sleep 0.05; done
check "lazy-style init: the server lost the repo from its runtimepath" 0 "$(ask "index(nvim_list_runtime_paths(), '$root') >= 0")"
i=$("$host" show com.example.app 4242 2>&1)
check "lazy-style init: show works without a prior ensure" "yes i com.example.app" \
  "$(case $i in "$VOICE_VIM_NOTES_DIR"/*.md) echo yes ;; *) echo "no ($i)" ;; esac) $(ask 'mode()') $(ask 'b:voicevim.target')"
check "lazy-style init: show loads the GUI settings" "{'bg': '#001e27', 'font': 'Test Mono:h13'}" "$(ask 'string(g:voicevim_gui)')"
"$host" stop
nvim --headless -u "$work/init.lua" --listen "$VOICE_VIM_SOCK" </dev/null >/dev/null 2>&1 &
for _ in $(seq 100); do [ "$(ask v:vim_did_enter)" = 1 ] && break; sleep 0.05; done
check "lazy-style init: draft works without a prior ensure or show" "$VOICE_VIM_NOTES_DIR yes" \
  "$("$host" show com.example.app 4242 >/dev/null; d=$("$host" draft 2>&1); dirname "$d") $(test -n "$(ask 'g:voicevim_draft')" && echo yes)"
"$host" stop
# vim.wait lets the server answer requests mid-init, before the reset (as
# lazy can while it loads), so an ensure that does not wait for VimEnter
# fixes rtp too early.
printf 'vim.wait(1000)\nvim.opt.rtp = vim.env.VIMRUNTIME\n' >"$work/init.lua"
VOICE_VIM_HOST_NVIM_FLAGS="-u $work/init.lua" "$host" ensure >/dev/null
r=$?
for _ in $(seq 100); do [ "$(ask v:vim_did_enter)" = 1 ] && break; sleep 0.05; done
check "lazy-style init: after ensure on a fresh start and VimEnter the repo is on rtp" "0 1" \
  "$r $(ask "index(nvim_list_runtime_paths(), '$root') >= 0")"
j=$("$host" show com.example.app 4242 2>&1)
check "lazy-style init: ensure on a fresh start, then show works" "yes i" \
  "$(case $j in "$VOICE_VIM_NOTES_DIR"/*.md) echo yes ;; *) echo "no ($j)" ;; esac) $(ask 'mode()')"
"$host" stop
# VimEnter variant: the reset happens in a VimEnter autocmd.
printf 'vim.api.nvim_create_autocmd("VimEnter", { callback = function() vim.opt.rtp = vim.env.VIMRUNTIME end })\n' >"$work/init.lua"
VOICE_VIM_HOST_NVIM_FLAGS="-u $work/init.lua" "$host" ensure >/dev/null
k=$("$host" show com.example.app 4242 2>&1)
check "VimEnter rtp reset: ensure on a fresh start, then show works" "yes 1" \
  "$(case $k in "$VOICE_VIM_NOTES_DIR"/*.md) echo yes ;; *) echo "no ($k)" ;; esac) $(ask "index(nvim_list_runtime_paths(), '$root') >= 0")"
"$host" stop

exit $fail
