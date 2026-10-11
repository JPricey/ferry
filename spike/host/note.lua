-- Server side of the host spike. Loaded into the long-lived nvim by
-- spike/host/vv-host (dofile over --remote-expr) and kept in
-- _G.VoiceVimSpike. Each function takes one argument and returns a string,
-- so vv-host can call it with luaeval(…, _A) and print the result.
local M = {}

-- The current note buffer, so `draft` writes the note even if focus moved
-- to another buffer.
M.buf = nil

-- A path in dir that is neither on disk nor loaded as a buffer.
local function fresh_path(dir)
  local base = dir .. "/" .. os.date("%Y%m%d-%H%M%S")
  local path, n = base .. ".md", 1
  while vim.uv.fs_stat(path) or vim.fn.bufexists(path) == 1 do
    path = string.format("%s-%d.md", base, n)
    n = n + 1
  end
  return path
end

-- Open a fresh, empty note in insert mode. Notes live in dir (vv-host passes
-- $VOICE_VIM_SPIKE_NOTES), never in the history database.
function M.new(dir)
  vim.fn.mkdir(dir, "p")
  local path = fresh_path(dir)
  vim.cmd("silent edit " .. vim.fn.fnameescape(path))
  M.buf = vim.api.nvim_get_current_buf()
  vim.bo[M.buf].filetype = "markdown"
  vim.b[M.buf].voicevim_note = true
  vim.cmd("startinsert")
  return vim.api.nvim_buf_get_name(M.buf)
end

-- Write the current note to disk and record it as the draft.
function M.draft()
  local buf = M.buf
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then return "" end
  vim.api.nvim_buf_call(buf, function() vim.cmd("silent write!") end)
  local path = vim.api.nvim_buf_get_name(buf)
  vim.g.voicevim_draft = path
  vim.cmd("stopinsert")
  return path
end

-- Quit the server once this request has returned.
function M.stop()
  vim.schedule(function() vim.cmd("silent! wall | qall!") end)
  return "stopping"
end

-- Neovide sends Cmd+V as <D-v>; terminals never do. Paste the + register,
-- which is where Wispr Flow puts the dictation.
vim.keymap.set({ "i", "c" }, "<D-v>", "<C-r><C-o>+", { desc = "voice-vim: paste clipboard" })
vim.keymap.set("n", "<D-v>", '"+p', { desc = "voice-vim: paste clipboard" })

_G.VoiceVimSpike = M
return M
