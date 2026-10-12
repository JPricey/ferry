-- Flow toggle core in lua/voice-vim/flow.lua: start/stop through the
-- default M.open (a recording fake `open` first on PATH), paste detection
-- through the vim.paste hook, and finish_then's wait for the last paste.
-- Run by tests/test-flow.sh: nvim --headless --clean -l tests/flow_spec.lua <root> <work>
local root, work = arg[1], arg[2]
vim.opt.rtp:prepend(root)
local flow = require("voice-vim.flow")
local log = work .. "/open.log"

-- io.stdout, not print: print goes through nvim's message grid, which
-- drops newlines after a mode change.
io.stdout:setvbuf("line")
local function say(s) io.stdout:write(s, "\n") end
local notices = {}
vim.notify = function(msg) notices[#notices + 1] = msg; say("notice: " .. msg) end

local fail = 0
local function check(name, want, got)
  if want == got then
    say("ok   " .. name)
  else
    say("FAIL " .. name .. ": want '" .. tostring(want) .. "' got '" .. tostring(got) .. "'")
    fail = 1
  end
end

local function lines()
  local f = io.open(log, "r")
  if not f then return {} end
  local t = {}
  for l in f:lines() do t[#t + 1] = l end
  f:close()
  return t
end
-- Wait until the fake open has logged n lines (or ms passed), then return
-- the log joined by " | " and clear it.
local function opened(n, ms)
  vim.wait(ms or 2000, function() return #lines() >= n end, 10)
  local got = table.concat(lines(), " | ")
  os.remove(log)
  return got
end

local orig_paste = vim.paste
local orig_calls = 0
vim.paste = function(...) orig_calls = orig_calls + 1; return orig_paste(...) end
local buf = vim.api.nvim_get_current_buf()
flow.attach(buf)
local hooked = vim.paste
flow.attach(buf) -- a second attach is a no-op
local other = vim.api.nvim_create_buf(true, false)
flow.attach(other)
check("vim.paste is wrapped", true, hooked ~= orig_paste and hooked ~= nil)
check("two more attaches do not re-wrap vim.paste", true, vim.paste == hooked)
local function insert(text)
  local last = vim.api.nvim_buf_line_count(buf) - 1
  local col = #vim.api.nvim_buf_get_lines(buf, last, last + 1, false)[1]
  vim.api.nvim_buf_set_text(buf, last, col, last, col, { text })
end
local function text() return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n") end
local function reset_buf() vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" }) end

-- --- toggle -----------------------------------------------------------------
os.remove(log)
flow.toggle()
check("toggle on: recording", true, flow.recording())
flow.toggle()
check("toggle off: not recording", false, flow.recording())
check("toggle twice logs start then stop",
  "-g wispr-flow://start-hands-free | -g wispr-flow://stop-hands-free", opened(2))

-- --- paste detection --------------------------------------------------------
local function keys(k)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(k, true, false, true), "xt", false)
end
vim.o.showmode = false
flow.toggle()
opened(1)
insert("x")
check("1-byte insert while recording keeps recording", true, flow.recording())
insert("twelve bytes")
check("12-byte set_text (not a paste) keeps recording", true, flow.recording())
vim.bo[buf].autoindent = true
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "    indented" })
keys("A\u{e9}<Esc>")
check("typing \u{e9} keeps recording", true, flow.recording())
keys("A<CR>next<Esc>")
check("Enter with autoindent keeps recording", "    indented\u{e9}\n    next", text())
check("Enter with autoindent: still recording", true, flow.recording())
keys("oline<Esc>")
check("o keeps recording", true, flow.recording())
vim.cmd("silent normal u")
check("u (undo) keeps recording", true, flow.recording())
orig_calls = 0
vim.paste({ "twelve bytes" }, -1)
check("vim.paste clears recording", false, flow.recording())
check("vim.paste chains to the original handler once", 1, orig_calls)
check("vim.paste text lands", true, text():find("twelve bytes", 1, true) ~= nil)
check("vim.paste sends nothing", "", opened(1, 300))
flow.toggle()
check("next toggle after a paste sends start", "-g wispr-flow://start-hands-free", opened(1))
flow.stop()
opened(1)

