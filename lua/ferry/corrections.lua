-- :Corrections: the words Joe keeps fixing after Wispr Flow, as a list he
-- can add to Flow's own Dictionary. ferry never writes Flow's data (GT
-- decision 5): this view only helps him do it in Flow.
--
-- open() runs bin/ferry-corrections --json in the background (vim.system,
-- never waited on, so typing never blocks) with FERRY_NOTES_DIR set to the
-- server's notes folder, and shows the result in a scratch split below the
-- current window (buftype nofile, wiped when closed). It reads "Looking for
-- corrections…" until the job ends; :Corrections again (in the note or the
-- split) reruns it in the same split. Each suggestion is one line, `2× cube control → kubectl`.
-- Keys there:
--   y   copy the line's right-hand word (kubectl) through the note's
--       clipboard helper (note.to_clipboard, read back to confirm)
--   o   open Wispr Flow (`open -a 'Wispr Flow'`) to add it in its Dictionary
--   q   close the split
-- No suggestions, a missing Flow database or a failed run is one line in
-- the split, never an error. The command is `ferry-corrections` on PATH
-- (tests put a fake there), else the repo's bin/ferry-corrections.
local M = {}

-- Bumped when a running server must reload this module. 1: first version.
M.api = 1

-- buf, win: the split; run: bumped per run, so a late result of an older
-- run is dropped; words[lnum]: the right-hand word of each line.
M.state = { buf = nil, win = nil, run = 0, words = {} }

M.TITLE = "ferry://corrections"
M.WAITING = "Looking for corrections…"
-- A job that runs longer is stopped (vim.system timeout, exit 124).
M.timeout_ms = 60000

local function say(msg, level) require("ferry.notice").notify(msg, level) end

local function repo_root()
  local src = debug.getinfo(1, "S").source:sub(2)
  return vim.fn.fnamemodify(src, ":p:h:h:h")
end

function M.command()
  local onpath = vim.fn.exepath("ferry-corrections")
  if onpath ~= "" then return onpath end
  return repo_root() .. "/bin/ferry-corrections"
end

