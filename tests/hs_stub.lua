-- Stub of the parts of the Hammerspoon `hs` API that voice-vim uses.
--
-- Runs under `nvim -l` (LuaJIT) or plain Lua. It records every call that has
-- an effect and lets a test control what the API returns.
--
--   local stub = dofile(root .. "/tests/hs_stub.lua")
--   local rec = stub.install()          -- sets _G.hs, returns the recorder
--   rec.hotkeyBind = function() return nil end   -- make hs.hotkey.bind fail
--   local M = stub.load(root .. "/hammerspoon/voice-vim.lua")
--   M.start({ hotkey = { { "ctrl", "alt" }, "v" } })
--   rec:hasLog("e", "failed to bind")
--
-- Recorded (all lists, in call order):
--   rec.hotkeyBinds  {mods, key, fn, obj}
--   rec.urlBinds     name -> handler (also rec.urlBindOrder, a list of names)
--   rec.alerts       message strings
--   rec.keyStrokes   {mods, key, delay, app}
--   rec.logs         {level, msg, name}   level is "i", "e", "w", "d", "f", "v"
--   rec.executes     {cmd, out}
--   rec.osascripts   script strings
--   rec.pasteboardSets  strings ("" for clearContents)
--   rec.activations  app stubs passed to app:activate()
--   rec.focuses      window stubs passed to win:focus()
--   rec.timers       {delay, fn, fired}  (run them with rec:runTimers())
--   rec.windowGets   number of hs.window.get calls
--   rec.hides        app stubs passed to app:hide()
--   rec.unhides      app stubs passed to app:unhide()
--   rec.moves        {win, point} for win:setTopLeft(point)
--   rec.tasks        {path, args, cb, started} for hs.task.new (never run;
--                    finish one with rec:finishTask(i, code, out, err))
--
-- Controls (set on rec before or between calls):
--   rec.hotkeyBind     nil, or function(mods, key, fn) whose result is returned
--                      by hs.hotkey.bind (it may also error)
--   rec.frontmost      app stub returned by hs.application.frontmostApplication
--   rec.apps           bundle id -> app stub, for hs.application.get
--   rec.focusedWindow  window stub returned by hs.window.focusedWindow
--   rec.windows        window id -> window stub, for hs.window.get
--   rec:closeWindow(id)  the window's id() then returns nil, get() misses it
--   rec.accessibility  value of hs.accessibilityState() (default true)
--   rec.osascriptResult  {ok, result, err} returned by hs.osascript.applescript
--   rec.pasteboard     {contents = string|nil, changeCount = n}
--   rec.onKeyStroke    optional function(mods, key, delay, app) hook
--   rec.clock          seconds for hs.timer.secondsSinceEpoch (and
--                      hs.timer.absoluteTime, in ns); usleep and timers advance it
--   rec.screen         {x, y, w, h} of the one screen (hs.screen.mainScreen,
--                      allScreens, win:screen; default 0,0 1440x900)
--   rec.execStatus     true: hs.execute returns the command's real exit
--                      status (and records rc); default: success unless
--                      popen close fails, which LuaJIT never reports
--   app opts.windows   list returned by app:allWindows() (default {window})
--   window opts.size   {w, h} for win:frame() (default 800x600)
--
-- Window frame additions (hammerspoon/window-frame.lua):
--   rec.settings       key -> value for hs.settings.get/set (in memory)
--   rec.screens        nil, or list of {x, y, w, h}: hs.screen.allScreens
--                      returns these; mainScreen stays rec.screen
--   rec.setFrames      {win, frame, duration} for win:setFrame(rect, duration)
--   rec.fullScreenSets {win, value} for win:setFullScreen(value)
--   rec.watchers       watcher stubs from win:newWatcher(fn, userData):
--                      {win, fn, userData, events, started, stopped}
--   rec:fireWatcher(win, event)  call win's started, unstopped watchers as
--                      Hammerspoon would: fn(win, event, watcher, userData)
--   rec:placeWindow(win, {x, y, w, h})  move a window as the user would (no
--                      setFrames record, no watcher event)
--   window opts.fullScreen      initial win:isFullScreen() (default false)
--   window opts.stayFullScreen  setFullScreen(false) is recorded but ignored
--   hs.uielement.watcher.windowMoved / windowResized / elementDestroyed
--
-- Session window additions (close on submit / cancel):
--   rec.closes         {win, keyStrokes} for win:close(); keyStrokes is
--                      #rec.keyStrokes at the time of the close
--   window opts.closeError   win:close() raises this message
--   window opts.closeResult  win:close() returns this (default true; a
--                            true close acts like rec:closeWindow(id))
--
-- Neovide host additions (hammerspoon/hosts/neovide.lua):
--   rec.bundlePaths    bundle id -> app path, for
--                      hs.application.pathForBundleID (default: none)
--   rec.appList        every app stub made, in order; app opts.pid sets
--                      app:pid(), hs.application.applicationForPID(pid)
--                      finds it and hs.application.applicationsForBundleID
--                      lists the apps with that bundle id
--   rec.unminimizes    window stubs passed to win:unminimize()
--   window opts.minimized  initial win:isMinimized() (default false);
--                      win:minimize() sets it. win:isVisible() is false
--                      while minimized or while its app is hidden

