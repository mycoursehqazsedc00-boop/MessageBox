local S = dofile("suite.lua")
local H_STEPS = tonumber(arg[1]) or 6000
local combos = {
  { "no mods",   {} },
  { "classic",   {classic=true} },
  { "xp3+np",    {xp3=true, nampower=true} },
  { "ALL",       {classic=true, xp3=true, nampower=true, superwow=true, weird=true} },
}
local profiles = {
  { minGap=0,  latency=0.3, dropMode="silent" },
  { minGap=20, latency=0.3, dropMode="silent" },
  { minGap=25, latency=0.3, dropMode="stale"  },
  { minGap=0,  latency=13,  dropMode="silent" },
}
local totalFail = 0
for ci, combo in ipairs(combos) do
  local seed = 1000 + ci
  math.randomseed(seed)
  local roster = {}
  for i = 1, 60 do roster[i] = { name="Soak"..i, guild="G"..(i%5), level=10+i, race="Orc", class="Mage", zone="Z", classToken="MAGE", guid=string.format("0x%016X", 9000+i), online = (i % 7 ~= 0) } end
  local env = S.build{ dir="..", compat=true, assets=(ci % 2 == 1), mods=combo[2], players=roster, profile=profiles[1] }
  local sendWho0 = env.env.SendWho
  env.fire("PLAYER_LOGIN")
  local MB = env.env.MessageBox
  local C = MB.compat
  local violations = {}
  local function inv(cond, msg) if not cond then violations[#violations+1] = msg end end
  local cmds = { "", "queue", "who", "who auto", "who 15", "who reset", "who skip", "mods", "trace on", "trace off", "xp flash", "bubbles on", "bubbles off", "log", "help", "clear" }
  local sentMsgs = 0
  for step = 1, H_STEPS do
    local r = math.random(100)
    local p = roster[math.random(#roster)]
    if r <= 30 then
      env.whisper(p.name, "m" .. step, p.guid); sentMsgs = sentMsgs + 1
    elseif r <= 40 then
      env.whisperOut(p.name, "o" .. step, p.guid)
    elseif r <= 44 then
      env.whisper("GmX" .. math.random(3), "gm" .. step, nil, "GM")
    elseif r <= 50 then
      env.slash("/mbox", cmds[math.random(#cmds)])
    elseif r <= 54 then
      env.setProfile(profiles[math.random(#profiles)])
    elseif r <= 57 then
      env.fire("CHAT_MSG_SYSTEM", "No player named '" .. p.name .. "' is currently playing.")
    elseif r <= 59 then
      env.fire("CHAT_MSG_AFK", "afk", p.name)
    elseif r <= 61 then
      env.state.units.target = (math.random(2) == 1) and { name=p.name, class="Mage", classToken="MAGE", race="Orc", level=p.level, guid=p.guid } or nil
    else
      env.tick(math.random(1, 4))
    end
    -- invariants
    local wi, wt = MB.WHO_INTERVAL, MB.WHO_TIMEOUT
    inv(wi and wi >= 1 and wi <= 150, "interval out of range: " .. tostring(wi))
    inv(wt and wt >= 10 and wt <= 45, "timeout out of range: " .. tostring(wt))
    inv(#MB.whoQueue <= MB.WHO_QUEUE_MAX, "who queue overflow: " .. #MB.whoQueue)
    if #violations > 0 then break end
  end
  local errs = env.errs()
  for name, c in pairs(MB.conversations) do
    inv((c.count or 0) == #c.messages and #c.messages == #c.times and #c.messages == #c.outgoing and #c.messages == #c.system, "convo arrays desync for " .. name)
  end
  inv(env.env.SendWho == sendWho0, "global SendWho was not restored after Compat swap")
  local st = C.who.stats
  local ok = (#errs == 0) and (#violations == 0)
  if not ok then totalFail = totalFail + 1 end
  print(string.format("%-9s steps=%d  errors=%d  invariant violations=%d  | whisper-convos=%d  who sent=%d ok=%d dropped=%d stale=%d late=%d  | compat internal errors=%s  %s",
    combo[1], H_STEPS, #errs, #violations, (function() local n=0 for _ in pairs(MB.conversations) do n=n+1 end return n end)(),
    st.sent, st.ok, st.dropped, st.stale, st.late, tostring(C.errors or 0), ok and "PASS" or "FAIL"))
  for _, v in ipairs(violations) do print("    ! " .. v) end
  for i = 1, math.min(3, #errs) do print("    ! " .. (errs[i]:match("[^\n]+") or errs[i])) end
end
print(totalFail == 0 and "SOAK: PASS" or "SOAK: FAIL")
os.exit(totalFail == 0 and 0 or 1)
