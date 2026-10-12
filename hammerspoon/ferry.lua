-- ferry: Hammerspoon module.
--
-- One always-running nvim server shown in Neovide. The hotkey toggles it
-- (hammerspoon/instance.lua controller with the hammerspoon/hosts/neovide.lua
-- host): from any app it captures the app and window, then shows the note in
-- insert mode; from the note it keeps the note as a draft, hides Neovide and
-- refocuses that window. The note (lua/ferry/note.lua) sends
-- hammerspoon://ferry-submit, which hides Neovide and then runs M.submit
-- below, or ferry-hide. start() pre-warms the server (an hs.task) so the
-- first press is fast. Without Neovide there is no fallback window: start()
-- alerts once and each press alerts again. When install.sh has built the
-- ~/Applications/ferry.app wrapper, Neovide runs as that app (named
-- "ferry" in the Dock and Cmd-Tab); see hosts/neovide.lua.
--
-- Submit: put the text on the clipboard, focus the target window, wait until
-- it is frontmost, Cmd+V. The delivery logic lives in
-- lua/ferry/delivery.lua (pure, tested).
--
-- Hold to talk: a second hotkey (talkHotkey, default Ctrl+Option+B, or
-- hammerspoon://ferry-talk?state=down|up) calls the controller's
-- talkDown when pressed (start Flow, show the note) and talkUp when
-- released (stop Flow once the note is focused). See instance.lua.
--
-- Browse: a third hotkey (browseHotkey, default Ctrl+Option+N, or
-- hammerspoon://ferry-browse) toggles like the hotkey but shows the notes
-- browser (`ferry-host browse`): the sidebar focused on the newest note.
--
-- Usage in ~/.hammerspoon/init.lua:
--   local ferry = require("ferry")
--   ferry.start()  -- Ctrl+Option+V; pass { hotkey = { mods, key } } to change
--                     -- (talkHotkey and browseHotkey likewise; false turns
--                     -- either off)

local M = {}

M.config = {
  -- Ctrl+Option+V. Option-only combos are unreliable on macOS 15+, and
  -- Cmd+Shift+V clashes with paste-and-match-style.
  hotkey = { { "ctrl", "alt" }, "v" },
  -- Hold to talk: Wispr Flow records into the note while this is held
  -- (key down shows the note and starts Flow, key up stops it). false: off.
  -- Ctrl+Option+B: same hand shape as the hotkey; Ctrl+Option+Space is the
  -- macOS input-source switch.
  talkHotkey = { { "ctrl", "alt" }, "b" },
  -- The notes browser: like the hotkey, but shows the sidebar focused on the
  -- newest note. false: off. Joe's pick (2026-10-12).
  browseHotkey = { { "ctrl", "alt" }, "n" },
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
  -- The nvim server socket (default $FERRY_SOCK, else
  -- ${TMPDIR}/ferry.sock, as bin/ferry-host).
  sock = nil,
  -- The notes folder (FERRY_NOTES_DIR for bin/ferry-host). nil: its own
  -- default (~/notes/scratchpads, or $FERRY_NOTES_DIR).
  notesDir = nil,
  -- The ferry.app wrapper Neovide runs as (built by install.sh). nil:
  -- ~/Applications/ferry.app, used when it is there; false: plain Neovide.
  appPath = nil,
  -- Extra options for hammerspoon/hosts/neovide.lua new() (searchPath,
  -- appPaths, adoptTimeout, commandLine, appPath, appBundleID, appName).
  -- Tests use it.
  neovide = nil,
}

local log = hs.logger.new("ferry", "info")

local function repoRoot()
  if M.config.root then return M.config.root end
  -- Resolve this file's real path (~/.hammerspoon/ferry.lua is a symlink
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
    return dofile(repoRoot() .. "/lua/ferry/delivery.lua")
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

-- Deliver a note: hammerspoon://ferry-submit?file=&target=&window=
-- (sent by lua/ferry/note.lua; instance.lua hides Neovide first).
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
    hs.alert.show("ferry: grant Hammerspoon Accessibility to paste (text copied)")
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

-- "ctrl+alt+v", as configured (for logs and alerts).
local function comboName(mods, key)
  local parts = {}
  for _, m in ipairs(mods or {}) do parts[#parts + 1] = tostring(m) end
  parts[#parts + 1] = tostring(key)
  return table.concat(parts, "+")
end

-- The combo with modifier aliases folded and sorted, so two spellings of
-- the same keys compare equal.
local MOD_ALIASES = {
  option = "alt", ["⌥"] = "alt", control = "ctrl", ["⌃"] = "ctrl",
  command = "cmd", ["⌘"] = "cmd", ["⇧"] = "shift",
}
local function comboKey(mods, key)
  local parts = {}
  for _, m in ipairs(mods or {}) do
    local l = tostring(m):lower()
    parts[#parts + 1] = MOD_ALIASES[l] or l
  end
  table.sort(parts)
  parts[#parts + 1] = tostring(key):lower()
  return table.concat(parts, "+")
end

-- Bind one hotkey: pressed (and released, when given). suffix marks the
-- log and alert lines (" (talk)"); url names the URL to use instead when
-- the bind fails. Returns the hotkey object, or nil.
local function bindHotkey(spec, suffix, url, pressed, released)
  local mods, key = spec[1], spec[2]
  local combo = comboName(mods, key)
  if isOptionOnly(mods) then
    log.w("hotkey " .. combo .. suffix .. " is Option-only; macOS 15+ may refuse it")
  end
  local bok, obj
  if released then
    bok, obj = pcall(hs.hotkey.bind, mods, key, pressed, released)
  else
    bok, obj = pcall(hs.hotkey.bind, mods, key, pressed)
  end
  if bok and obj then
    log.i("bound " .. combo .. suffix)
    return obj
  end
  log.e("failed to bind " .. combo .. suffix .. ": "
    .. (bok and "hs.hotkey.bind returned nil" or tostring(obj)))
  hs.alert.show("ferry: could not bind " .. combo .. suffix .. "; use hammerspoon://" .. url)
  return nil
end

-- Same default as bin/ferry-host.
local function defaultSock()
  local env = os.getenv("FERRY_SOCK")
  if env and env ~= "" then return env end
  local tmp = os.getenv("TMPDIR")
  if not tmp or tmp == "" then tmp = "/tmp" end
  return (tmp:gsub("/$", "")) .. "/ferry.sock"
end

local NO_NEOVIDE = "ferry: Neovide is not installed — run ./install.sh"

-- The controller startInstance() is building; start() disables it if the
-- setup raises after it was made, so it can never show Neovide afterwards.
local building = nil

-- Build the one-instance controller: the Neovide host, the controller with
-- M.submit as its deliver, the ferry-submit / ferry-hide handlers,
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
    rememberFrame = M.config.rememberFrame ~= false, appPath = M.config.appPath,
  }
  for k, v in pairs(M.config.neovide or {}) do hcfg[k] = v end
  local neovide = dofile(root .. "/hammerspoon/hosts/neovide.lua")
  local host = neovide.new(hcfg)
  local ok, why = host.available()
  if not ok then return nil, why end
  -- For alerts, per alert: "Neovide", or "the ferry window" with the
  -- ferry.app wrapper (install.sh may build it while Hammerspoon runs).
  local function hostName()
    local _, appName = host.ident()
    return appName == neovide.NAME and appName or "the ferry window"
  end
  local c = dofile(root .. "/hammerspoon/instance.lua").new({
    host = host, root = root, sock = sock, notesDir = M.config.notesDir,
    captureSelection = M.config.captureSelection == true,
    deliver = function(p) M.submit(p) end,
    hostName = hostName,
  })
  building = c
  c.bindURLs()
  c.prewarm(function(warm)
    if not warm then
      log.w("pre-warm: the ferry server did not start;"
        .. " the next press runs ferry-host ensure again")
    end
  end)
  building = nil
  return c, why
end

-- Run controller method `name`. When start() could not set the instance
-- up, alert again instead (unless quiet), so nothing else runs.
local function callInstance(name, label, quiet)
  local c = M._instance
  if not c then
    local msg = M._unavailable or NO_NEOVIDE
    log.w(label .. ": ferry is not running (" .. msg .. ")")
    if not quiet then hs.alert.show(msg) end
    return
  end
  local ok, err = pcall(c[name])
  if not ok then
    log.e(name .. ": " .. tostring(err))
    hs.alert.show("ferry: error (see console)")
  end
end

-- The hotkey (and hammerspoon://ferry-start): show or hide the one
-- instance.
function M.toggle() callInstance("toggle", "press") end

-- The browse hotkey (and hammerspoon://ferry-browse): show the notes
-- browser, or hide the instance when it is focused.
function M.browse() callInstance("browse", "browse") end

-- hammerspoon://ferry-edit (bin/ferry-edit, which has already opened its
-- file in the server): show ferry over the terminal without touching the
-- note.
function M.showEdit() callInstance("showEdit", "edit") end

-- The talk hotkey pressed (hammerspoon://ferry-talk?state=down): start
-- Flow and show the note. Without an instance: the same alert as toggle,
-- and Flow is never started.
function M.talkDown() callInstance("talkDown", "talk down") end

-- The talk hotkey released (state=up): stop Flow once the note is focused.
-- Without an instance talkDown has already alerted.
function M.talkUp() callInstance("talkUp", "talk up", true) end

-- hammerspoon://ferry-talk?state=down|up (Karabiner, or anything that
-- can send key down and key up separately).
local function onTalkURL(_, params)
  local state = params and params.state
  if state == "down" then
    M.talkDown()
  elseif state == "up" then
    M.talkUp()
  else
    log.w("ferry-talk: state=" .. tostring(state) .. " ignored; use state=down or state=up")
  end
end

-- Config keys of the removed new-window-per-press path, and older ones:
-- each logs a warning and is ignored.
local OBSOLETE = {
  { "activateDelay", "activateDelay is no longer used; set confirmTimeout instead" },
  { "windowTitle", "windowTitle is no longer used" },
  { "terminal", "terminal is no longer used; ferry always runs in Neovide" },
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
        .. " ferry always runs one instance in Neovide")
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
    log.e("mode: Neovide not found (" .. tostring(why) .. "); ferry cannot run."
      .. " Run ./install.sh (brew install --cask neovide-app)")
    hs.alert.show(M._unavailable)
  else
    -- Half-built controller: drop its pending show and URL handlers.
    if building then pcall(building.disable) end
    building = nil
    M._unavailable = "ferry: setup failed (see console): " .. tostring(c)
    log.e("mode: one instance failed to start: " .. tostring(c))
    hs.alert.show(M._unavailable)
  end
  -- hammerspoon://ferry-start does what the hotkey does (Karabiner, a
  -- launcher, or `open -g` from a shell).
  hs.urlevent.bind("ferry-start", function() M.toggle() end)
  hs.urlevent.bind("ferry-talk", onTalkURL)
  hs.urlevent.bind("ferry-edit", function() M.showEdit() end)
  hs.urlevent.bind("ferry-browse", function() M.browse() end)
  if M.hotkeyObj then M.hotkeyObj:delete(); M.hotkeyObj = nil end
  if M.talkHotkeyObj then M.talkHotkeyObj:delete(); M.talkHotkeyObj = nil end
  if M.browseHotkeyObj then M.browseHotkeyObj:delete(); M.browseHotkeyObj = nil end
  M.hotkeyObj = bindHotkey(M.config.hotkey, "", "ferry-start", M.toggle)
  local hk = M.config.hotkey
  -- The same keys as an earlier configured hotkey: an error, not bound.
  -- others: { {name, spec}, ... }. Returns true when it clashes.
  local function clashes(label, key, spec, others)
    for _, o in ipairs(others) do
      local name, other = o[1], o[2]
      if other and comboKey(spec[1], spec[2]) == comboKey(other[1], other[2]) then
        local combo = comboName(spec[1], spec[2])
        log.e(label .. " hotkey " .. combo .. " is the same as the " .. name .. "; not bound")
        hs.alert.show("ferry: " .. key .. " " .. combo .. " is the same as the " .. name .. "; not bound")
        return true
      end
    end
    return false
  end
  local talk = M.config.talkHotkey
  if not talk then
    log.i("talk hotkey off")
  elseif not clashes("talk", "talkHotkey", talk, { { "hotkey", hk } }) then
    -- Pressed and released; no repeat function, so holding does nothing more.
    M.talkHotkeyObj = bindHotkey(talk, " (talk)", "ferry-talk?state=down|up", M.talkDown, M.talkUp)
  end
  local browse = M.config.browseHotkey
  if not browse then
    log.i("browse hotkey off")
  elseif not clashes("browse", "browseHotkey", browse, { { "hotkey", hk }, { "talkHotkey", talk } }) then
    M.browseHotkeyObj = bindHotkey(browse, " (browse)", "ferry-browse", M.browse)
  end
  return M
end

return M
