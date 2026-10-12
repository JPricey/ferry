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
--
-- Hold to talk: Hammerspoon starts Flow itself, then calls show{talk} (or
-- talk() when the note is already in front), which tells flow a recording
-- is in progress (flow.adopt_start). Key up calls release(): the stop goes
-- through flow's queue and waits for the paste like a Submit would.
--
-- Line 1 of a note is its target header, `to: <spec>` (lua/voice-vim/
-- target.lua), and the rest is the body. A fresh note's header is the
-- captured target (b:voicevim.auto_spec); a resume rewrites it only while it
-- still equals auto_spec, so an edited header is kept. Submit sends the body
-- to the header's target, or to the captured one when line 1 is not a header.
-- `to: clipboard` copies the body and hides; :Copy (<C-y>) does that for any
-- header.
local M = {}

-- A module note.lua needs at api `want` or later. A running server can hold
-- one loaded before that (api lower or unset); reload it, keeping its
-- M.state, as voice-vim-host does for this module, then run adopt(old, new)
-- for anything else the old module must hand over. If the reload fails or
-- is no newer, the loaded one stays.
local function current(name, want, adopt)
  local old = require(name)
  if (old.api or 0) >= want then return old end
  package.loaded[name] = nil
  local ok, m = pcall(require, name)
  if ok and type(m) == "table" and (m.api or 0) >= want then
    m.state = old.state
    if adopt then adopt(old, m) end
    return m
  end
  package.loaded[name] = old
  return old
end

-- flow api 3: adopt_start, release, a quick second hold during a release
-- wait. Its state keeps a recording and the pending wait across the reload.
-- The old module's vim.paste hook stays installed, so its on_paste forwards
-- to the new one (which counts a paste reported by both hooks once).
local flow = current("voice-vim.flow", 3, function(old, new)
  old.on_paste = function(b) return new.on_paste(b) end
end)
local target = require("voice-vim.target")

-- Bumped when the module changes in a way an already-running server must
-- pick up: bin/voice-vim-host reloads the module (keeping M.state and a
-- swapped M.host) when the loaded one reports a different api.
M.api = 7

-- history api 1: open() binds the note keys on the sidebar. Reloaded now
-- when already loaded, so a sidebar opened from a :History command an older
-- note module defined has them too.
local function history() return current("voice-vim.history", 1) end
if package.loaded["voice-vim.history"] then history() end

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

