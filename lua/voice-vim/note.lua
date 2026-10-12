-- voice-vim note core: runs inside the one long-lived nvim server.
--
-- bin/voice-vim-host calls the public functions over --remote-expr as
-- luaeval('require"voice-vim.note".<fn>(_A)', {dict}). Each takes one table
-- and returns a string, which voice-vim-host prints.
--
-- One note is "current" until it is finished. show() resumes it, unless a
-- seed (captured selection) asks for a fresh note. Note files are scratch
-- in $VOICE_VIM_NOTES_DIR; the history database stays the record.
--
-- In a note, :Submit (ZZ, <C-x>, :wq, :x), :Cancel (ZQ) and :Hide (:q)
-- call M.host instead of exiting. Hide keeps the note as the draft.
-- Submit files go in <notes dir>/outbox/ (they must outlive the server, so
-- not vim.fn.tempname()). After Submit or Cancel the window shows a new,
-- empty note, so :q there still hides instead of quitting the server.
--
-- Voice keys: <C-s> toggles Wispr Flow hands-free, <C-q> cancels. Submit,
-- Cancel and Hide first wait for Flow's last paste when Flow is recording
-- (flow.finish_then), so the last words land in the note, not the target.
local M = {}
local flow = require("voice-vim.flow")

-- Bumped when the module changes in a way an already-running server must
-- pick up: bin/voice-vim-host reloads the module (keeping M.state and a
-- swapped M.host) when the loaded one reports a different api.
M.api = 2

-- The current (unfinished) note: { id = uuid, path = file, buf = bufnr,
-- unstarted = true while it has no history row (see blank()) }.
-- dir: the notes folder of the last show().
M.state = { note = nil, cursor = nil, dir = nil }

local function notes_dir(opts)
  if opts and opts.dir and opts.dir ~= "" then return opts.dir end
  if M.state.dir then return M.state.dir end
  local env = os.getenv("VOICE_VIM_NOTES_DIR")
  if env and env ~= "" then return env end
  local tmp = (os.getenv("TMPDIR") or "/tmp"):gsub("/$", "")
  return tmp .. "/voice-vim-notes"
end

local seeded = false
-- A random (version 4) UUID, lower case.
function M.uuid()
  if not seeded then
    math.randomseed(vim.uv.hrtime() % 2 ^ 31 + vim.fn.getpid())
    seeded = true
  end
  return (string.gsub("xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx", "[xy]", function(c)
    local v = c == "x" and math.random(0, 15) or math.random(8, 11)
    return string.format("%x", v)
  end))
end

-- Seed text from a seed file path ("" when absent, unreadable or blank).
local function read_seed(path)
  if not path or path == "" or vim.fn.filereadable(path) == 0 then return "" end
  local text = table.concat(vim.fn.readfile(path), "\n")
  if not text:find("%S") then return "" end
  return text
end

-- The note's buffer, reloading it from its file if it was wiped.
local function note_buf(note)
  if not (note.buf and vim.api.nvim_buf_is_valid(note.buf)) then
    note.buf = vim.fn.bufadd(note.path)
    vim.fn.bufload(note.buf)
  end
  return note.buf
end

local function repo_root()
  local src = debug.getinfo(1, "S").source:sub(2)
  return vim.fn.fnamemodify(src, ":p:h:h:h")
end

-- History: `voice-vim-db start` runs in the background when a fresh note
-- opens, so show stays fast; finish waits for it, then runs to completion
-- before the host is called (Hammerspoon deletes the submit file).
local db_starts = {}

local function db(args, on_exit)
  local cmd = { repo_root() .. "/bin/voice-vim-db" }
  vim.list_extend(cmd, args)
  local ok, obj = pcall(vim.system, cmd, { text = true }, on_exit)
  if not ok then
    vim.notify("voice-vim: history unavailable: " .. tostring(obj), vim.log.levels.WARN)
    return nil
  end
  return obj
end

local function history_start(id, target, seed)
  local seedfile = vim.fn.tempname()
  vim.fn.writefile(seed ~= "" and vim.split(seed, "\n", { plain = true }) or {}, seedfile)
  db_starts[id] = db({ "start", id, target or "", seedfile }, function() os.remove(seedfile) end)
end

