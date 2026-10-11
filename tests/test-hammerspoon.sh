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
  check("default mods are ctrl+alt", "ctrl+alt", table.concat(b.mods, "+"))
  check("default key is v", "v", b.key)
  check("default: no Option-only warning", false, rec:hasLog("w", "Option-only"))
  check("default: bound ctrl+alt+v logged", true, rec:hasLog("i", "bound ctrl+alt+v"))
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
  rec.focusedWindow = rec:window({ id = 77, app = rec.frontmost })
  M.start({ captureSelection = false })
  rec:openURL("voicevim-start", {})
  check("start URL launches terminal once", 1, #rec.osascripts)
  local script = rec.osascripts[1] or ""
  check("realpath ran through hs.execute", true, (rec.executes[1] and rec.executes[1].cmd or ""):find("realpath", 1, true) ~= nil)
  check("script runs the repo session script", true, script:find(root .. "/bin/voice-vim-session", 1, true) ~= nil)
  check("script passes the target bundle", true, script:find("com.example.target", 1, true) ~= nil)
  check("script passes the focused window id", true, script:find("'com.example.target' '77'", 1, true) ~= nil)
  check("Ghostty is the default terminal", true, script:find('application "Ghostty"', 1, true) ~= nil)
  check("no keystrokes with captureSelection off", 0, #rec.keyStrokes)
  -- Clean up the temp file begin() wrote (and the os.tmpname placeholder).
  local file = script:match("'([^']*%-voice%-vim%.md)'")
  if file then os.remove(file); os.remove((file:gsub("%-voice%-vim%.md$", ""))) end
  check("temp file path found in script", true, file ~= nil)
end

-- No focused window: begin() still works and passes an empty window arg.
do
  local rec, M = fresh()
  rec.frontmost = rec:app({ bundleID = "com.example.target" })
  M.start({ captureSelection = false })
  local ok = pcall(M.begin)
  check("begin without focused window does not raise", true, ok)
  local script = rec.osascripts[1] or ""
  check("empty window arg when none focused", true, script:find("'com.example.target' ''", 1, true) ~= nil)
  local file = script:match("'([^']*%-voice%-vim%.md)'")
  if file then os.remove(file); os.remove((file:gsub("%-voice%-vim%.md$", ""))) end
end

-- Write a submit file the way the session script leaves it.
local function submitFile(text)
  local path = os.tmpname()
  local f = assert(io.open(path, "w"))
  f:write(text)
  f:close()
  return path
end

local function countAlerts(rec, needle)
  local n = 0
  for _, a in ipairs(rec.alerts) do
    if a:find(needle, 1, true) then n = n + 1 end
  end
  return n
end

-- Setup shared by the submit cases: the voice-vim terminal is frontmost,
-- the target app has window 4242.
local function submitSetup(focusOnFocus)
  local rec, M = fresh()
  local term = rec:app({ bundleID = "com.mitchellh.ghostty" })
  rec.frontmost = term
  rec.focusedWindow = rec:window({ id = 9, app = term })
  local target = rec:app({ bundleID = "com.example.target", frontmostOnActivate = focusOnFocus })
  rec:window({ id = 4242, app = target, focusOnFocus = focusOnFocus })
  M.start({ hotkey = { { "ctrl", "alt" }, "v" } })
  return rec, M
end

-- Submit where the target window comes to front: one global Cmd+V.
do
  local rec = submitSetup(true)
  local file = submitFile("hello there\n")
  rec:openURL("voicevim-submit", { file = file, target = "com.example.target", window = "4242" })
  rec:runTimers()
  check("delivered: one keystroke", 1, #rec.keyStrokes)
  local k = rec.keyStrokes[1] or { mods = {} }
  check("delivered: keystroke is cmd+v", "cmd+v", table.concat(k.mods, "+") .. "+" .. tostring(k.key))
  check("delivered: keystroke has no app argument", nil, k.app)
  check("delivered: target window focused", 4242, rec.focuses[1] and rec.focuses[1]:id())
  check("delivered: clipboard keeps the text", "hello there", rec.pasteboard.contents)
  check("delivered: no alert", 0, #rec.alerts)
  check("delivered: submit file removed", nil, io.open(file, "r"))
  check("delivered: logs target", true, rec:hasLog("i", "submit: target=com.example.target window=4242"))
  check("delivered: logs focus", true, rec:hasLog("i", "focusing window 4242"))
  check("delivered: logs frontmost check", true, rec:hasLog("i", "deliver: poll 1"))
  check("delivered: logs keystroke", true, rec:hasLog("i", "keystroke cmd+v posted"))
  check("delivered: logs clipboard", true, rec:hasLog("i", "deliver: clipboard set"))
  check("delivered: logs result", true, rec:hasLog("i", "submit: delivered"))
  check("delivered: hs.window.get called once", 1, rec.windowGets)
end

-- Submit where the target never comes to front: no paste, alert, text kept.
do
  local rec = submitSetup(false)
  local file = submitFile("never mind\n")
  rec:openURL("voicevim-submit", { file = file, target = "com.example.target", window = "4242" })
  rec:runTimers()
  check("unconfirmed: no keystroke", 0, #rec.keyStrokes)
  check("unconfirmed: alert shown", 1, countAlerts(rec, "copied — paste manually"))
  check("unconfirmed: clipboard holds the text", "never mind", rec.pasteboard.contents)
  check("unconfirmed: logged", true, rec:hasLog("w", "submit: unconfirmed"))
  check("unconfirmed: polled more than once", true, rec:hasLog("i", "deliver: poll 2"))
  check("unconfirmed: hs.window.get at most once over all polls", true, rec.windowGets <= 1)
end

-- Captured window closes before submit: falls back to the app by bundle id.
do
  local rec = submitSetup(true)
  rec:closeWindow(4242)
  local file = submitFile("window gone")
  rec:openURL("voicevim-submit", { file = file, target = "com.example.target", window = "4242" })
  rec:runTimers()
  check("closed window: app activated", 1, #rec.activations)
  check("closed window: one keystroke", 1, #rec.keyStrokes)
  check("closed window: hs.window.get at most once", true, rec.windowGets <= 1)
end

-- delivery.lua missing or erroring, or the repo root lookup erroring: no Lua
-- error escapes, the text stays on the clipboard, and an alert shows.
local tmpdir = assert(os.getenv("VV_TMP"))
local function fakeRoot(name, body)
  local dir = tmpdir .. "/" .. name
  os.execute("mkdir -p '" .. dir .. "/lua/voice-vim'")
  local f = assert(io.open(dir .. "/lua/voice-vim/delivery.lua", "w"))
  f:write(body)
  f:close()
  return dir
end
local broken = {
  { "delivery.lua missing", { root = tmpdir .. "/no-such-root" } },
  { "delivery.lua errors on load", { root = fakeRoot("load-error", 'error("load boom")') } },
  { "delivery.lua returns no table", { root = fakeRoot("no-table", "return 42") } },
  { "deliver() errors", { root = fakeRoot("deliver-error",
      'return { deliver = function() error("deliver boom") end }') } },
  { "deliver() errors in a timer", { root = fakeRoot("timer-error",
      'return { deliver = function(env) env.setClipboard("partial") '
      .. 'env.after(0.05, function() error("timer boom") end) end }') } },
  { "repo root lookup errors", { root = nil, executeErrors = true } },
}
for _, c in ipairs(broken) do
  local name, o = c[1], c[2]
  local rec = submitSetup(true)
  local M = stub.load(modpath)
  M.start({ hotkey = { { "ctrl", "alt" }, "v" }, root = o.root })
  if o.executeErrors then hs.execute = function() error("realpath boom") end end
  local file = submitFile("keep me\n")
  local ok, err = pcall(function()
    rec:openURL("voicevim-submit", { file = file, target = "com.example.target", window = "4242" })
    rec:runTimers()
  end)
  check(name .. ": no Lua error escapes", true, ok or tostring(err))
  check(name .. ": clipboard holds the text", "keep me", rec.pasteboard.contents)
  check(name .. ": alert shown", 1, countAlerts(rec, "copied — paste manually"))
  check(name .. ": no keystroke", 0, #rec.keyStrokes)
  check(name .. ": error logged", true, rec:hasLog("e", "text left on clipboard"))
end

-- No window id (old URL): falls back to activating the app by bundle id.
do
  local rec = submitSetup(true)
  local file = submitFile("by bundle")
  rec:openURL("voicevim-submit", { file = file, target = "com.example.target" })
  rec:runTimers()
  check("bundle only: app activated", 1, #rec.activations)
  check("bundle only: one keystroke", 1, #rec.keyStrokes)
end

-- No Accessibility: no keystroke, text left on the clipboard, alert.
do
  local rec = submitSetup(true)
  rec.accessibility = false
  local file = submitFile("no ax")
  rec:openURL("voicevim-submit", { file = file, target = "com.example.target", window = "4242" })
  rec:runTimers()
  check("no AX: no keystroke", 0, #rec.keyStrokes)
  check("no AX: alert", 1, countAlerts(rec, "Accessibility"))
  check("no AX: clipboard holds the text", "no ax", rec.pasteboard.contents)
end

-- Old activateDelay config key is accepted with a warning.
do
  local rec, M = fresh()
  local ok = pcall(M.start, { activateDelay = 0.25 })
  check("activateDelay accepted", true, ok)
  check("activateDelay warns", true, rec:hasLog("w", "confirmTimeout"))
  check("confirmTimeout default", 1.0, M.config.confirmTimeout)
end

os.exit(fail)
LUA

VV_ROOT="$root" VV_TMP="$tmp" perl -e 'alarm 20; exec @ARGV' nvim -l "$tmp/spec.lua" 2>&1
status=$?
echo  # nvim -l leaves the last line unterminated
if [ $status -eq 0 ]; then echo "all ok"; else echo "FAILED"; fi
exit $status
