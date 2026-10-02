-- AutoPainter Hands Free v6
-- Fully automatic client-side controller using the normal PaintBucket input path.
-- No direct PaintPart calls, no Mouse.Target/GetMouseData spoofing, and no hooks.
-- NORMAL paints every protected province to one palette color.
-- CIVIL WAR is optional and assigns a unique color to every protected province.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local GuiService = game:GetService("GuiService")

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
	ActivationStrategy = "ADAPTIVE", -- ADAPTIVE, PER_TARGET or CONTINUOUS; no native cooldown changes.
	TargetDwellDefault = 0.32,
	TargetDwellMin = 0.20,
	TargetDwellMax = 0.45,
	DwellHistory = 24,
	DwellMinSamples = 4,
	DwellMargin = 0.08,
	StrategyMinAttempts = 4,
	StrategyMaxProbeAttempts = 8,
	StrategyWindow = 16,
	StrategyReliabilityMargin = 0.20,
	StrategyThroughputMargin = 0.20,
	ReconcileInterval = 0.15,
	RecentlyChangedPriorityWindow = 1.0,
	CursorAcquire = 0.10,
	HeldCursorGrace = 0.035,
	MaxProjections = 96,
	MaxRays = 32,
	CandidatesPerStep = 32,
	PointsPerCandidate = 9,
	MaxTransitionsPerFrame = 8,
	PriorityAge = 2.0,
	MaxRetry = 1.6,
	StallsBeforeHoldRecovery = 8,
	AcquireTimeout = 1.10,
	AcquireFrames = 7,
	MouseRefreshDelay = 0.018,
	PaintTimeout = 0.90,
	Retry = 0.12,
	UnreachableRetry = 0.40,
	EquipWait = 0.35,
	PaletteSettle = 0.10,
	InputVerify = 0.35,
	ActivationReleaseTimeout = 0.40,
	ActivationReleaseQuiet = 0.06,
	ConfirmedNoEffectLimit = 3,
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
local downObservedAt,equippedDownObservedAt=nil,nil
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
	return mode == "CIVIL WAR" and entry.civilColor or (normalTarget or paletteColor())
end

local cachedBucket,cachedHumanoid=nil,nil
local function findBucket()
	local character = player.Character
	if cachedBucket and ((character and cachedBucket.Parent==character) or (backpack and cachedBucket.Parent==backpack)) then return cachedBucket end
	if character then
		local tool = character:FindFirstChild("PaintBucket")
		if tool and tool:IsA("Tool") then cachedBucket=tool;return tool end
	end
	if not backpack or backpack.Parent~=player then backpack=player:FindFirstChildOfClass("Backpack") end
	local tool = backpack and backpack:FindFirstChild("PaintBucket")
	cachedBucket=tool and tool:IsA("Tool") and tool or nil
	return cachedBucket
end

local function humanoid()
	local character = player.Character
	if character and cachedHumanoid and cachedHumanoid.Parent==character then return cachedHumanoid end
	cachedHumanoid=character and character:FindFirstChildOfClass("Humanoid") or nil
	return cachedHumanoid
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
local forceRelease, observeTool, onLateUp
local virtualInput, primaryMethod, primaryFailures, holdStalls = nil, nil, 0, 0
local equippedGeneration, confirmedGeneration = 0, -1
local inputConnections = {
	mouse.Button1Down:Connect(function() downSeen += 1;downObservedAt=os.clock() end),
	mouse.Button1Up:Connect(function()
		upSeen += 1
		if ownedInput and not ownedInput.ReleaseSent then ownedInput.ExternalUp=true end
		if onLateUp then onLateUp() end
	end),
}
local function disconnectInput(list)
	for _, connection in ipairs(list) do connection:Disconnect() end
	table.clear(list)
end
local function result(text)
	if #activation.Results >= 12 then table.remove(activation.Results, 1) end
	table.insert(activation.Results, text)
end
observeTool = function(tool)
	if activationTool == tool then return end
	disconnectInput(toolConnections); disconnectInput(equippedMouseConnections)
	activationTool = tool
	activation.Preferred = nil
	activationMethods, rejectedMethods = {}, {}
	activation.Source = "VirtualInput live-confirmed by user; no source scan on the fast path"
	virtualInput,primaryMethod,primaryFailures=nil,nil,0
	equippedGeneration+=1;confirmedGeneration=-1
	table.insert(toolConnections, tool.Activated:Connect(function() toolDownSeen += 1 end))
	table.insert(toolConnections, tool.Deactivated:Connect(function() toolUpSeen += 1;if onLateUp then onLateUp() end end))
	table.insert(toolConnections, tool.Equipped:Connect(function(toolMouse)
		equippedGeneration+=1;confirmedGeneration=-1
		disconnectInput(equippedMouseConnections)
		-- The actual Mouse delivered to Equipped can differ from Player:GetMouse().
		if toolMouse and toolMouse ~= mouse then
			table.insert(equippedMouseConnections, toolMouse.Button1Down:Connect(function() equippedDownSeen += 1;equippedDownObservedAt=os.clock() end))
			table.insert(equippedMouseConnections, toolMouse.Button1Up:Connect(function()
				equippedUpSeen+=1
				if ownedInput and not ownedInput.ReleaseSent then ownedInput.ExternalUp=true end
				if onLateUp then onLateUp() end
			end))
		end
	end))
end
local function discoverActivation(tool)
	observeTool(tool)
	if #activationMethods > 0 then return end
	local ok, handle = pcall(function() return UserInputService:CreateVirtualInput() end)
	if ok and handle then
		virtualInput = handle
		primaryMethod = { Name = "VirtualInput.SendMouseButton",
			Down = function() handle:SendMouseButton(UserInputService:GetMouseLocation(), Enum.UserInputType.MouseButton1, true, 0) end,
			Up = function() handle:SendMouseButton(UserInputService:GetMouseLocation(), Enum.UserInputType.MouseButton1, false, 0) end }
		table.insert(activationMethods,primaryMethod)
	else result("VirtualInput unavailable; bounded alternate activation recovery") end
	if type(mouse1press)=="function" and type(mouse1release)=="function" then
		table.insert(activationMethods,{Name="mouse1press",Down=mouse1press,Up=mouse1release})
	end
	table.insert(activationMethods,{Name="Tool:Activate",ToolMethod=true,
		Down=function() tool:Activate() end,Up=function() tool:Deactivate() end})
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
	if owner.MouseObserved and not owner.MouseObservedAt then
		local general=downSeen>owner.Down and downObservedAt or math.huge
		local equipped=equippedDownSeen>owner.EquippedDown and equippedDownObservedAt or math.huge
		owner.MouseObservedAt=math.min(general,equipped)
	end
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
	if owner.ExternalUp then
		local ok, pressed=pcall(function() return UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) end)
		if ok and not pressed then return true end
	end
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
	if ownedInput~=owner then return not releaseBlocked end
	releaseBlocked = true
	activation.Status = "Release unconfirmed; stopped without testing another activation method"
	lastMessage = activation.Status
	return false
