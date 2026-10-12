-- Compat.lua
-- Client-mod integration layer for MessageBox.
--   ClassicAPI, UnitXP_SP3, Nampower, SuperWoW, WeirdUtils (all optional)
--   + adaptive /who throttle learning, locale-correct class tokens, tracing.
--
-- Load order: LAST in the .toc (after MessageBox.lua).
--
-- Design rules
--   1. Purely additive. Wraps a few MessageBox functions (same manual-hook
--      pattern Logic.lua uses) and writes only into the cache fields the stock
--      /who handler already writes (playerCache / settings.classCache).
--   2. Never breaks core. Every Compat code path that runs inside a core event
--      or function is pcall-guarded; a Compat bug logs to the trace buffer and
--      the original behaviour continues.
--   3. Lua 5.0 only (WoW 1.12): no '#', no '...', no string.match/select.

MessageBox.compat = MessageBox.compat or {}
local C = MessageBox.compat
C.VERSION = "1.1.0"

------------------------------------------------------------------------
-- 0. Settings, trace, small helpers
------------------------------------------------------------------------

C.defaults = {
	whoAdaptive      = true,   -- learn the server's /who throttle
	whoInterval      = nil,    -- learned/pinned interval (nil = stock value)
	whoTimeout       = nil,    -- learned timeout (nil = stock value)
	whoIntervalMin   = 10,     -- conservative floor (server drops CMSG_WHO at ~5s granularity; pin lower with /mbox who <s>)
	whoIntervalMax   = 150,
	whoTimeoutMax    = 45,
	whoSkipIfClassKnown = false,
	classicSilentWho = true,   -- ClassicAPI: route /who silently, suppress friends popup
	xpFlash          = true,   -- UnitXP: flash taskbar on whisper (background only)
	xpSystemSound    = false,  -- UnitXP: OS sound on whisper (off: addon already has a sound)
	npWhisperBubbles = false,  -- Nampower: chat bubbles for whispers (opt-in)
}

function C:Get(key)
	local s = MessageBox.settings
	if s and s.compat and s.compat[key] ~= nil then return s.compat[key] end
	if C.pending and C.pending[key] ~= nil then return C.pending[key] end
	return C.defaults[key]
end

function C:Set(key, value)
	local s = MessageBox.settings
	if s then
		if not s.compat then s.compat = {} end
		s.compat[key] = value
	else
		if not C.pending then C.pending = {} end
		C.pending[key] = value
	end
end

