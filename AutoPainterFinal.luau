-- Smart native-input AutoPainter. No game remote calls, hooks, or fabricated mouse data.
-- PaintBucket's existing client script is the sole sender of paint requests.
-- Input API availability and delivery must be checked in the user's client.
-- These profiles govern targeting/input only. The native tool owns its cooldown.
local PROFILES = {
	FAST = { TargetDwell = 0.45, PriorityDwellMultiplier = 1.75, MaxDwell = 2,
		ReleaseGap = 0.10, AimTimeout = 0.75, AimRetry = 0.20, CursorInterval = 0.025,
		TargetStableSeconds = 0.03, TargetStableFrames = 1, IdleRetry = 0.08, CandidatesPerFrame = 128 },
	NORMAL = { TargetDwell = 0.9, PriorityDwellMultiplier = 1.75, MaxDwell = 2,
		ReleaseGap = 0.25, AimTimeout = 1.5, AimRetry = 0.4, CursorInterval = 0.05,
		TargetStableSeconds = 0.08, TargetStableFrames = 2, IdleRetry = 0.2, CandidatesPerFrame = 64 },
}
local CONFIG = {
	SpeedMode = "FAST",
	NativeMoveMode = "Auto", -- Prefers relative; Absolute is an explicit alternative.
	TestHold = 0.35,
	InputEventTimeout = 0.6,
	MaxRaysPerFrame = 32, -- Bounds expensive visibility work, even with many selected parts.
	AgingSeconds = 4, -- Oldest visible target overrides distance after this wait.
	VisibleVisitsBeforeAgedOffscreen = 8, -- Bounded aging escape from perpetual visible contention.
	ContestDecay = 20,
	CameraAutomation = true,
	VisibleOnly = false,
	CameraMinDistance = 35,
	CameraMaxDistance = 1200,
	TelemetryInterval = 0.25,
}
local speedMode = CONFIG.SpeedMode
local timing = PROFILES[speedMode]
local options = ...
if type(options) ~= "table" then options = {} end
local locked = options.LockDiagnostics == true or options.DiagnosticOnly == true
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Input = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local Workspace = game:GetService("Workspace")
local player = assert(Players.LocalPlayer, "Run AutoPainter on your own client")
local playerGui = player:WaitForChild("PlayerGui")
local mouse = player:GetMouse()
local GUI_NAME, VERSION = "AutoPainterFinalUI", 9
local existing = playerGui:FindFirstChild(GUI_NAME)
if existing then
	assert(existing:GetAttribute("AutoPainterNativeVersion") == VERSION,
		"Close the older AutoPainter panel first. If a diagnostic decompile is stuck, restart the client.")
	local controller = existing:FindFirstChild("Controller")
	assert(controller and controller:IsA("BindableFunction"), "Existing AutoPainter controller unavailable")
	local running = controller:Invoke()
	assert(not running.GetStats().Closed, "A previous input release is unresolved. Release the mouse manually before reloading.")
	if locked then running.LockDiagnostics() end
	return running
end

local api = {}
local alive, painting, keepColor = true, false, false
local cameraAutomation, visibleOnly = CONFIG.CameraAutomation, CONFIG.VisibleOnly
local dwell = timing.TargetDwell
local entries, lookup, dirty = {}, {}, {}
local pendingCount, nextId, paletteBlocked = 0, 0, 0
local selectionMode, priority, testTarget = nil, nil, nil
local connections = {}
local character, bucket, humanoid = nil, nil, nil
local focused = true
local color = player:GetAttribute("PaintBucketColor")
if typeof(color) ~= "Color3" then color = Color3.new(1, 1, 1) end
-- Preview is intentionally separate: no known writer updates the native cached color.
local desiredGlobalColor = color
local collapsed, dragging, uiMouseDown = false, nil, false
local dragResumeAt = 0
local windowX, windowY = 8, 80
local visibleVisits, rayBudget, holdLimit = 0, CONFIG.MaxRaysPerFrame, timing.TargetDwell
local restoreAfterRelease = false
local lastToolQuery = -math.huge
local state, active, testing = "OFF", nil, false
local stateAt, lastPick, lastCursor, stableAt, stableFrames = 0, -math.huge, 0, 0, 0
local held, releasing, downSeen, upSeen = false, false, 0, 0
local pressBaseline, releaseBaseline = 0, 0
local releaseAt, releaseFault, releaseAttempts = 0, false, 0
local runColor, poseAttempt = nil, 0
local decision, cameraSnapshot, nextPressAt = nil, nil, 0
local tested, testSucceeded, testMessage = false, false, "Native input has not been tested."
local holdDowns, holdUps, observed, inputErrors = 0, 0, 0, 0
local status = locked and "Diagnostic lock: input disabled" or "Paused. Choose a visible test province, then TEST NATIVE INPUT."
local lastDisplay, stepping = 0, false
local adapter = {}
local moveMode = CONFIG.NativeMoveMode
local ui, main, doneButton, mini, statusLabel, colorButton
local paletteLabel, countsLabel
local paintButton, cameraButton, visibleButton, keepButton, capabilityLabel, testLabel, dwellBox, moveButton, speedButton, hudLabel
local stop, release, removeEntry, evaluate, setSelectionMode, updateUI, layoutWindow, overOwnWindow

local function connect(signal, callback, list)
	local c = signal:Connect(callback)
	table.insert(list or connections, c)
	return c
end
local function disconnect(list)
	for _, c in ipairs(list) do c:Disconnect() end
	table.clear(list)
end
local function make(class, parent, props)
	local object = Instance.new(class)
	for key, value in pairs(props) do object[key] = value end
	object.Parent = parent
	return object
end
local function capabilities()
	-- Read names only; probing never generates input.
	adapter.relative = moveMode ~= "Absolute" and type(mousemoverel) == "function"
	adapter.move = adapter.relative and mousemoverel or
		(moveMode ~= "Relative" and type(mousemoveabs) == "function" and mousemoveabs or nil)
	adapter.press = type(mouse1press) == "function" and mouse1press or nil
	adapter.release = type(mouse1release) == "function" and mouse1release or nil
	adapter.focus = type(isrbxactive) == "function" and isrbxactive or nil
	return adapter.move ~= nil and adapter.press ~= nil and adapter.release ~= nil
end
local function valid(part)
	local provinces = Workspace:FindFirstChild("Provinces")
	return part ~= nil and part:IsA("BasePart") and provinces ~= nil and part.Parent == provinces
end
local function paletteColor()
	local value = player:GetAttribute("PaintBucketColor")
	return typeof(value) == "Color3" and value or Color3.new(1, 1, 1)
end
local function desired(entry) return keepColor and entry.savedColor or desiredGlobalColor end
local function eligible(entry)
	return entry and entry.active and entry.committed and valid(entry.part)
		and entry.part.Color ~= desired(entry)
