-- Post-dictation fix-ups: small commands for the mistakes Flow makes.
--
-- The line functions are pure Lua (no `vim` at load time), so they load
-- under LuaJIT and `nvim -l`. Each takes a list of lines and returns a new
-- list; the input is never changed.
--
--   join_breaks(lines)            join a line with no end punctuation
--                                 (. ! ? : ; … maybe then a closing quote or
--                                 bracket) to a next line that starts with a
--                                 lowercase letter, with one space; never
--                                 into or out of a "# heading" line
--   strip_fillers(lines, list)    remove filler words, with a comma pair
--                                 around them ("we, you know, ship" -> "we
--                                 ship"); a one-word filler goes anywhere
--                                 outside a word ("uh-huh" stays), a phrase
--                                 only when set off by punctuation, a dash,
--                                 a quote or a line edge ("do you know"
--                                 stays); punctuation, dashes, quotes and
--                                 brackets left with nothing to do go too
--                                 (see settle below)
--   cycle_word(word, groups)      next word of its homophone group, keeping
--                                 Capitalized / UPPER case and curly ’;
--                                 nil if none
--
-- Both line functions leave ``` / ~~~ fences and fenced lines alone.
-- Text is UTF-8: curly quotes and dashes are not letters, other non-ASCII
-- characters are.
--
-- The list: $FERRY_FIXUPS, default ~/.config/ferry/fixups.txt. `#` starts
-- a comment. A `filler: a, b c` line adds fillers (comma separated, so a
-- filler may be a phrase); any other line is a homophone group, words
-- separated by spaces, commas or slashes. A file with group lines replaces
-- the built-in groups; one with filler lines replaces the built-in
-- fillers. A missing or unreadable file means the built-ins, no error.
--
-- setup(buf) (needs nvim): buffer-local :FixJoin and :FixFillers.
-- With no range they act on '[,'] (the last change, normally Flow's
-- paste), else on the paragraph at the cursor. Maps <leader>fj, ff in
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

-- A Markdown heading: "# Title", "## next steps".
local function heading(line) return line:match("^%s*#+%s") ~= nil end

