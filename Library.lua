--!nocheck
--!nolint UnknownGlobal
--[[
	uiLib  ·  v1.0.0
	A dock + floating-window interface library for Roblox.

	    local Library = loadstring(game:HttpGet(URL .. "/Library.lua"))()
	    local UI = Library:Create({ Name = "My Hub", ToggleKey = Enum.KeyCode.K })
	    local Tab = UI:AddTab({ Name = "Main", Icon = "home" })
	    Tab:AddToggle({ Name = "Enabled", Flag = "Enabled", Callback = print })

	Layout
	    Hub ─ dock (bottom bar) ─ one item per tab
	     └─ Tab ─ floating window (or a page of the single shared window)
	         ├─ elements  (toggle, slider, dropdown, input, keybind, colour, button …)
	         └─ Group ─ collapsible box ─ elements / sub-tabs

	Full documentation: README.md
]]

local Library = { Version = "1.0.0" }

------------------------------------------------------------------------------
-- Services
------------------------------------------------------------------------------
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")
local TextService = game:GetService("TextService")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer

-- Executor-only globals. All of them are optional: inside Studio or a plain
-- LocalScript they are nil and the library falls back to in-memory behaviour.
local ex_gethui = gethui
local ex_writefile, ex_readfile = writefile, readfile
local ex_isfile, ex_isfolder = isfile, isfolder
local ex_makefolder, ex_listfiles, ex_delfile = makefolder, listfiles, delfile
local ex_setclipboard = setclipboard or toclipboard
local ex_getgenv = getgenv

------------------------------------------------------------------------------
-- Constants
------------------------------------------------------------------------------
local FONT_FAMILY = "rbxasset://fonts/families/GothamSSm.json"

local TITLE_H = 44 -- window title bar height
local DOCK_ITEM_W, DOCK_ITEM_H = 74, 58
local DOCK_GAP, DOCK_PAD, DOCK_MARGIN = 2, 8, 16
local MIN_WINDOW = Vector2.new(300, 180)

local EASE = Enum.EasingStyle.Quint
local OUT = Enum.EasingDirection.Out

local KEY_LABELS = {
	LeftShift = "LShift", RightShift = "RShift", LeftControl = "LCtrl", RightControl = "RCtrl",
	LeftAlt = "LAlt", RightAlt = "RAlt", Return = "Enter", Backspace = "Back", CapsLock = "Caps",
	Insert = "Ins", Delete = "Del", PageUp = "PgUp", PageDown = "PgDn", Escape = "Esc",
	One = "1", Two = "2", Three = "3", Four = "4", Five = "5",
	Six = "6", Seven = "7", Eight = "8", Nine = "9", Zero = "0",
	Minus = "-", Equals = "=", LeftBracket = "[", RightBracket = "]", Semicolon = ";",
	Quote = "'", Comma = ",", Period = ".", Slash = "/", BackSlash = "\\", Backquote = "`",
	MouseButton2 = "MB2", MouseButton3 = "MB3", None = "None",
}

------------------------------------------------------------------------------
-- Small helpers
------------------------------------------------------------------------------
local function New(className, props, children)
	local inst = Instance.new(className)
	local parent
	if props then
		for key, value in pairs(props) do
			if key == "Parent" then
				parent = value
			else
				inst[key] = value
			end
		end
	end
	if children then
		for _, child in ipairs(children) do
			child.Parent = inst
		end
	end
	if parent then
		inst.Parent = parent
	end
	return inst
end

local function Tween(inst, duration, goal, style, direction)
	local tween = TweenService:Create(inst, TweenInfo.new(duration, style or EASE, direction or OUT), goal)
	tween:Play()
	return tween
end

local function Corner(radius)
	return New("UICorner", { CornerRadius = UDim.new(0, radius) })
end

local function Round()
	return New("UICorner", { CornerRadius = UDim.new(1, 0) })
end

local function Padding(left, top, right, bottom)
	return New("UIPadding", {
		PaddingLeft = UDim.new(0, left),
		PaddingTop = UDim.new(0, top or left),
		PaddingRight = UDim.new(0, right or left),
		PaddingBottom = UDim.new(0, bottom or top or left),
	})
end

local function List(direction, padding, horizontal, vertical)
	return New("UIListLayout", {
		FillDirection = direction,
		Padding = UDim.new(0, padding or 0),
		SortOrder = Enum.SortOrder.LayoutOrder,
		HorizontalAlignment = horizontal or Enum.HorizontalAlignment.Left,
		VerticalAlignment = vertical or Enum.VerticalAlignment.Top,
	})
end

local function isPress(input)
	local kind = input.UserInputType
	return kind == Enum.UserInputType.MouseButton1 or kind == Enum.UserInputType.Touch
end

local function pointOf(input)
	return Vector2.new(input.Position.X, input.Position.Y)
end

local function safeCall(fn, ...)
	if type(fn) ~= "function" then
		return
	end
	task.spawn(function(...)
		local ok, err = pcall(fn, ...)
		if not ok then
			warn("[uiLib] callback error: " .. tostring(err))
		end
	end, ...)
end

local function viewport()
	local camera = Workspace.CurrentCamera
	if camera then
		local size = camera.ViewportSize
		if size.X > 0 and size.Y > 0 then
			return size
		end
	end
	return Vector2.new(1280, 720)
end

local function keyName(key)
	if key == nil then
		return nil
	end
	if type(key) == "string" then
		return key
	end
	if typeof(key) == "EnumItem" then
		if key.Value == 0 then
			return "None" -- Enum.KeyCode.Unknown
		end
		return key.Name
	end
	return nil
end

local function keyLabel(name)
	return KEY_LABELS[name] or name
end

local function decimalsOf(step)
	local text = string.gsub(string.format("%.6f", step), "0+$", "")
	local dot = string.find(text, ".", 1, true)
	if not dot then
		return 0
	end
	return #text - dot
end

local function sanitizeName(name)
	name = string.gsub(tostring(name or ""), "[^%w%-_ ]", "")
	name = string.gsub(name, "^%s+", "")
	name = string.gsub(name, "%s+$", "")
	return name
end

