#!/usr/bin/env bash
# Correction suggestions: bin/ferry-corrections over a temp WAL-mode
# flow.sqlite built from tests/fixtures/flow/schema.sql and a temp notes
# folder. Never touches Wispr Flow's real database or ~/notes: HOME,
# FERRY_NOTES_DIR and --flow-db all point into a mktemp dir.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=${TMPDIR:-/tmp}
work=$(mktemp -d "${tmp%/}/ferrycorr.XXXXXX")
[ -n "$work" ] && [ -d "$work" ] || { echo "mktemp failed" >&2; exit 1; }
holder=""
holder2=""
trap 'for p in $holder $holder2; do kill "$p" 2>/dev/null; done; rm -rf "$work"' EXIT
export HOME="$work/home"; mkdir -p "$HOME"
# the script's private copies go here, so we can see them removed
export TMPDIR="$work/tmpd"; mkdir -p "$TMPDIR"
tmpd_left() { ls -A "$TMPDIR" | wc -l | tr -d ' '; }
export FERRY_NOTES_DIR="$work/notes"; mkdir -p "$FERRY_NOTES_DIR"
script="$root/bin/ferry-corrections"
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want '$2' got '$3'"; fail=1; fi; }

note() { # file state created sent body
  { echo "---"; echo "id: $1"; echo "state: $2"; echo "created: $3"
    [ -n "$4" ] && echo "sent: $4"; echo "target: app:com.mitchellh.ghostty#1"
    echo "---"; printf '%s\n' "$5"; } > "$FERRY_NOTES_DIR/$1.md"
}
note n1 sent 2026-10-10T09:00:00-07:00 2026-10-10T09:05:00-07:00 \
  "We deploy with kubectl apply today. Build the docker image, then run pytest now."
note n2 sent 2026-10-10T10:00:00-07:00 2026-10-10T10:05:00-07:00 \
  "Then kubectl get pods. Run pytest again."
note n3 sent 2026-10-10T11:00:00-07:00 2026-10-10T11:05:00-07:00 "kubectl logs"
note n4 draft 2026-10-10T12:00:00-07:00 "" "kubectl describe"

# --- a live Flow: a process holds the db open, rows only in the -wal ------
db="$work/flow/flow.sqlite"; mkdir -p "$work/flow"
cat > "$work/holder.py" <<'PY'
import sqlite3, sys, time
db, schema, ready = sys.argv[1:4]
con = sqlite3.connect(db, isolation_level=None)
con.execute("PRAGMA journal_mode=WAL")
con.executescript(open(schema).read())
con.execute("PRAGMA wal_autocheckpoint=0")
con.execute("BEGIN")
H = "INSERT INTO History(transcriptEntityId, asrText, formattedText, pastedText, timestamp, app) VALUES (?,?,?,?,?,?)"
for r in [
    ("h1", "x", "We deploy with cube control apply today. Build the dock her image, then run pie test now.", None,
     "2026-10-10 16:01:00.000 +00:00", "local.ferry"),
    ("h2", "x", "Then cube control get pods.", "", "2026-10-10 17:01:00.000 +00:00", "com.neovide.neovide"),
    ("h3", "x", "nope", "Run pie test again.", "2026-10-10T17:02:00Z", "com.neovide.neovide"),
    ("h4", "x", "cube control logs", None, "2026-10-10 18:01:00.000 +00:00", "com.apple.Safari"),
    ("h5", "x", "cube control describe", None, "2026-10-10 19:01:00.000 +00:00", "local.ferry"),
]:
    con.execute(H, r)
D = "INSERT INTO Dictionary(id, phrase, replacement, isDeleted) VALUES (?,?,?,?)"
con.execute(D, ("d1", "PyTest", None, 0))
con.execute(D, ("d2", "kubectl", None, 1))
con.execute("COMMIT")
open(ready, "w").close()
time.sleep(300)
PY
python3 "$work/holder.py" "$db" "$root/tests/fixtures/flow/schema.sql" "$work/ready" &
holder=$!
for _ in $(seq 100); do [ -e "$work/ready" ] && break; sleep 0.1; done
[ -e "$work/ready" ] || { echo "FAIL holder never got ready"; exit 1; }
check "rows live in the -wal, -shm present" "yes yes" \
  "$([ -s "$db-wal" ] && echo yes || echo no) $([ -e "$db-shm" ] && echo yes || echo no)"

sums() { # shasums of a db and whichever of its -wal and -shm exist
  for f in "$1" "$1-wal" "$1-shm"; do [ -e "$f" ] && shasum "$f" | cut -d' ' -f1; done | tr '\n' ' '; }
before_sums=$(sums "$db"); before_ls=$(ls -a "$work/flow")

out=$("$script" --flow-db "$db")
check "two notes fixing cube control → 2×, one-off hidden, other apps and drafts ignored" \
  "2× cube control → kubectl" "$out"
out=$("$script" --flow-db "$db" --min 1)
check "--min 1 shows the one-off" "2× cube control → kubectl
1× dock her → docker" "$out"
case "$out" in *"pie test"*) got=listed ;; *) got=skipped ;; esac
check "a Dictionary word is skipped (deleted entries are not)" skipped "$got"
out=$("$script" --flow-db "$db" --json)
check "--json" '[{"count": 2, "wrong": "cube control", "right": "kubectl"}]' "$out"
out=$("$script" --flow-db "$db" --apps com.apple.safari --min 1)
check "--apps picks other apps' rows instead" "1× cube control → kubectl" "$out"
out=$("$script" --flow-db "$db" --min 3)
check "nothing at --min 3" "no corrections seen in 3 or more notes" "$out"

check "live db, -wal and -shm byte-identical" "$before_sums" "$(sums "$db")"
check "no new files beside the live db" "$before_ls" "$(ls -a "$work/flow")"
check "temp copies removed" 0 "$(tmpd_left)"

