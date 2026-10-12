-- hosts/neovide.lua: Neovide as the host window of the one ferry
-- instance (GROUND_TRUTHS decision 10). Implements the host interface
-- documented at the top of hammerspoon/instance.lua.
--
-- Loaded by hammerspoon/ferry.lua.
--
--   local neovide = dofile(root .. "/hammerspoon/hosts/neovide.lua")
--   if neovide.available() then
--     local host = neovide.new({ sock = sock, root = root })
--     local c = dofile(root .. "/hammerspoon/instance.lua").new({
--       host = host, sock = sock, deliver = M.submit, root = root })
--   end
--
-- Pass the same sock to both (default: ${TMPDIR}/ferry.sock, as
-- bin/ferry-host).
--
--   launch(cb)   start Neovide attached to the server, off the main thread
--                (hs.task running /bin/sh). With the ferry.app wrapper
--                (below): `<app>/Contents/MacOS/ferry --icon
--                <app>/Contents/Resources/ferry.png --server <sock>` under
--                nohup, a direct exec (never `open`, which would resolve the
--                symlinked binary back to Neovide.app). Without it:
--                `neovide --server <sock>` under nohup when a neovide binary
--                is found (searchPath, then the app bundle's
--                Contents/MacOS/neovide), else
--                `open -n -a Neovide --args --server <sock>`. cb(ok, why)
--                once the task started. Then the first new Neovide window
--                is adopted by hammerspoon/window-frame.lua: it gets the
--                saved frame (or the default) and moves are saved
--                (hs.settings key ferry.windowFrame). If window-frame.lua cannot load,
--                a plain poll finds the launched window instead, so a held
--                show still happens (the frame is then left to Neovide).
--   show(cb)     app:unhide(), unminimize its window (after Cmd+M),
--                app:activate(), focus the window. If
--                Neovide is not up yet (just launched) or has no window,
--                the show is kept and done when the launched window
--                appears. A window not seen before (Neovide was already
--                running) is watched for moves, not moved. With ferry.app
--                and no ferry.app running (say a plain Neovide from before
--                the wrapper is still attached, so the controller saw a UI
--                and did not launch), show launches ferry.app itself and
--                holds the show. Once ferry.app's window has appeared, every
--                plain Neovide attached to our socket is quit (below), so
--                there is never a second ferry window.
--   hide(cb)     app:hide(). The controller refocuses the target in cb.
--   isFocused()  -> bool, why: the frontmost app is our Neovide and its
--                window is neither minimized nor invisible (so a press
--                after Cmd+M shows it instead of hiding nothing).
--   available()  -> bool, why: ferry.app, a neovide binary or Neovide.app
--                exists.
--
-- ferry.app (milestone "ferry in the Dock"): install.sh builds a wrapper
-- bundle at appPath (default ~/Applications/ferry.app, bundle id
-- local.ferry, name ferry) whose Contents/MacOS/ferry is a symlink to
-- Neovide's binary, so the Dock, Cmd-Tab and the menu bar show "ferry".
-- While its executable resolves, every lookup (our app, the window adopted
-- after launch, the frontmost check) uses its bundle id and name, and a
-- plain Neovide (com.neovide.neovide) is never shown, hidden or adopted.
-- Without it, plain Neovide as before; which one is in use is logged once,
-- and again when it changes (checked on each call, so install.sh needs no
-- reload).
--
-- Old plain window: once ferry.app's launched window is found, each plain
-- Neovide (com.neovide.neovide) whose command line holds exactly
-- ` --server <sock> ` is quit (app:kill(), else `/bin/kill <pid>`) and
-- logged. No other process is touched: a Neovide Joe opened himself, one on
-- another socket, or one whose command line cannot be read. If ferry.app
-- does not launch or its window never appears, the plain one is kept.
--
-- Our Neovide only: show, hide and isFocused act on the one Neovide process
-- attached to our socket, never on a Neovide Joe runs for his own editing.
-- Its pid is remembered from the window adopted after launch, or found by
-- reading each Neovide process's command line (`ps -o args= -p <pid>`,
-- once per pid) for `--server <sock>`.
--
-- Logs to logger `ferry` with prefix `neovide:`. Every hs call is
-- nil-guarded and pcall'd. Launching runs in hs.task; the only blocking
-- call is one short `ps` per Neovide pid (cached) to find our instance.
-- Valid for Lua 5.4 and LuaJIT.

local N = {}

