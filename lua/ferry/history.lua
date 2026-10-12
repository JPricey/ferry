-- ferry notes browser: the history sidebar.
--
-- A left split listing the note files (lua/ferry/store.lua) from the
-- index (`bin/ferry-notes list`): every note, drafts included, pinned
-- first, then newest first. Each row: ▶ the open (current) note, ★ pinned,
-- then ● draft or ~ cancelled (blank: sent), the time, the target app and
-- the first line. The open note's row shows its buffer's first line
-- whenever the sidebar lists, and is updated when a note is saved
-- (note_saved); a blank note with no file yet is not listed. Opening the
-- sidebar runs `ferry-notes sync` first, so files changed outside ferry
-- show as they are now. Keys:
--   <CR>  open the note for editing (note.open: the current note is saved
--         as a draft; the opened one takes the target of the latest show)
--   s     open it and send it again (same file, state sent)
--   y     copy it to the clipboard      P  pin or unpin it
--   d     delete it (after a confirm; the file moves to <notes>/.trash)
--   K     preview it in a float         i  insert it into the current note
--   On the open note's row: <CR> focuses the note (nothing written), s
--   sends it (as <C-x>), y and K use its buffer, P saves it and pins it,
--   d and i refuse with a notice.
--   /     search: list only notes with every word (`list --query`); an
--         empty search lists all again
--   R     sync and refresh, clearing the search
--   <Tab> back to the note        q  close
-- The note keys (<C-x>, ZZ, :wq, :x send; <C-q>, ZQ cancel; :q hides; <C-s>
-- toggles Flow) act on the tab's note, as in the note (note.bind_note_keys).
local M = {}

-- Bumped when the module changes in a way a running server must pick up:
-- the note module reloads an older one (keeping M.state). 1: open() binds
-- the note keys on the sidebar. 2: <CR> and p take the whole note as its
-- body (no `to:` header); bind_keys rebinds an open sidebar's keys.
-- 3: rows come from the notes index (ferry-notes), not the old history
-- database; new keys (<CR> open, s send, P pin, i insert); the note module
-- refreshes an open sidebar after the reload, since its rows came from
-- that database.
-- 4: / searches (state.query), open and R sync the index first; the old
-- history database is no longer written or read.
-- 5: one-line notices (ferry.notice).
-- 6: the open note is listed, marked ▶, and its keys act on the note;
-- note_saved (called by note api 18) updates a saved note's row.
M.api = 6

M.width = 38
-- query: the active search ("" or nil: none).
M.state = { win = nil, buf = nil, main_win = nil, rows = {}, preview_win = nil, query = nil }

local function root()
  local src = debug.getinfo(1, "S").source:sub(2)
  return vim.fn.fnamemodify(src, ":p:h:h:h")
end

local function note() return require("ferry.note") end

-- The notes folder the note module uses (ferry-host passes it on every call).
local function notes_dir()
  local ok, n = pcall(note)
  if ok and type(n.dir) == "function" then return n.dir() end
  local env = os.getenv("FERRY_NOTES_DIR")
  if env and env ~= "" then return env end
  return (os.getenv("HOME") or "") .. "/notes/scratchpads"
end

-- Run bin/ferry-notes on the notes folder. Returns its stdout, or nil after
-- a notice.
local function notes_cmd(args)
  local cmd = { root() .. "/bin/ferry-notes" }
  vim.list_extend(cmd, args)
  local ok, obj = pcall(vim.system, cmd, { text = true, env = { FERRY_NOTES_DIR = notes_dir() } })
  local r = ok and obj:wait(10000) or nil
  if not r or r.code ~= 0 then
    local why = r and (r.stderr or ""):match("[^\n]+") or tostring(obj)
    require("ferry.notice").notify("ferry: notes command failed: " .. table.concat(args, " ") .. (why and ": " .. why or ""),
      vim.log.levels.WARN)
    return nil
  end
  return r.stdout
end

local function key(path) return vim.fn.resolve(vim.fn.fnamemodify(path, ":p")) end

-- The open (current) note's file, spelled as key() spells it, or nil.
local function open_path()
  local ok, n = pcall(note)
  local cur = ok and n.current and n.current()
  return cur and cur.path and cur.path ~= "" and key(cur.path) or nil
end

-- The open note's buffer, or nil (no note, or its buffer was wiped).
local function open_buf()
  local cur = note().current()
  local b = cur and cur.buf
  return b and vim.api.nvim_buf_is_valid(b) and b or nil
end