# --- Flow crashed: db + -wal + a stale -shm, nobody holds it ----------------
crash="$work/crashed"; mkdir -p "$crash"
cp "$db" "$crash/flow.sqlite"; cp "$db-wal" "$crash/flow.sqlite-wal"; cp "$db-shm" "$crash/flow.sqlite-shm"
crash_sums=$(sums "$crash/flow.sqlite"); crash_ls=$(ls -a "$crash")
out=$("$script" --flow-db "$crash/flow.sqlite")
check "crashed db read through a copy" "2× cube control → kubectl" "$out"
check "crashed db, -wal and stale -shm byte-identical" "$crash_sums" "$(sums "$crash/flow.sqlite")"
check "no new files beside the crashed db" "$crash_ls" "$(ls -a "$crash")"

# --- Flow not running: db + -wal, no -shm; read through a temp copy -------
off="$work/offline"; mkdir -p "$off"
cp "$db" "$off/flow.sqlite"; cp "$db-wal" "$off/flow.sqlite-wal"
off_sums=$(sums "$off/flow.sqlite"); off_ls=$(ls -a "$off")
out=$("$script" --flow-db "$off/flow.sqlite")
check "offline db + -wal read through a copy" "2× cube control → kubectl" "$out"
check "offline db and -wal unchanged" "$off_sums" "$(sums "$off/flow.sqlite")"
check "no -shm or other file created offline" "$off_ls" "$(ls -a "$off")"

# --- held open, no -wal or -shm (rollback journal); case-insensitive count -
cn="$work/notes-case"; mkdir -p "$cn"
for i in 1 2 3; do
  FERRY_NOTES_DIR="$cn" note "c$i" sent "2026-10-11T0$i:00:00Z" "2026-10-11T0$i:05:00Z" "kubectl rocks"
done
held="$work/held"; mkdir -p "$held"
cat > "$work/holder2.py" <<'PY'
import sqlite3, sys, time
db, schema, ready = sys.argv[1:4]
con = sqlite3.connect(db, isolation_level=None)
con.executescript(open(schema).read())
H = "INSERT INTO History(transcriptEntityId, asrText, timestamp, app) VALUES (?,?,?,?)"
for r in [("k1", "cube control rocks", "2026-10-11T01:01:00Z", "local.ferry"),
          ("k2", "Cube control rocks", "2026-10-11T02:01:00Z", "local.ferry"),
          ("k3", "cube control rocks", "2026-10-11T03:01:00Z", "local.ferry")]:
    con.execute(H, r)
con.execute("BEGIN"); con.execute("SELECT count(*) FROM History").fetchone()
open(ready, "w").close()
time.sleep(300)
PY
python3 "$work/holder2.py" "$held/flow.sqlite" "$root/tests/fixtures/flow/schema.sql" "$work/ready2" &
holder2=$!
for _ in $(seq 100); do [ -e "$work/ready2" ] && break; sleep 0.1; done
check "held db has no -wal or -shm" "no no" \
  "$([ -e "$held/flow.sqlite-wal" ] && echo yes || echo no) $([ -e "$held/flow.sqlite-shm" ] && echo yes || echo no)"
held_sums=$(sums "$held/flow.sqlite"); held_ls=$(ls -a "$held")
out=$(FERRY_NOTES_DIR="$cn" "$script" --flow-db "$held/flow.sqlite" --min 1)
check "cube control and Cube control count as one pair, most common spelling shown" \
  "3× cube control → kubectl" "$out"
check "held db byte-identical" "$held_sums" "$(sums "$held/flow.sqlite")"
check "no new files beside the held db" "$held_ls" "$(ls -a "$held")"

# --- errors and the no-writes guard ----------------------------------------
"$script" --flow-db "$work/missing.sqlite" > "$work/o" 2> "$work/e"; rc=$?
check "missing --flow-db → exit 2" 2 "$rc"
check "missing --flow-db → one line, nothing on stdout" "1 0" \
  "$(wc -l < "$work/e" | tr -d ' ') $(wc -c < "$work/o" | tr -d ' ')"
"$script" --flow-db > /dev/null 2>&1; rc=$?
check "--flow-db without a path → exit 2" 2 "$rc"
bad="$work/corrupt"; mkdir -p "$bad"
head -c 65536 /dev/urandom > "$bad/flow.sqlite"
"$script" --flow-db "$bad/flow.sqlite" > "$work/o" 2> "$work/e"; rc=$?
check "corrupt db → exit 2, one line, temp copies removed" "2 1 0" \
  "$rc $(wc -l < "$work/e" | tr -d ' ') $(tmpd_left)"
torn="$work/torn"; mkdir -p "$torn"; cp "$off/flow.sqlite" "$torn/flow.sqlite"
python3 - "$torn/flow.sqlite" <<'PY'
import sys
p = sys.argv[1]
b = bytearray(open(p, "rb").read())
ps = int.from_bytes(b[16:18], "big")
for i in range(ps, len(b)):  # scramble every page after the first
    b[i] = (b[i] * 7 + 13) & 0xFF
open(p, "wb").write(b)
PY
"$script" --flow-db "$torn/flow.sqlite" > "$work/o" 2> "$work/e"; rc=$?
check "db that fails quick_check → exit 2, one line, temp copies removed" "2 1 0" \
  "$rc $(wc -l < "$work/e" | tr -d ' ') $(tmpd_left)"
check "no INSERT|UPDATE|DELETE|ATTACH in the script" 0 \
  "$(grep -Eciw 'INSERT|UPDATE|DELETE|ATTACH' "$script")"

[ "$fail" = 0 ] && echo "all corrections tests passed"
exit "$fail"
