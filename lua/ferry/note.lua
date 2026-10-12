-- ferry note core: runs inside the one long-lived nvim server.
--
-- bin/ferry-host calls the public functions over --remote-expr as
-- luaeval('require"ferry.note".<fn>(_A)', {dict}). Each takes one table
-- and returns a string, which ferry-host prints.
--
-- One note is "current" until it is finished. show() resumes it, unless a
-- seed (captured selection) asks for a fresh note.
--
-- Notes persist as markdown files (GROUND_TRUTHS decision 11), one per
-- note, <notes dir>/<YYYY-MM-DD-HHMMSS>-<id8>.md (lua/ferry/store.lua):
-- frontmatter (id, state, created, updated, sent, target, ...), then the
-- body. The buffer never shows the frontmatter: it is the body only, and
-- BufWriteCmd (also :w) writes the file through store.write,
-- then runs `ferry-notes index <file>` in the background. A note gets its
-- file on its first change (an untouched blank note leaves nothing);
-- drafts autosave about 1 s after a change, and on draft and Hide. Submit
-- marks the file `sent`, Cancel `cancelled`; a blank Cancel deletes it.
-- The files and their index are the only record; the browser
-- (lua/ferry/history.lua) lists the index and opens a note with M.open.
-- (Note api 13 and older also wrote the old history database, which is
-- left on disk untouched.)
--
-- In a note, :Submit (ZZ, <C-x>, :wq, :x), :Cancel (ZQ) and :Hide (:q)
-- call M.host instead of exiting. Hide keeps the note as the draft.
-- Submit files go in $FERRY_OUTBOX (default ${TMPDIR}/ferry-outbox; they
-- must outlive the server, so not vim.fn.tempname()). After Submit or
-- Cancel the window shows a new, empty note, so :q there still hides
-- instead of quitting the server.
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
-- Submit sends the whole buffer to the target captured at the latest show
-- (b:ferry.target and .window; every show and resume takes the new one),
-- or copies it when nothing was captured; :Copy (<C-y>) copies it and
-- hides. The file stores that target as a spec (lua/ferry/target.lua), or
-- `clipboard` after a copy. Note api 11 and older showed it as a `to:`
-- header on line 1; see drop_header for the upgrade.
--
-- ferry never overwrites an outside edit: it remembers the bytes of the
-- note file as it last wrote or read it (b:ferry_disk, a sha256). A write
-- that finds the file changed since forks instead: the buffer moves to a
-- sibling <name>.conflict-<time>.md (a fresh id, `conflict_of: <id>`,
-- state draft), which holds ferry's text from then on, and the outside
-- edit stays in the original file. One notice. A file changed outside
-- reloads into the buffer when it has no unsaved typing; with typing, the
-- fork happens at once. Only a file that matches ferry's own last write
-- changes without a word.
local M = {}

-- A module note.lua needs at api `want` or later. A running server can hold
-- one loaded before that (api lower or unset); reload it, keeping its
-- M.state, as ferry-host does for this module, then run adopt(old, new)
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

-- flow api 5: adopt_start, release, a quick second hold during a release
-- wait, a stray paste keeps an adopted recording, stopped(); api 6: a
-- timed-out wait forgets its stop, one-line notices. Its state
-- keeps a recording and the pending wait across the reload.
-- The old module's vim.paste hook stays installed, so its on_paste forwards
-- to the new one (which counts a paste reported by both hooks once).
local flow = current("ferry.flow", 6, function(old, new)
  old.on_paste = function(b) return new.on_paste(b) end
end)
local target = require("ferry.target")
local store = require("ferry.store")
-- Notices: one screen line, the full text in :messages (ferry.notice).
local function say(msg, level) require("ferry.notice").notify(msg, level) end

-- Bumped when the module changes in a way an already-running server must
-- pick up: bin/ferry-host reloads the module (keeping M.state and a
-- swapped M.host) when the loaded one reports a different api.
-- 15: one-line notices; a wiped buffer's note keeps its fork's file id.
M.api = 15

-- history api 4: the browser on the notes index (open, send, pin, ...,
-- / search; opening syncs). A sidebar the old module opened keeps its
-- keys bound to the old functions (and, before api 3, lists rows of the
-- old database), so rebind its keys to the new ones and list it again.
local function history()
  return current("ferry.history", 4, function(_, new)
    if new.is_open() then
      new.bind_keys(new.state.buf)
      vim.schedule(function() pcall(new.refresh) end)
    end
  end)
end

-- The current (unfinished) note: { id = uuid, path = file, buf = bufnr,
-- created = Unix time its file name was stamped with (nil: a note from
-- before note files, see adopt()), unstarted = true for the blank note
-- after a finish until a show resumes it (see blank()) }.
-- dir: the notes folder of the last call that named one (ferry-host
-- passes it on every call).
M.state = { note = nil, cursor = nil, dir = nil }

