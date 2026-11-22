local S = dofile("suite.lua")
local function dump(env, title)
  print("### " .. title)
  for _, l in ipairs(env.env.MessageBox.compat.traceBuf) do print("  " .. l) end
  print()
end

-- 1. resolver paths
do
  local e = S.build{ dir="..", compat=true, mods={classic=true}, profile={minGap=0,latency=0.3,dropMode="silent"} }
  e.fire("PLAYER_LOGIN"); e.slash("/mbox", "trace on")
  e.state.units.target = { name="Bob", class="Rogue", classToken="ROGUE", race="Orc", level=42, guid="0x0000000000000A02" }
  e.whisper("Bob",   "yo",  "0x0000000000000A02")      -- visible unit wins (free, no GUID lookup needed)
  e.whisper("Alice", "hi",  "0x0000000000000A01")      -- chat GUID
  e.env.MessageBox.playerCache.Alice = nil; e.env.MessageBox.settings.classCache.Alice = nil
  e.whisper("Alice", "hi2", nil)                       -- no GUID -> persistent name cache
  e.whisper("Stranger", "hey", nil)                    -- nothing known
  e.whisper("Alice", "again", "0x0000000000000A01")    -- already cached
  e.whisper("Gm_Zed", "gm", nil, "GM")                 -- GM: never resolved/queried
  dump(e, "1. resolver paths (ClassicAPI present)")
end

-- 2. adaptation on a 25s-throttled realm
do
  local pl = {}
  for i = 1, 8 do pl[i] = { name="P"..i, guild="G", level=60, race="Orc", class="Mage", zone="Z", classToken="MAGE", guid=string.format("0x%016X", 100+i) } end
  local e = S.build{ dir="..", compat=true, mods={}, players=pl, profile={minGap=25,latency=0.3,dropMode="silent"} }
  e.fire("PLAYER_LOGIN"); e.slash("/mbox", "trace on")
  for i = 1, 8 do e.whisper("P"..i, "hi", nil) end
  e.run(420, 1)
  dump(e, "2. adaptation on a realm that drops /who closer than 25s")
end

-- 3. slow realm: timeout vs late reply
do
  local pl = {}
  for i = 1, 4 do pl[i] = { name="P"..i, guild="G", level=60, race="Orc", class="Mage", zone="Z", classToken="MAGE", guid=string.format("0x%016X", 100+i) } end
  local e = S.build{ dir="..", compat=true, mods={}, players=pl, profile={minGap=0,latency=14,dropMode="silent"} }
  e.fire("PLAYER_LOGIN"); e.slash("/mbox", "trace on")
  for i = 1, 4 do e.whisper("P"..i, "hi", nil) end
  e.run(200, 1)
  dump(e, "3. slow realm (replies after 14s, stock timeout 10s)")
  e.slash("/mbox", "who")
end
