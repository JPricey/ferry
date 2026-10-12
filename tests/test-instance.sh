#!/usr/bin/env bash
# hammerspoon/instance.lua against the stub in tests/hs_stub.lua under
# `nvim -l`, with a recording stub host. hs.execute really runs
# bin/ferry-host against a headless nvim on a temp socket (--clean, temp
# DB and notes dir); hs.task is recorded, never run. Fake osascript/open/
# neovide on PATH record and fail, so nothing reaches other apps. Never
# touches the real Hammerspoon or Joe's nvim server.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# macOS socket paths max out at 104 bytes, so keep the folder short.
work=$(mktemp -d /tmp/ferryi.XXXX)
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
# A failing ghostty: ferry-host ensure finds no GUI settings.
printf '#!/bin/sh\nexit 1\n' > "$work/fakes/ghostty"; chmod +x "$work/fakes/ghostty"
: > "$work/calls"
export PATH="$work/fakes:$PATH" FERRY_DB="$work/history.sqlite" \
  FERRY_INDEX="$work/index.sqlite" FERRY_OUTBOX="$work/outbox"
# The controller must pass these itself.
unset FERRY_SOCK FERRY_NOTES_DIR FERRY_HOST_NVIM_FLAGS

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
local root = assert(os.getenv("FERRY_ROOT"))
local work = assert(os.getenv("FERRY_WORK"))
local stub = dofile(root .. "/tests/hs_stub.lua")
local modpath = root .. "/hammerspoon/instance.lua"
local hostbin = root .. "/bin/ferry-host"
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
  return "FERRY_SOCK='" .. sock .. "' FERRY_NOTES_DIR='" .. work .. "/notes' "
    .. "FERRY_HOST_NVIM_FLAGS=--clean '" .. hostbin .. "' "
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
  rec.execStatus = true  -- hs.execute reports ferry-host's exit code
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
    ask(sock, 'mode()." ".b:ferry.target." ".b:ferry.window'))
  check("one host.show", 1, count(t.order, "host.show"))
  rec:runTimers()
  check("logs show: host focused after", true, rec:hasLog("i", "show: host focused after"))
  check("logs show: show took", true, rec:hasLog("i", "show: show took"))
  check("logger is ferry", true, rec:findLogs("i", "show: host focused after")[1].name == "ferry")
  check("toggle logs -> show", true, rec:hasLog("i", "-> show;"))
  check("default: no Cmd+C (captureSelection off)", 0, #rec.keyStrokes)

  ask(sock, 'nvim_buf_set_lines(0, 0, -1, v:false, ["draft words"])')
  local path = ask(sock, "expand(\"%:p\")")
  c.toggle()
  check("toggle while focused runs draft", 1, #execs(rec, "'draft'"))
  check("draft wrote the note file (body after the frontmatter)", "draft words", sh("sed '1,/^---$/d' '" .. path .. "'"))
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
  check("bindURLs binds ferry-submit", "function", type(rec.urlBinds["ferry-submit"]))
  check("bindURLs binds ferry-hide", "function", type(rec.urlBinds["ferry-hide"]))
  c.toggle()
  rec:runTimers()
  rec:openURL("ferry-hide", {})
  check("ferry-hide calls host.hide", 1, count(t.order, "host.hide"))
  check("ferry-hide refocuses 4242", 4242, lastFocusId(rec))
  check("ferry-hide runs no draft", 0, #execs(rec, "'draft'"))
  rec:runTimers()
  check("ferry-hide logs hide timing", true, rec:hasLog("i", "hide: target focused after"))
  rec:openURL("ferry-submit", { file = "f", target = "com.example.target", window = "4242" })
  check("ferry-submit hides then delivers", "host.hide,deliver",
    table.concat(t.order, ",", #t.order - 1, #t.order))
  check("ferry-submit passes the URL params", "f", t.delivered[1] and t.delivered[1].file)
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
    local f = require("ferry.flow")
    f.open = function(u) vim.g.ferry_flow = (vim.g.ferry_flow or "") .. u .. " " end
    require("ferry.note").host = {
      hide = function() vim.g.ferry_hidden = (vim.g.ferry_hidden or 0) + 1 end,
      submit = function() end,
    }
    f.start()
    return 1
  ]])
  local function hidden() return ask(sock, 'get(g:, "ferry_hidden", 0)') end
  ask(sock, 'nvim_buf_set_lines(0, 0, -1, v:false, ["draft words"])')
  local path = ask(sock, "expand(\"%:p\")")
  c.toggle()
  check("Flow recording: hotkey draft answers waiting for flow", true,
    has(execs(rec, "'draft'")[1] and rec.executes[#rec.executes].out, "waiting for flow"))
  check("Flow recording: host not hidden, target not refocused", "0 0",
    count(t.order, "host.hide") .. " " .. #rec.focuses)
  check("Flow recording: hide waits logged", true, rec:hasLog("i", "hide: Flow is recording"))
  check("Flow recording: the note sent stop-hands-free", true, has(ask(sock, 'get(g:, "ferry_flow", "")'), "stop-hands-free"))
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
  rec:openURL("ferry-hide", {})  -- what the note's hide URL does
  check("Flow recording: ferry-hide then hides and refocuses 4242", "1 4242",
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
    local f = require("ferry.flow")
    f.open = function() end
    require("ferry.note").host = {
      hide = function() vim.g.ferry_hidden = (vim.g.ferry_hidden or 0) + 1 end,
      submit = function() vim.g.ferry_submitted = 1 end,
    }
    f.start()
    return 1
  ]])
  f:close()
  ask(sock, 'luaeval("dofile(\\"' .. work .. '/flowrec2.lua\\")")')
  local function hidden() return ask(sock, 'get(g:, "ferry_hidden", 0)') end
  ask(sock, 'nvim_buf_set_lines(0, 0, -1, v:false, ["draft words"])')
  local path = ask(sock, "expand(\"%:p\")")
  c.toggle()  -- hotkey hide: waits for Flow
  ask(sock, 'luaeval("require(\\"ferry.note\\").cancel()")')  -- Ctrl-Q
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
    hidden() .. " " .. ask(sock, 'get(g:, "ferry_submitted", 0)'))
  local kept = sh("cat '" .. path .. "'")
  check("Ctrl-Q during the hide wait: the note file is kept as cancelled, with the paste", true,
    has(kept, "state: cancelled") and has(kept, "draft words") and has(kept, "late"))
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
  check("after ferry-host stop, a toggle restarts the server", "1 up uis=0", servers(sock) .. " " .. status(sock))
  check("server down: show retried once", 2, #execs(rec, "'show' 'com.example.target' '4242'"))
  check("restarted server: note in insert mode with target 4242", "i com.example.target 4242",
    ask(sock, 'mode()." ".b:ferry.target." ".b:ferry.window'))
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
    has(rec.alerts[1], "ferry: Neovide did not appear") and has(rec.alerts[1], "Hammerspoon console"))
  check(case .. ": host launched once", 1, count(t.order, "host.launch"))
  c.toggle()  -- next press, well within launchGrace
  rec:runTimers()
  check(case .. ": next press launches again", 2, count(t.order, "host.launch"))
  check(case .. ": next press alerts once more", 2, #rec.alerts)
  stop(sock)
end

-- hostName as a function is asked per alert (ferry.app built meanwhile).
do
  local name = "Neovide"
  local t = setup({ pollTimeout = 0.2, hostName = function() return name end })
  local rec, c, sock = t.rec, t.c, t.sock
  t.host.show = function(cb) cb(false, "not running") end
  c.toggle()
  rec:runTimers()
  name = "the ferry window"
  c.toggle()
  rec:runTimers()
  check("hostName function: asked per alert", "Neovide|the ferry window",
    tostring(tostring(rec.alerts[1]):match("ferry: (.-) did not appear")) .. "|"
    .. tostring(tostring(rec.alerts[2]):match("ferry: (.-) did not appear")))
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
  check("captureSelection: note holds the selection below its to: line", "picked text", ask(sock, 'getline(2)'))
  check("captureSelection: seed file removed", nil, seed and io.open(seed, "r"))
  check("captureSelection: clipboard restored", "old clipboard", rec.pasteboard.contents)
  stop(sock)
end

-- --- hold to talk: talkDown / talkUp -----------------------------------------

-- Run a Lua file in the server; its return value comes back as a string.
local function luaRun(sock, name, body)
  local f = assert(io.open(work .. "/" .. name, "w"))
  f:write(body)
  f:close()
  return ask(sock, 'luaeval("dofile(\\"' .. work .. "/" .. name .. '\\")")')
end
-- Record Flow URLs in g:ferry_flow instead of running `open`.
local function recordFlow(sock)
  luaRun(sock, "talkrec.lua", [[
    require("ferry.flow").open = function(u) vim.g.ferry_flow = (vim.g.ferry_flow or "") .. u .. " " end
    return 1
  ]])
end
local function urls(sock) return ask(sock, 'get(g:, "ferry_flow", "")') end
local function stops(sock)
  local k = 0
  for _ in urls(sock):gmatch("stop%-hands%-free") do k = k + 1 end
  return k
end
local function recording(sock)
  return luaRun(sock, "talkq.lua", 'return tostring(require("ferry.flow").recording())')
end
local function waiting(sock)
  return luaRun(sock, "talkw.lua", 'return tostring(require("ferry.flow").state.waiting ~= nil)')
end
-- Flow's paste into the note (a bracketed paste reaches nvim as vim.paste).
local function paste(sock, text)
  luaRun(sock, "talkp.lua", 'vim.paste({ "' .. text .. '" }, -1) return 1')
  sh("sleep 0.1")
end
-- Fire the timers pending now once (not the ones they schedule).
local function tick(rec)
  local k = #rec.timers
  for i = 1, k do
    local t = rec.timers[i]
    if not t.fired then
      t.fired = true
      rec.clock = rec.clock + t.delay
      t.fn()
    end
  end
end
local function startTasks(rec)
  local out = {}
  for i, t in ipairs(rec.tasks) do
    if t.path == "/usr/bin/open" then out[#out + 1] = i end
  end
  return out
end
local function finishStart(rec, k) rec:finishTask(startTasks(rec)[k or #startTasks(rec)], 0, "", "") end

-- talkDown from window 4242 with the host slow to get focus: Flow's start
-- task goes first, then show --talk; talkUp holds the release until the
-- host is focused, the start task has exited and no modifier is down.
do
  local t = setup()
  local rec, c, sock = t.rec, t.c, t.sock
  recordFlow(sock)
  t.host.show = function(cb) t.order[#t.order + 1] = "host.show"; cb(true) end  -- no focus yet
  c.talkDown()
  local st = rec.tasks[startTasks(rec)[1] or 0]
  check("talkDown: Flow start task is open -g wispr-flow://start-hands-free", "-g wispr-flow://start-hands-free",
    st and table.concat(st.args, " "))
  check("talkDown: start task started", true, st ~= nil and st.started)
  local shows = execs(rec, "'show' '--talk' 'com.example.target' '4242'")
  check("talkDown from 4242: show --talk com.example.target 4242", 1, #shows)
  check("talkDown: start task before the show execute", true, st ~= nil and shows[1] ~= nil and st.seq < shows[1].seq)
  check("talkDown: server reports recording, no URL", "true ", recording(sock) .. " " .. urls(sock))
  check("talkDown: note in insert mode with target 4242", "i com.example.target 4242",
    ask(sock, 'mode()." ".b:ferry.target." ".b:ferry.window'))
  check("talkDown logs focused=false -> show", true, rec:hasLog("i", "talk: down focused=false -> show"))
  check("talkDown logs the start task", true, rec:hasLog("i", "talk: flow start task started after"))

  c.talkUp()
  check("talkUp logs up after N ms held", true, rec:hasLog("i", "talk: up after"))
  tick(rec)
  check("talkUp before focus: no release", 0, #execs(rec, "'release'"))
  rec.frontmost, rec.focusedWindow = rec.apps["com.example.host"], t.hostWin
  tick(rec)
  check("focused but the start task still running: no release", 0, #execs(rec, "'release'"))
  rec.modifiers = { ctrl = true, alt = true }
  finishStart(rec)
  check("start task exit logged", true, rec:hasLog("i", "talk: flow start exited after"))
  tick(rec)
  tick(rec)
  check("modifiers down: release held", 0, #execs(rec, "'release'"))
  rec.modifiers = {}
  tick(rec)
  check("modifiers up: exactly one release", 1, #execs(rec, "'release'"))
  check("release printed released", "released", (execs(rec, "'release'")[1].out:gsub("%s+$", "")))
  check("server URLs end in one stop", "wispr-flow://stop-hands-free", urls(sock))
  check("release logged with its waits", true, rec:hasLog("i", "talk: release after"))
  rec:runTimers()
  check("no second release, no alert", "1 0", #execs(rec, "'release'") .. " " .. #rec.alerts)
  paste(sock, "talked")
  check("after Flow's paste: not recording, no wait", "false false", recording(sock) .. " " .. waiting(sock))
  stop(sock)
end

-- Modifiers that never come up: release anyway talkModsTimeout after the
-- host was ready.
do
  local t = setup({ talkModsTimeout = 0.2 })
  local rec, c, sock = t.rec, t.c, t.sock
  recordFlow(sock)
  c.talkDown()
  finishStart(rec)
  rec.modifiers = { ctrl = true }
  c.talkUp()
  check("modifiers stuck: no release at once", 0, #execs(rec, "'release'"))
  rec:runTimers()
  check("modifiers stuck: one release after talkModsTimeout, warned", "1 true",
    #execs(rec, "'release'") .. " " .. tostring(rec:hasLog("w", "still down after")))
  check("modifiers stuck: one stop", 1, stops(sock))
  stop(sock)
end

-- Never focused: no release, one alert, Flow still recording.
do
  local t = setup()
  local rec, c, sock = t.rec, t.c, t.sock
  recordFlow(sock)
  t.host.show = function(cb) t.order[#t.order + 1] = "host.show"; cb(true) end
  c.talkDown()
  finishStart(rec)
  c.talkUp()
  rec:runTimers()
  check("never focused: no release", 0, #execs(rec, "'release'"))
  check("never focused: one alert", 1, #rec.alerts)
  check("never focused: alert says Flow is still recording", true,
    has(rec.alerts[1], "note did not appear") and has(rec.alerts[1], "Ctrl-S"))
  check("never focused: stop withheld logged", true, rec:hasLog("w", "talk: stop withheld"))
  check("never focused: server still recording, no URL", "true ", recording(sock) .. " " .. urls(sock))
  c.talkUp()
  check("never focused: a later up does nothing", 0, #execs(rec, "'release'"))
  stop(sock)
end

-- Note already focused: talk, no hide, no new target; then release.
do
  local t = setup()
  local rec, c, sock = t.rec, t.c, t.sock
  recordFlow(sock)
  c.toggle()
  rec:runTimers()
  ask(sock, 'nvim_buf_set_lines(0, 1, -1, v:false, ["hello world"])')
  local captures = #rec:findLogs("i", "show: target")
  c.talkDown()
  check("talkDown while focused: talk, logged -> more", "1 true",
    #execs(rec, "'talk'") .. " " .. tostring(rec:hasLog("i", "talk: down focused=true -> more")))
  check("talkDown while focused: no show, no host.hide, target not re-captured", "1 0 " .. captures,
    #execs(rec, "'show'") .. " " .. count(t.order, "host.hide") .. " " .. #rec:findLogs("i", "show: target"))
  check("talkDown while focused: mode i, recording", "i true", ask(sock, "mode()") .. " " .. recording(sock))
  c.talkDown()
  check("double down: one start task", 1, #startTasks(rec))
  check("double down: logged, no second talk", "true 1",
    tostring(rec:hasLog("i", "already down")) .. " " .. #execs(rec, "'talk'"))
  finishStart(rec)
  c.talkUp()
  check("focused talk: one release at key up, one stop", "1 1", #execs(rec, "'release'") .. " " .. stops(sock))
  check("focused talk: never hidden", 0, count(t.order, "host.hide"))
  paste(sock, " more")

  -- A quick second hold while the first release still waits for Flow's
  -- paste: down/up/down/up, then both pastes.
  c.talkDown(); finishStart(rec); c.talkUp()
  check("quick second hold: first release sent one stop", 2, stops(sock))
  c.talkDown()
  check("quick second hold: second down during the wait runs talk, recording", "3 true",
    #execs(rec, "'talk'") .. " " .. recording(sock))
  finishStart(rec)
  c.talkUp()
  check("quick second hold: its own key up sends exactly one more stop", 3, stops(sock))
  paste(sock, " one")
  check("quick second hold: still waiting after the first paste", "true", waiting(sock))
  paste(sock, " two")
  check("quick second hold: second paste ends the wait, Flow idle", "false false",
    waiting(sock) .. " " .. recording(sock))
  check("quick second hold: no further stop", 3, stops(sock))

  -- Same, but the first paste lands before the second key up.
  c.talkDown(); finishStart(rec); c.talkUp()
  c.talkDown(); finishStart(rec)
  paste(sock, " a")
  check("first paste before the second up: still recording", "true", recording(sock))
  c.talkUp()
  check("first paste before the second up: its key up stops once", 5, stops(sock))
  paste(sock, " b")
  check("then Flow idle", "false false", waiting(sock) .. " " .. recording(sock))
  check("the pastes landed in the note, in order", true, has(ask(sock, "getline(2)"), " more one two a b"))
  check("talk session: never hidden", 0, count(t.order, "host.hide"))
  stop(sock)
end

-- Focused, but the start task still running at talkStopTimeout: a stop now
-- could reach Flow before the late start, so none is sent; one alert.
do
  local t = setup({ talkStopTimeout = 0.3 })
  local rec, c, sock = t.rec, t.c, t.sock
  recordFlow(sock)
  c.talkDown()  -- host.show focuses the host
  c.talkUp()
  rec:runTimers()
  check("start task running at talkStopTimeout: no release, one alert", "0 1",
    #execs(rec, "'release'") .. " " .. #rec.alerts)
  check("start task running: withheld logged with the reason", true,
    rec:hasLog("w", "the Flow start task is still running"))
  check("start task running: the alert says Flow was slow to start", true,
    has(rec.alerts[1], "Flow was slow to start") and not has(rec.alerts[1], "did not appear"))
  check("start task running: server still recording, no URL (Ctrl-S stops Flow)", "true ",
    recording(sock) .. " " .. urls(sock))
  finishStart(rec)
  rec:runTimers()
  check("start task running: its late exit releases nothing", "0 1", #execs(rec, "'release'") .. " " .. #rec.alerts)
  stop(sock)
end

-- The note clicked into focus while show --talk still waits for the
-- pre-warm: no release until show --talk has told nvim, then one stop.
do
  local t = setup({ warm = false })
  local rec, c, sock = t.rec, t.c, t.sock
  c.talkDown()
  rec.frontmost, rec.focusedWindow = rec.apps["com.example.host"], t.hostWin
  finishStart(rec)
  c.talkUp()
  tick(rec); tick(rec)
  check("focused before show --talk ran: no release yet", "0 0",
    #execs(rec, "'release'") .. " " .. #execs(rec, "'show'"))
  ensure(sock)
  recordFlow(sock)
  rec:finishTask(1, 0, "", "")  -- the pre-warm: show --talk runs now
  check("after the pre-warm: show --talk ran, server recording", "1 true",
    #execs(rec, "'show' '--talk'") .. " " .. recording(sock))
  rec:runTimers()
  local rel = execs(rec, "'release'")
  check("then exactly one release, released, one stop, no alert", "1 released 1 0",
    #rel .. " " .. (rel[1] and rel[1].out:gsub("%s+$", "") or "") .. " " .. stops(sock) .. " " .. #rec.alerts)
  stop(sock)
end

-- Host focused but the server has no note and there is no target: nvim
-- never took the recording; release --force still sends the one stop.
do
  local t = setup()
  local rec, c, sock = t.rec, t.c, t.sock
  recordFlow(sock)
  rec.frontmost, rec.focusedWindow = rec.apps["com.example.host"], t.hostWin
  c.talkDown()
  check("no note, no target: talk printed no note, no show", "1 0",
    #execs(rec, "'talk'") .. " " .. #execs(rec, "'show'"))
  finishStart(rec)
  c.talkUp()
  local rel = execs(rec, "'release' '--force'")
  check("no note: one release --force, forced, one stop, no alert", "1 forced 1 0",
    #rel .. " " .. (rel[1] and rel[1].out:gsub("%s+$", "") or "") .. " " .. stops(sock) .. " " .. #rec.alerts)
  check("no note: logged that nvim had no recording", true, rec:hasLog("w", "nvim had no recording"))
  stop(sock)
end

-- Ctrl-S in the note stops Flow while the talk modifiers are still down:
-- key up still sends release --force (nvim's idle is not trusted), so Flow
-- gets one or two stops, never zero, and no alert.
do
  local t = setup()
  local rec, c, sock = t.rec, t.c, t.sock
  recordFlow(sock)
  c.talkDown()
  finishStart(rec)
  rec.modifiers = { ctrl = true, alt = true }
  c.talkUp()
  tick(rec)
  check("Ctrl-S during held modifiers: no release yet", 0, #execs(rec, "'release'"))
  luaRun(sock, "talks.lua", 'require("ferry.flow").toggle() return 1')  -- Ctrl-S
  check("Ctrl-S during held modifiers: one stop from Ctrl-S", 1, stops(sock))
  rec.modifiers = {}
  tick(rec)
  check("Ctrl-S then key up: one release --force, two stops (never zero), no alert", "1 1 2 0",
    #execs(rec, "'release'") .. " " .. #execs(rec, "'release' '--force'") .. " " .. stops(sock) .. " " .. #rec.alerts)
  check("Ctrl-S then key up: logged the stop sent anyway", true,
    rec:hasLog("i", "talk: nvim reported Flow idle (Ctrl-S?); sent the stop anyway"))
  stop(sock)
end

-- The reported sequence: nvim adopts the hold's recording, a stray paste
-- lands in the note with no wait running (a late paste from an earlier hold,
-- or a Cmd+V), then key up: nvim still says recording, and exactly one stop
-- reaches Flow, no alert.
do
  local t = setup()
  local rec, c, sock = t.rec, t.c, t.sock
  recordFlow(sock)
  c.talkDown()
  finishStart(rec)
  check("stray paste: nvim adopted the recording, no URL", "true ", recording(sock) .. " " .. urls(sock))
  paste(sock, "stray")
  check("stray paste: nvim still recording, flow-state recording", "true recording",
    recording(sock) .. " " .. luaRun(sock, "talkfs.lua", 'return require("ferry.note").flow_state()'))
  c.talkUp()
  tick(rec)
  check("stray paste then key up: one release --force, exactly one stop, no alert, released", "1 1 1 0 true",
    #execs(rec, "'release'") .. " " .. #execs(rec, "'release' '--force'") .. " " .. stops(sock) .. " "
      .. #rec.alerts .. " " .. waiting(sock))
  stop(sock)
end

-- The same sequence with an older flow in the server whose stray paste
-- clears the recording (nvim says idle): key up still sends one stop.
do
  local t = setup()
  local rec, c, sock = t.rec, t.c, t.sock
  recordFlow(sock)
  c.talkDown()
  finishStart(rec)
  luaRun(sock, "talkst.lua", 'require("ferry.flow").state.recording = false return 1')  -- old on_paste
  check("stray paste (old flow): flow-state idle", "idle",
    luaRun(sock, "talkfs.lua", 'return require("ferry.note").flow_state()'))
  c.talkUp()
  tick(rec)
  check("stray paste (old flow) then key up: one release --force, exactly one stop, no alert", "1 1 1 0",
    #execs(rec, "'release'") .. " " .. #execs(rec, "'release' '--force'") .. " " .. stops(sock) .. " " .. #rec.alerts)
  stop(sock)
end

-- A release that stops nothing (an older note module that ignores --force
-- prints idle): one alert.
do
  local t = setup()
  local rec, c, sock = t.rec, t.c, t.sock
  recordFlow(sock)
  c.toggle()
  rec:runTimers()
  luaRun(sock, "talkold.lua", 'require("ferry.note").release = function() return "idle" end return 1')
  c.talkDown(); finishStart(rec); c.talkUp()
  check("release prints idle: one release, no stop, one alert", "1 0 1",
    #execs(rec, "'release'") .. " " .. stops(sock) .. " " .. #rec.alerts)
  check("release prints idle: alert says Flow is still recording", true,
    has(rec.alerts[1], "still recording") and has(rec.alerts[1], "Ctrl-S"))
  stop(sock)
end

-- show --talk fails with the host not focused: one alert at key up (not
-- one from show and one from key up), no release.
do
  local t = setup()
  local rec, c, sock = t.rec, t.c, t.sock
  recordFlow(sock)
  luaRun(sock, "talkboom.lua", 'require("ferry.note").show = function() error("boom") end return 1')
  c.talkDown()
  check("show failed: no alert at key down", 0, #rec.alerts)
  finishStart(rec)
  c.talkUp()
  check("show failed: one alert at key up, no release, withheld logged", "1 0 true",
    #rec.alerts .. " " .. #execs(rec, "'release'") .. " " .. tostring(rec:hasLog("w", "the note did not open")))
  rec:runTimers()
  check("show failed: still one alert", 1, #rec.alerts)
  stop(sock)
end

-- Ctrl-X in the note while key up still waits (start task running): the
-- Submit takes over Flow's wait and the note hides; key up stops polling
-- with no release and no alert.
do
  local t = setup()
  local rec, c, sock = t.rec, t.c, t.sock
  recordFlow(sock)
  c.toggle()
  rec:runTimers()
  c.talkDown()
  c.talkUp()
  tick(rec)
  check("Ctrl-X during key up: no release while the start task runs", 0, #execs(rec, "'release'"))
  luaRun(sock, "talkx.lua", 'require("ferry.flow").finish_then(0, function() end) return 1')
  rec.focusedWindow = nil  -- the Submit hid the note
  tick(rec)
  check("Ctrl-X during key up: polling stopped, logged, no release, no alert", "true true nil 0 0",
    tostring(rec:hasLog("i", "talk: no release needed: nvim already stopped Flow (waiting)")) .. " "
      .. tostring(c._talk == nil) .. " " .. tostring(c._talkTimer) .. " "
      .. #execs(rec, "'release'") .. " " .. #rec.alerts)
  finishStart(rec)
  rec:runTimers()
  check("Ctrl-X during key up: only the Submit's stop, still no alert", "1 0", stops(sock) .. " " .. #rec.alerts)
  stop(sock)
end

-- P5: a Submit/Cancel/Hide whose wait finishes while the talk key is still
-- held. At key up nvim is no longer recording or waiting; flow-state says
-- `stopped` (our stop ended the adopted recording and its paste landed), so
-- key up ends quietly: no "still recording" alert.
local function noteHost(sock)
  luaRun(sock, "talkhost.lua", [[
    require("ferry.note").host = {
      hide = function() vim.g.ferry_hidden = (vim.g.ferry_hidden or 0) + 1 end,
      submit = function() vim.g.ferry_submitted = (vim.g.ferry_submitted or 0) + 1 end,
    }
    return 1
  ]])
end
local function waitFor(sock, expr)
  for _ = 1, 100 do
    if ask(sock, expr) ~= "0" then return end
    sh("sleep 0.02")
  end
end
local function flowState(sock)
  return luaRun(sock, "talkfs.lua", 'return require("ferry.note").flow_state()')
end

-- Ctrl-X while held: one submit, the note hides, then key up: no alert.
do
  local t = setup()
  local rec, c, sock = t.rec, t.c, t.sock
  recordFlow(sock)
  noteHost(sock)
  c.talkDown()
  finishStart(rec)
  ask(sock, 'luaeval("require(\\"ferry.note\\").submit()")')  -- Ctrl-X, talk key held
  paste(sock, "held words")
  waitFor(sock, 'get(g:, "ferry_submitted", 0)')
  rec.focusedWindow = nil  -- Hammerspoon hid the note to deliver
  check("Ctrl-X while held: one submit, one stop, flow-state stopped", "1 1 stopped",
    ask(sock, 'get(g:, "ferry_submitted", 0)') .. " " .. stops(sock) .. " " .. flowState(sock))
  c.talkUp()
  rec:runTimers()
  check("Ctrl-X while held: key up ends quietly, one submit, no release, no alert", "1 0 0 true",
    ask(sock, 'get(g:, "ferry_submitted", 0)') .. " " .. #execs(rec, "'release'") .. " " .. #rec.alerts .. " "
      .. tostring(rec:hasLog("i", "talk: no release needed: nvim already stopped Flow (stopped)")))
  check("Ctrl-X while held: still one stop", 1, stops(sock))
  stop(sock)
end

-- Ctrl+Option+V tap while held: draft waits for Flow, the note hides after
-- the paste, then key up: no alert.
do
  local t = setup()
  local rec, c, sock = t.rec, t.c, t.sock
  c.bindURLs()
  recordFlow(sock)
  noteHost(sock)
  c.talkDown()
  finishStart(rec)
  c.toggle()  -- the main hotkey, talk key held
  check("hotkey tap while held: draft waits for flow, not hidden yet", "0 0",
    count(t.order, "host.hide") .. " " .. ask(sock, 'get(g:, "ferry_hidden", 0)'))
  paste(sock, "held words")
  waitFor(sock, 'get(g:, "ferry_hidden", 0)')
  check("hotkey tap while held: the note asks to hide after the paste", "1", ask(sock, 'get(g:, "ferry_hidden", 0)'))
  rec:openURL("ferry-hide", {})  -- what the note's hide URL does
  check("hotkey tap while held: hidden, flow-state stopped", "1 stopped",
    count(t.order, "host.hide") .. " " .. flowState(sock))
  c.talkUp()
  rec:runTimers()
  check("hotkey tap while held: key up ends quietly, no release, no alert, one stop", "0 0 1",
    #execs(rec, "'release'") .. " " .. #rec.alerts .. " " .. stops(sock))
  stop(sock)
end

-- A stray paste never reads as stopped: the note hidden by hand after a
-- stray paste, key up still alerts once (a stop now would paste elsewhere).
do
  local t = setup({ talkStopTimeout = 0.3 })
  local rec, c, sock = t.rec, t.c, t.sock
  recordFlow(sock)
  c.talkDown()
  finishStart(rec)
  paste(sock, "stray")
  check("stray paste: flow-state recording, not stopped", "recording", flowState(sock))
  rec.focusedWindow = nil  -- the note went away without a stop
  c.talkUp()
  rec:runTimers()
  check("stray paste, note gone: no release, no stop, exactly one alert", "0 0 1",
    #execs(rec, "'release'") .. " " .. stops(sock) .. " " .. #rec.alerts)
  stop(sock)
end

-- Up without down, and a disabled controller: nothing.
do
  local t = setup()
  local rec, c, sock = t.rec, t.c, t.sock
  c.talkUp()
  check("up without down: no release, logged", "0 true",
    #execs(rec, "'release'") .. " " .. tostring(rec:hasLog("i", "talk: up ignored")))
  c.disable()
  c.talkDown()
  c.talkUp()
  check("disabled: talkDown starts no Flow task and runs nothing", "0 0",
    #startTasks(rec) .. " " .. #execs(rec, "'show'"))
  stop(sock)
end

os.exit(fail)
LUA

FERRY_ROOT="$root" FERRY_WORK="$work" perl -e 'alarm 60; exec @ARGV' nvim -l "$work/spec.lua" 2>&1
status=$?
echo  # nvim -l leaves the last line unterminated

check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want '$2' got '$3'"; status=1; fi; }
check "fake osascript/open/neovide never called" 0 "$(grep -c '^CALL ' "$work/calls")"
check "ferry.lua loads instance.lua" 1 "$(grep -c 'dofile(root .. "/hammerspoon/instance.lua")' "$root/hammerspoon/ferry.lua")"
lj=$(command -v luajit || echo /opt/homebrew/bin/luajit)
if [ -x "$lj" ]; then
  check "instance.lua parses under LuaJIT" ok "$("$lj" -e "assert(loadfile('$root/hammerspoon/instance.lua')) print('ok')" 2>&1)"
fi
if l=$(command -v lua5.4 || command -v lua); then
  check "instance.lua parses under $(basename "$l")" ok "$("$l" -e "assert(loadfile('$root/hammerspoon/instance.lua')) print('ok')" 2>&1)"
fi

if [ $status -eq 0 ]; then echo "all ok"; else echo "FAILED"; fi
exit $status
