#!/usr/bin/env bash
# Host spike: spike/host/host.lua against the stub in tests/hs_stub.lua under
# `nvim -l`. hs.execute really runs the launch scripts' note/draft against a
# headless nvim on a temp socket (--clean); hs.task is recorded, never run.
# Fake osascript/open/neovide on PATH record and fail, so nothing reaches
# Ghostty, Neovide or other apps. Never touches the real Hammerspoon.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d -t vv-spike-hs)
[ -n "$work" ] && [ -d "$work" ] || { echo "mktemp failed" >&2; exit 1; }
cleanup() {
  pkill -f -- "--listen $work/" 2>/dev/null
  rm -rf "$work"
}
trap cleanup EXIT

mkdir -p "$work/fakes"
for f in osascript open neovide; do
  printf '#!/bin/sh\n{ echo "CALL %s"; echo "$*"; } >> "%s/calls"\nexit 1\n' "$f" "$work" > "$work/fakes/$f"
  chmod +x "$work/fakes/$f"
done
: > "$work/calls"
export PATH="$work/fakes:$PATH" VV_SPIKE_DRY_RUN=1
# Keep the spike's own env defaults out: the module must pass these itself.
unset VOICE_VIM_SOCK VOICE_VIM_SPIKE_NOTES VV_HOST_NVIM_FLAGS VV_QT_MODE

cat > "$work/spec.lua" <<'LUA'
local root = assert(os.getenv("VV_ROOT"))
local work = assert(os.getenv("VV_WORK"))
local stub = dofile(root .. "/tests/hs_stub.lua")
local modpath = root .. "/spike/host/host.lua"
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

local function lastExec(rec, needle)
  for i = #rec.executes, 1, -1 do
    if has(rec.executes[i].cmd, needle) then return rec.executes[i] end
  end
  return nil
end

-- Index of the last recorded hs.task whose shell command contains needle.
local function findTask(rec, needle)
  for i = #rec.tasks, 1, -1 do
    if has(rec.tasks[i].args[2], needle) then return i end
  end
  return nil
end

local function countTasks(rec, needle)
  local n = 0
  for _, t in ipairs(rec.tasks) do if has(t.args[2], needle) then n = n + 1 end end
  return n
end

-- N from the first log line containing prefix .. "N ms".
local function logMs(rec, prefix)
  for _, l in ipairs(rec.logs) do
    local n = l.msg:match(prefix:gsub("%p", "%%%0") .. "(%d+) ms")
    if n then return tonumber(n) end
  end
  return nil
end

