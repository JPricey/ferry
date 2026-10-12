#!/usr/bin/env bash
# Notes index: bin/voice-vim-notes over a temp notes folder and index.
# Never touches ~/notes or the real index: both env vars point into a
# mktemp dir, and HOME does too.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=${TMPDIR:-/tmp}
work=$(mktemp -d "${tmp%/}/vvnotes.XXXXXX")
[ -n "$work" ] && [ -d "$work" ] || { echo "mktemp failed" >&2; exit 1; }
trap 'rm -rf "$work"' EXIT
export HOME="$work/home"; mkdir -p "$HOME"
export VOICE_VIM_NOTES_DIR="$work/notes"
export VOICE_VIM_INDEX="$work/idx/index.sqlite"
notes="$root/bin/voice-vim-notes"
fixtures="$root/tests/fixtures/notes"
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want '$2' got '$3'"; fail=1; fi; }
# jq-like helper: py '<expr over d>' reads JSON from stdin as d.
py() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }
body() { sed '1,/^---$/d' "$1" | shasum | cut -d' ' -f1; } # bytes after the frontmatter

# --- frontmatter parses exactly as store.lua -----------------------------
# Both sides dump: has, effective state, each key in order (raw YAML as
# RAW lines), then body lines; \ newline tab and CR escaped the same way.
cases="$work/cases"; mkdir -p "$cases"
cp "$fixtures"/*.md "$cases/"
printf -- '---\nk: "a\\x41\\u00e9\\U0001F600\\n\\t\\"q\\"" # c\nj: '"'"'it'"'"''"'"'s'"'"'\nz: v # note\nz: dup\n---\nb\n' > "$cases/x-escapes.md"
printf -- '---\nk: "bad \\q"\nl: [a, b]\nm: |\n  block\n---\nbody\n' > "$cases/x-unmodelled.md"
printf -- '---\na:b\n---\nbody\n' > "$cases/x-not-key.md"
printf -- '---\nid: 1\n' > "$cases/x-unclosed.md"
printf -- '---\r\nid: 1\r\n---\r\nbody\r\n' > "$cases/x-crlf.md"
printf -- '---\n---\n' > "$cases/x-empty-front.md"
printf -- '---\nid: x\n---' > "$cases/x-no-final-newline.md"
: > "$cases/x-empty.md"
cat > "$work/dump.lua" <<'LUA'
local S = dofile(arg[1])
local function esc(s)
  return (s:gsub("\\", "\\\\"):gsub("\n", "\\n"):gsub("\t", "\\t"):gsub("\r", "\\r"))
end
local out = assert(io.open(arg[2], "wb"))
for i = 3, #arg do
  local f = assert(io.open(arg[i], "rb")); local text = f:read("*a"); f:close()
  local meta, lines, has = S.parse(text)
  out:write("file ", arg[i]:match("[^/]+$"), "\nhas ", tostring(has), "\nstate ", esc(meta.state), "\n")
  for _, k in ipairs(meta) do
    local v = meta[k]
    if type(v) == "table" then
      for _, l in ipairs(v.raw) do out:write("key ", k, " RAW ", esc(l), "\n") end
    else
      out:write("key ", k, " = ", esc(v), "\n")
    end
  end
  for _, l in ipairs(lines) do out:write("body ", esc(l), "\n") end
end
out:close()
LUA
cat > "$work/dump.py" <<'PY'
import sys
from importlib.machinery import SourceFileLoader
N = SourceFileLoader("vvnotes", sys.argv[1]).load_module()
def esc(s):
    return s.replace("\\", "\\\\").replace("\n", "\\n").replace("\t", "\\t").replace("\r", "\\r")
out = []
for p in sys.argv[3:]:
    keys, meta, lines, has = N.parse(N.read_text(p))
    st = meta.get("state", "draft")
    out.append("file %s\nhas %s\nstate %s\n" % (p.rsplit("/", 1)[-1], str(has).lower(),
               esc(st if isinstance(st, str) else "table")))
    for k in keys:
        v = meta[k]
        if isinstance(v, dict):
            out += ["key %s RAW %s\n" % (k, esc(l)) for l in v["raw"]]
        else:
            out.append("key %s = %s\n" % (k, esc(v)))
    out += ["body %s\n" % esc(l) for l in lines]
open(sys.argv[2], "wb").write("".join(out).encode("utf-8", "surrogateescape"))
PY
lua=""
if command -v luajit >/dev/null; then lua="luajit"; elif command -v nvim >/dev/null; then lua="nvim --clean -l"; fi
if [ -z "$lua" ]; then
  echo "FAIL no Lua interpreter (luajit or nvim) found"; fail=1
else
  for f in "$cases"/*.md; do
    n=$(basename "$f")
    $lua "$work/dump.lua" "$root/lua/voice-vim/store.lua" "$work/lua-$n.txt" "$f" 2>&1
    python3 "$work/dump.py" "$notes" "$work/py-$n.txt" "$f"
    if [ -s "$work/lua-$n.txt" ] && cmp -s "$work/lua-$n.txt" "$work/py-$n.txt"; then
      echo "ok   same meta and body as store.lua: $n"
    else
      echo "FAIL same meta and body as store.lua: $n"; diff "$work/lua-$n.txt" "$work/py-$n.txt"; fail=1
    fi
  done
fi

# --- list order -----------------------------------------------------------
mkdir -p "$VOICE_VIM_NOTES_DIR"
cp "$fixtures"/*.md "$VOICE_VIM_NOTES_DIR/"
# Notes without frontmatter sort by file mtime.
touch -t 202610010900 "$VOICE_VIM_NOTES_DIR/no-frontmatter.md"
touch -t 202610020900 "$VOICE_VIM_NOTES_DIR/no-frontmatter-dashes.md"
check "missing index builds itself on first use" "indexed 0, dropped 0, notes 11" "$("$notes" sync)"
ids() { py '" ".join(r["id"][:8] for r in d)'; }
order="55aa66bb 3f9a1c2e 1234abcd 1234abcd 1234abcd 1234abcd 7c21d0aa a0b1c2d3 9d8c7b6a no-front no-front"
check "list: pinned first, then updated newest first" "$order" "$("$notes" list | ids)"
check "list: same-prefix rows in time order" \
  "empty-body target-special body-to body-dashes no-frontmatter-dashes no-frontmatter" \
  "$("$notes" list | py '" ".join(r["path"].rsplit("/",1)[1][:-3] for r in d if r["id"].startswith(("1234","no-")))')"
check "list: fields" "draft  3f9a1c2e-5b7d-4e8f-9a01-23456789abcd False Remind me to check the paste timing in Neovide. 9" \
  "$("$notes" list | py '" ".join(str(x) for x in [d[1][k] for k in ("state","target","id","pinned","preview","words")])')"
check "list: path is the note file" "$VOICE_VIM_NOTES_DIR/pinned.md" "$("$notes" list | py 'd[0]["path"]')"
check "list: app from target" "tmux ghostty fleet" \
  "$("$notes" list | py '" ".join(r["app"] for r in d if r["id"][:8] in ("55aa66bb","7c21d0aa","a0b1c2d3"))')"
check "list: time and date label" "True True" \
  "$("$notes" list | py '" ".join(str(bool(x)) for x in (d[0]["time"], d[0]["date_label"]))')"
check "list --limit" "55aa66bb 3f9a1c2e" "$("$notes" list --limit 2 | ids)"
check "list --exclude" "3f9a1c2e" "$("$notes" list --exclude 55aa66bb-77cc-48dd-99ee-00ff11aa22bb --limit 1 | ids)"

# --- search ---------------------------------------------------------------
check "--query matches a body word" "3f9a1c2e" "$("$notes" list --query neovide | ids)"
check "--query: all words must match" "7c21d0aa" "$("$notes" list --query 'hammerspoon thin' | ids)"
check "--query: word only in a target does not match" "" "$("$notes" list --query ghostty | ids)"
check "--query: word only in frontmatter keys does not match" "1234abcd" "$("$notes" list --query title | ids)"
check "--query: no match is empty" "" "$("$notes" list --query kubernetes | ids)"
check "--query: FTS syntax is taken literally" "0" "$("$notes" list --query 'kubernetes OR ("' | py 'len(d)')"
check "--query: empty lists all" "11" "$("$notes" list --query '' | py 'len(d)')"

# --- get ------------------------------------------------------------------
check "get: text is the body" "Refactor the delivery module so the focus wait is testable.

Keep the Hammerspoon layer thin." "$("$notes" get 7c21d0aa-90b4-4c3e-8f12-0d9e8f7a6b5c | py 'd["text"]')"
check "get: id prefix" "sent 2026-10-11T22:05:30-07:00" "$("$notes" get 7c21d0aa | py 'd["state"], d["sent"]' | tr -d "(),'")"
"$notes" get nosuchid >/dev/null 2>&1
check "get: unknown id exits 1" "1" "$?"

# --- hand edit + sync, rm + sync ------------------------------------------
draft="$VOICE_VIM_NOTES_DIR/draft.md"
sed -i '' 's/^Remind me.*/Kubernetes upgrade plan, edited by hand./' "$draft"
check "sync after a hand edit" "indexed 1, dropped 0, notes 11" "$("$notes" sync)"
check "hand edit + sync: new preview" "Kubernetes upgrade plan, edited by hand." \
  "$("$notes" list | py '[r["preview"] for r in d if r["id"].startswith("3f9a1c2e")][0]')"
