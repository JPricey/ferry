-- voice-vim: Hammerspoon module.
--
-- Two modes, picked once in start():
--
-- "instance" (default): one always-running nvim server shown in Neovide.
--   The hotkey toggles it (hammerspoon/instance.lua controller with the
--   hammerspoon/hosts/neovide.lua host): from any app it captures the app
--   and window, then shows the note in insert mode; from the note it keeps
--   the note as a draft, hides Neovide and refocuses that window. The note
--   (lua/voice-vim/note.lua) sends hammerspoon://voicevim-submit, which
--   hides Neovide and then runs M.submit below, or voicevim-hide.
--   start() pre-warms the server (an hs.task) so the first press is fast.
--
-- "session" (mode = "session", or the fallback when Neovide is not
--   installed or setting up the instance raises): each press opens a Ghostty
--   window running Neovim on a temp file (bin/voice-vim-session). Each
--   session gets a token; Hammerspoon maps it to the Ghostty window it
--   opened and closes that window on submit or on
--   hammerspoon://voicevim-cancel (which then refocuses the start window).
--
-- Submit is the same in both: put the text on the clipboard, focus the
-- target window, wait until it is frontmost, Cmd+V. The delivery logic lives
-- in lua/voice-vim/delivery.lua (pure, tested).
--
-- Usage in ~/.hammerspoon/init.lua:
--   local voicevim = require("voice-vim")
--   voicevim.start()  -- Ctrl+Option+V; pass { hotkey = { mods, key } } to change

local M = {}

M.config = {
  -- Ctrl+Option+V. Option-only combos are unreliable on macOS 15+, and
  -- Cmd+Shift+V clashes with paste-and-match-style.
  hotkey = { { "ctrl", "alt" }, "v" },
  -- Repo root; set by install.sh via the symlinked module path, or override.
  root = nil,
  -- "instance": one always-running voice-vim in Neovide that the hotkey
  -- shows and hides. "session": a new Ghostty window per press (the old
  -- path, also used when Neovide is not installed).
  mode = "instance",
  -- Copy the current selection into the buffer and replace it on submit.
  -- nil: on in session mode, off in instance mode (the Cmd+C costs up to
  -- 0.4 s per press). true or false sets it for both.
  captureSelection = nil,
  -- Session mode only: start a Flow hands-free dictation as soon as the
  -- editor opens.
  autoStartFlow = false,
  -- Session mode only: terminal to open the editor in: "ghostty" (default)
  -- or "iTerm2".
  terminal = "ghostty",
  -- Seconds to wait for the target window to be confirmed frontmost before
  -- giving up on the paste (the text then stays on the clipboard).
  confirmTimeout = 1.0,
  -- Open the Ghostty window where it was last left, at the size it was left
  -- (hammerspoon/window-frame.lua). false leaves the frame to Ghostty.
  rememberFrame = true,
  -- First-open size, as a fraction of the main screen's width and height.
  windowSize = 0.5,
  -- Instance mode: the nvim server socket (default $VOICE_VIM_SOCK, else
  -- ${TMPDIR}/voice-vim.sock, as bin/voice-vim-host).
  sock = nil,
  -- Instance mode: extra options for hammerspoon/hosts/neovide.lua new()
  -- (searchPath, appPaths, adoptTimeout, commandLine). Tests use it.
  neovide = nil,
}

local log = hs.logger.new("voice-vim", "info")

local function repoRoot()
  if M.config.root then return M.config.root end
  -- Resolve this file's real path (~/.hammerspoon/voice-vim.lua is a symlink
  -- into the repo) and go up one directory.
  local src = debug.getinfo(1, "S").source:sub(2)
  local out = hs.execute("realpath " .. string.format("%q", src))
  local real = out and out:gsub("%s+$", "") or src
  return real:match("^(.*)/hammerspoon/[^/]+$") or real:match("^(.*)/[^/]+$")
end

