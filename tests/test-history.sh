#!/usr/bin/env bash
# History: database helper and the notes browser (the Neovim sidebar).
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export FERRY_DB=$(mktemp -t ferry-hist-db).sqlite
db="$root/bin/ferry-db"
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want '$2' got '$3'"; fail=1; fi; }

# --- helper -------------------------------------------------------------
seed=$(mktemp -t ferry-seed); printf 'seed text' > "$seed"
fin=$(mktemp -t ferry-fin);   printf 'first line\nsecond line\n' > "$fin"
empty=$(mktemp -t ferry-empty); : > "$empty"
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
check "FERRY_HISTORY=0 is a no-op" "1" "$(FERRY_HISTORY=0 "$db" start zzz x "$seed"; FERRY_HISTORY=0 "$db" finish zzz submitted "$fin"; "$db" list | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))')"


# --- the notes browser on a fixture folder ---------------------------------
# tests/history_spec.lua: fixture note files, a stub host, a fake clipboard.
notes=$(mktemp -d -t ferry-hist-notes)
out=$(FERRY_NOTES_DIR="$notes/n" FERRY_INDEX="$notes/index.sqlite" FERRY_OUTBOX="$notes/outbox" FERRY_SIDEBAR=1 \
  perl -e "alarm 30; exec @ARGV" nvim --headless --clean -l "$root/tests/history_spec.lua" "$root" "$notes" 2>&1 | tr -d '\r')
grep -E '^(ok|FAIL) ' <<<"$out"
if [ "$(grep -o 'RESULT=[0-9]*' <<<"$out")" != "RESULT=0" ]; then
  echo "FAIL history_spec: $(grep -v -E '^(ok|FAIL) ' <<<"$out" | tail -5)"; fail=1
fi
rm -rf "$notes"

# --- sidebar keys through the note -----------------------------------------
# Reopened by :History (not through show), the sidebar still has the note
# keys, and they act on the note: <C-x> sends it to the target captured at
# the latest show. Joe's global <C-x> (:write) must not run.
notes=$(mktemp -d -t ferry-hist-notes)
cat > "$notes/spec.lua" <<'LUA'
local root = arg[1]
vim.opt.rtp:prepend(root)
local note = require("ferry.note")
note.host = { submit = function() end, hide = function() end }
note.show({ target = "com.example.app", window = "4242" })
local h = require("ferry.history")
local out = {}
out[#out + 1] = "WINS=" .. #vim.api.nvim_list_wins() .. " CUR="
  .. (vim.api.nvim_get_current_win() == h.state.main_win and "main" or "side")
out[#out + 1] = "LEFT=" .. tostring(vim.fn.win_screenpos(h.state.win)[2] < vim.fn.win_screenpos(h.state.main_win)[2])
out[#out + 1] = "LINE1=" .. vim.api.nvim_buf_get_lines(h.state.buf, 0, 1, false)[1]
local sent
note.host = { hide = function() end, submit = function(p)
  sent = p.target .. "#" .. p.window .. " " .. table.concat(vim.fn.readfile(p.file), "|")
end }
note.show({ target = "com.third", window = "9" })
local fresh = vim.api.nvim_win_get_buf(h.state.main_win)
vim.api.nvim_buf_set_lines(fresh, 0, -1, false, { "side text", "more" })
vim.keymap.set("n", "<C-x>", vim.cmd.write)
h.close(); vim.cmd("History")
vim.api.nvim_set_current_win(h.state.win)
vim.v.errmsg = ""
vim.api.nvim_feedkeys(vim.keycode("<C-x>"), "xt", false)
out[#out + 1] = "SIDEKEY=" .. tostring(sent) .. " err=" .. vim.v.errmsg
io.stdout:write(table.concat(out, "\n"), "\n")
vim.cmd("qall!")
LUA
out=$(FERRY_NOTES_DIR="$notes/n" FERRY_INDEX="$notes/index.sqlite" FERRY_OUTBOX="$notes/outbox" FERRY_SIDEBAR=1 perl -e "alarm 20; exec @ARGV" nvim --headless --clean -l "$notes/spec.lua" "$root" 2>&1 | tr -d '\r')
check "note opens the sidebar, focus stays on the note" "WINS=2 CUR=main" "$(grep -o 'WINS=[0-9]* CUR=[a-z]*' <<<"$out")"
check "sidebar is on the left" "LEFT=true" "$(grep -o 'LEFT=[a-z]*' <<<"$out")"
check "an empty notes folder: the sidebar says so" "LINE1=  no notes yet" "$(grep '^LINE1=' <<<"$out" | sed 's/ *$//')"
check "<C-x> in a sidebar opened by :History sends the note to the latest show's target" "SIDEKEY=com.third#9 side text|more err=" "$(grep '^SIDEKEY=' <<<"$out")"

rm -rf "$seed" "$fin" "$empty" "$notes" "$FERRY_DB"
exit $fail
