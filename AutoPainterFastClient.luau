-- Settings --

local color = Color3.fromRGB(255,255,255)

-- Performance tuning
-- Normal mode keeps one request in flight per province.
-- Fast Paint allows a few overlapping requests per province while keeping
-- a global ceiling so the client does not create an unlimited backlog.
local NORMAL_MAX_IN_FLIGHT = 40
local FAST_MAX_IN_FLIGHT = 80
local FAST_MAX_PER_PROVINCE = 3
local SAFE_INTERVAL = 1

-- Values --

local userInputService = game:GetService("UserInputService")
local runService = game:GetService("RunService")
local tweenService = game:GetService("TweenService")

local player = game.Players.LocalPlayer
local mouse = player:GetMouse()

local provincesFolder = Instance.new("Model")
provincesFolder.Parent = workspace
local highlight = Instance.new("Highlight")
highlight.FillColor = color
highlight.FillTransparency = 0.8
highlight.Parent = workspace
highlight.Adornee = provincesFolder

local UI = Instance.new("ScreenGui",player.PlayerGui)
local UIHolder = Instance.new("Frame",UI)
UIHolder.AnchorPoint = Vector2.new(0.5,0.5)
UIHolder.BackgroundTransparency = 1
UIHolder.Position = UDim2.new(0.5,0,0.5,0)
UIHolder.Size = UDim2.new(0,0,0,0)
local aspectratio = Instance.new("UIAspectRatioConstraint",UIHolder)
local mainFrame = Instance.new("Frame",UIHolder)
mainFrame.BackgroundColor3 = Color3.fromRGB(33,33,42)
mainFrame.AnchorPoint = Vector2.new(0.5,0.5)
mainFrame.Position = UDim2.new(0.5,0,0.5,0)
mainFrame.Size = UDim2.new(0.5,0,0.276,0)
mainFrame.Rotation = 359
local topBar = Instance.new("Frame",mainFrame)
topBar.BorderColor3 = Color3.fromRGB(0,0,0)
topBar.BackgroundColor3 = Color3.fromRGB(49,49,64)
topBar.Size = UDim2.new(1,0,0.14,0)
local pss = Instance.new("TextLabel",topBar)
pss.Text = "0 paint/second"
pss.AnchorPoint = Vector2.new(0,0.5)
pss.Size = UDim2.new(0.974,0,0.5,0)
pss.Position = UDim2.new(0,0,0.5,0)
pss.TextColor3 = Color3.fromRGB(255,255,255)
pss.BackgroundTransparency = 1
pss.TextScaled = true
pss.TextXAlignment = Enum.TextXAlignment.Right
local scrollFrame = Instance.new("ScrollingFrame",mainFrame)
scrollFrame.BackgroundTransparency = 1
scrollFrame.Position = UDim2.new(0,0,0.14,0)
scrollFrame.Size = UDim2.new(1,0,0.86,0)
scrollFrame.ScrollBarThickness = 0
local panelTitle = Instance.new("TextLabel",topBar)
panelTitle.AnchorPoint = Vector2.new(0,0.5)
panelTitle.BackgroundTransparency = 1
panelTitle.Position = UDim2.new(0.02,0,0.5,0)
panelTitle.Size = UDim2.new(1,0,0.5,0)
panelTitle.Text = '<b>Paint Admin Panel</b><font size="6"> FAST CLIENT</font>'
panelTitle.RichText = true
panelTitle.TextScaled = true
panelTitle.TextColor3 = Color3.fromRGB(255,255,255)
panelTitle.TextXAlignment = Enum.TextXAlignment.Left
local listlayout = Instance.new("UIListLayout",scrollFrame)
listlayout.Padding = UDim.new(0,10)
local uipadding = Instance.new("UIPadding",scrollFrame)
uipadding.PaddingTop = UDim.new(0,10)
uipadding.PaddingLeft = UDim.new(0,10)
uipadding.PaddingRight = UDim.new(0,10)
uipadding.PaddingBottom = UDim.new(0,10)
local doneButton = Instance.new("TextButton",UI)
doneButton.Visible = false
doneButton.AnchorPoint = Vector2.new(0.5,0)
doneButton.BackgroundColor3 = Color3.fromRGB(0,247,159)
doneButton.Position = UDim2.new(0.5,0,0,0)
doneButton.Size = UDim2.new(0.3,0,0.1,0)
doneButton.TextColor3 = Color3.fromRGB(255,255,255)
doneButton.TextScaled = true
doneButton.Text = "Done"
doneButton.AutoButtonColor = false
doneButton.BorderSizePixel = 0
local whiteFrame = Instance.new("Frame",mainFrame)
whiteFrame.Size = UDim2.new(1,0,1,0)
whiteFrame.BackgroundColor3 = Color3.fromRGB(255,255,255)
local sound = Instance.new("Sound")
sound.SoundId = "rbxassetid://4612386227"
sound.Parent = workspace
local changecolor = Instance.new("Sound")
changecolor.SoundId = "rbxassetid://4612383790"
changecolor.Parent = workspace
local sound2 = Instance.new("Sound")
sound2.SoundId = "rbxassetid://7486747911"
sound2.Parent = workspace
sound2.PlaybackSpeed = 2
local provinceSound = Instance.new("Sound")
provinceSound.SoundId = "rbxassetid://5694665239"
provinceSound.Parent = workspace

