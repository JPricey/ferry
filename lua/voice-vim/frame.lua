-- Pure window-frame logic: the default frame, whether a saved frame is still
-- on a screen, and fitting a frame onto a screen.
--
-- No hs or vim globals. Frames and screens are plain tables {x,y,w,h} in
-- screen points, so the logic runs under LuaJIT tests and under Hammerspoon
-- (Lua 5.4, loaded with dofile). All returned frames hold integers.

local M = {}

M.DEFAULT_FRACTION = 0.5
M.MIN_W = 200 -- saved frames narrower than this are ignored
M.MIN_H = 100 -- saved frames shorter than this are ignored

local function round(v) return math.floor(v + 0.5) end

local function finite(v)
  return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

-- A table with finite numeric x, y, w, h, and w, h > 0.
local function isRect(r)
  return type(r) == "table" and finite(r.x) and finite(r.y)
    and finite(r.w) and finite(r.h) and r.w > 0 and r.h > 0
end

local function fraction(f)
  if finite(f) and f > 0 and f <= 1 then return f end
  return M.DEFAULT_FRACTION
end

-- Centred on screen, `fraction` (0 < f <= 1, default 0.5) of its width and
-- height.
function M.default(screen, frac)
  if not isRect(screen) then return nil end
  frac = fraction(frac)
  local w, h = round(screen.w * frac), round(screen.h * frac)
  return {
    x = round(screen.x + (screen.w - w) / 2),
    y = round(screen.y + (screen.h - h) / 2),
    w = w,
    h = h,
  }
end

-- The first screen that contains the centre of f, or nil.
function M.onScreen(f, screens)
  if not isRect(f) or type(screens) ~= "table" then return nil end
  local cx, cy = f.x + f.w / 2, f.y + f.h / 2
  for _, s in ipairs(screens) do
    if isRect(s) and cx >= s.x and cx < s.x + s.w and cy >= s.y and cy < s.y + s.h then
      return s
    end
  end
  return nil
end

-- f shrunk to fit screen if it is larger, then moved the least distance so
-- it lies wholly on screen.
function M.clamp(f, screen)
  if not isRect(f) or not isRect(screen) then return nil end
  local sx, sy, sw, sh = round(screen.x), round(screen.y), round(screen.w), round(screen.h)
  local w, h = math.min(round(f.w), sw), math.min(round(f.h), sh)
  local x = math.max(sx, math.min(round(f.x), sx + sw - w))
  local y = math.max(sy, math.min(round(f.y), sy + sh - h))
  return { x = x, y = y, w = w, h = h }
end

-- The frame to open with, and why:
--   "restored"  saved is usable and its centre is on a screen (fitted to it)
--   "moved"     saved is usable but on no screen: same size (shrunk if it
--               does not fit), centred on main
--   "default"   nothing usable saved: M.default(main, frac)
-- main defaults to screens[1]. Returns nil, "default" with no usable screen.
function M.restore(saved, screens, main, frac)
  if type(screens) ~= "table" then screens = {} end
  if not isRect(main) then main = screens[1] end
  if not isRect(main) then return nil, "default" end
  if not isRect(saved) or saved.w < M.MIN_W or saved.h < M.MIN_H then
    return M.default(main, frac), "default"
  end
  local s = M.onScreen(saved, screens)
  if s then return M.clamp(saved, s), "restored" end
  local w, h = math.min(round(saved.w), round(main.w)), math.min(round(saved.h), round(main.h))
  return M.clamp({
    x = main.x + (main.w - w) / 2,
    y = main.y + (main.h - h) / 2,
    w = w,
    h = h,
  }, main), "moved"
end

return M
