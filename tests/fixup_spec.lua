-- Tests for lua/ferry/fixup.lua. The line functions run anywhere (LuaJIT,
-- nvim -l); the buffer commands and maps only under nvim.
-- Run by tests/test-fixup.sh: <lua> tests/fixup_spec.lua <root> <work>
-- with FERRY_FIXUPS and HOME pointing into <work>.
local root, work = arg[1], arg[2]
local F = dofile(root .. "/lua/ferry/fixup.lua")

local out = io.stdout
out:setvbuf("line")
local function say(s) out:write(s, "\n") end

local fail = 0
local function check(name, want, got)
  if want == got then
    say("ok   " .. name)
  else
    say("FAIL " .. name .. ": want '" .. tostring(want) .. "' got '" .. tostring(got) .. "'")
    fail = 1
  end
end
local function j(t) return table.concat(t, "|") .. " (" .. #t .. ")" end

-- join_breaks
check("join {we should, deploy it.} -> one line", "we should deploy it. (1)",
  j(F.join_breaks({ "we should", "deploy it." })))
check("line ending in . is not joined", "Done.|then more (2)",
  j(F.join_breaks({ "Done.", "then more" })))
for _, p in ipairs({ "?", "!", ":", ";" }) do
  check("line ending in " .. p .. " not joined", "a" .. p .. "|b (2)",
    j(F.join_breaks({ "a" .. p, "b" })))
end
check("closing quote after . not joined", 'he said "go."|then (2)',
  j(F.join_breaks({ 'he said "go."', "then" })))
check("uppercase next line not joined", "we should|Deploy (2)",
  j(F.join_breaks({ "we should", "Deploy" })))
check("chain of breaks joins", "a b c. (1)", j(F.join_breaks({ "a", "b", "c." })))
check("comma end joins, trailing space trimmed", "so, then (1)",
  j(F.join_breaks({ "so,  ", "then" })))
check("blank line not joined", "a||b (3)", j(F.join_breaks({ "a", "", "b" })))
check("indented next line not joined", "a|  b (2)", j(F.join_breaks({ "a", "  b" })))
check("fence line not joined to text around it", "see|```|foo|bar|```|after (6)",
  j(F.join_breaks({ "see", "```", "foo", "bar", "```", "after" })))
check("lines after a closed fence join again", "```|x|```|a b. (4)",
  j(F.join_breaks({ "```", "x", "```", "a", "b." })))
check("~~~ fence", "~~~|a|b|~~~ (4)", j(F.join_breaks({ "~~~", "a", "b", "~~~" })))
check("Latin-1 lowercase start joins", "we went élan. (1)",
  j(F.join_breaks({ "we went", "élan." })))
check("curly closing quote after . not joined", "he said “go.”|then (2)",
  j(F.join_breaks({ "he said “go.”", "then" })))
check("heading not joined to the next line", "## next steps|deploy it. (2)",
  j(F.join_breaks({ "## next steps", "deploy it." })))
check("line not joined into a heading", "we should|# heading (2)",
  j(F.join_breaks({ "we should", "# heading" })))
check("#hashtag line still joins", "see #ops now (1)", j(F.join_breaks({ "see #ops", "now" })))
local input = { "x", "y" }
F.join_breaks(input)
check("input not changed", "x|y (2)", j(input))

-- strip_fillers
local fl = F.DEFAULT_FILLERS
check("we ship, um. -> we ship.", "we ship. (1)", j(F.strip_fillers({ "we ship, um." }, fl)))
check("ok, you know? -> ok?", "ok? (1)", j(F.strip_fillers({ "ok, you know?" }, fl)))
check("if you know, you know. -> if you know.", "if you know. (1)",
  j(F.strip_fillers({ "if you know, you know." }, fl)))
check("uh-huh stays", "uh-huh, sure (1)", j(F.strip_fillers({ "uh-huh, sure" }, fl)))
check("um-hmm stays", "so um-hmm right (1)", j(F.strip_fillers({ "so um-hmm right" }, fl)))
check("(um) yes -> yes", "yes (1)", j(F.strip_fillers({ "(um) yes" }, fl)))
check("we (uh) ship -> we ship", "we ship (1)", j(F.strip_fillers({ "we (uh) ship" }, fl)))
check("Uh. -> empty", " (1)", j(F.strip_fillers({ "Uh." }, fl)))
check("Umm... yes -> yes", "yes (1)", j(F.strip_fillers({ "Umm... yes" }, fl)))
check("Umm… yes -> yes", "yes (1)", j(F.strip_fillers({ "Umm… yes" }, fl)))
check("done. Um. so -> done. so", "done. so (1)", j(F.strip_fillers({ "done. Um. so" }, fl)))
check("fenced um stays", "```|um = 1|``` (3)", j(F.strip_fillers({ "```", "um = 1", "```" }, fl)))
check("um so we, you know, ship -> so we ship", "so we ship (1)",
  j(F.strip_fillers({ "um so we, you know, ship" }, fl)))
