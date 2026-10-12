-- $EDITOR mode in lua/ferry/edit.lua, with a recording stub host. Key-
-- driven cases run against a real server in tests/test-edit.sh.
-- Run by tests/test-edit.sh: nvim --headless --clean -l tests/edit_spec.lua <root> <work>
-- The shell sets FERRY_DB, FERRY_NOTES_DIR, FERRY_INDEX, FERRY_OUTBOX and
-- puts a recording fake `open` first on PATH.
local root, work = arg[1], arg[2]
vim.opt.rtp:prepend(root)
local note = require("ferry.note")
local flow = require("ferry.flow")
local store = require("ferry.store")
local edit = require("ferry.edit")

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

local function readfile(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("a"); f:close(); return s
end
local function writefile(path, s)
  local f = assert(io.open(path, "wb")); f:write(s); f:close()
end

-- Flow URLs and host calls in one ordered event list; flow.open is swapped,
-- so nothing is run for Flow.
local events = {}
flow.open = function(url) events[#events + 1] = url:match("wispr%-flow://(%S+)") or url end
note.host = { submit = function() events[#events + 1] = "submit" end,
  hide = function() events[#events + 1] = "hide" end }
local function evs() local e = table.concat(events, ","); events = {}; return e end
local function paste_later(text, ms)
  vim.defer_fn(function()
    events[#events + 1] = "paste"
    vim.paste({ text }, -1)
  end, ms)
end

local n = 0
-- A fresh file with text and its done path.
local function files(text)
  n = n + 1
  local file, done = work .. "/edit" .. n .. ".txt", work .. "/done/" .. n
  if text then writefile(file, text) end
  return file, done
end
local function tabs() return #vim.api.nvim_list_tabpages() end
local function lines() return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "|") end
-- Wait until the edit with done file d has ended.
local function ended(d) vim.wait(3000, function() return not edit.pending() end, 10); return readfile(d) end

-- --- a note draft is kept ------------------------------------------------
local npath = note.show({ target = "com.example.app", window = "4242", seed = "" })
vim.cmd("stopinsert")
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "my draft", "second" })
vim.api.nvim_win_set_cursor(0, { 2, 2 })
local nbuf, nwin, nid = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win(), vim.b.ferry.id
vim.o.showtabline = 1

local file, done = files("hello\n")
check("start answers ok", "ok", edit.start({ file = file, done = done }))
check("start saved the note draft", "draft|my draft|second", (function()
  local m, body = store.read(npath)
  return m and (tostring(rawget(m, "state")) .. "|" .. table.concat(body, "|")) or "none"
end)())
check("the edit is in a new tab with the file, tab line hidden", "2 true hello 0",
  table.concat({ tabs(), tostring(vim.api.nvim_buf_get_name(0) == vim.fn.resolve(file)
    or vim.fn.resolve(vim.api.nvim_buf_get_name(0)) == vim.fn.resolve(file)), lines(), vim.o.showtabline }, " "))
check("the edit buffer has the edit keys, not the note's", "true true nil",
  tostring(vim.fn.maparg("<C-x>", "i"):find("Submit", 1, true) ~= nil) .. " "
  .. tostring(vim.fn.maparg("<C-q>", "n"):find("Cancel", 1, true) ~= nil) .. " " .. tostring(vim.b.ferry))
check("status pending, pending() true", "pending true", edit.status({ done = done }) .. " " .. tostring(edit.pending()))
vim.api.nvim_exec_autocmds("FocusGained", {})
check("FocusGained: status shown", "shown", edit.status({ done = done }))
check("status of another done file is done", "done", edit.status({ done = done .. "x" }))
local file2, done2 = files("other\n")
check("second start answers busy", "busy", edit.start({ file = file2, done = done2 }))
check("busy start leaves the edit and no done file", "2 nil", tabs() .. " " .. tostring(readfile(done2)))

-- --- Submit --------------------------------------------------------------
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "edited text", "line two" })
events = {}
vim.cmd("Submit")
check("Submit: file holds the text, done=0, one hide", "edited text\nline two\n|0\n|hide",
  tostring(readfile(file)) .. "|" .. tostring(ended(done)) .. "|" .. evs())
check("Submit: tab gone, tab line restored, not pending, status done", "1 1 false done",
  table.concat({ tabs(), vim.o.showtabline, tostring(edit.pending()), edit.status({ done = done }) }, " "))
check("after the edit the note is still current, shown, with its cursor",
  "true true true 2,2 true", table.concat({ tostring(note.current() and note.current().id == nid),
    tostring(vim.api.nvim_get_current_buf() == nbuf), tostring(vim.api.nvim_get_current_win() == nwin),
    table.concat(vim.api.nvim_win_get_cursor(nwin), ","), tostring(vim.g.ferry_draft == npath) }, " "))
check("the edit buffer is wiped", -1, vim.fn.bufnr(file))

-- --- Cancel leaves the bytes ---------------------------------------------
local orig = "keep me\r\n# no final newline"
file, done = files(orig)
edit.start({ file = file, done = done })
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "changed" })
vim.cmd("Cancel")
check("Cancel: file bytes unchanged, done=1, one hide", "true|1\n|hide",
  tostring(readfile(file) == orig) .. "|" .. tostring(ended(done)) .. "|" .. evs())