end
local function paintable(entry)
	-- Mixed saved colors wait for the user to choose that color in the normal palette.
	return eligible(entry) and desired(entry) == desiredGlobalColor
end
local function restoreCamera()
	local saved = cameraSnapshot
	cameraSnapshot = nil
	if not saved then return end
	pcall(function()
		-- Do not seize a new camera or overwrite a camera another controller took over.
		if saved.object == Workspace.CurrentCamera and saved.object.CameraType == Enum.CameraType.Scriptable then
			saved.object.CFrame = saved.cframe
			saved.object.Focus = saved.focus
			saved.object.CameraType = saved.kind
		end
	end)
end
local function removeDirty(entry)
	local index = entry.dirtyIndex
	if not index then return end
	local last = table.remove(dirty)
	if index <= #dirty then dirty[index], last.dirtyIndex = last, index end
	entry.dirtyIndex = nil
end
local function addDirty(entry, now)
	if entry.dirtyIndex or not entry.committed then return end
	entry.waitSince, entry.dirtyIndex = now, #dirty + 1
	dirty[entry.dirtyIndex] = entry
	lastPick = -math.huge
end
local function presentation()
	if not ui then return end
	main.Visible = not selectionMode and not collapsed
	doneButton.Visible = selectionMode ~= nil
	mini.Visible = collapsed and not selectionMode
end
local function finishRelease(now)
	if restoreAfterRelease or not painting or selectionMode then restoreCamera() end
	restoreAfterRelease = false
	releasing, held, releaseFault = false, false, false
	active = nil
	if testing then
		testing = false
		tested = testSucceeded
		testMessage = (testSucceeded and "PASS: real target and native down/up observed; AutoPainter RPCs=0. Native RPC completion is unobserved."
			or "FAILED: " .. testMessage)
		painting = false
		restoreCamera()
	end
	state, stateAt, lastPick = painting and "IDLE" or "OFF", now, -math.huge
	presentation()
end
release = function(reason)
	if active and active.active then
		active.waitSince = os.clock()
		active.retryAt = active.part.Color == desired(active) and 0 or os.clock() + timing.AimRetry
	end
	status = reason or status
	if held or releasing then
		if not releasing then
			releasing, releaseAt, releaseBaseline = true, os.clock(), upSeen
			releaseAttempts = 0
		end
		state = "RELEASING"
		if releaseAttempts < 3 and (held or releaseFault) then
			releaseAttempts += 1
			-- Reserve release state before entering an external API. No cursor/camera
			-- or target-color changes are made until button-up has been observed.
			local ok = adapter.release and pcall(adapter.release)
			holdUps += 1
			if ok then held, releaseFault = false, false
			else releaseFault = true; inputErrors += 1; painting = false end
		end
	else
		active = nil
		if testing then testing, tested = false, false; testMessage = "FAILED: " .. testMessage end
		state = painting and "IDLE" or "OFF"
	end
	presentation()
end
stop = function(reason)
	painting = false
	if testing then testSucceeded = false; testMessage = reason end
	release(reason or "Emergency stop")
	if not releasing then testing = false end
	if releasing then restoreAfterRelease = true else restoreCamera() end
	decision = nil
	presentation()
end

evaluate = function(entry, changed)
	if not entry.active then return end
	if not valid(entry.part) then removeEntry(entry); return end
	local now = os.clock()
	local matched = entry.part.Color == desired(entry)
	if changed then
		entry.changedAt = now
		if not matched then
			entry.contests = math.min(10, entry.contests * math.exp(-(now - entry.contestAt) / CONFIG.ContestDecay) + 1)
			entry.contestAt = now
		end
	end
	if entry.committed then
		if matched then
			if not entry.matched then observed += 1 end
			removeDirty(entry)
		else addDirty(entry, now) end
	end
	local blocked = entry.committed and not matched and desired(entry) ~= desiredGlobalColor
	if blocked ~= (entry.paletteBlocked == true) then paletteBlocked += blocked and 1 or -1 end
	entry.paletteBlocked = blocked
	entry.matched = matched
	if entry.box then entry.box.Color3 = desired(entry) end
	if active == entry and matched and not testing and not releasing then release("Target color observed") end
end
removeEntry = function(entry)
	if not entry.active then return end
	if active == entry then
		if testing then testSucceeded = false; testMessage = "Test province removed" end
		release("Province removed")
	end
	entry.active = false
	if entry.paletteBlocked then paletteBlocked -= 1; entry.paletteBlocked = false end
	removeDirty(entry)
	if not entry.committed then pendingCount -= 1 end
	if priority == entry then priority = nil end
	if testTarget == entry then testTarget = nil end
	lookup[entry.part] = nil
	disconnect(entry.connections)
	entry.box:Destroy()
	local index, last = entry.index, table.remove(entries)
	if index <= #entries then entries[index], last.index = last, index end
	entry.part, entry.box = nil, nil
end
function api.AddProvince(part)
	if not alive or not valid(part) or lookup[part] then return false end
	nextId += 1
	local box = make("SelectionBox", ui, { Name = "ProtectedProvince", Adornee = part,
		Color3 = paletteColor(), SurfaceTransparency = 1, LineThickness = 0.025 })
	local entry = { active = true, part = part, savedColor = paletteColor(), committed = false, box = box,
		id = nextId, index = #entries + 1, connections = {}, contests = 0, contestAt = os.clock(),
		changedAt = -math.huge, retryAt = 0, matched = part.Color == desiredGlobalColor }
	entries[entry.index], lookup[part] = entry, entry
	pendingCount += 1
	connect(part:GetPropertyChangedSignal("Color"), function() evaluate(entry, true) end, entry.connections)
	connect(part.AncestryChanged, function() evaluate(entry, false) end, entry.connections)
	connect(part.Destroying, function() removeEntry(entry) end, entry.connections)
	return true
end
function api.RemoveProvince(part) if lookup[part] then removeEntry(lookup[part]) end end
function api.Clear()
	if not alive then return end
	stop("Selections cleared")
	while #entries > 0 do removeEntry(entries[#entries]) end
	decision, priority, testTarget = nil, nil, nil
end
local function reevaluate()
	for i = #entries, 1, -1 do evaluate(entries[i], false) end
	decision = nil
end
setSelectionMode = function(value)
	if not alive then return end
	if value then
		if testing then testSucceeded = false; testMessage = "Selection interrupted test" end
		release("Selecting; native input paused")
		if releasing then restoreAfterRelease = true else restoreCamera() end
	end
	selectionMode = value
	if not value then
		-- One non-yielding transaction. Add never inserts into the dirty set.
		for _, entry in ipairs(entries) do entry.committed = true end
		pendingCount = 0
		reevaluate()
	end
	decision = nil
	if value then doneButton.Text = value .. " · Done / Cancel" end
	presentation()