-- --- finish_then, idle --------------------------------------------------------
local ran = false
flow.finish_then(buf, function() ran = true end)
check("idle finish_then runs fn synchronously", true, ran)
check("idle finish_then opens nothing", "", opened(1, 300))

-- --- finish_then, recording, paste arrives ---------------------------------
reset_buf()
flow.start()
opened(1)
insert("h"); insert("i") -- typed, one byte at a time
local seen, timer_fired, fn_at
local t0 = vim.uv.hrtime()
flow.finish_then(buf, function() seen = text(); fn_at = vim.uv.hrtime() end)
local returned_ms = (vim.uv.hrtime() - t0) / 1e6
check("recording finish_then returns at once", true, returned_ms < 50)
check("recording finish_then sends stop", "-g wispr-flow://stop-hands-free", opened(1))
vim.defer_fn(function() timer_fired = vim.uv.hrtime() end, 150)
vim.defer_fn(function() insert(" last words") end, 300)
vim.wait(math.max(0, 100 - (vim.uv.hrtime() - t0) / 1e6), function() return false end, 10)
check("fn not run at 100 ms", nil, seen)
vim.wait(3000, function() return seen ~= nil end, 10)
check("deferred paste at 300 ms lands and fn sees it", "hi last words", seen)
check("a timer fires during the wait (UI not blocked)", true,
  timer_fired ~= nil and fn_at ~= nil and timer_fired < fn_at)
