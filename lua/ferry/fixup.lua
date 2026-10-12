-- Post-dictation fix-ups: small commands for the mistakes Flow makes.
--
-- The line functions are pure Lua (no `vim` at load time), so they load
-- under LuaJIT and `nvim -l`. Each takes a list of lines and returns a new
-- list; the input is never changed.
--
--   join_breaks(lines)            join a line with no end punctuation
--                                 (. ! ? : ; … maybe then a closing quote or
--                                 bracket) to a next line that starts with a
--                                 lowercase letter, with one space
--   sentence_case(lines, prev)    capitalize sentence starts and a lone "i";
--                                 prev is the line before the range (the
--                                 first line starts a sentence when prev is
--                                 nil, blank or ends a sentence)
--   strip_fillers(lines, list)    remove filler words, with a comma pair
--                                 around them ("we, you know, ship" -> "we
--                                 ship"); a one-word filler goes anywhere
--                                 outside a word ("uh-huh" stays), a phrase
--                                 only when set off by punctuation or a line
--                                 edge ("do you know" stays); punctuation
--                                 left with nothing to end goes too ("Uh."
--                                 -> "", "we ship, um." -> "we ship.")
--   cycle_word(word, groups)      next word of its homophone group, keeping
--                                 Capitalized / UPPER case and curly ’;
--                                 nil if none
--
-- All three line functions leave ``` / ~~~ fences and fenced lines alone.
-- Text is UTF-8: curly quotes and dashes are not letters, other non-ASCII
-- characters are. Sentence case uppercases ASCII and Latin-1 (é -> É)
-- everywhere, and other letters only under nvim (vim.fn.toupper).
--
-- The list: $FERRY_FIXUPS, default ~/.config/ferry/fixups.txt. `#` starts
-- a comment. A `filler: a, b c` line adds fillers (comma separated, so a
-- filler may be a phrase); any other line is a homophone group, words
-- separated by spaces, commas or slashes. A file with group lines replaces
-- the built-in groups; one with filler lines replaces the built-in
-- fillers. A missing or unreadable file means the built-ins, no error.
--
-- setup(buf) (needs nvim): buffer-local :FixJoin, :FixCase, :FixFillers.
-- With no range they act on '[,'] (the last change, normally Flow's
-- paste), else on the paragraph at the cursor. Maps <leader>fj, fc, ff in
-- normal (default range) and visual (the selection) mode, and <leader>fw
-- cycles the word at the cursor (or the one-line selection) through its
-- group. The list is read on each use, so edits apply at once.
local M = {}

-- Bumped when a running server must reload this module. 1: first version.
M.api = 1

M.DEFAULT_GROUPS = {
  { "their", "there", "they're" },
  { "your", "you're" },
  { "its", "it's" },
  { "to", "too" },
  { "then", "than" },
  { "whose", "who's" },
}
M.DEFAULT_FILLERS = { "um", "uh", "umm", "uhh", "erm", "you know" }

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

local function copy(lines)
  local out = {}
  for i, l in ipairs(lines) do out[i] = l end
  return out
end

-- UTF-8 characters. Lines are byte strings; these read whole characters.

-- The character starting at byte i ("" outside the line).
local function char_at(s, i)
  if i < 1 or i > #s then return "" end
  local c = s:byte(i)
  local n = c >= 0xF0 and 4 or c >= 0xE0 and 3 or c >= 0xC0 and 2 or 1
  return s:sub(i, i + n - 1)
end

-- The character ending at byte i ("" before the line).
local function char_before(s, i)
  if i < 1 or i > #s then return "" end
  local st = i
  while st > 1 and st > i - 3 do
    local c = s:byte(st)
    if c < 0x80 or c >= 0xC0 then break end
    st = st - 1
  end
  return s:sub(st, i)
end

