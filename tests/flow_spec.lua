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

-- --- second finish_then while waiting ----------------------------------------
flow.paste_timeout_ms = 4000
flow.assume_recording()
local first, second = 0, false
flow.finish_then(buf, function() first = first + 1 end)
flow.finish_then(buf, function() second = true end)
check("second finish_then while waiting runs fn at once", true, second)
vim.wait(500, function() return false end, 10)
check("the first wait is dropped", 0, first)
check("second finish_then sends only one stop", "-g wispr-flow://stop-hands-free", opened(1, 300))

-- --- a hanging `open` is killed and the queue moves on -----------------------
flow.open_timeout_ms = 200
local t2 = vim.uv.hrtime()
flow.open("wispr-flow://hang")
flow.open(flow.START_URL)
local got = opened(2, 3000)
check("hanging open: the next URL still goes out",
  "-g wispr-flow://hang | -g wispr-flow://start-hands-free", got)
check("hanging open: next URL within 1.5 s", true, (vim.uv.hrtime() - t2) / 1e6 < 1500)

say(fail == 0 and "flow_spec: all ok" or "flow_spec: FAILED")
os.exit(fail)
