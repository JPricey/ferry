-- instance.lua: Hammerspoon controller for the one long-lived ferry.
--
-- Loaded by hammerspoon/ferry.lua with the Neovide host
-- (hammerspoon/hosts/neovide.lua). The window that shows nvim is an
-- injected host, and the server and note are driven by bin/ferry-host.
--
--   local instance = dofile(root .. "/hammerspoon/instance.lua")
--   local c = instance.new({ host = host, deliver = M.submit, root = root })
--   c.prewarm()   -- start the nvim server off the main thread
--   c.bindURLs()  -- hammerspoon://ferry-submit and ferry-hide
--   hs.hotkey.bind({ "ctrl", "alt" }, "v", c.toggle)
--
-- Host interface (B1 implements it for the picked host). Every function must
-- return quickly; slow work (osascript, launching an app) goes in hs.task.
--   show(cb)            bring the host window forward with keyboard focus;
--                       cb(ok, why) once it has been asked to (not confirmed)
--   hide(cb)            hide or park the host window; cb(ok, why) when done.
--                       The controller refocuses the target in cb.
--   isFocused()         -> bool, why: the host window has keyboard focus.
--                       why is a short string for the log.
--   launch(cb)          start the host UI attached to the server
--                       (`ferry-host attach-cmd`); cb(ok, why) once it
--                       has been asked to. Called by show when `status`
--                       reports no UI attached; the controller then calls
--                       show once while polling, after cb.
--
-- toggle() (the hotkey):
--   host focused -> `ferry-host draft`, host.hide, refocus the captured
--                   window object (its app when the window is gone).
--                   While Wispr Flow is recording (started from the note),
--                   draft answers `waiting for flow …` and the controller
--                   leaves the host up: the note stops Flow, waits for its
--                   paste, then hides itself via ferry-hide (onHide), so
--                   dictation never lands in the target.
--   otherwise    -> capture the frontmost app + window (and, with
--                   captureSelection, the selection as a seed file),
--                   `ferry-host show <bundle> <window> [seedfile]`,
--                   `ferry-host status`, host.show (host.launch first
--                   when status says uis=0)
-- Each direction polls every pollInterval and logs to logger `ferry`,
-- timed from the key press (so the show/draft call is included):
--   show: show took N ms              hide: draft took N ms
--   show: host focused after N ms     hide: target focused after N ms
-- Each press also logs `toggle: focused=<bool> (<why>) -> show|hide`.
--
-- showEdit() (hammerspoon://ferry-edit, after bin/ferry-edit opened its file
--   in the server): the show path without `ferry-host show`, so the note is
--   untouched. Host focused: the old target is kept. Logs `edit: ...`.
--
-- onSubmit(p) (hammerspoon://ferry-submit?file=&target=&window=):
--   host.hide, then deliver(p). deliver is injected (B2: ferry.lua's
--   M.submit, which focuses p's target and pastes).
-- onHide() (hammerspoon://ferry-hide, from :Hide / :Cancel in the note,
--   which already wrote the draft): host.hide, refocus the target.
--
-- Blocking: show, status and draft run on the main thread (hs.execute).
-- Each is a couple of --remote-expr round trips while the server is up, and
-- fails at once while it is down. ensure (a cold nvim start can take
-- seconds) only runs as an hs.task, from prewarm(); a press during the
-- pre-warm waits for it instead of starting a second server.
--
-- Recovery: when show fails because the server is down, the controller
-- runs the same async ensure and retries show once (logs `show: server
-- down`). When `status` reports `uis=0`, it calls host.launch before
-- polling (logs `show: no UI attached`), at most once per launchGrace.
-- When host.show reports false or the host is not focused within
-- pollTimeout, the press shows one alert ("<hostName> did not appear") and
-- the next press launches the host again instead of waiting out
-- launchGrace.
--
-- Hold to talk (the talk hotkey: pressed talkDown, released talkUp):
--   talkDown()  start Flow at once (cfg.startFlow; default `/usr/bin/open -g
--               wispr-flow://start-hands-free` as an hs.task), before
--               anything waits on nvim, so the first word is not clipped.
--               Host not focused: the show path above with
--               `ferry-host show --talk ...` (captures the target, waits
--               for the pre-warm, launches the host). Host focused:
--               `ferry-host talk` (insert at the cursor; never hides,
--               never re-captures the target). A second down before up is
--               ignored. A down while the last key up still waits to
--               release takes that release over (one recording, released at
--               this hold's key up).
--   talkUp()    polls every pollInterval until the start task has exited,
--               the host is focused, the show path has finished (nvim took
--               the recording, or it failed) and no modifier is down (Flow
--               pastes with Cmd+V; a held Ctrl+Option would make it
--               Ctrl+Option+Cmd+V), then always runs `ferry-host
--               release --force` once: nvim stops Flow and waits for its
--               paste (flow.release), and sends the stop even when it
--               reports idle (Ctrl-S already stopped Flow, a stray paste,
--               or nvim never took the recording), since a stop to an idle
--               Flow is harmless and a missed one leaves Flow recording.
--               Modifiers still down talkModsTimeout after the host was
--               ready: release anyway. Not released talkStopTimeout after
--               key up (start task still running, host not focused, or the
--               show never finished): no release (a stop could beat the
--               start to Flow, or Flow's paste would land in whatever is in
--               front), one alert worded by cause (Flow slow to start, note
--               did not appear, note not ready); Flow records on until
--               stopped. The one quiet end: nvim took this hold's recording
--               and `flow-state` says `waiting` or `stopped` (asked when the
--               note loses focus and at the timeout): a Submit, Cancel or
--               Hide wait took over and sent the stop (`stopped`: and its
--               paste has landed, e.g. Ctrl-X while the key is still held),
--               so no release and no alert. An idle answer is not trusted. A show that failed and the host
--               not focused: alert at once. A release that fails or prints
--               anything else: alert. So every hold ends in one stop (two
--               after a Ctrl-S while held) or one alert. A talk press's
--               failed show does not alert itself; this one does.
--   Logs: `talk: down focused=<b> -> show|more`, `talk: flow start task
--   started after N ms`, `talk: flow start exited after N ms`, `talk: up
--   after N ms held`, `talk: release after N ms (waited focus N ms, mods
--   N ms)`, `talk: stop withheld ...`.
--
-- disable(): stop for good (a new start() replaced it, or its setup failed):
-- drops a show waiting for the pre-warm, stops the poll, unbinds the URL
-- handlers bindURLs() made, and makes toggle/show/hide/talkDown/talkUp
-- no-ops.
--
-- captureSelection (default off): Cmd+C and a wait of up to 0.4 s for the
-- clipboard before every show, which breaks the ~150 ms show target.
--
-- Valid for Lua 5.4 and LuaJIT.

local I = {}

local function q(s)
  return "'" .. (tostring(s):gsub("'", "'\\''")) .. "'"
end

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function ms(x) return math.floor(x + 0.5) end

local function nowMs()
  if hs.timer and hs.timer.absoluteTime then
    return hs.timer.absoluteTime() / 1e6
  end
  return os.clock() * 1000
end

-- Repo root from this file's path (hammerspoon/instance.lua).
local function defaultRoot()
  local info = debug.getinfo(1, "S")
  local src = info and info.source or ""
  local path = src:match("^@(.*)$")
  if not path then return nil end
  return path:match("^(.*)/hammerspoon/[^/]+$") or path:match("^(.*)/[^/]+$")
end

-- cfg:
--   host              table with show, hide, isFocused, launch (required)
--   deliver           function(p) for submits (required)
--   captureSelection  grab the selection as a seed before show (default false)
--   root              repo root (default: derived from this file's path)
--   sock              FERRY_SOCK for ferry-host (default: its own)
--   notesDir          FERRY_NOTES_DIR (default: ferry-host's own)
--   nvimFlags         FERRY_HOST_NVIM_FLAGS (tests: "--clean")
--   pollInterval      seconds between focus checks (default 0.01)
--   pollTimeout       seconds before a focus poll gives up (default 5)
--   selectionTimeout  seconds to wait for Cmd+C to land (default 0.4)
--   launchGrace       seconds after a host.launch during which uis=0 is
--                     taken as the UI still starting (default 5)
--   hostName          name of the host window in alerts, or a function
--                     returning it (asked per alert; default
--                     "the ferry window")
--   startFlow         function(onExit) that starts Wispr Flow recording and
--                     returns true once started; onExit(code) when done
--                     (default: `/usr/bin/open -g wispr-flow://start-hands-free`
--                     as an hs.task)
--   talkModsTimeout   seconds talkUp waits for modifiers to come up once the
--                     host is focused (default 1)
--   talkStopTimeout   seconds after key up before talkUp gives up on the host
--                     getting focus (default 5)
function I.new(cfg)
  cfg = cfg or {}
  local c = {
    config = {
      captureSelection = cfg.captureSelection == true,
      root = cfg.root or defaultRoot() or ".",
      sock = cfg.sock,
      notesDir = cfg.notesDir,
      nvimFlags = cfg.nvimFlags,
      pollInterval = cfg.pollInterval or 0.01,
      pollTimeout = cfg.pollTimeout or 5,
      selectionTimeout = cfg.selectionTimeout or 0.4,
      launchGrace = cfg.launchGrace or 5,
      hostName = cfg.hostName or "the ferry window",
      startFlow = cfg.startFlow,
      talkModsTimeout = cfg.talkModsTimeout or 1,
      talkStopTimeout = cfg.talkStopTimeout or 5,
    },
    host = cfg.host,
    deliver = cfg.deliver,
    shown = false,     -- we showed the host and have not hidden it since
    target = nil,      -- { app, bundle, win, winId } captured on show
    _timer = nil,      -- current poll timer (kept so it is not collected)
    _tasks = {},       -- running hs.task objects (kept so they are not collected)
    _warming = false,  -- a pre-warm `ferry-host ensure` is running
    _afterWarm = nil,  -- show continuation waiting for the pre-warm
    _launchedAt = nil, -- nowMs() of the last host.launch (nil: none pending)
    _disabled = false, -- disable() was called
    _boundURLs = false, -- bindURLs() bound ferry-submit / ferry-hide
    _talk = nil,       -- the talk hold: { t0, up, upAt, startExited, press }
    _talkTimer = nil,  -- talkUp's poll timer
  }
  local log = hs.logger.new("ferry", "info")
  c.log = log

  local function try(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, a, b = pcall(fn, ...)
    if not ok then
      log.w("instance: " .. tostring(a))
      return nil
    end
    return a, b
  end

  local function alert(msg)
    if hs.alert and hs.alert.show then try(hs.alert.show, msg) end
  end

  -- The host window's name for an alert, asked each time (a function
  -- config follows ferry.app being built or removed while running).
  local function hostName()
    local n = c.config.hostName
    if type(n) == "function" then n = try(n) end
    if type(n) ~= "string" or n == "" then return "the ferry window" end
    return n
  end

  local h = c.host
  if type(h) ~= "table" then
    log.e("instance: no host given")
    h = {}
    c.host = h
  end
  for _, k in ipairs({ "show", "hide", "isFocused", "launch" }) do
    if type(h[k]) ~= "function" then log.e("instance: host lacks " .. k .. "()") end
  end
  if type(c.deliver) ~= "function" then log.e("instance: no deliver function given") end

  -- -------------------------------------------------------------------------
  -- ferry-host calls

  local function envPrefix()
    local parts = {}
    local function add(k, v) if v ~= nil and v ~= "" then parts[#parts + 1] = k .. "=" .. q(v) end end
    add("FERRY_SOCK", c.config.sock)
    add("FERRY_NOTES_DIR", c.config.notesDir)
    add("FERRY_HOST_NVIM_FLAGS", c.config.nvimFlags)
    if #parts == 0 then return "" end
    return table.concat(parts, " ") .. " "
  end

  local function command(args)
    local quoted = {}
    for i, a in ipairs(args) do quoted[i] = q(a) end
    return envPrefix() .. q(c.config.root .. "/bin/ferry-host") .. " " .. table.concat(quoted, " ")
  end

  -- Synchronous call (show, draft). Logs `<label>: <sub> took N ms`.
  local function runSync(label, args)
    local cmd = command(args) .. " 2>&1"
    local t0 = nowMs()
    local out, ok = try(hs.execute, cmd)
    out = trim(out)
    local took = ms(nowMs() - t0)
    if ok then
      log.i(string.format("%s: %s took %d ms (%s)", label, args[1], took, out))
    else
      log.e(string.format("%s: %s failed after %d ms: %s", label, args[1], took, out))
    end
    return ok and true or false, out
  end

  -- Slow call (ensure) off the main thread; cb(ok, output) when done.
  local function runAsync(args, cb)
    local cmd = command(args)
    local t0 = nowMs()
    local task
    local function done(ok, text)
      if cb then try(cb, ok, text) end
    end
    task = try(hs.task.new, "/bin/sh", function(code, out, err)
      for i, t in ipairs(c._tasks) do
        if t == task then table.remove(c._tasks, i); break end
      end
      local ok = code == 0
      local text = trim((out or "") .. (err or ""))
      if ok then
        log.i(string.format("ferry-host %s: done after %d ms %s", args[1], ms(nowMs() - t0), text))
      else
        log.e(string.format("ferry-host %s: exit %s: %s", args[1], tostring(code), text))
      end
      done(ok, text)
    end, { "-c", cmd })
    if not task then
      log.e("ferry-host " .. args[1] .. ": could not create hs.task")
      return done(false, "")
    end
    c._tasks[#c._tasks + 1] = task
    if not try(task.start, task) then
      log.e("ferry-host " .. args[1] .. ": hs.task did not start")
      for i, t in ipairs(c._tasks) do
        if t == task then table.remove(c._tasks, i); break end
      end
      done(false, "")
    end
  end

  -- -------------------------------------------------------------------------
  -- Focus helpers

  local function frontApp() return try(hs.application.frontmostApplication) end
  local function bundleOf(app) return app and try(app.bundleID, app) or nil end
  local function focusedWin() return try(hs.window.focusedWindow) end
  local function winId(w) return w and try(w.id, w) or nil end

  local function describeFocus()
    return string.format("front=%s win=%s", tostring(bundleOf(frontApp())), tostring(winId(focusedWin())))
  end

  local function stopPoll()
    if c._timer then try(c._timer.stop, c._timer) end
    c._timer = nil
  end

  -- Poll every pollInterval until check() is true or pollTimeout passes.
  -- t0 is the key press (nowMs), so the logged ms covers the whole press.
  -- onMiss (optional) runs after each check that fails; onTimeout
  -- (optional) once when pollTimeout passes.
  local function poll(label, what, t0, check, onMiss, onTimeout)
    stopPoll()
    local function step()
      c._timer = nil
      local elapsed = nowMs() - t0
      if try(check) then
        log.i(string.format("%s: %s focused after %d ms", label, what, ms(elapsed)))
        return
      end
      if onMiss then try(onMiss) end
      if elapsed >= c.config.pollTimeout * 1000 then
        log.w(string.format("%s: %s not focused after %d ms (%s)", label, what, ms(elapsed), describeFocus()))
        if onTimeout then try(onTimeout) end
        return
      end
      c._timer = try(hs.timer.doAfter, c.config.pollInterval, step)
    end
    step()
  end

  local function hostFocused()
    local yes = try(h.isFocused)
    return yes == true
  end

  -- -------------------------------------------------------------------------
  -- Target

  local function captureTarget()
    local app = frontApp()
    local w = focusedWin()
    c.target = { app = app, bundle = bundleOf(app), win = w, winId = winId(w) }
    log.i(string.format("show: target %s window %s", tostring(c.target.bundle), tostring(c.target.winId)))
  end

  local function targetFocused()
    local t = c.target
    if not t then return true end
    if t.winId then return winId(focusedWin()) == t.winId end
    return t.bundle ~= nil and bundleOf(frontApp()) == t.bundle
  end

  -- Use the window object captured on show (no hs.window.get scan); a
  -- closed window answers id() with nil.
  local function refocusTarget()
    local t = c.target
    if not t then log.w("hide: no captured target"); return end
    local w = t.win
    if w and winId(w) ~= nil then
      try(w.focus, w)
      return
    end
    local app = t.app
    if not app and t.bundle then app = try(hs.application.get, t.bundle) end
    if app then
      log.i("hide: window gone, activating " .. tostring(t.bundle))
      try(app.activate, app)
    else
      log.w("hide: target app gone: " .. tostring(t.bundle))
    end
  end

  -- -------------------------------------------------------------------------
  -- Selection (captureSelection only). Blocks up to selectionTimeout.

  -- Cmd+C into the target app; returns the selection ("" if nothing landed)
  -- and puts the clipboard back.
  local function grabSelection(app)
    local pb = hs.pasteboard
    if not (pb and hs.eventtap and app) then return "" end
    local saved = try(pb.getContents)
    local before = try(pb.changeCount)
    try(hs.eventtap.keyStroke, { "cmd" }, "c", 0, app)
    local deadline = hs.timer.secondsSinceEpoch() + c.config.selectionTimeout
    while try(pb.changeCount) == before and hs.timer.secondsSinceEpoch() < deadline do
      hs.timer.usleep(20000)
    end
    local sel = ""
    if try(pb.changeCount) ~= before then
      sel = try(pb.getContents) or ""
      if saved then try(pb.setContents, saved) else try(pb.clearContents) end
    end
    return sel
  end

  -- Seed file holding the selection, or nil when there is none.
  local function seedFile()
    if not (c.config.captureSelection and c.target) then return nil end
    local sel = grabSelection(c.target.app)
    log.i("show: selection " .. #sel .. " bytes")
    if not sel:find("%S") then return nil end
    local path = os.tmpname()
    local f = io.open(path, "w")
    if not f then log.w("show: cannot write seed file " .. path); return nil end
    f:write(sel)
    f:close()
    return path
  end

  -- -------------------------------------------------------------------------
  -- Show / hide

  -- A show that failed (host.show reported false, or the host never got
  -- focus): one alert per press, and the next press launches the host
  -- again instead of waiting out launchGrace.
  local function showFailed(press, why)
    c._launchedAt = nil
    if press.alerted then return end
    press.alerted = true
    if press.talk then
      log.w("show: failed (" .. tostring(why) .. "); the talk key-up check alerts, the next press relaunches")
      return
    end
    log.w("show: failed (" .. tostring(why) .. "); alerting, the next press relaunches")
    alert("ferry: " .. hostName() .. " did not appear — check the Hammerspoon console")
  end

  local function hostShow(press)
    try(h.show, function(okShow, why)
      if okShow == false then
        log.w("show: host.show failed: " .. tostring(why))
        showFailed(press, "host.show: " .. tostring(why))
      end
    end)
  end

  -- Poll until the host has focus; alert once if it never does.
  local function pollShow(press, onMiss)
    poll("show", "host", press.t0, hostFocused, onMiss, function()
      showFailed(press, "host not focused after " .. c.config.pollTimeout .. " s")
    end)
  end

  -- Number of UIs attached to the server, from `ferry-host status`
  -- (nil when it does not answer `up uis=N`), and its output.
  local function attachedUIs()
    local _, out = runSync("show", { "status" })
    return tonumber(out:match("up uis=(%d+)")), out
  end

  -- No UI attached: launch the host, then call host.show once while
  -- polling, after launch has reported back. Within launchGrace of the
  -- last launch the UI is taken as still starting, so a quick second press
  -- never opens a second window.
  local function launchAndPoll(press)
    local since = c._launchedAt and (nowMs() - c._launchedAt) or nil
    if since and since < c.config.launchGrace * 1000 then
      log.i(string.format("show: no UI attached yet, launched %d ms ago; showing", ms(since)))
      hostShow(press)
      pollShow(press)
      return
    end
    log.i("show: no UI attached (uis=0), host.launch")
    c._launchedAt = nowMs()
    local launched, showed = false, false
    if type(h.launch) == "function" then
      local ok, err = pcall(h.launch, function(okLaunch, why)
        launched = true
        if okLaunch == false then
          log.w("show: host.launch failed: " .. tostring(why))
          c._launchedAt = nil
        end
      end)
      if not ok then
        log.w("show: host.launch error: " .. tostring(err))
        c._launchedAt, launched = nil, true
      end
    else
      launched = true
    end
    pollShow(press, function()
      if launched and not showed then
        showed = true
        hostShow(press)
      end
    end)
  end

  -- The server holds what to show (the note, or an edit): launch the host
  -- when no UI is attached (uis 0), else show it; then poll for focus.
  local function showHost(press, uis)
    c.shown = true
    if uis == 0 then
      launchAndPoll(press)
      return
    end
    if uis then c._launchedAt = nil else log.w("show: status did not report uis") end
    hostShow(press)
    pollShow(press)
  end

  -- press: { t0 = key press, alerted }. again: { seed = path } on the one
  -- retry after the server was down.
  local function showRest(press, again)
    if c._disabled then return end
    local args = { "show" }
    if press.talk then args[#args + 1] = "--talk" end
    args[#args + 1] = c.target.bundle or ""
    args[#args + 1] = c.target.winId and tostring(c.target.winId) or ""
    local seed
    if again then seed = again.seed else seed = seedFile() end
    if seed then args[#args + 1] = seed end
    local ok, out = runSync("show", args)
    if not ok and not again and out:find("no server on", 1, true) then
      log.w("show: server down; ferry-host ensure, then retry show once")
      c._afterWarm = function() showRest(press, { seed = seed }) end
      c.prewarm()
      return
    end
    if seed then os.remove(seed) end
    if not ok then
      if press.talk then
        -- The talk key up stops Flow or alerts, once (see talkUp).
        press.failed = "show failed"
        log.w("show: could not open the note; the talk key up decides")
        return
      end
      alert("ferry: could not open the note (see console)")
      return
    end
    if press.talk then press.adopted = true end  -- nvim knows Flow is recording
    showHost(press, (attachedUIs()))
  end

  -- Show the host with the note. t0: the key press (default now). opts.talk:
  -- hold to talk (`show --talk`). Returns the press.
  function c.show(t0, opts)
    if c._disabled then return end
    local press = { t0 = t0 or nowMs(), alerted = false, talk = opts ~= nil and opts.talk == true }
    stopPoll()
    captureTarget()
    if c._warming then
      -- A synchronous show now would find no server; wait for the ensure.
      log.i("show: waiting for the pre-warm ensure to finish")
      c._afterWarm = function() showRest(press) end
      return press
    end
    showRest(press)
    return press
  end

  -- hammerspoon://ferry-edit: bin/ferry-edit has already opened its file in
  -- the server, so show the host as c.show does (target, pre-warm wait,
  -- launch, host.show, poll) but never run `ferry-host show`: the note is
  -- left alone. With the host already focused the old target is kept (the
  -- edit hides back to it). A server that is down has no edit to show:
  -- nothing is shown and ferry-edit falls back to the terminal.
  function c.showEdit(t0)
    if c._disabled then log.w("edit: ignored, the controller is disabled"); return end
    local press = { t0 = t0 or nowMs(), alerted = false }
    stopPoll()
    local focused, why = try(h.isFocused)
    focused = focused == true
    log.i(string.format("edit: show requested; focused=%s (%s) shown=%s %s", tostring(focused),
      tostring(why), tostring(c.shown), describeFocus()))
    if focused then
      local t = c.target
      log.i(string.format("edit: host already focused; keeping target %s window %s",
        tostring(t and t.bundle), tostring(t and t.winId)))
    else
      captureTarget()
    end
    local function rest()
      if c._disabled then return end
      local uis, out = attachedUIs()
      if out == "down" then
        log.w("edit: server down, nothing to show; ferry-edit falls back to the terminal")
        return
      end
      log.i("edit: showing the host (no ferry-host show)")
      showHost(press, uis)
    end
    if c._warming then
      log.i("edit: waiting for the pre-warm ensure to finish")
      c._afterWarm = rest
      return press
    end
    rest()
    return press
  end

  -- Hide the host, then run after() (once) when host.hide reports back.
  local function hideHost(after)
    stopPoll()
    c.shown = false
    local called = false
    local function cb(okHide, why)
      if called then return end
      called = true
      if okHide == false then log.w("hide: host.hide failed: " .. tostring(why)) end
      if after then try(after) end
    end
    if type(h.hide) == "function" then
      local ok, err = pcall(h.hide, cb)
      if not ok then
        log.w("hide: host.hide error: " .. tostring(err))
        cb(false, err)
      end
    else
      cb(false, "host has no hide")
    end
  end

  -- From focused: keep the note as the draft, hide, refocus the target.
  function c.hide(t0)
    if c._disabled then return end
    t0 = t0 or nowMs()
    local ok, out = runSync("hide", { "draft" })
    if ok and out:find("waiting for flow", 1, true) then
      log.i("hide: Flow is recording; the note hides itself after Flow's paste")
      return
    end
    hideHost(refocusTarget)
    poll("hide", "target", t0, targetFocused)
  end

  function c.toggle()
    if c._disabled then log.w("toggle: instance controller is disabled"); return end
    local t0 = nowMs()  -- the press: every ms line is measured from here
    local focused, why = try(h.isFocused)
    focused = focused == true
    log.i(string.format("toggle: focused=%s (%s) -> %s; shown=%s %s", tostring(focused),
      tostring(why), focused and "hide" or "show", tostring(c.shown), describeFocus()))
    if focused then c.hide(t0) else c.show(t0) end
  end

  -- -------------------------------------------------------------------------
  -- Hold to talk (see the header)

  local FLOW_START = "wispr-flow://start-hands-free"

  local function forgetTask(task)
    for i, t in ipairs(c._tasks) do
      if t == task then table.remove(c._tasks, i); break end
    end
  end

  -- Default startFlow: `open -g` the start link as an hs.task.
  local function openStartTask(onExit)
    local task
    task = try(hs.task.new, "/usr/bin/open", function(code)
      forgetTask(task)
      onExit(code)
    end, { "-g", FLOW_START })
    if not task then return false end
    c._tasks[#c._tasks + 1] = task
    if not try(task.start, task) then
      forgetTask(task)
      return false
    end
    return true
  end

  local function startFlow(talk)
    local function onExit(code)
      if talk.startExited then return end
      talk.startExited = true
      local m = string.format("talk: flow start exited after %d ms (exit %s)", ms(nowMs() - talk.t0), tostring(code))
      if code == nil or code == 0 then log.i(m) else log.w(m) end
    end
    local ok = try(c.config.startFlow or openStartTask, onExit)
    if ok then
      log.i(string.format("talk: flow start task started after %d ms", ms(nowMs() - talk.t0)))
    else
      log.e("talk: could not start Flow (" .. FLOW_START .. "); the note still opens")
      talk.startExited = true
    end
  end

  local function stopTalkPoll()
    if c._talkTimer then try(c._talkTimer.stop, c._talkTimer) end
    c._talkTimer = nil
  end

  -- Modifiers held down now (only those that change Flow's Cmd+V).
  local function modsDown()
    local m = hs.eventtap and hs.eventtap.checkKeyboardModifiers and try(hs.eventtap.checkKeyboardModifiers)
    local down = {}
    if type(m) ~= "table" then return down end
    for _, k in ipairs({ "cmd", "alt", "ctrl", "shift" }) do
      if m[k] then down[#down + 1] = k end
    end
    return down
  end

  function c.talkDown()
    if c._disabled then log.w("talk: down ignored, the controller is disabled"); return end
    local prev = c._talk
    if prev and not prev.up then log.i("talk: down ignored, the talk key is already down"); return end
    if prev then
      log.i("talk: down while the last key up still waits to release; this hold releases")
      stopTalkPoll()
    end
    local talk = { t0 = nowMs(), up = false, startExited = false }
    c._talk = talk
    startFlow(talk)  -- first: nothing below may delay Flow
    local focused, why = try(h.isFocused)
    focused = focused == true
    log.i(string.format("talk: down focused=%s -> %s (%s); shown=%s %s", tostring(focused),
      focused and "more" or "show", tostring(why), tostring(c.shown), describeFocus()))
    if not focused then
      talk.press = c.show(talk.t0, { talk = true })
      return
    end
    local ok, out = runSync("talk", { "talk" })
    if ok and out:find("^talk ") then
      talk.press = { t0 = talk.t0, alerted = false, talk = true, adopted = true }
    elseif ok and out:find("no note", 1, true) and c.target then
      log.w("talk: the server has no note; show --talk with the last target")
      talk.press = { t0 = talk.t0, alerted = false, talk = true }
      showRest(talk.press)
    else
      -- Nothing told nvim about the recording; key up still stops Flow
      -- through nvim while the host is focused (release --force), or alerts.
      talk.press = { t0 = talk.t0, alerted = false, talk = true, failed = ok and out or "talk failed" }
      log.w("talk: nvim did not take the recording (" .. talk.press.failed .. "); the talk key up decides")
    end
  end

  function c.talkUp()
    if c._disabled then log.w("talk: up ignored, the controller is disabled"); return end
    local talk = c._talk
    if not talk or talk.up then log.i("talk: up ignored, the talk key was not down"); return end
    talk.up, talk.upAt = true, nowMs()
    log.i(string.format("talk: up after %d ms held", ms(talk.upAt - talk.t0)))
    local focusAt, readyAt, lossChecked

    -- Every hold ends in exactly one of: release (one stop through nvim),
    -- withhold (no stop, one alert), or done (a Submit/Cancel/Hide wait in
    -- nvim already stopped Flow).
    -- msg: the alert, worded by cause (default: the note did not appear).
    local function withhold(now, why, msg)
      c._talk = nil
      log.w(string.format("talk: stop withheld %d ms after key up: %s (%s); Flow keeps recording",
        ms(now - talk.upAt), why, describeFocus()))
      alert(msg or "ferry: note did not appear — Flow is still recording; open the note and press Ctrl-S")
    end

    local function done(why)
      c._talk = nil
      log.i("talk: no release needed: " .. why)
    end

    -- nvim's view of Flow: "recording", "waiting", "stopped", "idle", or nil
    -- (no answer).
    local function flowState()
      local ok, out = runSync("talk", { "flow-state" })
      if ok and (out == "recording" or out == "waiting" or out == "stopped" or out == "idle") then return out end
      return nil
    end

    local function release(now, mods)
      c._talk = nil
      if #mods > 0 then
        log.w("talk: " .. table.concat(mods, "+") .. " still down after " .. c.config.talkModsTimeout
          .. " s; releasing anyway")
      end
      log.i(string.format("talk: release after %d ms (waited focus %d ms, mods %d ms)",
        ms(now - talk.upAt), ms(focusAt - talk.upAt), ms(now - readyAt)))
      -- Always --force, so the hold ends in a stop: nvim may report idle
      -- while Flow records (Ctrl-S stopped Flow and the user spoke on, a
      -- stray paste in an older flow module, or nvim never took the
      -- recording), and a stop to an idle Flow is harmless. A Submit, Cancel
      -- or Hide wait that took over keeps its own stop (prints released).
      -- The host is focused, so Flow's paste lands in it, never in the
      -- target app.
      local adopted = talk.press ~= nil and talk.press.adopted == true
      local ok, out = runSync("talk", { "release", "--force" })
      if ok and out == "released" then return end
      if ok and out == "forced" then
        if adopted then
          log.i("talk: nvim reported Flow idle (Ctrl-S?); sent the stop anyway")
        else
          log.w("talk: nvim had no recording to release; it sent the stop anyway")
        end
        return
      end
      log.w("talk: release did not stop Flow (" .. tostring(out) .. "); Flow keeps recording")
      alert("ferry: could not stop Flow — it is still recording; open the note and press Ctrl-S")
    end

    -- nvim took this hold's recording and a Submit, Cancel or Hide wait
    -- took over (that wait sent the stop; `stopped`: and its paste landed):
    -- nothing to release. Idle is not trusted: Flow may still be recording
    -- (a stray paste never makes nvim say `stopped`).
    local function stoppedInNvim(press)
      if not press.adopted then return nil end
      local st = flowState()
      if st == "waiting" or st == "stopped" then return "nvim already stopped Flow (" .. st .. ")" end
      return nil
    end

    local function step()
      c._talkTimer = nil
      if c._disabled or c._talk ~= talk then return end
      local now = nowMs()
      local press = talk.press or {}
      -- The show path has finished: nvim took the recording, or it failed.
      -- Until then a release could reach nvim before show --talk does.
      local settled = press.adopted == true or press.failed ~= nil
      local focused = hostFocused()
      if focused then
        focusAt, lossChecked = focusAt or now, false
      elseif press.failed then
        return withhold(now, "the note did not open (" .. press.failed .. ")")
      elseif focusAt and not lossChecked then
        lossChecked = true  -- the note was in front and went away: ask once
        local why = stoppedInNvim(press)
        if why then return done(why) end
      end
      if focused and talk.startExited and settled then
        readyAt = readyAt or now
        local mods = modsDown()
        if #mods == 0 or now - readyAt >= c.config.talkModsTimeout * 1000 then return release(now, mods) end
      else
        readyAt = nil
      end
      if now - talk.upAt >= c.config.talkStopTimeout * 1000 then
        -- A stop now could reach Flow before the late start: Flow would keep
        -- recording while nvim thinks it stopped. nvim stays recording, so
        -- Ctrl-S in the note stops Flow.
        if not talk.startExited then
          return withhold(now, "the Flow start task is still running",
            "ferry: Flow was slow to start — it may still be recording; open the note and press Ctrl-S")
        end
        local why = stoppedInNvim(press)
        if why then return done(why) end
        if focused then
          return withhold(now, "the note never took the recording",
            "ferry: the note was not ready — Flow is still recording; stop it in Wispr Flow")
        end
        return withhold(now, hostName() .. " not focused")
      end
      c._talkTimer = try(hs.timer.doAfter, c.config.pollInterval, step)
    end
    stopTalkPoll()
    step()
  end

  -- Start the server off the main thread. A show pressed meanwhile waits.
  function c.prewarm(cb)
    if c._warming then return end
    c._warming = true
    log.i("pre-warm: ferry-host ensure (async)")
    runAsync({ "ensure" }, function(ok)
      c._warming = false
      if not ok then log.w("pre-warm: ensure failed") end
      local after = c._afterWarm
      c._afterWarm = nil
      if after then try(after) end
      if cb then try(cb, ok) end
    end)
  end

  -- hammerspoon://ferry-submit: hide the host, then deliver p.
  function c.onSubmit(p)
    p = p or {}
    log.i(string.format("submit: target=%s window=%s", tostring(p.target), tostring(p.window)))
    hideHost(function()
      if type(c.deliver) == "function" then
        try(c.deliver, p)
      else
        log.e("submit: no deliver function")
      end
    end)
  end

  -- hammerspoon://ferry-hide: the note already wrote its draft.
  function c.onHide()
    local t0 = nowMs()
    log.i("hide: requested by the note")
    hideHost(refocusTarget)
    poll("hide", "target", t0, targetFocused)
  end

  function c.bindURLs()
    if not (hs.urlevent and hs.urlevent.bind) then
      log.e("bindURLs: hs.urlevent unavailable")
      return c
    end
    try(hs.urlevent.bind, "ferry-submit", function(_, params) c.onSubmit(params) end)
    try(hs.urlevent.bind, "ferry-hide", function() c.onHide() end)
    c._boundURLs = true
    log.i("bound hammerspoon://ferry-submit and ferry-hide")
    return c
  end

  -- Stop for good (see the header). The caller binds its own handlers
  -- afterwards; hs.urlevent.bind(name, nil) removes ours.
  function c.disable()
    if c._disabled then return end
    c._disabled = true
    c._afterWarm = nil
    stopPoll()
    stopTalkPoll()
    c._talk = nil
    if c._boundURLs and hs.urlevent and hs.urlevent.bind then
      try(hs.urlevent.bind, "ferry-submit", nil)
      try(hs.urlevent.bind, "ferry-hide", nil)
      c._boundURLs = false
    end
    log.w("instance: disabled")
  end

  return c
end

return I
