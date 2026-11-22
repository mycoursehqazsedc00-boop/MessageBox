local H = dofile("harness.lua")
local S = {}

local PLAYERS = {
  { name="Alice", guild="Foo",  level=60, race="Human",  class="Mage",    zone="Org", classToken="MAGE",    guid="0x0000000000000A01" },
  { name="Bob",   guild="",     level=42, race="Orc",    class="Rogue",   zone="IF",  classToken="ROGUE",   guid="0x0000000000000A02" },
  { name="Carol", guild="Bar",  level=55, race="Dwarf",  class="Warrior", zone="UC",  classToken="WARRIOR", guid="0x0000000000000A03" },
}
S.PLAYERS = PLAYERS

-- opts: dir, compat(bool), assets(bool), mods{}, locale, profile, preseed{}, friends{}
function S.build(o)
  local env = H.newEnv{
    missingFolders = (o.assets == false) and { img=true, font=true, sound=true } or nil,
    mods = o.mods or {}, locale = o.locale, whoProfile = o.profile,
  }
  local files = {}
  for _, f in ipairs(env.tocFiles(o.dir)) do
    if not (f == "Compat.lua" and o.compat == false) then files[#files+1] = f end
  end
  env.loadAddon(o.dir, files)
  local g = env.env
  g.MessageBoxDB = o.db or {}
  g.MessageBoxSettings = o.settings or {}
  env.setPlayers(o.players or PLAYERS)
  env.setGuids(o.players or PLAYERS)
  if o.friends then env.setFriends(o.friends) end
  return env
end

-- Core whisper session (identical input for every configuration)
function S.session(env, o)
  o = o or {}
  env.fire("PLAYER_LOGIN")
  env.whisper("Alice", "hello there", "0x0000000000000A01")
  env.whisper("Bob", "ping", "0x0000000000000A02")
  env.whisperOut("Alice", "hi!", "0x0000000000000A01")
  env.whisper("Gm_Zed", "Hello, this is a GM", nil, "GM")
  env.whisper("Carol", "lfg?", "0x0000000000000A03")
  env.fire("CHAT_MSG_AFK", "brb", "Bob")
  env.fire("CHAT_MSG_SYSTEM", "No player named 'Dave' is currently playing.")
  env.whisperOut("Dave", "are you there", nil)
  env.fire("CHAT_MSG_SYSTEM", "No player named 'Dave' is currently playing.")
  env.slash("/mbox", "")        -- open
  env.run(40, 1)
  env.slash("/mbox", "queue")
  env.slash("/mbox", "")        -- close
  env.run(80, 1)
  env.slash("/mbox", "")        -- open again
  env.run(60, 1)
end

function S.snapshot(env)
  local g = env.env
  local MB = g.MessageBox
  local snap = { convos = {}, unread = {}, errors = #env.errs() }
  local names = {}
  for n in pairs(MB.conversations) do names[#names+1] = n end
  table.sort(names)
  for _, n in ipairs(names) do
    local c = MB.conversations[n]
    local parts = {}
    for i = 1, (c.count or #c.messages) do
      parts[#parts+1] = (c.outgoing[i] and ">" or "<") .. (c.system[i] and "S" or "M") .. ":" .. c.messages[i]
    end
    snap.convos[#snap.convos+1] = n .. "=" .. table.concat(parts, " | ")
  end
  local un = {}
  for n, v in pairs(MB.unreadCounts or {}) do un[#un+1] = n .. ":" .. v end
  table.sort(un); snap.unread = un
  local pc = {}
  for n, v in pairs(MB.playerCache) do
    pc[#pc+1] = n .. "{" .. tostring(v.class) .. "/" .. tostring(v.classUpper) .. "/g=" .. tostring(v.guild) .. "/gm=" .. tostring(v.isGM) .. "}"
  end
  table.sort(pc); snap.players = pc
  local sent = {}
  for _, s in ipairs(env.state.whoSends) do sent[#sent+1] = s.q end
  snap.whoSends = #sent
  return snap
end

function S.coreKey(snap)
  return table.concat(snap.convos, "\n") .. "\nUNREAD " .. table.concat(snap.unread, ",")
end

function S.summarize(env)
  local errs = env.errs()
  return #errs
end

return S