local function measure(text, size, width)
	local ok, bounds = pcall(function()
		return TextService:GetTextSize(text, size, Enum.Font.GothamMedium, Vector2.new(width, 10000))
	end)
	if ok and bounds then
		return bounds
	end
	-- rough fallback when the text service is unavailable
	local perLine = math.max(1, math.floor(width / (size * 0.55)))
	local lines = math.max(1, math.ceil(#text / perLine))
	return Vector2.new(math.min(width, #text * size * 0.55), lines * (size + 3))
end

local function avatarThumb()
	local id = LocalPlayer and LocalPlayer.UserId or 1
	return "rbxthumb://type=AvatarHeadShot&id=" .. tostring(id) .. "&w=150&h=150"
end

------------------------------------------------------------------------------
-- Icons  (Lucide set, name -> asset id).  Use them as  Icon = "swords"
------------------------------------------------------------------------------
-- stylua: ignore
local Icons = {
	["accessibility"]=10709751939, ["activity"]=10709752035, ["air-vent"]=10709752131, ["airplay"]=10709752254,
	["alarm-check"]=10709752405, ["alarm-clock"]=10709752630, ["alarm-clock-off"]=10709752508,
	["alarm-minus"]=10709752732, ["alarm-plus"]=10709752825, ["album"]=10709752906, ["alert-circle"]=10709752996,
	["alert-octagon"]=10709753064, ["alert-triangle"]=10709753149, ["align-center"]=10709753570,
	["align-center-horizontal"]=10709753272, ["align-center-vertical"]=10709753421,
	["align-end-horizontal"]=10709753692, ["align-end-vertical"]=10709753808,
	["align-horizontal-distribute-center"]=10747779791, ["align-horizontal-distribute-end"]=10747784534,
	["align-horizontal-distribute-start"]=10709754118, ["align-horizontal-justify-center"]=10709754204,
	["align-horizontal-justify-end"]=10709754317, ["align-horizontal-justify-start"]=10709754436,
	["align-horizontal-space-around"]=10709754590, ["align-horizontal-space-between"]=10709754749,
	["align-justify"]=10709759610, ["align-left"]=10709759764, ["align-right"]=10709759895,
	["align-start-horizontal"]=10709760051, ["align-start-vertical"]=10709760244,
	["align-vertical-distribute-center"]=10709760351, ["align-vertical-distribute-end"]=10709760434,
	["align-vertical-distribute-start"]=10709760612, ["align-vertical-justify-center"]=10709760814,
	["align-vertical-justify-end"]=10709761003, ["align-vertical-justify-start"]=10709761176,
	["align-vertical-space-around"]=10709761324, ["align-vertical-space-between"]=10709761434,
	["anchor"]=10709761530, ["angry"]=10709761629, ["annoyed"]=10709761722, ["aperture"]=10709761813,
	["apple"]=10709761889, ["archive"]=10709762233, ["archive-restore"]=10709762058, ["armchair"]=10709762327,
	["arrow-big-down"]=10747796644, ["arrow-big-left"]=10709762574, ["arrow-big-right"]=10709762727,
	["arrow-big-up"]=10709762879, ["arrow-down"]=10709767827, ["arrow-down-circle"]=10709763034,
	["arrow-down-left"]=10709767656, ["arrow-down-right"]=10709767750, ["arrow-left"]=10709768114,
	["arrow-left-circle"]=10709767936, ["arrow-left-right"]=10709768019, ["arrow-right"]=10709768347,
	["arrow-right-circle"]=10709768226, ["arrow-up"]=10709768939, ["arrow-up-circle"]=10709768432,
	["arrow-up-down"]=10709768538, ["arrow-up-left"]=10709768661, ["arrow-up-right"]=10709768787,
	["asterisk"]=10709769095, ["at-sign"]=10709769286, ["award"]=10709769406, ["axe"]=10709769508,
	["axis-3d"]=10709769598, ["baby"]=10709769732, ["backpack"]=10709769841, ["baggage-claim"]=10709769935,
	["banana"]=10709770005, ["banknote"]=10709770178, ["bar-chart"]=10709773755, ["bar-chart-2"]=10709770317,
	["bar-chart-3"]=10709770431, ["bar-chart-4"]=10709770560, ["bar-chart-horizontal"]=10709773669,
	["barcode"]=10747360675, ["baseline"]=10709773863, ["bath"]=10709773963, ["battery"]=10709774640,
	["battery-charging"]=10709774068, ["battery-full"]=10709774206, ["battery-low"]=10709774370,
	["battery-medium"]=10709774513, ["beaker"]=10709774756, ["bed"]=10709775036, ["bed-double"]=10709774864,
	["bed-single"]=10709774968, ["beer"]=10709775167, ["bell"]=10709775704, ["bell-minus"]=10709775241,
	["bell-off"]=10709775320, ["bell-plus"]=10709775448, ["bell-ring"]=10709775560, ["bike"]=10709775894,
	["binary"]=10709776050, ["bitcoin"]=10709776126, ["bluetooth"]=10709776655,
	["bluetooth-connected"]=10709776240, ["bluetooth-off"]=10709776344, ["bluetooth-searching"]=10709776501,
	["bold"]=10747813908, ["bomb"]=10709781460, ["bone"]=10709781605, ["book"]=10709781824,
	["book-open"]=10709781717, ["bookmark"]=10709782154, ["bookmark-minus"]=10709781919,
	["bookmark-plus"]=10709782044, ["bot"]=10709782230, ["box"]=10709782497, ["box-select"]=10709782342,
	["boxes"]=10709782582, ["briefcase"]=10709782662, ["brush"]=10709782758, ["bug"]=10709782845,
	["building"]=10709783051, ["building-2"]=10709782939, ["bus"]=10709783137, ["cake"]=10709783217,
	["calculator"]=10709783311, ["calendar"]=10709789505, ["calendar-check"]=10709783474,
	["calendar-check-2"]=10709783392, ["calendar-clock"]=10709783577, ["calendar-days"]=10709783673,
	["calendar-heart"]=10709783835, ["calendar-minus"]=10709783959, ["calendar-off"]=10709788784,
	["calendar-plus"]=10709788937, ["calendar-range"]=10709789053, ["calendar-search"]=10709789200,
	["calendar-x"]=10709789407, ["calendar-x-2"]=10709789329, ["camera"]=10709789686, ["camera-off"]=10747822677,
	["car"]=10709789810, ["carrot"]=10709789960, ["cast"]=10709790097, ["charge"]=10709790202,
	["check"]=10709790644, ["check-circle"]=10709790387, ["check-circle-2"]=10709790298,
	["check-square"]=10709790537, ["chef-hat"]=10709790757, ["cherry"]=10709790875, ["chevron-down"]=10709790948,
	["chevron-first"]=10709791015, ["chevron-last"]=10709791130, ["chevron-left"]=10709791281,
	["chevron-right"]=10709791437, ["chevron-up"]=10709791523, ["chevrons-down"]=10709796864,
	["chevrons-down-up"]=10709791632, ["chevrons-left"]=10709797151, ["chevrons-left-right"]=10709797006,
	["chevrons-right"]=10709797382, ["chevrons-right-left"]=10709797274, ["chevrons-up"]=10709797622,
	["chevrons-up-down"]=10709797508, ["chrome"]=10709797725, ["circle"]=10709798174, ["circle-dot"]=10709797837,
	["circle-ellipsis"]=10709797985, ["circle-slashed"]=10709798100, ["citrus"]=10709798276,
	["clapperboard"]=10709798350, ["clipboard"]=10709799288, ["clipboard-check"]=10709798443,
	["clipboard-copy"]=10709798574, ["clipboard-edit"]=10709798682, ["clipboard-list"]=10709798792,
	["clipboard-signature"]=10709798890, ["clipboard-type"]=10709798999, ["clipboard-x"]=10709799124,
	["clock"]=10709805144, ["clock-1"]=10709799535, ["clock-10"]=10709799718, ["clock-11"]=10709799818,
	["clock-12"]=10709799962, ["clock-2"]=10709803876, ["clock-3"]=10709803989, ["clock-4"]=10709804164,
	["clock-5"]=10709804291, ["clock-6"]=10709804435, ["clock-7"]=10709804599, ["clock-8"]=10709804784,
	["clock-9"]=10709804996, ["cloud"]=10709806740, ["cloud-cog"]=10709805262, ["cloud-drizzle"]=10709805371,
	["cloud-fog"]=10709805477, ["cloud-hail"]=10709805596, ["cloud-lightning"]=10709805727,
	["cloud-moon"]=10709805942, ["cloud-moon-rain"]=10709805838, ["cloud-off"]=10709806060,
	["cloud-rain"]=10709806277, ["cloud-rain-wind"]=10709806166, ["cloud-snow"]=10709806374,
	["cloud-sun"]=10709806631, ["cloud-sun-rain"]=10709806475, ["cloudy"]=10709806859, ["clover"]=10709806995,
	["code"]=10709810463, ["code-2"]=10709807111, ["codepen"]=10709810534, ["codesandbox"]=10709810676,
	["coffee"]=10709810814, ["cog"]=10709810948, ["coins"]=10709811110, ["columns"]=10709811261,
	["command"]=10709811365, ["compass"]=10709811445, ["component"]=10709811595, ["concierge-bell"]=10709811706,
	["connection"]=10747361219, ["contact"]=10709811834, ["contrast"]=10709811939, ["cookie"]=10709812067,
	["copy"]=10709812159, ["copyleft"]=10709812251, ["copyright"]=10709812311, ["corner-down-left"]=10709812396,
	["corner-down-right"]=10709812485, ["corner-left-down"]=10709812632, ["corner-left-up"]=10709812784,
	["corner-right-down"]=10709812939, ["corner-right-up"]=10709813094, ["corner-up-left"]=10709813185,
	["corner-up-right"]=10709813281, ["cpu"]=10709813383, ["croissant"]=10709818125, ["crop"]=10709818245,
	["cross"]=10709818399, ["crosshair"]=10709818534, ["crown"]=10709818626, ["cup-soda"]=10709818763,
	["curly-braces"]=10709818847, ["currency"]=10709818931, ["database"]=10709818996, ["delete"]=10709819059,
	["diamond"]=10709819149, ["dice-1"]=10709819266, ["dice-2"]=10709819361, ["dice-3"]=10709819508,
	["dice-4"]=10709819670, ["dice-5"]=10709819801, ["dice-6"]=10709819896, ["dices"]=10723343321,
	["diff"]=10723343416, ["disc"]=10723343537, ["divide"]=10723343805, ["divide-circle"]=10723343636,
	["divide-square"]=10723343737, ["dollar-sign"]=10723343958, ["download"]=10723344270,
	["download-cloud"]=10723344088, ["droplet"]=10723344432, ["droplets"]=10734883356, ["drumstick"]=10723344737,
	["edit"]=10734883598, ["edit-2"]=10723344885, ["edit-3"]=10723345088, ["egg"]=10723345518,
	["egg-fried"]=10723345347, ["electricity"]=10723345749, ["electricity-off"]=10723345643, ["equal"]=10723345990,
	["equal-not"]=10723345866, ["eraser"]=10723346158, ["euro"]=10723346372, ["expand"]=10723346553,
	["external-link"]=10723346684, ["eye"]=10723346959, ["eye-off"]=10723346871, ["factory"]=10723347051,
	["fan"]=10723354359, ["fast-forward"]=10723354521, ["feather"]=10723354671, ["figma"]=10723354801,
	["file"]=10723374641, ["file-archive"]=10723354921, ["file-audio"]=10723355148, ["file-audio-2"]=10723355026,
	["file-axis-3d"]=10723355272, ["file-badge"]=10723355622, ["file-badge-2"]=10723355451,
	["file-bar-chart"]=10723355887, ["file-bar-chart-2"]=10723355746, ["file-box"]=10723355989,
	["file-check"]=10723356210, ["file-check-2"]=10723356100, ["file-clock"]=10723356329,
	["file-code"]=10723356507, ["file-cog"]=10723356830, ["file-cog-2"]=10723356676, ["file-diff"]=10723357039,
	["file-digit"]=10723357151, ["file-down"]=10723357322, ["file-edit"]=10723357495, ["file-heart"]=10723357637,
	["file-image"]=10723357790, ["file-input"]=10723357933, ["file-json"]=10723364435, ["file-json-2"]=10723364361,
	["file-key"]=10723364605, ["file-key-2"]=10723364515, ["file-line-chart"]=10723364725,
	["file-lock"]=10723364957, ["file-lock-2"]=10723364861, ["file-minus"]=10723365254,
	["file-minus-2"]=10723365086, ["file-output"]=10723365457, ["file-pie-chart"]=10723365598,
	["file-plus"]=10723365877, ["file-plus-2"]=10723365766, ["file-question"]=10723365987,
	["file-scan"]=10723366167, ["file-search"]=10723366550, ["file-search-2"]=10723366340,
	["file-signature"]=10723366741, ["file-spreadsheet"]=10723366962, ["file-symlink"]=10723367098,
	["file-terminal"]=10723367244, ["file-text"]=10723367380, ["file-type"]=10723367606,
	["file-type-2"]=10723367509, ["file-up"]=10723367734, ["file-video"]=10723373884, ["file-video-2"]=10723367834,
	["file-volume"]=10723374172, ["file-volume-2"]=10723374030, ["file-warning"]=10723374276,
	["file-x"]=10723374544, ["file-x-2"]=10723374378, ["files"]=10723374759, ["film"]=10723374981,
	["filter"]=10723375128, ["fingerprint"]=10723375250, ["flag"]=10723375890, ["flag-off"]=10723375443,
	["flag-triangle-left"]=10723375608, ["flag-triangle-right"]=10723375727, ["flame"]=10723376114,
	["flashlight"]=10723376471, ["flashlight-off"]=10723376365, ["flask-conical"]=10734883986,
	["flask-round"]=10723376614, ["flip-horizontal"]=10723376884, ["flip-horizontal-2"]=10723376745,
	["flip-vertical"]=10723377138, ["flip-vertical-2"]=10723377026, ["flower"]=10747830374,
	["flower-2"]=10723377305, ["focus"]=10723377537, ["folder"]=10723387563, ["folder-archive"]=10723384478,
	["folder-check"]=10723384605, ["folder-clock"]=10723384731, ["folder-closed"]=10723384893,
	["folder-cog"]=10723385213, ["folder-cog-2"]=10723385036, ["folder-down"]=10723385338,
	["folder-edit"]=10723385445, ["folder-heart"]=10723385545, ["folder-input"]=10723385721,
	["folder-key"]=10723385848, ["folder-lock"]=10723386005, ["folder-minus"]=10723386127,
	["folder-open"]=10723386277, ["folder-output"]=10723386386, ["folder-plus"]=10723386531,
	["folder-search"]=10723386787, ["folder-search-2"]=10723386674, ["folder-symlink"]=10723386930,
	["folder-tree"]=10723387085, ["folder-up"]=10723387265, ["folder-x"]=10723387448, ["folders"]=10723387721,
	["form-input"]=10723387841, ["forward"]=10723388016, ["frame"]=10723394389, ["framer"]=10723394565,
	["frown"]=10723394681, ["fuel"]=10723394846, ["function-square"]=10723395041, ["gamepad"]=10723395457,
	["gamepad-2"]=10723395215, ["gauge"]=10723395708, ["gavel"]=10723395896, ["gem"]=10723396000,
	["ghost"]=10723396107, ["gift"]=10723396402, ["gift-card"]=10723396225, ["git-branch"]=10723396676,
	["git-branch-plus"]=10723396542, ["git-commit"]=10723396812, ["git-compare"]=10723396954,
	["git-fork"]=10723397049, ["git-merge"]=10723397165, ["git-pull-request"]=10723397431,
	["git-pull-request-closed"]=10723397268, ["git-pull-request-draft"]=10734884302, ["glass"]=10723397788,
	["glass-2"]=10723397529, ["glass-water"]=10723397678, ["glasses"]=10723397895, ["globe"]=10723404337,
	["globe-2"]=10723398002, ["grab"]=10723404472, ["graduation-cap"]=10723404691, ["grape"]=10723404822,
	["grid"]=10723404936, ["grip-horizontal"]=10723405089, ["grip-vertical"]=10723405236, ["hammer"]=10723405360,
	["hand"]=10723405649, ["hand-metal"]=10723405508, ["hard-drive"]=10723405749, ["hard-hat"]=10723405859,
	["hash"]=10723405975, ["haze"]=10723406078, ["headphones"]=10723406165, ["heart"]=10723406885,
	["heart-crack"]=10723406299, ["heart-handshake"]=10723406480, ["heart-off"]=10723406662,
	["heart-pulse"]=10723406795, ["help-circle"]=10723406988, ["hexagon"]=10723407092, ["highlighter"]=10723407192,
	["history"]=10723407335, ["home"]=10723407389, ["hourglass"]=10723407498, ["ice-cream"]=10723414308,
	["image"]=10723415040, ["image-minus"]=10723414487, ["image-off"]=10723414677, ["image-plus"]=10723414827,
	["import"]=10723415205, ["inbox"]=10723415335, ["indent"]=10723415494, ["indian-rupee"]=10723415642,
	["infinity"]=10723415766, ["info"]=10723415903, ["inspect"]=10723416057, ["italic"]=10723416195,
	["japanese-yen"]=10723416363, ["joystick"]=10723416527, ["key"]=10723416652, ["keyboard"]=10723416765,
	["lamp"]=10723417513, ["lamp-ceiling"]=10723416922, ["lamp-desk"]=10723417016, ["lamp-floor"]=10723417131,
	["lamp-wall-down"]=10723417240, ["lamp-wall-up"]=10723417356, ["landmark"]=10723417608,
	["languages"]=10723417703, ["laptop"]=10723423881, ["laptop-2"]=10723417797, ["lasso"]=10723424235,
	["lasso-select"]=10723424058, ["laugh"]=10723424372, ["layers"]=10723424505, ["layout"]=10723425376,
	["layout-dashboard"]=10723424646, ["layout-grid"]=10723424838, ["layout-list"]=10723424963,
	["layout-template"]=10723425187, ["leaf"]=10723425539, ["library"]=10723425615, ["life-buoy"]=10723425685,
	["lightbulb"]=10723425852, ["lightbulb-off"]=10723425762, ["line-chart"]=10723426393, ["link"]=10723426722,
	["link-2"]=10723426595, ["link-2-off"]=10723426513, ["list"]=10723433811, ["list-checks"]=10734884548,
	["list-end"]=10723426886, ["list-minus"]=10723426986, ["list-music"]=10723427081, ["list-ordered"]=10723427199,
	["list-plus"]=10723427334, ["list-start"]=10723427494, ["list-video"]=10723427619, ["list-x"]=10723433655,
	["loader"]=10723434070, ["loader-2"]=10723433935, ["locate"]=10723434557, ["locate-fixed"]=10723434236,
	["locate-off"]=10723434379, ["lock"]=10723434711, ["log-in"]=10723434830, ["log-out"]=10723434906,
	["luggage"]=10723434993, ["magnet"]=10723435069, ["mail"]=10734885430, ["mail-check"]=10723435182,
	["mail-minus"]=10723435261, ["mail-open"]=10723435342, ["mail-plus"]=10723435443,
	["mail-question"]=10723435515, ["mail-search"]=10734884739, ["mail-warning"]=10734885015,
	["mail-x"]=10734885247, ["mails"]=10734885614, ["map"]=10734886202, ["map-pin"]=10734886004,
	["map-pin-off"]=10734885803, ["maximize"]=10734886735, ["maximize-2"]=10734886496, ["medal"]=10734887072,
	["megaphone"]=10734887454, ["megaphone-off"]=10734887311, ["meh"]=10734887603, ["menu"]=10734887784,
	["message-circle"]=10734888000, ["message-square"]=10734888228, ["mic"]=10734888864, ["mic-2"]=10734888430,
	["mic-off"]=10734888646, ["microscope"]=10734889106, ["microwave"]=10734895076, ["milestone"]=10734895310,
	["minimize"]=10734895698, ["minimize-2"]=10734895530, ["minus"]=10734896206, ["minus-circle"]=10734895856,
	["minus-square"]=10734896029, ["monitor"]=10734896881, ["monitor-off"]=10734896360,
	["monitor-speaker"]=10734896512, ["moon"]=10734897102, ["more-horizontal"]=10734897250,
	["more-vertical"]=10734897387, ["mountain"]=10734897956, ["mountain-snow"]=10734897665, ["mouse"]=10734898592,
	["mouse-pointer"]=10734898476, ["mouse-pointer-2"]=10734898194, ["mouse-pointer-click"]=10734898355,
	["move"]=10734900011, ["move-3d"]=10734898756, ["move-diagonal"]=10734899164, ["move-diagonal-2"]=10734898934,
	["move-horizontal"]=10734899414, ["move-vertical"]=10734899821, ["music"]=10734905958, ["music-2"]=10734900215,
	["music-3"]=10734905665, ["music-4"]=10734905823, ["navigation"]=10734906744, ["navigation-2"]=10734906332,
	["navigation-2-off"]=10734906144, ["navigation-off"]=10734906580, ["network"]=10734906975,
	["newspaper"]=10734907168, ["octagon"]=10734907361, ["option"]=10734907649, ["outdent"]=10734907933,
	["package"]=10734909540, ["package-2"]=10734908151, ["package-check"]=10734908384,
	["package-minus"]=10734908626, ["package-open"]=10734908793, ["package-plus"]=10734909016,
	["package-search"]=10734909196, ["package-x"]=10734909375, ["paint-bucket"]=10734909847,
	["paintbrush"]=10734910187, ["paintbrush-2"]=10734910030, ["palette"]=10734910430, ["palmtree"]=10734910680,
	["paperclip"]=10734910927, ["party-popper"]=10734918735, ["pause"]=10734919336, ["pause-circle"]=10735024209,
	["pause-octagon"]=10734919143, ["pen-tool"]=10734919503, ["pencil"]=10734919691, ["percent"]=10734919919,
	["person-standing"]=10734920149, ["phone"]=10734921524, ["phone-call"]=10734920305,
	["phone-forwarded"]=10734920508, ["phone-incoming"]=10734920694, ["phone-missed"]=10734920845,
	["phone-off"]=10734921077, ["phone-outgoing"]=10734921288, ["pie-chart"]=10734921727,
	["piggy-bank"]=10734921935, ["pin"]=10734922324, ["pin-off"]=10734922180, ["pipette"]=10734922497,
	["pizza"]=10734922774, ["plane"]=10734922971, ["play"]=10734923549, ["play-circle"]=10734923214,
	["plus"]=10734924532, ["plus-circle"]=10734923868, ["plus-square"]=10734924219, ["podcast"]=10734929553,
	["pointer"]=10734929723, ["pound-sterling"]=10734929981, ["power"]=10734930466, ["power-off"]=10734930257,
	["printer"]=10734930632, ["puzzle"]=10734930886, ["quote"]=10734931234, ["radio"]=10734931596,
	["radio-receiver"]=10734931402, ["rectangle-horizontal"]=10734931777, ["rectangle-vertical"]=10734932081,
	["recycle"]=10734932295, ["redo"]=10734932822, ["redo-2"]=10734932586, ["refresh-ccw"]=10734933056,
	["refresh-cw"]=10734933222, ["refrigerator"]=10734933465, ["regex"]=10734933655, ["repeat"]=10734933966,
	["repeat-1"]=10734933826, ["reply"]=10734934252, ["reply-all"]=10734934132, ["rewind"]=10734934347,
	["rocket"]=10734934585, ["rocking-chair"]=10734939942, ["rotate-3d"]=10734940107, ["rotate-ccw"]=10734940376,
	["rotate-cw"]=10734940654, ["rss"]=10734940825, ["ruler"]=10734941018, ["russian-ruble"]=10734941199,
	["sailboat"]=10734941354, ["save"]=10734941499, ["scale"]=10734941912, ["scale-3d"]=10734941739,
	["scaling"]=10734942072, ["scan"]=10734942565, ["scan-face"]=10734942198, ["scan-line"]=10734942351,
	["scissors"]=10734942778, ["screen-share"]=10734943193, ["screen-share-off"]=10734942967,
	["scroll"]=10734943448, ["search"]=10734943674, ["send"]=10734943902, ["separator-horizontal"]=10734944115,
	["separator-vertical"]=10734944326, ["server"]=10734949856, ["server-cog"]=10734944444,
	["server-crash"]=10734944554, ["server-off"]=10734944668, ["settings"]=10734950309, ["settings-2"]=10734950020,
	["share"]=10734950813, ["share-2"]=10734950553, ["sheet"]=10734951038, ["shield"]=10734951847,
	["shield-alert"]=10734951173, ["shield-check"]=10734951367, ["shield-close"]=10734951535,
	["shield-off"]=10734951684, ["shirt"]=10734952036, ["shopping-bag"]=10734952273, ["shopping-cart"]=10734952479,
	["shovel"]=10734952773, ["shower-head"]=10734952942, ["shrink"]=10734953073, ["shrub"]=10734953241,
	["shuffle"]=10734953451, ["sidebar"]=10734954301, ["sidebar-close"]=10734953715, ["sidebar-open"]=10734954000,
	["sigma"]=10734954538, ["signal"]=10734961133, ["signal-high"]=10734954807, ["signal-low"]=10734955080,
	["signal-medium"]=10734955336, ["signal-zero"]=10734960878, ["siren"]=10734961284, ["skip-back"]=10734961526,
	["skip-forward"]=10734961809, ["skull"]=10734962068, ["slack"]=10734962339, ["slash"]=10734962600,
	["slice"]=10734963024, ["sliders"]=10734963400, ["sliders-horizontal"]=10734963191, ["smartphone"]=10734963940,
	["smartphone-charging"]=10734963671, ["smile"]=10734964441, ["smile-plus"]=10734964188,
	["snowflake"]=10734964600, ["sofa"]=10734964852, ["sort-asc"]=10734965115, ["sort-desc"]=10734965287,
	["speaker"]=10734965419, ["sprout"]=10734965572, ["square"]=10734965702, ["star"]=10734966248,
	["star-half"]=10734965897, ["star-off"]=10734966097, ["stethoscope"]=10734966384, ["sticker"]=10734972234,
	["sticky-note"]=10734972463, ["stop-circle"]=10734972621, ["stretch-horizontal"]=10734972862,
	["stretch-vertical"]=10734973130, ["strikethrough"]=10734973290, ["subscript"]=10734973457,
	["sun"]=10734974297, ["sun-dim"]=10734973645, ["sun-medium"]=10734973778, ["sun-moon"]=10734973999,
	["sun-snow"]=10734974130, ["sunrise"]=10734974522, ["sunset"]=10734974689, ["superscript"]=10734974850,
	["swiss-franc"]=10734975024, ["switch-camera"]=10734975214, ["sword"]=10734975486, ["swords"]=10734975692,
	["syringe"]=10734975932, ["table"]=10734976230, ["table-2"]=10734976097, ["tablet"]=10734976394,
	["tag"]=10734976528, ["tags"]=10734976739, ["target"]=10734977012, ["tent"]=10734981750,
	["terminal"]=10734982144, ["terminal-square"]=10734981995, ["text-cursor"]=10734982395,
	["text-cursor-input"]=10734982297, ["thermometer"]=10734983134, ["thermometer-snowflake"]=10734982571,
	["thermometer-sun"]=10734982771, ["thumbs-down"]=10734983359, ["thumbs-up"]=10734983629,
	["ticket"]=10734983868, ["timer"]=10734984606, ["timer-off"]=10734984138, ["timer-reset"]=10734984355,
	["toggle-left"]=10734984834, ["toggle-right"]=10734985040, ["tornado"]=10734985247, ["toy-brick"]=10747361919,
	["train"]=10747362105, ["trash"]=10747362393, ["trash-2"]=10747362241, ["tree-deciduous"]=10747362534,
	["tree-pine"]=10747362748, ["trees"]=10747363016, ["trending-down"]=10747363205, ["trending-up"]=10747363465,
	["triangle"]=10747363621, ["trophy"]=10747363809, ["truck"]=10747364031, ["tv"]=10747364593,
	["tv-2"]=10747364302, ["type"]=10747364761, ["umbrella"]=10747364971, ["underline"]=10747365191,
	["undo"]=10747365484, ["undo-2"]=10747365359, ["unlink"]=10747365771, ["unlink-2"]=10747397871,
	["unlock"]=10747366027, ["upload"]=10747366434, ["upload-cloud"]=10747366266, ["usb"]=10747366606,
	["user"]=10747373176, ["user-check"]=10747371901, ["user-cog"]=10747372167, ["user-minus"]=10747372346,
	["user-plus"]=10747372702, ["user-x"]=10747372992, ["users"]=10747373426, ["utensils"]=10747373821,
	["utensils-crossed"]=10747373629, ["venetian-mask"]=10747374003, ["verified"]=10747374131,
	["vibrate"]=10747374489, ["vibrate-off"]=10747374269, ["video"]=10747374938, ["video-off"]=10747374721,
	["view"]=10747375132, ["voicemail"]=10747375281, ["volume"]=10747376008, ["volume-1"]=10747375450,
	["volume-2"]=10747375679, ["volume-x"]=10747375880, ["wallet"]=10747376205, ["wand"]=10747376565,
	["wand-2"]=10747376349, ["watch"]=10747376722, ["waves"]=10747376931, ["webcam"]=10747381992,
	["wifi"]=10747382504, ["wifi-off"]=10747382268, ["wind"]=10747382750, ["wrap-text"]=10747383065,
	["wrench"]=10747383470, ["x"]=10747384394, ["x-circle"]=10747383819, ["x-octagon"]=10747384037,
	["x-square"]=10747384217, ["zoom-in"]=10747384552, ["zoom-out"]=10747384679,
}

local function resolveIcon(icon)
	if icon == nil or icon == "" then
		return nil
	end
	if type(icon) == "number" then
		return "rbxassetid://" .. string.format("%.0f", icon)
	end
	if type(icon) == "string" then
		local id = Icons[icon] or Icons[(string.gsub(icon, "^lucide%-", ""))]
		if id then
			return "rbxassetid://" .. string.format("%.0f", id)
		end
		if string.find(icon, "^rbx") or string.find(icon, "^http") then
			return icon
		end
		if tonumber(icon) then
			return "rbxassetid://" .. icon
		end
	end
	return nil
end

Library.Icons = Icons

------------------------------------------------------------------------------
-- Themes
------------------------------------------------------------------------------
local rgb = Color3.fromRGB

local BaseTheme = {
	Accent = rgb(245, 181, 106), -- highlights, active states
	OnAccent = rgb(30, 23, 14), -- text / knobs drawn on top of the accent
	Window = rgb(24, 24, 28),
	Dock = rgb(22, 22, 26),
	Group = rgb(28, 28, 33),
	Card = rgb(35, 35, 40),
	CardHover = rgb(42, 42, 48),
	Inset = rgb(19, 19, 23), -- inputs, segmented controls
	Stroke = rgb(46, 46, 53),
	StrokeLight = rgb(64, 64, 73),
	Text = rgb(236, 236, 241),
	SubText = rgb(164, 164, 174),
	Muted = rgb(112, 112, 123),
	Track = rgb(60, 60, 68), -- switch / slider rail
	Knob = rgb(242, 242, 246),
	Danger = rgb(240, 98, 98),
	Success = rgb(112, 212, 144),
	Warning = rgb(245, 196, 92),
	Info = rgb(112, 172, 250),
	Shadow = rgb(0, 0, 0),
}

local Presets = {
	Ember = { Accent = rgb(245, 181, 106), OnAccent = rgb(30, 23, 14) },
	Ocean = { Accent = rgb(104, 170, 252), OnAccent = rgb(10, 20, 36) },
	Mint = { Accent = rgb(112, 218, 168), OnAccent = rgb(10, 30, 22) },
	Rose = { Accent = rgb(246, 124, 158), OnAccent = rgb(36, 12, 20) },
	Violet = { Accent = rgb(172, 146, 252), OnAccent = rgb(22, 14, 40) },
	Mono = { Accent = rgb(232, 232, 238), OnAccent = rgb(20, 20, 24) },
}

Library.Themes = Presets

local function contrastOn(color)
	-- pick a readable colour for content placed on top of `color`
	local luminance = 0.299 * color.R + 0.587 * color.G + 0.114 * color.B
	if luminance > 0.55 then
		return color:Lerp(Color3.new(0, 0, 0), 0.86)
	end
	return Color3.new(1, 1, 1)
end

local function derive(theme)
	theme.AccentHover = theme.Accent:Lerp(Color3.new(1, 1, 1), 0.16)
	theme.Focus = theme.Accent:Lerp(theme.Stroke, 0.45)
	return theme
end

local function buildTheme(custom, accent)
	local theme = {}
	for key, value in pairs(BaseTheme) do
		theme[key] = value
	end
	if type(custom) == "string" then
		custom = Presets[custom]
	end
	if type(custom) == "table" then
		for key, value in pairs(custom) do
			theme[key] = value
		end
	end
	if typeof(accent) == "Color3" then
		theme.Accent = accent
		theme.OnAccent = contrastOn(accent)
	end
	return derive(theme)
end

------------------------------------------------------------------------------
-- Class tables (forward declarations)
------------------------------------------------------------------------------
local Hub = {}
Hub.__index = Hub

local Chrome = {}
Chrome.__index = Chrome

local Container = {}
Container.__index = Container

local Tab = setmetatable({}, Container)
Tab.__index = Tab

local Group = setmetatable({}, Container)
Group.__index = Group

local Page = setmetatable({}, Container)
Page.__index = Page

local Element = {}
Element.__index = Element

local GUI_CLASSES = {
	Frame = true, TextLabel = true, TextButton = true, TextBox = true,
	ImageLabel = true, ImageButton = true, ScrollingFrame = true,
}

local COLOR_PROPS = {
	BackgroundColor3 = true, TextColor3 = true, ImageColor3 = true, Color = true,
	PlaceholderColor3 = true, ScrollBarImageColor3 = true,
}

------------------------------------------------------------------------------
-- Hub : instance creation + theming
------------------------------------------------------------------------------

-- Like New(), but colour properties may be given as a theme key ("Card",
-- "Accent" ...). Those stay bound to the theme and update when it changes.
function Hub:_new(className, props, children)
	local inst = Instance.new(className)
	local parent
	if GUI_CLASSES[className] then
		inst.BorderSizePixel = 0
	end
	if props then
		for key, value in pairs(props) do
			if key == "Parent" then
				parent = value
			elseif COLOR_PROPS[key] and type(value) == "string" then
				self:_color(inst, key, value)
			else
				inst[key] = value
			end
		end
	end
	if children then
		for _, child in ipairs(children) do
			child.Parent = inst
		end
	end
	if parent then
		inst.Parent = parent
	end
	return inst
end

-- Point `inst[prop]` at a theme key, optionally animating to the new colour.
function Hub:_color(inst, prop, key, duration)
	local map = self._bindings[inst]
	if not map then
		map = {}
		self._bindings[inst] = map
	end
	map[prop] = key
	local color = self.Theme[key]
	if duration and duration > 0 then
		Tween(inst, duration, { [prop] = color })
	else
		inst[prop] = color
	end
end

function Hub:_stroke(parent, key, thickness)
	return self:_new("UIStroke", {
		Color = key or "Stroke",
		Thickness = thickness or 1,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Parent = parent,
	})
end

function Hub:_text(props)
	local base = {
		BackgroundTransparency = 1,
		FontFace = self.Fonts.Medium,
		TextSize = 13,
		TextColor3 = "Text",
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Center,
		Text = "",
	}
	for key, value in pairs(props) do
		base[key] = value
	end
	return self:_new("TextLabel", base)
end

function Hub:_icon(icon, size, colorKey, props)
	local base = {
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(size, size),
		Image = resolveIcon(icon) or "",
		ImageColor3 = colorKey or "Text",
		ScaleType = Enum.ScaleType.Fit,
	}
	if props then
		for key, value in pairs(props) do
			base[key] = value
		end
	end
	return self:_new("ImageLabel", base)
end

-- Soft drop shadow built from stacked translucent frames (no image asset).
function Hub:_shadow(parent, radius)
	for i = 1, 6 do
		local spread = i * 3
		self:_new("Frame", {
			Name = "Shadow",
			BackgroundColor3 = "Shadow",
			BackgroundTransparency = 0.89 + i * 0.015,
			Position = UDim2.fromOffset(-spread, -spread + 5),
			Size = UDim2.new(1, spread * 2, 1, spread * 2),
			ZIndex = 0,
			Parent = parent,
		}, { Corner(radius + spread) })
	end
end

function Hub:_connect(signal, fn)
	local connection = signal:Connect(fn)
	table.insert(self._connections, connection)
	return connection
end

function Hub:_applyTheme(animated)
	for inst, map in pairs(self._bindings) do
		for prop, key in pairs(map) do
			local color = self.Theme[key]
			if color then
				if animated then
					Tween(inst, 0.3, { [prop] = color })
				else
					inst[prop] = color
				end
			end
		end
	end
	for _, hook in ipairs(self._themeHooks) do
		safeCall(hook, self.Theme)
	end
end

--- Replace theme colours. Accepts a preset name ("Ocean") or a table of keys.
function Hub:SetTheme(theme)
	if type(theme) == "string" then
		theme = Presets[theme]
	end
	if type(theme) ~= "table" then
		return
	end
	for key, value in pairs(theme) do
		self.Theme[key] = value
	end
	derive(self.Theme)
	self:_applyTheme(true)
	self:_saveInterface()
end

--- Change only the accent colour (text on top of it is picked automatically).
function Hub:SetAccent(color)
	self.Theme.Accent = color
	self.Theme.OnAccent = contrastOn(color)
	derive(self.Theme)
	self:_applyTheme(true)
	self:_saveInterface()
end

------------------------------------------------------------------------------
-- Hub : construction
------------------------------------------------------------------------------
local function fsAvailable()
	return type(ex_writefile) == "function" and type(ex_readfile) == "function" and type(ex_isfile) == "function"
end

-- Hubs are tracked globally so re-running a script replaces the old interface
-- instead of stacking a second copy on top of it.
local function registry()
	local env = _G
	if type(ex_getgenv) == "function" then
		local ok, result = pcall(ex_getgenv)
		if ok and type(result) == "table" then
			env = result
		end
	end
	if type(env.__uiLibHubs) ~= "table" then
		env.__uiLibHubs = {}
	end
	return env.__uiLibHubs
end

local function makeFonts(family)
	local function face(weight)
		local ok, font = pcall(Font.new, family, weight, Enum.FontStyle.Normal)
		if ok and font then
			return font
		end
		return Font.fromEnum(Enum.Font.GothamMedium)
	end
	return {
		Medium = face(Enum.FontWeight.Medium),
		SemiBold = face(Enum.FontWeight.SemiBold),
		Bold = face(Enum.FontWeight.Bold),
	}
end

--[[
	Library:Create(options) -> Hub

	options
	    Name          string    shown in notifications / used for the config folder
	    ToggleKey     KeyCode   shows / hides the whole interface   (RightShift)
	    Accent        Color3    accent colour
	    Theme         string | table   preset name or colour overrides
	    Mode          "Windows" | "Single"   one window per tab, or one shared window
	    Scale         number    interface scale                     (1)
	    ConfigFolder  string    folder used for saved configs       (Name)
	    ShowAvatar    boolean   avatar in window title bars         (true)
	    Size          Vector2   size of the shared window in "Single" mode
	    Font          string    font family asset
	    MobileButton  boolean   floating show/hide button (auto on touch devices)
	    Parent        Instance  custom parent for the ScreenGui
]]
function Library:Create(options)
	options = options or {}
	local self = setmetatable({}, Hub)

	self.Name = tostring(options.Name or "uiLib")
	self.Folder = sanitizeName(options.ConfigFolder or self.Name)
	if self.Folder == "" then
		self.Folder = "uiLib"
	end
	self.Theme = buildTheme(options.Theme, options.Accent)
	self.Fonts = makeFonts(options.Font or FONT_FAMILY)
	self.Scale = math.clamp(tonumber(options.Scale) or 1, 0.5, 2)
	self.Mode = (options.Mode == "Single") and "Single" or "Windows"
	self.ShowAvatar = options.ShowAvatar ~= false
	self.Visible = true
	self.Flags = {}
	self.Tabs = {}

	self._toggleKey = keyName(options.ToggleKey) or "RightShift"
	self._chromes = {}
	self._bindings = setmetatable({}, { __mode = "k" })
	self._themeHooks = {}
	self._connections = {}
	self._keybinds = {}
	self._unloadHooks = {}
	self._memoryConfigs = {}
	self._z = 10

	self:_loadInterface()

	local hubs = registry()
	local previous = hubs[self.Name]
	if previous and previous ~= self then
		pcall(function()
			previous:Unload()
		end)
	end
	hubs[self.Name] = self

	self:_buildGui(options.Parent)
	self:_buildDock()
	self._shared = Chrome.new(self, { Title = self.Name, Size = options.Size or Vector2.new(660, 480) })
	self:_bindInput()

	local touchOnly = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
	if options.MobileButton == true or (options.MobileButton == nil and touchOnly) then
		self:_buildMobileButton()
	end
	return self
end

Library.CreateWindow = Library.Create

function Hub:_buildGui(parent)
	local gui = New("ScreenGui", {
		Name = self.Name,
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		IgnoreGuiInset = true,
		DisplayOrder = 9999,
	})

	-- custom parent -> executor gui container -> CoreGui -> PlayerGui
	local function try(getParent)
		if gui.Parent then
			return
		end
		pcall(function()
			gui.Parent = getParent()
		end)
	end
	if parent then
		try(function()
			return parent
		end)
	end
	if type(ex_gethui) == "function" then
		try(ex_gethui)
	end
	try(function()
		return game:GetService("CoreGui")
	end)
	try(function()
		return LocalPlayer:WaitForChild("PlayerGui")
	end)

	self.Gui = gui

	local function layer(name, zIndex)
		return New("Frame", {
			Name = name,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Size = UDim2.fromScale(1, 1),
			ZIndex = zIndex,
			Parent = gui,
		})
	end
	self._windowLayer = layer("Windows", 1)
	self._dockLayer = layer("Dock", 5)
	self._toastLayer = layer("Notifications", 20)
	self._overlay = layer("Overlay", 30)
	self._dialogLayer = layer("Dialogs", 40)
	self._tipLayer = layer("Tooltips", 50)
end

------------------------------------------------------------------------------
-- Hub : dock
------------------------------------------------------------------------------
function Hub:_buildDock()
	local root = self:_new("Frame", {
		Name = "Dock",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, 140),
		Size = UDim2.fromOffset(DOCK_PAD * 2, DOCK_ITEM_H + DOCK_PAD * 2),
		BackgroundTransparency = 1,
		Parent = self._dockLayer,
	})
	self._dockScale = New("UIScale", { Scale = self.Scale, Parent = root })
	self:_shadow(root, 18)

	local bar = self:_new("Frame", {
		Name = "Bar",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = "Dock",
		ZIndex = 2,
		Parent = root,
	}, { Corner(18), Padding(DOCK_PAD), List(Enum.FillDirection.Horizontal, DOCK_GAP) })
	self:_stroke(bar, "Stroke")

	self._dock = root
	self._dockBar = bar
	Tween(root, 0.7, { Position = UDim2.new(0.5, 0, 1, -DOCK_MARGIN) }, Enum.EasingStyle.Back)
end

function Hub:_addDockItem(tab)
	local button = self:_new("TextButton", {
		Name = tab.Name,
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = "Card",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(DOCK_ITEM_W, DOCK_ITEM_H),
		LayoutOrder = tab.Index,
		Parent = self._dockBar,
	}, { Corner(12) })

	local icon, iconSize
	if tab.Avatar then
		iconSize = 26
		icon = self:_new("ImageLabel", {
			BackgroundColor3 = "Card",
			Image = avatarThumb(),
			Size = UDim2.fromOffset(iconSize, iconSize),
		}, { Round() })
	else
		iconSize = 22
		icon = self:_icon(tab.Icon or "circle", iconSize, "SubText")
	end
	icon.AnchorPoint = Vector2.new(0.5, 0.5)
	icon.Position = UDim2.new(0.5, 0, 0, 22)
	icon.Parent = button

	local label = self:_text({
		Text = string.upper(tab.Name),
		FontFace = self.Fonts.Bold,
		TextSize = 10,
		TextColor3 = "SubText",
		TextXAlignment = Enum.TextXAlignment.Center,
		TextTruncate = Enum.TextTruncate.AtEnd,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -9),
		Size = UDim2.new(1, -4, 0, 12),
		Parent = button,
	})

	local pip = self:_new("Frame", {
		BackgroundColor3 = "Accent",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -3),
		Size = UDim2.fromOffset(0, 2),
		Parent = button,
	}, { Round() })

	tab._dock = { Button = button, Icon = icon, Label = label, Pip = pip, Tinted = not tab.Avatar }

	button.MouseEnter:Connect(function()
		Tween(button, 0.18, { BackgroundTransparency = 0.3 })
		Tween(icon, 0.3, { Position = UDim2.new(0.5, 0, 0, 20) }, Enum.EasingStyle.Back)
	end)
	button.MouseLeave:Connect(function()
		Tween(button, 0.18, { BackgroundTransparency = 1 })
		Tween(icon, 0.3, { Position = UDim2.new(0.5, 0, 0, 22) })
	end)
	button.MouseButton1Click:Connect(function()
		-- little "press" bounce, then open / close the tab
		icon.Size = UDim2.fromOffset(iconSize - 7, iconSize - 7)
		Tween(icon, 0.45, { Size = UDim2.fromOffset(iconSize, iconSize) }, Enum.EasingStyle.Back)
		tab:Toggle()
	end)

	local count = #self.Tabs
	self._dock.Size = UDim2.fromOffset(
		count * DOCK_ITEM_W + (count - 1) * DOCK_GAP + DOCK_PAD * 2,
		DOCK_ITEM_H + DOCK_PAD * 2
	)
end

function Hub:_dockState(tab, active)
	local dock = tab._dock
	if not dock then
		return
	end
	if dock.Tinted then
		self:_color(dock.Icon, "ImageColor3", active and "Accent" or "SubText", 0.2)
	end
	self:_color(dock.Label, "TextColor3", active and "Accent" or "SubText", 0.2)
	Tween(dock.Pip, 0.35, { Size = UDim2.fromOffset(active and 16 or 0, 2) }, active and Enum.EasingStyle.Back or EASE)
end

-- Screen position of a tab's dock item. Computed from the layout constants so
-- it is correct even before the dock has been rendered for the first time.
function Hub:_dockCenter(tab)
	local count = #self.Tabs
	local scale = self.Scale
	local view = viewport()
	local width = count * DOCK_ITEM_W + (count - 1) * DOCK_GAP + DOCK_PAD * 2
	local height = DOCK_ITEM_H + DOCK_PAD * 2
	local offset = -width / 2 + DOCK_PAD + (tab.Index - 1) * (DOCK_ITEM_W + DOCK_GAP) + DOCK_ITEM_W / 2
	return Vector2.new(view.X / 2 + offset * scale, view.Y - DOCK_MARGIN - height * scale / 2)
end

function Hub:_buildMobileButton()
	local button = self:_new("TextButton", {
		Name = "Toggle",
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = "Dock",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 14, 0.5, 0),
		Size = UDim2.fromOffset(46, 46),
		Parent = self._dockLayer,
	}, { Round() })
	self:_stroke(button, "StrokeLight")
	self:_icon("layout-grid", 20, "Accent", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Parent = button,
	})

	local moved = false
	button.InputBegan:Connect(function(input)
		if not isPress(input) then
			return
		end
		moved = false
		local start = pointOf(input)
		local origin = button.Position
		self:_beginDrag(input, function(point)
			local delta = point - start
			if delta.Magnitude > 6 then
				moved = true
			end
			if moved then
				button.Position = UDim2.new(
					origin.X.Scale, origin.X.Offset + delta.X,
					origin.Y.Scale, origin.Y.Offset + delta.Y
				)
			end
		end)
	end)
	button.MouseButton1Click:Connect(function()
		if not moved then
			self:Toggle()
		end
	end)
	self._mobileButton = button