-- True when row r is the open note's, checked now (not when it was listed:
-- a send from the note makes another note current).
local function is_open_row(r)
  local p = open_path()
  return p ~= nil and key(r.path) == p
end

-- The first non-blank line, trimmed, as ferry-notes makes a preview.
local function first_line(lines)
  for _, l in ipairs(lines) do
    local t = vim.trim(l)
    if t ~= "" then return t end
  end
  return ""
end

local function count_words(text) return select(2, text:gsub("%S+", "")) end

-- Mark the open note's row (r.open), showing its buffer's first line.
local function mark_open(rows)
  local open = open_path()
  for _, r in ipairs(rows) do
    r.open = (open ~= nil and r.path ~= nil and key(r.path) == open) or nil
    local b = r.open and open_buf()
    if b then
      local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
      r.preview, r.words = first_line(lines), count_words(table.concat(lines, "\n"))
    end
  end
  return rows
end

local function query()
  local q = M.state.query
  return type(q) == "string" and q:find("%S") and q or nil
end

local function list_args()
  local args = { "list", "--limit", "200" }
  if query() then vim.list_extend(args, { "--query", query() }) end
  return args
end

local function decode(out)
  if not out or out == "" then return {} end
  local ok, rows = pcall(vim.json.decode, out)
  if not ok or type(rows) ~= "table" then return {} end
  return mark_open(rows)
end

function M.load()
  -- Note files written a moment ago are indexed in the background.
  pcall(function() note().wait_index(3000) end)
  return decode(notes_cmd(list_args()))
end

local function truncate(s, width)
  if vim.fn.strdisplaywidth(s) <= width then return s end
  local out = ""
  for _, ch in ipairs(vim.fn.split(s, "\\zs")) do
    if vim.fn.strdisplaywidth(out .. ch) > width - 1 then break end
    out = out .. ch
  end
  return out .. "…"
end

M.marks = { open = "▶", pinned = "★", draft = "●", cancelled = "~" }