local function lastFocusId(rec)
  local w = rec.focuses[#rec.focuses]
  return w and w:id()
end

local GHOSTTY, NEOVIDE = "com.mitchellh.ghostty", "com.neovide.neovide"

-- One case per host: its own socket, a target app with window 4242 in front.
local function setup(host, opts)
  local rec = stub.install()
  local sock = work .. "/" .. host .. ".sock"
  local target = rec:app({ bundleID = "com.example.target" })
  local tw = rec:window({ id = 4242, app = target })
  target._window = tw
  rec.frontmost, rec.focusedWindow = target, tw
  local M = stub.load(modpath)
  local cfg = { host = host, sock = sock, notes = work .. "/notes-" .. host, nvimFlags = "--clean" }
  for k, v in pairs(opts or {}) do cfg[k] = v end
  local keepWarm = cfg.keepWarm
  cfg.keepWarm = nil
  M.start(cfg)
  -- start() pre-warms with an async `vv-host ensure`; finish it (the note's
  -- own ensure then starts the test server) unless the case wants it running.
  local wi = findTask(rec, "vv-host' ensure")
  if wi and not keepWarm then rec:finishTask(wi, 0, "", "") end
  return rec, M, sock
end

local function ask(sock, expr)
  return sh("nvim --server '" .. sock .. "' --remote-expr '" .. expr .. "'")
end

-- show/hide round trip shared by the hosts. hooks.afterShow and
-- hooks.afterHide simulate what the real host would do.
local function roundTrip(host, rec, M, sock, script, hooks)
  local press = rec.hotkeyBinds[#rec.hotkeyBinds].fn
  press()
  local note = lastExec(rec, script .. "' note")
  check(host .. ": show runs note via hs.execute", true, note ~= nil)
  local path = note and note.out:match("(%S+%.md)") or nil
  check(host .. ": note printed a .md path", true, path ~= nil)
  check(host .. ": note command carries the socket", true, note ~= nil and has(note.cmd, sock))
  check(host .. ": server note in insert mode", "i markdown", ask(sock, 'mode()." ".&filetype'))
  if hooks.afterShow then hooks.afterShow() end
  rec:runTimers()
  check(host .. ": host focused", true, M.hosts[M.config.host].isFocused())
  check(host .. ": show timing logged", true, rec:hasLog("i", "show: host focused after"))

  ask(sock, "nvim_buf_set_lines(0, 0, -1, v:false, [\"spike " .. host .. "\"])")
  press()
  local draft = lastExec(rec, script .. "' draft")
  check(host .. ": second toggle runs draft via hs.execute", true, draft ~= nil)
  check(host .. ": draft wrote the note", "spike " .. host, sh("cat '" .. tostring(path) .. "'"))
  check(host .. ": g:voicevim_draft is the note", path, ask(sock, "g:voicevim_draft"))
  if hooks.afterHide then hooks.afterHide() end
  rec:runTimers()
  check(host .. ": window 4242 focused", 4242, lastFocusId(rec))
  check(host .. ": front window is 4242", 4242, rec.focusedWindow and rec.focusedWindow:id())
  check(host .. ": hide timing logged", true, rec:hasLog("i", "hide: target focused after"))
  check(host .. ": shown is false after hide", false, M.shown)
  check(host .. ": hide uses the captured window (no hs.window.get)", 0, rec.windowGets)
  check(host .. ": toggle logs the branch", true, rec:hasLog("i", "-> hide;"))
  sh("VOICE_VIM_SOCK='" .. sock .. "' '" .. root .. "/spike/host/vv-host' stop")
end

-- Shared checks on start(): spike hotkey, logger name.
do
  local rec, M = setup("ghostty-window")
  local b = rec.hotkeyBinds[1]
  check("spike hotkey mods are ctrl+alt+cmd", "ctrl+alt+cmd", table.concat(b.mods, "+"))
  check("spike hotkey key is v", "v", b.key)
  check("bound line logged", true, rec:hasLog("i", "bound ctrl+alt+cmd+v"))
  check("logger name is voice-vim-spike", "voice-vim-spike", rec.logs[1] and rec.logs[1].name)
  local obj = M.hotkeyObj
  M.stop()
  check("stop deletes the hotkey", true, obj.deleted)
  check("stop clears the hotkey object", nil, M.hotkeyObj)
  local again = M.start()
  check("start returns the module", M, again)
  check("restart binds again", 2, #rec.hotkeyBinds)
  check("unknown host is refused by use", "ghostty-window", M.use("nope").config.host)
end

-- ghostty-window: the host window exists (a second Ghostty window too).
do
  local rec, M, sock = setup("ghostty-window")
  local g = rec:app({ bundleID = GHOSTTY })
  local hw = rec:window({ id = 9, title = "voice-vim-host", app = g, topLeft = { x = 40, y = 50 } })
  local other = rec:window({ id = 10, title = "zsh", app = g })
  g._windows = { other, hw }
  roundTrip("ghostty-window", rec, M, sock, "ghostty-window.sh", {
    afterShow = function()
      check("ghostty-window: show focuses window 9", 9, lastFocusId(rec))
      check("ghostty-window: other Ghostty window not focused", 1, #rec.focuses)
    end,
    afterHide = function()
      check("ghostty-window: hide moves the host window", 9, rec.moves[1] and rec.moves[1].win:id())
      check("ghostty-window: hide moves it away", true, rec.moves[1] and rec.moves[1].point.x > 1000)
    end,
  })
  -- A second show restores the saved position.
  rec.hotkeyBinds[#rec.hotkeyBinds].fn()
  check("ghostty-window: reshow restores top-left", 40, hw:topLeft().x)
  check("ghostty-window: no hs.task launch while window exists", 0, countTasks(rec, "launch"))
  sh("VOICE_VIM_SOCK='" .. sock .. "' '" .. root .. "/spike/host/vv-host' stop")
end

-- ghostty-window: no host window yet -> launch via hs.task, focus when it appears.
do
  local rec, M, sock = setup("ghostty-window")
  local g = rec:app({ bundleID = GHOSTTY })
  g._windows = {}
  rec.hotkeyBinds[1].fn()
  local li = findTask(rec, "ghostty-window.sh' launch")
  local t = li and rec.tasks[li]
  check("ghostty-window cold: launch runs as an hs.task", true, t ~= nil and t.started)
  local hw = rec:window({ id = 9, title = "voice-vim-host", app = g })
  g._windows = { hw }
  rec:finishTask(li, 0, "", "")
  rec:runTimers()
  check("ghostty-window cold: window focused once it appears", 9, lastFocusId(rec))
  check("ghostty-window cold: show timing logged", true, rec:hasLog("i", "show: host focused after"))
  sh("VOICE_VIM_SOCK='" .. sock .. "' '" .. root .. "/spike/host/vv-host' stop")
end

-- neovide: app running and hidden.
do
  local rec, M, sock = setup("neovide")
  local nv = rec:app({ bundleID = NEOVIDE, name = "Neovide" })
  nv._window = rec:window({ id = 11, app = nv })
  roundTrip("neovide", rec, M, sock, "neovide.sh", {
    afterShow = function()
      check("neovide: show unhides", 1, #rec.unhides)
      check("neovide: show activates Neovide", nv, rec.activations[#rec.activations])
    end,
    afterHide = function()
      check("neovide: hide calls app:hide()", nv, rec.hides[1])
    end,
  })
end

-- quick-terminal: show = launch (hs.task), hide = toggle (hs.task).
local function qtCase(label, opts)
  local rec, M, sock = setup("quick-terminal", opts)
  local g = rec:app({ bundleID = GHOSTTY })
  local qtw = rec:window({ id = 12, app = g })
  roundTrip("quick-terminal" .. label, rec, M, sock, "quick-terminal.sh", {
    afterShow = function()
      local li = findTask(rec, "quick-terminal.sh' launch")
      local t = li and rec.tasks[li]
      check("quick-terminal" .. label .. ": show runs launch as an hs.task", true, t ~= nil)
      check("quick-terminal" .. label .. ": VV_QT_MODE", opts and opts.qtMode == "keystroke" or false,
        t ~= nil and has(t.args[2], "VV_QT_MODE='keystroke'"))
      -- What Ghostty does: the quick terminal takes focus.
      rec.frontmost, rec.focusedWindow = g, qtw
      rec:finishTask(li, 0, "", "")
    end,
    afterHide = function()
      local ti = findTask(rec, "quick-terminal.sh' toggle")
      check("quick-terminal" .. label .. ": hide runs toggle as an hs.task", true, ti ~= nil)
      if ti then rec:finishTask(ti, 0, "", "") end
    end,
  })
end
qtCase("", nil)
qtCase(" keystroke", { qtMode = "keystroke" })

-- Timing is measured from the press: a 40 ms note/draft must show up in the
-- "focused after" lines, and the note/draft cost is logged on its own.
do
  local rec, M, sock = setup("ghostty-window")
  local g = rec:app({ bundleID = GHOSTTY })
  local hw = rec:window({ id = 9, title = "voice-vim-host", app = g })
  g._windows = { hw }
  local exec = hs.execute
  hs.execute = function(...) rec.clock = rec.clock + 0.04; return exec(...) end
  local press = rec.hotkeyBinds[#rec.hotkeyBinds].fn
  press()
  rec:runTimers()
  check("t0: show note took 40 ms logged", 40, logMs(rec, "show: note took "))
  local showMs = logMs(rec, "show: host focused after ")
  check("t0: show ms includes the 40 ms note", true, showMs ~= nil and showMs >= 40)
  press()
  rec:runTimers()
  check("t0: hide draft took 40 ms logged", 40, logMs(rec, "hide: draft took "))
  local hideMs = logMs(rec, "hide: target focused after ")
  check("t0: hide ms includes the 40 ms draft", true, hideMs ~= nil and hideMs >= 40)
  hs.execute = exec
  sh("VOICE_VIM_SOCK='" .. sock .. "' '" .. root .. "/spike/host/vv-host' stop")
end

-- Pre-warm: start() runs `vv-host ensure` as an hs.task; a press during it
-- waits (no synchronous note) and continues when it finishes.
do
  local rec, M, sock = setup("neovide", { keepWarm = true })
  local nv = rec:app({ bundleID = NEOVIDE, name = "Neovide" })
  nv._window = rec:window({ id = 11, app = nv })
  local wi = findTask(rec, "vv-host' ensure")
  local t = wi and rec.tasks[wi]
  check("pre-warm: start runs ensure as an hs.task", true, t ~= nil and t.started)
  check("pre-warm: ensure carries the socket", true, t ~= nil and has(t.args[2], sock))
  rec.hotkeyBinds[#rec.hotkeyBinds].fn()
  check("pre-warm: press waits, no note yet", nil, lastExec(rec, "neovide.sh' note"))
  check("pre-warm: wait logged", true, rec:hasLog("i", "waiting for the pre-warm"))
  -- What the real task does: start the server.
  sh("VOICE_VIM_SOCK='" .. sock .. "' VV_HOST_NVIM_FLAGS=--clean '" .. root .. "/spike/host/vv-host' ensure")
  rec:finishTask(wi, 0, "", "")
  check("pre-warm: note runs after ensure", true, lastExec(rec, "neovide.sh' note") ~= nil)
  rec:runTimers()
  check("pre-warm: host shown", true, M.shown and rec:hasLog("i", "show: host focused after"))
  local before = countTasks(rec, "vv-host' ensure")
  M.use("ghostty-window")
  check("pre-warm: use() runs ensure again", before + 1, countTasks(rec, "vv-host' ensure"))
  sh("VOICE_VIM_SOCK='" .. sock .. "' '" .. root .. "/spike/host/vv-host' stop")
end

-- ghostty-window parked off-screen by an earlier copy of the module (no
-- saved position): show centres it on the main screen.
do
  local rec, M, sock = setup("ghostty-window")
  local g = rec:app({ bundleID = GHOSTTY })
  local hw = rec:window({ id = 9, title = "voice-vim-host", app = g, topLeft = { x = 1439, y = 899 } })
  g._windows = { hw }
  rec.hotkeyBinds[#rec.hotkeyBinds].fn()
  local mv = rec.moves[#rec.moves]
  check("off-screen: show moves the window", 9, mv and mv.win:id())
  check("off-screen: centred x", 320, mv and mv.point.x)
  check("off-screen: centred y", 150, mv and mv.point.y)
  check("off-screen: then focused", 9, lastFocusId(rec))
  -- An on-screen window without a saved position is left where it is.
  local rec2, M2, sock2 = setup("ghostty-window")
  local g2 = rec2:app({ bundleID = GHOSTTY })
  g2._windows = { rec2:window({ id = 9, title = "voice-vim-host", app = g2, topLeft = { x = 10, y = 20 } }) }
  rec2.hotkeyBinds[#rec2.hotkeyBinds].fn()
  check("on-screen: show does not move it", 0, #rec2.moves)
  sh("VOICE_VIM_SOCK='" .. sock .. "' '" .. root .. "/spike/host/vv-host' stop")
  sh("VOICE_VIM_SOCK='" .. sock2 .. "' '" .. root .. "/spike/host/vv-host' stop")
end

-- quick-terminal: autohide hid it while Joe was in another Ghostty window.
-- The next press must show (not hide), and log why.
do
  local rec, M, sock = setup("quick-terminal")
  local g = rec:app({ bundleID = GHOSTTY })
  local qtw = rec:window({ id = 12, app = g })
  local other = rec:window({ id = 13, title = "zsh", app = g })
  local press = rec.hotkeyBinds[#rec.hotkeyBinds].fn
  press()
  rec.frontmost, rec.focusedWindow = g, qtw
  rec:finishTask(findTask(rec, "quick-terminal.sh' launch"), 0, "", "")
  rec:runTimers()
  check("qt autohide: shown and window 12 learned", true, M.shown and M._qtWin == 12)
  rec.focusedWindow = other  -- autohide: quick terminal gone, zsh window focused
  local notes = 0
  for _, e in ipairs(rec.executes) do if has(e.cmd, "quick-terminal.sh' note") then notes = notes + 1 end end
  press()
  local notes2 = 0
  for _, e in ipairs(rec.executes) do if has(e.cmd, "quick-terminal.sh' note") then notes2 = notes2 + 1 end end
  check("qt autohide: press shows again (note runs)", notes + 1, notes2)
  check("qt autohide: no draft run", nil, lastExec(rec, "quick-terminal.sh' draft"))
  check("qt autohide: reason logged", true, rec:hasLog("i", "not quick terminal window 12"))
  check("qt autohide: branch logged", true, rec:hasLog("i", "-> show;"))
  check("qt autohide: target is the zsh window", 13, M.target and M.target.winId)
  sh("VOICE_VIM_SOCK='" .. sock .. "' '" .. root .. "/spike/host/vv-host' stop")
end

-- use(): switching while shown hides the old host (draft, hide, refocus).
do
  local rec, M, sock = setup("neovide")
  local nv = rec:app({ bundleID = NEOVIDE, name = "Neovide" })
  nv._window = rec:window({ id = 11, app = nv })
  rec.hotkeyBinds[1].fn()
  check("use: neovide shown first", true, M.shown)
  local ret = M.use("ghostty-window")
  check("use: returns the module", M, ret)
  check("use: ran draft for the old host", true, lastExec(rec, "neovide.sh' draft") ~= nil)
  check("use: hid Neovide", nv, rec.hides[1])
  check("use: refocused window 4242", 4242, lastFocusId(rec))
  check("use: host switched", "ghostty-window", M.config.host)
  check("use: shown cleared", false, M.shown)
  sh("VOICE_VIM_SOCK='" .. sock .. "' '" .. root .. "/spike/host/vv-host' stop")
end

-- Target window closed while shown: falls back to activating the app.
do
  local rec, M, sock = setup("neovide")
  local nv = rec:app({ bundleID = NEOVIDE, name = "Neovide" })
  nv._window = rec:window({ id = 11, app = nv })
  local press = rec.hotkeyBinds[1].fn
  press()
  rec:runTimers()
  rec:closeWindow(4242)
  local before = #rec.activations
  press()
  check("closed target: app activated", "com.example.target",
    rec.activations[before + 1] and rec.activations[before + 1]:bundleID())
  sh("VOICE_VIM_SOCK='" .. sock .. "' '" .. root .. "/spike/host/vv-host' stop")
end

os.exit(fail)
LUA

VV_ROOT="$root" VV_WORK="$work" perl -e 'alarm 60; exec @ARGV' nvim -l "$work/spec.lua" 2>&1
status=$?
echo  # nvim -l leaves the last line unterminated

check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want '$2' got '$3'"; status=1; fi; }
check "fake osascript/open/neovide never called" 0 "$(grep -c '^CALL ' "$work/calls")"
check "voice-vim.lua does not load the spike" 0 "$(grep -c 'spike' "$root/hammerspoon/voice-vim.lua")"
if command -v luajit >/dev/null || [ -x /opt/homebrew/bin/luajit ]; then
  lj=$(command -v luajit || echo /opt/homebrew/bin/luajit)
  check "host.lua parses under LuaJIT" ok "$("$lj" -e "assert(loadfile('$root/spike/host/host.lua')) print('ok')" 2>&1)"
fi
if command -v lua5.4 >/dev/null || command -v lua >/dev/null; then
  l=$(command -v lua5.4 || command -v lua)
  check "host.lua parses under $(basename "$l")" ok "$("$l" -e "assert(loadfile('$root/spike/host/host.lua')) print('ok')" 2>&1)"
fi

if [ $status -eq 0 ]; then echo "all ok"; else echo "FAILED"; fi
exit $status
