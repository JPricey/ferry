-- voice-vim: Hammerspoon module.
--
-- Hotkey -> capture frontmost app and selection -> open a Ghostty window
-- running Neovim on a temp file -> (shell wrapper runs the editor) ->
-- hammerspoon://voicevim-submit callback -> paste result into the target app.
--
-- Usage in ~/.hammerspoon/init.lua:
--   local voicevim = require("voice-vim")
--   voicevim.start({ hotkey = { { "cmd", "alt" }, "v" } })

local M = {}

M.config = {
  hotkey = { { "cmd", "alt" }, "v" },
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
  -- Seconds to wait for the target app to come back to front before pasting.
  activateDelay = 0.25,
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

function M.begin()
  local app = hs.application.frontmostApplication()
  local target = app and app:bundleID() or ""
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
  log.i("target=" .. target .. " file=" .. file)
  openTerminal(argv)
end

-- Callback from bin/voice-vim-session: hammerspoon://voicevim-submit?file=&target=
function M.submit(params)
  local file, target = params.file, params.target or ""
  local f = file and io.open(file, "r")
  if not f then log.e("submit: cannot read " .. tostring(file)); return end
  local text = f:read("a")
  f:close()
  os.remove(file)
  -- Drop a single trailing newline that :w always adds.
  text = text:gsub("\n$", "")
  if text == "" then return end

  local saved = hs.pasteboard.getContents()
  hs.pasteboard.setContents(text)

  local app = target ~= "" and hs.application.get(target) or nil
  if app then app:activate() end

  hs.timer.doAfter(M.config.activateDelay, function()
    hs.eventtap.keyStroke({ "cmd" }, "v", 0, app)
    hs.timer.doAfter(0.3, function()
      if saved then hs.pasteboard.setContents(saved) end
    end)
  end)
end

function M.start(cfg)
  for k, v in pairs(cfg or {}) do M.config[k] = v end
  hs.urlevent.bind("voicevim-submit", function(_, params) M.submit(params) end)
  if M.hotkeyObj then M.hotkeyObj:delete() end
  local mods, key = M.config.hotkey[1], M.config.hotkey[2]
  M.hotkeyObj = hs.hotkey.bind(mods, key, M.begin)
  log.i("bound " .. table.concat(mods, "+") .. "+" .. key)
  return M
end

return M
