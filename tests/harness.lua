-- harness.lua
-- Minimal WoW 1.12 simulator for running MessageBox under texlua (Lua 5.3).
--   * Each env is isolated (addon files are loaded with the env as _ENV).
--   * Lua 5.0 / WoW legacy globals are shimmed (table.getn, math.mod, unpack, ...).
--   * Frame mock has faithful failure semantics for the two bugs under test:
--       - SetNormalTexture(missingFile) -> GetNormalTexture() == nil
--       - SetFont(missingFile)          -> returns nil, FontString:SetText errors "Font not set"
--   * Virtual clock, event dispatch, OnUpdate ticking.
--   * Simulated /who server with throttle profiles.
--   * Togglable mock client mods: ClassicAPI, UnitXP_SP3, SuperWoW, Nampower, WeirdUtils.

local H = {}

------------------------------------------------------------------------
-- helpers
------------------------------------------------------------------------
local function readfile(path)
	local f = assert(io.open(path, "rb"))
	local s = f:read("a")
	f:close()
	return s
end
H.readfile = readfile

local function shallow(t)
	local r = {}
	for k, v in pairs(t) do r[k] = v end
	return r
end

------------------------------------------------------------------------
-- Frame mock
------------------------------------------------------------------------
local function newFrameSystem(env, state)
	local FrameMT = {}
	local Methods = {}
	FrameMT.__index = Methods

	local allFrames = state.allFrames
	local function isAssetPresent(path)
		if type(path) ~= "string" then return false end
		local p = string.lower(path)
		local addon = "interface\\addons\\messagebox\\"
		if string.sub(p, 1, #addon) == addon then
			local rest = string.sub(p, #addon + 1)
			local folder = string.match(rest, "^([^\\]+)\\")
			if folder and state.opts.missingFolders and state.opts.missingFolders[folder] then
				return false
			end
			return true
		end
		return true -- Blizzard paths always exist
	end
	state.isAssetPresent = isAssetPresent

	local function new(kind, name, parent, template)
		local o = setmetatable({
			_kind = kind, _name = name, _parent = parent, _shown = true,
			_scripts = {}, _events = {}, _w = 100, _h = 100, _text = "",
			_points = {}, _children = {}, _alpha = 1, _scale = 1, _level = 1, _id = 0,
			_min = 0, _max = 1, _value = 0,
		}, FrameMT)
		if parent and type(parent) == "table" and parent._children then
			table.insert(parent._children, o)
		end
		if kind ~= "FontString" and kind ~= "Texture" then
			table.insert(allFrames, o)
		end
		if template then
			o._template = template
			if string.find(template, "GameFont") or string.find(template, "Font") then
				o._font = "template:" .. template
			end
		end
		if name then env[name] = o end
		return o
	end

	local function fontOK(self)
		return self._font ~= nil
	end

	-- identity / hierarchy
	function Methods:GetName() return self._name end
	function Methods:GetParent() return self._parent end
	function Methods:GetObjectType() return self._kind end
	function Methods:GetID() return self._id end
	function Methods:SetID(i) self._id = i end

	-- size / position
	function Methods:SetWidth(w) self._w = w end
	function Methods:SetHeight(h) self._h = h end
	function Methods:SetSize(w, h) self._w = w; self._h = h end
	function Methods:GetWidth() return self._w end
	function Methods:GetHeight() return self._h end
	function Methods:SetPoint(...) self._points[#self._points + 1] = { ... } end
	function Methods:ClearAllPoints() self._points = {} end
	function Methods:SetAllPoints() end
	function Methods:GetPoint() local p = self._points[1]; if p then return p[1], p[2], p[3], p[4] or 0, p[5] or 0 end; return "CENTER", nil, "CENTER", 0, 0 end
	function Methods:GetLeft() return 100 end
	function Methods:GetRight() return 300 end
	function Methods:GetTop() return 400 end
	function Methods:GetBottom() return 100 end
	function Methods:GetCenter() return 200, 250 end
	function Methods:SetScale(s) self._scale = s end
	function Methods:GetScale() return self._scale end
	function Methods:GetEffectiveScale() return 1 end
	function Methods:SetAlpha(a) self._alpha = a end
	function Methods:GetAlpha() return self._alpha end
	function Methods:SetFrameLevel(l) self._level = l end
	function Methods:GetFrameLevel() return self._level end
	function Methods:SetFrameStrata() end
	function Methods:SetToplevel() end
	function Methods:SetMovable() end
	function Methods:SetResizable() end
	function Methods:SetMinResize() end
	function Methods:SetMaxResize() end
	function Methods:SetClampedToScreen() end
	function Methods:EnableMouse() end
	function Methods:EnableMouseWheel() end
	function Methods:EnableKeyboard() end
	function Methods:RegisterForDrag() end
	function Methods:RegisterForClicks() end
	function Methods:StartMoving() end
	function Methods:StopMovingOrSizing() end
	function Methods:StartSizing() end
	function Methods:SetBackdrop() end
	function Methods:SetBackdropColor() end
	function Methods:SetBackdropBorderColor() end
	function Methods:SetClipsChildren() end
	function Methods:Raise() end
	function Methods:Lower() end

	-- visibility
	function Methods:Show()
		if not self._shown then
			self._shown = true
			if self._scripts.OnShow then state.runScript(self, "OnShow") end
		end
	end
	function Methods:Hide()
		if self._shown then
			self._shown = false
			if self._scripts.OnHide then state.runScript(self, "OnHide") end
		end
	end
	function Methods:IsShown() return self._shown and true or false end
	function Methods:IsVisible()
		local f = self
		while f do
			if not f._shown then return false end
			f = f._parent
		end
		return true
	end

	-- scripts / events
	function Methods:SetScript(kind, fn) self._scripts[kind] = fn end
	function Methods:GetScript(kind) return self._scripts[kind] end
	function Methods:HasScript(kind) return true end
	function Methods:RegisterEvent(e) self._events[e] = true end
	function Methods:UnregisterEvent(e) self._events[e] = nil end
	function Methods:UnregisterAllEvents() self._events = {} end

	-- creation
	function Methods:CreateFontString(name, layer, inherits)
		local fs = new("FontString", name, self, inherits)
		if inherits then fs._font = "template:" .. inherits end
		return fs
	end
	function Methods:CreateTexture(name, layer)
		return new("Texture", name, self)
	end
	function Methods:GetRegions() return nil end
	function Methods:GetChildren() return table.unpack(self._children) end

	-- fonts / text
	function Methods:SetFont(path, size, flags)
		if isAssetPresent(path) then
			self._font = path
			return 1
		end
		return nil
	end
	function Methods:GetFont()
		if self._font then return self._font, 12, "" end
		return nil
	end
	function Methods:SetFontObject(o) if o then self._font = "object:" .. tostring(o) end end
	function Methods:SetText(t)
		if self._kind == "FontString" and not fontOK(self) then
			error("<unnamed>:SetText(): Font not set", 2)
		end
		self._text = t or ""
	end
	function Methods:GetText() return self._text end
	function Methods:SetTextColor() end
	function Methods:SetTextInsets() end
	function Methods:SetJustifyH() end
	function Methods:SetJustifyV() end
	function Methods:SetShadowOffset() end
	function Methods:SetShadowColor() end
	function Methods:SetNonSpaceWrap() end
	function Methods:SetWordWrap() end
	function Methods:GetStringWidth() return math.max(10, #(self._text or "") * 6) end
	function Methods:GetStringHeight() return 12 end
	function Methods:GetFontString()
		if not self._fs then self._fs = new("FontString", nil, self, "GameFontNormal") end
		return self._fs
	end
	function Methods:SetNumber(n) self._text = tostring(n) end
	function Methods:GetNumber() return tonumber(self._text) or 0 end
	function Methods:SetMaxLetters() end
	function Methods:SetMultiLine() end
	function Methods:SetAutoFocus() end
	function Methods:SetFocus() self._focus = true end
	function Methods:ClearFocus() self._focus = false end
	function Methods:HasFocus() return self._focus and true or false end
	function Methods:Insert(t) self._text = (self._text or "") .. t end
	function Methods:HighlightText() end
	function Methods:SetCursorPosition() end
	function Methods:GetCursorPosition() return 0 end

	-- textures
	function Methods:SetTexture(p) self._texture = p end
	function Methods:GetTexture() return self._texture end
	function Methods:SetTexCoord() end
	function Methods:SetVertexColor(r, g, b) self._vc = { r, g, b } end
	function Methods:SetBlendMode() end
	function Methods:SetDesaturated() end
	function Methods:SetGradient() end
	function Methods:SetGradientAlpha() end
	function Methods:SetNormalTexture(p)
		if isAssetPresent(p) then
			local t = new("Texture", nil, self)
			t._texture = p
			self._normal = t
		else
			self._normal = nil
		end
	end
	function Methods:GetNormalTexture() return self._normal end
	local function setSlot(slot)
		return function(self, p)
			if isAssetPresent(p) then
				local t = new("Texture", nil, self); t._texture = p; self[slot] = t
			end
		end
	end
	Methods.SetHighlightTexture = setSlot("_highlight")
	Methods.SetPushedTexture = setSlot("_pushed")
	Methods.SetDisabledTexture = setSlot("_disabled")
	Methods.SetCheckedTexture = setSlot("_checked")
	function Methods:GetHighlightTexture() return self._highlight end
	function Methods:GetPushedTexture() return self._pushed end
	function Methods:GetDisabledTexture() return self._disabled end
	function Methods:GetCheckedTexture() return self._checked end
	function Methods:LockHighlight() end
	function Methods:UnlockHighlight() end
	function Methods:Enable() self._disabledFlag = false end
	function Methods:Disable() self._disabledFlag = true end
	function Methods:IsEnabled() return not self._disabledFlag end
	function Methods:SetChecked(v) self._checked_v = v end
	function Methods:GetChecked() return self._checked_v end
	function Methods:Click() if self._scripts.OnClick then state.runScript(self, "OnClick") end end

	-- sliders / scroll
	function Methods:SetMinMaxValues(a, b) self._min = a; self._max = b end
	function Methods:GetMinMaxValues() return self._min, self._max end
	function Methods:SetValue(v) self._value = v end
	function Methods:GetValue() return self._value end
	function Methods:SetValueStep() end
	function Methods:SetOrientation() end
	function Methods:SetScrollChild(c) self._scrollChild = c end
	function Methods:GetScrollChild() return self._scrollChild end
	function Methods:SetVerticalScroll(v) self._vscroll = v end
	function Methods:GetVerticalScroll() return self._vscroll or 0 end
	function Methods:GetVerticalScrollRange() return 0 end
	function Methods:UpdateScrollChildRect() end
	function Methods:SetThumbTexture() end
	function Methods:SetStatusBarTexture() end
	function Methods:SetStatusBarColor() end

	-- ScrollingMessageFrame
	function Methods:AddMessage(m, r, g, b)
		if self._isChat then
			table.insert(state.chatLog, tostring(m))
		elseif self._kind == "ScrollingMessageFrame" then
			if not fontOK(self) then error("<unnamed>:AddMessage(): Font not set", 2) end
			self._lines = self._lines or {}
			table.insert(self._lines, m)
		else
			table.insert(state.chatLog, tostring(m))
		end
	end
	function Methods:Clear() self._lines = {} end
	function Methods:ScrollToBottom() end
	function Methods:ScrollToTop() end
	function Methods:ScrollUp() end
	function Methods:ScrollDown() end
	function Methods:SetMaxLines() end
	function Methods:SetFading() end
	function Methods:SetFadeDuration() end
	function Methods:SetTimeVisible() end
	function Methods:SetHyperlinksEnabled() end
	function Methods:SetInsertMode() end
	function Methods:GetNumMessages() return self._lines and #self._lines or 0 end
	function Methods:SetOwner() end
	function Methods:AddLine() end
	function Methods:AddDoubleLine() end
	function Methods:ClearLines() end
	function Methods:IsOwned() return false end
	function Methods:SetHyperlink() end
	function Methods:SetColorRGB() end
	function Methods:GetColorRGB() return 1, 1, 1 end

	-- template children (getglobal(name .. "Text") etc.)
	local function makeTemplateChildren(o, name, template)
		if not name or not template then return end
		env[name .. "Text"] = new("FontString", name .. "Text", o, "GameFontNormalSmall")
		env[name .. "Button"] = new("Button", name .. "Button", o)
		env[name .. "Left"] = new("Texture", name .. "Left", o)
		env[name .. "Middle"] = new("Texture", name .. "Middle", o)
		env[name .. "Right"] = new("Texture", name .. "Right", o)
		local sb = new("Slider", name .. "ScrollBar", o)
		env[name .. "ScrollBarScrollUpButton"] = new("Button", name .. "ScrollBarScrollUpButton", sb)
		env[name .. "ScrollBarScrollDownButton"] = new("Button", name .. "ScrollBarScrollDownButton", sb)
		env[name .. "ScrollChildFrame"] = new("Frame", name .. "ScrollChildFrame", o)
		env[name .. "Low"] = new("FontString", name .. "Low", o, "GameFontNormalSmall")
		env[name .. "High"] = new("FontString", name .. "High", o, "GameFontNormalSmall")
	end

	env.CreateFrame = function(kind, name, parent, template)
		local o = new(kind, name, parent, template)
		makeTemplateChildren(o, name, template)
		return o
	end
	return { new = new, Methods = Methods }
end

------------------------------------------------------------------------
-- Environment
------------------------------------------------------------------------
-- opts:
--   missingFolders = { img=true, font=true, sound=true }
--   mods = { classic, xp3, nampower, superwow, weird }  (booleans)
--   locale = "enUS" | "deDE"
--   whoProfile = { minGap, latency, dropMode ("silent"|"stale"), strict }
function H.newEnv(opts)
	opts = opts or {}
	local env = {}
	local state = {
		opts = opts, allFrames = {}, chatLog = {}, errors = {}, now = 1000.0,
		queue = {}, sent = {}, xpCalls = {}, cvars = {}, files = {}, whoSends = {},
		whoDelivered = 0, whoDropped = 0, whoAccepted = 0, whoResults = {},
		lastWhoSet = {},
	}
	env._G = env
	env._state = state

	-- ---------------- Lua 5.0 shims ----------------
	local realFormat = string.format
	local function fmt(f, ...)
		local args = { ... }
		local i = 0
		local out = string.gsub(f, "%%[%-%+ #0]*%d*%.?%d*[%a%%]", function(spec)
			local conv = string.sub(spec, -1)
			if conv == "%" then return nil end
			i = i + 1
			if (conv == "d" or conv == "i" or conv == "x" or conv == "X" or conv == "c" or conv == "o") and type(args[i]) == "number" then
				args[i] = math.floor(args[i])
			end
			return nil
		end)
		return realFormat(f, table.unpack(args, 1, select("#", ...)))
	end
	-- Restrict to the real Lua 5.0 library surface so 5.1+/5.3-only calls fail like in-game.
	local function pick(src, names)
		local r = {}
		for _, n in ipairs(names) do r[n] = src[n] end
		return r
	end
	env.string = pick(string, { "byte", "char", "find", "gsub", "len", "lower", "rep", "sub", "upper" })
	env.string.format = fmt
	env.string.gfind = string.gmatch
	env.table = pick(table, { "concat", "insert", "remove", "sort" })
	env.table.getn = function(t) return #t end
	env.table.setn = function() end
	env.table.foreach = function(t, f) for k, v in pairs(t) do f(k, v) end end
	env.table.foreachi = function(t, f) for i, v in ipairs(t) do f(i, v) end end
	env.math = pick(math, { "abs", "acos", "asin", "atan", "atan2", "ceil", "cos", "deg", "exp", "floor", "log", "log10", "max", "min", "pow", "rad", "random", "randomseed", "sin", "sqrt", "tan" })
	env.math.mod = math.fmod
	env.pairs, env.ipairs, env.type, env.tostring, env.tonumber = pairs, ipairs, type, tostring, tonumber
	env.pcall, env.error, env.assert, env.next = pcall, error, assert, next
	env.rawget, env.rawset, env.setmetatable, env.getmetatable = rawget, rawset, setmetatable, getmetatable
	env.unpack = table.unpack
	env.print = function() end
	env.getglobal = function(n) return env[n] end
	env.setglobal = function(n, v) env[n] = v end
	env.loadstring = function(s) return load(s, "=loadstring", "t", env) end
	env.debugstack = function() return "" end
	env.date = function(f, t) return os.date("!" .. (f or "%c"), t) end
	env.time = function() return 1700000000 + math.floor(state.now) end
	env.GetTime = function() return state.now end
	env.strlen, env.strsub, env.strlower, env.strupper, env.strfind = string.len, string.sub, string.lower, string.upper, string.find
	env.format, env.gsub, env.tinsert, env.tremove = fmt, string.gsub, table.insert, table.remove
	env.floor, env.ceil, env.abs, env.max, env.min = math.floor, math.ceil, math.abs, math.max, math.min
	env.mod = math.fmod
	env.getn = function(t) return #t end

	-- ---------------- frames ----------------
	state.runScript = function(frame, kind, ...)
		local fn = frame._scripts[kind]
		if not fn then return end
		local saved = env.this
		env.this = frame
		local ok, err = xpcall(fn, function(e) return tostring(e) .. "\n" .. debug.traceback("", 2) end, ...)
		env.this = saved
		if not ok then table.insert(state.errors, err) end
		return ok
	end
	local fs = newFrameSystem(env, state)
	env.UIParent = fs.new("Frame", "UIParent", nil)
	env.WorldFrame = fs.new("Frame", "WorldFrame", nil)
	env.Minimap = fs.new("Frame", "Minimap", env.UIParent)
	env.DEFAULT_CHAT_FRAME = fs.new("ScrollingMessageFrame", "DEFAULT_CHAT_FRAME", env.UIParent)
	env.DEFAULT_CHAT_FRAME._font = "stock"
	env.DEFAULT_CHAT_FRAME._isChat = true
	env.ChatFrameEditBox = fs.new("EditBox", "ChatFrameEditBox", env.UIParent); env.ChatFrameEditBox._shown = false
	env.FriendsFrame = fs.new("Frame", "FriendsFrame", env.UIParent); env.FriendsFrame._shown = false
	env.WhoFrame = fs.new("Frame", "WhoFrame", env.UIParent); env.WhoFrame._shown = false
	env.GameTooltip = fs.new("GameTooltip", "GameTooltip", env.UIParent); env.GameTooltip._shown = false
	env.ColorPickerFrame = fs.new("Frame", "ColorPickerFrame", env.UIParent); env.ColorPickerFrame._shown = false
	env.StaticPopupDialogs = {}
	env.UISpecialFrames = {}
	env.SlashCmdList = {}
	env.StaticPopup_Show = function() end
	env.PlaySoundFile = function(p) table.insert(state.sent, { "sound", p }) end
	env.PlaySound = function() end
	env.IsShiftKeyDown = function() return false end
	env.IsControlKeyDown = function() return false end
	env.IsAltKeyDown = function() return false end
	env.GetCursorPosition = function() return 500, 400 end
	env.GetScreenWidth = function() return 1920 end
	env.GetScreenHeight = function() return 1080 end
	env.GetMouseFocus = function() return nil end
	env.ACCEPT, env.CANCEL, env.OKAY = "Accept", "Cancel", "Okay"
	env.NORMAL_FONT_COLOR = { r = 1, g = 0.82, b = 0 }
	env.HIGHLIGHT_FONT_COLOR = { r = 1, g = 1, b = 1 }
	env.ITEM_QUALITY_COLORS = {}
	env.RAID_CLASS_COLORS = {
		WARRIOR = { r = .78, g = .61, b = .43 }, MAGE = { r = .41, g = .8, b = .94 },
		ROGUE = { r = 1, g = .96, b = .41 }, DRUID = { r = 1, g = .49, b = .04 },
		HUNTER = { r = .67, g = .83, b = .45 }, SHAMAN = { r = .14, g = .35, b = 1 },
		PRIEST = { r = 1, g = 1, b = 1 }, WARLOCK = { r = .58, g = .51, b = .79 },
		PALADIN = { r = .96, g = .55, b = .73 },
	}
	env.FauxScrollFrame_GetOffset = function(f) return (f and f._fauxOffset) or 0 end
	env.FauxScrollFrame_Update = function() end
	env.FauxScrollFrame_OnVerticalScroll = function() end
	env.UIDropDownMenu_Initialize = function() end
	env.UIDropDownMenu_AddButton = function() end
	env.UIDropDownMenu_SetWidth = function() end
	env.UIDropDownMenu_SetText = function() end
	env.UIDropDownMenu_SetSelectedID = function() end
	env.UIDropDownMenu_CreateInfo = function() return {} end
	env.ToggleDropDownMenu = function() end
	env.CloseDropDownMenus = function() end
	env.OpenColorPicker = function() end
	env.ShowUIPanel = function() end
	env.HideUIPanel = function() end
	env.ChatFrame_OnHyperlinkShow = function() end
	env.ChatFrame_OnEvent = function() end
	env.ChatFrame_SendTell = function() end
	env.ChatEdit_ParseText = function() end
	env.GetContainerItemLink = function() return nil end
	env.GetInventoryItemLink = function() return nil end
	env.GetItemInfo = function() return nil end
	env.GetItemQualityColor = function() return 1, 1, 1 end
	env.SetItemRef = function() end
	env.ContainerFrameItemButton_OnClick = function() end
	env.PaperDollItemSlotButton_OnClick = function() end
	env.HandleModifiedItemClick = function() end
	env.TargetByName = function(n) table.insert(state.sent, { "target", n }) end
	env.InviteByName = function(n) table.insert(state.sent, { "invite", n }) end
	env.AddFriend = function(n) table.insert(state.sent, { "addfriend", n }) end
	env.AddIgnore = function(n) table.insert(state.sent, { "ignore", n }) end
	env.SendChatMessage = function(msg, chatType, lang, target)
		table.insert(state.sent, { "chat", msg, chatType, target })
	end
	state.friends = {}
	env.GetNumFriends = function() return #state.friends end
	env.GetFriendInfo = function(i)
		local f = state.friends[i]
		if not f then return nil end
		return f.name, f.level, f.class, f.area, f.online and 1 or nil, f.status
	end
	env.GetRealmName = function() return "TestRealm" end
	env.GetLocale = function() return opts.locale or "enUS" end
	env.GetNumPartyMembers = function() return 0 end
	env.GetNumRaidMembers = function() return 0 end
	env.IsAddOnLoaded = function() return false end
	env.GetAddOnInfo = function() return nil end
	env.seterrorhandler = function() end
	env.IsFriend = nil
	env.IsPlayerOnline = nil

	-- ---------------- units ----------------
	state.units = { player = { name = "Tester", class = "Mage", classToken = "MAGE", race = "Human", level = 60, guid = "0x0000000000000001" } }
	state.guidDB = {}
	env.UnitName = function(u) local x = state.units[u]; return x and x.name or nil end
	env.UnitExists = function(u)
		local x = state.units[u]
		if not x then return nil end
		if state.mods.superwow then return 1, x.guid end
		return 1
	end
	env.UnitClass = function(u) local x = state.units[u]; if x then return x.class, x.classToken end end
	env.UnitRace = function(u) local x = state.units[u]; if x then return x.race, string.upper(x.race) end end
	env.UnitLevel = function(u) local x = state.units[u]; return x and x.level or nil end
	env.UnitIsPlayer = function(u) return state.units[u] and 1 or nil end

	-- ---------------- mods ----------------
	local m = opts.mods or {}
	state.mods = m

	if m.classic then
		env.GetCurrentChatGUID = function() return state.curChatGuid end
		env.GetPlayerInfoByGUID = function(g)
			local x = state.guidDB[g]
			if x then return x.class, x.classToken, x.race, string.upper(x.race), 2, x.name, nil end
		end
		env.UnitGUID = function(u) local x = state.units[u]; return x and x.guid or nil end
		local cache = { byName = {} }
		state.pcache = cache
		cache.enabled = false
		env.C_PlayerCache = {
			SetEnabled = function(v) cache.enabled = v and true or false end,
			IsEnabled = function() return cache.enabled end,
			SetScanEnabled = function() end,
			IsScanEnabled = function() return true end,
			RememberPlayer = function(guid, name, classToken, raceToken)
				if not cache.enabled then return false end
				cache.byName[name] = { classToken = classToken, raceToken = raceToken, guid = guid }
				state.rememberCalls = (state.rememberCalls or 0) + 1
				return true
			end,
			GetPlayerInfoByName = function(name)
				if not cache.enabled then return nil end
				local e = cache.byName[name]
				if not e then return nil end
				local loc = (state.locClassByToken or {})[e.classToken] or e.classToken
				return loc, e.classToken, e.raceToken, e.raceToken, 2, name, nil, e.guid
			end,
		}
		local fl = { lastSend = -1e9 }
		env.C_FriendList = {
			SendWhoQueryByName = function(name)
				if not name or name == "" then return false end
				if state.now - fl.lastSend < 5 then return false end
				fl.lastSend = state.now
				state.classicWhoSends = (state.classicWhoSends or 0) + 1
				state.whoViaClassic = true
				state.engineSendWho("n-" .. name, true)
				return true
			end,
			IsWhoQueryPending = function() return (state.now - fl.lastSend) < 5 end,
		}
		env.FriendsFrame_OnEvent = function() end
	end

	if m.xp3 then
		env.UnitXP = function(a, b)
			if a == "nop" then return end
			table.insert(state.xpCalls, { a, b, state.now })
		end
	end

	if m.nampower then
		env.WriteCustomFile = function(p, c) state.files[p] = c; return true end
		env.ReadCustomFile = function(p) return state.files[p] end
		env.CustomFileExists = function(p) return state.files[p] ~= nil end
		env.GetUnitGUID = function(u) local x = state.units[u]; return x and x.guid or nil end
		env.GetCVar = function(k) local v = state.cvars[k]; if v == nil and k == "NP_ChatBubblesWhisper" then return "0" end; return v end
		env.SetCVar = function(k, v) state.cvars[k] = tostring(v) end
	else
		env.GetCVar = function(k) return state.cvars[k] end
		env.SetCVar = function(k, v) state.cvars[k] = tostring(v) end
	end

	if m.superwow then
		env.SUPERWOW_VERSION = "1.5"
	end

	if m.weird then
		env.GetWeirdUtilsVersion = function(n)
			local t = { logsessions = "1.0" }
			if n then return t[n] end
			return t
		end
		env.GetChatLogPath = function() return "Logs\\TestRealm\\Tester\\WoWChatLog_2026_10_11.txt" end
	end

	-- ---------------- /who server sim ----------------
	state.server = { players = {}, lastAccept = -1e9, lastSet = {}, profile = opts.whoProfile or { minGap = 0, latency = 0.3, dropMode = "silent" } }
	env.SetWhoToUI = function() end
	env.GetNumWhoResults = function() return #state.whoResults, #state.whoResults end
	env.GetWhoInfo = function(i)
		local p = state.whoResults[i]
		if not p then return nil end
		return p.name, p.guild, p.level, p.race, p.class, p.zone, ""
	end
	state.engineSendWho = function(q, viaClassic)
		local S = state.server
		local pr = S.profile
		local nm = string.match(q, "^n%-(.+)$")
		table.insert(state.whoSends, { t = state.now, q = q, classic = viaClassic and true or false })
		local accepted = (state.now - S.lastAccept) >= pr.minGap
		if pr.strict and not accepted then S.lastAccept = state.now end -- punishing server
		if accepted then
			S.lastAccept = state.now
			state.whoAccepted = state.whoAccepted + 1
			local res = {}
			local p = nm and S.players[nm]
			if p and p.online ~= false then res = { p } end
			S.lastSet = res
			table.insert(state.queue, { at = state.now + pr.latency, kind = "who", res = res })
		else
			state.whoDropped = state.whoDropped + 1
			if pr.dropMode == "stale" then
				table.insert(state.queue, { at = state.now + pr.latency, kind = "who", res = S.lastSet })
			end
		end
	end

	env.SendWho = function(q) state.engineSendWho(q, false) end

	-- ---------------- driver ----------------
	local function protectedCall(fn, ...)
		local ok, err = xpcall(fn, function(e) return tostring(e) .. "\n" .. debug.traceback("", 2) end, ...)
		if not ok then table.insert(state.errors, err) end
		return ok
	end
	env.H = nil

	local api = { env = env, state = state }

	function api.fire(event, a1, a2, a3, a4, a5, a6, a7, a8, a9)
		env.event = event
		env.arg1, env.arg2, env.arg3, env.arg4, env.arg5, env.arg6, env.arg7, env.arg8, env.arg9 = a1, a2, a3, a4, a5, a6, a7, a8, a9
		for _, f in ipairs(state.allFrames) do
			if f._events[event] and f._scripts.OnEvent then
				state.runScript(f, "OnEvent")
			end
		end
	end

	-- whisper helper: sets the chat GUID (ClassicAPI GetCurrentChatGUID) for the dispatch window
	function api.whisper(sender, msg, guid, flag)
		state.curChatGuid = guid
		api.fire("CHAT_MSG_WHISPER", msg, sender, "", "", sender, flag or "", 0, 0, "", 0, 1)
		state.curChatGuid = nil
	end
	function api.whisperOut(recipient, msg, guid)
		state.curChatGuid = guid
		api.fire("CHAT_MSG_WHISPER_INFORM", msg, recipient, "", "", recipient, "", 0, 0, "", 0, 1)
		state.curChatGuid = nil
	end

	function api.tick(dt)
		state.now = state.now + dt
		-- deliver due server events first
		local due = {}
		local rest = {}
		for _, q in ipairs(state.queue) do
			if q.at <= state.now then table.insert(due, q) else table.insert(rest, q) end
		end
		state.queue = rest
		for _, q in ipairs(due) do
			if q.kind == "who" then
				state.whoResults = q.res
				state.whoDelivered = state.whoDelivered + 1
				api.fire("WHO_LIST_UPDATE")
			end
		end
		env.arg1 = dt
		for _, f in ipairs(state.allFrames) do
			if f._scripts.OnUpdate and f:IsVisible() then
				state.runScript(f, "OnUpdate", dt)
			end
		end
	end

	function api.run(seconds, step)
		step = step or 1
		local n = math.floor(seconds / step)
		for _ = 1, n do api.tick(step) end
	end

	function api.slash(msg_cmd, msg)
		local key
		for k, _ in pairs(env.SlashCmdList) do
			local i = 1
			while env["SLASH_" .. k .. i] do
				if env["SLASH_" .. k .. i] == msg_cmd then key = k end
				i = i + 1
			end
		end
		if not key then table.insert(state.errors, "no slash handler for " .. msg_cmd); return false end
		return protectedCall(env.SlashCmdList[key], msg or "")
	end

	function api.loadAddon(dir, files, only)
		for _, f in ipairs(files) do
			local src = readfile(dir .. "/" .. f)
			local fn, err = load(src, "@MessageBox\\" .. f, "t", env)
			if not fn then error("syntax: " .. tostring(err)) end
			local ok, e = xpcall(fn, function(x) return tostring(x) .. "\n" .. debug.traceback("", 2) end)
			if not ok then table.insert(state.errors, "LOAD " .. f .. ": " .. e) end
		end
	end

	function api.tocFiles(dir)
		local files = {}
		for line in string.gmatch(readfile(dir .. "/MessageBox.toc"), "[^\r\n]+") do
			if not string.find(line, "^##") and string.find(line, "%.lua%s*$") then
				table.insert(files, (string.gsub(line, "%s+$", "")))
			end
		end
		return files
	end

	function api.chat() return state.chatLog end
	function api.errs() return state.errors end
	function api.clearErrs() state.errors = {} end
	function api.setPlayers(list) for _, p in ipairs(list) do state.server.players[p.name] = p end end
	function api.setGuids(list)
		state.locClassByToken = state.locClassByToken or {}
		for _, p in ipairs(list) do state.guidDB[p.guid] = p; state.locClassByToken[p.classToken] = p.class end
	end
	function api.setProfile(p) state.server.profile = p end
	function api.setFriends(list) state.friends = list end
	return api
end

return H