function C:Say(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cff3cb7f0Message|rBox: " .. msg)
end

C.traceOn = false
C.traceEcho = false
C.traceBuf = {}
function C:T(tag, msg)
	if not C.traceOn then return end
	local line = string.format("%.1f %s %s", GetTime(), tag, tostring(msg))
	if table.getn(C.traceBuf) >= 200 then table.remove(C.traceBuf, 1) end
	table.insert(C.traceBuf, line)
	if C.traceEcho then DEFAULT_CHAT_FRAME:AddMessage("|cff808080[mb] " .. line .. "|r") end
end

-- Run fn(a, b) guarded; a Compat bug must never take core logic down with it.
function C:Safe(tag, fn, a, b)
	local ok, err = pcall(fn, a, b)
	if not ok then
		C.errors = (C.errors or 0) + 1
		C.lastError = tostring(err)
		C:T("ERR", tag .. ": " .. tostring(err))
	end
	return ok
end

------------------------------------------------------------------------
-- 1. Detection (re-run at login: some mods only expose state after login)
------------------------------------------------------------------------

function C:Detect()
	C.hasClassicAPI = (type(GetCurrentChatGUID) == "function" and type(GetPlayerInfoByGUID) == "function")

	-- UnitXP_SP3 wiki: "local xp3 = pcall(UnitXP, "nop", "nop")" -> TRUE if it exists.
	-- The pcall success flag is the signal, not the function's own return value.
	C.hasUnitXP = false
	if type(UnitXP) == "function" then
		C.hasUnitXP = (pcall(UnitXP, "nop", "nop")) and true or false
	end

	C.hasNampower = (type(GetUnitGUID) == "function")
		or (type(WriteCustomFile) == "function" and type(ReadCustomFile) == "function")

	C.hasWeirdUtils = (type(GetWeirdUtilsVersion) == "function")
	-- GetChatLogPath() comes from WeirdUtils' logsessions module specifically.
	C.hasWeirdLog = C.hasWeirdUtils and (type(GetChatLogPath) == "function")
		and (GetWeirdUtilsVersion("logsessions") ~= nil)

	C.hasSuperWoW = (SUPERWOW_VERSION ~= nil)
	if not C.hasSuperWoW then
		local _, g = UnitExists("player")
		C.hasSuperWoW = (type(g) == "string")
	end
end

function C:ModList()
	local found = {}
	if C.hasClassicAPI then table.insert(found, "ClassicAPI") end
	if C.hasSuperWoW then table.insert(found, "SuperWoW") end
	if C.hasNampower then table.insert(found, "Nampower") end
	if C.hasUnitXP then table.insert(found, "UnitXP_SP3") end
	if C.hasWeirdLog then table.insert(found, "WeirdUtils(logsessions)") end
	return found
end

-- GUID of a unit token, from whichever mod provides one.
function C:GuidOf(unit)
	if type(UnitGUID) == "function" then
		local g = UnitGUID(unit)
		if g then return g end
	end
	if type(GetUnitGUID) == "function" then
		local g = GetUnitGUID(unit)
		if g then return g end
	end
	if C.hasSuperWoW then
		local _, g = UnitExists(unit)
		if type(g) == "string" then return g end
	end
	return nil
end

------------------------------------------------------------------------
-- 2. Class tokens + shared feeder
--
-- The stock /who handler stores classUpper = string.upper(GetWhoInfo class),
-- but GetWhoInfo returns the LOCALIZED class name, so on non-English clients
-- RAID_CLASS_COLORS[classUpper] never matches and names lose class colour.
-- We learn localized->token pairs from every source that gives both
-- (UnitClass, GetPlayerInfoByGUID) and re-assert the engine token.
------------------------------------------------------------------------

C.tokenByLocalized = {}

function C:LearnClass(localized, token)
	if localized and token then C.tokenByLocalized[localized] = token end
end

function C:TokenFor(localized)
	if not localized then return nil end
	local t = C.tokenByLocalized[localized]
	if t then return t end
	local up = string.upper(localized)
	if RAID_CLASS_COLORS and RAID_CLASS_COLORS[up] then return up end
	return nil
end

function C:NormalizeClass(name)
	local cache = MessageBox.playerCache[name]
	if not (cache and cache.class) then return end
	local tok = C:TokenFor(cache.class)
	if tok and cache.classUpper ~= tok then
		cache.classUpper = tok
		local sc = MessageBox.settings and MessageBox.settings.classCache
		if sc and sc[name] then sc[name].classUpper = tok end
		if C.traceOn then C:T("class", name .. " classUpper -> " .. tok) end
	end
end

-- Same fields, same shape, as Logic.lua:HandleWhoResult() writes.
function C:FeedPlayerInfo(name, localizedClass, englishClass, localizedRace, level)
	if not name or not localizedClass then return end
	C:LearnClass(localizedClass, englishClass)

	if not MessageBox.playerCache[name] then MessageBox.playerCache[name] = {} end
	local cache = MessageBox.playerCache[name]
	cache.class = localizedClass
	cache.classUpper = englishClass or string.upper(localizedClass)
	if localizedRace then cache.race = localizedRace end
	if level then cache.level = level end

	local sc = MessageBox.settings and MessageBox.settings.classCache
	if sc then
		if not sc[name] then sc[name] = {} end
		sc[name].class = cache.class
		sc[name].classUpper = cache.classUpper
		if level and tonumber(level) == 60 then sc[name].level = level end
	end
end

------------------------------------------------------------------------
-- 3. Instant contact resolution (no /who needed)
--      a) visible unit  (target/mouseover/party/raid)  - vanilla API, free
--      b) ClassicAPI GetCurrentChatGUID -> GetPlayerInfoByGUID
--      c) ClassicAPI persistent name cache
------------------------------------------------------------------------