local function history_finish(id, outcome, file)
  local pending = db_starts[id]
  db_starts[id] = nil
  if pending then pcall(pending.wait, pending, 5000) end
  local obj = db({ "finish", id, outcome, file })
  if obj then pcall(obj.wait, obj, 5000) end
end

-- Percent-encode a URL query value.
local function enc(s)
  return (tostring(s or ""):gsub("[^%w%-%._~]", function(c)
    return string.format("%%%02X", c:byte())
  end))
end

-- Open a URL in the background. on_fail runs (scheduled) when `open` is
-- missing or exits non-zero.
local function open_url(url, on_fail)
  local ok = pcall(vim.system, { "open", "-g", url }, {}, function(r)
    if r.code ~= 0 then vim.schedule(on_fail) end
  end)
  if not ok then on_fail() end
end

-- The default host talks to Hammerspoon. submit{file,target,window} reuses
-- V0's voicevim-submit URL (Hammerspoon reads, delivers and deletes the
-- file); hide{} asks it to hide the host and refocus the target. If the URL
-- cannot be opened, the text goes on the clipboard instead.
M.default_host = {}

function M.default_host.submit(p)
  local url = "hammerspoon://voicevim-submit?file=" .. enc(p.file) .. "&target=" .. enc(p.target)
  if p.window and p.window ~= "" then url = url .. "&window=" .. enc(p.window) end
  open_url(url, function()
    local f = io.open(p.file, "r")
    local text = f and f:read("a") or ""
    if f then f:close() end
    os.remove(p.file)
    vim.fn.setreg("+", (text:gsub("\n$", "")))
    vim.notify("voice-vim: copied — paste manually", vim.log.levels.WARN)
  end)
end

function M.default_host.hide()
  open_url("hammerspoon://voicevim-hide", function()
    vim.notify("voice-vim: could not reach Hammerspoon to hide", vim.log.levels.WARN)
  end)
end

-- Swappable (tests use a recording stub).
M.host = M.default_host

-- Buffer and window settings, as in vim/voice-vim.vim minus the V0
-- process-exit commands. Run with the note displayed in the current window.
function M.apply_options(buf)
  vim.bo[buf].buflisted = true
  if vim.bo[buf].filetype ~= "markdown" then vim.bo[buf].filetype = "markdown" end
  vim.cmd([[
    setlocal wrap linebreak nolist
    setlocal textwidth=0
    setlocal spell spelllang=en_us
    setlocal nonumber norelativenumber
    setlocal noswapfile nobackup nowritebackup noundofile
    setlocal bufhidden=hide
    setlocal formatoptions-=t
  ]])
  -- Wispr Flow: a paste into the note means Flow stopped. :Dictate starts
  -- hands-free; <C-s> toggles it without leaving insert mode.
  flow.attach(buf)
  vim.api.nvim_buf_create_user_command(buf, "Dictate", function() flow.start() end, { force = true })
  vim.keymap.set("n", "<leader>d", "<Cmd>Dictate<CR>", { buffer = buf, silent = true })
  vim.keymap.set({ "n", "i" }, "<C-s>", "<Cmd>lua require'voice-vim.flow'.toggle()<CR>",
    { buffer = buf, silent = true })
  vim.api.nvim_buf_create_user_command(buf, "History", function()
    require("voice-vim.history").toggle()
  end, { force = true })
  vim.keymap.set("n", "<leader>h", "<Cmd>History<CR>", { buffer = buf, silent = true })
  -- Submit, cancel and hide. A note never quits the server: :wq and :x
  -- submit, :q hides and keeps the draft.
  local function cmd(name, fn)
    vim.api.nvim_buf_create_user_command(buf, name, function() M[fn](buf) end, { force = true, bang = true })
  end
  cmd("Submit", "submit")
  cmd("Cancel", "cancel")
  cmd("Hide", "hide")
  local o = { buffer = buf, silent = true }
  vim.keymap.set("n", "ZZ", "<Cmd>Submit<CR>", o)
  vim.keymap.set({ "n", "i" }, "<C-x>", "<Cmd>Submit<CR>", o)
  vim.keymap.set("n", "ZQ", "<Cmd>Cancel<CR>", o)
  vim.keymap.set({ "n", "i" }, "<C-q>", "<Cmd>Cancel<CR>", o)
  for lhs, rhs in pairs({ wq = "Submit", x = "Submit", q = "Hide" }) do
    vim.cmd(string.format(
      "cnoreabbrev <buffer> <expr> %s getcmdtype() ==# ':' && getcmdline() ==# '%s' ? '%s' : '%s'",
      lhs, lhs, rhs, lhs))
  end
