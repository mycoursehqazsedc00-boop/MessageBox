-- Reproduces the reported crash and proves the fix.
-- Original code + missing img/font folders must raise exactly:
--   UI.lua:786  attempt to index a nil value            (bell button, GetNormalTexture() == nil)
--   UI.lua:1117 SetText(): Font not set                 (friends list, OpenSans.ttf failed to load)
-- Patched code must be clean whether the assets are present or not.
local S = dofile("suite.lua")

local function case(dir, compat, assets)
  local env = S.build{
    dir = dir, compat = compat, assets = assets, mods = {},
    settings = { popupNotificationsEnabled = false },      -- reporter's saved state
    friends = { {name="Carol",level=60,class="Mage",area="Org",online=true},
                {name="Dave",level=45,class="Rogue",area="IF",online=false} },
  }
  local out = { steps = {} }
  local function step(label, fn)
    env.clearErrs(); fn()
    local e = {}
    for _, x in ipairs(env.errs()) do e[#e+1] = (x:match("[^\n]+") or x) end
    out.steps[#out.steps+1] = { label = label, errs = e }
  end
  step("login",      function() env.fire("PLAYER_LOGIN") end)
  step("whispers",   function() env.whisper("Alice","hello"); env.whisper("Bob","ping"); env.whisperOut("Alice","hi!") end)
  step("toggle #1",  function() env.slash("/mbox","") end)
  step("toggle #2",  function() env.slash("/mbox","") end)
  step("toggle #3",  function() env.slash("/mbox","") end)
  return out
end

local pass, fail = 0, 0
local function check(name, cond, detail)
  if cond then pass = pass + 1; print("  PASS  " .. name)
  else fail = fail + 1; print("  FAIL  " .. name .. (detail and ("  -> " .. tostring(detail)) or "")) end
end
local function errsOf(o, label) for _, s in ipairs(o.steps) do if s.label == label then return s.errs end end end

print("original, assets MISSING (the reported install)")
local o = case("baseline", false, false)
local t1, t2 = errsOf(o, "toggle #1"), errsOf(o, "toggle #2")
check("toggle #1 -> UI.lua:786 attempt to index a nil value", t1[1] and t1[1]:find("UI.lua:786: attempt to index a nil value", 1, true), t1[1])
check("toggle #2 -> UI.lua:1117 Font not set",              t2[1] and t2[1]:find("UI.lua:1117: <unnamed>:SetText(): Font not set", 1, true), t2[1])

local function clean(o2) for _, s in ipairs(o2.steps) do if #s.errs > 0 then return false, s.label .. ": " .. s.errs[1] end end return true end
print("original, assets present (control)");        check("no errors", clean(case("baseline", false, true)))
print("patched, assets MISSING");                   check("no errors", clean(case("..", false, false)))
print("patched, assets present");                   check("no errors", clean(case("..", false, true)))
print("patched + Compat, assets MISSING");          check("no errors", clean(case("..", true, false)))
print("patched + Compat, assets present");          check("no errors", clean(case("..", true, true)))

print(string.format("\nREPRO: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
