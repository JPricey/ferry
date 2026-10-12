#!/usr/bin/env bash
# hammerspoon/hosts/neovide.lua against the stub in tests/hs_stub.lua under
# `nvim -l`. hs.task is recorded; the launch command is then run by hand
# with fake neovide/open first on PATH (they record their arguments and
# fail), so no real Neovide starts. The controller cycle drives
# hammerspoon/instance.lua with this adapter and a real bin/voice-vim-host
# on a temp socket (--clean, temp DB and notes dir). Never touches the real
# Hammerspoon, Neovide or Joe's nvim server.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# macOS socket paths max out at 104 bytes, so keep the folder short.
work=$(mktemp -d /tmp/vvn.XXXX)
[ -n "$work" ] && [ -d "$work" ] || { echo "mktemp failed" >&2; exit 1; }
ps_ours= ps_other=
cleanup() {
  pkill -f -- "--listen $work/" 2>/dev/null
  [ -n "$ps_ours" ] && kill "$ps_ours" 2>/dev/null
  [ -n "$ps_other" ] && kill "$ps_other" 2>/dev/null
  rm -rf "$work"
}
trap cleanup EXIT

mkdir -p "$work/fakes" "$work/empty" "$work/apps/Neovide.app/Contents/MacOS"
for f in osascript open neovide; do
  printf '#!/bin/sh\n{ echo "CALL %s"; echo "$*"; } >> "%s/calls"\nexit 1\n' "$f" "$work" > "$work/fakes/$f"
  chmod +x "$work/fakes/$f"
done
# A failing ghostty: voice-vim-host ensure finds no GUI settings.
printf '#!/bin/sh\nexit 1\n' > "$work/fakes/ghostty"; chmod +x "$work/fakes/ghostty"
: > "$work/apps/Neovide.app/Contents/Info.plist"
cp "$work/fakes/neovide" "$work/apps/Neovide.app/Contents/MacOS/neovide"
: > "$work/calls"
# Two stand-in processes whose command lines /bin/ps reads: one served on
# r.sock (ours in the ps case), one on another socket.
perl -e 'sleep 60' neovide --server "$work/r.sock" </dev/null >/dev/null 2>&1 &
ps_ours=$!
perl -e 'sleep 60' neovide --server "$work/other.sock" </dev/null >/dev/null 2>&1 &
ps_other=$!
export VV_PS_OURS=$ps_ours VV_PS_OTHER=$ps_other
export PATH="$work/fakes:$PATH" VOICE_VIM_DB="$work/history.sqlite"
unset VOICE_VIM_SOCK VOICE_VIM_NOTES_DIR VOICE_VIM_HOST_NVIM_FLAGS

cat > "$work/spec.lua" <<'LUA'
local root = assert(os.getenv("VV_ROOT"))
local work = assert(os.getenv("VV_WORK"))
local stub = dofile(root .. "/tests/hs_stub.lua")
local modpath = root .. "/hammerspoon/hosts/neovide.lua"
local hostbin = root .. "/bin/voice-vim-host"
local NEOVIDE = "com.neovide.neovide"
local KEY = "voice-vim.windowFrame"
local fail = 0

local function check(name, want, got)
  if want == got then
    print("ok   " .. name)
  else
    print("FAIL " .. name .. ": want '" .. tostring(want) .. "' got '" .. tostring(got) .. "'")
    fail = 1
  end
end

local function sh(cmd)
  local p = io.popen(cmd .. " 2>&1")
  local out = p:read("*a")
  p:close()
  return (out:gsub("%s+$", ""))
end
local function has(s, needle) return (s or ""):find(needle, 1, true) ~= nil end
local function fs(f)
  if type(f) ~= "table" then return tostring(f) end
  return string.format("%s,%s %sx%s", tostring(f.x), tostring(f.y), tostring(f.w), tostring(f.h))
end
local function count(list, x)
  local k = 0
  for _, v in ipairs(list) do if v == x then k = k + 1 end end
  return k
end