local function notes_dir(opts)
  if opts and opts.dir and opts.dir ~= "" then return opts.dir end
  if M.state.dir then return M.state.dir end
  local env = os.getenv("FERRY_NOTES_DIR")
  if env and env ~= "" then return env end
  return (os.getenv("HOME") or "") .. "/notes/scratchpads"
end

-- The notes folder (the history browser lists it).
function M.dir() return notes_dir() end

local function use_dir(opts)
  if type(opts) == "table" and opts.dir and opts.dir ~= "" then M.state.dir = opts.dir end
end

-- Submit files: $FERRY_OUTBOX, else ${TMPDIR}/ferry-outbox. Hammerspoon
-- reads and deletes each one.
local function outbox_dir()
  local env = os.getenv("FERRY_OUTBOX")
  if env and env ~= "" then return env end
  local tmp = (os.getenv("TMPDIR") or "/tmp"):gsub("/$", "")
  return tmp .. "/ferry-outbox"
end

-- Local time as ISO 8601 with its offset: 2026-10-12T09:15:02-07:00.
local function iso(t)
  local z = os.date("%z", t)
  return os.date("%Y-%m-%dT%H:%M:%S", t) .. z:sub(1, 3) .. ":" .. z:sub(4, 5)
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

local function repo_root()
  local src = debug.getinfo(1, "S").source:sub(2)
  return vim.fn.fnamemodify(src, ":p:h:h:h")
end

-- The note's target spec (the captured one) and its body (every line).
local function parts(buf)
  return captured_spec(vim.b[buf].ferry), vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

local function is_blank(body) return not table.concat(body, "\n"):find("%S") end

