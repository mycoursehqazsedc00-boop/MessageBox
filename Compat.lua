-- Compat.lua
-- Optional integrations for: ClassicAPI, SuperWoW, Nampower, UnitXP_SP3, WeirdUtils
-- Plus an adaptive /who throttle that learns the current server's rate limit.
--
-- Load this file LAST in MessageBox.toc (after MessageBox.lua). It never
-- requires any of the above to be installed -- every feature detects its
-- dependency at runtime and quietly no-ops if that dependency is absent,
-- so this file is always safe to ship alongside the base addon.
--
-- It does not modify any existing MessageBox file. It wraps a small number
-- of MessageBox's own functions (the same manual-hook pattern Logic.lua
-- already uses for ChatFrame_SendTell/ChatFrame_OnEvent/ChatEdit_ParseText)
-- and writes into the same data structures (MessageBox.playerCache,
-- MessageBox.settings.classCache) that the stock /who pipeline already
-- populates, so the existing UI code needs zero changes to benefit.

MessageBox.compat = MessageBox.compat or {}
local C = MessageBox.compat

------------------------------------------------------------------------
-- 0. Settings access
--
-- MessageBoxSettings doesn't exist yet when this file loads (MessageBox.lua
-- builds it on PLAYER_LOGIN). So read through a helper that falls back to
-- an in-memory default until the saved table shows up, then persists.
------------------------------------------------------------------------

C.defaults = {
	whoAdaptive        = true,   -- learn the server's throttle automatically
	whoInterval        = 30,     -- seconds between /who; the learned value lives here
	whoIntervalMin     = 5,      -- never query faster than this
	whoIntervalMax     = 150,    -- never back off slower than this
	whoTimeout         = 10,     -- seconds to wait for WHO_LIST_UPDATE
	whoTimeoutMax      = 45,
	whoSkipIfClassKnown = false, -- if class resolved via ClassicAPI, skip /who entirely
}

function C:Get(key)
	local s = MessageBox.settings
	if s and s[key] ~= nil then return s[key] end
	if C.pending and C.pending[key] ~= nil then return C.pending[key] end
	return C.defaults[key]
end

function C:Set(key, value)
	local s = MessageBox.settings
	if s then
		s[key] = value
	else
		C.pending = C.pending or {}
		C.pending[key] = value
	end
end

------------------------------------------------------------------------
-- 1. Detection
------------------------------------------------------------------------

C.hasClassicAPI = (GetCurrentChatGUID ~= nil and GetPlayerInfoByGUID ~= nil)

C.hasUnitXP = false
if UnitXP then
	local ok, exists = pcall(UnitXP, "nop", "nop")
	C.hasUnitXP = ok and exists == true
end

C.hasNampower = MessageBox.hasNampower and true or false
C.hasWeirdUtils = (GetWeirdUtilsVersion ~= nil)

-- SuperWoW: the version-independent runtime signature is that it makes
-- UnitExists() return the unit's GUID as a second value. (ClassicAPI's
-- GUID-token support does NOT add this second return, so this test still
-- isolates SuperWoW specifically.)
C.hasSuperWoW = false
do
	local ok, exists, guid = pcall(UnitExists, "player")
	C.hasSuperWoW = ok and type(guid) == "string"
end

local function AnnounceCompat()
	local found = {}
	if C.hasClassicAPI then table.insert(found, "ClassicAPI") end
	if C.hasSuperWoW then table.insert(found, "SuperWoW") end
	if C.hasNampower then table.insert(found, "Nampower") end
	if C.hasUnitXP then table.insert(found, "UnitXP_SP3") end
	if C.hasWeirdUtils then table.insert(found, "WeirdUtils") end
	if table.getn(found) > 0 then
		DEFAULT_CHAT_FRAME:AddMessage("|cff3cb7f0Message|rBox: enhanced with " .. table.concat(found, ", ") .. ".")
	else
		DEFAULT_CHAT_FRAME:AddMessage("|cff3cb7f0Message|rBox: no client mods detected; running stock.")
	end
end

------------------------------------------------------------------------
-- 2. Shared helper: feed class/race/level into the SAME cache fields
--    Logic.lua:HandleWhoResult() already writes.
--
-- Note: the stock addon derives classUpper by string.upper()-ing whatever
-- GetWhoInfo() returned, which is the LOCALIZED class name -- a no-op on
-- enUS but wrong on any other locale. Feeding the real english token here
-- fixes class colors on non-English clients as a side effect.
------------------------------------------------------------------------

