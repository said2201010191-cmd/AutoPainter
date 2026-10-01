-- AutoPainter Hands Free v3
-- Fully automatic client-side controller using the normal PaintBucket input path.
-- No direct PaintPart calls, no Mouse.Target/GetMouseData spoofing, and no hooks.
-- NORMAL paints every protected province to one palette color.
-- CIVIL WAR is optional and assigns a unique color to every protected province.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local player = assert(Players.LocalPlayer, "Run on the client")
local playerGui = player:WaitForChild("PlayerGui")
local backpack = player:WaitForChild("Backpack")
local mouse = player:GetMouse()

local GUI_NAME = "AutoPainterHandsFreeUI"
local old = playerGui:FindFirstChild(GUI_NAME)
if old then old:Destroy() end

local CFG = {
	AcquireTimeout = 1.10,
	AcquireFrames = 7,
	MouseRefreshDelay = 0.018,
	PaintTimeout = 0.90,
	Retry = 0.22,
	UnreachableRetry = 0.40,
	EquipWait = 0.35,
	PaletteSettle = 0.10,
	InputVerify = 0.22,
	Idle = 0.04,
	Switch = 0.015,
	CameraHeightMin = 45,
	CameraHeightScale = 3.0,
	StatusInterval = 0.15,
}

local alive, running = true, false
local selecting = nil
local mode = "NORMAL"
local entries, lookup = {}, {}
local usedColors = {}
local nextId = 0
local workerToken = 0
local currentEntry = nil
local normalTarget = nil
local paletteBeforeRun = nil
local civilPaletteDirty = false
local held = false
local cameraSnapshot = nil
local cameraCache = setmetatable({}, {__mode = "k"})
local lastMessage = "Ready"
local lastAcquireDetail = "—"
local lastStatusAt = 0

local downSeen, upSeen = 0, 0
local inputErrors, aimFailures, noEffect, corrections = 0, 0, 0, 0
local pressAttempts, releaseAttempts = 0, 0

mouse.Button1Down:Connect(function() downSeen += 1 end)
mouse.Button1Up:Connect(function() upSeen += 1 end)

local function validProvince(part)
	local provinces = Workspace:FindFirstChild("Provinces")
	return part ~= nil and part:IsA("BasePart") and provinces ~= nil and part.Parent == provinces
end

local function paletteColor()
	local value = player:GetAttribute("PaintBucketColor")
	return typeof(value) == "Color3" and value or Color3.new(1, 1, 1)
end

local function colorKey(c)
	return string.format("%02X%02X%02X",
		math.clamp(math.round(c.R * 255), 0, 255),
		math.clamp(math.round(c.G * 255), 0, 255),
		math.clamp(math.round(c.B * 255), 0, 255))
end

local hueSeed, colorIndex = math.random(), 0
local function uniqueColor(current)
	for _ = 1, 4096 do
		colorIndex += 1
		local h = (hueSeed + colorIndex * 0.618033988749895) % 1
		local c = Color3.fromHSV(h, 0.74 + math.random() * 0.26, 0.84 + math.random() * 0.16)
		local d = ((c.R-current.R)^2 + (c.G-current.G)^2 + (c.B-current.B)^2)^0.5
		local key = colorKey(c)
		if not usedColors[key] and d >= 0.18 then
			usedColors[key] = true
			return c
		end
	end
	while true do
		local c = Color3.fromRGB(math.random(0,255), math.random(0,255), math.random(0,255))
		local key = colorKey(c)
		if not usedColors[key] then
			usedColors[key] = true
			return c
		end
	end
end

local function targetColor(entry)
	return mode == "CIVIL WAR" and entry.civilColor or normalTarget
end

local function findBucket()
	local character = player.Character
	if character then
		local tool = character:FindFirstChild("PaintBucket")
		if tool and tool:IsA("Tool") then return tool end
	end
	local tool = backpack:FindFirstChild("PaintBucket")
	return tool and tool:IsA("Tool") and tool or nil