-- sha256 of buf's text (a note opened from the browser remembers it).
local function body_sum(buf)
  return vim.fn.sha256(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
end

local function readable(path) return path ~= "" and vim.fn.filereadable(path) == 1 end

-- --- note files ---------------------------------------------------------

local function same_file(a, b)
  return vim.fn.resolve(vim.fn.fnamemodify(a, ":p")) == vim.fn.resolve(vim.fn.fnamemodify(b, ":p"))
end

-- Reindex one note file (or drop its row when the file is gone) in the
-- background. The index lives in $FERRY_INDEX (ferry-notes' default
-- otherwise); the notes folder is the file's own. Jobs still running are
-- kept in `indexing` until they exit, for M.wait_index.
local indexing, index_n = {}, 0
local function index(path)
  -- Spelled the way the notes folder is (nvim resolves /tmp to
  -- /private/tmp in buffer names), so the index keeps one path per file.
  local dir = vim.fn.fnamemodify(path, ":h")
  if same_file(dir, notes_dir()) then
    dir = notes_dir()
    path = dir .. "/" .. vim.fn.fnamemodify(path, ":t")
  end
  index_n = index_n + 1
  local n = index_n
  local ok, obj = pcall(vim.system, { repo_root() .. "/bin/ferry-notes", "index", path },
    { text = true, env = { FERRY_NOTES_DIR = dir } }, function() indexing[n] = nil end)
  if ok then indexing[n] = obj end
end

-- Wait (up to ms each) for the background index jobs, so a list that
-- follows sees every note file written so far.
function M.wait_index(ms)
  for n, obj in pairs(indexing) do
    pcall(obj.wait, obj, ms or 3000)
    indexing[n] = nil
  end
end

-- An error notice, shown after the current command: raised inside :write
-- (BufWriteCmd) or a vim.cmd, an error message would abort the caller
-- halfway (a Cancel would stop before keeping the note).
local function alert(msg)
  vim.schedule(function() say(msg, vim.log.levels.ERROR) end)
end

-- --- outside edits ------------------------------------------------------

-- sha256 of the file's bytes, or nil when it cannot be read.
local function digest(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local text = f:read("a")
  f:close()
  return vim.fn.sha256(text or "")
end

-- Remember the file's bytes as ferry wrote or read them into buf (their
-- sha256, from digest() or of the text ferry itself wrote: re-reading the
-- file after a write would take an outside write in between as ferry's).
local function remember(buf, sum) vim.b[buf].ferry_disk = sum end

-- True when path holds what ferry last wrote or read into buf. A buffer
-- with no record (held over from note api 10 or older) counts as ferry's.
local function ours(buf, path)
  local rec = vim.b[buf].ferry_disk
  if type(rec) ~= "string" then return true end
  return digest(path) == rec
end

-- Rename buf to path, dropping the unloaded buffer that renaming leaves
-- behind under the old name. No file is moved.
local function rename(buf, path)
  local old = vim.api.nvim_buf_get_name(buf)
  vim.api.nvim_buf_set_name(buf, path)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if b ~= buf and not vim.api.nvim_buf_is_loaded(b) and vim.api.nvim_buf_get_name(b) == old then
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end
end

-- <dir>/<name>.conflict-<date>-<time>.md next to path, not taken yet.
-- path a conflict file itself: <name> is its original's stem, so names do
-- not chain (x.conflict-A.conflict-B.md).
local function conflict_path(path)
  local stem = path:gsub("%.md$", ""):gsub("%.conflict%-%d%d%d%d%-%d%d%-%d%d%-%d%d%d%d%d%d[%-%d]*$", "")
  local base = stem .. ".conflict-" .. os.date("%Y-%m-%d-%H%M%S")
  local p, n = base .. ".md", 1
  while vim.uv.fs_stat(p) do
    n = n + 1
    p = base .. "-" .. n .. ".md"
  end
  return p
end

-- path (buf's note file) changed outside ferry: leave it as it is and move
-- buf to a conflict file beside it, which takes ferry's text from now on.
-- Returns the conflict file's base frontmatter (the original's, with a
-- fresh id, `conflict_of` and state draft) and its path. The buffer keeps
-- the fork's id and conflict_of (b:ferry.file_id, .conflict_of), so a
-- conflict file that is never written or is deleted later is recreated
-- as the fork, never under the original's id. b:ferry.id and note.id
-- stay (note.file_id names the file).
local function fork(buf, path)
  local meta = store.read(path) or {}
  local b = vim.b[buf].ferry or {}
  local orig = rawget(meta, "id") or b.file_id or b.id
  local id = M.uuid()
  local new = conflict_path(path)
  store.set(meta, "id", id)
  store.set(meta, "state", "draft")
  if orig then store.set(meta, "conflict_of", orig) end
  if type(vim.b[buf].ferry) == "table" then
    b.file_id, b.conflict_of = id, orig
    vim.b[buf].ferry = b
  end
  rename(buf, new)
  vim.b[buf].ferry_disk = nil
  local note = M.state.note
  if note and note.buf == buf then note.path, note.file_id, note.conflict_of = new, id, orig end
  index(path)
  say(string.format("ferry: %s was changed outside ferry and is kept as it is; your text is in %s",
    vim.fn.fnamemodify(path, ":t"), vim.fn.fnamemodify(new, ":t")), vim.log.levels.WARN)
  return meta, new
end

-- Write buf's note file: its frontmatter (kept from the file, unknown keys
-- and all) with id, state, created, updated and target set, then the body.
-- opts: state (else the file's, else draft), sent = true to stamp `sent`,
-- target (else the note's spec). A file changed outside ferry is never
-- overwritten: the note forks to a conflict file (see fork). Returns true,
-- or false after an error notice.
local function write_note(buf, opts)
  opts = opts or {}
  local path = vim.api.nvim_buf_get_name(buf)
  if path == "" then return false end
  local spec, body = parts(buf)
  local meta
  if readable(path) and not ours(buf, path) then
    meta, path = fork(buf, path)
  else
    meta = readable(path) and store.read(path) or {}
  end
  local b = vim.b[buf].ferry or {}
  local now = os.time()
  store.set(meta, "id", rawget(meta, "id") or b.file_id or b.id)
  if b.conflict_of and not rawget(meta, "conflict_of") then store.set(meta, "conflict_of", b.conflict_of) end
  store.set(meta, "state", opts.state or rawget(meta, "state") or "draft")
  store.set(meta, "created", rawget(meta, "created") or iso(tonumber(b.created) or now))
  store.set(meta, "updated", iso(now))
  if opts.sent then store.set(meta, "sent", iso(now)) end
  store.set(meta, "target", opts.target or spec)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local text = store.format(meta, body)
  local ok, err = store.write(path, meta, body)
  if not ok then
    alert("ferry: could not save the note to " .. path .. ": " .. tostring(err))
    return false
  end
  remember(buf, vim.fn.sha256(text))
  vim.bo[buf].modified = false
  index(path)
  return true
end

-- Save a note as it stands (a draft keeps its state): when it changed
-- since the last save, or has text but no file yet. A blank note without
-- a file gets none. Returns false when the write failed (after its error
-- notice; the buffer keeps its text), else true.
local function save(buf)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then return true end
  local path = vim.api.nvim_buf_get_name(buf)
  local _, body = parts(buf)
  if not readable(path) then
    if is_blank(body) then
      vim.bo[buf].modified = false
      return true
    end
  elseif not vim.bo[buf].modified then
    return true
  end
  -- Through :write! (so BufWriteCmd, write_note), not write_note itself:
  -- only a write nvim knows of clears its "file exists" (E13) guard on a
  -- buffer whose file appeared after it was loaded, so a later :w works.
  -- With BufWriteCmd set, BufWritePre/Post (formatters) do not run.
  vim.api.nvim_buf_call(buf, function() vim.cmd("silent keepalt write!") end)
  return readable(vim.api.nvim_buf_get_name(buf)) and not vim.bo[buf].modified
end

-- Autosave: about 1 s after the last change (swappable for tests).
M.autosave_ms = 1000
local timers = {}

local function stop_timer(buf)
  local t = timers[buf]
  if t then
    timers[buf] = nil
    t:stop()
    if not t:is_closing() then t:close() end
  end
end

local function autosave(buf)
  local t = timers[buf]
  if not t then
    t = vim.uv.new_timer()
    timers[buf] = t
  end
  t:stop()
  t:start(M.autosave_ms, 0, vim.schedule_wrap(function()
    if vim.api.nvim_buf_is_valid(buf) and type(vim.b[buf].ferry) == "table" then save(buf) end
  end))
end

-- Load a note file into buf (BufReadCmd, :e!, a wiped buffer).
local function load(buf)
  local path = vim.api.nvim_buf_get_name(buf)
  if not readable(path) then return end
  -- Hashed before the read: a write in between then reads as an outside
  -- edit (kept), never as ferry's.
  local sum = digest(path)
  local meta, body = store.read(path)
  if not meta then return end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, body)
  vim.b[buf].ferry_body = true
  remember(buf, sum)
  vim.bo[buf].modified = false
end

-- The file changed under buf (FileChangedShell, e.g. on focus): never a
-- prompt. Still ferry's own last write: nothing to do. Changed outside:
-- reload it when the buffer has no unsaved typing, else save now, which
-- forks the typing to a conflict file (write_note).
local function changed_outside(buf)
  vim.v.fcs_choice = ""
  local path = vim.api.nvim_buf_get_name(buf)
  if not readable(path) or ours(buf, path) then return end
  vim.schedule(function()
    if not vim.api.nvim_buf_is_valid(buf) or vim.api.nvim_buf_get_name(buf) ~= path then return end
    if vim.bo[buf].modified then
      save(buf)
    elseif not ours(buf, path) then
      load(buf)
      say("ferry: reloaded " .. vim.fn.fnamemodify(path, ":t") .. " (changed outside ferry)",
        vim.log.levels.INFO)
    end
  end)
end

-- The file autocmds of a note buffer: :w and every write go through the
-- note file format, :e reads it back, changes autosave, and the file
-- changing under the buffer never prompts (see changed_outside).
local function attach(buf)
  local group = vim.api.nvim_create_augroup("ferry_note_" .. buf, { clear = true })
  local function au(ev, fn) vim.api.nvim_create_autocmd(ev, { group = group, buffer = buf, callback = fn }) end
  au("BufWriteCmd", function(a)
    if same_file(a.file, vim.api.nvim_buf_get_name(buf)) then
      if readable(vim.api.nvim_buf_get_name(buf)) or not is_blank(select(2, parts(buf))) then
        -- Edited text is a draft again (a sent note opened from the
        -- browser); an unchanged one keeps its state.
        write_note(buf, { state = vim.bo[buf].modified and "draft" or nil })
      else
        vim.bo[buf].modified = false
      end
    else
      vim.fn.writefile(vim.api.nvim_buf_get_lines(buf, 0, -1, false), a.file)
    end
  end)
  au("BufReadCmd", function() load(buf) end)
  au({ "TextChanged", "TextChangedI", "InsertLeave" }, function() autosave(buf) end)
  au("FileChangedShell", function() changed_outside(buf) end)
  au("BufWipeout", function() stop_timer(buf) end)
end

-- Stamp a note's file name with the time now: <dir>/<date>-<time>-<id8>.md,
-- with the file's id (a fork's own, else the note's).
-- A buffer already open is renamed (no file is moved).
local function place(note, dir)
  note.created = os.time()
  local old = note.path
  note.path = dir .. "/" .. store.name(note.created, note.file_id or note.id)
  local buf = note.buf
  if buf and vim.api.nvim_buf_is_valid(buf) then
    local m = vim.b[buf].ferry
    if type(m) == "table" then m.created = note.created; vim.b[buf].ferry = m end
    if old ~= note.path then rename(buf, note.path) end
  end
end

-- A note held over from a module before note files (API 8 and older): its
-- buffer is named <old notes dir>/<id>.md and writes raw text. Give it a
-- note file name in the notes folder and the file autocmds; it is written
-- there on its next change, draft or Hide. The old file is left alone.
local function adopt(note)
  if note.created then return end
  place(note, notes_dir())
  attach(note.buf)
end

-- Note api 11 and older showed the target as a `to: <spec>` header on line
-- 1 of the buffer. A buffer such a module held (no b:ferry_body) loses that
-- line the first time this module touches it: the text below stays, the
-- cursor stays on the same text (also the one draft() kept), and the
-- modified flag is kept, since the file already stores the body and the
-- target apart. Buffers this module fills are marked b:ferry_body, so a
-- body line starting with `to:` is never taken for a header.
local function drop_header(buf)
  if vim.b[buf].ferry_body then return end
  vim.b[buf].ferry_body = true
  if target.split(vim.api.nvim_buf_get_lines(buf, 0, 1, false)) == nil then return end
  local modified = vim.bo[buf].modified
  local cursors = {}
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do cursors[win] = vim.api.nvim_win_get_cursor(win) end
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, {})
  vim.bo[buf].modified = modified
  local up = function(c) return c[1] > 1 and { c[1] - 1, c[2] } or { 1, 0 } end
  for win, c in pairs(cursors) do pcall(vim.api.nvim_win_set_cursor, win, up(c)) end
  local note = M.state.note
  if note and note.buf == buf and M.state.cursor then M.state.cursor = up(M.state.cursor) end
end

-- The note's buffer, reloading it from its file if it was wiped.
local function note_buf(note)
  if not (note.buf and vim.api.nvim_buf_is_valid(note.buf)) then
    note.buf = vim.fn.bufadd(note.path)
    vim.fn.bufload(note.buf)
    if note.created then
      attach(note.buf)
      load(note.buf)
    end
  end
  drop_header(note.buf)
  adopt(note)
  return note.buf
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

-- Put text on the clipboard and confirm it is there: true when + reads
-- back as text. A provider whose copy throws or drops the text raises no
-- error from setreg, so the read-back is the only proof.
local function to_clipboard(text)
  local trim = function(s) return (s:gsub("\n+$", "")) end
  local ok = pcall(vim.fn.setreg, "+", text)
  if not ok then return false end
  local got_ok, got = pcall(vim.fn.getreg, "+")
  return got_ok and type(got) == "string" and trim(got) == trim(text)
end

local CLIP_FAIL = "ferry: could not copy to the clipboard — note kept"
-- For the history browser's copy.
M.to_clipboard, M.CLIP_FAIL = to_clipboard, CLIP_FAIL

-- The default host talks to Hammerspoon. submit{file,target,window} reuses
-- V0's ferry-submit URL (Hammerspoon reads, delivers and deletes the
-- file); hide{} asks it to hide the host and refocus the target. If the URL
-- cannot be opened, the text goes on the clipboard instead.
M.default_host = {}

