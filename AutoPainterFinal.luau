-- Smart native-input AutoPainter. No game remote calls, hooks, or fabricated mouse data.
-- PaintBucket's existing client script is the sole sender of paint requests.
-- Input API availability and delivery must be checked in the user's client.
-- These profiles govern targeting/input only. The native tool owns its cooldown.
local PROFILES = {
	ULTRA = { TargetDwell = 0.24, PriorityDwellMultiplier = 1.75, MaxDwell = 2,
		ReleaseGap = 0.025, AimTimeout = 0.80, AimRetry = 0.08, CursorInterval = 0.012,
		TargetStableSeconds = 0, TargetStableFrames = 1, IdleRetry = 0.016, CandidatesPerFrame = 256,
		CameraPoseMinInterval = 0.07, CameraSettleSeconds = 0.035, UnreachableRetry = 0.30, MoveVerify = 0.04 },
	FAST = { TargetDwell = 0.32, PriorityDwellMultiplier = 1.75, MaxDwell = 2,
		ReleaseGap = 0.05, AimTimeout = 1.05, AimRetry = 0.12, CursorInterval = 0.016,
		TargetStableSeconds = 0, TargetStableFrames = 1, IdleRetry = 0.03, CandidatesPerFrame = 128,
		CameraPoseMinInterval = 0.08, CameraSettleSeconds = 0.04, UnreachableRetry = 0.40, MoveVerify = 0.05 },
	NORMAL = { TargetDwell = 0.9, PriorityDwellMultiplier = 1.75, MaxDwell = 2,
		ReleaseGap = 0.15, AimTimeout = 2.4, AimRetry = 0.4, CursorInterval = 0.05,
		TargetStableSeconds = 0.05, TargetStableFrames = 2, IdleRetry = 0.2, CandidatesPerFrame = 64,
		CameraPoseMinInterval = 0.15, CameraSettleSeconds = 0.08, UnreachableRetry = 0.75, MoveVerify = 0.10 },
}
local CONFIG = {
	SpeedMode = "FAST",
	NativeMoveMode = "Auto", -- Starts relative; learns mode/coordinate preference from genuine target acquisition.
	TestHold = 0.35,
	InputEventTimeout = 0.6,
	MaxProjectionsPerFrame = 96,
	MaxSurfacePoints = 64,
	MaxRaysPerFrame = 32, -- Bounds expensive visibility work, even with many selected parts.
	AgingSeconds = 4, -- Oldest visible target overrides distance after this wait.
	VisibleVisitsBeforeAgedOffscreen = 8, -- Bounded aging escape from perpetual visible contention.
	ContestDecay = 20,
	CameraAutomation = true,
	VisibleOnly = false,
	CameraMinDistance = 35,
	CameraMaxDistance = 1200,
	TelemetryInterval = 0.25,
	FailureHistory = 20,
	TimingSamples = 128,
	UnreachableMaxRetry = 4,
	ContestGrace = 0.15,
	ContestGraceMax = 0.25,
	ViewResidence = 0.35,

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
local GUI_NAME, VERSION = "AutoPainterFinalUI", 10
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
local runColor = nil
local decision, cameraSnapshot, nextPressAt = nil, nil, 0
local tested, testSucceeded, testMessage = false, false, "Native input has not been tested."
local holdDowns, holdUps, observed, inputErrors = 0, 0, 0, 0
local status = locked and "Diagnostic lock: input disabled" or "Paused. Choose a visible test province, then TEST NATIVE INPUT."
local lastDisplay, stepping = 0, false
local adapter = {}
local moveMode = CONFIG.NativeMoveMode
local ui, main, doneButton, mini, statusLabel, colorButton, close
local paletteLabel, countsLabel, contestButton, performanceLabel
local paintButton, cameraButton, visibleButton, keepButton, capabilityLabel, testLabel, dwellBox, moveButton, speedButton, hudLabel
local stop, release, removeEntry, evaluate, setSelectionMode, updateUI, layoutWindow, overOwnWindow
local acq, prepared, wakeEntry = nil, nil, nil
local inputBusy, releaseRequested = false, false
local function nativeCall(fn,...)
	assert(not inputBusy,"Overlapping native input call")
	inputBusy=true
	local ok=pcall(fn,...)
	inputBusy=false
	if releaseRequested then
		releaseRequested=false
		if fn~=adapter.release then release("Deferred mouse release") end
	end
	return ok
end


local renderId, projectionBudget = 0, CONFIG.MaxProjectionsPerFrame
local frameSeconds, lastCameraAt, lastCameraTarget = 1/60, -math.huge, nil
local contestHold, graceUntil = false, nil
local calibrationOnly = false
local movementStats = {
	Relative = { Attempts = 0, SuccessfulAcquisitions = 0, TotalTime = 0 },
	Absolute = { Attempts = 0, SuccessfulAcquisitions = 0, TotalTime = 0 },
}
local preferredMove, absoluteSpace = "Relative", "Viewport"
local reliability = { verifiedCycles = 0, downLatency = 0, upLatency = 0, moveWait = 0, gapFloor = 0 }
local telemetry = { SuccessfulCorrections = 0, HoldAttempts = 0, NoEffectHolds = 0, AimAttempts = 0,
	AimFailures = 0, CameraPoseChanges = 0, TargetSwitches = 0, Raycasts = 0, Projections = 0,
	CachedPointHits = 0, SchedulerScans = 0, TinySelections = 0, TurboAcquisitions = 0 }
local measures = {}
local failures, correctionBins = {}, {}
local runtime, runStarted, lastHoldEnd, lastUpAt, lastTargetId = 0, nil, nil, nil, nil
local function pauseRuntime()
	if runStarted then runtime += os.clock()-runStarted;runStarted=nil end
end
local calibrationResult = "Not calibrated; explicit cursor-only calibration is available."
local function record(name, seconds)
	local m = measures[name]
	if not m then m = { samples = {}, cursor = 0, total = 0, count = 0 }; measures[name] = m end
	m.total += seconds; m.count += 1; m.cursor = m.cursor % CONFIG.TimingSamples + 1
	m.samples[m.cursor] = seconds * 1000
end
local function metric(name)
	local m = measures[name]
	if not m then return 0, 0 end
	local values = table.clone(m.samples); table.sort(values)
	return m.total * 1000 / m.count, values[math.max(1, math.ceil(#values * 0.95))] or 0
end
local function correctionsPerSecond()
	local now, sum = os.clock(), 0
	for _, bin in pairs(correctionBins) do if now - bin.at < 5 then sum += bin.count end end
	return sum / math.min(5, math.max(1, runtime + (runStarted and now - runStarted or 0)))
end
local function effectiveGap()
	return math.max(timing.ReleaseGap, reliability.gapFloor, reliability.upLatency,
		(speedMode == "ULTRA" and reliability.verifiedCycles < 8) and 0.05 or 0)
end
local function targetState(entry)
	if not entry.committed then return "PENDING" end
	if entry.matched then return "CORRECT" end
	if entry.paletteBlocked then return "PALETTE_BLOCKED" end
	if entry == active and not releasing then return held and "HELD" or "ACQUIRING" end
	if os.clock() < entry.retryAt then return entry.unreachable and "TEMP_UNREACHABLE" or "COOLDOWN" end
	return "READY"
end


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
	adapter.relativeFn = type(mousemoverel) == "function" and mousemoverel or nil
	adapter.absoluteFn = type(mousemoveabs) == "function" and mousemoveabs or nil
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
local function correctDuringHold(entry, now, transition)
	if not painting or entry ~= active or not held or releasing or (entry.holdCorrected and not transition) or mouse.Target ~= entry.part then return end
	entry.holdCorrected = true; entry.noEffect = 0
	telemetry.SuccessfulCorrections += 1
	local key = math.floor(now * 2) % 10 + 1
	local bin = correctionBins[key]
	local at = math.floor(now * 2) / 2
	if not bin or bin.at ~= at then bin = { at = at, count = 0 }; correctionBins[key] = bin end
	bin.count += 1
end
local function canGrace(entry, now)
	return contestHold and painting and not testing and entry == active and held and not releasing
		and entry.contests * math.exp(-(now - entry.contestAt) / CONFIG.ContestDecay) >= 3
		and (#dirty == 0 or (#dirty == 1 and dirty[1] == entry)) and mouse.Target == entry.part
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
	record("Release", now - releaseAt)
	nextPressAt = math.max(nextPressAt, (lastUpAt or now) + effectiveGap())
	if not painting then pauseRuntime() end
	if downSeen>pressBaseline then reliability.verifiedCycles += 1 end
	releasing, held, releaseFault = false, false, false
	active, acq = nil, nil
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
	if active and active.active and not releasing then
		active.waitSince = os.clock()
		if held then
			record("Hold", os.clock() - stateAt); lastHoldEnd = os.clock()
			if not testing and not active.holdCorrected and downSeen > pressBaseline and mouse.Target == active.part
				and reason == "Dwell complete" then
				telemetry.NoEffectHolds += 1; active.noEffect = math.min(4, (active.noEffect or 0) + 1)
				local backoff = active.noEffect == 1 and 0.08 or active.noEffect == 2 and 0.15 or 0.30
				active.retryAt = os.clock() + backoff
			elseif active.part.Color == desired(active) then active.retryAt = 0
			else active.retryAt = math.max(active.retryAt, os.clock() + timing.AimRetry) end
		end
	end
	graceUntil = nil
	status = reason or status
	if held or releasing then
		if not releasing then
			releasing, releaseAt, releaseBaseline = true, os.clock(), upSeen
			releaseAttempts = 0
		end
		state = "RELEASING"
		if inputBusy then releaseRequested=true;presentation();return end
		if releaseAttempts < 3 and (held or releaseFault) then
			releaseAttempts += 1
			-- Reserve release state before entering an external API. No cursor/camera
			-- or target-color changes are made until button-up has been observed.
			local ok = adapter.release and nativeCall(adapter.release)
			holdUps += 1
			if ok then held, releaseFault = false, false
			else releaseFault = true; inputErrors += 1; painting = false;pauseRuntime() end
		end
	else
		active, acq = nil, nil
		if testing then testing, tested = false, false; testMessage = "FAILED: " .. testMessage end
		state = painting and "IDLE" or "OFF"
	end
	presentation()
end
stop = function(reason)
	painting = false
	pauseRuntime()
	prepared, wakeEntry, calibrationOnly = nil, nil, false
	if testing then testSucceeded = false; testMessage = reason end
	release(reason or "Emergency stop")
	lastHoldEnd,lastUpAt=nil,nil
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
		if not matched and entry.matched then
			entry.contests = math.min(10, entry.contests * math.exp(-(now - entry.contestAt) / CONFIG.ContestDecay) + 1)
			entry.contestAt = now
		end
	end
	if entry.committed then
		if matched then
			entry.noEffect=0
			if not entry.unreachable then entry.retryAt=0 end
			if changed and not entry.matched then observed += 1; correctDuringHold(entry, now, true) end
			removeDirty(entry)
		else
			addDirty(entry, now)
			if changed and not active and not releasing then wakeEntry = entry end
		end
	end
	local blocked = entry.committed and not matched and desired(entry) ~= desiredGlobalColor
	if blocked ~= (entry.paletteBlocked == true) then paletteBlocked += blocked and 1 or -1 end
	entry.paletteBlocked = blocked
	entry.matched = matched
	if entry.box then entry.box.Color3 = desired(entry) end
	if active == entry and matched and not testing and not releasing then
		if canGrace(entry, now) then
			graceUntil = graceUntil or math.min(stateAt + holdLimit, now + math.min(CONFIG.ContestGrace, CONFIG.ContestGraceMax))
		else release("Target color observed") end
	end
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
	if prepared == entry then prepared = nil end
	if wakeEntry == entry then wakeEntry = nil end
	entry.part, entry.box, entry.points, entry.offsets = nil, nil, nil, nil
end
function api.AddProvince(part)
	if not alive or not valid(part) or lookup[part] then return false end
	nextId += 1
	local box = make("SelectionBox", ui, { Name = "ProtectedProvince", Adornee = part,
		Color3 = paletteColor(), SurfaceTransparency = 1, LineThickness = 0.025 })
	local entry = { active = true, part = part, savedColor = paletteColor(), committed = false, box = box,
		id = nextId, index = #entries + 1, connections = {}, contests = 0, contestAt = os.clock(),
		changedAt = -math.huge, retryAt = 0, failStreak = 0, noEffect = 0, nextPose = 1, matched = part.Color == desiredGlobalColor }
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
function api.SetContestHold(value)
	contestHold = value == true or value == "SMART"
	if not contestHold and active and active.matched and held then release("Contest Hold disabled") end
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
	dwell = math.clamp(value, 0.15, timing.MaxDwell)
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
-- Bounded adaptive surface solver. Geometry is cached; projection and occlusion are not assumed.
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
local rayCharacter = nil
local function geometry(entry)
	local part = entry.part
	if entry.pointFrame == part.CFrame and entry.pointSize == part.Size then return end
	entry.pointFrame, entry.pointSize = part.CFrame, part.Size
	entry.points, entry.offsets, entry.searchIndex, entry.searchRemaining = {}, {}, 1, nil
	entry.searchOrder,entry.orderFor=nil,nil
	entry.LastGoodOffsetIndex, entry.LastGoodLocalPoint = nil, nil
	entry.LastGoodWorldPoint,entry.LastGoodScreenPoint,entry.LastGoodCameraCFrame=nil,nil,nil
	entry.exhaustedCamera, entry.nextPose = nil, 1
	local size, seen = part.Size, {}
	local function add(x,y,z)
		local key = string.format("%.3f/%.3f/%.3f",x,y,z)
		if seen[key] or #entry.points >= CONFIG.MaxSurfacePoints then return end
		seen[key] = true
		local offset = Vector3.new(x*size.X,y*size.Y,z*size.Z)
		table.insert(entry.offsets,offset)
		table.insert(entry.points,part.CFrame:PointToWorldSpace(offset))
	end
	add(0,0,0); add(0,0.49,0)
	for _,v in ipairs({-0.46,0.46}) do add(v,0.49,0); add(0,0.49,v); add(v,0,0); add(0,0,v) end
	for _,x in ipairs({-0.46,0.46}) do for _,z in ipairs({-0.46,0.46}) do add(x,0.49,z) end end
	local nx = math.clamp(math.ceil(size.X/20),2,7)
	local nz = math.clamp(math.ceil(size.Z/20),2,7)
	-- Thin/elongated shapes get more samples along their major axis, capped at 64 total.
	for ix=0,nx do for iz=0,nz do add(-0.46+0.92*ix/nx,0.49,-0.46+0.92*iz/nz) end end
end
local function pointProbe(entry,index,cheap)
	if projectionBudget < 2 then return nil,true end
	projectionBudget -= 2; telemetry.Projections += 2
	local camera, worldPoint = Workspace.CurrentCamera, entry.points[index]
	local point,onScreen = camera:WorldToViewportPoint(worldPoint)
	local screen=camera:WorldToScreenPoint(worldPoint)
	local probe = { index=index, point=point, screen=screen, onScreen=onScreen, world=worldPoint, gui=false }
	entry.probe = probe
	local size = camera.ViewportSize
	if not onScreen or point.Z <= 0 or point.X < 1 or point.Y < 1 or point.X >= size.X-1 or point.Y >= size.Y-1 then return nil end
	if cheap then return point end
	probe.gui = not unobstructedGUI(point)
	if probe.gui then return nil end
	if rayBudget <= 0 then return nil,true end
	rayBudget -= 1; telemetry.Raycasts += 1
	local ray = camera:ViewportPointToRay(point.X,point.Y)
	local hit = Workspace:Raycast(ray.Origin,ray.Direction * math.max(1,(worldPoint-ray.Origin).Magnitude+10),rayParams)
	probe.hit = hit and hit.Instance
	if probe.hit ~= entry.part then return nil end
	entry.candidateIndex = index
	return point
end
local function targetPoint(entry,cheap)
	if not Workspace.CurrentCamera or not entry.active or not valid(entry.part) then return nil end
	if rayCharacter ~= character then rayCharacter=character;rayParams.FilterDescendantsInstances=character and {character} or {} end
	geometry(entry)
	if cheap then
		for i=1,math.min(5,#entry.points) do
			local index=i==1 and entry.LastGoodOffsetIndex or i
			local point,exhausted=pointProbe(entry,index or i,true)
			if point or exhausted then return point,exhausted end
		end
		return nil
	end
	if not entry.searchRemaining then
		entry.searchRemaining=#entry.points;entry.searchStep=1
		local good=entry.LastGoodOffsetIndex
		if good and entry.orderFor~=good then
			entry.searchOrder={}
			for i=1,#entry.points do entry.searchOrder[i]=i end
			local origin=entry.offsets[good]
			table.sort(entry.searchOrder,function(a,b)
				local da=(entry.offsets[a]-origin).Magnitude;local db=(entry.offsets[b]-origin).Magnitude
				return da<db or (da==db and a<b)
			end)
			entry.orderFor=good
		elseif not good then entry.searchOrder,entry.orderFor=nil,nil end
		entry.searchIndex=entry.searchOrder and entry.searchOrder[1] or entry.searchIndex or 1
	end
	while entry.searchRemaining>0 do
		local index=entry.searchIndex
		local point,exhausted=pointProbe(entry,index,false)
		if exhausted then return nil,true end
		if point then
			entry.searchRemaining=nil
			if index==entry.LastGoodOffsetIndex then telemetry.CachedPointHits+=1 end
			return point
		end
		entry.searchRemaining-=1;entry.searchStep+=1
		entry.searchIndex=entry.searchOrder and entry.searchOrder[entry.searchStep] or index%#entry.points+1
	end
	entry.searchRemaining=nil;entry.searchIndex=1
	return nil
end
local function fullPath(object)
	if not object then return "<none>" end
	local ok,name=pcall(function() return object:GetFullName() end)
	return ok and name or "<unavailable>"
end
local function captureProbe(entry,reason,now)
	local probe=entry.probe or {}
	return {Target=fullPath(entry.part),Reason=reason,Size=entry.part.Size,PartCFrame=entry.part.CFrame,
		CameraCFrame=Workspace.CurrentCamera and Workspace.CurrentCamera.CFrame,PoseStage=acq and acq.stage or 0,
		CandidatePointIndex=probe.index,ProjectedOnScreen=probe.onScreen,RaycastHit=fullPath(probe.hit),
		RealMouseTarget=fullPath(mouse.Target),ActualMouseLocation=Input:GetMouseLocation(),
		ProjectedViewportPoint=probe.point,ProjectedScreenPoint=probe.screen,GuiInset=GuiService:GetGuiInset(),
		MoveMode=acq and acq.trial or moveMode,GUIBlocked=probe.gui,AttemptDuration=now-(acq and acq.started or now)}
end
local function formatProbe(p)
	if type(p)=="string" then return p end
	return table.concat({
		"Target="..p.Target.." Reason="..p.Reason,
		"Part.Size="..tostring(p.Size).." Part.CFrame="..tostring(p.PartCFrame),
		"CameraCFrame="..tostring(p.CameraCFrame).." PoseStage="..p.PoseStage,
		"CandidatePointIndex="..tostring(p.CandidatePointIndex).." ProjectedOnScreen="..tostring(p.ProjectedOnScreen),
		"RaycastHit="..p.RaycastHit.." RaycastHitFullName="..p.RaycastHit,
		"RealMouseTarget="..p.RealMouseTarget.." ActualMouseLocation="..tostring(p.ActualMouseLocation),
		"ProjectedViewportPoint="..tostring(p.ProjectedViewportPoint).." ProjectedScreenPoint="..tostring(p.ProjectedScreenPoint),
		"GuiInset="..tostring(p.GuiInset).." MoveMode="..p.MoveMode.." GUIBlocked="..tostring(p.GUIBlocked),
		"AttemptDuration="..string.format("%.3f",p.AttemptDuration),
	},"\n")
end
local function acquisitionFailed(reason,now)
	local entry=active
	if not entry then return end
	telemetry.AimFailures += 1
	if #failures >= CONFIG.FailureHistory then table.remove(failures,1) end
	table.insert(failures,formatProbe(captureProbe(entry,reason,now)))
	entry.failStreak=math.min(5,entry.failStreak+1); entry.unreachable=true
	entry.retryAt=now+math.min(CONFIG.UnreachableMaxRetry,timing.UnreachableRetry*2^(entry.failStreak-1))
	if acq and acq.stage>=5 then entry.exhaustedCamera=Workspace.CurrentCamera.CFrame end
	if testing then testMessage=reason; stop(reason) else release(reason) end
end
local function cameraPose(entry,now)
	local camera=Workspace.CurrentCamera
	if not camera or not cameraAutomation or visibleOnly or testing or not paintable(entry) then return false end
	if now-lastCameraAt < timing.CameraPoseMinInterval then return nil end
	if acq.stage==0 and lastCameraTarget~=entry.id and entry~=priority
		and now-entry.waitSince<CONFIG.AgingSeconds and now-lastCameraAt<CONFIG.ViewResidence then return nil end
	if acq.stage>=5 then return false end
	if entry.exhaustedCamera==camera.CFrame then return false end
	if not cameraSnapshot then cameraSnapshot={object=camera,cframe=camera.CFrame,kind=camera.CameraType,focus=camera.Focus} end
	if cameraSnapshot.object~=camera then return false end
	local stage=acq.stage==0 and entry.nextPose or acq.stage+1
	if stage>5 then return false end
	local center,size=entry.part.Position,entry.part.Size
	local fov=math.rad(camera.FieldOfView or 70)
	local aspect=math.max(0.25,camera.ViewportSize.X/math.max(1,camera.ViewportSize.Y))
	local distance=math.clamp(math.max(size.Z,size.X/aspect)*0.65/math.tan(fov/2),CONFIG.CameraMinDistance,CONFIG.CameraMaxDistance)
	local base=acq.origin.Position
	local delta=base-center
	local direction=delta.Magnitude>1 and delta.Unit or Vector3.new(0,1,0.2).Unit
	local position
	if stage==1 then position=base
	elseif stage==2 then position=base+direction*math.min(distance*0.25,40)+Vector3.new(0,distance*0.15,0)
	elseif stage==3 then position=center+direction*distance+Vector3.new(0,distance*0.6,0)
	elseif stage==4 then position=center+Vector3.new(0,distance,distance*0.06)
	else position=center+Vector3.new(distance*0.65,distance*0.8,distance*0.35) end
	if (position-center).Magnitude<1 then position=center+Vector3.new(0,distance,1) end
	camera.CameraType=Enum.CameraType.Scriptable
	camera.CFrame=CFrame.lookAt(position,center); camera.Focus=CFrame.new(center)
	lastCameraAt=now;lastCameraTarget=entry.id;telemetry.CameraPoseChanges+=1
	acq.stage=stage; entry.nextPose=math.min(5,stage+1)
	acq.settleUntil=now+timing.CameraSettleSeconds; acq.poseFrame=renderId
	acq.poseAt=now; acq.point=nil; acq.movedFrame=nil; acq.movedAt=nil
	entry.searchIndex=1; entry.searchRemaining=nil; state="CAMERA_SETTLE"; stableFrames=0
	return true
end
local function older(a,b) return not b or a.waitSince<b.waitSince or (a.waitSince==b.waitSince and a.id<b.id) end
local function ready(entry,now,exclude)
	if entry and entry.active and entry.committed and valid(entry.part) and entry.part.Color==desired(entry) then evaluate(entry,false) end
	return entry~=exclude and paintable(entry) and now>=entry.retryAt
end
local function chooseSmall(now,exclude)
	telemetry.TinySelections+=1
	if #dirty==1 then
		decision=nil
		local entry=dirty[1]
		if ready(entry,now,exclude) and (not visibleOnly or targetPoint(entry,true)) then return entry,true end
		return nil,true
	end
	if not decision or not decision.small or decision.exclude~=exclude then
		decision={small=true,a=dirty[1],b=dirty[2],c=dirty[3],index=1,exclude=exclude,distance=math.huge,alignment=-math.huge}
	end
	local d=decision
	while d.index<=3 do
		local entry=d.index==1 and d.a or d.index==2 and d.b or d.c
		if ready(entry,now,exclude) then
			local point,exhausted=targetPoint(entry,false)
			if exhausted then return nil,false end
			if point then
				if entry==priority then d.priority=entry end
				if now-entry.waitSince>=CONFIG.AgingSeconds and older(entry,d.oldest) then d.oldest=entry end
				local cursor=Input:GetMouseLocation()
				local distance=(point.X-cursor.X)^2+(point.Y-cursor.Y)^2
				if distance<d.distance or (distance==d.distance and older(entry,d.best)) then d.best,d.distance=entry,distance end
			elseif cameraAutomation and not visibleOnly then
				if entry==priority then d.priority=entry end
				if now-entry.waitSince>=CONFIG.AgingSeconds and older(entry,d.oldHidden) then d.oldHidden=entry end
				local delta=entry.part.Position-Workspace.CurrentCamera.CFrame.Position
				local alignment=delta.Magnitude>0 and Workspace.CurrentCamera.CFrame.LookVector:Dot(delta.Unit) or 1
				if alignment>d.alignment or (alignment==d.alignment and older(entry,d.hidden)) then d.hidden,d.alignment=entry,alignment end
			end
		end
		d.index+=1
	end
	decision=nil
	if d.oldHidden and visibleVisits>=CONFIG.VisibleVisitsBeforeAgedOffscreen then
		visibleVisits=0;return d.oldHidden,true
	end
	if d.best or d.priority then visibleVisits+=1;return d.oldest or d.priority or d.best,true end
	return d.hidden,true
end
local function choose(now,exclude)
	if #dirty<=3 then return chooseSmall(now,exclude) end
	if not decision or decision.small or decision.exclude~=exclude then
		telemetry.SchedulerScans+=1
		decision={index=1,snapshot=table.clone(dirty),exclude=exclude,distance=math.huge,alignment=-math.huge,camera=Workspace.CurrentCamera}
	end
	local pick=decision
	if pick.camera~=Workspace.CurrentCamera then decision=nil;return nil,false end
	for _=1,timing.CandidatesPerFrame do
		if pick.index>#pick.snapshot then break end
		local entry=pick.snapshot[pick.index]
		if entry.active and not valid(entry.part) then removeEntry(entry) end
		if ready(entry,now,exclude) then
			local point,exhausted=targetPoint(entry,false)
			if exhausted then return nil,false end
			local aged=now-entry.waitSince>=CONFIG.AgingSeconds
			if point then
				if entry==priority then pick.priority=entry end
				if aged and older(entry,pick.oldVisible) then pick.oldVisible=entry end
				local cursor=Input:GetMouseLocation()
				local distance=(point.X-cursor.X)^2+(point.Y-cursor.Y)^2
				if distance<pick.distance or (distance==pick.distance and older(entry,pick.visible)) then pick.visible,pick.distance=entry,distance end
			elseif cameraAutomation and not visibleOnly then
				if entry==priority then pick.priority=entry end
				if aged and older(entry,pick.oldHidden) then pick.oldHidden=entry end
				local delta=entry.part.Position-pick.camera.CFrame.Position
				local alignment=delta.Magnitude>0 and pick.camera.CFrame.LookVector:Dot(delta.Unit) or 1
				if alignment>pick.alignment or (alignment==pick.alignment and older(entry,pick.hidden)) then pick.hidden,pick.alignment=entry,alignment end
			end
		elseif entry.active and entry.committed and entry.part.Color==desired(entry) then evaluate(entry,false) end
		pick.index+=1
	end
	if pick.index<=#pick.snapshot then return nil,false end
	decision=nil
	local candidate=pick.oldVisible or pick.priority or pick.visible
	if pick.oldHidden and (not candidate or visibleVisits>=CONFIG.VisibleVisitsBeforeAgedOffscreen) then candidate,visibleVisits=pick.oldHidden,0
	elseif candidate then visibleVisits+=1
	else candidate,visibleVisits=pick.oldHidden or pick.hidden,0 end
	return candidate,true
end
local function trialList()
	local list={}
	local function add(mode)
		if mode=="Relative" and adapter.relativeFn and moveMode~="Absolute" then table.insert(list,"Relative") end
		if mode=="Absolute" and adapter.absoluteFn and moveMode~="Relative" then
			table.insert(list,"Absolute"..absoluteSpace)
			table.insert(list,absoluteSpace=="Viewport" and "AbsoluteScreen" or "AbsoluteViewport")
		end
	end
	add(preferredMove);add(preferredMove=="Relative" and "Absolute" or "Relative")
	return list
end
local function aim(entry,now)
	if not testing and not paintable(entry) then return false end
	active,state,stateAt=entry,"AIM_VISIBLE",now
	stableFrames,stableAt,lastCursor=0,now,-math.huge
	runColor=testing and paletteColor() or desired(entry)
	acq={started=now,origin=Workspace.CurrentCamera.CFrame,stage=0,poseAt=now,trials=trialList(),trialIndex=1,used={}}
	acq.trial=acq.trials[1]
	entry.searchIndex=1;entry.searchRemaining=nil;entry.unreachable=false
	telemetry.AimAttempts+=1
	if #dirty==1 then telemetry.TurboAcquisitions+=1 end
	if lastTargetId and lastTargetId~=entry.id then telemetry.TargetSwitches+=1 end
	lastTargetId=entry.id
	presentation();return true
end
local function modeName(trial) return trial=="Relative" and "Relative" or "Absolute" end
local function trialSuccess(now)
	if not acq.used[acq.trial] then return end
	local m=movementStats[modeName(acq.trial)]
	m.SuccessfulAcquisitions+=1; m.TotalTime+=now-acq.trialAt
	acq.used[acq.trial]=nil
	if acq.trial~="Relative" then absoluteSpace=acq.trial=="AbsoluteScreen" and "Screen" or "Viewport" end
	local best,score=preferredMove,-math.huge
	for name,stats in pairs(movementStats) do
		if stats.Attempts>0 then
			local value=stats.SuccessfulAcquisitions/stats.Attempts*1000-(stats.SuccessfulAcquisitions>0 and stats.TotalTime/stats.SuccessfulAcquisitions or 1)
			if value>score then best,score=name,value end
		end
	end
	preferredMove=best
end
local function nextTrial(now)
	if acq.trialIndex>=#acq.trials then return false end
	acq.trialIndex+=1;acq.trial=acq.trials[acq.trialIndex]
	acq.movedFrame,acq.movedAt,acq.point=nil,nil,nil
	stableFrames,stableAt=0,now
	return true
end
local function moveTo(point,now)
	local entry=active
	local screen=entry.probe.screen
	local trial=acq.trial
	if not acq.used[trial] then
		movementStats[modeName(trial)].Attempts+=1;acq.used[trial]=true;acq.trialAt=now
	end
	local cursor=Input:GetMouseLocation()
	local ok
	if trial=="Relative" then ok=nativeCall(adapter.relativeFn,math.round(point.X-cursor.X),math.round(point.Y-cursor.Y))
	else
		local destination=trial=="AbsoluteScreen" and screen or point
		ok=nativeCall(adapter.absoluteFn,math.round(destination.X),math.round(destination.Y))
	end
	if not alive or not active or releasing or not acq then return false end
	lastCursor,acq.movedAt,acq.movedFrame=now,now,renderId
	acq.point=point;state="TARGET_CONFIRM";stableFrames=0;stableAt=now
	calibrationResult=captureProbe(entry,"cursor observation (not a failure)",now)
	if not ok then
		inputErrors+=1
		if nextTrial(now) then state="AIM_VISIBLE"
		else acquisitionFailed("Native cursor APIs failed",now) end
		return false
	end
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
	local useAbsolute=moveMode=="Absolute" or (moveMode=="Auto" and preferredMove=="Absolute" and adapter.absoluteFn)
	local selected=useAbsolute and "mousemoveabs" or (adapter.relativeFn and "mousemoverel" or "mousemoveabs")
	return { Move = adapter.move and selected or "unavailable",
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
	runStarted = os.clock()
	layoutWindow()
	presentation(); return true
end
function api.TestNativeInput()
	rayBudget,projectionBudget=CONFIG.MaxRaysPerFrame,CONFIG.MaxProjectionsPerFrame
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
function api.GetPerformanceStats()
	local result=table.clone(telemetry)
	for _,name in ipairs({"Acquire","Hold","Release","Switch","DeadTime"}) do
		local avg,p95=metric(name);result["Average"..name.."Ms"]=avg;result["P95"..name.."Ms"]=p95
	end
	result.CorrectionsPerSecond=correctionsPerSecond();result.SuccessfulCorrectionsPerSecond=result.CorrectionsPerSecond
	result.Runtime=runtime+(runStarted and os.clock()-runStarted or 0)
	result.EffectiveReleaseGap=effectiveGap();result.VerifiedInputCycles=reliability.verifiedCycles
	result.ObservedDownMs=reliability.downLatency*1000;result.ObservedUpMs=reliability.upLatency*1000
	result.MoveVerificationSeconds=math.max(timing.MoveVerify,reliability.moveWait)
	result.RelativeMoveSuccess=movementStats.Relative.SuccessfulAcquisitions
	result.AbsoluteMoveSuccess=movementStats.Absolute.SuccessfulAcquisitions
	result.State=state;result.Target=active and fullPath(active.part) or "<none>"
	result.PoseStage=acq and acq.stage or 0;result.MoveMode=acq and acq.trial or preferredMove
	result.CandidatePoint=active and active.candidateIndex or nil
	result.RetryRemaining=active and math.max(0,active.retryAt-os.clock()) or (#dirty==1 and math.max(0,dirty[1].retryAt-os.clock()) or 0)
	result.UnreachableCount=0
	for _,entry in ipairs(dirty) do if entry.unreachable and os.clock()<entry.retryAt then result.UnreachableCount+=1 end end
	return result
end
function api.GetMovementStats()
	local result={Preferred=preferredMove,AbsoluteSpace=absoluteSpace,Calibration=formatProbe(calibrationResult)}
	for name,m in pairs(movementStats) do
		result[name]={Attempts=m.Attempts,SuccessfulAcquisitions=m.SuccessfulAcquisitions,SuccessRate=m.Attempts>0 and m.SuccessfulAcquisitions/m.Attempts or 0,
			AverageAcquireTime=m.SuccessfulAcquisitions>0 and m.TotalTime*1000/m.SuccessfulAcquisitions or 0}
	end
	return result
end
function api.GetTargetStats(part)
	local entry=lookup[part];if not entry then return nil end
	return {State=targetState(entry),RetryRemaining=math.max(0,entry.retryAt-os.clock()),FailStreak=entry.failStreak,
		NoEffectHold=entry.noEffect,SampleCount=entry.points and #entry.points or 0,
		LastGoodLocalPoint=entry.LastGoodLocalPoint,LastGoodWorldPoint=entry.LastGoodWorldPoint,
		LastGoodScreenPoint=entry.LastGoodScreenPoint,LastGoodOffsetIndex=entry.LastGoodOffsetIndex,
		LastGoodCameraCFrame=entry.LastGoodCameraCFrame,LastSuccessfulAcquireTime=entry.LastSuccessfulAcquireTime}
end
local function exportText(text,name)
	if type(setclipboard)=="function" and pcall(setclipboard,text) then return true end
	if type(writefile)=="function" and pcall(writefile,name,text) then return true end
	status="Clipboard/file export unavailable; use report API.";return false
end
function api.GetTargetFailureReport()
	return "AUTOPAINTER TARGET FAILURE REPORT\nAutoPainterRPCs=0\nLast "..#failures.." acquisition failures (max 20)\n\n"
		..table.concat(failures,"\n\n---\n\n").."\n\nCOORDINATE CALIBRATION\n"..formatProbe(calibrationResult)
end
function api.CopyTargetFailureReport() return exportText(api.GetTargetFailureReport(),"AutoPainterTargetFailures.txt") end
function api.ResetBenchmark()
	for key in pairs(telemetry) do telemetry[key]=0 end
	table.clear(measures);table.clear(correctionBins)
	runtime=0;runStarted=painting and os.clock() or nil;lastHoldEnd,lastUpAt=nil,nil
end
function api.GetBenchmarkReport()
	local m=api.GetPerformanceStats()
	return string.format("AUTOPAINTER BENCHMARK (observations, not server attribution)\nProtected=%d Corrections=%d Runtime=%.2fs Corrections/s=%.2f\nAvgAcquire=%.2fms P95Acquire=%.2fms AvgDeadTime=%.2fms P95DeadTime=%.2fms\nAvgHold=%.2fms AvgRelease=%.2fms AvgSwitch=%.2fms\nHoldAttempts=%d NoEffect=%d AimAttempts=%d AimFailures=%d CameraMoves=%d TargetSwitches=%d\nRaycasts=%d Projections=%d CachedPointHits=%d Unreachable=%d\nState=%s Target=%s PoseStage=%d MoveMode=%s RetryRemaining=%.3f\nAutoPainterRPCs=0 NativeRPCs=unobserved\nCorrections are desired-color transitions observed during a hold, not proof of causal ownership or server success.",
		#entries-pendingCount,m.SuccessfulCorrections,m.Runtime,m.CorrectionsPerSecond,
		m.AverageAcquireMs,m.P95AcquireMs,m.AverageDeadTimeMs,m.P95DeadTimeMs,m.AverageHoldMs,m.AverageReleaseMs,m.AverageSwitchMs,
		m.HoldAttempts,m.NoEffectHolds,m.AimAttempts,m.AimFailures,m.CameraPoseChanges,m.TargetSwitches,m.Raycasts,m.Projections,m.CachedPointHits,m.UnreachableCount,
		m.State,m.Target,m.PoseStage,m.MoveMode,m.RetryRemaining)
end
function api.CopyBenchmarkReport() return exportText(api.GetBenchmarkReport(),"AutoPainterBenchmark.txt") end
function api.CalibrateInput()
	if not alive or locked or painting or testing or held or releasing or selectionMode then return false end
	if not testTarget or not testTarget.active or not testTarget.committed or not capabilities() or not inputReady(true) then return false end
	rayBudget,projectionBudget=CONFIG.MaxRaysPerFrame,CONFIG.MaxProjectionsPerFrame
	if not targetPoint(testTarget,true) then return false end
	testing,calibrationOnly,collapsed=true,true,true
	layoutWindow();aim(testTarget,os.clock());status="Cursor-only calibration: both exposed modes; no button press."
	return true
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
		CameraAutomation = cameraAutomation, VisibleOnly = visibleOnly, Dwell = dwell, ContestHold = contestHold and "SMART" or "OFF", Performance = api.GetPerformanceStats() }
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
local function pressTarget(now)
	if not active or mouse.Target~=active.part or (not testing and not paintable(active)) then return end
	if Input:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) then stop("Mouse1 is already held by the user");return end
	if now<nextPressAt then state="PRESS";return end
	local entry=active
	local contest=entry.contests*math.exp(-(now-entry.contestAt)/CONFIG.ContestDecay)
	local tier=contest>=6 and 1 or contest>=3 and 0.7 or contest>=1 and 0.45 or dwell
	holdLimit=math.min(timing.MaxDwell,math.max(dwell,tier))
	if entry==priority then holdLimit=math.min(math.max(dwell,1),holdLimit*timing.PriorityDwellMultiplier) end
	record("Acquire",now-acq.started)
	if lastHoldEnd then record("DeadTime",now-lastHoldEnd);lastHoldEnd=nil end
	if lastUpAt then record("Switch",now-lastUpAt);lastUpAt=nil end
	entry.LastGoodOffsetIndex=entry.candidateIndex
	entry.LastGoodLocalPoint=entry.offsets[entry.candidateIndex]
	entry.LastGoodWorldPoint=entry.points[entry.candidateIndex]
	entry.LastGoodScreenPoint=acq.point or (entry.probe and entry.probe.point)
	entry.LastGoodCameraCFrame=Workspace.CurrentCamera.CFrame
	entry.LastSuccessfulAcquireTime=now
	entry.failStreak,entry.unreachable,entry.nextPose,entry.exhaustedCamera=0,false,1,nil
	entry.holdCorrected=false;graceUntil=nil
	held,state,stateAt,pressBaseline=true,"HOLD",now,downSeen
	holdDowns+=1;telemetry.HoldAttempts+=1
	local ok=nativeCall(adapter.press)
	if not ok then inputErrors+=1;tested=false;stop("Native mouse-down failed; releasing") end
end
local function acquireFrame(now)
	if not acq or not active then return end
	if now-acq.started>(calibrationOnly and 2 or timing.AimTimeout) then acquisitionFailed("Acquisition timeout",now);return end
	if state=="CAMERA_SETTLE" then
		if now<acq.settleUntil or renderId<=acq.poseFrame then return end
		state="AIM_AFTER_CAMERA"
	end
	if state=="CAMERA_MOVE" then
		local moved=cameraPose(active,now)
		if moved==false then acquisitionFailed("All settled camera/surface strategies failed",now) end
		return
	end
	local point,exhausted=targetPoint(active,false)
	if exhausted then return end
	if not point then
		-- A transient miss is not a reason to switch target or change pose immediately.
		acq.missSince=acq.missSince or now
		if now-acq.missSince<math.max(frameSeconds*2,timing.CameraSettleSeconds) then return end
		if testing then
			if now-acq.started>=timing.AimTimeout then acquisitionFailed("Visible surface unavailable",now) end
		elseif now-acq.poseAt>=timing.CameraPoseMinInterval then state="CAMERA_MOVE" end
		return
	end
	acq.missSince=nil
	local propagated=not acq.movedFrame or renderId>acq.movedFrame
	if mouse.Target==active.part and propagated and (not calibrationOnly or acq.movedAt) and unobstructedGUI(Input:GetMouseLocation()) then
		stableFrames+=1
		if stableFrames>=timing.TargetStableFrames and now-stableAt>=timing.TargetStableSeconds then
			trialSuccess(now)
			calibrationResult=captureProbe(active,"genuine target acquired",now)
			if calibrationOnly then
				if nextTrial(now) then state="AIM_VISIBLE";return end
				calibrationOnly=false;testing=false;active=nil;acq=nil;state="OFF"
				status="Cursor calibration finished; no button presses or RPCs. Run TEST NATIVE INPUT before Auto Paint."
				presentation();return
			end
			pressTarget(now);return
		end
	elseif propagated then stableFrames=0;stableAt=now end
	if acq.movedAt then
		-- Never resend while waiting for real mouse propagation: this was a source of oscillation.
		if not propagated or now-acq.movedAt<math.max(timing.MoveVerify,reliability.moveWait) then return end
		if nextTrial(now) then state="AIM_VISIBLE";return end
		if calibrationOnly then
			calibrationResult=captureProbe(active,"Final calibration variant did not acquire; compare per-mode successes",now)
			calibrationOnly,testing=false,false;active,acq=nil,nil;state="OFF"
			status="Calibration complete; compare observed mode success. Zero button presses.";presentation();return
		end
		-- Both input modes were given settled verification. Broaden geometry once before camera fallback.
		if not acq.broadened then
			acq.broadened=true;active.searchIndex=(active.candidateIndex or 1)%#active.points+1
			active.LastGoodOffsetIndex=nil;active.searchRemaining=nil;acq.movedAt=nil;acq.movedFrame=nil
			state="AIM_AFTER_CAMERA";return
		end
		reliability.moveWait=math.min(0.12,math.max(reliability.moveWait,timing.MoveVerify)+0.01)
		if testing then acquisitionFailed("Cursor modes did not acquire the genuine target",now)
		else state="CAMERA_MOVE" end
		return
	end
	if now-lastCursor>=timing.CursorInterval then moveTo(point,now) end
end
local function frame(now)
	rayBudget,projectionBudget=CONFIG.MaxRaysPerFrame,CONFIG.MaxProjectionsPerFrame
	if releasing then
		if releaseFault then
			if now-releaseAt>=releaseAttempts*0.1 and releaseAttempts<3 then release(status) end
			if releaseAttempts>=3 then status="Mouse release failed. Release Mouse1 manually; automation stopped." end
		elseif upSeen>releaseBaseline then
			-- Input/camera acquisition may resume on observed up; only the next DOWN waits for the safety gap.
			finishRelease(now)
		elseif now-releaseAt>CONFIG.InputEventTimeout then
			painting,tested,testSucceeded=false,false,false;pauseRuntime()
			reliability.gapFloor=math.min(0.15,math.max(0.05,reliability.gapFloor+0.01))
			testMessage="Native button-up was not observed. Release Mouse1 manually.";status=testMessage
		end
		if releasing then return end
	end
	if not painting and not testing then return end
	if locked or selectionMode then if active or held then release("Input suspended") end;return end
	if dragging or uiMouseDown or now<dragResumeAt then return end
	if not toolReady() then
		if testing then testMessage="PaintBucket or live character unavailable";stop(testMessage)
		else release("Waiting for equipped PaintBucket");if releasing then restoreAfterRelease=true else restoreCamera() end end
		return
	end
	if not inputReady() then stop("Input focus, menu or cursor lock changed");return end
	if not Workspace.CurrentCamera then stop("Camera unavailable");return end
	if cameraSnapshot and cameraSnapshot.object~=Workspace.CurrentCamera then stop("Camera replaced");return end
	if active and (not active.active or not active.committed or not valid(active.part)) then
		local invalid=active;release("Target unavailable")
		if invalid.active and not valid(invalid.part) then removeEntry(invalid) end
		return
	end
	if active and not testing and desired(active)~=runColor then release("Desired color changed");return end
	if active and paletteColor()~=runColor then stop("Normal palette changed during targeting");return end
	if active and not testing and not paintable(active) then
		if not (state=="HOLD" and canGrace(active,now) and graceUntil and now<graceUntil) then release("Target color observed");return end
	end
	if state=="IDLE" or state=="OFF" then
		if #dirty==0 then decision,prepared,wakeEntry=nil,nil,nil;lastHoldEnd,lastUpAt=nil,nil;status="All protected provinces match";return end
		local nextEntry,finished=nil,false
		if ready(prepared,now,nil) then nextEntry,finished=prepared,true
		elseif ready(wakeEntry,now,nil) and #dirty==1 then nextEntry,finished=wakeEntry,true
		elseif decision or #dirty<=3 or now-lastPick>=timing.IdleRetry then nextEntry,finished=choose(now,nil) end
		if finished then
			lastPick=now;prepared,wakeEntry=nil,nil
			if nextEntry then aim(nextEntry,now)
			elseif paletteBlocked>0 then status=tostring(paletteBlocked).." saved colors await matching palette" end
		end
	end
	if state=="HOLD" then
		if mouse.Target~=active.part then
			if testing then testSucceeded=false;testMessage="Real mouse target changed during hold" end
			release("Real mouse target lost");return
		end
		if downSeen<=pressBaseline and now-stateAt>=CONFIG.InputEventTimeout then
			painting,tested,testSucceeded=false,false,false;pauseRuntime();testMessage="Native mouse-down not observed"
			release(testMessage);return
		end
		local maximum=testing and CONFIG.TestHold or holdLimit
		local matched=active.part.Color==runColor
		if matched and not testing then correctDuringHold(active,now) end
		if matched and canGrace(active,now) then graceUntil=graceUntil or math.min(stateAt+maximum,now+CONFIG.ContestGrace) end
		local grace=matched and canGrace(active,now) and graceUntil and now<graceUntil
		if (matched and not grace) or now-stateAt>=maximum then
			if not testing and downSeen<=pressBaseline then
				painting,tested=false,false;pauseRuntime();testMessage="No native mouse-down event observed; automation stopped."
				reliability.gapFloor=math.max(0.05,reliability.gapFloor);release(testMessage);return
			end
			if testing then testSucceeded=downSeen>pressBaseline;if not testSucceeded then testMessage="No native button-down observed" end end
			release(testing and "Native input test releasing" or matched and "Target color observed" or "Dwell complete");return
		end
		-- Pure bounded precomputation: no input/camera change before observed button-up.
		if not testing and not prepared and #dirty>1 then
			local nextEntry,finished=choose(now,active)
			if finished then prepared=nextEntry end
		end
	elseif active then acquireFrame(now) end
end

do
local function createUI()
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
close = make("TextButton", main, { Text = "×", Size = UDim2.fromOffset(36, 32),
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
speedButton = button("Speed Mode: FAST", function() api.SetSpeedMode(speedMode == "ULTRA" and "FAST" or speedMode == "FAST" and "NORMAL" or "ULTRA") end)
order += 1
paletteLabel = make("TextLabel", scroll, { Name = "DesiredPaletteColor", LayoutOrder = order,
	Text = "Desired color: normal PaintBucket palette", Size = UDim2.new(1, -8, 0, 48),
	TextWrapped = true, TextSize = 14 })
keepButton = button("Keep Territory Color: OFF", function() api.SetKeepColor(not keepColor) end)
cameraButton = button("Camera Automation: ON", function() api.SetCameraAutomation(not cameraAutomation) end)
visibleButton = button("Visible Only: OFF", function() api.SetVisibleOnly(not visibleOnly) end)
button("Priority Target / Lock Province", function() setSelectionMode("Priority") end)
button("Clear Priority", function() api.SetPriority(nil) end)
button("Snap Left", function() windowX=0;layoutWindow() end)
button("Snap Right", function() windowX=Workspace.CurrentCamera.ViewportSize.X;layoutWindow() end)
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
button("CALIBRATE INPUT (cursor only)", function() api.CalibrateInput() end)
button("Copy Target Failure Report", function() api.CopyTargetFailureReport() end)
button("Copy Benchmark Report", function() api.CopyBenchmarkReport() end)
button("Reset Benchmark", function() api.ResetBenchmark() end)
order += 1
performanceLabel = make("TextLabel", scroll, { Name = "PerformanceTelemetry", LayoutOrder = order,
	Size = UDim2.new(1,-8,0,104), TextWrapped=true, TextSize=14, BackgroundTransparency=1,
	TextColor3=Color3.new(1,1,1) })
contestButton = button("Contest Hold: OFF", function() api.SetContestHold(not contestHold) end)
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

end
createUI()
end

updateUI = function()
	if not alive then return end
	layoutWindow()
	speedButton.Text = "Speed Mode: " .. speedMode
	contestButton.Text = "Contest Hold: " .. (contestHold and "SMART" or "OFF")
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
	local acquireMeasure,deadMeasure=measures.Acquire,measures.DeadTime
	local retry=active or (#dirty==1 and dirty[1])
	performanceLabel.Text=string.format("State: %s · Pose: %d · Retry: %.2fs\nAim: %d / failed: %d · No effect: %d\nAvg acquire: %.1fms · Avg dead: %.1fms\nCamera: %d · Rays: %d · Cached: %d · Move: %s",
		state,acq and acq.stage or 0,retry and math.max(0,retry.retryAt-os.clock()) or 0,
		telemetry.AimAttempts,telemetry.AimFailures,telemetry.NoEffectHolds,
		acquireMeasure and acquireMeasure.total*1000/acquireMeasure.count or 0,
		deadMeasure and deadMeasure.total*1000/deadMeasure.count or 0,
		telemetry.CameraPoseChanges,telemetry.Raycasts,telemetry.CachedPointHits,acq and acq.trial or preferredMove)
	statusLabel.Text = status
	countsLabel.Text = string.format("Protected: %d · Wrong Color: %d · Correct Color: %d · Pending: %d",
		#entries - pendingCount, #dirty, #entries - pendingCount - #dirty, pendingCount)
	hudLabel.Text = string.format("AUTO: %s · Protected: %d · Dirty: %d\nCurrent Target: %s · Corrections/s: %.1f",
		painting and "ON" or "OFF", #entries - pendingCount, #dirty, active and active.part and active.part.Name or "—", correctionsPerSecond())
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
connect(mouse.Button1Down, function()
	downSeen += 1
	if held and not releasing then reliability.downLatency = reliability.downLatency * 0.8 + (os.clock()-stateAt) * 0.2 end
end)
connect(mouse.Button1Up, function()
	upSeen += 1
	if releasing then
		if painting then lastUpAt = os.clock() end
		reliability.upLatency = reliability.upLatency * 0.8 + (os.clock()-releaseAt) * 0.2
	end
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
connect(RunService.RenderStepped, function(delta) renderId += 1; frameSeconds = math.clamp(delta, 1/240, 0.1) end)
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