-- The captured target (bundle id and window id from show) as a spec:
-- app:<bundle>[#<window>], or clipboard when nothing was captured.
local function captured_spec(meta)
  local bundle = meta and meta.target or ""
  if bundle == "" then return "clipboard" end
  local win = tostring(meta.window or "")
  return target.render({ kind = "app", bundle = bundle, window = win:match("^%d+$") and tonumber(win) or nil })
end

local function header(spec) return "to: " .. spec end

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

local function history_finish(id, outcome, file, spec)
  local pending = db_starts[id]
  db_starts[id] = nil
  if pending then pcall(pending.wait, pending, 5000) end
  local obj = db({ "finish", id, outcome, file, spec or "" })
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

-- Buffer and window settings, keys and commands of a note. Run with the
-- note displayed in the current window.
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
  vim.api.nvim_buf_create_user_command(buf, "History", function() M.toggle_history() end,
    { force = true })
  vim.keymap.set("n", "<leader>h", "<Cmd>History<CR>", { buffer = buf, silent = true })
  -- Submit, cancel and hide. A note never quits the server: :wq and :x
  -- submit, :q hides and keeps the draft.
  local function cmd(name, fn)
    vim.api.nvim_buf_create_user_command(buf, name, function() M[fn](buf) end, { force = true, bang = true })
  end
  cmd("Submit", "submit")
  cmd("Cancel", "cancel")
  cmd("Hide", "hide")
  cmd("Copy", "copy")
  local o = { buffer = buf, silent = true }
  vim.keymap.set("n", "ZZ", "<Cmd>Submit<CR>", o)
  vim.keymap.set({ "n", "i" }, "<C-x>", "<Cmd>Submit<CR>", o)
  vim.keymap.set("n", "ZQ", "<Cmd>Cancel<CR>", o)
  vim.keymap.set({ "n", "i" }, "<C-q>", "<Cmd>Cancel<CR>", o)
  vim.keymap.set({ "n", "i" }, "<C-y>", "<Cmd>Copy<CR>", o)
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
  local hist = history()
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
  -- Also here, not only in hist.open: a sidebar an older history module
  -- opened gets the keys once the note module reloads.
  if hist.is_open() then M.bind_note_keys(hist.state.buf) end
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
  local meta = { id = id, target = opts.target or "", window = opts.window or "", seed = seed }
  meta.auto_spec = captured_spec(meta)
  local body = seed ~= "" and vim.split(seed, "\n", { plain = true }) or { "" }
  vim.api.nvim_buf_set_lines(note.buf, 0, -1, false, target.join(meta.auto_spec, body))
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  M.state.note, M.state.cursor = note, nil
  vim.b[note.buf].voicevim = meta
  history_start(id, meta.auto_spec, seed)
  vim.cmd("startinsert")
  return note
end

local function resume(opts)
  local note = M.state.note
  local buf = note_buf(note)
  display(buf)
  M.apply_options(buf)
  local meta = vim.b[buf].voicevim or { id = note.id, seed = "" }
  local prev = captured_spec(meta)
  meta.target, meta.window = opts.target or "", opts.window or ""
  -- The header follows the new target while it is still the automatic one.
  -- A note that never had one (a blank note, or a draft from before
  -- headers) gets it above its text. A note with a header but no
  -- auto_spec (a draft last held by a module without auto_spec) keeps
  -- that header; it is automatic only when it equals a captured spec.
  local spec = captured_spec(meta)
  local cur = M.state.cursor
  if meta.auto_spec == nil then
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local have = target.split(lines)
    if have == nil then
      vim.api.nvim_buf_set_lines(buf, 0, 0, false, { header(spec) })
      cur = cur and { cur[1] + 1, cur[2] } or { 2, 0 }
      meta.auto_spec = spec
    else
      -- Drop repeats of the header that an earlier resume stacked on it,
      -- so Submit never sends one as the body's first line.
      local extra = 0
      while lines[2 + extra] and target.split({ lines[2 + extra] }) == have do extra = extra + 1 end
      if extra > 0 then
        vim.api.nvim_buf_set_lines(buf, 1, 1 + extra, false, {})
        if cur and cur[1] > 1 then cur = { math.max(cur[1] - extra, 2), cur[2] } end
      end
      if have == prev or have == spec then
        vim.api.nvim_buf_set_lines(buf, 0, 1, false, { header(spec) })
        meta.auto_spec = spec
      else
        meta.auto_spec = false
      end
    end
  elseif meta.auto_spec and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == header(meta.auto_spec) then
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { header(spec) })
    meta.auto_spec = spec
  end
  vim.b[buf].voicevim = meta
  if note.unstarted then
    note.unstarted = nil
    history_start(note.id, spec, "")
  end
  -- Put the cursor back where draft() found it. In insert mode it may sit
  -- just past the end of the line, which normal mode cannot hold.
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

-- Hold to talk: Flow's paste lands at the cursor, so never in the to:
-- header. With the cursor on a header line 1, move to the end of line 2
-- (added when missing) and insert there. Returns true when it moved.
local function off_header(buf)
  local win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_cursor(win)[1] ~= 1 then return false end
  if target.split(vim.api.nvim_buf_get_lines(buf, 0, 1, false)) == nil then return false end
  if vim.api.nvim_buf_line_count(buf) < 2 then vim.api.nvim_buf_set_lines(buf, 1, 1, false, { "" }) end
  local len = #vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1]
  vim.api.nvim_win_set_cursor(win, { 2, len })
  if vim.fn.mode():sub(1, 1) ~= "i" then vim.cmd("startinsert!") end
  return true
end

-- Insert mode at the cursor, like `a` from normal mode (already in insert
-- mode: the cursor stays), never in the header.
local function insert_here(buf)
  if off_header(buf) then return end
  if vim.fn.mode():sub(1, 1) == "i" then return end
  local win = vim.api.nvim_get_current_win()
  local row, col = unpack(vim.api.nvim_win_get_cursor(win))
  local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
  local after = col + #vim.fn.strcharpart(line:sub(col + 1), 0, 1)
  if line ~= "" and after >= #line then
    vim.cmd("startinsert!")
  else
    if line ~= "" then vim.api.nvim_win_set_cursor(win, { row, after }) end
    vim.cmd("startinsert")
  end
end

local function on(v) return v ~= nil and v ~= "" and v ~= "0" and v ~= false and v ~= 0 end

-- Show the note: resume the unfinished one unless seeded, else open a fresh
-- note. opts: { target, window, seed = seed file path, dir = notes folder,
-- sidebar = "0" to leave the history sidebar closed, talk = "1" when
-- Hammerspoon has started Flow (hold to talk) }.
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
  if on(opts.talk) then
    off_header(note.buf)
    flow.adopt_start()
  end
  return note.path
end

-- Hold to talk with the note already in front: no show, no new target, no
-- layout change. Enter insert mode at the cursor (like `a`, never in the
-- header) and tell flow that Hammerspoon started a recording. Returns
-- "talk <path>", or "no note".
function M.talk()
  local note = M.state.note
  if not note then return "no note" end
  local buf = note_buf(note)
  display(buf)
  M.apply_options(buf)
  insert_here(buf)
  flow.adopt_start()
  return "talk " .. note.path