end

------------------------------------------------------------------------------
-- Hub : input, focus, visibility
------------------------------------------------------------------------------
function Hub:_beginDrag(input, onMove, onStop)
	self._drag = { Input = input, Move = onMove, Stop = onStop }
end

function Hub:_bindInput()
	local MB1 = Enum.UserInputType.MouseButton1

	local function bindName(input)
		local kind = input.UserInputType
		if kind == Enum.UserInputType.Keyboard then
			if input.KeyCode.Value == 0 then
				return nil -- unidentified key
			end
			return input.KeyCode.Name
		elseif kind == Enum.UserInputType.MouseButton2 then
			return "MouseButton2"
		elseif kind == Enum.UserInputType.MouseButton3 then
			return "MouseButton3"
		end
		return nil
	end

	self:_connect(UserInputService.InputBegan, function(input, processed)
		if isPress(input) then
			self:_focusAt(pointOf(input))
			return
		end
		if self._binding then
			return -- a keybind is currently being re-assigned
		end
		local name = bindName(input)
		if not name then
			return
		end
		if input.UserInputType == Enum.UserInputType.Keyboard then
			if processed or UserInputService:GetFocusedTextBox() then
				return -- typing in a text box / chat
			end
		end
		self:_dispatchKey(name, true)
	end)

	self:_connect(UserInputService.InputEnded, function(input)
		local drag = self._drag
		if drag then
			local sameMouse = input.UserInputType == MB1 and drag.Input.UserInputType == MB1
			if input == drag.Input or sameMouse then
				self._drag = nil
				if drag.Stop then
					drag.Stop()
				end
			end
		end
		local name = bindName(input)
		if name then
			self:_dispatchKey(name, false)
		end
	end)

	self:_connect(UserInputService.InputChanged, function(input)
		local drag = self._drag
		if not drag then
			return
		end
		local kind = input.UserInputType
		local mouseDrag = kind == Enum.UserInputType.MouseMovement and drag.Input.UserInputType == MB1
		local touchDrag = kind == Enum.UserInputType.Touch and input == drag.Input
		if mouseDrag or touchDrag then
			drag.Move(pointOf(input))
		end
	end)
end

function Hub:_dispatchKey(name, down)
	if name == "None" then
		return -- "None" means unbound, it must never match a real input
	end
	if down and name == self._toggleKey then
		self:Toggle()
	end
	for _, bind in ipairs(self._keybinds) do
		if bind.Value == name then
			bind:_trigger(down)
		end
	end
end

function Hub:_focusAt(point)
	local best
	for _, chrome in ipairs(self._chromes) do
		if chrome.Shown then
			local pos, size = chrome.Root.AbsolutePosition, chrome.Root.AbsoluteSize
			local inside = point.X >= pos.X and point.X <= pos.X + size.X
				and point.Y >= pos.Y and point.Y <= pos.Y + size.Y
			if inside and (not best or chrome.Root.ZIndex > best.Root.ZIndex) then
				best = chrome
			end
		end
	end
	if best then
		self:_focus(best)
	end
end

function Hub:_focus(chrome)
	if self._focused == chrome then
		return
	end
	local previous = self._focused
	self._focused = chrome
	self._z = self._z + 1
	chrome.Root.ZIndex = self._z
	if previous then
		self:_color(previous.Stroke, "Color", "Stroke", 0.2)
	end
	self:_color(chrome.Stroke, "Color", "Focus", 0.2)
end

--- Show or hide the whole interface (dock + every open window).
function Hub:SetVisible(visible)
	visible = visible and true or false
	if self.Visible == visible or self._unloaded then
		return
	end
	self.Visible = visible
	self:_closePopup(true)
	self:_hideTip()

	if visible then
		Tween(self._dock, 0.5, { Position = UDim2.new(0.5, 0, 1, -DOCK_MARGIN) }, Enum.EasingStyle.Back)
	else
		local height = (DOCK_ITEM_H + DOCK_PAD * 2) * self.Scale
		Tween(self._dock, 0.35, { Position = UDim2.new(0.5, 0, 1, height + 40) }, EASE, Enum.EasingDirection.In)
		if not self._hintShown then
			self._hintShown = true
			local how = self._mobileButton and "Tap the floating button" or ("Press " .. keyLabel(self._toggleKey))
			self:Notify({ Title = self.Name, Content = how .. " to bring the interface back.", Duration = 4 })
		end
	end
	for _, chrome in ipairs(self._chromes) do
		chrome:_refresh()
	end
end

function Hub:Toggle()
	self:SetVisible(not self.Visible)
end

--- Interface scale ("DPI scale"), 0.5 - 2.
function Hub:SetScale(scale)
	scale = math.clamp(tonumber(scale) or 1, 0.5, 2)
	if scale == self.Scale then
		return
	end
	self.Scale = scale
	self:_closePopup(true)
	Tween(self._dockScale, 0.3, { Scale = scale })
	if self._toastScale then
		self._toastScale.Scale = scale
	end
	for _, chrome in ipairs(self._chromes) do
		if chrome.Shown then
			chrome:_settle()
		end
	end
	self:_saveInterface()
end

--- Key that shows / hides the interface. Accepts a KeyCode or its name.
function Hub:SetToggleKey(key)
	self._toggleKey = keyName(key) or "None"
	self:_saveInterface()
end

