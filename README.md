# uiLib

A dock + floating-window interface library for Roblox, written in Luau.

- **Dock** at the bottom of the screen, one item per tab
- **Floating windows** you can drag, resize, collapse and maximise, or a single shared window
- **Controls**: toggle, slider, dropdown (single / multi / searchable), text input, keybind, colour picker, buttons
- **Layout**: columns, collapsible groups, sub-tabs, sections, cards, stat tiles, paragraphs
- **Feedback**: notifications, dialogs, tooltips
- **Configs**: save / load / delete / export / import / auto-load, plus a ready-made settings page
- **Theming**: accent colour and presets, applied live
- Smooth animations everywhere; mouse and touch input; no image assets except the Lucide icons

## Try it

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/LyherScript/uiLib/main/Example.lua"))()
```

`Example.lua` builds a demo that shows every component. Press **K** to hide or show it.

## Quick start

```lua
local Library = loadstring(game:HttpGet("https://raw.githubusercontent.com/LyherScript/uiLib/main/Library.lua"))()

local UI = Library:Create({
    Name = "My Hub",
    ToggleKey = Enum.KeyCode.K,
})

local Main = UI:AddTab({ Name = "Main", Icon = "home" })

Main:AddToggle({
    Name = "Enabled",
    Flag = "Enabled",          -- flags are what configs save
    Default = false,
    Callback = function(value) print("Enabled:", value) end,
})

Main:AddSlider({ Name = "Speed", Flag = "Speed", Min = 0, Max = 100, Default = 50, Suffix = "%" })

local Settings = UI:AddTab({ Name = "Settings", Icon = "settings" })
UI:BuildSettings(Settings)     -- toggle key, scale, window mode, accent, configs, unload

UI:LoadAutoload()              -- apply the auto-load config, if one is set
```

## Structure

```
Hub (Library:Create)
 ├─ dock item ── Tab ── window
 │                ├─ elements
 │                └─ Group (collapsible) ── elements / sub-tab pages
 └─ notifications, dialogs, configs, theme
```

Tabs, groups and sub-tab pages are all *containers*: every `Add...` method below works on each of them.

## Hub

```lua
local UI = Library:Create(options)
```

| Option | Type | Default | |
|---|---|---|---|
| `Name` | string | `"uiLib"` | Shown in notifications, used for the config folder |
| `ToggleKey` | KeyCode | `RightShift` | Shows / hides the whole interface |
| `Accent` | Color3 | amber | Accent colour |
| `Theme` | string / table | | Preset name (`Ember`, `Ocean`, `Mint`, `Rose`, `Violet`, `Mono`) or colour overrides |
| `Mode` | string | `"Windows"` | `"Windows"`: one window per tab. `"Single"`: one window, the dock switches pages |
| `Scale` | number | `1` | Interface scale, 0.5 to 2 |
| `ConfigFolder` | string | `Name` | Folder for saved configs |
| `ShowAvatar` | boolean | `true` | Avatar in window title bars |
| `MobileButton` | boolean | auto | Floating show / hide button (on by default on touch-only devices) |
| `Parent` | Instance | auto | Custom parent for the ScreenGui |

| Method | |
|---|---|
| `UI:AddTab(options)` | Create a tab (see below) |
| `UI:Notify({ Title, Content, Duration, Type })` | `Type`: `Info`, `Success`, `Warning`, `Error` |
| `UI:Dialog({ Title, Content, Input, Buttons })` | Modal dialog. `Buttons = { { Name, Style, Callback(text) } }` |
| `UI:SetVisible(bool)` / `UI:Toggle()` | Show / hide everything |
| `UI:SetScale(number)` | Interface scale |
| `UI:SetMode("Windows" \| "Single")` | Window mode |
| `UI:SetAccent(Color3)` / `UI:SetTheme(nameOrTable)` | Recolour live |
| `UI:SetToggleKey(KeyCode)` | Change the show / hide key |
| `UI:BuildSettings(tab, { Footer })` | Fill a tab with the built-in settings page |
| `UI:OnUnload(fn)` / `UI:Unload()` | Clean-up hook / remove the interface |
| `UI.Flags` | `UI.Flags.Speed.Value`, `UI.Flags.Speed:Set(10)` |

Running a script again replaces the previous hub with the same `Name`.

## Tabs

```lua
local Tab = UI:AddTab({
    Name = "Farm",
    Icon = "swords",              -- Lucide icon name, or an asset id
    Columns = 2,                  -- 1 to 3
    Size = Vector2.new(660, 520),
    Position = Vector2.new(200, 80),
    Open = true,                  -- only the first tab opens by default
    Avatar = false,               -- true: the dock shows the player's avatar
})

Tab:Open()  Tab:Close()  Tab:Toggle()  Tab:IsOpen()
```

On a multi-column tab, pass `Column = 2` in any element's options to place it.

## Groups and sub-tabs

```lua
local Group = Tab:AddGroup({ Name = "Farm", Icon = "swords", Column = 1, Collapsed = false })
Group:SetCollapsed(true)