local provinces = {}
local provinceLookup = {}

local provincespersecond = 0
local inFlight = 0

local selectColorMode = false
local removeProvincesMode = false
local selectProvincesMode = false
local safeMode = false
local newpaint = false
local painting = true
local keepTerColor = false

local provinceCodeGenerator = 0

local dragging
local dragInput
local dragStart
local startPos

-- Functions --

local function getPaintRemote()
	local character = player.Character
	if not character then return nil end

	local bucket = character:FindFirstChild("PaintBucket")
	if not bucket then return nil end

	local remotes = bucket:FindFirstChild("Remotes")
	if not remotes then return nil end

	return remotes:FindFirstChild("ServerControls")
end

local function removeProvince(province)
	local info = provinceLookup[province]
	if not info then return end

	provinceLookup[province] = nil
	for i = #provinces, 1, -1 do
		if provinces[i] == info then
			table.remove(provinces, i)
			break
		end
	end

	if info.Highlight and info.Highlight.Parent then
		info.Highlight:Destroy()
	end
end

local function clearProvinces()
	for _, info in ipairs(provinces) do
		provinceLookup[info.Province] = nil
		if info.Highlight and info.Highlight.Parent then
			info.Highlight:Destroy()
		end
	end
	table.clear(provinces)
end

local function addProvince(province, highlighty)
	if provinceLookup[province] then
		if highlighty then highlighty:Destroy() end
		return false
	end

	local info = {
		Province = province,
		Highlight = highlighty,
		SavedColor = color,
		InFlight = 0,
		LastPaint = 0,
	}

	provinceLookup[province] = info
	table.insert(provinces, info)
	provinceCodeGenerator += 1
	return true
end

local function requestPaint(info, targetColor, maxPerProvince)
	if inFlight >= (newpaint and FAST_MAX_IN_FLIGHT or NORMAL_MAX_IN_FLIGHT) then
		return false
	end

	if info.InFlight >= maxPerProvince then
		return false
	end

	local province = info.Province
	if not province or not province.Parent then
		removeProvince(province)
		return false
	end

	local remote = getPaintRemote()
	if not remote then
		return false
	end

	inFlight += 1
	info.InFlight += 1
	info.LastPaint = os.clock()

	task.spawn(function()
		local ok = pcall(function()
			remote:InvokeServer(
				"PaintPart",
				{
					Part = province,
					Color = targetColor,
				},
				"Peace"
			)
		end)

		inFlight = math.max(0, inFlight - 1)
		info.InFlight = math.max(0, info.InFlight - 1)

		if ok then
			provincespersecond += 1
		end
	end)

	return true
end

-- One scheduler for every selected province. This replaces one Stepped
-- connection per province and keeps the number of outstanding requests bounded.
runService.Heartbeat:Connect(function()
	if not painting or #provinces == 0 then
		return
	end

	local now = os.clock()
	local maxTotal = newpaint and FAST_MAX_IN_FLIGHT or NORMAL_MAX_IN_FLIGHT
	local maxPerProvince = newpaint and FAST_MAX_PER_PROVINCE or 1

	for i = #provinces, 1, -1 do
		if inFlight >= maxTotal then
			break
		end

		local info = provinces[i]
		local province = info.Province

		if not province or not province.Parent then
			removeProvince(province)
		else
			local targetColor = keepTerColor and info.SavedColor or color
			local needsPaint = province.Color ~= targetColor

			if needsPaint then
				if safeMode then
					if info.InFlight == 0 and now - info.LastPaint >= SAFE_INTERVAL then
						requestPaint(info, targetColor, 1)
					end
				else
					requestPaint(info, targetColor, maxPerProvince)
				end
			end
		end
	end
end)

