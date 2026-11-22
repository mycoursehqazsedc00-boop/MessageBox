local S = dofile("suite.lua")
local N = 40
local CL = { {"Mage","MAGE"},{"Rogue","ROGUE"},{"Warrior","WARRIOR"},{"Priest","PRIEST"},{"Druid","DRUID"} }
local function players()
  local t = {}
  for i = 1, N do
    local c = CL[((i - 1) % #CL) + 1]
    t[i] = { name = "Player" .. i, guild = "G" .. (i % 7), level = 20 + i, race = "Human", class = c[1], zone = "Z", classToken = c[2], guid = string.format("0x%016X", 5000 + i) }
  end
  return t
end

local profiles = {
  { "permissive realm      (no limit, 0.3s)",        { minGap = 0,  latency = 0.3,  dropMode = "silent" } },
  { "throttled 12s, silent drop",                    { minGap = 12, latency = 0.3,  dropMode = "silent" } },
  { "throttled 25s, silent drop",                    { minGap = 25, latency = 0.3,  dropMode = "silent" } },
  { "throttled 40s, silent drop",                    { minGap = 40, latency = 0.3,  dropMode = "silent" } },
  { "throttled 25s, stale re-delivery",              { minGap = 25, latency = 0.3,  dropMode = "stale"  } },
  { "slow realm (replies after 14s)",                { minGap = 0,  latency = 14,   dropMode = "silent" } },
  { "strict 20s (any attempt resets lockout)",       { minGap = 20, latency = 0.3,  dropMode = "silent", strict = true } },
}
local variants = {
  { "stock",              { dir="baseline", compat=false, mods={} } },
  { "adaptive",           { dir="..",   compat=true,  mods={} } },
  { "adaptive+ClassicAPI",{ dir="..",   compat=true,  mods={classic=true} } },
}
local DURATION = 2400

local function run(variant, prof)
  local o = {}
  for k, v in pairs(variant[2]) do o[k] = v end
  o.profile = prof[2]; o.players = players(); o.assets = true
  local env = S.build(o)
  env.fire("PLAYER_LOGIN")
  local MB = env.env.MessageBox
  for i, p in ipairs(o.players) do
    env.whisper(p.name, "hi", p.guid)
  end
  local t50, t100, tc100
  for sec = 1, DURATION do
    env.tick(1)
    local done = 0
    for i = 1, N do
      local c = MB.playerCache["Player" .. i]
      if c and c.class and c.guild ~= nil then done = done + 1 end
    end
    local cls = 0
    for i = 1, N do local c = MB.playerCache["Player" .. i]; if c and c.class then cls = cls + 1 end end
    if not tc100 and cls >= N then tc100 = sec end
    if not t50 and done >= N / 2 then t50 = sec end
    if not t100 and done >= N then t100 = sec end
  end
  local done, classOnly = 0, 0
  for i = 1, N do
    local c = MB.playerCache["Player" .. i]
    if c and c.class and c.guild ~= nil then done = done + 1 elseif c and c.class then classOnly = classOnly + 1 end
  end
  return { done = done, classOnly = classOnly, sends = #env.state.whoSends, dropped = env.state.whoDropped,
           accepted = env.state.whoAccepted, t50 = t50, t100 = t100, tc100 = tc100, errors = #env.errs(),
           interval = MB.WHO_INTERVAL, timeout = MB.WHO_TIMEOUT }
end

print(string.format("%d contacts whisper at t=0; %ds simulated. 'resolved' = class+guild known.\n", N, DURATION))
local totals = {}
for _, prof in ipairs(profiles) do
  print(prof[1])
  print(string.format("   %-20s %-9s %-10s %-9s %-9s %-10s %-6s %-8s %s", "variant", "resolved", "class-only", "t(50%)", "t(100%)", "all-class", "sent", "dropped", "final int/timeout"))
  for _, v in ipairs(variants) do
    local r = run(v, prof)
    print(string.format("   %-20s %-9s %-10d %-9s %-9s %-10s %-6d %-8d %.0fs/%.0fs%s", v[1], r.done .. "/" .. N, r.classOnly,
      r.t50 and (r.t50 .. "s") or "never", r.t100 and (r.t100 .. "s") or "never", r.tc100 and (r.tc100 .. "s") or "never", r.sends, r.dropped, r.interval, r.timeout,
      r.errors > 0 and ("  ERRORS=" .. r.errors) or ""))
  end
  print()
end
