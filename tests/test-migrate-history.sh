#!/usr/bin/env bash
# History migration: bin/ferry-migrate-history from a fixture database
# with the old `sessions` schema into a temp notes folder. HOME, the notes
# folder and the index all point into a mktemp dir; the real history
# database and ~/notes are never opened.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=${TMPDIR:-/tmp}
work=$(mktemp -d "${tmp%/}/ferrymigrate.XXXXXX")
[ -n "$work" ] && [ -d "$work" ] || { echo "mktemp failed" >&2; exit 1; }
trap 'rm -rf "$work"' EXIT
export HOME="$work/home"; mkdir -p "$HOME"
export FERRY_NOTES_DIR="$work/notes"
export FERRY_INDEX="$work/idx/index.sqlite"
export TZ=America/Los_Angeles
migrate="$root/bin/ferry-migrate-history"
notes="$root/bin/ferry-notes"
db="$work/src/history.sqlite"
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want '$2' got '$3'"; fail=1; fi; }
py() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }

# --- fixture: the old history database's `sessions` schema, five rows ---
mkdir -p "$work/src"
python3 - "$db" <<'PY'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.executescript("""
CREATE TABLE IF NOT EXISTS sessions (
  id          TEXT PRIMARY KEY,
  started_at  TEXT NOT NULL,      -- ISO 8601 UTC
  ended_at    TEXT,
  target      TEXT,               -- bundle id of the paste target
  seed_text   TEXT,               -- selection the buffer started with
  final_text  TEXT,               -- buffer contents at exit
  outcome     TEXT NOT NULL       -- open | submitted | cancelled
);
CREATE INDEX IF NOT EXISTS sessions_started ON sessions(started_at DESC);
""")
rows = [
    ("aaaa1111-0000-4000-8000-000000000001", "2026-10-11T22:04:51Z", "2026-10-11T22:05:30Z",
     "com.mitchellh.ghostty", "", "Refactor the delivery module.\n\nKeep it thin.\n", "submitted"),
    ("bbbb2222-0000-4000-8000-000000000002", "2026-10-10T15:00:00Z", "2026-10-10T15:01:12Z",
     "com.tinyspeck.slackmacgap", "seed", "Never mind: #later\n", "cancelled"),
    ("cccc3333-0000-4000-8000-000000000003", "2026-10-12T16:15:02Z", None,
     "com.apple.Safari", "Selected text from Safari\n", None, "open"),
    ("dddd4444-0000-4000-8000-000000000004", "2026-10-09T10:00:00Z", "2026-10-09T10:00:05Z",
     "com.apple.Notes", "", "  \n\n", "submitted"),
    ("eeee5555-0000-4000-8000-000000000005", "2026-10-08T09:30:00Z", "2026-10-08T09:31:00Z",
     None, None, "to: x\nbody after a to: line", "submitted"),
]
con.executemany("INSERT INTO sessions VALUES (?,?,?,?,?,?,?)", rows)
con.commit()
con.close()
PY
before=$(shasum "$db" | cut -d' ' -f1)
dir_state() { (cd "$work/src" && ls -A | sort | tr '\n' ' '); }
src_files=$(dir_state)

# --- dry run writes nothing ---------------------------------------------
out=$("$migrate" --from "$db" --to "$work/notes" --dry-run 2>/dev/null)
check "--dry-run: summary" "would write 4, skipped 1" "$(printf '%s\n' "$out" | tail -n1)"
check "--dry-run: lists the files it would write" "4" "$(printf '%s\n' "$out" | grep -c '^would write /')"
check "--dry-run: notes folder not created" "no" "$([ -e "$work/notes" ] && echo yes || echo no)"
check "--dry-run: no index written" "no" "$([ -e "$FERRY_INDEX" ] && echo yes || echo no)"

# --- migrate (default --to is $FERRY_NOTES_DIR) ---------------------
check "migrate: summary" "wrote 4, skipped 1" "$("$migrate" --from "$db" 2>"$work/err")"
check "migrate: skipped row named on stderr" "skip dddd4444-0000-4000-8000-000000000004: no text" "$(cat "$work/err")"
check "5 rows -> 4 files" "4" "$(ls "$work/notes" | grep -c '\.md$')"
check "no temp files left" "" "$(ls -A "$work/notes" | grep '^\.' || true)"
check "file names" \
  "2026-10-08-023000-eeee5555.md 2026-10-10-080000-bbbb2222.md 2026-10-11-150451-aaaa1111.md 2026-10-12-091502-cccc3333.md" \
  "$(ls "$work/notes" | tr '\n' ' ' | sed 's/ $//')"