local function createNewOption(optionType,text,customText,enabled)
	local optionFrame = Instance.new("Frame",scrollFrame)
	optionFrame.BorderColor3 = Color3.fromRGB(0,0,0)
	optionFrame.BackgroundColor3 = Color3.fromRGB(49, 49, 64)
	optionFrame.Size = UDim2.new(1,0,0.075,0)
	optionFrame.Parent = scrollFrame
	local textlabel = Instance.new("TextLabel",optionFrame)
	textlabel.BackgroundTransparency = 1
	textlabel.Position = UDim2.new(0.02,0,0.2,0)
	textlabel.Size = UDim2.new(1,0,0.6,0)
	textlabel.TextScaled = true
	textlabel.Text = text
	textlabel.Font = Enum.Font.SourceSansBold
	textlabel.TextColor3 = Color3.fromRGB(255,255,255)
	textlabel.TextXAlignment = Enum.TextXAlignment.Left
	if optionType == "switch" then
		local switchFrame = Instance.new("Frame",optionFrame)
		switchFrame.BackgroundColor3 = Color3.fromRGB(241, 33, 103)
		switchFrame.Position = UDim2.new(0.865,0,0.125,0)
		switchFrame.Size = UDim2.new(0.125,0,0.75,0)
		switchFrame.BorderSizePixel = 0
		local switch = Instance.new("ImageButton",switchFrame)
		switch.AutoButtonColor = false
		switch.BorderSizePixel = 0
		switch.Size = UDim2.new(1,0,1,0)
		switch.BackgroundColor3 = Color3.fromRGB(255,255,255)
		local aspectRatio = Instance.new("UIAspectRatioConstraint",switch)
		if enabled then
			tweenService:Create(switch.Parent,TweenInfo.new(0.1),{BackgroundColor3 = Color3.fromRGB(53, 227, 153)}):Play()
			tweenService:Create(switch,TweenInfo.new(0.1),{Position = UDim2.new(1,0,0,0)}):Play()
			tweenService:Create(switch,TweenInfo.new(0.1),{AnchorPoint = Vector2.new(1,0)}):Play()
		end
		return switch
	elseif optionType == "color" then
		local colorButton = Instance.new("ImageButton",optionFrame)
		colorButton.Position = UDim2.new(0.928,0,0.125,0)
		colorButton.AutoButtonColor = false
		colorButton.Size = UDim2.new(0.062,0,0.75,0)
		return colorButton
	elseif optionType == "custom" then
		local button = Instance.new("ImageButton",optionFrame)
		button.BackgroundColor3 = Color3.fromRGB(100,100,100)
		button.Position = UDim2.new(0.865,0,0.125,0)
		button.Size = UDim2.new(0.125,0,0.75,0)
		button.AutoButtonColor = false
		local textlabel = Instance.new("TextLabel",button)
		textlabel.BackgroundTransparency = 1
		textlabel.Position = UDim2.new(0.5,0,0.5,0)
		textlabel.AnchorPoint = Vector2.new(0.5,0.5)
		textlabel.Size = UDim2.new(0.8,0,0.8,0)
		textlabel.Text = customText
		textlabel.TextScaled = true
		textlabel.Font = Enum.Font.SourceSansBold
		textlabel.TextColor3 = Color3.fromRGB(255,255,255)
		return button
	end
end

local function update(input)
	local delta = input.Position - dragStart
	mainFrame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
end

-- Script --

wait(1)

sound:Play()

if userInputService.MouseEnabled == false then
	tweenService:Create(UIHolder,TweenInfo.new(0.5),{Size = UDim2.new(1.5,0,1.5,0)}):Play()
else
	tweenService:Create(UIHolder,TweenInfo.new(0.5),{Size = UDim2.new(0.75,0,0.75,0)}):Play()
end
tweenService:Create(mainFrame,TweenInfo.new(0.5),{Rotation = 0}):Play()
tweenService:Create(whiteFrame,TweenInfo.new(4),{BackgroundTransparency = 1}):Play()

topBar.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		dragging = true
		dragStart = input.Position
		startPos = mainFrame.Position

		input.Changed:Connect(function()
			if input.UserInputState == Enum.UserInputState.End then
				dragging = false
			end
		end)
	end
