-- Tests for lua/ferry/delivery.lua with a fake env and a manual clock.
-- Run: luajit tests/delivery_spec.lua  (or nvim -l tests/delivery_spec.lua)
local here = debug.getinfo(1, "S").source:sub(2):match("^(.*)/[^/]+$") or "."
local D = dofile(here .. "/../lua/ferry/delivery.lua")

local fail = 0
local function check(name, want, got)
  if want == got then
    print("ok   " .. name)
  else
    print("FAIL " .. name .. ": want '" .. tostring(want) .. "' got '" .. tostring(got) .. "'")
    fail = 1
  end
end

-- Fake env. `fronts` is a list of frontmost results, one per poll; the last
-- one repeats. `windows` is the set of window ids that still exist.
local function fakeEnv(o)
  local e = { t = 0, queue = {}, seq = 0, logs = {}, alerts = {}, pastes = 0,
              clip = o.clip, focused = nil, polls = 0 }
  e.now = function() return e.t end
  e.after = function(sec, fn)
    e.seq = e.seq + 1
    e.queue[#e.queue + 1] = { at = e.t + sec, seq = e.seq, fn = fn }
  end
  e.frontmost = function()
    e.polls = e.polls + 1
    return o.fronts[math.min(e.polls, #o.fronts)]
  end
  e.focus = function(target) e.focused = target end
  e.getClipboard = function() return e.clip end
  e.setClipboard = function(s) e.clip = s end
  e.postPaste = function() e.pastes = e.pastes + 1; e.pasteClip = e.clip; e.pasteT = e.t end
  e.alert = function(msg) e.alerts[#e.alerts + 1] = msg end
  e.log = function(msg) e.logs[#e.logs + 1] = msg end
  e.windowExists = function(id) return (o.windows or {})[id] == true end
  -- Run scheduled callbacks in time order until the queue is empty.
  e.run = function()
    while #e.queue > 0 do
      table.sort(e.queue, function(a, b)
        if a.at ~= b.at then return a.at < b.at end
        return a.seq < b.seq
      end)
      local job = table.remove(e.queue, 1)
      e.t = job.at
      job.fn()
    end
  end
  return e
end

-- Index of the first log line containing pat (plain), or nil.
local function logAt(e, pat, from)
  for i = from or 1, #e.logs do
    if e.logs[i]:find(pat, 1, true) then return i end
  end
end

local function inOrder(e, pats)
  local pos = 0
  for _, p in ipairs(pats) do
    local i = logAt(e, p, pos + 1)
    if not i then return "missing '" .. p .. "'" end
    pos = i
  end
  return "in order"
end

local SLACK = "com.tinyspeck.slackmacgap"
local OTHER = "com.mitchellh.ghostty"

-- 1. Confirmed on the 3rd poll: one paste after the default settle (0.05 s),
--    steps logged in order.
do
  local e = fakeEnv({ clip = "old", windows = { [7] = true }, fronts = {
    { bundle = OTHER, windowId = 1 }, { bundle = OTHER, windowId = 1 }, { bundle = SLACK, windowId = 7 } } })
  local result
  D.deliver(e, { text = "hello", bundle = SLACK, windowId = 7 }, { onDone = function(r) result = r end })
  e.run()
  check("confirmed on 3rd poll: result", "delivered", result)
  check("confirmed on 3rd poll: 3 polls + 1 settle re-check", 4, e.polls)
  check("confirmed on 3rd poll: one paste", 1, e.pastes)
  check("confirmed on 3rd poll: clipboard held text at paste", "hello", e.pasteClip)
  check("confirmed on 3rd poll: focused target", 7, e.focused and e.focused.windowId)
  check("confirmed on 3rd poll: steps logged in order", "in order", inOrder(e, {
    "deliver: start", "clipboard set", "focus requested", "poll 1", "poll 2", "poll 3",
    "matched, settling 0.05s", "still frontmost after settle", "paste posted", "delivered" }))
  check("confirmed on 3rd poll: no alert", 0, #e.alerts)
  check("confirmed on 3rd poll: paste at match time (0.10) + settle", "0.15", string.format("%.2f", e.pasteT))
end

-- 1b. Custom settle: paste at match time + settle, nothing before it.
do
  local e = fakeEnv({ fronts = { { bundle = OTHER }, { bundle = SLACK } } })
  D.deliver(e, { text = "hi", bundle = SLACK }, { settle = 0.2 })
  local pastedEarly = e.pastes > 0
  e.run()
  check("settle 0.2: no paste before settle elapses", false, pastedEarly)
  check("settle 0.2: one paste", 1, e.pastes)
  check("settle 0.2: paste at match (0.05) + 0.2", "0.25", string.format("%.2f", e.pasteT))
end

-- 1c. Match lost during settle: keeps polling, pastes on the next stable match.
do
  local e = fakeEnv({ fronts = {
    { bundle = SLACK }, -- poll 1 matches
    { bundle = OTHER }, -- settle re-check: lost
    { bundle = OTHER }, -- poll 2
    { bundle = SLACK }, -- poll 3 matches
    { bundle = SLACK }, -- settle re-check: still there
  } })
  local result
  D.deliver(e, { text = "hi", bundle = SLACK }, { onDone = function(r) result = r end })
  e.run()
  check("lost during settle: delivered", "delivered", result)
  check("lost during settle: one paste", 1, e.pastes)
  check("lost during settle: logged", true, logAt(e, "match lost during settle") ~= nil)
  check("lost during settle: polled again", true, logAt(e, "poll 3") ~= nil)
  check("lost during settle: 5 frontmost checks", 5, e.polls)
  -- poll1 t=0, lost at 0.05, poll2 0.10, poll3 0.15, paste at 0.20.
  check("lost during settle: paste at t=0.20", "0.20", string.format("%.2f", e.pasteT))
end

-- 1d. Match always lost during settle: never pastes, gives up at the timeout.
do
  local fronts = {}
  for i = 1, 60 do fronts[i] = { bundle = (i % 2 == 1) and SLACK or OTHER } end
  local e = fakeEnv({ fronts = fronts })
  local result
  D.deliver(e, { text = "hi", bundle = SLACK }, { onDone = function(r) result = r end })
  e.run()
  check("always lost during settle: unconfirmed", "unconfirmed", result)
  check("always lost during settle: no paste", 0, e.pastes)
  check("always lost during settle: alert", D.UNCONFIRMED_ALERT, e.alerts[1])
end

-- 1e. settle = 0: paste at once on the first match, no re-check.
do
  local e = fakeEnv({ fronts = { { bundle = SLACK } } })
  local result
  D.deliver(e, { text = "hi", bundle = SLACK }, { settle = 0, onDone = function(r) result = r end })
  check("settle 0: delivered synchronously", "delivered", result)
  check("settle 0: one paste", 1, e.pastes)
  check("settle 0: one frontmost check", 1, e.polls)
  check("settle 0: paste at t=0", "0.00", string.format("%.2f", e.pasteT))
  check("settle 0: no settle log", nil, logAt(e, "settling"))
end

-- 2. Timeout: never frontmost -> no paste, alert, clipboard keeps text.
do
  local e = fakeEnv({ clip = "old", fronts = { { bundle = OTHER, windowId = 1 } } })
  local result
  D.deliver(e, { text = "hello", bundle = SLACK }, { onDone = function(r) result = r end })
  e.run()
  check("timeout: result", "unconfirmed", result)
  check("timeout: no paste", 0, e.pastes)
  check("timeout: alert", D.UNCONFIRMED_ALERT, e.alerts[1])
  check("timeout: alert text", "copied — paste manually", e.alerts[1])
  check("timeout: clipboard keeps text", "hello", e.clip)
  check("timeout: polled until 1.0 s (21 polls)", 21, e.polls)
  check("timeout: gave up at t=1.00", "1.00", string.format("%.2f", e.t))
  check("timeout: logged unconfirmed", true, logAt(e, "unconfirmed") ~= nil)
end

-- 3. Same bundle but another window of it, captured window exists -> times out.
do
  local e = fakeEnv({ clip = "old", windows = { [7] = true, [8] = true },
    fronts = { { bundle = SLACK, windowId = 8 } } })
  local result
  D.deliver(e, { text = "hi", bundle = SLACK, windowId = 7 },
    { interval = 0.1, timeout = 0.5, onDone = function(r) result = r end })
  e.run()
  check("same bundle other window: unconfirmed", "unconfirmed", result)
  check("same bundle other window: no paste", 0, e.pastes)
  check("same bundle other window: opts override (6 polls)", 6, e.polls)
end

-- 4. No window id captured -> bundle match.
do
  local e = fakeEnv({ clip = "old", fronts = { { bundle = SLACK, windowId = 99 } } })
  local result
  D.deliver(e, { text = "hi", bundle = SLACK }, { onDone = function(r) result = r end })
  e.run()
  check("no window id: bundle match delivers", "delivered", result)
  check("no window id: one paste", 1, e.pastes)
  check("no window id: clipboard not restored by default", "hi", e.clip)
end

-- 4b. Captured window has closed -> fall back to bundle match.
do
  local e = fakeEnv({ clip = "old", windows = {}, fronts = { { bundle = SLACK, windowId = 3 } } })
  local result
  D.deliver(e, { text = "hi", bundle = SLACK, windowId = 7 }, { onDone = function(r) result = r end })
  e.run()
  check("closed window: falls back to bundle", "delivered", result)
end

-- 5. restoreClipboard restores the old clipboard after the paste.
do
  local e = fakeEnv({ clip = "old", fronts = { { bundle = SLACK } } })
  D.deliver(e, { text = "hi", bundle = SLACK }, { restoreClipboard = true })
  e.run()
  check("restoreClipboard: text on clipboard at paste", "hi", e.pasteClip)
  check("restoreClipboard: restores old clipboard", "old", e.clip)
  check("restoreClipboard: logged", true, logAt(e, "clipboard restored") ~= nil)
end

-- 6. Empty text does nothing.
do
  local e = fakeEnv({ clip = "old", fronts = { { bundle = SLACK } } })
  local result
  D.deliver(e, { text = "", bundle = SLACK }, { onDone = function(r) result = r end })
  e.run()
  check("empty text: no paste, clipboard untouched", "empty 0 old", result .. " " .. e.pastes .. " " .. e.clip)
end

-- 7. isOptionOnly.
check("isOptionOnly({\"alt\"})", true, D.isOptionOnly({ "alt" }))
check("isOptionOnly({\"ctrl\",\"alt\"})", false, D.isOptionOnly({ "ctrl", "alt" }))
check("isOptionOnly({\"option\"})", true, D.isOptionOnly({ "option" }))
check("isOptionOnly({})", false, D.isOptionOnly({}))
check("isOptionOnly({\"cmd\"})", false, D.isOptionOnly({ "cmd" }))

os.exit(fail)