end

-- Hold to talk, key up: stop Flow through flow's queue and wait for its
-- paste into the note (flow.release). A Submit, Cancel or Hide right after
-- takes that wait over. Returns "released", or "idle" when Flow is not
-- recording (nothing sent). opts.force: when idle, treat Flow as recording
-- and stop it anyway (the key-up stop Hammerspoon sends only while the note
-- is focused, so the paste lands here): returns "forced".
function M.release(opts)
  local note = M.state.note
  local buf = note and note_buf(note) or vim.api.nvim_get_current_buf()
  if flow.release(buf) then return "released" end
  if not (opts and on(opts.force)) then return "idle" end
  flow.assume_recording()
  flow.release(buf)
  return "forced"
end

-- Flow as nvim sees it: "recording" (a stop is still due), "waiting" (a
-- stop went out; a Submit, Cancel, Hide or release waits for the paste) or
-- "idle". Hammerspoon's talk key up asks before giving up on a release.
function M.flow_state()
  if flow.recording() then return "recording" end
  if flow.state.waiting then return "waiting" end
  return "idle"
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
-- A key-up release wait has nothing to run after the paste, so draft()
-- makes it a Hide; a Submit or Cancel wait is left as it is.
function M.draft()
  local note = M.state.note
  if not note then return "" end
  local buf = note_buf(note)
  local w = flow.state.waiting
  if w then
    if w.kind == "release" then M.hide(buf) end
    return M.FLOW_WAIT .. " " .. note.path
  end
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
local function finish(buf, outcome, file, spec)
  local meta = vim.b[buf].voicevim or {}
  local note = M.state.note
  local current = note and note.buf == buf
  if meta.id then
    -- A blank note submitted before any show has no row yet.
    if current and note.unstarted then history_start(meta.id, spec, "") end
    history_finish(meta.id, outcome, file, spec)
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