end
onLateUp = function()
	if not alive and ownedInput and not inputBusy and releaseObserved(ownedInput) then
		ownedInput,releaseBlocked=nil,false
		if finishClose then finishClose() end
	end
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

-- Fast queue/target path. The v4 camera acquisition above remains the last fallback.
local dirty, dirtyCursor = {}, 0
local freshHead,freshTail,freshCount=nil,nil,0
local wake = Instance.new("BindableEvent")
local transitionCount, projectionsLeft, raysLeft = 0, CFG.MaxProjections, CFG.MaxRays
local nextWorkerAt,nextReconcileAt=nil,0
local lastPreparedColor, lastPreparedTool = nil, nil
local metrics = { Acquisitions=0, Corrections=0, CachedCursorHits=0, CachedCameraHits=0,
	FullCameraSearches=0, Deferred=0, Stalled=0, Projections=0, Raycasts=0, Candidates=0,
	AcquireTotal=0, ColorTotal=0, SwitchTotal=0, Switches=0, QueueEvaluations=0,
	Attempts=0,CompletedServices=0,AbortedServices=0,ServiceTotal=0,
	ColorEventsReceived=0,DirtyEventsWithoutHover=0,ColorEventQueueTotal=0,ColorEventQueued=0,
	MaxColorEventToDirtyQueueMs=0,ReconciliationFinds=0,ReconciliationChecks=0,
	FreshAttackCorrections=0,AttackResponseTotal=0,MinimumAttackResponseMs=0,MaximumAttackResponseMs=0,
	AcquisitionAttempts=0,CursorAcquireAttempts=0,CursorAcquireSuccesses=0,CameraFallbacks=0 }
local rateBins, runStartedAt, runSeconds, switchedAt = {}, nil, 0, nil
local syncDirty, removeProvince, noteCorrection
local eventLog,lastOffHoverEvent={},nil
local function wakeWork() nextWorkerAt=nil;if alive then wake:Fire() end end
local function waitWork() wake.Event:Wait() end
local function unlinkFresh(entry)
	if not entry.freshLinked then return end
	if entry.freshPrev then entry.freshPrev.freshNext=entry.freshNext else freshHead=entry.freshNext end
	if entry.freshNext then entry.freshNext.freshPrev=entry.freshPrev else freshTail=entry.freshPrev end
	entry.freshPrev,entry.freshNext,entry.freshLinked=nil,nil,false;freshCount-=1
end
local function markFresh(entry,now)
	unlinkFresh(entry);entry.recentUntil=now+CFG.RecentlyChangedPriorityWindow
	entry.freshLinked,entry.freshNext,entry.freshPrev=true,freshHead,nil
	if freshHead then freshHead.freshPrev=entry else freshTail=entry end
	freshHead=entry;freshCount+=1
end
local function expireFresh(now)
	while freshTail and (freshTail.recentUntil<=now or not freshTail.dirtyIndex) do unlinkFresh(freshTail) end
end
local function removeDirty(entry)
	local index = entry.dirtyIndex
	unlinkFresh(entry)
	if not index then return end
	local last = table.remove(dirty)
	if index <= #dirty then dirty[index], last.dirtyIndex = last, index end
	entry.dirtyIndex,entry.dirtySince=nil,nil
end
local function addDirty(entry,now)
	if entry.dirtyIndex or not entry.active then return false end
	entry.dirtyIndex = #dirty + 1; dirty[entry.dirtyIndex] = entry
	entry.waitSince,entry.dirtySince,entry.lastDirtyTime,entry.dirtyQueueInsertTime=now,now,now,now
	return true
end
local function bumpRate(kind)
	local now = os.clock(); local tick = math.floor(now*2)
	local key = tick % 10 + 1; local bin = rateBins[key]
	if not bin or bin.tick ~= tick then bin={tick=tick,Acquisitions=0,Corrections=0};rateBins[key]=bin end
	bin[kind] += 1
end

-- Paint strategy statistics contain only real selected-target services, never test RPCs.
local policy: any = { tool=nil, generation=-1, choice="PER_TARGET", locked=false,
	reason="Collecting real-target evidence; PER_TARGET first", normal={}, civil={}, current=nil }
function policy.newArm()
	return {Attempts=0,Successes=0,RetainedAttempts=0,Aborted=0,window={},latencies={},dwell=CFG.TargetDwellDefault,streak=0,workSeconds=0,lastSampleSeconds=0}
end
function policy.account()
	local now=os.clock()
	if policy.chargingArm and policy.clockAt then policy.chargingArm.workSeconds+=math.max(0,now-policy.clockAt) end
	policy.clockAt=now
end
function policy.setCharge(arm)
	policy.account();policy.chargingArm=arm
end
function policy.reset()
	policy.normal={CONTINUOUS=policy.newArm(),PER_TARGET=policy.newArm()}
	policy.choice,policy.locked="PER_TARGET",false
	policy.reason="Collecting real-target evidence; PER_TARGET first"
end
policy.reset();policy.civil=policy.newArm()
function policy.session()
	if policy.tool~=activationTool then
		policy.tool=activationTool;policy.generation=equippedGeneration
		policy.reset();policy.civil=policy.newArm()
	elseif mode=="NORMAL" and policy.generation~=equippedGeneration then
		policy.generation=equippedGeneration;policy.reset()
	end
end
function policy.stats(arm)
	local successes,total,elapsed,service,latency=0,0,0,0,0
	for _,sample in ipairs(arm.window) do
		total+=1;elapsed+=sample.elapsed;service+=sample.service
		if sample.success then successes+=1;latency+=sample.latency end
	end
	return {Attempts=arm.Attempts,Successes=arm.Successes,RetainedAttempts=arm.RetainedAttempts,Aborted=arm.Aborted,
		WorkSeconds=arm.workSeconds,WindowAttempts=total,WindowSuccesses=successes,SuccessRate=total>0 and successes/total or 0,
		CorrectionsPerSecond=elapsed>0 and successes/elapsed or 0,
		AverageServiceMs=total>0 and service*1000/total or 0,
		AverageAcquiredToColorMs=successes>0 and latency*1000/successes or 0,
		DwellMs=arm.dwell*1000}
