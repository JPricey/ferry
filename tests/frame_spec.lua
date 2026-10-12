-- Tests for lua/ferry/frame.lua.
-- Run: luajit tests/frame_spec.lua  (or nvim -l tests/frame_spec.lua)
local here = debug.getinfo(1, "S").source:sub(2):match("^(.*)/[^/]+$") or "."
local F = dofile(here .. "/../lua/ferry/frame.lua")

local fail = 0
local function check(name, want, got)
  if want == got then
    print("ok   " .. name)
  else
    print("FAIL " .. name .. ": want '" .. tostring(want) .. "' got '" .. tostring(got) .. "'")
    fail = 1
  end
end

-- "{x,y,w,h}" with integer formatting, or "nil"; non-integers show as such.
local function s(f)
  if f == nil then return "nil" end
  local parts = {}
  for _, k in ipairs({ "x", "y", "w", "h" }) do
    local v = f[k]
    if type(v) == "number" and v == math.floor(v) then
      parts[#parts + 1] = string.format("%d", v)
    else
      parts[#parts + 1] = "?" .. tostring(v)
    end
  end
  return "{" .. table.concat(parts, ",") .. "}"
end
local function r(x, y, w, h) return { x = x, y = y, w = w, h = h } end
local function both(f, why) return s(f) .. " " .. tostring(why) end

local main = r(0, 25, 1440, 875)
local second = r(1440, 0, 1920, 1080)
local screens = { main, second }

-- default
check("default on {0,25,1440,875} is {360,244,720,438}", "{360,244,720,438}", s(F.default(main, 0.5)))
check("default with no fraction uses 0.5", "{360,244,720,438}", s(F.default(main)))
check("default with bad fraction uses 0.5", "{360,244,720,438}", s(F.default(main, 7)))
check("default fraction 1 fills the screen", "{0,25,1440,875}", s(F.default(main, 1)))
check("default on nil screen is nil", "nil", s(F.default(nil, 0.5)))

-- onScreen
check("onScreen: frame on second screen", second, F.onScreen(r(2000, 100, 800, 600), screens))
check("onScreen: frame on main screen", main, F.onScreen(r(100, 100, 800, 600), screens))
check("onScreen: frame on a gone screen", nil, F.onScreen(r(-3000, 100, 800, 600), screens))
check("onScreen: garbage frame", nil, F.onScreen("x", screens))

-- clamp
check("clamp: fitting frame unchanged", "{100,100,800,600}", s(F.clamp(r(100, 100, 800, 600), main)))
check("clamp: overhanging frame moved in", "{640,300,800,600}", s(F.clamp(r(1000, 700, 800, 600), main)))
check("clamp: oversized frame shrunk to screen", "{0,25,1440,875}", s(F.clamp(r(-50, 0, 3000, 2000), main)))
check("clamp: fractional input rounded", "{101,100,800,600}", s(F.clamp(r(100.6, 100.2, 800.4, 599.5), main)))

-- restore
check("restore: saved on second of two screens comes back unchanged as restored",
  "{2000,100,800,600} restored", both(F.restore(r(2000, 100, 800, 600), screens, main, 0.5)))
check("restore: saved on main comes back unchanged as restored",
  "{100,100,800,600} restored", both(F.restore(r(100, 100, 800, 600), screens, main, 0.5)))
check("restore: saved on a gone screen is centred on main, size kept, as moved",
  "{320,163,800,600} moved", both(F.restore(r(2000, 100, 800, 600), { main }, main, 0.5)))
check("restore: 3000x2000 saved on a gone screen is shrunk to main as moved",
  "{0,25,1440,875} moved", both(F.restore(r(5000, 0, 3000, 2000), { main }, main, 0.5)))
check("restore: 3000x2000 saved centred on main is shrunk to main as restored",
  "{0,25,1440,875} restored", both(F.restore(r(-780, -550, 3000, 2000), { main }, main, 0.5)))
check("restore: nil gives default", "{360,244,720,438} default", both(F.restore(nil, screens, main, 0.5)))
check("restore: string gives default", "{360,244,720,438} default", both(F.restore("garbage", screens, main, 0.5)))
check("restore: non-numeric fields give default", "{360,244,720,438} default",
  both(F.restore({ x = "1", y = 2, w = 800, h = 600 }, screens, main, 0.5)))
check("restore: NaN gives default", "{360,244,720,438} default",
  both(F.restore(r(0 / 0, 100, 800, 600), screens, main, 0.5)))
check("restore: missing field gives default", "{360,244,720,438} default",
  both(F.restore({ x = 1, y = 2, w = 800 }, screens, main, 0.5)))
check("restore: tiny width (w<200) gives default", "{360,244,720,438} default",
  both(F.restore(r(100, 100, 199, 600), screens, main, 0.5)))
check("restore: tiny height (h<100) gives default", "{360,244,720,438} default",
  both(F.restore(r(100, 100, 800, 99), screens, main, 0.5)))
check("restore: no main uses screens[1]", "{360,244,720,438} default", both(F.restore(nil, screens, nil, 0.5)))
check("restore: no screens at all gives nil", "nil default", both(F.restore(nil, {}, nil, 0.5)))

os.exit(fail)