function C:FeedPlayerInfo(name, localizedClass, englishClass, localizedRace, level)
	if not name or not localizedClass then return end

	if not MessageBox.playerCache[name] then
		MessageBox.playerCache[name] = {}
	end
	local cache = MessageBox.playerCache[name]
	cache.class = localizedClass
	cache.classUpper = englishClass or string.upper(localizedClass)
	if localizedRace then cache.race = localizedRace end
	if level then cache.level = level end

	if MessageBox.settings and MessageBox.settings.classCache then
		local sc = MessageBox.settings.classCache
		if not sc[name] then sc[name] = {} end
		sc[name].class = cache.class
		sc[name].classUpper = cache.classUpper
		if level and tonumber(level) == 60 then
			sc[name].level = level
		end
	end
end

------------------------------------------------------------------------
-- 3. ClassicAPI: resolve class/race the instant a whisper arrives.
------------------------------------------------------------------------

function C:TryResolveByGUID(name)
	if not C.hasClassicAPI then return false end

	-- Only valid synchronously inside the CHAT_MSG_* dispatch window.
	-- MessageBox:AddToWhoQueue() is always called directly from
	-- MessageBox:OnEvent()'s whisper branches, which is that window.
	local guid = GetCurrentChatGUID()
	if guid then
		local locClass, engClass, locRace = GetPlayerInfoByGUID(guid)
		if engClass then
			C:FeedPlayerInfo(name, locClass, engClass, locRace, nil)
			if C_PlayerCache and C_PlayerCache.RememberPlayer then
				pcall(C_PlayerCache.RememberPlayer, guid, name, engClass)
			end
			return true
		end
	end

	if C_PlayerCache and C_PlayerCache.GetPlayerInfoByName then
		local locClass, engClass, locRace = C_PlayerCache.GetPlayerInfoByName(name)
		if engClass then
			C:FeedPlayerInfo(name, locClass, engClass, locRace, nil)
			return true
		end
	end

	return false
end

if C.hasClassicAPI and C_PlayerCache then
	pcall(C_PlayerCache.SetEnabled, true)
	pcall(C_PlayerCache.SetScanEnabled, true)
end

------------------------------------------------------------------------
-- 4. Visible-unit resolution (free, no network call).
--    Plain vanilla API, so it works with nothing installed; SuperWoW and
--    Nampower just make the GUID pairing exact rather than name-matched.
------------------------------------------------------------------------

local VISIBLE_UNITS = {
	"target", "mouseover",
	"party1", "party2", "party3", "party4",
	"raid1", "raid2", "raid3", "raid4", "raid5",
	"raid6", "raid7", "raid8", "raid9", "raid10",
}

function C:TryResolveFromVisibleUnit(name)
	for _, unit in ipairs(VISIBLE_UNITS) do
		if UnitExists(unit) and UnitName(unit) == name then
			local locClass, engClass = UnitClass(unit)
			local locRace = UnitRace(unit)
			if engClass then
				local level = UnitLevel(unit)
				if level and level < 0 then level = nil end -- "??" units
				C:FeedPlayerInfo(name, locClass, engClass, locRace, level)

				if C.hasClassicAPI and C_PlayerCache and C_PlayerCache.RememberPlayer and UnitGUID then
					local guid = UnitGUID(unit)
					if guid then
						pcall(C_PlayerCache.RememberPlayer, guid, name, engClass)
					end
				end
				return true
			end
		end
	end
	return false
end

------------------------------------------------------------------------
-- 5. ADAPTIVE /WHO THROTTLE
--
-- There is no API to ask a server what its /who rate limit is, and it
-- varies wildly between realms (and by realm population). The stock addon
-- hardcodes WHO_INTERVAL = 30 and WHO_TIMEOUT = 10, which is simultaneously
-- too aggressive for throttled realms (queries silently dropped, entries
-- burn their 3 retries and never resolve) and far too slow for quiet ones
-- (a 50-name backlog takes 25 minutes to drain).
--
-- So: measure it. AIMD controller -- additive decrease on success,
-- multiplicative increase on a dropped query.
--
-- Logic.lua reads MessageBox.WHO_INTERVAL and MessageBox.WHO_TIMEOUT fresh
-- on every ProcessWhoQueue() call, so simply mutating those two fields is
-- enough to steer the stock scheduler. No rewrite of its logic needed.
--
-- Signals we can actually observe:
--   TIMEOUT  -- SendWho fired, no WHO_LIST_UPDATE inside WHO_TIMEOUT.
--              Strongest throttle evidence: server dropped it. Back off.
--   STALE    -- WHO_LIST_UPDATE fired but returned byte-identical results
--              to the previous query, and our target isn't in them. The
--              server ignored the new query and we're re-reading the old
--              result set. Also throttling. Back off.
--   LATE     -- WHO_LIST_UPDATE arrives after we'd already given up. The
--              server DID answer, just slower than WHO_TIMEOUT. Not a
--              throttle -- raise the timeout instead of the interval,
--              otherwise we throw away good results forever.
--   SUCCESS  -- fresh results back in time. Creep the interval down.
------------------------------------------------------------------------

