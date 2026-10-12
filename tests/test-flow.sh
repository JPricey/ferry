#!/usr/bin/env bash
# Flow toggle core in lua/ferry/flow.lua: tests/flow_spec.lua under
# headless nvim (--clean). A recording fake `open` is first on PATH, so
# nothing reaches Wispr Flow. A URL containing "hang" makes it hang.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d /tmp/ferryf.XXXX)
[ -n "$work" ] && [ -d "$work" ] || { echo "mktemp failed" >&2; exit 1; }
trap 'rm -rf "$work"' EXIT
# nvim keeps its socket in a temp dir that it leaves behind when killed or
# on os.exit; keep those in ours too.
export TMPDIR=$work/tmp
mkdir -p "$TMPDIR"

mkdir -p "$work/bin"
cat >"$work/bin/open" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$work/open.log"
case "\$*" in *hang*) exec sleep 30 ;; esac
exit 0
EOF
chmod +x "$work/bin/open"
export PATH="$work/bin:$PATH"

# nvim -l prints to stderr and leaves the last line unterminated.
perl -e 'alarm 60; exec @ARGV' nvim --headless --clean -l "$root/tests/flow_spec.lua" "$root" "$work" 2>&1
status=$?
echo
exit $status
