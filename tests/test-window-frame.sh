#!/usr/bin/env bash
# Hammerspoon frame glue: hammerspoon/window-frame.lua against the stub in
# tests/hs_stub.lua (stub screens, windows, watchers, in-memory hs.settings).
# Runs under LuaJIT and nvim -l; also Lua 5.4 when installed. Never touches
# the real Hammerspoon, opens no windows, sends no keystrokes.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d -t vv-wf)
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/spec.lua" <<'LUA'
local root = assert(os.getenv("VV_ROOT"))
local stub = dofile(root .. "/tests/hs_stub.lua")
local modpath = root .. "/hammerspoon/window-frame.lua"
local KEY = "voice-vim.windowFrame"
local GHOSTTY = "com.mitchellh.ghostty"
local fail = 0

local function check(name, want, got)
  if want == got then
    print("ok   " .. name)
  else
    print("FAIL " .. name .. ": want '" .. tostring(want) .. "' got '" .. tostring(got) .. "'")
    fail = 1
  end
end

local function fs(f)
  if type(f) ~= "table" then return tostring(f) end
  return string.format("%s,%s %sx%s", tostring(f.x), tostring(f.y), tostring(f.w), tostring(f.h))
end

local function countLogs(rec, needle) return #rec:findLogs(nil, needle) end

-- Fresh stub with one existing Ghostty window (id 1) on a 1440x875 screen
-- below the menu bar. screens: rec.screens. Returns rec, wf, app.
local function fresh(screens)
  local rec = stub.install()
  rec.screen = { x = 0, y = 25, w = 1440, h = 875 }
  rec.screens = screens
  local app = rec:app({ bundleID = GHOSTTY, windows = {} })
  app._windows[1] = rec:window({ id = 1, app = app })
  local wf = stub.load(modpath).new({ log = hs.logger.new("voice-vim", "info") })
  return rec, wf, app
end

