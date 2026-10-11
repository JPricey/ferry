-- Submit, Cancel and Hide in lua/voice-vim/note.lua, with a recording stub
-- host and a temp history database.
-- Key-driven cases (:q, :wq, <C-x>, ZQ) run against a real server in
-- tests/test-note.sh, where typed input goes through the main loop.
-- Run by tests/test-note.sh: nvim --headless --clean -l tests/note_spec.lua <root> <work>
-- The shell sets VOICE_VIM_DB, VOICE_VIM_NOTES_DIR and puts a recording
-- fake `open` first on PATH (it fails while <work>/open.fail exists).
local root, work = arg[1], arg[2]
vim.opt.rtp:prepend(root)
local note = require("voice-vim.note")
local db = root .. "/bin/voice-vim-db"

-- Never touch the system clipboard: a fake + and * provider.
local clip = {}
vim.g.clipboard = {
  name = "voice-vim-test",
  copy = { ["+"] = function(lines) clip["+"] = lines end, ["*"] = function(lines) clip["*"] = lines end },
  paste = { ["+"] = function() return clip["+"] or {} end, ["*"] = function() return clip["*"] or {} end },
}

local notices = {}
local real_notify = vim.notify
vim.notify = function(msg, ...) notices[#notices + 1] = msg; return real_notify(msg, ...) end

local fail = 0
local function check(name, want, got)
  if want == got then
    print("ok   " .. name)
  else
    print("FAIL " .. name .. ": want '" .. tostring(want) .. "' got '" .. tostring(got) .. "'")
    fail = 1
  end
end

local function readfile(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("a"); f:close(); return s
end

-- Recording stub host. submit reads the file at call time.
local calls
local stub = {
  submit = function(p)
    calls[#calls + 1] = { "submit", p, readfile(p.file) }
  end,
  hide = function(p) calls[#calls + 1] = { "hide", p } end,
}
local function reset() calls = {} end
note.host = stub

local function row(id)
  local out = vim.fn.system({ db, "get", id })
  if vim.v.shell_error ~= 0 then return nil end
  return vim.json.decode(out)
end
local function outcome(id) local r = row(id); return r and r.outcome or "none" end

local function show(seedtext)
  local seed = ""
  if seedtext then
    seed = work .. "/seed.txt"
    vim.fn.writefile(vim.split(seedtext, "\n", { plain = true }), seed)
  end
  local path = note.show({ target = "com.example.app", window = "4242", seed = seed })
  return path, vim.b.voicevim.id, vim.api.nvim_get_current_buf()
end
local function set(lines) vim.api.nvim_buf_set_lines(0, 0, -1, false, lines) end
local function kinds() local k = {}; for _, c in ipairs(calls) do k[#k + 1] = c[1] end; return table.concat(k, ",") end

-- --- Submit ---------------------------------------------------------------
reset()
local p1, id1 = show()
check("note has Submit/Cancel/Hide commands and ZZ, <C-x>, ZQ maps",
  "2 2 2 <Cmd>Submit<CR> <Cmd>Submit<CR> <Cmd>Submit<CR> <Cmd>Cancel<CR>",
  table.concat({ vim.fn.exists(":Submit"), vim.fn.exists(":Cancel"), vim.fn.exists(":Hide"),
    vim.fn.maparg("ZZ", "n"), vim.fn.maparg("<C-x>", "n"), vim.fn.maparg("<C-x>", "i"),
    vim.fn.maparg("ZQ", "n") }, " "))
set({ "hello world", "second line" })
vim.cmd("Submit")
check("Submit calls host.submit once", "submit", kinds())
local c = calls[1] or { nil, {} }
check("host.submit gets target and window", "com.example.app 4242", tostring(c[2].target) .. " " .. tostring(c[2].window))
check("submit file holds the text", "hello world\nsecond line\n", c[3])
check("Submit records a submitted row with the text", "submitted hello world",
  outcome(id1) .. " " .. ((row(id1) or {}).preview or ""))
check("Submit drops the note file", 0, vim.fn.filereadable(p1))
check("Submit leaves the server running", vim.NIL, vim.v.exiting)
check("submit file is <notes>/outbox/<id>.md", vim.env.VOICE_VIM_NOTES_DIR .. "/outbox/" .. id1 .. ".md", c[2].file)
local blank_id = (vim.b.voicevim or {}).id
check("after Submit the window shows a new empty note with :Hide and the :q abbreviation",
  "markdown 2 true ",
  table.concat({ vim.bo.filetype, vim.fn.exists(":Hide"),
    tostring(blank_id ~= nil and blank_id ~= id1 and vim.fn.maparg("q", "c", true) ~= ""),
    table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "|") }, " "))
check("the blank note has no history row before show", "none", outcome(blank_id))
local p2, id2 = show()
check("after Submit the next show is fresh", true, p2 ~= p1 and id2 ~= id1)
check("next show resumes the blank note", blank_id, id2)
check("fresh note is empty", "", table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "|"))
-- history start runs in the background; give it a moment.
vim.wait(3000, function() return outcome(id2) == "open" end, 20)
check("fresh note has an open row", "open", outcome(id2))

-- --- Cancel ---------------------------------------------------------------
reset()
set({ "not this one" })
vim.cmd("Cancel")
check("Cancel calls host.hide only", "hide", kinds())
check("Cancel records a cancelled row", "cancelled", outcome(id2))
local _, id3 = show()
check("after Cancel the next show is fresh", true, id3 ~= id2)

-- --- blank Submit ---------------------------------------------------------
reset()
set({ "  ", "" })
vim.cmd("Submit")
check("blank Submit calls host.hide only", "hide", kinds())
check("blank Submit drops the row", "none", outcome(id3))

-- --- unchanged-seed Submit -----------------------------------------------
reset()
local blank4 = vim.b.voicevim.id
local _, id4 = show("selected text\nline two")
local function has_buf(id)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and (vim.b[b].voicevim or {}).id == id then return true end
  end
  return false
end
check("a seeded show drops the unused blank note", "none false", outcome(blank4) .. " " .. tostring(has_buf(blank4)))
check("seeded note shows the seed", "selected text|line two", table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "|"))
vim.cmd("Submit")
check("unchanged-seed Submit calls host.hide only", "hide", kinds())
check("unchanged-seed Submit records a cancelled row", "cancelled", outcome(id4))

-- --- Hide keeps the draft ---------------------------------------------------
reset()
local p5, id5 = show()
set({ "keep me" })
vim.cmd("Hide")
check("Hide calls host.hide only", "hide", kinds())
check("Hide writes the draft", "keep me\n", readfile(p5))
check("Hide sets g:voicevim_draft", p5, vim.g.voicevim_draft)
check("Hide leaves the row open", "open", outcome(id5))
local p6, id6 = show()
check("next show resumes the draft", p5 .. " " .. id5 .. " keep me",
  p6 .. " " .. id6 .. " " .. table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "|"))

-- --- history sidebar excludes the current note -----------------------------
local _, id9 = show()
local fin = work .. "/fin.txt"
vim.fn.writefile({ "listed elsewhere" }, fin)
vim.fn.system({ db, "finish", id9, "submitted", fin })
local hist = require("voice-vim.history")
local function listed(id)
  for _, r in ipairs(hist.load()) do if r.id == id then return true end end
  return false
end
check("history excludes b:voicevim.id of the note", false, listed(id9))
check("history lists other notes", true, listed(id1))
vim.cmd("enew")
vim.env.VOICE_VIM_SESSION_ID = id1
check("history falls back to VOICE_VIM_SESSION_ID", "false true", tostring(listed(id1)) .. " " .. tostring(listed(id9)))
vim.env.VOICE_VIM_SESSION_ID = nil
show()
vim.cmd("Cancel")

-- --- default host ---------------------------------------------------------
note.host = note.default_host
local log = work .. "/open.log"
local function opened() return readfile(log) or "" end
local function wait_for(pat) vim.wait(3000, function() return opened():find(pat, 1, true) ~= nil end, 20) end

show()
set({ "via hammerspoon" })
vim.cmd("Submit")
wait_for("voicevim-submit")
local line = opened():match("[^\n]*voicevim%-submit[^\n]*") or ""
check("default host runs open -g with the submit URL", true, line:find("^%-g hammerspoon://voicevim%-submit%?file=") ~= nil)
check("submit URL contains target=com.example.app&window=4242", true,
  line:find("target=com.example.app&window=4242", 1, true) ~= nil)
local file = vim.uri_decode(line:match("file=([^&]*)") or "")
check("submit URL names the file holding the text", "via hammerspoon\n", readfile(file))
os.remove(file)

os.remove(log)
show()
set({ "cancel via hammerspoon" })
vim.cmd("Cancel")
wait_for("voicevim-hide")
check("default host hides via hammerspoon://voicevim-hide", "-g hammerspoon://voicevim-hide\n", opened())

-- open fails: text goes on the clipboard with a notice.
vim.fn.writefile({}, work .. "/open.fail")
notices = {}
show()
set({ "clipboard fallback" })
vim.cmd("Submit")
vim.wait(3000, function() return #notices > 0 end, 20)
check("failed open copies the text to +", "clipboard fallback", table.concat(clip["+"] or {}, "\n"))
check("failed open notifies copied — paste manually", "voice-vim: copied — paste manually", notices[1])
os.remove(work .. "/open.fail")

print(fail == 0 and "note_spec: all ok" or "note_spec: FAILED")
os.exit(fail)
