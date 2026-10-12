-- voice-vim GUI appearance: make Neovide look like Joe's Ghostty terminal.
--
-- In a terminal, a transparent colorscheme (Normal with no guibg) shows the
-- terminal's background; in Neovide nothing shows through, and Neovide uses
-- its own default font. bin/voice-vim-host reads Ghostty's font and
-- background (or VOICE_VIM_GUI_FONT / VOICE_VIM_GUI_BG) and calls
-- setup({ font = "Family:h13", bg = "#001e27" }), which stores them in
-- g:voicevim_gui.
--
-- Only while a GUI is attached (g:neovide, or a UI whose client is neovide):
-- on UIEnter it sets 'guifont' and, if Normal has no guibg, the background;
-- after any ColorScheme it re-applies the background. With no GUI nothing
-- changes, so terminal UIs keep their transparent look.
local M = {}

M.settings = { font = "", bg = "" }

function M.attached()
  if vim.g.neovide then return true end
  for _, ui in ipairs(vim.api.nvim_list_uis()) do
    local ok, info = pcall(vim.api.nvim_get_chan_info, ui.chan or -1)
    if ok and type(info) == "table" and info.client and info.client.name == "neovide" then
      return true
    end
  end
  return false
end

-- Set Normal's guibg when it has none (an existing one is left alone).
function M.apply_bg()
  local bg = M.settings.bg
  if bg == "" or not M.attached() then return false end
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = "Normal", link = false })
  if not ok or hl.bg ~= nil then return false end
  return (pcall(vim.cmd, "highlight Normal guibg=" .. bg))
end

function M.apply_font()
  local font = M.settings.font
  if font == "" or not M.attached() then return false end
  if vim.o.guifont ~= font then pcall(function() vim.o.guifont = font end) end
  return true
end

function M.apply()
  M.apply_font()
  M.apply_bg()
end

-- Only plain values reach :highlight: a #rrggbb colour or a colour name.
local function clean_bg(s)
  s = vim.trim(tostring(s or ""))
  if s:match("^#?%x%x%x%x%x%x$") then return (s:gsub("^#?", "#")) end
  if s:match("^%a+$") then return s end
  return ""
end

-- settings: { font, bg } (strings, "" = leave alone). Stores them, (re)makes
-- the autocmds and applies at once if a GUI is already attached.
function M.setup(settings)
  settings = type(settings) == "table" and settings or {}
  M.settings = { font = vim.trim(tostring(settings.font or "")), bg = clean_bg(settings.bg) }
  vim.g.voicevim_gui = M.settings
  local group = vim.api.nvim_create_augroup("voice-vim-gui", { clear = true })
  vim.api.nvim_create_autocmd("UIEnter", { group = group, callback = function()
    M.apply()
    -- Neovide may set g:neovide just after attaching.
    vim.schedule(M.apply)
  end })
  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = function() M.apply_bg() end })
  M.apply()
  return 1
end

return M