end
function policy.decide()
	if policy.locked or CFG.ActivationStrategy~="ADAPTIVE" then return end
	local p,c=policy.normal.PER_TARGET,policy.normal.CONTINUOUS
	if p.Attempts<CFG.StrategyMinAttempts then policy.choice="PER_TARGET";return end
	if c.Attempts<CFG.StrategyMinAttempts then policy.choice="CONTINUOUS";return end
	-- A series of singleton holds cannot establish the value of held target transfers.
	if c.RetainedAttempts<2 and c.Attempts<CFG.StrategyMaxProbeAttempts then policy.choice="CONTINUOUS";return end
	local ps,cs=policy.stats(p),policy.stats(c)
	local winner,reason="PER_TARGET","Similar evidence; retain fresh per-target activation"
	if c.RetainedAttempts<2 then
		reason="No meaningful held-transfer sample; use PER_TARGET"
	elseif math.max(ps.WindowSuccesses,cs.WindowSuccesses)<2 then
		if p.Attempts<CFG.StrategyMaxProbeAttempts then policy.choice="PER_TARGET";return end
		if c.Attempts<CFG.StrategyMaxProbeAttempts then policy.choice="CONTINUOUS";return end
		reason="Insufficient successful evidence; PER_TARGET fallback (not a proven winner)"
	elseif ps.SuccessRate>=cs.SuccessRate+CFG.StrategyReliabilityMargin then
		reason="PER_TARGET has a materially higher observed success rate"
	elseif cs.SuccessRate>=ps.SuccessRate+CFG.StrategyReliabilityMargin and cs.WindowSuccesses>=2 then
		winner,reason="CONTINUOUS","CONTINUOUS has a materially higher observed success rate"
	elseif cs.WindowSuccesses>=2 and cs.SuccessRate>=ps.SuccessRate-0.05
		and cs.CorrectionsPerSecond>ps.CorrectionsPerSecond*(1+CFG.StrategyThroughputMargin) then
		winner,reason="CONTINUOUS","CONTINUOUS has higher measured correction throughput at comparable reliability"
	elseif ps.WindowSuccesses>=2 and ps.CorrectionsPerSecond>cs.CorrectionsPerSecond*(1+CFG.StrategyThroughputMargin) then
		reason="PER_TARGET has higher measured correction throughput"
	elseif cs.WindowSuccesses>=2 and cs.SuccessRate>=ps.SuccessRate and ps.AverageAcquiredToColorMs>0
		and cs.AverageAcquiredToColorMs<ps.AverageAcquiredToColorMs*0.8 then
		winner,reason="CONTINUOUS","Comparable throughput; CONTINUOUS has lower observed color latency"
	end
	policy.choice,policy.reason,policy.locked=winner,reason,true
end
function policy.strategy()
	policy.session()
	if mode=="CIVIL WAR" then return "PER_TARGET",policy.civil end
	if CFG.ActivationStrategy=="CONTINUOUS" or CFG.ActivationStrategy=="PER_TARGET" then
		return CFG.ActivationStrategy,policy.normal[CFG.ActivationStrategy]
	end
	policy.decide()
	return policy.choice,policy.normal[policy.choice]
