-- Note files: one markdown file per note, the source of truth
-- (GROUND_TRUTHS decision 11). SQLite is only an index rebuilt from these.
--
-- Pure Lua: no hs or vim globals. Parses under LuaJIT and Lua 5.4, so it can
-- be required from nvim (require("voice-vim.store")) or loaded with dofile.
--
-- File format:
--
--   ---
--   id: 3f9a1c2e-...
--   state: sent
--   created: 2026-10-12T09:15:02-07:00
--   target: app:com.mitchellh.ghostty#42
--   ---
--   body line 1
--   body line 2
--
-- Frontmatter counts only when the file's first line is exactly `---`, a
-- later line is exactly `---`, and every line between is `key: value` (key
-- is one word) or a
-- continuation (indented, `- item`, blank or `# comment`) of the key above.
-- Anything else is body. A file without frontmatter reads as state draft.
--
-- Meta is one table: its array part lists the keys in file order, its
-- string keys hold the values.
--
--   meta = { "id", "state", id = "3f9a...", state = "sent" }
--   for _, k in ipairs(meta) do print(k, meta[k]) end
--
-- Values are strings when read. write() also takes numbers and booleans.
-- A key whose YAML this module does not model (a list, a flow collection, a
-- block scalar, a value spanning lines) reads as { raw = { lines } } and is
-- written back verbatim. Keys missing from the array part but set on the
-- table are written after the listed ones. Reading sets defaults through
-- the metatable (meta.state is "draft" when the file has no state); they
-- are not written back, so a file without frontmatter stays without.
--
-- Body lines carry no newline; write() ends every line with "\n".

local M = {}

M.KNOWN = { "id", "state", "created", "updated", "sent", "target", "pinned" }
M.DEFAULTS = { state = "draft" }

local function withDefaults(meta)
  return setmetatable(meta, { __index = M.DEFAULTS })
end