--- Run `fn` when the interface is unloaded (stop your loops here).
function Hub:OnUnload(fn)
	table.insert(self._unloadHooks, fn)
end

--- Remove the interface and disconnect everything it created.
function Hub:Unload()
	if self._unloaded then
		return
	end
	self._unloaded = true
	for _, hook in ipairs(self._unloadHooks) do
		pcall(hook)
	end
	for _, connection in ipairs(self._connections) do
		pcall(function()
			connection:Disconnect()
		end)
	end
	self._connections = {}
	self._keybinds = {}
	if self.Gui then
		self.Gui:Destroy()
	end
	local hubs = registry()
	if hubs[self.Name] == self then
		hubs[self.Name] = nil
	end
end

Hub.Destroy = Hub.Unload

-- Interface preferences (scale, mode, toggle key, accent) persist between runs.
function Hub:_loadInterface()
	if not fsAvailable() then
		return
	end
	local ok, data = pcall(function()
		local path = self.Folder .. "/interface.json"
		if not ex_isfile(path) then
			return nil
		end
		return HttpService:JSONDecode(ex_readfile(path))
	end)
	if not ok or type(data) ~= "table" then
		return
	end
	if type(data.Scale) == "number" then
		self.Scale = math.clamp(data.Scale, 0.5, 2)
	end
	if data.Mode == "Single" or data.Mode == "Windows" then
		self.Mode = data.Mode
	end
	if type(data.ToggleKey) == "string" then
		self._toggleKey = data.ToggleKey
	end
	if type(data.Accent) == "string" then
		local okColor, color = pcall(Color3.fromHex, data.Accent)
		if okColor and color then
			self.Theme.Accent = color
			self.Theme.OnAccent = contrastOn(color)
			derive(self.Theme)
		end
	end
end

function Hub:_saveInterface()
	if self._unloaded or not fsAvailable() then
		return
	end
	self._interfaceSave = (self._interfaceSave or 0) + 1
	local id = self._interfaceSave
	task.delay(0.5, function()
		if id ~= self._interfaceSave or self._unloaded then
			return
		end
		pcall(function()
			self:_ensureFolders()
			ex_writefile(self.Folder .. "/interface.json", HttpService:JSONEncode({
				Scale = self.Scale,
				Mode = self.Mode,
				ToggleKey = self._toggleKey,
				Accent = self.Theme.Accent:ToHex(),
			}))
		end)
	end)
end

------------------------------------------------------------------------------
-- Chrome : the floating window frame (title bar, controls, drag, resize)
------------------------------------------------------------------------------
function Chrome.new(hub, options)
	local self = setmetatable({}, Chrome)
	self.Hub = hub
	self.Tab = options.Tab -- nil for the shared window used by "Single" mode
	self.Opened = false -- what the user asked for
	self.Shown = false -- what is on screen (Opened and hub visible)
	self.Collapsed = false
	self.Maximized = false
	self._anim = 0

	-- keep the window inside the screen
	local view = viewport()
	local size = options.Size
	self.Size = Vector2.new(
		math.clamp(size.X, MIN_WINDOW.X, math.max(MIN_WINDOW.X, (view.X - 40) / hub.Scale)),
		math.clamp(size.Y, MIN_WINDOW.Y, math.max(MIN_WINDOW.Y, (view.Y - 150) / hub.Scale))
	)
	self.Pos = options.Position

	local root = hub:_new("Frame", {
		Name = "Window",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(self.Size.X, self.Size.Y),
		Visible = false,
		Parent = hub._windowLayer,
	})
	self.Root = root
	self.UIScale = New("UIScale", { Scale = hub.Scale, Parent = root })
	hub:_shadow(root, 12)

	local main = hub:_new("Frame", {
		Name = "Main",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = "Window",
		ClipsDescendants = true,
		ZIndex = 2,
		Parent = root,
	}, { Corner(12) })
	self.Stroke = hub:_stroke(main, "Stroke")

	-- title bar ----------------------------------------------------------
	local bar = hub:_new("Frame", {
		Name = "TitleBar",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, TITLE_H),
		Parent = main,
	})
	local grab = hub:_new("TextButton", {
		Name = "Grab",
		Text = "",
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Parent = bar,
	})

	local x = 12
	if hub.ShowAvatar then
		hub:_new("ImageLabel", {
			Name = "Avatar",
			BackgroundColor3 = "Card",
			Image = avatarThumb(),
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, x, 0.5, 0),
			Size = UDim2.fromOffset(24, 24),
			Parent = bar,
		}, { Round() })
		x = x + 34
	end
	self._headerX = x
	self.IconLabel = hub:_icon(nil, 16, "Text", {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, x, 0.5, 0),
		Parent = bar,
	})
	self.TitleLabel = hub:_text({
		FontFace = hub.Fonts.SemiBold,
		TextSize = 14,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = bar,
	})
	self:SetHeader(options.Title, options.Icon)

	local function control(icon, slot, hoverKey)
		local button = hub:_new("TextButton", {
			Name = icon,
			Text = "",
			AutoButtonColor = false,
			BackgroundColor3 = "Card",
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -10 - slot * 30, 0.5, 0),
			Size = UDim2.fromOffset(26, 26),
			ZIndex = 2,
			Parent = bar,
		}, { Corner(7) })
		local image = hub:_icon(icon, 14, "SubText", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Parent = button,
		})
		button.MouseEnter:Connect(function()
			Tween(button, 0.15, { BackgroundTransparency = 0 })
			hub:_color(image, "ImageColor3", hoverKey or "Text", 0.15)
		end)
		button.MouseLeave:Connect(function()
			Tween(button, 0.15, { BackgroundTransparency = 1 })
			hub:_color(image, "ImageColor3", "SubText", 0.15)
		end)
		return button
	end

	control("x", 0, "Danger").MouseButton1Click:Connect(function()
		self:_requestClose()
	end)
	control("minus", 1).MouseButton1Click:Connect(function()
		self:SetCollapsed(not self.Collapsed)
	end)
	control("maximize", 2).MouseButton1Click:Connect(function()
		self:SetMaximized(not self.Maximized)
	end)

	hub:_new("Frame", {
		Name = "Divider",
		BackgroundColor3 = "Stroke",
		Position = UDim2.fromOffset(0, TITLE_H),
		Size = UDim2.new(1, 0, 0, 1),
		Parent = main,
	})

	self.Body = hub:_new("Frame", {
		Name = "Body",
		BackgroundTransparency = 1,
		ClipsDescendants = true,
		Position = UDim2.fromOffset(0, TITLE_H + 1),
		Size = UDim2.new(1, 0, 1, -(TITLE_H + 1)),
		Parent = main,
	})

	-- resize grip ----------------------------------------------------------
	local grip = hub:_new("TextButton", {
		Name = "Resize",
		Text = "",
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -1, 1, -1),
		Size = UDim2.fromOffset(18, 18),
		ZIndex = 5,
		Parent = main,
	})
	hub:_new("Frame", {
		BackgroundColor3 = "Muted",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(9, 9),
		Size = UDim2.fromOffset(11, 1),
		Rotation = -45,
		Parent = grip,
	})
	hub:_new("Frame", {
		BackgroundColor3 = "Muted",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(12, 12),
		Size = UDim2.fromOffset(5, 1),
		Rotation = -45,
		Parent = grip,
	})
	self._grip = grip

	-- dragging (double click the title bar to maximise) --------------------
	local lastClick = 0
	grab.InputBegan:Connect(function(input)
		if not isPress(input) then
			return
		end
		local now = os.clock()
		if now - lastClick < 0.3 then
			lastClick = 0
			self:SetMaximized(not self.Maximized)
			return
		end
		lastClick = now
		if self.Maximized then
			return
		end
		hub:_closePopup()
		local start = pointOf(input)
		local origin = self.Pos or self:_defaultPos()
		hub:_beginDrag(input, function(point)
			self.Pos = self:_clamp(origin + (point - start))
			Tween(root, 0.1, { Position = UDim2.fromOffset(self.Pos.X, self.Pos.Y) }, Enum.EasingStyle.Quad)
		end)
	end)

	grip.InputBegan:Connect(function(input)
		if not isPress(input) or self.Maximized or self.Collapsed then
			return
		end
		hub:_closePopup()
		local start = pointOf(input)
		local origin = self.Size
		hub:_beginDrag(input, function(point)
			local delta = (point - start) / hub.Scale
			local limit = viewport() / hub.Scale
			self.Size = Vector2.new(
				math.clamp(origin.X + delta.X, MIN_WINDOW.X, math.max(MIN_WINDOW.X, limit.X)),
				math.clamp(origin.Y + delta.Y, MIN_WINDOW.Y, math.max(MIN_WINDOW.Y, limit.Y))
			)
			root.Size = UDim2.fromOffset(self.Size.X, self.Size.Y)
		end)
	end)

	table.insert(hub._chromes, self)
	return self
end

function Chrome:SetHeader(title, icon)
	local x = self._headerX
	local image = resolveIcon(icon)
	self.IconLabel.Visible = image ~= nil
	if image then
		self.IconLabel.Image = image
		x = x + 26
	end
	self.TitleLabel.Text = title or ""
	self.TitleLabel.Position = UDim2.fromOffset(x, 0)
	self.TitleLabel.Size = UDim2.new(1, -(x + 104), 1, 0)
end

function Chrome:_clamp(pos)
	local view = viewport()
	local scale = self.Hub.Scale
	local left = -(self.Size.X * scale - 90)
	local x = math.clamp(pos.X, left, math.max(left, view.X - 90))
	local y = math.clamp(pos.Y, 0, math.max(0, view.Y - TITLE_H * scale))
	return Vector2.new(math.floor(x + 0.5), math.floor(y + 0.5))
end

-- Windows without an explicit position cascade out from the screen centre.
function Chrome:_defaultPos()
	local view = viewport()
	local scale = self.Hub.Scale
	local index = self.Tab and self.Tab.Index or 1
	local shift = ((index - 1) % 6) * 32
	return self:_clamp(Vector2.new(
		(view.X - self.Size.X * scale) / 2 - 64 + shift,
		(view.Y - self.Size.Y * scale) / 2 - 56 + shift
	))
end

-- Point the window grows out of / shrinks back into: its dock item.
function Chrome:_anchor()
	local tab = self.Tab or self.Hub._active
	if tab and tab._dock then
		return self.Hub:_dockCenter(tab)
	end
	local scale = self.Hub.Scale
	return self.Pos + Vector2.new(self.Size.X, self.Size.Y) * scale / 2
end

function Chrome:_updateCanvas()
	if self.Tab then
		self.Tab._updateCanvas()
	else
		for _, tab in ipairs(self.Hub.Tabs) do
			tab._updateCanvas()
		end
	end
end

function Chrome:SetOpened(opened)
	self.Opened = opened and true or false
	self:_refresh()
end