-- Run a recorded hs.task's /bin/sh -c command for real (fakes first on
-- PATH), then wait for the fake it starts to record a call with needle.
local function runLaunch(rec, i, needle)
  local t = rec.tasks[i]
  local out = sh("/bin/sh -c " .. "'" .. t.args[2]:gsub("'", "'\\''") .. "'" .. "; echo \"rc=$?\"")
  for _ = 1, 40 do
    if has(sh("cat '" .. work .. "/calls'"), needle) then break end
    sh("sleep 0.05")
  end
  rec:finishTask(i, tonumber(out:match("rc=(%d+)$")) or 1, out, "")
end

-- Process command lines by pid (rec.cmdlines); "ours" stands for a
-- Neovide started with --server <this adapter's sock>. rec.cmdlineReads
-- counts reads per pid.
local function new(rec, cfg)
  cfg = cfg or {}
  cfg.root = cfg.root or root
  cfg.searchPath = cfg.searchPath or { work .. "/empty" }
  cfg.appPaths = cfg.appPaths or {}
  rec.cmdlines = rec.cmdlines or {}
  rec.cmdlineReads = rec.cmdlineReads or {}
  local h
  cfg.commandLine = cfg.commandLine or function(pid)
    rec.cmdlineReads[pid] = (rec.cmdlineReads[pid] or 0) + 1
    local c = rec.cmdlines[pid]
    if c == "ours" then return "/Applications/Neovide.app/Contents/MacOS/neovide --server " .. h.config.sock end
    return c
  end
  h = stub.load(modpath).new(cfg)
  return h
end

-- Neovide app stub with one window; not frontmost, hidden. cmdline: its
-- command line (default "ours").
local nextPid = 7000
local function neovide(rec, id, cmdline)
  nextPid = nextPid + 1
  rec.cmdlines = rec.cmdlines or {}
  rec.cmdlines[nextPid] = cmdline or "ours"
  local app = rec:app({ bundleID = NEOVIDE, name = "Neovide", windows = {}, pid = nextPid })
  local win = rec:window({ id = id or 50, app = app })
  app._window = win
  app._windows[1] = win
  app._hidden = true
  return app, win
end

local function other(rec)
  local app = rec:app({ bundleID = "com.example.target" })
  local w = rec:window({ id = 4242, app = app })
  app._window = w
  rec.frontmost, rec.focusedWindow = app, w
  return app, w
end

-- available()
do
  local rec = stub.install()
  local h = new(rec)
  local ok, why = h.available()
  check("available() false when no Neovide", false, ok)
  check("available() false logs why", true, has(why, "no neovide"))
  h = new(rec, { searchPath = { work .. "/fakes" } })
  check("available() true with neovide on the search path", true, (h.available()))
  rec.bundlePaths[NEOVIDE] = work .. "/apps/Neovide.app"
  check("available() true with Neovide.app from pathForBundleID", true, (new(rec).available()))
  check("module-level available() matches", true,
    (stub.load(modpath).available({ searchPath = { work .. "/empty" }, appPaths = {} })))
  rec.bundlePaths[NEOVIDE] = nil
  check("available() true with Neovide.app in appPaths", true,
    (new(rec, { appPaths = { work .. "/apps/Neovide.app" } }).available()))
end

-- launch: neovide binary on the search path.
do
  local rec = stub.install()
  local sock = work .. "/a.sock"
  local h = new(rec, { sock = sock, searchPath = { work .. "/fakes" } })
  local got
  h.launch(function(ok, why) got = { ok, why } end)
  local t = rec.tasks[1]
  check("launch: one hs.task via /bin/sh", "/bin/sh -c", t and (t.path .. " " .. t.args[1]))
  check("launch: task started", true, t and t.started)
  check("launch: cb(true) once started", true, got and got[1])
  check("launch carries --server <sock>", true, t and has(t.args[2], "--server '" .. sock .. "'"))
  check("launch: runs the found neovide binary", true, t and has(t.args[2], "'" .. work .. "/fakes/neovide'"))
  runLaunch(rec, 1, "--server " .. sock)
  check("launch: fake neovide ran with --server <sock>", true,
    has(sh("cat '" .. work .. "/calls'"), "CALL neovide\n--server " .. sock))
  check("launch: logged", true, rec:hasLog("i", "neovide: launch (binary)"))
