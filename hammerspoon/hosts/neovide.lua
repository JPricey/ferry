-- hosts/neovide.lua: Neovide as the host window of the one voice-vim
-- instance (GROUND_TRUTHS decision 10). Implements the host interface
-- documented at the top of hammerspoon/instance.lua.
--
-- Loaded by hammerspoon/voice-vim.lua in the one-instance mode. Ported
-- from the neovide block of spike/host/host.lua and spike/host/neovide.sh.
--
--   local neovide = dofile(root .. "/hammerspoon/hosts/neovide.lua")
--   if neovide.available() then
--     local host = neovide.new({ sock = sock, root = root })
--     local c = dofile(root .. "/hammerspoon/instance.lua").new({
--       host = host, sock = sock, deliver = M.submit, root = root })
--   end
--
-- Pass the same sock to both (default: ${TMPDIR}/voice-vim.sock, as
-- bin/voice-vim-host).
--
--   launch(cb)   start Neovide attached to the server, off the main thread
--                (hs.task running /bin/sh): `neovide --server <sock>` under
--                nohup when a neovide binary is found (searchPath, then the
--                app bundle's Contents/MacOS/neovide), else
--                `open -n -a Neovide --args --server <sock>`. cb(ok, why)
--                once the task started. Then the first new Neovide window
--                is adopted by hammerspoon/window-frame.lua: it gets the
--                saved frame (or the default) and moves are saved, shared
--                with the Ghostty session window (hs.settings key
--                voice-vim.windowFrame). If window-frame.lua cannot load,
--                a plain poll finds the launched window instead, so a held
--                show still happens (the frame is then left to Neovide).
--   show(cb)     app:unhide(), unminimize its window (after Cmd+M),
--                app:activate(), focus the window. If
--                Neovide is not up yet (just launched) or has no window,
--                the show is kept and done when the launched window
--                appears. A window not seen before (Neovide was already
--                running) is watched for moves, not moved.
--   hide(cb)     app:hide(). The controller refocuses the target in cb.
--   isFocused()  -> bool, why: the frontmost app is our Neovide and its
--                window is neither minimized nor invisible (so a press
--                after Cmd+M shows it instead of hiding nothing).
--   available()  -> bool, why: a neovide binary or Neovide.app exists.
--
-- Our Neovide only: show, hide and isFocused act on the one Neovide process
-- attached to our socket, never on a Neovide Joe runs for his own editing.
-- Its pid is remembered from the window adopted after launch, or found by
-- reading each Neovide process's command line (`ps -o args= -p <pid>`,
-- once per pid) for `--server <sock>`.
--
-- Logs to logger `voice-vim` with prefix `neovide:`. Every hs call is
-- nil-guarded and pcall'd. Launching runs in hs.task; the only blocking
-- call is one short `ps` per Neovide pid (cached) to find our instance.
-- Valid for Lua 5.4 and LuaJIT.

local N = {}

N.BUNDLE = "com.neovide.neovide"
N.NAME = "Neovide"
N.ADOPT_TIMEOUT = 5 -- seconds to wait for the first window after launch

local function q(s)
  return "'" .. (tostring(s):gsub("'", "'\\''")) .. "'"
end

-- Repo root from this file's path (hammerspoon/hosts/neovide.lua).
local function defaultRoot()
  local info = debug.getinfo(1, "S")
  local src = info and info.source or ""
  local path = src:match("^@(.*)$")
  if not path then return nil end
  return path:match("^(.*)/hammerspoon/hosts/[^/]+$") or path:match("^(.*)/[^/]+$")
end

-- Same default as bin/voice-vim-host.
local function defaultSock()
  local tmp = os.getenv("TMPDIR")
  if not tmp or tmp == "" then tmp = "/tmp" end
  tmp = tmp:gsub("/$", "")
  return tmp .. "/voice-vim.sock"
end

local function isFile(p)
  if type(p) ~= "string" or p == "" then return false end
  local f = io.open(p, "r")
  if not f then return false end
  f:close()
  return true
end