C.who = {
	lastSignature = nil,
	lastSendTime  = 0,
	consecutiveDrops = 0,
	consecutiveOK = 0,
	samples = 0,
	lastLatency = nil,
}

local function ApplyWhoTuning()
	MessageBox.WHO_INTERVAL = C:Get("whoInterval")
	MessageBox.WHO_TIMEOUT  = C:Get("whoTimeout")
end

-- Signature of the current result set, so we can tell a fresh response
-- from the server handing us back the previous one.
local function WhoResultSignature()
	local n = GetNumWhoResults()
	if n == 0 then return "0" end
	local parts = { tostring(n) }
	for i = 1, n do
		local name, guild, level = GetWhoInfo(i)
		table.insert(parts, (name or "?") .. ":" .. (level or "?") .. ":" .. (guild or ""))
	end
	return table.concat(parts, "|")
end

function C:OnWhoDropped(reason)
	if not C:Get("whoAdaptive") then return end

	local w = C.who
	w.consecutiveDrops = w.consecutiveDrops + 1
	w.consecutiveOK = 0
	w.samples = w.samples + 1

	-- Multiplicative back-off. Steeper on repeat drops so a hard-throttled
	-- realm converges in a handful of queries instead of dozens.
	local factor = (w.consecutiveDrops >= 3) and 2.0 or 1.5
	local cur = C:Get("whoInterval")
	local next_ = math.min(cur * factor, C:Get("whoIntervalMax"))

	if next_ ~= cur then
		C:Set("whoInterval", next_)
		ApplyWhoTuning()
		if C.debug then
			DEFAULT_CHAT_FRAME:AddMessage(string.format(
				"|cff3cb7f0Message|rBox: /who %s -- backing off to %.0fs.", reason, next_))
		end
	end
end

function C:OnWhoLate(latency)
	if not C:Get("whoAdaptive") then return end

	-- Server answered, just slowly. Grow the timeout to cover it (with
	-- headroom) rather than treating a slow realm as a throttled one.
	local want = math.min(latency * 1.5, C:Get("whoTimeoutMax"))
	if want > C:Get("whoTimeout") then
		C:Set("whoTimeout", want)
		ApplyWhoTuning()
		if C.debug then
			DEFAULT_CHAT_FRAME:AddMessage(string.format(
				"|cff3cb7f0Message|rBox: /who answered late (%.1fs) -- timeout now %.0fs.", latency, want))
		end
	end
end

function C:OnWhoSuccess(latency)
	if not C:Get("whoAdaptive") then return end

	local w = C.who
	w.consecutiveOK = w.consecutiveOK + 1
	w.consecutiveDrops = 0
	w.samples = w.samples + 1
	w.lastLatency = latency

	-- Additive decrease, and only after a few clean queries in a row, so
	-- one lucky response doesn't immediately undo a justified back-off.
	if w.consecutiveOK >= 3 then
		w.consecutiveOK = 0
		local cur = C:Get("whoInterval")
		local next_ = math.max(cur - 2, C:Get("whoIntervalMin"))
		if next_ ~= cur then
			C:Set("whoInterval", next_)
			ApplyWhoTuning()
			if C.debug then
				DEFAULT_CHAT_FRAME:AddMessage(string.format(
					"|cff3cb7f0Message|rBox: /who healthy -- tightening to %.0fs.", next_))
			end
		end
	end
end