-- Submit with nothing changed rewrites nothing.
file, done = files(orig)
edit.start({ file = file, done = done })
vim.cmd("Submit")
check("Submit unchanged: bytes as they were, done=0", "true|0\n", tostring(readfile(file) == orig) .. "|" .. tostring(ended(done)))
evs()

-- A file that does not exist yet is created on Submit.
file, done = files(nil)
edit.start({ file = file, done = done })
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "new file" })
vim.cmd("Submit")
check("Submit creates a missing file", "new file\n|0\n", tostring(readfile(file)) .. "|" .. tostring(ended(done)))
evs()

-- --- Hide keeps the edit pending -----------------------------------------
file, done = files("hide me\n")
edit.start({ file = file, done = done })
vim.cmd("Hide")
check("Hide: one hide, still pending, no done file", "hide true nil",
  evs() .. " " .. tostring(edit.pending()) .. " " .. tostring(readfile(done)))
vim.cmd("tabnext 1")
check("show() brings the edit tab back", file, edit.show())
check("show(): the edit buffer is current", "hide me", lines())

-- --- abort ---------------------------------------------------------------
check("abort with another done file: none", "none", edit.abort({ done = done .. "x" }))
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "dropped" })
check("abort answers aborted", "aborted", edit.abort({ done = done }))
check("abort: done=1, file unchanged, tab gone, no hide (never shown)", "1\n|hide me\n|1|",
  tostring(readfile(done)) .. "|" .. tostring(readfile(file)) .. "|" .. tabs() .. "|" .. evs())
file, done = files("x\n")
edit.start({ file = file, done = done })
vim.api.nvim_exec_autocmds("FocusGained", {})
edit.abort({ done = done })
check("abort of a shown edit hides", "hide", evs())

-- --- Flow ----------------------------------------------------------------
file, done = files("")
edit.start({ file = file, done = done })
vim.cmd("stopinsert")
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "typed" })
vim.cmd("normal! G$")
vim.api.nvim_feedkeys(vim.keycode("<C-s>"), "x", false)
paste_later(" spoken", 300)
vim.cmd("Submit")
check("Submit while recording waits (no done yet)", "nil", tostring(readfile(done)))
check("Flow recording at Submit: the paste is in the file, done=0", "typed spoken\n|0\n",
  tostring((ended(done) and readfile(file))) .. "|" .. tostring(readfile(done)))
check("Flow events: start, stop, paste, then hide", "start-hands-free,stop-hands-free,paste,hide", evs())

file, done = files("before\n")
edit.start({ file = file, done = done })
flow.toggle()
paste_later(" cancelled words", 300)
vim.cmd("Cancel")
check("Cancel while recording: file unchanged, done=1 after the paste", "before\n|1\n",
  tostring((ended(done) and readfile(file))) .. "|" .. tostring(readfile(done)))
check("Cancel while recording: hide only after the paste", "start-hands-free,stop-hands-free,paste,hide", evs())

-- Flow busy in the note: start answers busy and touches nothing.
note.show({ target = "com.example.app", window = "4242", seed = "" })
flow.assume_recording()
file, done = files("y\n")
check("start while Flow records in the note: busy, no tab", "busy 1",
  edit.start({ file = file, done = done }) .. " " .. tabs())
