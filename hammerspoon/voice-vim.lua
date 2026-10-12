-- voice-vim: Hammerspoon module.
--
-- One always-running nvim server shown in Neovide. The hotkey toggles it
-- (hammerspoon/instance.lua controller with the hammerspoon/hosts/neovide.lua
-- host): from any app it captures the app and window, then shows the note in
-- insert mode; from the note it keeps the note as a draft, hides Neovide and
-- refocuses that window. The note (lua/voice-vim/note.lua) sends
-- hammerspoon://voicevim-submit, which hides Neovide and then runs M.submit
-- below, or voicevim-hide. start() pre-warms the server (an hs.task) so the
-- first press is fast. Without Neovide there is no fallback window: start()
-- alerts once and each press alerts again.
--
-- Submit: put the text on the clipboard, focus the target window, wait until
-- it is frontmost, Cmd+V. The delivery logic lives in
-- lua/voice-vim/delivery.lua (pure, tested).
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
  -- Copy the current selection into a new note before showing it. Off by
  -- default: the Cmd+C costs up to 0.4 s per press.
  captureSelection = false,
  -- Seconds to wait for the target window to be confirmed frontmost before
  -- giving up on the paste (the text then stays on the clipboard).
  confirmTimeout = 1.0,
  -- Open the Neovide window where it was last left, at the size it was left
  -- (hammerspoon/window-frame.lua). false leaves the frame to Neovide.
  rememberFrame = true,
  -- First-open size, as a fraction of the main screen's width and height.
  windowSize = 0.5,
  -- The nvim server socket (default $VOICE_VIM_SOCK, else
  -- ${TMPDIR}/voice-vim.sock, as bin/voice-vim-host).
  sock = nil,
  -- Extra options for hammerspoon/hosts/neovide.lua new() (searchPath,
  -- appPaths, adoptTimeout, commandLine). Tests use it.
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

-- Deliver a note: hammerspoon://voicevim-submit?file=&target=&window=
-- (sent by lua/voice-vim/note.lua; instance.lua hides Neovide first).
function M.submit(params)
  params = params or {}
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

local NO_NEOVIDE = "voice-vim: Neovide is not installed — run ./install.sh"

-- The controller startInstance() is building; start() disables it if the
-- setup raises after it was made, so it can never show Neovide afterwards.
local building = nil

-- Build the one-instance controller: the Neovide host, the controller with
-- M.submit as its deliver, the voicevim-submit / voicevim-hide handlers,
-- and the server pre-warm. Returns the controller and why, or nil and why
-- (Neovide not found). May raise (start() pcalls it).
--
-- Decided here, synchronously, from what is known now: Neovide installed
-- and this setup done. The pre-warm's outcome never changes it: a failed or
-- slow pre-warm leaves the instance in place, and the next press runs
-- ensure again (instance.lua's recovery), alerting if that fails too.
local function startInstance()
  local root = repoRoot()
  local sock = M.config.sock or defaultSock()
  local hcfg = {
    log = log, sock = sock, root = root, fraction = M.config.windowSize,
    rememberFrame = M.config.rememberFrame ~= false,
  }
  for k, v in pairs(M.config.neovide or {}) do hcfg[k] = v end
  local neovide = dofile(root .. "/hammerspoon/hosts/neovide.lua")
  local host = neovide.new(hcfg)
  local ok, why = host.available()
  if not ok then return nil, why end
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
      log.w("pre-warm: the voice-vim server did not start;"
        .. " the next press runs voice-vim-host ensure again")
    end
  end)
  building = nil
  return c, why
end

-- The hotkey (and hammerspoon://voicevim-start): show or hide the one
-- instance. When start() could not set it up, alert again instead.
function M.toggle()
  local c = M._instance
  if not c then
    local msg = M._unavailable or NO_NEOVIDE
    log.w("press: voice-vim is not running (" .. msg .. ")")
    hs.alert.show(msg)
    return
  end
  local ok, err = pcall(c.toggle)
  if not ok then
    log.e("toggle: " .. tostring(err))
    hs.alert.show("voice-vim: error (see console)")
  end
end

-- Config keys of the removed new-window-per-press path, and older ones:
-- each logs a warning and is ignored.
local OBSOLETE = {
  { "activateDelay", "activateDelay is no longer used; set confirmTimeout instead" },
  { "windowTitle", "windowTitle is no longer used" },
  { "terminal", "terminal is no longer used; voice-vim always runs in Neovide" },
  { "autoStartFlow", "autoStartFlow is no longer used; press Ctrl-S in the note" },
}

function M.start(cfg)
  cfg = cfg or {}
  for k, v in pairs(cfg) do M.config[k] = v end
  for _, o in ipairs(OBSOLETE) do
    if M.config[o[1]] ~= nil then
      log.w(o[2])
      M.config[o[1]] = nil
    end
  end
  if M.config.mode ~= nil then
    if M.config.mode ~= "instance" then
      log.w("mode = " .. tostring(M.config.mode) .. " is no longer used;"
        .. " voice-vim always runs one instance in Neovide")
    end
    M.config.mode = nil
  end

  -- Set up the one instance, once and synchronously. A controller from an
  -- earlier start() is switched off first. Without Neovide, or when the
  -- setup raises, there is no fallback: one alert now, and each press
  -- alerts again.
  if M._instance then pcall(M._instance.disable) end
  M._instance, M.mode, M._unavailable = nil, "unavailable", nil
  building = nil
  local ok, c, why = pcall(startInstance)
  if ok and c then
    M._instance, M.mode = c, "instance"
    log.i("mode: one instance in Neovide (" .. tostring(why) .. ")")
  elseif ok then
    M._unavailable = NO_NEOVIDE
    log.e("mode: Neovide not found (" .. tostring(why) .. "); voice-vim cannot run."
      .. " Run ./install.sh (brew install --cask neovide-app)")
    hs.alert.show(M._unavailable)
  else
    -- Half-built controller: drop its pending show and URL handlers.
    if building then pcall(building.disable) end
    building = nil
    M._unavailable = "voice-vim: setup failed (see console): " .. tostring(c)
    log.e("mode: one instance failed to start: " .. tostring(c))
    hs.alert.show(M._unavailable)
  end
  -- hammerspoon://voicevim-start does what the hotkey does (Karabiner, a
  -- launcher, or `open -g` from a shell).
  hs.urlevent.bind("voicevim-start", function() M.toggle() end)
  if M.hotkeyObj then M.hotkeyObj:delete(); M.hotkeyObj = nil end
  local mods, key = M.config.hotkey[1], M.config.hotkey[2]
  local combo = table.concat(mods, "+") .. "+" .. key
  if isOptionOnly(mods) then
    log.w("hotkey " .. combo .. " is Option-only; macOS 15+ may refuse it")
  end
  local bok, obj = pcall(hs.hotkey.bind, mods, key, M.toggle)
  if bok and obj then
    M.hotkeyObj = obj
    log.i("bound " .. combo)
  else
    log.e("failed to bind " .. combo .. ": " .. (bok and "hs.hotkey.bind returned nil" or tostring(obj)))
    hs.alert.show("voice-vim: could not bind " .. combo .. "; use hammerspoon://voicevim-start")
  end
  return M
end

return M