check("so, um, we -> so we", "so we (1)", j(F.strip_fillers({ "so, um, we" }, fl)))
check("Um, leading with comma", "let's go (1)", j(F.strip_fillers({ "Um, let's go" }, fl)))
check("filler before period", "we ship. (1)", j(F.strip_fillers({ "we ship um." }, fl)))
check("phrase not set off stays", "do you know the time (1)",
  j(F.strip_fillers({ "do you know the time" }, fl)))
check("filler inside a word stays", "umbrella and drum (1)",
  j(F.strip_fillers({ "umbrella and drum" }, fl)))
check("indent kept", "  so (1)", j(F.strip_fillers({ "  um so" }, fl)))
check("several lines", "a|b (2)", j(F.strip_fillers({ "a uh", "uh b" }, fl)))
-- Quotes are treated like brackets.
check('she said "um, yes" -> she said "yes"', 'she said "yes" (1)',
  j(F.strip_fillers({ 'she said "um, yes"' }, fl)))
check("he said “um” twice -> he said twice", "he said twice (1)",
  j(F.strip_fillers({ "he said “um” twice" }, fl)))
check('"um." -> empty line', " (1)", j(F.strip_fillers({ '"um."' }, fl)))
check("so 'um' yes -> so yes", "so yes (1)", j(F.strip_fillers({ "so 'um' yes" }, fl)))
check("«uh» and ‘um’ go", "a b c (1)", j(F.strip_fillers({ "a «uh» b ‘um’ c" }, fl)))
check('he said, "um." -> he said', "he said (1)", j(F.strip_fillers({ 'he said, "um."' }, fl)))
check('"yes, um" -> "yes"', '"yes" (1)', j(F.strip_fillers({ '"yes, um"' }, fl)))
check("(you know) phrase in brackets goes", "we ship (1)",
  j(F.strip_fillers({ "we (you know) ship" }, fl)))
check("they're and don't stay whole", "they're here don't (1)",
  j(F.strip_fillers({ "they're here um don't" }, fl)))
-- Commas and dashes at a line end; a spaced dash pair keeps one dash.
check("it works, you know -> it works", "it works (1)",
  j(F.strip_fillers({ "it works, you know" }, fl)))
check("ok — um — sure -> ok — sure", "ok — sure (1)",
  j(F.strip_fillers({ "ok — um — sure" }, fl)))
check("ok -- uh -- sure -> ok -- sure", "ok -- sure (1)",
  j(F.strip_fillers({ "ok -- uh -- sure" }, fl)))
check("ok — um -> ok", "ok (1)", j(F.strip_fillers({ "ok — um" }, fl)))
check("um — sure -> sure", "sure (1)", j(F.strip_fillers({ "um — sure" }, fl)))
check("so, um — we -> so, we", "so, we (1)", j(F.strip_fillers({ "so, um — we" }, fl)))
check("um— glued stays", "we um— ship (1)", j(F.strip_fillers({ "we um— ship" }, fl)))
check("—um glued stays", "we —um ship (1)", j(F.strip_fillers({ "we —um ship" }, fl)))
check("unchanged line kept byte for byte", "a  b,c   (1)", j(F.strip_fillers({ "a  b,c  " }, fl)))
check("custom list", "we ship (1)", j(F.strip_fillers({ "we like ship" }, { "like" })))
check("default list when nil", "so (1)", j(F.strip_fillers({ "um so" })))

-- cycle_word
local g = F.DEFAULT_GROUPS
check("their -> there", "there", F.cycle_word("their", g))
check("there -> they're", "they're", F.cycle_word("there", g))
check("they're -> their (wraps)", "their", F.cycle_word("they're", g))
check("curly they’re -> their", "their", F.cycle_word("they\226\128\153re", g))
check("Their -> There", "There", F.cycle_word("Their", g))
check("THEIR -> THERE", "THERE", F.cycle_word("THEIR", g))
check("THEY’RE -> THEIR", "THEIR", F.cycle_word("THEY\226\128\153RE", g))
check("They’re -> Their", "Their", F.cycle_word("They\226\128\153re", g))
check("It’s -> Its", "Its", F.cycle_word("It\226\128\153s", g))
check("curly source keeps curly: we’re -> we’ll", "we\226\128\153ll",
  F.cycle_word("we\226\128\153re", { { "we're", "we'll" } }))