end
function api.CommitSelections() setSelectionMode(nil) end
function api.SetColor(value)
	assert(typeof(value) == "Color3", "Expected Color3")
	if not alive then return false end
	color = value -- Preview only; never writes tool state or changes a running target.
	status = "Preview only. Choose this color in the normal PaintBucket palette, then start Auto Paint."
	if updateUI then updateUI() end
	return true
end
function api.GetColor() return color end
function api.GetDesiredColor() return desiredGlobalColor end
function api.SetSpeedMode(value)
	if not alive or not PROFILES[value] then return false end
	release("Speed mode changed")
	speedMode, timing = value, PROFILES[value]
	dwell = timing.TargetDwell
	if dwellBox then dwellBox.Text = tostring(dwell) end
	decision, lastPick = nil, -math.huge
	return true
end
function api.GetTiming() return table.clone(timing) end
function api.SetCollapsed(value)
	if not alive then return end
	collapsed = value == true
	if layoutWindow then layoutWindow() end
	presentation()
end
function api.SetKeepColor(value)
	if not alive then return end
	release("Keep Territory Color changed")
	keepColor = value == true; reevaluate()
end
function api.SetPriority(part)
	if not alive then return false end
	if part == nil then priority = nil; return true end
	local entry = lookup[part]
	if not entry or not entry.active then return false end
	priority = entry; decision = nil; return true
end
function api.SetTestTarget(part)
	if not alive then return false end
	if testing or painting then return false end
	local entry = lookup[part]
	if not entry or not entry.active or not entry.committed then return false end
	testTarget = entry; return true
end
function api.SetDwell(value)
	if not alive then return false end
	value = tonumber(value)
	if not value or value ~= value then return false end
	dwell = math.clamp(value, 0.25, timing.MaxDwell)
	return true
end
function api.SetCameraAutomation(value)
	if not alive then return false end
	release("Camera option changed"); if releasing then restoreAfterRelease = true else restoreCamera() end
	cameraAutomation = value == true; decision = nil
	return true
end
function api.SetVisibleOnly(value)
	if not alive then return false end
	release("Visibility option changed")
	visibleOnly = value == true; decision = nil
	return true
end
function api.EmergencyStop() if alive then stop("Emergency stop; press Auto Paint to resume") end end
function api.LockDiagnostics()
	if not alive then return end
	stop("Diagnostic lock enabled")
	locked = true
end

local function toolReady()
	local current = player.Character
	if current ~= character or (bucket and (bucket.Parent ~= current or bucket.Name ~= "PaintBucket"))
		or (humanoid and humanoid.Parent ~= current) then
		character, bucket, humanoid, lastToolQuery = current, nil, nil, -math.huge
	end
	if (not bucket or not humanoid) and os.clock() - lastToolQuery >= 0.5 then
		lastToolQuery = os.clock()
		bucket = character and character:FindFirstChild("PaintBucket")
		humanoid = character and character:FindFirstChildOfClass("Humanoid")
	end
	return character and character:IsDescendantOf(Workspace) and bucket and bucket:IsA("Tool")
		and bucket.Parent == character and bucket.Enabled ~= false and humanoid and humanoid.Health > 0
end
local function inputReady(fromButton)
	if dragging or (not fromButton and (uiMouseDown or os.clock() < dragResumeAt)) then return false end
	if not focused or Input:GetFocusedTextBox() or not Input.MouseEnabled then return false end
	if Input.MouseBehavior ~= Enum.MouseBehavior.Default then return false end
	local menuOK, menuOpen = pcall(function() return GuiService.MenuIsOpen end)
	if not menuOK or menuOpen then return false end
	if not held and Input:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) then return false end
	if adapter.focus then
		local ok, yes = pcall(adapter.focus)
		if not ok or not yes then return false end
	end
	return true
end
local function unobstructedGUI(point)
	if overOwnWindow and overOwnWindow(point) then return false end
	local inset = GuiService:GetGuiInset()
	local ok, objects = pcall(function() return playerGui:GetGuiObjectsAtPosition(point.X - inset.X, point.Y - inset.Y) end)
	if not ok then return false end
	for _, object in ipairs(objects) do
		if object.Visible and (object.Active or object:IsA("TextButton") or object:IsA("ImageButton") or object:IsA("TextBox")) then
			return false
		end
	end
	return true
