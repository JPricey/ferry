-- The notes browser (lua/ferry/history.lua) on a fixture notes folder, with
-- a recording stub host and a fake clipboard.
-- Run by tests/test-history.sh: nvim --headless --clean -l tests/history_spec.lua <root> <work>
-- The shell sets FERRY_NOTES_DIR, FERRY_INDEX and FERRY_OUTBOX to temp
-- paths.
local root, work = arg[1], arg[2]
vim.opt.rtp:prepend(root)
local note = require("ferry.note")
local store = require("ferry.store")
local dir = vim.env.FERRY_NOTES_DIR

-- Never touch the system clipboard. clip_mode "throw": the + copy raises.
local clip, clip_mode = {}, nil
vim.g.clipboard = {
  name = "ferry-test",
  copy = {
    ["+"] = function(lines)
      if clip_mode == "throw" then error("fake clipboard copy failed") end
      clip["+"] = lines
    end,
    ["*"] = function(lines) clip["*"] = lines end,
  },
  paste = { ["+"] = function() return clip["+"] or {} end, ["*"] = function() return clip["*"] or {} end },
}
local notices = {}
vim.notify = function(msg) notices[#notices + 1] = msg end

io.stdout:setvbuf("line")
local fail = 0
local function check(name, want, got)
  if want == got then
    io.stdout:write("ok   ", name, "\n")
  else
    io.stdout:write("FAIL ", name, ": want '", tostring(want), "' got '", tostring(got), "'\n")
    fail = 1
  end
end

-- Fixture notes: today at 10:00 (draft), 09:00 (sent), 08:00 (cancelled),
-- and yesterday at 07:00 (sent, pinned).
local function iso(t)
  local z = os.date("%z", t)
  return os.date("%Y-%m-%dT%H:%M:%S", t) .. z:sub(1, 3) .. ":" .. z:sub(4, 5)
end
local function at(h, days)
  local d = os.date("*t")
  d.hour, d.min, d.sec = h, 0, 0
  d.day = d.day - (days or 0)
  return os.time(d)
end
local paths = {}
local function fixture(name, id, state, t, body, extra)
  local meta = { "id", "state", "created", "updated", "target",
    id = id, state = state, created = iso(t), updated = iso(t), target = "app:com.example.app#1" }
  for k, v in pairs(extra or {}) do store.set(meta, k, v) end
  paths[name] = dir .. "/" .. store.name(t, id)
  vim.fn.mkdir(dir, "p")
  assert(store.write(paths[name], meta, body))
end
fixture("bravo", "bbbbbbbb-0000-4000-8000-000000000002", "draft", at(10), { "bravo draft" })
fixture("alpha", "aaaaaaaa-0000-4000-8000-000000000001", "sent", at(9), { "alpha sent", "line two" },
  { sent = iso(at(9)) })
fixture("charlie", "cccccccc-0000-4000-8000-000000000003", "cancelled", at(8), { "charlie cancelled" })
fixture("delta", "dddddddd-0000-4000-8000-000000000004", "sent", at(7, 1), { "delta pinned" },
  { pinned = "true" })
vim.fn.system({ root .. "/bin/ferry-notes", "rebuild" })

-- Recording stub host.
local calls = {}
note.host = {
  submit = function(p) calls[#calls + 1] = { p = p, text = table.concat(vim.fn.readfile(p.file), "|") } end,
  hide = function() end,
}

local h = require("ferry.history")
local function show(t, w)
  local p = note.show({ target = t, window = w })
  vim.cmd("stopinsert")
  h.refresh()
  return p
end
local function rows() -- the sidebar's row lines, joined by |
  local out = {}
  for ln, l in ipairs(vim.api.nvim_buf_get_lines(h.state.buf, 0, -1, false)) do
    out[#out + 1] = l
  end
  return table.concat(out, "|")
end
-- Press keys on the sidebar row whose line holds text.
local function press(text, keys)
  vim.api.nvim_set_current_win(h.state.win)
  for ln, l in ipairs(vim.api.nvim_buf_get_lines(h.state.buf, 0, -1, false)) do
    if h.state.map[ln] and l:find(text, 1, true) then vim.api.nvim_win_set_cursor(h.state.win, { ln, 0 }) end
  end
  vim.v.errmsg = ""
  local ok, err = pcall(vim.api.nvim_feedkeys, vim.keycode(keys), "xt", false)
  -- The search prompt is echoed without a newline: end its line.
  if keys:sub(1, 1) == "/" then io.stderr:write("\n") end
  return ok and vim.v.errmsg == "" and "" or ("error: " .. tostring(err) .. vim.v.errmsg)
end
local function fmeta(path, k) local m = store.read(path); return m and tostring(rawget(m, k)) or "none" end
local function fbody(path) local _, b = store.read(path); return b and table.concat(b, "|") or "none" end
local function buflines(b) return table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "|") end

-- The sidebar line holding text (a row), or "".
local function line_of(text)
  for _, l in ipairs(vim.api.nvim_buf_get_lines(h.state.buf, 0, -1, false)) do
    if l:find(text, 1, true) then return l end
  end
  return ""
end
local function n_open() return select(2, rows():gsub("▶", "")) end
local function stat(path) local s = vim.uv.fs_stat(path); return s and (s.mtime.sec .. "." .. s.mtime.nsec) or "none" end
local function bytes(path) return table.concat(vim.fn.readfile(path, "b"), "\n") end

-- The current note, with a file: listed in its place (newest first: its
-- time is now), marked ▶ before the other marks.
local cur = show("com.example.app", "4242")
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "current text" })
vim.cmd("silent write")
h.refresh()
check("rows: pinned first, then newest first; marks ★ pinned, ● draft, ~ cancelled; the app",
  "── Pinned| ★ 07:00 app     delta pinned||── Today|  ●10:00 app     bravo draft|   09:00 app     alpha sent|  ~08:00 app     charlie cancelled",
  (rows():gsub("|[^|]*current text", "")))