local Main, Extra = Group:AddSubTabs({ "Main", "Extra" })   -- segmented control
Main:AddToggle({ Name = "Auto" })
Extra:AddSlider({ Name = "Delay", Min = 0, Max = 5, Step = 0.1 })
```

## Elements

Every element accepts `Flag` (saved in configs), `Callback`, `Visible` and returns an object with
`:Set(value, silent)`, `:Get()`, `:OnChanged(fn)`, `:SetVisible(bool)`, `:Destroy()` and `.Value`.
Elements with a `Name` also accept `Tooltip` (an info icon you hover) and most accept `Description`.

### Toggle

```lua
local toggle = Tab:AddToggle({ Name = "Auto Dodge", Description = "Optional second line", Default = true, Flag = "AutoDodge" })
toggle:AddKeybind({ Default = Enum.KeyCode.F, Mode = "Toggle", Flag = "AutoDodgeKey" })   -- "Toggle" or "Hold"
```

### Slider

```lua
Tab:AddSlider({ Name = "Wait", Min = 0, Max = 10, Step = 0.5, Default = 2, Suffix = "s", Lazy = false })
```

`Step` sets the precision (`0.1`, `0.01` ...). `Lazy = true` only fires the callback when the drag ends.
Click the number to type an exact value.

### Dropdown

```lua
local mode = Tab:AddDropdown({ Name = "Mode", Values = { "Auto", "Manual" }, Default = "Auto" })
Tab:AddDropdown({ Name = "Targets", Values = names, Multi = true, Default = { "A" } })   -- value is a list
mode:SetValues({ "Auto", "Manual", "Off" })
```

`AllowNone = true` lets a single dropdown be cleared, `Placeholder` is shown while it is empty,
`Search = true/false` forces the search box (automatic above 8 values).

### Input

```lua
Tab:AddInput({ Name = "Webhook", Placeholder = "https://...", Callback = function(text, enterPressed) end })
Tab:AddInput({ Placeholder = "config name...", Button = { Name = "Save", Callback = function(text) end } })
```

`Numeric`, `MaxLength`, `ClearOnFocus`; `Finished = false` fires on every keystroke. Leave `Name` out for a full-width box.

### Keybind

```lua
Tab:AddKeybind({ Name = "Dash", Default = Enum.KeyCode.Q, Mode = "Press", Callback = function() end })
```

| Mode | Callback |
|---|---|
| `"Toggle"` (default) | `Callback(state)`, flips on every press |
| `"Hold"` | `Callback(true)` on press, `Callback(false)` on release |
| `"Press"` | `Callback()` on press |

Click the key to rebind it. **Esc** cancels, **Backspace** clears. `ChangedCallback(keyName)` fires when the key changes.
Right and middle mouse buttons can be bound too.

### Colour picker

```lua
Tab:AddColorPicker({ Name = "ESP colour", Default = Color3.fromRGB(255, 80, 80), Callback = function(color) end })
```

### Buttons

```lua
Tab:AddButton({ Name = "Run", Icon = "play", Style = "Primary", Callback = function() end })
Tab:AddButton({ Name = "Reset", Style = "Danger", Confirm = "Really reset everything?", Callback = reset })
Tab:AddButtonRow({ { Name = "Load", Style = "Primary" }, { Name = "Delete" } })
```

Styles: `Default`, `Accent`, `Primary`, `Danger`. `Confirm` asks in a dialog first.

### Text and display

```lua
Tab:AddSection("Run options")                         -- small accent heading
Tab:AddLabel("Plain wrapped text")
Tab:AddParagraph({ Title = "Note", Content = "Longer wrapped text in a card." })
Tab:AddDivider()

local stats = Tab:AddStats({ { Label = "FPS", Value = 60 }, { Label = "Ping", Value = "41ms" } })
stats:Set("FPS", 144)

local card = Tab:AddCard({
    Title = "Standard tier", Subtitle = "premium unlocked",
    Lines = { "Place ID: 123" },
    Image = "rbxthumb://type=GameIcon&id=" .. game.GameId .. "&w=150&h=150",
    RightTitle = "Lifetime", RightSubtitle = "expires in",
})
card:SetTitle("New title")
```

## Configs

Every element with a `Flag` is saved. `UI:BuildSettings(tab)` gives users the whole flow, or drive it yourself:

```lua
UI:SaveConfig("legit")      UI:LoadConfig("legit")      UI:DeleteConfig("legit")
UI:GetConfigs()             -- { "legit", ... }
UI:SetAutoload("legit")     UI:LoadAutoload()
local json = UI:ExportConfig()
UI:ImportConfig(json)
```

Files live in `<ConfigFolder>/configs/`. Without file access (for example in Studio) configs are kept in memory for the session.
Interface preferences (scale, window mode, toggle key, accent) are remembered separately.

## Icons

`Icon` takes a [Lucide](https://lucide.dev/icons) name (`"home"`, `"swords"`, `"shield-check"`, `"settings"` ... 818 are built in,
see `Library.Icons`), a numeric asset id, or a full `rbxassetid://` / `rbxthumb://` string.

## Theme keys

`Accent`, `OnAccent`, `Window`, `Dock`, `Group`, `Card`, `CardHover`, `Inset`, `Stroke`, `StrokeLight`, `Text`, `SubText`,
`Muted`, `Track`, `Knob`, `Danger`, `Success`, `Warning`, `Info`.

```lua
UI:SetTheme({ Window = Color3.fromRGB(16, 18, 24), Accent = Color3.fromRGB(120, 200, 255) })
```
