#!/usr/bin/env bash
# Fix-ups: lua/ferry/fixup.lua. tests/fixup_spec.lua runs the line
# functions under LuaJIT, then everything (buffer commands and maps) under
# headless nvim (--clean). FERRY_FIXUPS and HOME point into a temp dir, so
# ~/.config/ferry is never read.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d /tmp/ferryfx.XXXX)
[ -n "$work" ] && [ -d "$work" ] || { echo "mktemp failed" >&2; exit 1; }
trap 'rm -rf "$work"' EXIT
export HOME="$work" FERRY_FIXUPS="$work/fixups.txt"
spec="$root/tests/fixup_spec.lua"
fail=0

if command -v luajit >/dev/null; then
  echo "== luajit"
  luajit "$spec" "$root" "$work" || fail=1
  echo "== default path (FERRY_FIXUPS unset)"
  got=$(env -u FERRY_FIXUPS luajit -e "print(dofile('$root/lua/ferry/fixup.lua').path())")
  if [ "$got" = "$work/.config/ferry/fixups.txt" ]; then
    echo "ok   default path is \$HOME/.config/ferry/fixups.txt"
  else
    echo "FAIL default path: got '$got'"; fail=1
  fi
fi

echo "== nvim --headless"
# nvim -l prints to stderr and leaves the last line unterminated.
perl -e 'alarm 60; exec @ARGV' nvim --headless --clean -l "$spec" "$root" "$work" 2>&1 || fail=1
echo
exit $fail