check("unknown word -> nil", nil, F.cycle_word("ship", g))
local function span(line, col)
  local s, e = F.word_at(line, col)
  return s and line:sub(s, e) or nil
end
check("word_at ‘their’ -> their", "their", span("so ‘their’ dog", 7))
check("word_at their—dog -> their", "their", span("their—dog", 2))
check("word_at their—dog on dog", "dog", span("their—dog", 10))
check("word_at “your” -> your", "your", span("“your”", 5))
check("word_at they’re keeps inner ’", "they’re", span("they’re", 1))
check("word_at on a curly quote -> nil", nil, span("“your”", 2))
check("word_at hawaiʻi whole", "hawaiʻi", span("hawaiʻi", 7))
check("word_at their", "4-8", (function()
  local s, e = F.word_at("so their dog", 6); return s .. "-" .. e end)())
check("word_at strips outer quote", "2-8", (function()
  local s, e = F.word_at("'they're'", 3); return s .. "-" .. e end)())
check("word_at on space -> nil", nil, (F.word_at("a b", 2)))
check("paragraph", "2-3", (function()
  local s, e = F.paragraph({ "", "a", "b", "", "c" }, 3); return s .. "-" .. e end)())

-- The list file.
check("FERRY_FIXUPS points into work", true, F.path():sub(1, #work) == work)
local missing = F.load(work .. "/nope.txt")
check("missing list -> default groups", F.DEFAULT_GROUPS, missing.groups)
check("missing list -> default fillers", F.DEFAULT_FILLERS, missing.fillers)
local p = F.parse("# mine\nfoo bar/baz  # comment\nfiller: like, sort of\n\nsolo\n")
check("parse groups", "foo,bar,baz (1)", (function()
  local t = {}
  for _, grp in ipairs(p.groups) do t[#t + 1] = table.concat(grp, ",") end
  return j(t)
end)())
check("parse fillers", "like|sort of (2)", j(p.fillers))
check("only fillers -> default groups", F.DEFAULT_GROUPS, F.parse("filler: x").groups)

local f = assert(io.open(F.path(), "w"))
f:write("cube kubectl\nfiller: basically\n")
f:close()
local list = F.load()
check("temp FERRY_FIXUPS honoured: group", "kubectl", F.cycle_word("cube", list.groups))
check("temp FERRY_FIXUPS honoured: filler", "we ship (1)",
  j(F.strip_fillers({ "basically we ship" }, list.fillers)))
check("temp list replaces default groups", nil, F.cycle_word("their", list.groups))
os.remove(F.path())

if not vim then
  say(fail == 0 and "all ok (pure)" or "FAILED")
  os.exit(fail)
end

-- Buffer commands and maps (nvim only).
vim.g.mapleader = "\\"
local buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(buf)
check("api 2", 2, F.api)
F.setup(buf)
F.setup(buf) -- twice is fine
local function set(lines)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_del_mark(buf, "[")
  vim.api.nvim_buf_del_mark(buf, "]")
end
local function get() return j(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) end
local function keys(k)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(k, true, false, true), "mx", false)
end

-- :FixJoin with no range, '[,'] set by a paste.
set({ "intro.", "" })
vim.api.nvim_win_set_cursor(0, { 2, 0 })
vim.paste({ "we should", "deploy it." }, -1)
check(":FixJoin after a paste joins the paste", "intro.|we should deploy it. (2)",
  (function() vim.cmd("FixJoin"); return get() end)())

-- Paragraph fallback: no '[ mark.
set({ "a", "b", "", "c", "d" })
check("'[ cleared", 0, vim.api.nvim_buf_get_mark(buf, "[")[1])
vim.api.nvim_win_set_cursor(0, { 4, 0 })
vim.cmd("FixJoin")
check("no '[: :FixJoin on the paragraph only",
  "a|b||c d (4)", get())

-- A recorded paste (b:ferry_paste, from flow.on_paste) wins over '[,'],
-- which a write sets to the whole buffer; one out of bounds: paragraph.
set({ "keep this", "line broken", "we should", "deploy it." })
vim.b[buf].ferry_paste = { 3, 4 }
vim.api.nvim_buf_set_mark(buf, "[", 1, 0, {})
vim.api.nvim_buf_set_mark(buf, "]", 4, 0, {})
vim.cmd("FixJoin")
check("b:ferry_paste wins over '[,']: only the paste joined, the record follows",
  "keep this|line broken|we should deploy it. (3) 3,3", get() .. " " .. table.concat(vim.b[buf].ferry_paste, ","))
