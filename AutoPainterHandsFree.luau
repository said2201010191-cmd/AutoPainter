-- AutoPainter Hands Free v4
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
if old then
	local controller = old:FindFirstChild("ActivationController")
	assert(controller and controller:IsA("BindableFunction"), "Close the older Hands Free panel before loading this revision")
	local existing = controller:Invoke()
	assert(not existing.GetStats().Closed, "Previous activation release is unresolved; this controller cannot overlap it")
	return existing
end

local CFG = {
	AcquireTimeout = 1.10,
	AcquireFrames = 7,
	MouseRefreshDelay = 0.018,
	PaintTimeout = 0.90,
	Retry = 0.22,
	UnreachableRetry = 0.40,
	EquipWait = 0.35,
	PaletteSettle = 0.10,
	InputVerify = 0.35,
	ActivationReleaseTimeout = 0.40,
	ActivationReleaseQuiet = 0.06,
	ConfirmedNoEffectLimit = 3,
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

-- ACTIVATION LAYER BEGIN: no target/camera changes and no game remote transport.
local activation = { Method = "none", TargetAcquired = false, Attempted = false,
	Observed = false, Observation = "none", ColorChanged = false, TargetColorObserved = false,
	Status = "Not tested", Source = "Not inspected", Results = {}, Preferred = nil }
local activationTool, activationMethods, rejectedMethods = nil, {}, {}
local toolConnections, equippedMouseConnections = {}, {}
local ownedInput, inputBusy, pendingRelease = nil, false, false
local workerActive, releaseBlocked, starting = false, false, false
local finishClose, restorePending, restoringPalette = nil, false, false
local focused = true
local lifetimeConnections = {}
local function connectLifetime(signal, callback)
	local c = signal:Connect(callback);table.insert(lifetimeConnections,c);return c
end
local toolDownSeen, toolUpSeen, equippedDownSeen, equippedUpSeen = 0, 0, 0, 0
local forceRelease, observeTool
local inputConnections = {
	mouse.Button1Down:Connect(function() downSeen += 1 end),
	mouse.Button1Up:Connect(function() upSeen += 1 end),
}
local function disconnectInput(list)
	for _, connection in ipairs(list) do connection:Disconnect() end
	table.clear(list)
end
local function result(text)
	if #activation.Results >= 12 then table.remove(activation.Results, 1) end
	table.insert(activation.Results, text)
end
local function inspectActivationSource(tool)
	-- Source is often protected. No decompiler, require, closure access or execution.
	local readable, failures, mouseHandlers, toolHandlers = 0, 0, 0, 0
	local ok, descendants = pcall(function() return tool:GetDescendants() end)
	if not ok then return "PaintBucket inventory unavailable; handler wiring unknown" end
	for _, object in ipairs(descendants) do
		if object:IsA("LocalScript") then
			local success, source = pcall(function() return object.Source end)
			if success and type(source) == "string" and #source > 0 then
				readable += 1
				if source:find("Button1Down", 1, true) then mouseHandlers += 1 end
				if source:find(".Activated", 1, true) then toolHandlers += 1 end
			else failures += 1 end
		end
	end
	return string.format("LocalScript text readable=%d unavailable=%d; Button1Down mentions=%d Activated mentions=%d. Text/event existence does not prove handler execution.",
		readable, failures, mouseHandlers, toolHandlers)
end
observeTool = function(tool)
	if activationTool == tool then return end
	disconnectInput(toolConnections); disconnectInput(equippedMouseConnections)
	activationTool = tool
	activation.Preferred = nil
	activationMethods, rejectedMethods = {}, {}
	activation.Source = inspectActivationSource(tool)
	table.insert(toolConnections, tool.Activated:Connect(function() toolDownSeen += 1 end))
	table.insert(toolConnections, tool.Deactivated:Connect(function() toolUpSeen += 1 end))
	table.insert(toolConnections, tool.Equipped:Connect(function(toolMouse)
		disconnectInput(equippedMouseConnections)
		-- The actual Mouse delivered to Equipped can differ from Player:GetMouse().
		if toolMouse and toolMouse ~= mouse then
			table.insert(equippedMouseConnections, toolMouse.Button1Down:Connect(function() equippedDownSeen += 1 end))
			table.insert(equippedMouseConnections, toolMouse.Button1Up:Connect(function() equippedUpSeen += 1 end))
		end
	end))
end
local function discoverActivation(tool)
	observeTool(tool)
	if #activationMethods > 0 then return end
	if type(mouse1press) == "function" and type(mouse1release) == "function" then
		table.insert(activationMethods, { Name = "mouse1press", Down = mouse1press, Up = mouse1release })
	else result("mouse1press: unavailable (both down/up functions required)") end
	local ok, virtualInput = pcall(function() return UserInputService:CreateVirtualInput() end)
	if ok and virtualInput then
		table.insert(activationMethods, { Name = "VirtualInput.SendMouseButton",
			Down = function()
				virtualInput:SendMouseButton(UserInputService:GetMouseLocation(), Enum.UserInputType.MouseButton1, true, 0)
			end,
			Up = function()
				virtualInput:SendMouseButton(UserInputService:GetMouseLocation(), Enum.UserInputType.MouseButton1, false, 0)
			end })
	else result("VirtualInput: unavailable/denied; no privileged fallback") end
	table.insert(activationMethods, { Name = "Tool:Activate", ToolMethod = true,
		Down = function() tool:Activate() end, Up = function() tool:Deactivate() end })
end
local function callInput(fn)
	if inputBusy then return false, "Input call already pending" end
	inputBusy = true
	local ok, problem = pcall(fn)
	inputBusy = false
	if pendingRelease then pendingRelease = false; forceRelease() end
	return ok, problem
end
local function inputEvidence(owner)
	owner.MouseObserved = downSeen > owner.Down or equippedDownSeen > owner.EquippedDown
	owner.ToolObserved = toolDownSeen > owner.ToolDown
	activation.Observed = owner.MouseObserved or owner.ToolObserved
	activation.Observation = owner.MouseObserved and "Mouse.Button1Down"
		or owner.ToolObserved and "Tool.Activated only" or "none"
end
forceRelease = function()
	local owner = ownedInput
	if not owner then held = false; return not releaseBlocked end
	if inputBusy then pendingRelease = true; return false end
	if owner.ReleaseSent then return not owner.ReleaseError end
	inputEvidence(owner)
	owner.ReleaseSent, owner.ReleaseAt = true, os.clock()
	owner.Up, owner.EquippedUp, owner.ToolUp = upSeen, equippedUpSeen, toolUpSeen
	releaseAttempts += 1
	local ok, problem = callInput(owner.Method.Up)
	owner.ReleaseError = not ok
	held = false
	if not ok then
		inputErrors += 1
		result(owner.Method.Name .. " release error: " .. tostring(problem))
	end
	-- No delayed duplicate up: it could release the NEXT method's hold.
	return ok
end
local function releaseObserved(owner)
	if not owner.ReleaseSent then return false end
	inputEvidence(owner) -- include deferred down observations before deciding that a failed call was inert
	if owner.MouseObserved then return upSeen > owner.Up or equippedUpSeen > owner.EquippedUp end
	if owner.ToolObserved then return toolUpSeen > owner.ToolUp end
	-- An unobserved/no-op down has no matching event to await. Require a successful
	-- paired release, a quiet interval, and an observable non-pressed mouse state.
	local ok, pressed = pcall(function() return UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) end)
	return (not owner.ReleaseError or owner.DownFailed) and ok and not pressed and os.clock() - owner.ReleaseAt >= CFG.ActivationReleaseQuiet