check("the current note's row is listed, marked ▶ first", true,
  line_of("current text"):find("^▶ ●%d%d:%d%d app     current text$") ~= nil)
check("one row marked ▶", 1, n_open())

-- Unsaved typing: listing shows the open note's first line from its buffer.
local cur_buf = vim.api.nvim_win_get_buf(h.state.main_win)
vim.api.nvim_buf_set_lines(cur_buf, 0, -1, false, { "current text edited" })
h.refresh()
check("a list shows the open note's unsaved first line", true,
  line_of("current text edited"):find("^▶ ●") ~= nil)

-- Keys on the open note's row.
local cur_bytes, cur_stat = bytes(cur), stat(cur)
check("<CR> on the open note's row runs without error", "", press("current text edited", "<CR>"))
check("<CR> on the open note's row: the same note current, the note window focused, nothing written",
  "true true current text edited true true", tostring(note.current().buf == cur_buf) .. " "
  .. tostring(vim.api.nvim_get_current_win() == h.state.main_win) .. " " .. buflines(cur_buf) .. " "
  .. tostring(bytes(cur) == cur_bytes and stat(cur) == cur_stat) .. " " .. tostring(vim.bo[cur_buf].modified))
notices = {}
check("d on the open note's row runs without error", "", press("current text edited", "d"))
check("d on the open note's row: refused with one notice, the file and the row kept",
  "ferry: this is the open note — Ctrl-Q cancels it 1 true current text edited",
  tostring(notices[#notices]) .. " " .. vim.fn.filereadable(cur) .. " "
  .. tostring(line_of("current text edited") ~= "") .. " " .. buflines(cur_buf))
notices = {}
check("i on the open note's row runs without error", "", press("current text edited", "i"))
check("i on the open note's row: refused with a notice, the note unchanged",
  "true current text edited", tostring(tostring(notices[#notices]):find("this is the open note", 1, true) ~= nil)
  .. " " .. buflines(cur_buf))
press("current text edited", "y")
check("y on the open note's row copies its buffer", "current text edited", table.concat(clip["+"] or {}, "|"))
press("current text edited", "K")
check("K on the open note's row previews its buffer", "current text edited",
  h.state.preview_win and vim.api.nvim_win_is_valid(h.state.preview_win)
  and buflines(vim.api.nvim_win_get_buf(h.state.preview_win)) or "none")
h.close_preview()
press("current text edited", "P")
check("P on the open note's row: saved, then pinned in the file; the row under Pinned, ▶★",
  "true current text edited true", fmeta(cur, "pinned") .. " " .. fbody(cur) .. " "
  .. tostring(rows():find("── Pinned|▶★●", 1, true) == 1))
press("current text edited", "P")
check("P again unpins it", "nil", fmeta(cur, "pinned"))
-- The pin was ferry's own write: the next save is not an outside edit.
vim.api.nvim_buf_set_lines(cur_buf, 0, -1, false, { "current text edited" })
vim.api.nvim_buf_call(cur_buf, function() vim.cmd("silent write") end)
check("after P, the next save writes the same file (no conflict file)", "0 current text edited",
  #vim.fn.glob(dir .. "/*.conflict-*", false, true) .. " " .. fbody(cur))

-- <CR>: bravo becomes the current note; the old one (unsaved typing) is
-- kept as a draft file and listed.
vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(h.state.main_win), 0, -1, false, { "current text edited" })
local old_buf = vim.api.nvim_win_get_buf(h.state.main_win)
check("<CR> runs without error", "", press("bravo draft", "<CR>"))
local nb = vim.api.nvim_get_current_buf()
check("<CR> makes that note current, in the note window, focused",
  "true true bravo draft", tostring(vim.fn.resolve(note.current().path) == vim.fn.resolve(paths.bravo))
  .. " " .. tostring(vim.api.nvim_get_current_win() == h.state.main_win) .. " " .. buflines(nb))
check("<CR>: the opened note takes the target of the latest show", "com.example.app 4242",
  vim.b[nb].ferry.target .. " " .. vim.b[nb].ferry.window)
check("<CR>: the old note is a draft file with its unsaved typing, its buffer let go",
  "draft current text edited false", fmeta(cur, "state") .. " " .. fbody(cur) .. " "
  .. tostring(vim.api.nvim_buf_is_valid(old_buf)))
check("<CR>: the marker moves to the opened note; the old one is listed as a draft, unmarked",
  "true true 1", tostring(line_of("bravo draft"):find("^▶ ●") ~= nil) .. " "
  .. tostring(line_of("current text edited"):find("^  ●") ~= nil) .. " " .. n_open())
-- Edited, the opened note saves into the same file as a draft.
vim.api.nvim_buf_set_lines(nb, 0, -1, false, { "bravo draft", "more" })
vim.cmd("silent write")
check("the opened note writes its own file", "draft bravo draft|more bbbbbbbb-0000-4000-8000-000000000002",
  fmeta(paths.bravo, "state") .. " " .. fbody(paths.bravo) .. " " .. fmeta(paths.bravo, "id"))

-- s: open alpha and send it again, in place, to the latest show's target.
show("com.second", "77")
local sent_before = fmeta(paths.alpha, "sent")
calls = {}
check("s runs without error", "", press("alpha sent", "s"))
check("s calls host.submit once with that note's body and the latest target",
  "1 com.second 77 alpha sent|line two", #calls .. " " .. (calls[1] and (calls[1].p.target .. " "
  .. calls[1].p.window .. " " .. calls[1].text) or ""))
check("s: the same file says state sent, with a new sent time", "sent true",
  fmeta(paths.alpha, "state") .. " " .. tostring(fmeta(paths.alpha, "sent") ~= sent_before))
check("s: bravo (current before) kept as a draft", "draft bravo draft|more",
  fmeta(paths.bravo, "state") .. " " .. fbody(paths.bravo))
check("s: a blank note is current after the send", "", buflines(vim.api.nvim_win_get_buf(h.state.main_win)))
local n_md = #vim.fn.glob(dir .. "/*.md", false, true)
check("s sends in place: no new note file", 5, n_md)

-- y: the fake clipboard gets the text; a failing clipboard gives the
-- note's notice, not an error.
check("y runs without error", "", press("charlie cancelled", "y"))
check("y puts the note's text on +", "charlie cancelled", table.concat(clip["+"] or {}, "|"))
clip_mode, notices = "throw", {}
check("y with a failing clipboard: no error", "", press("charlie cancelled", "y"))
check("y with a failing clipboard: the note's error notice", note.CLIP_FAIL, notices[#notices])
clip_mode = nil

-- P flips `pinned:`.
press("charlie cancelled", "P")
check("P pins: pinned: true in the file, the row under Pinned with ★", "true true",
  fmeta(paths.charlie, "pinned") .. " " .. tostring(rows():find(
    "── Pinned| ★~08:00 app     charlie cancelled| ★ 07:00 app     delta pinned||── Today|", 1, true) == 1))
press("charlie cancelled", "P")
check("P again unpins: no pinned key", "nil", fmeta(paths.charlie, "pinned"))

-- K previews the body.
press("alpha sent", "K")
local pv = h.state.preview_win
check("K opens a preview of the body", "alpha sent|line two",
  pv and vim.api.nvim_win_is_valid(pv) and buflines(vim.api.nvim_win_get_buf(pv)) or "none")
h.close_preview()

-- i inserts the note's text into the current (blank) note.
press("delta pinned", "i")
check("i fills the current blank note", "delta pinned", buflines(vim.api.nvim_win_get_buf(h.state.main_win)))

-- d deletes after a confirm.
h.confirm = function() return false end
press("charlie cancelled", "d")
check("d, not confirmed: file kept, row kept", "1 true",
  vim.fn.filereadable(paths.charlie) .. " " .. tostring(rows():find("charlie", 1, true) ~= nil))
h.confirm = function() return true end
press("charlie cancelled", "d")
check("d, confirmed: the file moves to .trash and the row goes", "0 1 false",
  vim.fn.filereadable(paths.charlie) .. " " .. vim.fn.filereadable(dir .. "/.trash/" .. vim.fs.basename(paths.charlie))
  .. " " .. tostring(rows():find("charlie", 1, true) ~= nil))

-- R lists a note written outside ferry after an index run.
fixture("echo", "eeeeeeee-0000-4000-8000-000000000005", "draft", at(11), { "echo outside" })
vim.fn.system({ root .. "/bin/ferry-notes", "index", paths.echo })
press("alpha sent", "R")
check("R refreshes", true, rows():find("echo outside", 1, true) ~= nil)

-- /: search with list --query; an empty search or R lists all again.
fixture("kube1", "abababab-0000-4000-8000-000000000006", "sent", at(6), { "kubernetes rollout notes" })
fixture("kube2", "acacacac-0000-4000-8000-000000000007", "draft", at(5), { "first line", "about Kubernetes pods" })
vim.fn.system({ root .. "/bin/ferry-notes", "index", paths.kube1, paths.kube2 })
h.refresh()
local function listed(text) return rows():find(text, 1, true) ~= nil end
local function n_rows() return vim.tbl_count(h.state.map) end
local all = n_rows()
check("/ runs without error", "", press("alpha sent", "/kubernetes<CR>"))
check("/ kubernetes: only the two matching notes, the search on the first line",
  "2 true true false false /kubernetes", n_rows() .. " " .. tostring(listed("kubernetes rollout"))
  .. " " .. tostring(listed("first line")) .. " " .. tostring(listed("alpha sent")) .. " "
  .. tostring(listed("delta pinned")) .. " " .. vim.api.nvim_buf_get_lines(h.state.buf, 0, 1, false)[1])
check("the search stays across a refresh", 2, (function() h.refresh(); return n_rows() end)())
press("first line", "/<Esc>")
check("/ then Esc: the search is kept", "2 kubernetes", n_rows() .. " " .. tostring(h.state.query))
press("first line", "/<C-u><CR>")
check("/ with an empty search lists every note again", all .. " nil true",
  n_rows() .. " " .. tostring(h.state.query) .. " " .. tostring(listed("alpha sent")))
press("first line", "/zzzz-nothing<CR>")
check("/ with no match: says so", "0 /zzzz-nothing|  no notes match", n_rows() .. " " .. rows())
press("", "R")
check("R clears the search", all .. " nil", n_rows() .. " " .. tostring(h.state.query))
-- A file edited outside ferry: the sidebar shows its new first line once
-- it is opened again (opening syncs the index).
vim.fn.system({ "sed", "-i", "", "s/^kubernetes rollout notes$/edited by sed/", paths.kube1 })
check("before reopening the sidebar still shows the old first line", "true false",
  tostring(listed("kubernetes rollout")) .. " " .. tostring(listed("edited by sed")))
h.close(); h.open()
check("reopened: the sed edit's first line is listed", "true false",
  tostring(listed("edited by sed")) .. " " .. tostring(listed("kubernetes rollout")))
press("first line", "/kubernetes<CR>")
check("... and searched: only the note that still says kubernetes", "1 true", n_rows() .. " " .. tostring(listed("first line")))
h.close(); h.open()
check("reopening clears the search", all .. " nil", n_rows() .. " " .. tostring(h.state.query))

-- The open note's row follows its saves; s on it sends it as <C-x> does.
note.cancel(note.current().buf)
show("com.example.app", "4242")
local sb, sp = note.current().buf, note.current().path
check("a blank note with no file is not listed: no row marked ▶", "0 0", vim.fn.filereadable(sp) .. " " .. n_open())
vim.api.nvim_buf_set_lines(sb, 0, -1, false, { "first save" })
vim.api.nvim_buf_call(sb, function() vim.cmd("silent write") end)
vim.wait(2000, function() return listed("first save") end)
check("its first save lists it, marked ▶", true, line_of("first save"):find("^▶ ●") ~= nil)
local loads, load = 0, h.load
h.load = function() loads = loads + 1; return load() end
vim.api.nvim_buf_set_lines(sb, 0, -1, false, { "second save", "body" })
vim.api.nvim_buf_call(sb, function() vim.cmd("silent write") end)
vim.wait(2000, function() return listed("second save") end)
h.load = load
check("a later save updates its row's first line in place (no list)", "true false 0 1",
  tostring(line_of("second save"):find("^▶ ●") ~= nil) .. " " .. tostring(listed("first save")) .. " " .. loads
  .. " " .. n_open())
calls = {}
check("s on the open note's row runs without error", "", press("second save", "s"))
check("s on the open note's row submits it once, its text to the latest target",
  "1 com.example.app 4242 second save|body", #calls .. " " .. (calls[1] and (calls[1].p.target .. " "
  .. calls[1].p.window .. " " .. calls[1].text) or ""))
vim.wait(100)
check("s on the open note's row: its file says sent, listed unmarked; a blank note is current, unlisted",
  "sent true false 0", fmeta(sp, "state") .. " " .. tostring(line_of("second save"):find("^   ") ~= nil) .. " "
  .. tostring(vim.fn.resolve(note.current().path) == vim.fn.resolve(sp)) .. " " .. n_open())

-- A search the open note cannot match: its first save starts no background
-- list (its row would not be shown); one it matches lists it.
h.state.query = "kubernetes"; h.refresh()
local bg, system = 0, vim.system
vim.system = function(cmd, opts, cb)
  if cb and cmd[2] == "list" then bg = bg + 1 end
  return system(cmd, opts, cb)
end
local qb = note.current().buf
vim.api.nvim_buf_set_lines(qb, 0, -1, false, { "nothing to find here" })
vim.api.nvim_buf_call(qb, function() vim.cmd("silent write") end)
pcall(note.wait_index, 3000)
vim.wait(100)
local miss = bg
vim.api.nvim_buf_set_lines(qb, 0, -1, false, { "Kubernetes2 too" })
vim.api.nvim_buf_call(qb, function() vim.cmd("silent write") end)
vim.wait(2000, function() return listed("Kubernetes2 too") end)
vim.system = system
check("search on: a save that cannot match lists nothing; one that matches (prefix, any case) lists it, ▶",
  "0 1 true", miss .. " " .. bg .. " " .. tostring((line_of("Kubernetes2 too") or ""):find("^▶") ~= nil))
h.state.query = nil; h.refresh()

-- Cancel on a note opened unchanged: its file (state sent) is left as is.
local alpha_bytes = table.concat(vim.fn.readfile(paths.alpha, "b"), "\n")
press("alpha sent", "<CR>")
local ab = vim.api.nvim_get_current_buf()
note.cancel(ab)
check("Cancel on an opened, unchanged sent note keeps its file (state sent, bytes as they were)",
  "sent true", fmeta(paths.alpha, "state") .. " "
  .. tostring(table.concat(vim.fn.readfile(paths.alpha, "b"), "\n") == alpha_bytes))

-- <CR> when the current note cannot be saved: refused, nothing lost.
local keep = vim.api.nvim_win_get_buf(h.state.main_win)
vim.api.nvim_buf_set_lines(keep, 0, -1, false, { "unsaved here" })
vim.fn.setfperm(dir, "r-xr-xr-x")
notices = {}
press("alpha sent", "<CR>")
vim.wait(100)
vim.fn.setfperm(dir, "rwxr-xr-x")
check("<CR> with an unwritable notes folder: refused, the previous note still current and shown with its text",
  "true true unsaved here true", tostring(note.current() ~= nil and note.current().buf == keep) .. " "
  .. tostring(vim.api.nvim_win_get_buf(h.state.main_win) == keep) .. " " .. buflines(keep) .. " "
  .. tostring(table.concat(notices, "|"):find("could not save", 1, true) ~= nil))

-- Background index runs end before the shell removes the folder.
note.wait_index(3000)
io.stdout:write("RESULT=" .. fail .. "\n")
vim.cmd("qall!")