check("no notice when the paste arrived", 0, #notices)

-- --- finish_then, recording, vim.paste arrives: done without settle_ms -------
reset_buf()
flow.settle_ms = 1000
flow.start()
opened(1)
seen, fn_at = nil, nil
local paste_at
flow.finish_then(buf, function() seen = text(); fn_at = vim.uv.hrtime() end)
opened(1)
vim.defer_fn(function() vim.paste({ "flow words" }, -1); paste_at = vim.uv.hrtime() end, 200)
vim.wait(3000, function() return seen ~= nil end, 10)
check("vim.paste during the wait: fn sees it", "flow words", seen)
check("vim.paste during the wait: fn runs within 100 ms", true,
  fn_at ~= nil and paste_at ~= nil and (fn_at - paste_at) / 1e6 < 100)
flow.settle_ms = 150

-- --- finish_then, recording, no paste ---------------------------------------
flow.paste_timeout_ms = 300
flow.assume_recording()
seen = nil
local t1 = vim.uv.hrtime()
flow.finish_then(buf, function() seen = (vim.uv.hrtime() - t1) / 1e6 end)
opened(1)
vim.wait(2000, function() return seen ~= nil end, 10)
check("no paste: fn runs after the 300 ms timeout", true, seen ~= nil and seen >= 300 and seen < 1000)
check("no paste: notice", flow.NO_DICTATION, notices[1])

-- --- second finish_then while waiting: takes over and still waits ----------
-- (Ctrl-Q during the hotkey's hide-while-recording wait must not run before
-- Flow's paste, or the paste lands in the target.)
reset_buf()
flow.paste_timeout_ms = 4000
flow.assume_recording()
local first, second = 0, nil
flow.finish_then(buf, function() first = first + 1 end)
flow.finish_then(buf, function() second = text() end)
check("second finish_then while waiting does not run at once", nil, second)
check("second finish_then sends only one stop", "-g wispr-flow://stop-hands-free", opened(1, 300))
vim.wait(150, function() return false end, 10)
check("second finish_then: still waiting for the paste", nil, second)
vim.paste({ "late words" }, -1)
vim.wait(1000, function() return second ~= nil end, 10)
check("second finish_then runs after the paste and sees it", "late words", second)
vim.wait(300, function() return false end, 10)
check("the first (replaced) fn never runs", 0, first)

-- Taking over a wait that times out: the new fn runs at the timeout, once.
flow.paste_timeout_ms = 300
flow.assume_recording()
local took, runs = nil, 0
local t3 = vim.uv.hrtime()
flow.finish_then(buf, function() end)
opened(1)
flow.finish_then(buf, function() runs = runs + 1; took = (vim.uv.hrtime() - t3) / 1e6 end)
vim.wait(2000, function() return took ~= nil end, 10)
vim.wait(200, function() return false end, 10)
check("takeover with no paste: runs once after the timeout", true, runs == 1 and took >= 300)
flow.paste_timeout_ms = 4000

-- --- a hanging `open` is killed and the queue moves on -----------------------
flow.open_timeout_ms = 200
local t2 = vim.uv.hrtime()
flow.open("wispr-flow://hang")
flow.open(flow.START_URL)
local got = opened(2, 3000)
check("hanging open: the next URL still goes out",
  "-g wispr-flow://hang | -g wispr-flow://start-hands-free", got)
check("hanging open: next URL within 1.5 s", true, (vim.uv.hrtime() - t2) / 1e6 < 1500)

-- --- hold to talk: adopt_start / release -------------------------------------
-- Hammerspoon starts Flow itself; adopt_start only records that it did.
vim.wait(1000, function() return not flow.busy() end, 10)
check("busy() false when the queue is idle", false, flow.busy())
flow.state.recording = false
flow.adopt_start()
check("adopt while idle: recording", true, flow.recording())
check("adopt while idle: no URL", "", opened(1, 300))

flow.adopt_start()
check("adopt while recording: still recording", true, flow.recording())
check("adopt while recording: no URL", "", opened(1, 300))

-- A link in flight (say our own stop): queue one start behind it.
flow.state.recording = false
flow.open("wispr-flow://hang")
check("busy() true with a link in flight", true, flow.busy())
flow.adopt_start()
check("adopt behind a hanging link: recording", true, flow.recording())
check("adopt behind a hanging link: start after it",
  "-g wispr-flow://hang | -g wispr-flow://start-hands-free", opened(2, 3000))
vim.wait(1000, function() return not flow.busy() end, 10)

-- release: one stop, a wait of kind "release", ended by Flow's paste.
reset_buf()
flow.paste_timeout_ms = 4000
check("release while recording returns true", true, flow.release(buf))
check("release: kind release", "release", flow.state.waiting and flow.state.waiting.kind)
check("release: not recording", false, flow.recording())
check("release: one stop", "-g wispr-flow://stop-hands-free", opened(1))
check("second release during the wait returns true", true, flow.release(buf))
check("second release sends nothing", "", opened(1, 300))
vim.paste({ "talked" }, -1)
vim.wait(1000, function() return flow.state.waiting == nil end, 10)
check("release: a paste ends the wait", nil, flow.state.waiting)
check("release: paste lands", "talked", text())

-- finish_then during a release takes the wait over and runs after the paste.
reset_buf()
flow.adopt_start()
flow.release(buf)
opened(1)
local after
flow.finish_then(buf, function() after = text() end)
check("finish_then during a release: kind finish", "finish", flow.state.waiting and flow.state.waiting.kind)
vim.wait(200, function() return false end, 10)
check("finish_then during a release: not run before the paste", nil, after)
check("finish_then during a release: no second stop", "", opened(1, 300))
vim.paste({ "last words" }, -1)
vim.wait(1000, function() return after ~= nil end, 10)
check("finish_then during a release: runs after the paste and sees it", "last words", after)

-- release while idle: nothing sent, false.
check("release while idle returns false", false, flow.release(buf))
check("release while idle: no wait", nil, flow.state.waiting)
check("release while idle logs nothing", "", opened(1, 300))

say(fail == 0 and "flow_spec: all ok" or "flow_spec: FAILED")
os.exit(fail)