end
function policy.learn(arm,success,latency)
	if success then
		arm.streak=0
		if #arm.latencies>=CFG.DwellHistory then table.remove(arm.latencies,1) end
		table.insert(arm.latencies,latency)
		if #arm.latencies>=CFG.DwellMinSamples then
			local sorted=table.clone(arm.latencies);table.sort(sorted)
			local value=math.clamp(sorted[math.ceil(#sorted*0.9)]+CFG.DwellMargin,CFG.TargetDwellMin,CFG.TargetDwellMax)
			-- Reduce slowly; a few quick successes must not erase slower cooldown opportunities.
			arm.dwell=math.max(arm.dwell-0.02,value)
		end
	else
		arm.streak+=1
		arm.dwell=math.min(CFG.TargetDwellMax,arm.dwell+0.04)
	end
	arm.dwell=math.clamp(arm.dwell,CFG.TargetDwellMin,CFG.TargetDwellMax)
end
function policy.begin(entry,strategy,arm,started)
	local service={entry=entry,strategy=strategy,arm=arm,started=started,normal=mode=="NORMAL",
		generation=equippedGeneration,qualified=false,success=false,retained=false,dwell=arm.dwell,benchmark=true}
	policy.current=service;entry.service=service
	return service
end
function policy.qualify(service)
	if service.qualified then return end
	service.qualified=true
	service.validAt=math.max(service.entry.acquiredAt or os.clock(),ownedInput and ownedInput.MouseObservedAt or os.clock())
	service.entry.lastPaintAttempt=service.validAt
	metrics.Attempts+=1
end
function policy.finish(service,stalled)
	if not service or service.finished then return end
	service.finished=true;policy.account()
	local arm=service.arm
	if service.qualified and service.benchmark and (service.success or stalled) then
		local ended=os.clock();local latency=service.latency or 0
		arm.Attempts+=1;if service.success then arm.Successes+=1 end
		if service.retained then arm.RetainedAttempts+=1 end
		local sample={success=service.success,latency=latency,
			elapsed=math.max(0.001,arm.workSeconds-arm.lastSampleSeconds),service=math.max(0,ended-(service.validAt or ended))}
		arm.lastSampleSeconds=arm.workSeconds
		if #arm.window>=CFG.StrategyWindow then table.remove(arm.window,1) end
		table.insert(arm.window,sample)
		policy.learn(arm,service.success,latency)
		metrics.CompletedServices+=1;metrics.ServiceTotal+=sample.service
		if service.normal then policy.decide() end
	elseif service.qualified then arm.Aborted+=1;metrics.AbortedServices+=1 end
	if service.entry.service==service then service.entry.service=nil end
	if policy.current==service then policy.current=nil end
end

local function reportPerformance()
	policy.account()
	local now = os.clock(); local duration = runSeconds + (runStartedAt and now-runStartedAt or 0)
	local acq, corrected = 0, 0
	for _, bin in pairs(rateBins) do if now-bin.tick/2 < 5 then acq+=bin.Acquisitions;corrected+=bin.Corrections end end
	local result = table.clone(metrics); local window=math.min(5,math.max(1,duration))
	result.ActiveTarget=currentEntry and currentEntry.active and currentEntry.part:GetFullName() or "none"
	result.DirtyCount=#dirty;result.AcquisitionsPerSecond=acq/window;result.CorrectionsPerSecond=corrected/window
	result.AverageAcquisitionMs=metrics.Acquisitions>0 and metrics.AcquireTotal*1000/metrics.Acquisitions or 0
	result.AverageAcquiredToColorMs=metrics.Corrections>0 and metrics.ColorTotal*1000/metrics.Corrections or 0
	result.AverageSwitchMs=metrics.Switches>0 and metrics.SwitchTotal*1000/metrics.Switches or 0
	result.VirtualInputHold=held and ownedInput ~= nil and ownedInput.Method==primaryMethod and not ownedInput.ReleaseSent
	result.SessionConfirmed=confirmedGeneration==equippedGeneration
	result.Runtime=duration;result.AutoPainterRPCs=0
	result.OverallCorrectionsPerSecond=duration>0 and metrics.Corrections/duration or 0
	result.ActivationStrategy=mode=="CIVIL WAR" and "PER_TARGET (CIVIL WAR)" or (CFG.ActivationStrategy=="ADAPTIVE" and policy.choice or CFG.ActivationStrategy)
	result.StrategyConfigured=CFG.ActivationStrategy
	result.StrategyDecisionCached=policy.locked
	result.StrategyDecisionReason=mode=="CIVIL WAR" and "Separate palette colors require fresh per-target activation" or policy.reason
	local arm=mode=="CIVIL WAR" and policy.civil or policy.normal[result.ActivationStrategy]
	result.AdaptiveDwellMs=(arm and arm.dwell or CFG.TargetDwellDefault)*1000
	result.DownEvents,result.UpEvents=downSeen,upSeen
	result.SuccessfulPaints=metrics.Corrections
	result.SuccessRate=metrics.CompletedServices>0 and math.min(1,metrics.Corrections/metrics.CompletedServices) or 0
	result.AverageTargetDwellMs=metrics.CompletedServices>0 and metrics.ServiceTotal*1000/metrics.CompletedServices or 0
	result.TargetAcquisitionsPerSecond=result.AcquisitionsPerSecond
	result.CursorAcquireSuccessRate=metrics.CursorAcquireAttempts>0 and metrics.CursorAcquireSuccesses/metrics.CursorAcquireAttempts or 0
	result.CameraFallbackRate=metrics.AcquisitionAttempts>0 and metrics.CameraFallbacks/metrics.AcquisitionAttempts or 0
	result.AverageColorEventToDirtyQueueMs=metrics.ColorEventQueued>0 and metrics.ColorEventQueueTotal/metrics.ColorEventQueued or 0
	result.AverageAttackColorChangeToCorrectedMs=metrics.FreshAttackCorrections>0 and metrics.AttackResponseTotal/metrics.FreshAttackCorrections or 0
	result.RecentlyChangedQueueDepth=freshCount
	result.Strategies={PER_TARGET=policy.stats(policy.normal.PER_TARGET),CONTINUOUS=policy.stats(policy.normal.CONTINUOUS),CIVIL_WAR=policy.stats(policy.civil)}
	return result
end
local function rebuildDirty()
	for _,entry in ipairs(entries) do syncDirty(entry,"rebuild") end
	wakeWork()
end
local function deferEntry(entry, stalled, cause)
	entry.failures=math.min(5,(entry.failures or 0)+1)
	if not stalled and cause=="acquisition" then entry.acquisitionFailures=(entry.acquisitionFailures or 0)+1 end
	entry.retryAt=os.clock()+math.min(CFG.MaxRetry,((stalled or cause=="input") and CFG.Retry or CFG.UnreachableRetry)*2^(entry.failures-1))
	entry.waitSince=os.clock();metrics.Deferred+=1
	if stalled then metrics.Stalled+=1;noEffect+=1 end
end
noteCorrection = function(entry)
	if entry.corrected or currentEntry~=entry or not held or not ownedInput
		or ownedInput.ReleaseSent or mouse.Target~=entry.part then return end
	inputEvidence(ownedInput)
	if not ownedInput.MouseObserved then return end
	if not entry.acquiredAt then entry.earlyCorrectionAt=os.clock();return end
	entry.corrected=true;entry.failures=0;entry.retryAt=0
	local observedAt=entry.earlyCorrectionAt or os.clock()
	local latency=math.max(0,observedAt-entry.acquiredAt)
	corrections+=1;metrics.Corrections+=1;metrics.ColorTotal+=latency;bumpRate("Corrections")
	entry.lastCorrectedTime=observedAt
	local service=entry.service
	if service then
		policy.qualify(service);service.success,service.latency=true,latency
		if entry.attackAt then
			local ms=math.max(0,observedAt-entry.attackAt)*1000
			metrics.FreshAttackCorrections+=1;metrics.AttackResponseTotal+=ms
			if metrics.FreshAttackCorrections==1 then metrics.MinimumAttackResponseMs=ms
			else metrics.MinimumAttackResponseMs=math.min(metrics.MinimumAttackResponseMs,ms) end
			metrics.MaximumAttackResponseMs=math.max(metrics.MaximumAttackResponseMs,ms)
			entry.attackAt=nil
		end
	end
	activation.ColorChanged,activation.TargetColorObserved=true,true
	if ownedInput.Method==primaryMethod then
		activation.Preferred=primaryMethod;confirmedGeneration=equippedGeneration;primaryFailures=0;holdStalls=0
	end
	activation.Status="Mouse.Button1Down + target color observed"
	switchedAt=observedAt
end
syncDirty = function(entry,source)
	metrics.QueueEvaluations+=1
	if not entry.active then return end
	if not validProvince(entry.part) then removeProvince(entry.part);return end
	local now,color,target=os.clock(),entry.part.Color,targetColor(entry)
	local wasDirty=entry.dirtyIndex~=nil
	local changed=entry.lastSeenColor~=color
	local wrong=target~=nil and color~=target -- Eligibility uses Color only; never Mouse.Target.
	local colorEvent=source=="color"
	local hovered=false
	if colorEvent then
		metrics.ColorEventsReceived+=1;entry.lastColorEventTime=now
		hovered=mouse.Target==entry.part -- Diagnostics only; not used by eligibility.
	end
	entry.lastSeenColor=color
	if wrong then
		addDirty(entry,now)
		if changed and (colorEvent or source=="reconcile") then
			entry.attackAt=now;entry.failures,entry.retryAt=0,0
			markFresh(entry,now)
		end
		if colorEvent then
			if not hovered then metrics.DirtyEventsWithoutHover+=1 end
			local latency=(os.clock()-now)*1000
			metrics.ColorEventQueued+=1;metrics.ColorEventQueueTotal+=latency
			metrics.MaxColorEventToDirtyQueueMs=math.max(metrics.MaxColorEventToDirtyQueueMs,latency)
			local record={Path=entry.part:GetFullName(),Time=now,HoveredAtEvent=hovered,
				DirtyQueued=entry.dirtyIndex~=nil,QueueLatencyMs=latency,Color=tostring(color),Target=tostring(target)}
			if #eventLog>=24 then table.remove(eventLog,1) end
			table.insert(eventLog,record);if not hovered then lastOffHoverEvent=record end
		end
	else
		removeDirty(entry);entry.failures,entry.retryAt=0,0
		if wasDirty then entry.lastCorrectedTime=now end
		if target then noteCorrection(entry) end
		if not entry.service then entry.attackAt=nil end
	end
	if source=="reconcile" and wasDirty~=wrong then metrics.ReconciliationFinds+=1 end
	if colorEvent or wasDirty~=wrong then wakeWork() end
end
local function reconcile()
	-- Queue repair only. The single worker owns all input/camera operations.
	local i=1
	while i<=#entries do
		local entry=entries[i];metrics.ReconciliationChecks+=1;syncDirty(entry,"reconcile")
		if entries[i]==entry then i+=1 end
	end
end
local function dirtyEventReport()
	local lines={"HOVER-INDEPENDENT DIRTY EVENTS (callback time; not server replication time)",
		"Eligibility = province.Color ~= targetColor(entry); hover is diagnostic only."}
	local e=lastOffHoverEvent
	if e then
		table.insert(lines,string.format("Last off-cursor province: %s\nColorChanged received=true\nHovered at event=%s\nDirty queued=%s\nQueue latency=%.3f ms\nEvent time=%.3f",e.Path,tostring(e.HoveredAtEvent),tostring(e.DirtyQueued),e.QueueLatencyMs,e.Time))
	else table.insert(lines,"No off-cursor wrong-color event observed yet; external recolor needed.") end
	for _,event in ipairs(eventLog) do
		table.insert(lines,string.format("%.3f %s | Hovered=%s DirtyQueued=%s QueueMs=%.3f",event.Time,event.Path,tostring(event.HoveredAtEvent),tostring(event.DirtyQueued),event.QueueLatencyMs))
	end
	return table.concat(lines,"\n")
end
local fastRayParams = RaycastParams.new()
fastRayParams.FilterType=Enum.RaycastFilterType.Exclude
local rayCharacter=nil
local function guiClear(point)
	if GuiService.MenuIsOpen or UserInputService:GetFocusedTextBox() then return false end
	local ok, objects=pcall(function()
		local inset=GuiService:GetGuiInset()
		return playerGui:GetGuiObjectsAtPosition(point.X-inset.X,point.Y-inset.Y)
	end)
	if not ok then return false end
	for _,object in ipairs(objects) do
		if object.Visible and (object.Active or object:IsA("TextButton") or object:IsA("ImageButton") or object:IsA("TextBox")) then return false end
	end
	return true
end
local function geometry(entry)
	local part=entry.part
	if entry.pointFrame~=part.CFrame or entry.pointSize~=part.Size then
		entry.pointFrame,entry.pointSize=part.CFrame,part.Size
		entry.surfacePoints=targetPoints(part);entry.sampleCursor=1
		entry.lastScreen,entry.lastWorld,entry.lastFrame=nil,nil,nil
		entry.lastCamera=nil;cameraCache[part]=nil
	end
end
local function probe(entry,index)
	local camera=Workspace.CurrentCamera
	local point,visible
	if index==entry.lastIndex and entry.lastFrame==camera.CFrame and entry.lastViewport==camera.ViewportSize then
		point,visible=entry.lastScreen,true
	else
		if projectionsLeft<=0 then return nil,true end
		projectionsLeft-=1;metrics.Projections+=1
		point,visible=camera:WorldToViewportPoint(entry.surfacePoints[index])
	end
	if not visible or not point or point.Z<=0 or not guiClear(point) then return nil end
	if raysLeft<=0 then return nil,true end
	raysLeft-=1;metrics.Raycasts+=1
	if rayCharacter~=player.Character then rayCharacter=player.Character;fastRayParams.FilterDescendantsInstances=rayCharacter and {rayCharacter} or {} end
	local ray=camera:ViewportPointToRay(point.X,point.Y)
	local hit=Workspace:Raycast(ray.Origin,ray.Direction*10000,fastRayParams)
	if hit and hit.Instance==entry.part then return point,false end
	return nil,false
end
local function visiblePoint(entry)
	geometry(entry)
	if entry.lastIndex then
		local point,budget=probe(entry,entry.lastIndex)
		if point then return {entry=entry,point=point,index=entry.lastIndex,tier=0} end
		if budget then return nil,true end
	end
	for _=1,math.min(CFG.PointsPerCandidate,#entry.surfacePoints) do
		local index=entry.sampleCursor;entry.sampleCursor=index%#entry.surfacePoints+1
		local point,budget=probe(entry,index)
		if point then return {entry=entry,point=point,index=index,tier=1} end
		if budget then return nil,true end
	end
	return nil,false
end
local decisionSerial=0
local function chooseFast(now)
	expireFresh(now);decisionSerial+=1
	local best,bestTier,bestDistance=nil,math.huge,math.huge
	local cursor=UserInputService:GetMouseLocation()
	local exhausted=false;local minimumRetry=math.huge
	local function consider(entry: any)
		if entry.decisionSerial==decisionSerial then return end
		entry.decisionSerial=decisionSerial
		if not entry.active then return end
		if now<entry.retryAt then minimumRetry=math.min(minimumRetry,entry.retryAt);return end
		metrics.Candidates+=1
		if not validProvince(entry.part) then removeProvince(entry.part);return end
		if entry.part.Color==targetColor(entry) then syncDirty(entry,"check");return end
		local candidate,budget=visiblePoint(entry)
		if budget then exhausted=true;return end
		candidate=candidate or {entry=entry,tier=entry.lastCamera and 2 or 3}
		local tier=candidate.tier
		if entry.freshLinked then tier=-1 end
		-- Aging eventually wins even against a stream of freshly attacked targets.
		if now-entry.waitSince>=CFG.PriorityAge then tier=-2 end
		local distance=candidate.point and ((candidate.point.X-cursor.X)^2+(candidate.point.Y-cursor.Y)^2)
			or (entry.part.Position-Workspace.CurrentCamera.CFrame.Position).Magnitude^2
		if tier<bestTier or (tier==bestTier and (distance<bestDistance or
			(distance==bestDistance and entry.waitSince<(best and best.entry.waitSince or math.huge)))) then
			best,bestTier,bestDistance=candidate,tier,distance
		end
	end
	-- New color events have a direct queue entry: no patrol through earlier selections.
	local fresh=freshHead
	for _=1,math.min(freshCount,1) do
		if not fresh then break end
		local nextFresh=fresh.freshNext;consider(fresh);fresh=nextFresh
		if exhausted then return best end
	end
	local visited=math.min(#dirty,CFG.CandidatesPerStep)
	for _=1,visited do
		if #dirty==0 then break end
		dirtyCursor=dirtyCursor%#dirty+1;consider(dirty[dirtyCursor])
		if exhausted then return best end
	end
	if not best and visited>=#dirty and minimumRetry<math.huge then nextWorkerAt=minimumRetry end
	return best
end
local function liveToken(token)
	return alive and running and workerToken==token and focused
end
local function ownedTargetSafe(entry,previous)
	if not ownedInput or ownedInput.ReleaseSent then return true end
	local actual=mouse.Target
	return actual==entry.part or (previous and actual==previous and lookup[previous] and validProvince(previous))
end
local function moveCursor(candidate,token)
	local entry,point=candidate.entry,candidate.point
	if not liveToken(token) or not entry.active or not validProvince(entry.part) then return false end
	local before=mouse.Target
	if not ownedTargetSafe(entry,before) then if not settleRelease() then return false end end
	local moved=true
	if mouse.Target~=entry.part then
		local destination=Vector2.new(point.X,point.Y)
		local ok
		local readable, mover = pcall(function() return virtualInput and virtualInput.SendMousePosition end)
		if readable and type(mover)=="function" then
			ok=callInput(function() virtualInput:SendMousePosition(destination) end)
			if not ok then
				settleRelease();lastAcquireDetail="Virtual cursor movement rejected; recovering through camera";return false
			end
		end
		if not ok then
			-- Movement recovery is serialized and released before trying a different API.
			if not settleRelease() then return false end
			if type(mousemoverel)=="function" then
				local cursor=UserInputService:GetMouseLocation()
				ok=callInput(function() mousemoverel(math.round(point.X-cursor.X),math.round(point.Y-cursor.Y)) end)
			end
		end
		moved=ok==true
	end
	if not moved then lastAcquireDetail="Cursor movement unavailable or denied";return false end
	local deadline=os.clock()+CFG.CursorAcquire
	local holdDeadline=os.clock()+CFG.HeldCursorGrace
	while liveToken(token) and entry.active and validProvince(entry.part) do
		if not ownedTargetSafe(entry,before) or (mouse.Target~=entry.part and os.clock()>=holdDeadline) then
			if not settleRelease() then return false end
		end
		if mouse.Target==entry.part then
			entry.lastIndex,entry.lastWorld,entry.lastScreen=candidate.index,entry.surfacePoints[candidate.index],point
			entry.lastFrame,entry.lastCamera,entry.lastViewport=Workspace.CurrentCamera.CFrame,Workspace.CurrentCamera.CFrame,Workspace.CurrentCamera.ViewportSize
			cameraCache[entry.part]=entry.lastCamera
			lastAcquireDetail="Real Mouse.Target acquired by cursor"
			if candidate.tier==0 then metrics.CachedCursorHits+=1 end
			return true
		end
		if os.clock()>=deadline then break end
		waitWork()
	end
	return false
end
local function acquireFast(candidate,token)
	local entry=candidate.entry
	if candidate.point then
		metrics.CursorAcquireAttempts+=1
		if moveCursor(candidate,token) then metrics.CursorAcquireSuccesses+=1;return true end
	end
	if not liveToken(token) or not entry.active then return false end
	metrics.CameraFallbacks+=1
	-- A camera sweep while held can paint intervening, unselected tiles. Recovery releases first.
	if not settleRelease() then return false end
	if entry.lastCamera and saveView() then
		local camera=Workspace.CurrentCamera
		camera.CFrame=entry.lastCamera
		camera.Focus=CFrame.new(entry.lastWorld or entry.part.Position)
		RunService.RenderStepped:Wait()
		if not liveToken(token) or not entry.active then return false end
		local point=visiblePoint(entry)
		if point and moveCursor(point,token) then metrics.CachedCameraHits+=1;return true end
	end
	metrics.FullCameraSearches+=1
	if not acquireTarget(entry) or not liveToken(token) or not entry.active then return false end
	-- Existing proven camera alignment is retained. Prefer a projected point once exposed.
	local point=visiblePoint(entry)
	if point then return moveCursor(point,token) end
	return mouse.Target==entry.part
end
local function rememberAcquired(entry,started)
	local now=entry.earlyCorrectionAt or os.clock()
	entry.acquiredAt,entry.lastAcquireSeconds,entry.corrected=now,now-started,false
	entry.lastCamera=Workspace.CurrentCamera.CFrame
	metrics.Acquisitions+=1;metrics.AcquireTotal+=now-started;bumpRate("Acquisitions")
	if switchedAt then metrics.Switches+=1;metrics.SwitchTotal+=now-switchedAt;switchedAt=nil end
	entry.lastHoveredTime,entry.lastAcquiredTime=now,now
	entry.acquisitionFailures=0
	activation.TargetAcquired=true
	activation.ColorChanged,activation.TargetColorObserved=false,false
end
local function startOrRetainHold(entry,token)
	local tool=activationTool
	if not guiClear(UserInputService:GetMouseLocation()) then settleRelease();activation.Status="Interactive GUI blocks native input";return false end
	if not tool or tool.Parent~=player.Character or not tool.Enabled or not inputAllowed(entry,tool,token) then return false end
	if ownedInput then
		if ownedInput.Tool==tool and not ownedInput.ReleaseSent then return true end
		if not settleRelease() then return false end
	end
	if not primaryMethod or primaryFailures>=CFG.ConfirmedNoEffectLimit then return false end
	if UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) then
		activation.Status="External Mouse1 is held; stopping";running=false;return false
	end
	local owner={Method=primaryMethod,Tool=tool,Before=entry.part.Color,Down=downSeen,
		EquippedDown=equippedDownSeen,ToolDown=toolDownSeen,Started=os.clock()}
	ownedInput,held=owner,true
	activation.Method,activation.Attempted,activation.Observed=primaryMethod.Name,true,false
	activation.Observation,activation.ColorChanged,activation.TargetColorObserved="none",false,false
	pressAttempts+=1
	local ok,problem=callInput(primaryMethod.Down);owner.DownFailed=not ok
	if not ok then
		primaryFailures+=1;inputErrors+=1;result("VirtualInput down failed: "..tostring(problem))
		settleRelease();return false
	end
	return liveToken(token) and not owner.ReleaseSent
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

local function stop(reason)
	local wasCivil = running and mode == "CIVIL WAR"
	policy.setCharge(nil)
	running = false
	workerToken += 1
	wakeWork()
	if runStartedAt then runSeconds+=os.clock()-runStartedAt;runStartedAt=nil end
	forceRelease()
	if not ownedInput then restoreView() end
	currentEntry = nil
	if wasCivil then restorePalette() end
	if reason then lastMessage = reason end
end

local function worker(token)
	while liveToken(token) do
		if policy.current then policy.finish(policy.current,false) end
		if releaseBlocked then running=false;break end
		if transitionCount>=CFG.MaxTransitionsPerFrame then waitWork();continue end
		if #dirty==0 then
			policy.setCharge(nil)
			currentEntry=nil;switchedAt=nil
			if not settleRelease() then running=false;break end
			lastMessage="All selected provinces match; waiting for ColorChanged (queue reconciliation active)"
			if #dirty==0 and liveToken(token) then waitWork() end
			continue
		end
		local candidate=chooseFast(os.clock())
		if not candidate then
			if projectionsLeft<=0 or raysLeft<=0 then waitWork();continue end
			currentEntry=nil
			if not settleRelease() then running=false;break end
			waitWork();continue
		end
		transitionCount+=1
		local entry=candidate.entry
		currentEntry=entry;activation.TargetAcquired=false
		entry.acquiredAt,entry.earlyCorrectionAt,entry.corrected=nil,nil,false
		local target=targetColor(entry)
		local tool=ensureBucket()
		if not tool then lastMessage="PaintBucket unavailable; stopped";running=false;break end
		discoverActivation(tool)
		local strategy,arm=policy.strategy()
		policy.setCharge(arm)
		-- A benchmark phase boundary also ends the old hold; samples cannot mix strategies.
		if strategy=="PER_TARGET" or (ownedInput and ownedInput.Strategy~=strategy) then
			if not settleRelease() then running=false;break end
		end
		if mode=="CIVIL WAR" and (lastPreparedColor~=target or lastPreparedTool~=tool) then
			if not prepareCivil(entry) then deferEntry(entry,false,"input");waitWork();continue end
			lastPreparedColor,lastPreparedTool=target,tool
		end
		if not liveToken(token) or not entry.active then break end
		if not entry.dirtyIndex or entry.part.Color==target then syncDirty(entry,"check");continue end
		local began=os.clock()
		local service=policy.begin(entry,strategy,arm,began)
		service.retained=ownedInput~=nil and not ownedInput.ReleaseSent
		metrics.AcquisitionAttempts+=1
		if not acquireFast(candidate,token) then
			if entry.active and entry.dirtyIndex then deferEntry(entry,false,"acquisition") end
			if ownedInput then settleRelease() end
			policy.finish(service,false);continue
		end
		if not liveToken(token) or not entry.active then break end
		-- Camera recovery may have released the hold; only actual transfers count as retained.
		service.retained=service.retained and ownedInput~=nil and not ownedInput.ReleaseSent
		rememberAcquired(entry,began)
		if entry.part.Color==target then
			noteCorrection(entry);syncDirty(entry,"check")
			if strategy=="PER_TARGET" then settleRelease() end
			policy.finish(service,false);continue
		end
		if not primaryMethod or primaryFailures>=CFG.ConfirmedNoEffectLimit then
			-- Input errors/missing down observation, not paint stalls, unlock alternate recovery.
			service.benchmark=false
			if not settleRelease() then running=false;break end
			if primaryMethod then rejectedMethods[primaryMethod.Name]=true end
			local outcome=activateAndPaint(entry,target,token)
			if outcome=="unsupported" or outcome=="blocked" then running=false;lastMessage=activation.Status;break end
			if outcome=="correct" then syncDirty(entry,"check") else deferEntry(entry,false,"input") end
			policy.finish(service,false);continue
		end
		entry.lastPaintAttempt=os.clock()
		if not startOrRetainHold(entry,token) then
			if entry.active and entry.dirtyIndex then deferEntry(entry,false,"input") end
			policy.finish(service,false);continue
		end
		ownedInput.Strategy=strategy
		local stalled=false
		while liveToken(token) and entry.active and ownedInput and not ownedInput.ReleaseSent do
			if ownedInput.ExternalUp then activation.Status="Unexpected native mouse-up; hold stopped";lastMessage=activation.Status;running=false;break end
			if not validProvince(entry.part) or activationTool.Parent~=player.Character then break end
			if mouse.Target~=entry.part or not guiClear(UserInputService:GetMouseLocation()) then
				activation.Status="Real target lost; release and reacquire";settleRelease();break
			end
			entry.lastHoveredTime=os.clock()
			inputEvidence(ownedInput)
			if not ownedInput.MouseObserved and os.clock()-ownedInput.Started>=CFG.InputVerify then
				primaryFailures+=1;activation.Status="VirtualInput Mouse.Button1Down not observed; bounded recovery"
				settleRelease();break
			end
			if ownedInput.MouseObserved then policy.qualify(service) end
			if entry.part.Color==target or service.success then
				noteCorrection(entry);syncDirty(entry,"check");break
			end
			-- Full dwell begins only once genuine acquisition AND input observation are valid.
			if service.qualified and os.clock()>=service.validAt+service.dwell then
				stalled=true;deferEntry(entry,true);holdStalls+=1
				activation.Status="Full adaptive dwell elapsed; target deferred, native cooldown unchanged"
				if strategy=="CONTINUOUS" and holdStalls>=CFG.StallsBeforeHoldRecovery then holdStalls=0;settleRelease() end
				break
			end
			waitWork()
		end
		if strategy=="PER_TARGET" then
			if not settleRelease() then running=false end
		end
		policy.finish(service,stalled)
	end
	if settleRelease() then restoreView() end
	policy.finish(policy.current,false)
	policy.setCharge(nil)
	currentEntry=nil
	if runStartedAt then runSeconds+=os.clock()-runStartedAt;runStartedAt=nil end
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
	entry.index=#entries+1
	entries[entry.index] = entry
	lookup[part] = entry

	local box = Instance.new("SelectionBox")
	box.Name = "HandsFreeProtected"
	box.Adornee = part
	box.SurfaceTransparency = 1
	box.LineThickness = 0.025
	box.Color3 = mode == "CIVIL WAR" and entry.civilColor or paletteColor()
	box.Parent = playerGui:FindFirstChild(GUI_NAME)
	entry.box = box

	entry.colorConn = part:GetPropertyChangedSignal("Color"):Connect(function() syncDirty(entry,"color") end)
	entry.ancestryConn = part.AncestryChanged:Connect(function() if not validProvince(part) then removeProvince(part) end end)
	entry.destroyConn = part.Destroying:Connect(function() removeProvince(part) end)
	syncDirty(entry)
	return true
end

removeProvince = function(part)
	local entry = lookup[part]
	if not entry then return end
	entry.active = false
	removeDirty(entry)
	if currentEntry==entry then forceRelease() end
	lookup[part] = nil
	usedColors[colorKey(entry.civilColor)]=nil
	cameraCache[part]=nil
	local last=table.remove(entries)
	if entry.index<=#entries then entries[entry.index],last.index=last,entry.index end
	entry.surfacePoints=nil
	if entry.ancestryConn then entry.ancestryConn:Disconnect() end
	wakeWork()
	if entry.colorConn then entry.colorConn:Disconnect() end
	if entry.destroyConn then entry.destroyConn:Disconnect() end
	entry.service=nil
	if entry.box then entry.box:Destroy() end
end

local function clearAll()
	stop("Cleared")
	while #entries>0 do removeProvince(entries[#entries].part) end
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
title.Text = "AutoPainter · HANDS FREE v6"
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
liveStatus.Size = UDim2.fromOffset(470,250)
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
local performanceFields={"ActivationStrategy","StrategyConfigured","StrategyDecisionCached","StrategyDecisionReason","VirtualInputHold",
	"DownEvents","UpEvents","Attempts","CompletedServices","AbortedServices","SuccessfulPaints","SuccessRate","CorrectionsPerSecond","OverallCorrectionsPerSecond",
	"AverageTargetDwellMs","AdaptiveDwellMs","AverageAcquisitionMs","AverageAcquiredToColorMs","AverageSwitchMs","ActiveTarget","DirtyCount","Deferred","Stalled",
	"CachedCursorHits","CachedCameraHits","FullCameraSearches","TargetAcquisitionsPerSecond","CursorAcquireSuccessRate","CameraFallbackRate",
	"ColorEventsReceived","DirtyEventsWithoutHover","AverageColorEventToDirtyQueueMs","MaxColorEventToDirtyQueueMs","ReconciliationFinds","ReconciliationChecks",
	"FreshAttackCorrections","AverageAttackColorChangeToCorrectedMs","MinimumAttackResponseMs","MaximumAttackResponseMs","RecentlyChangedQueueDepth",
	"SessionConfirmed","Runtime","AutoPainterRPCs"}
local function performanceReport()
	local m=reportPerformance();local lines={"AUTOPAINTER v6 — observed corrections; native RPCs unobserved"}
	for _,key in ipairs(performanceFields) do table.insert(lines,key.."="..tostring(m[key])) end
	table.insert(lines,"STRATEGY BENCHMARK (rolling completed services; work time includes acquisition/release/retry; clean idle excluded)")
	for _,name in ipairs({"PER_TARGET","CONTINUOUS","CIVIL_WAR"}) do
		local stats=m.Strategies[name];table.insert(lines,name)
		for _,key in ipairs({"Attempts","Successes","RetainedAttempts","Aborted","WorkSeconds","WindowAttempts","WindowSuccesses","SuccessRate","CorrectionsPerSecond","AverageServiceMs","AverageAcquiredToColorMs","DwellMs"}) do
			table.insert(lines,"  "..key.."="..tostring(stats[key]))
		end
	end
	table.insert(lines,dirtyEventReport())
	return table.concat(lines,"\n")
end
local function copyActivationReport()
	local report=activationReport().."\n"..performanceReport()
	if type(setclipboard)=="function" and pcall(setclipboard,report) then return true end
	if type(writefile)=="function" and pcall(writefile,"AutoPainterActivationReport.txt",report) then return true end
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

local function activeCount() return #entries end
local function dirtyCount() return #dirty end

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

	local perf=reportPerformance()
	liveStatus.Text=string.format("AUTO v6 · Q / Escape to stop · %s\n%s · %s\nDirty %d · Attempts %d · Success %d (%.0f%%) · Corrections/s %.2f\nDwell %.0f / limit %.0f ms · Acquire %.1f ms · To color %.1f ms · Switch %.1f ms\nAcq/s %.1f · Cursor %.0f%% · Camera fallback %.0f%%\nCursor cache %d · Camera cache %d · Full search %d\nDeferred %d · Stalls %d · Hold %s · Down/Up %d/%d\nColor events %d · Away from cursor %d · Queue avg/max %.2f/%.2f ms\nFresh queue %d · Attack corrections %d · Response %.1f ms\nTarget: %s",
		perf.ActivationStrategy,activation.Method,activation.Observation,
		perf.DirtyCount,perf.Attempts,perf.SuccessfulPaints,perf.SuccessRate*100,perf.CorrectionsPerSecond,
		perf.AverageTargetDwellMs,perf.AdaptiveDwellMs,perf.AverageAcquisitionMs,perf.AverageAcquiredToColorMs,perf.AverageSwitchMs,
		perf.TargetAcquisitionsPerSecond,perf.CursorAcquireSuccessRate*100,perf.CameraFallbackRate*100,
		perf.CachedCursorHits,perf.CachedCameraHits,perf.FullCameraSearches,perf.Deferred,perf.Stalled,tostring(perf.VirtualInputHold),perf.DownEvents,perf.UpEvents,
		perf.ColorEventsReceived,perf.DirtyEventsWithoutHover,perf.AverageColorEventToDirtyQueueMs,perf.MaxColorEventToDirtyQueueMs,
		perf.RecentlyChangedQueueDepth,perf.FreshAttackCorrections,perf.AverageAttackColorChangeToCorrectedMs,perf.ActiveTarget)

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
	lastPreparedColor,lastPreparedTool=nil,nil
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
	rebuildDirty()
	runStartedAt=os.clock()
	switchedAt=nil
	rejectedMethods = {} -- explicit START permits bounded input recovery
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
		policy.finish(policy.current,false)
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
	rebuildDirty()
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
	wake:Destroy()
	gui:Destroy()
end
local function closeController()
	if not alive then return end
	stop("Closed")
	alive = false
	disconnectInput(lifetimeConnections)
	while #entries>0 do removeProvince(entries[#entries].part) end
	gui.Enabled = false
	finishClose()
end
close.Activated:Connect(closeController)
gui.Destroying:Connect(closeController)

connectLifetime(player:GetAttributeChangedSignal("PaintBucketColor"), function()
	if running and mode=="NORMAL" and paletteColor()~=normalTarget then stop("Normal palette changed; restart with the desired color") end
end)

connectLifetime(UserInputService.WindowFocusReleased, function()
	focused=false
	stop("Client lost focus; activation stopped")
end)
connectLifetime(UserInputService.WindowFocused, function() focused=true;wakeWork() end)
connectLifetime(player:GetPropertyChangedSignal("Character"), function()
	if running then stop("Character changed; restart Auto") end
end)

connectLifetime(Workspace.DescendantRemoving, function(object)
	if lookup[object] then removeProvince(object) end
	if running and ownedInput and (object==ownedInput.Tool or object==player.Character) then stop("Tool lost; released native hold") end
end)

connectLifetime(Workspace:GetPropertyChangedSignal("CurrentCamera"), function()
	if running then stop("Camera changed; restart Auto") end
end)

connectLifetime(RunService.Heartbeat, function()
	transitionCount=0;projectionsLeft=CFG.MaxProjections;raysLeft=CFG.MaxRays
	local now=os.clock()
	expireFresh(now)
	if alive and now>=nextReconcileAt then nextReconcileAt=now+CFG.ReconcileInterval;reconcile() end
	if workerActive and (ownedInput or (#dirty>0 and (not nextWorkerAt or now>=nextWorkerAt))) then wakeWork() end
	if alive and os.clock() - lastStatusAt >= CFG.StatusInterval then
		lastStatusAt = os.clock()
		updateUI()
	end
end)

updateUI()

local api = {
	GetPerformanceStats = reportPerformance,
	GetTargetStats = function(part)
		local e=lookup[part];if not e then return nil end
		return {Dirty=e.dirtyIndex~=nil,LastScreenPoint=e.lastScreen,LastWorldPoint=e.lastWorld,
			LastCamera=e.lastCamera,AcquisitionSeconds=e.lastAcquireSeconds,RecentFailures=e.failures or 0,RetryAt=e.retryAt,
			AcquisitionFailures=e.acquisitionFailures or 0,LastAcquiredTime=e.lastAcquiredTime,
			GeometryCFrame=e.pointFrame,GeometrySize=e.pointSize,LastColorEventTime=e.lastColorEventTime,LastSeenColor=e.lastSeenColor,
			TargetColor=targetColor(e),DirtySince=e.dirtySince,DirtyQueueInsertTime=e.dirtyQueueInsertTime,
			LastHoveredTime=e.lastHoveredTime,LastPaintAttempt=e.lastPaintAttempt,LastCorrectedTime=e.lastCorrectedTime,LastDirtyTime=e.lastDirtyTime}
	end,
	GetPerformanceReport = performanceReport,
	GetDirtyEventReport = dirtyEventReport,
	SetActivationStrategy = function(value)
		if value~="ADAPTIVE" and value~="CONTINUOUS" and value~="PER_TARGET" then return false end
		if running or workerActive or starting or ownedInput then return false end
		CFG.ActivationStrategy=value;policy.reset();wakeWork();updateUI();return true
	end,
	Destroy = closeController,
	GetActivationReport = activationReport,
	CopyActivationReport = copyActivationReport,
	Start = startAuto,
	Stop = function() stop("Stopped by API"); updateUI() end,
	SetMode = function(value)
		if value ~= "NORMAL" and value ~= "CIVIL WAR" then return false end
		if running then stop("Stopped before changing mode") end
		mode = value
		rebuildDirty()
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
			Performance = reportPerformance(),
		}
	end,
}
local bridge = Instance.new("BindableFunction")
bridge.Name = "ActivationController"
bridge.OnInvoke = function() return api end
bridge.Parent = gui
return api