end

-- A window that can hold a note: a normal (non-floating) window on a
-- normal buffer, not the history sidebar (so not nvim-tree either).
local function note_window_ok(win)
  if vim.api.nvim_win_get_config(win).relative ~= "" then return false end
  local hist = package.loaded["voice-vim.history"]
  if hist and hist.state and hist.state.win == win then return false end
  return vim.bo[vim.api.nvim_win_get_buf(win)].buftype == ""
end

-- Show buf in the current window (or jump to a window already showing it).
-- If the current window is a special one (sidebar, file tree, float), use
-- another normal window in the tab, or split one off for the note.
local function display(buf)
  local win = vim.fn.bufwinid(buf)
  if win ~= -1 then
    vim.api.nvim_set_current_win(win)
    return
  end
  if not note_window_ok(0) then
    local found
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if note_window_ok(w) then found = w; break end
    end
    if found then
      vim.api.nvim_set_current_win(found)
    else
      vim.api.nvim_open_win(buf, true, { split = "right", win = -1 })
      return
    end
  end
  vim.api.nvim_win_set_buf(0, buf)
end

local function sidebar_on(opts)
  local v = opts and opts.sidebar
  if v == nil or v == "" then v = os.getenv("VOICE_VIM_SIDEBAR") end
  return v ~= "0"
end

-- The note window (current) is the only normal window in its tab, plus the
-- history sidebar on the left unless sidebar is off (VOICE_VIM_SIDEBAR=0),
-- as in V0. Other windows (e.g. a file tree opened at startup) are closed;
-- a modified buffer in one just becomes hidden. The sidebar is refreshed
-- (after show returns) when the note changed since it was last listed.
local function layout(opts)
  local hist = require("voice-vim.history")
  local note_win = vim.api.nvim_get_current_win()
  local tab = vim.api.nvim_get_current_tabpage()
  local want = sidebar_on(opts)
  if hist.is_open() and (not want or vim.api.nvim_win_get_tabpage(hist.state.win) ~= tab) then
    hist.close()
  end
  local side = hist.is_open() and hist.state.win or nil
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    if w ~= note_win and w ~= side and vim.api.nvim_win_get_config(w).relative == "" then
      pcall(vim.api.nvim_win_close, w, true)
    end
  end
  vim.api.nvim_set_current_win(note_win)
  if not want then return end
  local id = (vim.b.voicevim or {}).id
  if side then
    hist.state.main_win = note_win
    if M.state.listed ~= id then
      vim.schedule(function() pcall(hist.refresh) end)
    end
  else
    pcall(hist.open)
    if vim.api.nvim_win_is_valid(note_win) then vim.api.nvim_set_current_win(note_win) end
  end
  M.state.listed = id
end

-- Write the note if it has unsaved changes, so switching away loses nothing.
local function save(note)
  if note and note.buf and vim.api.nvim_buf_is_valid(note.buf) and vim.bo[note.buf].modified then
    vim.api.nvim_buf_call(note.buf, function() vim.cmd("silent write!") end)
  end
end

-- A new note buffer with the note options, shown in the current window.
local function new_note(dir)
  vim.fn.mkdir(dir, "p")
  local id = M.uuid()
  local note = { id = id, path = dir .. "/" .. id .. ".md" }
  note.buf = vim.fn.bufadd(note.path)
  vim.fn.bufload(note.buf)
  display(note.buf)
  M.apply_options(note.buf)
  return note
end

-- Drop a note that never got a history row and was never edited.
local function discard_unstarted(note)
  if not (note and note.unstarted) then return false end
  local buf = note.buf
  if buf and vim.api.nvim_buf_is_valid(buf) then
    if vim.bo[buf].modified or vim.fn.filereadable(note.path) == 1 then return false end
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
  return true
end