check "hand edit + sync: search finds the new words" "3f9a1c2e" "$("$notes" list --query kubernetes | ids)"
check "hand edit + sync: old words gone" "" "$("$notes" list --query neovide | ids)"
check "sync with nothing changed" "indexed 0, dropped 0, notes 11" "$("$notes" sync)"
rm "$VOICE_VIM_NOTES_DIR/cancelled.md"
check "rm + sync" "indexed 0, dropped 1, notes 10" "$("$notes" sync)"
check "rm + sync drops the row" "0" "$("$notes" list | py 'sum(r["id"].startswith("a0b1c2d3") for r in d)')"
check "rm + sync: search drops it too" "" "$("$notes" list --query 'by hand' | py '",".join(r["id"][:8] for r in d if r["id"].startswith("a0b1"))')"

# --- index <file> ---------------------------------------------------------
printf -- '---\nid: feedface-0000\nstate: draft\nupdated: 2099-01-01T00:00:00Z\ntarget: clipboard\n---\nFresh note\n' \
  > "$VOICE_VIM_NOTES_DIR/fresh.md"
"$notes" index "$VOICE_VIM_NOTES_DIR/fresh.md"
check "index <file>: newest unpinned note after the pinned one" "55aa66bb feedface" "$("$notes" list --limit 2 | ids)"
check "index <file>: clipboard app" "clipboard" "$("$notes" get feedface-0000 | py 'd["app"]')"
rm "$VOICE_VIM_NOTES_DIR/fresh.md"
"$notes" index "$VOICE_VIM_NOTES_DIR/fresh.md"
check "index <gone file> drops the row" "1" "$("$notes" get feedface-0000 >/dev/null 2>&1; echo $?)"
printf 'x\n' > "$work/outside.md"
"$notes" index "$work/outside.md" 2>/dev/null
check "index <file outside the notes folder> fails" "1" "$?"
check "file outside the notes folder is not listed" "10" "$("$notes" list | py 'len(d)')"