end
local function settleRelease()
	local owner = ownedInput
	if not owner then return not releaseBlocked end
	forceRelease()
	local deadline = os.clock() + CFG.ActivationReleaseTimeout
	while ownedInput == owner and os.clock() < deadline do
		if not inputBusy and releaseObserved(owner) then
			ownedInput, releaseBlocked = nil, false
			return true
		end
		RunService.Heartbeat:Wait()
	end
	releaseBlocked = true
	activation.Status = "Release unconfirmed; stopped without testing another activation method"
	lastMessage = activation.Status
	return false
end
local function inputAllowed(entry, tool, token)
	return alive and running and workerToken == token and entry.active and validProvince(entry.part)
		and mouse.Target == entry.part and tool.Parent == player.Character and focused
end
local function activateAndPaint(entry, target, token)
	local tool = findBucket()
	if not tool or tool.Parent ~= player.Character or not tool.Enabled then return "retry" end
	discoverActivation(tool)
	activation.TargetAcquired = mouse.Target == entry.part
	if not activation.TargetAcquired then return "retry" end
	local order = {}
	for _, method in ipairs(activationMethods) do
		if method == activation.Preferred then table.insert(order, 1, method) else table.insert(order, method) end
	end
	for _, method in ipairs(order) do
		if rejectedMethods[method.Name] then continue end
		if not inputAllowed(entry, tool, token) or not tool.Enabled then return "retry" end
		if entry.part.Color == target then return "correct" end
		if ownedInput or releaseBlocked or inputBusy then return "blocked" end
		if UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) then
			activation.Status = "Existing Mouse1 down; activation not attempted"
			return "blocked"
		end
		activation.Method, activation.Attempted, activation.Observed = method.Name, true, false
		activation.Observation, activation.ColorChanged, activation.TargetColorObserved = "none", false, false
		activation.Status = "Activation attempted; awaiting observable input and target color"
		local owner = { Method = method, Tool = tool, Before = entry.part.Color, Down = downSeen,
			EquippedDown = equippedDownSeen, ToolDown = toolDownSeen }
		ownedInput, held = owner, true -- reserve before an external function can yield
		pressAttempts += 1
		local ok, problem = callInput(method.Down)
		owner.DownFailed = not ok
		if not ok then inputErrors += 1 end
		local deadline = os.clock() + CFG.PaintTimeout
		local inputDeadline = os.clock() + CFG.InputVerify
		local confirmed, interrupted = false, false
		while ok and inputAllowed(entry, tool, token) and not owner.ReleaseSent do
			inputEvidence(owner)
			if entry.part.Color ~= owner.Before then activation.ColorChanged = true end
			activation.TargetColorObserved = entry.part.Color == target
			if activation.Observed and activation.TargetColorObserved then confirmed = true; break end
			if os.clock() >= deadline or (not activation.Observed and os.clock() >= inputDeadline) then break end
			RunService.Heartbeat:Wait()
		end
		interrupted = not inputAllowed(entry, tool, token) or owner.ReleaseSent
		inputEvidence(owner)
		if not settleRelease() then return "blocked" end
		if interrupted then return "retry" end
		if confirmed then
			activation.Preferred = method
			method.NoEffect = 0
			activation.Status = "Activation observed + target color changed (local evidence; server causality unobserved)"
			result(method.Name .. ": " .. activation.Observation .. "; target color observed")
			return "correct"
		end
		local detail = not ok and ("API error: " .. tostring(problem))
			or (activation.Observation .. "; no confirming target-color change")
		result(method.Name .. ": " .. detail)
		if method == activation.Preferred and activation.Observed then
			method.NoEffect = (method.NoEffect or 0) + 1
			if method.NoEffect < CFG.ConfirmedNoEffectLimit then
				activation.Status = "Previously observed method had no effect; bounded target retry"
				return "retry"
			end
		end
		rejectedMethods[method.Name] = true
		if activation.Preferred == method then activation.Preferred = nil end
	end
	activation.Status = "No available activation method confirmed the normal paint path. Input/color evidence is incomplete; stopped."
	lastMessage = activation.Status
	return "unsupported"
