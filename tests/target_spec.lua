-- Tests for lua/ferry/target.lua (pure Lua, no vim or hs globals).
-- Run: luajit tests/target_spec.lua  (or nvim -l tests/target_spec.lua)
local here = debug.getinfo(1, "S").source:sub(2):match("^(.*)/[^/]+$") or "."
local T = dofile(here .. "/../lua/ferry/target.lua")

local fail = 0
local function check(name, want, got)
  if want == got then
    print("ok   " .. name)
  else
    print("FAIL " .. name .. ": want '" .. tostring(want) .. "' got '" .. tostring(got) .. "'")
    fail = 1
  end
end

local function lines(t) return table.concat(t, "|") .. " (" .. #t .. ")" end

-- Round trips: parse then render gives the spec back.
local fields = { "kind", "bundle", "window", "server", "pane", "id" }
local function roundTrip(spec, want)
  local t, err = T.parse(spec)
  check("parse " .. spec, nil, err)
  if not t then return end
  for _, f in ipairs(fields) do
    check("parse " .. spec .. " ." .. f, want[f], t[f])
  end
  check("render " .. spec, spec, T.render(t))
end
roundTrip("app:com.tinyspeck.slackmacgap#4242",
  { kind = "app", bundle = "com.tinyspeck.slackmacgap", window = 4242 })
roundTrip("app:com.x", { kind = "app", bundle = "com.x" })
roundTrip("clipboard", { kind = "clipboard" })
roundTrip("tmux:default:%12", { kind = "tmux", server = "default", pane = "%12" })
roundTrip("tmux:ferry-test:%3", { kind = "tmux", server = "ferry-test", pane = "%3" })
roundTrip("fleet:task:jpX", { kind = "fleet", id = "task:jpX" })
roundTrip("editor:COMMIT_EDITMSG", { kind = "editor", name = "COMMIT_EDITMSG" })
roundTrip("editor:my notes: v2.md", { kind = "editor", name = "my notes: v2.md" })

-- Legacy history rows: a bare bundle id is an app target.
local t = T.parse("com.example.app")
check("legacy com.example.app kind", "app", t and t.kind)
check("legacy com.example.app bundle", "com.example.app", t and t.bundle)
check("legacy com.example.app renders", "app:com.example.app", t and T.render(t))
check("whitespace trimmed", "clipboard", (T.parse("  clipboard  ") or {}).kind)

-- Bad specs: nil plus an error message.
for _, spec in ipairs({ "app:", "app:x#abc", "app:x#", "tmux:", "tmux:s:",
                        "tmux::%1", "foo:bar", "fleet:", "clipboard:x", "app",
                        "editor:", "editor",
                        "", "   ", "nodot" }) do
  local r, err = T.parse(spec)
  check("reject '" .. spec .. "'", "nil+err",
    (r == nil and type(err) == "string") and "nil+err" or tostring(r))
end
check("reject non-string", nil, (T.parse(nil)))
check("reject editor name with a line break", nil, (T.parse("editor:a\nb")))

-- Kinds live in a table; render/label refuse unknown kinds.
check("kinds table", "table", type(T.kinds.tmux))
check("render unknown kind errors", false, (pcall(T.render, { kind = "nope" })))

-- Labels.
check("label app+window", "com.x (window 7)", T.label(T.parse("app:com.x#7")))
check("label app", "com.x", T.label(T.parse("app:com.x")))
check("label clipboard", "clipboard", T.label(T.parse("clipboard")))
check("label tmux default", "tmux %12", T.label(T.parse("tmux:default:%12")))
check("label tmux server", "tmux ferry-test %3", T.label(T.parse("tmux:ferry-test:%3")))
check("label fleet", "fleet task:jpX", T.label(T.parse("fleet:task:jpX")))
check("label editor", "editor COMMIT_EDITMSG", T.label(T.parse("editor:COMMIT_EDITMSG")))

-- split / join between buffer lines and (spec, body).
local spec, body = T.split({ "to: clipboard", "hi" })
check("split header spec", "clipboard", spec)
check("split header body", "hi (1)", lines(body))
spec, body = T.split({ "hello" })
check("split no header spec", nil, spec)
check("split no header body", "hello (1)", lines(body))
spec, body = T.split({})
check("split empty spec", nil, spec)
check("split empty body", " (0)", lines(body))
spec, body = T.split({ "to:   tmux:default:%1  ", "a", "", "b" })
check("split trims spec", "tmux:default:%1", spec)
check("split keeps blank body lines", "a||b (3)", lines(body))
check("split only line 1 is a header", nil, (T.split({ "x", "to: clipboard" })))
check("split header is lowercase to:", nil, (T.split({ "To: clipboard" })))

check("join with spec", "to: clipboard|hi (2)", lines(T.join("clipboard", { "hi" })))
check("join without spec", "hello (1)", lines(T.join(nil, { "hello" })))
for _, ls in ipairs({ { "to: clipboard", "hi" }, { "hello" },
                      { "to: fleet:task:jpX", "a", "", "b" }, { "to: app:com.x#1" }, {} }) do
  local s, b = T.split(ls)
  check("join inverts split " .. lines(ls), lines(ls), lines(T.join(s, b)))
end
local orig = { "keep" }
local _, b2 = T.split(orig)
b2[1] = "changed"
check("split copies body", "keep", orig[1])

if fail ~= 0 then os.exit(1) end
print("all target tests passed")