-- Build display lines, a line -> row index map and highlights. Pinned
-- notes go under "── Pinned", the rest under their date. With a search
-- (q), its words come first.
function M.render(rows, width, q)
  local lines, map, hl = {}, {}, {}
  local last_label
  if q then
    lines[1] = truncate("/" .. q, width)
    hl[1] = { 0, "Search", 0, -1 }
  end
  if #rows == 0 then
    lines[#lines + 1] = q and "  no notes match" or "  no notes yet"
    hl[#hl + 1] = { #lines - 1, "Comment", 0, -1 }
    return lines, map, hl
  end
  for i, r in ipairs(rows) do
    local label = r.pinned and "Pinned" or r.date_label
    if label ~= last_label then
      if last_label then lines[#lines + 1] = "" end
      lines[#lines + 1] = "── " .. label
      hl[#hl + 1] = { #lines - 1, "Title", 0, -1 }
      last_label = label
    end
    local open = r.open and M.marks.open or " "
    local pin = r.pinned and M.marks.pinned or " "
    local mark = M.marks[r.state] or " "
    local app = truncate(r.app or "", 7)
    local head = open .. pin .. mark .. r.time .. " " .. app .. string.rep(" ", 7 - vim.fn.strdisplaywidth(app)) .. " "
    local preview = (r.preview or "") ~= "" and r.preview or "(empty)"
    lines[#lines + 1] = head .. truncate(preview, width - vim.fn.strdisplaywidth(head) - 1)
    local ln = #lines - 1
    local o = #open
    local p, m = o + #pin, o + #pin + #mark
    if r.open then hl[#hl + 1] = { ln, "Function", 0, o } end
    if r.pinned then hl[#hl + 1] = { ln, "Special", o, p } end
    if r.state == "draft" then hl[#hl + 1] = { ln, "Constant", p, m } end
    if r.state == "cancelled" then hl[#hl + 1] = { ln, "Comment", p, m } end
    hl[#hl + 1] = { ln, "Number", m, m + #r.time }
    hl[#hl + 1] = { ln, "Identifier", m + #r.time + 1, m + #r.time + 1 + #app }
    map[#lines] = i
  end
  return lines, map, hl
end

local function current_row()
  local st = M.state
  if not (st.win and vim.api.nvim_win_is_valid(st.win)) then return nil end
  local ln = vim.api.nvim_win_get_cursor(st.win)[1]
  local idx = (st.map or {})[ln]
  local r = idx and st.rows[idx] or nil
  -- Rows a history api 2 (or older) sidebar listed have no path.
  return r and r.path and r or nil
end

local function main_win()
  local st = M.state
  if st.main_win and vim.api.nvim_win_is_valid(st.main_win) then return st.main_win end
  -- Fall back to any other window.
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if w ~= st.win then return w end
  end
  return nil
end

-- The note's body lines, read from its file (the file is the truth; the
-- open note's from its buffer, unsaved typing included), with trailing
-- blank lines dropped. nil after a notice.
local function body_of(r)
  local b = is_open_row(r) and open_buf()
  local meta, lines
  if b then
    meta, lines = true, vim.api.nvim_buf_get_lines(b, 0, -1, false)
  else
    meta, lines = require("ferry.store").read(r.path)
  end
  if not meta then
    require("ferry.notice").notify("ferry: cannot read " .. r.path .. ": " .. tostring(lines), vim.log.levels.WARN)
    return nil
  end
  while #lines > 1 and lines[#lines] == "" do lines[#lines] = nil end
  if #lines == 0 then lines = { "" } end
  return lines
end

local function refuse(msg) require("ferry.notice").notify(msg, vim.log.levels.WARN) end

-- Focus the open note in the note window: the window showing it, else
-- through note.open (the same file: shown, nothing written). Returns its
-- buffer, or nil after a notice.
local function focus_open()
  local b = open_buf()
  local win = b and vim.fn.bufwinid(b) or -1
  if win ~= -1 then
    vim.api.nvim_set_current_win(win)
    return b
  end
  return note().open(note().current().path)
end

-- i: put the note's text into the current note, below the cursor line (an
-- empty note is replaced). Never the open note into itself.
function M.insert()
  local r = current_row(); if not r then return end
  if is_open_row(r) then return refuse("ferry: this is the open note — i inserts another note into it") end
  local win = main_win(); if not win then return end
  local lines = body_of(r); if not lines then return end
  local buf = vim.api.nvim_win_get_buf(win)
  local body = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  vim.api.nvim_set_current_win(win)
  if #body == 1 and body[1] == "" then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_win_set_cursor(win, { #lines, #lines[#lines] })
  else
    vim.api.nvim_put(lines, "l", true, true)
  end
end

-- <CR>: make the note the current one, in the note window. On the open
-- note's row: focus the note (no reopen, nothing written).
function M.open_note()
  local r = current_row(); if not r then return end
  if is_open_row(r) then return focus_open() end
  local buf = note().open(r.path)
  if buf then M.refresh() end
  return buf
end

-- s: open the note and send it again to the latest show's target. On the
-- open note's row: send it, as <C-x> in the note does.
function M.send()
  local r = current_row(); if not r then return end
  local n = note()
  if is_open_row(r) then
    local b = focus_open()
    if not b then return end
    n.submit(b)
    M.refresh()
    return
  end
  local buf = n.open(r.path)
  if not buf then return end
  n.submit(buf)
  M.refresh()
end

-- y: the note's text on the clipboard. A clipboard that fails gives the
-- note's error notice, never an error.
function M.yank()
  local r = current_row(); if not r then return end
  local lines = body_of(r); if not lines then return end
  local text = table.concat(lines, "\n")
  local n = note()
  if not n.to_clipboard(text) then
    require("ferry.notice").notify(n.CLIP_FAIL, vim.log.levels.ERROR)
    return
  end
  pcall(vim.fn.setreg, '"', text)
  require("ferry.notice").notify(string.format("ferry: copied %d words", count_words(text)))
end

-- P: pin or unpin the note (frontmatter `pinned`). The open note's file
-- goes through note.pin_open, which saves it first and writes the pin as
-- ferry's own write (ferry-notes changing it would look like an outside
-- edit to the note's next save).
function M.pin()
  local r = current_row(); if not r then return end
  local n = note()
  if is_open_row(r) and type(n.pin_open) == "function" then
    if n.pin_open(not r.pinned) then M.refresh(r.path) end
    return
  end
  if notes_cmd({ "pin", r.id, r.pinned and "off" or "on" }) then M.refresh(r.path) end
end

-- Swappable (tests): true to delete.
function M.confirm(msg)
  return vim.fn.confirm(msg, "&Delete\n&Keep", 2) == 1
end

-- d: after a confirm, move the note's file to <notes>/.trash.
function M.delete()
  local r = current_row(); if not r then return end
  if is_open_row(r) then return refuse("ferry: this is the open note — Ctrl-Q cancels it") end
  local preview = (r.preview or "") ~= "" and r.preview or "(empty)"
  if not M.confirm("Delete \"" .. truncate(preview, 40) .. "\"?") then return end
  if not notes_cmd({ "delete", r.id }) then return end
  -- A hidden buffer of that note (a draft left by a seeded show) goes too,
  -- so it can never write the file back.
  local cur = note().current()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b) ~= "" and key(vim.api.nvim_buf_get_name(b)) == key(r.path)
      and not (cur and cur.buf == b) and vim.fn.bufwinid(b) == -1 then
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end
  M.refresh()
end

function M.close_preview()
  local st = M.state
  if st.preview_win and vim.api.nvim_win_is_valid(st.preview_win) then
    vim.api.nvim_win_close(st.preview_win, true)
  end
  st.preview_win = nil
end

function M.preview()
  local st = M.state
  if st.preview_win and vim.api.nvim_win_is_valid(st.preview_win) then
    M.close_preview(); return
  end
  local r = current_row(); if not r then return end
  local lines = body_of(r); if not lines then return end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  local width = math.max(20, math.min(80, vim.o.columns - M.width - 6))
  local height = math.min(#lines + 1, vim.o.lines - 6)
  st.preview_win = vim.api.nvim_open_win(buf, false, {
    relative = "win", win = st.win, anchor = "NW", row = 0, col = M.width + 1,
    width = width, height = math.max(height, 1), style = "minimal", border = "rounded",
    title = string.format(" %s · %s · %s · %s · %d words ", r.date_label, r.time, r.app, r.state, r.words or 0),
  })
  vim.wo[st.preview_win].wrap = true
  vim.wo[st.preview_win].linebreak = true
end

function M.focus_main()
  local win = main_win()
  if win then vim.api.nvim_set_current_win(win) end
end

-- Draw st.rows. The cursor goes to the row of keep_path when it is listed,
-- else to the first row (keep_line: else it stays on its line).
local function draw(keep_path, keep_line)
  local st = M.state
  local lines, map, hl = M.render(st.rows, M.width, query())
  st.map = map
  vim.bo[st.buf].modifiable = true
  vim.api.nvim_buf_set_lines(st.buf, 0, -1, false, lines)
  vim.bo[st.buf].modifiable = false
  local ns = vim.api.nvim_create_namespace("ferry-history")
  vim.api.nvim_buf_clear_namespace(st.buf, ns, 0, -1)
  for _, h in ipairs(hl) do
    pcall(vim.api.nvim_buf_add_highlight, st.buf, ns, h[2], h[1], h[3], h[4])
  end
  if st.win and vim.api.nvim_win_is_valid(st.win) then
    local first, want
    for ln = 1, #lines do
      if map[ln] then
        first = first or ln
        if keep_path and key(st.rows[map[ln]].path) == key(keep_path) then want = ln end
      end
    end
    if keep_line and not want then
      local ln = vim.api.nvim_win_get_cursor(st.win)[1]
      vim.api.nvim_win_set_cursor(st.win, { math.min(ln, #lines), 0 })
    elseif want or first then
      vim.api.nvim_win_set_cursor(st.win, { want or first, 0 })
    end
  end
end

-- Reload the rows. The cursor goes to the row of keep_path when it is
-- listed, else to the first row.
function M.refresh(keep_path)
  local st = M.state
  if not (st.buf and vim.api.nvim_buf_is_valid(st.buf)) then return end
  st.rows = M.load()
  draw(keep_path)
end

-- List again without blocking: `ferry-notes list` runs in the background
-- and the rows are drawn when it is done (unless the sidebar closed or the
-- search changed meanwhile), the cursor kept on its row. Never a wait: a
-- wait runs the event loop, which would take ferry-host requests (draft,
-- talk) in the middle of whatever the editor was doing.
local function refresh_async()
  local q = query()
  local cmd = { root() .. "/bin/ferry-notes" }
  vim.list_extend(cmd, list_args())
  pcall(vim.system, cmd, { text = true, env = { FERRY_NOTES_DIR = notes_dir() } }, function(r)
    vim.schedule(function()
      local st = M.state
      if r.code ~= 0 or not M.is_open() or not (st.buf and vim.api.nvim_buf_is_valid(st.buf)) or query() ~= q then
        return
      end
      local cur = current_row()
      st.rows = decode(r.stdout)
      draw(cur and cur.path, true)
    end)
  end)
end

-- A note file was written and indexed (note api 18 calls this then, on the
-- main loop). Its row, when listed, shows the file's state and first line
-- now, without listing again (its place and time wait for the next list),
-- and the ▶ mark follows the current note; the cursor stays. The open
-- note's file not listed yet (its first save) lists the sidebar again, in
-- the background.
function M.note_saved(path)
  local st = M.state
  if not path or not (M.is_open() and st.buf and vim.api.nvim_buf_is_valid(st.buf)) then return end
  local k, found = key(path), nil
  for _, r in ipairs(st.rows or {}) do
    if r.path and key(r.path) == k then found = r end
  end
  local cur = current_row()
  if not found then
    if open_path() == k then refresh_async() end
    return
  end
  local meta, body = require("ferry.store").read(path)
  if meta then
    found.state = rawget(meta, "state") or found.state
    found.preview, found.words = first_line(body), count_words(table.concat(body, "\n"))
  end
  mark_open(st.rows)
  draw(cur and cur.path, true)
end

-- Bring the index up to date with the folder (files edited, added or
-- removed outside ferry).
function M.sync()
  pcall(function() note().wait_index(3000) end)
  notes_cmd({ "sync" })
end

-- /: ask for words and list only the notes that have them all (an empty
-- answer lists every note; a cancelled prompt changes nothing).
function M.search()
  vim.ui.input({ prompt = "search notes: ", default = M.state.query or "" }, function(q)
    if q == nil or not M.is_open() then return end
    M.state.query = q:find("%S") and vim.trim(q) or nil
    M.refresh()
  end)
end

-- R: sync, clear the search, list again.
function M.reset()
  M.state.query = nil
  M.sync()
  M.refresh()
end

function M.close()
  M.close_preview()
  local st = M.state
  if st.win and vim.api.nvim_win_is_valid(st.win) then
    vim.api.nvim_win_close(st.win, true)
  end
  st.win, st.buf = nil, nil
end

function M.is_open()
  local st = M.state
  return st.win ~= nil and vim.api.nvim_win_is_valid(st.win)
end

function M.toggle()
  if M.is_open() then M.close() else M.open() end
end

-- The sidebar's own keys on buf, bound to this module's functions. The note
-- module reruns it when it reloads an older history module, so a sidebar
-- that module opened stops calling the old functions (and loses its old
-- p key).
function M.bind_keys(buf)
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, silent = true, nowait = true, desc = desc })
  end
  pcall(vim.keymap.del, "n", "p", { buffer = buf })
  map("<CR>", M.open_note, "open the note")
  map("s", M.send, "open the note and send it again")
  map("y", M.yank, "copy to clipboard")
  map("P", M.pin, "pin or unpin")
  map("d", M.delete, "delete (to .trash)")
  map("K", M.preview, "preview")
  map("i", M.insert, "insert into the current note")
  map("/", M.search, "search")
  map("R", M.reset, "sync, clear the search, refresh")
  map("<Tab>", M.focus_main, "back to the note")
  map("q", M.close, "close sidebar")
  map("<Esc>", M.close_preview, "close preview")
end

-- Open the sidebar to the left of the current (dictation) window and return
-- focus to that window.
function M.open()
  local st = M.state
  if M.is_open() then M.refresh(); return end
  st.main_win = vim.api.nvim_get_current_win()

  vim.cmd("topleft vertical " .. M.width .. " new")
  st.win = vim.api.nvim_get_current_win()
  st.buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_name(st.buf, "ferry://history")
  local bo = vim.bo[st.buf]
  bo.buftype, bo.bufhidden, bo.swapfile, bo.buflisted = "nofile", "wipe", false, false
  bo.filetype = "ferry-history"
  local wo = vim.wo[st.win]
  wo.number, wo.relativenumber, wo.signcolumn, wo.foldcolumn = false, false, "no", "0"
  wo.wrap, wo.cursorline, wo.winfixwidth, wo.spell, wo.list = false, true, true, false, false
  wo.statusline = " notes "

  M.bind_keys(st.buf)
  -- Send, cancel, hide and Flow keys act on the note, not on this buffer.
  pcall(function() require("ferry.note").bind_note_keys(st.buf) end)

  vim.api.nvim_create_autocmd("CursorMoved", { buffer = st.buf, callback = M.close_preview })
  vim.api.nvim_create_autocmd("BufWipeout", { buffer = st.buf, callback = function()
    M.close_preview(); st.win, st.buf = nil, nil
  end })

  st.query = nil
  M.sync()
  M.refresh()
  vim.api.nvim_set_current_win(st.main_win)
end

return M
