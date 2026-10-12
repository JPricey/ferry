-- tmux delivery and pane listing. Runs inside nvim (uses vim.system); no
-- Hammerspoon involved. Targets are parsed target tables from
-- lua/voice-vim/target.lua: { kind = "tmux", server, pane }, where server
-- `default` means tmux's default socket (no `-L`).
--
--   send(t, text, { enter = bool }) -> true | false, err
--     checks the pane exists, loads the text into a uniquely named tmux
--     buffer (stdin, trailing newlines dropped), pastes it with
--     `paste-buffer -p -d` (bracketed paste when the app asked for it, buffer
--     deleted afterwards) and, with enter, sends one Enter.
--   list(servers) -> { { spec, label, claude, server, pane }, ... }
--     every pane on the given servers (default: servers()), Claude Code
--     panes (current command `claude`) first. Label:
--     `session:win.pane · title · cwd basename`.
--   servers() -> list from VOICE_VIM_TMUX_SERVERS (comma-separated),
--     default { "default" }.
local target = require("voice-vim.target")

local M = {}

M.timeout_ms = 2000

-- tmux binary: PATH first, then Homebrew (nvim started by Hammerspoon may
-- have a bare PATH). Looked up on every call so a PATH change is seen.
M.fallbacks = { "/opt/homebrew/bin/tmux", "/usr/local/bin/tmux" }
function M.find()
  local p = vim.fn.exepath("tmux")
  if p ~= "" then return p end
  for _, f in ipairs(M.fallbacks) do
    if vim.fn.executable(f) == 1 then return f end
  end
  return nil
end

function M.servers()
  local env = vim.env.VOICE_VIM_TMUX_SERVERS
  local out = {}
  for s in (env or ""):gmatch("[^,]+") do
    s = vim.trim(s)
    if s ~= "" then out[#out + 1] = s end
  end
  if #out == 0 then out = { "default" } end
  return out
end

-- run(server, args, stdin) -> true, stdout | false, err
local function run(server, args, stdin)
  local bin = M.find()
  if not bin then return false, "tmux: not found" end
  local argv = { bin }
  if server ~= "default" then
    argv[#argv + 1] = "-L"
    argv[#argv + 1] = server
  end
  vim.list_extend(argv, args)
  local ok, obj = pcall(vim.system, argv, { text = true, stdin = stdin or false, timeout = M.timeout_ms })
  if not ok then return false, "tmux " .. args[1] .. ": " .. tostring(obj) end
  local r = obj:wait()
  if r.code == 124 or (r.signal and r.signal ~= 0) then
    return false, "tmux " .. args[1] .. ": timed out"
  end
  if r.code ~= 0 then
    local msg = vim.trim(r.stderr or "")
    if msg == "" then msg = "exit " .. tostring(r.code) end
    return false, "tmux " .. args[1] .. ": " .. msg
  end
  return true, r.stdout or ""
end

local function as_target(t)
  if type(t) == "string" then
    local p, err = target.parse(t)
    if not p then return nil, err end
    t = p
  end
  if type(t) ~= "table" or t.kind ~= "tmux" then
    return nil, "tmux: not a tmux target"
  end
  return t
end

local seeded = false
local function buffer_name()
  if not seeded then
    math.randomseed(vim.uv.hrtime() % 2147483647 + vim.uv.os_getpid())
    seeded = true
  end
  return string.format("voicevim-%d-%06d", vim.uv.os_getpid(), math.random(0, 999999))
end

function M.send(t, text, opts)
  local err
  t, err = as_target(t)
  if not t then return false, err end
  opts = opts or {}
  if type(text) == "table" then text = table.concat(text, "\n") end
  text = tostring(text or ""):gsub("\n+$", "")

  local ok, out = run(t.server, { "display-message", "-p", "-t", t.pane, "#{pane_id}" })
  if not ok then return false, out end
  -- tmux 3.5 answers an unknown %N with exit 0 and no output.
  local id = vim.trim(out)
  if id == "" or (t.pane:match("^%%%d+$") and id ~= t.pane) then
    return false, "tmux: no pane " .. t.pane
  end

  local buf = buffer_name()
  ok, out = run(t.server, { "load-buffer", "-b", buf, "-" }, text)
  if not ok then return false, out end
  ok, out = run(t.server, { "paste-buffer", "-p", "-d", "-b", buf, "-t", t.pane })
  if not ok then
    run(t.server, { "delete-buffer", "-b", buf })
    return false, out
  end
  if opts.enter then
    ok, out = run(t.server, { "send-keys", "-t", t.pane, "Enter" })
    if not ok then return false, out end
  end
  return true
end

local FORMAT = table.concat({
  "#{pane_id}", "#{session_name}:#{window_index}.#{pane_index}",
  "#{pane_title}", "#{pane_current_path}", "#{pane_current_command}",
}, "\t")

function M.list(servers)
  servers = servers or M.servers()
  local items = {}
  for _, server in ipairs(servers) do
    local ok, out = run(server, { "list-panes", "-a", "-F", FORMAT })
    if ok then
      for line in out:gmatch("[^\n]+") do
        local f = vim.split(line, "\t", { plain = true })
        local pane, where, title, cwd, cmd = f[1], f[2], f[3] or "", f[4] or "", f[5] or ""
        if pane and pane ~= "" then
          local parts = { where }
          if title ~= "" then parts[#parts + 1] = title end
          local base = vim.fs.basename(cwd)
          if base and base ~= "" then parts[#parts + 1] = base end
          local t = { kind = "tmux", server = server, pane = pane }
          items[#items + 1] = {
            spec = target.render(t),
            label = table.concat(parts, " · "),
            claude = cmd == "claude",
            server = server,
            pane = pane,
          }
        end
      end
    end
  end
  -- Claude Code panes first; otherwise keep tmux's order.
  for i, it in ipairs(items) do it.order = i end
  table.sort(items, function(a, b)
    if a.claude ~= b.claude then return a.claude end
    return a.order < b.order
  end)
  for _, it in ipairs(items) do it.order = nil end
  return items
end

return M
