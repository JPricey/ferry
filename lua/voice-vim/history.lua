-- voice-vim history sidebar.
--
-- A left split listing past sessions from the history database. Keys:
--   <CR>  insert the session's text into the dictation buffer
--   p     replace the dictation buffer with it and submit
--   y     yank it to the system clipboard
--   K     preview the full text in a float
--   d     delete it from history
--   R     refresh        <Tab> back to the dictation buffer     q  close
local M = {}

M.width = 38
M.state = { win = nil, buf = nil, main_win = nil, rows = {}, preview_win = nil }

local function root()
  local src = debug.getinfo(1, "S").source:sub(2)
  return vim.fn.fnamemodify(src, ":p:h:h:h")
end

local function db_cmd(args)
  local cmd = { root() .. "/bin/voice-vim-db" }
  vim.list_extend(cmd, args)
  local out = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 then
    vim.notify("voice-vim: history command failed: " .. table.concat(args, " "), vim.log.levels.WARN)
    return nil
  end
  return out
end

-- The entry to leave out of the list: the note being written (b:voicevim.id
-- in the dictation window), else the V0 session ($VOICE_VIM_SESSION_ID).
local function exclude_id()
  local st = M.state
  local win = st.main_win
  if not (win and vim.api.nvim_win_is_valid(win)) then win = vim.api.nvim_get_current_win() end
  local meta = vim.b[vim.api.nvim_win_get_buf(win)].voicevim
  if type(meta) == "table" and meta.id and meta.id ~= "" then return meta.id end
  local sid = os.getenv("VOICE_VIM_SESSION_ID")
  if sid and sid ~= "" then return sid end
  return nil
end

function M.load()
  local args = { "list", "--limit", "200" }
  local sid = exclude_id()
  if sid then vim.list_extend(args, { "--exclude", sid }) end
  local out = db_cmd(args)
  if not out or out == "" then return {} end
  local ok, rows = pcall(vim.json.decode, out)
  return ok and rows or {}
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