end

-- launch: no binary, Neovide.app from pathForBundleID -> its own binary.
do
  local rec = stub.install()
  rec.bundlePaths[NEOVIDE] = work .. "/apps/Neovide.app"
  local h = new(rec, { sock = work .. "/b.sock" })
  h.launch(function() end)
  check("launch: app bundle binary when no CLI", true,
    rec.tasks[1] and has(rec.tasks[1].args[2], "Neovide.app/Contents/MacOS/neovide' --server '" .. work .. "/b.sock'"))
end

-- launch: nothing found -> open -n -a Neovide --args --server <sock>.
do
  local rec = stub.install()
  local sock = work .. "/c.sock"
  local h = new(rec, { sock = sock })
  h.launch(function() end)
  local t = rec.tasks[1]
  check("launch fallback: open -a Neovide --args --server <sock>", true,
    t and has(t.args[2], "open -n -a 'Neovide' --args --server '" .. sock .. "'"))
  runLaunch(rec, 1, "--server " .. sock)
  check("launch fallback: fake open ran with --server <sock>", true,
    has(sh("cat '" .. work .. "/calls'"), "CALL open\n-n -a Neovide --args --server " .. sock))
  check("launch fallback: failed open logged", true, rec:hasLog("w", "neovide: launch command exit 1"))
end