vim.paste({ " flow" }, -1)
check("start after Flow pasted: ok", "ok", edit.start({ file = file, done = done }))
edit.abort({ done = done })

-- --- errors --------------------------------------------------------------
check("relative paths are refused", "error file and done must be absolute paths",
  edit.start({ file = "rel.txt", done = done }))
file, done = work .. "/missing-dir/f.txt", work .. "/done/werr"
edit.start({ file = file, done = done })
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "keep this" })
vim.cmd("Submit")
vim.wait(200)
check("a failed write keeps the edit pending and shown, no done file", "true keep this nil",
  tostring(edit.pending()) .. " " .. lines() .. " " .. tostring(readfile(done)))
edit.abort({ done = done })
evs()

file, done = files("wipe\n")
edit.start({ file = file, done = done })
vim.cmd("bwipeout!")
check(":bwipeout of the edit buffer ends it with done=1", "false 1\n 1",
  tostring(edit.pending()) .. " " .. tostring(readfile(done)) .. " " .. vim.o.showtabline)

-- --- front: ferry already frontmost, no FocusGained ------------------------
evs()
file, done = files("front\n")
edit.start({ file = file, done = done })
check("status front=0 stays pending", "pending", edit.status({ done = done, front = 0 }))
check("status front=1 marks it shown", "shown shown",
  edit.status({ done = done, front = 1 }) .. " " .. edit.status({ done = done }))
edit.abort({ done = done })
check("abort after front=1 hides", "hide", evs())

-- --- abort while Flow records in the edit ----------------------------------
file, done = files("flow abort\n")
edit.start({ file = file, done = done })
flow.toggle()
paste_later(" late words", 300)
check("abort while recording: aborting, still pending", "aborting true",
  edit.abort({ done = done }) .. " " .. tostring(edit.pending()))
check("abort while recording: done=1 after the paste, file unchanged, Flow idle",
  "1\n|flow abort\n|false nil", tostring(ended(done)) .. "|" .. tostring(readfile(file)) .. "|"
  .. tostring(flow.recording()) .. " " .. tostring(flow.state.waiting))
check("abort while recording: start, stop, paste, no hide (never shown)",
  "start-hands-free,stop-hands-free,paste", evs())
file, done = files("next\n")
check("start after that abort: ok", "ok", edit.start({ file = file, done = done }))
edit.abort({ done = done })

-- Flow recording in the note (not the edit): abort ends the edit at once and
-- leaves the note's recording alone.
file, done = files("note flow\n")
edit.start({ file = file, done = done })
vim.cmd("tabnext 1")
flow.assume_recording()
check("abort with Flow recording in the note: aborted at once, Flow still recording",
  "aborted false true", edit.abort({ done = done }) .. " " .. tostring(edit.pending()) .. " "
  .. tostring(flow.recording()))
vim.paste({ " x" }, -1)
evs()

-- --- a pending edit wins the hotkey: live upgrade, release --force ----------
-- A server whose loaded edit module predates api 3 (no on_show): the note
-- reloads it, keeping the pending edit.
file, done = files("hot\n")
edit.start({ file = file, done = done })
vim.cmd("stopinsert")
vim.cmd("tabnext 1")
edit.api = 2
local shown = note.show({ target = "com.other", window = "7", seed = "" })
local edit3 = package.loaded["ferry.edit"]
check("show with an api-2 edit module and an edit pending: reloaded, edit kept and shown",
  file .. " 3 true hot", shown .. " " .. tostring(edit3.api) .. " " .. tostring(edit3.pending()) .. " " .. lines())
check("release --force with Flow idle in the edit: forced, waiting on the edit buffer",
  "forced true", note.release({ force = "1" }) .. " " .. tostring(flow.state.waiting
    and flow.state.waiting.buf == vim.fn.bufnr(file)))
vim.paste({ "said " }, -1)
vim.wait(1000, function() return flow.state.waiting == nil end, 10)
check("the forced stop's paste ended the wait in the edit", "true nil",
  tostring(lines():find("said ", 1, true) ~= nil) .. " " .. tostring(flow.state.waiting))
edit3.abort({ done = done })
check("with no edit pending, show is the note again", npath, note.show({ target = "com.example.app", window = "4242", seed = "" }))
evs()

say(fail == 0 and "edit_spec: all ok" or "edit_spec: FAILED")
os.exit(fail)