end
local function activationStats()
	return { Method=activation.Method, TargetAcquired=activation.TargetAcquired, Attempted=activation.Attempted,
		Observed=activation.Observed, Observation=activation.Observation, ColorChanged=activation.ColorChanged,
		TargetColorObserved=activation.TargetColorObserved, Status=activation.Status,
		Preferred=activation.Preferred and activation.Preferred.Name or nil }
end
local function activationReport()
	return table.concat({ "AUTOPAINTER ACTIVATION REPORT", "AutoPainterRPCs=0; no direct game remote calls",
		"Target acquired=" .. tostring(activation.TargetAcquired), "Activation method=" .. activation.Method,
		"Activation attempted=" .. tostring(activation.Attempted), "Activation observed=" .. tostring(activation.Observed) .. " (" .. activation.Observation .. ")",
		"Color changed=" .. tostring(activation.ColorChanged) .. " Target color observed=" .. tostring(activation.TargetColorObserved),
		"Status=" .. activation.Status, "Tool source: " .. activation.Source,
		"Tool.Activated alone does not establish that Mouse.Button1Down or the paint handler ran.",
		"A color transition can have another cause; no server acknowledgment is observed.",
		table.concat(activation.Results, "\n"), }, "\n")
end
-- ACTIVATION LAYER END

