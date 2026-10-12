local S = dofile("suite.lua")
local pass, fail = 0, 0
local function check(name, cond, detail)
  if cond then pass = pass + 1; print("  PASS  " .. name)
  else fail = fail + 1; print("  FAIL  " .. name .. (detail and ("   -> " .. tostring(detail)) or "")) end
end
local function B(o) o.dir = o.dir or ".."; if o.compat == nil then o.compat = true end; if o.assets == nil then o.assets = true end; return S.build(o) end
local function last(env) return env.chat() end
local function chatHas(env, s)
  for _, l in ipairs(env.chat()) do if string.find(l, s, 1, true) then return true end end
  return false
end

print("F1  ClassicAPI: instant class/race from chat GUID (no /who yet)")
do
  local e = B{ mods={classic=true} }
  e.fire("PLAYER_LOGIN")
  e.whisper("Alice", "hi", "0x0000000000000A01")
  local c = e.env.MessageBox.playerCache.Alice
  check("class+token resolved on the whisper event", c and c.class == "Mage" and c.classUpper == "MAGE", c and c.class)
  check("race stored", c and c.race == "Human")
  check("persisted into settings.classCache", e.env.MessageBox.settings.classCache.Alice and e.env.MessageBox.settings.classCache.Alice.classUpper == "MAGE")
  check("C_PlayerCache enabled + player remembered", e.state.pcache.enabled and e.state.pcache.byName.Alice ~= nil)
  check("guild still pending (/who still fills guild/zone)", c.guild == nil)
  local o = S.build{ dir="baseline", compat=false, mods={classic=true} }
  o.fire("PLAYER_LOGIN"); o.whisper("Alice", "hi", "0x0000000000000A01")
  check("control: original has NO class at that moment", o.env.MessageBox.playerCache.Alice == nil or o.env.MessageBox.playerCache.Alice.class == nil)
end

print("F2  Visible-unit resolution (vanilla API, no mods needed)")
do
  local e = B{ mods={} }
  e.state.units.target = { name="Bob", class="Rogue", classToken="ROGUE", race="Orc", level=42, guid="0x0000000000000A02" }
  e.fire("PLAYER_LOGIN"); e.whisper("Bob", "yo", nil)
  local c = e.env.MessageBox.playerCache.Bob
  check("class from current target", c and c.classUpper == "ROGUE")
  check("level from target", c and c.level == 42)
  local e2 = B{ mods={} }; e2.fire("PLAYER_LOGIN"); e2.whisper("Bob", "yo", nil)
  check("control: not a target -> unresolved", not (e2.env.MessageBox.playerCache.Bob and e2.env.MessageBox.playerCache.Bob.class))
end

print("F3  Persistent name-cache fallback (no chat GUID on the event)")
do
  local e = B{ mods={classic=true} }
  e.fire("PLAYER_LOGIN")
  e.whisper("Carol", "a", "0x0000000000000A03")            -- remembers Carol
  e.env.MessageBox.playerCache.Carol = nil                  -- simulate fresh session cache
  e.env.MessageBox.settings.classCache.Carol = nil
  e.whisper("Carol", "b", nil)                              -- event carries no GUID
  local c = e.env.MessageBox.playerCache.Carol
  check("resolved via C_PlayerCache.GetPlayerInfoByName", c and c.classUpper == "WARRIOR")
end

print("F4  Safety: GUID belonging to a different character is rejected")
do
  local e = B{ mods={classic=true} }
  e.fire("PLAYER_LOGIN")
  e.whisper("Bob", "x", "0x0000000000000A01")               -- Alice's guid on Bob's whisper
  local c = e.env.MessageBox.playerCache.Bob
  check("Bob NOT coloured as Alice's class", not (c and c.class))
end