-- Build display lines and a line -> session index map.
function M.render(rows, width)
  local lines, map, hl = {}, {}, {}
  local last_label
  if #rows == 0 then
    lines[1] = "  no history yet"
    hl[#hl + 1] = { 0, "Comment", 0, -1 }
    return lines, map, hl
  end
  for i, r in ipairs(rows) do
    if r.date_label ~= last_label then
      if #lines > 0 then lines[#lines + 1] = "" end
      lines[#lines + 1] = "── " .. r.date_label
      hl[#hl + 1] = { #lines - 1, "Title", 0, -1 }
      last_label = r.date_label
    end
    local mark = r.outcome == "cancelled" and "~" or " "
    local head = string.format("%s%s %-7s ", mark, r.time, truncate(r.app, 7))
    local preview = r.preview ~= "" and r.preview or "(empty)"
    lines[#lines + 1] = head .. truncate(preview, width - vim.fn.strdisplaywidth(head) - 1)
    local ln = #lines - 1
    hl[#hl + 1] = { ln, "Number", 1, 6 }
    hl[#hl + 1] = { ln, "Identifier", 7, 7 + #truncate(r.app, 7) }
    if r.outcome == "cancelled" then hl[#hl + 1] = { ln, "Comment", 0, 1 } end
    map[#lines] = i
  end
  return lines, map, hl
end

local function current_row()
  local st = M.state
  if not (st.win and vim.api.nvim_win_is_valid(st.win)) then return nil end
  local ln = vim.api.nvim_win_get_cursor(st.win)[1]
  local idx = st.map[ln]
  return idx and st.rows[idx] or nil
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

local function text_lines(r)
  local t = r.text:gsub("\n$", "")
  return vim.split(t, "\n", { plain = true })
end

function M.insert()
  local r = current_row(); if not r then return end
  local win = main_win(); if not win then return end
  local buf = vim.api.nvim_win_get_buf(win)
  local lines = text_lines(r)
  local existing = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  vim.api.nvim_set_current_win(win)
  if #existing == 1 and existing[1] == "" then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_win_set_cursor(win, { #lines, #lines[#lines] })
  else
    vim.api.nvim_put(lines, "l", true, true)
  end
end

function M.paste_to_target()
  local r = current_row(); if not r then return end
  local win = main_win(); if not win then return end
  local buf = vim.api.nvim_win_get_buf(win)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, text_lines(r))
  vim.api.nvim_set_current_win(win)
  vim.cmd("Submit")
end

function M.yank()
  local r = current_row(); if not r then return end
  vim.fn.setreg("+", r.text)
  vim.fn.setreg('"', r.text)
  vim.notify(string.format("voice-vim: yanked %d words", r.words))
end

function M.delete()
  local r = current_row(); if not r then return end
  db_cmd({ "delete", r.id })
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
  local lines = text_lines(r)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  local width = math.min(80, vim.o.columns - M.width - 6)
  local height = math.min(#lines + 1, vim.o.lines - 6)
  st.preview_win = vim.api.nvim_open_win(buf, false, {
    relative = "win", win = st.win, anchor = "NW", row = 0, col = M.width + 1,
    width = width, height = math.max(height, 1), style = "minimal", border = "rounded",
    title = string.format(" %s · %s · %s · %d words ", r.date_label, r.time, r.app, r.words),
  })
  vim.wo[st.preview_win].wrap = true
  vim.wo[st.preview_win].linebreak = true
end

function M.focus_main()
  local win = main_win()
  if win then vim.api.nvim_set_current_win(win) end
end

function M.refresh()
  local st = M.state
  if not (st.buf and vim.api.nvim_buf_is_valid(st.buf)) then return end
  st.rows = M.load()
  local lines, map, hl = M.render(st.rows, M.width)
  st.map = map
  vim.bo[st.buf].modifiable = true
  vim.api.nvim_buf_set_lines(st.buf, 0, -1, false, lines)
  vim.bo[st.buf].modifiable = false
  local ns = vim.api.nvim_create_namespace("voice-vim-history")
  vim.api.nvim_buf_clear_namespace(st.buf, ns, 0, -1)
  for _, h in ipairs(hl) do
    vim.api.nvim_buf_add_highlight(st.buf, ns, h[2], h[1], h[3], h[4])
  end
  -- Park the cursor on the first entry.
  if st.win and vim.api.nvim_win_is_valid(st.win) then
    for ln = 1, #lines do
      if map[ln] then vim.api.nvim_win_set_cursor(st.win, { ln, 0 }); break end
    end
  end
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

-- Open the sidebar to the left of the current (dictation) window and return
-- focus to that window.
function M.open()
  local st = M.state
  if M.is_open() then M.refresh(); return end
  st.main_win = vim.api.nvim_get_current_win()

  vim.cmd("topleft vertical " .. M.width .. " new")
  st.win = vim.api.nvim_get_current_win()
  st.buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_name(st.buf, "voice-vim://history")
  local bo = vim.bo[st.buf]
  bo.buftype, bo.bufhidden, bo.swapfile, bo.buflisted = "nofile", "wipe", false, false
  bo.filetype = "voicevim-history"
  local wo = vim.wo[st.win]
  wo.number, wo.relativenumber, wo.signcolumn, wo.foldcolumn = false, false, "no", "0"
  wo.wrap, wo.cursorline, wo.winfixwidth, wo.spell, wo.list = false, true, true, false, false
  wo.statusline = " history "

  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = st.buf, silent = true, nowait = true, desc = desc })
  end
  map("<CR>", M.insert, "insert into buffer")
  map("p", M.paste_to_target, "paste to target and submit")
  map("y", M.yank, "yank to clipboard")
  map("K", M.preview, "preview")
  map("d", M.delete, "delete from history")
  map("R", M.refresh, "refresh")
  map("<Tab>", M.focus_main, "back to buffer")
  map("q", M.close, "close sidebar")
  map("<Esc>", M.close_preview, "close preview")

  vim.api.nvim_create_autocmd("CursorMoved", { buffer = st.buf, callback = M.close_preview })
  vim.api.nvim_create_autocmd("BufWipeout", { buffer = st.buf, callback = function()
    M.close_preview(); st.win, st.buf = nil, nil
  end })

  M.refresh()
  vim.api.nvim_set_current_win(st.main_win)
end

return M