end
local offsets = {
	Vector3.new(0, 0, 0), Vector3.new(0, 0.48, 0),
	Vector3.new(-0.3, 0.48, -0.3), Vector3.new(0.3, 0.48, -0.3),
	Vector3.new(-0.3, 0.48, 0.3), Vector3.new(0.3, 0.48, 0.3),
}
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
local rayCharacter = nil
local function targetPoint(entry, cheap)
	local camera = Workspace.CurrentCamera
	if not camera or not entry.active or not valid(entry.part) then return nil end
	local size = camera.ViewportSize
	if size.X < 100 or size.Y < 100 then return nil end
	if rayCharacter ~= character then
		rayCharacter = character
		rayParams.FilterDescendantsInstances = character and { character } or {}
	end
	local part = entry.part
	if entry.pointFrame ~= part.CFrame or entry.pointSize ~= part.Size then
		entry.pointFrame, entry.pointSize = part.CFrame, part.Size
		entry.points, entry.goodPoint = {}, nil
		for i, offset in ipairs(offsets) do entry.points[i] = part.CFrame:PointToWorldSpace(offset * part.Size) end
	end
	local first = entry.goodPoint or 1
	for n = 1, cheap and 1 or #offsets do
		local i = ((first + n - 2) % #offsets) + 1
		local worldPoint = entry.points[i]
		-- Projection/ray hits are revalidated, never assumed across camera/occluder changes.
		local point, onScreen = camera:WorldToViewportPoint(worldPoint)
		if onScreen and point.Z > 0 and point.X >= 8 and point.X < size.X - 8
			and point.Y >= 60 and point.Y < size.Y - 8 then
			if cheap then return point end
			if unobstructedGUI(point) then
				if rayBudget <= 0 then return nil, true end
				rayBudget -= 1
				local ray = camera:ViewportPointToRay(point.X, point.Y)
				local hit = Workspace:Raycast(ray.Origin, ray.Direction * math.max(1, (worldPoint - ray.Origin).Magnitude + 10), rayParams)
				if hit and hit.Instance == part then entry.goodPoint = i; return point end
			end
		end
	end
	entry.goodPoint = nil
	return nil
end
local function cameraPose(entry)
	local camera = Workspace.CurrentCamera
	if not camera or not cameraAutomation or visibleOnly or testing or not paintable(entry) then return false end
	if not cameraSnapshot then
		cameraSnapshot = { object = camera, cframe = camera.CFrame, kind = camera.CameraType, focus = camera.Focus }
	elseif cameraSnapshot.object ~= camera then return false end
	poseAttempt += 1
	local center = entry.part.Position
	local distance = math.clamp(entry.part.Size.Magnitude * 1.5, CONFIG.CameraMinDistance, CONFIG.CameraMaxDistance)
	local position
	if poseAttempt == 1 and (camera.CFrame.Position - center).Magnitude > 1 then position = camera.CFrame.Position
	elseif poseAttempt == 2 then position = center + Vector3.new(0, distance, distance * 0.15)
	elseif poseAttempt == 3 then position = center + Vector3.new(distance * 0.4, distance, distance * 0.4)
	else return false end
	camera.CameraType = Enum.CameraType.Scriptable
	camera.CFrame = CFrame.lookAt(position, center)
	camera.Focus = CFrame.new(center)
	return true
end
local function older(a, b)
	return not b or a.waitSince < b.waitSince or (a.waitSince == b.waitSince and a.id < b.id)
end
local function nearer(entry, best, distance, bestDistance, now)
	if not best or distance ~= bestDistance then return distance < bestDistance end
	if entry.waitSince ~= best.waitSince then return entry.waitSince < best.waitSince end
	local contest = entry.contests * math.exp(-(now - entry.contestAt) / CONFIG.ContestDecay)
	local other = best.contests * math.exp(-(now - best.contestAt) / CONFIG.ContestDecay)
	if contest ~= other then return contest > other end
	return entry.id < best.id
end
local function choose(now)
	if not decision then
		decision = { index = 1, snapshot = table.clone(dirty), distance = math.huge, alignment = -math.huge,
			camera = Workspace.CurrentCamera }
	end
	local pick = decision
	-- Camera motion must not restart large scans forever. Every point is projected
	-- against the current view; AIM revalidates the chosen point before movement/down.
	if pick.camera ~= Workspace.CurrentCamera then decision = nil; return nil, false end
	for _ = 1, timing.CandidatesPerFrame do
		if pick.index > #pick.snapshot then break end
		local entry = pick.snapshot[pick.index]
		if entry.active and not valid(entry.part) then removeEntry(entry) end
		if paintable(entry) and now >= entry.retryAt then
			local point, exhausted = targetPoint(entry, false)
			if exhausted then return nil, false end
			local aged = now - entry.waitSince >= CONFIG.AgingSeconds
			if point then
				local cursor = Input:GetMouseLocation()
				local distance = (point.X - cursor.X)^2 + (point.Y - cursor.Y)^2
				if aged and older(entry, pick.oldVisible) then pick.oldVisible = entry end
				if nearer(entry, pick.visible, distance, pick.distance, now) then
					pick.visible, pick.distance = entry, distance
				end
			elseif cameraAutomation and not visibleOnly then
				if aged and older(entry, pick.oldHidden) then pick.oldHidden = entry end
				local delta = entry.part.Position - pick.camera.CFrame.Position
				local alignment = delta.Magnitude > 0 and pick.camera.CFrame.LookVector:Dot(delta.Unit) or 1
				if alignment > pick.alignment or (alignment == pick.alignment and older(entry, pick.hidden)) then
					pick.hidden, pick.alignment = entry, alignment
				end
			end
		elseif entry.active and entry.committed and entry.part.Color == desired(entry) then
			evaluate(entry, false) -- Defensive check for a deferred Color notification.
		end
		pick.index += 1
	end
	if pick.index <= #pick.snapshot then return nil, false end
	decision = nil
	local candidate = pick.oldVisible or pick.visible
	if pick.oldHidden and (not candidate or visibleVisits >= CONFIG.VisibleVisitsBeforeAgedOffscreen) then
		candidate, visibleVisits = pick.oldHidden, 0
	elseif candidate then visibleVisits += 1
	else candidate, visibleVisits = pick.oldHidden or pick.hidden, 0 end
	return candidate, true
end
local function aim(entry, now)
	if not testing and not paintable(entry) then return false end
	active, state, stateAt, poseAttempt = entry, "AIM", now, 0
	stableFrames, stableAt, lastCursor = 0, now, -math.huge
	runColor = testing and paletteColor() or desired(entry)
	presentation()
	return true
end
function api.RefreshInputCapabilities()
	if not alive then return false end
	if held or releasing or testing or painting then return false end
	tested = false
	return capabilities()
end
function api.SetMoveMode(value)
	if not alive then return false end
	if value ~= "Auto" and value ~= "Relative" and value ~= "Absolute" then return false end
	if held or releasing or testing or painting then return false end
	moveMode, tested = value, false
	capabilities()
	return true
end
function api.GetCapabilities()
	return { Move = adapter.move and (adapter.relative and "mousemoverel" or "mousemoveabs") or "unavailable",
		MouseDown = adapter.press ~= nil, MouseUp = adapter.release ~= nil,
		RelativeAvailable = type(mousemoverel) == "function", AbsoluteAvailable = type(mousemoveabs) == "function",
		MoveMode = moveMode, Focus = adapter.focus ~= nil, Callable = adapter.move ~= nil and adapter.press ~= nil and adapter.release ~= nil,
		Tested = tested, Locked = locked }
end
function api.SetPainting(value)
	if not alive then return false end
	if value ~= true then stop("Paused"); return true end
	if locked then status = "Diagnostics locked: input disabled"; return false end
	if not tested then status = "Run TEST NATIVE INPUT successfully before enabling Auto Paint"; return false end
	if held or releasing or releaseFault or testing then return false end
	if painting then return true end
	desiredGlobalColor, color = paletteColor(), paletteColor()
	reevaluate()
	painting, state, lastPick, collapsed = true, "IDLE", -math.huge, true
	layoutWindow()
	presentation(); return true
end
function api.TestNativeInput()
	if not alive or locked or painting or testing or held or releasing or releaseFault or selectionMode then return false end
	if not capabilities() then status = "Required native input APIs unavailable"; return false end
	if not testTarget or not testTarget.active or not testTarget.committed then status = "Choose a committed Test Province first"; return false end
	if not eligible(testTarget) then status = "Choose a protected wrong-color province for the input test"; return false end
	if not toolReady() then status = "Equip your normal PaintBucket and keep your character alive"; return false end
	if not inputReady(true) then status = "Focus Roblox, close menus/text input and unlock the cursor"; return false end
	-- Test cannot move the camera or silently choose another province.
	if not targetPoint(testTarget, true) then status = "Chosen test province is not visible"; return false end
	tested, testing, testSucceeded, collapsed = false, true, false, true
	layoutWindow()
	testMessage = "Test in progress; native PaintBucket may send legitimate paint requests."
	aim(testTarget, os.clock()); return true
end
function api.GetStats()
	return { Closed = not alive, Painting = painting, State = state, Held = held, Releasing = releasing,
		Protected = #entries - pendingCount, WrongColor = #dirty, WaitingForPalette = paletteBlocked, CorrectColor = #entries - pendingCount - #dirty,
		DesiredGlobalColor = desiredGlobalColor, SpeedMode = speedMode, Collapsed = collapsed, Dragging = dragging ~= nil,
		WindowX = windowX, WindowY = windowY, HoldLimit = holdLimit,
		Selected = #entries, PendingSelections = pendingCount, CommittedSelections = #entries - pendingCount,
		Dirty = #dirty, SelectionMode = selectionMode, Target = active and active.part or nil,
		Priority = priority and priority.part or nil, TestTarget = testTarget and testTarget.part or nil,
		Tested = tested, TestResult = testMessage, InputErrors = inputErrors,
		HoldDowns = holdDowns, HoldUps = holdUps, TargetMatches = observed,
		AutoPainterRPCs = 0, NativeRPCs = "unobserved", Locked = locked,
		CameraAutomation = cameraAutomation, VisibleOnly = visibleOnly, Dwell = dwell }
end
function api.GetNativeInputReport()
	local function path(entry)
		return entry and entry.active and entry.part:GetFullName() or "<none>"
	end
	local cap = api.GetCapabilities()
	return table.concat({
		"AUTOPAINTER NATIVE INPUT REPORT",
		"AutoPainterRPCs=0 (no game remote transport in this controller; native RPC count/completion unobserved)",
		"Move=" .. cap.Move .. " Down=" .. tostring(cap.MouseDown) .. " Up=" .. tostring(cap.MouseUp),
		"Callable=" .. tostring(cap.Callable) .. " InputTestPassed=" .. tostring(tested) .. " Locked=" .. tostring(locked),
		"State=" .. state .. " Painting=" .. tostring(painting) .. " Held=" .. tostring(held) .. " Releasing=" .. tostring(releasing),
		"Protected=" .. (#entries - pendingCount) .. " Pending=" .. pendingCount .. " WrongColor=" .. #dirty
			.. " CorrectColor=" .. (#entries - pendingCount - #dirty) .. " WaitingForPalette=" .. paletteBlocked,
		"Speed=" .. speedMode .. " Dwell=" .. dwell .. " ReleaseGap=" .. timing.ReleaseGap,
		"DesiredGlobalColor=" .. tostring(desiredGlobalColor) .. " (normal palette snapshot; no attribute writes)",
		"ChosenTest=" .. path(testTarget) .. " Active=" .. path(active) .. " Priority=" .. path(priority),
		"RealMouseTarget=" .. (mouse.Target and mouse.Target:GetFullName() or "<none>"),
		"DownAttempts=" .. holdDowns .. " UpAttempts=" .. holdUps .. " ObservedMouseDown=" .. downSeen .. " ObservedMouseUp=" .. upSeen,
		"InputErrors=" .. inputErrors .. " ObservedTargetColorMatches=" .. observed,
		"Status=" .. status, "TestResult=" .. testMessage,
		"Input events do not prove tool receipt, native-loop drain, server acceptance or paint success.",
	}, "\n")
end
function api.CopyNativeInputReport()
	if not alive then return false end
	local text = api.GetNativeInputReport()
	if type(setclipboard) == "function" and pcall(setclipboard, text) then return true end
	if type(writefile) == "function" and pcall(writefile, "AutoPainterNativeInputReport.txt", text) then return true end
	status = "Clipboard/file export unavailable; use GetNativeInputReport()."
	return false
end
local function frame(now)
	rayBudget = CONFIG.MaxRaysPerFrame
	if releasing then
		if releaseFault then
			if now - releaseAt >= releaseAttempts * 0.1 and releaseAttempts < 3 then release(status) end
			if releaseAttempts >= 3 then status = "Mouse release failed. Manually release Mouse1; automation is stopped." end
		elseif upSeen > releaseBaseline and now >= releaseAt + timing.ReleaseGap then
			nextPressAt = now
			finishRelease(now)
		elseif now - releaseAt > CONFIG.InputEventTimeout + timing.ReleaseGap then
			painting, tested, testSucceeded = false, false, false
			testMessage = "Native button-up was not observed. Release Mouse1 manually."
			status = testMessage -- Keep the guard; never move/press a new target.
		end
		if releasing then return end
	end
	if not painting and not testing then return end
	if locked or selectionMode then
		if active or held then release("Input suspended") end
		return
	end
	if dragging or uiMouseDown or now < dragResumeAt then return end
	if not toolReady() then
		if testing then testMessage = "PaintBucket or live character unavailable"; stop(testMessage)
		else release("Waiting for equipped PaintBucket"); if releasing then restoreAfterRelease = true else restoreCamera() end end
		return
	end
	if not inputReady() then stop("Input focus, menu or cursor lock changed"); return end
	if not Workspace.CurrentCamera then stop("Camera unavailable"); return end
	if cameraSnapshot and cameraSnapshot.object ~= Workspace.CurrentCamera then stop("Camera replaced"); return end
	if active and (not active.active or not active.committed or not valid(active.part)) then
		local invalid = active
		release("Target unavailable")
		if invalid.active and not valid(invalid.part) then removeEntry(invalid) end
		return
	end
	if active and not testing and not paintable(active) then release("Target clean or palette does not match saved color"); return end
	if active and not testing and desired(active) ~= runColor then release("Desired color changed"); return end
	if active and paletteColor() ~= runColor then stop("Normal bucket color changed during targeting"); return end
	if state == "IDLE" or state == "OFF" then
		if #dirty == 0 then decision = nil; status = "All protected provinces match the desired color"; return end
		if decision or now - lastPick >= timing.IdleRetry then
			local nextEntry, finished = choose(now)
			if finished then
				lastPick = now
				if paintable(nextEntry) then aim(nextEntry, now)
				elseif paletteBlocked > 0 then status = tostring(paletteBlocked) .. " dirty saved colors await a matching normal palette" end
			end
		end
	end
	if state == "HOLD" then
		if mouse.Target ~= active.part then
			if testing then testSucceeded = false; testMessage = "Real mouse target changed during hold" end
			release("Real mouse target lost"); return
		end
		if downSeen <= pressBaseline and now - stateAt >= CONFIG.InputEventTimeout then
			painting, tested, testSucceeded = false, false, false
			testMessage = "Mouse-down API returned but no genuine Mouse.Button1Down was observed."
			release(testMessage); return
		end
		local maximum = testing and CONFIG.TestHold or holdLimit
		if active.part.Color == runColor or now - stateAt >= maximum then
			if not testing and downSeen <= pressBaseline then
				painting, tested = false, false
				testMessage = "No native mouse-down event observed; automation stopped."
				release(testMessage); return
			end
			if testing then
				testSucceeded = downSeen > pressBaseline
				if not testSucceeded then testMessage = "No native button-down event observed" end
			end
			release(testing and "Native input test releasing" or "Dwell complete"); return
		end
	elseif state == "AIM" then
		if now - stateAt > timing.AimTimeout then
			if testing then testMessage = "Could not acquire the exact real Mouse.Target"; stop(testMessage)
			else release("Target not reachable; trying another province") end
			return
		end
		local point, exhausted = targetPoint(active, false)
		if exhausted then return end
		if not point then
			if now - lastCursor >= timing.CursorInterval and cameraPose(active) then
				lastCursor = now; stableAt, stableFrames = now, 0
			end
			return
		end
		if mouse.Target == active.part and unobstructedGUI(Input:GetMouseLocation()) then
			stableFrames += 1
			if stableFrames >= timing.TargetStableFrames and now - stableAt >= timing.TargetStableSeconds and now >= nextPressAt then
				if Input:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) then stop("Mouse1 is already held by the user"); return end
				-- No yield between final real-target check and issuing native input.
				if mouse.Target ~= active.part or (not testing and not paintable(active)) then return end
				local contest = active.contests * math.exp(-(now - active.contestAt) / CONFIG.ContestDecay)
				holdLimit = math.min(timing.MaxDwell, dwell + math.min(1.05, contest * 0.25))
				if active == priority then holdLimit = math.min(timing.MaxDwell, holdLimit * timing.PriorityDwellMultiplier) end
				held, state, stateAt, pressBaseline = true, "HOLD", now, downSeen
				holdDowns += 1
				local ok = pcall(adapter.press)
				if not ok then inputErrors += 1; tested = false; stop("Native mouse-down failed; releasing") end
				return
			end
		else stableFrames, stableAt = 0, now end
		if now - lastCursor >= timing.CursorInterval then
			local location = Input:GetMouseLocation()
			local ok
			if adapter.relative then ok = pcall(adapter.move, math.round(point.X - location.X), math.round(point.Y - location.Y))
			else ok = pcall(adapter.move, math.round(point.X), math.round(point.Y)) end
			lastCursor = now
			if not ok then inputErrors += 1; tested = false; stop("Native cursor move failed") end
		end

	end
end

-- All generated UI belongs to this client; no game tool properties are rewritten.
ui = make("ScreenGui", playerGui, { Name = GUI_NAME, ResetOnSpawn = false, IgnoreGuiInset = true,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling })
ui:SetAttribute("AutoPainterNativeVersion", VERSION)
main = make("Frame", ui, { Name = "Panel", Active = true, Position = UDim2.fromOffset(windowX, windowY),
	Size = UDim2.fromOffset(420, 640), BackgroundColor3 = Color3.fromRGB(30, 34, 43), BorderSizePixel = 0 })
local title = make("TextLabel", main, { Name = "DragTitle", Active = true,
	Text = "AutoPainter · native hold", Size = UDim2.new(1, -80, 0, 34),
	TextSize = 19, TextColor3 = Color3.new(1, 1, 1), BackgroundTransparency = 1 })
local collapse = make("TextButton", main, { Name = "Collapse", Text = "—", Size = UDim2.fromOffset(36, 32),
	Position = UDim2.new(1, -76, 0, 0), TextSize = 24 })
local close = make("TextButton", main, { Text = "×", Size = UDim2.fromOffset(36, 32),
	Position = UDim2.new(1, -38, 0, 0), TextSize = 24 })
statusLabel = make("TextLabel", main, { Name = "NativeStatus", Text = status, TextWrapped = true,
	Size = UDim2.new(1, -16, 0, 60), Position = UDim2.fromOffset(8, 76), TextSize = 15,
	TextColor3 = Color3.new(1, 1, 1), BackgroundTransparency = 1 })
countsLabel = make("TextLabel", main, { Name = "ProtectedCounts", Text = "", TextWrapped = true,
	Size = UDim2.new(1, -16, 0, 38), Position = UDim2.fromOffset(8, 36), TextSize = 15,
	TextColor3 = Color3.new(1, 1, 1), BackgroundTransparency = 1 })
local scroll = make("ScrollingFrame", main, { Size = UDim2.new(1, -16, 1, -148), Position = UDim2.fromOffset(8, 140),
	AutomaticCanvasSize = Enum.AutomaticSize.Y, CanvasSize = UDim2.new(), BackgroundTransparency = 1, ScrollBarThickness = 5 })
make("UIListLayout", scroll, { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder })
local order = 0
local function button(text, callback)
	order += 1
	local b = make("TextButton", scroll, { Text = text, LayoutOrder = order,
		Size = UDim2.new(1, -8, 0, 34), TextSize = 16, BackgroundColor3 = Color3.fromRGB(48, 74, 95), TextColor3 = Color3.new(1, 1, 1) })
	connect(b.Activated, callback)
	return b
end
paintButton = button("Auto Paint: OFF [Q]", function() api.SetPainting(not painting) end)
button("Protect Province", function() setSelectionMode("Add") end)
button("Unprotect Province", function() setSelectionMode("Remove") end)
button("Clear Provinces", api.Clear)
colorButton = button("Country Color / Pick (preview only)", function() setSelectionMode("Color") end)
button("Randomize Preview [R]", function() api.SetColor(Color3.fromRGB(math.random(0, 255), math.random(0, 255), math.random(0, 255))) end)
speedButton = button("Speed Mode: FAST", function() api.SetSpeedMode(speedMode == "FAST" and "NORMAL" or "FAST") end)
order += 1
paletteLabel = make("TextLabel", scroll, { Name = "DesiredPaletteColor", LayoutOrder = order,
	Text = "Desired color: normal PaintBucket palette", Size = UDim2.new(1, -8, 0, 48),
	TextWrapped = true, TextSize = 14 })
keepButton = button("Keep Territory Color: OFF", function() api.SetKeepColor(not keepColor) end)
cameraButton = button("Camera Automation: ON", function() api.SetCameraAutomation(not cameraAutomation) end)
visibleButton = button("Visible Only: OFF", function() api.SetVisibleOnly(not visibleOnly) end)
button("Priority Target / Lock Province", function() setSelectionMode("Priority") end)
button("Clear Priority", function() api.SetPriority(nil) end)
order += 1
make("TextLabel", scroll, { Text = "Target Dwell Time (seconds)", LayoutOrder = order,
	Size = UDim2.new(1, -8, 0, 22), TextSize = 15, BackgroundTransparency = 1, TextColor3 = Color3.new(1, 1, 1) })
order += 1
dwellBox = make("TextBox", scroll, { Name = "TargetDwell", Text = tostring(dwell), PlaceholderText = "Target dwell seconds",
	LayoutOrder = order, Size = UDim2.new(1, -8, 0, 34), TextSize = 16, ClearTextOnFocus = false })
button("Choose Test Province", function() setSelectionMode("Test Target") end)
button("TEST NATIVE INPUT", function() api.TestNativeInput() end)
moveButton = button("Cursor API: Auto", function()
	api.SetMoveMode(moveMode == "Auto" and "Relative" or moveMode == "Relative" and "Absolute" or "Auto")
end)
button("Refresh Input Capabilities", function() api.RefreshInputCapabilities() end)
button("Copy Native Input Report", function() api.CopyNativeInputReport() end)
button("Emergency Stop [Escape]", api.EmergencyStop)
order += 1
capabilityLabel = make("TextLabel", scroll, { Name = "NativeCapabilities", LayoutOrder = order,
	Size = UDim2.new(1, -8, 0, 60), TextWrapped = true, TextSize = 14, BackgroundTransparency = 1, TextColor3 = Color3.new(1, 1, 1) })
order += 1
testLabel = make("TextLabel", scroll, { Name = "NativeTestResult", LayoutOrder = order, Size = UDim2.new(1, -8, 0, 85),
	TextWrapped = true, TextSize = 14, BackgroundTransparency = 1, TextColor3 = Color3.new(1, 1, 1) })
doneButton = make("TextButton", ui, { Text = "Done / Cancel", Visible = false,
	Position = UDim2.new(0.5, -140, 0, 0), Size = UDim2.fromOffset(280, 38), TextSize = 18 })
mini = make("Frame", ui, { Name = "CombatHUD", Visible = false, Active = true,
	Position = UDim2.fromOffset(windowX, windowY), Size = UDim2.fromOffset(320, 76),
	BackgroundColor3 = Color3.fromRGB(30, 34, 43), BorderSizePixel = 0 })
local miniTitle = make("TextLabel", mini, { Name = "HUDDragTitle", Text = "AutoPainter", Active = true,
	Size = UDim2.new(1, -100, 0, 26), TextSize = 16, BackgroundTransparency = 1, TextColor3 = Color3.new(1, 1, 1) })
local miniStop = make("TextButton", mini, { Text = "STOP", Position = UDim2.new(1, -98, 0, 0),
	Size = UDim2.fromOffset(62, 26), TextSize = 16, BackgroundColor3 = Color3.fromRGB(180, 48, 65), TextColor3 = Color3.new(1, 1, 1) })
local expand = make("TextButton", mini, { Name = "Expand", Text = "+", Position = UDim2.new(1, -34, 0, 0),
	Size = UDim2.fromOffset(34, 26), TextSize = 20 })
hudLabel = make("TextLabel", mini, { Name = "CombatStatus", Position = UDim2.fromOffset(4, 26),
	Size = UDim2.new(1, -8, 0, 48), TextWrapped = true, TextSize = 14,
	BackgroundTransparency = 1, TextColor3 = Color3.new(1, 1, 1) })
local panelWidth, panelHeight, hudWidth = 420, 640, 320
local lastLayout = nil
layoutWindow = function()
	local camera = Workspace.CurrentCamera
	if not camera then return end
	local size = camera.ViewportSize
	local inset = GuiService:GetGuiInset()
	panelWidth, panelHeight = math.min(420, size.X), math.min(640, math.max(0, size.Y - inset.Y))
	hudWidth = math.min(320, size.X)
	windowX = math.clamp(windowX, 0, math.max(0, size.X - (collapsed and hudWidth or panelWidth)))
	windowY = math.clamp(windowY, inset.Y, math.max(inset.Y, size.Y - (collapsed and 76 or panelHeight)))
	if lastLayout and lastLayout.x == windowX and lastLayout.y == windowY
		and lastLayout.width == panelWidth and lastLayout.height == panelHeight and lastLayout.hud == hudWidth then return end
	lastLayout = { x = windowX, y = windowY, width = panelWidth, height = panelHeight, hud = hudWidth }
	doneButton.Position = UDim2.new(0.5, -140, 0, inset.Y)
	main.Size, mini.Size = UDim2.fromOffset(panelWidth, panelHeight), UDim2.fromOffset(hudWidth, 76)
	main.Position, mini.Position = UDim2.fromOffset(windowX, windowY), UDim2.fromOffset(windowX, windowY)
end
overOwnWindow = function(point)
	if selectionMode then
		local width = Workspace.CurrentCamera and Workspace.CurrentCamera.ViewportSize.X or 0
		local top = GuiService:GetGuiInset().Y
		return point.X >= width / 2 - 140 and point.X <= width / 2 + 140 and point.Y >= top and point.Y <= top + 38
	end
	return point.X >= windowX and point.X <= windowX + (collapsed and hudWidth or panelWidth)
		and point.Y >= windowY and point.Y <= windowY + (collapsed and 76 or panelHeight)
end
local function beginDrag(input)
	if input.UserInputType ~= Enum.UserInputType.MouseButton1 or not alive or selectionMode then return end
	local point = Input:GetMouseLocation()
	dragging = { x = point.X, y = point.Y, startX = windowX, startY = windowY }
	uiMouseDown = true
	if active then release("Menu drag; native input suspended") end
	decision = nil
end
connect(title.InputBegan, beginDrag)
connect(miniTitle.InputBegan, beginDrag)
connect(Input.InputChanged, function(input)
	if not dragging or input.UserInputType ~= Enum.UserInputType.MouseMovement then return end
	local point = Input:GetMouseLocation()
	windowX, windowY = dragging.startX + point.X - dragging.x, dragging.startY + point.Y - dragging.y
	layoutWindow()
end)
connect(Input.InputEnded, function(input)
	if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
	if dragging or uiMouseDown then
		dragging, uiMouseDown = nil, false
		dragResumeAt = os.clock() + timing.ReleaseGap
		lastPick = -math.huge
	end
end)
connect(collapse.Activated, function() api.SetCollapsed(true) end)
connect(expand.Activated, function() api.SetCollapsed(false) end)
connect(miniStop.Activated, api.EmergencyStop)
layoutWindow()
connect(doneButton.Activated, function() setSelectionMode(nil) end)
connect(dwellBox.FocusLost, function()
	api.SetDwell(dwellBox.Text); dwellBox.Text = tostring(dwell)
end)

updateUI = function()
	if not alive then return end
	layoutWindow()
	speedButton.Text = "Speed Mode: " .. speedMode
	moveButton.Text = "Cursor API: " .. moveMode
	paintButton.Text = "Auto Paint: " .. (painting and "ON" or "OFF") .. " [Q]"
	cameraButton.Text = "Camera Automation: " .. (cameraAutomation and "ON" or "OFF")
	visibleButton.Text = "Visible Only: " .. (visibleOnly and "ON" or "OFF")
	keepButton.Text = "Keep Territory Color: " .. (keepColor and "ON" or "OFF")
	paletteLabel.BackgroundColor3 = desiredGlobalColor
	paletteLabel.TextColor3 = desiredGlobalColor.R + desiredGlobalColor.G + desiredGlobalColor.B > 1.5 and Color3.new(0, 0, 0) or Color3.new(1, 1, 1)
	paletteLabel.Text = "Desired color: normal palette snapshot\nChoose in PaintBucket before starting. Waiting for palette: " .. paletteBlocked
	colorButton.BackgroundColor3 = color
	colorButton.TextColor3 = color.R + color.G + color.B > 1.5 and Color3.new(0, 0, 0) or Color3.new(1, 1, 1)
	statusLabel.Text = status
	countsLabel.Text = string.format("Protected: %d · Wrong Color: %d · Correct Color: %d · Pending: %d",
		#entries - pendingCount, #dirty, #entries - pendingCount - #dirty, pendingCount)
	hudLabel.Text = string.format("AUTO: %s · Protected: %d · Dirty: %d\nCurrent Target: %s",
		painting and "ON" or "OFF", #entries - pendingCount, #dirty, active and active.part and active.part.Name or "—")
	local cap = api.GetCapabilities()
	capabilityLabel.Text = string.format("Move: %s · Down: %s · Up: %s\nCallable ≠ verified. Q toggle · R preview · Escape stop", cap.Move, tostring(cap.MouseDown), tostring(cap.MouseUp))
	testLabel.Text = "Test province: " .. (testTarget and testTarget.part and testTarget.part:GetFullName() or "<choose one>") .. "\n" .. testMessage
end
local function selectPart(part)
	if not valid(part) then return end
	if selectionMode == "Add" then api.AddProvince(part)
	elseif selectionMode == "Remove" then api.RemoveProvince(part)
	elseif selectionMode == "Color" then api.SetColor(part.Color)
	elseif selectionMode == "Priority" then api.SetPriority(part)
	elseif selectionMode == "Test Target" then
		if not api.SetTestTarget(part) then status = "Test target must already be committed; finish Add first" end
	end
	updateUI()
end
connect(Input.InputBegan, function(input, processed)
	if input.KeyCode == Enum.KeyCode.Escape then
		stop("Emergency stop")
		if selectionMode then setSelectionMode(nil) end
		return
	end
	if input.UserInputType == Enum.UserInputType.MouseButton1 and overOwnWindow(Input:GetMouseLocation()) then
		uiMouseDown = true
		if active then release("Menu interaction; native input suspended") end
		return
	end
	if dragging or uiMouseDown or os.clock() < dragResumeAt or processed or Input:GetFocusedTextBox() then return end
	if input.KeyCode == Enum.KeyCode.Q then api.SetPainting(not painting)
	elseif input.KeyCode == Enum.KeyCode.R then api.SetColor(Color3.fromRGB(math.random(0, 255), math.random(0, 255), math.random(0, 255)))
	elseif input.UserInputType == Enum.UserInputType.MouseButton1 and selectionMode then selectPart(mouse.Target) end
end)
connect(mouse.Button1Down, function() downSeen += 1 end)
connect(mouse.Button1Up, function()
	upSeen += 1
	if releaseFault then held, releaseFault = false, false end
	if held and not releasing then
		held = false
		stop("Mouse button released by user")
	end
end)
connect(mouse.Move, function()
	if held and active and mouse.Target ~= active.part then
		if testing then testSucceeded = false; testMessage = "Mouse target lost" end
		release("Real mouse target lost")
	end
end)
connect(Input.WindowFocusReleased, function() focused = false; dragging, uiMouseDown = nil, false; stop("Roblox lost focus") end)
connect(Input.WindowFocused, function() focused = true end)
connect(player:GetAttributeChangedSignal("PaintBucketColor"), function()
	local value = paletteColor()
	if value == desiredGlobalColor then return end
	-- An attribute notification is not proof of native-cache propagation. Stop and
	-- require an explicit new start after the user finishes choosing in the palette.
	if painting or testing then stop("Normal palette changed. Finish choosing its color, then restart Auto Paint.") end
	desiredGlobalColor, color = value, value
	reevaluate(); updateUI()
end)
connect(player:GetPropertyChangedSignal("Character"), function()
	if active then release("Character changed") end
	if releasing then restoreAfterRelease = true else restoreCamera() end
	character, bucket, humanoid, lastToolQuery = nil, nil, nil, -math.huge
end)
connect(Workspace.DescendantRemoving, function(object)
	local entry = lookup[object]
	if entry then removeEntry(entry) end
	if object == bucket or object == character or object == humanoid then
		if testing then testSucceeded = false; testMessage = "Tool or character removed" end
		release("Waiting for PaintBucket after removal"); if releasing then restoreAfterRelease = true else restoreCamera() end
		bucket, humanoid, lastToolQuery = nil, nil, -math.huge
	end
end)
connect(Workspace:GetPropertyChangedSignal("CurrentCamera"), function() stop("Camera changed") end)
function api.Destroy()
	if not alive then return end
	local guard, released = nil, false
	if held or releasing then
		-- Subscribe before issuing up: deferred signals must not be lost on disconnect.
		guard = mouse.Button1Up:Connect(function()
			released = true
			if not alive then
				held, releasing = false, false
				restoreCamera()
				guard:Disconnect(); ui:Destroy()
			end
		end)
	end
	stop("AutoPainter closed")
	if held and releaseFault then release("AutoPainter closed; release Mouse1 manually") end
	alive = false
	while #entries > 0 do removeEntry(entries[#entries]) end
	disconnect(connections)
	if not released and (held or (releasing and upSeen <= releaseBaseline)) then
		ui.Enabled = false -- Minimal guard until native/manual up; no more input scheduled.
	else
		if guard then guard:Disconnect() end
		restoreCamera(); ui:Destroy()
	end
end
connect(close.Activated, api.Destroy)
connect(ui.Destroying, function() if alive then api.Destroy() end end)
connect(ui.AncestryChanged, function() if alive and not ui:IsDescendantOf(playerGui) then api.Destroy() end end)
local bridge = make("BindableFunction", ui, { Name = "Controller" })
bridge.OnInvoke = function() return api end
connect(RunService.Heartbeat, function()
	if not alive or stepping then return end
	stepping = true
	local now = os.clock()
	local ok, problem = pcall(frame, now)
	stepping = false
	if not ok then inputErrors += 1; tested = false; stop("Controller error: " .. tostring(problem)) end
	if now - lastDisplay >= CONFIG.TelemetryInterval then
		lastDisplay = now
		if state == "HOLD" then status = "Holding genuine Mouse1; native PaintBucket owns requests" end
		updateUI()
	end
end)
capabilities()
updateUI()
presentation()
return api
