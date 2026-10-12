#!/usr/bin/env bash
# hammerspoon/instance.lua against the stub in tests/hs_stub.lua under
# `nvim -l`, with a recording stub host. hs.execute really runs
# bin/voice-vim-host against a headless nvim on a temp socket (--clean, temp
# DB and notes dir); hs.task is recorded, never run. Fake osascript/open/
# neovide on PATH record and fail, so nothing reaches other apps. Never
# touches the real Hammerspoon or Joe's nvim server.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# macOS socket paths max out at 104 bytes, so keep the folder short.
work=$(mktemp -d /tmp/vvi.XXXX)
[ -n "$work" ] && [ -d "$work" ] || { echo "mktemp failed" >&2; exit 1; }
cleanup() {
  pkill -f -- "--listen $work/" 2>/dev/null
  pkill -f -- "$work/ui.py" 2>/dev/null
  rm -rf "$work"
}
trap cleanup EXIT

mkdir -p "$work/fakes"
for f in osascript open neovide; do
  printf '#!/bin/sh\n{ echo "CALL %s"; echo "$*"; } >> "%s/calls"\nexit 1\n' "$f" "$work" > "$work/fakes/$f"
  chmod +x "$work/fakes/$f"
done
: > "$work/calls"
export PATH="$work/fakes:$PATH" VOICE_VIM_DB="$work/history.sqlite"
# The controller must pass these itself.
unset VOICE_VIM_SOCK VOICE_VIM_NOTES_DIR VOICE_VIM_HOST_NVIM_FLAGS

# A stand-in UI: attaches to a server over its socket with a raw msgpack
# nvim_ui_attach request, then drains redraws until killed.
cat > "$work/ui.py" <<'PY'
import socket, sys
s = socket.socket(socket.AF_UNIX)
s.connect(sys.argv[1])
name = b"nvim_ui_attach"
s.sendall(bytes([0x94, 0, 1, 0xa0 | len(name)]) + name + bytes([0x93, 80, 24, 0x80]))
while s.recv(65536):
    pass
PY

cat > "$work/spec.lua" <<'LUA'
local root = assert(os.getenv("VV_ROOT"))
local work = assert(os.getenv("VV_WORK"))
local stub = dofile(root .. "/tests/hs_stub.lua")
local modpath = root .. "/hammerspoon/instance.lua"
local hostbin = root .. "/bin/voice-vim-host"
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

