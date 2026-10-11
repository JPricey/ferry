-- voice-vim: Hammerspoon module.
--
-- Hotkey -> capture frontmost app, focused window and selection -> open a
-- Ghostty window running Neovim on a temp file -> (shell wrapper runs the
-- editor) -> hammerspoon://voicevim-submit callback -> put the text on the
-- clipboard, focus the target window, wait until it is frontmost, Cmd+V.
-- The delivery logic lives in lua/voice-vim/delivery.lua (pure, tested).
--
-- Usage in ~/.hammerspoon/init.lua:
--   local voicevim = require("voice-vim")
--   voicevim.start({ hotkey = { { "alt" }, "v" } })

local M = {}

M.config = {
  hotkey = { { "alt" }, "v" },
  -- Repo root; set by install.sh via the symlinked module path, or override.
  root = nil,
  -- Copy the current selection into the buffer and replace it on submit.
  captureSelection = true,
  -- Start a Flow hands-free dictation as soon as the editor opens.
  autoStartFlow = false,
  -- Terminal to open the editor in: "ghostty" (default) or "iTerm2".
  terminal = "ghostty",
  -- Window title for the Ghostty session window.
  windowTitle = "voice-vim",
  -- Seconds to wait for the target window to be confirmed frontmost before
  -- giving up on the paste (the text then stays on the clipboard).
  confirmTimeout = 1.0,
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

-- Launch a terminal window running argv (a list of strings).
local function openTerminal(argv)
  local term = M.config.terminal
  local cmdline = shjoin(argv)
  local script
  if term == "ghostty" then
    -- Ghostty 1.3+ exposes an AppleScript dictionary. `new window with
    -- configuration` runs our command in a fresh window of the already
    -- running instance and closes the window when the command exits.
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
  elseif term == "iTerm2" then
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
  end
  return ok
end

-- Id of the focused window, or nil.
local function focusedWindowId()
  local win = hs.window.focusedWindow()
  local id = win and win:id() or nil
  return id
end

function M.begin()
  local app = hs.application.frontmostApplication()
  local target = app and app:bundleID() or ""
  local winId = focusedWindowId()
  local sel = ""
  if M.config.captureSelection and app then sel = grabSelection(app) end

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
  log.i("begin: target=" .. target .. " window=" .. tostring(winId) .. " file=" .. file)
  openTerminal(argv)
end

-- Load the pure delivery core from the repo. Returns the module or nil.
local function loadDelivery()
  local ok, mod = pcall(dofile, repoRoot() .. "/lua/voice-vim/delivery.lua")
  if ok and type(mod) == "table" then return mod end
  log.e("submit: cannot load delivery.lua: " .. tostring(mod))
  return nil
end

-- Timers from hs.timer.doAfter are kept referenced until they fire so they
-- cannot be garbage collected first.
local pending = {}

-- The env table delivery.lua runs against, built from the real hs APIs.
local function deliveryEnv()
  local env = {}
  env.now = function() return hs.timer.secondsSinceEpoch() end
  env.after = function(sec, fn)
    local t
    t = hs.timer.doAfter(sec, function()
      if t then pending[t] = nil end
      fn()
    end)
    if t then pending[t] = true end
  end
  env.frontmost = function()
    local app = hs.application.frontmostApplication()
    local win = hs.window.focusedWindow()
    return { bundle = app and app:bundleID() or nil, windowId = win and win:id() or nil }
  end
  env.windowExists = function(id) return id ~= nil and hs.window.get(id) ~= nil end
  env.focus = function(target)
    local win = target.windowId and hs.window.get(target.windowId) or nil
    if win then
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
-- hammerspoon://voicevim-submit?file=&target=&window=
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
    hs.pasteboard.setContents(text)
    hs.alert.show("copied — paste manually")
    return
  end

  delivery.deliver(deliveryEnv(), {
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

function M.start(cfg)
  for k, v in pairs(cfg or {}) do M.config[k] = v end
  if M.config.activateDelay ~= nil then
    -- Old key: submit now waits until the target is frontmost.
    log.w("activateDelay is no longer used; set confirmTimeout instead")
    M.config.activateDelay = nil
  end
  hs.urlevent.bind("voicevim-submit", function(_, params) M.submit(params) end)
  -- hammerspoon://voicevim-start starts a session without the hotkey
  -- (Karabiner, a launcher, or `open -g` from a shell).
  hs.urlevent.bind("voicevim-start", function() M.begin() end)
  if M.hotkeyObj then M.hotkeyObj:delete(); M.hotkeyObj = nil end
  local mods, key = M.config.hotkey[1], M.config.hotkey[2]
  local combo = table.concat(mods, "+") .. "+" .. key
  if isOptionOnly(mods) then
    log.w("hotkey " .. combo .. " is Option-only; macOS 15+ may refuse it")
  end
  local ok, obj = pcall(hs.hotkey.bind, mods, key, M.begin)
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