local LSQUO, RSQUO = "\226\128\152", "\226\128\153" -- ‘ ’
local LDQUO, RDQUO = "\226\128\156", "\226\128\157" -- “ ”
local ELLIPSIS = "\226\128\166"                      -- …
local APOS = { ["'"] = true, [RSQUO] = true }
-- Non-ASCII characters that are not letters: quotes, dashes, spaces.
local NONWORD = {
  [LSQUO] = true, [LDQUO] = true, [RDQUO] = true, [ELLIPSIS] = true,
  ["\226\128\154"] = true, ["\226\128\158"] = true,                     -- ‚ „
  ["\194\171"] = true, ["\194\187"] = true,                             -- « »
  ["\226\128\185"] = true, ["\226\128\186"] = true,                     -- ‹ ›
  ["\194\160"] = true, ["\226\128\162"] = true,                         -- nbsp •
}
local DASH = {
  ["\226\128\144"] = true, ["\226\128\145"] = true, ["\226\128\146"] = true, -- ‐ ‑ ‒
  ["\226\128\147"] = true, ["\226\128\148"] = true, ["\226\128\149"] = true, -- – — ―
}
local OPENERS = { ['"'] = true, ["'"] = true, ["("] = true, ["["] = true,
  [LSQUO] = true, [LDQUO] = true, ["\194\171"] = true }
local CLOSERS = { ['"'] = true, ["'"] = true, [")"] = true, ["]"] = true,
  [RSQUO] = true, [RDQUO] = true, ["\194\187"] = true }

-- A letter or digit: ASCII %w, or any non-ASCII character that is not a
-- known quote, dash or space (so ʻ in hawaiʻi and é count).
local function letter(ch)
  if ch == "" then return false end
  if #ch == 1 then return ch:match("%w") ~= nil end
  return not (NONWORD[ch] or DASH[ch] or APOS[ch])
end

-- Uppercase one character: ASCII, Latin-1 (é -> É) anywhere; others via
-- vim.fn.toupper when running in nvim, else unchanged.
local function upper_char(ch)
  if #ch == 1 then return ch:upper() end
  local b1, b2 = ch:byte(1, 2)
  if #ch == 2 and b1 == 0xC3 then
    if b2 >= 0xA0 and b2 <= 0xBE and b2 ~= 0xB7 then return string.char(0xC3, b2 - 0x20) end
    return ch
  end
  local v = rawget(_G, "vim")
  if type(v) == "table" and v.fn then
    local ok, u = pcall(v.fn.toupper, ch)
    if ok and type(u) == "string" and u ~= "" then return u end
  end
  return ch
end

-- Starts with a lowercase letter (ASCII or Latin-1 à-ÿ, ß).
local function lower_start(line)
  if line:match("^%l") then return true end
  local b1, b2 = line:byte(1, 2)
  return b1 == 0xC3 and b2 ~= nil and b2 >= 0x9F and b2 <= 0xBF and b2 ~= 0xB7
end