-- Bring what is on screen in line with Opened / hub visibility, animated.
function Chrome:_refresh()
	local hub = self.Hub
	local want = self.Opened and hub.Visible
	if want == self.Shown then
		return
	end
	self.Shown = want
	self._anim = self._anim + 1
	local id = self._anim
	local root = self.Root

	if not self.Pos then
		self.Pos = self:_defaultPos()
	end
	local anchor = self:_anchor()

	if want then
		if not root.Visible then
			root.Visible = true
			root.Position = UDim2.fromOffset(anchor.X, anchor.Y)
			self.UIScale.Scale = 0.02
		end
		hub:_focus(self)
		Tween(root, 0.45, { Position = UDim2.fromOffset(self.Pos.X, self.Pos.Y) })
		-- grow slightly past the final size, then settle: a soft "pop"
		local grow = Tween(self.UIScale, 0.3, { Scale = hub.Scale * 1.035 }, Enum.EasingStyle.Quart)
		grow.Completed:Connect(function()
			if self._anim == id then
				self:_settle()
			end
		end)
	else
		Tween(root, 0.26, { Position = UDim2.fromOffset(anchor.X, anchor.Y) }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		local shrink = Tween(self.UIScale, 0.26, { Scale = 0.02 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		shrink.Completed:Connect(function()
			if self._anim == id then
				root.Visible = false
			end
		end)
	end
end

-- Ease the window to the hub's current scale and refresh scroll canvases.
function Chrome:_settle()
	self._anim = self._anim + 1
	local id = self._anim
	local tween = Tween(self.UIScale, 0.22, { Scale = self.Hub.Scale }, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
	tween.Completed:Connect(function()
		if self._anim == id then
			self:_updateCanvas()
		end
	end)
end

function Chrome:_requestClose()
	local tab = self.Tab or self.Hub._active
	if tab then
		tab:Close()
	else
		self:SetOpened(false)
	end
end

--- Collapse the window down to its title bar.
function Chrome:SetCollapsed(collapsed)
	collapsed = collapsed and true or false
	if collapsed and self.Maximized then
		self:SetMaximized(false)
	end
	self.Collapsed = collapsed
	self._grip.Visible = not collapsed
	Tween(self.Root, 0.35, { Size = UDim2.fromOffset(self.Size.X, collapsed and TITLE_H or self.Size.Y) })
end

--- Fill the screen (above the dock), or restore the previous size.
function Chrome:SetMaximized(maximized)
	maximized = maximized and true or false
	if maximized == self.Maximized then
		return
	end
	local hub = self.Hub
	local scale = hub.Scale
	self.Maximized = maximized
	hub:_closePopup(true)

	if not self.Pos then
		self.Pos = self:_defaultPos()
	end
	if maximized then
		self.Collapsed = false
		self._restore = { Pos = self.Pos, Size = self.Size }
		local view = viewport()
		local dockSpace = (DOCK_ITEM_H + DOCK_PAD * 2) * scale + DOCK_MARGIN + 12
		self.Pos = Vector2.new(12, 12)
		self.Size = Vector2.new(
			math.max(MIN_WINDOW.X, (view.X - 24) / scale),
			math.max(MIN_WINDOW.Y, (view.Y - 12 - dockSpace) / scale)
		)
	elseif self._restore then
		self.Pos = self._restore.Pos
		self.Size = self._restore.Size
	end
	self._grip.Visible = not maximized
	Tween(self.Root, 0.4, {
		Position = UDim2.fromOffset(self.Pos.X, self.Pos.Y),
		Size = UDim2.fromOffset(self.Size.X, self.Size.Y),
	})
end

------------------------------------------------------------------------------
-- Tabs
------------------------------------------------------------------------------
--[[
	Hub:AddTab(options) -> Tab

	options
	    Name      string    dock label
	    Title     string    window title                       (Name)
	    Icon      string    Lucide icon name or asset id
	    Avatar    boolean   show the player's avatar in the dock instead of the icon
	    Columns   number    1 - 3 content columns              (1)
	    Size      Vector2   window size
	    Position  Vector2   window position (top-left, pixels)
	    Open      boolean   open on start                      (first tab only)
]]
function Hub:AddTab(options)
	options = options or {}
	local tab = setmetatable({}, Tab)
	tab._hub = self
	tab._tab = tab
	tab.Name = tostring(options.Name or ("Tab " .. (#self.Tabs + 1)))
	tab.Title = tostring(options.Title or tab.Name)
	tab.Icon = options.Icon
	tab.Avatar = options.Avatar == true
	table.insert(self.Tabs, tab)
	tab.Index = #self.Tabs

	local columns = math.clamp(math.floor(tonumber(options.Columns) or 1), 1, 3)

	local scroll = self:_new("ScrollingFrame", {
		Name = tab.Name,
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		CanvasSize = UDim2.new(0, 0, 0, 0),
		ScrollBarThickness = 3,
		ScrollBarImageColor3 = "StrokeLight",
		ScrollingDirection = Enum.ScrollingDirection.Y,
	})
	local content = self:_new("Frame", {
		Name = "Content",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(12, 12),
		Size = UDim2.new(1, -24, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = scroll,
	}, { List(Enum.FillDirection.Horizontal, 8) })

	tab._columns = {}
	local trim = math.ceil(8 * (columns - 1) / columns)
	for index = 1, columns do
		tab._columns[index] = self:_new("Frame", {
			Name = "Column" .. index,
			BackgroundTransparency = 1,
			Size = UDim2.new(1 / columns, -trim, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			LayoutOrder = index,
			Parent = content,
		}, { List(Enum.FillDirection.Vertical, 8) })
	end
	tab._scroll = scroll
	tab._holder = tab._columns[1]

	-- The canvas is sized by hand: AutomaticCanvasSize misbehaves under UIScale.
	tab._updateCanvas = function()
		local scale = tab:_scale()
		if scale < 0.05 then
			return
		end
		scroll.CanvasSize = UDim2.fromOffset(0, math.ceil(content.AbsoluteSize.Y / scale) + 24)
	end
	content:GetPropertyChangedSignal("AbsoluteSize"):Connect(tab._updateCanvas)

	local size = options.Size or Vector2.new(columns > 1 and (330 * columns) or 390, 520)
	tab.Chrome = Chrome.new(self, {
		Tab = tab,
		Title = tab.Title,
		Icon = tab.Icon,
		Size = size,
		Position = options.Position,
	})
	self:_attach(tab)
	self:_addDockItem(tab)

	local open = options.Open
	if open == nil then
		open = tab.Index == 1
	end
	if open then
		task.defer(function()
			if not self._unloaded then
				tab:Open()
			end
		end)
	end
	return tab
end

-- Parent a tab's page to whichever window hosts it in the current mode.
function Hub:_attach(tab)
	if self.Mode == "Single" then
		tab._scroll.Parent = self._shared.Body
		tab._scroll.Visible = self._active == tab
	else
		tab._scroll.Parent = tab.Chrome.Body
		tab._scroll.Visible = true
	end
end

--- "Windows": every tab is its own window.  "Single": one window, the dock switches pages.
function Hub:SetMode(mode)
	mode = (mode == "Single") and "Single" or "Windows"
	if mode == self.Mode then
		return
	end
	local open = {}
	for _, tab in ipairs(self.Tabs) do
		if tab:IsOpen() then
			table.insert(open, tab)
			tab:Close()
		end
	end
	self._active = nil
	self.Mode = mode
	for _, tab in ipairs(self.Tabs) do
		self:_attach(tab)
	end
	if mode == "Single" then
		if open[1] then
			open[1]:Open()
		end
	else
		for _, tab in ipairs(open) do
			tab:Open()
		end
	end
	self:_saveInterface()
end

function Tab:_scale()
	local hub = self._hub
	local chrome = (hub.Mode == "Single") and hub._shared or self.Chrome
	return chrome.UIScale.Scale
end

function Tab:_holderFor(options)
	local index = type(options) == "table" and tonumber(options.Column) or 1
	return self._columns[math.clamp(index, 1, #self._columns)]
end

function Tab:IsOpen()
	local hub = self._hub
	if hub.Mode == "Single" then
		return hub._shared.Opened and hub._active == self
	end
	return self.Chrome.Opened
end

function Tab:Open()
	local hub = self._hub
	if hub.Mode ~= "Single" then
		self.Chrome:SetOpened(true)
		hub:_dockState(self, true)
		return
	end
	local shared = hub._shared
	local previous = hub._active
	if previous ~= self then
		if previous then
			previous._scroll.Visible = false
			hub:_dockState(previous, false)
		end
		hub._active = self
		shared:SetHeader(self.Title, self.Icon)
		self._scroll.Visible = true
		if shared.Opened then
			-- page change inside an open window: slide the new page up
			self._scroll.Position = UDim2.fromOffset(0, 14)
			Tween(self._scroll, 0.3, { Position = UDim2.fromOffset(0, 0) })
		end
	end
	shared:SetOpened(true)
	hub:_dockState(self, true)
	self._updateCanvas()
end

function Tab:Close()
	local hub = self._hub
	if hub.Mode ~= "Single" then
		self.Chrome:SetOpened(false)
		hub:_dockState(self, false)
	elseif hub._active == self then
		hub._shared:SetOpened(false)
		hub:_dockState(self, false)
	end
end

function Tab:Toggle()
	if self:IsOpen() then
		self:Close()
	else
		self:Open()
	end
end

------------------------------------------------------------------------------
-- Containers : anything that can hold elements (Tab, Group, sub-tab Page)
------------------------------------------------------------------------------
function Container:_holderFor(_options)
	return self._holder
end

--[[
	Tab:AddGroup(options) -> Group      collapsible box that holds elements

	options:  Name, Icon, Column (number), Collapsed (boolean)
]]
function Tab:AddGroup(options)
	options = options or {}
	local hub = self._hub
	local group = setmetatable({}, Group)
	group._hub = hub
	group._tab = self
	group.Name = tostring(options.Name or "Group")
	group.Collapsed = false
	group._anim = 0

	local frame = hub:_new("Frame", {
		Name = group.Name,
		BackgroundColor3 = "Group",
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = self:_holderFor(options),
	}, { Corner(10), List(Enum.FillDirection.Vertical, 0) })
	hub:_stroke(frame, "Stroke")

	local header = hub:_new("TextButton", {
		Name = "Header",
		Text = "",
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 42),
		LayoutOrder = 1,
		Parent = frame,
	})
	local x = 14
	if options.Icon then
		hub:_icon(options.Icon, 16, "Text", {
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, x, 0.5, 0),
			Parent = header,
		})
		x = x + 26
	end
	hub:_text({
		Text = group.Name,
		FontFace = hub.Fonts.SemiBold,
		TextSize = 14,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Position = UDim2.fromOffset(x, 0),
		Size = UDim2.new(1, -(x + 40), 1, 0),
		Parent = header,
	})
	group._chevron = hub:_icon("chevron-up", 14, "SubText", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(1, -21, 0.5, 0),
		Parent = header,
	})

	-- Clip is what animates when collapsing; Inner keeps its natural height.
	group._clip = hub:_new("Frame", {
		Name = "Clip",
		BackgroundTransparency = 1,
		ClipsDescendants = true,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = 2,
		Parent = frame,
	})
	group._inner = hub:_new("Frame", {
		Name = "Inner",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = group._clip,
	}, { Padding(8, 0, 8, 8), List(Enum.FillDirection.Vertical, 6) })
	group._holder = group._inner
	group.Instance = frame

	header.MouseButton1Click:Connect(function()
		group:SetCollapsed(not group.Collapsed)
	end)
	if options.Collapsed then
		group.Collapsed = true
		group._clip.AutomaticSize = Enum.AutomaticSize.None
		group._chevron.Rotation = 180
	end
	return group
end

function Group:SetCollapsed(collapsed)
	collapsed = collapsed and true or false
	if collapsed == self.Collapsed then
		return
	end
	self.Collapsed = collapsed
	self._anim = self._anim + 1
	local id = self._anim
	local clip = self._clip
	local scale = math.max(self._tab:_scale(), 0.05)

	self._hub:_closePopup()
	Tween(self._chevron, 0.3, { Rotation = collapsed and 180 or 0 })
	if collapsed then
		-- freeze the current height, then animate it away
		clip.Size = UDim2.new(1, 0, 0, clip.AbsoluteSize.Y / scale)
		clip.AutomaticSize = Enum.AutomaticSize.None
		Tween(clip, 0.3, { Size = UDim2.new(1, 0, 0, 0) })
	else
		local tween = Tween(clip, 0.3, { Size = UDim2.new(1, 0, 0, self._inner.AbsoluteSize.Y / scale) })
		tween.Completed:Connect(function()
			if self._anim == id then
				clip.AutomaticSize = Enum.AutomaticSize.Y
				clip.Size = UDim2.new(1, 0, 0, 0)
			end
		end)
	end
end

function Group:SetVisible(visible)
	self.Instance.Visible = visible and true or false
end

--[[
	Container:AddSubTabs({ "Main", "Settings" }) -> Page, Page ...

	A segmented control; every name gets its own page of elements.
	    local Main, Settings = Group:AddSubTabs({ "Main", "Settings" })
]]
function Container:AddSubTabs(names, options)
	local hub = self._hub
	local holder = self:_holderFor(options)
	local count = math.max(1, #names)

	local bar = hub:_new("Frame", {
		Name = "SubTabs",
		BackgroundColor3 = "Inset",
		Size = UDim2.new(1, 0, 0, 32),
		Parent = holder,
	}, { Corner(8) })
	local pill = hub:_new("Frame", {
		Name = "Pill",
		BackgroundColor3 = "Accent",
		Position = UDim2.new(0, 3, 0, 3),
		Size = UDim2.new(1 / count, -6, 1, -6),
		Parent = bar,
	}, { Corner(6) })

	local pages = {}
	local selected

	local function select(page, animated)
		if selected == page then
			return
		end
		hub:_closePopup()
		if selected then
			selected._holder.Visible = false
			hub:_color(selected._label, "TextColor3", "SubText", 0.2)
		end
		selected = page
		page._holder.Visible = true
		hub:_color(page._label, "TextColor3", "OnAccent", animated and 0.2 or 0)
		local goal = UDim2.new((page._index - 1) / count, 3, 0, 3)
		if animated then
			Tween(pill, 0.35, { Position = goal })
		else
			pill.Position = goal
		end
	end

	for index, name in ipairs(names) do
		local page = setmetatable({}, Page)
		page._hub = hub
		page._tab = self._tab
		page._index = index
		page.Name = tostring(name)

		local button = hub:_new("TextButton", {
			Name = page.Name,
			Text = "",
			AutoButtonColor = false,
			BackgroundTransparency = 1,
			Position = UDim2.fromScale((index - 1) / count, 0),
			Size = UDim2.fromScale(1 / count, 1),
			ZIndex = 2,
			Parent = bar,
		})
		page._label = hub:_text({
			Text = page.Name,
			FontFace = hub.Fonts.SemiBold,
			TextSize = 12,
			TextColor3 = "SubText",
			TextXAlignment = Enum.TextXAlignment.Center,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Size = UDim2.fromScale(1, 1),
			Parent = button,
		})
		page._holder = hub:_new("Frame", {
			Name = page.Name .. "Page",
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			Visible = false,
			Parent = holder,
		}, { List(Enum.FillDirection.Vertical, 6) })

		page.Select = function()
			select(page, true)
		end
		button.MouseButton1Click:Connect(page.Select)
		pages[index] = page
	end

	if pages[1] then
		select(pages[1], false)
	end
	return table.unpack(pages)
end

------------------------------------------------------------------------------
-- Element plumbing
------------------------------------------------------------------------------
local function class()
	local object = setmetatable({}, Element)
	object.__index = object
	return object
end

local Toggle, Slider, Dropdown, Keybind = class(), class(), class(), class()
local Input, ColorPicker, Button, Text = class(), class(), class(), class()
local Stats, Card = class(), class()

local function newElement(kind, container, options, instance)
	local element = setmetatable({}, kind)
	element._hub = container._hub
	element._tab = container._tab
	element.Instance = instance
	element.Flag = options.Flag
	element.Callback = options.Callback
	element._listeners = {}
	if options.Flag ~= nil then
		element._hub.Flags[options.Flag] = element
	end
	if options.Visible == false then
		instance.Visible = false
	end
	return element
end

function Element:_fire(...)
	safeCall(self.Callback, ...)
	for _, listener in ipairs(self._listeners) do
		safeCall(listener, ...)
	end
end

--- Run `fn` whenever the value changes (in addition to Callback).
function Element:OnChanged(fn)
	table.insert(self._listeners, fn)
	return self
end

function Element:Get()
	return self.Value
end

function Element:SetVisible(visible)
	self.Instance.Visible = visible and true or false
end

function Element:Destroy()
	local hub = self._hub
	if self.Flag ~= nil and hub.Flags[self.Flag] == self then
		hub.Flags[self.Flag] = nil
	end
	for index, bind in ipairs(hub._keybinds) do
		if bind == self then
			table.remove(hub._keybinds, index)
			break
		end
	end
	self.Instance:Destroy()
end

-- A rounded card that most elements sit on.
function Hub:_row(parent, height, clickable)
	local props = {
		Name = "Row",
		BackgroundColor3 = "Card",
		Size = UDim2.new(1, 0, 0, height),
		Parent = parent,
	}
	if clickable then
		props.Text = ""
		props.AutoButtonColor = false
	end
	local row = self:_new(clickable and "TextButton" or "Frame", props, { Corner(8) })
	self:_stroke(row, "Stroke")
	if clickable then
		row.MouseEnter:Connect(function()
			self:_color(row, "BackgroundColor3", "CardHover", 0.15)
		end)
		row.MouseLeave:Connect(function()
			self:_color(row, "BackgroundColor3", "Card", 0.15)
		end)
	end
	return row
end

-- Title (+ optional info icon with tooltip, + optional description) on the left.
function Hub:_rowText(row, options, reserve, widthScale)
	local block = self:_new("Frame", {
		Name = "Text",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(14, 0),
		Size = UDim2.new(widthScale or 1, -(14 + reserve), 1, 0),
		Parent = row,
	}, { List(Enum.FillDirection.Vertical, 3, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center) })

	local line = self:_new("Frame", {
		Name = "Line",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 16),
		LayoutOrder = 1,
		Parent = block,
	}, { List(Enum.FillDirection.Horizontal, 6, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center) })

	local title = self:_text({
		Name = "Title",
		Text = tostring(options.Name or ""),
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 16),
		LayoutOrder = 1,
		Parent = line,
	})
	if options.Tooltip then
		local info = self:_icon("info", 13, "Muted", { LayoutOrder = 2, Parent = line })
		self:_tooltip(info, tostring(options.Tooltip))
	end
	if options.Description then
		self:_text({
			Name = "Description",
			Text = tostring(options.Description),
			TextSize = 11,
			TextColor3 = "Muted",
			TextTruncate = Enum.TextTruncate.AtEnd,
			Size = UDim2.new(1, 0, 0, 13),
			LayoutOrder = 2,
			Parent = block,
		})
	end
	return title
end

function Hub:_ripple(clip, point, colorKey)
	local scale = math.max(self.Scale, 0.05)
	local origin = (point - clip.AbsolutePosition) / scale
	local reach = math.max(clip.AbsoluteSize.X, clip.AbsoluteSize.Y) / scale * 2.2
	local circle = self:_new("Frame", {
		BackgroundColor3 = colorKey,
		BackgroundTransparency = 0.8,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(origin.X, origin.Y),
		Size = UDim2.fromOffset(0, 0),
		Parent = clip,
	}, { Round() })
	local tween = Tween(circle, 0.55, {
		Size = UDim2.fromOffset(reach, reach),
		BackgroundTransparency = 1,
	}, Enum.EasingStyle.Quad)
	tween.Completed:Connect(function()
		circle:Destroy()
	end)
end

-- Shared button visual.  Styles: "Default" | "Accent" | "Primary" | "Danger"
function Hub:_button(parent, options)
	local style = options.Style or "Default"
	local primary = style == "Primary"
	local textKey = primary and "OnAccent"
		or (style == "Accent" and "Accent")
		or (style == "Danger" and "Danger")
		or "Text"
	local baseKey = primary and "Accent" or "Card"
	local hoverKey = primary and "AccentHover" or "CardHover"

	local button = self:_new("TextButton", {
		Name = "Button",
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = baseKey,
		Size = UDim2.new(1, 0, 0, 36),
		Parent = parent,
	}, { Corner(8) })
	if not primary then
		self:_stroke(button, "Stroke")
	end
	local clip = self:_new("Frame", {
		Name = "Ripples",
		BackgroundTransparency = 1,
		ClipsDescendants = true,
		Position = UDim2.fromOffset(1, 1),
		Size = UDim2.new(1, -2, 1, -2),
		Parent = button,
	})
	local content = self:_new("Frame", {
		Name = "Content",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Parent = button,
	}, { List(Enum.FillDirection.Horizontal, 7, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center) })
	if options.Icon then
		self:_icon(options.Icon, 14, textKey, { LayoutOrder = 1, Parent = content })
	end
	local label = self:_text({
		Name = "Label",
		Text = tostring(options.Name or "Button"),
		FontFace = self.Fonts.SemiBold,
		TextSize = 12,
		TextColor3 = textKey,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.new(0, 0, 1, 0),
		LayoutOrder = 2,
		Parent = content,
	})

	button.MouseEnter:Connect(function()
		self:_color(button, "BackgroundColor3", hoverKey, 0.15)
	end)
	button.MouseLeave:Connect(function()
		self:_color(button, "BackgroundColor3", baseKey, 0.15)
	end)
	button.InputBegan:Connect(function(input)
		if isPress(input) then
			self:_ripple(clip, pointOf(input), textKey)
		end
	end)
	return button, label
end

------------------------------------------------------------------------------
-- Toggle
------------------------------------------------------------------------------
--[[
	Container:AddToggle(options) -> Toggle
	options:  Name, Description, Tooltip, Default (boolean), Flag, Callback(value)
	methods:  :Set(value, silent)  :Get()  :OnChanged(fn)  :AddKeybind(options)
]]
function Container:AddToggle(options)
	options = options or {}
	local hub = self._hub
	local row = hub:_row(self:_holderFor(options), options.Description and 54 or 40, true)
	hub:_rowText(row, options, 64)

	local track = hub:_new("Frame", {
		Name = "Switch",
		BackgroundColor3 = "Track",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -14, 0.5, 0),
		Size = UDim2.fromOffset(36, 20),
		Parent = row,
	}, { Round() })
	local knob = hub:_new("Frame", {
		Name = "Knob",
		BackgroundColor3 = "Knob",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 3, 0.5, 0),
		Size = UDim2.fromOffset(14, 14),
		Parent = track,
	}, { Round() })

	local toggle = newElement(Toggle, self, options, row)
	toggle._container = self
	toggle._track = track
	toggle._knob = knob
	toggle.Value = options.Default == true
	toggle:_render(false)

	row.MouseButton1Click:Connect(function()
		toggle:Set(not toggle.Value)
	end)
	return toggle
end

function Toggle:_render(animated)
	local hub = self._hub
	local on = self.Value
	local duration = animated and 0.22 or 0
	hub:_color(self._track, "BackgroundColor3", on and "Accent" or "Track", duration)
	hub:_color(self._knob, "BackgroundColor3", on and "OnAccent" or "Knob", duration)
	local goal = UDim2.new(0, on and 19 or 3, 0.5, 0)
	if animated then
		-- the knob squashes as it leaves and springs into place
		self._knob.Size = UDim2.fromOffset(17, 12)
		Tween(self._knob, 0.32, { Size = UDim2.fromOffset(14, 14) })
		Tween(self._knob, 0.32, { Position = goal }, Enum.EasingStyle.Back)
	else
		self._knob.Position = goal
	end
end

function Toggle:Set(value, silent)
	value = value and true or false
	if value == self.Value then
		return
	end
	self.Value = value
	self:_render(true)
	if not silent then
		self:_fire(value)
	end
end

function Toggle:_save()
	return self.Value
end

function Toggle:_load(value)
	self:Set(value == true)
end

------------------------------------------------------------------------------
-- Keybind
------------------------------------------------------------------------------
local function buildKeybind(container, options, parent, position)
	local hub = container._hub
	local pill = hub:_new("TextButton", {
		Name = "Key",
		AutoButtonColor = false,
		BackgroundColor3 = "Inset",
		FontFace = hub.Fonts.SemiBold,
		TextSize = 11,
		TextColor3 = "SubText",
		Text = "",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = position,
		Size = UDim2.fromOffset(0, 22),
		AutomaticSize = Enum.AutomaticSize.X,
		Parent = parent,
	}, {
		Corner(6),
		Padding(9, 0, 9, 0),
		New("UISizeConstraint", { MinSize = Vector2.new(30, 22) }),
	})

	local bind = newElement(Keybind, container, options, pill)
	bind._pill = pill
	bind._stroke = hub:_stroke(pill, "Stroke")
	bind.Mode = options.Mode or "Toggle" -- "Toggle" | "Hold" | "Press"
	bind.State = false
	bind.Value = keyName(options.Default) or "None"
	bind.ChangedCallback = options.ChangedCallback
	pill.Text = keyLabel(bind.Value)

	pill.MouseButton1Click:Connect(function()
		bind:_listen()
	end)
	table.insert(hub._keybinds, bind)
	return bind
end

--[[
	Container:AddKeybind(options) -> Keybind
	options
	    Name, Description, Tooltip, Flag
	    Default          KeyCode | string
	    Mode             "Toggle" (default)  Callback(state) flips on every press
	                     "Hold"              Callback(true) on press, Callback(false) on release
	                     "Press"             Callback() on press
	    ChangedCallback  function(keyName)   the user picked another key
	Click the key to rebind.  Esc cancels, Backspace clears.
]]
function Container:AddKeybind(options)
	options = options or {}
	local hub = self._hub
	local row = hub:_row(self:_holderFor(options), options.Description and 54 or 40, false)
	hub:_rowText(row, options, 90)
	local bind = buildKeybind(self, options, row, UDim2.new(1, -12, 0.5, 0))
	bind.Instance = row
	if options.Visible == false then
		bind._pill.Visible = true -- hide the whole row, not just the key
		row.Visible = false
	end
	return bind
end

--- Attach a key to a toggle:  Toggle:AddKeybind({ Default = Enum.KeyCode.F, Mode = "Toggle" })
function Toggle:AddKeybind(options)
	options = options or {}
	local toggle = self
	local bind = buildKeybind(self._container, options, self.Instance, UDim2.new(1, -60, 0.5, 0))
	bind._custom = function(down)
		if bind.Mode == "Hold" then
			toggle:Set(down)
		elseif down then
			toggle:Set(not toggle.Value)
		end
	end
	return bind
end

function Keybind:_trigger(down)
	if self._listening then
		return
	end
	if self._custom then
		self._custom(down)
	elseif self.Mode == "Hold" then
		self.State = down
		safeCall(self.Callback, down)
	elseif down then
		if self.Mode == "Toggle" then
			self.State = not self.State
			safeCall(self.Callback, self.State)
		else
			safeCall(self.Callback)
		end
	end
end

function Keybind:_listen()
	local hub = self._hub
	if self._listening then
		return
	end
	self._listening = true
	hub._binding = true
	self._pill.Text = "..."
	hub:_color(self._stroke, "Color", "Accent", 0.15)
	hub:_color(self._pill, "TextColor3", "Accent", 0.15)

	local connection
	connection = UserInputService.InputBegan:Connect(function(input)
		local kind = input.UserInputType
		local name
		if kind == Enum.UserInputType.Keyboard then
			if input.KeyCode == Enum.KeyCode.Escape then
				name = self.Value
			elseif input.KeyCode == Enum.KeyCode.Backspace then
				name = "None"
			elseif input.KeyCode.Value == 0 then
				return -- unidentified key: keep listening
			else
				name = input.KeyCode.Name
			end
		elseif kind == Enum.UserInputType.MouseButton2 then
			name = "MouseButton2"
		elseif kind == Enum.UserInputType.MouseButton3 then
			name = "MouseButton3"
		elseif isPress(input) then
			name = self.Value -- clicked elsewhere: keep the current key
		else
			return
		end
		connection:Disconnect()
		hub:_color(self._stroke, "Color", "Stroke", 0.15)
		hub:_color(self._pill, "TextColor3", "SubText", 0.15)
		self:Set(name)
		-- release on the next step so this very key press does not also fire the bind
		task.defer(function()
			self._listening = false
			hub._binding = false
		end)
	end)
	table.insert(hub._connections, connection)
end

function Keybind:Set(key, silent)
	local name = keyName(key) or "None"
	local changed = name ~= self.Value
	self.Value = name
	self._pill.Text = keyLabel(name)
	if changed and not silent then
		safeCall(self.ChangedCallback, name)
		for _, listener in ipairs(self._listeners) do
			safeCall(listener, name)
		end
	end
end

function Keybind:_save()
	return self.Value
end

function Keybind:_load(value)
	if type(value) == "string" then
		self:Set(value)
	end
end

------------------------------------------------------------------------------
-- Slider
------------------------------------------------------------------------------
--[[
	Container:AddSlider(options) -> Slider
	options
	    Name, Tooltip, Flag, Callback(value)
	    Min, Max, Default   numbers
	    Step                snap increment (1).  0.1 / 0.01 give decimals
	    Suffix              text after the value, e.g. "%" or " studs"
	    Lazy                only fire the callback when the drag ends
	Click the value to type an exact number.
]]
function Container:AddSlider(options)
	options = options or {}
	local hub = self._hub
	local row = hub:_row(self:_holderFor(options), 56, false)

	local title = hub:_text({
		Name = "Title",
		Text = tostring(options.Name or ""),
		TextTruncate = Enum.TextTruncate.AtEnd,
		Position = UDim2.fromOffset(14, 10),
		Size = UDim2.new(1, -116, 0, 16),
		Parent = row,
	})
	if options.Tooltip then
		hub:_tooltip(title, tostring(options.Tooltip))
	end
	local box = hub:_new("TextBox", {
		Name = "Value",
		BackgroundTransparency = 1,
		ClearTextOnFocus = false,
		FontFace = hub.Fonts.SemiBold,
		TextSize = 12,
		TextColor3 = "Accent",
		TextXAlignment = Enum.TextXAlignment.Right,
		Text = "",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -14, 0, 10),
		Size = UDim2.fromOffset(84, 16),
		Parent = row,
	})
	local rail = hub:_new("Frame", {
		Name = "Rail",
		BackgroundColor3 = "Track",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 14, 1, -16),
		Size = UDim2.new(1, -28, 0, 4),
		Parent = row,
	}, { Round() })
	local fill = hub:_new("Frame", {
		Name = "Fill",
		BackgroundColor3 = "Accent",
		Size = UDim2.fromScale(0, 1),
		Parent = rail,
	}, { Round() })
	local knob = hub:_new("Frame", {
		Name = "Knob",
		BackgroundColor3 = "Knob",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0, 0.5),
		Size = UDim2.fromOffset(12, 12),
		ZIndex = 2,
		Parent = rail,
	}, { Round() })
	local hit = hub:_new("TextButton", {
		Name = "Hit",
		Text = "",
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 6, 1, -16),
		Size = UDim2.new(1, -12, 0, 26),
		ZIndex = 3,
		Parent = row,
	})

	local slider = newElement(Slider, self, options, row)
	slider._box, slider._fill, slider._knob = box, fill, knob
	slider.Min = tonumber(options.Min) or 0
	slider.Max = tonumber(options.Max) or 100
	if slider.Max <= slider.Min then
		slider.Max = slider.Min + 1
	end
	slider.Step = tonumber(options.Step) or 1
	if slider.Step <= 0 then
		slider.Step = 1
	end
	slider.Suffix = tostring(options.Suffix or "")
	slider.Lazy = options.Lazy == true
	slider._decimals = decimalsOf(slider.Step)
	slider.Value = slider:_snap(tonumber(options.Default) or slider.Min)
	slider:_render(false)

	local dragging = false
	local function resting()
		Tween(knob, 0.2, { Size = UDim2.fromOffset(12, 12) })
	end

	hit.InputBegan:Connect(function(input)
		if not isPress(input) then
			return
		end
		local function update(point)
			local width = rail.AbsoluteSize.X
			if width <= 0 then
				return
			end
			local alpha = math.clamp((point.X - rail.AbsolutePosition.X) / width, 0, 1)
			local value = slider:_snap(slider.Min + (slider.Max - slider.Min) * alpha)
			if value ~= slider.Value then
				slider.Value = value
				slider:_render(true)
				if slider.Lazy then
					slider._dirty = true
				else
					slider:_fire(value)
				end
			end
		end
		dragging = true
		Tween(knob, 0.25, { Size = UDim2.fromOffset(17, 17) }, Enum.EasingStyle.Back)
		update(pointOf(input))
		hub:_beginDrag(input, update, function()
			dragging = false
			resting()
			if slider._dirty then
				slider._dirty = false
				slider:_fire(slider.Value)
			end
		end)
	end)
	hit.MouseEnter:Connect(function()
		if not dragging then
			Tween(knob, 0.2, { Size = UDim2.fromOffset(14, 14) })
		end
	end)
	hit.MouseLeave:Connect(function()
		if not dragging then
			resting()
		end
	end)

	box.FocusLost:Connect(function()
		local number = tonumber((string.gsub(box.Text, "[^%d%.%-]", "")))
		if number then
			slider:Set(number)
		end
		slider:_render(false)
	end)
	return slider
end

function Slider:_snap(value)
	value = math.clamp(value, self.Min, self.Max)
	local steps = math.floor((value - self.Min) / self.Step + 0.5)
	value = math.clamp(self.Min + steps * self.Step, self.Min, self.Max)
	local factor = 10 ^ self._decimals
	return math.floor(value * factor + 0.5) / factor
end

function Slider:_render(animated)
	local alpha = (self.Value - self.Min) / (self.Max - self.Min)
	self._box.Text = string.format("%." .. self._decimals .. "f", self.Value) .. self.Suffix
	if animated then
		Tween(self._fill, 0.12, { Size = UDim2.fromScale(alpha, 1) }, Enum.EasingStyle.Quad)
		Tween(self._knob, 0.12, { Position = UDim2.fromScale(alpha, 0.5) }, Enum.EasingStyle.Quad)
	else
		self._fill.Size = UDim2.fromScale(alpha, 1)
		self._knob.Position = UDim2.fromScale(alpha, 0.5)
	end
end

function Slider:Set(value, silent)
	value = self:_snap(tonumber(value) or self.Min)
	if value == self.Value then
		return
	end
	self.Value = value
	self:_render(true)
	if not silent then
		self:_fire(value)
	end
end

function Slider:_save()
	return self.Value
end

function Slider:_load(value)
	if tonumber(value) then
		self:Set(tonumber(value))
	end
end

------------------------------------------------------------------------------
-- Popups (dropdown lists, colour pickers) live on an overlay above everything
------------------------------------------------------------------------------
function Hub:_popup(anchor, width, height, alignRight)
	self:_closePopup(true)
	local scale = self.Scale
	local overlay = self._overlay
	local origin = overlay.AbsolutePosition
	local view = overlay.AbsoluteSize
	if view.X <= 0 or view.Y <= 0 then
		view = viewport()
	end
	local pos = anchor.AbsolutePosition - origin
	local size = anchor.AbsoluteSize
	local w, h = width * scale, height * scale

	local x = alignRight and (pos.X + size.X - w) or pos.X
	x = math.clamp(x, 8, math.max(8, view.X - w - 8))
	local y = pos.Y + size.Y + 6
	local upward = false
	if y + h > view.Y - 8 and pos.Y - 6 - h >= 8 then
		upward = true -- not enough room below: open above the anchor
		y = pos.Y - 6
	end

	-- invisible full-screen button: a press anywhere else closes the popup
	local blocker = New("TextButton", {
		Name = "Blocker",
		Text = "",
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Parent = overlay,
	})
	local frame = self:_new("Frame", {
		Name = "Popup",
		BackgroundColor3 = "Group",
		ClipsDescendants = true,
		AnchorPoint = Vector2.new(0, upward and 1 or 0),
		Position = UDim2.fromOffset(x, y),
		Size = UDim2.fromOffset(width, 0),
		ZIndex = 2,
		Parent = overlay,
	}, { Corner(10), New("UIScale", { Scale = scale }) })
	self:_stroke(frame, "StrokeLight")
	local content = self:_new("Frame", {
		Name = "Content",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0, upward and 1 or 0),
		Position = UDim2.fromScale(0, upward and 1 or 0),
		Size = UDim2.new(1, 0, 0, height),
		Parent = frame,
	})
	Tween(frame, 0.28, { Size = UDim2.fromOffset(width, height) })

	local popup = { Frame = frame, Content = content, Open = true }
	function popup.Close(instant)
		if not popup.Open then
			return
		end
		popup.Open = false
		if self._popupRef == popup then
			self._popupRef = nil
		end
		blocker:Destroy()
		if popup.OnClose then
			popup.OnClose()
		end
		if instant then
			frame:Destroy()
		else
			local tween = Tween(frame, 0.16, { Size = UDim2.fromOffset(width, 0) }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
			tween.Completed:Connect(function()
				frame:Destroy()
			end)
		end
	end
	blocker.MouseButton1Down:Connect(function()
		popup.Close()
	end)
	self._popupRef = popup
	return popup
end

function Hub:_closePopup(instant)
	local popup = self._popupRef
	if popup then
		popup.Close(instant)
	end
end

------------------------------------------------------------------------------
-- Dropdown
------------------------------------------------------------------------------
--[[
	Container:AddDropdown(options) -> Dropdown
	options
	    Name, Description, Tooltip, Flag, Callback(value)
	    Values       { "A", "B", ... }
	    Default      value, or a list of values when Multi
	    Multi        boolean   pick several (value becomes a list)
	    AllowNone    boolean   single mode: clicking the selected item clears it
	    Placeholder  string    shown while nothing is selected
	    Search       boolean   search box (automatic when there are more than 8 values)
	methods:  :Set(value, silent)  :Get()  :SetValues(list)  :OnChanged(fn)
]]
function Container:AddDropdown(options)
	options = options or {}
	local hub = self._hub
	local row = hub:_row(self:_holderFor(options), options.Description and 54 or 40, true)
	hub:_rowText(row, options, 0, 0.55)

	local label = hub:_text({
		Name = "Value",
		TextSize = 12,
		TextColor3 = "SubText",
		TextXAlignment = Enum.TextXAlignment.Right,
		TextTruncate = Enum.TextTruncate.AtEnd,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -38, 0.5, 0),
		Size = UDim2.new(0.45, -40, 0, 16),
		Parent = row,
	})
	local chevron = hub:_icon("chevron-down", 14, "SubText", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(1, -21, 0.5, 0),
		Parent = row,
	})

	local dropdown = newElement(Dropdown, self, options, row)
	dropdown._label = label
	dropdown._chevron = chevron
	dropdown.Multi = options.Multi == true
	dropdown.AllowNone = options.AllowNone == true
	dropdown.Search = options.Search
	dropdown.Placeholder = tostring(options.Placeholder or (dropdown.Multi and "None" or "Select"))
	dropdown.Values = {}
	for _, value in ipairs(options.Values or {}) do
		table.insert(dropdown.Values, value)
	end
	dropdown:_assign(options.Default)
	dropdown:_render()

	row.MouseButton1Click:Connect(function()
		if dropdown._popup then
			hub:_closePopup()
		else
			dropdown:_open()
		end
	end)
	return dropdown
