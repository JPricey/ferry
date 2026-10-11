-- host.lua: Hammerspoon side of the single-instance host spike.
--
-- Not part of voice-vim proper: hammerspoon/voice-vim.lua never requires it.
-- Joe loads it by hand from the Hammerspoon console:
--
--   vvspike = dofile(os.getenv("HOME") .. "/Code/voice-vim/spike/host/host.lua")
--     .start({ host = "ghostty-window" })
--   vvspike.use("neovide")            -- hides the current host first
--   vvspike.start({ host = "quick-terminal", qtMode = "keystroke" })
--   vvspike.stop()                    -- unbinds the spike hotkey
--
-- The hotkey (default Ctrl+Option+Cmd+V, apart from voice-vim's
-- Ctrl+Option+V) calls toggle():
--   hidden  -> capture the frontmost app + window, `<script> note` (ensures
--              the server, fresh note in insert mode), show the host
--   focused -> `<script> draft`, hide the host, refocus the captured window
--              (or its app when the window is gone)
-- Each direction polls every 10 ms and logs to logger `voice-vim-spike`,
-- timed from the hotkey press (so the note/draft call is included):
--   show: note took N ms              hide: draft took N ms
--   show: host focused after N ms     hide: target focused after N ms
-- Each press also logs `toggle: … focused=<bool> (<why>)`, the branch taken.
--
-- Hosts (scripts in this folder, see their headers):
--   ghostty-window  ghostty-window.sh; window titled voice-vim-host; hide
--                   moves it off-screen
--   neovide         neovide.sh; show = unhide + activate; hide = app:hide()
--   quick-terminal  quick-terminal.sh; show = launch (toggle, attach if no
--                   UI); hide = toggle. qtMode = "keystroke" sets VV_QT_MODE.
--                   Focused = shown by us, Ghostty frontmost, and the focused
--                   window is the one seen when the show was confirmed.
--
-- Unknown (quick-terminal, Joe check 5): if autohide hides the quick
-- terminal and it is not an hs.window (seen as window nil), a press while
-- Ghostty is frontmost with no focused hs.window still reads as "focused"
-- and hides instead of shows; press again. Likewise if the show was never
-- confirmed (poll timed out). The `toggle:` line logs which case it was.
--
-- Valid for Lua 5.4 and LuaJIT. note and draft run on the main thread
-- (hs.execute). They are quick only while the nvim server is up: each runs
-- `vv-host ensure`, and a cold ensure waits up to ~5 s for nvim, blocking
-- Hammerspoon. So start() and use() pre-warm the server with an async
-- `vv-host ensure` (hs.task), and a press during the pre-warm waits for it
-- instead of cold-starting a second server. If the server dies later (e.g.
-- `vv-host stop`), the next note cold-starts it on the main thread; the
-- `show: note took N ms` line shows that. launch and the quick-terminal
-- toggle also run as hs.task.

local M = {}

local log = hs.logger.new("voice-vim-spike", "info")
M.log = log

local GHOSTTY = "com.mitchellh.ghostty"
local NEOVIDE = "com.neovide.neovide"
local TITLE = "voice-vim-host"

