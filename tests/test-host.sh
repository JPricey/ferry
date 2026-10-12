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
check "seed text is in the buffer, mode i" "selected text|second line i" \
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
ask "luaeval('(function() local n = require\"voice-vim.note\"; n.api = 1; n.old = true; vim.g.voicevim_gui = nil; vim.cmd(\"vsplit | split\"); return 1 end)()')" >/dev/null
"$host" draft >/dev/null
h=$("$host" show com.example.app 4242)
check "old server: show reloads the note module and keeps the draft" "2 true $g" \
  "$(ask 'luaeval("require\"voice-vim.note\".api")') $(ask 'luaeval("require\"voice-vim.note\".old == nil")') $h"
check "old server: show applies the layout" "history $(basename "$g")" "$(wins)"
check "old server: show loads the GUI settings" "{'bg': '#001e27', 'font': 'Test Mono:h13'}" "$(ask 'string(g:voicevim_gui)')"
"$host" stop

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

exit $fail
