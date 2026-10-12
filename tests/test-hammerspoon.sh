#!/usr/bin/env bash
# Hammerspoon module smoke test: loads hammerspoon/ferry.lua against the
# stub in tests/hs_stub.lua under `nvim -l`. Never touches the real
# Hammerspoon, opens no windows, sends no keystrokes.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d -t ferry-hs)
# The one-instance cases run a real ferry-host server; macOS socket
# paths max out at 104 bytes, so its folder is short.
swork=$(mktemp -d /tmp/ferryh.XXXX)
[ -n "$swork" ] && [ -d "$swork" ] || { echo "mktemp failed" >&2; exit 1; }
cleanup() {
  pkill -f -- "--listen $swork/" 2>/dev/null
  rm -rf "$tmp" "$swork"
}
trap cleanup EXIT
# nvim keeps its socket in a temp dir that it leaves behind when killed or
# on os.exit; keep those in ours too.
export TMPDIR=$swork/tmp
mkdir -p "$TMPDIR"
export FERRY_DB="$tmp/history.sqlite"
# Recording, failing fakes first on PATH: nothing reaches other apps.
mkdir -p "$swork/fakes" "$swork/empty"
for f in osascript open neovide; do
  printf '#!/bin/sh\n{ echo "CALL %s"; echo "$*"; } >> "%s/calls"\nexit 1\n' "$f" "$swork" > "$swork/fakes/$f"
  chmod +x "$swork/fakes/$f"
done
# A failing ghostty: ferry-host ensure finds no GUI settings.
printf '#!/bin/sh\nexit 1\n' > "$swork/fakes/ghostty"; chmod +x "$swork/fakes/ghostty"
# A fake ferry.app wrapper (its binary a symlink to the fake neovide).
mkdir -p "$swork/ferry.app/Contents/MacOS" "$swork/ferry.app/Contents/Resources"
: > "$swork/ferry.app/Contents/Info.plist"
ln -s "$swork/fakes/neovide" "$swork/ferry.app/Contents/MacOS/ferry"
: > "$swork/calls"
export PATH="$swork/fakes:$PATH" FERRY_NOTES_DIR="$swork/notes" FERRY_HOST_NVIM_FLAGS=--clean \
  FERRY_INDEX="$swork/index.sqlite" FERRY_OUTBOX="$swork/outbox"
unset FERRY_SOCK

cat > "$tmp/spec.lua" <<'LUA'
local root = assert(os.getenv("FERRY_ROOT"))
local stub = dofile(root .. "/tests/hs_stub.lua")
local modpath = root .. "/hammerspoon/ferry.lua"
local fail = 0

local function check(name, want, got)
  if want == got then
    print("ok   " .. name)
  else
    print("FAIL " .. name .. ": want '" .. tostring(want) .. "' got '" .. tostring(got) .. "'")
    fail = 1
  end
end

local swork = assert(os.getenv("FERRY_SWORK"))
-- A fake neovide on the search path: host.available() finds it. start()
-- only records its pre-warm hs.task (the stub never runs tasks). appPath:
-- never Joe's ~/Applications/ferry.app.
local noApp = swork .. "/none/ferry.app"
local found = { searchPath = { swork .. "/fakes" }, appPaths = {}, appPath = noApp }
local socks = 0

-- Fresh stub and module for each case; start() with a fake Neovide found
-- and its own socket.
local function fresh()
  local rec = stub.install()
  local M = stub.load(modpath)
  return rec, M
end
local function opts(cfg)
  cfg = cfg or {}
  socks = socks + 1
  if cfg.sock == nil then cfg.sock = swork .. "/s" .. socks .. ".sock" end
  if cfg.neovide == nil then cfg.neovide = found end
  return cfg
end