end

local function humanoid()
	local character = player.Character
	return character and character:FindFirstChildOfClass("Humanoid") or nil
end

local function ensureBucket()
	local tool = findBucket()
	local hum = humanoid()
	local character = player.Character
	if not tool or not hum or not character or hum.Health <= 0 then return nil end
	if tool.Parent ~= character then
		if not pcall(function() hum:EquipTool(tool) end) then
			inputErrors += 1
			return nil
		end
		local deadline = os.clock() + CFG.EquipWait
		while alive and os.clock() < deadline and tool.Parent ~= character do
			RunService.Heartbeat:Wait()
		end
	end
	return tool.Parent == character and tool or nil
end

local function forceRelease()
	if not held and type(mouse1release) ~= "function" then return false end
	releaseAttempts += 1
	local fn = type(mouse1release) == "function" and mouse1release or nil
	if not fn then
		held = false
		return false
	end
	local ok = pcall(fn)
	if not ok then inputErrors += 1 end
	held = false
	-- Bounded second release. No waiting for Button1Up is required.
	task.delay(0.035, function()
		if alive then pcall(fn) end
	end)
	return ok
end

local function verifiedPress()
	if held then return true end
	local fn = type(mouse1press) == "function" and mouse1press or nil
	if not fn then
		lastMessage = "mouse1press unavailable"
		return false
	end

	pressAttempts += 1
	local baseline = downSeen
	if not pcall(fn) then
		inputErrors += 1
		lastMessage = "Mouse1 press API failed"
		return false
	end

	local deadline = os.clock() + CFG.InputVerify
	while alive and running and os.clock() < deadline do
		RunService.Heartbeat:Wait()
		if downSeen > baseline then
			held = true
			return true
		end
	end

	forceRelease()
	inputErrors += 1
	lastMessage = "Automatic Mouse1 did not reach the normal PaintBucket input loop"
	return false
end

local function saveView()
	if cameraSnapshot then return true end
	local camera = Workspace.CurrentCamera
	if not camera then return false end
	cameraSnapshot = {
		camera = camera,
		kind = camera.CameraType,
		cframe = camera.CFrame,
		focus = camera.Focus,
	}
	local ok = pcall(function()
		camera.CameraType = Enum.CameraType.Scriptable
	end)
	if not ok then
		cameraSnapshot = nil
		inputErrors += 1
		return false
	end
	return true
end

local function restoreView()
	local saved = cameraSnapshot
	cameraSnapshot = nil
	if not saved then return end
	pcall(function()
		if Workspace.CurrentCamera == saved.camera then
			saved.camera.CFrame = saved.cframe
			saved.camera.Focus = saved.focus
			saved.camera.CameraType = saved.kind
		end
	end)
end

-- Refresh PlayerMouse without changing the cursor position.
-- A zero relative movement is used only when the client exposes it.
local function refreshMouseTarget()
	if type(mousemoverel) == "function" then
		pcall(mousemoverel, 0, 0)
	end
end