local function shquote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- Copy the current selection via Cmd+C, restoring the clipboard afterwards.
-- Returns the selected text or "" if nothing was copied.
local function grabSelection(app)
  local saved = hs.pasteboard.getContents()
  local before = hs.pasteboard.changeCount()
  hs.eventtap.keyStroke({ "cmd" }, "c", 0, app)
  local deadline = hs.timer.secondsSinceEpoch() + 0.4
  while hs.pasteboard.changeCount() == before and hs.timer.secondsSinceEpoch() < deadline do
    hs.timer.usleep(20000)
  end
  local sel = ""
  if hs.pasteboard.changeCount() ~= before then
    sel = hs.pasteboard.getContents() or ""
    if saved then hs.pasteboard.setContents(saved) else hs.pasteboard.clearContents() end
  end
  return sel
end

-- Build a single shell command line from argv.
local function shjoin(argv)
  local parts = {}
  for _, a in ipairs(argv) do parts[#parts + 1] = shquote(a) end
  return table.concat(parts, " ")
end

local GHOSTTY = "com.mitchellh.ghostty"

-- The window-frame glue, loaded once and kept in M._frameGlue so the
-- watchers it holds on open windows stay referenced. It also finds the
-- session window when rememberFrame is off (then it sets no frame). Returns
-- nil when the glue cannot load (logged; tried again on the next session).
-- Never raises.
local function frameGlue()
  local wf = M._frameGlue
  if not wf then
    local ok, res = pcall(function()
      local root = repoRoot()
      return dofile(root .. "/hammerspoon/window-frame.lua").new({
        log = log, root = root, fraction = M.config.windowSize,
      })
    end)
    if not (ok and type(res) == "table" and type(res.snapshot) == "function"
        and type(res.adopt) == "function") then
      log.e("frame: cannot load window-frame.lua, window frame not set: " .. tostring(res))
      return nil
    end
    wf = res
    M._frameGlue = wf
  end
  wf.fraction = M.config.windowSize
  return wf
end

-- Before the window opens: the glue and the set of Ghostty window ids, or
-- nil. Never raises.
local function frameBefore()
  local wf = frameGlue()
  if not wf then return nil end
  local ok, before = pcall(wf.snapshot, GHOSTTY)
  if not ok then
    log.e("frame: snapshot failed, window frame not set: " .. tostring(before))
    return nil
  end
  return { wf = wf, before = before }
end

-- After the window opened: find it, report it to onFound, set its frame
-- (when rememberFrame is on), watch it. Never raises.
local function frameAfter(snap, onFound)
  if not snap then return end
  local ok, err = pcall(snap.wf.adopt, GHOSTTY, snap.before, nil,
    { onFound = onFound, frame = M.config.rememberFrame ~= false })
  if not ok then log.e("frame: adopt failed: " .. tostring(err)) end
end

-- Launch a terminal window running argv (a list of strings). onFound(win)
-- is called with the new Ghostty window once it is found.
local function openTerminal(argv, onFound)
  local term = M.config.terminal
  local cmdline = shjoin(argv)
  local script
  local snap
  if term == "ghostty" then
    -- Ghostty 1.3+ exposes an AppleScript dictionary. `new window with
    -- configuration` runs our command in a fresh window of the already
    -- running instance. Ghostty 1.3.1 can leave a "Process exited" screen
    -- instead of closing it, so submit and cancel close it themselves.
    -- (The `open -na Ghostty.app --args -e` route spawns a second app
    -- instance per session and leaves it running; avoid it.)
    -- Hammerspoon needs Automation permission for Ghostty the first time.
    script = string.format([[
      tell application "Ghostty"
        set cfg to {command:%s, wait after command:false}
        set w to new window with configuration cfg
        activate window w
      end tell
    ]], string.format("%q", cmdline))
    snap = frameBefore()
  elseif term == "iTerm2" then
    if M.config.rememberFrame then log.i("frame: not managed under iTerm2") end
    log.i("session: window not tracked under iTerm2 (it closes its own)")
    script = string.format([[
      tell application "iTerm2"
        activate
        create window with default profile command %s
      end tell
    ]], string.format("%q", cmdline))
  else
    hs.alert.show("voice-vim: unknown terminal " .. tostring(term))
    return false
  end
  local ok, _, err = hs.osascript.applescript(script)
  if not ok then
    log.e(term .. " launch failed: " .. hs.inspect(err))
    hs.alert.show("voice-vim: could not open " .. term)
  elseif snap then
    frameAfter(snap, onFound)
  end
  return ok
end

-- Id of the focused window, or nil.
local function focusedWindowId()
  local win = hs.window.focusedWindow()
  local id = win and win:id() or nil
  return id
end

-- Sessions: token -> { token, target, windowId (start window), win, winId
-- (session window) }. M._windows maps a session window id to its session
-- until that window is closed, so a press from a voice-vim window (live, or
-- left on Ghostty's "Process exited" screen) reuses its start target.
M._sessions = {}
M._windows = {}

local tokenCount = 0
local function newToken()
  tokenCount = tokenCount + 1
  return string.format("%x-%x-%x", os.time(), tokenCount, math.random(0, 0xfffff))
end

-- The session whose window has this id, or nil.
local function sessionForWindow(id)
  if id == nil then return nil end
  return M._windows[id]
end

-- Close the session window for token and drop the token. Returns the
-- session (or nil). Never raises; every failure only logs.
local function endSession(token, why)
  if token == nil or token == "" then return nil end
  local s = M._sessions[token]
  M._sessions[token] = nil
  if not s or not s.win then
    log.i("session: window not found (" .. why .. ", session " .. tostring(token) .. ")")
    return s
  end
  local ok, res = pcall(function() return s.win:close() end)
  if ok and res then
    log.i("session: closed window " .. tostring(s.winId) .. " (" .. why .. ")")
    if s.winId ~= nil then M._windows[s.winId] = nil end
  else
    log.w("session: could not close window " .. tostring(s.winId) .. " (" .. why .. "): "
      .. tostring(res))
  end
  return s
end

function M.begin()
  local app = hs.application.frontmostApplication()
  local target = app and app:bundleID() or ""
  local winId = focusedWindowId()
  local sel = ""
  local reuse = sessionForWindow(winId)
  if reuse then
    -- Never target a voice-vim window: use the start target of its session.
    log.i("begin: frontmost is a voice-vim window, reusing its target")
    target, winId = reuse.target or "", reuse.windowId
  elseif M.config.captureSelection ~= false and app then
    sel = grabSelection(app)
  end

  local file = os.tmpname() .. "-voice-vim.md"
  local f = io.open(file, "w")
  if not f then hs.alert.show("voice-vim: cannot create temp file"); return end
  f:write(sel)
  f:close()

  local session = repoRoot() .. "/bin/voice-vim-session"
  local argv = { "/usr/bin/env" }
  if M.config.autoStartFlow then argv[#argv + 1] = "VOICE_VIM_AUTOSTART_FLOW=1" end
  argv[#argv + 1] = session
  argv[#argv + 1] = file
  argv[#argv + 1] = target
  argv[#argv + 1] = winId and tostring(winId) or ""
  local token = newToken()
  argv[#argv + 1] = token
  local s = { token = token, target = target, windowId = winId }
  M._sessions[token] = s
  log.i("begin: target=" .. target .. " window=" .. tostring(winId) .. " file=" .. file
    .. " session=" .. token)
  local opened = openTerminal(argv, function(win)
    s.win = win
    s.winId = win:id()
    if s.winId ~= nil then M._windows[s.winId] = s end
    log.i("session: window " .. tostring(s.winId) .. " is session " .. token)
  end)
  if not opened then M._sessions[token] = nil end
end

-- Load the pure delivery core from the repo. Returns the module or nil.
-- repoRoot() runs inside the pcall too, so any failure ends up here.
local function loadDelivery()
  local ok, mod = pcall(function()
    return dofile(repoRoot() .. "/lua/voice-vim/delivery.lua")
  end)
  if ok and type(mod) == "table" and type(mod.deliver) == "function" then return mod end
  log.e("submit: cannot load delivery.lua: " .. tostring(mod))
  return nil
end

-- Fallback when delivery cannot run: leave the text on the clipboard.
local function copyOnly(text, why)
  log.e("submit: " .. why .. "; text left on clipboard")
  pcall(hs.pasteboard.setContents, text)
  hs.alert.show("copied — paste manually")
end

-- Timers from hs.timer.doAfter are kept referenced until they fire so they
-- cannot be garbage collected first.
local pending = {}

-- The env table delivery.lua runs against, built from the real hs APIs.
-- `win` is the target window object, resolved once per submit (nil if none);
-- hs.window.get scans every window, so it is not called on each poll.
local function deliveryEnv(win, text)
  local env = {}
  env.now = function() return hs.timer.secondsSinceEpoch() end
  env.after = function(sec, fn)
    local t
    t = hs.timer.doAfter(sec, function()
      if t then pending[t] = nil end
      local ok, err = pcall(fn)
      if not ok then copyOnly(text, "delivery error: " .. tostring(err)) end
    end)
    if t then pending[t] = true end
  end
  env.frontmost = function()
    local app = hs.application.frontmostApplication()
    local win = hs.window.focusedWindow()
    return { bundle = app and app:bundleID() or nil, windowId = win and win:id() or nil }
  end
  -- Cheap: asks the captured window object for its id. A closed window
  -- returns nil (or errors), which counts as gone.
  env.windowExists = function(id)
    if id == nil or win == nil then return false end
    local ok, wid = pcall(function() return win:id() end)
    return ok and wid == id
  end
  env.focus = function(target)
    if win and env.windowExists(target.windowId) then
      log.i("submit: focusing window " .. tostring(target.windowId))
      win:focus()
      return
    end
    local app = target.bundle and hs.application.get(target.bundle) or nil
    if app then
      log.i("submit: activating app " .. tostring(target.bundle) .. " (window "
        .. tostring(target.windowId) .. " not found)")
      app:activate()
    else
      log.w("submit: target app " .. tostring(target.bundle) .. " is not running")
    end
  end
  env.getClipboard = function() return hs.pasteboard.getContents() end
  env.setClipboard = function(text) hs.pasteboard.setContents(text) end
  env.postPaste = function()
    -- Global Cmd+V, not posted to one app: per-app posting is unreliable in
    -- Electron apps. delivery.lua only calls this once the target is frontmost.
    hs.eventtap.keyStroke({ "cmd" }, "v")
    log.i("submit: keystroke cmd+v posted")
  end
  env.alert = function(msg) hs.alert.show(msg) end
  env.log = function(msg) log.i(msg) end
  return env
end

-- Callback from bin/voice-vim-session:
-- hammerspoon://voicevim-submit?file=&target=&window=&session=
function M.submit(params)
  params = params or {}
  endSession(params.session, "submit")
  local file, target = params.file, params.target or ""
  local windowId = tonumber(params.window or "")
  local f = file and io.open(file, "r")
  if not f then log.e("submit: cannot read " .. tostring(file)); return end
  local text = f:read("a")
  f:close()
  os.remove(file)
  -- Drop a single trailing newline that :w always adds.
  text = text:gsub("\n$", "")
  log.i("submit: target=" .. target .. " window=" .. tostring(windowId) .. " bytes=" .. #text)
  if text == "" then return end

  if not hs.accessibilityState() then
    hs.pasteboard.setContents(text)
    log.e("submit: Hammerspoon lacks Accessibility; cannot paste (text left on clipboard)")
    hs.alert.show("voice-vim: grant Hammerspoon Accessibility to paste (text copied)")
    hs.accessibilityState(true)
    return
  end

  local delivery = loadDelivery()
  if not delivery then
    copyOnly(text, "delivery.lua unavailable")
    return
  end

  local ok, err = pcall(function()
    local win = windowId and hs.window.get(windowId) or nil
    log.i("submit: target window " .. tostring(windowId) .. (win and " found" or " not found"))
    delivery.deliver(deliveryEnv(win, text), {
      text = text,
      bundle = target ~= "" and target or nil,
      windowId = windowId,
    }, {
      timeout = M.config.confirmTimeout,
      onDone = function(result)
        if result == "delivered" then
          log.i("submit: delivered")
        else
          log.w("submit: " .. tostring(result))
        end
      end,
    })
  end)
  if not ok then copyOnly(text, "delivery error: " .. tostring(err)) end
end

-- Callback from bin/voice-vim-session on cancel:
-- hammerspoon://voicevim-cancel?target=&window=&session=
-- Close the session window, then focus the start window (or its app).
function M.cancel(params)
  params = params or {}
  local s = endSession(params.session, "cancel")
  local target = params.target
  if target == nil or target == "" then target = s and s.target or nil end
  local windowId = tonumber(params.window or "") or (s and s.windowId) or nil
  log.i("cancel: target=" .. tostring(target) .. " window=" .. tostring(windowId))
  local ok, err = pcall(function()
    local win = windowId and hs.window.get(windowId) or nil
    if win then
      log.i("cancel: focusing window " .. tostring(windowId))
      win:focus()
      return
    end
    local app = target and target ~= "" and hs.application.get(target) or nil
    if app then
      log.i("cancel: activating app " .. tostring(target) .. " (window "
        .. tostring(windowId) .. " not found)")
      app:activate()
    else
      log.w("cancel: target " .. tostring(target) .. " not found, focus left alone")
    end
  end)
  if not ok then log.w("cancel: focus failed: " .. tostring(err)) end
end

-- True when every modifier is Option. macOS 15+ may refuse such hotkeys.
local function isOptionOnly(mods)
  if #mods == 0 then return false end
  for _, m in ipairs(mods) do
    local l = tostring(m):lower()
    if l ~= "alt" and l ~= "option" and l ~= "⌥" then return false end
  end
  return true
end

-- Same default as bin/voice-vim-host.
local function defaultSock()
  local env = os.getenv("VOICE_VIM_SOCK")
  if env and env ~= "" then return env end
  local tmp = os.getenv("TMPDIR")
  if not tmp or tmp == "" then tmp = "/tmp" end
  return (tmp:gsub("/$", "")) .. "/voice-vim.sock"
end

local NO_NEOVIDE = "voice-vim: install Neovide for the one-instance mode"
local INSTANCE_FAILED = "voice-vim: one-instance mode failed (see console); using a new window per press"

-- The controller startInstance() is building; start() disables it if the
-- setup raises after it was made, so it can never show Neovide afterwards.
local building = nil

-- Build the one-instance controller: the Neovide host, the controller with
-- M.submit as its deliver, the voicevim-submit / voicevim-hide handlers,
-- and the server pre-warm. Returns the controller and why, or nil, why and
-- the alert to show. May raise (start() pcalls it).
--
-- The mode is decided here, synchronously, from what is known now:
-- Neovide installed and this setup done. The pre-warm's outcome never
-- changes it: a failed or slow pre-warm leaves the instance in place, and
-- the next press runs ensure again (instance.lua's recovery), alerting if
-- that fails too.
local function startInstance()
  local root = repoRoot()
  local sock = M.config.sock or defaultSock()
  local hcfg = {
    log = log, sock = sock, root = root, fraction = M.config.windowSize,
    rememberFrame = M.config.rememberFrame ~= false, windowFrame = frameGlue(),
  }
  for k, v in pairs(M.config.neovide or {}) do hcfg[k] = v end
  local neovide = dofile(root .. "/hammerspoon/hosts/neovide.lua")
  local host = neovide.new(hcfg)
  local ok, why = host.available()
  if not ok then return nil, why, NO_NEOVIDE end
  local c = dofile(root .. "/hammerspoon/instance.lua").new({
    host = host, root = root, sock = sock,
    captureSelection = M.config.captureSelection == true,
    deliver = function(p) M.submit(p) end,
    hostName = "Neovide",
  })
  building = c
  c.bindURLs()
  c.prewarm(function(warm)
    if not warm then
      log.w("pre-warm: the voice-vim server did not start; staying in one-instance mode,"
        .. " the next press runs voice-vim-host ensure again")
    end
  end)
  building = nil
  return c, why
end

-- The hotkey (and hammerspoon://voicevim-start) in instance mode: show or
-- hide the one instance.
function M.toggle()
  local c = M._instance
  if not c then return M.begin() end
  local ok, err = pcall(c.toggle)
  if not ok then
    log.e("toggle: " .. tostring(err))
    hs.alert.show("voice-vim: error (see console)")
  end
end

function M.start(cfg)
  cfg = cfg or {}
  for k, v in pairs(cfg) do M.config[k] = v end
  if M.config.activateDelay ~= nil then
    -- Old key: submit now waits until the target is frontmost.
    log.w("activateDelay is no longer used; set confirmTimeout instead")
    M.config.activateDelay = nil
  end
  if M.config.windowTitle ~= nil then
    log.w("windowTitle is no longer used")
    M.config.windowTitle = nil
  end

  -- Pick the mode, once and synchronously. An error setting up the one
  -- instance leaves the new-window-per-press path working, with one alert.
  -- A controller from an earlier start() is switched off first.
  if M._instance then pcall(M._instance.disable) end
  M._instance, M.mode = nil, "session"
  if M.config.mode ~= "session" then
    building = nil
    local ok, c, why, alertMsg = pcall(startInstance)
    if ok and c then
      M._instance, M.mode = c, "instance"
      log.i("mode: one instance in Neovide (" .. tostring(why) .. ")")
    elseif ok then
      log.w("mode: Neovide not found (" .. tostring(why) .. "); using a new window per press."
        .. " Install it with: brew install --cask neovide")
      hs.alert.show(alertMsg or NO_NEOVIDE)
    else
      -- Half-built controller: drop its pending show and URL handlers.
      if building then pcall(building.disable) end
      building = nil
      log.e("mode: one instance failed to start: " .. tostring(c) .. "; using a new window per press")
      hs.alert.show(INSTANCE_FAILED)
    end
  else
    log.i("mode: session (a new window per press)")
  end
  if M.mode == "instance" then
    if cfg.terminal ~= nil then log.w("terminal is only used with mode = \"session\"") end
    if M.config.autoStartFlow then
      log.w("autoStartFlow is only used with mode = \"session\"; press Ctrl-S in the note")
    end
  else
    hs.urlevent.bind("voicevim-submit", function(_, params) M.submit(params) end)
  end
  -- Sessions opened before a reload still cancel through this.
  hs.urlevent.bind("voicevim-cancel", function(_, params)
    local ok, err = pcall(M.cancel, params)
    if not ok then log.e("cancel: " .. tostring(err)) end
  end)
  local press = M.mode == "instance" and M.toggle or M.begin
  -- hammerspoon://voicevim-start does what the hotkey does (Karabiner, a
  -- launcher, or `open -g` from a shell).
  hs.urlevent.bind("voicevim-start", function() press() end)
  if M.hotkeyObj then M.hotkeyObj:delete(); M.hotkeyObj = nil end
  local mods, key = M.config.hotkey[1], M.config.hotkey[2]
  local combo = table.concat(mods, "+") .. "+" .. key
  if isOptionOnly(mods) then
    log.w("hotkey " .. combo .. " is Option-only; macOS 15+ may refuse it")
  end
  local ok, obj = pcall(hs.hotkey.bind, mods, key, press)
  if ok and obj then
    M.hotkeyObj = obj
    log.i("bound " .. combo)
  else
    log.e("failed to bind " .. combo .. ": " .. (ok and "hs.hotkey.bind returned nil" or tostring(obj)))
    hs.alert.show("voice-vim: could not bind " .. combo .. "; use hammerspoon://voicevim-start")
  end
  return M
end

return M