function M.default_host.submit(p)
  local url = "hammerspoon://ferry-submit?file=" .. enc(p.file) .. "&target=" .. enc(p.target)
  if p.window and p.window ~= "" then url = url .. "&window=" .. enc(p.window) end
  open_url(url, function()
    local f = io.open(p.file, "r")
    local text = f and f:read("a") or ""
    if f then f:close() end
    if to_clipboard((text:gsub("\n$", ""))) then
      os.remove(p.file)
      say("ferry: copied — paste manually", vim.log.levels.WARN)
    else
      say("ferry: could not reach Hammerspoon or copy to the clipboard — text kept in "
        .. p.file, vim.log.levels.ERROR)
    end
  end)
end

function M.default_host.hide()
  open_url("hammerspoon://ferry-hide", function()
    say("ferry: could not reach Hammerspoon to hide", vim.log.levels.WARN)
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
  attach(buf)
  -- Wispr Flow: a paste into the note means Flow stopped. :Dictate starts
  -- hands-free; <C-s> toggles it without leaving insert mode.
  flow.attach(buf)
  vim.api.nvim_buf_create_user_command(buf, "Dictate", function() flow.start() end, { force = true })
  vim.keymap.set("n", "<leader>d", "<Cmd>Dictate<CR>", { buffer = buf, silent = true })
  vim.keymap.set({ "n", "i" }, "<C-s>", "<Cmd>lua require'ferry.flow'.toggle()<CR>",
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
  local hist = package.loaded["ferry.history"]
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
  if v == nil or v == "" then v = os.getenv("FERRY_SIDEBAR") end
  return v ~= "0"
end

-- The note window (current) is the only normal window in its tab, plus the
-- history sidebar on the left unless sidebar is off (FERRY_SIDEBAR=0),
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
  local id = (vim.b.ferry or {}).id
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

-- A new note buffer with the note options, shown in the current window.
-- Its file is written on the first change.
local function new_note(dir)
  local note = { id = M.uuid() }
  place(note, dir)
  note.buf = vim.fn.bufadd(note.path)
  vim.fn.bufload(note.buf)
  vim.b[note.buf].ferry_body = true
  display(note.buf)
  M.apply_options(note.buf)
  return note
end

-- Drop the blank note left by a finish if no show resumed it and it was
-- never edited.
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
  local prev = M.state.note
  if prev and not discard_unstarted(prev) then save(note_buf(prev)) end
  local note = new_note(notes_dir(opts))
  local id = note.id
  local meta = { id = id, target = opts.target or "", window = opts.window or "", seed = seed,
    created = note.created }
  local body = seed ~= "" and vim.split(seed, "\n", { plain = true }) or { "" }
  vim.api.nvim_buf_set_lines(note.buf, 0, -1, false, body)
  -- Untouched: no file until the first change (a seed counts as text, so
  -- the next draft or Hide writes it).
  vim.bo[note.buf].modified = false
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  M.state.note, M.state.cursor = note, nil
  vim.b[note.buf].ferry = meta
  vim.cmd("startinsert")
  return note
end

local function resume(opts)
  local note = M.state.note
  local buf = note_buf(note)
  -- A note with neither a file nor text yet (the blank note after a send)
  -- starts now: its file name takes this show's time.
  if not readable(note.path) and is_blank(select(2, parts(buf))) then place(note, notes_dir(opts)) end
  display(buf)
  M.apply_options(buf)
  -- A wiped buffer reloads without b:ferry: a fork's file id and
  -- conflict_of come from the note (fork keeps them there), so a conflict
  -- file deleted outside is recreated as the fork, not under note.id.
  local meta = vim.b[buf].ferry or { id = note.id, file_id = note.file_id, conflict_of = note.conflict_of,
    seed = "", created = note.created }
  meta.target, meta.window = opts.target or "", opts.window or ""
  vim.b[buf].ferry = meta
  note.unstarted = nil
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

-- Insert mode at the cursor, like `a` from normal mode (already in insert
-- mode: the cursor stays).
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

local function on(v) return v ~= nil and v ~= "" and v ~= "0" and v ~= false and v ~= 0 end

-- Show the note: resume the unfinished one unless seeded, else open a fresh
-- note. opts: { target, window, seed = seed file path, dir = notes folder,
-- sidebar = "0" to leave the history sidebar closed, talk = "1" when
-- Hammerspoon has started Flow (hold to talk) }.
-- A resumed note takes the new target and window. Returns the note's path.
function M.show(opts)
  opts = opts or {}
  if opts.dir and opts.dir ~= "" then M.state.dir = opts.dir end
  M.state.captured = { target = opts.target or "", window = opts.window or "" }
  local seed = read_seed(opts.seed)
  local note
  if seed == "" and M.state.note then
    note = resume(opts)
  else
    note = fresh(opts, seed)
  end
  layout(opts)
  if on(opts.talk) then flow.adopt_start() end
  return note.path
end

-- Hold to talk with the note already in front: no show, no new target, no
-- layout change. Enter insert mode at the cursor (like `a`) and tell flow that Hammerspoon started a recording. Returns
-- "talk <path>", or "no note".
function M.talk(opts)
  use_dir(opts)
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
  use_dir(opts)
  local note = M.state.note
  local buf = note and note_buf(note) or vim.api.nvim_get_current_buf()
  if flow.release(buf) then return "released" end
  if not (opts and on(opts.force)) then return "idle" end
  flow.assume_recording()
  flow.release(buf)
  return "forced"
end

-- Flow as nvim sees it: "recording" (a stop is still due), "waiting" (a
-- stop went out; a Submit, Cancel, Hide or release waits for the paste),
-- "stopped" (the talk key's adopted recording was ended by our stop and
-- its paste arrived, flow.stopped()) or "idle". Hammerspoon's talk key up
-- asks before giving up on a release.
function M.flow_state()
  if flow.recording() then return "recording" end
  if flow.state.waiting then return "waiting" end
  if flow.stopped and flow.stopped() then return "stopped" end
  return "idle"
end

-- Returned (with the path) by draft() while Flow is recording.
M.FLOW_WAIT = "waiting for flow"

-- Save the current note's file (when it has changed or has text but no
-- file yet), record it as the draft and leave insert mode. Returns its path ("" when there is no note).
-- While Flow is recording (started from the note) or a finish is already
-- waiting for its paste, the note must stay in front for Flow's paste: it
-- returns "waiting for flow <path>" at once, and the note hides itself
-- through M.host.hide once the paste has landed (or timed out), as :Hide
-- does. The caller must not hide the host itself then. A Submit or Cancel
-- during that wait takes it over (flow.finish_then) and also runs only
-- after the paste, so cancelled dictation never reaches the target.
-- A key-up release wait has nothing to run after the paste, so draft()
-- makes it a Hide; a Submit or Cancel wait is left as it is.
function M.draft(opts)
  use_dir(opts)
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
  save(buf)
  vim.g.ferry_draft = note.path
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

-- Open a note file (the history browser's <CR> and s) as the current note,
-- in the note window, normal mode, cursor on its last line. The note that
-- was current is saved as a draft first (an untouched blank one is
-- dropped) and its buffer let go once the opened one is shown. The opened
-- note takes the target captured at the latest show; its file keeps its
-- state until its text changes (then draft), and a Cancel before then
-- leaves the file as it is. Not while Flow is recording, a finish waits
-- for its paste, or the current note cannot be saved (it stays current and
-- shown). Returns the buffer, or nil after a notice.
function M.open(path)
  if flow.recording() or flow.state.waiting then
    say("ferry: Flow is still recording; open the note when it is done", vim.log.levels.WARN)
    return nil
  end
  path = vim.fn.fnamemodify(path, ":p")
  local meta = readable(path) and store.read(path)
  if not meta then
    say("ferry: cannot read " .. path, vim.log.levels.WARN)
    return nil
  end
  local prev = M.state.note
  local cap = M.state.captured
  if not cap and prev and prev.buf and vim.api.nvim_buf_is_valid(prev.buf) then
    local m = vim.b[prev.buf].ferry or {}
    cap = { target = m.target or "", window = m.window or "" }
  end
  cap = cap or { target = "", window = "" }
  if prev and same_file(prev.path, path) then
    local cur = note_buf(prev)
    display(cur)
    return cur
  end
  local old
  if prev then
    old = note_buf(prev)
    if not save(old) then
      say("ferry: could not save the current note, so it stays open", vim.log.levels.ERROR)
      if vim.fn.bufwinid(old) == -1 then display(old) end
      return nil
    end
  end
  local buf = vim.fn.bufadd(path)
  if buf == old then old = nil end
  if not (vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].modified) then
    vim.fn.bufload(buf)
    attach(buf)
    load(buf)
  end
  vim.b[buf].ferry_body = true
  local id = rawget(meta, "id") or M.uuid()
  local created = vim.fn.getftime(path)
  local note = { id = id, path = path, buf = buf, created = created > 0 and created or os.time() }
  display(buf)
  M.apply_options(buf)
  vim.b[buf].ferry = { id = id, target = cap.target, window = cap.window, seed = "", created = note.created,
    opened = body_sum(buf) }
  M.state.note, M.state.cursor, M.state.listed = note, nil, id
  vim.cmd("stopinsert")
  vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(buf), 0 })
  -- The old note's buffer goes once it is saved (a failed save keeps it).
  if old and prev.unstarted then discard_unstarted(prev) end
  if old and vim.api.nvim_buf_is_valid(old) and not vim.bo[old].modified and vim.fn.bufwinid(old) == -1 then
    pcall(vim.api.nvim_buf_delete, old, { force = true })
  end
  return buf