M.config = {
  host = "ghostty-window",
  hotkey = { { "ctrl", "alt", "cmd" }, "v" },
  qtMode = nil,       -- nil/"applescript" or "keystroke"
  sock = nil,         -- VOICE_VIM_SOCK (scripts default to $TMPDIR/voice-vim-spike.sock)
  notes = nil,        -- VOICE_VIM_SPIKE_NOTES
  nvimFlags = nil,    -- VV_HOST_NVIM_FLAGS
  dir = nil,          -- folder holding the scripts (default: this file's folder)
  pollInterval = 0.01,
  pollTimeout = 5,    -- seconds; a cold Neovide launch can take a while
}

-- State.
M.shown = false       -- we showed the host and have not hidden it since
M.target = nil        -- { app = hs.application, bundle = string, win = hs.window, winId = number }
M.hotkeyObj = nil
M._timer = nil        -- current poll timer (kept so it is not collected)
M._tasks = {}         -- running hs.task objects (kept so they are not collected)
M._saved = nil        -- ghostty-window: top-left before it went off-screen
M._warming = false    -- a pre-warm `vv-host ensure` is running
M._afterWarm = nil    -- show continuation waiting for the pre-warm
M._qtWin = nil        -- quick-terminal: focused window id when it was last
                      -- seen shown (false: it had none); nil: not seen yet

-- ---------------------------------------------------------------------------
-- Helpers

local function try(fn, ...)
  local ok, a, b = pcall(fn, ...)
  if not ok then
    log.w("spike: " .. tostring(a))
    return nil
  end
  return a, b
end

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

local function scriptDir()
  if M.config.dir then return M.config.dir end
  local info = debug.getinfo(1, "S")
  local src = info and info.source or ""
  local dir = src:match("^@(.*)/[^/]*$")
  return dir or "."
end

local function envPrefix()
  local c = M.config
  local parts = {}
  local function add(k, v) if v ~= nil and v ~= "" then parts[#parts + 1] = k .. "=" .. q(v) end end
  add("VOICE_VIM_SOCK", c.sock)
  add("VOICE_VIM_SPIKE_NOTES", c.notes)
  add("VV_HOST_NVIM_FLAGS", c.nvimFlags)
  if c.qtMode == "keystroke" then add("VV_QT_MODE", "keystroke") end
  if #parts == 0 then return "" end
  return table.concat(parts, " ") .. " "
end

local function command(script, sub)
  return envPrefix() .. q(scriptDir() .. "/" .. script) .. " " .. sub
end

-- Synchronous call (note, draft): a couple of --remote-expr round trips while
-- the server is up. Logs `<label>: <sub> took N ms` so the cost is visible.
local function runSync(label, script, sub)
  local cmd = command(script, sub) .. " 2>&1"
  local t0 = nowMs()
  local out, ok = try(hs.execute, cmd)
  out = trim(out)
  local took = ms(nowMs() - t0)
  if ok then
    log.i(string.format("%s: %s took %d ms (%s %s)", label, sub, took, script, out))
  else
    log.e(string.format("%s: %s failed after %d ms (%s): %s", label, sub, took, script, out))
  end
  return ok and true or false, out
end

-- Slow call (launch, toggle) off the main thread; cb(ok, output) when done.
local function runAsync(script, sub, cb)
  local cmd = command(script, sub)
  local t0 = nowMs()
  local task
  task = try(hs.task.new, "/bin/sh", function(code, out, err)
    for i, t in ipairs(M._tasks) do
      if t == task then table.remove(M._tasks, i); break end
    end
    local ok = code == 0
    local text = trim((out or "") .. (err or ""))
    if ok then
      log.i(string.format("%s %s: done after %d ms %s", script, sub, ms(nowMs() - t0), text))
    else
      log.e(string.format("%s %s: exit %s: %s", script, sub, tostring(code), text))
    end
    if cb then try(cb, ok, text) end
  end, { "-c", cmd })
  if not task then
    log.e(string.format("%s %s: could not create hs.task", script, sub))
    if cb then try(cb, false, "") end
    return
  end
  M._tasks[#M._tasks + 1] = task
  if not try(task.start, task) then
    log.e(string.format("%s %s: hs.task did not start", script, sub))
    table.remove(M._tasks)
    if cb then try(cb, false, "") end
  end
end

local function frontBundle()
  local app = try(hs.application.frontmostApplication)
  return app and try(app.bundleID, app) or nil
end

local function focusedWin()
  return try(hs.window.focusedWindow)
end

local function winId(w)
  return w and try(w.id, w) or nil
end

local function winTitle(w)
  return w and try(w.title, w) or nil
end

local function describeFocus()
  local w = focusedWin()
  return string.format("front=%s win=%s title=%q", tostring(frontBundle()), tostring(winId(w)),
    tostring(winTitle(w) or ""))
end

-- ---------------------------------------------------------------------------
-- Hosts. Each has: script, isFocused(), focus() -> true if it brought an
-- existing host forward, launch(cb), hide(cb).

local function ghosttyApp()
  return try(hs.application.get, GHOSTTY)
end

local function ghosttyHostWindow()
  local app = ghosttyApp()
  if not (app and app.allWindows) then return nil end
  for _, w in ipairs(try(app.allWindows, app) or {}) do
    local t = winTitle(w)
    if t and t:find(TITLE, 1, true) then return w end
  end
  return nil
end

local function neovideApp()
  return try(hs.application.get, NEOVIDE) or try(hs.application.get, "Neovide")
end

local hosts = {}

-- True when the window's centre is on no screen (parked by hide).
local function offScreen(w)
  local f = w.frame and try(w.frame, w)
  if not (f and f.x and f.w) then return false end
  local cx, cy = f.x + f.w / 2, f.y + f.h / 2
  for _, s in ipairs((hs.screen and try(hs.screen.allScreens)) or {}) do
    local sf = s.frame and try(s.frame, s)
    if sf and cx >= sf.x and cx < sf.x + sf.w and cy >= sf.y and cy < sf.y + sf.h then
      return false
    end
  end
  return true
end

-- Top-left that centres window w on the main screen.
local function centred(w)
  local scr = hs.screen and try(hs.screen.mainScreen)
  local sf = scr and scr.frame and try(scr.frame, scr)
  local f = w.frame and try(w.frame, w)
  if not (sf and f) then return { x = 100, y = 100 } end
  return { x = math.floor(sf.x + math.max(0, sf.w - f.w) / 2),
           y = math.floor(sf.y + math.max(0, sf.h - f.h) / 2) }
end

hosts["ghostty-window"] = {
  script = "ghostty-window.sh",
  isFocused = function()
    local t = winTitle(focusedWin())
    local yes = t ~= nil and t:find(TITLE, 1, true) ~= nil
    return yes, string.format("focused title %q %s %s", tostring(t or ""),
      yes and "contains" or "lacks", TITLE)
  end,
  focus = function()
    local w = ghosttyHostWindow()
    if not w then return false end
    if w.setTopLeft then
      if M._saved then
        try(w.setTopLeft, w, M._saved)
      elseif offScreen(w) then
        -- Parked by an earlier copy of this module (re-dofile'd): no saved
        -- position, so bring it back to the middle of the main screen.
        local pt = centred(w)
        log.i(string.format("show: host window off-screen, no saved position; centring at %d,%d", pt.x, pt.y))
        try(w.setTopLeft, w, pt)
      end
    end
    M._saved = nil
    try(w.focus, w)
    return true
  end,
  launch = function(cb) runAsync("ghostty-window.sh", "launch", cb) end,
  hide = function(cb)
    local w = ghosttyHostWindow()
    if w and w.setTopLeft then
      if w.topLeft then M._saved = try(w.topLeft, w) end
      -- Park it at the far corner of its screen; macOS keeps a sliver visible.
      local pt = { x = 100000, y = 100000 }
      local scr = w.screen and try(w.screen, w)
      local f = scr and scr.fullFrame and try(scr.fullFrame, scr)
      if f and f.w and f.h then pt = { x = f.x + f.w - 1, y = f.y + f.h - 1 } end
      try(w.setTopLeft, w, pt)
    else
      log.w("hide: no window titled " .. TITLE)
    end
    if cb then cb(true) end
  end,
}

hosts["neovide"] = {
  script = "neovide.sh",
  isFocused = function()
    local b = frontBundle()
    if b == NEOVIDE then return true, "Neovide frontmost" end
    local app = try(hs.application.frontmostApplication)
    local name = app and try(app.name, app)
    if name == "Neovide" then return true, "Neovide frontmost (by name)" end
    return false, "frontmost is " .. tostring(b)
  end,
  focus = function()
    local app = neovideApp()
    if not app then return false end
    if app.unhide then try(app.unhide, app) end
    try(app.activate, app)
    return true
  end,
  launch = function(cb) runAsync("neovide.sh", "launch", cb) end,
  hide = function(cb)
    local app = neovideApp()
    if app and app.hide then try(app.hide, app) else log.w("hide: Neovide not running") end
    if cb then cb(true) end
  end,
}

hosts["quick-terminal"] = {
  script = "quick-terminal.sh",
  -- The quick terminal may not be an hs.window, and autohide can hide it
  -- behind our back (M.shown stays true). So besides "shown by us and
  -- Ghostty frontmost", compare the focused window with the one seen when
  -- the show was confirmed (M._qtWin): an ordinary Ghostty window in front
  -- means autohide hid it, and the press shows it again.
  isFocused = function()
    if not M.shown then return false, "not shown by us" end
    local b = frontBundle()
    if b ~= GHOSTTY then return false, "frontmost is " .. tostring(b) .. " (autohide?)" end
    local id = winId(focusedWin())
    if M._qtWin == nil then
      return true, string.format("Ghostty frontmost, window %s; quick terminal never confirmed shown, assuming it (unverified)", tostring(id))
    elseif M._qtWin == false then
      if id == nil then return true, "Ghostty frontmost with no focused hs.window, as when shown" end
      return false, string.format("Ghostty window %s focused, quick terminal had none (autohide hid it?)", tostring(id))
    elseif id == M._qtWin then
      return true, string.format("quick terminal window %s focused", tostring(id))
    end
    return false, string.format("Ghostty window %s focused, not quick terminal window %s (autohide hid it?)",
      tostring(id), tostring(M._qtWin))
  end,
  -- Shown once Ghostty is frontmost and the focused window is not the
  -- window we started from (nil counts: the quick terminal may have none).
  shownCheck = function()
    if frontBundle() ~= GHOSTTY then return false end
    local id = winId(focusedWin())
    return id == nil or id ~= (M.target and M.target.winId)
  end,
  -- Remember which window the quick terminal is, for isFocused.
  onShown = function()
    local id = winId(focusedWin())
    M._qtWin = id or false
    log.i("show: quick terminal is window " .. tostring(id))
  end,
  focus = function() return false end,
  launch = function(cb) runAsync("quick-terminal.sh", "launch", cb) end,
  hide = function(cb) runAsync("quick-terminal.sh", "toggle", cb) end,
}

M.hosts = hosts

local function current()
  return hosts[M.config.host]
end

-- ---------------------------------------------------------------------------
-- Polling

local function stopPoll()
  if M._timer then try(M._timer.stop, M._timer) end
  M._timer = nil
end

-- Poll every pollInterval until check() is true or pollTimeout passes.
-- t0 is the hotkey press (nowMs), so the logged ms covers the whole press.
-- onTick (optional) runs on each miss, onDone (optional) on success.
local function poll(label, what, t0, check, onTick, onDone)
  stopPoll()
  local function step()
    M._timer = nil
    local elapsed = nowMs() - t0
    if try(check) then
      log.i(string.format("%s: %s focused after %d ms (host=%s)", label, what,
        ms(elapsed), M.config.host))
      if onDone then try(onDone) end
      return
    end
    if elapsed >= M.config.pollTimeout * 1000 then
      log.w(string.format("%s: %s not focused after %d ms (host=%s; %s)", label, what,
        ms(elapsed), M.config.host, describeFocus()))
      return
    end
    if onTick then try(onTick) end
    M._timer = hs.timer.doAfter(M.config.pollInterval, step)
  end
  step()
end

-- ---------------------------------------------------------------------------
-- Show / hide

local function captureTarget()
  local app = try(hs.application.frontmostApplication)
  local w = focusedWin()
  M.target = {
    app = app,
    bundle = app and try(app.bundleID, app) or nil,
    win = w,
    winId = winId(w),
  }
  log.i(string.format("show: target %s window %s", tostring(M.target.bundle), tostring(M.target.winId)))
end

local function targetFocused()
  local t = M.target
  if not t then return true end
  if t.winId then return winId(focusedWin()) == t.winId end
  return t.bundle ~= nil and frontBundle() == t.bundle
end

local function refocusTarget()
  local t = M.target
  if not t then log.w("hide: no captured target"); return end
  -- Use the window object captured on show (no hs.window.get scan); a
  -- closed window answers id() with nil.
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

local function showRest(h, t0)
  local okNote = runSync("show", h.script, "note")
  if not okNote then
    if hs.alert then try(hs.alert.show, "voice-vim spike: note failed (see console)") end
    return
  end
  M.shown = true
  M._qtWin = nil  -- quick-terminal: re-learned by onShown
  local brought = try(h.focus)
  local check = h.shownCheck or h.isFocused
  local retried = brought
  if brought then
    poll("show", "host", t0, check, nil, h.onShown)
  else
    log.i("show: launching " .. M.config.host)
    -- After a launch the host may appear without key focus; bring it
    -- forward once when it shows up.
    h.launch(function() end)
    poll("show", "host", t0, check, function()
      if not retried then retried = try(h.focus) end
    end, h.onShown)
  end
end

-- Show the host with a fresh note. t0: the hotkey press (default now).
function M.show(t0)
  t0 = t0 or nowMs()
  local h = current()
  if not h then log.e("unknown host: " .. tostring(M.config.host)); return end
  captureTarget()
  if M._warming then
    -- A second, synchronous ensure now could start a second server.
    log.i("show: waiting for the pre-warm ensure to finish")
    M._afterWarm = function() showRest(h, t0) end
    return
  end
  showRest(h, t0)
end

-- Hide the host and refocus the target. Used by toggle() and use().
-- t0: the hotkey press (default now).
function M.hide(t0)
  t0 = t0 or nowMs()
  local h = current()
  if not h then log.e("unknown host: " .. tostring(M.config.host)); return end
  stopPoll()
  runSync("hide", h.script, "draft")
  M.shown = false
  h.hide(function()
    refocusTarget()
  end)
  poll("hide", "target", t0, targetFocused)
end

function M.toggle()
  local t0 = nowMs()  -- the press: every ms line is measured from here
  local h = current()
  if not h then log.e("unknown host: " .. tostring(M.config.host)); return end
  local focused, why = try(h.isFocused)
  log.i(string.format("toggle: host=%s focused=%s (%s) -> %s; shown=%s %s", M.config.host,
    tostring(focused), tostring(why), focused and "hide" or "show", tostring(M.shown), describeFocus()))
  if focused then M.hide(t0) else M.show(t0) end
end

-- Start the nvim server off the main thread, so the first note does not
-- cold-start it inside hs.execute. A show pressed meanwhile waits for it.
local function prewarm()
  if M._warming then return end
  M._warming = true
  log.i("pre-warm: vv-host ensure (async)")
  runAsync("vv-host", "ensure", function(ok)
    M._warming = false
    if not ok then log.w("pre-warm: ensure failed; the next note will try again") end
    local after = M._afterWarm
    M._afterWarm = nil
    if after then try(after) end
  end)
end
M.prewarm = prewarm

-- Switch hosts; hides the old one first if we showed it.
function M.use(name)
  if not hosts[name] then
    log.e("use: unknown host " .. tostring(name) .. " (ghostty-window, neovide, quick-terminal)")
    return M
  end
  if name ~= M.config.host and M.shown then
    log.i("use: hiding " .. M.config.host .. " first")
    M.hide()
  end
  M.config.host = name
  log.i("use: host=" .. name)
  prewarm()
  return M
end

-- ---------------------------------------------------------------------------
-- Start / stop

local function unbind()
  if M.hotkeyObj then try(M.hotkeyObj.delete, M.hotkeyObj) end
  M.hotkeyObj = nil
end

function M.start(opts)
  opts = opts or {}
  local newHost = opts.host
  for k, v in pairs(opts) do
    if k ~= "host" then M.config[k] = v end
  end
  if newHost then
    if M.config.host ~= newHost and M.shown then M.use(newHost) end
    if not hosts[newHost] then
      log.e("start: unknown host " .. tostring(newHost))
    else
      M.config.host = newHost
    end
  end
  unbind()
  prewarm()
  local mods, key = M.config.hotkey[1], M.config.hotkey[2]
  local desc = table.concat(mods or {}, "+") .. "+" .. tostring(key)
  local ok, obj = pcall(hs.hotkey.bind, mods, key, function() try(M.toggle) end)
  if ok and obj then
    M.hotkeyObj = obj
    log.i(string.format("bound %s (host=%s, qtMode=%s)", desc, M.config.host, tostring(M.config.qtMode)))
  else
    log.e("failed to bind " .. desc .. ": " .. tostring(obj))
    if hs.alert then try(hs.alert.show, "voice-vim spike: failed to bind " .. desc) end
  end
  return M
end

function M.stop()
  unbind()
  stopPoll()
  log.i("stopped (hotkey unbound)")
  return M
end

return M