function C:TryVisibleUnit(name)
	local units = { "target", "mouseover", "party1", "party2", "party3", "party4" }
	local nraid = GetNumRaidMembers() or 0
	for i = 1, nraid do table.insert(units, "raid" .. i) end

	for _, unit in ipairs(units) do
		if UnitExists(unit) and UnitName(unit) == name then
			local locClass, engClass = UnitClass(unit)
			if engClass then
				local locRace = UnitRace(unit)
				local level = UnitLevel(unit)
				if level and level < 1 then level = nil end -- skull / unknown
				C:FeedPlayerInfo(name, locClass, engClass, locRace, level)
				if C.hasClassicAPI and C_PlayerCache and C_PlayerCache.RememberPlayer then
					local guid = C:GuidOf(unit)
					if guid then C_PlayerCache.RememberPlayer(guid, name, engClass) end
				end
				return unit
			end
		end
	end
	return nil
end

function C:TryGuid(name)
	if not C.hasClassicAPI then return nil end

	-- GetCurrentChatGUID() is only valid synchronously inside the CHAT_MSG_*
	-- dispatch; MessageBox:OnEvent wrapper below calls us from exactly there.
	local guid = GetCurrentChatGUID()
	if guid then
		local locClass, engClass, locRace, _, _, gname = GetPlayerInfoByGUID(guid)
		-- Guard: only trust it if the GUID really belongs to this contact.
		if engClass and (gname == nil or gname == name) then
			C:FeedPlayerInfo(name, locClass, engClass, locRace, nil)
			if C_PlayerCache and C_PlayerCache.RememberPlayer then
				C_PlayerCache.RememberPlayer(guid, name, engClass)
			end
			return "guid"
		end
	end

	if C_PlayerCache and C_PlayerCache.GetPlayerInfoByName then
		local locClass, engClass, locRace = C_PlayerCache.GetPlayerInfoByName(name)
		if engClass then
			C:FeedPlayerInfo(name, locClass, engClass, locRace, nil)
			return "name-cache"
		end
	end
	return nil
end

function C:ResolveContact(name)
	local cache = MessageBox.playerCache[name]
	if cache and cache.isGM then return "gm" end
	if cache and cache.class then
		C:NormalizeClass(name)
		return "cached"
	end
	local via = C:TryVisibleUnit(name)
	if via then return "unit:" .. via end
	via = C:TryGuid(name)
	if via then return via end
	return "none"
end

------------------------------------------------------------------------
-- 4. Adaptive /who throttle
--
-- Servers rate-limit /who differently and there is no API to ask. The stock
-- 30s interval / 10s timeout is too aggressive on throttled realms (queries
-- dropped, retries burned, contact never resolves), too slow on quiet ones,
-- and a fixed 10s timeout discards correct-but-slow answers.
--
-- AIMD controller steering MessageBox.WHO_INTERVAL / WHO_TIMEOUT, which the
-- stock scheduler re-reads every tick:
--   timeout  -> server dropped it        : interval x1.5 (x2 after 3 in a row)
--   stale    -> same non-empty result,   : interval x1.5 (server ignored us)
--               target absent
--   late     -> the "timed out" query was actually answered later: undo the
--               penalty, raise TIMEOUT instead, and harvest the late data
--   success  -> 2 clean in a row         : interval x0.85, never below the
--               last interval that got us dropped (floor, expires in 30 min)
------------------------------------------------------------------------

C.who = {
	lastSig = nil, lastSendAt = 0, timedOut = nil,
	drops = 0, ok = 0, floor = nil, floorAt = 0,
	prevInterval = nil, prevFloor = nil,
	stats = { sent = 0, ok = 0, dropped = 0, stale = 0, late = 0 },
}

function C:BaseInterval() return C.baseInterval or 30 end
function C:BaseTimeout() return C.baseTimeout or 10 end

function C:Apply()
	MessageBox.WHO_INTERVAL = C:Get("whoInterval") or C:BaseInterval()
	MessageBox.WHO_TIMEOUT = C:Get("whoTimeout") or C:BaseTimeout()
end

function C:CurInterval() return C:Get("whoInterval") or C:BaseInterval() end
function C:CurTimeout() return C:Get("whoTimeout") or C:BaseTimeout() end