end

-- An empty note that takes the place of a finished one, so :q in its
-- window hides rather than quitting the server. It is the current note
-- (the next unseeded show resumes it).
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
  vim.b[note.buf].ferry = { id = note.id, target = "", window = "", seed = "", created = note.created }
  M.state.note, M.state.cursor = note, nil
  return note
end

-- End a note: write its file as sent (submitted) or cancelled, with spec
-- as its target, and drop its buffer. The file is kept, except a blank
-- Cancel's, which is deleted (unless it was changed outside ferry). A
-- Cancel of a note opened from the browser whose text is unchanged since
-- (and saved) leaves its file alone. If it was the current note, a blank
-- note replaces it in its windows. Returns true; false when a Cancel could
-- not write the file, which leaves the note as it was (buffer, current
-- note). _file (the outbox copy) is unused since the old history database
-- went.
local function finish(buf, outcome, _file, spec)
  local meta = vim.b[buf].ferry or {}
  local note = M.state.note
  local current = note and note.buf == buf
  -- A note held over from before note files gets its file name first.
  if current then adopt(note) end
  local path = vim.api.nvim_buf_get_name(buf)
  stop_timer(buf)
  local untouched = outcome == "cancelled" and meta.opened ~= nil and not vim.bo[buf].modified
    and meta.opened == body_sum(buf)
  if untouched then
    -- Nothing to write.
  elseif outcome == "cancelled" and is_blank(select(2, parts(buf))) then
    if readable(path) and ours(buf, path) then
      os.remove(path)
      index(path)
    end
  else
    local ok = write_note(buf, { state = outcome == "submitted" and "sent" or "cancelled",
      sent = outcome == "submitted", target = spec })
    if not ok and outcome == "cancelled" then return false end
  end
  if current then M.forget() end
  vim.g.ferry_draft = nil
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
  return true
