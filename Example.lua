--[[
	uiLib · example

	    loadstring(game:HttpGet("https://raw.githubusercontent.com/LyherScript/uiLib/main/Example.lua"))()

	Builds a small demo hub that shows every component of the library.
	Nothing here touches the game: every callback only prints or notifies.
]]

-- In your own script this is a single line:
--     local Library = loadstring(game:HttpGet(".../uiLib/main/Library.lua"))()
-- The demo also looks on the development branch so it works before a merge.
local function import(file)
	for _, branch in ipairs({ "main", "claude/compassionate-gauss-r2p7dj" }) do
		local ok, source = pcall(function()
			return game:HttpGet("https://raw.githubusercontent.com/LyherScript/uiLib/" .. branch .. "/" .. file)
		end)
		local chunk = ok and type(source) == "string" and loadstring(source)
		if chunk then
			return chunk()
		end
	end
	error("uiLib: could not download " .. file)
end

local Library = import("Library.lua")

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local LocalPlayer = Players.LocalPlayer

local UI = Library:Create({
	Name = "uiLib Demo",
	ToggleKey = Enum.KeyCode.K, -- show / hide everything
	ConfigFolder = "uiLibDemo",
})

local view = workspace.CurrentCamera.ViewportSize
local left = math.max(20, math.floor(view.X / 2 - 540))

--------------------------------------------------------------------------------
-- Home
--------------------------------------------------------------------------------
local Home = UI:AddTab({
	Name = "Home",
	Icon = "home",
	Avatar = true, -- the dock shows your avatar for this tab
	Size = Vector2.new(390, 560),
	Position = Vector2.new(left, 70),
})

Home:AddSection("Current experience")
local experience = Home:AddCard({
	Title = "Loading...",
	Image = "rbxthumb://type=GameIcon&id=" .. tostring(game.GameId) .. "&w=150&h=150",
	Lines = {
		"Place ID: " .. tostring(game.PlaceId),
		"Universe ID: " .. tostring(game.GameId),
		"Job ID: " .. string.sub(tostring(game.JobId), 1, 13) .. "...",
	},
})
task.spawn(function()
	local ok, info = pcall(function()
		return game:GetService("MarketplaceService"):GetProductInfo(game.PlaceId)
	end)
	experience:SetTitle(ok and info and info.Name or "Unknown experience")
end)

Home:AddSection("Your profile")
Home:AddCard({
	Title = LocalPlayer.DisplayName,
	Subtitle = "@" .. LocalPlayer.Name .. "  ·  " .. tostring(LocalPlayer.AccountAge) .. " days",
	Image = "rbxthumb://type=AvatarHeadShot&id=" .. tostring(LocalPlayer.UserId) .. "&w=150&h=150",
	ImageRound = true,
	RightTitle = "Demo",
	RightSubtitle = "v" .. Library.Version,
})