-- show, hide, isFocused on a running Neovide.
do
  local rec = stub.install()
  local _, tw = other(rec)
  local app, win = neovide(rec)
  local h = new(rec)
  check("isFocused false when another app is frontmost", false, (h.isFocused()))
  local got
  h.show(function(ok) got = ok end)
  check("show unhides the Neovide app", 1, count(rec.unhides, app))
  check("show activates the Neovide app", 1, count(rec.activations, app))
  check("show focuses its main window", win, rec.focuses[#rec.focuses])
  check("show: cb(true)", true, got)
  check("isFocused true when Neovide is frontmost", true, (h.isFocused()))
  check("show: existing window watched for moves", 1, #rec.watchers)
  check("show: existing window not moved", 0, #rec.setFrames)
  h.show(function() end)
  check("show again: no second watcher", 1, #rec.watchers)
  got = nil
  h.hide(function(ok) got = ok end)
  check("hide hides the Neovide app", 1, count(rec.hides, app))
  check("hide: cb(true)", true, got)
  tw:focus()
  check("isFocused false after focus moves away", false, (h.isFocused()))
  nextPid = nextPid + 1
  rec.cmdlines[nextPid] = "ours"
  local byName = rec:app({ name = "Neovide", pid = nextPid })
  byName._window = rec:window({ id = 90, app = byName })
  rec.frontmost = byName
  local yes, why = h.isFocused()
  check("isFocused true by app name Neovide", true, yes)
  check("isFocused why says by name", true, has(why, "by name"))
end

-- Cmd+M: a minimized Neovide window is not focused, and show unminimizes
-- it (else the hotkey goes silently dead: focused, nothing on screen).
do
  local rec = stub.install()
  other(rec)
  local app, win = neovide(rec)
  local h = new(rec)
  h.show(function() end)
  check("minimize: shown window is focused", true, (h.isFocused()))
  win:minimize()  -- Cmd+M: Neovide stays the frontmost app
  local yes, why = h.isFocused()
  check("minimize: frontmost Neovide with a minimized window is not focused", false, yes)
  check("minimize: why says minimized", true, has(why, "minimized"))
  -- A minimized window is not always the main window: found via allWindows.
  app._window = nil
  check("minimize: no main window, minimized in allWindows: not focused", false, (h.isFocused()))
  h.show(function() end)
  check("minimize: show unminimizes our window", 1, count(rec.unminimizes, win))
  check("minimize: show focuses it", win, rec.focuses[#rec.focuses])
  check("minimize: shown again -> focused", true, (h.isFocused()))
  check("minimize: unminimize logged", true, rec:hasLog("i", "is minimized; unminimizing"))
  app._window = win
  h.show(function() end)
  check("minimize: a window that is not minimized is not unminimized", 1, #rec.unminimizes)
  -- Hidden app (window not visible) while frontmost: not focused.
  app._hidden = true
  check("not visible: frontmost Neovide with a hidden window is not focused", false, (h.isFocused()))
  app._hidden = false
  -- Frontmost with no window at all: not focused.
  app._window, app._windows = nil, {}
  check("no window: frontmost Neovide without a window is not focused", false, (h.isFocused()))
end

-- show/hide with Neovide not running: no error, show reports false.
do
  local rec = stub.install()
  local h = new(rec)
  local got
  h.show(function(ok) got = ok end)
  check("show without Neovide (no launch): cb(false)", false, got)
  got = nil
  h.hide(function(ok) got = ok end)
  check("hide without Neovide: cb(true)", true, got)
end

-- First window after launch gets the default frame, then the saved one.
do
  local rec = stub.install()
  other(rec)
  local h = new(rec, { searchPath = { work .. "/fakes" } })
  h.launch(function() end)
  h.show(function() end)  -- before Neovide is up: kept until its window appears
  local app, win = neovide(rec)
  rec:runTimers()
  check("first window gets the default frame", "360,225 720x450",
    fs(rec.setFrames[1] and rec.setFrames[1].frame))
  check("first window: setFrame on the Neovide window", win, rec.setFrames[1] and rec.setFrames[1].win)
  check("first window: logs frame: default", true, rec:hasLog("i", "frame: default 360,225 720x450"))
  check("first window: watched", true, #rec.watchers == 1 and rec.watchers[1].win == win)
  check("show before the window: shown when it appears", "1 1",
    count(rec.activations, app) .. " " .. count(rec.focuses, win))
  check("show before the window: Neovide frontmost", true, (h.isFocused()))
  rec:placeWindow(win, { x = 100, y = 120, w = 900, h = 500 })
  rec:fireWatcher(win, "AXWindowMoved")
  rec:runTimers()
  check("move of the Neovide window saved", "100,120 900x500", fs(rec.settings[KEY]))
  h.show(function() end)
  check("show of the adopted window adds no watcher", 1, #rec.watchers)

  rec = stub.install()
  rec.settings[KEY] = { x = 100, y = 120, w = 900, h = 500 }
  h = new(rec, { searchPath = { work .. "/fakes" } })
  h.launch(function() end)
  neovide(rec, 51)
  rec:runTimers()
  check("first window gets the saved frame", "100,120 900x500",
    fs(rec.setFrames[1] and rec.setFrames[1].frame))
  check("first window: logs frame: restored", true, rec:hasLog("i", "frame: restored"))

  rec = stub.install()
  h = new(rec, { searchPath = { work .. "/fakes" }, rememberFrame = false })
  h.launch(function() end)
  neovide(rec, 52)
  rec:runTimers()
  check("rememberFrame=false: no setFrame, no watcher", "0 0", #rec.setFrames .. " " .. #rec.watchers)
end

-- Our Neovide only: Joe's own Neovide (no --server <sock>) is never shown,
-- hidden or taken as focused. get() returns Joe's (made last).
do
  local rec = stub.install()
  local _, tw = other(rec)
  local ours, ourWin = neovide(rec, 50)
  local joes, joeWin = neovide(rec, 70, "/Applications/Neovide.app/Contents/MacOS/neovide")
  joes._hidden = false
  local h = new(rec)
  rec.frontmost, rec.focusedWindow = joes, joeWin
  local yes, why = h.isFocused()
  check("own Neovide only: Joe's Neovide frontmost is not focused", false, yes)
  check("own Neovide only: why names another Neovide", true, has(why, "another Neovide"))
  tw:focus()
  h.show(function() end)
  check("own Neovide only: show unhides and activates ours, not Joe's", "1 1 0 0",
    count(rec.unhides, ours) .. " " .. count(rec.activations, ours) .. " "
    .. count(rec.unhides, joes) .. " " .. count(rec.activations, joes))
  check("own Neovide only: show focuses our window", ourWin, rec.focuses[#rec.focuses])
  check("own Neovide only: ours frontmost is focused", true, (h.isFocused()))
  h.hide(function() end)
  check("own Neovide only: hide hides ours, not Joe's", "1 0", count(rec.hides, ours) .. " " .. count(rec.hides, joes))
  check("own Neovide only: Joe's logged as left alone", true, rec:hasLog("i", "is another Neovide, left alone"))
  rec.frontmost = joes
  h.isFocused(); h.show(function() end); h.isFocused()
  check("own Neovide only: each command line read once", "1 1",
    tostring(rec.cmdlineReads[ours:pid()]) .. " " .. tostring(rec.cmdlineReads[joes:pid()]))
  check("own Neovide only: Joe's never hidden or unhidden", "0 0", count(rec.hides, joes) .. " " .. count(rec.unhides, joes))
  rec:closeWindow(50)
  ours._quit = true
  local got
  h.show(function(ok) got = ok end)
  check("own Neovide only: ours quit -> show fails, Joe's untouched", "false 0",
    tostring(got) .. " " .. count(rec.unhides, joes))
end

-- The window adopted after launch is ours even when command lines cannot
-- be read; other Neovides with unreadable command lines are left alone.
do
  local rec = stub.install()
  other(rec)
  local h = new(rec, { searchPath = { work .. "/fakes" }, commandLine = function() return nil end })
  local joes = neovide(rec, 70)
  joes._hidden = false
  h.launch(function() end)
  h.show(function() end)
  local ours, ourWin = neovide(rec, 51)
  rec:runTimers()
  check("adopted: launched window shown", "1 " .. tostring(ourWin),
    count(rec.activations, ours) .. " " .. tostring(rec.focuses[#rec.focuses]))
  h.hide(function() end)
  check("adopted: hide acts on the adopted Neovide only", "1 0", count(rec.hides, ours) .. " " .. count(rec.hides, joes))
  rec.frontmost = joes
  check("adopted: an unreadable other Neovide is not focused", false, (h.isFocused()))
end

-- window-frame.lua cannot load: a show held for the launched window still
-- happens (fallback poll), with no frame set.
do
  local rec = stub.install()
  other(rec)
  local h = new(rec, { root = work .. "/no-root", searchPath = { work .. "/fakes" } })
  h.launch(function() end)
  local got
  h.show(function(ok) got = ok end)
  check("no frame glue: show before the window is kept", true, got)
  check("no frame glue: load error logged", true, rec:hasLog("e", "neovide: cannot load window-frame.lua"))
  local app, win = neovide(rec, 56)
  rec:runTimers()
  check("no frame glue: held show happens when the window appears", "1 1",
    count(rec.activations, app) .. " " .. count(rec.focuses, win))
  check("no frame glue: Neovide frontmost", true, (h.isFocused()))
  check("no frame glue: found by the fallback poll", true, rec:hasLog("i", "found after launch (no frame glue)"))
  check("no frame glue: no setFrame", 0, #rec.setFrames)
end

-- Default command-line reader: /bin/ps on real processes.
do
  local rec = stub.install()
  local h = stub.load(modpath).new({ root = root, sock = work .. "/r.sock",
    searchPath = { work .. "/empty" }, appPaths = {} })
  local ours = rec:app({ bundleID = NEOVIDE, name = "Neovide", pid = tonumber(os.getenv("VV_PS_OURS")) })
  ours._window = rec:window({ id = 91, app = ours })
  local theirs = rec:app({ bundleID = NEOVIDE, name = "Neovide", pid = tonumber(os.getenv("VV_PS_OTHER")) })
  rec.frontmost = theirs
  check("ps: a Neovide on another --server socket is not ours", false, (h.isFocused()))
  rec.frontmost = ours
  check("ps: the Neovide with --server <sock> is ours", true, (h.isFocused()))
  local n = 0
  for _, e in ipairs(rec.executes) do if has(e.cmd, "/bin/ps -o args= -p ") then n = n + 1 end end
  check("ps: read through /bin/ps once per pid", 2, n)
end

-- Full controller cycle: instance.lua + this adapter, real voice-vim-host.
do
  local rec = stub.install()
  rec.execStatus = true
  local sock = work .. "/i.sock"
  local _, tw = other(rec)
  local env = "VOICE_VIM_SOCK='" .. sock .. "' VOICE_VIM_NOTES_DIR='" .. work .. "/notes' "
    .. "VOICE_VIM_HOST_NVIM_FLAGS=--clean '" .. hostbin .. "' "
  local host = new(rec, { sock = sock, searchPath = { work .. "/fakes" } })
  local c = stub.load(root .. "/hammerspoon/instance.lua").new({
    host = host, root = root, sock = sock, notesDir = work .. "/notes", nvimFlags = "--clean",
    deliver = function() end,
  })
  c.prewarm()
  sh(env .. "ensure")  -- what the pre-warm task does
  rec:finishTask(1, 0, "", "")
  c.toggle()
  check("cycle: show runs show com.example.target 4242", true,
    has(rec.executes[1] and rec.executes[1].cmd, "'show' 'com.example.target' '4242'"))
  check("cycle: uis=0 -> Neovide launched with --server <sock>", true,
    rec.tasks[2] ~= nil and has(rec.tasks[2].args[2], "--server '" .. sock .. "'"))
  local app, win = neovide(rec, 60)  -- Neovide starts
  rec:runTimers()
  check("cycle: Neovide shown and focused", true, (host.isFocused()))
  check("cycle: logs show: host focused after", true, rec:hasLog("i", "show: host focused after"))
  check("cycle: first window framed", win, rec.setFrames[1] and rec.setFrames[1].win)
  check("cycle: note in insert mode with target 4242", "i com.example.target 4242",
    sh("nvim --server '" .. sock .. "' --remote-expr 'mode().\" \".b:voicevim.target.\" \".b:voicevim.window'"))
  c.toggle()
  check("cycle: toggle while focused runs draft", true,
    has(rec.executes[#rec.executes].cmd, "'draft'"))
  check("cycle: hides Neovide", 1, count(rec.hides, app))
  check("cycle: refocuses window 4242", tw, rec.focuses[#rec.focuses])
  rec:runTimers()
  check("cycle: logs hide: target focused after", true, rec:hasLog("i", "hide: target focused after"))
  check("cycle: Neovide no longer focused", false, (host.isFocused()))
  c.toggle()
  rec:runTimers()
  check("cycle: second show unhides without a second launch", "2 2",
    #rec.tasks .. " " .. count(rec.unhides, app))
  sh(env .. "stop")
end

os.exit(fail)
LUA

VV_ROOT="$root" VV_WORK="$work" perl -e 'alarm 60; exec @ARGV' nvim -l "$work/spec.lua" 2>&1
status=$?
echo  # nvim -l leaves the last line unterminated

check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want '$2' got '$3'"; status=1; fi; }
check "fake osascript never called" 0 "$(grep -c '^CALL osascript' "$work/calls")"
check "fakes called only by the launch commands run above" 2 "$(grep -c '^CALL ' "$work/calls")"
check "voice-vim.lua loads hosts/neovide.lua" 1 "$(grep -c 'dofile(root .. "/hammerspoon/hosts/neovide.lua")' "$root/hammerspoon/voice-vim.lua")"
lj=$(command -v luajit || echo /opt/homebrew/bin/luajit)
if [ -x "$lj" ]; then
  check "hosts/neovide.lua parses under LuaJIT" ok "$("$lj" -e "assert(loadfile('$root/hammerspoon/hosts/neovide.lua')) print('ok')" 2>&1)"
fi
if l=$(command -v lua5.4 || command -v lua); then
  check "hosts/neovide.lua parses under $(basename "$l")" ok "$("$l" -e "assert(loadfile('$root/hammerspoon/hosts/neovide.lua')) print('ok')" 2>&1)"
fi

if [ $status -eq 0 ]; then echo "all ok"; else echo "FAILED"; fi
exit $status
