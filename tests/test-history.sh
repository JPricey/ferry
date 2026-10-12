#!/usr/bin/env bash
# History: the notes browser (the Neovim sidebar) on the notes index.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d /tmp/ferryhist.XXXX)
[ -n "$work" ] && [ -d "$work" ] || { echo "mktemp failed" >&2; exit 1; }
trap 'rm -rf "$work"' EXIT
# Every temp dir (ours from mktemp -t, nvim's socket dirs) under $work, so
# none is left behind even when a run is cut short.
export TMPDIR=$work/tmp
mkdir -p "$TMPDIR"
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want '$2' got '$3'"; fail=1; fi; }

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
note.wait_index(3000)
vim.cmd("qall!")
LUA
out=$(FERRY_NOTES_DIR="$notes/n" FERRY_INDEX="$notes/index.sqlite" FERRY_OUTBOX="$notes/outbox" FERRY_SIDEBAR=1 perl -e "alarm 20; exec @ARGV" nvim --headless --clean -l "$notes/spec.lua" "$root" 2>&1 | tr -d '\r')
check "note opens the sidebar, focus stays on the note" "WINS=2 CUR=main" "$(grep -o 'WINS=[0-9]* CUR=[a-z]*' <<<"$out")"
check "sidebar is on the left" "LEFT=true" "$(grep -o 'LEFT=[a-z]*' <<<"$out")"
check "an empty notes folder: the sidebar says so" "LINE1=  no notes yet" "$(grep '^LINE1=' <<<"$out" | sed 's/ *$//')"
check "<C-x> in a sidebar opened by :History sends the note to the latest show's target" "SIDEKEY=com.third#9 side text|more err=" "$(grep '^SIDEKEY=' <<<"$out")"

rm -rf "$notes"
exit $fail
