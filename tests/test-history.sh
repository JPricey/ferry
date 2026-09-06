#!/usr/bin/env bash
# History: database helper, session recording, and the Neovim sidebar.
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
"$db" delete bbb
check "delete" "1" "$("$db" list | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))')"
check "VOICE_VIM_HISTORY=0 is a no-op" "1" "$(VOICE_VIM_HISTORY=0 "$db" start zzz x "$seed"; VOICE_VIM_HISTORY=0 "$db" finish zzz submitted "$fin"; "$db" list | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))')"

# --- session script records ---------------------------------------------
ed=$(mktemp -t vv-ed); printf '#!/bin/bash\nprintf "dictated words\\n" > "${@: -1}"\n' > "$ed"; chmod +x "$ed"
f=$(mktemp -t vv-file); : > "$f"
VOICE_VIM_DRY_RUN=1 VOICE_VIM_EDITOR="$ed" VOICE_VIM_SESSION_ID=sess1 "$root/bin/voice-vim-session" "$f" com.example.app >/dev/null 2>&1
check "session script records submit" "submitted dictated words" "$("$db" get sess1 | python3 -c 'import json,sys;r=json.load(sys.stdin);print(r["outcome"],r["preview"])')"

# --- sidebar in headless neovim ----------------------------------------
main=$(mktemp -t vv-main).md; : > "$main"
out=$(VOICE_VIM_SIDEBAR=1 VOICE_VIM_SESSION_ID=none perl -e "alarm 20; exec @ARGV" nvim --headless -u NONE -c "source $root/vim/voice-vim.vim" -c 'lua local h=require("voice-vim.history"); local lines=vim.api.nvim_buf_get_lines(h.state.buf,0,-1,false); print("WINS="..#vim.api.nvim_list_wins(), "ROWS="..#h.state.rows, "CUR="..(vim.api.nvim_get_current_win()==h.state.main_win and "main" or "side")); print("LINE1="..lines[1]); vim.api.nvim_set_current_win(h.state.win); h.insert(); print("MAIN="..table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(h.state.main_win),0,-1,false),"|")); vim.cmd("quit!")' -- "$main" 2>&1 | tr -d '\r' | tr '\n' ' ')
check "sidebar opens left, focus stays on main" "WINS=2 ROWS=2 CUR=main" "$(echo "$out" | grep -o 'WINS=[0-9]* ROWS=[0-9]* CUR=[a-z]*')"
check "sidebar shows date header" "── Today" "$(echo "$out" | sed 's/.*LINE1=//; s/ MAIN=.*//; s/ *$//')"
check "<CR> inserts text into empty main buffer" "MAIN=dictated words" "$(echo "$out" | grep -o 'MAIN=[^ ]* [a-z]*' | head -1)"
VOICE_VIM_SIDEBAR=1 perl -e "alarm 20; exec @ARGV" nvim --headless -u NONE -c "source $root/vim/voice-vim.vim" -c 'quit' -- "$main" >/dev/null 2>&1
check ":quit from main ends nvim with sidebar open" "exit=0" "exit=$?"
check "sidebar disabled with VOICE_VIM_SIDEBAR=0" "WINS=1" "$(VOICE_VIM_SIDEBAR=0 perl -e "alarm 20; exec @ARGV" nvim --headless -u NONE -c "source $root/vim/voice-vim.vim" -c 'lua print("WINS="..#vim.api.nvim_list_wins())' -c q -- "$main" 2>&1 | grep -o 'WINS=[0-9]*')"

rm -f "$seed" "$fin" "$empty" "$ed" "$f" "$main" "$VOICE_VIM_DB"
exit $fail
