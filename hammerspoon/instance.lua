-- instance.lua: Hammerspoon controller for the one long-lived voice-vim.
--
-- Not loaded by hammerspoon/voice-vim.lua yet (that is task B2). Ported from
-- spike/host/host.lua without its hosts table: the window that shows nvim is
-- an injected host, and the server and note are driven by bin/voice-vim-host.
--
--   local instance = dofile(root .. "/hammerspoon/instance.lua")
--   local c = instance.new({ host = host, deliver = M.submit, root = root })
--   c.prewarm()   -- start the nvim server off the main thread
--   c.bindURLs()  -- hammerspoon://voicevim-submit and voicevim-hide
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
--                       (`voice-vim-host attach-cmd`); cb(ok, why) once it
--                       has been asked to. Called by show when `status`
--                       reports no UI attached; the controller then calls
--                       show once while polling, after cb.
--
-- toggle() (the hotkey):
--   host focused -> `voice-vim-host draft`, host.hide, refocus the captured
--                   window object (its app when the window is gone)
--   otherwise    -> capture the frontmost app + window (and, with
--                   captureSelection, the selection as a seed file),
--                   `voice-vim-host show <bundle> <window> [seedfile]`,
--                   `voice-vim-host status`, host.show (host.launch first
--                   when status says uis=0)
-- Each direction polls every pollInterval and logs to logger `voice-vim`,
-- timed from the key press (so the show/draft call is included):
--   show: show took N ms              hide: draft took N ms
--   show: host focused after N ms     hide: target focused after N ms
-- Each press also logs `toggle: focused=<bool> (<why>) -> show|hide`.
--
-- onSubmit(p) (hammerspoon://voicevim-submit?file=&target=&window=):
--   host.hide, then deliver(p). deliver is injected (B2: voice-vim.lua's
--   M.submit, which focuses p's target and pastes).
-- onHide() (hammerspoon://voicevim-hide, from :Hide / :Cancel in the note,
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
--   sock              VOICE_VIM_SOCK for voice-vim-host (default: its own)
--   notesDir          VOICE_VIM_NOTES_DIR (default: voice-vim-host's own)
--   nvimFlags         VOICE_VIM_HOST_NVIM_FLAGS (tests: "--clean")
--   pollInterval      seconds between focus checks (default 0.01)
--   pollTimeout       seconds before a focus poll gives up (default 5)
--   selectionTimeout  seconds to wait for Cmd+C to land (default 0.4)
--   launchGrace       seconds after a host.launch during which uis=0 is
--                     taken as the UI still starting (default 5)
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
    },
    host = cfg.host,
    deliver = cfg.deliver,
    shown = false,     -- we showed the host and have not hidden it since
    target = nil,      -- { app, bundle, win, winId } captured on show
    _timer = nil,      -- current poll timer (kept so it is not collected)
    _tasks = {},       -- running hs.task objects (kept so they are not collected)
    _warming = false,  -- a pre-warm `voice-vim-host ensure` is running
    _afterWarm = nil,  -- show continuation waiting for the pre-warm
    _launchedAt = nil, -- nowMs() of the last host.launch (nil: none pending)
  }
  local log = hs.logger.new("voice-vim", "info")
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
  -- voice-vim-host calls

  local function envPrefix()
    local parts = {}
    local function add(k, v) if v ~= nil and v ~= "" then parts[#parts + 1] = k .. "=" .. q(v) end end
    add("VOICE_VIM_SOCK", c.config.sock)
    add("VOICE_VIM_NOTES_DIR", c.config.notesDir)
    add("VOICE_VIM_HOST_NVIM_FLAGS", c.config.nvimFlags)
    if #parts == 0 then return "" end
    return table.concat(parts, " ") .. " "
  end

  local function command(args)
    local quoted = {}
    for i, a in ipairs(args) do quoted[i] = q(a) end
    return envPrefix() .. q(c.config.root .. "/bin/voice-vim-host") .. " " .. table.concat(quoted, " ")
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
        log.i(string.format("voice-vim-host %s: done after %d ms %s", args[1], ms(nowMs() - t0), text))
      else
        log.e(string.format("voice-vim-host %s: exit %s: %s", args[1], tostring(code), text))
      end
      done(ok, text)
    end, { "-c", cmd })
    if not task then
      log.e("voice-vim-host " .. args[1] .. ": could not create hs.task")
      return done(false, "")
    end
    c._tasks[#c._tasks + 1] = task
    if not try(task.start, task) then
      log.e("voice-vim-host " .. args[1] .. ": hs.task did not start")
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
  -- onMiss (optional) runs after each check that fails.
  local function poll(label, what, t0, check, onMiss)
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

  local function hostShow()
    try(h.show, function(okShow, why)
      if okShow == false then log.w("show: host.show failed: " .. tostring(why)) end
    end)
  end

  -- Number of UIs attached to the server, from `voice-vim-host status`
  -- (nil when it does not answer `up uis=N`).
  local function attachedUIs()
    local _, out = runSync("show", { "status" })
    return tonumber(out:match("up uis=(%d+)"))
  end

  -- No UI attached: launch the host, then call host.show once while
  -- polling, after launch has reported back. Within launchGrace of the
  -- last launch the UI is taken as still starting, so a quick second press
  -- never opens a second window.
  local function launchAndPoll(t0)
    local since = c._launchedAt and (nowMs() - c._launchedAt) or nil
    if since and since < c.config.launchGrace * 1000 then
      log.i(string.format("show: no UI attached yet, launched %d ms ago; showing", ms(since)))
      hostShow()
      poll("show", "host", t0, hostFocused)
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
    poll("show", "host", t0, hostFocused, function()
      if launched and not showed then
        showed = true
        hostShow()
      end
    end)
  end

  -- again: { seed = path } on the one retry after the server was down.
  local function showRest(t0, again)
    local args = { "show", c.target.bundle or "", c.target.winId and tostring(c.target.winId) or "" }
    local seed
    if again then seed = again.seed else seed = seedFile() end
    if seed then args[#args + 1] = seed end
    local ok, out = runSync("show", args)
    if not ok and not again and out:find("no server on", 1, true) then
      log.w("show: server down; voice-vim-host ensure, then retry show once")
      c._afterWarm = function() showRest(t0, { seed = seed }) end
      c.prewarm()
      return
    end
    if seed then os.remove(seed) end
    if not ok then
      alert("voice-vim: could not open the note (see console)")
      return
    end
    c.shown = true
    local uis = attachedUIs()
    if uis == 0 then
      launchAndPoll(t0)
      return
    end
    if uis then c._launchedAt = nil else log.w("show: status did not report uis") end
    hostShow()
    poll("show", "host", t0, hostFocused)
  end

  -- Show the host with the note. t0: the key press (default now).
  function c.show(t0)
    t0 = t0 or nowMs()
    stopPoll()
    captureTarget()
    if c._warming then
      -- A synchronous show now would find no server; wait for the ensure.
      log.i("show: waiting for the pre-warm ensure to finish")
      c._afterWarm = function() showRest(t0) end
      return
    end
    showRest(t0)
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
    t0 = t0 or nowMs()
    runSync("hide", { "draft" })
    hideHost(refocusTarget)
    poll("hide", "target", t0, targetFocused)
  end

  function c.toggle()
    local t0 = nowMs()  -- the press: every ms line is measured from here
    local focused, why = try(h.isFocused)
    focused = focused == true
    log.i(string.format("toggle: focused=%s (%s) -> %s; shown=%s %s", tostring(focused),
      tostring(why), focused and "hide" or "show", tostring(c.shown), describeFocus()))
    if focused then c.hide(t0) else c.show(t0) end
  end

  -- Start the server off the main thread. A show pressed meanwhile waits.
  function c.prewarm(cb)
    if c._warming then return end
    c._warming = true
    log.i("pre-warm: voice-vim-host ensure (async)")
    runAsync({ "ensure" }, function(ok)
      c._warming = false
      if not ok then log.w("pre-warm: ensure failed") end
      local after = c._afterWarm
      c._afterWarm = nil
      if after then try(after) end
      if cb then try(cb, ok) end
    end)
  end

  -- hammerspoon://voicevim-submit: hide the host, then deliver p.
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

  -- hammerspoon://voicevim-hide: the note already wrote its draft.
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
    try(hs.urlevent.bind, "voicevim-submit", function(_, params) c.onSubmit(params) end)
    try(hs.urlevent.bind, "voicevim-hide", function() c.onHide() end)
    log.i("bound hammerspoon://voicevim-submit and voicevim-hide")
    return c
  end

  return c
end

return I
