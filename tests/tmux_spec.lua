-- tmux delivery and pane listing in lua/ferry/tmux.lua, against the
-- throwaway `tmux -L ferry-test` server set up by tests/test-tmux.sh.
-- Run: nvim --headless --clean -l tests/tmux_spec.lua <root> <work> <real tmux> <paneA> <paneB>
local root, work, real, paneA, paneB = arg[1], arg[2], arg[3], arg[4], arg[5]
vim.opt.rtp:prepend(root)
local tmux = require("ferry.tmux")
local T = require("ferry.target")

io.stdout:setvbuf("line")
local function say(s) io.stdout:write(s, "\n") end
local fail = 0
local function check(name, want, got)
  if want == got then
    say("ok   " .. name)
  else
    say("FAIL " .. name .. ": want '" .. tostring(want) .. "' got '" .. tostring(got) .. "'")
    fail = 1
  end
end

local function read(path)
  local f = io.open(path, "rb")
  if not f then return "" end
  local s = f:read("*a")
  f:close()
  return s
end
local spylog = work .. "/spy.log"
local function spy() return vim.split(read(spylog), "\n", { trimempty = true }) end
local function clear_spy() os.remove(spylog) end
local function show(s) return (s:gsub("\n", "\\n")) end
-- Wait until path holds want (or 2 s passed), return its content.
local function settle(path, want)
  vim.wait(2000, function() return read(path) == want end, 20)
  return read(path)
end
local function real_tmux(...)
  return vim.system({ real, "-L", "ferry-test", ... }, { text = true }):wait()
end

local A = T.parse("tmux:ferry-test:" .. paneA)
local B = T.parse("tmux:ferry-test:" .. paneB)
local a_out, b_out = work .. "/a.out", work .. "/b.out"
local all_spy = {}
local function keep_spy()
  vim.list_extend(all_spy, spy())
  clear_spy()
end

-- 1. Two-line send, no Enter: bracketed, no trailing newline.
local ok, err = tmux.send(A, "line one\nline two\n", { enter = false })
check("send two lines ok", true, ok)
check("send two lines err", nil, err)
local want = "^[[200~line one\nline two^[[201~"
check("pane A got bracketed paste, no newline", show(want), show(settle(a_out, want)))
local calls = spy()
check("send ran 3 tmux calls", 3, #calls)
check("1st call checks the pane", true,
  (calls[1] or ""):find("-L ferry-test display-message -p -t " .. paneA, 1, true) ~= nil)
local bufname = (calls[2] or ""):match("load%-buffer %-b (ferry%-%S+) %-$")
check("2nd call load-buffer from stdin, ferry-<rand>", true, bufname ~= nil)
check("3rd call paste-buffer -p -d", "-L ferry-test paste-buffer -p -d -b " .. tostring(bufname) .. " -t " .. paneA,
  calls[3])
check("buffer deleted after paste", "", vim.trim(real_tmux("list-buffers").stdout or ""))
keep_spy()

-- 2. enter=true adds exactly one newline.
ok = tmux.send(A, "third", { enter = true })
check("send with enter ok", true, ok)
want = want .. "^[[200~third^[[201~\n"
check("pane A got paste plus one newline", show(want), show(settle(a_out, want)))
calls = spy()
check("enter: send-keys Enter last", "-L ferry-test send-keys -t " .. paneA .. " Enter", calls[#calls])
keep_spy()

-- 3. Pane B (the `claude` cat copy, no bracketed paste) also takes a spec string.
ok = tmux.send("tmux:ferry-test:" .. paneB, "to claude", { enter = true })
check("send to pane B by spec string", true, ok)
check("pane B got the text plus newline", "to claude\n", settle(b_out, "to claude\n"))
keep_spy()

-- 4. list: pane B (claude) first.
local items = tmux.list({ "ferry-test" })
check("list finds 2 panes", 2, #items)
local base = vim.fs.basename(work)
check("list[1] is pane B", "tmux:ferry-test:" .. paneB, items[1] and items[1].spec)
check("list[1] claude", true, items[1] and items[1].claude)
check("list[1] label", "ferryt:0.1 · B title · " .. base, items[1] and items[1].label)
check("list[2] is pane A", "tmux:ferry-test:" .. paneA, items[2] and items[2].spec)
check("list[2] not claude", false, items[2] and items[2].claude)
check("list[2] label ends with cwd", true,
  items[2] ~= nil and items[2].label:find("^ferryt:0%.0 · .* · " .. vim.pesc(base) .. "$") ~= nil)
keep_spy()

-- 5. Missing pane: false + err, nothing loaded or pasted.
local before = read(a_out)
ok, err = tmux.send(T.parse("tmux:ferry-test:%999"), "nope", { enter = true })
check("missing pane -> false", false, ok)
check("missing pane -> err", true, type(err) == "string" and err ~= "")
say("     err: " .. tostring(err))
calls = spy()
check("missing pane: only the check ran", 1, #calls)
check("missing pane: nothing pasted", before, read(a_out))
keep_spy()

-- 6. Not a tmux target.
ok, err = tmux.send(T.parse("clipboard"), "x")
check("non-tmux target -> false", false, ok)
check("non-tmux target: no tmux call", 0, #spy())

-- 7. servers() from FERRY_TMUX_SERVERS.
vim.env.FERRY_TMUX_SERVERS = nil
check("servers default", "default", table.concat(tmux.servers(), ","))
vim.env.FERRY_TMUX_SERVERS = " ferry-test , default,,"
check("servers from env", "ferry-test,default", table.concat(tmux.servers(), ","))
vim.env.FERRY_TMUX_SERVERS = nil

-- 8. find(): PATH first (the spy), then Homebrew when PATH is bare.
check("find uses PATH first", work .. "/bin/tmux", tmux.find())
local path = vim.env.PATH
vim.env.PATH = "/usr/bin:/bin"
local hb = vim.fn.executable("/opt/homebrew/bin/tmux") == 1
if hb then check("find falls back to /opt/homebrew/bin/tmux", "/opt/homebrew/bin/tmux", tmux.find()) end
vim.env.PATH = path

-- 9. Record-only: the default server means no -L. The spy refuses to
-- forward it, so the check fails and Joe's server is never reached.
ok = tmux.send(T.parse("tmux:default:%1"), "never", {})
check("default server: send fails under the spy", false, ok)
calls = spy()
check("default server: one recorded call", 1, #calls)
check("default server: no -L", "display-message -p -t %1 #{pane_id}", calls[1])
local default_calls = #calls
keep_spy()

-- 10. Dead server: false + err, nothing pasted; list is empty.
real_tmux("kill-server")
ok, err = tmux.send(A, "dead", { enter = true })
check("dead server -> false", false, ok)
check("dead server -> err", true, type(err) == "string" and err ~= "")
say("     err: " .. tostring(err))
check("dead server: only the check ran", 1, #spy())
check("dead server: list empty", 0, #tmux.list({ "ferry-test" }))
keep_spy()

-- Every argv the module ran names -L ferry-test, except the one
-- record-only default-server check.
local other = 0
for _, c in ipairs(all_spy) do
  if not c:find("^%-L ferry%-test ") then other = other + 1 end
end
check("all calls use -L ferry-test but the default check", default_calls, other)
check("spy saw calls", true, #all_spy > 10)

os.exit(fail)