local function ensureBucket()
	local tool = findBucket()
	local hum = humanoid()
	local character = player.Character
	if not tool or not hum or not character or hum.Health <= 0 then return nil end
	observeTool(tool)
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
	if not settleRelease() then return false end
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
	if ownedInput or workerActive or starting then restorePending = true; return end
	restorePending = false
	if not civilPaletteDirty or typeof(paletteBeforeRun) ~= "Color3" then return end
	civilPaletteDirty = false
	local value = paletteBeforeRun
	player:SetAttribute("PaintBucketColor", value)
	if alive then pcall(function() preparePalette(value) end) end
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
	if not ownedInput then restoreView() end
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
		activation.TargetAcquired = false
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

		local outcome = activateAndPaint(entry, target, token)
		if outcome == "unsupported" or outcome == "blocked" then
			lastMessage = activation.Status
			running = false
			break
		end
		if not alive or not running or workerToken ~= token then break end
		if outcome == "correct" then
			corrections += 1
			entry.retryAt, entry.waitSince = 0, os.clock()
			lastMessage = "Target color observed through " .. activation.Method
		elseif entry.active and validProvince(entry.part) then
			noEffect += 1
			entry.retryAt, entry.waitSince = os.clock() + CFG.Retry, os.clock()
			lastMessage = activation.Status
		end

		task.wait(CFG.Switch)
	end

	if settleRelease() then restoreView() end
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
frame.Size = UDim2.fromOffset(410, 500)
frame.Position = UDim2.fromOffset(12, 80)
frame.BackgroundColor3 = Color3.fromRGB(30,30,40)
frame.BorderSizePixel = 0
frame.Active = true
frame.Parent = gui

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1,0,0,34)
title.BackgroundColor3 = Color3.fromRGB(49,49,64)
title.BorderSizePixel = 0
title.Text = "AutoPainter · HANDS FREE v4"
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

local liveStatus = Instance.new("TextLabel")
liveStatus.Name = "ActivationLiveStatus"
liveStatus.Position = UDim2.fromOffset(12,42)
liveStatus.Size = UDim2.fromOffset(410,155)
liveStatus.BackgroundTransparency = 0.2
liveStatus.BackgroundColor3 = Color3.fromRGB(30,30,40)
liveStatus.TextColor3 = Color3.new(1,1,1)
liveStatus.TextWrapped = true
liveStatus.TextSize = 14
liveStatus.Active = false
liveStatus.Visible = false
liveStatus.Parent = gui

local status = Instance.new("TextLabel")
status.Position = UDim2.fromOffset(10,42)
status.Size = UDim2.new(1,-20,0,155)
status.BackgroundTransparency = 1
status.TextWrapped = true
status.TextColor3 = Color3.fromRGB(220,220,230)
status.TextSize = 14
status.Parent = frame

local counts = Instance.new("TextLabel")
counts.Position = UDim2.fromOffset(10,200)
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

local modeButton = button("Mode: NORMAL", 260)
local addButton = button("Protect Province", 300)
local removeButton = button("Unprotect Province", 340)
local clearButton = button("Clear Provinces", 380)
local startButton = button("START AUTO", 420)
local copyButton = button("Copy Activation Report", 460)
local function copyActivationReport()
	local report = activationReport()
	if type(setclipboard) == "function" and pcall(setclipboard, report) then return true end
	if type(writefile) == "function" and pcall(writefile, "AutoPainterActivationReport.txt", report) then return true end
	return false
end
copyButton.Activated:Connect(copyActivationReport)

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
	frame.Visible = not running and not selecting
	liveStatus.Visible = running
	modeButton.Text = "Mode: " .. mode
	startButton.Text = running and "STOP AUTO" or "START AUTO"
	local c = normalTarget or paletteColor()
	counts.Text = string.format(
		"Selected: %d · Dirty: %d · Mode: %s\nCorrections: %d · Aim fails: %d · No effect: %d · Input errors: %d",
		activeCount(), dirtyCount(), mode, corrections, aimFailures, noEffect, inputErrors
	)
	status.Text = lastMessage
		.. "\nAcquire: " .. lastAcquireDetail
		.. "\nTarget acquired: " .. tostring(activation.TargetAcquired) .. " · Method: " .. activation.Method
		.. "\nActivation attempted: " .. tostring(activation.Attempted)
		.. " · Activation observed: " .. activation.Observation
		.. "\nColor changed: " .. tostring(activation.ColorChanged) .. " · Target color: " .. tostring(activation.TargetColorObserved)
		.. (mode == "NORMAL" and ("\nNormal target: " .. tostring(c))
			or "\nCivil War: unique target color per province")

	liveStatus.Text = "AUTO · Q / Escape to stop\n" .. status.Text
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