end)

topBar.InputChanged:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
		dragInput = input
	end
end)

userInputService.InputChanged:Connect(function(input)
	if input == dragInput and dragging then
		update(input)
	end
end)

local button2 = createNewOption("color","Country Color")
local button1 = createNewOption("custom","Protect Province","Add")
local button5 = createNewOption("custom","Unprotect Province","Remove")
local button3 = createNewOption("custom","Clear Provinces","Clear")
local button4 = createNewOption("switch","Safe Mode")
local togglePaintButton = createNewOption("switch","Toggle Paint",nil,true)
local newPaintButton = createNewOption("switch","Fast Paint")
local territoryColorButton = createNewOption("switch","Keep Territory Color (NEW)")
local randomColorButton = createNewOption("custom","Randomize color (NEW)","Change")

mouse.Button1Down:Connect(function()
	if mouse.Target and mouse.Target.Name == "Province" then
		if selectColorMode then
			color = mouse.Target.Color
			selectColorMode = false
			UIHolder.Visible = true
			button2.BackgroundColor3 = color
			changecolor:Play()
		end
		if selectProvincesMode then
			if not provinceLookup[mouse.Target] then
				provinceSound:Play()
				local clone = mouse.Target:Clone()
				clone.Position -= Vector3.new(0,0.01,0)
				clone.Material = Enum.Material.Glass
				clone.Transparency = 1
				clone.CanCollide = false
				clone.CanTouch = false
				clone.CanQuery = false
				clone.Parent = provincesFolder
				addProvince(mouse.Target, clone)
			end
		end
		if removeProvincesMode then
			removeProvince(mouse.Target)
		end
	end
end)

button2.BackgroundColor3 = color
button2.MouseButton1Down:Connect(function()
	UIHolder.Visible = false
	selectColorMode = true
end)

button1.MouseButton1Down:Connect(function()
	UIHolder.Visible = false
	selectProvincesMode = true
	doneButton.Visible = true
end)

doneButton.MouseButton1Down:Connect(function()
	removeProvincesMode = false
	selectProvincesMode = false
	UIHolder.Visible = true
	doneButton.Visible = false
end)

button3.MouseButton1Down:Connect(function()
	clearProvinces()
end)

button4.MouseButton1Down:Connect(function()
	sound2:Play()
	if safeMode then
		safeMode = false
		tweenService:Create(button4.Parent,TweenInfo.new(0.1),{BackgroundColor3 = Color3.fromRGB(241, 33, 103)}):Play()
		tweenService:Create(button4,TweenInfo.new(0.1),{Position = UDim2.new(0,0,0,0)}):Play()
		tweenService:Create(button4,TweenInfo.new(0.1),{AnchorPoint = Vector2.new(0,0)}):Play()
	else
		safeMode = true
		tweenService:Create(button4.Parent,TweenInfo.new(0.1),{BackgroundColor3 = Color3.fromRGB(53, 227, 153)}):Play()
		tweenService:Create(button4,TweenInfo.new(0.1),{Position = UDim2.new(1,0,0,0)}):Play()
		tweenService:Create(button4,TweenInfo.new(0.1),{AnchorPoint = Vector2.new(1,0)}):Play()
	end
end)

button5.MouseButton1Down:Connect(function()
	UIHolder.Visible = false
	removeProvincesMode = true
	doneButton.Visible = true
end)

togglePaintButton.MouseButton1Down:Connect(function()
	sound2:Play()
	if painting then
		painting = false
		tweenService:Create(togglePaintButton.Parent,TweenInfo.new(0.1),{BackgroundColor3 = Color3.fromRGB(241, 33, 103)}):Play()
		tweenService:Create(togglePaintButton,TweenInfo.new(0.1),{Position = UDim2.new(0,0,0,0)}):Play()
		tweenService:Create(togglePaintButton,TweenInfo.new(0.1),{AnchorPoint = Vector2.new(0,0)}):Play()
	else
		painting = true
		tweenService:Create(togglePaintButton.Parent,TweenInfo.new(0.1),{BackgroundColor3 = Color3.fromRGB(53, 227, 153)}):Play()
		tweenService:Create(togglePaintButton,TweenInfo.new(0.1),{Position = UDim2.new(1,0,0,0)}):Play()
		tweenService:Create(togglePaintButton,TweenInfo.new(0.1),{AnchorPoint = Vector2.new(1,0)}):Play()
	end
end)