-- The split's lines and words (lnum -> right-hand word) for a finished
-- run: exit code, stdout (a JSON array of {count, wrong, right}), stderr.
function M.render(code, out, err)
  if code ~= 0 then
    local msg = ((err or ""):match("[^\n]*%S[^\n]*") or ""):gsub("^%s*ferry%-corrections:%s*", "")
    local db = msg:match("^no Wispr Flow database: (.*)$")
    if db then return { "No Wispr Flow database (" .. db .. "), so nothing to suggest." }, {} end
    if code == 124 then return { "ferry-corrections took too long and was stopped." }, {} end
    if msg == "" then msg = "exit " .. tostring(code) end
    return { "ferry-corrections failed: " .. msg }, {}
  end
  local ok, list = pcall(vim.json.decode, out or "")
  if not ok or type(list) ~= "table" then
    return { "ferry-corrections gave output ferry cannot read." }, {}
  end
  local lines, words = {}, {}
  for _, c in ipairs(list) do
    if type(c) == "table" and type(c.wrong) == "string" and type(c.right) == "string" then
      lines[#lines + 1] = string.format("%s× %s → %s", tostring(c.count or "?"), c.wrong, c.right)
      words[#lines] = c.right
    end
  end
  if #lines == 0 then return { "No corrections seen in 2 or more notes yet." }, {} end
  return lines, words
end

local function valid_buf() return M.state.buf and vim.api.nvim_buf_is_valid(M.state.buf) end
local function valid_win()
  return M.state.win and vim.api.nvim_win_is_valid(M.state.win)
    and vim.api.nvim_win_get_buf(M.state.win) == M.state.buf
end

local function fill(lines, words)
  local buf = M.state.buf
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  M.state.words = words
  if valid_win() then
    pcall(vim.api.nvim_win_set_height, M.state.win, math.max(3, math.min(#lines, 12)))
  end
end

-- The word on the cursor line of the split, or nil.
function M.word_at_cursor()
  if not valid_buf() or vim.api.nvim_get_current_buf() ~= M.state.buf then return nil end
  return M.state.words[vim.api.nvim_win_get_cursor(0)[1]]
end

function M.copy()
  local word = M.word_at_cursor()
  if not word then
    say("ferry: no suggestion on this line", vim.log.levels.WARN)
    return false
  end
  local note = package.loaded["ferry.note"] or require("ferry.note")
  local ok = note.to_clipboard and note.to_clipboard(word)
  if not ok then
    say("ferry: could not copy to the clipboard", vim.log.levels.ERROR)
    return false
  end
  say("ferry: copied " .. word .. " — o opens Wispr Flow to add it to its Dictionary", vim.log.levels.INFO)
  return true
end

function M.open_flow()
  local function failed()
    say("ferry: could not open Wispr Flow", vim.log.levels.WARN)
  end
  local ok = pcall(vim.system, { "open", "-a", "Wispr Flow" }, {}, function(r)
    if r.code ~= 0 then vim.schedule(failed) end
  end)
  if not ok then failed() end
end

function M.close()
  if valid_win() and #vim.api.nvim_tabpage_list_wins(vim.api.nvim_win_get_tabpage(M.state.win)) > 1 then
    pcall(vim.api.nvim_win_close, M.state.win, true)
  end
  if valid_buf() then pcall(vim.api.nvim_buf_delete, M.state.buf, { force = true }) end
  M.state.buf, M.state.win, M.state.words = nil, nil, {}
end

local function make_buf()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "ferry-corrections"
  pcall(vim.api.nvim_buf_set_name, buf, M.TITLE)
  -- Through package.loaded: a reloaded module takes the keys over.
  local function key(lhs, fn)
    vim.keymap.set("n", lhs, function() require("ferry.corrections")[fn]() end,
      { buffer = buf, silent = true, nowait = true, desc = "ferry corrections: " .. fn })
  end
  key("y", "copy")
  key("o", "open_flow")
  key("q", "close")
  vim.api.nvim_buf_create_user_command(buf, "Corrections", function() require("ferry.corrections").open() end,
    { force = true, desc = "ferry: run the corrections list again" })
  vim.api.nvim_create_autocmd("BufWipeout", { buffer = buf, callback = function()
    if M.state.buf == buf then M.state.buf, M.state.win, M.state.words = nil, nil, {} end
  end })
  return buf
end

-- Show the split (reused when open) and start a run. opts.dir: the notes
-- folder (default note.dir()). Returns the split's buffer.
function M.open(opts)
  opts = opts or {}
  if not valid_buf() then M.state.buf = make_buf() end
  if valid_win() then
    vim.api.nvim_set_current_win(M.state.win)
  else
    M.state.win = vim.api.nvim_open_win(M.state.buf, true, { split = "below", win = 0, height = 3 })
    vim.wo[M.state.win].winbar = "Corrections   y copy word · o open Wispr Flow · q close"
    vim.wo[M.state.win].wrap = false
    vim.wo[M.state.win].spell = false
  end
  fill({ M.WAITING }, {})
  M.state.run = M.state.run + 1
  local run = M.state.run
  local dir = opts.dir
  if not dir or dir == "" then
    local note = package.loaded["ferry.note"]
    dir = note and note.dir and note.dir() or nil
  end
  local function done(code, out, err)
    vim.schedule(function()
      if M.state.run ~= run or not valid_buf() then return end
      fill(M.render(code, out, err))
    end)
  end
  local ok, e = pcall(vim.system, { M.command(), "--json" },
    { text = true, env = dir and { FERRY_NOTES_DIR = dir } or nil, timeout = M.timeout_ms },
    function(r) done(r.code, r.stdout, r.stderr) end)
  if not ok then done(127, "", "cannot run " .. M.command() .. ": " .. tostring(e)) end
  return M.state.buf
end

return M