print("F5  ClassicAPI silent /who + friends-panel suppression")
do
  local e = B{ mods={classic=true} }
  local called = 0
  e.env.FriendsFrame_OnEvent = function() called = called + 1 end
  e.fire("PLAYER_LOGIN")
  e.whisper("Alice", "hi", "0x0000000000000A01")
  e.run(35, 1)
  local viaClassic = false
  for _, s in ipairs(e.state.whoSends) do if s.classic then viaClassic = true end end
  check("who sent through C_FriendList.SendWhoQueryByName", viaClassic)
  e.env.event = "WHO_LIST_UPDATE"
  local t0 = e.env.MessageBox.compat.who.lastSendAt
  e.state.now = t0 + 1; e.env.FriendsFrame_OnEvent()
  check("panel popup suppressed right after our query", called == 0, called)
  e.state.now = t0 + 20; e.env.FriendsFrame_OnEvent()
  check("user-issued /who later still reaches FriendsFrame", called == 1, called)
end

print("F6  UnitXP: taskbar flash (+ optional OS sound)")
do
  local e = B{ mods={xp3=true} }
  e.fire("PLAYER_LOGIN"); e.whisper("Alice", "hi", nil)
  check("detected via pcall success flag (UnitXP('nop') returns nothing)", e.env.MessageBox.compat.hasUnitXP == true)
  check("taskbarIcon fired", #e.state.xpCalls == 1 and e.state.xpCalls[1][2] == "taskbarIcon")
  e.slash("/mbox", "xp sound"); e.whisper("Alice", "again", nil)
  check("systemSound only after opting in", #e.state.xpCalls == 3 and e.state.xpCalls[3][2] == "systemSound", #e.state.xpCalls)
  e.whisperOut("Alice", "out", nil)
  check("outgoing whispers don't flash", #e.state.xpCalls == 3)
  local n = B{ mods={} }; n.fire("PLAYER_LOGIN"); n.whisper("Alice", "hi", nil)
  check("no UnitXP -> no error", #n.errs() == 0)
end

print("F7  Nampower: whisper bubbles are opt-in and non-destructive")
do
  local e = B{ mods={nampower=true} }
  e.fire("PLAYER_LOGIN")
  check("default: CVar untouched", e.state.cvars.NP_ChatBubblesWhisper == nil)
  e.slash("/mbox", "bubbles on")
  check("on -> NP_ChatBubblesWhisper=1", e.state.cvars.NP_ChatBubblesWhisper == "1")
  e.slash("/mbox", "bubbles off")
  check("off -> restored to 0 (we set it)", e.state.cvars.NP_ChatBubblesWhisper == "0")
  local u = B{ mods={nampower=true} }
  u.state.cvars.NP_ChatBubblesWhisper = "1"                  -- user already enabled it themselves
  u.fire("PLAYER_LOGIN"); u.slash("/mbox", "bubbles off")
  check("never clobbers a user-set CVar", u.state.cvars.NP_ChatBubblesWhisper == "1")
end

print("F8  WeirdUtils: /mbox log needs the logsessions module")
do
  local e = B{ mods={weird=true} }; e.fire("PLAYER_LOGIN"); e.slash("/mbox", "log")
  check("prints chat log path", chatHas(e, "WoWChatLog_2026_10_11.txt"))
  local n = B{ mods={} }; n.fire("PLAYER_LOGIN"); n.slash("/mbox", "log")
  check("graceful message without it", chatHas(n, "logsessions"))
end

print("F9  Locale: class colour token on a non-English client (deDE)")
do
  local de = {
    { name="Alice", guild="Foo", level=60, race="Mensch", class="Magier", zone="Org", classToken="MAGE", guid="0x0000000000000A01" },
  }
  local function go(dir, compat)
    local e = S.build{ dir=dir, compat=compat, locale="deDE", mods={}, players=de }
    e.state.units.player = { name="Tester", class="Magier", classToken="MAGE", race="Mensch", level=60, guid="0x1" }
    e.fire("PLAYER_LOGIN"); e.whisper("Alice", "hi", nil); e.run(40, 1)
    return e.env.MessageBox.playerCache.Alice
  end
  local o = go("baseline", false)
  check("control: original stores classUpper='" .. tostring(o and o.classUpper) .. "' (no RAID_CLASS_COLORS match)", o and o.classUpper == "MAGIER")
  local m = go("..", true)
  check("patched stores engine token", m and m.classUpper == "MAGE", m and m.classUpper)
end

print("F10 Fault isolation: a Compat/mod failure never loses a whisper")
do
  local e = B{ mods={classic=true} }
  e.fire("PLAYER_LOGIN")
  e.env.GetPlayerInfoByGUID = function() error("boom from client mod") end
  e.slash("/mbox", "trace on")
  e.whisper("Alice", "must survive", "0x0000000000000A01")
  local c = e.env.MessageBox.conversations.Alice
  check("message still stored", c and c.messages[1] == "must survive")
  check("no error escaped to the UI", #e.errs() == 0, e.errs()[1])
  check("failure recorded in trace", (e.env.MessageBox.compat.errors or 0) >= 1)
end

print("F11 Slash commands: new verbs work, stock verbs untouched")
do
  local e = B{ mods={classic=true,xp3=true} }
  e.fire("PLAYER_LOGIN")
  e.whisper("Alice", "hi", "0x0000000000000A01")
  e.slash("/mbox", "mods");  check("/mbox mods lists detected mods", chatHas(e, "ClassicAPI") and chatHas(e, "UnitXP_SP3"))
  e.slash("/mbox", "who");   check("/mbox who prints status", chatHas(e, "/who interval"))
  e.slash("/mbox", "queue"); check("stock /mbox queue still works", chatHas(e, "WHO Queue") or chatHas(e, "WHO in progress") or chatHas(e, "empty"))
  e.slash("/mbox", "who 20"); check("/mbox who 20 pins interval", e.env.MessageBox.WHO_INTERVAL == 20 and e.env.MessageBox.compat:Get("whoAdaptive") == false)
  e.slash("/mbox", "who reset"); check("/mbox who reset restores stock", e.env.MessageBox.WHO_INTERVAL == 30)
  e.slash("/mbox", "")
  check("bare /mbox still toggles the window", e.env.MessageBox.frame and e.env.MessageBox.frame:IsVisible())
end

print("F12 whoSkipIfClassKnown (opt-in): no /who for contacts whose class is known")
do
  local e = B{ mods={classic=true} }
  e.fire("PLAYER_LOGIN"); e.slash("/mbox", "who skip")
  e.whisper("Alice", "hi", "0x0000000000000A01"); e.run(60, 1)
  check("zero /who sent", #e.state.whoSends == 0, #e.state.whoSends)
  check("contact still coloured", e.env.MessageBox.playerCache.Alice.classUpper == "MAGE")
end

local function roster(n)
  local pl = {}
  for i = 1, n do pl[i] = { name="P"..i, guild="G", level=60, race="Orc", class="Mage", zone="Z", classToken="MAGE", guid=string.format("0x%016X", 100+i) } end
  return pl
end
local function resolvedCount(env, n)
  local k = 0
  for i = 1, n do local c = env.env.MessageBox.playerCache["P"..i]; if c and c.class and c.guild ~= nil then k = k + 1 end end
  return k
end

print("F13 Slow realm (reply 14s > stock timeout 10s): late replies are recognised, harvested, penalty undone")
do
  local e = B{ mods={}, players=roster(6), profile={minGap=0, latency=14, dropMode="silent"} }
  e.fire("PLAYER_LOGIN")
  for i = 1, 6 do e.whisper("P"..i, "hi", nil) end
  e.run(500, 1)
  local MB = e.env.MessageBox
  check("all 6 contacts resolved", resolvedCount(e, 6) == 6, resolvedCount(e, 6))
  check("timeout raised above the slow reply time", MB.WHO_TIMEOUT > 14, MB.WHO_TIMEOUT)
  check("interval not left penalised (<= stock 30s)", MB.WHO_INTERVAL <= 30, MB.WHO_INTERVAL)
  check("late replies harvested: exactly 1 /who per contact (no re-query)", #e.state.whoSends == 6, #e.state.whoSends)
  local o = S.build{ dir="baseline", compat=false, mods={}, players=roster(6), profile={minGap=0, latency=14, dropMode="silent"} }
  o.fire("PLAYER_LOGIN"); for i = 1, 6 do o.whisper("P"..i, "hi", nil) end; o.run(500, 1)
  check("control: stock resolves none of them", resolvedCount(o, 6) == 0, resolvedCount(o, 6))
end

print("F14 Realm throttling stricter than stock (40s): adaptive converges, stock keeps getting dropped")
do
  local e = B{ mods={}, players=roster(6), profile={minGap=40, latency=0.3, dropMode="silent"} }
  e.fire("PLAYER_LOGIN")
  for i = 1, 6 do e.whisper("P"..i, "hi", nil) end
  e.run(1200, 1)
  check("all 6 resolved", resolvedCount(e, 6) == 6, resolvedCount(e, 6))
  check("few wasted queries (<= 3)", e.state.whoDropped <= 3, e.state.whoDropped)
  check("interval learned >= 40s", e.env.MessageBox.WHO_INTERVAL >= 40, e.env.MessageBox.WHO_INTERVAL)
  local o = S.build{ dir="baseline", compat=false, mods={}, players=roster(6), profile={minGap=40, latency=0.3, dropMode="silent"} }
  o.fire("PLAYER_LOGIN"); for i = 1, 6 do o.whisper("P"..i, "hi", nil) end; o.run(1200, 1)
  check("control: stock wastes more queries (" .. o.state.whoDropped .. " dropped)", o.state.whoDropped > e.state.whoDropped)
end

print("F15 Learned interval persists in saved variables; global SendWho restored after silent /who")
do
  local e = B{ mods={classic=true}, players=roster(3), profile={minGap=0, latency=0.3, dropMode="silent"} }
  local sw0 = e.env.SendWho
  e.fire("PLAYER_LOGIN")
  for i = 1, 3 do e.whisper("P"..i, "hi", nil) end
  e.run(200, 1)
  check("SendWho global restored", e.env.SendWho == sw0)
  local saved = e.env.MessageBoxSettings.compat and e.env.MessageBoxSettings.compat.whoInterval
  check("learned interval stored in MessageBoxSettings.compat", saved ~= nil and saved < 30, saved)
  local e2 = S.build{ dir="..", compat=true, mods={}, settings=e.env.MessageBoxSettings, players=roster(3) }
  e2.fire("PLAYER_LOGIN")
  check("next session starts from the learned interval", e2.env.MessageBox.WHO_INTERVAL == saved, e2.env.MessageBox.WHO_INTERVAL)
end

print("F16 Known GMs (persisted gmList) are never resolved or looked up, even without the GM flag")
do
  local pl = roster(1)
  pl[2] = { name="Gm_Zed", guild="", level=60, race="Human", class="Mage", zone="Z", classToken="MAGE", guid="0x0000000000000AFF" }
  local e = B{ mods={classic=true}, players=pl, settings={ gmList = { Gm_Zed = true } } }
  e.fire("PLAYER_LOGIN")
  e.whisper("Gm_Zed", "hello", "0x0000000000000AFF")
  local c = e.env.MessageBox.playerCache.Gm_Zed
  check("flagged GM stays flagged", c and c.isGM == true)
  check("no class resolved for a GM", not (c and c.class))
  e.run(60, 1)
  check("no /who sent for a GM", #e.state.whoSends == 0, #e.state.whoSends)
end

print(string.format("\nFEATURES: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