-- Wrap ProcessWhoQueue: detect the timeout case *before* the stock code
-- clears the state, and stamp the send time *after* it fires SendWho.
if not C.original_ProcessWhoQueue then
	C.original_ProcessWhoQueue = MessageBox.ProcessWhoQueue

	function MessageBox:ProcessWhoQueue()
		local wasWaiting = MessageBox.waitingForWhoResult
		local since = MessageBox.waitingForWhoSince

		if wasWaiting and (GetTime() - since) > MessageBox.WHO_TIMEOUT then
			C:OnWhoDropped("timed out")
		end

		local before = MessageBox.waitingForWhoSince
		local ret = C.original_ProcessWhoQueue(self)

		-- A new query went out this tick.
		if MessageBox.waitingForWhoResult and MessageBox.waitingForWhoSince ~= before then
			C.who.lastSendTime = MessageBox.waitingForWhoSince
		end
		return ret
	end
end

-- Wrap HandleWhoResult: classify the response before the stock code
-- consumes and resets it.
if not C.original_HandleWhoResult then
	C.original_HandleWhoResult = MessageBox.HandleWhoResult

	function MessageBox:HandleWhoResult()
		local sig = WhoResultSignature()
		local entry = MessageBox.currentWhoEntry
		local latency = C.who.lastSendTime > 0 and (GetTime() - C.who.lastSendTime) or nil

		if not MessageBox.waitingForWhoResult then
			-- We already gave up on this one, but the server did reply.
			-- Only counts as "late" if it's genuinely a new result set and
			-- plausibly ours -- otherwise it's just the user opening the
			-- Who panel themselves.
			if latency and latency < C:Get("whoTimeoutMax") * 2 and sig ~= C.who.lastSignature then
				C:OnWhoLate(latency)
			end
			C.who.lastSignature = sig
			return C.original_HandleWhoResult(self)
		end

		-- Did our actual target come back in this result set?
		local targetLower = entry and entry.nameLower or nil
		local foundTarget = false
		if targetLower then
			for i = 1, GetNumWhoResults() do
				local nm = GetWhoInfo(i)
				if nm and string.lower(nm) == targetLower then
					foundTarget = true
					break
				end
			end
		end

		if sig == C.who.lastSignature and not foundTarget and sig ~= "0" then
			-- Identical non-empty result set as last time and our target
			-- isn't in it: the server ignored this query.
			C:OnWhoDropped("stale result")
		else
			-- Note: zero results is a legitimate answer (player offline),
			-- not a drop -- the server did respond. Count it as success so
			-- offline contacts don't push us into needless back-off.
			C:OnWhoSuccess(latency or 0)
		end

		C.who.lastSignature = sig
		return C.original_HandleWhoResult(self)
	end
end

ApplyWhoTuning()

------------------------------------------------------------------------
-- 6. Wrap AddToWhoQueue: try the free/instant paths first. Every query we
--    avoid is throttle budget spent on someone who actually needs it.
------------------------------------------------------------------------

if not C.original_AddToWhoQueue then
	C.original_AddToWhoQueue = MessageBox.AddToWhoQueue

	function MessageBox:AddToWhoQueue(name)
		if name then
			local resolved = C:TryResolveFromVisibleUnit(name)
			if not resolved then
				resolved = C:TryResolveByGUID(name)
			end
			if resolved then
				local cache = MessageBox.playerCache[name]

				-- Fully resolved already (class + guild from a prior /who).
				if cache and cache.guild ~= nil then
					if MessageBox.frame and MessageBox.frame:IsVisible() then
						MessageBox:MarkContactListDirty()
					end
					return
				end

				-- Class is known instantly. On a hard-throttled realm the
				-- remaining /who buys only guild/zone, which may not be
				-- worth the budget -- let the user decide.
				if C:Get("whoSkipIfClassKnown") then
					if cache then cache.guild = cache.guild or "" end
					if MessageBox.frame and MessageBox.frame:IsVisible() then
						MessageBox:MarkContactListDirty()
					end
					return
				end
			end
		end
		return C.original_AddToWhoQueue(self, name)
	end
end

------------------------------------------------------------------------
-- 7. UnitXP_SP3: OS-level notification when the client is backgrounded.
------------------------------------------------------------------------

if C.hasUnitXP and MessageBox.ShowNotificationPopup and not C.original_ShowNotificationPopup then
	C.original_ShowNotificationPopup = MessageBox.ShowNotificationPopup

	function MessageBox:ShowNotificationPopup()
		if MessageBox.settings and MessageBox.settings.notificationSound then
			pcall(UnitXP, "notify", "taskbarIcon")
			pcall(UnitXP, "notify", "systemSound")
		end
		return C.original_ShowNotificationPopup(self)
	end
end

------------------------------------------------------------------------
-- 8. Nampower: keep in-world chat bubbles for whisperers.
------------------------------------------------------------------------