-- Lines of s without newlines. A trailing newline does not start a line.
local function splitLines(s)
  local out = {}
  if s == "" then return out end
  if s:sub(-1) ~= "\n" then s = s .. "\n" end
  for line in s:gmatch("([^\n]*)\n") do out[#out + 1] = line end
  return out
end

---------------------------------------------------------------------------
-- Scalars

local function utf8char(cp)
  if cp < 0x80 then return string.char(cp) end
  if cp < 0x800 then
    return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
  end
  if cp < 0x10000 then
    return string.char(0xE0 + math.floor(cp / 0x1000),
      0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
  end
  return string.char(0xF0 + math.floor(cp / 0x40000),
    0x80 + math.floor(cp / 0x1000) % 0x40,
    0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
end

local SIMPLE_ESC = { ["\\"] = "\\", ['"'] = '"', ["/"] = "/", n = "\n", t = "\t",
  r = "\r", ["0"] = "\0", a = "\a", b = "\b", e = "\27", f = "\f", v = "\v",
  [" "] = " " }
local HEX_LEN = { x = 2, u = 4, U = 8 }

-- Text after the closing quote may only be spaces or a ` # comment`.
local function restOk(rest)
  return rest:match("^%s*$") ~= nil or rest:match("^%s+#") ~= nil
end

local function parseDouble(v)
  local out, i, n = {}, 2, #v
  while i <= n do
    local c = v:sub(i, i)
    if c == '"' then
      if not restOk(v:sub(i + 1)) then return nil end
      return table.concat(out)
    elseif c == "\\" then
      local e = v:sub(i + 1, i + 1)
      if SIMPLE_ESC[e] then
        out[#out + 1] = SIMPLE_ESC[e]; i = i + 2
      elseif HEX_LEN[e] then
        local hex = v:sub(i + 2, i + 1 + HEX_LEN[e])
        if #hex ~= HEX_LEN[e] or not hex:match("^%x+$") then return nil end
        local cp = tonumber(hex, 16)
        out[#out + 1] = e == "x" and string.char(cp) or utf8char(cp)
        i = i + 2 + HEX_LEN[e]
      else
        return nil
      end
    else
      out[#out + 1] = c; i = i + 1
    end
  end
  return nil -- unterminated
end

local function parseSingle(v)
  local out, i, n = {}, 2, #v
  while i <= n do
    local c = v:sub(i, i)
    if c == "'" then
      if v:sub(i + 1, i + 1) == "'" then
        out[#out + 1] = "'"; i = i + 2
      else
        if not restOk(v:sub(i + 1)) then return nil end
        return table.concat(out)
      end
    else
      out[#out + 1] = c; i = i + 1
    end
  end
  return nil
end

-- Decodes the text after `key:`. Returns the string, or nil when the value
-- is YAML this module does not model.
local function parseScalar(v)
  v = v:gsub("^%s+", "")
  local c = v:sub(1, 1)
  if c == '"' then return parseDouble(v) end
  if c == "'" then return parseSingle(v) end
  if c ~= "" and ("[{|>&*!%@`"):find(c, 1, true) then return nil end
  v = v:gsub("%s+#.*$", ""):gsub("%s+$", "")
  return v
end

-- Words YAML would read as null, a YAML 1.1 bool other than true/false, or
-- a number. Those are quoted so they read back as strings everywhere.
-- Plain true and false stay plain on purpose (`pinned: true` is a bool in
-- Obsidian) and still read back here as the strings "true" and "false".
local AMBIGUOUS = {}
for w in ("null Null NULL ~ yes Yes YES no No NO on On ON off Off OFF y Y n N "
  .. "True TRUE False FALSE = .inf .Inf .INF .nan .NaN .NAN"):gmatch("%S+") do
  AMBIGUOUS[w] = true
end

local function looksNumeric(s)
  local t = s:gsub("^[-+]", ""):gsub("_", "")
  if t:match("^%d+$") or t:match("^0x%x+$") or t:match("^0o[0-7]+$")
    or t:match("^0b[01]+$") then return true end
  if t:match("^%d*%.?%d*[eE][-+]?%d+$") and t:match("%d") then return true end
  if t:match("^%d*%.%d*$") and t:match("%d") then return true end
  if t:match("^%d+:[0-5]?%d[:%d]*$") then return true end -- YAML 1.1 base 60
  return false
end

local function needsQuote(s)
  if s == "" or AMBIGUOUS[s] or looksNumeric(s) then return true end
  if s:match("^%s") or s:match("%s$") or s:find("%c") then return true end
  if ("-?:,[]{}#&*!|>'\"%@`"):find(s:sub(1, 1), 1, true) then return true end
  if s:find(": ", 1, true) or s:find(" #", 1, true) or s:sub(-1) == ":" then
    return true
  end
  return false
end

local function quote(s)
  return '"' .. s:gsub('[%c"\\]', function(c)
    if c == '"' then return '\\"' end
    if c == "\\" then return "\\\\" end
    if c == "\n" then return "\\n" end
    if c == "\t" then return "\\t" end
    if c == "\r" then return "\\r" end
    return string.format("\\x%02x", c:byte())
  end) .. '"'
end

-- The YAML text for one value, as it goes after `key: `.
function M.scalar(v)
  local t = type(v)
  if t == "boolean" then return tostring(v) end
  if t == "number" then
    if v == math.floor(v) and v >= -2 ^ 53 and v <= 2 ^ 53 then
      return string.format("%d", v)
    end
    return tostring(v)
  end
  v = tostring(v)
  if needsQuote(v) then return quote(v) end
  return v
end

---------------------------------------------------------------------------
-- Frontmatter

-- Keys are one word ([A-Za-z0-9_.-], starting with a letter, digit or _),
-- so prose like "Note: ..." between two rules stays body.
local function keyLine(line)
  local k, rest = line:match("^([%w_][%w_%-%.]*):(.*)$")
  if not k then return nil end
  if rest ~= "" and not rest:match("^%s") then return nil end -- "a:b" is not a key
  return k, rest
end

local function isContinuation(line)
  return line == "" or line:match("^%s") ~= nil or line:match("^%-%s") ~= nil
    or line == "-" or line:match("^#") ~= nil
end

-- Parses lines[first..last] as frontmatter. Returns meta or nil.
local function parseFront(lines, first, last)
  local groups = {}
  for i = first, last do
    local line = lines[i]
    local k, rest = keyLine(line)
    if k then
      groups[#groups + 1] = { key = k, rest = rest, raw = { line } }
    elseif isContinuation(line) and #groups > 0 then
      local g = groups[#groups]
      g.raw[#g.raw + 1] = line
    else
      return nil
    end
  end
  local meta = {}
  for _, g in ipairs(groups) do
    local v
    if #g.raw == 1 then v = parseScalar(g.rest) end
    if v == nil then v = { raw = g.raw } end
    if meta[g.key] == nil then meta[#meta + 1] = g.key end
    meta[g.key] = v
  end
  return meta
end

-- Parses file text. Returns meta, lines, hasFrontmatter.
function M.parse(text)
  local lines = splitLines(text)
  if lines[1] == "---" then
    for i = 2, #lines do
      if lines[i] == "---" then
        local meta = parseFront(lines, 2, i - 1)
        if meta then
          local body = {}
          for j = i + 1, #lines do body[#body + 1] = lines[j] end
          return withDefaults(meta), body, true
        end
        break
      end
    end
  end
  return withDefaults({}), lines, false
end

-- Keys to write, in order: the listed ones, then keys set on the table
-- but not listed (known keys first, then the rest sorted).
function M.keys(meta)
  local out, seen = {}, {}
  for _, k in ipairs(meta) do
    if not seen[k] and rawget(meta, k) ~= nil then
      seen[k] = true; out[#out + 1] = k
    end
  end
  for _, k in ipairs(M.KNOWN) do
    if not seen[k] and rawget(meta, k) ~= nil then
      seen[k] = true; out[#out + 1] = k
    end
  end
  local extra = {}
  for k in pairs(meta) do
    if type(k) == "string" and not seen[k] then extra[#extra + 1] = k end
  end
  table.sort(extra)
  for _, k in ipairs(extra) do out[#out + 1] = k end
  return out
end

-- Sets a key, listing it after the others when it is new. A nil value
-- removes it.
function M.set(meta, key, value)
  if value ~= nil and rawget(meta, key) == nil then
    local listed = false
    for _, k in ipairs(meta) do if k == key then listed = true; break end end
    if not listed then meta[#meta + 1] = key end
  end
  rawset(meta, key, value)
end

-- File text for meta and body lines.
function M.format(meta, lines)
  local out = {}
  local keys = M.keys(meta or {})
  for _, line in ipairs(lines or {}) do out[#out + 1] = line .. "\n" end
  local body = table.concat(out)
  if #keys == 0 then
    -- No frontmatter, unless the body would read back as frontmatter.
    local _, _, has = M.parse(body)
    if has then return "---\n---\n" .. body end
    return body
  end
  local head = { "---\n" }
  for _, k in ipairs(keys) do
    local v = meta[k]
    if type(v) == "table" and v.raw then
      for _, line in ipairs(v.raw) do head[#head + 1] = line .. "\n" end
    else
      head[#head + 1] = k .. ": " .. M.scalar(v) .. "\n"
    end
  end
  head[#head + 1] = "---\n"
  return table.concat(head) .. body
end

---------------------------------------------------------------------------
-- Files

-- Returns meta, lines; or nil, err.
function M.read(path)
  local f, err = io.open(path, "rb")
  if not f then return nil, err end
  local text = f:read("*a")
  f:close()
  local meta, lines = M.parse(text or "")
  return meta, lines
end

local counter = 0
math.randomseed(os.time() % 2147483647)

-- Writes a temp file next to path, then renames it over path, so a reader
-- never sees half a note. Returns true, or nil, err (no temp file is left).
function M.write(path, meta, lines)
  local dir, base = path:match("^(.*)/([^/]+)$")
  if not dir then dir, base = ".", path end
  counter = counter + 1
  local tmp = string.format("%s/.%s.%d%d.tmp", dir, base, counter,
    math.random(100000000, 999999999))
  local f, err = io.open(tmp, "wb")
  if not f then return nil, err end
  local ok, werr = f:write(M.format(meta, lines))
  local cok, cerr = f:close()
  if not ok or not cok then
    os.remove(tmp)
    return nil, werr or cerr
  end
  local rok, rerr = os.rename(tmp, path)
  if not rok then
    os.remove(tmp)
    return nil, rerr
  end
  return true
end

-- File name for a note: YYYY-MM-DD-HHMMSS-<first 8 of id>.md.
-- created is a Unix time (local time is used) or a string that starts with
-- an ISO 8601 date and time (`2026-10-12T09:15:02-07:00`; its own clock
-- time is used, the offset is ignored).
function M.name(created, id)
  local stamp
  if type(created) == "number" then
    stamp = os.date("%Y-%m-%d-%H%M%S", math.floor(created))
  elseif type(created) == "string" then
    local y, mo, d, h, mi, s =
      created:match("^(%d%d%d%d)-(%d%d)-(%d%d)[T ](%d%d):(%d%d):(%d%d)")
    if y then stamp = string.format("%s-%s-%s-%s%s%s", y, mo, d, h, mi, s) end
  end
  if not stamp then error("store.name: bad created: " .. tostring(created), 2) end
  local short = tostring(id or ""):gsub("[^%w_-]", ""):sub(1, 8)
  if short == "" then error("store.name: bad id: " .. tostring(id), 2) end
  return stamp .. "-" .. short .. ".md"
end

return M
