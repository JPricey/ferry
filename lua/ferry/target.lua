-- Target specs: where a note is sent. Pure Lua, no `vim` or `hs` globals,
-- so it loads under LuaJIT, `nvim -l` and Hammerspoon's Lua 5.4.
--
-- Grammar (one spec per line, surrounding whitespace ignored):
--
--   app:<bundle>[#<windowId>]   app + window; windowId is digits
--                               e.g. app:com.tinyspeck.slackmacgap#4242
--   clipboard                   clipboard only
--   tmux:<server>:<pane>        tmux pane; server `default` means no `-L`;
--                               pane is a tmux target, normally %N, and is
--                               everything after the second colon
--                               e.g. tmux:default:%12, tmux:ferry-test:%3
--   fleet:<id>                  fleet session or task; id is everything
--                               after `fleet:` and may contain colons
--                               e.g. fleet:task:jpX -> id task:jpX
--   editor:<name>               a finished $EDITOR edit (lua/ferry/edit.lua)
--                               of a file with basename <name> (spaces
--                               and colons allowed); only recorded in
--                               note files, nothing delivers to it
--                               e.g. editor:COMMIT_EDITMSG
--   <bundle>                    legacy history rows: a bare bundle id (no
--                               colon, at least one dot) parses as app
--
-- Parsed form: { kind = "app"|"clipboard"|"tmux"|"fleet"|"editor", bundle,
-- window (number), server, pane, id, name }. Only the fields of that kind
-- are set.
--
-- In the buffer, line 1 `to: <spec>` is the header and the rest is the
-- body (`split` / `join`). The note file keeps the spec in its frontmatter
-- under `target:`, which is store.lua's job, not this module's.

local M = {}

local function nonblank(s)
  return s ~= nil and s ~= "" and not s:find("%s")
end

-- One entry per kind. `bare` kinds are the kind word alone (no colon).
-- parse(rest) -> t | nil, err; render(t) -> spec; label(t) -> text.
M.kinds = {
  app = {
    parse = function(rest)
      local bundle, win = rest:match("^([^#]*)#(.*)$")
      if not bundle then bundle = rest end
      if not nonblank(bundle) then return nil, "app: missing bundle id" end
      local t = { kind = "app", bundle = bundle }
      if win then
        if not win:match("^%d+$") then
          return nil, "app: window id must be a number, got '" .. win .. "'"
        end
        t.window = tonumber(win)
      end
      return t
    end,
    render = function(t)
      if t.window then return "app:" .. t.bundle .. "#" .. tostring(t.window) end
      return "app:" .. t.bundle
    end,
    label = function(t)
      if t.window then return t.bundle .. " (window " .. tostring(t.window) .. ")" end
      return t.bundle
    end,
  },
  clipboard = {
    bare = true,
    render = function() return "clipboard" end,
    label = function() return "clipboard" end,
  },
  tmux = {
    parse = function(rest)
      local server, pane = rest:match("^([^:]*):(.*)$")
      if not server or not nonblank(server) then return nil, "tmux: missing server" end
      if not nonblank(pane) then return nil, "tmux: missing pane" end
      return { kind = "tmux", server = server, pane = pane }
    end,
    render = function(t) return "tmux:" .. t.server .. ":" .. t.pane end,
    label = function(t)
      if t.server == "default" then return "tmux " .. t.pane end
      return "tmux " .. t.server .. " " .. t.pane
    end,
  },
  fleet = {
    parse = function(rest)
      if not nonblank(rest) then return nil, "fleet: missing id" end
      return { kind = "fleet", id = rest }
    end,
    render = function(t) return "fleet:" .. t.id end,
    label = function(t) return "fleet " .. t.id end,
  },
  editor = {
    parse = function(rest)
      if rest == "" then return nil, "editor: missing file name" end
      if rest:find("[\r\n]") then return nil, "editor: file name has a line break" end
      return { kind = "editor", name = rest }
    end,
    render = function(t) return "editor:" .. t.name end,
    label = function(t) return "editor " .. t.name end,
  },
}

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- parse(spec) -> target table, or nil, err.
function M.parse(spec)
  if type(spec) ~= "string" then return nil, "target: not a string" end
  spec = trim(spec)
  if spec == "" then return nil, "target: empty" end
  local name, rest = spec:match("^([%a][%w_-]*):(.*)$")
  if name then
    local kind = M.kinds[name]
    if not kind then return nil, "target: unknown kind '" .. name .. "'" end
    if kind.bare then return nil, name .. ": takes no argument" end
    return kind.parse(rest)
  end
  local kind = M.kinds[spec]
  if kind then
    if kind.bare then return { kind = spec } end
    return nil, spec .. ": missing argument"
  end
  -- Legacy history rows hold a bare bundle id.
  if not spec:find(":", 1, true) and spec:match("^[%w_-]+%.[^%s]+$") then
    return M.kinds.app.parse(spec)
  end
  return nil, "target: cannot parse '" .. spec .. "'"
end

local function kindOf(t)
  local kind = type(t) == "table" and M.kinds[t.kind]
  if not kind then error("target: unknown kind '" .. tostring(type(t) == "table" and t.kind) .. "'", 3) end
  return kind
end

-- render(t) -> spec string. Inverse of parse.
function M.render(t)
  return kindOf(t).render(t)
end

-- label(t) -> fallback human label (when no app/window title is known).
function M.label(t)
  return kindOf(t).label(t)
end

-- split(lines) -> spec | nil, body. Line 1 `to: <spec>` is the header; the
-- spec is returned trimmed and unvalidated (it may be half-typed), so
-- callers run parse on it. Without a header, all lines are the body.
function M.split(lines)
  local first = lines[1]
  local spec = type(first) == "string" and first:match("^to:(.*)$")
  local body, from = {}, 1
  if spec then spec, from = trim(spec), 2 else spec = nil end
  for i = from, #lines do body[#body + 1] = lines[i] end
  return spec, body
end

-- join(spec, body) -> lines. Inverse of split: `to: <spec>` then the body.
function M.join(spec, body)
  local lines = {}
  if spec then lines[1] = "to: " .. spec end
  for i = 1, #body do lines[#lines + 1] = body[i] end
  return lines
end

return M