Home:AddSection("Live")
local live = Home:AddStats({
	{ Label = "FPS", Value = "-" },
	{ Label = "Ping", Value = "-" },
	{ Label = "Players", Value = #Players:GetPlayers() },
})

Home:AddSection("Session")
Home:AddButtonRow({
	{
		Name = "Say hello",
		Icon = "bell",
		Callback = function()
			UI:Notify({ Title = "Hello!", Content = "This is a notification. Click it to dismiss.", Type = "Success" })
		end,
	},
	{
		Name = "Ask something",
		Icon = "help-circle",
		Callback = function()
			UI:Dialog({
				Title = "A question",
				Content = "Dialogs can carry any number of buttons and an optional text box.",
				Buttons = {
					{ Name = "Cancel" },
					{ Name = "Sounds good", Style = "Primary", Callback = function()
						UI:Notify({ Title = "Dialog", Content = "Confirmed.", Type = "Info" })
					end },
				},
			})
		end,
	},
})
Home:AddLabel("Press K to hide or show the interface. Drag windows by their title bar, resize them from the bottom-right corner.")

-- live counters ----------------------------------------------------------------
local frames, running = 0, true
local frameConnection = RunService.RenderStepped:Connect(function()
	frames = frames + 1
end)
UI:OnUnload(function()
	running = false
	frameConnection:Disconnect()
end)
task.spawn(function()
	while running do
		task.wait(0.5)
		if not running then
			break
		end
		live:Set("FPS", frames * 2)
		frames = 0
		local ok, ping = pcall(function()
			return LocalPlayer:GetNetworkPing() * 1000
		end)
		live:Set("Ping", ok and (tostring(math.floor(ping + 0.5)) .. "ms") or "-")
		live:Set("Players", #Players:GetPlayers())
	end
end)

--------------------------------------------------------------------------------
-- Controls (two columns of groups)
--------------------------------------------------------------------------------
local Controls = UI:AddTab({
	Name = "Controls",
	Icon = "sliders-horizontal",
	Columns = 2,
	Size = Vector2.new(660, 560),
	Position = Vector2.new(left + 410, 70),
	Open = true,
})

local function log(name)
	return function(value)
		if type(value) == "table" then
			value = table.concat(value, ", ")
		end
		print("[uiLib demo] " .. name .. " ->", value)
	end
end

-- left column
local Basics = Controls:AddGroup({ Name = "Basics", Icon = "swords", Column = 1 })
local Main, Advanced = Basics:AddSubTabs({ "Main", "Advanced" })

local enabled = Main:AddToggle({
	Name = "Enabled",
	Flag = "Enabled",
	Default = true,
	Tooltip = "Hover the little (i) to read a tooltip like this one.",
	Callback = log("Enabled"),
})
Main:AddToggle({
	Name = "With a description",
	Description = "A second line of muted text.",
	Flag = "Described",
	Callback = log("Described"),
})
Main:AddToggle({ Name = "Bound to a key", Flag = "Bound", Callback = log("Bound") })
	:AddKeybind({ Default = Enum.KeyCode.G, Flag = "BoundKey" })
Main:AddSlider({
	Name = "Speed",
	Flag = "Speed",
	Min = 0,
	Max = 100,
	Default = 35,
	Suffix = "%",
	Callback = log("Speed"),
})
Main:AddSlider({
	Name = "Precision",
	Flag = "Precision",
	Min = 0,
	Max = 1,
	Step = 0.05,
	Default = 0.5,
	Callback = log("Precision"),
})

Advanced:AddDropdown({
	Name = "Mode",
	Flag = "Mode",
	Values = { "Balanced", "Fast", "Careful" },
	Default = "Balanced",
	Callback = log("Mode"),
})
Advanced:AddDropdown({
	Name = "Targets",
	Flag = "Targets",
	Values = { "Alpha", "Bravo", "Charlie", "Delta" },
	Multi = true,
	Default = { "Alpha" },
	Callback = log("Targets"),
})
Advanced:AddDropdown({
	Name = "Searchable", -- lists with more than 8 values get a search box
	Flag = "Fruit",
	Values = { "Apple", "Apricot", "Banana", "Cherry", "Grape", "Kiwi", "Lemon", "Mango", "Orange", "Peach", "Pear", "Plum" },
	Placeholder = "Pick a fruit",
	AllowNone = true,
	Callback = log("Fruit"),
})

Basics:AddButton({
	Name = "Flip \"Enabled\" from code",
	Style = "Accent",
	Callback = function()
		enabled:Set(not enabled.Value)
	end,
})

local Assists = Controls:AddGroup({ Name = "More toggles", Icon = "shield-check", Column = 1 })
Assists:AddToggle({ Name = "Option one", Flag = "One", Tooltip = "Groups collapse when you click their header." })
Assists:AddToggle({ Name = "Option two", Flag = "Two", Default = true })

-- right column
local Inputs = Controls:AddGroup({ Name = "Inputs", Icon = "keyboard", Column = 2 })
Inputs:AddInput({
	Name = "Nickname",
	Flag = "Nickname",
	Placeholder = "type here",
	Callback = log("Nickname"),
})
Inputs:AddInput({
	Name = "Amount",
	Flag = "Amount",
	Numeric = true,
	Default = "10",
	Callback = log("Amount"),
})
Inputs:AddInput({
	Placeholder = "full-width box with a button...",
	Button = {
		Name = "Send",
		Callback = function(text)
			UI:Notify({ Title = "Input", Content = text ~= "" and ("You sent: " .. text) or "The box is empty.", Duration = 3 })
		end,
	},
})
Inputs:AddKeybind({
	Name = "Hold key",
	Flag = "HoldKey",
	Default = Enum.KeyCode.LeftAlt,
	Mode = "Hold",
	Tooltip = "Click the key to rebind. Esc cancels, Backspace clears.",
	Callback = log("Hold key"),
})
Inputs:AddColorPicker({
	Name = "Highlight colour",
	Flag = "Highlight",
	Default = Color3.fromRGB(104, 170, 252),
	Callback = function(color)
		print("[uiLib demo] Highlight -> #" .. color:ToHex())
	end,
})

local Words = Controls:AddGroup({ Name = "Text", Icon = "file-text", Column = 2 })
Words:AddParagraph({
	Title = "Paragraph",
	Content = "Paragraphs wrap automatically and grow with their content, so longer notes stay readable.",
})
Words:AddDivider()
Words:AddLabel("Labels are plain muted text for small hints.")

--------------------------------------------------------------------------------
-- Alerts
--------------------------------------------------------------------------------
local Alerts = UI:AddTab({ Name = "Alerts", Icon = "bell", Size = Vector2.new(360, 380) })

Alerts:AddSection("Notifications")
for _, kind in ipairs({ "Info", "Success", "Warning", "Error" }) do
	Alerts:AddButton({
		Name = kind .. " notification",
		Callback = function()
			UI:Notify({
				Title = kind,
				Content = "This is what a " .. string.lower(kind) .. " notification looks like.",
				Type = kind,
			})
		end,
	})
end

Alerts:AddSection("Dialogs")
Alerts:AddButton({
	Name = "Button with confirmation",
	Style = "Danger",
	Confirm = "This button asks before it runs its callback.",
	Callback = function()
		UI:Notify({ Title = "Confirmed", Content = "The callback ran.", Type = "Success" })
	end,
})
Alerts:AddButton({
	Name = "Dialog with a text box",
	Callback = function()
		UI:Dialog({
			Title = "Rename",
			Content = "Type anything and press Save.",
			Input = { Placeholder = "new name" },
			Buttons = {
				{ Name = "Cancel" },
				{ Name = "Save", Style = "Primary", Callback = function(text)
					UI:Notify({ Title = "Saved", Content = "You typed: " .. tostring(text) })
				end },
			},
		})
	end,
})

--------------------------------------------------------------------------------
-- Settings (built in: toggle key, scale, window mode, accent, configs, unload)
--------------------------------------------------------------------------------
local Settings = UI:AddTab({ Name = "Settings", Icon = "settings", Size = Vector2.new(390, 600) })
UI:BuildSettings(Settings, { Footer = "uiLib demo  ·  v" .. Library.Version })

-- apply the config chosen under "Auto-load on execute", if any
UI:LoadAutoload()

UI:Notify({
	Title = "uiLib Demo",
	Content = "Loaded. Use the dock at the bottom to open windows, press K to hide everything.",
	Duration = 6,
})

return UI