local function fresh(opts, seed)
  if not discard_unstarted(M.state.note) then save(M.state.note) end
  local note = new_note(notes_dir(opts))
  local id = note.id
  if seed ~= "" then
    vim.api.nvim_buf_set_lines(note.buf, 0, -1, false, vim.split(seed, "\n", { plain = true }))
  end
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  M.state.note, M.state.cursor = note, nil
  vim.b[note.buf].voicevim = { id = id, target = opts.target or "", window = opts.window or "", seed = seed }
  history_start(id, opts.target, seed)
  vim.cmd("startinsert")
  return note
end

local function resume(opts)
  local note = M.state.note
  local buf = note_buf(note)
  display(buf)
  M.apply_options(buf)
  local meta = vim.b[buf].voicevim or { id = note.id, seed = "" }
  meta.target, meta.window = opts.target or "", opts.window or ""
  vim.b[buf].voicevim = meta
  if note.unstarted then
    note.unstarted = nil
    history_start(note.id, meta.target, "")
  end
  -- Put the cursor back where draft() found it. In insert mode it may sit
  -- just past the end of the line, which normal mode cannot hold.
  local cur = M.state.cursor
  local append = false
  if cur then
    local last = vim.api.nvim_buf_line_count(buf)
    local row = math.min(cur[1], last)
    local len = #(vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or "")
    append = cur[2] >= len and len > 0
    vim.api.nvim_win_set_cursor(0, { row, math.min(cur[2], math.max(len - 1, 0)) })
  end
  vim.cmd(append and "startinsert!" or "startinsert")
  return note
end

-- Show the note: resume the unfinished one unless seeded, else open a fresh
-- note. opts: { target, window, seed = seed file path, dir = notes folder,
-- sidebar = "0" to leave the history sidebar closed }.
-- A resumed note takes the new target and window. Returns the note's path.
function M.show(opts)
  opts = opts or {}
  if opts.dir and opts.dir ~= "" then M.state.dir = opts.dir end
  local seed = read_seed(opts.seed)
  local note
  if seed == "" and M.state.note then
    note = resume(opts)
  else
    note = fresh(opts, seed)
  end
  layout(opts)
  return note.path
end

-- Returned (with the path) by draft() while Flow is recording.
M.FLOW_WAIT = "waiting for flow"

-- Write the current note to disk, record it as the draft and leave insert
-- mode. Returns its path ("" when there is no note).
-- While Flow is recording (started from the note) or a finish is already
-- waiting for its paste, the note must stay in front for Flow's paste: it
-- returns "waiting for flow <path>" at once, and the note hides itself
-- through M.host.hide once the paste has landed (or timed out), as :Hide
-- does. The caller must not hide the host itself then. A Submit or Cancel
-- during that wait takes it over (flow.finish_then) and also runs only
-- after the paste, so cancelled dictation never reaches the target.
function M.draft()
  local note = M.state.note
  if not note then return "" end
  local buf = note_buf(note)
  if flow.state.waiting then return M.FLOW_WAIT .. " " .. note.path end
  if flow.recording() then
    M.hide(buf)
    return M.FLOW_WAIT .. " " .. note.path
  end
  local win = vim.fn.bufwinid(buf)
  if win ~= -1 then M.state.cursor = vim.api.nvim_win_get_cursor(win) end
  vim.api.nvim_buf_call(buf, function() vim.cmd("silent write!") end)
  vim.g.voicevim_draft = note.path
  vim.cmd("stopinsert")
  return note.path
end

-- The current note ({ id, path, buf }) or nil. For the commands (Submit,
-- Cancel, Hide) that finish or hide it.
function M.current()
  return M.state.note
end

-- Forget the current note so the next show() opens a fresh one.
function M.forget()
  M.state.note, M.state.cursor = nil, nil
end

-- An empty note that takes the place of a finished one, so :q in its
-- window hides rather than quitting the server. It is the current note
-- (the next unseeded show resumes it) but gets its history row only then.
local function blank(wins)
  local cur = vim.api.nvim_get_current_win()
  local win = wins[1] or cur
  local note
  vim.api.nvim_win_call(win, function() note = new_note(notes_dir()) end)
  for i = 2, #wins do
    vim.api.nvim_win_call(wins[i], function()
      vim.api.nvim_win_set_buf(0, note.buf)
      M.apply_options(note.buf)
    end)
  end
  note.unstarted = true
  vim.b[note.buf].voicevim = { id = note.id, target = "", window = "", seed = "" }
  M.state.note, M.state.cursor = note, nil
  return note
