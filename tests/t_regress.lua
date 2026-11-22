local S = dofile("suite.lua")
local results = {}
local function run(label, o)
  local env = S.build(o)
  S.session(env, o)
  local snap = S.snapshot(env)
  local key = S.coreKey(snap)
  results[#results+1] = { label = label, snap = snap, key = key, env = env }
  return snap, key, env
end

local base = {dir="baseline", compat=false, assets=true, mods={}}
local _, baseKey, baseEnv = run("original", base)
print("BASELINE (original, assets present): errors=" .. #baseEnv.errs())
for _, e in ipairs(baseEnv.errs()) do print("   " .. (e:match("[^\n]+") or e)) end
print("  conversations: " .. #results[1].snap.convos .. ", unread: " .. table.concat(results[1].snap.unread, ","))

local configs = {
  { "patched, no Compat",             {dir="..", compat=false, assets=true, mods={}} },
  { "patched + Compat, no mods",      {dir="..", compat=true,  assets=true, mods={}} },
  { "  + ClassicAPI",                 {dir="..", compat=true,  assets=true, mods={classic=true}} },
  { "  + UnitXP",                     {dir="..", compat=true,  assets=true, mods={xp3=true}} },
  { "  + Nampower",                   {dir="..", compat=true,  assets=true, mods={nampower=true}} },
  { "  + SuperWoW",                   {dir="..", compat=true,  assets=true, mods={superwow=true}} },
  { "  + WeirdUtils",                 {dir="..", compat=true,  assets=true, mods={weird=true}} },
  { "  + ALL mods",                   {dir="..", compat=true,  assets=true, mods={classic=true,xp3=true,nampower=true,superwow=true,weird=true}} },
  { "  ALL mods, assets MISSING",     {dir="..", compat=true,  assets=false, mods={classic=true,xp3=true,nampower=true,superwow=true,weird=true}} },
  { "  no mods,  assets MISSING",     {dir="..", compat=true,  assets=false, mods={}} },
}
local fail = 0
print(string.format("\n%-34s %-7s %-12s %s", "configuration", "errors", "core state", "who sends"))
for _, c in ipairs(configs) do
  local snap, key, env = run(c[1], c[2])
  local same = (key == baseKey)
  if not same or snap.errors > 0 then fail = fail + 1 end
  print(string.format("%-34s %-7d %-12s %d", c[1], snap.errors, same and "IDENTICAL" or "DIFFERS", snap.whoSends))
  if snap.errors > 0 then for _, e in ipairs(env.errs()) do print("      ! " .. (e:match("[^\n]+") or e)) end end
  if not same then print("--- expected:\n" .. baseKey .. "\n--- got:\n" .. key) end
end
print(fail == 0 and "\nREGRESSION: PASS (core conversations/unread identical to original in all configurations)" or ("\nREGRESSION: " .. fail .. " FAILURE(S)"))
os.exit(fail == 0 and 0 or 1)