function C:WhoSignature()
	local n = GetNumWhoResults()
	if n == 0 then return "0" end
	local parts = { tostring(n) }
	for i = 1, n do
		local name, guild, level = GetWhoInfo(i)
		table.insert(parts, tostring(name) .. ":" .. tostring(level) .. ":" .. tostring(guild))
	end
	return table.concat(parts, "|")
end

function C:ResultsContain(lower)
	if not lower then return false end
	for i = 1, GetNumWhoResults() do
		local name = GetWhoInfo(i)
		if name and string.lower(name) == lower then return true end
	end
	return false
end

function C:OnWhoDropped(reason)
	local w = C.who
	if reason == "stale" then w.stats.stale = w.stats.stale + 1 else w.stats.dropped = w.stats.dropped + 1 end
	w.drops = w.drops + 1
	w.ok = 0
	if not C:Get("whoAdaptive") then return end

	local cur = C:CurInterval()
	w.prevInterval = cur
	w.prevFloor = w.floor
	local factor = 1.5
	if w.drops >= 3 then factor = 2.0 end
	local nxt = math.min(cur * factor, C:Get("whoIntervalMax"))
	w.floor = math.min(cur * 1.1, C:Get("whoIntervalMax"))
	w.floorAt = GetTime()
	C:Set("whoInterval", nxt)
	C:Apply()
	if C.traceOn then C:T("who", string.format("%s: interval %.1f -> %.1f (floor %.1f)", reason, cur, nxt, w.floor)) end
end

function C:OnWhoLate(latency)
	local w = C.who
	w.stats.late = w.stats.late + 1
	w.drops = 0
	-- The earlier "drop" was a slow answer, not a throttle: undo that penalty.
	if C:Get("whoAdaptive") then
		if w.prevInterval then C:Set("whoInterval", w.prevInterval) end
		w.floor = w.prevFloor
		local want = math.min(latency * 1.5, C:Get("whoTimeoutMax"))
		if want > C:CurTimeout() then C:Set("whoTimeout", want) end
		C:Apply()
	end
	if C.traceOn then C:T("who", string.format("late reply %.1fs: timeout=%.1f interval=%.1f", latency, C:CurTimeout(), C:CurInterval())) end
end

function C:OnWhoSuccess(latency)
	local w = C.who
	w.stats.ok = w.stats.ok + 1
	w.ok = w.ok + 1
	w.drops = 0
	if not C:Get("whoAdaptive") then return end
	if w.ok < 2 then return end
	w.ok = 0

	local floor = C:Get("whoIntervalMin")
	if w.floor then
		if (GetTime() - w.floorAt) < 1800 then
			if w.floor > floor then floor = w.floor end
		else
			w.floor = nil
		end
	end
	local cur = C:CurInterval()
	local nxt = cur * 0.85
	if nxt < floor then nxt = floor end
	if nxt > cur then nxt = cur end
	if nxt ~= cur then
		C:Set("whoInterval", nxt)
		C:Apply()
		if C.traceOn then C:T("who", string.format("healthy: interval %.1f -> %.1f", cur, nxt)) end
	end
end

------------------------------------------------------------------------
-- 5. Wrappers (installed once)
------------------------------------------------------------------------

-- 5a. AddToWhoQueue: optional "class is enough" shortcut
if not C.orig_AddToWhoQueue then
	C.orig_AddToWhoQueue = MessageBox.AddToWhoQueue
	function MessageBox:AddToWhoQueue(name)
		if name and C:Get("whoSkipIfClassKnown") then
			local c = MessageBox.playerCache[name]
			if c and c.class and c.guild == nil and not c.isGM then
				c.guild = "" -- mark resolved: guild/zone intentionally not looked up
				if C.traceOn then C:T("queue", "skip /who for " .. name .. " (class known)") end
				return
			end
		end
		return C.orig_AddToWhoQueue(self, name)
	end
end