# --- rebuild --------------------------------------------------------------
before=$("$notes" list)
rm -f "$VOICE_VIM_INDEX" "$VOICE_VIM_INDEX-wal" "$VOICE_VIM_INDEX-shm"
check "rebuild after deleting the index" "indexed 10" "$("$notes" rebuild)"
check "delete index + rebuild: identical list" "$before" "$("$notes" list)"
check "rebuild again: identical list" "$before" "$("$notes" rebuild >/dev/null; "$notes" list)"
rm -f "$VOICE_VIM_INDEX" "$VOICE_VIM_INDEX-wal" "$VOICE_VIM_INDEX-shm"
check "delete index + list: rebuilt on use" "$before" "$("$notes" list)"

# --- pin ------------------------------------------------------------------
sent="$VOICE_VIM_NOTES_DIR/sent.md"
b0=$(body "$sent")
"$notes" pin 7c21d0aa on
check "pin on: frontmatter has pinned: true" "pinned: true" "$(grep '^pinned:' "$sent")"
check "pin leaves body bytes unchanged" "$b0" "$(body "$sent")"
check "pin on: pinned notes come first" "55aa66bb 7c21d0aa" "$("$notes" list --limit 2 | ids)"
check "pin on: other keys unchanged" "$(sed '/^pinned:/d' "$sent")" "$(cat "$fixtures/sent.md")"
"$notes" pin 7c21d0aa off
check "pin off: file back to the original bytes" "$(shasum < "$fixtures/sent.md")" "$(shasum < "$sent")"
check "pin off: not pinned" "False" "$("$notes" get 7c21d0aa | py 'd["pinned"]')"
pinned="$VOICE_VIM_NOTES_DIR/pinned.md"
"$notes" pin 55aa66bb off; "$notes" pin 55aa66bb on
check "pin off then on: pinned.md byte-identical" "$(shasum < "$fixtures/pinned.md")" "$(shasum < "$pinned")"
nf="$VOICE_VIM_NOTES_DIR/no-frontmatter.md"
"$notes" pin no-frontmatter on
check "pin a note without frontmatter: whole old file stays the body" \
  "$(shasum < "$fixtures/no-frontmatter.md")" "$(sed '1,3d' "$nf" | shasum)"