-- The note's target spec and body lines: line 1 `to: <spec>` is the
-- header; without one the spec is the captured target.
-- Repeats of the header right under it (stacked by an older resume) are
-- not body.
local function parts(buf)
  local spec, body = target.split(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  while spec and #body > 0 and target.split({ body[1] }) == spec do table.remove(body, 1) end
  return spec or captured_spec(vim.b[buf].voicevim), body
end

-- Write the body to <notes dir>/outbox/<id>.md and return its path. Not
-- vim.fn.tempname(): nvim deletes that folder on exit, and Hammerspoon
-- reads (then deletes) the submit file after the URL is opened.
local function to_tempfile(buf, body)
  local dir = notes_dir() .. "/outbox"
  vim.fn.mkdir(dir, "p")
  local id = (vim.b[buf].voicevim or {}).id or M.uuid()
  local file = dir .. "/" .. id .. ".md"
  vim.fn.writefile(body, file)
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
  local spec, body = parts(buf)
  local file = to_tempfile(buf, body)
  finish(buf, "cancelled", file, spec)
  os.remove(file)
  M.host.hide({})
end

-- The body as text, or nil when it is blank or unchanged from the seed
-- (a Submit or Copy of it is a cancel).
local function body_text(buf, body)
  local meta = vim.b[buf].voicevim or {}
  local text = table.concat(body, "\n")
  local trim = function(s) return (s:gsub("\n+$", "")) end
  if not text:find("%S") or trim(text) == trim(meta.seed or "") then return nil end
  return text
end

-- Copy: the body on the clipboard (first, so a failure later still leaves
-- it there), recorded as submitted to `clipboard`, then hide.
local function copy_body(buf, body, text)
  vim.fn.setreg("+", text)
  local file = to_tempfile(buf, body)
  finish(buf, "submitted", file, "clipboard")
  os.remove(file)
  M.host.hide({})
end

-- Submit: a blank body, or one unchanged from the seed, is a cancel. An
-- app target goes to the host with only the body; `clipboard` is a Copy.
-- Any other target, or a header that does not parse, cannot be sent yet:
-- the body goes on the clipboard and the note stays current and shown.
local function submit_now(buf)
  local spec, body = parts(buf)
  local text = body_text(buf, body)
  if not text then return cancel_now(buf) end
  local t, err = target.parse(spec)
  if t and t.kind == "clipboard" then return copy_body(buf, body, text) end
  if not (t and t.kind == "app") then
    vim.fn.setreg("+", text)
    vim.notify(string.format("voice-vim: copied — target %q %s", spec,
      t and "cannot be sent to yet" or ("is not valid (" .. tostring(err) .. ")")), vim.log.levels.WARN)
    return
  end
  local file = to_tempfile(buf, body)
  finish(buf, "submitted", file, target.render(t))
  M.host.submit({ file = file, target = t.bundle, window = t.window and tostring(t.window) or "" })
end

-- Copy and hide (:Copy, <C-y>): whatever the header says.
local function copy_now(buf)
  local _, body = parts(buf)
  local text = body_text(buf, body)
  if not text then return cancel_now(buf) end
  copy_body(buf, body, text)
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
function M.copy(buf) buf = bufnr(buf); after_flow(buf, copy_now) end

-- The note of the current tab: the buffer with b:voicevim in the sidebar's
-- main window, else in any window of the tab, else the current note.
-- Returns buf and its window in the tab (nil when not shown), or nil.
function M.tab_note()
  local tab = vim.api.nvim_get_current_tabpage()
  local wins = vim.api.nvim_tabpage_list_wins(tab)
  local hist = package.loaded["voice-vim.history"]
  local main = hist and hist.state and hist.state.main_win
  if main and vim.api.nvim_win_is_valid(main) and vim.api.nvim_win_get_tabpage(main) == tab then
    table.insert(wins, 1, main)
  end
  for _, w in ipairs(wins) do
    local b = vim.api.nvim_win_get_buf(w)
    if type(vim.b[b].voicevim) == "table" then return b, w end
  end
  if M.state.note then return note_buf(M.state.note), nil end
  return nil
end

-- Run a note key ("submit", "cancel", "hide", "copy" or "flow") from another window
-- of the tab, such as the history sidebar: focus the tab's note (so Flow's
-- paste lands there), then act on it, never on the window the key came from.
function M.for_tab_note(action)
  local buf, win = M.tab_note()
  if not buf then
    vim.notify("voice-vim: no note to " .. action, vim.log.levels.WARN)
    return
  end
  if win then vim.api.nvim_set_current_win(win) else display(buf) end
  if action == "flow" then
    -- Joe stays in insert mode (GT 8), at the end of the body: never on
    -- the to: line, where Flow's paste would change the target.
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    if #lines == 1 and target.split(lines) then
      vim.api.nvim_buf_set_lines(buf, 1, 1, false, { "" })
      lines[2] = ""
    end
    vim.api.nvim_win_set_cursor(0, { #lines, 0 })
    vim.cmd("startinsert!")
    return flow.toggle()
  end
  M[action](buf)
end

-- :History and <leader>h in a note: toggle the sidebar, with the note keys
-- on it whichever history module opened it.
function M.toggle_history()
  local hist = history()
  hist.toggle()
  if hist.is_open() then M.bind_note_keys(hist.state.buf) end
end

-- The note keys on a buffer that is not a note (the history sidebar), so a
-- global mapping (e.g. <C-x> = :write) or :wq never hits that buffer.
function M.bind_note_keys(buf)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then return end
  for name, action in pairs({ Submit = "submit", Cancel = "cancel", Hide = "hide", Copy = "copy" }) do
    vim.api.nvim_buf_create_user_command(buf, name, function() M.for_tab_note(action) end,
      { force = true, bang = true })
  end
  local o = { buffer = buf, silent = true, nowait = true }
  vim.keymap.set("n", "ZZ", "<Cmd>Submit<CR>", o)
  vim.keymap.set("n", "<C-x>", "<Cmd>Submit<CR>", o)
  vim.keymap.set("n", "ZQ", "<Cmd>Cancel<CR>", o)
  vim.keymap.set("n", "<C-q>", "<Cmd>Cancel<CR>", o)
  vim.keymap.set("n", "<C-y>", "<Cmd>Copy<CR>", o)
  vim.keymap.set("n", "<C-s>", function() M.for_tab_note("flow") end, o)
  vim.api.nvim_buf_call(buf, function()
    for lhs, rhs in pairs({ wq = "Submit", x = "Submit", q = "Hide" }) do
      vim.cmd(string.format(
        "cnoreabbrev <buffer> <expr> %s getcmdtype() ==# ':' && getcmdline() ==# '%s' ? '%s' : '%s'",
        lhs, lhs, rhs, lhs))
    end
  end)
end

-- Neovide sends Cmd+V as <D-v>; terminals never do. Paste the + register,
-- which is where Wispr Flow puts the dictation, then tell flow a paste
-- landed (terminal pastes reach it through the vim.paste hook instead).
local on_paste = "<Cmd>lua require'voice-vim.flow'.on_paste(0)<CR>"
vim.keymap.set({ "i", "c" }, "<D-v>", "<C-r><C-o>+" .. on_paste, { desc = "voice-vim: paste clipboard" })
vim.keymap.set("n", "<D-v>", '"+p' .. on_paste, { desc = "voice-vim: paste clipboard" })

return M
