#!/usr/bin/env bash
# Delivery core: lua/voice-vim/delivery.lua with a fake env and clock.
# Runs the spec under LuaJIT and under nvim -l; also Lua 5.4 when installed.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
spec="$root/tests/delivery_spec.lua"
fail=0
ran=0
run() { # label cmd...
  local label=$1; shift
  echo "== $label"
  "$@" "$spec" 2>&1 || fail=1 # nvim -l prints to stderr
  [ "$1" = nvim ] && echo # nvim -l leaves the last line unterminated
  ran=1
}
command -v luajit >/dev/null && run luajit luajit
command -v nvim   >/dev/null && run "nvim -l" nvim -l
for l in lua5.4 lua54 lua; do
  if command -v "$l" >/dev/null && "$l" -v 2>&1 | grep -q 'Lua 5.4'; then run "$l" "$l"; break; fi
done
if [ "$ran" = 0 ]; then echo "FAIL no Lua interpreter (luajit or nvim) found"; fail=1; fi
exit $fail