-- A new Ghostty window (focused, as after the AppleScript).
local function openWindow(rec, app, id, opts)
  opts = opts or {}
  opts.id, opts.app = id, app
  local w = rec:window(opts)
  app._windows[#app._windows + 1] = w
  rec.focusedWindow = w
  return w
end

-- New window gets the default frame and is watched.
local rec, wf, app = fresh()
local before = wf.snapshot(GHOSTTY)
check("snapshot holds the existing window", true, before[1])
local win = openWindow(rec, app, 2)
wf.adopt(GHOSTTY, before)
check("new window: one setFrame", 1, #rec.setFrames)
check("new window: setFrame on the new window", win, rec.setFrames[1] and rec.setFrames[1].win)
check("new window: default frame", "360,244 720x438", fs(rec.setFrames[1] and rec.setFrames[1].frame))
check("new window: no animation", 0, rec.setFrames[1] and rec.setFrames[1].duration)
check("new window: logs frame: default", true, rec:hasLog("i", "frame: default 360,244 720x438"))
check("new window: one watcher started", true, #rec.watchers == 1 and rec.watchers[1].started)
check("new window: watches move, resize, destroy", "AXWindowMoved,AXWindowResized,AXUIElementDestroyed",
  table.concat(rec.watchers[1] and rec.watchers[1].events or {}, ","))
check("new window: watcher kept referenced", rec.watchers[1], wf._watched[2] and wf._watched[2].watcher)
check("new window: nothing saved yet", nil, rec.settings[KEY])

-- Our own frame coming back as an event is not saved (unchanged).
rec:fireWatcher(win, "AXWindowResized")
rec:runTimers()
check("equal frame: not saved", nil, rec.settings[KEY])

-- A move then a resize is saved once, after the debounce.
rec:placeWindow(win, { x = 100, y = 120, w = 900, h = 500 })
rec:fireWatcher(win, "AXWindowMoved")
rec:fireWatcher(win, "AXWindowResized")
check("move: not saved before the debounce", nil, rec.settings[KEY])
check("move: debounce is 0.5 s", 0.5, rec.timers[#rec.timers] and rec.timers[#rec.timers].delay)
rec:runTimers()
check("move: saved after the debounce", "100,120 900x500", fs(rec.settings[KEY]))
check("move: saved once", 1, countLogs(rec, "frame: saved"))
check("move: logs frame: saved", true, rec:hasLog("i", "frame: saved 100,120 900x500"))

-- Same frame again: not saved again.
rec:fireWatcher(win, "AXWindowMoved")
rec:runTimers()
check("equal frame again: no second save", 1, countLogs(rec, "frame: saved"))

-- Fullscreen: not saved.
win._fullScreen = true
rec:placeWindow(win, { x = 0, y = 0, w = 1440, h = 900 })
rec:fireWatcher(win, "AXWindowResized")
rec:runTimers()
check("fullscreen: not saved", "100,120 900x500", fs(rec.settings[KEY]))
win._fullScreen = false

-- Parked off every screen: not saved.
rec:placeWindow(win, { x = 5000, y = 5000, w = 900, h = 500 })
rec:fireWatcher(win, "AXWindowMoved")
rec:runTimers()
check("off-screen parked: not saved", "100,120 900x500", fs(rec.settings[KEY]))
check("not-saved cases log no save", 1, countLogs(rec, "frame: saved"))

-- Destroy flushes a pending save at once and stops the watcher.
rec:placeWindow(win, { x = 200, y = 220, w = 700, h = 400 })
rec:fireWatcher(win, "AXWindowMoved")
rec:fireWatcher(win, "AXUIElementDestroyed")
check("destroy: pending save flushed", "200,220 700x400", fs(rec.settings[KEY]))
check("destroy: watcher stopped", true, rec.watchers[1].stopped)
check("destroy: watcher dropped", nil, wf._watched[2])
rec:runTimers()
check("destroy: saved once", 2, countLogs(rec, "frame: saved"))

-- The next window gets the saved frame.
before = wf.snapshot(GHOSTTY)
local win3 = openWindow(rec, app, 3)
wf.adopt(GHOSTTY, before)
check("next window: saved frame", "200,220 700x400", fs(rec.setFrames[2] and rec.setFrames[2].frame))
check("next window: logs frame: restored", true, rec:hasLog("i", "frame: restored 200,220 700x400"))
check("next window: watched", win3, rec.watchers[2] and rec.watchers[2].win)

-- Saved frame on a second screen that is still there: restored as is.
rec, wf, app = fresh({ { x = 0, y = 25, w = 1440, h = 875 }, { x = 1440, y = 0, w = 1920, h = 1080 } })
rec.settings[KEY] = { x = 1600, y = 100, w = 800, h = 600 }
before = wf.snapshot(GHOSTTY)
openWindow(rec, app, 2)
wf.adopt(GHOSTTY, before)
check("second screen: restored unchanged", "1600,100 800x600", fs(rec.setFrames[1] and rec.setFrames[1].frame))
check("second screen: logs restored", true, rec:hasLog("i", "frame: restored"))

-- Saved frame on a screen that is gone: moved onto main, size kept.
rec, wf, app = fresh()
rec.settings[KEY] = { x = 1600, y = 100, w = 800, h = 600 }
before = wf.snapshot(GHOSTTY)
openWindow(rec, app, 2)
wf.adopt(GHOSTTY, before)
local f = rec.setFrames[1] and rec.setFrames[1].frame or {}
check("gone screen: logs moved onto main screen", true, rec:hasLog("i", "frame: moved onto main screen"))
check("gone screen: size kept", "800x600", tostring(f.w) .. "x" .. tostring(f.h))
check("gone screen: centred on main", 320, f.x)

-- No new window: polls until the timeout, logs not found, no setFrame.
rec, wf, app = fresh()
before = wf.snapshot(GHOSTTY)
wf.adopt(GHOSTTY, before)
check("no window: no setFrame before the timeout", 0, #rec.setFrames)
check("no window: polling with a kept timer", true, wf._adoptTimer ~= nil)
rec:runTimers()
check("no window: logs not found", true, rec:hasLog("w", "frame: new window not found"))
check("no window: no setFrame", 0, #rec.setFrames)
check("no window: no watcher", 0, #rec.watchers)
check("no window: polled every 0.02 s", 0.02, rec.timers[1] and rec.timers[1].delay)
check("no window: 2 s of polls", 100, #rec.timers)

-- Window appears on a later poll: adopted then.
rec, wf, app = fresh()
before = wf.snapshot(GHOSTTY)
wf.adopt(GHOSTTY, before)
openWindow(rec, app, 2)
rec:runTimers()
check("late window: one setFrame", 1, #rec.setFrames)
check("late window: no not-found log", false, rec:hasLog("w", "not found"))

-- Missing app: snapshot is empty, adopt does not raise.
rec, wf, app = fresh()
local ok = pcall(function()
  local s = wf.snapshot("com.example.missing")
  check("missing app: empty snapshot", nil, next(s))
  wf.adopt("com.example.missing", s, 0.1)
  rec:runTimers()
end)
check("missing app: no Lua error", true, ok)
check("missing app: not found logged", true, rec:hasLog("w", "not found"))

-- Fullscreen new window: leaves fullscreen, frame set after 0.6 s, then watched.
rec, wf, app = fresh()
before = wf.snapshot(GHOSTTY)
openWindow(rec, app, 2, { fullScreen = true })
wf.adopt(GHOSTTY, before)
check("fullscreen: setFullScreen(false)", false, rec.fullScreenSets[1] and rec.fullScreenSets[1].value)
check("fullscreen: no setFrame yet", 0, #rec.setFrames)
check("fullscreen: not watched yet", 0, #rec.watchers)
rec:runTimers()
check("fullscreen: retry after 0.6 s", 0.6, rec.timers[1] and rec.timers[1].delay)
check("fullscreen: default frame after retry", "360,244 720x438", fs(rec.setFrames[1] and rec.setFrames[1].frame))
check("fullscreen: watched after the frame", 1, #rec.watchers)

-- Stays fullscreen: one retry, then gives up without setFrame.
rec, wf, app = fresh()
before = wf.snapshot(GHOSTTY)
openWindow(rec, app, 2, { fullScreen = true, stayFullScreen = true })
wf.adopt(GHOSTTY, before)
rec:runTimers()
check("stuck fullscreen: one setFullScreen", 1, #rec.fullScreenSets)
check("stuck fullscreen: no setFrame", 0, #rec.setFrames)
check("stuck fullscreen: logged", true, rec:hasLog("w", "still fullscreen"))

-- Custom key and fraction.
rec, wf, app = fresh()
wf = stub.load(modpath).new({ key = "test.key", fraction = 1 })
before = wf.snapshot(GHOSTTY)
win = openWindow(rec, app, 2)
wf.adopt(GHOSTTY, before)
check("fraction 1: full main screen", "0,25 1440x875", fs(rec.setFrames[1] and rec.setFrames[1].frame))
rec:placeWindow(win, { x = 10, y = 30, w = 600, h = 400 })
rec:fireWatcher(win, "AXWindowMoved")
rec:runTimers()
check("custom key: saved under it", "10,30 600x400", fs(rec.settings["test.key"]))
check("custom key: default key untouched", nil, rec.settings[KEY])

-- frame.lua cannot be loaded: new() raises (the caller pcalls it).
stub.install()
ok = pcall(stub.load(modpath).new, { root = "/nonexistent" })
check("missing frame.lua: new() raises", false, ok)

os.exit(fail)
LUA

fail=0
ran=0
run() { # label cmd...
  local label=$1; shift
  echo "== $label"
  VV_ROOT="$root" perl -e 'alarm 20; exec @ARGV' "$@" "$tmp/spec.lua" 2>&1 || fail=1 # nvim -l prints to stderr
  [ "$1" = nvim ] && echo # nvim -l leaves the last line unterminated
  ran=1
}
command -v luajit >/dev/null && run luajit luajit
command -v nvim   >/dev/null && run "nvim -l" nvim -l
for l in lua5.4 lua54 lua; do
  if command -v "$l" >/dev/null && "$l" -v 2>&1 | grep -q 'Lua 5.4'; then run "$l" "$l"; break; fi
done
if [ "$ran" = 0 ]; then echo "FAIL no Lua interpreter (luajit or nvim) found"; fail=1; fi
if [ $fail -eq 0 ]; then echo "all ok"; else echo "FAILED"; fi
exit $fail