local function execs(rec, needle)
  local out = {}
  for _, e in ipairs(rec.executes) do if has(e.cmd, needle) then out[#out + 1] = e end end
  return out
end

local function lastFocusId(rec)
  local w = rec.focuses[#rec.focuses]
  return w and w:id()
end

local n = 0
local function hostEnv(sock)
  return "VOICE_VIM_SOCK='" .. sock .. "' VOICE_VIM_NOTES_DIR='" .. work .. "/notes' "
    .. "VOICE_VIM_HOST_NVIM_FLAGS=--clean '" .. hostbin .. "' "
end
local function ensure(sock) return sh(hostEnv(sock) .. "ensure") end
local function stop(sock) sh(hostEnv(sock) .. "stop") end
local function ask(sock, expr)
  return sh("nvim --server '" .. sock .. "' --remote-expr '" .. expr .. "'")
end
local function servers(sock)
  return tonumber(sh("pgrep -f -- '--listen " .. sock .. "' | wc -l")) or -1
end
local function status(sock) return sh(hostEnv(sock) .. "status") end
local function q(s) return "'" .. (tostring(s):gsub("'", "'\\''")) .. "'" end
-- Run a recorded hs.task's real command, then finish it with its exit code.
local function runTask(rec, i)
  local t = rec.tasks[i]
  local out = sh(t.path .. " " .. q(t.args[1]) .. " " .. q(t.args[2]) .. "; echo \"rc=$?\"")
  local rc = tonumber(out:match("rc=(%d+)$")) or 1
  rec:finishTask(i, rc, out, "")
end
-- Attach a stand-in UI to sock; returns its pid once status shows it.
local function attachUI(sock)
  local pid = sh("python3 '" .. work .. "/ui.py' '" .. sock .. "' </dev/null >/dev/null 2>&1 & echo $!")
  for _ = 1, 100 do
    if status(sock) == "up uis=1" then break end
    sh("sleep 0.05")
  end
  return pid
end

-- A target app with window 4242 in front, a stub host that records calls
-- in `order`, and a controller on its own socket. opts.warm = false leaves
-- the pre-warm task running and the server down.
local function setup(opts)
  opts = opts or {}
  n = n + 1
  local rec = stub.install()
  rec.execStatus = true  -- hs.execute reports voice-vim-host's exit code
  local sock = work .. "/s" .. n .. ".sock"
  local target = rec:app({ bundleID = "com.example.target" })
  local tw = rec:window({ id = 4242, app = target })
  target._window = tw
  rec.frontmost, rec.focusedWindow = target, tw
  local hostApp = rec:app({ bundleID = "com.example.host" })
  local hostWin = rec:window({ id = 7, app = hostApp })
  local order, delivered = {}, {}
  local host = {
    show = function(cb)
      order[#order + 1] = "host.show"
      rec.frontmost, rec.focusedWindow = hostApp, hostWin
      cb(true)
    end,
    hide = function(cb)
      order[#order + 1] = "host.hide"
      rec.focusedWindow = nil
      cb(true)
    end,
    isFocused = function()
      return rec.focusedWindow == hostWin, "stub host window " .. tostring(rec.focusedWindow == hostWin)
    end,
    launch = function(cb) order[#order + 1] = "host.launch"; cb(true) end,
  }
  local I = stub.load(modpath)
  local cfg = {
    host = host, root = root, sock = sock, notesDir = work .. "/notes", nvimFlags = "--clean",
    deliver = function(p) order[#order + 1] = "deliver"; delivered[#delivered + 1] = p end,
  }
  for k, v in pairs(opts) do if k ~= "warm" then cfg[k] = v end end
  local c = I.new(cfg)
  c.prewarm()
  if opts.warm ~= false then
    ensure(sock)  -- what the pre-warm task does
    rec:finishTask(#rec.tasks, 0, "", "")
  end
  return { rec = rec, c = c, sock = sock, order = order, delivered = delivered,
    target = target, hostWin = hostWin, host = host }
end

local function count(list, x)
  local k = 0
  for _, v in ipairs(list) do if v == x then k = k + 1 end end
  return k
end

-- Show from window 4242, then hide.
do
  local t = setup()
  local rec, c, sock = t.rec, t.c, t.sock
  check("prewarm runs ensure as an hs.task", true,
    rec.tasks[1] ~= nil and has(rec.tasks[1].args[2], "'ensure'") and rec.tasks[1].started)
  check("ensure task carries the socket", true, rec.tasks[1] ~= nil and has(rec.tasks[1].args[2], sock))
  c.toggle()
  local shows = execs(rec, "'show' 'com.example.target' '4242'")
  check("toggle from window 4242 runs show com.example.target 4242", 1, #shows)
  check("show carries the socket and --clean", true,
    shows[1] ~= nil and has(shows[1].cmd, sock) and has(shows[1].cmd, "--clean"))
  check("note in insert mode with target 4242", "i com.example.target 4242",
    ask(sock, 'mode()." ".b:voicevim.target." ".b:voicevim.window'))
  check("one host.show", 1, count(t.order, "host.show"))
  rec:runTimers()
  check("logs show: host focused after", true, rec:hasLog("i", "show: host focused after"))
  check("logs show: show took", true, rec:hasLog("i", "show: show took"))
  check("logger is voice-vim", true, rec:findLogs("i", "show: host focused after")[1].name == "voice-vim")
  check("toggle logs -> show", true, rec:hasLog("i", "-> show;"))
  check("default: no Cmd+C (captureSelection off)", 0, #rec.keyStrokes)

  ask(sock, 'nvim_buf_set_lines(0, 0, -1, v:false, ["draft words"])')
  local path = ask(sock, "expand(\"%:p\")")
  c.toggle()
  check("toggle while focused runs draft", 1, #execs(rec, "'draft'"))
  check("draft wrote the note", "draft words", sh("cat '" .. path .. "'"))
  check("toggle while focused calls host.hide", 1, count(t.order, "host.hide"))
  check("toggle while focused focuses 4242", 4242, lastFocusId(rec))
  rec:runTimers()
  check("logs hide: target focused after", true, rec:hasLog("i", "hide: target focused after"))
  check("toggle logs -> hide", true, rec:hasLog("i", "-> hide;"))
  check("hide uses the captured window (no hs.window.get)", 0, rec.windowGets)
  check("shown is false after hide", false, c.shown)

  c.toggle()
  check("next show resumes the draft", path, ask(sock, "expand(\"%:p\")"))
  stop(sock)
end

-- Target window closed while shown: hide activates its app.
do
  local t = setup()
  local rec, c = t.rec, t.c
  c.toggle()
  rec:runTimers()
  rec:closeWindow(4242)
  local before = #rec.activations
  c.toggle()
  check("closed target window -> app activated", "com.example.target",
    rec.activations[before + 1] and rec.activations[before + 1]:bundleID())
  stop(t.sock)
end

-- onSubmit: host.hide before deliver, same params; no draft call.
do
  local t = setup()
  local rec, c = t.rec, t.c
  c.toggle()
  rec:runTimers()
  local p = { file = "/tmp/x.md", target = "com.example.target", window = "4242" }
  c.onSubmit(p)
  check("onSubmit calls host.hide before deliver", "host.launch,host.show,host.hide,deliver",
    table.concat(t.order, ","))
  check("onSubmit passes the same params to deliver", p, t.delivered[1])
  check("onSubmit runs no draft", 0, #execs(rec, "'draft'"))
  check("shown is false after onSubmit", false, c.shown)
  stop(t.sock)
end

-- onHide (the note's :Hide / :Cancel) and bindURLs.
do
  local t = setup()
  local rec, c = t.rec, t.c
  c.bindURLs()
  check("bindURLs binds voicevim-submit", "function", type(rec.urlBinds["voicevim-submit"]))
  check("bindURLs binds voicevim-hide", "function", type(rec.urlBinds["voicevim-hide"]))
  c.toggle()
  rec:runTimers()
  rec:openURL("voicevim-hide", {})
  check("voicevim-hide calls host.hide", 1, count(t.order, "host.hide"))
  check("voicevim-hide refocuses 4242", 4242, lastFocusId(rec))
  check("voicevim-hide runs no draft", 0, #execs(rec, "'draft'"))
  rec:runTimers()
  check("voicevim-hide logs hide timing", true, rec:hasLog("i", "hide: target focused after"))
  rec:openURL("voicevim-submit", { file = "f", target = "com.example.target", window = "4242" })
  check("voicevim-submit hides then delivers", "host.hide,deliver",
    table.concat(t.order, ",", #t.order - 1, #t.order))
  check("voicevim-submit passes the URL params", "f", t.delivered[1] and t.delivered[1].file)
  stop(t.sock)
end

-- Hotkey hide while Flow is recording (started from the note): the note
-- stays up until Flow's paste lands, then asks to be hidden itself.
do
  local t = setup()
  local rec, c, sock = t.rec, t.c, t.sock
  c.bindURLs()
  c.toggle()
  rec:runTimers()
  -- In the server: record Flow URLs and host calls instead of running open,
  -- then start Flow as Ctrl-S would.
  local function run(name, body)
    local f = assert(io.open(work .. "/" .. name, "w"))
    f:write(body)
    f:close()
    return ask(sock, 'luaeval("dofile(\\"' .. work .. "/" .. name .. '\\")")')
  end
  run("flowrec.lua", [[
    local f = require("voice-vim.flow")
    f.open = function(u) vim.g.vv_flow = (vim.g.vv_flow or "") .. u .. " " end
    require("voice-vim.note").host = {
      hide = function() vim.g.vv_hidden = (vim.g.vv_hidden or 0) + 1 end,
      submit = function() end,
    }
    f.start()
    return 1
  ]])
  local function hidden() return ask(sock, 'get(g:, "vv_hidden", 0)') end
  ask(sock, 'nvim_buf_set_lines(0, 0, -1, v:false, ["draft words"])')
  local path = ask(sock, "expand(\"%:p\")")
  c.toggle()
  check("Flow recording: hotkey draft answers waiting for flow", true,
    has(execs(rec, "'draft'")[1] and rec.executes[#rec.executes].out, "waiting for flow"))
  check("Flow recording: host not hidden, target not refocused", "0 0",
    count(t.order, "host.hide") .. " " .. #rec.focuses)
  check("Flow recording: hide waits logged", true, rec:hasLog("i", "hide: Flow is recording"))
  check("Flow recording: the note sent stop-hands-free", true, has(ask(sock, 'get(g:, "vv_flow", "")'), "stop-hands-free"))
  c.toggle()  -- a second press during the wait changes nothing
  check("Flow recording: second press still waits", "0 0",
    count(t.order, "host.hide") .. " " .. hidden())
  run("paste.lua", 'vim.paste({ " last words" }, -1) return 1')  -- Flow's paste
  for _ = 1, 100 do
    if hidden() ~= "0" then break end
    sh("sleep 0.02")
  end
  check("Flow recording: after the paste the note asks to hide once", "1", hidden())
  check("Flow recording: the draft holds the last words", true, has(sh("cat '" .. path .. "'"), "last words"))
  rec:openURL("voicevim-hide", {})  -- what the note's hide URL does
  check("Flow recording: voicevim-hide then hides and refocuses 4242", "1 4242",
    count(t.order, "host.hide") .. " " .. tostring(lastFocusId(rec)))
  stop(sock)
end

-- Ctrl-Q during the hotkey's hide-while-recording wait: the cancel takes
-- over the wait, so nothing hides (and the target is not refocused) until
-- Flow's paste has landed in the note; then the note is cancelled.
do
  local t = setup()
  local rec, c, sock = t.rec, t.c, t.sock
  c.bindURLs()
  c.toggle()
  rec:runTimers()
  local f = assert(io.open(work .. "/flowrec2.lua", "w"))
  f:write([[
    local f = require("voice-vim.flow")
    f.open = function() end
    require("voice-vim.note").host = {
      hide = function() vim.g.vv_hidden = (vim.g.vv_hidden or 0) + 1 end,
      submit = function() vim.g.vv_submitted = 1 end,
    }
    f.start()
    return 1
  ]])
  f:close()
  ask(sock, 'luaeval("dofile(\\"' .. work .. '/flowrec2.lua\\")")')
  local function hidden() return ask(sock, 'get(g:, "vv_hidden", 0)') end
  ask(sock, 'nvim_buf_set_lines(0, 0, -1, v:false, ["draft words"])')
  local path = ask(sock, "expand(\"%:p\")")
  c.toggle()  -- hotkey hide: waits for Flow
  ask(sock, 'luaeval("require(\\"voice-vim.note\\").cancel()")')  -- Ctrl-Q
  sh("sleep 0.3")
  check("Ctrl-Q during the hide wait: nothing hidden before Flow's paste", "0 0",
    hidden() .. " " .. count(t.order, "host.hide"))
  check("Ctrl-Q during the hide wait: note not cancelled yet", "draft words",
    ask(sock, 'getline(1)'))
  ask(sock, 'luaeval("vim.paste({\\" late\\"}, -1)")')  -- Flow's paste
  for _ = 1, 100 do
    if hidden() ~= "0" then break end
    sh("sleep 0.02")
  end
  check("Ctrl-Q during the hide wait: after the paste, cancelled and hidden once", "1 0",
    hidden() .. " " .. ask(sock, 'get(g:, "vv_submitted", 0)'))
  check("Ctrl-Q during the hide wait: the note file (with the paste) is gone", nil, io.open(path, "r"))
  stop(sock)
end

-- A press during the pre-warm waits for it: no show, no second server.
do
  local t = setup({ warm = false })
  local rec, c, sock = t.rec, t.c, t.sock
  c.toggle()
  check("press during prewarm: no show yet", 0, #execs(rec, "'show'"))
  check("press during prewarm: no synchronous ensure", 0, #execs(rec, "'ensure'"))
  check("press during prewarm: wait logged", true, rec:hasLog("i", "waiting for the pre-warm"))
  check("press during prewarm: no host.show yet", 0, count(t.order, "host.show"))
  c.prewarm()
  check("second prewarm while warming starts no task", 1, #rec.tasks)
  ensure(sock)  -- what the pre-warm task does
  rec:finishTask(1, 0, "", "")
  check("press during prewarm starts no second server", 1, servers(sock))
  check("after prewarm: show runs once", 1, #execs(rec, "'show' 'com.example.target' '4242'"))
  check("after prewarm: one host.show", 1, count(t.order, "host.show"))
  check("after prewarm: note in insert mode", "i", ask(sock, "mode()"))
  rec:runTimers()
  check("after prewarm: show timing logged", true, rec:hasLog("i", "show: host focused after"))
  stop(sock)
end

-- Server down: show fails, ensure runs as an hs.task, show is retried once.
do
  local t = setup()
  local rec, c, sock = t.rec, t.c, t.sock
  stop(sock)
  c.toggle()
  check("server down: logged", true, rec:hasLog("w", "show: server down"))
  local task = rec.tasks[#rec.tasks]
  check("server down: ensure started as a second hs.task", true,
    #rec.tasks == 2 and has(task.args[2], "'ensure'") and has(task.args[2], sock) and task.started)
  check("server down: no alert, no host.show yet", "0 0", #rec.alerts .. " " .. count(t.order, "host.show"))
  runTask(rec, #rec.tasks)  -- the task's real command
  check("after voice-vim-host stop, a toggle restarts the server", "1 up uis=0", servers(sock) .. " " .. status(sock))
  check("server down: show retried once", 2, #execs(rec, "'show' 'com.example.target' '4242'"))
  check("restarted server: note in insert mode with target 4242", "i com.example.target 4242",
    ask(sock, 'mode()." ".b:voicevim.target." ".b:voicevim.window'))
  rec:runTimers()
  check("restarted server: one host.show, host focused", "1 true",
    count(t.order, "host.show") .. " " .. tostring(rec:hasLog("i", "show: host focused after")))
  check("restarted server: shown, no alert", "true 0", tostring(c.shown) .. " " .. #rec.alerts)
  stop(sock)
end

-- Server down and ensure fails: one retry, then alert; no second ensure.
do
  local t = setup()
  local rec, c, sock = t.rec, t.c, t.sock
  stop(sock)
  c.toggle()
  rec:finishTask(#rec.tasks, 1, "", "failed")  -- ensure failed, no server
  check("ensure failed: show tried twice", 2, #execs(rec, "'show' 'com.example.target' '4242'"))
  check("ensure failed: alert", true, #rec.alerts == 1 and has(rec.alerts[1], "could not open the note"))
  check("ensure failed: no further ensure", 2, #rec.tasks)
  check("ensure failed: no host.show, shown stays false", "0 false",
    count(t.order, "host.show") .. " " .. tostring(c.shown))
end

-- No UI attached (uis=0): host.launch once before polling, then host.show.
do
  local t = setup()
  local rec, c, sock = t.rec, t.c, t.sock
  check("headless server reports uis=0", "up uis=0", status(sock))
  c.toggle()
  check("uis=0: status runs after show", 1, #execs(rec, "'status'"))
  check("uis=0: host.launch called exactly once", 1, count(t.order, "host.launch"))
  check("uis=0: launch logged", true, rec:hasLog("i", "show: no UI attached (uis=0), host.launch"))
  rec:runTimers()
  check("uis=0: host.show once after launch, then focused", "host.launch,host.show true",
    table.concat(t.order, ",") .. " " .. tostring(rec:hasLog("i", "show: host focused after")))
  c.toggle()  -- hide
  c.toggle()  -- show again, UI still not attached, within launchGrace
  rec:runTimers()
  check("uis=0 within launchGrace: no second host.launch", 1, count(t.order, "host.launch"))
  check("uis=0 within launchGrace: host.show again", 2, count(t.order, "host.show"))
  stop(sock)
end

-- A show that fails (host.show false, or the host never gets focus):
-- one alert per press, and the next press launches the host again
-- instead of waiting out launchGrace.
for _, case in ipairs({ "host.show false", "never focused" }) do
  local t = setup({ pollTimeout = 0.2, hostName = "Neovide" })
  local rec, c, sock = t.rec, t.c, t.sock
  t.host.show = function(cb)
    t.order[#t.order + 1] = "host.show"
    if case == "host.show false" then cb(false, "Neovide not running") else cb(true) end
  end
  c.toggle()
  rec:runTimers()
  check(case .. ": one alert for the press", 1, #rec.alerts)
  check(case .. ": alert says Neovide did not appear", true,
    has(rec.alerts[1], "voice-vim: Neovide did not appear") and has(rec.alerts[1], "Hammerspoon console"))
  check(case .. ": host launched once", 1, count(t.order, "host.launch"))
  c.toggle()  -- next press, well within launchGrace
  rec:runTimers()
  check(case .. ": next press launches again", 2, count(t.order, "host.launch"))
  check(case .. ": next press alerts once more", 2, #rec.alerts)
  stop(sock)
end

-- A UI attached: no host.launch.
do
  local t = setup()
  local rec, c, sock = t.rec, t.c, t.sock
  local pid = attachUI(sock)
  check("stand-in UI attached", "up uis=1", status(sock))
  c.toggle()
  rec:runTimers()
  check("UI attached: host.launch not called", 0, count(t.order, "host.launch"))
  check("UI attached: one host.show, focused", "host.show true",
    table.concat(t.order, ",") .. " " .. tostring(rec:hasLog("i", "show: host focused after")))
  sh("kill " .. pid)
  stop(sock)
end

-- captureSelection on: Cmd+C into the target, selection seeds a fresh note.
do
  local t = setup({ captureSelection = true })
  local rec, c, sock = t.rec, t.c, t.sock
  rec.pasteboard = { contents = "old clipboard", changeCount = 5 }
  rec.onKeyStroke = function(mods, key)
    if key == "c" then rec.pasteboard = { contents = "picked text", changeCount = 6 } end
  end
  c.toggle()
  local k = rec.keyStrokes[1]
  check("captureSelection: Cmd+C sent to the target app", "cmd c com.example.target",
    k and (table.concat(k.mods, "+") .. " " .. k.key .. " " .. tostring(k.app and k.app:bundleID())))
  local e = execs(rec, "'show' 'com.example.target' '4242'")[1]
  local seed = e and e.cmd:match("'4242' '([^']+)'")
  check("captureSelection: show gets a seed file", true, seed ~= nil)
  check("captureSelection: note holds the selection", "picked text", ask(sock, 'getline(1)'))
  check("captureSelection: seed file removed", nil, seed and io.open(seed, "r"))
  check("captureSelection: clipboard restored", "old clipboard", rec.pasteboard.contents)
  stop(sock)
end

os.exit(fail)
LUA

VV_ROOT="$root" VV_WORK="$work" perl -e 'alarm 60; exec @ARGV' nvim -l "$work/spec.lua" 2>&1
status=$?
echo  # nvim -l leaves the last line unterminated

check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want '$2' got '$3'"; status=1; fi; }
check "fake osascript/open/neovide never called" 0 "$(grep -c '^CALL ' "$work/calls")"
check "voice-vim.lua loads instance.lua" 1 "$(grep -c 'dofile(root .. "/hammerspoon/instance.lua")' "$root/hammerspoon/voice-vim.lua")"
lj=$(command -v luajit || echo /opt/homebrew/bin/luajit)
if [ -x "$lj" ]; then
  check "instance.lua parses under LuaJIT" ok "$("$lj" -e "assert(loadfile('$root/hammerspoon/instance.lua')) print('ok')" 2>&1)"
fi
if l=$(command -v lua5.4 || command -v lua); then
  check "instance.lua parses under $(basename "$l")" ok "$("$l" -e "assert(loadfile('$root/hammerspoon/instance.lua')) print('ok')" 2>&1)"
fi

if [ $status -eq 0 ]; then echo "all ok"; else echo "FAILED"; fi
exit $status