end

-- Write the body to <outbox>/<id>.md and return its path. Not
-- vim.fn.tempname(): nvim deletes that folder on exit, and Hammerspoon
-- reads (then deletes) the submit file after the URL is opened.
local function to_tempfile(buf, body)
  local dir = outbox_dir()
  vim.fn.mkdir(dir, "p")
  local id = (vim.b[buf].ferry or {}).id or M.uuid()
  local file = dir .. "/" .. id .. ".md"
  vim.fn.writefile(body, file)
  return file
end

local function bufnr(buf)
  buf = (buf and buf ~= 0) and buf or vim.api.nvim_get_current_buf()
  if type(vim.b[buf].ferry) == "table" then drop_header(buf) end
  return buf
end

-- Run fn(buf) once Flow's last paste has landed (at once when Flow is idle).
-- The buffer may be gone by then (another finish ran first).
local function after_flow(buf, fn)
  flow.finish_then(buf, function()
    if vim.api.nvim_buf_is_valid(buf) then fn(buf) end
  end)
end

-- Cancel: mark the note's file cancelled (a blank note's file is deleted)
-- and hide. If the note file cannot be written, nothing is
-- dropped: the note stays shown and current, its copy stays in the outbox,
-- and an alert names it.
local function cancel_now(buf)
  local spec, body = parts(buf)
  local file = to_tempfile(buf, body)
  if not finish(buf, "cancelled", file, spec) then
    alert("ferry: Cancel could not save the note, so it stays open; a copy is in " .. file)
    return
  end
  os.remove(file)
  M.host.hide({})
