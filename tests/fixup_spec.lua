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
local input = { "x", "y" }
F.join_breaks(input)
check("input not changed", "x|y (2)", j(input))

-- sentence_case
check("sentence starts capitalized", "Hello there. How are you? Fine! (1)",
  j(F.sentence_case({ "hello there. how are you? fine!" })))
check("lone i -> I", "I think I'm right, I'd say (1)",
  j(F.sentence_case({ "i think i'm right, i'd say" })))
check("i.e. and e.g. left alone", "Use it, i.e. now, e.g. today (1)",
  j(F.sentence_case({ "use it, i.e. now, e.g. today" })))
check("so do i.", "So do I. (1)", j(F.sentence_case({ "so do i." })))
check("next line after . starts a sentence", "One.|Two (2)",
  j(F.sentence_case({ "one.", "two" })))
check("next line mid-sentence stays", "One|two (2)", j(F.sentence_case({ "one", "two" })))
check("after blank line starts a sentence", "A||B (3)", j(F.sentence_case({ "a", "", "b" })))
check("prev mid-sentence: first line stays", "and more. Then (1)",
  j(F.sentence_case({ "and more. then" }, "we went")))
check("prev ends sentence: first line capitalized", "And (1)",
  j(F.sentence_case({ "and" }, "Done.")))
check("quote before letter", '"Yes," she said. (1)', j(F.sentence_case({ '"yes," she said.' })))
check("mid-sentence capitals kept", "Use NASA and Bob. (1)",
  j(F.sentence_case({ "use NASA and Bob." })))

-- strip_fillers
local fl = F.DEFAULT_FILLERS
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
check("unknown word -> nil", nil, F.cycle_word("ship", g))
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
check("api 1", 1, F.api)
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

-- Explicit range.
set({ "x", "y", "z" })
vim.cmd("1,2FixJoin")
check(":1,2FixJoin", "x y|z (2)", get())

-- :FixCase, :FixFillers on a range.
set({ "hello. i am here" })
vim.cmd("%FixCase")
check(":FixCase", "Hello. I am here (1)", get())
set({ "um so we, you know, ship" })
vim.cmd("%FixFillers")
check(":FixFillers", "so we ship (1)", get())

-- Maps exist in n and x.
for _, k in ipairs({ "fj", "fc", "ff", "fw" }) do
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