f1="$work/notes/2026-10-11-150451-aaaa1111.md"
check "sent note: exact file" "$(printf -- '---\nid: aaaa1111-0000-4000-8000-000000000001\nstate: sent\ncreated: 2026-10-11T15:04:51-07:00\nupdated: 2026-10-11T15:05:30-07:00\nsent: 2026-10-11T15:05:30-07:00\ntarget: app:com.mitchellh.ghostty\n---\nRefactor the delivery module.\n\nKeep it thin.\n')" "$(cat "$f1")"
check "draft note: seed body, no updated/sent" \
  "$(printf -- '---\nid: cccc3333-0000-4000-8000-000000000003\nstate: draft\ncreated: 2026-10-12T09:15:02-07:00\ntarget: app:com.apple.Safari\n---\nSelected text from Safari\n')" \
  "$(cat "$work/notes/2026-10-12-091502-cccc3333.md")"

# --- read back through ferry-notes (index rebuilt by the script) ----
check "index rebuilt: list has the 4 notes" \
  "cccc3333:draft aaaa1111:sent bbbb2222:cancelled eeee5555:sent" \
  "$("$notes" list | py '" ".join(r["id"][:8] + ":" + r["state"] for r in d)')"
check "get: sent body" "Refactor the delivery module.|
Keep it thin." "$("$notes" get aaaa1111 | py 'd["text"].replace(chr(10)+chr(10), "|"+chr(10))')"
check "get: cancelled body and target" "Never mind: #later app:com.tinyspeck.slackmacgap" \
  "$("$notes" get bbbb2222 | py 'd["text"] + " " + d["target"]')"
check "get: draft body is the seed" "Selected text from Safari" "$("$notes" get cccc3333 | py 'd["text"]')"
check "get: row without a target -> clipboard; to: line stays body" \
  "clipboard|to: x|body after a to: line" \
  "$("$notes" get eeee5555 | py '"|".join([d["target"]] + d["text"].split(chr(10)))')"
check "--query finds migrated text" "aaaa1111" "$("$notes" list --query delivery | py '" ".join(r["id"][:8] for r in d)')"

# --- read back through store.lua: same meta, byte-identical round trip --
lua=""
if command -v luajit >/dev/null; then lua="luajit"; elif command -v nvim >/dev/null; then lua="nvim --clean -l"; fi
if [ -z "$lua" ]; then
  echo "FAIL no Lua interpreter (luajit or nvim) found"; fail=1
else
  cat > "$work/rt.lua" <<'LUA'