local function targetPoints(part)
	local sx, sy, sz = part.Size.X, part.Size.Y, part.Size.Z
	local y = sy * 0.5 + 0.03
	local fractions = {
		Vector2.new(0, 0),
		Vector2.new(0.24, 0),
		Vector2.new(-0.24, 0),
		Vector2.new(0, 0.24),
		Vector2.new(0, -0.24),
		Vector2.new(0.22, 0.22),
		Vector2.new(-0.22, 0.22),
		Vector2.new(0.22, -0.22),
		Vector2.new(-0.22, -0.22),
	}
	local result = {}
	for _, f in ipairs(fractions) do
		result[#result + 1] = part.CFrame:PointToWorldSpace(Vector3.new(sx * f.X, y, sz * f.Y))
	end
	return result
end

local function cameraOrigins(part, point)
	local mag = math.max(part.Size.X, part.Size.Z, 1)
	local h = math.max(CFG.CameraHeightMin, mag * CFG.CameraHeightScale)
	local up, right, forward = part.CFrame.UpVector, part.CFrame.RightVector, part.CFrame.LookVector
	return {
		point + up*h + forward*(h*0.18),
		point + up*(h*0.90) + right*(h*0.40) + forward*(h*0.34),
		point + up*(h*0.90) - right*(h*0.40) + forward*(h*0.34),
		point + up*(h*0.90) + right*(h*0.40) - forward*(h*0.34),
		point + up*(h*0.90) - right*(h*0.40) - forward*(h*0.34),
	}
end

local function alignCursorRay(camera, screenPoint, worldPoint)
	local ray = camera:ScreenPointToRay(screenPoint.X, screenPoint.Y)
	local current = ray.Direction.Unit
	local wantedVector = worldPoint - camera.CFrame.Position
	if wantedVector.Magnitude < 1e-4 then return end
	local wanted = wantedVector.Unit
	local dot = math.clamp(current:Dot(wanted), -1, 1)
	if dot > 0.999995 then return end

	local axis = current:Cross(wanted)
	local axisMag = axis.Magnitude
	if axisMag < 1e-6 then return end

	local delta = CFrame.fromAxisAngle(axis / axisMag, math.acos(dot))
	local pos = camera.CFrame.Position
	local rotation = camera.CFrame - pos
	camera.CFrame = CFrame.new(pos) * delta * rotation
	camera.Focus = CFrame.new(worldPoint)
end

local function screenRayHits(camera, screenPoint, part)
	local ray = camera:ScreenPointToRay(screenPoint.X, screenPoint.Y)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local character = player.Character
	params.FilterDescendantsInstances = character and {character} or {}
	local hit = Workspace:Raycast(ray.Origin, ray.Direction * 10000, params)
	return hit and hit.Instance == part
end

local function acquireTarget(entry)
	if not saveView() then
		lastAcquireDetail = "Could not take camera control"
		return false
	end

	local camera = Workspace.CurrentCamera
	if not camera or not validProvince(entry.part) then
		lastAcquireDetail = "Province/camera disappeared"
		return false
	end

	-- Never move the user's cursor. We steer the camera ray through the cursor's
	-- current screen position and repeatedly verify the real PlayerMouse.Target.
	local screenPoint = UserInputService:GetMouseLocation()
	local cached = cameraCache[entry.part]

	local function tryPoint(point, origin, deadline)
		if not alive or not running then return false end
		if cached and origin == nil then
			camera.CFrame = cached
			camera.Focus = CFrame.new(point)
		else
			camera.CFrame = CFrame.lookAt(origin, point)
			camera.Focus = CFrame.new(point)
		end

		for _ = 1, CFG.AcquireFrames do
			if not alive or not running or os.clock() >= deadline then return false end
			RunService.RenderStepped:Wait()

			if mouse.Target == entry.part then
				cameraCache[entry.part] = camera.CFrame
				lastAcquireDetail = "Real Mouse.Target acquired"
				return true
			end

			alignCursorRay(camera, screenPoint, point)
			refreshMouseTarget()
			task.wait(CFG.MouseRefreshDelay)

			if mouse.Target == entry.part then
				cameraCache[entry.part] = camera.CFrame
				lastAcquireDetail = "Real Mouse.Target acquired after camera alignment"
				return true
			end

			if screenRayHits(camera, screenPoint, entry.part) then
				-- The visible ray is already on the province. Give PlayerMouse a few
				-- frames to refresh before trying another surface point.
				for _ = 1, 3 do
					refreshMouseTarget()
					RunService.RenderStepped:Wait()
					if mouse.Target == entry.part then
						cameraCache[entry.part] = camera.CFrame
						lastAcquireDetail = "Real Mouse.Target acquired after refresh"
						return true
					end
				end
				lastAcquireDetail = "Camera ray reached province but PlayerMouse.Target stayed stale"
			end
		end
		return false
	end

	local deadline = os.clock() + CFG.AcquireTimeout
	local points = targetPoints(entry.part)

	if cached then
		if tryPoint(points[1], nil, deadline) then return true end
	end

	for _, point in ipairs(points) do
		for _, origin in ipairs(cameraOrigins(entry.part, point)) do
			if tryPoint(point, origin, deadline) then return true end
			if os.clock() >= deadline then break end
		end
		if os.clock() >= deadline then break end
	end

	aimFailures += 1
	if lastAcquireDetail == "—" then
		lastAcquireDetail = "Could not place real Mouse.Target on province"
	end
	return false
end

local function preparePalette(target)
	if typeof(target) ~= "Color3" then return false end
	forceRelease()
	local tool = findBucket()
	local hum = humanoid()
	if not tool or not hum then return false end
	pcall(function() hum:UnequipTools() end)
	player:SetAttribute("PaintBucketColor", target)
	task.wait(0.02)
	if not ensureBucket() then return false end
	task.wait(CFG.PaletteSettle)
	return paletteColor() == target
end

local function prepareCivil(entry)
	if not preparePalette(entry.civilColor) then return false end
	civilPaletteDirty = true
	return true
end

local function restorePalette()
	if not civilPaletteDirty or typeof(paletteBeforeRun) ~= "Color3" then return end
	civilPaletteDirty = false
	local value = paletteBeforeRun
	player:SetAttribute("PaintBucketColor", value)
	task.spawn(function()
		if alive then pcall(function() preparePalette(value) end) end
	end)
end

local function chooseDirty(now)
	local best, score = nil, -math.huge
	for _, entry in ipairs(entries) do
		if entry.active and validProvince(entry.part) and now >= entry.retryAt then
			local target = targetColor(entry)
			if target and entry.part.Color ~= target then
				local s = now - entry.waitSince
				if entry == currentEntry then s += 0.08 end
				if s > score then
					best, score = entry, s
				end
			end
		end
	end
	return best
end

local function stop(reason)
	local wasCivil = running and mode == "CIVIL WAR"
	running = false
	workerToken += 1
	forceRelease()
	restoreView()
	currentEntry = nil
	if wasCivil then restorePalette() end
	if reason then lastMessage = reason end
end

local function worker(token)
	while alive and running and workerToken == token do
		local entry = chooseDirty(os.clock())
		if not entry then
			currentEntry = nil
			forceRelease()
			restoreView()
			lastMessage = "All selected provinces are at target color"
			task.wait(CFG.Idle)
			continue
		end

		currentEntry = entry
		local target = targetColor(entry)

		if mode == "CIVIL WAR" then
			if not prepareCivil(entry) then
				entry.retryAt = os.clock() + CFG.Retry
				lastMessage = "Could not prepare this Civil War color; retrying"
				task.wait(CFG.Switch)
				continue
			end
		elseif not ensureBucket() then
			entry.retryAt = os.clock() + CFG.Retry
			lastMessage = "Equip/own the normal PaintBucket"
			task.wait(CFG.Switch)
			continue
		end

		-- Always acquire the genuine PlayerMouse.Target before Mouse1 goes down.
		forceRelease()
		if not acquireTarget(entry) then
			entry.retryAt = os.clock() + CFG.UnreachableRetry
			entry.waitSince = os.clock()
			lastMessage = "Target acquisition failed: " .. lastAcquireDetail
			task.wait(CFG.Switch)
			continue
		end

		if not verifiedPress() then
			running = false
			break
		end

		local before = entry.part.Color
		local deadline = os.clock() + CFG.PaintTimeout
		while alive and running and workerToken == token and os.clock() < deadline do
			RunService.Heartbeat:Wait()
			if not validProvince(entry.part) then break end
			if mouse.Target ~= entry.part then
				lastMessage = "Real Mouse.Target was lost; retrying"
				break
			end
			if entry.part.Color == target then
				corrections += 1
				entry.retryAt = 0
				entry.waitSince = os.clock()
				lastMessage = "Corrected target"
				break
			end
		end

		forceRelease()

		if entry.active and validProvince(entry.part) and entry.part.Color ~= target then
			if entry.part.Color == before then noEffect += 1 end
			entry.retryAt = os.clock() + CFG.Retry
			entry.waitSince = os.clock()
			if mouse.Target == entry.part then
				lastMessage = "Mouse.Target was correct but no color change was observed; retrying"
			end
		end

		task.wait(CFG.Switch)
	end

	forceRelease()
	restoreView()
	currentEntry = nil
end

local function addProvince(part)
	if not validProvince(part) or lookup[part] then return false end
	nextId += 1
	local entry = {
		id = nextId,
		part = part,
		active = true,
		retryAt = 0,
		waitSince = os.clock(),
		civilColor = uniqueColor(part.Color),
	}
	entries[#entries + 1] = entry
	lookup[part] = entry

	local box = Instance.new("SelectionBox")
	box.Name = "HandsFreeProtected"
	box.Adornee = part
	box.SurfaceTransparency = 1
	box.LineThickness = 0.025
	box.Color3 = mode == "CIVIL WAR" and entry.civilColor or paletteColor()
	box.Parent = playerGui:FindFirstChild(GUI_NAME)
	entry.box = box

	entry.colorConn = part:GetPropertyChangedSignal("Color"):Connect(function()
		if entry.active and part.Color ~= targetColor(entry) then
			entry.waitSince = os.clock()
		end
	end)

	entry.destroyConn = part.Destroying:Connect(function()
		entry.active = false
		lookup[part] = nil
		if entry.box then entry.box:Destroy() end
	end)
	return true
end

local function removeProvince(part)
	local entry = lookup[part]
	if not entry then return end
	entry.active = false
	lookup[part] = nil
	if entry.colorConn then entry.colorConn:Disconnect() end
	if entry.destroyConn then entry.destroyConn:Disconnect() end
	if entry.box then entry.box:Destroy() end
end

local function clearAll()
	stop("Cleared")
	for _, entry in ipairs(entries) do
		if entry.active then removeProvince(entry.part) end
	end
	table.clear(entries)
	table.clear(lookup)
	table.clear(usedColors)
	colorIndex, hueSeed = 0, math.random()
end

-- UI -------------------------------------------------------------------------

local gui = Instance.new("ScreenGui")
gui.Name = GUI_NAME
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = playerGui

local frame = Instance.new("Frame")
frame.Size = UDim2.fromOffset(410, 420)
frame.Position = UDim2.fromOffset(12, 80)
frame.BackgroundColor3 = Color3.fromRGB(30,30,40)
frame.BorderSizePixel = 0
frame.Active = true
frame.Parent = gui

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1,0,0,34)
title.BackgroundColor3 = Color3.fromRGB(49,49,64)
title.BorderSizePixel = 0
title.Text = "AutoPainter · HANDS FREE v3"
title.TextColor3 = Color3.new(1,1,1)
title.Font = Enum.Font.SourceSansBold
title.TextSize = 19
title.Active = true
title.Parent = frame

local close = Instance.new("TextButton")
close.Size = UDim2.fromOffset(34,34)
close.Position = UDim2.new(1,-34,0,0)
close.BackgroundTransparency = 1
close.Text = "×"
close.TextColor3 = Color3.new(1,1,1)
close.TextSize = 24
close.Parent = title

local status = Instance.new("TextLabel")
status.Position = UDim2.fromOffset(10,42)
status.Size = UDim2.new(1,-20,0,88)
status.BackgroundTransparency = 1
status.TextWrapped = true
status.TextColor3 = Color3.fromRGB(220,220,230)
status.TextSize = 14
status.Parent = frame

local counts = Instance.new("TextLabel")
counts.Position = UDim2.fromOffset(10,130)
counts.Size = UDim2.new(1,-20,0,54)
counts.BackgroundTransparency = 1
counts.TextColor3 = Color3.fromRGB(120,255,160)
counts.TextSize = 14
counts.TextWrapped = true
counts.Parent = frame

local function button(text, y)
	local b = Instance.new("TextButton")
	b.Position = UDim2.fromOffset(10,y)
	b.Size = UDim2.new(1,-20,0,34)
	b.BackgroundColor3 = Color3.fromRGB(75,75,95)
	b.BorderSizePixel = 0
	b.TextColor3 = Color3.new(1,1,1)
	b.Font = Enum.Font.SourceSansBold
	b.TextSize = 15
	b.Text = text
	b.Parent = frame
	return b
end

local modeButton = button("Mode: NORMAL", 190)
local addButton = button("Protect Province", 230)
local removeButton = button("Unprotect Province", 270)
local clearButton = button("Clear Provinces", 310)
local startButton = button("START AUTO", 350)

local doneButton = Instance.new("TextButton")
doneButton.Size = UDim2.fromOffset(260,42)
doneButton.AnchorPoint = Vector2.new(0.5,0)
doneButton.Position = UDim2.new(0.5,0,0,8)
doneButton.BackgroundColor3 = Color3.fromRGB(35,145,110)
doneButton.BorderSizePixel = 0
doneButton.TextColor3 = Color3.new(1,1,1)
doneButton.TextSize = 18
doneButton.Text = "DONE SELECTING"
doneButton.Visible = false
doneButton.Parent = gui

local function activeCount()
	local n = 0
	for _, e in ipairs(entries) do
		if e.active then n += 1 end
	end
	return n
end

local function dirtyCount()
	local n = 0
	for _, e in ipairs(entries) do
		if e.active and validProvince(e.part) then
			local target = targetColor(e)
			if target and e.part.Color ~= target then n += 1 end
		end
	end
	return n
end

local function updateUI()
	if not alive then return end
	modeButton.Text = "Mode: " .. mode
	startButton.Text = running and "STOP AUTO" or "START AUTO"
	local c = normalTarget or paletteColor()
	counts.Text = string.format(
		"Selected: %d · Dirty: %d · Mode: %s\nCorrections: %d · Aim fails: %d · No effect: %d · Input errors: %d",
		activeCount(), dirtyCount(), mode, corrections, aimFailures, noEffect, inputErrors
	)
	status.Text = lastMessage
		.. "\nAcquire: " .. lastAcquireDetail
		.. (mode == "NORMAL" and ("\nNormal target: " .. tostring(c))
			or "\nCivil War: unique target color per province")

	for _, e in ipairs(entries) do
		if e.active and e.box then
			e.box.Color3 = mode == "CIVIL WAR" and e.civilColor or c
		end
	end
end

local function beginSelection(kind)
	stop("Selection mode")
	selecting = kind
	frame.Visible = false
	doneButton.Visible = true
	lastMessage = kind == "ADD" and "Click provinces to protect" or "Click provinces to remove"
	updateUI()
end

local function finishSelection()
	selecting = nil
	frame.Visible = true
	doneButton.Visible = false
	lastMessage = "Selection finished"
	updateUI()
end

local function startAuto()
	if running then return true end
	if activeCount() == 0 then
		lastMessage = "Select at least one province first"
		updateUI()
		return false
	end
	if type(mouse1press) ~= "function" or type(mouse1release) ~= "function" then
		lastMessage = "This client does not expose mouse1press/mouse1release"
		updateUI()
		return false
	end
	if not ensureBucket() then
		lastMessage = "Equip/own the normal PaintBucket first"
		updateUI()
		return false
	end

	paletteBeforeRun = paletteColor()
	normalTarget = paletteBeforeRun
	if mode == "NORMAL" and not preparePalette(normalTarget) then
		lastMessage = "Could not prepare the normal PaintBucket color"
		updateUI()
		return false
	end

	for _, e in ipairs(entries) do
		if e.active then
			e.waitSince = os.clock()
			e.retryAt = 0
		end
	end

	running = true
	workerToken += 1
	lastAcquireDetail = "Waiting for first target"
	lastMessage = "Running automatically through the normal PaintBucket input path"
	task.spawn(worker, workerToken)
	updateUI()
	return true
end

local function toggleAuto()
	if running then stop("Stopped") else startAuto() end
	updateUI()
end

modeButton.Activated:Connect(function()
	if running then stop("Stopped before changing mode") end
	mode = mode == "NORMAL" and "CIVIL WAR" or "NORMAL"
	lastMessage = mode == "NORMAL"
		and "Normal mode uses the current PaintBucket palette color"
		or "Civil War gives every selected province a unique random target color"
	updateUI()
end)

addButton.Activated:Connect(function() beginSelection("ADD") end)
removeButton.Activated:Connect(function() beginSelection("REMOVE") end)
clearButton.Activated:Connect(function() clearAll(); updateUI() end)
doneButton.Activated:Connect(finishSelection)
startButton.Activated:Connect(toggleAuto)

UserInputService.InputBegan:Connect(function(input, processed)
	if input.KeyCode == Enum.KeyCode.Escape then
		if selecting then finishSelection() else stop("Emergency stop") end
		updateUI()
		return
	end
	if processed or UserInputService:GetFocusedTextBox() then return end
	if input.KeyCode == Enum.KeyCode.Q then
		toggleAuto()
		return
	end
	if selecting and input.UserInputType == Enum.UserInputType.MouseButton1 then
		local part = mouse.Target
		if selecting == "ADD" then addProvince(part) else removeProvince(part) end
		updateUI()
	end
end)

local dragging = false
local dragStart, frameStart, dragInput

title.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		dragging = true
		dragStart = input.Position
		frameStart = frame.Position
		dragInput = input
	end
end)

