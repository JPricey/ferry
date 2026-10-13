-- Wispr Flow hands-free toggle for a ferry buffer.
--
-- start()/stop() open wispr-flow://start-hands-free / stop-hands-free with
-- `open -g` (through M.open, which tests swap or shadow with a fake `open`).
-- The recording flag is module-level: one nvim, one Flow.
--
-- Flow can also be stopped with its own shortcut, which we never hear about.
-- Flow inserts with Cmd+V, which reaches terminal nvim as a bracketed paste,
-- i.e. a vim.paste call. attach(buf) wraps vim.paste (once) so a paste into
-- an attached buffer calls on_paste(buf): Flow stopped and pasted, so the
-- flag clears. Typing, Enter, `o` and `u` are not pastes. GUI paste mappings
-- (Neovide <D-v>) call on_paste(buf) themselves.
--
-- finish_then(buf, fn) runs fn once Flow's last paste has landed: at once
-- when idle; otherwise it sends stop and polls changedtick on a timer (never
-- blocking the UI) until a paste is signalled, the buffer changed and stayed
-- quiet settle_ms, or paste_timeout_ms passed. A second call while waiting
-- takes over that wait: its fn replaces the pending one and still runs only
-- after the paste (or the timeout), so a cancel pressed during a hide's wait
-- can never let Flow's paste land in the target (GROUND_TRUTHS req. 8).
-- There is no "press again to skip the wait"; the wait ends by itself
-- within paste_timeout_ms.
--
-- Hold to talk: Hammerspoon starts Flow itself, then adopt_start() tells us
-- a recording is in progress (no URL, unless our own links are in flight).
-- release(buf) is the key-up stop: a finish_then with nothing to run
-- (waiting.kind = "release"), so a Submit/Cancel right after takes it over
-- and still waits for Flow's paste.
--
-- A quick second hold can start (adopt_start) while the first release still
-- waits for its paste. A paste during a wait belongs to that wait, so it
-- never clears the new recording; a release (or finish_then) during the wait
-- while recording again sends the second stop at once and makes the same
-- wait also wait for that recording's paste (w.more). Two hooks reporting
-- one paste (a live module reload) count once: pastes are told apart by the
-- buffer's changedtick.
--
-- An adopted recording (talk key held) ends only by our own stop: a paste
-- with no wait running (a late paste from an earlier hold, or a Cmd+V into
-- the note) leaves it recording, so key up and a Submit still stop Flow.
--
-- stopped(): the latest adopted recording was ended by our own stop and its
-- paste arrived (a Submit, Cancel or Hide wait, or a release, that finished
-- on a paste; or, with no wait, a paste after a Ctrl-S stop). Key up treats
-- it as done, so a Submit that finished while the talk key was held gives
-- no "still recording" alert. A stray paste never sets it (no stop of ours
-- was due), nor does a wait that timed out or whose buffer was wiped (nor
-- a paste after such a wait); adopt_start, start and assume_recording
-- clear it.
local M = {}

-- Bumped when note.lua needs functions an older flow lacks; note.lua
-- reloads a stale flow module in a running server (keeping M.state).
-- api 6: a timed-out or wiped wait forgets its stop (stop_gen), and
-- notices are one screen line (ferry.notice).
-- api 7: on_paste records the paste's lines as b:ferry_paste (fixup's
-- default range).
-- api 8: the record is an extmark (M.PASTE_NS, id 1) that moves with edits
-- above it; on_paste(buf, first) takes a streamed paste's first line and
-- never records from the command line.
M.api = 8

-- The paste record's namespace; fixup.lua reads it by the same name.
M.PASTE_NS = "ferry_paste"

M.paste_timeout_ms = 4000
M.settle_ms = 150
M.poll_ms = 50
-- An `open` that hangs is killed after this, so the queue moves on.
M.open_timeout_ms = 5000

M.START_URL = "wispr-flow://start-hands-free"
M.STOP_URL = "wispr-flow://stop-hands-free"
M.NO_DICTATION = "ferry: no dictation arrived"

-- recording: Flow was started by us (or assumed) and has not pasted yet.
-- adopted: that recording was started outside (adopt_start); only stop()
-- clears it, never a stray paste.
-- waiting: the pending finish_then, { timer = uv timer, buf, fn = action,
-- pasted = fn, kind = "finish" | "release", more = pastes still due after
-- the next one (a recording stopped during this wait) } or nil.
-- gen counts adopt_start calls; stop_gen is the gen of the adopted
-- recording our last stop ended (nil once its paste arrived); stopped is
-- true once that paste arrived (see stopped()). A state from an older
-- module (live reload) lacks them: nil reads as none.
M.state = { recording = false, adopted = false, waiting = nil, gen = 0, stop_gen = nil, stopped = false }
local attached = {}
local function say(msg, level) require("ferry.notice").notify(msg, level) end