local S = dofile(arg[1])
for i = 2, #arg do
  local f = assert(io.open(arg[i], "rb")); local text = f:read("*a"); f:close()
  local meta, lines, has = S.parse(text)
  local base = arg[i]:match("[^/]+$")
  local name = S.name(meta.created, meta.id)
  local same = S.format(meta, lines) == text
  local keys = table.concat(meta, ",")
  print(string.format("%s has=%s roundtrip=%s name=%s keys=%s state=%s target=%s lines=%d",
    base, tostring(has), tostring(same), tostring(name == base), keys, meta.state,
    tostring(meta.target), #lines))
end
LUA
  rt=$($lua "$work/rt.lua" "$root/lua/ferry/store.lua" "$work/notes"/*.md 2>&1)
  want="2026-10-08-023000-eeee5555.md has=true roundtrip=true name=true keys=id,state,created,updated,sent,target state=sent target=clipboard lines=2
2026-10-10-080000-bbbb2222.md has=true roundtrip=true name=true keys=id,state,created,updated,target state=cancelled target=app:com.tinyspeck.slackmacgap lines=1
2026-10-11-150451-aaaa1111.md has=true roundtrip=true name=true keys=id,state,created,updated,sent,target state=sent target=app:com.mitchellh.ghostty lines=3
2026-10-12-091502-cccc3333.md has=true roundtrip=true name=true keys=id,state,created,target state=draft target=app:com.apple.Safari lines=1"
  check "store.lua reads the files back; format is byte-identical; name rule" "$want" "$rt"
fi

# --- source untouched; re-run writes nothing -----------------------------
check "source DB shasum unchanged" "$before" "$(shasum "$db" | cut -d' ' -f1)"
check "no journal/wal files next to the source" "$src_files" "$(dir_state)"
snap=$(cd "$work/notes" && shasum *.md)
check "re-run: wrote 0" "wrote 0, skipped 5" "$("$migrate" --from "$db" --to "$work/notes" 2>/dev/null)"
check "re-run: files unchanged" "$snap" "$(cd "$work/notes" && shasum *.md)"

# A note moved to .trash is not migrated again.
"$notes" delete bbbb2222 >/dev/null
check "trashed note not resurrected" "wrote 0, skipped 5" "$("$migrate" --from "$db" --to "$work/notes" 2>/dev/null)"

# An existing note with the same id (written by the app) wins.
mkdir -p "$work/notes2"
printf -- '---\nid: aaaa1111-0000-4000-8000-000000000001\nstate: sent\n---\nmine\n' > "$work/notes2/other.md"
idx_before=$(shasum "$FERRY_INDEX" | cut -d' ' -f1)
check "id already in folder is skipped" "wrote 3, skipped 2" "$("$migrate" --from "$db" --to "$work/notes2" 2>/dev/null)"
check "--to another folder: \$FERRY_INDEX not rebuilt from it" "$idx_before" "$(shasum "$FERRY_INDEX" | cut -d' ' -f1)"
check "existing note untouched" "mine" "$(sed -n 5p "$work/notes2/other.md")"

check "missing source: exit 1" "1" "$("$migrate" --from "$work/nope.sqlite" --to "$work/notes3" 2>/dev/null; echo $?)"
check "missing source: nothing created" "no" "$([ -e "$work/notes3" ] && echo yes || echo no)"
check "bad argument: exit 2" "2" "$("$migrate" --bogus 2>/dev/null; echo $?)"
check "HOME untouched (no ~/notes)" "" "$(ls -A "$HOME")"
check "source DB still unchanged" "$before" "$(shasum "$db" | cut -d' ' -f1)"

# --- FERRY_INDEX unset: only the default folder rebuilds the default index
h2="$work/home2"; ddir="$h2/notes/scratchpads"; mkdir -p "$ddir"
didx="$h2/Library/Application Support/ferry/index.sqlite"
printf -- '---\nid: ffff6666-0000-4000-8000-000000000006\nstate: draft\n---\nalready here\n' > "$ddir/mine.md"
d2() { env -u FERRY_INDEX -u FERRY_NOTES_DIR HOME="$h2" "$@"; }
d2 "$notes" rebuild >/dev/null
idx_sum=$(shasum "$didx" | cut -d' ' -f1)
idx_list=$(d2 "$notes" list | py '" ".join(r["id"][:8] for r in d)')
check "default index: built from the default folder" "ffff6666" "$idx_list"
# A folder name with a space and a quote, so the hint must be shell-quoted.
else="$work/else where's"
check "--to elsewhere: wrote 4" "wrote 4, skipped 1" "$(d2 "$migrate" --from "$db" --to "$else" 2>"$work/err2")"
check "--to elsewhere: default index byte-identical" "$idx_sum" "$(shasum "$didx" | cut -d' ' -f1)"
check "--to elsewhere: list unchanged" "$idx_list" "$(d2 "$notes" list | py '" ".join(r["id"][:8] for r in d)')"
hint=$(grep '^not indexed: run ' "$work/err2" | sed 's/^not indexed: run //')
check "--to elsewhere: hint names that folder and an index inside it" \
  "FERRY_NOTES_DIR=$(printf %q "$else") FERRY_INDEX=$(printf %q "$else/.index.sqlite")" \
  "$(d2 bash -c 'eval "set -- $1"; printf "%s=%q %s=%q" "${1%%=*}" "${1#*=}" "${2%%=*}" "${2#*=}"' _ "$hint")"
# Follow the hint exactly as printed, in the same environment.
d2 bash -c "$hint" >/dev/null 2>"$work/err3"
check "following the hint: exit 0, no stderr" "" "$(cat "$work/err3")"
check "following the hint: default index byte-identical" "$idx_sum" "$(shasum "$didx" | cut -d' ' -f1)"
check "following the hint: default list unchanged" "$idx_list" "$(d2 "$notes" list | py '" ".join(r["id"][:8] for r in d)')"
check "following the hint: its own index lists that folder" "aaaa1111 bbbb2222 cccc3333 eeee5555" \
  "$(d2 env FERRY_NOTES_DIR="$else" FERRY_INDEX="$else/.index.sqlite" "$notes" list | py '" ".join(sorted(r["id"][:8] for r in d))')"
check "following the hint: re-run still skips every row" "wrote 0, skipped 5" \
  "$(d2 "$migrate" --from "$db" --to "$else" 2>/dev/null)"
check "--to default folder (other spelling): wrote 4" "wrote 4, skipped 1" \
  "$(d2 "$migrate" --from "$db" --to "$h2/notes/../notes/scratchpads/" 2>/dev/null)"
check "--to default folder: index rebuilt" "aaaa1111 bbbb2222 cccc3333 eeee5555 ffff6666" \
  "$(d2 "$notes" list | py '" ".join(sorted(r["id"][:8] for r in d))')"

[ "$fail" = 0 ] && echo "all ok" || echo "some checks failed"
exit "$fail"
