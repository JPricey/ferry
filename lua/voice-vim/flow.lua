-- Wispr Flow hands-free toggle for a voice-vim buffer.
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
local M = {}

M.paste_timeout_ms = 4000
M.settle_ms = 150
M.poll_ms = 50
-- An `open` that hangs is killed after this, so the queue moves on.
M.open_timeout_ms = 5000

M.START_URL = "wispr-flow://start-hands-free"
M.STOP_URL = "wispr-flow://stop-hands-free"
M.NO_DICTATION = "voice-vim: no dictation arrived"

-- recording: Flow was started by us (or assumed) and has not pasted yet.
-- waiting: the pending finish_then, { timer = uv timer, buf, fn = action,
-- pasted = fn } or nil.
M.state = { recording = false, waiting = nil }
local attached = {}

-- One `open` at a time, in call order, so a quick start/stop pair cannot
-- reach Flow as stop/start.
local queue, busy = {}, false
local function run_next()
  local url = table.remove(queue, 1)
  if not url then busy = false; return end
  busy = true
  local ok, err = pcall(vim.system, { "open", "-g", url }, { timeout = M.open_timeout_ms }, function(obj)
    vim.schedule(function()
      if obj.code ~= 0 then vim.notify("voice-vim: could not open " .. url, vim.log.levels.WARN) end
      run_next()
    end)
  end)
  if not ok then
    vim.notify("voice-vim: could not open " .. url .. ": " .. tostring(err), vim.log.levels.WARN)
    run_next()
  end
end

function M.open(url)
  queue[#queue + 1] = url
  if not busy then run_next() end
end

function M.recording() return M.state.recording end

-- Flow was started outside nvim (VOICE_VIM_AUTOSTART_FLOW): treat it as ours.
function M.assume_recording() M.state.recording = true end

function M.start()
  M.state.recording = true
  M.open(M.START_URL)
end

function M.stop()
  M.state.recording = false
  M.open(M.STOP_URL)
end

function M.toggle()
  if M.state.recording then M.stop() else M.start() end
end

-- A paste landed in buf: Flow has stopped, and a pending finish_then can run.
function M.on_paste(buf)
  if buf == nil or buf == 0 then buf = vim.api.nvim_get_current_buf() end
  M.state.recording = false
  local w = M.state.waiting
  if w and w.buf == buf then vim.schedule(w.pasted) end
end

-- Wrap vim.paste once, chaining to the handler that was there before.
local paste_hook
local function install_paste_hook()
  if paste_hook then return end
  local orig = vim.paste
  paste_hook = function(lines, phase)
    local buf = vim.api.nvim_get_current_buf()
    local ret = orig(lines, phase)
    -- -1: whole paste in one call; 3: last chunk of a streamed paste.
    if attached[buf] and (phase == -1 or phase == 3) then M.on_paste(buf) end
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

function M.finish_then(buf, fn)
  if M.state.waiting then
    -- Takes over the wait (one stop already went out); see the header.
    M.state.waiting.fn = fn
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
  local w = { timer = timer, buf = buf, fn = fn }
  M.state.waiting = w

  local function done(notice)
    if M.state.waiting ~= w then return end
    stop_waiting()
    if notice then vim.notify(notice, vim.log.levels.WARN) end
    w.fn()
  end
  w.pasted = function() done() end

  timer:start(M.poll_ms, M.poll_ms, vim.schedule_wrap(function()
    if M.state.waiting ~= w then return end
    local t, now = tick(), now_ms()
    if t == nil then return done() end
    if t ~= last_tick then last_tick, last_change = t, now end
    if last_change and now - last_change >= M.settle_ms then return done() end
    if now - start >= M.paste_timeout_ms then
      return done(last_change == nil and M.NO_DICTATION or nil)
    end
  end))
end

return M
