-- Civil War selector for the legacy fully automatic AutoPainter.
-- Hard-locked to the requested Roblox experience.

local ALLOWED_GAME_ID = 126330684723008
if game.GameId ~= ALLOWED_GAME_ID then
	warn("Civil War AutoPainter disabled: wrong game.")
	return
end

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local player = assert(Players.LocalPlayer, "Run on the client")
local playerGui = player:WaitForChild("PlayerGui")
local mouse = player:GetMouse()

-- Pinned legacy fully-automatic build requested by the user.
local api = loadstring(game:HttpGet(
	"https://raw.githubusercontent.com/said2201010191-cmd/AutoPainter/ddca399f476391f367073acc7bcc55bfa0aa9399/AutoPainterFinal.luau",
	true
))()

if type(api) ~= "table" then
	warn("Legacy AutoPainter did not return its controller API.")
	return
end

local GUI_NAME = "AutoPainterCivilWarUI"
local old = playerGui:FindFirstChild(GUI_NAME)
if old then old:Destroy() end

local selecting = false
local selected = {}
local usedColors = {}
local hueSeed = math.random()
local colorIndex = 0

local function validProvince(part)
	return part ~= nil
		and part:IsA("BasePart")
		and part.Name == "Province"
		and part:IsDescendantOf(Workspace)
end

local function colorKey(c)
	local r = math.clamp(math.round(c.R * 255), 0, 255)
	local g = math.clamp(math.round(c.G * 255), 0, 255)
	local b = math.clamp(math.round(c.B * 255), 0, 255)
	return string.format("%02X%02X%02X", r, g, b)
end

local function nextUniqueColor()
	-- Golden-ratio hue stepping keeps neighboring selections visually separated,
	-- while saturation/value jitter keeps the result random-looking.
	for _ = 1, 4096 do
		colorIndex += 1
		local h = (hueSeed + colorIndex * 0.618033988749895) % 1
		local s = 0.72 + math.random() * 0.28
		local v = 0.82 + math.random() * 0.18
		local c = Color3.fromHSV(h, s, v)
		local key = colorKey(c)
		if not usedColors[key] then
			usedColors[key] = true
			return c
		end
	end

	-- Extremely unlikely fallback; still explicitly rejects duplicates.
	while true do
		local c = Color3.fromRGB(math.random(0, 255), math.random(0, 255), math.random(0, 255))
		local key = colorKey(c)
		if not usedColors[key] then
			usedColors[key] = true
			return c
		end
	end
end

local gui = Instance.new("ScreenGui")
gui.Name = GUI_NAME
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = playerGui

local frame = Instance.new("Frame")
frame.Name = "CivilWarPanel"
frame.Size = UDim2.fromOffset(300, 154)
frame.Position = UDim2.new(1, -316, 0, 70)
frame.BackgroundColor3 = Color3.fromRGB(30, 30, 40)
frame.BorderSizePixel = 0
frame.Active = true
frame.Parent = gui

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, 0, 0, 30)
title.BackgroundColor3 = Color3.fromRGB(50, 50, 66)
title.BorderSizePixel = 0
title.TextColor3 = Color3.new(1, 1, 1)
title.Font = Enum.Font.SourceSansBold
title.TextSize = 18
title.Text = "Civil War Mode"
title.Active = true
title.Parent = frame

local status = Instance.new("TextLabel")
status.Position = UDim2.fromOffset(8, 34)
status.Size = UDim2.new(1, -16, 0, 36)
status.BackgroundTransparency = 1
status.TextColor3 = Color3.fromRGB(215, 215, 225)
status.TextSize = 14
status.TextWrapped = true
status.Text = "NEW: clear old selection, then click provinces. Each gets a unique random color."
status.Parent = frame

