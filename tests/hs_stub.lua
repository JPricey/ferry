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
--
-- Controls (set on rec before or between calls):
--   rec.hotkeyBind     nil, or function(mods, key, fn) whose result is returned
--                      by hs.hotkey.bind (it may also error)
--   rec.frontmost      app stub returned by hs.application.frontmostApplication
--   rec.apps           bundle id -> app stub, for hs.application.get
--   rec.focusedWindow  window stub returned by hs.window.focusedWindow
--   rec.windows        window id -> window stub, for hs.window.get
--   rec.accessibility  value of hs.accessibilityState() (default true)
--   rec.osascriptResult  {ok, result, err} returned by hs.osascript.applescript
--   rec.pasteboard     {contents = string|nil, changeCount = n}
--   rec.onKeyStroke    optional function(mods, key, delay, app) hook
--   rec.clock          seconds for hs.timer.secondsSinceEpoch; usleep advances it

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

-- App stub. opts: bundleID, name, window (window stub), frontmostOnActivate.
function S.app(rec, opts)
  local a = { _bundle = opts.bundleID, _name = opts.name or opts.bundleID, _window = opts.window }
  function a:bundleID() return self._bundle end
  function a:name() return self._name end
  function a:focusedWindow() return self._window end
  function a:mainWindow() return self._window end
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

-- Window stub. opts: id, title, app (app stub).
function S.window(rec, opts)
  local w = { _id = opts.id, _title = opts.title or "", _app = opts.app }
  function w:id() return self._id end
  function w:title() return self._title end
  function w:application() return self._app end
  function w:focus()
    rec.focuses[#rec.focuses + 1] = self
    rec.focusedWindow = self
    if self._app then rec.frontmost = self._app end
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
    apps = {}, windows = {}, accessibility = true,
    pasteboard = { contents = nil, changeCount = 0 },
    clock = 1000,
  }

  function rec:app(opts) return S.app(self, opts) end
  function rec:window(opts) return S.window(self, opts) end

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
  }

  hs.window = {
    focusedWindow = function() return rec.focusedWindow end,
    get = function(id) return rec.windows[id] end,
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
    usleep = function(us) rec.clock = rec.clock + us / 1e6 end,
    doAfter = function(delay, fn)
      local t = { delay = delay, fn = fn, fired = false }
      function t:stop() self.fired = true; return self end
      rec.timers[#rec.timers + 1] = t
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