-- line without trailing spaces and closing quotes/brackets.
local function strip_closers(line)
  while true do
    line = line:gsub("%s+$", "")
    local ch = char_before(line, #line)
    if not CLOSERS[ch] then return line end
    line = line:sub(1, #line - #ch)
  end
end

-- Ends a sentence or clause: . ! ? : ; (or …) then maybe closing quotes.
local function ends_clause(line)
  local s = strip_closers(line)
  return s:match("[%.!%?:;]$") ~= nil or s:sub(-#ELLIPSIS) == ELLIPSIS
end

local function ends_sentence(line)
  local s = strip_closers(line)
  return s:match("[%.!%?]$") ~= nil or s:sub(-#ELLIPSIS) == ELLIPSIS
end

-- true for each line that is a ``` or ~~~ fence or inside a fenced block.
local function fenced(lines)
  local mask, inside = {}, false
  for i, line in ipairs(lines) do
    if line:match("^%s*```") or line:match("^%s*~~~") then
      mask[i], inside = true, not inside
    else
      mask[i] = inside
    end
  end
  return mask
end

function M.join_breaks(lines)
  local out, mask, open = {}, fenced(lines), false
  for i, line in ipairs(lines) do
    local last = out[#out]
    if not mask[i] and open and last:match("%S") and not ends_clause(last) and lower_start(line) then
      out[#out] = last:gsub("%s+$", "") .. " " .. line
    else
      out[#out + 1] = line
    end
    open = not mask[i]
  end
  return out
end

-- Abbreviations whose period does not end a sentence (lowercase, with the
-- final period).
local ABBREV = { ["e.g."] = true, ["i.e."] = true, ["etc."] = true, ["vs."] = true }

-- Capitalize the first letter of word, after any opening quotes/brackets.
local function cap_word(word)
  local i = 1
  while OPENERS[char_at(word, i)] do i = i + #char_at(word, i) end
  local ch = char_at(word, i)
  if ch == "" then return word end
  return word:sub(1, i - 1) .. upper_char(ch) .. word:sub(i + #ch)
end

local function cap_line(line, start)
  -- A lone i (and i'm, i've, i'd, i'll) is always I; not i.e., i-th, or
  -- the i in hawaiʻi.
  line = line:gsub("()i()", function(p, q)
    local before, after = char_before(line, p - 1), char_at(line, q)
    if letter(before) or APOS[before] or letter(after) then return nil end
    local next2 = line:sub(q, q + 1)
    if next2:match("^[%-%.]") and not next2:match("^%.%s") and next2 ~= "." then
      return nil
    end
    return "I"
  end)
  local out, pos, at_start = {}, 1, start
  while pos <= #line do
    local s, e = line:find("^%s+", pos)
    if s then
      out[#out + 1] = line:sub(s, e)
      pos = e + 1
    else
      local ws, we = line:find("^%S+", pos)
      local word = line:sub(ws, we)
      if at_start then word = cap_word(word) end
      out[#out + 1] = word
      at_start = ends_sentence(word) and not ABBREV[strip_closers(word):lower()]
      pos = we + 1
    end
  end
  return table.concat(out), at_start
end

function M.sentence_case(lines, prev)
  local out, mask = {}, fenced(lines)
  local start = prev == nil or not prev:match("%S") or ends_sentence(prev)
  for i, line in ipairs(lines) do
    if mask[i] then
      out[i] = line
      start = true
    elseif not line:match("%S") then
      out[i] = line
      start = true
    else
      out[i], start = cap_line(line, start)
    end
  end
  return out
end

-- Part of a word next to a filler: letters, apostrophes and dashes, so
-- "umbrella", "uh-huh" and "um—" are left whole.
local function filler_joins(ch)
  return letter(ch) or APOS[ch] or ch == "-" or DASH[ch] or false
end

-- Pattern for a filler: its words (escaped, lowercase) joined by %s+.
local function filler_pattern(f)
  local parts = {}
  for w in f:lower():gmatch("%S+") do
    parts[#parts + 1] = (w:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"))
  end
  return table.concat(parts, "%s+"), #parts > 1
end

local function strip_one(line, pat, phrase)
  local from = 1
  while true do
    local a, b = line:lower():find(pat, from)
    if not a then return line end
    local ok = not filler_joins(char_before(line, a - 1)) and not filler_joins(char_at(line, b + 1))
    if ok and phrase then
      local lc = line:sub(1, a - 1):match("([^%s]?)%s*$")
      local rc = line:sub(b + 1):match("^%s*([^%s]?)")
      ok = (lc == "" or lc:match("[,%.;:!%?%(]") ~= nil)
        and (rc == "" or rc:match("[,%.;:!%?%)]") ~= nil)
    end
    if not ok then
      from = a + 1
    else
      local left, right = line:sub(1, a - 1), line:sub(b + 1)
      -- Brackets around only the filler go with it: "(um) yes" -> "yes".
      local open = left:match("([%(%[])%s*$")
      if open then
        local close = right:match("^%s*%" .. (open == "(" and ")" or "]"))
        if close then
          left = left:gsub("%" .. open .. "%s*$", "")
          right = right:sub(#close + 1)
        end
      end
      local rcomma = right:match("^%s*,")
      if rcomma then
        right = right:sub(#rcomma + 1)
        left = left:gsub(",%s*$", "")
      elseif right:match("^%s*[%.!%?;:]") then
        -- "we ship, um." -> "we ship."
        left = left:gsub(",%s*$", "")
      end
      -- Nothing before needs the filler's punctuation: "Uh." -> "",
      -- "Umm... yes" -> "yes", "done. um. so" -> "done. so".
      local lt = left:gsub("%s+$", "")
      if lt:match("^%s*$") or ends_clause(lt) then
        repeat
          local r = right:gsub("^%s*[%.!%?;:]+", "")
          if r == right then r = right:gsub("^%s*" .. ELLIPSIS, "") end
          local same = r == right
          right = r
        until same
      end
      right = right:gsub("^%s+", "")
      if left:match("^%s*$") then
        line = left .. right
      else
        left = left:gsub("%s+$", "")
        if right == "" or right:match("^[,%.;:!%?%)]") or left:match("[%(%[]$") then
          line = left .. right
        else
          line = left .. " " .. right
        end
      end
      from = 1
    end
  end
end

function M.strip_fillers(lines, list)
  list = list or M.DEFAULT_FILLERS
  local out, mask = copy(lines), fenced(lines)
  for _, f in ipairs(list) do
    local pat, phrase = filler_pattern(f)
    if pat ~= "" then
      for i, line in ipairs(out) do
        if not mask[i] then out[i] = strip_one(line, pat, phrase) end
      end
    end
  end
  return out
end

local function norm(w) return (w:lower():gsub(RSQUO, "'")) end

-- w in src's case (UPPER, Capitalized or as is), with src's curly
-- apostrophes.
local function match_case(src, w)
  local s = src:gsub(RSQUO, "'")
  if s:match("^%u[%u']+$") then
    w = w:upper()
  elseif s:match("^%u") then
    w = w:gsub("^%l", string.upper)
  end
  if s ~= src then w = w:gsub("'", RSQUO) end
  return w
end

function M.cycle_word(word, groups)
  if type(word) ~= "string" or word == "" then return nil end
  local key = norm(word)
  for _, g in ipairs(groups or M.DEFAULT_GROUPS) do
    for i, w in ipairs(g) do
      if norm(w) == key and #g > 1 then
        return match_case(word, g[i % #g + 1])
      end
    end
  end
  return nil
end

-- The word around byte col (1-based) of line: letters, digits and
-- apostrophes (' or ’), outer apostrophes left out; quotes (‘ “ ”) and
-- dashes (- – —) end it. Returns first, last (1-based bytes, inclusive)
-- or nil.
function M.word_at(line, col)
  if col < 1 or col > #line then return nil end
  local function inword(ch) return letter(ch) or APOS[ch] or false end
  local s = col
  while s > 1 and s > col - 3 and line:byte(s) >= 0x80 and line:byte(s) < 0xC0 do s = s - 1 end
  local ch = char_at(line, s)
  if not inword(ch) then return nil end
  local e = s + #ch - 1
  while s > 1 and inword(char_before(line, s - 1)) do s = s - #char_before(line, s - 1) end
  while e < #line and inword(char_at(line, e + 1)) do e = e + #char_at(line, e + 1) end
  while s <= e and APOS[char_at(line, s)] do s = s + #char_at(line, s) end
  while e >= s and APOS[char_before(line, e)] do e = e - #char_before(line, e) end
  if s > e then return nil end
  return s, e
end

-- The paragraph around row: the run of non-blank lines holding it (just
-- row when it is blank). Returns first, last (1-based).
function M.paragraph(lines, row)
  local blank = function(i) return not (lines[i] or ""):match("%S") end
  if blank(row) then return row, row end
  local s, e = row, row
  while s > 1 and not blank(s - 1) do s = s - 1 end
  while e < #lines and not blank(e + 1) do e = e + 1 end
  return s, e
end

function M.parse(text)
  local groups, fillers = {}, {}
  for raw in (text .. "\n"):gmatch("([^\n]*)\n") do
    local line = trim((raw:gsub("#.*$", "")))
    local rest = line:match("^[Ff]iller:%s*(.*)$")
    if rest then
      for f in rest:gmatch("[^,]+") do
        f = trim(f)
        if f ~= "" then fillers[#fillers + 1] = f end
      end
    elseif line ~= "" then
      local g = {}
      for w in line:gmatch("[^%s,/]+") do g[#g + 1] = w end
      if #g > 1 then groups[#groups + 1] = g end
    end
  end
  return {
    groups = #groups > 0 and groups or M.DEFAULT_GROUPS,
    fillers = #fillers > 0 and fillers or M.DEFAULT_FILLERS,
  }
end

function M.path()
  local p = os.getenv("FERRY_FIXUPS")
  if p and p ~= "" then return p end
  return (os.getenv("HOME") or "") .. "/.config/ferry/fixups.txt"
end

-- The list from path (default M.path()); the built-ins when unreadable.
function M.load(path)
  local f = io.open(path or M.path(), "r")
  if not f then return M.parse("") end
  local text = f:read("*a") or ""
  f:close()
  return M.parse(text)
end

-- nvim side ---------------------------------------------------------------

-- The default range in buf: '[,'] when set and inside the buffer, else
-- the paragraph at the cursor.
function M.default_range(buf)
  local n = vim.api.nvim_buf_line_count(buf)
  local s = vim.api.nvim_buf_get_mark(buf, "[")[1]
  local e = vim.api.nvim_buf_get_mark(buf, "]")[1]
  if s >= 1 and s <= e and e <= n then return s, e end
  local row = 1
  if vim.api.nvim_get_current_buf() == buf then row = vim.api.nvim_win_get_cursor(0)[1] end
  return M.paragraph(vim.api.nvim_buf_get_lines(buf, 0, -1, false), row)
end

-- Run fn(lines, s, e) over lines s..e of buf (default range when s is nil)
-- and write back what it returns, only if anything changed.
local function apply(buf, s, e, fn)
  if not s then s, e = M.default_range(buf) end
  local old = vim.api.nvim_buf_get_lines(buf, s - 1, e, false)
  local new = fn(old, s, e)
  if table.concat(new, "\n") == table.concat(old, "\n") and #new == #old then return false end
  vim.api.nvim_buf_set_lines(buf, s - 1, e, false, new)
  return true
end

M.ops = {
  join = function(buf, s, e)
    return apply(buf, s, e, function(lines) return M.join_breaks(lines) end)
  end,
  case = function(buf, s, e)
    return apply(buf, s, e, function(lines, first)
      local prev = first > 1 and vim.api.nvim_buf_get_lines(buf, first - 2, first - 1, false)[1] or nil
      return M.sentence_case(lines, prev)
    end)
  end,
  fillers = function(buf, s, e)
    local list = M.load()
    return apply(buf, s, e, function(lines) return M.strip_fillers(lines, list.fillers) end)
  end,
}

-- Replace bytes first..last (1-based) of row in buf with the next word of
-- its group. Returns the new word or nil.
local function cycle_span(buf, row, first, last)
  local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
  local nxt = M.cycle_word(line:sub(first, last), M.load().groups)
  if not nxt then return nil end
  vim.api.nvim_buf_set_text(buf, row - 1, first - 1, row - 1, last, { nxt })
  return nxt
end

-- Cycle the word at the cursor of the current window (buf must be shown).
function M.cycle_at_cursor(buf)
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
  local s, e = M.word_at(line, col + 1)
  if not s then return nil end
  local nxt = cycle_span(buf, row, s, e)
  if nxt then vim.api.nvim_win_set_cursor(0, { row, s - 1 }) end
  return nxt
end

local function cycle_visual(buf)
  local a, b = vim.fn.getpos("v"), vim.fn.getpos(".")
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
  if a[2] ~= b[2] then
    vim.notify("ferry: select one word on one line", vim.log.levels.WARN)
    return nil
  end
  local s, e = math.min(a[3], b[3]), math.max(a[3], b[3])
  local line = vim.api.nvim_buf_get_lines(buf, a[2] - 1, a[2], false)[1] or ""
  -- Extend the end to the last byte of a multibyte character.
  while e < #line and line:byte(e + 1) >= 128 and line:byte(e + 1) < 192 do e = e + 1 end
  return cycle_span(buf, a[2], s, e)
end

local COMMANDS = { FixJoin = "join", FixCase = "case", FixFillers = "fillers" }
local KEYS = { j = "FixJoin", c = "FixCase", f = "FixFillers" }

function M.setup(buf)
  if buf == nil or buf == 0 then buf = vim.api.nvim_get_current_buf() end
  for name, op in pairs(COMMANDS) do
    vim.api.nvim_buf_create_user_command(buf, name, function(o)
      if o.range > 0 then M.ops[op](buf, o.line1, o.line2) else M.ops[op](buf) end
    end, { range = true, force = true, desc = "ferry fix-up: " .. op })
  end
  for k, cmd in pairs(KEYS) do
    vim.keymap.set("n", "<leader>f" .. k, "<Cmd>" .. cmd .. "<CR>",
      { buffer = buf, silent = true, desc = "ferry " .. cmd })
    vim.keymap.set("x", "<leader>f" .. k, ":" .. cmd .. "<CR>",
      { buffer = buf, silent = true, desc = "ferry " .. cmd })
  end
  vim.keymap.set("n", "<leader>fw", function() M.cycle_at_cursor(buf) end,
    { buffer = buf, silent = true, desc = "ferry cycle homophone" })
  vim.keymap.set("x", "<leader>fw", function() cycle_visual(buf) end,
    { buffer = buf, silent = true, desc = "ferry cycle homophone" })
  return buf
end

return M