end

-- Normalise a requested value against the list of allowed values.
function Dropdown:_assign(value)
	if self.Multi then
		local wanted = {}
		if type(value) == "table" then
			for key, item in pairs(value) do
				if type(key) == "number" then
					wanted[item] = true
				elseif item then
					wanted[key] = true
				end
			end
		elseif value ~= nil then
			wanted[value] = true
		end
		local result = {}
		for _, item in ipairs(self.Values) do
			if wanted[item] then
				table.insert(result, item)
			end
		end
		self.Value = result
	else
		self.Value = nil
		for _, item in ipairs(self.Values) do
			if item == value then
				self.Value = item
				break
			end
		end
	end
end

function Dropdown:_selected(item)
	if self.Multi then
		return table.find(self.Value, item) ~= nil
	end
	return self.Value == item
end

function Dropdown:_render()
	local text
	if self.Multi then
		if #self.Value > 0 then
			local parts = {}
			for _, item in ipairs(self.Value) do
				table.insert(parts, tostring(item))
			end
			text = table.concat(parts, ", ")
		end
	elseif self.Value ~= nil then
		text = tostring(self.Value)
	end
	self._label.Text = text or self.Placeholder
	self._hub:_color(self._label, "TextColor3", text and "Accent" or "SubText", 0.15)

	if self._items then
		for _, entry in ipairs(self._items) do
			local selected = self:_selected(entry.Value)
			entry.Check.Visible = selected
			self._hub:_color(entry.Label, "TextColor3", selected and "Text" or "SubText", 0.12)
		end
	end
end

function Dropdown:_output()
	if self.Multi then
		return table.clone(self.Value)
	end
	return self.Value
end

function Dropdown:_pick(item)
	if self.Multi then
		local list = {}
		local removed = false
		for _, value in ipairs(self.Value) do
			if value == item then
				removed = true
			else
				table.insert(list, value)
			end
		end
		if not removed then
			table.insert(list, item)
		end
		self:_assign(list)
	else
		if self.Value == item then
			if not self.AllowNone then
				self._hub:_closePopup()
				return
			end
			self.Value = nil
		else
			self.Value = item
		end
		self._hub:_closePopup()
	end
	self:_render()
	self:_fire(self:_output())
end

function Dropdown:_open()
	local hub = self._hub
	local row = self.Instance
	local count = #self.Values
	local searchable = self.Search == true or (self.Search == nil and count > 8)
	local top = searchable and 38 or 0
	local listHeight = math.clamp(count, 1, 7) * 30 + 6
	local width = math.max(170, row.AbsoluteSize.X / math.max(hub.Scale, 0.05))

	local popup = hub:_popup(row, width, listHeight + top)
	self._popup = popup
	Tween(self._chevron, 0.28, { Rotation = 180 })
	popup.OnClose = function()
		self._popup = nil
		self._items = nil
		Tween(self._chevron, 0.28, { Rotation = 0 })
	end

	local list = hub:_new("ScrollingFrame", {
		Name = "List",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, top),
		Size = UDim2.new(1, 0, 1, -top),
		CanvasSize = UDim2.fromOffset(0, count * 30 + 6),
		ScrollBarThickness = 2,
		ScrollBarImageColor3 = "StrokeLight",
		ScrollingDirection = Enum.ScrollingDirection.Y,
		Parent = popup.Content,
	}, { Padding(4), List(Enum.FillDirection.Vertical, 2) })

	if count == 0 then
		hub:_text({
			Text = "Nothing to show",
			TextSize = 12,
			TextColor3 = "Muted",
			TextXAlignment = Enum.TextXAlignment.Center,
			Size = UDim2.new(1, 0, 0, 28),
			Parent = list,
		})
	end

	self._items = {}
	for index, item in ipairs(self.Values) do
		local button = hub:_new("TextButton", {
			Name = "Item",
			Text = "",
			AutoButtonColor = false,
			BackgroundColor3 = "Card",
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 28),
			LayoutOrder = index,
			Parent = list,
		}, { Corner(6) })
		local label = hub:_text({
			Text = tostring(item),
			TextSize = 12,
			TextColor3 = "SubText",
			TextTruncate = Enum.TextTruncate.AtEnd,
			Position = UDim2.fromOffset(10, 0),
			Size = UDim2.new(1, -40, 1, 0),
			Parent = button,
		})
		local check = hub:_icon("check", 14, "Accent", {
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -9, 0.5, 0),
			Visible = false,
			Parent = button,
		})
		self._items[index] = { Value = item, Button = button, Label = label, Check = check }

		button.MouseEnter:Connect(function()
			Tween(button, 0.12, { BackgroundTransparency = 0 })
		end)
		button.MouseLeave:Connect(function()
			Tween(button, 0.12, { BackgroundTransparency = 1 })
		end)
		button.MouseButton1Click:Connect(function()
			self:_pick(item)
		end)
	end
	self:_render()

	if searchable then
		local field = hub:_new("Frame", {
			Name = "Search",
			BackgroundColor3 = "Inset",
			Position = UDim2.fromOffset(6, 6),
			Size = UDim2.new(1, -12, 0, 28),
			Parent = popup.Content,
		}, { Corner(6) })
		hub:_stroke(field, "Stroke")
		hub:_icon("search", 13, "Muted", {
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, 9, 0.5, 0),
			Parent = field,
		})
		local box = hub:_new("TextBox", {
			BackgroundTransparency = 1,
			ClearTextOnFocus = false,
			FontFace = hub.Fonts.Medium,
			TextSize = 12,
			TextColor3 = "Text",
			PlaceholderText = "Search",
			PlaceholderColor3 = "Muted",
			Text = "",
			TextXAlignment = Enum.TextXAlignment.Left,
			Position = UDim2.fromOffset(28, 0),
			Size = UDim2.new(1, -36, 1, 0),
			Parent = field,
		})
		box:GetPropertyChangedSignal("Text"):Connect(function()
			local query = string.lower(box.Text)
			local shown = 0
			for _, entry in ipairs(self._items or {}) do
				local match = query == ""
					or string.find(string.lower(tostring(entry.Value)), query, 1, true) ~= nil
				entry.Button.Visible = match
				if match then
					shown = shown + 1
				end
			end
			list.CanvasSize = UDim2.fromOffset(0, shown * 30 + 6)
		end)
	end
end

function Dropdown:Set(value, silent)
	self:_assign(value)
	self:_render()
	if not silent then
		self:_fire(self:_output())
	end
end

--- Replace the list of options. Selections that no longer exist are dropped.
function Dropdown:SetValues(values)
	local current = self.Value
	self._hub:_closePopup()
	self.Values = {}
	for _, value in ipairs(values or {}) do
		table.insert(self.Values, value)
	end
	self:_assign(current)
	self:_render()
end

function Dropdown:_save()
	if self.Multi then
		return table.clone(self.Value)
	end
	if self.Value == nil then
		return false
	end
	return self.Value
end

function Dropdown:_load(value)
	if value == false then
		value = nil
	end
	self:Set(value)
end

------------------------------------------------------------------------------
-- Input (text box)
------------------------------------------------------------------------------
--[[
	Container:AddInput(options) -> Input
	options
	    Name          leave it out for a full-width box
	    Placeholder, Default, Flag
	    Numeric       only allow numbers
	    MaxLength     number
	    ClearOnFocus  boolean
	    Finished      true (default): Callback(text, enterPressed) when focus is lost
	                  false: Callback(text) on every change
	    Button        { Name = "Save", Callback = function(text) end }  inline action button
]]
function Container:AddInput(options)
	options = options or {}
	local hub = self._hub
	local named = options.Name ~= nil and options.Name ~= ""
	local row = hub:_row(self:_holderFor(options), 40, false)
	if named then
		hub:_rowText(row, options, 0, 0.5)
	end

	local action = options.Button
	local actionWidth = 0
	if type(action) == "table" then
		actionWidth = math.max(54, math.ceil(measure(tostring(action.Name or "OK"), 12, 300).X) + 28)
	end
	local right = 7 + (actionWidth > 0 and (actionWidth + 6) or 0)

	local field = hub:_new("Frame", {
		Name = "Field",
		BackgroundColor3 = "Inset",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -right, 0.5, 0),
		Size = named and UDim2.new(0.5, -right, 0, 26) or UDim2.new(1, -(right + 7), 0, 26),
		Parent = row,
	}, { Corner(6) })
	local stroke = hub:_stroke(field, "Stroke")
	local box = hub:_new("TextBox", {
		Name = "Box",
		BackgroundTransparency = 1,
		ClearTextOnFocus = options.ClearOnFocus == true,
		ClipsDescendants = true,
		FontFace = hub.Fonts.Medium,
		TextSize = 12,
		TextColor3 = "Text",
		PlaceholderText = tostring(options.Placeholder or ""),
		PlaceholderColor3 = "Muted",
		Text = tostring(options.Default or ""),
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(9, 0),
		Size = UDim2.new(1, -18, 1, 0),
		Parent = field,
	})

	local input = newElement(Input, self, options, row)
	input._box = box
	input.Value = box.Text
	local live = options.Finished == false
	local maxLength = tonumber(options.MaxLength)

	box.Focused:Connect(function()
		hub:_color(stroke, "Color", "Accent", 0.15)
	end)
	box:GetPropertyChangedSignal("Text"):Connect(function()
		local text = box.Text
		local clean = text
		if options.Numeric then
			clean = string.gsub(clean, "[^%d%.%-]", "")
		end
		if maxLength and #clean > maxLength then
			clean = string.sub(clean, 1, maxLength)
		end
		if clean ~= text then
			box.Text = clean -- re-enters this handler with the cleaned text
			return
		end
		if input.Value ~= text then
			input.Value = text
			if live and not input._silent then
				input:_fire(text)
			end
		end
	end)
	box.FocusLost:Connect(function(enterPressed)
		hub:_color(stroke, "Color", "Stroke", 0.15)
		if not live then
			input:_fire(input.Value, enterPressed)
		end
	end)

	if actionWidth > 0 then
		local button = hub:_button(row, { Name = action.Name or "OK", Style = action.Style or "Primary" })
		button.AnchorPoint = Vector2.new(1, 0.5)
		button.Position = UDim2.new(1, -7, 0.5, 0)
		button.Size = UDim2.fromOffset(actionWidth, 26)
		button.MouseButton1Click:Connect(function()
			safeCall(action.Callback, input.Value)
		end)
	end
	return input