if C.hasNampower and SetCVar and GetCVar then
	if GetCVar("NP_ChatBubblesWhisper") == "0" then
		SetCVar("NP_ChatBubblesWhisper", "1")
	end
end

------------------------------------------------------------------------
-- 9. Slash commands
------------------------------------------------------------------------

local function CompatSlash(msg)
	local cmd = msg and string.lower(msg) or ""
	local _, _, verb, arg = string.find(cmd, "^(%S*)%s*(.*)$")

	if verb == "mods" then
		AnnounceCompat()
		return true

	elseif verb == "log" then
		if C.hasWeirdUtils and GetChatLogPath then
			local path = GetChatLogPath()
			DEFAULT_CHAT_FRAME:AddMessage("|cff3cb7f0Message|rBox: raw chat log -> " .. (path or "unavailable"))
		else
			DEFAULT_CHAT_FRAME:AddMessage("|cff3cb7f0Message|rBox: raw chat logs need WeirdUtils (logsessions).")
		end
		return true

	elseif verb == "who" then
		if arg == "auto" then
			C:Set("whoAdaptive", true)
			DEFAULT_CHAT_FRAME:AddMessage("|cff3cb7f0Message|rBox: /who throttle set to adaptive.")
		elseif arg == "reset" then
			C:Set("whoAdaptive", true)
			C:Set("whoInterval", C.defaults.whoInterval)
			C:Set("whoTimeout", C.defaults.whoTimeout)
			C.who.consecutiveDrops = 0
			C.who.consecutiveOK = 0
			C.who.samples = 0
			ApplyWhoTuning()
			DEFAULT_CHAT_FRAME:AddMessage("|cff3cb7f0Message|rBox: /who tuning reset to defaults.")
		elseif arg == "debug" then
			C.debug = not C.debug
			DEFAULT_CHAT_FRAME:AddMessage("|cff3cb7f0Message|rBox: /who tuning debug " .. (C.debug and "on" or "off") .. ".")
		elseif arg == "skip" then
			local v = not C:Get("whoSkipIfClassKnown")
			C:Set("whoSkipIfClassKnown", v)
			DEFAULT_CHAT_FRAME:AddMessage("|cff3cb7f0Message|rBox: skip /who when class already known: " .. (v and "on" or "off") .. ".")
		elseif tonumber(arg) then
			local n = tonumber(arg)
			if n < 1 then n = 1 end
			C:Set("whoAdaptive", false)
			C:Set("whoInterval", n)
			ApplyWhoTuning()
			DEFAULT_CHAT_FRAME:AddMessage(string.format(
				"|cff3cb7f0Message|rBox: /who interval pinned to %ds (adaptive off).", n))
		else
			DEFAULT_CHAT_FRAME:AddMessage(string.format(
				"|cff3cb7f0Message|rBox: /who interval %.0fs, timeout %.0fs, mode %s (%d samples, %d queued).",
				C:Get("whoInterval"), C:Get("whoTimeout"),
				C:Get("whoAdaptive") and "adaptive" or "pinned",
				C.who.samples, table.getn(MessageBox.whoQueue)))
			DEFAULT_CHAT_FRAME:AddMessage("  /mbox who <seconds> | auto | reset | skip | debug")
		end
		return true
	end

	return false
end

if SlashCmdList["MESSAGEBOX"] and not C.original_SlashHandler then
	C.original_SlashHandler = SlashCmdList["MESSAGEBOX"]
	SlashCmdList["MESSAGEBOX"] = function(msg)
		if CompatSlash(msg) then return end
		return C.original_SlashHandler(msg)
	end
end

------------------------------------------------------------------------
-- 10. Re-apply tuning once saved settings load, so a learned interval
--     survives relogs instead of relearning from 30s every session.
------------------------------------------------------------------------

C.initFrame = CreateFrame("Frame", "MessageBoxCompatInit")
C.initFrame:RegisterEvent("PLAYER_LOGIN")
C.initFrame:SetScript("OnEvent", function()
	-- MessageBox.lua's own PLAYER_LOGIN handler builds MessageBoxSettings;
	-- ours runs after it on the same event, so settings exist by now.
	if MessageBox.settings then
		for k, v in pairs(C.defaults) do
			if MessageBox.settings[k] == nil then
				MessageBox.settings[k] = v
			end
		end
		if C.pending then
			for k, v in pairs(C.pending) do
				MessageBox.settings[k] = v
			end
			C.pending = nil
		end
	end
	ApplyWhoTuning()
	AnnounceCompat()
end)