-- 5b. ProcessWhoQueue: observe timeouts, silent ClassicAPI send, collision gate
if not C.orig_ProcessWhoQueue then
	C.orig_ProcessWhoQueue = MessageBox.ProcessWhoQueue
	function MessageBox:ProcessWhoQueue()
		local s = MessageBox.settings
		if not (s and s.backgroundWho) then return C.orig_ProcessWhoQueue(self) end

		local w = C.who
		local waiting = MessageBox.waitingForWhoResult
		local entry = MessageBox.currentWhoEntry
		local silent = C.hasClassicAPI and C:Get("classicSilentWho")
			and C_FriendList and C_FriendList.SendWhoQueryByName

		C:Safe("pwq-observe", function()
			if waiting and entry and (GetTime() - MessageBox.waitingForWhoSince) > MessageBox.WHO_TIMEOUT then
				w.timedOut = { lower = entry.nameLower, sentAt = MessageBox.waitingForWhoSince }
				C:OnWhoDropped("timeout")
			end
		end)

		-- Another addon's silent /who is in flight: don't collide with it.
		if silent and not waiting and C_FriendList.IsWhoQueryPending and C_FriendList.IsWhoQueryPending() then
			return
		end

		local before = MessageBox.waitingForWhoSince
		local realSendWho = SendWho
		if silent then
			SendWho = function(q)
				local nm = string.gsub(q, "^n%-", "")
				if not C_FriendList.SendWhoQueryByName(nm) then realSendWho(q) end
			end
		end
		local ok, err = pcall(C.orig_ProcessWhoQueue, self)
		if silent then SendWho = realSendWho end
		if not ok then error(err) end

		if MessageBox.waitingForWhoResult and MessageBox.waitingForWhoSince ~= before then
			w.lastSendAt = MessageBox.waitingForWhoSince
			w.stats.sent = w.stats.sent + 1
			if C.traceOn then C:T("who", "sent for " .. tostring(MessageBox.currentWhoEntry and MessageBox.currentWhoEntry.name)) end
		end
	end
end

-- 5c. HandleWhoResult: classify the reply, harvest late replies, fix tokens
if not C.orig_HandleWhoResult then
	C.orig_HandleWhoResult = MessageBox.HandleWhoResult
	function MessageBox:HandleWhoResult()
		local w = C.who
		C:Safe("hwr-classify", function()
			local sig = C:WhoSignature()
			if not MessageBox.waitingForWhoResult then
				local to = w.timedOut
				if to and (GetTime() - to.sentAt) < (C:Get("whoTimeoutMax") * 2) and C:ResultsContain(to.lower) then
					local lat = GetTime() - to.sentAt
					w.timedOut = nil
					C:OnWhoLate(lat)
					-- Stock code ignores results when not waiting; let it parse
					-- this one so the late (but valid) data isn't thrown away.
					MessageBox.waitingForWhoResult = true
					MessageBox.currentWhoEntry = nil
				end
			else
				local entry = MessageBox.currentWhoEntry
				local found = entry and C:ResultsContain(entry.nameLower)
				local latency = GetTime() - (MessageBox.waitingForWhoSince or GetTime())
				if (not found) and GetNumWhoResults() > 0 and sig == w.lastSig then
					C:OnWhoDropped("stale")
				else
					C:OnWhoSuccess(latency)
				end
			end
			w.lastSig = sig
		end)

		local r = C.orig_HandleWhoResult(self)

		C:Safe("hwr-tokens", function()
			for i = 1, GetNumWhoResults() do
				local name = GetWhoInfo(i)
				if name then C:NormalizeClass(name) end
			end
		end)
		return r
	end
end

-- 5d. OnEvent: instant resolution + UnitXP alert + login setup
if not C.orig_OnEvent then
	C.orig_OnEvent = MessageBox.OnEvent
	function MessageBox:OnEvent(evt)
		if (evt == "CHAT_MSG_WHISPER" or evt == "CHAT_MSG_WHISPER_INFORM")
			and MessageBox.settings and arg2 and arg6 ~= "GM" then
			local who = arg2
			C:Safe("resolve", function()
				local via = C:ResolveContact(who)
				if C.traceOn then C:T("resolve", who .. " via " .. tostring(via)) end
			end)
		end
		if evt == "CHAT_MSG_WHISPER" and C.hasUnitXP then
			C:Safe("xp-alert", function()
				if C:Get("xpFlash") then UnitXP("notify", "taskbarIcon") end
				if C:Get("xpSystemSound") then UnitXP("notify", "systemSound") end
			end)
		end

		local r = C.orig_OnEvent(self, evt)

		if evt == "PLAYER_LOGIN" then
			C:Safe("login", C.OnLogin, C)
		end
		return r
	end
