-- Submit, Cancel and Hide in lua/ferry/note.lua, with a recording stub
-- host and a temp history database.
-- Key-driven cases (:q, :wq, <C-x>, ZQ) run against a real server in
-- tests/test-note.sh, where typed input goes through the main loop.
-- Run by tests/test-note.sh: nvim --headless --clean -l tests/note_spec.lua <root> <work>
-- The shell sets FERRY_DB, FERRY_NOTES_DIR, FERRY_INDEX, FERRY_OUTBOX and
-- puts a recording fake `open` first on PATH (it fails while
-- <work>/open.fail exists).
local root, work = arg[1], arg[2]
vim.opt.rtp:prepend(root)
local note = require("ferry.note")
local flow = require("ferry.flow")
local store = require("ferry.store")
local db = root .. "/bin/ferry-db"

-- Never touch the system clipboard: a fake + and * provider.
-- clip_mode "throw" makes the + copy raise, "drop" makes it silently keep
-- nothing (nil: a working copy).
local clip, clip_mode = {}, nil
vim.g.clipboard = {
  name = "ferry-test",
  copy = {
    ["+"] = function(lines)
      if clip_mode == "throw" then error("fake clipboard copy failed") end
      if clip_mode ~= "drop" then clip["+"] = lines end
    end,
    ["*"] = function(lines) clip["*"] = lines end,
  },
  paste = { ["+"] = function() return clip["+"] or {} end, ["*"] = function() return clip["*"] or {} end },
}