end

-- End a note: record the outcome, and drop its buffer and file. If it was
-- the current note, a blank note replaces it in its windows.
local function finish(buf, outcome, file)
  local meta = vim.b[buf].voicevim or {}
  local note = M.state.note
  local current = note and note.buf == buf
  if meta.id then
    -- A blank note submitted before any show has no row yet.
    if current and note.unstarted then history_start(meta.id, meta.target, "") end
    history_finish(meta.id, outcome, file)
  end
  local path = vim.api.nvim_buf_get_name(buf)
  if current then
    path = note.path
    M.forget()
  end
  vim.g.voicevim_draft = nil
  vim.cmd("stopinsert")
  local wins = vim.fn.win_findbuf(buf)
  if current then
    blank(wins)
  else
    local empty = vim.api.nvim_create_buf(true, false)
    vim.bo[empty].bufhidden = "wipe"
    for _, win in ipairs(wins) do vim.api.nvim_win_set_buf(win, empty) end
  end
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
  if path ~= "" then os.remove(path) end
end

local function text_of(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

-- Write buf's text to <notes dir>/outbox/<id>.md and return its path. Not
-- vim.fn.tempname(): nvim deletes that folder on exit, and Hammerspoon
-- reads (then deletes) the submit file after the URL is opened.
local function to_tempfile(buf)
  local dir = notes_dir() .. "/outbox"
  vim.fn.mkdir(dir, "p")
  local id = (vim.b[buf].voicevim or {}).id or M.uuid()
  local file = dir .. "/" .. id .. ".md"
  vim.fn.writefile(vim.api.nvim_buf_get_lines(buf, 0, -1, false), file)
  return file
end

local function bufnr(buf)
  return (buf and buf ~= 0) and buf or vim.api.nvim_get_current_buf()
end

-- Run fn(buf) once Flow's last paste has landed (at once when Flow is idle).
-- The buffer may be gone by then (another finish ran first).
local function after_flow(buf, fn)
  flow.finish_then(buf, function()
    if vim.api.nvim_buf_is_valid(buf) then fn(buf) end
  end)
end

-- Cancel: record the text as cancelled (blank notes are dropped from
-- history) and hide.
local function cancel_now(buf)
  local file = to_tempfile(buf)
  finish(buf, "cancelled", file)
  os.remove(file)
  M.host.hide({})
end

-- Submit, deciding like bin/voice-vim-session: blank, or unchanged from the
-- seed, is a cancel. Otherwise the text goes to the host with the target.
local function submit_now(buf)
  local meta = vim.b[buf].voicevim or {}
  local text = text_of(buf)
  local trim = function(s) return (s:gsub("\n+$", "")) end
  if not text:find("%S") or trim(text) == trim(meta.seed or "") then
    return cancel_now(buf)
  end
  local file = to_tempfile(buf)
  finish(buf, "submitted", file)
  M.host.submit({ file = file, target = meta.target or "", window = meta.window or "" })
end

-- Hide: keep the note as the draft (history row stays open) and hide.
local function hide_now(buf)
  local note = M.state.note
  if note and note.buf == buf then
    M.draft()
  elseif vim.bo[buf].modified then
    vim.api.nvim_buf_call(buf, function() vim.cmd("silent write!") end)
  end
  vim.cmd("stopinsert")
  M.host.hide({})
end

function M.cancel(buf) buf = bufnr(buf); after_flow(buf, cancel_now) end
function M.submit(buf) buf = bufnr(buf); after_flow(buf, submit_now) end
function M.hide(buf) buf = bufnr(buf); after_flow(buf, hide_now) end

-- Neovide sends Cmd+V as <D-v>; terminals never do. Paste the + register,
-- which is where Wispr Flow puts the dictation, then tell flow a paste
-- landed (terminal pastes reach it through the vim.paste hook instead).
local on_paste = "<Cmd>lua require'voice-vim.flow'.on_paste(0)<CR>"
vim.keymap.set({ "i", "c" }, "<D-v>", "<C-r><C-o>+" .. on_paste, { desc = "voice-vim: paste clipboard" })
vim.keymap.set("n", "<D-v>", '"+p' .. on_paste, { desc = "voice-vim: paste clipboard" })

return M