local S = {}

local function copy(t)
  if type(t) ~= "table" then return t end
  local c = {}
  for k, v in pairs(t) do c[k] = v end
  return c
end

local function inspect(v, depth)
  depth = depth or 0
  if type(v) == "string" then return string.format("%q", v) end
  if type(v) ~= "table" then return tostring(v) end
  if depth > 3 then return "{...}" end
  local parts = {}
  for k, x in pairs(v) do
    parts[#parts + 1] = "[" .. inspect(k, depth + 1) .. "]=" .. inspect(x, depth + 1)
  end
  table.sort(parts)
  return "{" .. table.concat(parts, ", ") .. "}"
end

-- App stub. opts: bundleID, name, window (window stub), windows (list for
-- allWindows), frontmostOnActivate.
function S.app(rec, opts)
  local a = { _bundle = opts.bundleID, _name = opts.name or opts.bundleID, _window = opts.window,
    _windows = opts.windows, _pid = opts.pid }
  rec.appList[#rec.appList + 1] = a
  function a:bundleID() return self._bundle end
  function a:pid() return self._pid end
  function a:name() return self._name end
  function a:focusedWindow() return self._window end
  function a:mainWindow() return self._window end
  function a:allWindows() return self._windows or { self._window } end
  function a:hide()
    rec.hides[#rec.hides + 1] = self
    self._hidden = true
    return self
  end
  function a:unhide()
    rec.unhides[#rec.unhides + 1] = self
    self._hidden = false
    return true
  end
  function a:isHidden() return self._hidden == true end
  function a:activate()
    rec.activations[#rec.activations + 1] = self
    if opts.frontmostOnActivate ~= false then
      rec.frontmost = self
      if self._window then rec.focusedWindow = self._window end
    end
    return true
  end
  if opts.bundleID then rec.apps[opts.bundleID] = a end
  return a
end

-- Screen stub: frame()/fullFrame() return rect (default rec.screen).
function S.screen(rec, rect)
  local s = {}
  function s:frame() return copy(rect or rec.screen) end
  function s:fullFrame() return copy(rect or rec.screen) end
  return s
end

-- Window stub. opts: id, title, app (app stub), focusOnFocus (default true;
-- false makes win:focus() record the call but leave focus where it was).
function S.window(rec, opts)
  local w = { _id = opts.id, _title = opts.title or "", _app = opts.app,
    _topLeft = opts.topLeft or { x = 0, y = 0 }, _size = opts.size or { w = 800, h = 600 } }
  function w:id()
    if self._closed then return nil end
    return self._id
  end
  function w:title() return self._title end
  function w:application() return self._app end
  function w:topLeft() return copy(self._topLeft) end
  function w:frame()
    return { x = self._topLeft.x, y = self._topLeft.y, w = self._size.w, h = self._size.h }
  end
  function w:screen() return S.screen(rec) end
  function w:setTopLeft(pt)
    rec.moves[#rec.moves + 1] = { win = self, point = copy(pt) }
    self._topLeft = copy(pt)
    return self
  end
  w._fullScreen = opts.fullScreen == true
  w._minimized = opts.minimized == true
  function w:isMinimized() return self._minimized end
  function w:minimize() self._minimized = true; return self end
  function w:unminimize()
    rec.unminimizes[#rec.unminimizes + 1] = self
    self._minimized = false
    return self
  end
  function w:isVisible()
    return not self._minimized and not (self._app and self._app._hidden == true)
  end
  function w:isFullScreen() return self._fullScreen end
  function w:setFullScreen(v)
    rec.fullScreenSets[#rec.fullScreenSets + 1] = { win = self, value = v }
    if not (opts.stayFullScreen and not v) then self._fullScreen = v and true or false end
    return self
  end
  function w:setFrame(f, duration)
    rec.setFrames[#rec.setFrames + 1] = { win = self, frame = copy(f), duration = duration }
    self._topLeft = { x = f.x, y = f.y }
    self._size = { w = f.w, h = f.h }
    return self
  end
  function w:newWatcher(fn, userData)
    local wt = { win = self, fn = fn, userData = userData, events = nil, started = false, stopped = false }
    function wt:start(events)
      self.events = copy(events)
      self.started = true
      return self
    end
    function wt:stop() self.stopped = true; return self end
    rec.watchers[#rec.watchers + 1] = wt
    return wt
  end
  function w:close()
    rec.closes[#rec.closes + 1] = { win = self, keyStrokes = #rec.keyStrokes }
    if opts.closeError then error(opts.closeError) end
    local res = opts.closeResult
    if res == nil then res = true end
    if res and self._id then rec:closeWindow(self._id) end
    return res
  end
  function w:focus()
    rec.focuses[#rec.focuses + 1] = self
    if opts.focusOnFocus ~= false then
      rec.focusedWindow = self
      if self._app then rec.frontmost = self._app end
    end
    return self
  end
  if opts.id then rec.windows[opts.id] = w end
  return w
end

-- Install a fresh stub as _G.hs and return its recorder.
function S.install()
  local rec = {
    hotkeyBinds = {}, urlBinds = {}, urlBindOrder = {}, alerts = {},
    keyStrokes = {}, logs = {}, executes = {}, osascripts = {},
    pasteboardSets = {}, activations = {}, focuses = {}, timers = {},
    apps = {}, windows = {}, windowGets = 0, accessibility = true,
    hides = {}, unhides = {}, moves = {}, tasks = {},
    settings = {}, bundlePaths = {}, appList = {}, setFrames = {}, fullScreenSets = {}, watchers = {}, closes = {},
    unminimizes = {},
    pasteboard = { contents = nil, changeCount = 0 },
    clock = 1000, screen = { x = 0, y = 0, w = 1440, h = 900 },
  }

  function rec:app(opts) return S.app(self, opts) end
  function rec:window(opts) return S.window(self, opts) end
  function rec:closeWindow(id)
    local w = self.windows[id]
    if w then w._closed = true end
    self.windows[id] = nil
    if self.focusedWindow == w then self.focusedWindow = nil end
  end

  function rec:fireWatcher(win, event)
    for _, wt in ipairs(self.watchers) do
      if wt.win == win and wt.started and not wt.stopped then wt.fn(win, event, wt, wt.userData) end
    end
  end
  function rec:placeWindow(win, f)
    win._topLeft = { x = f.x, y = f.y }
    win._size = { w = f.w, h = f.h }
  end

  -- Logs at `level` whose message contains `needle` (plain match).
  function rec:findLogs(level, needle)
    local out = {}
    for _, l in ipairs(self.logs) do
      if (level == nil or l.level == level) and (needle == nil or l.msg:find(needle, 1, true)) then
        out[#out + 1] = l
      end
    end
    return out
  end
  function rec:hasLog(level, needle) return #self:findLogs(level, needle) > 0 end

  -- Fire due timers (all of them by default), including ones they schedule.
  function rec:runTimers()
    local i = 1
    while i <= #self.timers do
      local t = self.timers[i]
      if not t.fired then
        t.fired = true
        self.clock = self.clock + t.delay
        t.fn()
      end
      i = i + 1
    end
  end

  -- Finish a recorded hs.task (1-based index) and call its callback.
  function rec:finishTask(i, code, out, err)
    local t = assert(self.tasks[i], "no task " .. tostring(i))
    t.finished = true
    if t.cb then return t.cb(code or 0, out or "", err or "") end
  end

  -- Call a bound hammerspoon:// handler, as Hammerspoon would.
  function rec:openURL(name, params)
    local fn = self.urlBinds[name]
    assert(fn, "no handler bound for hammerspoon://" .. name)
    return fn(name, params or {})
  end

  local hs = {}

  hs.logger = {
    new = function(name, _level)
      local lg = {}
      for _, lvl in ipairs({ "e", "w", "i", "d", "v", "f" }) do
        lg[lvl] = function(...)
          local parts = {}
          for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
          rec.logs[#rec.logs + 1] = { level = lvl, msg = table.concat(parts, " "), name = name }
        end
        lg[lvl .. "f"] = function(fmt, ...)
          rec.logs[#rec.logs + 1] = { level = lvl, msg = string.format(fmt, ...), name = name }
        end
      end
      lg.setLogLevel = function() end
      return lg
    end,
  }

  hs.inspect = function(v) return inspect(v) end

  hs.execute = function(cmd)
    if rec.execStatus then
      -- LuaJIT's popen close reports success whatever the exit code, so
      -- append the code to the output and strip it off again.
      local p = io.popen("{ " .. cmd .. " ; } 2>/dev/null; printf '\\n__hs_stub_rc=%d' $?")
      local raw = p and p:read("*a") or ""
      if p then p:close() end
      local out, rc = raw:match("^(.-)\n__hs_stub_rc=(%d+)$")
      out, rc = out or raw, tonumber(rc) or 1
      rec.executes[#rec.executes + 1] = { cmd = cmd, out = out, rc = rc }
      return out, rc == 0 and true or nil, "exit", rc
    end
    local p = io.popen(cmd .. " 2>/dev/null")
    local out = p and p:read("*a") or ""
    local ok = p and p:close()
    rec.executes[#rec.executes + 1] = { cmd = cmd, out = out }
    return out, ok and true or nil, "exit", ok and 0 or 1
  end

  hs.alert = { show = function(msg) rec.alerts[#rec.alerts + 1] = tostring(msg) end }

  hs.accessibilityState = function(_prompt) return rec.accessibility end

  hs.hotkey = {
    bind = function(mods, key, fn, ...)
      local obj
      if rec.hotkeyBind then
        obj = rec.hotkeyBind(mods, key, fn, ...)
      else
        obj = { deleted = false }
        function obj:delete() self.deleted = true end
        function obj:enable() return self end
        function obj:disable() return self end
      end
      rec.hotkeyBinds[#rec.hotkeyBinds + 1] = { mods = copy(mods), key = key, fn = fn, obj = obj }
      return obj
    end,
  }

  hs.urlevent = {
    bind = function(name, fn)
      if not rec.urlBinds[name] then rec.urlBindOrder[#rec.urlBindOrder + 1] = name end
      rec.urlBinds[name] = fn
    end,
  }

  hs.application = {
    frontmostApplication = function() return rec.frontmost end,
    get = function(hint) return rec.apps[hint] end,
    pathForBundleID = function(bundle) return rec.bundlePaths[bundle] end,
    applicationForPID = function(pid)
      for _, a in ipairs(rec.appList) do
        if pid ~= nil and a._pid == pid and not a._quit then return a end
      end
      return nil
    end,
    applicationsForBundleID = function(bundle)
      local out = {}
      for _, a in ipairs(rec.appList) do
        if a._bundle == bundle and not a._quit then out[#out + 1] = a end
      end
      return out
    end,
  }

  hs.window = {
    focusedWindow = function() return rec.focusedWindow end,
    get = function(id)
      rec.windowGets = rec.windowGets + 1
      return rec.windows[id]
    end,
  }

  hs.eventtap = {
    keyStroke = function(mods, key, delay, app)
      rec.keyStrokes[#rec.keyStrokes + 1] = { mods = copy(mods), key = key, delay = delay, app = app }
      if rec.onKeyStroke then rec.onKeyStroke(mods, key, delay, app) end
    end,
  }

  hs.pasteboard = {
    getContents = function() return rec.pasteboard.contents end,
    changeCount = function() return rec.pasteboard.changeCount end,
    setContents = function(s)
      rec.pasteboard.contents = s
      rec.pasteboard.changeCount = rec.pasteboard.changeCount + 1
      rec.pasteboardSets[#rec.pasteboardSets + 1] = s
      return true
    end,
    clearContents = function()
      rec.pasteboard.contents = nil
      rec.pasteboard.changeCount = rec.pasteboard.changeCount + 1
      rec.pasteboardSets[#rec.pasteboardSets + 1] = ""
      return true
    end,
  }

  hs.timer = {
    secondsSinceEpoch = function() return rec.clock end,
    absoluteTime = function() return rec.clock * 1e9 end,
    usleep = function(us) rec.clock = rec.clock + us / 1e6 end,
    doAfter = function(delay, fn)
      local t = { delay = delay, fn = fn, fired = false }
      function t:stop() self.fired = true; return self end
      rec.timers[#rec.timers + 1] = t
      return t
    end,
  }

  hs.screen = {
    mainScreen = function() return S.screen(rec) end,
    allScreens = function()
      if not rec.screens then return { S.screen(rec) } end
      local out = {}
      for i, r in ipairs(rec.screens) do out[i] = S.screen(rec, r) end
      return out
    end,
  }

  hs.settings = {
    get = function(key) return copy(rec.settings[key]) end,
    set = function(key, v) rec.settings[key] = copy(v) end,
    clear = function(key) rec.settings[key] = nil; return true end,
  }

  hs.uielement = {
    watcher = {
      windowMoved = "AXWindowMoved",
      windowResized = "AXWindowResized",
      elementDestroyed = "AXUIElementDestroyed",
    },
  }

  hs.task = {
    new = function(path, cb, a3, a4)
      local args = a4 or a3
      if type(args) ~= "table" then args = {} end
      local t = { path = path, args = copy(args), cb = cb, started = false, finished = false }
      function t:start() self.started = true; return self end
      function t:terminate() self.finished = true; return self end
      function t:isRunning() return self.started and not self.finished end
      rec.tasks[#rec.tasks + 1] = t
      return t
    end,
  }

  hs.osascript = {
    applescript = function(script)
      rec.osascripts[#rec.osascripts + 1] = script
      local r = rec.osascriptResult or { true, nil, nil }
      return r[1], r[2], r[3]
    end,
  }

  _G.hs = hs
  return rec
end

-- Load a fresh copy of a module file (not cached by require).
function S.load(path)
  local chunk = assert(loadfile(path))
  return chunk()
end

return S
