-- ferry $EDITOR mode, server side: an outside file (a Claude Code Ctrl-G
-- prompt, a git commit message) edited in the one nvim server.
--
-- bin/ferry-edit (the client) calls start{file, done} over --remote-expr,
-- shows ferry through Hammerspoon, then polls the done file. Like the
-- note functions, each public call takes one table and returns a string.
--
-- The edit is its own buffer in its own tab, never the note: start saves
-- the note's draft first (note.draft, which keeps its cursor), and the note
-- tab is left as it was. While the edit tab is open the tab line is hidden
-- ('showtabline' 0, the old value comes back when the edit ends).
--
-- Keys in the edit buffer, as in a note:
--   <C-x> (n, i), ZZ, :Submit, :wq, :x  write the file, done file "0"
--   <C-q> (n, i), ZQ, :Cancel           leave the file as it is, done "1"
--                                       (git's only reliable abort)
--   :q, :Hide                           hide; the edit stays pending
--   <C-s> (n, i), :Dictate              Wispr Flow hands-free
--   :FixJoin, :FixFillers, <leader>fj, ff, fw, :Corrections
--                                       fix-ups and the corrections list,
--                                       as in a note (fixup api 1,
--                                       corrections api 1)
-- Submit, Cancel and Hide first wait for Flow's last paste when Flow is
-- recording (flow.finish_then), so the last words land in the file and a
-- cancelled dictation lands nowhere.
--
-- Ending the edit writes the file (Submit only, and only when changed),
-- then the done file (the exit code and a newline, written whole through
-- a rename), wipes the buffer, closes the tab and calls note.host.hide{}.
-- A write that fails keeps the edit open and shown, with an error.
--
-- A Submit whose text is not blank is also kept in history (E5): a new
-- note file in the notes folder (opts.dir from start, else note.dir()),
-- named and written as note.lua names and writes notes (store.name,
-- store.write): id, state sent, created (when the edit started), updated
-- and sent (now), target editor:<basename of the file>, then the text as
-- the body; then `ferry-notes index <file>` runs in the background. Cancel,
-- abort and a blank text record nothing. Recording runs after the done
-- file is written and the tab is closed, so it never holds up or fails the
-- edit: an error is one notice.
--
-- A FocusGained while the edit is pending marks it shown: the client waits
-- for that before it trusts the window is up (status(); not state(): M.state
-- is the module's data, kept across reloads). With ferry already in front
-- no FocusGained comes, so the client also passes front = 1 to status()
-- when it sees ferry frontmost (lsappinfo); that marks it shown as well.
--
-- One edit at a time. start answers `busy` while one is pending, or while
-- Flow is busy in the note (recording, or a finish still waiting for its
-- paste), since the note must stay in front for that paste.
--
-- A pending edit wins the hotkey (note api 16 and later): while pending()
-- is true, note.show, talk, release and draft hand their call to
-- on_show, on_talk, on_release and on_draft here, so the hotkey re-shows
-- the edit tab, the talk key dictates at the edit's cursor, and the hotkey
-- pressed in ferry hides with the edit still pending. The note, its
-- captured target and its draft are left alone.
local M = {}

-- Bumped when callers (note.lua, bin/ferry-edit) need functions an older
-- loaded module lacks; a reload keeps M.state.
-- api 3: on_show, on_talk, on_release, on_draft.
-- api 4: a finished Submit is recorded as a sent note; start takes dir.
-- api 5: fix-ups and :Corrections in the edit buffer.
M.api = 5

-- The pending edit: { file, done, dir = notes folder or nil, started =
-- Unix time, buf, tab = edit tab, prev_tab = the tab it came from,
-- showtabline = value before, shown = FocusGained since } or nil.
M.state = { edit = nil }

-- Required at call time: ferry-host may reload the note module (and with
-- it flow) in a running server.
local function note() return require("ferry.note") end
local function flow()
  note()
  return require("ferry.flow")
end

local function alert(msg)
  vim.schedule(function() require("ferry.notice").notify(msg, vim.log.levels.ERROR) end)
end

-- A module at api `want` or later: one loaded before that is reloaded,
-- keeping its M.state (as note.lua's current() does); a failed reload
-- keeps the loaded one.
local function current(name, want)
  local old = require(name)
  if (old.api or 0) >= want then return old end
  package.loaded[name] = nil
  local ok, m = pcall(require, name)
  if ok and type(m) == "table" and (m.api or 0) >= want then
    m.state = old.state
    return m
  end
  package.loaded[name] = old
  return old
end

-- Write "<code>\n" to done whole: a temp file renamed over it, so a
-- polling client never reads it half written.
local function write_done(done, code)
  vim.fn.mkdir(vim.fn.fnamemodify(done, ":h"), "p")
  local tmp = done .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then return false end
  f:write(tostring(code), "\n")
  f:close()
  return os.rename(tmp, done) ~= nil
end

-- --- history -------------------------------------------------------------

local function repo_root()
  local src = debug.getinfo(1, "S").source:sub(2)
  return vim.fn.fnamemodify(src, ":p:h:h:h")
end

-- Local time as ISO 8601 with its offset, as note.lua writes it.
local function iso(t)
  local z = os.date("%z", t)
  return os.date("%Y-%m-%dT%H:%M:%S", t) .. z:sub(1, 3) .. ":" .. z:sub(4, 5)
end

-- Background `ferry-notes index` jobs still running, for M.wait_index.
local indexing, index_n = {}, 0

-- Record a finished edit's text (lines) as a sent note. Raises on failure.
local function record(e, lines)
  if not (lines and table.concat(lines, "\n"):find("%S")) then return end
  local store = require("ferry.store")
  local dir = (e.dir and e.dir ~= "") and e.dir or note().dir()
  local id = note().uuid()
  local started, now = e.started or os.time(), os.time()
  local meta = {}
  store.set(meta, "id", id)
  store.set(meta, "state", "sent")
  store.set(meta, "created", iso(started))
  store.set(meta, "updated", iso(now))
  store.set(meta, "sent", iso(now))
  local name = vim.fn.fnamemodify(e.file, ":t"):gsub("[\r\n]", " ")
  store.set(meta, "target", "editor:" .. name)
  pcall(vim.fn.mkdir, dir, "p")
  local path = dir .. "/" .. store.name(started, id)
  local ok, err = store.write(path, meta, lines)
  if not ok then error(tostring(err), 0) end
  index_n = index_n + 1
  local n = index_n
  local sok, obj = pcall(vim.system, { repo_root() .. "/bin/ferry-notes", "index", path },
    { text = true, env = { FERRY_NOTES_DIR = dir } }, function() indexing[n] = nil end)
  if sok then indexing[n] = obj end
end

-- Wait (up to ms each) for the background index jobs (tests).
function M.wait_index(ms)
  for n, obj in pairs(indexing) do
    pcall(obj.wait, obj, ms or 3000)
    indexing[n] = nil
  end
end

local function tab_ok(tab) return tab and vim.api.nvim_tabpage_is_valid(tab) end

-- Close the edit tab (back to the tab it came from), drop the buffer and
-- put 'showtabline' back. The edit is already out of M.state.
local function teardown(e)
  if tab_ok(e.tab) and #vim.api.nvim_list_tabpages() > 1 then
    if vim.api.nvim_get_current_tabpage() == e.tab then
      if tab_ok(e.prev_tab) and e.prev_tab ~= e.tab then
        vim.api.nvim_set_current_tabpage(e.prev_tab)
      else
        vim.cmd("tabprevious")
      end
    end
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(e.tab)) do pcall(vim.api.nvim_win_close, w, true) end
  end
  if vim.api.nvim_buf_is_valid(e.buf) then pcall(vim.api.nvim_buf_delete, e.buf, { force = true }) end
  if e.showtabline ~= nil then vim.o.showtabline = e.showtabline end
  vim.cmd("stopinsert")
end

-- End the pending edit with code 0 (write the file) or 1 (leave it).
-- Returns false when the write failed: the edit stays pending and shown.
local function finish(e, code)
  local lines = code == 0 and vim.api.nvim_buf_is_valid(e.buf) and vim.api.nvim_buf_get_lines(e.buf, 0, -1, false)
  if code == 0 and vim.api.nvim_buf_is_valid(e.buf) and vim.bo[e.buf].modified then
    local ok, err
    vim.api.nvim_buf_call(e.buf, function() ok, err = pcall(vim.cmd, "silent keepalt write!") end)
    if not ok then
      err = tostring(err)
      alert("ferry: could not write " .. e.file .. ": " .. (err:match("E%d+:.*") or err))
      return false
    end
  end
  M.state.edit = nil
  if not write_done(e.done, code) then alert("ferry: could not write " .. e.done) end
  teardown(e)
  if lines then
    local ok, err = pcall(record, e, lines)
    if not ok then alert("ferry: the edit was saved, but not kept in history: " .. tostring(err)) end
  end
  return true
end

-- The pending edit when buf is its buffer (any buffer when buf is nil).
local function edit_of(buf)
  local e = M.state.edit
  if e and (buf == nil or e.buf == buf) then return e end
  return nil
end

-- Run fn(edit) once Flow's last paste has landed, if the edit in buf is
-- still pending by then.
local function after_flow(buf, fn)
  flow().finish_then(buf, function()
    local e = edit_of(buf)
    if e then fn(e) end
  end)
end

local function bufnr(buf) return (buf and buf ~= 0) and buf or vim.api.nvim_get_current_buf() end

function M.submit(buf)
  buf = bufnr(buf)
  after_flow(buf, function(e)
    if finish(e, 0) then note().host.hide({}) end
  end)
end

function M.cancel(buf)
  buf = bufnr(buf)
  after_flow(buf, function(e)
    finish(e, 1)
    note().host.hide({})
  end)
end

-- Hide with the edit still pending (:q, and the hotkey through E4).
function M.hide(buf)
  buf = bufnr(buf)
  after_flow(buf, function()
    vim.cmd("stopinsert")
    note().host.hide({})
  end)
end

-- Options, keys and commands of the edit buffer (current window).
local function apply_options(buf)
  vim.cmd([[
    setlocal wrap linebreak nolist
    setlocal noswapfile nobackup nowritebackup noundofile
    setlocal bufhidden=hide
  ]])
  flow().attach(buf)
  local function cmd(name, fn)
    vim.api.nvim_buf_create_user_command(buf, name, fn, { force = true, bang = true })
  end
  cmd("Submit", function() require("ferry.edit").submit(buf) end)
  cmd("Cancel", function() require("ferry.edit").cancel(buf) end)
  cmd("Hide", function() require("ferry.edit").hide(buf) end)
  cmd("Dictate", function() require("ferry.flow").start() end)
  -- Fix-ups and :Corrections, as in a note; a fix-up module that fails to
  -- load costs only its keys.
  local fok, ferr = pcall(function() current("ferry.fixup", 1).setup(buf) end)
  if not fok then alert("ferry: fix-up keys unavailable: " .. tostring(ferr)) end
  vim.api.nvim_buf_create_user_command(buf, "Corrections", function()
    current("ferry.corrections", 1).open({ dir = (M.state.edit or {}).dir })
  end, { force = true, desc = "ferry: words you keep fixing after Wispr Flow" })
  local o = { buffer = buf, silent = true }
  vim.keymap.set("n", "ZZ", "<Cmd>Submit<CR>", o)
  vim.keymap.set({ "n", "i" }, "<C-x>", "<Cmd>Submit<CR>", o)
  vim.keymap.set("n", "ZQ", "<Cmd>Cancel<CR>", o)
  vim.keymap.set({ "n", "i" }, "<C-q>", "<Cmd>Cancel<CR>", o)
  vim.keymap.set({ "n", "i" }, "<C-s>", "<Cmd>lua require'ferry.flow'.toggle()<CR>", o)
  vim.api.nvim_buf_call(buf, function()
    for lhs, rhs in pairs({ wq = "Submit", x = "Submit", q = "Hide" }) do
      vim.cmd(string.format(
        "cnoreabbrev <buffer> <expr> %s getcmdtype() ==# ':' && getcmdline() ==# '%s' ? '%s' : '%s'",
        lhs, lhs, rhs, lhs))
    end
  end)
  -- Wiped by hand (:bwipe): the edit cannot finish, so it is cancelled.
  local group = vim.api.nvim_create_augroup("ferry_edit_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd("BufWipeout", { group = group, buffer = buf, callback = function()
    local e = edit_of(buf)
    if not e then return end
    M.state.edit = nil
    write_done(e.done, 1)
    if e.showtabline ~= nil then vim.o.showtabline = e.showtabline end
  end })
end

local function absolute(p) return type(p) == "string" and p:sub(1, 1) == "/" end

-- Start editing opts.file (absolute path; a missing file starts empty and
-- is created on Submit). opts.done (absolute path) gets the exit code when
-- the edit ends. opts.dir: the notes folder a Submit is recorded in
-- (default note.dir(), the server's; bin/ferry-edit never passes one). Returns "ok", "busy", or "error <why>".
function M.start(opts)
  opts = opts or {}
  if not (absolute(opts.file) and absolute(opts.done)) then
    return "error file and done must be absolute paths"
  end
  if M.state.edit then return "busy" end
  local n, f = note(), flow()
  if f.recording() or f.state.waiting then return "busy" end
  local old = vim.fn.bufnr(opts.file)
  if old ~= -1 and type(vim.b[old].ferry) == "table" then return "error " .. opts.file .. " is a note" end
  if n.current() then n.draft({}) end
  -- A buffer left over for the same file would show stale text.
  if old ~= -1 then pcall(vim.api.nvim_buf_delete, old, { force = true }) end
  local e = { file = opts.file, done = opts.done, prev_tab = vim.api.nvim_get_current_tabpage(),
    showtabline = vim.o.showtabline, shown = false, started = os.time(),
    dir = type(opts.dir) == "string" and opts.dir ~= "" and opts.dir or nil }
  local ok, err = pcall(vim.cmd, "silent noswapfile tabedit " .. vim.fn.fnameescape(opts.file))
  if not ok then return "error " .. tostring(err) end
  e.tab, e.buf = vim.api.nvim_get_current_tabpage(), vim.api.nvim_get_current_buf()
  vim.o.showtabline = 0
  M.state.edit = e
  apply_options(e.buf)
  local group = vim.api.nvim_create_augroup("ferry-edit", { clear = true })
  vim.api.nvim_create_autocmd("FocusGained", { group = group, callback = function()
    local cur = require("ferry.edit").state.edit
    if cur then cur.shown = true end
  end })
  -- Called in insert mode (the note was left in it), draft's stopinsert
  -- ends insert mode only after this call, and :startinsert is ignored
  -- until then: poll on a timer (a vim.schedule runs too soon) for normal
  -- mode, then insert again.
  if vim.fn.mode():sub(1, 1) == "i" then
    local tries = 0
    local function again()
      if M.state.edit ~= e or vim.api.nvim_get_current_buf() ~= e.buf then return end
      local mode = vim.fn.mode()
      if mode == "n" then return vim.cmd("startinsert") end
      tries = tries + 1
      if mode:sub(1, 1) == "i" and tries < 50 then vim.defer_fn(again, 10) end
    end
    vim.defer_fn(again, 0)
  else
    vim.cmd("startinsert")
  end
  return "ok"
end

-- Bring the pending edit's tab back to front (reopened when it was
-- closed, e.g. :q! in it) in insert mode. Returns the file, or "none".
function M.show()
  local e = M.state.edit
  if not e then return "none" end
  if not vim.api.nvim_buf_is_valid(e.buf) then return "none" end
  if tab_ok(e.tab) then
    vim.api.nvim_set_current_tabpage(e.tab)
  else
    vim.cmd("tab sbuffer " .. e.buf)
    e.tab = vim.api.nvim_get_current_tabpage()
    vim.o.showtabline = 0
  end
  local win = vim.fn.bufwinid(e.buf)
  if win ~= -1 then vim.api.nvim_set_current_win(win) else vim.api.nvim_win_set_buf(0, e.buf) end
  vim.cmd("startinsert")
  return e.file
end

-- End the edit with done file opts.done as Cancel would (code 1, the file
-- left alone): at once, unless Flow is recording in the edit or a
-- Submit/Cancel/Hide of it is waiting for Flow's paste. Then Flow is
-- stopped (or that wait taken over) and the edit ends once the paste has
-- landed, so Flow is idle and the next start is not busy. It hides ferry
-- only when the edit had been shown. Returns "aborted", "aborting" (ends
-- after Flow's paste, within flow.paste_timeout_ms), or "none" when no
-- pending edit has that done file.
function M.abort(opts)
  local e = M.state.edit
  if not (e and opts and e.done == opts.done) then return "none" end
  local function cancel(cur)
    local shown = cur.shown
    finish(cur, 1)
    if shown then note().host.hide({}) end
  end
  local f = flow()
  local w = f.state.waiting
  if (w and w.buf == e.buf) or (not w and f.recording() and vim.api.nvim_get_current_buf() == e.buf) then
    after_flow(e.buf, cancel)
    return M.state.edit == e and "aborting" or "aborted"
  end
  cancel(e)
  return "aborted"
end

-- "pending" (started, no FocusGained yet), "shown", or "done" when no
-- pending edit has done file opts.done (it ended, or never started).
-- opts.front (1/true: the client saw ferry frontmost) marks it shown.
function M.status(opts)
  local e = M.state.edit
  if not (e and opts and e.done == opts.done) then return "done" end
  local front = opts.front
  if front == true or front == 1 or front == "1" then e.shown = true end
  return e.shown and "shown" or "pending"
end

-- True while an edit is pending.
function M.pending() return M.state.edit ~= nil end

local function on(v) return v ~= nil and v ~= "" and v ~= "0" and v ~= false and v ~= 0 end

-- note.show while an edit is pending (the hotkey from another app): show
-- the edit tab in insert mode instead of the note. opts.talk (hold to
-- talk; Hammerspoon has started Flow): Flow is recording into the edit.
-- The seed, target and window are ignored: the note keeps its own.
-- Returns the edit's file.
function M.on_show(opts)
  local file = M.show()
  if file ~= "none" and opts and on(opts.talk) then flow().adopt_start() end
  return file
end

-- Insert mode at the cursor, like `a` from normal mode (already in insert
-- mode: the cursor stays). As note.lua's insert_here.
local function insert_here(buf)
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

-- note.talk while an edit is pending (the talk key with ferry in front):
-- dictate at the edit's cursor (the edit tab is brought back first when
-- another tab is current). Returns "talk <file>", or "no note" when the
-- edit buffer is gone.
function M.on_talk()
  local e = M.state.edit
  if not (e and vim.api.nvim_buf_is_valid(e.buf)) then return "no note" end
  if vim.api.nvim_get_current_buf() ~= e.buf then
    if M.show() == "none" then return "no note" end
  else
    insert_here(e.buf)
  end
  flow().adopt_start()
  return "talk " .. e.file
end

-- note.release while an edit is pending (talk key up): stop Flow and wait
-- for its paste into the edit buffer. As note.release: "released",
-- "idle", or "forced" with opts.force.
function M.on_release(opts)
  local e = M.state.edit
  local buf = (e and vim.api.nvim_buf_is_valid(e.buf)) and e.buf or vim.api.nvim_get_current_buf()
  local f = flow()
  if f.release(buf) then return "released" end
  if not (opts and on(opts.force)) then return "idle" end
  f.assume_recording()
  f.release(buf)
  return "forced"
end

-- note.draft while an edit is pending (the hotkey with ferry in front):
-- leave the edit pending and let Hammerspoon hide ferry; the note's draft
-- was saved when the edit started. While Flow is recording or a wait for
-- its paste runs, ferry must stay in front for that paste: the edit hides
-- itself after it (as :Hide does; a key-up release wait becomes that
-- Hide) and this returns "waiting for flow <file>", so the caller does not
-- hide. Returns the edit's file otherwise.
function M.on_draft()
  local e = M.state.edit
  local f, wait = flow(), note().FLOW_WAIT or "waiting for flow"
  local w = f.state.waiting
  if w then
    if w.kind == "release" then M.hide(e.buf) end
    return wait .. " " .. e.file
  end
  if f.recording() then
    M.hide(e.buf)
    return wait .. " " .. e.file
  end
  vim.cmd("stopinsert")
  return e.file
end

return M