end

-- The body as text, or nil when it is blank or unchanged from the seed
-- (a Submit or Copy of it is a cancel).
local function body_text(buf, body)
  local meta = vim.b[buf].ferry or {}
  local text = table.concat(body, "\n")
  local trim = function(s) return (s:gsub("\n+$", "")) end
  if not text:find("%S") or trim(text) == trim(meta.seed or "") then return nil end
  return text
end

-- Copy: the body on the clipboard (first, so a failure later still leaves
-- it there), recorded as submitted to `clipboard`, then hide. If the copy
-- does not take, the note stays current and shown, and its row open.
local function copy_body(buf, body, text)
  if not to_clipboard(text) then
    say(CLIP_FAIL, vim.log.levels.ERROR)
    return
  end
  local file = to_tempfile(buf, body)
  finish(buf, "submitted", file, "clipboard")
  os.remove(file)
  M.host.hide({})
end

-- Submit: a blank body, or one unchanged from the seed, is a cancel. The
-- body goes to the host with the target captured at the latest show; with
-- nothing captured it is a Copy.
local function submit_now(buf)
  local spec, body = parts(buf)
  local text = body_text(buf, body)
  if not text then return cancel_now(buf) end
  local meta = vim.b[buf].ferry or {}
  local bundle = meta.target or ""
  if bundle == "" then return copy_body(buf, body, text) end
  local file = to_tempfile(buf, body)
  finish(buf, "submitted", file, spec)
  M.host.submit({ file = file, target = bundle, window = tostring(meta.window or ""):match("^%d+$") or "" })