UserInputService.InputChanged:Connect(function(input)
	if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
		local d = input.Position - dragStart
		frame.Position = UDim2.new(
			frameStart.X.Scale, frameStart.X.Offset + d.X,
			frameStart.Y.Scale, frameStart.Y.Offset + d.Y
		)
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if input == dragInput or input.UserInputType == Enum.UserInputType.MouseButton1 then
		dragging = false
		dragInput = nil
	end
end)

close.Activated:Connect(function()
	if not alive then return end
	stop("Closed")
	alive = false
	for _, e in ipairs(entries) do
		if e.active then removeProvince(e.part) end
	end
	gui:Destroy()
end)

player:GetPropertyChangedSignal("Character"):Connect(function()
	if running then stop("Character changed; restart Auto") end
end)

Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
	if running then stop("Camera changed; restart Auto") end
end)

RunService.Heartbeat:Connect(function()
	if alive and os.clock() - lastStatusAt >= CFG.StatusInterval then
		lastStatusAt = os.clock()
		updateUI()
	end
end)

updateUI()

return {
	Start = startAuto,
	Stop = function() stop("Stopped by API"); updateUI() end,
	SetMode = function(value)
		if value ~= "NORMAL" and value ~= "CIVIL WAR" then return false end
		if running then stop("Stopped before changing mode") end
		mode = value
		updateUI()
		return true
	end,
	AddProvince = addProvince,
	RemoveProvince = removeProvince,
	Clear = clearAll,
	GetStats = function()
		return {
			Running = running,
			Mode = mode,
			Selected = activeCount(),
			Dirty = dirtyCount(),
			Held = held,
			Corrections = corrections,
			AimFailures = aimFailures,
			NoEffect = noEffect,
			InputErrors = inputErrors,
			PressAttempts = pressAttempts,
			ReleaseAttempts = releaseAttempts,
			ObservedDown = downSeen,
			ObservedUp = upSeen,
			LastAcquire = lastAcquireDetail,
			AutoPainterRPCs = 0,
		}
	end,
}
