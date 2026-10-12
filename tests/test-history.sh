#!/usr/bin/env bash
# History: database helper and the Neovim sidebar.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export VOICE_VIM_DB=$(mktemp -t vv-hist-db).sqlite
db="$root/bin/voice-vim-db"
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want '$2' got '$3'"; fail=1; fi; }

# --- helper -------------------------------------------------------------
seed=$(mktemp -t vv-seed); printf 'seed text' > "$seed"
fin=$(mktemp -t vv-fin);   printf 'first line\nsecond line\n' > "$fin"
empty=$(mktemp -t vv-empty); : > "$empty"
"$db" start aaa com.google.Chrome "$seed"
"$db" start bbb com.googlecode.iterm2 "$empty"
"$db" start ccc com.mitchellh.ghostty "$empty"
check "open sessions hidden from list" "0" "$("$db" list | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))')"
"$db" finish aaa submitted "$fin"
"$db" finish bbb cancelled "$fin"
"$db" finish ccc cancelled "$empty"
check "listed after finish (empty cancel dropped)" "2" "$("$db" list | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))')"
check "newest first, preview is first line" "bbb first line iTerm2" "$("$db" list | python3 -c 'import json,sys;r=json.load(sys.stdin)[0];print(r["id"],r["preview"],r["app"])')"
check "exclude current session" "aaa" "$("$db" list --exclude bbb | python3 -c 'import json,sys;print(json.load(sys.stdin)[0]["id"])')"
check "get returns text" "first line
second line" "$("$db" get aaa | python3 -c 'import json,sys;print(json.load(sys.stdin)["text"].rstrip())')"
check "outcome recorded" "submitted cancelled" "$("$db" get aaa | python3 -c 'import json,sys;print(json.load(sys.stdin)["outcome"])') $("$db" get bbb | python3 -c 'import json,sys;print(json.load(sys.stdin)["outcome"])')"
# finish takes the target spec as an optional 5th argument; app labels read specs.
"$db" start spec1 com.tinyspeck.slackmacgap "$empty"
"$db" finish spec1 submitted "$fin" 'app:com.tinyspeck.slackmacgap#4242'
check "finish with a spec records it" "app:com.tinyspeck.slackmacgap#4242 Slack" "$("$db" get spec1 | python3 -c 'import json,sys;r=json.load(sys.stdin);print(r["target"],r["app"])')"
"$db" start spec2 x "$empty"; "$db" finish spec2 submitted "$fin" clipboard
"$db" start spec3 x "$empty"; "$db" finish spec3 submitted "$fin" 'tmux:default:%12'
"$db" start spec4 com.example.app "$empty"; "$db" finish spec4 submitted "$fin" ''
check "app labels: clipboard, tmux, no spec keeps the start target" "clipboard tmux app" \
  "$(for i in spec2 spec3 spec4; do "$db" get $i | python3 -c 'import json,sys;print(json.load(sys.stdin)["app"])'; done | paste -sd' ' -)"
for i in spec1 spec2 spec3 spec4; do "$db" delete $i; done
"$db" delete bbb
check "delete" "1" "$("$db" list | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))')"
check "VOICE_VIM_HISTORY=0 is a no-op" "1" "$(VOICE_VIM_HISTORY=0 "$db" start zzz x "$seed"; VOICE_VIM_HISTORY=0 "$db" finish zzz submitted "$fin"; "$db" list | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))')"

# --- sidebar in headless neovim, through the note -----------------------
# A note shown with a stub host opens the sidebar on its left. (Recording a
# submitted note is covered by tests/test-note.sh.)
notes=$(mktemp -d -t vv-hist-notes)
cat > "$notes/spec.lua" <<'LUA'
local root = arg[1]
vim.opt.rtp:prepend(root)
local note = require("voice-vim.note")
note.host = { submit = function() end, hide = function() end }
note.show({ target = "com.example.app", window = "4242" })
local h = require("voice-vim.history")
local lines = vim.api.nvim_buf_get_lines(h.state.buf, 0, -1, false)
local out = {}
out[#out + 1] = "WINS=" .. #vim.api.nvim_list_wins() .. " ROWS=" .. #h.state.rows .. " CUR="
  .. (vim.api.nvim_get_current_win() == h.state.main_win and "main" or "side")
out[#out + 1] = "LEFT=" .. tostring(vim.fn.win_screenpos(h.state.win)[2] < vim.fn.win_screenpos(h.state.main_win)[2])
out[#out + 1] = "LINE1=" .. lines[1]
vim.api.nvim_set_current_win(h.state.win)
for ln = 1, #lines do if lines[ln]:find("first line", 1, true) then vim.api.nvim_win_set_cursor(0, { ln, 0 }) end end
h.insert()
local main = vim.api.nvim_win_get_buf(h.state.main_win)
out[#out + 1] = "MAIN=" .. table.concat(vim.api.nvim_buf_get_lines(main, 0, -1, false), "|")
-- p replaces the body, keeps an edited to: line and submits to it.
local sent = "none"
note.host = { hide = function() end, submit = function(p)
  sent = p.target .. "#" .. p.window .. " " .. table.concat(vim.fn.readfile(p.file), "|")
end }
vim.api.nvim_buf_set_lines(main, 0, 2, false, { "to: app:com.other#7", "old text" })
vim.api.nvim_set_current_win(h.state.win)
for ln = 1, #lines do if lines[ln]:find("first line", 1, true) then vim.api.nvim_win_set_cursor(0, { ln, 0 }) end end
h.paste_to_target()
out[#out + 1] = "SENT=" .. sent
io.stdout:write(table.concat(out, "\n"), "\n")
vim.cmd("qall!")
LUA
out=$(VOICE_VIM_NOTES_DIR="$notes/n" VOICE_VIM_SIDEBAR=1 perl -e "alarm 20; exec @ARGV" nvim --headless --clean -l "$notes/spec.lua" "$root" 2>&1 | tr -d '\r')
check "note opens the sidebar, focus stays on the note" "WINS=2 ROWS=1 CUR=main" "$(grep -o 'WINS=[0-9]* ROWS=[0-9]* CUR=[a-z]*' <<<"$out")"
check "sidebar is on the left" "LEFT=true" "$(grep -o 'LEFT=[a-z]*' <<<"$out")"
check "sidebar shows date header" "LINE1=── Today" "$(grep '^LINE1=' <<<"$out" | sed 's/ *$//')"
check "<CR> inserts text below the to: line of the empty note" "MAIN=to: app:com.example.app#4242|first line|second line" "$(grep '^MAIN=' <<<"$out")"
check "p replaces the body and sends it to the to: line's target" "SENT=com.other#7 first line|second line" "$(grep '^SENT=' <<<"$out")"

rm -rf "$seed" "$fin" "$empty" "$notes" "$VOICE_VIM_DB"
exit $fail