end

-- Copy and hide (:Copy, <C-y>).
local function copy_now(buf)
  local _, body = parts(buf)
  local text = body_text(buf, body)
  if not text then return cancel_now(buf) end
  copy_body(buf, body, text)
end

-- Hide: keep the note as the draft (its file stays a draft) and hide.
local function hide_now(buf)
  local note = M.state.note
  if note and note.buf == buf then
    M.draft()
  else
    save(buf)
  end
  vim.cmd("stopinsert")
  M.host.hide({})
end

function M.cancel(buf) buf = bufnr(buf); after_flow(buf, cancel_now) end
function M.submit(buf) buf = bufnr(buf); after_flow(buf, submit_now) end
function M.hide(buf) buf = bufnr(buf); after_flow(buf, hide_now) end
function M.copy(buf) buf = bufnr(buf); after_flow(buf, copy_now) end

-- The note of the current tab: the buffer with b:ferry in the sidebar's
-- main window, else in any window of the tab, else the current note.
-- Returns buf and its window in the tab (nil when not shown), or nil.
function M.tab_note()
  local tab = vim.api.nvim_get_current_tabpage()
  local wins = vim.api.nvim_tabpage_list_wins(tab)
  local hist = package.loaded["ferry.history"]
  local main = hist and hist.state and hist.state.main_win
  if main and vim.api.nvim_win_is_valid(main) and vim.api.nvim_win_get_tabpage(main) == tab then
    table.insert(wins, 1, main)
  end
  for _, w in ipairs(wins) do
    local b = vim.api.nvim_win_get_buf(w)
    if type(vim.b[b].ferry) == "table" then return b, w end
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
    say("ferry: no note to " .. action, vim.log.levels.WARN)
    return
  end
  drop_header(buf)
  if win then vim.api.nvim_set_current_win(win) else display(buf) end
  if action == "flow" then
    -- Joe stays in insert mode (GT requirement 7), at the end of the body.
    vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(buf), 0 })
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
local on_paste = "<Cmd>lua require'ferry.flow'.on_paste(0)<CR>"
vim.keymap.set({ "i", "c" }, "<D-v>", "<C-r><C-o>+" .. on_paste, { desc = "ferry: paste clipboard" })
vim.keymap.set("n", "<D-v>", '"+p' .. on_paste, { desc = "ferry: paste clipboard" })

return M