-- start() with defaults: both URL handlers, hotkey with the configured mods.
do
  local rec, M = fresh()
  M.start(opts())
  check("ferry-submit bound", "function", type(rec.urlBinds["ferry-submit"]))
  check("ferry-start bound", "function", type(rec.urlBinds["ferry-start"]))
  check("ferry-talk bound", "function", type(rec.urlBinds["ferry-talk"]))
  check("ferry-edit bound", "function", type(rec.urlBinds["ferry-edit"]))
  local edits = 0
  M._instance.showEdit = function() edits = edits + 1 end
  rec:openURL("ferry-edit", {})
  check("ferry-edit reaches the controller's showEdit", 1, edits)
  check("defaults: two hotkey binds", 2, #rec.hotkeyBinds)
  local b = rec.hotkeyBinds[1]
  check("hotkey mods are configured mods", table.concat(M.config.hotkey[1], "+"), table.concat(b.mods, "+"))
  check("hotkey key is configured key", M.config.hotkey[2], b.key)
  check("hotkey calls M.toggle", M.toggle, b.fn)
  check("hotkey object kept", b.obj, M.hotkeyObj)
  check("no bind error logged", false, rec:hasLog("e", "failed to bind"))
  check("bound line logged", true, rec:hasLog("i", "bound " .. table.concat(M.config.hotkey[1], "+")))
  check("default mods are ctrl+alt", "ctrl+alt", table.concat(b.mods, "+"))
  check("default key is v", "v", b.key)
  check("default: no Option-only warning", false, rec:hasLog("w", "Option-only"))
  check("default: bound ctrl+alt+v logged", true, rec:hasLog("i", "bound ctrl+alt+v"))
  check("hotkey: no released or repeat fn", "nil nil", tostring(b.released) .. " " .. tostring(b.rep))
  local tb = rec.hotkeyBinds[2] or {}
  check("talk: default ctrl+alt+b", "ctrl+alt+b", table.concat(tb.mods or {}, "+") .. "+" .. tostring(tb.key))
  check("talk: pressed is M.talkDown", M.talkDown, tb.fn)
  check("talk: released is M.talkUp", M.talkUp, tb.released)
  check("talk: no repeat fn", nil, tb.rep)
  check("talk: object kept", tb.obj, M.talkHotkeyObj)
  check("talk: bound ctrl+alt+b (talk) logged", true, rec:hasLog("i", "bound ctrl+alt+b (talk)"))
  check("defaults: no alert", 0, #rec.alerts)
end

-- talkHotkey = false: only the main hotkey, logged off.
do
  local rec, M = fresh()
  M.start(opts({ talkHotkey = false }))
  check("talkHotkey=false: one bind, the hotkey", "1 true",
    #rec.hotkeyBinds .. " " .. tostring(rec.hotkeyBinds[1].fn == M.toggle))
  check("talkHotkey=false: talk hotkey off logged", true, rec:hasLog("i", "talk hotkey off"))
  check("talkHotkey=false: no object, no alert", "nil 0", tostring(M.talkHotkeyObj) .. " " .. #rec.alerts)
end

-- The talk bind fails: error log and alert marked (talk); the hotkey still binds.
do
  local rec, M = fresh()
  rec.hotkeyBind = function(_, key)
    if key == "b" then return nil end
    return { delete = function() end }
  end
  M.start(opts())
  check("failing talk bind: logged with (talk)", true, rec:hasLog("e", "failed to bind ctrl+alt+b (talk)"))
  check("failing talk bind: one alert naming (talk) and ferry-talk", true,
    #rec.alerts == 1 and rec.alerts[1]:find("(talk)", 1, true) ~= nil
      and rec.alerts[1]:find("ferry-talk", 1, true) ~= nil)
  check("failing talk bind: hotkey still bound", true, rec:hasLog("i", "bound ctrl+alt+v"))
end

-- talkHotkey the same combo as the hotkey (other spelling): error, not bound.
do
  local rec, M = fresh()
  M.start(opts({ talkHotkey = { { "option", "control" }, "V" } }))
  check("same combo: one bind (the hotkey)", "1 true",
    #rec.hotkeyBinds .. " " .. tostring(rec.hotkeyBinds[1].fn == M.toggle))
  check("same combo: error logged", true, rec:hasLog("e", "is the same as the hotkey; not bound"))
  check("same combo: one alert", 1, #rec.alerts)
end

-- hammerspoon://ferry-talk?state=down|up reaches the controller's
-- talkDown/talkUp; another state warns and does nothing.
do
  local rec, M = fresh()
  M.start(opts())
  local calls = {}
  M._instance.talkDown = function() calls[#calls + 1] = "down" end
  M._instance.talkUp = function() calls[#calls + 1] = "up" end
  rec:openURL("ferry-talk", { state = "down" })
  rec:openURL("ferry-talk", { state = "up" })
  rec:openURL("ferry-talk", { state = "sideways" })
  rec:openURL("ferry-talk", {})
  check("ferry-talk: down then up reach talkDown, talkUp", "down,up", table.concat(calls, ","))
  check("ferry-talk: other states warn", 2, #rec:findLogs("w", "ferry-talk: state="))
  rec.hotkeyBinds[2].fn()
  rec.hotkeyBinds[2].released()
  check("talk hotkey: pressed/released reach talkDown, talkUp", "down,up,down,up", table.concat(calls, ","))
  M._instance.talkDown = function() error("talk boom") end
  M.talkDown()
  check("talkDown error: logged, one alert", "true 1",
    tostring(rec:hasLog("e", "talk boom")) .. " " .. #rec.alerts)
end

-- Explicit config: mods passed through, no Option-only warning.
do
  local rec, M = fresh()
  M.start(opts({ hotkey = { { "ctrl", "alt" }, "v" } }))
  check("configured ctrl+alt mods", "ctrl+alt", table.concat(rec.hotkeyBinds[1].mods, "+"))
  check("ctrl+alt: no Option-only warning", false, rec:hasLog("w", "Option-only"))
  check("ctrl+alt: no alert", 0, #rec.alerts)
end

-- Option-only hotkey warns.
do
  local rec, M = fresh()
  M.start(opts({ hotkey = { { "alt" }, "v" } }))
  check("Option-only warning logged", true, rec:hasLog("w", "Option-only"))
  check("Option-only still binds (and the talk hotkey)", 2, #rec.hotkeyBinds)
end

-- hs.hotkey.bind returns nil: error log and alert.
do
  local rec, M = fresh()
  rec.hotkeyBind = function() return nil end
  M.start(opts({ hotkey = { { "ctrl", "alt" }, "v" }, talkHotkey = false }))
  check("nil bind logs error", true, rec:hasLog("e", "failed to bind ctrl+alt+v"))
  check("nil bind alerts", 1, #rec.alerts)
  check("nil bind keeps no hotkey object", nil, M.hotkeyObj)
  check("URL start still bound after failed bind", "function", type(rec.urlBinds["ferry-start"]))
end

-- hs.hotkey.bind errors: error log with the message, alert, start() returns.
do
  local rec, M = fresh()
  rec.hotkeyBind = function() error("refused by macOS") end
  local ok = pcall(M.start, opts({ hotkey = { { "ctrl", "alt" }, "v" }, talkHotkey = false }))
  check("erroring bind does not raise", true, ok)
  check("erroring bind logs error", true, rec:hasLog("e", "refused by macOS"))
  check("erroring bind alerts", 1, #rec.alerts)
end

-- Re-running start() deletes the previous hotkey.
do
  local rec, M = fresh()
  M.start(opts({ hotkey = { { "ctrl", "alt" }, "v" } }))
  local first, firstTalk = M.hotkeyObj, M.talkHotkeyObj
  M.start(opts())
  check("restart deletes old hotkey and talk hotkey", "true true",
    tostring(first.deleted) .. " " .. tostring(firstTalk.deleted))
  check("restart binds both again", 4, #rec.hotkeyBinds)
end

-- Write a submit file the way the note leaves it.
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

-- Setup shared by the submit cases: Neovide is frontmost, the target app
-- has window 4242. ferry-submit goes through the instance (hide, then
-- M.submit).
local function submitSetup(focusOnFocus)
  local rec, M = fresh()
  local nv = rec:app({ bundleID = "com.neovide.neovide" })
  rec.frontmost = nv
  rec.focusedWindow = rec:window({ id = 9, app = nv })
  local target = rec:app({ bundleID = "com.example.target", frontmostOnActivate = focusOnFocus })
  rec:window({ id = 4242, app = target, focusOnFocus = focusOnFocus })
  M.start(opts({ hotkey = { { "ctrl", "alt" }, "v" } }))
  return rec, M
end

-- Submit where the target window comes to front: one global Cmd+V.
do
  local rec = submitSetup(true)
  local file = submitFile("hello there\n")
  rec:openURL("ferry-submit", { file = file, target = "com.example.target", window = "4242" })
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
  rec:openURL("ferry-submit", { file = file, target = "com.example.target", window = "4242" })
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
  rec:openURL("ferry-submit", { file = file, target = "com.example.target", window = "4242" })
  rec:runTimers()
  check("closed window: app activated", 1, #rec.activations)
  check("closed window: one keystroke", 1, #rec.keyStrokes)
  check("closed window: hs.window.get at most once", true, rec.windowGets <= 1)
end

-- delivery.lua missing or erroring, or the repo root lookup erroring: no Lua
-- error escapes, the text stays on the clipboard, and an alert shows.
local tmpdir = assert(os.getenv("FERRY_TMP"))
local function fakeRoot(name, body)
  local dir = tmpdir .. "/" .. name
  os.execute("mkdir -p '" .. dir .. "/lua/ferry'")
  local f = assert(io.open(dir .. "/lua/ferry/delivery.lua", "w"))
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
  local rec, M = submitSetup(true)
  M.config.root = o.root
  if o.executeErrors then hs.execute = function() error("realpath boom") end end
  local file = submitFile("keep me\n")
  local ok, err = pcall(function()
    M.submit({ file = file, target = "com.example.target", window = "4242" })
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
  rec:openURL("ferry-submit", { file = file, target = "com.example.target" })
  rec:runTimers()
  check("bundle only: app activated", 1, #rec.activations)
  check("bundle only: one keystroke", 1, #rec.keyStrokes)
end

-- No Accessibility: no keystroke, text left on the clipboard, alert.
do
  local rec = submitSetup(true)
  rec.accessibility = false
  local file = submitFile("no ax")
  rec:openURL("ferry-submit", { file = file, target = "com.example.target", window = "4242" })
  rec:runTimers()
  check("no AX: no keystroke", 0, #rec.keyStrokes)
  check("no AX: alert", 1, countAlerts(rec, "Accessibility"))
  check("no AX: clipboard holds the text", "no ax", rec.pasteboard.contents)
end

-- Obsolete config keys (activateDelay, and the removed new-window-per-press
-- path's mode = "session", terminal, autoStartFlow, windowTitle): a warning
-- each, ignored, and the one instance still starts with no alert.
do
  local rec, M = fresh()
  local ok = pcall(M.start, opts({ activateDelay = 0.25, mode = "session", terminal = "iTerm2",
    autoStartFlow = true, windowTitle = "x" }))
  check("obsolete keys: accepted", true, ok)
  check("activateDelay warns", true, rec:hasLog("w", "activateDelay is no longer used; set confirmTimeout"))
  check("mode = session warns", true, rec:hasLog("w", "mode = session is no longer used"))
  check("terminal warns", true, rec:hasLog("w", "terminal is no longer used"))
  check("autoStartFlow warns", true, rec:hasLog("w", "autoStartFlow is no longer used"))
  check("windowTitle warns", true, rec:hasLog("w", "windowTitle is no longer used"))
  check("obsolete keys: dropped from config", "nil nil nil nil nil",
    tostring(M.config.activateDelay) .. " " .. tostring(M.config.mode) .. " " .. tostring(M.config.terminal)
    .. " " .. tostring(M.config.autoStartFlow) .. " " .. tostring(M.config.windowTitle))
  check("obsolete keys: still the one instance, no alert", "instance 0", M.mode .. " " .. #rec.alerts)
  check("confirmTimeout default", 1.0, M.config.confirmTimeout)
end

-- mode = "instance" is accepted silently.
do
  local rec, M = fresh()
  M.start(opts({ mode = "instance" }))
  check("mode = instance: no warning", false, rec:hasLog("w", "is no longer used"))
end

-- --- One instance ----------------------------------------------------------
local hostbin = root .. "/bin/ferry-host"
local NEOVIDE = "com.neovide.neovide"
local function sh(cmd)
  local p = io.popen(cmd .. " 2>&1")
  local out = p:read("*a")
  p:close()
  return (out:gsub("%s+$", ""))
end
local function has(s, needle) return (s or ""):find(needle, 1, true) ~= nil end
local function count(list, x)
  local k = 0
  for _, v in ipairs(list) do if v == x then k = k + 1 end end
  return k
end
local function hostSh(sock, sub)
  return sh("FERRY_SOCK='" .. sock .. "' '" .. hostbin .. "' " .. sub)
end
-- Anything that would open a window other than our Neovide: an AppleScript
-- (the removed Ghostty window per press) or a command naming a terminal.
local function otherWindows(rec)
  local n = #rec.osascripts
  for _, e in ipairs(rec.executes) do
    if has(e.cmd, "Ghostty") or has(e.cmd, "iTerm") then n = n + 1 end
  end
  return n
end

-- Neovide not installed: one alert at start, each press alerts again and
-- does nothing else (no fallback window, no server, no URL handlers).
do
  local rec = stub.install()
  local M = stub.load(modpath)
  rec.frontmost = rec:app({ bundleID = "com.example.target" })
  M.start({ neovide = { searchPath = { swork .. "/empty" }, appPaths = {}, appPath = noApp } })
  local NO = "ferry: Neovide is not installed — run ./install.sh"
  check("Neovide missing: not running", "unavailable", M.mode)
  check("Neovide missing: one alert", 1, #rec.alerts)
  check("Neovide missing: alert says run install.sh", NO, rec.alerts[1])
  check("Neovide missing: logs the brew command", true, rec:hasLog("e", "brew install --cask neovide-app"))
  check("Neovide missing: hotkey still bound to toggle", M.toggle, rec.hotkeyBinds[1] and rec.hotkeyBinds[1].fn)
  check("Neovide missing: no server pre-warm", 0, #rec.tasks)
  check("Neovide missing: ferry-submit and ferry-hide not bound", "nil nil",
    tostring(rec.urlBinds["ferry-submit"]) .. " " .. tostring(rec.urlBinds["ferry-hide"]))
  rec.hotkeyBinds[1].fn()
  rec:openURL("ferry-start", {})
  rec:runTimers()
  check("Neovide missing: each press alerts again", "3 " .. NO, #rec.alerts .. " " .. tostring(rec.alerts[3]))
  check("Neovide missing: a press opens nothing", "0 0 0",
    otherWindows(rec) .. " " .. #rec.tasks .. " " .. #rec.keyStrokes)
  local tb = rec.hotkeyBinds[2]
  check("Neovide missing: talk hotkey still bound", M.talkDown, tb and tb.fn)
  tb.fn()
  tb.released()
  rec:openURL("ferry-talk", { state = "down" })
  rec:openURL("ferry-talk", { state = "up" })
  rec:runTimers()
  check("Neovide missing: talk down alerts like a press, up adds nothing", "5 " .. NO,
    #rec.alerts .. " " .. tostring(rec.alerts[5]))
  local flowRuns = 0
  for _, t in ipairs(rec.tasks) do
    if has(t.path, "wispr-flow") or has(table.concat(t.args or {}, " "), "wispr-flow") then flowRuns = flowRuns + 1 end
  end
  for _, e in ipairs(rec.executes) do if has(e.cmd, "wispr-flow") then flowRuns = flowRuns + 1 end end
  check("Neovide missing: talk never starts Flow (no task or command with wispr-flow)", "0 0",
    flowRuns .. " " .. #rec.tasks)
end

-- The ferry.app wrapper: config appPath reaches the host, which finds it
-- (even with no other Neovide) and logs that it uses it. false: plain only.
do
  local rec = stub.install()
  local M = stub.load(modpath)
  M.start(opts({ appPath = swork .. "/ferry.app", neovide = { searchPath = { swork .. "/empty" }, appPaths = {} } }))
  check("ferry.app: config appPath -> instance mode", "instance 0", M.mode .. " " .. #rec.alerts)
  check("ferry.app: host logs it uses ferry.app", true, rec:hasLog("i", "neovide: using ferry.app at " .. swork .. "/ferry.app"))
  rec = stub.install()
  M = stub.load(modpath)
  M.start(opts({ appPath = false, neovide = { searchPath = { swork .. "/empty" }, appPaths = {} } }))
  check("ferry.app: appPath = false and no Neovide -> unavailable", "unavailable", M.mode)
  check("ferry.app: appPath = false logs plain Neovide", true, rec:hasLog("i", "using plain Neovide"))
end

-- Setting up the one instance raises in start(): one alert with the error,
-- and each press alerts again.
do
  local bad = swork .. "/badroot"
  sh("mkdir -p '" .. bad .. "/hammerspoon/hosts' && ln -s '" .. root .. "/bin' '" .. root .. "/lua' '" .. bad .. "/'"
    .. " && ln -s '" .. root .. "/hammerspoon/window-frame.lua' '" .. bad .. "/hammerspoon/'"
    .. " && ln -s '" .. root .. "/hammerspoon/hosts/neovide.lua' '" .. bad .. "/hammerspoon/hosts/'"
    .. " && echo 'error(\"instance boom\")' > '" .. bad .. "/hammerspoon/instance.lua'")
  local rec = stub.install()
  local M = stub.load(modpath)
  rec.frontmost = rec:app({ bundleID = "com.example.target" })
  local ok = pcall(M.start, { root = bad, captureSelection = false, neovide = found })
  check("setup error: start() does not raise", true, ok)
  check("setup error: not running", "unavailable", M.mode)
  check("setup error: one alert", 1, #rec.alerts)
  check("setup error: alert carries the error", true,
    has(rec.alerts[1], "setup failed") and has(rec.alerts[1], "instance boom"))
  check("setup error: logged", true, rec:hasLog("e", "instance boom"))
  check("setup error: hotkey bound to toggle", M.toggle, rec.hotkeyBinds[1] and rec.hotkeyBinds[1].fn)
  rec.hotkeyBinds[1].fn()
  check("setup error: a press alerts again", "2 true", #rec.alerts .. " " .. tostring(rec.alerts[2] == rec.alerts[1]))
  check("setup error: a press opens nothing", 0, otherWindows(rec))
end

-- The server pre-warm fails: the mode was decided at start() and stays the
-- one instance. A press (here during the pre-warm) runs ensure again, and
-- alerts when that fails too; it never opens another window.
do
  local rec = stub.install()
  rec.execStatus = true
  local M = stub.load(modpath)
  local target = rec:app({ bundleID = "com.example.target" })
  local tw = rec:window({ id = 4242, app = target })
  target._window = tw
  rec.frontmost, rec.focusedWindow = target, tw
  M.start({ sock = swork .. "/f.sock", captureSelection = false, neovide = found })
  check("ensure fails: instance mode at start()", "instance", M.mode)
  rec.hotkeyBinds[1].fn()  -- during the pre-warm: waits for it
  rec:finishTask(1, 1, "", "nvim not found")
  check("ensure fails: stays in instance mode", "instance", M.mode)
  check("ensure fails: hotkey is still toggle", M.toggle, rec.hotkeyBinds[1].fn)
  check("ensure fails: ferry-hide still bound", "function", type(rec.urlBinds["ferry-hide"]))
  check("ensure fails: the press runs ensure again", true,
    #rec.tasks == 2 and has(rec.tasks[2].args[2], "'ensure'") and rec.tasks[2].started)
  check("ensure fails: no alert while recovering", 0, #rec.alerts)
  rec:finishTask(2, 1, "", "nvim not found")
  check("ensure fails twice: one alert", true,
    #rec.alerts == 1 and has(rec.alerts[1], "could not open the note"))
  check("ensure fails: never another window", 0, otherWindows(rec))
  rec.hotkeyBinds[1].fn()  -- the next press tries again
  check("ensure fails: next press runs ensure again", true,
    #rec.tasks == 3 and has(rec.tasks[3].args[2], "'ensure'"))
  rec:finishTask(3, 1, "", "nvim not found")
  check("ensure fails: still no other window", 0, otherWindows(rec))
end

-- Setup raises after the controller was built (here in prewarm, with a show
-- already waiting for it): not running, and the half-built controller is
-- disabled so it can never show Neovide (pending show dropped, URL
-- handlers unbound).
do
  local bad = swork .. "/badroot2"
  sh("mkdir -p '" .. bad .. "/hammerspoon/hosts' && ln -s '" .. root .. "/bin' '" .. root .. "/lua' '" .. bad .. "/'"
    .. " && ln -s '" .. root .. "/hammerspoon/window-frame.lua' '" .. bad .. "/hammerspoon/'"
    .. " && ln -s '" .. root .. "/hammerspoon/hosts/neovide.lua' '" .. bad .. "/hammerspoon/hosts/'")
  local f = assert(io.open(bad .. "/hammerspoon/instance.lua", "w"))
  f:write("local I = dofile('" .. root .. "/hammerspoon/instance.lua')\n"
    .. "local new = I.new\n"
    .. "I.new = function(cfg)\n"
    .. "  local c = new(cfg)\n"
    .. "  local pw = c.prewarm\n"
    .. "  c.prewarm = function(cb)\n"
    .. "    pw(cb)\n"
    .. "    c._afterWarm = function() _G.FERRY_SHOWN = true end\n"
    .. "    error('prewarm boom')\n"
    .. "  end\n"
    .. "  _G.FERRY_BUILT = c\n"
    .. "  return c\n"
    .. "end\n"
    .. "return I\n")
  f:close()
  local rec = stub.install()
  local M = stub.load(modpath)
  rec.frontmost = rec:app({ bundleID = "com.example.target" })
  _G.FERRY_BUILT, _G.FERRY_SHOWN = nil, nil
  M.start({ root = bad, sock = swork .. "/g.sock", captureSelection = false, neovide = found })
  check("late setup error: not running, one alert", "unavailable 1", M.mode .. " " .. #rec.alerts)
  check("late setup error: logged", true, rec:hasLog("e", "prewarm boom"))
  local c = _G.FERRY_BUILT
  check("late setup error: controller disabled, pending show dropped", "true nil",
    tostring(c and c._disabled) .. " " .. tostring(c and c._afterWarm))
  check("late setup error: ferry-hide unbound", nil, rec.urlBinds["ferry-hide"])
  rec:finishTask(1, 0, "", "")  -- the pre-warm finishes later
  check("late setup error: the dropped show never runs", nil, _G.FERRY_SHOWN)
  c.toggle()
  local shows = 0
  for _, e in ipairs(rec.executes) do if has(e.cmd, "'show'") then shows = shows + 1 end end
  check("late setup error: the disabled controller shows nothing", "0 0", shows .. " " .. #rec.unhides)
  check("late setup error: hotkey bound to toggle", M.toggle, rec.hotkeyBinds[1] and rec.hotkeyBinds[1].fn)
  rec.hotkeyBinds[1].fn()
  check("late setup error: a press alerts again", true, #rec.alerts == 2 and has(rec.alerts[2], "prewarm boom"))
end

-- One instance: the hotkey toggles Neovide, start() pre-warms once, submit
-- hides Neovide before the Cmd+V, and no other window is ever opened.
do
  local rec = stub.install()
  rec.execStatus = true
  local sock = swork .. "/i.sock"
  local target = rec:app({ bundleID = "com.example.target" })
  local tw = rec:window({ id = 4242, app = target })
  target._window = tw
  rec.frontmost, rec.focusedWindow = target, tw
  local M = stub.load(modpath)
  local cmdlines = {}
  M.start({ sock = sock, neovide = { searchPath = found.searchPath, appPaths = {}, appPath = noApp,
    commandLine = function(pid) return cmdlines[pid] end } })
  check("instance: Neovide found -> instance mode, no alert", "instance 0", M.mode .. " " .. #rec.alerts)
  local b = rec.hotkeyBinds[1]
  check("instance: hotkey function is toggle", M.toggle, b and b.fn)
  local ensures = 0
  for _, t in ipairs(rec.tasks) do if has(t.args[2], "'ensure'") and t.started then ensures = ensures + 1 end end
  check("instance: start() creates one ensure hs.task", "1 1", #rec.tasks .. " " .. ensures)
  check("instance: ensure uses the socket", true, has(rec.tasks[1].args[2], sock))
  check("instance: ferry-hide and ferry-submit bound", "function function",
    type(rec.urlBinds["ferry-hide"]) .. " " .. type(rec.urlBinds["ferry-submit"]))
  hostSh(sock, "ensure")  -- what the pre-warm task does
  rec:finishTask(1, 0, "", "")
  b.fn()
  local shown = 0
  for _, e in ipairs(rec.executes) do if has(e.cmd, "'show' 'com.example.target' '4242'") then shown = shown + 1 end end
  check("instance: press runs show com.example.target 4242", 1, shown)
  check("instance: no Cmd+C on press (captureSelection off)", 0, #rec.keyStrokes)
  check("instance: uis=0 -> Neovide launched with --server <sock>", true,
    rec.tasks[2] ~= nil and has(rec.tasks[2].args[2], "--server '" .. sock .. "'"))
  local nv = rec:app({ bundleID = NEOVIDE, name = "Neovide", windows = {}, pid = 9001 })
  cmdlines[9001] = swork .. "/fakes/neovide --server " .. sock
  local nw = rec:window({ id = 60, app = nv })
  nv._window, nv._windows[1] = nw, nw
  rec:runTimers()
  check("instance: Neovide frontmost after the press", true, rec.frontmost == nv)
  check("instance: logs show: host focused after", true, rec:hasLog("i", "show: host focused after"))

  local file = submitFile("from the note\n")
  local hidesAtPaste
  rec.onKeyStroke = function(_, key) if key == "v" then hidesAtPaste = count(rec.hides, nv) end end
  rec:openURL("ferry-submit", { file = file, target = "com.example.target", window = "4242" })
  rec:runTimers()
  check("instance: submit URL calls host.hide before Cmd+V", 1, hidesAtPaste)
  check("instance: one Cmd+V after focusing 4242", "1 4242",
    #rec.keyStrokes .. " " .. tostring(rec.focuses[#rec.focuses] and rec.focuses[#rec.focuses]:id()))
  check("instance: delivered, text on the clipboard", "true from the note",
    tostring(rec:hasLog("i", "submit: delivered")) .. " " .. tostring(rec.pasteboard.contents))
  check("instance: submit file removed", nil, io.open(file, "r"))

  rec:openURL("ferry-start", {})  -- shows again, like the hotkey
  rec:runTimers()
  check("instance: ferry-start shows Neovide", true, rec.frontmost == nv)
  b.fn()  -- Neovide focused: keep the draft, hide, refocus 4242
  local drafts = 0
  for _, e in ipairs(rec.executes) do if has(e.cmd, "'draft'") then drafts = drafts + 1 end end
  check("instance: press while shown runs draft and hides", "1 2", drafts .. " " .. count(rec.hides, nv))
  check("instance: press while shown refocuses 4242", tw, rec.focuses[#rec.focuses])
  check("instance: the hotkey never opens another window", 0, otherWindows(rec))
  hostSh(sock, "stop")
end

os.exit(fail)
LUA

FERRY_ROOT="$root" FERRY_TMP="$tmp" FERRY_SWORK="$swork" perl -e 'alarm 60; exec @ARGV' nvim -l "$tmp/spec.lua" 2>&1
status=$?
echo  # nvim -l leaves the last line unterminated

check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want '$2' got '$3'"; status=1; fi; }
check "fake osascript/open/neovide never called" 0 "$(grep -c '^CALL ' "$swork/calls")"
lj=$(command -v luajit || echo /opt/homebrew/bin/luajit)
if [ -x "$lj" ]; then
  for f in "$root"/hammerspoon/*.lua "$root"/hammerspoon/hosts/*.lua; do
    check "$(basename "$f") parses under LuaJIT" ok "$("$lj" -e "assert(loadfile('$f')) print('ok')" 2>&1)"
  done
fi
if [ $status -eq 0 ]; then echo "all ok"; else echo "FAILED"; fi
exit $status