local function startAutoImpl()
	local startToken = workerToken
	if running then return true end
	if not alive or selecting or workerActive or inputBusy or restoringPalette then return false end
	if ownedInput then
		if releaseObserved(ownedInput) then ownedInput, releaseBlocked = nil, false
		else lastMessage = "Previous activation release is unresolved"; updateUI(); return false end
	end
	if releaseBlocked then return false end
	if activeCount() == 0 then
		lastMessage = "Select at least one province first"
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

	if not alive or selecting or workerToken ~= startToken then return false end
	rejectedMethods = {} -- explicit START permits one new bounded trial sequence
	running = true
	workerToken += 1
	lastAcquireDetail = "Waiting for first target"
	lastMessage = "Running automatically through the normal PaintBucket input path"
	updateUI()
	workerActive = true
	local token = workerToken
	task.spawn(function()
		local ok, problem = pcall(worker, token)
		if not ok then
			inputErrors += 1
			stop("Activation/controller error: " .. tostring(problem))
			settleRelease()
		end
		workerActive = false
		if not running and restorePending then restoringPalette=true;restorePalette();restoringPalette=false end
		if not alive and finishClose then finishClose() end
	end)
	updateUI()
	return true
end

local function startAuto()
	if starting then return false end
	starting = true
	local ok, value = pcall(startAutoImpl)
	starting = false
	if not ok then stop("Activation start error: " .. tostring(value)); updateUI(); return false end
	return value
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

connectLifetime(UserInputService.InputBegan, function(input, processed)
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

connectLifetime(UserInputService.InputChanged, function(input)
	if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
		local d = input.Position - dragStart
		frame.Position = UDim2.new(
			frameStart.X.Scale, frameStart.X.Offset + d.X,
			frameStart.Y.Scale, frameStart.Y.Offset + d.Y
		)
	end
end)

connectLifetime(UserInputService.InputEnded, function(input)
	if input == dragInput or input.UserInputType == Enum.UserInputType.MouseButton1 then
		dragging = false
		dragInput = nil
	end
end)

finishClose = function()
	if ownedInput or inputBusy or workerActive then return end
	disconnectInput(inputConnections)
	disconnectInput(toolConnections)
	disconnectInput(equippedMouseConnections)
	gui:Destroy()
end
local function closeController()
	if not alive then return end
	stop("Closed")
	alive = false
	disconnectInput(lifetimeConnections)
	for _, e in ipairs(entries) do
		if e.active then removeProvince(e.part) end
	end
	gui.Enabled = false
	finishClose()
end
close.Activated:Connect(closeController)
gui.Destroying:Connect(closeController)

connectLifetime(UserInputService.WindowFocusReleased, function()
	focused=false
	stop("Client lost focus; activation stopped")
end)
connectLifetime(UserInputService.WindowFocused, function() focused=true end)
connectLifetime(player:GetPropertyChangedSignal("Character"), function()
	if running then stop("Character changed; restart Auto") end
end)

connectLifetime(Workspace:GetPropertyChangedSignal("CurrentCamera"), function()
	if running then stop("Camera changed; restart Auto") end
end)

connectLifetime(RunService.Heartbeat, function()
	if alive and os.clock() - lastStatusAt >= CFG.StatusInterval then
		lastStatusAt = os.clock()
		updateUI()
	end
end)

updateUI()

local api = {
	Destroy = closeController,
	GetActivationReport = activationReport,
	CopyActivationReport = copyActivationReport,
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
			Activation = activationStats(),
			Closed = not alive,
			LastMessage = lastMessage,
		}
	end,
}
local bridge = Instance.new("BindableFunction")
bridge.Name = "ActivationController"
bridge.OnInvoke = function() return api end
bridge.Parent = gui
return api