-- Directories searched for a `neovide` binary: $PATH (bare under
-- Hammerspoon), then the usual install places.
local function defaultSearchPath()
  local dirs, seen = {}, {}
  local function add(d)
    if d and d ~= "" and not seen[d] then
      seen[d] = true
      dirs[#dirs + 1] = d
    end
  end
  for d in (os.getenv("PATH") or ""):gmatch("[^:]+") do add(d) end
  local home = os.getenv("HOME")
  add("/opt/homebrew/bin")
  add("/usr/local/bin")
  if home then
    add(home .. "/.local/bin")
    add(home .. "/.cargo/bin")
  end
  return dirs
end

local function defaultAppPaths()
  local paths = { "/Applications/Neovide.app" }
  local home = os.getenv("HOME")
  if home then paths[#paths + 1] = home .. "/Applications/Neovide.app" end
  return paths
end

-- cfg:
--   log            hs.logger (default: a "voice-vim" logger)
--   sock           server socket (default ${TMPDIR}/voice-vim.sock)
--   root           repo root (default: from this file's path)
--   windowFrame    a hammerspoon/window-frame.lua object to share (default:
--                  one is loaded on first use)
--   fraction       first-open size as a fraction of the main screen
--   rememberFrame  false: leave the window frame to Neovide (default true)
--   adoptTimeout   seconds to wait for the window after launch (default 5)
--   searchPath     list of dirs to look for `neovide` in (default above)
--   appPaths       list of Neovide.app paths to try after
--                  hs.application.pathForBundleID (default /Applications
--                  and ~/Applications)
--   commandLine    function(pid) -> the process's command line or nil
--                  (default: /bin/ps through hs.execute)
function N.new(cfg)
  cfg = cfg or {}
  local log = cfg.log or hs.logger.new("voice-vim", "info")
  local o = {
    config = {
      sock = cfg.sock or defaultSock(),
      root = cfg.root or defaultRoot() or ".",
      fraction = cfg.fraction,
      rememberFrame = cfg.rememberFrame ~= false,
      adoptTimeout = cfg.adoptTimeout or N.ADOPT_TIMEOUT,
      searchPath = cfg.searchPath,
      appPaths = cfg.appPaths,
      commandLine = cfg.commandLine,
    },
    log = log,
    _wf = cfg.windowFrame,  -- window-frame glue (loaded lazily)
    _tasks = {},            -- running hs.task objects (kept referenced)
    _pendingShow = false,   -- show asked for before Neovide had a window
    _launchedAt = nil,      -- seconds of the last launch
    _watchedId = nil,       -- id of the Neovide window whose frame we watch
    _pid = nil,             -- pid of our Neovide (attached to our socket)
    _foreign = {},          -- pid -> true for Neovide processes that are not ours
    _findTimer = nil,       -- fallback poll for the launched window
  }

  local function try(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, a, b = pcall(fn, ...)
    if not ok then
      log.w("neovide: " .. tostring(a))
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

  local function done(cb, ok, why)
    if type(cb) == "function" then try(cb, ok, why) end
  end

  local function now()
    if hs.timer and hs.timer.secondsSinceEpoch then
      return try(hs.timer.secondsSinceEpoch) or os.time()
    end
    return os.time()
  end

  -- -------------------------------------------------------------------------
  -- Finding Neovide

  local function appBundle()
    if hs.application and hs.application.pathForBundleID then
      local p = try(hs.application.pathForBundleID, N.BUNDLE)
      if type(p) == "string" and isFile(p .. "/Contents/Info.plist") then return p end
    end
    for _, p in ipairs(o.config.appPaths or defaultAppPaths()) do
      if isFile(p .. "/Contents/Info.plist") then return p end
    end
    return nil
  end

  local function findBinary()
    for _, d in ipairs(o.config.searchPath or defaultSearchPath()) do
      local p = d .. "/neovide"
      if isFile(p) then return p end
    end
    local app = appBundle()
    if app and isFile(app .. "/Contents/MacOS/neovide") then
      return app .. "/Contents/MacOS/neovide"
    end
    return nil
  end

  function o.available()
    local bin = findBinary()
    if bin then return true, "neovide at " .. bin end
    local app = appBundle()
    if app then return true, "Neovide.app at " .. app end
    return false, "no neovide binary or Neovide.app"
  end

  -- The shell command that starts Neovide attached to the server.
  function o.launchCommand()
    local sock = o.config.sock
    local bin = findBinary()
    if bin then
      -- nohup + &: the sh exits at once and Neovide outlives the hs.task
      -- (and a Hammerspoon reload), forking or not.
      return "nohup " .. q(bin) .. " --server " .. q(sock) .. " </dev/null >/dev/null 2>&1 &", "binary"
    end
    -- No CLI found: go through the app bundle. -n so that a Neovide
    -- already running (not attached) does not swallow the arguments.
    return "open -n -a " .. q(N.NAME) .. " --args --server " .. q(sock), "open"
  end

  -- -------------------------------------------------------------------------
  -- Our Neovide process

  local function pidOf(app)
    local p = call(app, "pid")
    if type(p) == "number" then return p end
    return nil
  end

  local function isNeovide(app)
    return call(app, "bundleID") == N.BUNDLE or call(app, "name") == N.NAME
  end

  local function commandLine(pid)
    if type(o.config.commandLine) == "function" then return try(o.config.commandLine, pid) end
    if not hs.execute then return nil end
    local out, ok = try(hs.execute, string.format("/bin/ps -o args= -p %d", pid))
    if not ok or type(out) ~= "string" then return nil end
    out = out:gsub("%s+$", "")
    if out == "" then return nil end
    return out
  end

  -- Whether app is our Neovide. unknownOk: also yes when its command line
  -- cannot be read (the window that appeared right after our launch).
  local function isOurs(app, unknownOk)
    local pid = pidOf(app)
    if not pid then return false end
    if pid == o._pid then return true end
    if o._foreign[pid] then return false end
    local cmd = commandLine(pid)
    if cmd == nil and not unknownOk then return false end
    if cmd == nil or (" " .. cmd .. " "):find(" --server " .. o.config.sock .. " ", 1, true) then
      o._pid = pid
      log.i("neovide: pid " .. pid .. " is ours (--server " .. o.config.sock .. ")")
      return true
    end
    o._foreign[pid] = true
    log.i("neovide: pid " .. pid .. " is another Neovide, left alone")
    return false
  end

  -- Our running Neovide app, or nil.
  local function neovideApp()
    if not hs.application then return nil end
    if o._pid then
      local app = hs.application.applicationForPID and try(hs.application.applicationForPID, o._pid)
      if app and isNeovide(app) then return app end
      log.i("neovide: pid " .. o._pid .. " is gone")
      o._pid = nil
    end
    local cands = {}
    local list = hs.application.applicationsForBundleID
      and try(hs.application.applicationsForBundleID, N.BUNDLE)
    if type(list) == "table" then
      for _, a in ipairs(list) do cands[#cands + 1] = a end
    end
    if hs.application.get then
      cands[#cands + 1] = try(hs.application.get, N.BUNDLE)
      cands[#cands + 1] = try(hs.application.get, N.NAME)
    end
    for i = 1, #cands do
      local a = cands[i]
      if a and isOurs(a) then return a end
    end
    return nil
  end

  -- -------------------------------------------------------------------------
  -- Window frame

  local function glue()
    if o._wf then return o._wf end
    local ok, res = pcall(function()
      return dofile(o.config.root .. "/hammerspoon/window-frame.lua").new({
        log = log, root = o.config.root, fraction = o.config.fraction,
      })
    end)
    if not (ok and type(res) == "table" and type(res.adopt) == "function") then
      log.e("neovide: cannot load window-frame.lua, window frame not set: " .. tostring(res))
      return nil
    end
    o._wf = res
    return res
  end

  -- Watch a Neovide window we did not adopt (Neovide was already running),
  -- so Joe's moves are saved; its frame is left where it is.
  local function watchExisting(win)
    if not o.config.rememberFrame then return end
    local id = call(win, "id")
    if id == nil or id == o._watchedId then return end
    local wf = glue()
    if not (wf and type(wf.watch) == "function") then return end
    log.i("neovide: watching window " .. tostring(id) .. " (not adopted at launch)")
    try(wf.watch, win)
    o._watchedId = id
  end

  -- Our app's window: the main or focused one, else the first of
  -- allWindows (a minimized window is not always the main window).
  local function windowOf(app)
    local win = call(app, "mainWindow") or call(app, "focusedWindow")
    if win then return win end
    local all = call(app, "allWindows")
    if type(all) == "table" then return all[1] end
    return nil
  end

  -- Undo Cmd+M: a minimized window stays minimized through unhide/activate.
  local function unminimize(win)
    if call(win, "isMinimized") == true then
      log.i("neovide: window " .. tostring(call(win, "id")) .. " is minimized; unminimizing")
      call(win, "unminimize")
    end
  end

  -- Unhide, unminimize, activate and focus the window; returns it or nil.
  local function bringForward(app)
    call(app, "unhide")
    local win = windowOf(app)
    if win then unminimize(win) end
    call(app, "activate")
    if win then
      call(win, "focus")
      watchExisting(win)
    end
    return win
  end

  -- Unhide, unminimize, activate and focus win (a show held until it
  -- appeared).
  local function showHeld(app, win)
    o._pendingShow = false
    call(app, "unhide")
    unminimize(win)
    call(app, "activate")
    call(win, "focus")
  end

  -- Without window-frame.lua: poll for our launched Neovide's window, so a
  -- show held until it appeared still happens.
  local function findLaunched()
    if o._findTimer then call(o._findTimer, "stop") end
    o._findTimer = nil
    local deadline = now() + o.config.adoptTimeout
    local function step()
      o._findTimer = nil
      local app = neovideApp()
      local win = app and windowOf(app)
      if win then
        log.i("neovide: window " .. tostring(call(win, "id")) .. " found after launch (no frame glue)")
        if o._pendingShow then showHeld(app, win) end
        return
      end
      if now() >= deadline then
        log.w("neovide: launched window not found after " .. o.config.adoptTimeout .. " s")
        return
      end
      o._findTimer = hs.timer and try(hs.timer.doAfter, 0.05, step)
    end
    step()
  end

  -- -------------------------------------------------------------------------
  -- Host interface

  function o.launch(cb)
    local cmd, how = o.launchCommand()
    log.i("neovide: launch (" .. how .. "): " .. cmd)
    local wf = glue()
    local before = wf and try(wf.snapshot, N.BUNDLE) or {}
    if not (hs.task and hs.task.new) then
      log.e("neovide: launch: hs.task unavailable")
      return done(cb, false, "hs.task unavailable")
    end
    local task
    task = try(hs.task.new, "/bin/sh", function(code, out, err)
      for i, t in ipairs(o._tasks) do
        if t == task then table.remove(o._tasks, i); break end
      end
      local text = tostring(out or "") .. tostring(err or "")
      if code == 0 then
        log.i("neovide: launch command done")
      else
        log.w("neovide: launch command exit " .. tostring(code) .. ": " .. text)
      end
    end, { "-c", cmd })
    if not task then
      log.e("neovide: launch: could not create hs.task")
      return done(cb, false, "could not create hs.task")
    end
    o._tasks[#o._tasks + 1] = task
    if not try(task.start, task) then
      for i, t in ipairs(o._tasks) do
        if t == task then table.remove(o._tasks, i); break end
      end
      log.e("neovide: launch: hs.task did not start")
      return done(cb, false, "hs.task did not start")
    end
    o._launchedAt = now()
    if wf then
      local opts = { frame = o.config.rememberFrame }
      opts.onFound = function(win)
        local id = call(win, "id")
        local app = call(win, "application")
        if app and not isOurs(app, true) then
          -- Another Neovide opened a window: leave it where it is (adopt
          -- reads opts.frame after onFound) and look for ours instead.
          log.w("neovide: window " .. tostring(id) .. " is not ours; not adopted")
          opts.frame = false
          findLaunched()
          return
        end
        log.i("neovide: window " .. tostring(id) .. " appeared after launch")
        if o.config.rememberFrame then o._watchedId = id end
        if o._pendingShow then showHeld(app or neovideApp(), win) end
      end
      try(wf.adopt, N.BUNDLE, before, o.config.adoptTimeout, opts)
    else
      findLaunched()
    end
    done(cb, true)
  end

  function o.show(cb)
    local app = neovideApp()
    if not app then
      o._pendingShow = true
      local since = o._launchedAt and (now() - o._launchedAt)
      if since and since <= o.config.adoptTimeout then
        log.i("neovide: show: not up yet, will show its window when it appears")
        return done(cb, true, "waiting for the launched window")
      end
      log.w("neovide: show: our Neovide (--server " .. o.config.sock .. ") is not running")
      return done(cb, false, "Neovide not running")
    end
    local win = bringForward(app)
    if not win then
      o._pendingShow = true
      log.i("neovide: show: no window yet, will focus it when it appears")
    else
      o._pendingShow = false
    end
    done(cb, true)
  end

  function o.hide(cb)
    o._pendingShow = false
    local app = neovideApp()
    if app then
      call(app, "hide")
    else
      log.i("neovide: hide: our Neovide is not running")
    end
    done(cb, true)
  end

  -- Our Neovide is frontmost: focused only when its window can be seen.
  local function windowShown(app, how)
    local win = windowOf(app)
    if not win then return false, "Neovide frontmost but has no window" end
    if call(win, "isMinimized") == true then return false, "Neovide window minimized" end
    if call(win, "isVisible") == false then return false, "Neovide window not visible" end
    return true, "Neovide frontmost" .. how
  end

  function o.isFocused()
    local app = hs.application and try(hs.application.frontmostApplication)
    local b = call(app, "bundleID")
    local pid = pidOf(app)
    local how = b == N.BUNDLE and "" or " (by name)"
    if o._pid and pid == o._pid then return windowShown(app, how) end
    if isNeovide(app) then
      if isOurs(app) then return windowShown(app, how) end
      return false, "frontmost is another Neovide (pid " .. tostring(pid) .. ")"
    end
    return false, "frontmost is " .. tostring(b)
  end

  return o
end

-- Whether Neovide is installed (cfg as new()).
function N.available(cfg)
  return N.new(cfg).available()
end

return N
