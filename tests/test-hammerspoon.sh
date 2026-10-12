#!/usr/bin/env bash
# Hammerspoon module smoke test: loads hammerspoon/voice-vim.lua against the
# stub in tests/hs_stub.lua under `nvim -l`. Never touches the real
# Hammerspoon, opens no windows, sends no keystrokes.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d -t vv-hs)
# The one-instance cases run a real voice-vim-host server; macOS socket
# paths max out at 104 bytes, so its folder is short.
swork=$(mktemp -d /tmp/vvh.XXXX)
[ -n "$swork" ] && [ -d "$swork" ] || { echo "mktemp failed" >&2; exit 1; }
cleanup() {
  pkill -f -- "--listen $swork/" 2>/dev/null
  rm -rf "$tmp" "$swork"
}
trap cleanup EXIT
export VOICE_VIM_DB="$tmp/history.sqlite"
# Recording, failing fakes first on PATH: nothing reaches other apps.
mkdir -p "$swork/fakes" "$swork/empty"
for f in osascript open neovide; do
  printf '#!/bin/sh\n{ echo "CALL %s"; echo "$*"; } >> "%s/calls"\nexit 1\n' "$f" "$swork" > "$swork/fakes/$f"
  chmod +x "$swork/fakes/$f"
done
# A failing ghostty: voice-vim-host ensure finds no GUI settings.
printf '#!/bin/sh\nexit 1\n' > "$swork/fakes/ghostty"; chmod +x "$swork/fakes/ghostty"
: > "$swork/calls"
export PATH="$swork/fakes:$PATH" VOICE_VIM_NOTES_DIR="$swork/notes" VOICE_VIM_HOST_NVIM_FLAGS=--clean
unset VOICE_VIM_SOCK

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

-- Fresh stub and module for each case. These cases cover the session path
-- (mode = "session"); the one-instance cases further down set their own.
local function fresh()
  local rec = stub.install()
  local M = stub.load(modpath)
  M.config.mode = "session"
  return rec, M
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
  M.start({ hotkey = { { "ctrl", "alt" }, "v" }, root = o.root, mode = "session" })
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

-- Window frame (hammerspoon/window-frame.lua through begin()): stub Ghostty
-- with one existing window; each successful AppleScript opens a new focused
-- window, as Ghostty's `new window` does.
local FRAME_KEY = "voice-vim.windowFrame"
local function fs(f)
  if type(f) ~= "table" then return tostring(f) end
  return string.format("%s,%s %sx%s", tostring(f.x), tostring(f.y), tostring(f.w), tostring(f.h))