-- One `open` at a time, in call order, so a quick start/stop pair cannot
-- reach Flow as stop/start.
local queue, busy = {}, false
local function run_next()
  local url = table.remove(queue, 1)
  if not url then busy = false; return end
  busy = true
  local ok, err = pcall(vim.system, { "open", "-g", url }, { timeout = M.open_timeout_ms }, function(obj)
    vim.schedule(function()
      if obj.code ~= 0 then say("ferry: could not open " .. url, vim.log.levels.WARN) end
      run_next()
    end)
  end)
  if not ok then
    say("ferry: could not open " .. url .. ": " .. tostring(err), vim.log.levels.WARN)
    run_next()
  end
end

function M.open(url)
  queue[#queue + 1] = url
  if not busy then run_next() end
end

function M.recording() return M.state.recording end

-- True while a deep link is in flight or queued.
function M.busy() return busy or #queue > 0 end

-- A new recording: an earlier one's stopped() no longer says anything.
local function new_recording()
  M.state.stopped, M.state.stop_gen = false, nil
end

-- Flow was started elsewhere (Hammerspoon's talk key). With the queue idle
-- nothing is sent: Flow is already recording. With a link in flight or
-- queued (say a stop), Flow may see that link after the outside start, so
-- one start is queued behind it. Already recording: nothing.
function M.adopt_start()
  M.state.gen = (M.state.gen or 0) + 1
  new_recording()
  M.state.adopted = true
  if M.state.recording then return end
  M.state.recording = true
  if M.busy() then M.open(M.START_URL) end
end

-- Treat a Flow recording started elsewhere as ours (tests use it).
function M.assume_recording()
  new_recording()
  M.state.recording = true
end

function M.start()
  new_recording()
  M.state.recording, M.state.adopted = true, false
  M.open(M.START_URL)
end

function M.stop()
  if M.state.adopted then M.state.stop_gen = M.state.gen or 0 end
  M.state.recording, M.state.adopted = false, false
  M.open(M.STOP_URL)
end

-- The paste after our stop of an adopted recording arrived: that recording
-- is over, unless a new one was adopted or started since.
local function paste_after_stop()
  local s = M.state
  if s.stop_gen ~= nil and s.stop_gen == (s.gen or 0) and not s.recording then s.stopped = true end
  s.stop_gen = nil
end

function M.stopped() return M.state.stopped == true end

function M.toggle()
  if M.state.recording then M.stop() else M.start() end
end

-- A paste landed in buf: Flow has stopped, and a pending finish_then can run.
-- During a wait the paste is the stopped recording's: `recording` is left
-- alone (it is only true again when a new one started during the wait).
-- With no wait, an adopted recording is left alone too (see the header).
-- The paste's lines ('[ to '], set by the paste; from first when a
-- streamed paste began above its last chunk) are kept as an extmark, id 1
-- in namespace M.PASTE_NS, for fixup.lua's default range: a write (the
-- note's autosave) resets '[,'] to the whole buffer, and the extmark moves
-- with lines added or deleted above. Never from the command line (<D-v>
-- or a terminal paste there goes into it, not the buffer, and '[ is stale).
local function remember_paste(buf, first)
  if vim.api.nvim_get_mode().mode:sub(1, 1) == "c" then return end
  if not vim.api.nvim_buf_is_valid(buf) then return end
  local s = vim.api.nvim_buf_get_mark(buf, "[")[1]
  local e = vim.api.nvim_buf_get_mark(buf, "]")[1]
  if first and first >= 1 and first < s then s = first end
  if s < 1 or s > e or e > vim.api.nvim_buf_line_count(buf) then return end
  local last = vim.api.nvim_buf_get_lines(buf, e - 1, e, false)[1] or ""
  pcall(vim.api.nvim_buf_set_extmark, buf, vim.api.nvim_create_namespace(M.PASTE_NS), s - 1, 0,
    { id = 1, end_row = e - 1, end_col = #last, invalidate = true })
end

function M.on_paste(buf, first)
  if buf == nil or buf == 0 then buf = vim.api.nvim_get_current_buf() end
  remember_paste(buf, first)
  local w = M.state.waiting
  if not w then
    if not M.state.adopted then M.state.recording = false end
    paste_after_stop()
  elseif w.buf == buf then
    vim.schedule(w.pasted)
  end
end

-- Wrap vim.paste once, chaining to the handler that was there before.
local paste_hook
local function install_paste_hook()
  if paste_hook then return end
  local orig = vim.paste
  local first -- a streamed paste's first line ('[ after its first chunk)
  paste_hook = function(lines, phase)
    local buf = vim.api.nvim_get_current_buf()
    local ret = orig(lines, phase)
    if phase == 1 then
      first = vim.api.nvim_get_mode().mode:sub(1, 1) ~= "c" and vim.api.nvim_buf_get_mark(buf, "[")[1] or nil
    end
    -- -1: whole paste in one call; 3: last chunk of a streamed paste.
    if attached[buf] and (phase == -1 or phase == 3) then
      M.on_paste(buf, phase == 3 and first or nil)
    end
    if phase == -1 or phase == 3 then first = nil end
    return ret
  end
  vim.paste = paste_hook
end

function M.attach(buf)
  if buf == nil or buf == 0 then buf = vim.api.nvim_get_current_buf() end
  install_paste_hook()
  attached[buf] = true
end

local function now_ms() return vim.uv.hrtime() / 1e6 end

local function stop_waiting()
  local w = M.state.waiting
  M.state.waiting = nil
  if w and w.timer and not w.timer:is_closing() then
    w.timer:stop()
    w.timer:close()
  end
end

-- A recording started during a wait (a quick second hold): stop it now and
-- make the wait also wait for its paste.
local function stop_during(w)
  if not M.state.recording then return end
  M.stop()
  w.more = (w.more or 0) + 1
end

-- kind (default "finish") is stored on the wait so callers can tell a
-- key-up release from a Submit/Cancel; a takeover sets the new kind.
function M.finish_then(buf, fn, kind)
  kind = kind or "finish"
  if M.state.waiting then
    -- Takes over the wait (one stop already went out); see the header.
    M.state.waiting.fn = fn
    M.state.waiting.kind = kind
    stop_during(M.state.waiting)
    return
  end
  if not M.state.recording then
    fn()
    return
  end
  if buf == nil or buf == 0 then buf = vim.api.nvim_get_current_buf() end
  M.stop()

  local function tick()
    if not vim.api.nvim_buf_is_valid(buf) then return nil end
    return vim.api.nvim_buf_get_changedtick(buf)
  end
  local start, tick0 = now_ms(), tick()
  local last_tick, last_change = tick0, nil
  local timer = vim.uv.new_timer()
  local w = { timer = timer, buf = buf, fn = fn, kind = kind, more = 0 }
  M.state.waiting = w

  -- pasted: the wait ended on a paste (not a timeout or a wiped buffer).
  -- With no paste, our stop is over all the same: a later stray paste must
  -- not count as its paste (stopped() stays false).
  local function done(notice, pasted)
    if M.state.waiting ~= w then return end
    stop_waiting()
    if pasted then paste_after_stop() else M.state.stop_gen = nil end
    if notice then say(notice, vim.log.levels.WARN) end
    w.fn()
  end
  -- One paste arrived (signalled, or changes that settled). With more
  -- pastes due, keep waiting, the timeout counted from now.
  local pasted_tick
  local function paste_seen()
    if M.state.waiting ~= w then return end
    local t = tick()
    if t ~= nil and t == pasted_tick then return end  -- same paste, reported twice
    pasted_tick = t
    if (w.more or 0) > 0 then
      w.more = w.more - 1
      start, last_tick, last_change = now_ms(), t, nil
      return
    end
    done(nil, true)
  end
  w.pasted = paste_seen

  timer:start(M.poll_ms, M.poll_ms, vim.schedule_wrap(function()
    if M.state.waiting ~= w then return end
    local t, now = tick(), now_ms()
    if t == nil then return done() end
    if t ~= last_tick then last_tick, last_change = t, now end
    if last_change and now - last_change >= M.settle_ms then return paste_seen() end
    if now - start >= M.paste_timeout_ms then
      return done(last_change == nil and M.NO_DICTATION or nil)
    end
  end))
end

-- Key-up stop: stop Flow and wait for its paste with nothing to run after.
-- A later finish_then takes the wait over. Returns true while a wait is in
-- progress, false when idle (nothing sent). A wait already running keeps its
-- fn and kind; a recording started during it is stopped and waited for.
function M.release(buf)
  if M.state.waiting then
    stop_during(M.state.waiting)
    return true
  end
  if not M.state.recording then return false end
  M.finish_then(buf, function() end, "release")
  return true
end

return M
