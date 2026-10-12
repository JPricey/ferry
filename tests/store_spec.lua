-- Tests for lua/ferry/store.lua against tests/fixtures/notes/*.md.
-- Run through tests/test-store.sh, which sets STORE_TMP to a fresh temp dir.
local here = debug.getinfo(1, "S").source:sub(2):match("^(.*)/[^/]+$") or "."
local S = dofile(here .. "/../lua/ferry/store.lua")
local fixtures = here .. "/fixtures/notes"
local tmp = os.getenv("STORE_TMP")
if not tmp or tmp == "" then print("FAIL STORE_TMP not set"); os.exit(1) end

local fail = 0
local function check(name, want, got)
  if want == got then
    print("ok   " .. name)
  else
    print("FAIL " .. name .. ": want '" .. tostring(want) .. "' got '" .. tostring(got) .. "'")
    fail = 1
  end
end

local function slurp(path)
  local f = assert(io.open(path, "rb"))
  local s = f:read("*a")
  f:close()
  return s
end

local function spit(path, s)
  local f = assert(io.open(path, "wb"))
  f:write(s)
  f:close()
end

local function ls(dir)
  local out = {}
  local p = io.popen("ls -A '" .. dir .. "'")
  for line in p:lines() do out[#out + 1] = line end
  p:close()
  return out
end

local function fixture(name) return S.read(fixtures .. "/" .. name) end

-- Every fixture round-trips byte-identical, and the write leaves no temp file.
local names = ls(fixtures)
check("fixtures found", true, #names >= 11)
local rt = tmp .. "/roundtrip"
os.execute("mkdir -p '" .. rt .. "'")
for _, n in ipairs(names) do
  local meta, lines = fixture(n)
  local ok, err = S.write(rt .. "/" .. n, meta, lines)
  check("write " .. n, true, ok == true and true or tostring(err))
  check("round-trip byte-identical " .. n, slurp(fixtures .. "/" .. n), slurp(rt .. "/" .. n))
end
check("round-trip leaves no temp file", table.concat(names, ","), table.concat(ls(rt), ","))

-- Known keys.
local m, b = fixture("sent.md")
check("sent: state", "sent", m.state)
check("sent: target", "app:com.mitchellh.ghostty#42", m.target)
check("sent: key order", "id,state,created,updated,sent,target", table.concat(m, ","))
check("sent: body keeps blank line", 3, #b)
check("sent: body line 3", "Keep the Hammerspoon layer thin.", b[3])
m = fixture("cancelled.md")
check("cancelled: state", "cancelled", m.state)
check("cancelled: fleet target", "fleet:task:jpX", m.target)
m = fixture("pinned.md")
check("pinned: pinned", "true", m.pinned)
check("pinned: tmux target", "tmux:default:%3", m.target)
m, b = fixture("empty-body.md")
check("empty body: no lines", 0, #b)

-- Unknown keys survive, in order, and are kept on rewrite after edits.
m, b = fixture("unknown-key.md")
check("unknown keys: order kept",
  "title,id,state,mood,created,tags,aliases,updated,x-obsidian.cssclass", table.concat(m, ","))
check("unknown keys: title", "Prompt ideas", m.title)
check("unknown keys: quoted yes stays a string", "yes", m.mood)
check("unknown keys: list kept raw", "tags:|  - prompts|  - ideas",
  type(m.tags) == "table" and table.concat(m.tags.raw, "|") or tostring(m.tags))
check("unknown keys: flow list kept raw", "aliases: [ideas, prompt ideas]",
  type(m.aliases) == "table" and m.aliases.raw[1] or tostring(m.aliases))
check("unknown keys: dotted key", "wide", m["x-obsidian.cssclass"])
m.state = "sent"
S.set(m, "sent", "2026-10-12T08:00:00-07:00")
S.set(m, "target", "app:com.x#42")
assert(S.write(tmp .. "/edited.md", m, b))
local m2 = S.read(tmp .. "/edited.md")
check("unknown keys: survive an edit",
  "title,id,state,mood,created,tags,aliases,updated,x-obsidian.cssclass,sent,target",
  table.concat(m2, ","))
check("unknown keys: edited state", "sent", m2.state)
check("unknown keys: list survives an edit", "tags:\n  - prompts\n  - ideas\n",
  slurp(tmp .. "/edited.md"):match("(tags:\n.-\n)aliases"))

-- A body starting with --- or to: x stays body.
m, b = fixture("body-dashes.md")
check("body ---: state", "draft", m.state)
check("body ---: id", "1234abcd-0000-4000-8000-000000000001", m.id)
check("body ---: first body line", "---", b[1])
check("body ---: body length", 4, #b)
m, b = fixture("body-to.md")
check("body to: x: first body line", "to: x", b[1])
check("body to: x: no to key", nil, rawget(m, "to"))
m, b = fixture("no-frontmatter-dashes.md")
check("unclosed-looking prose between rules stays body", "---", b[1])
check("prose between rules: body length", 4, #b)
check("prose between rules: draft", "draft", m.state)
check("prose between rules: no keys", 0, #m)
m, b = S.parse("to: x\nhello\n")
check("to: x without frontmatter is body", "to: x", b[1])
m, b = S.parse("---\nid: 1\n")
check("unclosed frontmatter is body", "---,id: 1", table.concat(b, ","))
-- Body that would read back as frontmatter gets an empty block in front.
check("format guards a frontmatter-looking body", "---\n---\n---\na: b\n---\n",
  S.format({}, { "---", "a: b", "---" }))

-- Special-character targets round-trip.
m = fixture("target-special.md")
check("special target: decoded", "tmux:work \"proj\": %3 #x 'y'", m.target)
local specials = {
  "app:com.x#42", "tmux:default:%3", "fleet:task:jpX",
  "tmux:my \"proj\": %3 #x", "it's", "'quoted'", "\"dq\"", "back\\slash",
  "%3", "#42", "- dash", "a: b", "a #b", "ends:", " lead", "trail ",
  "two\nlines", "tab\there", "123", "1e5", "0x1F", "yes", "null", "~", "1:30",
  "", "café ✓",
}
for _, t in ipairs(specials) do
  local p = tmp .. "/special.md"
  assert(S.write(p, { "id", "target", id = "x1", target = t }, { "body" }))
  local got, gb = S.read(p)
  check("target round-trips: " .. t:gsub("\n", "\\n"):gsub("\t", "\\t"), t, got.target)
  check("body intact after target: " .. t:gsub("\n", "\\n"):gsub("\t", "\\t"), "body", gb[1])
end
check("plain target stays unquoted", "app:com.x#42", S.scalar("app:com.x#42"))
check("tmux target stays unquoted", "tmux:default:%3", S.scalar("tmux:default:%3"))
check("number-like id is quoted", '"12345678"', S.scalar("12345678"))
check("boolean writes plain", "true", S.scalar(true))
check("integer writes plain", "3", S.scalar(3))
check("double-quoted \\u escape", "é", S.parse('---\nk: "\\u00e9"\n---\n').k)
check("single-quoted value", "it's", S.parse("---\nk: 'it''s'\n---\n").k)
check("plain value comment dropped", "v", S.parse("---\nk: v # note\n---\n").k)

-- No frontmatter reads as draft, whole file as body; writes back without.
m, b = fixture("no-frontmatter.md")
check("no frontmatter: state draft", "draft", m.state)
check("no frontmatter: no keys", 0, #m)
check("no frontmatter: whole file is body", 2, #b)
check("no frontmatter: first line", "Just a thought, written before notes had frontmatter.", b[1])
m = S.parse("---\nid: abc\n---\nx\n")
check("frontmatter without state reads as draft", "draft", m.state)
check("default state is not written", "---\nid: abc\n---\nx\n", S.format(m, { "x" }))
m, b = S.parse("")
check("empty file: draft", "draft", m.state)
check("empty file: no lines", 0, #b)

-- write: temp file then rename, no temp left, overwrite works, errors clean.
local wd = tmp .. "/write"
os.execute("mkdir -p '" .. wd .. "'")
spit(wd .. "/n.md", "old\n")
check("write over existing", true, S.write(wd .. "/n.md", { "id", id = "n1" }, { "new" }))
check("write over existing: content", "---\nid: n1\n---\nnew\n", slurp(wd .. "/n.md"))
check("write leaves no temp file", "n.md", table.concat(ls(wd), ","))
local ok, err = S.write(tmp .. "/missing/dir/n.md", {}, { "x" })
check("write into missing dir fails", nil, ok)
check("write into missing dir gives an error", "string", type(err))
check("missing file read fails", nil, (S.read(tmp .. "/nope.md")))

-- name()
check("name from ISO string", "2026-10-12-091502-3f9a1c2e.md",
  S.name("2026-10-12T09:15:02-07:00", "3f9a1c2e-5b7d-4e8f-9a01-23456789abcd"))
check("name from ISO with space", "2026-10-12-091502-abcdef01.md",
  S.name("2026-10-12 09:15:02", "abcdef0123"))
local t = os.time({ year = 2026, month = 1, day = 2, hour = 3, min = 4, sec = 5 })
check("name from Unix time (local)", "2026-01-02-030405-abcdef01.md", S.name(t, "abcdef0123"))
check("name format", true,
  S.name(os.time(), "deadbeefcafe"):match("^%d%d%d%d%-%d%d%-%d%d%-%d%d%d%d%d%d%-deadbeef%.md$") ~= nil)
check("name rejects bad created", false, (pcall(S.name, "yesterday", "abc")))

os.exit(fail)