end
local function frameSetup(cfg, winOpts)
  local rec, M = fresh()
  local ghostty = rec:app({ bundleID = "com.mitchellh.ghostty", windows = {} })
  ghostty._windows[1] = rec:window({ id = 1, app = ghostty })
  rec.frontmost = rec:app({ bundleID = "com.example.target" })
  local nextId = 100
  local applescript = hs.osascript.applescript
  hs.osascript.applescript = function(script)
    local ok, res, err = applescript(script)
    if ok and script:find('application "Ghostty"', 1, true) then
      nextId = nextId + 1
      local o = { id = nextId, app = ghostty }
      for k, v in pairs(winOpts or {}) do o[k] = v end
      local w = rec:window(o)
      ghostty._windows[#ghostty._windows + 1] = w
      rec.focusedWindow = w
    end
    return ok, res, err
  end
  cfg = cfg or {}
  cfg.captureSelection = false
  M.start(cfg)
  return rec, M, ghostty
end
local function cleanupScripts(rec)
  for _, script in ipairs(rec.osascripts) do
    local file = script:match("'([^']*%-voice%-vim%.md)'")
    if file then os.remove(file); os.remove((file:gsub("%-voice%-vim%.md$", ""))) end
  end
end

do
  local rec, M, ghostty = frameSetup()
  M.begin()
  local win = ghostty._windows[2]
  check("frame: begin opens one Ghostty window", 1, #rec.osascripts)
  check("frame: one setFrame", 1, #rec.setFrames)
  check("frame: setFrame on the new window", win, rec.setFrames[1] and rec.setFrames[1].win)
  check("frame: nothing saved gives the default", "360,225 720x450", fs(rec.setFrames[1] and rec.setFrames[1].frame))
  check("frame: logs frame: default", true, rec:hasLog("i", "frame: default 360,225 720x450"))
  check("frame: new window watched", win, rec.watchers[1] and rec.watchers[1].win)
  rec:placeWindow(win, { x = 100, y = 120, w = 900, h = 500 })
  rec:fireWatcher(win, "AXWindowMoved")
  rec:runTimers()
  check("frame: watcher move saved to voice-vim.windowFrame", "100,120 900x500", fs(rec.settings[FRAME_KEY]))
  local glue = M._frameGlue
  M.begin()
  local win2 = ghostty._windows[3]
  check("frame: second begin sets the second window", win2, rec.setFrames[2] and rec.setFrames[2].win)
  check("frame: second window gets the saved frame", "100,120 900x500", fs(rec.setFrames[2] and rec.setFrames[2].frame))
  check("frame: logs frame: restored", true, rec:hasLog("i", "frame: restored 100,120 900x500"))
  check("frame: glue loaded once and kept", true, glue ~= nil and M._frameGlue == glue)
  cleanupScripts(rec)
end

-- windowSize sets the first-open fraction.
do
  local rec, M = frameSetup({ windowSize = 1 })
  M.begin()
  check("frame: windowSize 1 fills the main screen", "0,0 1440x900", fs(rec.setFrames[1] and rec.setFrames[1].frame))
  cleanupScripts(rec)
end

-- Failing AppleScript: no window, no setFrame, no adopt polling.
do
  local rec, M = frameSetup()
  rec.osascriptResult = { false, nil, { NSAppleScriptErrorMessage = "no" } }
  M.begin()
  rec:runTimers()
  check("frame: failing osascript causes no setFrame", 0, #rec.setFrames)
  check("frame: failing osascript does not poll", false, rec:hasLog("w", "session window not found"))
  cleanupScripts(rec)
end

-- iTerm2: frame is not managed.
do
  local rec, M = frameSetup({ terminal = "iTerm2" })
  M.begin()
  rec:runTimers()
  check("frame: iTerm2 opens a window", 1, #rec.osascripts)
  check("frame: terminal=iTerm2 causes no setFrame", 0, #rec.setFrames)
  check("frame: iTerm2 logged", true, rec:hasLog("i", "frame: not managed under iTerm2"))
  cleanupScripts(rec)
end

-- rememberFrame = false: no setFrame, no watcher.
do
  local rec, M = frameSetup({ rememberFrame = false })
  M.begin()
  rec:runTimers()
  check("frame: rememberFrame off opens the window", 1, #rec.osascripts)
  check("frame: rememberFrame off causes no setFrame", 0, #rec.setFrames)
  check("frame: rememberFrame off watches nothing", 0, #rec.watchers)
  cleanupScripts(rec)
end

-- Glue cannot load (no window-frame.lua under root): the session still
-- opens, the error is logged, and the next begin() tries again.
do
  local rec, M = frameSetup({ root = tmpdir .. "/no-frame-root" })
  local ok = pcall(M.begin)
  check("frame: glue load error does not raise", true, ok)
  check("frame: glue load error still opens the window", 1, #rec.osascripts)
  check("frame: glue load error logged", true, rec:hasLog("e", "frame: cannot load window-frame.lua"))
  check("frame: glue load error sets no frame", 0, #rec.setFrames)
  M.begin()
  check("frame: glue load retried next session", 2, #rec:findLogs("e", "frame: cannot load window-frame.lua"))
  cleanupScripts(rec)
end

-- Glue that raises in snapshot and adopt: the session still opens.
do
  local rec, M = frameSetup()
  M._frameGlue = {
    snapshot = function() error("snapshot boom") end,
    adopt = function() error("adopt boom") end,
  }
  local ok = pcall(M.begin)
  check("frame: snapshot error does not raise", true, ok)
  check("frame: snapshot error still opens the window", 1, #rec.osascripts)
  check("frame: snapshot error logged", true, rec:hasLog("e", "snapshot boom"))
  M._frameGlue.snapshot = function() return {} end
  ok = pcall(M.begin)
  check("frame: adopt error does not raise", true, ok)
  check("frame: adopt error still opens the window", 2, #rec.osascripts)
  check("frame: adopt error logged", true, rec:hasLog("e", "adopt boom"))
  cleanupScripts(rec)
end

-- Session window: begin() passes a token, the adopted Ghostty window is
-- mapped to it, and submit / cancel close that window.
local function sessionSetup(cfg, winOpts)
  local rec, M, ghostty = frameSetup(cfg, winOpts)
  local target = rec:app({ bundleID = "com.example.target" })
  local tw = rec:window({ id = 4242, app = target })
  target._window = tw
  rec.frontmost = target
  rec.focusedWindow = tw
  return rec, M, ghostty
end
-- begin(), then the token from the session command and the new window.
local function beginSession(rec, M, ghostty)
  M.begin()
  local script = rec.osascripts[#rec.osascripts] or ""
  return script:match("'4242' '([^']+)'"), ghostty._windows[#ghostty._windows]
end

do
  local rec, M, ghostty = sessionSetup()
  local token, win = beginSession(rec, M, ghostty)
  check("session: begin passes a token after the window id", true, token ~= nil)
  local s = token and M._sessions[token]
  check("session: adopt maps the token to the new window", win, s and s.win)
  check("session: token keeps the start target", "com.example.target", s and s.target)
  check("session: token keeps the start window", 4242, s and s.windowId)
  check("session: adopt logged", true, rec:hasLog("i", "session: window 101 is session " .. tostring(token)))
  local file = submitFile("closing\n")
  rec:openURL("voicevim-submit", { file = file, target = "com.example.target", window = "4242", session = token })
  rec:runTimers()
  check("session submit: window closed once", 1, #rec.closes)
  check("session submit: closed the session window", win, rec.closes[1] and rec.closes[1].win)
  check("session submit: closed before the Cmd+V", 0, rec.closes[1] and rec.closes[1].keyStrokes)
  check("session submit: one Cmd+V", 1, #rec.keyStrokes)
  check("session submit: delivered", true, rec:hasLog("i", "submit: delivered"))
  check("session submit: logs closed window", true, rec:hasLog("i", "session: closed window 101"))
  check("session submit: token dropped", nil, M._sessions[token])
  check("session submit: window mapping dropped", nil, M._windows[101])
  cleanupScripts(rec)
end

do
  local rec, M, ghostty = sessionSetup()
  local token, win = beginSession(rec, M, ghostty)
  check("cancel: voicevim-cancel bound", "function", type(rec.urlBinds["voicevim-cancel"]))
  rec:openURL("voicevim-cancel", { target = "com.example.target", window = "4242", session = token })
  check("cancel: window closed once", 1, #rec.closes)
  check("cancel: closed the session window", win, rec.closes[1] and rec.closes[1].win)
  check("cancel: focuses window 4242", 4242, rec.focuses[1] and rec.focuses[1]:id())
  check("cancel: no keystroke", 0, #rec.keyStrokes)
  check("cancel: logs closed window", true, rec:hasLog("i", "session: closed window 101 (cancel)"))
  check("cancel: token dropped", nil, M._sessions[token])
  rec:openURL("voicevim-cancel", { target = "com.example.target", window = "4242", session = token })
  check("cancel: same token again closes nothing", 1, #rec.closes)
  cleanupScripts(rec)
end

-- Cancel whose start window is gone: activates the app instead.
do
  local rec, M, ghostty = sessionSetup()
  local token = beginSession(rec, M, ghostty)
  rec:closeWindow(4242)
  rec:openURL("voicevim-cancel", { target = "com.example.target", window = "4242", session = token })
  check("cancel, window gone: app activated", 1, #rec.activations)
  check("cancel, window gone: session window still closed", 1, #rec.closes)
  cleanupScripts(rec)
end

-- Unknown session: no close, no error, submit still delivers.
do
  local rec, M, ghostty = sessionSetup()
  beginSession(rec, M, ghostty)
  local file = submitFile("unknown\n")
  local ok = pcall(function()
    rec:openURL("voicevim-submit", { file = file, target = "com.example.target", window = "4242", session = "nope" })
    rec:runTimers()
  end)
  check("unknown session: no error", true, ok)
  check("unknown session: no close", 0, #rec.closes)
  check("unknown session: still delivers", 1, #rec.keyStrokes)
  check("unknown session: logs window not found", true, rec:hasLog("i", "session: window not found"))
  ok = pcall(rec.openURL, rec, "voicevim-cancel", { target = "com.example.target", window = "4242", session = "nope" })
  check("unknown session cancel: no error", true, ok)
  check("unknown session cancel: no close", 0, #rec.closes)
  check("unknown session cancel: still focuses 4242", 4242, rec.focuses[#rec.focuses] and rec.focuses[#rec.focuses]:id())
  cleanupScripts(rec)
end

-- win:close() raises: logged, submit still delivers.
do
  local rec, M, ghostty = sessionSetup(nil, { closeError = "close boom" })
  local token = beginSession(rec, M, ghostty)
  local file = submitFile("still goes\n")
  local ok = pcall(function()
    rec:openURL("voicevim-submit", { file = file, target = "com.example.target", window = "4242", session = token })
    rec:runTimers()
  end)
  check("close throws: no error escapes", true, ok)
  check("close throws: close attempted", 1, #rec.closes)
  check("close throws: still delivers", 1, #rec.keyStrokes)
  check("close throws: logged", true, rec:hasLog("w", "close boom"))
  cleanupScripts(rec)
end

-- Hotkey pressed from a live voice-vim window: reuse its start target.
do
  local rec, M, ghostty = sessionSetup()
  local _, win = beginSession(rec, M, ghostty)
  rec.frontmost = ghostty
  rec.focusedWindow = win
  M.begin()
  local script = rec.osascripts[2] or ""
  check("reuse: second session targets the start window", true, script:find("'com.example.target' '4242'", 1, true) ~= nil)
  check("reuse: Ghostty not recorded as target", nil, script:find("com.mitchellh.ghostty", 1, true))
  check("reuse: logged", true, rec:hasLog("i", "begin: frontmost is a voice-vim window, reusing its target"))
  cleanupScripts(rec)
end

-- Close fails (window left on "Process exited"): a press from it reuses the target.
do
  local rec, M, ghostty = sessionSetup(nil, { closeResult = false })
  local token, win = beginSession(rec, M, ghostty)
  rec:openURL("voicevim-cancel", { target = "com.example.target", window = "4242", session = token })
  check("left window: close failure logged", true, rec:hasLog("w", "session: could not close window 101"))
  rec.frontmost = ghostty
  rec.focusedWindow = win
  M.begin()
  local script = rec.osascripts[2] or ""
  check("left window: next session targets the start window", true, script:find("'com.example.target' '4242'", 1, true) ~= nil)
  cleanupScripts(rec)
end

-- rememberFrame off: the window is still found and closed, but no frame set.
do
  local rec, M, ghostty = sessionSetup({ rememberFrame = false })
  local token, win = beginSession(rec, M, ghostty)
  check("rememberFrame off: token mapped to the window", win, token and M._sessions[token] and M._sessions[token].win)
  check("rememberFrame off: still no setFrame", 0, #rec.setFrames)
  rec:openURL("voicevim-cancel", { target = "com.example.target", window = "4242", session = token })
  check("rememberFrame off: cancel closes the window", 1, #rec.closes)
  cleanupScripts(rec)
end

-- --- One instance (mode = "instance", the default) -------------------------
local swork = assert(os.getenv("VV_SWORK"))
local hostbin = root .. "/bin/voice-vim-host"
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
  return sh("VOICE_VIM_SOCK='" .. sock .. "' '" .. hostbin .. "' " .. sub)
end
local found = { searchPath = { swork .. "/fakes" }, appPaths = {} }
local function sessionRuns(rec)
  local n = 0
  for _, sc in ipairs(rec.osascripts) do if has(sc, "voice-vim-session") then n = n + 1 end end
  for _, e in ipairs(rec.executes) do if has(e.cmd, "voice-vim-session") then n = n + 1 end end
  return n
end

-- Neovide not installed: today's new window per press, one alert.
do
  local rec = stub.install()
  local M = stub.load(modpath)
  rec.frontmost = rec:app({ bundleID = "com.example.target" })
  M.start({ captureSelection = false, neovide = { searchPath = { swork .. "/empty" }, appPaths = {} } })
  check("default mode is instance", "instance", M.config.mode)
  check("Neovide missing: falls back to the old path", "session", M.mode)
  check("Neovide missing: one alert", 1, #rec.alerts)
  check("Neovide missing: alert says install Neovide", "voice-vim: install Neovide for the one-instance mode", rec.alerts[1])
  check("Neovide missing: logs the brew command", true, rec:hasLog("w", "brew install --cask neovide-app"))
  check("Neovide missing: hotkey runs begin", M.begin, rec.hotkeyBinds[1] and rec.hotkeyBinds[1].fn)
  check("Neovide missing: no server pre-warm", 0, #rec.tasks)
  rec.hotkeyBinds[1].fn()
  check("Neovide missing: the hotkey opens a session window", 1, sessionRuns(rec))
  cleanupScripts(rec)
end

-- mode = "session": the old path even with Neovide installed, no alert.
do
  local rec = stub.install()
  local M = stub.load(modpath)
  M.start({ mode = "session", neovide = found })
  check("mode=session: old path, no alert, no pre-warm", "session 0 0", M.mode .. " " .. #rec.alerts .. " " .. #rec.tasks)
end

-- Setting up the one instance raises in start(): old path, one alert.
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
  check("setup error: falls back to the old path", "session", M.mode)
  check("setup error: one alert", 1, #rec.alerts)
  check("setup error: alert says it failed", true, has(rec.alerts[1], "one-instance mode failed"))
  check("setup error: logged", true, rec:hasLog("e", "instance boom"))
  check("setup error: hotkey runs begin", M.begin, rec.hotkeyBinds[1] and rec.hotkeyBinds[1].fn)
  rec.hotkeyBinds[1].fn()
  check("setup error: the hotkey opens a session window", 1, sessionRuns(rec))
  cleanupScripts(rec)
end

-- The server pre-warm fails: the mode was decided at start() and stays the
-- one instance. A press (here during the pre-warm) runs ensure again, and
-- alerts when that fails too; it never opens a session window.
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
  check("ensure fails: voicevim-hide still bound", "function", type(rec.urlBinds["voicevim-hide"]))
  check("ensure fails: the press runs ensure again", true,
    #rec.tasks == 2 and has(rec.tasks[2].args[2], "'ensure'") and rec.tasks[2].started)
  check("ensure fails: no alert while recovering", 0, #rec.alerts)
  rec:finishTask(2, 1, "", "nvim not found")
  check("ensure fails twice: one alert", true,
    #rec.alerts == 1 and has(rec.alerts[1], "could not open the note"))
  check("ensure fails: never a session window", 0, sessionRuns(rec))
  rec.hotkeyBinds[1].fn()  -- the next press tries again
  check("ensure fails: next press runs ensure again", true,
    #rec.tasks == 3 and has(rec.tasks[3].args[2], "'ensure'"))
  rec:finishTask(3, 1, "", "nvim not found")
  check("ensure fails: still no session window", 0, sessionRuns(rec))
end

-- Setup raises after the controller was built (here in prewarm, with a show
-- already waiting for it): old path, and the half-built controller is
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
    .. "    c._afterWarm = function() _G.VV_SHOWN = true end\n"
    .. "    error('prewarm boom')\n"
    .. "  end\n"
    .. "  _G.VV_BUILT = c\n"
    .. "  return c\n"
    .. "end\n"
    .. "return I\n")
  f:close()
  local rec = stub.install()
  local M = stub.load(modpath)
  rec.frontmost = rec:app({ bundleID = "com.example.target" })
  _G.VV_BUILT, _G.VV_SHOWN = nil, nil
  M.start({ root = bad, sock = swork .. "/g.sock", captureSelection = false, neovide = found })
  check("late setup error: old path, one alert", "session 1", M.mode .. " " .. #rec.alerts)
  check("late setup error: logged", true, rec:hasLog("e", "prewarm boom"))
  local c = _G.VV_BUILT
  check("late setup error: controller disabled, pending show dropped", "true nil",
    tostring(c and c._disabled) .. " " .. tostring(c and c._afterWarm))
  check("late setup error: voicevim-hide unbound", nil, rec.urlBinds["voicevim-hide"])
  rec:finishTask(1, 0, "", "")  -- the pre-warm finishes later
  check("late setup error: the dropped show never runs", nil, _G.VV_SHOWN)
  c.toggle()
  local shows = 0
  for _, e in ipairs(rec.executes) do if has(e.cmd, "'show'") then shows = shows + 1 end end
  check("late setup error: the disabled controller shows nothing", "0 0", shows .. " " .. #rec.unhides)
  check("late setup error: hotkey runs begin", M.begin, rec.hotkeyBinds[1] and rec.hotkeyBinds[1].fn)
end

-- Obsolete keys in instance mode.
do
  local rec = stub.install()
  local M = stub.load(modpath)
  M.start({ sock = swork .. "/o.sock", terminal = "iTerm2", windowTitle = "x", neovide = found })
  check("windowTitle warns", true, rec:hasLog("w", "windowTitle is no longer used"))
  check("terminal warns in instance mode", true, rec:hasLog("w", "terminal is only used with mode"))
end

-- One instance: the hotkey toggles Neovide, start() pre-warms once, submit
-- hides Neovide before the Cmd+V, and voice-vim-session never runs.
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
  M.start({ sock = sock, neovide = { searchPath = found.searchPath, appPaths = {},
    commandLine = function(pid) return cmdlines[pid] end } })
  check("instance: Neovide found -> instance mode, no alert", "instance 0", M.mode .. " " .. #rec.alerts)
  local b = rec.hotkeyBinds[1]
  check("instance: hotkey function is toggle", M.toggle, b and b.fn)
  local ensures = 0
  for _, t in ipairs(rec.tasks) do if has(t.args[2], "'ensure'") and t.started then ensures = ensures + 1 end end
  check("instance: start() creates one ensure hs.task", "1 1", #rec.tasks .. " " .. ensures)
  check("instance: ensure uses the socket", true, has(rec.tasks[1].args[2], sock))
  check("instance: voicevim-hide and voicevim-submit bound", "function function",
    type(rec.urlBinds["voicevim-hide"]) .. " " .. type(rec.urlBinds["voicevim-submit"]))
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
  rec:openURL("voicevim-submit", { file = file, target = "com.example.target", window = "4242" })
  rec:runTimers()
  check("instance: submit URL calls host.hide before Cmd+V", 1, hidesAtPaste)
  check("instance: one Cmd+V after focusing 4242", "1 4242",
    #rec.keyStrokes .. " " .. tostring(rec.focuses[#rec.focuses] and rec.focuses[#rec.focuses]:id()))
  check("instance: delivered, text on the clipboard", "true from the note",
    tostring(rec:hasLog("i", "submit: delivered")) .. " " .. tostring(rec.pasteboard.contents))
  check("instance: submit file removed", nil, io.open(file, "r"))

  rec:openURL("voicevim-start", {})  -- shows again, like the hotkey
  rec:runTimers()
  check("instance: voicevim-start shows Neovide", true, rec.frontmost == nv)
  b.fn()  -- Neovide focused: keep the draft, hide, refocus 4242
  local drafts = 0
  for _, e in ipairs(rec.executes) do if has(e.cmd, "'draft'") then drafts = drafts + 1 end end
  check("instance: press while shown runs draft and hides", "1 2", drafts .. " " .. count(rec.hides, nv))
  check("instance: press while shown refocuses 4242", tw, rec.focuses[#rec.focuses])
  check("instance: the hotkey never runs voice-vim-session", 0, sessionRuns(rec))
  hostSh(sock, "stop")
end

os.exit(fail)
LUA

VV_ROOT="$root" VV_TMP="$tmp" VV_SWORK="$swork" perl -e 'alarm 60; exec @ARGV' nvim -l "$tmp/spec.lua" 2>&1
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