end

------------------------------------------------------------------------
-- 6. Login setup
------------------------------------------------------------------------

function C:ApplyBubbles()
	if not (C.hasNampower and SetCVar and GetCVar) then return end
	if C:Get("npWhisperBubbles") then
		if GetCVar("NP_ChatBubblesWhisper") ~= "1" then
			SetCVar("NP_ChatBubblesWhisper", "1")
			C:Set("bubblesSetByUs", true)
		end
	elseif C:Get("bubblesSetByUs") then
		-- only undo what we changed; never clobber the user's own preference
		SetCVar("NP_ChatBubblesWhisper", "0")
		C:Set("bubblesSetByUs", false)
	end
end

function C:HookFriendsFrame()
	if C.friendsHooked then return end
	if not (C.hasClassicAPI and type(FriendsFrame_OnEvent) == "function"
		and C_FriendList and C_FriendList.IsWhoQueryPending) then return end
	C.friendsHooked = true
	local orig = FriendsFrame_OnEvent
	FriendsFrame_OnEvent = function()
		-- ClassicAPI doc: gate on IsWhoQueryPending so our silent /who doesn't
		-- pop the friends panel, while user-issued /who still works.
		if event == "WHO_LIST_UPDATE" and C:Get("classicSilentWho")
			and C_FriendList.IsWhoQueryPending() and (GetTime() - C.who.lastSendAt) < 5 then
			return
		end
		return orig()
	end
end

function C:OnLogin()
	C:Detect()

	if not MessageBox.settings.compat then MessageBox.settings.compat = {} end
	if C.pending then
		for k, v in pairs(C.pending) do MessageBox.settings.compat[k] = v end
		C.pending = nil
	end

	-- remember the stock values once, before we ever steer them
	if not C.baseInterval then
		C.baseInterval = MessageBox.WHO_INTERVAL or 30
		C.baseTimeout = MessageBox.WHO_TIMEOUT or 10
	end

	local loc, tok = UnitClass("player")
	C:LearnClass(loc, tok)
	for name, _ in pairs(MessageBox.playerCache) do C:NormalizeClass(name) end

	if C.hasClassicAPI and C_PlayerCache then
		-- persistent name/class cache: survives /reload and restarts
		if C_PlayerCache.SetEnabled then C_PlayerCache.SetEnabled(true) end
		if C_PlayerCache.SetScanEnabled then C_PlayerCache.SetScanEnabled(true) end
	end

	C:Apply()
	C:ApplyBubbles()
	C:HookFriendsFrame()

	if MessageBox.fonts and MessageBox.fonts.openSansMissing then
		C:Say("|cffff8800font\\OpenSans.ttf not found|r - using the default font. "
			.. "Copy the addon's font/, img/ and sound/ folders too, not just the .lua files.")
	end
	local found = C:ModList()
	if table.getn(found) > 0 then
		C:Say("enhanced with " .. table.concat(found, ", ") .. ".")
	end
end

------------------------------------------------------------------------
-- 7. Slash commands (extends /mbox; stock commands still reach the original)
------------------------------------------------------------------------

function C:WhoStatus()
	local w = C.who
	C:Say(string.format("/who interval %.1fs, timeout %.1fs, %s | sent %d ok %d dropped %d stale %d late %d | queue %d",
		C:CurInterval(), C:CurTimeout(), C:Get("whoAdaptive") and "adaptive" or "pinned",
		w.stats.sent, w.stats.ok, w.stats.dropped, w.stats.stale, w.stats.late,
		table.getn(MessageBox.whoQueue)))
end

function C:OnOff(v) return v and "on" or "off" end