newPaintButton.MouseButton1Down:Connect(function()
	sound2:Play()
	if newpaint then
		newpaint = false
		tweenService:Create(newPaintButton.Parent,TweenInfo.new(0.1),{BackgroundColor3 = Color3.fromRGB(241, 33, 103)}):Play()
		tweenService:Create(newPaintButton,TweenInfo.new(0.1),{Position = UDim2.new(0,0,0,0)}):Play()
		tweenService:Create(newPaintButton,TweenInfo.new(0.1),{AnchorPoint = Vector2.new(0,0)}):Play()
	else
		newpaint = true
		tweenService:Create(newPaintButton.Parent,TweenInfo.new(0.1),{BackgroundColor3 = Color3.fromRGB(53, 227, 153)}):Play()
		tweenService:Create(newPaintButton,TweenInfo.new(0.1),{Position = UDim2.new(1,0,0,0)}):Play()
		tweenService:Create(newPaintButton,TweenInfo.new(0.1),{AnchorPoint = Vector2.new(1,0)}):Play()
	end
end)

territoryColorButton.MouseButton1Down:Connect(function()
	sound2:Play()
	if keepTerColor then
		keepTerColor = false
		tweenService:Create(territoryColorButton.Parent,TweenInfo.new(0.1),{BackgroundColor3 = Color3.fromRGB(241, 33, 103)}):Play()
		tweenService:Create(territoryColorButton,TweenInfo.new(0.1),{Position = UDim2.new(0,0,0,0)}):Play()
		tweenService:Create(territoryColorButton,TweenInfo.new(0.1),{AnchorPoint = Vector2.new(0,0)}):Play()
	else
		keepTerColor = true
		tweenService:Create(territoryColorButton.Parent,TweenInfo.new(0.1),{BackgroundColor3 = Color3.fromRGB(53, 227, 153)}):Play()
		tweenService:Create(territoryColorButton,TweenInfo.new(0.1),{Position = UDim2.new(1,0,0,0)}):Play()
		tweenService:Create(territoryColorButton,TweenInfo.new(0.1),{AnchorPoint = Vector2.new(1,0)}):Play()
	end
end)

randomColorButton.MouseButton1Down:Connect(function()
	color = Color3.fromRGB(math.random(0,255),math.random(0,255),math.random(0,255))
	button2.BackgroundColor3 = color
	changecolor:Play()
end)

userInputService.InputBegan:Connect(function(input,isTyping)
	if isTyping == false then
		if input.KeyCode == Enum.KeyCode.R then
			color = Color3.fromRGB(math.random(0,255),math.random(0,255),math.random(0,255))
			button2.BackgroundColor3 = color
			changecolor:Play()
		elseif input.KeyCode == Enum.KeyCode.Q then
			if painting then
				painting = false
				tweenService:Create(togglePaintButton.Parent,TweenInfo.new(0.1),{BackgroundColor3 = Color3.fromRGB(241, 33, 103)}):Play()
				tweenService:Create(togglePaintButton,TweenInfo.new(0.1),{Position = UDim2.new(0,0,0,0)}):Play()
				tweenService:Create(togglePaintButton,TweenInfo.new(0.1),{AnchorPoint = Vector2.new(0,0)}):Play()
			else
				painting = true
				tweenService:Create(togglePaintButton.Parent,TweenInfo.new(0.1),{BackgroundColor3 = Color3.fromRGB(53, 227, 153)}):Play()
				tweenService:Create(togglePaintButton,TweenInfo.new(0.1),{Position = UDim2.new(1,0,0,0)}):Play()
				tweenService:Create(togglePaintButton,TweenInfo.new(0.1),{AnchorPoint = Vector2.new(1,0)}):Play()
			end
		end
	end
end)

-- Paint-per-second display
while task.wait(1) do
	pss.TextColor3 = Color3.fromRGB(80, 255, 123)
	if provincespersecond >= 50 then
		pss.TextColor3 = Color3.fromRGB(247, 226, 112)
	end
	if provincespersecond >= 100 then
		pss.TextColor3 = Color3.fromRGB(245, 128, 37)
	end
	if provincespersecond >= 300 then
		pss.TextColor3 = Color3.fromRGB(235, 8, 10)
	end
	if provincespersecond >= 1000 then
		pss.TextColor3 = Color3.fromRGB(235, 0, 120)
	end
	pss.Text = provincespersecond.." paint/second | "..inFlight.." pending"
	provincespersecond = 0
end