local function button(text, x, width)
	local b = Instance.new("TextButton")
	b.Position = UDim2.fromOffset(x, 78)
	b.Size = UDim2.fromOffset(width, 32)
	b.BackgroundColor3 = Color3.fromRGB(75, 75, 95)
	b.BorderSizePixel = 0
	b.TextColor3 = Color3.new(1, 1, 1)
	b.TextSize = 15
	b.Font = Enum.Font.SourceSansBold
	b.Text = text
	b.Parent = frame
	return b
end

local newButton = button("NEW", 8, 82)
local startButton = button("START", 98, 92)
local cancelButton = button("CANCEL", 198, 94)

local countLabel = Instance.new("TextLabel")
countLabel.Position = UDim2.fromOffset(8, 116)
countLabel.Size = UDim2.new(1, -16, 0, 28)
countLabel.BackgroundTransparency = 1
countLabel.TextColor3 = Color3.fromRGB(100, 255, 150)
countLabel.TextSize = 15
countLabel.Text = "Selected: 0"
countLabel.Parent = frame

local function resetCivilState()
	table.clear(selected)
	table.clear(usedColors)
	colorIndex = 0
	hueSeed = math.random()
	countLabel.Text = "Selected: 0"
end

local function beginCivilWar()
	api.SetPainting(false)
	api.Clear()
	api.SetKeepColor(true)
	resetCivilState()
	selecting = true
	status.Text = "SELECTING: click every province you want in the civil war, then press START."
	newButton.BackgroundColor3 = Color3.fromRGB(35, 145, 110)
end

local function addCivilProvince(part)
	if not selecting or not validProvince(part) or selected[part] then return end
	local c = nextUniqueColor()
	api.SetColor(c)
	if api.AddProvince(part) then
		selected[part] = c
		countLabel.Text = "Selected: " .. tostring((function()
			local n = 0
			for _ in pairs(selected) do n += 1 end
			return n
		end)())
	end
end

local function startCivilWar()
	if not selecting then
		status.Text = "Press NEW first, then select provinces."
		return
	end
	selecting = false
	api.CommitSelections()
	api.SetKeepColor(true)
	api.SetPainting(true)
	status.Text = "RUNNING: every selected province keeps its own unique random color."
	newButton.BackgroundColor3 = Color3.fromRGB(75, 75, 95)
end

local function cancelCivilWar()
	selecting = false
	api.SetPainting(false)
	api.Clear()
	resetCivilState()
	status.Text = "Cancelled. Press NEW to start another civil war."
	newButton.BackgroundColor3 = Color3.fromRGB(75, 75, 95)
end

newButton.Activated:Connect(beginCivilWar)
startButton.Activated:Connect(startCivilWar)
cancelButton.Activated:Connect(cancelCivilWar)

UserInputService.InputBegan:Connect(function(input, processed)
	if processed or not selecting or UserInputService:GetFocusedTextBox() then return end
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		addCivilProvince(mouse.Target)
	elseif input.KeyCode == Enum.KeyCode.Escape then
		cancelCivilWar()
	end
end)

-- Draggable mini-panel.
local dragging, dragStart, startPosition
local dragInput

title.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		dragging = true
		dragStart = input.Position
		startPosition = frame.Position
		dragInput = input
	end
end)

UserInputService.InputChanged:Connect(function(input)
	if dragging and (input == dragInput or input.UserInputType == Enum.UserInputType.MouseMovement) then
		local delta = input.Position - dragStart
		frame.Position = UDim2.new(
			startPosition.X.Scale,
			startPosition.X.Offset + delta.X,
			startPosition.Y.Scale,
			startPosition.Y.Offset + delta.Y
		)
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if input == dragInput or input.UserInputType == Enum.UserInputType.MouseButton1 then
		dragging = false
		dragInput = nil
	end
end)

return {
	Legacy = api,
	BeginCivilWar = beginCivilWar,
	StartCivilWar = startCivilWar,
	CancelCivilWar = cancelCivilWar,
	Selected = selected,
}
