-- Pure delivery core: put text on the clipboard, focus the target, wait
-- until it is confirmed frontmost, then paste once.
--
-- No hs or vim globals. Every effect comes in through `env`, so the logic
-- runs under LuaJIT tests with a fake clock and under Hammerspoon (Lua 5.4,
-- loaded with dofile) with real effects.
--
-- env fields:
--   now()                -> seconds (number)
--   after(sec, fn)       run fn after sec seconds
--   frontmost()          -> { bundle = "...", windowId = n } (either may be nil)
--   focus(target)        activate target ({ bundle, windowId })
--   getClipboard()       -> string or nil
--   setClipboard(text)
--   postPaste()          post Cmd+V to whatever is frontmost
--   alert(msg)
--   log(msg)
--   windowExists(id)     -> true if the window id still exists

local M = {}

M.defaults = {
  interval = 0.05, -- seconds between frontmost polls
  timeout = 1.0, -- give up after this many seconds
  restoreClipboard = false, -- restore the old clipboard after a paste
  restoreDelay = 0.3, -- seconds after the paste before restoring
}

M.UNCONFIRMED_ALERT = "copied — paste manually"

local OPTION_NAMES = { alt = true, option = true, opt = true, ["⌥"] = true }

-- True when the modifier list is Option alone (for example { "alt" }).
function M.isOptionOnly(mods)
  if type(mods) ~= "table" or #mods == 0 then return false end
  for _, m in ipairs(mods) do
    if not OPTION_NAMES[string.lower(tostring(m))] then return false end
  end
  return true
end

local function describe(t)
  return "bundle=" .. tostring(t.bundle) .. " window=" .. tostring(t.windowId)
end

-- Whether the frontmost app/window is the target. Match the window id when
-- one was captured and that window still exists; otherwise the bundle id.
function M.matches(env, target, front)
  if not front then return false end
  if target.windowId ~= nil and env.windowExists(target.windowId) then
    return front.windowId == target.windowId
  end
  return target.bundle ~= nil and front.bundle == target.bundle
end

-- deliver(env, { text, bundle, windowId }, opts)
-- opts: interval, timeout, restoreClipboard, restoreDelay,
--       onDone(result) with result "delivered" | "unconfirmed" | "empty".
function M.deliver(env, target, opts)
  opts = opts or {}
  local interval = opts.interval or M.defaults.interval
  local timeout = opts.timeout or M.defaults.timeout
  local restore = opts.restoreClipboard or M.defaults.restoreClipboard
  local restoreDelay = opts.restoreDelay or M.defaults.restoreDelay
  local onDone = opts.onDone or function() end
  local text = target.text or ""

  env.log("deliver: start bytes=" .. #text .. " " .. describe(target))
  if text == "" then
    env.log("deliver: empty text, nothing to do")
    onDone("empty")
    return
  end

  local saved
  if restore then saved = env.getClipboard() end
  env.setClipboard(text)
  env.log("deliver: clipboard set")

  local function unconfirmed(why)
    env.log("deliver: unconfirmed (" .. why .. "), text left on clipboard")
    env.alert(M.UNCONFIRMED_ALERT)
    onDone("unconfirmed")
  end

  if target.bundle == nil and target.windowId == nil then
    unconfirmed("no target")
    return
  end

  env.focus(target)
  env.log("deliver: focus requested")

  local start = env.now()
  local polls = 0
  local function poll()
    polls = polls + 1
    local front = env.frontmost()
    local elapsed = env.now() - start
    env.log(string.format("deliver: poll %d t=%.2f frontmost %s", polls, elapsed, describe(front or {})))
    if M.matches(env, target, front) then
      env.postPaste()
      env.log("deliver: paste posted")
      env.log("deliver: delivered after " .. polls .. " polls")
      if restore then
        env.after(restoreDelay, function()
          if saved ~= nil then env.setClipboard(saved) end
          env.log("deliver: clipboard restored")
        end)
      end
      onDone("delivered")
      return
    end
    -- Small epsilon so float accumulation in the clock does not add a poll.
    if elapsed + interval > timeout + 1e-9 then
      unconfirmed("target not frontmost after " .. polls .. " polls")
      return
    end
    env.after(interval, poll)
  end
  poll()
end

return M
