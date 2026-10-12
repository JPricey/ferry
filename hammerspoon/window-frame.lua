-- window-frame.lua: Hammerspoon glue that gives a voice-vim window its frame
-- and remembers where Joe moves it.
--
-- The frame logic (default, restore, clamping) is pure and lives in
-- lua/voice-vim/frame.lua; this file only reads screens and windows, sets
-- the frame, and saves moves. hammerspoon/voice-vim.lua uses it for the
-- Ghostty session window. The one-instance host adapter (B1) reuses it.
--
--   local wf = dofile(root .. "/hammerspoon/window-frame.lua").new({
--     log = log,            -- hs.logger (default: a "voice-vim" logger)
--     frame = frameModule,  -- lua/voice-vim/frame.lua (default: dofile it
--                           -- from root, or from this file's repo)
--     root = root,          -- repo root, only used to find frame.lua
--     key = "voice-vim.windowFrame",  -- hs.settings key
--     fraction = 0.5,       -- default size, as a fraction of the main screen
--   })
--   local before = wf.snapshot("com.mitchellh.ghostty")  -- before opening
--   ... open the window ...
--   wf.adopt("com.mitchellh.ghostty", before)            -- after opening
--
--   snapshot(bundle)        -> set of the app's current window ids
--   adopt(bundle, before, timeout)
--                           find a window of the app whose id is not in
--                           before (the focused window first); check at
--                           once, then every 0.02 s up to timeout (2 s).
--                           On a hit: apply, then watch. On a miss: log
--                           `frame: session window not found`.
--   apply(win, done)        leave native fullscreen if needed (retry once
--                           after 0.6 s), set the restored frame with no
--                           animation, log `frame: default|restored|moved
--                           onto main screen …`, then done(win).
--   watch(win)              save the frame 0.5 s after the last move or
--                           resize (at once when the window closes), unless
--                           fullscreen, unchanged, or parked off every
--                           screen. Logs `frame: saved …`.
--
-- Watching starts only after our frame is applied, so the terminal's own
-- opening frame is never saved. Every hs call is nil-guarded and pcall'd;
-- nothing here raises after new(). new() raises when frame.lua cannot be
-- loaded (callers pcall it). Valid for Lua 5.4 and LuaJIT.

local W = {}

W.KEY = "voice-vim.windowFrame"
W.POLL = 0.02           -- seconds between adopt checks
W.TIMEOUT = 2           -- default adopt timeout, seconds
W.FULLSCREEN_WAIT = 0.6 -- seconds to wait after leaving fullscreen
W.DEBOUNCE = 0.5        -- seconds of quiet before a move is saved

-- Repo root from this file's path (hammerspoon/window-frame.lua).
local function defaultRoot()
  local info = debug.getinfo(1, "S")
  local src = info and info.source or ""
  local path = src:match("^@(.*)$")
  if not path then return nil end
  return path:match("^(.*)/hammerspoon/[^/]+$") or path:match("^(.*)/[^/]+$")
end

local function round(v) return math.floor(v + 0.5) end

local function fmt(f)
  return string.format("%d,%d %dx%d", f.x, f.y, f.w, f.h)
end

local function same(a, b)
  return type(a) == "table" and type(b) == "table"
    and a.x == b.x and a.y == b.y and a.w == b.w and a.h == b.h
end

function W.new(cfg)
  cfg = cfg or {}
  local log = cfg.log or hs.logger.new("voice-vim", "info")
  local frame = cfg.frame
  if type(frame) ~= "table" then
    local root = cfg.root or defaultRoot() or "."
    frame = dofile(root .. "/lua/voice-vim/frame.lua")
  end
  assert(type(frame) == "table" and type(frame.restore) == "function",
    "window-frame: frame.lua did not return the frame module")

  local o = {
    log = log,
    frame = frame,
    key = cfg.key or W.KEY,
    fraction = cfg.fraction,
    _adoptTimer = nil, -- current adopt poll (kept so it is not collected)
    _applyTimer = nil, -- pending fullscreen retry
    _watched = {},     -- window id -> { watcher, timer, pending, last }
  }

  local function try(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, a, b = pcall(fn, ...)
    if not ok then
      log.w("frame: " .. tostring(a))
      return nil
    end
    return a, b
  end

  -- Call obj:name(...) when obj has it.
  local function call(obj, name, ...)
    if obj == nil then return nil end
    local ok, fn = pcall(function() return obj[name] end)
    if not ok or type(fn) ~= "function" then return nil end
    return try(fn, obj, ...)
  end

  -- A plain integer {x,y,w,h} copy of an hs.geometry rect, or nil.
  local function rect(r)
    if type(r) ~= "table" and type(r) ~= "userdata" then return nil end
    local ok, x, y, w, h = pcall(function() return r.x, r.y, r.w, r.h end)
    if not ok then return nil end
    local vals = { x, y, w, h }
    for i = 1, 4 do
      local v = vals[i]
      if type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge then return nil end
    end
    return { x = round(x), y = round(y), w = round(w), h = round(h) }
  end

  local function screens()
    local out = {}
    local all = hs.screen and try(hs.screen.allScreens)
    if type(all) == "table" then
      for _, s in ipairs(all) do
        local r = rect(call(s, "frame"))
        if r then out[#out + 1] = r end
      end
    end
    return out
  end

  local function mainScreen()
    local s = hs.screen and try(hs.screen.mainScreen)
    return rect(call(s, "frame"))
  end

  local function saved()
    if not (hs.settings and hs.settings.get) then return nil end
    return try(hs.settings.get, o.key)
  end

  local function winId(win) return call(win, "id") end

  local function bundleOf(win)
    return call(call(win, "application"), "bundleID")
  end

  local function stopTimer(t)
    if t then call(t, "stop") end
  end

  local function after(delay, fn)
    if not (hs.timer and hs.timer.doAfter) then return nil end
    return try(hs.timer.doAfter, delay, fn)
  end

  -- -------------------------------------------------------------------------

  function o.snapshot(bundle)
    local set = {}
    local app = hs.application and try(hs.application.get, bundle)
    local wins = call(app, "allWindows")
    if type(wins) == "table" then
      for _, w in ipairs(wins) do
        local id = winId(w)
        if id ~= nil then set[id] = true end
      end
    end
    return set
  end

  -- A window of bundle whose id is not in before, focused window first.
  local function findNew(bundle, before)
    local function fresh(w)
      local id = winId(w)
      return id ~= nil and not before[id]
    end
    local focused = hs.window and try(hs.window.focusedWindow)
    if focused and bundleOf(focused) == bundle and fresh(focused) then return focused end
    local app = hs.application and try(hs.application.get, bundle)
    local af = call(app, "focusedWindow")
    if af and fresh(af) then return af end
    local wins = call(app, "allWindows")
    if type(wins) == "table" then
      for _, w in ipairs(wins) do
        if fresh(w) then return w end
      end
    end
    return nil
  end

  function o.adopt(bundle, before, timeout)
    before = type(before) == "table" and before or {}
    timeout = (type(timeout) == "number" and timeout >= 0) and timeout or W.TIMEOUT
    stopTimer(o._adoptTimer)
    o._adoptTimer = nil
    local polls = 0
    local maxPolls = math.ceil(timeout / W.POLL)
    local function check()
      o._adoptTimer = nil
      local win = findNew(bundle, before)
      if win then
        log.i(string.format("frame: session window %s found after %d polls", tostring(winId(win)), polls))
        o.apply(win, o.watch)
        return
      end
      if polls >= maxPolls then
        log.w(string.format("frame: session window not found after %.1f s (%s)", timeout, tostring(bundle)))
        return
      end
      polls = polls + 1
      o._adoptTimer = after(W.POLL, check)
      if not o._adoptTimer then log.w("frame: session window not found (no timer)") end
    end
    check()
  end

  function o.apply(win, done)
    stopTimer(o._applyTimer)
    o._applyTimer = nil
    local function set(retried)
      o._applyTimer = nil
      if call(win, "isFullScreen") == true then
        if retried then
          log.w("frame: window still fullscreen, frame not set")
          return
        end
        log.i("frame: leaving fullscreen")
        call(win, "setFullScreen", false)
        o._applyTimer = after(W.FULLSCREEN_WAIT, function() set(true) end)
        return
      end
      local f, reason = o.frame.restore(saved(), screens(), mainScreen(), o.fraction)
      if not f then
        log.w("frame: no screen, frame not set")
        return
      end
      call(win, "setFrame", f, 0)
      local label = reason == "moved" and "moved onto main screen" or reason
      log.i("frame: " .. tostring(label) .. " " .. fmt(f))
      if type(done) == "function" then
        local ok, err = pcall(done, win, f)
        if not ok then log.w("frame: " .. tostring(err)) end
      end
    end
    set(false)
  end

  -- Save the window's pending frame unless it is unchanged.
  local function flush(st)
    stopTimer(st.timer)
    st.timer = nil
    local f = st.pending
    st.pending = nil
    if not f or same(f, st.last) then return end
    local cur = saved()
    st.last = f
    if same(f, rect(cur)) then return end
    if not (hs.settings and hs.settings.set) then
      log.w("frame: hs.settings unavailable, not saved")
      return
    end
    try(hs.settings.set, o.key, { x = f.x, y = f.y, w = f.w, h = f.h })
    log.i("frame: saved " .. fmt(f))
  end

  -- applied: the frame apply() set (the unchanged baseline), or nil.
  function o.watch(win, applied)
    local id = winId(win)
    if id == nil then
      log.w("frame: window has no id, not watching")
      return
    end
    local old = o._watched[id]
    if old then
      stopTimer(old.timer)
      call(old.watcher, "stop")
    end
    local st = { last = rect(applied) or rect(call(win, "frame")) }
    local ev = hs.uielement and hs.uielement.watcher or {}
    local moved, resized, destroyed = ev.windowMoved, ev.windowResized, ev.elementDestroyed

    local function onEvent(_, event)
      if event == destroyed then
        flush(st)
        call(st.watcher, "stop")
        if o._watched[id] == st then o._watched[id] = nil end
        return
      end
      if call(win, "isFullScreen") == true then return end
      local f = rect(call(win, "frame"))
      if not f then return end
      if not o.frame.onScreen(f, screens()) then return end -- parked off-screen
      st.pending = f
      stopTimer(st.timer)
      st.timer = after(W.DEBOUNCE, function() flush(st) end)
    end

    st.watcher = call(win, "newWatcher", function(el, event, _w, _u)
      local ok, err = pcall(onEvent, el, event)
      if not ok then log.w("frame: watcher: " .. tostring(err)) end
    end)
    if not st.watcher then
      log.w("frame: cannot watch window " .. tostring(id))
      return
    end
    local events = {}
    for _, e in ipairs({ moved, resized, destroyed }) do
      if e ~= nil then events[#events + 1] = e end
    end
    call(st.watcher, "start", events)
    o._watched[id] = st -- keeps the watcher referenced
  end

  return o
end

return W