function C:Slash(msg)
	local text = msg or ""
	local _, _, verb, rest = string.find(string.lower(text), "^(%S*)%s*(.*)$")
	verb = verb or ""
	rest = rest or ""

	if verb == "mods" then
		local found = C:ModList()
		if table.getn(found) == 0 then C:Say("no client mods detected (running stock).")
		else C:Say("detected: " .. table.concat(found, ", ")) end
		return true

	elseif verb == "who" then
		if rest == "" or rest == "status" then
			C:WhoStatus()
		elseif rest == "auto" then
			C:Set("whoAdaptive", true); C:Say("/who throttle: adaptive.")
		elseif rest == "reset" then
			C:Set("whoAdaptive", true); C:Set("whoInterval", nil); C:Set("whoTimeout", nil)
			C.who.floor = nil; C.who.drops = 0; C.who.ok = 0
			C:Apply(); C:Say("/who tuning reset to stock values.")
		elseif rest == "skip" then
			local v = not C:Get("whoSkipIfClassKnown"); C:Set("whoSkipIfClassKnown", v)
			C:Say("skip /who when class already known: " .. C:OnOff(v))
		elseif rest == "silent" then
			local v = not C:Get("classicSilentWho"); C:Set("classicSilentWho", v)
			C:Say("ClassicAPI silent /who: " .. C:OnOff(v))
		elseif tonumber(rest) then
			local n = tonumber(rest)
			if n < 1 then n = 1 end
			C:Set("whoAdaptive", false); C:Set("whoInterval", n); C:Apply()
			C:Say(string.format("/who interval pinned to %ds (adaptive off).", n))
		else
			C:Say("/mbox who [status | <seconds> | auto | reset | skip | silent]")
		end
		return true

	elseif verb == "xp" then
		if not C.hasUnitXP then C:Say("UnitXP_SP3 not detected."); return true end
		if rest == "flash" then
			local v = not C:Get("xpFlash"); C:Set("xpFlash", v); C:Say("taskbar flash: " .. C:OnOff(v))
		elseif rest == "sound" then
			local v = not C:Get("xpSystemSound"); C:Set("xpSystemSound", v); C:Say("OS sound alert: " .. C:OnOff(v))
		else
			C:Say("taskbar flash " .. C:OnOff(C:Get("xpFlash")) .. ", OS sound " .. C:OnOff(C:Get("xpSystemSound"))
				.. "  (/mbox xp flash | sound; only effective while the game is in the background)")
		end
		return true

	elseif verb == "bubbles" then
		if not C.hasNampower then C:Say("Nampower not detected."); return true end
		if rest == "on" then C:Set("npWhisperBubbles", true)
		elseif rest == "off" then C:Set("npWhisperBubbles", false)
		else C:Set("npWhisperBubbles", not C:Get("npWhisperBubbles")) end
		C:ApplyBubbles()
		C:Say("whisper chat bubbles: " .. C:OnOff(C:Get("npWhisperBubbles")))
		return true

	elseif verb == "log" then
		if C.hasWeirdLog then C:Say("chat log: " .. tostring(GetChatLogPath()))
		else C:Say("needs WeirdUtils' logsessions module.") end
		return true

	elseif verb == "trace" then
		if rest == "on" then C.traceOn = true; C:Say("trace on (/mbox trace dump)")
		elseif rest == "off" then C.traceOn = false; C:Say("trace off")
		elseif rest == "echo" then C.traceEcho = not C.traceEcho; C:Say("trace echo " .. C:OnOff(C.traceEcho))
		elseif rest == "clear" then C.traceBuf = {}; C:Say("trace cleared")
		else
			local n = table.getn(C.traceBuf)
			C:Say("trace buffer (" .. n .. " lines, errors " .. tostring(C.errors or 0) .. "):")
			for i = math.max(1, n - 24), n do DEFAULT_CHAT_FRAME:AddMessage("  " .. C.traceBuf[i]) end
		end
		return true

	elseif verb == "help" then
		C:Say("extra commands: mods | who | xp | bubbles | log | trace   (stock: queue | clear | stress)")
		return true
	end
	return false
end

if SlashCmdList["MESSAGEBOX"] and not C.orig_Slash then
	C.orig_Slash = SlashCmdList["MESSAGEBOX"]
	SlashCmdList["MESSAGEBOX"] = function(msg)
		local handled = false
		C:Safe("slash", function() handled = C:Slash(msg) end)
		if handled then return end
		return C.orig_Slash(msg)
	end
end

-- Static detection at load too (so /mbox mods works even before login)
C:Detect()