end

function Input:Set(text, silent)
	text = tostring(text == nil and "" or text)
	self._silent = true
	self._box.Text = text
	self._silent = false
	self.Value = self._box.Text
	if not silent then
		self:_fire(self.Value, false)
	end
end

function Input:_save()
	return self.Value
end

function Input:_load(value)
	self:Set(value)
end

------------------------------------------------------------------------------
-- Colour picker
------------------------------------------------------------------------------
--[[
	Container:AddColorPicker(options) -> ColorPicker
	options:  Name, Description, Tooltip, Default (Color3), Flag, Callback(color)
]]
function Container:AddColorPicker(options)
	options = options or {}
	local hub = self._hub
	local row = hub:_row(self:_holderFor(options), options.Description and 54 or 40, true)
	hub:_rowText(row, options, 60)

	local default = typeof(options.Default) == "Color3" and options.Default or Color3.new(1, 1, 1)
	local swatch = hub:_new("Frame", {
		Name = "Swatch",
		BackgroundColor3 = default,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -14, 0.5, 0),
		Size = UDim2.fromOffset(32, 18),
		Parent = row,
	}, { Corner(5) })
	hub:_stroke(swatch, "StrokeLight")

	local picker = newElement(ColorPicker, self, options, row)
	picker._swatch = swatch
	picker.Value = default

	row.MouseButton1Click:Connect(function()
		if picker._popup then
			hub:_closePopup()
		else
			picker:_open()
		end
	end)
	return picker
end

function ColorPicker:_open()
	local hub = self._hub
	local popup = hub:_popup(self._swatch, 208, 208, true)
	local content = popup.Content
	self._popup = popup
	popup.OnClose = function()
		self._popup = nil
	end

	local hue, sat, val = self.Value:ToHSV()

	-- saturation / value square: hue colour, white fading right, black fading down
	local square = hub:_new("TextButton", {
		Name = "Square",
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = Color3.fromHSV(hue, 1, 1),
		Position = UDim2.fromOffset(12, 12),
		Size = UDim2.fromOffset(184, 120),
		Parent = content,
	}, { Corner(6) })
	hub:_new("Frame", {
		BackgroundColor3 = Color3.new(1, 1, 1),
		Size = UDim2.fromScale(1, 1),
		Parent = square,
	}, { Corner(6), New("UIGradient", { Transparency = NumberSequence.new(0, 1) }) })
	hub:_new("Frame", {
		BackgroundColor3 = Color3.new(0, 0, 0),
		Size = UDim2.fromScale(1, 1),
		Parent = square,
	}, { Corner(6), New("UIGradient", { Rotation = 90, Transparency = NumberSequence.new(1, 0) }) })
	local cursor = hub:_new("Frame", {
		Name = "Cursor",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(12, 12),
		ZIndex = 2,
		Parent = square,
	}, { Round(), New("UIStroke", { Color = Color3.new(1, 1, 1), Thickness = 2 }) })

	local keypoints = {}
	for index = 0, 6 do
		keypoints[index + 1] = ColorSequenceKeypoint.new(index / 6, Color3.fromHSV(index / 6, 1, 1))
	end
	local bar = hub:_new("TextButton", {
		Name = "Hue",
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = Color3.new(1, 1, 1),
		Position = UDim2.fromOffset(12, 142),
		Size = UDim2.fromOffset(184, 12),
		Parent = content,
	}, { Round(), New("UIGradient", { Color = ColorSequence.new(keypoints) }) })
	local barCursor = hub:_new("Frame", {
		Name = "Cursor",
		BackgroundColor3 = Color3.new(1, 1, 1),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(6, 16),
		ZIndex = 2,
		Parent = bar,
	}, { Round(), New("UIStroke", { Color = Color3.new(0, 0, 0), Transparency = 0.6, Thickness = 1 }) })

	local field = hub:_new("Frame", {
		Name = "Hex",
		BackgroundColor3 = "Inset",
		Position = UDim2.fromOffset(12, 166),
		Size = UDim2.fromOffset(184, 28),
		Parent = content,
	}, { Corner(6) })
	hub:_stroke(field, "Stroke")
	local hex = hub:_new("TextBox", {
		BackgroundTransparency = 1,
		ClearTextOnFocus = false,
		FontFace = hub.Fonts.Medium,
		TextSize = 12,
		TextColor3 = "Text",
		Text = "",
		TextXAlignment = Enum.TextXAlignment.Center,
		Size = UDim2.fromScale(1, 1),
		Parent = field,
	})

	local function apply(fire)
		local color = Color3.fromHSV(hue, sat, val)
		square.BackgroundColor3 = Color3.fromHSV(hue, 1, 1)
		cursor.Position = UDim2.fromScale(sat, 1 - val)
		barCursor.Position = UDim2.fromScale(hue, 0.5)
		hex.Text = "#" .. string.upper(color:ToHex())
		self.Value = color
		self._swatch.BackgroundColor3 = color
		if fire then
			self:_fire(color)
		end
	end
	apply(false)

	square.InputBegan:Connect(function(input)
		if not isPress(input) then
			return
		end
		local function update(point)
			local pos, size = square.AbsolutePosition, square.AbsoluteSize
			if size.X <= 0 or size.Y <= 0 then
				return
			end
			sat = math.clamp((point.X - pos.X) / size.X, 0, 1)
			val = 1 - math.clamp((point.Y - pos.Y) / size.Y, 0, 1)
			apply(true)
		end
		update(pointOf(input))
		hub:_beginDrag(input, update)
	end)
	bar.InputBegan:Connect(function(input)
		if not isPress(input) then
			return
		end
		local function update(point)
			local width = bar.AbsoluteSize.X
			if width <= 0 then
				return
			end
			hue = math.clamp((point.X - bar.AbsolutePosition.X) / width, 0, 1)
			apply(true)
		end
		update(pointOf(input))
		hub:_beginDrag(input, update)
	end)
	hex.FocusLost:Connect(function()
		local ok, color = pcall(Color3.fromHex, (string.gsub(hex.Text, "%s", "")))
		if ok and typeof(color) == "Color3" then
			hue, sat, val = color:ToHSV()
			apply(true)
		else
			apply(false)
		end
	end)
end

--- Accepts a Color3 or a hex string ("#ffaa00").
function ColorPicker:Set(color, silent)
	if type(color) == "string" then
		local ok, parsed = pcall(Color3.fromHex, color)
		color = ok and parsed or nil
	end
	if typeof(color) ~= "Color3" then
		return
	end
	if self._popup then
		self._hub:_closePopup()
	end
	self.Value = color
	self._swatch.BackgroundColor3 = color
	if not silent then
		self:_fire(color)
	end
end

function ColorPicker:_save()
	return self.Value:ToHex()
end

function ColorPicker:_load(value)
	self:Set(value)
end

------------------------------------------------------------------------------
-- Buttons
------------------------------------------------------------------------------
--[[
	Container:AddButton(options) -> Button
	options
	    Name, Icon, Callback()
	    Style     "Default" | "Accent" | "Primary" | "Danger"
	    Confirm   string   ask this question in a dialog before running the callback

	Container:AddButtonRow({ options, options, ... }) -> Button, Button ...
	    Several buttons side by side.
]]
local function makeButton(container, options, parent)
	local hub = container._hub
	local frame, label = hub:_button(parent, options)
	local button = newElement(Button, container, options, frame)
	button._label = label
	button.Name = tostring(options.Name or "Button")
	frame.MouseButton1Click:Connect(function()
		if options.Confirm then
			hub:Dialog({
				Title = button.Name,
				Content = tostring(options.Confirm),
				Buttons = {
					{ Name = "Cancel" },
					{ Name = "Confirm", Style = "Primary", Callback = function()
						button:_fire()
					end },
				},
			})
		else
			button:_fire()
		end
	end)
	return button
end

function Container:AddButton(options)
	options = options or {}
	return makeButton(self, options, self:_holderFor(options))
end

function Container:AddButtonRow(list, options)
	local hub = self._hub
	local count = math.max(1, #list)
	local frame = hub:_new("Frame", {
		Name = "Buttons",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 36),
		Parent = self:_holderFor(options),
	}, { List(Enum.FillDirection.Horizontal, 8) })
	local trim = math.ceil(8 * (count - 1) / count)
	local buttons = {}
	for index, item in ipairs(list) do
		local button = makeButton(self, item, frame)
		button.Instance.Size = UDim2.new(1 / count, -trim, 1, 0)
		button.Instance.LayoutOrder = index
		buttons[index] = button
	end
	return table.unpack(buttons)
end

function Button:SetName(name)
	self.Name = tostring(name)
	self._label.Text = self.Name
end

--- Run the button's callback as if it had been clicked.
function Button:Press()
	self:_fire()
end

------------------------------------------------------------------------------
-- Text elements: section headers, labels, paragraphs, dividers
------------------------------------------------------------------------------
function Text:Set(text)
	self._label.Text = self._upper and string.upper(tostring(text)) or tostring(text)
end

--- Small accent-coloured heading, e.g. "RUN OPTIONS".
function Container:AddSection(text, options)
	local hub = self._hub
	local label = hub:_text({
		Name = "Section",
		Text = string.upper(tostring(text or "")),
		FontFace = hub.Fonts.Bold,
		TextSize = 11,
		TextColor3 = "Accent",
		TextYAlignment = Enum.TextYAlignment.Bottom, -- breathing room above the heading
		Size = UDim2.new(1, 0, 0, 20),
		Parent = self:_holderFor(options),
	})
	local element = newElement(Text, self, options or {}, label)
	element._label = label
	element._upper = true
	return element
end

--- Plain wrapped text.
function Container:AddLabel(text, options)
	local hub = self._hub
	local label = hub:_text({
		Name = "Label",
		Text = tostring(text or ""),
		TextSize = 12,
		TextColor3 = "SubText",
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = self:_holderFor(options),
	})
	local element = newElement(Text, self, options or {}, label)
	element._label = label
	return element
end

--- Card with a title and wrapped body text.   options: Title, Content
function Container:AddParagraph(options)
	options = options or {}
	local hub = self._hub
	local card = hub:_new("Frame", {
		Name = "Paragraph",
		BackgroundColor3 = "Card",
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = self:_holderFor(options),
	}, { Corner(8), Padding(14, 11, 14, 12), List(Enum.FillDirection.Vertical, 4) })
	hub:_stroke(card, "Stroke")
	local title = hub:_text({
		Name = "Title",
		Text = tostring(options.Title or ""),
		FontFace = hub.Fonts.SemiBold,
		Size = UDim2.new(1, 0, 0, 16),
		LayoutOrder = 1,
		Visible = options.Title ~= nil,
		Parent = card,
	})
	local body = hub:_text({
		Name = "Body",
		Text = tostring(options.Content or ""),
		TextSize = 12,
		TextColor3 = "SubText",
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = 2,
		Parent = card,
	})
	local element = newElement(Text, self, options, card)
	element._label = body
	function element:SetTitle(text)
		title.Text = tostring(text)
		title.Visible = true
	end
	return element
end

function Container:AddDivider(options)
	local hub = self._hub
	local frame = hub:_new("Frame", {
		Name = "Divider",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 5),
		Parent = self:_holderFor(options),
	})
	hub:_new("Frame", {
		BackgroundColor3 = "Stroke",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.fromScale(0, 0.5),
		Size = UDim2.new(1, 0, 0, 1),
		Parent = frame,
	})
	return frame
end

------------------------------------------------------------------------------
-- Stats: a row of small "value over label" tiles (FPS / PING / PLAYERS ...)
------------------------------------------------------------------------------
--[[
	Container:AddStats({ { Label = "FPS", Value = "60" }, ... }) -> Stats
	    Stats:Set("FPS", 144)      or      Stats:Set(1, 144)
]]
function Container:AddStats(items, options)
	local hub = self._hub
	local count = math.max(1, #items)
	local frame = hub:_new("Frame", {
		Name = "Stats",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 56),
		Parent = self:_holderFor(options),
	}, { List(Enum.FillDirection.Horizontal, 8) })
	local trim = math.ceil(8 * (count - 1) / count)

	local stats = newElement(Stats, self, options or {}, frame)
	stats._values = {}
	for index, item in ipairs(items) do
		local tile = hub:_new("Frame", {
			Name = tostring(item.Label or index),
			BackgroundColor3 = "Card",
			Size = UDim2.new(1 / count, -trim, 1, 0),
			LayoutOrder = index,
			Parent = frame,
		}, { Corner(8) })
		hub:_stroke(tile, "Stroke")
		local value = hub:_text({
			Text = tostring(item.Value == nil and "-" or item.Value),
			FontFace = hub.Fonts.SemiBold,
			TextSize = 15,
			TextXAlignment = Enum.TextXAlignment.Center,
			Position = UDim2.fromOffset(0, 11),
			Size = UDim2.new(1, 0, 0, 18),
			Parent = tile,
		})
		hub:_text({
			Text = string.upper(tostring(item.Label or "")),
			FontFace = hub.Fonts.Bold,
			TextSize = 10,
			TextColor3 = "Muted",
			TextXAlignment = Enum.TextXAlignment.Center,
			Position = UDim2.fromOffset(0, 33),
			Size = UDim2.new(1, 0, 0, 12),
			Parent = tile,
		})
		stats._values[index] = value
		if item.Label ~= nil then
			stats._values[tostring(item.Label)] = value
		end
	end
	return stats
end

function Stats:Set(key, value)
	local label = self._values[key]
	if label then
		label.Text = tostring(value)
	end
end

------------------------------------------------------------------------------
-- Card: image + title + lines, with an optional right-hand column
------------------------------------------------------------------------------
--[[
	Container:AddCard(options) -> Card
	options
	    Title, Subtitle
	    Lines          { "Place ID: 123", ... }   small muted lines
	    Image          asset id / rbxthumb url / icon name
	    ImageRound     boolean (circle, for avatars)
	    RightTitle, RightSubtitle
	methods:  :SetTitle  :SetSubtitle  :SetLine(index, text)  :SetImage  :SetRight(title, subtitle)
]]
function Container:AddCard(options)
	options = options or {}
	local hub = self._hub
	local lines = options.Lines or {}
	local hasImage = options.Image ~= nil
	local hasRight = options.RightTitle ~= nil or options.RightSubtitle ~= nil

	local textHeight = 18 + (options.Subtitle ~= nil and 17 or 0) + #lines * 16
	local imageSize = hasImage and (#lines > 0 and 62 or 42) or 0
	local row = hub:_row(self:_holderFor(options), math.max(textHeight, imageSize) + 26, false)

	local card = newElement(Card, self, options, row)
	card._lines = {}

	local x = 14
	if hasImage then
		card._image = hub:_new("ImageLabel", {
			Name = "Image",
			BackgroundColor3 = "Inset",
			Image = resolveIcon(options.Image) or tostring(options.Image),
			ScaleType = Enum.ScaleType.Crop,
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, x, 0.5, 0),
			Size = UDim2.fromOffset(imageSize, imageSize),
			Parent = row,
		}, { options.ImageRound and Round() or Corner(8) })
		x = x + imageSize + 14
	end

	local rightWidth = hasRight and 130 or 0
	local block = hub:_new("Frame", {
		Name = "Text",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(x, 0),
		Size = UDim2.new(1, -(x + 14 + rightWidth), 1, 0),
		Parent = row,
	}, { List(Enum.FillDirection.Vertical, 2, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center) })
	card._title = hub:_text({
		Name = "Title",
		Text = tostring(options.Title or ""),
		FontFace = hub.Fonts.SemiBold,
		TextSize = 14,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Size = UDim2.new(1, 0, 0, 16),
		LayoutOrder = 1,
		Parent = block,
	})
	card._subtitle = hub:_text({
		Name = "Subtitle",
		Text = tostring(options.Subtitle or ""),
		TextSize = 12,
		TextColor3 = "SubText",
		TextTruncate = Enum.TextTruncate.AtEnd,
		Size = UDim2.new(1, 0, 0, 15),
		LayoutOrder = 2,
		Visible = options.Subtitle ~= nil,
		Parent = block,
	})
	for index, line in ipairs(lines) do
		card._lines[index] = hub:_text({
			Name = "Line" .. index,
			Text = tostring(line),
			TextSize = 11,
			TextColor3 = "Muted",
			TextTruncate = Enum.TextTruncate.AtEnd,
			Size = UDim2.new(1, 0, 0, 14),
			LayoutOrder = 2 + index,
			Parent = block,
		})
	end

	if hasRight then
		local right = hub:_new("Frame", {
			Name = "Right",
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -14, 0, 0),
			Size = UDim2.new(0, rightWidth, 1, 0),
			Parent = row,
		}, { List(Enum.FillDirection.Vertical, 2, Enum.HorizontalAlignment.Right, Enum.VerticalAlignment.Center) })
		card._rightTitle = hub:_text({
			Text = tostring(options.RightTitle or ""),
			FontFace = hub.Fonts.SemiBold,
			TextXAlignment = Enum.TextXAlignment.Right,
			Size = UDim2.new(1, 0, 0, 16),
			LayoutOrder = 1,
			Parent = right,
		})
		card._rightSubtitle = hub:_text({
			Text = tostring(options.RightSubtitle or ""),
			TextSize = 11,
			TextColor3 = "Muted",
			TextXAlignment = Enum.TextXAlignment.Right,
			Size = UDim2.new(1, 0, 0, 14),
			LayoutOrder = 2,
			Parent = right,
		})
	end
	return card
end

function Card:SetTitle(text)
	self._title.Text = tostring(text)
end

function Card:SetSubtitle(text)
	self._subtitle.Text = tostring(text)
	self._subtitle.Visible = true
end

function Card:SetLine(index, text)
	local line = self._lines[index]
	if line then
		line.Text = tostring(text)
	end
end

function Card:SetImage(image)
	if self._image then
		self._image.Image = resolveIcon(image) or tostring(image)
	end
end

function Card:SetRight(title, subtitle)
	if self._rightTitle then
		if title ~= nil then
			self._rightTitle.Text = tostring(title)
		end
		if subtitle ~= nil then
			self._rightSubtitle.Text = tostring(subtitle)
		end
	end
end

------------------------------------------------------------------------------
-- Tooltips
------------------------------------------------------------------------------
function Hub:_tooltip(target, text)
	target.MouseEnter:Connect(function()
		self:_showTip(target, text)
	end)
	target.MouseLeave:Connect(function()
		self:_hideTip(target)
	end)
end

