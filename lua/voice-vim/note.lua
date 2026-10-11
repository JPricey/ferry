-- voice-vim note core: runs inside the one long-lived nvim server.
--
-- bin/voice-vim-host calls the public functions over --remote-expr as
-- luaeval('require"voice-vim.note".<fn>(_A)', {dict}). Each takes one table
-- and returns a string, which voice-vim-host prints.
--
-- One note is "current" until it is finished. show() resumes it, unless a
-- seed (captured selection) asks for a fresh note. Note files are scratch
-- in $VOICE_VIM_NOTES_DIR; the history database stays the record.
local M = {}

-- The current (unfinished) note: { id = uuid, path = file, buf = bufnr }.
M.state = { note = nil, cursor = nil }

local function notes_dir(opts)
  if opts and opts.dir and opts.dir ~= "" then return opts.dir end
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
  -- Start a Flow hands-free dictation from inside the note.
  vim.api.nvim_buf_create_user_command(buf, "Dictate", function()
    vim.system({ "open", "-g", "wispr-flow://start-hands-free" })
  end, { force = true })
  vim.keymap.set("n", "<leader>d", "<Cmd>Dictate<CR>", { buffer = buf, silent = true })
  vim.api.nvim_buf_create_user_command(buf, "History", function()
    require("voice-vim.history").toggle()
  end, { force = true })
  vim.keymap.set("n", "<leader>h", "<Cmd>History<CR>", { buffer = buf, silent = true })
end

-- Show buf in the current window (or jump to a window already showing it).
local function display(buf)
  local win = vim.fn.bufwinid(buf)
  if win ~= -1 then
    vim.api.nvim_set_current_win(win)
  else
    vim.api.nvim_win_set_buf(0, buf)
  end
end

-- Write the note if it has unsaved changes, so switching away loses nothing.
local function save(note)
  if note and note.buf and vim.api.nvim_buf_is_valid(note.buf) and vim.bo[note.buf].modified then
    vim.api.nvim_buf_call(note.buf, function() vim.cmd("silent write!") end)
  end
end

local function fresh(opts, seed)
  save(M.state.note)
  local dir = notes_dir(opts)
  vim.fn.mkdir(dir, "p")
  local id = M.uuid()
  local note = { id = id, path = dir .. "/" .. id .. ".md" }
  note.buf = vim.fn.bufadd(note.path)
  vim.fn.bufload(note.buf)
  display(note.buf)
  M.apply_options(note.buf)
  if seed ~= "" then
    vim.api.nvim_buf_set_lines(note.buf, 0, -1, false, vim.split(seed, "\n", { plain = true }))
  end
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  M.state.note, M.state.cursor = note, nil
  vim.b[note.buf].voicevim = { id = id, target = opts.target or "", window = opts.window or "", seed = seed }
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
-- note. opts: { target, window, seed = seed file path, dir = notes folder }.
-- A resumed note takes the new target and window. Returns the note's path.
function M.show(opts)
  opts = opts or {}
  local seed = read_seed(opts.seed)
  local note
  if seed == "" and M.state.note then
    note = resume(opts)
  else
    note = fresh(opts, seed)
  end
  return note.path
end

-- Write the current note to disk, record it as the draft and leave insert
-- mode. Returns its path ("" when there is no note).
function M.draft()
  local note = M.state.note
  if not note then return "" end
  local buf = note_buf(note)
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

-- Neovide sends Cmd+V as <D-v>; terminals never do. Paste the + register,
-- which is where Wispr Flow puts the dictation.
vim.keymap.set({ "i", "c" }, "<D-v>", "<C-r><C-o>+", { desc = "voice-vim: paste clipboard" })
vim.keymap.set("n", "<D-v>", '"+p', { desc = "voice-vim: paste clipboard" })

return M
