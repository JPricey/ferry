#!/usr/bin/env bash
# Hammerspoon module smoke test: loads hammerspoon/voice-vim.lua against the
# stub in tests/hs_stub.lua under `nvim -l`. Never touches the real
# Hammerspoon, opens no windows, sends no keystrokes.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d -t vv-hs)
trap 'rm -rf "$tmp"' EXIT
export VOICE_VIM_DB="$tmp/history.sqlite"

cat > "$tmp/spec.lua" <<'LUA'
local root = assert(os.getenv("VV_ROOT"))
local stub = dofile(root .. "/tests/hs_stub.lua")
local modpath = root .. "/hammerspoon/voice-vim.lua"
local fail = 0

local function check(name, want, got)
  if want == got then
    print("ok   " .. name)
  else
    print("FAIL " .. name .. ": want '" .. tostring(want) .. "' got '" .. tostring(got) .. "'")
    fail = 1
  end
end

-- Fresh stub and module for each case.
local function fresh()
  local rec = stub.install()
  return rec, stub.load(modpath)
end

-- start() with defaults: both URL handlers, hotkey with the configured mods.
do
  local rec, M = fresh()
  M.start()
  check("voicevim-submit bound", "function", type(rec.urlBinds["voicevim-submit"]))
  check("voicevim-start bound", "function", type(rec.urlBinds["voicevim-start"]))
  check("one hotkey bind", 1, #rec.hotkeyBinds)
  local b = rec.hotkeyBinds[1]
  check("hotkey mods are configured mods", table.concat(M.config.hotkey[1], "+"), table.concat(b.mods, "+"))
  check("hotkey key is configured key", M.config.hotkey[2], b.key)
  check("hotkey calls M.begin", M.begin, b.fn)
  check("hotkey object kept", b.obj, M.hotkeyObj)
  check("no bind error logged", false, rec:hasLog("e", "failed to bind"))
  check("bound line logged", true, rec:hasLog("i", "bound " .. table.concat(M.config.hotkey[1], "+")))
end

-- Explicit config: mods passed through, no Option-only warning.
do
  local rec, M = fresh()
  M.start({ hotkey = { { "ctrl", "alt" }, "v" } })
  check("configured ctrl+alt mods", "ctrl+alt", table.concat(rec.hotkeyBinds[1].mods, "+"))
  check("ctrl+alt: no Option-only warning", false, rec:hasLog("w", "Option-only"))
  check("ctrl+alt: no alert", 0, #rec.alerts)
end

-- Option-only hotkey warns.
do
  local rec, M = fresh()
  M.start({ hotkey = { { "alt" }, "v" } })
  check("Option-only warning logged", true, rec:hasLog("w", "Option-only"))
  check("Option-only still binds", 1, #rec.hotkeyBinds)
end

-- hs.hotkey.bind returns nil: error log and alert.
do
  local rec, M = fresh()
  rec.hotkeyBind = function() return nil end
  M.start({ hotkey = { { "ctrl", "alt" }, "v" } })
  check("nil bind logs error", true, rec:hasLog("e", "failed to bind ctrl+alt+v"))
  check("nil bind alerts", 1, #rec.alerts)
  check("nil bind keeps no hotkey object", nil, M.hotkeyObj)
  check("URL start still bound after failed bind", "function", type(rec.urlBinds["voicevim-start"]))
end

-- hs.hotkey.bind errors: error log with the message, alert, start() returns.
do
  local rec, M = fresh()
  rec.hotkeyBind = function() error("refused by macOS") end
  local ok = pcall(M.start, { hotkey = { { "ctrl", "alt" }, "v" } })
  check("erroring bind does not raise", true, ok)
  check("erroring bind logs error", true, rec:hasLog("e", "refused by macOS"))
  check("erroring bind alerts", 1, #rec.alerts)
end

-- Re-running start() deletes the previous hotkey.
do
  local rec, M = fresh()
  M.start({ hotkey = { { "ctrl", "alt" }, "v" } })
  local first = M.hotkeyObj
  M.start()
  check("restart deletes old hotkey", true, first.deleted)
  check("restart binds again", 2, #rec.hotkeyBinds)
end

-- hammerspoon://voicevim-start runs begin(): repo root via realpath, and the
-- session command goes to the terminal AppleScript with the frontmost bundle.
do
  local rec, M = fresh()
  rec.frontmost = rec:app({ bundleID = "com.example.target", name = "Target" })
  M.start({ captureSelection = false })
  rec:openURL("voicevim-start", {})
  check("start URL launches terminal once", 1, #rec.osascripts)
  local script = rec.osascripts[1] or ""
  check("realpath ran through hs.execute", true, (rec.executes[1] and rec.executes[1].cmd or ""):find("realpath", 1, true) ~= nil)
  check("script runs the repo session script", true, script:find(root .. "/bin/voice-vim-session", 1, true) ~= nil)
  check("script passes the target bundle", true, script:find("com.example.target", 1, true) ~= nil)
  check("Ghostty is the default terminal", true, script:find('application "Ghostty"', 1, true) ~= nil)
  check("no keystrokes with captureSelection off", 0, #rec.keyStrokes)
  -- Clean up the temp file begin() wrote (and the os.tmpname placeholder).
  local file = script:match("'([^']*%-voice%-vim%.md)'")
  if file then os.remove(file); os.remove((file:gsub("%-voice%-vim%.md$", ""))) end
  check("temp file path found in script", true, file ~= nil)
end

os.exit(fail)
LUA

VV_ROOT="$root" perl -e 'alarm 20; exec @ARGV' nvim -l "$tmp/spec.lua" 2>&1
status=$?
echo  # nvim -l leaves the last line unterminated
if [ $status -eq 0 ]; then echo "all ok"; else echo "FAILED"; fi
exit $status
