-- ferry's notices: one screen line, so a narrow window never stops at a
-- "Press ENTER" prompt (Joe's typing would go to the prompt, not the note).
--
-- notify(msg, level) with nvim's own vim.notify: a message that fits the
-- command line (v:echospace) is echoed as vim.notify would. A longer one
-- (or one with line breaks) goes to :messages in full and shows cut to
-- one line, ending in "…". The full text is echoed with 'messagesopt' set
-- to wait:0 and then :redraw (which drops the pending hit-enter prompt),
-- the option restored, then the cut line echoed without history.
-- The echo runs scheduled: a notice raised inside `silent write` (an
-- autosave that forks to a conflict file) would otherwise be swallowed,
-- and a redraw in the middle of a write or an RPC call is avoided.
-- A vim.notify replaced by a plugin (nvim-notify, noice, tests) gets the
-- full text: it does its own layout.
local M = {}

M.api = 1

local function builtin_notify()
  local ok, info = pcall(debug.getinfo, vim.notify, "S")
  return ok and info and type(info.source) == "string" and info.source:find("vim/_editor.lua", 1, true) ~= nil
end

-- msg cut to width display cells, "…" included, on one line.
function M.cut(msg, width)
  local line = msg:gsub("%s*\n%s*", " ")
  if vim.fn.strdisplaywidth(line) <= width then return line end
  local out, used = {}, 0
  for _, ch in ipairs(vim.fn.split(line, "\\zs")) do
    local w = vim.fn.strdisplaywidth(ch)
    if used + w > width - 1 then break end
    out[#out + 1] = ch
    used = used + w
  end
  return table.concat(out) .. "…"
end

local function echo(msg, level)
  local err = level == vim.log.levels.ERROR
  local hl = err and "ErrorMsg" or (level == vim.log.levels.WARN and "WarningMsg" or nil)
  local width = math.max(vim.v.echospace, 10)
  local short = M.cut(msg, width)
  if short == msg or vim.fn.exists("+messagesopt") == 0 then
    vim.api.nvim_echo({ { msg, hl } }, true, { err = err })
    return
  end
  local mopt = vim.o.messagesopt
  local hist = mopt:match("history:%d+") or "history:500"
  local ok = pcall(function()
    vim.o.messagesopt = "wait:0," .. hist
    vim.api.nvim_echo({ { msg, hl } }, true, { err = err })
    vim.cmd("redraw")
  end)
  vim.o.messagesopt = mopt
  if not ok then return end
  vim.api.nvim_echo({ { short, hl } }, false, {})
end

function M.notify(msg, level)
  msg = tostring(msg)
  if not builtin_notify() then return vim.notify(msg, level) end
  vim.schedule(function() echo(msg, level) end)
end

return M