N.BUNDLE = "com.neovide.neovide"
N.NAME = "Neovide"
N.APP_BUNDLE = "local.ferry" -- the ferry.app wrapper (install.sh builds it)
N.APP_NAME = "ferry"
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

-- Same default as bin/ferry-host.
local function defaultSock()
  local tmp = os.getenv("TMPDIR")
  if not tmp or tmp == "" then tmp = "/tmp" end
  tmp = tmp:gsub("/$", "")
  return tmp .. "/ferry.sock"
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

local function defaultAppPath()
  local home = os.getenv("HOME")
  if not home or home == "" then return nil end
  return home .. "/Applications/ferry.app"
end

local function defaultAppPaths()
  local paths = { "/Applications/Neovide.app" }
  local home = os.getenv("HOME")
  if home then paths[#paths + 1] = home .. "/Applications/Neovide.app" end
  return paths
end

-- cfg:
--   log            hs.logger (default: a "ferry" logger)
--   sock           server socket (default ${TMPDIR}/ferry.sock)
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
--   appPath        the ferry.app wrapper (default ~/Applications/ferry.app;
--                  false: never use it)
--   appBundleID    its bundle id (default local.ferry)
--   appName        its app name (default ferry)
--   killPid        function(pid) that ends a process when app:kill() is
--                  missing or fails (default: /bin/kill <pid> through
--                  hs.execute)
function N.new(cfg)
  cfg = cfg or {}
  local log = cfg.log or hs.logger.new("ferry", "info")
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
      killPid = cfg.killPid,
      appPath = (cfg.appPath == nil) and defaultAppPath() or cfg.appPath,
      appBundleID = cfg.appBundleID or N.APP_BUNDLE,
      appName = cfg.appName or N.APP_NAME,
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
    _using = nil,           -- "app" or "plain": what was last logged
    _stale = {},            -- pid -> true: plain Neovides on our socket, logged
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

  -- The ferry.app wrapper's executable when it resolves (a symlink to a
  -- Neovide binary that is gone does not), else nil. Logs which host is in
  -- use when that changes.
  local function wrapperExe()
    local app = o.config.appPath
    local exe = type(app) == "string" and app ~= "" and app .. "/Contents/MacOS/ferry" or nil
    if exe and not isFile(exe) then exe = nil end
    local using = exe and "app" or "plain"
    if using ~= o._using then
      o._using = using
      if exe then
        log.i("neovide: using ferry.app at " .. app .. " (" .. o.config.appBundleID .. ")")
      else
        log.i("neovide: no ferry.app at " .. tostring(app)
          .. " (or its binary is missing); using plain Neovide (run ./install.sh)")
      end
    end
    return exe
  end

  -- Bundle id and app name of our host app: ferry.app's, else Neovide's.
  local function ident()
    if wrapperExe() then return o.config.appBundleID, o.config.appName end
    return N.BUNDLE, N.NAME
  end
  o.ident = ident

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
    if wrapperExe() then return true, "ferry.app at " .. o.config.appPath end
    local bin = findBinary()
    if bin then return true, "neovide at " .. bin end
    local app = appBundle()
    if app then return true, "Neovide.app at " .. app end
    return false, "no neovide binary or Neovide.app"
  end

  -- The shell command that starts Neovide attached to the server.
  function o.launchCommand()
    local sock = o.config.sock
    local exe = wrapperExe()
    if exe then
      -- Direct exec of the wrapper's executable, so macOS attributes the
      -- process to ferry.app. Never `open`: it resolves the symlink and
      -- starts Neovide.app.
      local icon = o.config.appPath .. "/Contents/Resources/ferry.png"
      local iconArg = isFile(icon) and (" --icon " .. q(icon)) or ""
      return "nohup " .. q(exe) .. iconArg .. " --server " .. q(sock)
        .. " </dev/null >/dev/null 2>&1 &", "ferry.app"
    end
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

  -- app is our host app's kind (ferry.app, else plain Neovide), by bundle
  -- id or name.
  local function isNeovide(app)
    local bundle, name = ident()
    return call(app, "bundleID") == bundle or call(app, "name") == name
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
    local bundle, name = ident()
    local cands = {}
    local list = hs.application.applicationsForBundleID
      and try(hs.application.applicationsForBundleID, bundle)
    if type(list) == "table" then
      for _, a in ipairs(list) do cands[#cands + 1] = a end
    end
    if hs.application.get then
      cands[#cands + 1] = try(hs.application.get, bundle)
      cands[#cands + 1] = try(hs.application.get, name)
    end
    for i = 1, #cands do
      local a = cands[i]
      -- get(name) matches loosely; isNeovide keeps our app's kind only.
      if a and isNeovide(a) and isOurs(a) then return a end
    end
    return nil
  end

  -- With ferry.app: the plain Neovide apps attached to our socket (started
  -- before the wrapper existed), as {app, pid}. Only a command line that
  -- holds exactly ` --server <sock> ` counts; any other is remembered as
  -- foreign, an unreadable one is skipped.
  local function stalePlain()
    local out = {}
    if not (hs.application and hs.application.applicationsForBundleID) then return out end
    local list = try(hs.application.applicationsForBundleID, N.BUNDLE)
    if type(list) ~= "table" then return out end
    for _, a in ipairs(list) do
      local pid = pidOf(a)
      if pid and not o._foreign[pid] then
        local cmd = commandLine(pid)
        if cmd and (" " .. cmd .. " "):find(" --server " .. o.config.sock .. " ", 1, true) then
          out[#out + 1] = { app = a, pid = pid }
        elseif cmd then
          o._foreign[pid] = true
        end
      end
    end
    return out
  end

  -- Log (once per pid) the plain Neovides on our socket while ferry.app
  -- is launched; they are quit once its window appears.
  local function noteStalePlain()
    for _, s in ipairs(stalePlain()) do
      if not o._stale[s.pid] then
        o._stale[s.pid] = true
        log.w("neovide: a plain Neovide (pid " .. s.pid .. ") is attached to our server;"
          .. " it is quit once ferry.app's window appears")
      end
    end
  end

  local function killPid(pid)
    if type(o.config.killPid) == "function" then return try(o.config.killPid, pid) end
    if not hs.execute then return false end
    local _, ok = try(hs.execute, string.format("/bin/kill %d", pid))
    return ok == true
  end

  -- ferry.app's window is up: quit every plain Neovide on our socket, so
  -- the old window does not stay beside it (GROUND_TRUTHS requirement 4).
  local function quitStalePlain()
    if not wrapperExe() then return end
    for _, s in ipairs(stalePlain()) do
      local how
      local okGet, fn = pcall(function() return s.app.kill end)
      if okGet and type(fn) == "function" then
        local ok, res = pcall(fn, s.app)
        if ok and res ~= false then
          how = "app:kill()"
        else
          log.w("neovide: app:kill() on plain Neovide pid " .. s.pid .. " failed: " .. tostring(res))
        end
      end
      if not how and killPid(s.pid) then how = "kill " .. s.pid end
      if how then
        log.i("neovide: quit the old plain Neovide (pid " .. s.pid .. ", --server "
          .. o.config.sock .. ") now that ferry.app is up (" .. how .. ")")
      else
        log.e("neovide: could not quit the old plain Neovide (pid " .. s.pid .. "); quit it by hand")
      end
      if o._pid == s.pid then o._pid = nil end
      o._stale[s.pid] = nil
    end
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
        quitStalePlain()
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
    local bundle = ident()
    local before = wf and try(wf.snapshot, bundle) or {}
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
        if app and not (isNeovide(app) and isOurs(app, true)) then
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
        quitStalePlain()
      end
      try(wf.adopt, bundle, before, o.config.adoptTimeout, opts)
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
      if wrapperExe() then
        -- The controller launches only when no UI is attached; a plain
        -- Neovide left on our socket counts as one. Launch ferry.app here;
        -- the plain one is quit once ferry.app's window appears.
        noteStalePlain()
        log.w("neovide: show: ferry.app (--server " .. o.config.sock .. ") is not running; launching it")
        local launched, why
        o.launch(function(ok, w) launched, why = ok, w end)
        if launched then return done(cb, true, "launching ferry.app") end
        o._pendingShow = false
        return done(cb, false, "ferry.app did not launch: " .. tostring(why))
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
    local _, name = ident()
    local win = windowOf(app)
    if not win then return false, name .. " frontmost but has no window" end
    if call(win, "isMinimized") == true then return false, name .. " window minimized" end
    if call(win, "isVisible") == false then return false, name .. " window not visible" end
    return true, name .. " frontmost" .. how
  end

  function o.isFocused()
    local app = hs.application and try(hs.application.frontmostApplication)
    local b = call(app, "bundleID")
    local pid = pidOf(app)
    local how = b == ident() and "" or " (by name)"
    if o._pid and pid == o._pid and isNeovide(app) then return windowShown(app, how) end
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