function Hub:_showTip(target, text)
	local tip = self._tip
	if not tip then
		local frame = self:_new("Frame", {
			Name = "Tooltip",
			BackgroundColor3 = "Inset",
			Visible = false,
			Parent = self._tipLayer,
		}, { Corner(7) })
		tip = {
			Frame = frame,
			Stroke = self:_stroke(frame, "StrokeLight"),
			Scale = New("UIScale", { Parent = frame }),
			Label = self:_text({
				TextSize = 12,
				TextWrapped = true,
				Position = UDim2.fromOffset(10, 0),
				Size = UDim2.new(1, -20, 1, 0),
				Parent = frame,
			}),
		}
		self._tip = tip
	end

	local scale = self.Scale
	local bounds = measure(text, 12, 220)
	local width, height = math.ceil(bounds.X) + 24, math.ceil(bounds.Y) + 14
	local origin = self._tipLayer.AbsolutePosition
	local view = self._tipLayer.AbsoluteSize
	if view.X <= 0 or view.Y <= 0 then
		view = viewport()
	end
	local pos, size = target.AbsolutePosition - origin, target.AbsoluteSize
	local x = pos.X + size.X / 2 - width * scale / 2
	x = math.clamp(x, 8, math.max(8, view.X - width * scale - 8))
	local y = pos.Y - height * scale - 8
	if y < 8 then
		y = pos.Y + size.Y + 8
	end

	tip.Target = target
	tip.Label.Text = text
	tip.Scale.Scale = scale
	tip.Frame.Size = UDim2.fromOffset(width, height)
	tip.Frame.Position = UDim2.fromOffset(x, y)
	tip.Frame.BackgroundTransparency = 1
	tip.Stroke.Transparency = 1
	tip.Label.TextTransparency = 1
	tip.Frame.Visible = true
	Tween(tip.Frame, 0.16, { BackgroundTransparency = 0 })
	Tween(tip.Stroke, 0.16, { Transparency = 0 })
	Tween(tip.Label, 0.16, { TextTransparency = 0 })
end

function Hub:_hideTip(target)
	local tip = self._tip
	if not tip or (target and tip.Target ~= target) then
		return
	end
	tip.Target = nil
	tip.Frame.Visible = false
end

------------------------------------------------------------------------------
-- Notifications
------------------------------------------------------------------------------
local TOAST_COLORS = { Success = "Success", Warning = "Warning", Error = "Danger" }
local TOAST_ICONS = { Success = "check-circle", Warning = "alert-triangle", Error = "x-circle" }

--[[
	Hub:Notify(options) -> { Close = function }
	options:  Title, Content, Duration (seconds, 4), Type ("Info" | "Success" | "Warning" | "Error"), Icon
]]
function Hub:Notify(options)
	if self._unloaded then
		return
	end
	options = options or {}

	local holder = self._toastHolder
	if not holder then
		holder = New("Frame", {
			Name = "Stack",
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -16, 0, 16),
			Size = UDim2.new(0, 300, 1, -32),
			Parent = self._toastLayer,
		}, { List(Enum.FillDirection.Vertical, 8) })
		self._toastScale = New("UIScale", { Scale = self.Scale, Parent = holder })
		self._toastHolder = holder
		self._toastCount = 0
	end
	self._toastCount = self._toastCount + 1

	local kind = options.Type or "Info"
	local colorKey = TOAST_COLORS[kind] or "Accent"
	local title = tostring(options.Title or self.Name)
	local content = tostring(options.Content or "")
	local duration = math.max(0.5, tonumber(options.Duration) or 4)

	local bodyHeight = 0
	if content ~= "" then
		bodyHeight = math.ceil(measure(content, 12, 244).Y) + 4
	end
	local height = 13 + 16 + (bodyHeight > 0 and (bodyHeight + 3) or 0) + 15

	-- the wrapper animates the height (so the stack slides), the card slides in
	local wrapper = New("Frame", {
		Name = "Toast",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 0),
		LayoutOrder = self._toastCount,
		Parent = holder,
	})
	local card = self:_new("TextButton", {
		Name = "Card",
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = "Group",
		Position = UDim2.new(1, 40, 0, 0),
		Size = UDim2.new(1, 0, 0, height),
		Parent = wrapper,
	}, { Corner(10) })
	self:_stroke(card, "StrokeLight")
	self:_icon(options.Icon or TOAST_ICONS[kind] or "info", 18, colorKey, {
		Position = UDim2.fromOffset(14, 12),
		Parent = card,
	})
	self:_text({
		Text = title,
		FontFace = self.Fonts.SemiBold,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Position = UDim2.fromOffset(42, 13),
		Size = UDim2.new(1, -56, 0, 16),
		Parent = card,
	})
	if bodyHeight > 0 then
		self:_text({
			Text = content,
			TextSize = 12,
			TextColor3 = "SubText",
			TextWrapped = true,
			TextYAlignment = Enum.TextYAlignment.Top,
			Position = UDim2.fromOffset(42, 32),
			Size = UDim2.new(1, -56, 0, bodyHeight),
			Parent = card,
		})
	end
	local timer = self:_new("Frame", {
		Name = "Timer",
		BackgroundColor3 = colorKey,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 12, 1, -4),
		Size = UDim2.new(1, -24, 0, 2),
		Parent = card,
	}, { Round() })

	Tween(wrapper, 0.3, { Size = UDim2.new(1, 0, 0, height) })
	Tween(card, 0.5, { Position = UDim2.new(0, 0, 0, 0) }, Enum.EasingStyle.Back)
	Tween(timer, duration, { Size = UDim2.new(0, 0, 0, 2) }, Enum.EasingStyle.Linear)

	local closed = false
	local function close()
		if closed then
			return
		end
		closed = true
		local slide = Tween(card, 0.3, { Position = UDim2.new(1, 40, 0, 0) }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		slide.Completed:Connect(function()
			local shrink = Tween(wrapper, 0.25, { Size = UDim2.new(1, 0, 0, 0) })
			shrink.Completed:Connect(function()
				wrapper:Destroy()
			end)
		end)
	end
	card.MouseButton1Click:Connect(close)
	task.delay(duration, close)
	return { Close = close }
end

------------------------------------------------------------------------------
-- Dialogs
------------------------------------------------------------------------------
--[[
	Hub:Dialog(options)
	options
	    Title, Content
	    Input     { Placeholder, Default }   adds a text box; its text is passed to callbacks
	    Buttons   { { Name, Style, Callback(text) }, ... }      (defaults to a single "OK")
]]
function Hub:Dialog(options)
	if self._unloaded then
		return
	end
	options = options or {}
	self:_closePopup(true)

	local width = 340
	local content = tostring(options.Content or "")
	local bodyHeight = 0
	if content ~= "" then
		bodyHeight = math.ceil(measure(content, 12, width - 40).Y) + 4
	end
	local buttons = options.Buttons
	if type(buttons) ~= "table" or #buttons == 0 then
		buttons = { { Name = "OK", Style = "Primary" } }
	end

	local dim = New("TextButton", {
		Name = "Dim",
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Parent = self._dialogLayer,
	})
	local card = self:_new("Frame", {
		Name = "Dialog",
		BackgroundColor3 = "Window",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		ZIndex = 2,
		Parent = self._dialogLayer,
	}, { Corner(12) })
	self:_stroke(card, "StrokeLight")
	local scale = New("UIScale", { Scale = 0.02, Parent = card })

	local y = 18
	self:_text({
		Text = tostring(options.Title or self.Name),
		FontFace = self.Fonts.SemiBold,
		TextSize = 15,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Position = UDim2.fromOffset(20, y),
		Size = UDim2.new(1, -40, 0, 20),
		Parent = card,
	})
	y = y + 20
	if bodyHeight > 0 then
		y = y + 8
		self:_text({
			Text = content,
			TextSize = 12,
			TextColor3 = "SubText",
			TextWrapped = true,
			TextYAlignment = Enum.TextYAlignment.Top,
			Position = UDim2.fromOffset(20, y),
			Size = UDim2.new(1, -40, 0, bodyHeight),
			Parent = card,
		})
		y = y + bodyHeight
	end

	local box
	if type(options.Input) == "table" then
		y = y + 12
		local field = self:_new("Frame", {
			BackgroundColor3 = "Inset",
			Position = UDim2.fromOffset(20, y),
			Size = UDim2.new(1, -40, 0, 30),
			Parent = card,
		}, { Corner(6) })
		self:_stroke(field, "Stroke")
		box = self:_new("TextBox", {
			BackgroundTransparency = 1,
			ClearTextOnFocus = false,
			ClipsDescendants = true,
			FontFace = self.Fonts.Medium,
			TextSize = 12,
			TextColor3 = "Text",
			PlaceholderText = tostring(options.Input.Placeholder or ""),
			PlaceholderColor3 = "Muted",
			Text = tostring(options.Input.Default or ""),
			TextXAlignment = Enum.TextXAlignment.Left,
			Position = UDim2.fromOffset(10, 0),
			Size = UDim2.new(1, -20, 1, 0),
			Parent = field,
		})
		y = y + 30
	end

	y = y + 18
	local row = self:_new("Frame", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(20, y),
		Size = UDim2.new(1, -40, 0, 34),
		Parent = card,
	}, { List(Enum.FillDirection.Horizontal, 8) })
	y = y + 34 + 18
	card.Size = UDim2.fromOffset(width, y)

	local closed = false
	local function close()
		if closed then
			return
		end
		closed = true
		Tween(dim, 0.2, { BackgroundTransparency = 1 })
		local shrink = Tween(scale, 0.2, { Scale = 0.02 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		shrink.Completed:Connect(function()
			dim:Destroy()
			card:Destroy()
		end)
	end

	local count = #buttons
	local trim = math.ceil(8 * (count - 1) / count)
	for index, item in ipairs(buttons) do
		local button = self:_button(row, item)
		button.Size = UDim2.new(1 / count, -trim, 1, 0)
		button.LayoutOrder = index
		button.MouseButton1Click:Connect(function()
			local text = box and box.Text or nil
			close()
			safeCall(item.Callback, text)
		end)
	end

	Tween(dim, 0.25, { BackgroundTransparency = 0.45 })
	Tween(scale, 0.32, { Scale = self.Scale }, Enum.EasingStyle.Quart)
	return { Close = close }
end

------------------------------------------------------------------------------
-- Configs: every element created with a Flag is saved / loaded
------------------------------------------------------------------------------
function Hub:_ensureFolders()
	if type(ex_makefolder) ~= "function" then
		return
	end
	for _, path in ipairs({ self.Folder, self.Folder .. "/configs" }) do
		local exists = type(ex_isfolder) == "function" and ex_isfolder(path)
		if not exists then
			pcall(ex_makefolder, path)
		end
	end
end

function Hub:_configPath(name)
	return self.Folder .. "/configs/" .. name .. ".json"
end

--- Current value of a flag (or nil).
function Hub:GetFlag(flag)
	local element = self.Flags[flag]
	if element then
		return element.Value
	end
	return nil
end

--- All flagged values as one JSON string.
function Hub:ExportConfig()
	local data = {}
	for flag, element in pairs(self.Flags) do
		if type(element._save) == "function" then
			data[tostring(flag)] = element:_save()
		end
	end
	return HttpService:JSONEncode(data)
end

--- Apply a JSON string produced by ExportConfig. Returns success, error.
function Hub:ImportConfig(json)
	local ok, data = pcall(function()
		return HttpService:JSONDecode(json)
	end)
	if not ok or type(data) ~= "table" then
		return false, "invalid config data"
	end
	for flag, value in pairs(data) do
		local element = self.Flags[flag]
		if element and type(element._load) == "function" then
			local applied, err = pcall(element._load, element, value)
			if not applied then
				warn("[uiLib] could not load flag '" .. tostring(flag) .. "': " .. tostring(err))
			end
		end
	end
	return true
end

function Hub:SaveConfig(name)
	name = sanitizeName(name)
	if name == "" then
		return false, "config name is empty"
	end
	local json = self:ExportConfig()
	if not fsAvailable() then
		self._memoryConfigs[name] = json -- no file access: keep it for this session
		return true
	end
	local ok, err = pcall(function()
		self:_ensureFolders()
		ex_writefile(self:_configPath(name), json)
	end)
	return ok, (not ok) and tostring(err) or nil
end

function Hub:LoadConfig(name)
	name = sanitizeName(name)
	local json
	if fsAvailable() then
		local ok, result = pcall(function()
			local path = self:_configPath(name)
			if ex_isfile(path) then
				return ex_readfile(path)
			end
			return nil
		end)
		json = ok and result or nil
	else
		json = self._memoryConfigs[name]
	end
	if type(json) ~= "string" then
		return false, "config not found"
	end
	return self:ImportConfig(json)
end

function Hub:DeleteConfig(name)
	name = sanitizeName(name)
	if not fsAvailable() then
		self._memoryConfigs[name] = nil
		return true
	end
	if type(ex_delfile) ~= "function" then
		return false, "delfile is not available"
	end
	local ok, err = pcall(ex_delfile, self:_configPath(name))
	if ok and self:GetAutoload() == name then
		self:SetAutoload(nil)
	end
	return ok, (not ok) and tostring(err) or nil
end

--- Names of the saved configs, sorted.
function Hub:GetConfigs()
	local names = {}
	if not fsAvailable() then
		for name in pairs(self._memoryConfigs) do
			table.insert(names, name)
		end
	elseif type(ex_listfiles) == "function" then
		local ok, files = pcall(ex_listfiles, self.Folder .. "/configs")
		if ok and type(files) == "table" then
			for _, path in ipairs(files) do
				local name = string.match(tostring(path), "([^/\\]+)%.json$")
				if name then
					table.insert(names, name)
				end
			end
		end
	end
	table.sort(names)
	return names
end

--- Config that LoadAutoload() applies. Pass nil to clear.
function Hub:SetAutoload(name)
	name = name and sanitizeName(name) or ""
	self._autoload = name ~= "" and name or nil
	if fsAvailable() then
		pcall(function()
			self:_ensureFolders()
			ex_writefile(self.Folder .. "/autoload.txt", name)
		end)
	end
end

function Hub:GetAutoload()
	if fsAvailable() then
		local ok, name = pcall(function()
			local path = self.Folder .. "/autoload.txt"
			if ex_isfile(path) then
				return ex_readfile(path)
			end
			return nil
		end)
		if ok and type(name) == "string" and name ~= "" then
			return name
		end
		return nil
	end
	return self._autoload
end

--- Call once after building the interface to apply the auto-load config.
function Hub:LoadAutoload()
	local name = self:GetAutoload()
	if not name then
		return false
	end
	local ok = self:LoadConfig(name)
	if ok then
		self:Notify({ Title = "Config", Content = "Auto-loaded '" .. name .. "'.", Type = "Success", Duration = 3 })
	end
	return ok
end

------------------------------------------------------------------------------
-- Ready-made settings page
------------------------------------------------------------------------------
--[[
	Hub:BuildSettings(tab, options)
	Fills a tab with interface, config, auto-load and unload controls.
	options:  Footer (string)   small line of text at the bottom
]]
function Hub:BuildSettings(tab, options)
	options = options or {}
	local hub = self

	local function toast(text, kind)
		hub:Notify({ Title = "Settings", Content = text, Type = kind or "Info", Duration = 3 })
	end

	-- interface ------------------------------------------------------------
	tab:AddSection("Interface")
	tab:AddKeybind({
		Name = "Toggle menu",
		Default = hub._toggleKey,
		Mode = "Press",
		ChangedCallback = function(key)
			hub:SetToggleKey(key)
		end,
	})
	local scale = tab:AddSlider({
		Name = "UI scale",
		Min = 70,
		Max = 150,
		Step = 5,
		Suffix = "%",
		Default = math.floor(hub.Scale * 100 + 0.5),
		Lazy = true, -- apply on release: the slider itself moves when the scale changes
		Callback = function(value)
			hub:SetScale(value / 100)
		end,
	})
	tab:AddButton({
		Name = "Reset UI scale",
		Style = "Accent",
		Callback = function()
			scale:Set(100)
		end,
	})
	tab:AddDropdown({
		Name = "UI mode",
		Values = { "Separate windows", "Single window" },
		Default = hub.Mode == "Single" and "Single window" or "Separate windows",
		Callback = function(value)
			-- let the dropdown finish closing before windows are rearranged
			task.defer(function()
				hub:SetMode(value == "Single window" and "Single" or "Windows")
			end)
		end,
	})
	tab:AddColorPicker({
		Name = "Accent colour",
		Default = hub.Theme.Accent,
		Callback = function(color)
			hub:SetAccent(color)
		end,
	})

	-- configs ---------------------------------------------------------------
	tab:AddSection("Config")
	local saved = tab:AddDropdown({
		Name = "Saved config",
		Values = hub:GetConfigs(),
		Placeholder = "no saved configs",
		AllowNone = true,
	})
	local autoload

	local function refresh()
		local names = hub:GetConfigs()
		saved:SetValues(names)
		if autoload then
			local values = { "None" }
			for _, name in ipairs(names) do
				table.insert(values, name)
			end
			autoload:SetValues(values)
			autoload:Set(hub:GetAutoload() or "None", true)
		end
	end

	tab:AddButtonRow({
		{
			Name = "Load",
			Style = "Primary",
			Callback = function()
				local name = saved.Value
				if not name then
					toast("Pick a config first.", "Warning")
					return
				end
				local ok, err = hub:LoadConfig(name)
				toast(ok and ("Loaded '" .. name .. "'.") or ("Load failed: " .. tostring(err)), ok and "Success" or "Error")
			end,
		},
		{
			Name = "Delete",
			Callback = function()
				local name = saved.Value
				if not name then
					toast("Pick a config first.", "Warning")
					return
				end
				local ok, err = hub:DeleteConfig(name)
				refresh()
				toast(ok and ("Deleted '" .. name .. "'.") or ("Delete failed: " .. tostring(err)), ok and "Success" or "Error")
			end,
		},
	})
	local nameInput
	nameInput = tab:AddInput({
		Placeholder = "config name...",
		MaxLength = 32,
		Button = {
			Name = "Save",
			Callback = function(text)
				local name = sanitizeName(text)
				if name == "" then
					toast("Type a config name first.", "Warning")
					return
				end
				local ok, err = hub:SaveConfig(name)
				refresh()
				if ok then
					saved:Set(name, true)
					nameInput:Set("", true)
				end
				toast(ok and ("Saved '" .. name .. "'.") or ("Save failed: " .. tostring(err)), ok and "Success" or "Error")
			end,
		},
	})
	tab:AddButtonRow({
		{
			Name = "Export config",
			Callback = function()
				local json = hub:ExportConfig()
				if type(ex_setclipboard) == "function" and pcall(ex_setclipboard, json) then
					toast("Config copied to the clipboard.", "Success")
				else
					hub:Dialog({
						Title = "Export config",
						Content = "Copy the text below.",
						Input = { Default = json },
					})
				end
			end,
		},
		{
			Name = "Import config",
			Callback = function()
				hub:Dialog({
					Title = "Import config",
					Content = "Paste an exported config below.",
					Input = { Placeholder = "{ ... }" },
					Buttons = {
						{ Name = "Cancel" },
						{
							Name = "Import",
							Style = "Primary",
							Callback = function(text)
								local ok, err = hub:ImportConfig(text or "")
								toast(ok and "Config imported." or ("Import failed: " .. tostring(err)), ok and "Success" or "Error")
							end,
						},
					},
				})
			end,
		},
	})

	-- auto-load ---------------------------------------------------------------
	tab:AddSection("Auto-load")
	autoload = tab:AddDropdown({
		Name = "Auto-load on execute",
		Values = { "None" },
		Default = "None",
		Callback = function(value)
			hub:SetAutoload(value ~= "None" and value or nil)
		end,
	})
	refresh()
	if not fsAvailable() then
		tab:AddLabel("File access is not available here, so configs only last for this session.")
	end

	-- script ------------------------------------------------------------------
	tab:AddSection("Script")
	tab:AddButton({
		Name = "Unload " .. hub.Name,
		Style = "Accent",
		Confirm = "Remove the interface and stop the script?",
		Callback = function()
			hub:Unload()
		end,
	})
	if options.Footer then
		tab:AddLabel(tostring(options.Footer))
	end
end

return Library