local notices = {}
local real_notify = vim.notify
vim.notify = function(msg, ...) notices[#notices + 1] = msg; return real_notify(msg, ...) end

-- io.stdout, not print: print goes through nvim's message grid, which
-- drops newlines after a mode change.
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
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("a"); f:close(); return s
end

-- Recording stub host. submit reads the file at call time.
local calls
local stub = {
  submit = function(p)
    calls[#calls + 1] = { "submit", p, readfile(p.file) }
  end,
  hide = function(p) calls[#calls + 1] = { "hide", p } end,
}
local function reset() calls = {} end
note.host = stub

-- Flow URLs and host calls in one ordered event list. flow.open is swapped,
-- so nothing (not even the fake `open`) is run for Flow here.
local events = {}
flow.open = function(url) events[#events + 1] = url:match("wispr%-flow://(%S+)") or url end
stub.submit = (function(f) return function(p) events[#events + 1] = "submit"; f(p) end end)(stub.submit)
stub.hide = (function(f) return function(p) events[#events + 1] = "hide"; f(p) end end)(stub.hide)
local function flow_events() local e = table.concat(events, ","); events = {}; return e end

local function row(id)
  local out = vim.fn.system({ db, "get", id })
  if vim.v.shell_error ~= 0 then return nil end
  return vim.json.decode(out)
end
local function outcome(id) local r = row(id); return r and r.outcome or "none" end

-- A note file as "state|target|sent?|body lines joined by |", or "none".
local function nfile(path)
  local m, body = store.read(path)
  if not m then return "none" end
  return table.concat({ tostring(rawget(m, "state")), tostring(rawget(m, "target")),
    tostring(rawget(m, "sent") ~= nil), table.concat(body, "|") }, "|")
end

local function show(seedtext)
  local seed = ""
  if seedtext then
    seed = work .. "/seed.txt"
    vim.fn.writefile(vim.split(seedtext, "\n", { plain = true }), seed)
  end
  local path = note.show({ target = "com.example.app", window = "4242", seed = seed })
  return path, vim.b.ferry.id, vim.api.nvim_get_current_buf()
end
local function set(lines) vim.api.nvim_buf_set_lines(0, 0, -1, false, lines) end
local function kinds() local k = {}; for _, c in ipairs(calls) do k[#k + 1] = c[1] end; return table.concat(k, ",") end

-- --- Submit ---------------------------------------------------------------
reset()
local p1, id1 = show()
check("note has Submit/Cancel/Hide commands and ZZ, <C-x>, ZQ maps",
  "2 2 2 <Cmd>Submit<CR> <Cmd>Submit<CR> <Cmd>Submit<CR> <Cmd>Cancel<CR>",
  table.concat({ vim.fn.exists(":Submit"), vim.fn.exists(":Cancel"), vim.fn.exists(":Hide"),
    vim.fn.maparg("ZZ", "n"), vim.fn.maparg("<C-x>", "n"), vim.fn.maparg("<C-x>", "i"),
    vim.fn.maparg("ZQ", "n") }, " "))
check("note has <C-q> maps (n, i) to Cancel", "<Cmd>Cancel<CR> <Cmd>Cancel<CR>",
  vim.fn.maparg("<C-q>", "n") .. " " .. vim.fn.maparg("<C-q>", "i"))
check("note has <C-s> maps (n, i) to the Flow toggle", true,
  vim.fn.maparg("<C-s>", "n"):find("ferry.flow'.toggle()", 1, true) ~= nil
  and vim.fn.maparg("<C-s>", "i") == vim.fn.maparg("<C-s>", "n"))
set({ "hello world", "second line" })
vim.cmd("Submit")
check("Submit calls host.submit once", "submit", kinds())
local c = calls[1] or { nil, {} }
check("host.submit gets target and window", "com.example.app 4242", tostring(c[2].target) .. " " .. tostring(c[2].window))
check("submit file holds the text", "hello world\nsecond line\n", c[3])
check("Submit records a submitted row with the text", "submitted hello world",
  outcome(id1) .. " " .. ((row(id1) or {}).preview or ""))
check("Submit keeps the note file: sent, sent time, target, the body only",
  "sent|app:com.example.app#4242|true|hello world|second line", nfile(p1))
check("the note file is named <date>-<time>-<id8>.md", true,
  vim.fs.basename(p1):match("^%d%d%d%d%-%d%d%-%d%d%-%d%d%d%d%d%d%-" .. id1:sub(1, 8) .. "%.md$") ~= nil)
check("Submit leaves the server running", vim.NIL, vim.v.exiting)
check("submit file is $FERRY_OUTBOX/<id>.md", vim.env.FERRY_OUTBOX .. "/" .. id1 .. ".md", c[2].file)
local blank_id = (vim.b.ferry or {}).id
check("after Submit the window shows a new empty note with :Hide and the :q abbreviation",
  "markdown 2 true ",
  table.concat({ vim.bo.filetype, vim.fn.exists(":Hide"),
    tostring(blank_id ~= nil and blank_id ~= id1 and vim.fn.maparg("q", "c", true) ~= ""),
    table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "|") }, " "))
check("the blank note has no history row before show", "none", outcome(blank_id))
local blank_path = vim.api.nvim_buf_get_name(0)
local p2, id2 = show()
check("an untouched blank note leaves no file", "0 0", vim.fn.filereadable(blank_path) .. " " .. vim.fn.filereadable(p2))
check("after Submit the next show is fresh", true, p2 ~= p1 and id2 ~= id1)
check("next show resumes the blank note", blank_id, id2)
check("fresh note is only the target header", "to: app:com.example.app#4242|", table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "|"))
-- history start runs in the background; give it a moment.
vim.wait(3000, function() return outcome(id2) == "open" end, 20)
check("fresh note has an open row", "open", outcome(id2))

-- --- Cancel ---------------------------------------------------------------
reset()
set({ "not this one" })
vim.cmd("Cancel")
check("Cancel calls host.hide only", "hide", kinds())
check("Cancel records a cancelled row", "cancelled", outcome(id2))
check("Cancel keeps the note file as cancelled", "cancelled|app:com.example.app#4242|false|not this one", nfile(p2))
local p3, id3 = show()
check("after Cancel the next show is fresh", true, id3 ~= id2)

-- --- blank Submit ---------------------------------------------------------
reset()
set({ "  ", "" })
vim.cmd("Submit")
check("blank Submit calls host.hide only", "hide", kinds())
check("blank Submit drops the row", "none", outcome(id3))
check("blank Submit leaves no note file", "none", nfile(p3))

-- --- unchanged-seed Submit -----------------------------------------------
reset()
local blank4 = vim.b.ferry.id
local _, id4 = show("selected text\nline two")
local function has_buf(id)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and (vim.b[b].ferry or {}).id == id then return true end
  end
  return false
end
check("a seeded show drops the unused blank note", "none false", outcome(blank4) .. " " .. tostring(has_buf(blank4)))
check("seeded note shows the header, then the seed", "to: app:com.example.app#4242|selected text|line two",
  table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "|"))
vim.cmd("Submit")
check("unchanged-seed Submit calls host.hide only", "hide", kinds())
check("unchanged-seed Submit records a cancelled row", "cancelled", outcome(id4))

-- --- Hide keeps the draft ---------------------------------------------------
reset()
local p5, id5 = show()
set({ "keep me" })
vim.cmd("Hide")
check("Hide calls host.hide only", "hide", kinds())
check("Hide writes the draft file, the captured target with it", "draft|app:com.example.app#4242|false|keep me",
  nfile(p5))
check("Hide sets g:ferry_draft", p5, vim.g.ferry_draft)
-- history start runs in the background.
vim.wait(3000, function() return outcome(id5) == "open" end, 20)
check("Hide leaves the row open", "open", outcome(id5))
local p6, id6 = show()
check("next show resumes the draft", p5 .. " " .. id5 .. " keep me",
  p6 .. " " .. id6 .. " " .. table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "|"))

-- --- history sidebar excludes the current note -----------------------------
local _, id9 = show()
local fin = work .. "/fin.txt"
vim.fn.writefile({ "listed elsewhere" }, fin)
vim.fn.system({ db, "finish", id9, "submitted", fin })
local hist = require("ferry.history")
local function listed(id)
  for _, r in ipairs(hist.load()) do if r.id == id then return true end end
  return false
end
check("history excludes b:ferry.id of the note", false, listed(id9))
check("history lists other notes", true, listed(id1))
show()
vim.cmd("Cancel")

-- --- the to: header (target spec) -----------------------------------------
local function lines() return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "|") end
local function header(spec) vim.api.nvim_buf_set_lines(0, 0, 1, false, { "to: " .. spec }) end
local function body(b) vim.api.nvim_buf_set_lines(0, 1, -1, false, b) end
local function sent() local c = calls[1] or { nil, {} }
  return kinds() .. " " .. tostring(c[2].target) .. " " .. tostring(c[2].window) .. " " .. tostring(c[3])
end

reset()
local _, idh = show()
check("show: line 1 is the captured target, cursor on row 2", "to: app:com.example.app#4242 2",
  vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] .. " " .. vim.api.nvim_win_get_cursor(0)[1])
check("show: b:ferry.auto_spec is the header's spec", "app:com.example.app#4242", vim.b.ferry.auto_spec)
body({ "only the body", "two" })
vim.cmd("Submit")
check("Submit: host.submit gets the header's target and window, the file only the body",
  "submit com.example.app 4242 only the body\ntwo\n", sent())
check("Submit: history row target is the spec", "submitted app:com.example.app#4242",
  outcome(idh) .. " " .. tostring((row(idh) or {}).target))

reset()
local _, idh2 = show()
header("app:com.other#7")
body({ "elsewhere" })
vim.cmd("Submit")
check("header edited to app:com.other#7: sent there", "submit com.other 7 elsewhere\n", sent())
check("edited header: history row target is that spec", "app:com.other#7", tostring((row(idh2) or {}).target))

reset()
show()
header("app:com.nowin")
body({ "no window" })
vim.cmd("Submit")
check("header without a window: sent to the app, window empty", "submit com.nowin  no window\n", sent())

reset()
show()
set({ "no header here" })
vim.cmd("Submit")
check("header deleted: sent to the captured target", "submit com.example.app 4242 no header here\n", sent())

reset()
local _, idh3 = show()
vim.cmd("Submit")
check("header only: Submit cancels (hide, the empty row is dropped)", "hide none", kinds() .. " " .. outcome(idh3))

for _, case in ipairs({
  { "bogus:x", "is not valid" },
  { "fleet:task:x", "cannot be sent to yet" },
}) do
  reset(); notices = {}; clip["+"] = nil
  local _, idb = show()
  header(case[1])
  body({ "keep this", "safe" })
  vim.cmd("Submit")
  check("to: " .. case[1] .. ": no host call, + holds the body", " keep this\nsafe",
    kinds() .. " " .. table.concat(clip["+"] or {}, "\n"))
  check("to: " .. case[1] .. ": notifies copied — target", true,
    (notices[#notices] or ""):find('ferry: copied — target "' .. case[1] .. '" ' .. case[2], 1, true) ~= nil)
  vim.wait(3000, function() return outcome(idb) == "open" end, 20)
  check("to: " .. case[1] .. ": note still current and shown, row open",
    idb .. " to: " .. case[1] .. "|keep this|safe open",
    tostring((note.current() or {}).id) .. " " .. lines() .. " " .. outcome(idb))
  set({ "" })
  vim.cmd("Cancel")
end

reset()
show()
check("resumed blank note gets the header, cursor on row 2", "to: app:com.example.app#4242| 2",
  lines() .. " " .. vim.api.nvim_win_get_cursor(0)[1])
note.show({ target = "com.b", window = "9" })
check("resume from com.b 9 replaces the automatic header", "to: app:com.b#9|", lines())
header("app:com.kept#1")
note.show({ target = "com.c", window = "3" })
check("resume keeps an edited header", "to: app:com.kept#1|", lines())
set({ "" })
vim.cmd("Cancel")
note.show({ target = "", window = "" })
check("nothing captured: the header is to: clipboard", "to: clipboard|", lines())
local lb = vim.api.nvim_get_current_buf()
local lm = vim.b[lb].ferry; lm.auto_spec = nil; vim.b[lb].ferry = lm
set({ "old draft" })
show()
check("a draft from before headers gets one above its text", "to: app:com.example.app#4242|old draft", lines())
vim.cmd("Cancel")

-- A header already on line 1 with no auto_spec (a draft last held by a
-- module without auto_spec) is never stacked under a second one.
local function drop_auto()
  local b = vim.api.nvim_get_current_buf()
  local m = vim.b[b].ferry; m.auto_spec = nil; vim.b[b].ferry = m
end
reset()
note.show({ target = "com.a", window = "1" })
body({ "hello body" })
drop_auto()
note.draft()
note.show({ target = "com.a", window = "1" })
check("no auto_spec, header already there: one header", "to: app:com.a#1|hello body", lines())
vim.cmd("Submit")
check("no auto_spec, header already there: Submit sends only the body",
  "submit com.a 1 hello body\n", sent())
reset()
note.show({ target = "com.a", window = "1" })
set({ "to: app:com.a#1", "to: app:com.a#1", "stacked" })
drop_auto()
note.draft()
note.show({ target = "com.a", window = "1" })
check("no auto_spec, stacked headers: collapsed to one", "to: app:com.a#1|stacked", lines())
vim.cmd("Submit")
check("no auto_spec, stacked headers: Submit sends only the body", "submit com.a 1 stacked\n", sent())
reset()
note.show({ target = "com.a", window = "1" })
body({ "follow" })
drop_auto()
note.draft()
note.show({ target = "com.b", window = "9" })
check("no auto_spec, header equal to the captured spec follows com.b 9", "to: app:com.b#9|follow", lines())
note.show({ target = "com.c", window = "2" })
check("... and is automatic again after that", "to: app:com.c#2|follow", lines())
set({ "to: app:com.other#7", "edited" })
drop_auto()
note.draft()
note.show({ target = "com.b", window = "9" })
check("no auto_spec, edited header is kept", "to: app:com.other#7|edited", lines())
note.show({ target = "com.d", window = "4" })
check("... and still kept on the next show", "to: app:com.other#7|edited", lines())
set({ "" })
vim.cmd("Cancel")
reset()
note.show({ target = "com.a", window = "1" })
set({ "to: app:com.a#1", "to: app:com.a#1", "direct" })
vim.cmd("Submit")
check("Submit drops header repeats under line 1", "submit com.a 1 direct\n", sent())

-- --- clipboard target and copy-and-hide (T3) -----------------------------
local function clipped() return table.concat(clip["+"] or {}, "\n") end
local function target_of(id) return tostring((row(id) or {}).target) end
reset(); clip["+"] = nil
local _, idc = show()
header("clipboard")
body({ "copy me", "two" })
vim.cmd("Submit")
check("to: clipboard + Submit: + holds the body, one hide, no submit", "hide copy me\ntwo", kinds() .. " " .. clipped())
check("to: clipboard + Submit: row submitted, target clipboard", "submitted clipboard",
  outcome(idc) .. " " .. target_of(idc))
local _, idc2 = show()
check("after a clipboard Submit the next show is fresh", "true to: app:com.example.app#4242|",
  tostring(idc2 ~= idc) .. " " .. lines())

check("note has :Copy and <C-y> maps (n, i)", "2 <Cmd>Copy<CR> <Cmd>Copy<CR>",
  vim.fn.exists(":Copy") .. " " .. vim.fn.maparg("<C-y>", "n") .. " " .. vim.fn.maparg("<C-y>", "i"))
reset(); clip["+"] = nil
vim.wait(3000, function() return outcome(idc2) == "open" end, 20)
vim.api.nvim_feedkeys(vim.keycode("Ayanked<C-y>"), "x", false)
check("<C-y> in insert mode on an app note: + holds the body, one hide, no submit", "hide yanked",
  kinds() .. " " .. clipped())
check("<C-y>: row submitted, target clipboard", "submitted clipboard", outcome(idc2) .. " " .. target_of(idc2))
local _, idc3 = show()
check("after <C-y> the next show is fresh", "true to: app:com.example.app#4242|",
  tostring(idc3 ~= idc2) .. " " .. lines())

reset(); clip["+"] = nil
header("bogus:x")
body({ "any header" })
vim.cmd("Copy")
check(":Copy ignores a header that does not parse", "hide any header submitted clipboard",
  kinds() .. " " .. clipped() .. " " .. outcome(idc3) .. " " .. target_of(idc3))

reset(); clip["+"] = nil
local _, idc4 = show()
vim.cmd("Copy")
check(":Copy of a blank body cancels: hide, + untouched, row dropped", "hide  none",
  kinds() .. " " .. clipped() .. " " .. outcome(idc4))

-- A clipboard copy that throws or silently drops the text: the note is
-- never finished on a copy that did not take (GT 2).
local CLIP_FAIL = "ferry: could not copy to the clipboard — note kept"
for _, mode in ipairs({ "throw", "drop" }) do
  for _, case in ipairs({
    { ":Copy", nil, "Copy" },
    { "to: clipboard + Submit", "clipboard", "Submit" },
    { "to: fleet:task:x + Submit", "fleet:task:x", "Submit" },
    { "to: bogus:x + Submit", "bogus:x", "Submit" },
  }) do
    reset(); clip["+"] = nil; notices = {}
    local _, idf, bf = show()
    vim.wait(3000, function() return outcome(idf) == "open" end, 20)
    if case[2] then header(case[2]) end
    body({ "do not lose", "me" })
    local want_lines = lines()
    clip_mode = mode
    local ok, e = pcall(vim.cmd, case[3])
    clip_mode = nil
    local name = "copy " .. mode .. ", " .. case[1]
    -- An ERROR notice surfaces as a Vim error under pcall; nothing else may.
    check(name .. ": no error but the notice", true, ok or tostring(e):find(CLIP_FAIL, 1, true) ~= nil)
    check(name .. ": no host call, + empty", " ", kinds() .. " " .. clipped())
    check(name .. ": note current and shown, text kept, row open",
      idf .. " true " .. want_lines .. " open",
      tostring((note.current() or {}).id) .. " " .. tostring(vim.api.nvim_get_current_buf() == bf)
      .. " " .. lines() .. " " .. outcome(idf))
    check(name .. ": error notice, never copied", true,
      (notices[#notices] or ""):find(CLIP_FAIL, 1, true) ~= nil
      and not table.concat(notices, "\n"):find("copied", 1, true))
    set({ "" })
    vim.cmd("Cancel")
  end
end
reset(); clip["+"] = nil
local _, idw = show()
body({ "works again" })
vim.cmd("Copy")
check("after the fake copy works again, :Copy copies and hides", "hide works again submitted",
  kinds() .. " " .. clipped() .. " " .. outcome(idw))

-- --- note files (H3) -------------------------------------------------------
reset()
local pa, ida, ba = show()
check("a fresh note has no file until it changes", 0, vim.fn.filereadable(pa))
body({ "autosaved text" })
vim.api.nvim_exec_autocmds("TextChanged", { buffer = ba })
vim.wait(500)
check("autosave waits about 1 s", 0, vim.fn.filereadable(pa))
vim.wait(3000, function() return vim.fn.filereadable(pa) == 1 end, 20)
check("autosave after a change: draft, target, text; the buffer has no frontmatter",
  "draft|app:com.example.app#4242|false|autosaved text to: app:com.example.app#4242|autosaved text",
  nfile(pa) .. " " .. lines())
local fm = store.read(pa)
check("the file has id, created and updated", true,
  rawget(fm, "id") == ida and rawget(fm, "created") ~= nil and rawget(fm, "updated") ~= nil)
check("autosave leaves the buffer unmodified", false, vim.bo[ba].modified)
-- :w writes through the note file format.
body({ "written by :w" })
vim.cmd("write")
check(":w writes the frontmatter and the body", "---|draft|written by :w",
  (readfile(pa) or ""):match("^[^\n]*") .. "|" .. nfile(pa):match("^[^|]*") .. "|" .. nfile(pa):match("[^|]*$"))
-- Unknown keys and pinned survive a save. The pin is an outside write to
-- an unchanged buffer: checktime reloads it ('autoread', through
-- BufReadCmd), so the next save is no conflict.
local m2, b2 = store.read(pa)
store.set(m2, "pinned", true); store.set(m2, "mood", "calm")
table.insert(b2, "pinned elsewhere")
store.write(pa, m2, b2)
notices = {}
vim.cmd("checktime")
vim.wait(300)
check("an outside write to an unchanged buffer: checktime reloads it, no notice, no prompt",
  "0 false to: app:com.example.app#4242|written by :w|pinned elsewhere",
  #notices .. " " .. tostring(vim.bo[ba].modified) .. " " .. lines())
body({ "after pin" })
vim.cmd("write")
local m3 = store.read(pa)
check("a save keeps pinned and unknown keys, same file", "true calm true",
  tostring(rawget(m3, "pinned")) .. " " .. tostring(rawget(m3, "mood")) .. " "
  .. tostring(vim.fn.resolve(vim.api.nvim_buf_get_name(ba)) == vim.fn.resolve(pa)))
-- A body line starting with to: stays body on reload (fixture body-to.md:
-- no target in the file, so the captured target becomes the header).
local fx = io.open(root .. "/tests/fixtures/notes/body-to.md"):read("a")
local f = io.open(pa, "w"); f:write(fx); f:close()
vim.cmd("edit!")
check(":e! of a file without a target: captured header, body line to: x stays body",
  "to: app:com.example.app#4242|to: x|The first body line looks like a header but is body.", lines())
vim.cmd("write")
vim.cmd("edit!")
check("... saved and read again: target stored, to: x still body",
  "draft|app:com.example.app#4242|false|to: x|The first body line looks like a header but is body. "
  .. "to: app:com.example.app#4242|to: x|The first body line looks like a header but is body.",
  nfile(pa) .. " " .. lines())
-- No to: line in the buffer: the captured target is stored.
set({ "to: y is not line 1", "plain" })
set({ "plain", "to: y" })
vim.cmd("write")
check("no header in the buffer: the file stores the captured target", "draft|app:com.example.app#4242|false|plain|to: y",
  nfile(pa))
-- A blank Cancel deletes the file; nothing else is ever deleted.
set({ "to: app:com.example.app#4242", "" })
vim.cmd("Cancel")
check("blank Cancel deletes the note file", 0, vim.fn.filereadable(pa))
-- The index sees the files (ferry-notes index runs in the background).
local _, idx, bx = show()
body({ "indexed and sent" })
vim.cmd("Submit")
local function listed_state(id)
  local out = vim.fn.system({ root .. "/bin/ferry-notes", "list" })
  for _, r in ipairs(vim.v.shell_error == 0 and vim.json.decode(out) or {}) do
    if r.id == id then return r.state .. " " .. r.preview end
  end
  return "none"
end
vim.wait(5000, function() return listed_state(idx) ~= "none" end, 50)
check("ferry-notes list shows the sent note", "sent indexed and sent", listed_state(idx))
check("ferry-notes list leaves out deleted blank cancels", "none", listed_state(ida))
local _ = bx

-- --- outside edits (H3b) ---------------------------------------------------
local notes = vim.env.FERRY_NOTES_DIR
local function conflicts()
  local out = {}
  for name in vim.fs.dir(notes) do
    if name:find("%.conflict%-") then out[#out + 1] = notes .. "/" .. name end
  end
  table.sort(out)
  return out
end
local function same(a, b) return vim.fn.resolve(a) == vim.fn.resolve(b) end
local function changed(buf) vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf }) end
local T = "draft|app:com.example.app#4242|false|"
-- ferry's own writes never prompt or fork: autosaves and :w, each followed
-- by a checktime.
reset(); notices = {}
local po, ido, bo = show()
for i = 1, 3 do
  body({ "own write " .. i })
  changed(bo)
  vim.wait(3000, function() return nfile(po):find("own write " .. i, 1, true) ~= nil end, 20)
  vim.cmd("checktime")
  vim.wait(100)
end
body({ "own :w" })
vim.cmd("write")
vim.cmd("checktime")
vim.wait(200)
check("ferry's own writes: no notice, no conflict file, same file", "0 0 true " .. T .. "own :w",
  #notices .. " " .. #conflicts() .. " " .. tostring(same(vim.api.nvim_buf_get_name(bo), po)) .. " " .. nfile(po))

-- An outside edit while ferry has unsaved typing: both texts survive.
local mo = store.read(po)
store.write(po, mo, { "outside edit" })
body({ "ferry typing" })
changed(bo)
vim.wait(3000, function() return #conflicts() > 0 end, 20)
vim.wait(100)
local cf = conflicts()[1] or ""
local cm = store.read(cf) or {}
check("outside edit + typing: the file keeps the outside edit", T .. "outside edit", nfile(po))
check("outside edit + typing: a conflict file beside it holds ferry's text, state draft",
  T .. "ferry typing", nfile(cf))
local stem = vim.fs.basename(po):gsub("%.md$", "")
check("the conflict file is <name>.conflict-<time>.md, fresh id, conflict_of, same created", true,
  vim.fs.basename(cf):match("^" .. vim.pesc(stem) .. "%.conflict%-[%d%-]+%.md$") ~= nil
  and rawget(cm, "id") ~= ido and rawget(cm, "conflict_of") == ido and rawget(cm, "created") == rawget(mo, "created"))
check("outside edit + typing: one notice naming both files", true,
  #notices == 1 and notices[1]:find(vim.fs.basename(po), 1, true) ~= nil
  and notices[1]:find(vim.fs.basename(cf), 1, true) ~= nil)
check("the buffer and the current note move to the conflict file; the note keeps its id", true,
  same(vim.api.nvim_buf_get_name(bo), cf) and same(note.current().path, cf) and note.current().id == ido
  and note.current().file_id == rawget(cm, "id"))
-- Later saves go to the conflict file, with no further notice.
body({ "ferry typing more" })
changed(bo)
vim.wait(3000, function() return nfile(cf):find("more", 1, true) ~= nil end, 20)
check("later saves: the conflict file, original untouched, still one notice",
  T .. "ferry typing more " .. T .. "outside edit 1 1",
  nfile(cf) .. " " .. nfile(po) .. " " .. #notices .. " " .. #conflicts())
-- The conflict file deleted outside: the next save recreates it as the
-- fork (its own id and conflict_of), never under the original's id.
os.remove(cf)
body({ "ferry typing more", "after delete" })
changed(bo)
vim.wait(3000, function() return vim.fn.filereadable(cf) == 1 end, 20)
local rm = store.read(cf) or {}
check("conflict file deleted outside: the next save recreates it with the fork's id and conflict_of",
  tostring(rawget(cm, "id")) .. " " .. ido .. " " .. T .. "ferry typing more|after delete",
  tostring(rawget(rm, "id")) .. " " .. tostring(rawget(rm, "conflict_of")) .. " " .. nfile(cf))
-- An outside edit found by checktime while ferry has unsaved typing forks
-- at once, without waiting for the autosave.
store.write(cf, store.read(cf), { "second outside" })
body({ "typing again" })
notices = {}
vim.cmd("checktime")
vim.wait(1000, function() return #conflicts() > 1 end, 20)
local cf2 = vim.tbl_filter(function(x) return x ~= cf end, conflicts())[1] or ""
check("checktime with unsaved typing: forks at once, one notice, both texts kept",
  "1 " .. T .. "second outside " .. T .. "typing again", #notices .. " " .. nfile(cf) .. " " .. nfile(cf2))
check("forking a conflict file names it after the original stem (no chained .conflict-)", true,
  vim.fs.basename(cf2):match("^" .. vim.pesc(stem) .. "%.conflict%-[%d%-]+%.md$") ~= nil)
-- A blank Cancel never deletes a file changed outside.
store.write(cf2, store.read(cf2), { "outside again" })
set({ "to: app:com.example.app#4242", "" })
vim.cmd("Cancel")
check("blank Cancel keeps a file changed outside ferry", T .. "outside again", nfile(cf2))
-- Submit over an outside edit forks too: the sent text is kept.
reset(); notices = {}
local ps = show()
body({ "first save" })
vim.cmd("write")
store.write(ps, store.read(ps), { "edited elsewhere" })
body({ "sent text" })
vim.cmd("Submit")
local sstem = vim.fs.basename(ps):gsub("%.md$", "")
local cs = vim.tbl_filter(function(x) return x:find(sstem, 1, true) ~= nil end, conflicts())
check("Submit over an outside edit: original kept, sent text in the conflict file, delivered",
  T .. "edited elsewhere sent|app:com.example.app#4242|true|sent text submit",
  nfile(ps) .. " " .. nfile(cs[1] or "") .. " " .. kinds())

-- A fork whose first write fails: the next save writes the conflict file
-- with the fork's id and conflict_of, the original is left alone.
reset(); notices = {}
local pf, idf, bf = show()
body({ "before" })
vim.cmd("write")
store.write(pf, store.read(pf), { "outside first" })
vim.fn.setfperm(notes, "r-xr-xr-x")
body({ "fork text" })
pcall(vim.cmd, "write")
vim.fn.setfperm(notes, "rwxr-xr-x")
local fstem = vim.fs.basename(pf):gsub("%.md$", "")
local function fconf()
  return vim.tbl_filter(function(x) return x:find(fstem, 1, true) ~= nil end, conflicts())
end
local fid = (vim.b[bf].ferry or {}).file_id
check("fork keeps the note's id (the history key); the fork's id is file_id", "true true",
  tostring(note.current() ~= nil and note.current().id == idf and vim.b[bf].ferry.id == idf) .. " "
  .. tostring(fid ~= nil and fid ~= idf))
check("fork's first write fails: no conflict file yet, original kept, buffer on the conflict name", "0 "
  .. T .. "outside first true", #fconf() .. " " .. nfile(pf) .. " "
  .. tostring(vim.api.nvim_buf_get_name(bf):find(fstem .. ".conflict-", 1, true) ~= nil))
body({ "fork text", "retried" })
vim.cmd("write")
local fm = store.read(fconf()[1] or "") or {}
check("fork's first write failed: the next save writes the fork's id and conflict_of, original untouched",
  "true " .. idf .. " " .. T .. "outside first",
  tostring(fid ~= idf and rawget(fm, "id") == fid) .. " " .. tostring(rawget(fm, "conflict_of")) .. " " .. nfile(pf))
vim.cmd("Cancel")

-- ferry remembers the bytes it wrote, not the file re-read after: an
-- outside write right after ferry's own write is never taken as ferry's.
reset(); notices = {}
local pg, _, bg = show()
local real_write, once = store.write, true
store.write = function(path, meta, lines)
  local ok, err = real_write(path, meta, lines)
  if ok and once and same(path, pg) then
    once = false
    real_write(path, store.read(path), { "slipped in" })
  end
  return ok, err
end
body({ "ferry wrote this" })
vim.cmd("write")
store.write = real_write
body({ "ferry again" })
vim.cmd("write")
local gstem = vim.fs.basename(pg):gsub("%.md$", "")
local gs = vim.tbl_filter(function(x) return x:find(gstem, 1, true) ~= nil end, conflicts())
check("an outside write right after ferry's write: kept, ferry's next save forks",
  T .. "slipped in 1 " .. T .. "ferry again",
  nfile(pg) .. " " .. #gs .. " " .. nfile(gs[1] or ""))
check("the outside write after ferry's: the buffer moved to the conflict file", true,
  same(vim.api.nvim_buf_get_name(bg), gs[1] or ""))
vim.cmd("Cancel")

-- The blank note after a Submit, written, edited outside and forked, then
-- shown and submitted: one history row, under the note's own id, submitted.
reset(); notices = {}
show()
set({ "to: app:com.example.app#4242", "sent before" })
vim.cmd("Submit")
local bb = vim.api.nvim_get_current_buf()
local bid = (vim.b.ferry or {}).id
set({ "typed into blank" })
vim.cmd("write")
local bp = vim.api.nvim_buf_get_name(bb)
store.write(bp, store.read(bp), { "blank edited elsewhere" })
set({ "typed into blank", "more" })
vim.cmd("write")
local bfork = (vim.b[bb].ferry or {}).file_id
show()
vim.cmd("Submit")
local function rows_for(ids)
  local q = "SELECT id || ':' || outcome FROM sessions WHERE id IN ('" .. table.concat(ids, "','") .. "') ORDER BY id"
  return vim.trim(vim.fn.system({ "sqlite3", vim.env.FERRY_DB, q }))
end
check("blank note forked then submitted: one history row, under the note's id, submitted",
  "true " .. tostring(bid) .. ":submitted",
  tostring(bfork ~= nil and bfork ~= bid) .. " " .. rows_for({ tostring(bid), tostring(bfork) }))

-- Cancel when the note file cannot be written: nothing is lost.
reset(); notices = {}
local pc, idc2, bc = show()
body({ "keep me" })
vim.cmd("write")
vim.fn.setfperm(notes, "r-xr-xr-x")
body({ "keep me", "more" })
local cancel_ok = pcall(vim.cmd, "Cancel")
vim.wait(300)
vim.fn.setfperm(notes, "rwxr-xr-x")
check("unwritable notes dir + Cancel raises no error", true, cancel_ok)
local outbox = vim.env.FERRY_OUTBOX .. "/" .. idc2 .. ".md"
check("unwritable notes dir + Cancel: no hide, buffer kept and current, history row open",
  " true true open", kinds() .. " " .. tostring(vim.api.nvim_buf_is_valid(bc)) .. " "
  .. tostring(note.current() ~= nil and note.current().buf == bc) .. " " .. outcome(idc2))
check("unwritable notes dir + Cancel: outbox copy kept, file unchanged, an alert names the copy",
  "keep me|more " .. T .. "keep me true",
  table.concat(vim.fn.readfile(outbox), "|") .. " " .. nfile(pc) .. " "
  .. tostring((notices[#notices] or ""):find(outbox, 1, true) ~= nil))
vim.cmd("Cancel")
check("Cancel again once writable: cancelled, outbox copy gone, hidden",
  "cancelled|app:com.example.app#4242|false|keep me|more 0 hide",
  nfile(pc) .. " " .. vim.fn.filereadable(outbox) .. " " .. kinds())

-- --- voice keys: Flow toggle and the wait for its last paste -------------
-- Flow pastes into the note as a bracketed paste, i.e. a vim.paste call.
local function paste_later(text, ms)
  vim.defer_fn(function()
    events[#events + 1] = "paste"
    vim.paste({ text }, -1)
  end, ms)
end
local function at_end() vim.cmd("normal! G$") end

reset(); events = {}
show()
vim.cmd("Dictate")
check(":Dictate starts Flow", "start-hands-free true", flow_events() .. " " .. tostring(flow.recording()))
vim.api.nvim_feedkeys(vim.keycode("<C-s>"), "x", false)
check("<C-s> after :Dictate stops Flow", "stop-hands-free false", flow_events() .. " " .. tostring(flow.recording()))

reset(); events = {}
local _, id7 = show()
vim.cmd("stopinsert")
set({ "typed" })
at_end()
vim.api.nvim_feedkeys(vim.keycode("<C-s>"), "x", false)
paste_later(" pasted", 300)
vim.cmd("Submit")
check("Submit while recording waits (no host call yet)", "", kinds())
vim.wait(3000, function() return #calls > 0 end, 10)
vim.wait(100)
check("Ctrl-S then :Submit: start, stop, paste, then one host.submit",
  "start-hands-free,stop-hands-free,paste,submit", flow_events())
check("Ctrl-S then :Submit: file holds typed and pasted text", "submit typed pasted\n",
  kinds() .. " " .. tostring((calls[1] or {})[3]))
check("Ctrl-S then :Submit records a submitted row", "submitted", outcome(id7))

reset(); events = {}
local _, id8 = show()
vim.cmd("stopinsert")
set({ "never mind" })
at_end()
flow.toggle()
paste_later(" more", 300)
vim.cmd("Cancel")
vim.wait(100)
check("Cancel while recording sends stop and waits", "start-hands-free,stop-hands-free ",
  table.concat(events, ",") .. " " .. kinds())
vim.wait(3000, function() return #calls > 0 end, 10)
vim.wait(100)
check("Cancel while recording: host.hide only after the paste",
  "start-hands-free,stop-hands-free,paste,hide", flow_events())
check("Cancel while recording records a cancelled row", "cancelled", outcome(id8))
check("Flow is idle after the voice-key cases", false, flow.recording())

-- --- hold to talk: release, and draft (the main hotkey) during its wait ---
reset(); events = {}
local pt = note.show({ target = "com.example.app", window = "4242", talk = "1" })
check("show{talk}: Flow recording, no URL, insert on row 2", "true  2",
  tostring(flow.recording()) .. " " .. flow_events() .. " " .. vim.api.nvim_win_get_cursor(0)[1])
body({ "spoken" })
at_end()
check("release: one stop, prints released", "released stop-hands-free", note.release() .. " " .. flow_events())
check("release wait has kind release", "release", (flow.state.waiting or {}).kind)
check("draft during a release wait: waiting for flow, no host call yet", "waiting for flow " .. pt .. " ",
  note.draft() .. " " .. kinds())
paste_later(" words", 200)
vim.wait(3000, function() return #calls > 0 end, 10)
vim.wait(100)
check("draft during a release wait: one host.hide after the paste", "paste,hide hide", flow_events() .. " " .. kinds())
check("draft during a release wait: the file holds the paste", "draft|app:com.example.app#4242|false|spoken words",
  nfile(pt))
check("release while idle prints idle, sends nothing", "idle ", note.release() .. " " .. flow_events())

reset(); events = {}
note.show({ target = "com.example.app", window = "4242" })
body({ "send me" })
at_end()
flow.assume_recording()
vim.cmd("Submit")
check("draft during a Submit wait: waiting for flow, no host call", "waiting for flow " .. pt .. " ",
  note.draft() .. " " .. kinds())
paste_later(" too", 200)
vim.wait(3000, function() return #calls > 0 end, 10)
vim.wait(300)
check("draft during a Submit wait: only host.submit after the paste, with the paste",
  "stop-hands-free,paste,submit submit send me too\n", flow_events() .. " " .. kinds() .. " " .. tostring((calls[1] or {})[3]))

-- --- default host ---------------------------------------------------------
note.host = note.default_host
local log = work .. "/open.log"
local function opened() return readfile(log) or "" end
local function wait_for(pat) vim.wait(3000, function() return opened():find(pat, 1, true) ~= nil end, 20) end

show()
set({ "via hammerspoon" })
vim.cmd("Submit")
wait_for("ferry-submit")
local line = opened():match("[^\n]*ferry%-submit[^\n]*") or ""
check("default host runs open -g with the submit URL", true, line:find("^%-g hammerspoon://ferry%-submit%?file=") ~= nil)
check("submit URL contains target=com.example.app&window=4242", true,
  line:find("target=com.example.app&window=4242", 1, true) ~= nil)
local file = vim.uri_decode(line:match("file=([^&]*)") or "")
check("submit URL names the file holding the text", "via hammerspoon\n", readfile(file))
os.remove(file)

os.remove(log)
show()
set({ "cancel via hammerspoon" })
vim.cmd("Cancel")
wait_for("ferry-hide")
check("default host hides via hammerspoon://ferry-hide", "-g hammerspoon://ferry-hide\n", opened())

-- open fails: text goes on the clipboard with a notice.
vim.fn.writefile({}, work .. "/open.fail")
notices = {}
show()
set({ "clipboard fallback" })
vim.cmd("Submit")
vim.wait(3000, function() return #notices > 0 end, 20)
check("failed open copies the text to +", "clipboard fallback", table.concat(clip["+"] or {}, "\n"))
check("failed open notifies copied — paste manually", "ferry: copied — paste manually", notices[1])
for _, mode in ipairs({ "throw", "drop" }) do
  notices = {}; clip["+"] = nil; clip_mode = mode
  show()
  set({ "fallback " .. mode })
  vim.cmd("Submit")
  vim.wait(3000, function() return #notices > 0 end, 20)
  clip_mode = nil
  local kept = (notices[1] or ""):match("text kept in (%S+)$")
  check("failed open, copy " .. mode .. ": + empty, error notice names the kept file",
    "  fallback " .. mode .. "\n",
    table.concat(clip["+"] or {}, "\n") .. " " .. tostring((notices[1] or ""):find("could not", 1, true) and "")
    .. " " .. tostring(kept and readfile(kept)))
  if kept then os.remove(kept) end
end
os.remove(work .. "/open.fail")

say(fail == 0 and "note_spec: all ok" or "note_spec: FAILED")
os.exit(fail)