check "pin a note without frontmatter: header added" "---|pinned: true|---" "$(head -3 "$nf" | paste -sd'|' -)"
bd="$VOICE_VIM_NOTES_DIR/body-dashes.md"
b0=$(body "$bd")
"$notes" pin 1234abcd-0000-4000-8000-000000000001 on
check "pin a body starting with ---: body unchanged" "$b0" "$(body "$bd")"
check "pin a body starting with ---: store.lua still reads it" "true|---" \
  "$($lua "$work/dump.lua" "$root/lua/voice-vim/store.lua" "$work/bd.txt" "$bd" 2>&1; grep -E '^(key pinned|body )' "$work/bd.txt" | head -2 | sed 's/^key pinned = //; s/^body //' | paste -sd'|' -)"
"$notes" pin 7c21d0aa maybe 2>/dev/null
check "pin: bad value exits 2" "2" "$?"
check "no temp files left in the notes folder" "" "$(ls -A "$VOICE_VIM_NOTES_DIR" | grep '\.tmp$')"

# --- state ----------------------------------------------------------------
b0=$(body "$sent")
"$notes" state 7c21d0aa cancelled
check "state: frontmatter changed" "state: cancelled" "$(grep '^state:' "$sent")"
check "state: body unchanged" "$b0" "$(body "$sent")"
check "state: reindexed" "cancelled" "$("$notes" list | py '[r["state"] for r in d if r["id"].startswith("7c21")][0]')"
"$notes" state 7c21d0aa sent
check "state back: file back to the original bytes" "$(shasum < "$fixtures/sent.md")" "$(shasum < "$sent")"
"$notes" state 7c21d0aa bogus 2>/dev/null
check "state: bad state exits 2" "2" "$?"

# --- delete ---------------------------------------------------------------
printf 'still here\n' > "$VOICE_VIM_NOTES_DIR/.trash-me" # dot files are not notes
mkdir -p "$VOICE_VIM_NOTES_DIR/.trash"; cp "$fixtures/sent.md" "$VOICE_VIM_NOTES_DIR/.trash/sent.md"
check "delete prints the trash path" "$VOICE_VIM_NOTES_DIR/.trash/sent-1.md" "$("$notes" delete 7c21d0aa)"
check "delete moves the file to .trash" "no yes" \
  "$([ -e "$sent" ] && echo yes || echo no) $([ -e "$VOICE_VIM_NOTES_DIR/.trash/sent-1.md" ] && echo yes || echo no)"
check "delete keeps the bytes" "$(shasum < "$fixtures/sent.md")" "$(shasum < "$VOICE_VIM_NOTES_DIR/.trash/sent-1.md")"
check "delete drops the row" "0" "$("$notes" list | py 'sum(r["id"].startswith("7c21") for r in d)')"
check "sync does not index .trash or dot files" "indexed 0, dropped 0, notes 9" "$("$notes" sync)"
"$notes" delete 7c21d0aa 2>/dev/null
check "delete: unknown id exits 1" "1" "$?"

# --- app names and path ---------------------------------------------------
check "app names from target specs" "slackmacgap|slackmacgap|tmux|fleet|clipboard||?" "$(python3 -c '
import sys
from importlib.machinery import SourceFileLoader
N = SourceFileLoader("vvnotes", sys.argv[1]).load_module()
print("|".join(N.short_app(t) for t in ["app:com.tinyspeck.slackmacgap#4242",
  "com.tinyspeck.slackmacgap", "tmux:default:%3", "fleet:task:jpX", "clipboard", "", "what"]))' "$notes")"
check "path prints the index path" "$VOICE_VIM_INDEX" "$("$notes" path)"
check "path <id> prints the note path" "$pinned" "$("$notes" path 55aa66bb)"
check "real notes folder untouched" "no" "$([ -e "$HOME/notes" ] && echo yes || echo no)"
exit $fail