set({ "a", "b", "", "c", "d" })
vim.b[buf].ferry_paste = { 4, 9 }
vim.api.nvim_win_set_cursor(0, { 4, 0 })
vim.cmd("FixJoin")
check("b:ferry_paste out of bounds: the paragraph", "a|b||c d (4)", get())
vim.b[buf].ferry_paste = nil

-- Explicit range.
set({ "x", "y", "z" })
vim.cmd("1,2FixJoin")
check(":1,2FixJoin", "x y|z (2)", get())

-- :FixFillers on a range.
set({ "um so we, you know, ship" })
vim.cmd("%FixFillers")
check(":FixFillers", "so we ship (1)", get())

-- Maps exist in n and x.
for _, k in ipairs({ "fj", "ff", "fw" }) do
  for _, m in ipairs({ "n", "x" }) do
    check("map " .. m .. " <leader>" .. k, true,
      vim.fn.maparg("\\" .. k, m, false, true).buffer == 1)
  end
end

-- <leader>fj in normal mode uses the default range.
set({ "a", "b." })
vim.api.nvim_win_set_cursor(0, { 1, 0 })
keys("\\fj")
check("<leader>fj (n)", "a b. (1)", get())

-- Visual <leader>fj on the selection only.
set({ "a", "b", "c" })
vim.api.nvim_win_set_cursor(0, { 2, 0 })
keys("Vj\\fj")
check("<leader>fj (x) joins the selection", "a|b c (2)", get())

-- Visual <leader>ff.
set({ "um yes", "uh no" })
vim.api.nvim_win_set_cursor(0, { 1, 0 })
keys("V\\ff")
check("<leader>ff (x) on line 1", "yes|uh no (2)", get())

-- <leader>fw cycles the word at the cursor.
set({ "so their dog" })
vim.api.nvim_win_set_cursor(0, { 1, 5 })
keys("\\fw")
check("<leader>fw on their -> there", "so there dog (1)", get())
keys("\\fw")
check("<leader>fw again -> they're", "so they're dog (1)", get())
set({ "Its fine" })
vim.api.nvim_win_set_cursor(0, { 1, 0 })
keys("viw\\fw")
check("<leader>fw (x) Its -> It's", "It's fine (1)", get())
check("back in normal mode", "n", vim.api.nvim_get_mode().mode)
set({ "so ‘their’ dog" })
vim.api.nvim_win_set_cursor(0, { 1, 7 })
keys("\\fw")
check("<leader>fw inside ‘their’", "so ‘there’ dog (1)", get())
set({ "their—dog" })
vim.api.nvim_win_set_cursor(0, { 1, 1 })
keys("\\fw")
check("<leader>fw on their—dog", "there—dog (1)", get())
set({ "THEY’RE here" })
vim.api.nvim_win_set_cursor(0, { 1, 2 })
keys("\\fw")
check("<leader>fw THEY’RE -> THEIR", "THEIR here (1)", get())
set({ "ship it" })
vim.api.nvim_win_set_cursor(0, { 1, 0 })
keys("\\fw")
check("<leader>fw on a word with no group: no change", "ship it (1)", get())

-- Missing list: defaults, no error.
vim.env.FERRY_FIXUPS = work .. "/missing/fixups.txt"
set({ "your call" })
vim.api.nvim_win_set_cursor(0, { 1, 0 })
local okw, err = pcall(keys, "\\fw")
check("missing list: no error", true, okw and true or err)
check("missing list: default groups", "you're call (1)", get())

-- A list written later is read on the next use.
vim.env.FERRY_FIXUPS = work .. "/later.txt"
local lf = assert(io.open(work .. "/later.txt", "w"))
lf:write("cube kubectl\n")
lf:close()
set({ "run cube" })
vim.api.nvim_win_set_cursor(0, { 1, 5 })
keys("\\fw")
check("temp FERRY_FIXUPS read on use", "run kubectl (1)", get())

say(fail == 0 and "all ok" or "FAILED")
os.exit(fail)