function M.join_breaks(lines)
  local out, mask, open = {}, fenced(lines), false
  for i, line in ipairs(lines) do
    local skip = mask[i] or heading(line)
    local last = out[#out]
    if not skip and open and last:match("%S") and not ends_clause(last) and lower_start(line) then
      out[#out] = last:gsub("%s+$", "") .. " " .. line
    else
      out[#out + 1] = line
    end
    open = not skip
  end
  return out
end

local function norm(w) return (w:lower():gsub(RSQUO, "'")) end

-- Fillers work on tokens in one pass: split the line into tokens, drop
-- each filler and the punctuation it leaves with nothing to do, then
-- rejoin. A token is { t = text, k = kind, sp = whitespace before it }:
--   w  word: letters with inner ' . : (they're, e.g) and any - or dash
--      (uh-huh, um— stay whole, so never match a filler)
--   p  punctuation run: , . ; : ! ? …
--   d  dash run with nothing glued on its left: - -- – —
--   o  opener ( [ “ ‘ «, or " ' starting a quote
--   c  closer ) ] ” ’ », or " ' ending one
--   x  anything else
local PUNCT = { [","] = true, ["."] = true, [";"] = true, [":"] = true,
  ["!"] = true, ["?"] = true, [ELLIPSIS] = true }

local function dashy(ch) return ch == "-" or DASH[ch] or false end

-- Tokens of line, and the whitespace after the last one.
local function tokenize(line)
  local toks, i, sp = {}, 1, ""
  while i <= #line do
    local ch = char_at(line, i)
    local j = i + #ch
    if ch:match("^%s$") then
      sp = sp .. ch
    else
      local k
      if letter(ch) then
        k = "w"
        while j <= #line do
          local c = char_at(line, j)
          local inner = (APOS[c] or c == "." or c == ":") and letter(char_at(line, j + #c))
          if not (letter(c) or dashy(c) or inner) then break end
          j = j + #c
        end
      elseif PUNCT[ch] or dashy(ch) then
        local same = PUNCT[ch] and function(c) return PUNCT[c] end or dashy
        k = PUNCT[ch] and "p" or "d"
        while same(char_at(line, j)) do j = j + #char_at(line, j) end
      elseif ch == '"' or ch == "'" then
        -- Opens a quote after a space, a line start or another opener,
        -- when text follows; else closes one.
        local prev, after = toks[#toks], char_at(line, j)
        local opens = (not prev or sp ~= "" or prev.k == "o") and after ~= "" and not after:match("^%s")
        k = opens and "o" or "c"
      else
        k = OPENERS[ch] and "o" or CLOSERS[ch] and "c" or "x"
      end
      toks[#toks + 1] = { t = line:sub(i, j - 1), k = k, sp = sp }
      sp = ""
    end
    i = j
  end
  return toks, sp
end

local function spaced(t) return t.sp ~= "" or t.cutsp == true end
local function is_comma(t) return t ~= nil and t.k == "p" and t.t:match("^,+$") ~= nil end

-- Remove toks[i]; the token after it remembers a cut (and its space).
local function drop(toks, i)
  local t = table.remove(toks, i)
  local n = toks[i]
  if n then n.cut, n.cutsp = true, n.cutsp or spaced(t) end
end

-- toks[j] ends a clause: . ! ? ; : or …, then maybe closers.
local function clause_end(toks, j)
  while toks[j] and toks[j].k == "c" do j = j - 1 end
  local t = toks[j]
  return t ~= nil and t.k == "p" and t.t:sub(-1) ~= ","
end

-- Opener o and closer c make a pair: ( ), [ ], or any two quotes.
local function pair(o, c)
  if o.t == "(" then return c.t == ")" end
  if o.t == "[" then return c.t == "]" end
  return c.t ~= ")" and c.t ~= "]"
end

-- After a filler was cut just before toks[i], drop what it leaves with
-- nothing to do, until nothing changes:
--   "so, um, we" -> "so we"          a comma pair (or one comma) goes
--   "we ship, um." -> "we ship."     a comma before end punctuation goes
--   "Uh." -> "", "done. um. so"      end punctuation with nothing before
--     -> "done. so"                  it to end goes
--   "ok — um — sure" -> "ok — sure"  of a spaced dash pair one stays: a
--                                    dash may mark a real break, which we
--                                    cannot tell from an aside
--   "it works, you know" -> "it works"  a comma or dash left at the line
--                                    end (or before a closer) goes
--   "(um) yes", “um”, "\"um.\""      an opener and closer around nothing
--                                    go; a line left empty is ""
local function settle(toks, i)
  while true do
    local p, n = toks[i - 1], toks[i]
    if is_comma(n) then
      drop(toks, i)
      if is_comma(p) then drop(toks, i - 1); i = i - 1 end
    elseif n and n.k == "p" and is_comma(p) then
      drop(toks, i - 1); i = i - 1
    elseif n and n.k == "p" and (not p or p.k == "o" or clause_end(toks, i - 1)) then
      drop(toks, i)
    elseif n and n.k == "d" and (not p or p.k == "o" or p.k == "p" or p.k == "d") then
      drop(toks, i)
    elseif (not n or n.k == "c") and (is_comma(p) or (p and p.k == "d")) then
      drop(toks, i - 1); i = i - 1
    elseif p and n and p.k == "o" and n.k == "c" and pair(p, n) then
      drop(toks, i); drop(toks, i - 1); i = i - 1
    else
      return
    end
  end
end

-- A filler (list of normalized words) starts at toks[i]: its words with
-- space between. One word must not be glued to a dash or symbol ("—um");
-- a phrase must be set off by punctuation, a dash, a quote or bracket, or
-- the line edge ("do you know the time" stays).
local function filler_at(toks, i, words)
  for k, w in ipairs(words) do
    local t = toks[i + k - 1]
    if not t or t.k ~= "w" or norm(t.t) ~= w or (k > 1 and not spaced(t)) then return false end
  end
  local p, n = toks[i - 1], toks[i + #words]
  if #words == 1 then
    local glued_l = p and (p.k == "d" or p.k == "x") and not spaced(toks[i])
    local glued_r = n and (n.k == "d" or n.k == "x") and not spaced(n)
    return not (glued_l or glued_r)
  end
  return (not p or p.k == "p" or p.k == "o" or p.k == "d")
    and (not n or n.k == "p" or n.k == "c" or n.k == "d")
end

local function strip_line(line, fillers)
  local toks, tail = tokenize(line)
  if #toks == 0 then return line end
  local indent, last, changed = toks[1].sp, toks[#toks], false
  for _, words in ipairs(fillers) do
    local i = 1
    while i <= #toks do
      if filler_at(toks, i, words) then
        for _ = 1, #words do drop(toks, i) end
        settle(toks, i)
        changed, i = true, 1
      else
        i = i + 1
      end
    end
  end
  if not changed then return line end
  if #toks == 0 then return "" end
  -- Rejoin: kept spacing where nothing was cut; where something was, one
  -- space, none before punctuation or a closer or after an opener.
  local out = {}
  for k, t in ipairs(toks) do
    local sp = t.sp
    if k == 1 then
      sp = indent
    elseif t.cut then
      if t.k == "p" or t.k == "c" or toks[k - 1].k == "o" then
        sp = ""
      elseif sp == "" and t.cutsp then
        sp = " "
      end
    end
    out[#out + 1] = sp .. t.t
  end
  if toks[#toks] == last then out[#out + 1] = tail end
  return table.concat(out)
end

function M.strip_fillers(lines, list)
  local fillers = {}
  for _, f in ipairs(list or M.DEFAULT_FILLERS) do
    local words = {}
    for w in f:gmatch("%S+") do words[#words + 1] = norm(w) end
    if #words > 0 then fillers[#fillers + 1] = words end
  end
  local out, mask = copy(lines), fenced(lines)
  for i, line in ipairs(out) do
    if not mask[i] then out[i] = strip_line(line, fillers) end
  end
  return out
end


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

local COMMANDS = { FixJoin = "join", FixFillers = "fillers" }
local KEYS = { j = "FixJoin", f = "FixFillers" }

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
