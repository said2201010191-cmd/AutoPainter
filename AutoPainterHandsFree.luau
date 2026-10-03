-- AutoPainter Hands Free v8.2 Cadence Follow-up
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
	assert(existing.GetStats().Build=="8.2-followup","Close the older Hands Free panel; v8.2 must load its recovery and palette binding state")
	assert(not existing.GetStats().Closed, "Previous activation release is unresolved; this controller cannot overlap it")
	return existing
end

local CFG = {
 OverloadDepth=12,OverloadExitDepth=4,OverloadQueueMs=750,OverloadExitQuiet=1.5,OverloadMinHold=2,
 HardEligibleAge=1.5,HotReattackWindow=0.25,HotWindow=2,HotRotationGap=0.10,CivilMicroBatch=4,
 DwellTrainingDiversity=4,HealthyReconcile=1.5,RepairReconcile=0.12,RepairReconcileHold=3,
 FocusStable=0.35,PaletteColorRetry=1.0,CameraClearance=8,CameraManualQuiet=1.0,CameraGlobalGap=2,CameraEntryGap=8,CameraFailureLimit=3,

	MaxConsecutiveEntryFailures = 3,
	EntryCooldowns = {0.25,0.40,0.65,1.0},
	EntryExtraDwellMax = 0.10,
	ActivationStrategy = "PER_TARGET", -- Native hold failed live; experimental ADAPTIVE/CONTINUOUS are explicit opt-in.
 NormalDownSpacingDefault = 0.226, -- User 40/40 native row P90 225.02 ms, rounded up; independent of dwell.
	TargetDwellDefault = 0.12,
	TargetDwellMin = 0.12,
	TargetDwellMax = 0.35,
	DwellHistory = 24,
	DwellMinSamples = 4,
	DwellMargin = 0.04,
	StrategyMinAttempts = 4,
	StrategyMaxProbeAttempts = 8,
 HoldProbeWindow = 0.24, HoldProbeMaxSeconds = 8, HoldMinimumTransferredSuccesses = 2,
 CombatActivityWindow = 1.0, NormalMissExtraDwellMax = 0,
	StrategyWindow = 16,
	StrategyReliabilityMargin = 0.20,
	StrategyThroughputMargin = 0.20,
	ShowDirtyState = true,
	LateConfirmation = 1.0,
	PaletteTimeout = 0.60,
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
local nextId = 0
local workerToken = 0
local currentEntry = nil
local normalTarget = nil
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

local function targetColor(entry)
	if mode=="CIVIL WAR" then return entry.civilColor end
	return normalTarget or paletteColor()
end
-- All semantic color decisions go through this matcher, including palette/dirty/results.
local v7: any = { RawMismatchButNormalizedMatch=0, ActualRGB="unavailable",TargetRGB="unavailable",DeltaRGB="unavailable",CleanSkippedBeforeCursor=0, CleanSkippedBeforeDown=0,
	CursorMovesToAlreadyCleanProvince=0,CursorMovesTriggeredByReconciliation=0,
	ReleasesSent=0,ReleasesObserved=0,ReleasesConfirmedByButtonState=0,ReleaseTimeouts=0,
	TargetSwitches=0,AtoBtoASequences=0,SamePairOscillations=0,OscillationStops=0,ServicesPreempted=0,
	OscillationDetected=false,FailedValidServices=0,PaletteFailures=0,LateCorrections=0,
	defense={},records={},switches={},lock=nil,previousIntended=nil,SuspectedStalePalette=false }
-- Bounded per-entry recovery; no extra wait on a healthy target.
local v82: any = {overload=false,attacks={},queue={},groups={},groupCount=0,ids={},misses={},batchCount=0,
 normalSamples={},civilSamples={},rejectedDwell={},startedAt=os.clock(),reconcileInterval=0.75,reconcileZero=0,
 data={OverloadEntries=0,OverloadExits=0,TimeInOverloadMs=0,PeakDirtyCount=0,PeakAttackRate=0,PeakQueueAge=0,
 AttemptsDeferredByOverload=0,HotTargetsDetected=0,HotTargetRotations=0,CoalescedDirtyEvents=0,SchedulerSelections=0,
 PathologicalGroupsDetected=0,GroupCooldowns=0,GroupCooldownMs=0,HealthyServicesCompletedWhileGroupDeferred=0,
 HealthyDwellSampleCount=0,DistinctDwellTrainingEntries=0,LookaheadChecks=0,
 TargetLostBeforePalette=0,TargetLostAfterPalette=0,TargetLostBeforeDown=0,TargetLostRecoveries=0,
 TargetLostQuarantines=0,TargetLostEventuallyRecovered=0},lookahead=nil}
v82.combat={FreshPenaltyResets=0,FreshGroupClears=0,ActiveCombatMisses=0,StaleMisses=0,
 CoalescedCombatChanges=0,NormalMissWindowMs=120,NativeHoldFallbacks=0}
local health: any = {InputState="IDLE",DuplicateDownStates=0,DuplicateUpStates=0,InputStateResyncs=0,
 SuccessfulInputResyncs=0,FailedInputResyncs=0,TargetQuarantines=0,CacheInvalidations=0,BadTargetRecoveries=0,
 InterruptedAttempts=0,ValidNoEffectAttempts=0,LongestConsecutiveSameEntryFailures=0,
 OscillationPrevented=0,PairCooldowns=0,DwellIncreaseReason="successful latency baseline",events={},lastOwnedAt=-math.huge}
function health.event(entry,reason,action,oldCache,cooldown,outcome)
 if #health.events>=20 then table.remove(health.events,1) end
 table.insert(health.events,{Entry=entry and entry.id or "input",At=os.clock(),Reason=reason,Action=action,
  OldCache=oldCache or "none",CooldownMs=(cooldown or 0)*1000,Outcome=outcome or "pending"})
end
function health.invalidate(entry,camera)
 local old=string.format("cursor=%s camera=%s",tostring(entry.lastScreen~=nil),tostring(entry.lastCamera~=nil))
 entry.lastScreen,entry.lastWorld,entry.lastFrame,entry.lastViewport,entry.lastIndex=nil,nil,nil,nil,nil
 entry.sampleCursor=1
 if camera then entry.pointFrame=nil;entry.surfacePoints=nil;entry.lastCamera=nil;cameraCache[entry.part]=nil end
 entry.CacheInvalidations=(entry.CacheInvalidations or 0)+1;health.CacheInvalidations+=1
 return old
end
function health.reset(entry,success)
 if success and (entry.ConsecutiveTargetLosses or 0)>0 then v82.data.TargetLostEventuallyRecovered+=1 end
 if success and (entry.ConsecutiveFailures or 0)>0 then
  entry.RecoverySuccesses=(entry.RecoverySuccesses or 0)+1;health.BadTargetRecoveries+=1
  health.event(entry,"SUCCESS","reset entry failure/backoff",nil,0,"recovered")
 end
 entry.ConsecutiveFailures,entry.ConsecutiveAcquireFailures,entry.ConsecutiveTargetLosses,entry.ConsecutiveValidNoEffects=0,0,0,0
 entry.ExtraDwell,entry.quarantineLevel,entry.retryAt,entry.failures=0,0,0,0
 entry.LastFailureReason=nil;entry.lastValidService=nil;entry.acquisitionFailures=0
 if success then health.sameEntry,health.sameFailures=nil,0 end
end
local function normalizedRGB(c)
	if typeof(c)~="Color3" then return nil end
	return math.clamp(math.round(c.R*255),0,255),math.clamp(math.round(c.G*255),0,255),math.clamp(math.round(c.B*255),0,255)
end
local function colorsMatch(actual,target)
	local ar,ag,ab=normalizedRGB(actual);local tr,tg,tb=normalizedRGB(target)
	if not ar or not tr then return false end
	local match=math.abs(ar-tr)<=1 and math.abs(ag-tg)<=1 and math.abs(ab-tb)<=1
	if match and (math.abs(actual.R-target.R)>1e-9 or math.abs(actual.G-target.G)>1e-9 or math.abs(actual.B-target.B)>1e-9) then
		v7.RawMismatchButNormalizedMatch+=1
	end
	return match
end
local function rgbText(c)
	local r,g,b=normalizedRGB(c);return r and string.format("%d,%d,%d",r,g,b) or "unavailable"
end
local function colorDelta(a,b)
	local ar,ag,ab=normalizedRGB(a);local br,bg,bb=normalizedRGB(b)
	return ar and br and string.format("%d,%d,%d",ar-br,ag-bg,ab-bb) or "unavailable"
end
local function entryLabel(entry)
	local p=entry.part.Position
	return string.format("Entry %d @ (%.2f,%.2f,%.2f)",entry.id,p.X,p.Y,p.Z)
end
local function shouldTarget(entry)
	return entry.active and entry.part.Parent and not colorsMatch(entry.part.Color,targetColor(entry))
end
local function colorKey(c)
	local r,g,b=normalizedRGB(c);return r and string.format("%02X%02X%02X",r,g,b) or "unassigned"
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
local benchmark: any = {active=false,state="SETUP",detail="Not started",rows={}}
local pacing: any = {interval=CFG.NormalDownSpacingDefault,source="USER_200MS_ROW_P90 (not minimum proven)",normal={},civil={}}
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
	mouse.Button1Down:Connect(function() downSeen += 1;downObservedAt=os.clock();if ownedInput and ownedInput.ReleaseSent then ownedInput.QuietSince=nil end end),
	mouse.Button1Up:Connect(function()
		upSeen += 1
		if ownedInput and not ownedInput.ReleaseSent and not UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) then ownedInput.ExternalUp=true end
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
				if ownedInput and not ownedInput.ReleaseSent and not UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) then ownedInput.ExternalUp=true end
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
		if owner.PaintMode and not benchmark.active and pacing.record then pacing.record(owner) end
	end
	if owner.MouseObserved and not owner.ReleaseSent then health.InputState="DOWN_CONFIRMED" end
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
	health.InputState="UP_SENT";health.lastOwnedAt=os.clock();health.lastMethod=owner.Method;health.lastTool=owner.Tool
	owner.Up, owner.EquippedUp, owner.ToolUp = upSeen, equippedUpSeen, toolUpSeen
	releaseAttempts += 1;v7.ReleasesSent+=1
	local ok, problem = callInput(owner.Method.Up)
	owner.ReleaseError = not ok
	if not ok and string.find(string.lower(tostring(problem)),"duplicate",1,true) then
		health.DuplicateUpStates+=1;owner.DuplicateUp=true
	end
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
	inputEvidence(owner)
	local readable,pressed=pcall(function() return UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) end)
	local observed=owner.MouseObserved and (upSeen>owner.Up or equippedUpSeen>owner.EquippedUp)
		or (not owner.MouseObserved and owner.ToolObserved and toolUpSeen>owner.ToolUp)
	if readable and pressed then owner.QuietSince=nil;return false end
	if observed then
		if not owner.ReleaseCounted then v7.ReleasesObserved+=1;owner.ReleaseCounted=true end
		return true
	end
	if readable and not pressed and (not owner.ReleaseError or owner.DownFailed or owner.ExternalUp or owner.DuplicateUp) then
		owner.QuietSince=owner.QuietSince or os.clock()
		if os.clock()-owner.QuietSince>=CFG.ActivationReleaseQuiet then
			if not owner.ReleaseCounted then v7.ReleasesConfirmedByButtonState+=1;owner.ReleaseCounted=true end
			return true
		end
	else owner.QuietSince=nil end
	return false
end
local function settleRelease()
	local owner = ownedInput
	if not owner then return not releaseBlocked end
	inputEvidence(owner)
	forceRelease()
	local deadline = os.clock() + CFG.ActivationReleaseTimeout
	while ownedInput == owner and os.clock() < deadline do
		if not inputBusy and releaseObserved(owner) then
			ownedInput, releaseBlocked = nil, false
			health.InputState="RELEASE_CONFIRMED"
			return true
		end
		RunService.Heartbeat:Wait()
	end
	if ownedInput~=owner then return not releaseBlocked end
	if not owner.TimeoutCounted then owner.TimeoutCounted=true;v7.ReleaseTimeouts+=1 end
	releaseBlocked = true;health.InputState="RECOVERING"
	activation.Status = "Release unconfirmed; stopped without testing another activation method"
	lastMessage = activation.Status
	return false
end
function health.resync(tool)
 health.InputState="RECOVERING";health.InputStateResyncs+=1
 if not ownedInput then
  if health.lastTool~=tool or os.clock()-health.lastOwnedAt>2 or not health.lastMethod then
   health.FailedInputResyncs+=1;health.event(nil,"INPUT_STATE_CONFLICT","external ownership; stopped",nil,0,"unowned")
   running=false;return false
  end
  ownedInput={Method=health.lastMethod,Tool=tool,Down=downSeen,EquippedDown=equippedDownSeen,ToolDown=toolDownSeen,Started=os.clock()}
 end
 local ok=settleRelease()
 if ok then health.SuccessfulInputResyncs+=1 else health.FailedInputResyncs+=1 end
 health.event(nil,"INPUT_STATE_CONFLICT","one controlled UP and release boundary",nil,0,ok and "recovered" or "unresolved")
 return ok
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
		if colorsMatch(entry.part.Color,target) then return "correct" end
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
		health.InputState="DOWN_SENT"
		pressAttempts += 1
		local ok, problem = callInput(method.Down)
		owner.DownFailed = not ok
		if not ok then inputErrors += 1 end
		local deadline = os.clock() + CFG.PaintTimeout
		local inputDeadline = os.clock() + CFG.InputVerify
		local confirmed, interrupted = false, false
		while ok and inputAllowed(entry, tool, token) and not owner.ReleaseSent do
			inputEvidence(owner)
			if not colorsMatch(entry.part.Color,owner.Before) then activation.ColorChanged = true end
			activation.TargetColorObserved = colorsMatch(entry.part.Color,target)
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

-- Native palette click sequence retained from live-proven v8; bindings are replaceable.
local palette: any = {controls={},byButton={},learning=nil,pending=nil,opener=nil,closer=nil,
 status="Native palette controls have not been learned",duplicates=0,invalidClicks=0,lastLearned="none",nextIndex=0,
 pool="ALL LEARNED",seed=nil,seedSupplied=false,closeRequired=false,transactions={},current={PaletteStep="IDLE"},
 metrics={PaletteSelections=0,PaletteSelectionSuccesses=0,PaletteSelectionFailures=0,PaletteSelectionTotal=0,
 OpenerUses=0,OpenerFailures=0,CloserUses=0,CloserFailures=0,PaletteSkipsAlreadyCorrect=0},
 resumeNeeded=false,compactHUD=false}
local PAL = {SettleFrames=1,ClickHold=0.025,RetrySettleFrames=2,RetryClickHold=0.04,Verify=0.16,MaxControls=512,MinDistinctDistance=38}
function palette.path(button)
 local segments={};local o=button
 while o and o~=playerGui do table.insert(segments,1,{Name=o.Name,ClassName=o.ClassName});o=o.Parent end
 return o==playerGui and segments or nil
end
function palette.signature(button)
 return {ClassName=button.ClassName,Name=button.Name,Text=button:IsA("TextButton") and button.Text or nil,
 Image=button:IsA("ImageButton") and button.Image or nil,BackgroundRGB=rgbText(button.BackgroundColor3)}
end
-- One index per real palette-root generation. Unchanged failures are cached, not polled.
palette.generationState="DETACHED";palette.snapshotSerial=0;palette.blocked=nil;palette.nativeExpected=0;palette.maintenanceAt=0;
palette.bindingGeneration=0;palette.roots={};palette.rootRecords={};palette.byKey={};palette.bindingReason="Initial binding"
palette.bindingMetrics={PaletteGuiGenerations=0,PaletteRebindAttempts=0,PaletteControlsRebound=0,PaletteRebindFailures=0,
 OpenerRebinds=0,CloserRebinds=0,GenerationBindingPasses=0,LazyColorRebinds=0,AmbiguousResolutionsSucceeded=0,
 AmbiguousResolutionsFailed=0,FullGuiScans=0,FullGuiTraversals=0,PersistedDisambiguationsRebound=0,PaletteBlockedEntries=0,PaletteBlockedDurationMs=0,PaletteBlockedRecoveries=0,SuppressedPaletteUnavailableRetries=0}
function palette.pathKey(segments)
 local keys={};for _,s in ipairs(segments or {}) do table.insert(keys,#s.ClassName..":"..s.ClassName..#s.Name..":"..s.Name) end
 return table.concat(keys,"/")
end
function palette.rootKey(item)
 local s=item.segments and item.segments[1];return s and (#s.ClassName..":"..s.ClassName..#s.Name..":"..s.Name) or nil
end
function palette.invalidateBindings(reason)
 palette.bindingReason=reason
 -- Focus/START is not a new GUI generation. Only a real structural event dirties indexes.
end
function palette.rootRecord(item)
 local key=palette.rootKey(item);if not key then return nil end
 local record=palette.rootRecords[key]
 if not record then record={segment=item.segments[1],rootDirty=true,revision=0,connections={},items={},index={}};palette.rootRecords[key]=record end
 record.items[item]=true;item.rootRecord=record
 return record
end
function palette.detachBinding(item)
 if item.button then palette.byButton[item.button]=nil end
 item.button=nil;item.candidates=nil;item.checkedRevision=nil;item.pendingVerification=false
end
function palette.dropRoot(record)
 for _,c in ipairs(record.connections) do c:Disconnect() end;record.connections={}
 for item in pairs(record.items) do palette.detachBinding(item);item.bindingState="DETACHED" end
 record.root=nil;record.index={};record.rootDirty=true
end
function palette.markRootChanged(object)
 for _,record in pairs(palette.rootRecords) do
  local segment=record.segment
  if object==record.root or (object.Name==segment.Name and object.ClassName==segment.ClassName) then
   if object==record.root and not object:IsDescendantOf(playerGui) then palette.dropRoot(record) end
   record.rootDirty=true
  end
 end
end
function palette.geometrySignature(button)
 local root=button
 while root.Parent and root.Parent~=playerGui do root=root.Parent end
 local parent=button.Parent;local sibling,order=0,0
 if parent then for i,child in ipairs(parent:GetChildren()) do
  if child.Name==button.Name and child.ClassName==button.ClassName then sibling+=1 end
  if child==button then order=i;break end
 end end
 local normalized
 local container=parent
 while container and container~=playerGui do
  local ok,size=pcall(function() return container.AbsoluteSize end)
  if ok and size and size.X>0 and size.Y>0 then
   local pos=container.AbsolutePosition;local center=button.AbsolutePosition+button.AbsoluteSize*0.5
   normalized={X=(center.X-pos.X)/size.X,Y=(center.Y-pos.Y)/size.Y};break
  end
  container=container.Parent
 end
 if not normalized then
  local camera=Workspace.CurrentCamera;local size=camera and camera.ViewportSize or Vector2.new(1,1);local center=button.AbsolutePosition+button.AbsoluteSize*0.5
  normalized={X=center.X/math.max(1,size.X),Y=center.Y/math.max(1,size.Y)};container=nil
 end
 return {ParentName=parent and parent.Name,ParentClass=parent and parent.ClassName,
  Region=container and container.Name or "VIEWPORT",RegionPath=container and palette.pathKey(palette.path(container)) or "VIEWPORT",Sibling=sibling,Order=order,Normalized=normalized,
  RootName=root.Name,BackgroundRGB=rgbText(button.BackgroundColor3)}
end
function palette.identityMatches(button,item)
 if not (button:IsA("TextButton") or button:IsA("ImageButton")) then return false end
 local signature=palette.signature(button)
 for _,key in ipairs({"ClassName","Name","Text","Image","BackgroundRGB"}) do if signature[key]~=item.signature[key] then return false end end
 return true
end
function palette.bind(item,button,record,verified)
 local old=item.button
 if old~=button then
  if old then palette.byButton[old]=nil end
  if (item.lastBoundGeneration or 0)>0 then palette.bindingMetrics.PaletteControlsRebound+=1 end
  if item==palette.opener then palette.bindingMetrics.OpenerRebinds+=1 end
  if item==palette.closer then palette.bindingMetrics.CloserRebinds+=1 end
 end
 item.button=button;item.path=button:GetFullName();item.bindingState=verified and "REBOUND" or "VERIFY_REQUIRED"
 item.pendingVerification=not verified;item.lastBoundGeneration=record.generation;item.bindingFailure=nil
 palette.byButton[button]=item;item.checkedRevision=record.revision
end
function palette.rememberNative(item)
 item.validated=true;item.semanticVerified=true
 item.geometry=palette.geometrySignature(item.button)
 item.nativeSignature={Region=item.geometry.Region,RegionPath=item.geometry.RegionPath,
  ParentName=item.geometry.ParentName,ParentClass=item.geometry.ParentClass,
  Normalized=item.geometry.Normalized,BackgroundRGB=item.geometry.BackgroundRGB}
 item.verifiedGeneration=item.rootRecord and item.rootRecord.generation or palette.bindingGeneration
end
function palette.sameNativeRegion(expected,actual)
 return expected and actual and expected.Region==actual.Region and expected.RegionPath==actual.RegionPath
  and expected.ParentName==actual.ParentName and expected.ParentClass==actual.ParentClass
  and expected.BackgroundRGB==actual.BackgroundRGB and expected.Normalized and actual.Normalized
  and math.abs(expected.Normalized.X-actual.Normalized.X)<0.001 and math.abs(expected.Normalized.Y-actual.Normalized.Y)<0.001
end
function palette.resolveIndexed(item,record)
 if item.invalid then item.bindingState="INVALID";return nil end
 if item.checkedRevision==record.revision then
  if item.button and not palette.identityMatches(item.button,item) then
   palette.byButton[item.button]=nil;item.button=nil;item.bindingState="SIGNATURE_MISMATCH";item.bindingFailure="Bound control signature changed"
   palette.bindingMetrics.PaletteRebindFailures+=1;item.pendingVerification=false
  end
  if not item.button and item.pendingVerification and (item.retryAfter or 0)<=os.clock() then
   for _,candidate in ipairs(item.candidates or {}) do
    if candidate.button:IsDescendantOf(playerGui) and palette.identityMatches(candidate.button,item) then
     palette.bind(item,candidate.button,record,false);break
    end
   end
  end
  return item.button
 end
 item.checkedRevision=record.revision;palette.bindingMetrics.PaletteRebindAttempts+=1
 if item.button then palette.byButton[item.button]=nil end
 item.candidateFailures={};item.candidates={};item.pendingVerification=false
 local raw=record.index[palette.pathKey(item.segments)] or {}
 item.candidateCount=#raw
 for _,button in ipairs(raw) do
  if palette.identityMatches(button,item) then
   local geo=palette.geometrySignature(button);local expected=item.geometry;local score=0
   if expected then
    if expected.ParentName==geo.ParentName and expected.ParentClass==geo.ParentClass then score+=8 end
    if expected.Region==geo.Region then score+=4 end
    if expected.Normalized and geo.Normalized then score-=math.abs(expected.Normalized.X-geo.Normalized.X)*8+math.abs(expected.Normalized.Y-geo.Normalized.Y)*8 end
    if expected.Sibling==geo.Sibling then score+=1 end
    if expected.Order==geo.Order then score+=0.5 end
   end
   table.insert(item.candidates,{button=button,score=score,order=geo.Order,geometry=geo})
  else table.insert(item.candidateFailures,button:GetFullName()..": class/name/text/image/visual RGB signature mismatch") end
 end
 table.sort(item.candidates,function(a,b) if a.score==b.score then return a.order<b.order end;return a.score>b.score end)
 if #item.candidates==0 then
  item.button=nil
  item.bindingState=#raw>0 and "SIGNATURE_MISMATCH" or "REBIND_PENDING"
  item.bindingFailure=#raw>0 and "No compatible native signature" or "Exact palette path unavailable"
  palette.bindingMetrics.PaletteRebindFailures+=1;return nil
 end
 -- A previously native-verified discriminator can identify exactly one equivalent
 -- control. Sibling/creation order is never proof; unresolved ties still need input.
 local equivalent=nil;local equivalents=0
 for _,candidate in ipairs(item.candidates) do
  if item.semanticVerified and palette.sameNativeRegion(item.nativeSignature,candidate.geometry) then equivalent=candidate;equivalents+=1 end
 end
 if equivalents==1 then
  palette.bind(item,equivalent.button,record,true);item.verifiedGeneration=record.generation
  palette.bindingMetrics.PersistedDisambiguationsRebound+=1;return item.button
 end
 local ambiguous=#item.candidates>1
 palette.bind(item,item.candidates[1].button,record,not ambiguous)
 if ambiguous then item.bindingFailure="Native candidate verification required" end
 return item.button
end
function palette.ensureRoot(record)
 if record.rootDirty then record.state="DETACHED" end
 if record.rootDirty then
  record.rootDirty=false
  local found=nil
  for _,child in ipairs(playerGui:GetChildren()) do
   if child.Name==record.segment.Name and child.ClassName==record.segment.ClassName then
    if found then palette.dropRoot(record);record.rootDirty=false;record.rootAmbiguous=true;return nil end
    found=child
   end
  end
  record.rootAmbiguous=false
  if found~=record.root then
   palette.dropRoot(record);record.rootDirty=false;record.root=found
   if found then
    palette.bindingGeneration+=1;palette.bindingMetrics.PaletteGuiGenerations=palette.bindingGeneration
    record.generation=palette.bindingGeneration;record.indexDirty=true;record.fullPassPending=true
    palette.bindingReason="New native palette root: "..found:GetFullName()
    local function changed(object)
     if object==found then record.rootDirty=true end
     record.indexDirty=true
     -- Rebuild at the next operation; many same-frame descendants coalesce into one pass.
    end
    table.insert(record.connections,found.DescendantAdded:Connect(changed))
    table.insert(record.connections,found.DescendantRemoving:Connect(changed))
    table.insert(record.connections,found.AncestryChanged:Connect(function() if not found:IsDescendantOf(playerGui) then palette.dropRoot(record) end end))
   end
  end
 end
 if not record.root then return nil end
 if not record.root:IsDescendantOf(playerGui) or record.root.Name~=record.segment.Name or record.root.ClassName~=record.segment.ClassName then palette.dropRoot(record);return nil end
 if record.indexDirty then
  record.state="INDEXING";record.indexDirty=false;record.revision+=1;record.index={}
  local objects=record.root:GetDescendants();table.insert(objects,1,record.root)
  palette.bindingMetrics.FullGuiTraversals+=1
  if record.fullPassPending then palette.bindingMetrics.GenerationBindingPasses+=1;record.fullPassPending=false end
  for _,o in ipairs(objects) do
   if o:IsA("TextButton") or o:IsA("ImageButton") then
    local key=palette.pathKey(palette.path(o));record.index[key]=record.index[key] or {};table.insert(record.index[key],o)
   end
  end
  palette.inspectCustomControls(objects)
  record.state="REBINDING";for item in pairs(record.items) do palette.resolveIndexed(item,record) end
 end
 return record.root
end
function palette.inspectCustomControls(objects)
 -- Inventory only. A generic TextBox/slider name is not proof of a supported color writer.
 palette.customCandidates=palette.customCandidates or {}
 for _,o in ipairs(objects) do
  local name=string.lower(o.Name)
  if (o:IsA("TextBox") or o:IsA("TextButton") or o:IsA("ImageButton") or o:IsA("Frame"))
   and (string.find(name,"rgb",1,true) or string.find(name,"hsv",1,true) or string.find(name,"hex",1,true) or string.find(name,"picker",1,true) or string.find(name,"slider",1,true)) then
   palette.customCandidates[o:GetFullName()]=o.ClassName
  end
 end
end
function palette.resolvePaletteControl(item)
 if not item then return nil end
 if item.invalid then palette.detachBinding(item);item.bindingState="INVALID";return nil end
 local record=palette.rootRecord(item)
 if not record or not palette.ensureRoot(record) then palette.detachBinding(item);item.bindingState="DETACHED";return nil end
 if item.button and item.checkedRevision==record.revision and item.button:IsDescendantOf(record.root) and palette.identityMatches(item.button,item) then return item.button end
 if item.checkedRevision~=record.revision then palette.bindingMetrics.LazyColorRebinds+=1 end
 return palette.resolveIndexed(item,record)
end
function palette.valid(item) return palette.resolvePaletteControl(item)~=nil end
function palette.rebindAll(reason)
 if reason then palette.bindingReason=reason end
 for _,item in ipairs(palette.controls) do palette.rootRecord(item) end
 if palette.opener then palette.rootRecord(palette.opener) end;if palette.closer then palette.rootRecord(palette.closer) end
 for _,record in pairs(palette.rootRecords) do palette.ensureRoot(record) end
 -- Layout can settle after DescendantAdded without creating a new generation.
 -- Reconsider only unresolved cached candidates; never rescan the GUI for this.
 for _,item in ipairs(palette.controls) do
  if item.pendingVerification and item.semanticVerified and item.nativeSignature then
   local match,count=nil,0
   for _,candidate in ipairs(item.candidates or {}) do
    if candidate.button:IsDescendantOf(playerGui) and palette.identityMatches(candidate.button,item)
     and palette.sameNativeRegion(item.nativeSignature,palette.geometrySignature(candidate.button)) then match=candidate.button;count+=1 end
   end
   if count==1 then palette.bind(item,match,item.rootRecord,true);item.verifiedGeneration=item.rootRecord.generation;palette.bindingMetrics.PersistedDisambiguationsRebound+=1 end
  end
 end
end
function palette.semanticAvailable()
 local result={};for _,item in ipairs(palette.controls) do if not item.invalid and item.color then table.insert(result,item) end end
 return result
end
function palette.generationStatus()
 local bound,pending,missing,verified=0,0,0,0
 for _,item in ipairs(palette.controls) do
  if item.semanticVerified or item.validated then verified+=1 end
  if item.button and item.button:IsDescendantOf(playerGui) and not item.invalid and not item.pendingVerification then bound+=1
  elseif item.pendingVerification then pending+=1 else missing+=1 end
 end
 palette.nativeExpected=math.max(palette.nativeExpected,verified)
 local expected=#palette.controls
 local state=bound==expected and expected>0 and "READY" or pending>0 and "VERIFYING_AMBIGUOUS" or "REBINDING"
 local attached=false;for _,record in pairs(palette.rootRecords) do if record.root then attached=true end end
 if not attached then state="DETACHED"
 elseif missing>0 then
  for _,item in ipairs(palette.controls) do if item.bindingState=="SIGNATURE_MISMATCH" or item.invalid then state="DEGRADED";break end end
 end
 palette.generationState=state
 return state,bound,pending,missing,verified
end
function palette.preflight()
 palette.rebindAll();local state,live,_,_,nativeVerified=palette.generationStatus()
 local known=#palette.controls;local verified=#palette.semanticAvailable();local selected=#entries
 local bound=0;for _,item in ipairs(palette.controls) do if item.button and item.button:IsDescendantOf(playerGui) and not item.pendingVerification then bound+=1 end end
 local shortage=math.max(0,selected-verified)
 return {PaletteGenerationState=state,NativeVerifiedThisSession=nativeVerified,CustomColorUIAvailable=palette.custom and palette.custom.state or "UNVERIFIED",GeneratedUniqueAssigned=0,TotalUniqueAssignmentCapacity=verified,CurrentlyBoundLiveControls=bound,SemanticKnownCapacity=known,VerifiedNativeCapacity=verified,GeneratedVerifiedCapacity=0,GeneratedColorCreation="PROVEN",GeneratedColorApplicationViaCurrentNativePath="UNVERIFIED",NativeApplicationCapacity=verified,GeneratedAdditionalRequired=shortage,SelectedCount=selected,Shortage=shortage,
  Message=string.format("Selected provinces: %d | Verified native unique learned colors: %d | Additional colors required: %d%s",selected,verified,shortage,
   shortage>0 and " | RGB generation is proven; applying the additional RGB colors through the native tool is unverified. Use fewer provinces until that application path is established." or " | Unique assignments available")}
end

function palette.topButton(point)
 -- AbsolutePosition/GetGuiObjectsAtPosition use inset viewport coordinates;
 -- VirtualInput/GetMouseLocation use full-window coordinates. Convert once here.
 local inset=GuiService:GetGuiInset()
 local ok,objects=pcall(function() return playerGui:GetGuiObjectsAtPosition(point.X-inset.X,point.Y-inset.Y) end)
 if not ok then return nil end
 local own=playerGui:FindFirstChild(GUI_NAME)
 for _,o in ipairs(objects) do
  if own and o:IsDescendantOf(own) and (o.Active or o:IsA("TextButton") or o:IsA("ImageButton")) then return nil,"CONTROLLER_UI" end
  if o:IsA("TextButton") or o:IsA("ImageButton") then return o end
  -- A decorative label may be a child of the actual button. A foreign active overlay blocks it.
  if o:IsA("GuiObject") and o.Active then return nil end
 end
 return nil
end
function palette.visible(button)
 if not button or not button:IsDescendantOf(playerGui) then return false end
 local o=button
 while o and o~=playerGui do
  if o:IsA("ScreenGui") and not o.Enabled then return false end
  if (o:IsA("GuiObject") or o:IsA("TextButton") or o:IsA("ImageButton") or o:IsA("Frame")) and o.Visible==false then return false end
  o=o.Parent
 end
 return button.AbsoluteSize.X>=4 and button.AbsoluteSize.Y>=4
end
function palette.center(item)
 if not palette.valid(item) or not palette.visible(item.button) then return nil,"Control detached/hidden; waiting for current native GUI" end
 if item.button.Active==false then return nil,"Native control is inactive" end
 local ok,interactive=pcall(function() return item.button.Interactable end)
 if ok and interactive==false then return nil,"Native control is not interactable" end
 local pos,size=item.button.AbsolutePosition,item.button.AbsoluteSize
 local point=pos+size*0.5+GuiService:GetGuiInset()
 local viewport=Workspace.CurrentCamera and Workspace.CurrentCamera.ViewportSize
 if not viewport or point.X<1 or point.Y<1 or point.X>=viewport.X or point.Y>=viewport.Y then return nil,"Control center is outside viewport; reveal/scroll native palette" end
 if palette.topButton(point)~=item.button then return nil,"Control center is obscured/clipped; exact top button did not match" end
 return point
end
function palette.capture(button,point)
 local localPoint=point-GuiService:GetGuiInset()-button.AbsolutePosition
 return {button=button,path=button:GetFullName(),segments=palette.path(button),signature=palette.signature(button),
 offset=localPoint,normalized=Vector2.new(localPoint.X/button.AbsoluteSize.X,localPoint.Y/button.AbsoluteSize.Y),
 geometry=palette.geometrySignature(button),size=button.AbsoluteSize,successes=0,failures=0,lastUse=nil,validated=true,
 bindingState="BOUND",lastBoundGeneration=palette.bindingGeneration}
end
function palette.learningStatus()
 return string.format("Learned: %d | Last: %s | Duplicates ignored: %d | Invalid clicks: %d",#palette.controls,palette.lastLearned,palette.duplicates,palette.invalidClicks)
end
function palette.anyVisible()
 for _,item in ipairs(palette.controls) do if item.button and palette.visible(item.button) then return true end end
 return false
end
function palette.observeChrome()
 local pending=palette.chromePending;if not pending then return end
 local now=palette.anyVisible()
 if now~=pending.before and now==(pending.role=="OPENER") then
  palette.rememberNative(pending.item);pending.item.transitionVerified=true;palette.chromePending=nil
 elseif os.clock()-pending.at>1 then palette.chromePending=nil end
end
function palette.onClick(point)
 if not palette.learning then return end
 local button,blocked=palette.topButton(point)
 if blocked=="CONTROLLER_UI" then return end
 if not button or not palette.visible(button) then palette.invalidClicks+=1;palette.status=palette.learningStatus();return end
 local item=palette.capture(button,point)
 if palette.learning=="OPENER" then
  local old=palette.opener;if old then if old.rootRecord then old.rootRecord.items[old]=nil end;if old.button then palette.byButton[old.button]=nil end end
  palette.chromePending={item=item,role="OPENER",before=palette.anyVisible(),at=os.clock()};palette.opener=item;palette.status="Opener learned; finish setup";palette.learning=nil;return end
 if palette.learning=="CLOSER" then
  local old=palette.closer;if old then if old.rootRecord then old.rootRecord.items[old]=nil end;if old.button then palette.byButton[old.button]=nil end end
  palette.chromePending={item=item,role="CLOSER",before=palette.anyVisible(),at=os.clock()};palette.closer=item;palette.status="Closer learned (only used when it blocks the target point)";palette.learning=nil;return end
 palette.pending={item=item,before=paletteColor(),at=os.clock()}
end
function palette.onColor()
 local pending=palette.pending
 if not palette.learning or not pending or os.clock()-pending.at>0.75 then return end
 local color=paletteColor();if colorsMatch(color,pending.before) then return end
 palette.pending=nil
 local item=pending.item;local existing=palette.byButton[item.button]
 if existing then
  if not colorsMatch(existing.color,color) then existing.invalid=true;palette.invalidClicks+=1
   palette.status="Dynamic color control detected; exact picker adapter/source required";return end
  existing.validated=true;palette.duplicates+=1;palette.status=palette.learningStatus();return
 end
 for _,known in ipairs(palette.controls) do
  if palette.valid(known) and colorsMatch(known.color,color) then palette.duplicates+=1;palette.status=palette.learningStatus();return end
 end
 if #palette.controls>=PAL.MaxControls then palette.status="Palette learning capacity reached (512)";return end
 local r,g,b=normalizedRGB(color);item.color=Color3.fromRGB(r,g,b);item.key=colorKey(item.color)
 palette.nextIndex+=1;item.index=palette.nextIndex
 palette.byButton[item.button]=item;palette.byKey[item.key]=item;table.insert(palette.controls,item)
 palette.rootRecord(item);palette.rememberNative(item)
 palette.lastLearned=item.button.Name.." ("..rgbText(item.color)..")";palette.status=palette.learningStatus()
end
function palette.find(color)
 local item=palette.byKey[colorKey(color)]
 if item and not item.invalid then return item end
 for _,known in ipairs(palette.controls) do if not known.invalid and colorsMatch(known.color,color) then return known end end
 return nil
end
function palette.prune() palette.rebindAll() end
function palette.available()
 palette.rebindAll();local out={}
 for _,item in ipairs(palette.controls) do
  if not item.invalid and item.button and item.button:IsDescendantOf(playerGui) and not item.pendingVerification and item.bindingState~="DETACHED" then table.insert(out,item) end
 end
 return out
end
function palette.distance(a,b)
 local ar,ag,ab=normalizedRGB(a);local br,bg,bb=normalizedRGB(b)
 return (ar-br)^2+(ag-bg)^2+(ab-bb)^2
end
function palette.rng(seed)
 local state=seed%2147483647;if state<=0 then state=1 end
 return function(n) state=(state*16807)%2147483647;return state%n+1 end
end
function palette.assign(reroll)
 palette.prune()
 local capacity=palette.preflight();if capacity.Shortage>0 then return false,capacity.Message end
 if capacity.PaletteGenerationState~="READY" then return false,"Palette rebinding — wait ("..capacity.CurrentlyBoundLiveControls.."/"..capacity.SemanticKnownCapacity..")" end
 local available=palette.semanticAvailable();local used,missing,chosen={}, {}, {}
 for _,entry in ipairs(entries) do
  if entry.civilColor and not reroll then
   local item=palette.find(entry.civilColor)
   if not item or used[item.key] then return false,"Existing Civil assignment temporarily unavailable or incompatible; restore native GUI and RESUME. Assignment retained." end
   entry.civilControl=item;used[item.key]=true;table.insert(chosen,item)
  else table.insert(missing,entry) end
 end
 local all,filtered={},{}
 for _,item in ipairs(available) do
  if not used[item.key] then
   table.insert(all,item)
   local r: any,g: any,b: any=normalizedRGB(item.color);assert(r and g and b,"Invalid learned RGB");local hi,lo=math.max(r,g,b),math.min(r,g,b)
   local light=(0.2126*r+0.7152*g+0.0722*b)/255
   if palette.pool=="ALL LEARNED" or palette.pool=="HIGH CONTRAST" or
    (palette.pool=="VIVID" and hi>=150 and hi-lo>=90) or (palette.pool=="DARK" and light<=0.35) or (palette.pool=="LIGHT" and light>=0.68) then table.insert(filtered,item) end
  end
 end
 if #all<#missing then return false,string.format("Civil capacity: %d unique learned colors; selected: %d. Reuse is disabled.",#available,#entries) end
 if #filtered<#missing then filtered=all;palette.poolFallback="Filtered pool too small; ALL LEARNED used" else palette.poolFallback="none" end
 if not palette.seed then palette.seed=math.random(1,2147483646) end
 local random=palette.rng(palette.seed)
 for i=#filtered,2,-1 do local j=random(i);filtered[i],filtered[j]=filtered[j],filtered[i] end
 local assignments={}
 for _,entry in ipairs(missing) do
  local best,bestDistance=1,-1
  for i,item in ipairs(filtered) do
   local distance=math.huge
   for _,other in ipairs(chosen) do distance=math.min(distance,palette.distance(item.color,other.color)) end
   if distance>bestDistance then best,bestDistance=i,distance end
   -- Random order is primary for ALL/filtered pools, with a best-effort contrast floor.
   if palette.pool~="HIGH CONTRAST" and distance>=PAL.MinDistinctDistance^2 then best=i;break end
  end
  local item=table.remove(filtered,best);table.insert(chosen,item);assignments[entry]=item
 end
 -- Atomic assignment; no input and no partial reroll on shortage.
 for entry,item in pairs(assignments) do entry.civilColor=item.color;entry.civilKey=item.key;entry.civilControl=item end
 return true
end
function palette.summary()
 local keys={};local assigned,duplicate=0,0
 for _,entry in ipairs(entries) do
  if entry.civilColor then assigned+=1;local key=colorKey(entry.civilColor);if keys[key] then duplicate+=1 end;keys[key]=true end
 end
 local unique=0;for _ in pairs(keys) do unique+=1 end
 local capacity=#palette.available();local detached,pending,mismatch,ambiguous=0,0,0,0
 for _,item in ipairs(palette.controls) do
  if item.pendingVerification then ambiguous+=1 end
  if item.bindingState=="DETACHED" then detached+=1 elseif item.bindingState=="REBIND_PENDING" then pending+=1 elseif item.bindingState=="SIGNATURE_MISMATCH" then mismatch+=1 end
 end
 local semantic=#palette.semanticAvailable()
 return {LearnedSemanticColors=#palette.controls,BoundNativeColors=capacity,AmbiguousColors=ambiguous,CurrentPaletteGeneration=palette.bindingGeneration,
  CivilNativeCapacity=semantic,ExpectedNativeCapacity=semantic,SemanticKnownCapacity=#palette.controls,VerifiedNativeCapacity=semantic,
  CurrentlyBoundLiveControls=capacity,GeneratedVerifiedCapacity=0,GeneratedColorCreation="PROVEN",GeneratedColorApplicationViaCurrentNativePath="UNVERIFIED",NativeApplicationCapacity=semantic,GeneratedAdditionalRequired=math.max(0,#entries-semantic),Shortage=math.max(0,#entries-semantic),SelectedCount=#entries,
  LivePaletteRoot=palette.anyVisible() and "OPEN" or "CLOSED",CustomColorUIAvailable=palette.custom and palette.custom.state or "UNVERIFIED",GeneratedColorsAssigned=0,
  BoundPaletteControls=capacity,DetachedPaletteControls=detached,RebindPending=pending,SignatureMismatches=mismatch,
 CivilCapacityStatus=capacity==0 and #palette.controls>0 and (detached+pending)>0 and "temporarily unavailable" or "available",CivilSelectedCount=#entries,UniqueAssignedCivilColors=unique,DuplicateAssignedCivilColors=duplicate,
 UnassignedCivilColors=#entries-assigned,LearnedPaletteColors=#palette.controls,CivilCapacity=capacity,CapacityAvailable=semantic>=#entries,
 CivilColorPool=palette.pool,ColorPoolFallback=palette.poolFallback or "none",CivilRandomSeed=palette.seed or "not assigned",PaletteStatus=palette.status}
end
function palette.snapshot(item)
 palette.rebindAll();palette.snapshotSerial+=1
 local roots={};for key,record in pairs(palette.rootRecords) do roots[key]={object=record.root,generation=record.generation,revision=record.revision} end
 return {id=palette.snapshotSerial,roots=roots,tool=activationTool,session=equippedGeneration,
  generation=palette.bindingGeneration,root=item and item.rootRecord and item.rootRecord.root,
  visible=palette.anyVisible(),swatchVisible=item and palette.visible(item.button) or false,
  binding=item and item.bindingState or "UNAVAILABLE",opener=palette.opener and palette.opener.bindingState or "UNLEARNED",closer=palette.closer and palette.closer.bindingState or "UNLEARNED",selected=rgbText(paletteColor())}
end
function palette.snapshotValid(snapshot)
 if not snapshot then return true end
 if snapshot.tool~=activationTool or snapshot.session~=equippedGeneration then return false end
 for key,saved in pairs(snapshot.roots) do local current=palette.rootRecords[key]
  if current and (current.rootDirty or current.indexDirty) then palette.ensureRoot(current) end
  if not current or current.root~=saved.object or current.generation~=saved.generation then return false end
 end
 return true
end
function palette.verifiedOpener()
 local item=palette.opener
 return item and palette.valid(item) and not item.pendingVerification and (item.transitionVerified or item.semanticVerified) and item
end
function palette.accessState()
 return {generation=palette.bindingGeneration,opener=palette.opener and palette.opener.button,visible=palette.anyVisible(),
  focused=focused,tool=activationTool,openerSuccess=palette.opener and palette.opener.successes or 0}
end
function palette.block(reason)
 if not palette.blocked then palette.blocked={at=os.clock(),reason=reason,state=palette.accessState()};palette.bindingMetrics.PaletteBlockedEntries+=1 end
 palette.status="PALETTE_BLOCKED: "..reason
end
function palette.canAccess(item)
 return item and (colorsMatch(paletteColor(),item.color) or
  (item.button and palette.visible(item.button)) or (palette.verifiedOpener() and palette.visible(palette.opener.button)))
end
function palette.refreshAccess()
 palette.rebindAll();palette.generationStatus()
 if palette.blocked then
  local accessible=false
  for _,item in ipairs(palette.controls) do
   if item.button and palette.visible(item.button) then accessible=true;break end
  end
  if palette.verifiedOpener() and palette.visible(palette.opener.button) then accessible=true end
  local now=palette.accessState();local changed=false
  for key,value in pairs(now) do if value~=palette.blocked.state[key] then changed=true;break end end
  if accessible and changed then
   palette.bindingMetrics.PaletteBlockedDurationMs+=(os.clock()-palette.blocked.at)*1000
   palette.bindingMetrics.PaletteBlockedRecoveries+=1;palette.blocked=nil
   for _,entry in ipairs(entries) do if entry.paletteBlocked then entry.paletteBlocked=nil;entry.retryAt=0 end end
  end
 end
end
function palette.allowed(token)
 return palette.snapshotValid(palette.activeSnapshot) and alive and running and workerToken==token and focused and activationTool and activationTool.Parent==player.Character
end
function palette.waitUntil(predicate,token,seconds)
 local deadline=os.clock()+seconds
 repeat
  if not palette.allowed(token) then return false end
  if predicate() then return true end
  RunService.Heartbeat:Wait()
 until os.clock()>=deadline
 return palette.allowed(token) and predicate()
end
function palette.click(item,token,step,successPredicate,intended)
 palette.resolvePaletteControl(item)
 local detail={Role=step,TargetControlName=item and item.signature.Name or "unavailable",TargetControlPath=item and item.path or "unavailable",
 TargetControlVisible=item and palette.visible(item.button) or false,CursorPositionBefore=tostring(UserInputService:GetMouseLocation()),
 VirtualInputMoveSucceeded=false,MouseDownSent=false,MouseUpSent=false,ActivatedObserved=false,AttributeChangedObserved=false,
 FailureReason="",Retry=0}
 table.insert(palette.current.Steps,detail)
 palette.current.PaletteStep=step;palette.current.Click=detail
 local lastError="No learned "..step.." control"
 if not palette.valid(item) then detail.FailureReason=lastError;return false,lastError end
 local activated,changed=false,false
 local activatedConnection=item.button.Activated:Connect(function() activated=true end)
 local colorConnection=player:GetAttributeChangedSignal("PaintBucketColor"):Connect(function() changed=true end)
 local ok,problem=pcall(function()
  for attempt=1,2 do
   detail.Retry=attempt-1;activated,changed=false,false
   if not palette.allowed(token) then error("Focus/tool/session lost; transaction canceled") end
   if palette.currentEntry and not shouldTarget(palette.currentEntry) then error("CLEAN_BEFORE_PALETTE_INPUT") end
   if not settleRelease() then error("Previous release unresolved") end
   if UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) then error("External Mouse1 held; no palette click") end
   local point,why=palette.center(item)
   if not point then lastError=why else
    detail.TargetControlPosition=tostring(item.button.AbsolutePosition);detail.TargetControlVisible=true
    local moved,moveError=callInput(function() virtualInput:SendMousePosition(point) end)
    detail.VirtualInputMoveSucceeded=moved
    if not moved then lastError="VirtualInput move rejected: "..tostring(moveError) else
     for _=1,(attempt==1 and PAL.SettleFrames or PAL.RetrySettleFrames) do RunService.RenderStepped:Wait() end
     if not palette.allowed(token) then error("Focus/tool/session lost after cursor move") end
     if palette.currentEntry and not shouldTarget(palette.currentEntry) then error("CLEAN_BEFORE_PALETTE_INPUT") end
     local cursor=UserInputService:GetMouseLocation();detail.CursorPositionAfter=tostring(cursor)
     local currentPoint=palette.center(item);local top=palette.topButton(cursor)
     detail.TopButtonAtClick=top and top:GetFullName() or "none"
     if not currentPoint or (currentPoint-point).Magnitude>1 or (cursor-point).Magnitude>2 or top~=item.button then
      lastError="Cursor/layout/top button changed before DOWN"
     else
      local owner={Method=primaryMethod,Tool=activationTool,Down=downSeen,EquippedDown=equippedDownSeen,ToolDown=toolDownSeen,Started=os.clock(),Kind="PALETTE"}
      ownedInput,held=owner,true;health.InputState="DOWN_SENT"
      local down,downError=callInput(function() virtualInput:SendMouseButton(point,Enum.UserInputType.MouseButton1,true,0) end)
      owner.DownFailed=not down;detail.MouseDownSent=down
      local holdEnd=os.clock()+(attempt==1 and PAL.ClickHold or PAL.RetryClickHold)
      while down and palette.allowed(token) and not owner.ReleaseSent and os.clock()<holdEnd do RunService.Heartbeat:Wait() end
      local released=settleRelease();detail.MouseUpSent=owner.ReleaseSent and not owner.ReleaseError
      if not released then error("Palette UP unresolved") end
      if not down then lastError="Palette DOWN rejected: "..tostring(downError)
      elseif not palette.allowed(token) then error("Focus/tool/session lost during palette click")
      else
       palette.current.PaletteStep="VERIFYING"
       local success=palette.waitUntil(successPredicate,token,PAL.Verify)
       detail.ActivatedObserved=activated;detail.AttributeChangedObserved=changed;detail.FinalPaletteRGB=rgbText(paletteColor())
       if success then
        detail.PaletteSuccessVia=intended and (activated and "ACTIVATED+ATTRIBUTE" or "ATTRIBUTE") or "OTHER"
        item.lastUse=os.clock();item.successes=(item.successes or 0)+1;item.validated=true
        return true
       end
       lastError=intended and "Intended PaintBucketColor not observed after native click" or (step.." postcondition not observed")
      end
     end
    end
   end
   item.failures=(item.failures or 0)+1
   detail.FailureReason=lastError
   if not palette.allowed(token) then error("Focus/tool/session lost; no retry") end
   palette.current.PaletteStep=step
  end
  return false
 end)
 activatedConnection:Disconnect();colorConnection:Disconnect()
 if ownedInput then settleRelease() end
 detail.ActivatedObserved=activated;detail.AttributeChangedObserved=changed;detail.FinalPaletteRGB=rgbText(paletteColor())
 if ok and problem==true then detail.FailureReason="";return true end
 detail.FailureReason=ok and lastError or tostring(problem)
 return false,detail.FailureReason
end
function palette.ensureOpen(item,token)
 palette.resolvePaletteControl(item)
 if item.button and palette.visible(item.button) then return true end
 if palette.anyVisible() and not item.button then return false,"NATIVE_SWATCH_UNAVAILABLE" end
 if not focused then return false,"FOCUS_LOST_DURING_OPEN" end
 if not palette.snapshotValid(palette.activeSnapshot) then return false,"GENERATION_CHANGED_DURING_OPEN" end
 if not palette.valid(palette.opener) or not palette.visible(palette.opener.button) then
  if not palette.anyVisible() then palette.block("NO_LIVE_OPENER") end;return false,"NO_LIVE_OPENER"
 end
 palette.metrics.OpenerUses+=1;palette.current.OpenerAttempted=true
 local opened,why=palette.click(palette.opener,token,"OPENING",function()
  palette.resolvePaletteControl(item);return item.button and palette.visible(item.button)
 end)
 palette.current.OpenerActivatedObserved=palette.current.Click and palette.current.Click.ActivatedObserved or false
 palette.current.PaletteBecameVisible=opened
 if opened then
  palette.opener.transitionVerified=true;palette.rememberNative(palette.opener)
  if palette.activeSnapshot and not palette.snapshotValid(palette.activeSnapshot) then return false,"GENERATION_CHANGED_DURING_OPEN" end
 else
  palette.metrics.OpenerFailures+=1;palette.current.OpenerFailures=1
  if not focused then why="FOCUS_LOST_DURING_OPEN"
  elseif not palette.snapshotValid(palette.activeSnapshot) then why="GENERATION_CHANGED_DURING_OPEN"
  elseif not palette.current.Click or not palette.current.Click.MouseDownSent then why="OPENER_ACTIVATION_FAILED"
  elseif not palette.current.OpenerActivatedObserved then why="OPENER_CLICK_UNOBSERVED"
  else why="PALETTE_DID_NOT_OPEN" end
  if why~="FOCUS_LOST_DURING_OPEN" and why~="GENERATION_CHANGED_DURING_OPEN" then palette.block(why) end
 end
 return opened,why
end

function palette.verifyCandidates(item,token)
 if not item.pendingVerification then return true end
 local record=item.rootRecord;local candidates=table.clone(item.candidates or {})
 for i,candidate in ipairs(candidates) do
  if i>8 then break end -- bounded native UI trials, never an unbounded scan/click loop
  if not palette.allowed(token) then return false,"Palette candidate verification interrupted" end
  if ownedInput or releaseBlocked then return false,"Previous native release unresolved" end
  if candidate.button:IsDescendantOf(playerGui) and palette.identityMatches(candidate.button,item) then
   item.button=candidate.button;palette.byButton[candidate.button]=item
   local selected,why=palette.click(item,token,"VERIFYING_CANDIDATE",function() return colorsMatch(paletteColor(),item.color) end,item.color)
   if selected then
    palette.bind(item,candidate.button,record,true);palette.rememberNative(item)
    item.verifiedGeneration=record.generation;item.retryAfter=nil
    palette.bindingMetrics.AmbiguousResolutionsSucceeded+=1;return true
   end
   palette.byButton[candidate.button]=nil
   table.insert(item.candidateFailures,candidate.button:GetFullName()..": "..tostring(why))
  end
 end
 item.button=nil;item.bindingState="AMBIGUOUS_UNVERIFIED";item.bindingFailure="No candidate produced the expected native selected color"
 item.pendingVerification=true;item.retryAfter=os.clock()+CFG.PaletteColorRetry
 palette.bindingMetrics.AmbiguousResolutionsFailed+=1;return false,item.bindingFailure
end
function palette.mapBlocked(entry,item)
 if palette.closeRequired then return true end
 if mouse.Target==entry.part and palette.topButton(UserInputService:GetMouseLocation()) then return true end
 local camera=Workspace.CurrentCamera
 local world=entry.lastWorld or entry.part.Position
 local p,visible=camera:WorldToViewportPoint(world)
 if not visible then return false end
 local insetAtPoint=GuiService:GetGuiInset()
 local point=Vector2.new(p.X+insetAtPoint.X,p.Y+insetAtPoint.Y)
 local top=palette.topButton(point)
 if top then return true end
 -- Active frames in the palette's ScreenGui can also block map clicks.
 local root=palette.resolvePaletteControl(item)
 if not root then return false end -- Closed/absent palette has no map overlay; exact input GUI gate still applies.
 while root.Parent and root.Parent~=playerGui do root=root.Parent end
 local inset=GuiService:GetGuiInset()
 local ok,objects=pcall(function() return playerGui:GetGuiObjectsAtPosition(point.X-inset.X,point.Y-inset.Y) end)
 if ok then for _,o in ipairs(objects) do if o:IsDescendantOf(root) and o.Active then return true end end end
 return false
end
function palette.prepare(entry,token,service)
 local started=os.clock();local item=palette.find(entry.civilColor);entry.civilControl=item or entry.civilControl
 local trace={PaletteStep="IDLE",EntryId=entry.id,IntendedRGB=rgbText(entry.civilColor),CurrentPaintBucketRGB=rgbText(paletteColor()),
 Steps={},OpenerAttempted=false,OpenerActivatedObserved=false,PaletteBecameVisible=false,OpenerFailures=0,CloserAttempts=0,CloserFailures=0,
 PaletteSuccessVia="none",FailureReason=""}
 palette.current=trace;palette.currentEntry=entry
 local snapshot=palette.snapshot(item);palette.activeSnapshot=snapshot
 trace.PaletteStateSnapshotId=snapshot.id;trace.PaletteRootVisibleAtStart=snapshot.visible;trace.PaletteGenerationAtStart=snapshot.generation
 trace.SwatchVisibleAtStart=snapshot.swatchVisible;trace.SwatchBindingAtStart=snapshot.binding;trace.OpenerStateAtStart=snapshot.opener;trace.CloserStateAtStart=snapshot.closer;trace.PaletteRootAliveAtStart=snapshot.root~=nil
 if #palette.transactions>=20 then table.remove(palette.transactions,1) end;table.insert(palette.transactions,trace)
 service.attributeBefore=paletteColor();service.previousIntended=v7.previousIntended;v7.previousIntended=entry.civilColor
 local function finish(ok,why)
  trace.PaletteStep=ok and "COMPLETE" or "FAILED";trace.FailureReason=why or "";trace.FinalPaletteRGB=rgbText(paletteColor())
  trace.PaletteMs=(os.clock()-started)*1000
  service.paletteUISelection=item and item.path or "unavailable"
  service.paletteProof="Native selected-color observation: "..trace.PaletteSuccessVia.."; working color confirmed only by province result"
  service.attributeAfter=paletteColor();service.attributeAfterEquip=paletteColor()
  if not ok then palette.status=trace.FailureReason end
  if not ok then trace.PaletteRootVisibleAtFailure=palette.anyVisible() end
  trace.PaletteGenerationAtFailure=not ok and palette.bindingGeneration or nil
  if not ok and not palette.snapshotValid(snapshot) then why="GENERATION_CHANGED_DURING_TRANSACTION";trace.FailureReason=why end
  palette.currentEntry=nil;palette.activeSnapshot=nil
  return ok,why
 end
 if not item then return finish(false,"No learned native palette mapping for assignment") end
 if not shouldTarget(entry) then return finish(false,"CLEAN_BEFORE_PALETTE_INPUT") end
 palette.resolvePaletteControl(item)
 if (not colorsMatch(paletteColor(),entry.civilColor) or item.pendingVerification) and (not item.button or not palette.visible(item.button)) then
  local opened,why=palette.ensureOpen(item,token)
  if not opened then return finish(false,tostring(why)) end
 end
 if item.pendingVerification and not (item.semanticVerified and colorsMatch(paletteColor(),entry.civilColor)) then
  local verified,why=palette.verifyCandidates(item,token)
  if not verified then return finish(false,why) end
 end
 if not palette.allowed(token) then return finish(false,"Focus/tool/session unavailable") end
 if colorsMatch(paletteColor(),entry.civilColor) then
  palette.metrics.PaletteSkipsAlreadyCorrect+=1;trace.PaletteSuccessVia="ALREADY_CORRECT_ATTRIBUTE"
 else
  if not palette.visible(item.button) then
   local opened,why=palette.ensureOpen(item,token);if not opened then return finish(false,why) end
  end

  trace.PaletteBecameVisible=palette.visible(item.button)
  palette.metrics.PaletteSelections+=1;local selectingAt=os.clock()
  local selected,why=palette.click(item,token,"SELECTING",function() return colorsMatch(paletteColor(),entry.civilColor) end,entry.civilColor)
  palette.metrics.PaletteSelectionTotal+=(os.clock()-selectingAt)*1000
  if not selected then palette.metrics.PaletteSelectionFailures+=1;return finish(false,"SWATCH_FAILED: "..tostring(why)) end
  palette.metrics.PaletteSelectionSuccesses+=1;trace.PaletteSuccessVia=trace.Click.PaletteSuccessVia
 end
 if palette.mapBlocked(entry,item) then
  if not palette.verifiedOpener() then
   trace.AutoCloseSuppressed="KEEP OPEN (no verified opener)"
   if palette.closeRequired then palette.closeRequired=false end
   -- Keep open unless it physically blocks this target; other colors/targets can proceed.
   if palette.mapBlocked(entry,item) then return finish(false,"PALETTE_BLOCKS_TARGET_KEEP_OPEN_NO_OPENER") end
  elseif not palette.valid(palette.closer) then return finish(false,"PALETTE_BLOCKS_TARGET: learn a closer or move/close native palette")
  elseif palette.verifiedOpener() then
  trace.CloserAttempts=1;palette.metrics.CloserUses+=1
  local closed,why=palette.click(palette.closer,token,"CLOSING",function()
   if palette.closeRequired then return not palette.visible(item.button) end
   return not palette.mapBlocked(entry,item)
  end)
  if not closed then trace.CloserFailures=1;palette.metrics.CloserFailures+=1;return finish(false,"CLOSER_FAILED: "..tostring(why)) end
  palette.closer.transitionVerified=true;palette.rememberNative(palette.closer)
  end
 end
 if not palette.allowed(token) then return finish(false,"Transaction canceled") end
 return finish(true)
end
function palette.database(compact)
 local lines={compact and "Name | RGB | FullGuiPath" or "LEARNED NATIVE PALETTE COLORS"}
 for _,item in ipairs(palette.controls) do
  local valid=palette.valid(item);local button=item.button
  if compact then table.insert(lines,item.signature.Name.." | "..rgbText(item.color).." | "..item.path)
  else
   table.insert(lines,string.format("%03d | %s | %s\nRGB=%s | ColorKey=%s | ButtonVisible=%s | ButtonValid=%s\nAbsolutePosition=%s | AbsoluteSize=%s | LearnedClickOffset=%s\nLastSuccessfulUse=%s | SuccessfulAutomaticSelections=%d | FailedAutomaticSelections=%d | CurrentSessionVerified=%s",
    item.index,item.signature.Name,item.path,rgbText(item.color),item.key,tostring(palette.visible(button)),tostring(valid),tostring(button and button.AbsolutePosition),tostring(button and button.AbsoluteSize),tostring(item.offset),tostring(item.lastUse or "never"),item.successes or 0,item.failures or 0,tostring(item.validated)))
  end
  if not compact then table.insert(lines,"BindingState="..tostring(item.bindingState).." | CurrentButtonPath="..(button and button:GetFullName() or "unbound").." | LastBoundGeneration="..tostring(item.lastBoundGeneration).." | BindingFailure="..tostring(item.bindingFailure).." | CandidateCount="..tostring(item.candidateCount or 0).." | SemanticRegion="..tostring(item.geometry and item.geometry.Region).." | PreviouslyNativeVerified="..tostring(item.semanticVerified).." | StableDiscriminator="..tostring(item.nativeSignature~=nil))
   for _,failure in ipairs(item.candidateFailures or {}) do table.insert(lines,"  Candidate: "..failure) end end
 end
 return table.concat(lines,"\n")
end
function palette.assignments()
 local lines={"FULL CIVIL ASSIGNMENTS"}
 for _,e in ipairs(entries) do
  local item=e.civilControl or (e.civilColor and palette.find(e.civilColor))
  table.insert(lines,entryLabel(e).." | AssignedColorName="..(item and item.signature.Name or "unassigned").." | AssignedRGB="..rgbText(e.civilColor).." | LearnedPaletteIndex="..tostring(item and item.index).." | PaletteControlPath="..(item and item.path or "unavailable").." | LastActualRGB="..rgbText(e.part.Color).." | State="..(colorsMatch(e.part.Color,e.civilColor) and "CLEAN" or "DIRTY"))
 end
 return table.concat(lines,"\n")
end
function palette.transactionReport()
 local lines={"CIVIL PALETTE TRANSACTIONS (last 20; local evidence)"}
 local fields={"PaletteStep","EntryId","IntendedRGB","CurrentPaintBucketRGB","PaletteSuccessVia","FinalPaletteRGB","FailureReason","PaletteMs","PaletteStateSnapshotId","PaletteRootAliveAtStart","SwatchVisibleAtStart","SwatchBindingAtStart","OpenerStateAtStart","CloserStateAtStart","PaletteRootVisibleAtStart","PaletteRootVisibleAtFailure","PaletteGenerationAtStart","PaletteGenerationAtFailure","AutoCloseSuppressed","OpenerAttempted","OpenerActivatedObserved","PaletteBecameVisible","OpenerFailures","CloserAttempts","CloserFailures"}
 local clickFields={"Role","Retry","TargetControlName","TargetControlPath","TargetControlVisible","TargetControlPosition","CursorPositionBefore","CursorPositionAfter","TopButtonAtClick","VirtualInputMoveSucceeded","MouseDownSent","MouseUpSent","ActivatedObserved","AttributeChangedObserved","FinalPaletteRGB","PaletteSuccessVia","FailureReason"}
 for _,trace in ipairs(palette.transactions) do
  for _,key in ipairs(fields) do table.insert(lines,key.."="..tostring(trace[key])) end
  for _,click in ipairs(trace.Steps) do for _,key in ipairs(clickFields) do table.insert(lines,"  "..key.."="..tostring(click[key])) end end
 end
 return table.concat(lines,"\n")
end
function palette.inspect()
 return palette.database(false).."\n"..palette.assignments().."\n"..palette.transactionReport()
end
function palette.copy(text,filename)
 if type(setclipboard)=="function" and pcall(setclipboard,text) then return true end
 if type(writefile)=="function" and pcall(writefile,filename,text) then return true end
 return false
end
function palette.profile()
 local data={Version=2,PlaceId=game.PlaceId,Controls={}}
 local function row(item)
  if not item then return nil end
  local r,g,b=normalizedRGB(item.color)
  local segments={};for _,part in ipairs(item.segments) do table.insert(segments,{Name=part.Name,ClassName=part.ClassName}) end
  return {Path=segments,FullGuiPath=item.path,RGB=r and {r,g,b} or nil,ColorKey=item.key,Signature=table.clone(item.signature),NormalizedClick={0.5,0.5},LearnedIndex=item.index,SuccessfulAutomaticSelections=item.successes,FailedAutomaticSelections=item.failures,Invalid=item.invalid==true,Geometry=item.geometry,NativeSignature=item.nativeSignature,SemanticVerified=item.semanticVerified==true}
 end
 for _,item in ipairs(palette.controls) do table.insert(data.Controls,row(item)) end
 data.Opener=row(palette.opener);data.Closer=row(palette.closer)
 return data
end
function palette.import(data)
 if running or workerActive or starting or ownedInput or selecting then return false,"Stop/finish selection before import" end
 if type(data)~="table" or (data.Version~=1 and data.Version~=2) or data.PlaceId~=game.PlaceId or type(data.Controls)~="table" or #data.Controls>PAL.MaxControls then return false,"Invalid profile version/game/size" end
 local built,seen={},{}
 local function resolve(row: any,needsColor)
  if type(row)~="table" or type(row.Path)~="table" or #row.Path>32 or #row.Path==0 or type(row.Signature)~="table" then error("Invalid GUI path/signature") end
  local segments={};local pathKeys={}
  for _,segment in ipairs(row.Path) do
   if type(segment)~="table" or type(segment.Name)~="string" or type(segment.ClassName)~="string" or #segment.Name>256 then error("Invalid path segment") end
   if segment.Name==GUI_NAME then error("Controller UI is not native palette") end
   table.insert(segments,{Name=segment.Name,ClassName=segment.ClassName})
   table.insert(pathKeys,segment.ClassName..":"..segment.Name)
  end
  local last=segments[#segments]
  if last.ClassName~="TextButton" and last.ClassName~="ImageButton" then error("Profile target is not a native button") end
  if row.Signature.Name~=last.Name or row.Signature.ClassName~=last.ClassName or type(row.Signature.BackgroundRGB)~="string" then error("Invalid signature") end
  local geometry
  if row.Geometry~=nil then
   if type(row.Geometry)~="table" then error("Invalid geometry signature") end
   geometry={}
   for _,k in ipairs({"ParentName","ParentClass","Region","RootName","BackgroundRGB","RegionPath"}) do
    local value=row.Geometry[k];if value~=nil and (type(value)~="string" or #value>512) then error("Invalid geometry signature") end;geometry[k]=value
   end
   for _,k in ipairs({"Sibling","Order"}) do
    local value=row.Geometry[k];if value~=nil and (type(value)~="number" or value~=value or value<0 or value>1000000) then error("Invalid geometry order") end;geometry[k]=value
   end
   if row.Geometry.Normalized~=nil then
    local n: any=row.Geometry.Normalized
    if type(n)~="table" or type(n.X)~="number" or type(n.Y)~="number" or n.X~=n.X or n.Y~=n.Y or math.abs(n.X)>1000 or math.abs(n.Y)>1000 then error("Invalid normalized geometry") end
    geometry.Normalized={X=n.X,Y=n.Y}
   end
  end
  local identity=table.concat(pathKeys,"/")
  if needsColor then
   if seen[identity] then error("Duplicate control path") end;seen[identity]=true
  end
  local item={path=type(row.FullGuiPath)=="string" and row.FullGuiPath or identity,segments=segments,signature=table.clone(row.Signature),
   normalized=Vector2.new(0.5,0.5),successes=type(row.SuccessfulAutomaticSelections)=="number" and math.max(0,row.SuccessfulAutomaticSelections) or 0,
   failures=type(row.FailedAutomaticSelections)=="number" and math.max(0,row.FailedAutomaticSelections) or 0,
   validated=false,imported=true,bindingState="REBIND_PENDING",invalid=row.Invalid==true,geometry=geometry,semanticVerified=row.SemanticVerified==true,nativeSignature=nil}
  if item.semanticVerified and geometry and type(row.NativeSignature)=="table" then
   local proof=row.NativeSignature
   if proof.Region==geometry.Region and proof.RegionPath==geometry.RegionPath and proof.ParentName==geometry.ParentName and proof.ParentClass==geometry.ParentClass and proof.BackgroundRGB==geometry.BackgroundRGB
    and type(proof.Normalized)=="table" and geometry.Normalized and proof.Normalized.X==geometry.Normalized.X and proof.Normalized.Y==geometry.Normalized.Y then item.nativeSignature=table.clone(geometry) end
  end
  if needsColor then
   if type(row.RGB)~="table" or #row.RGB~=3 then error("Invalid RGB") end
   for _,v in ipairs(row.RGB) do if type(v)~="number" or v~=v or v<0 or v>255 or v%1~=0 then error("Invalid RGB byte") end end
   item.color=Color3.fromRGB(row.RGB[1],row.RGB[2],row.RGB[3]);item.key=colorKey(item.color)
   if item.key~=row.ColorKey then error("Invalid key/duplicate control") end
   for _,other in ipairs(built) do if colorsMatch(item.color,other.color) then error("Duplicate/near-identical profile color") end end
   item.index=#built+1;table.insert(built,item)
  end
  return item
 end
 local ok,extra=pcall(function()
  for _,row in ipairs(data.Controls) do resolve(row,true) end
  return {opener=data.Opener and resolve(data.Opener,false),closer=data.Closer and resolve(data.Closer,false)}
 end)
 if not ok then return false,tostring(extra) end
 for _,record in pairs(palette.rootRecords) do for _,connection in ipairs(record.connections) do connection:Disconnect() end end
 palette.rootRecords={};palette.controls=built;palette.byButton={};palette.byKey={};palette.nextIndex=#built
 for _,item in ipairs(built) do palette.byKey[item.key]=item end
 palette.opener,palette.closer=extra.opener,extra.closer
 palette.rebindAll("Profile imported against current PlayerGui")
 for _,entry in ipairs(entries) do
  entry.civilControl=nil
  for _,item in ipairs(built) do if entry.civilKey==item.key then entry.civilControl=item;break end end
 end
 palette.status=string.format("Imported %d semantic mappings; detached controls await rebind, selected color verified on use",#built)
 return true
end

local function saveView()
 if v82.camera.mode~="AGGRESSIVE" or v82.camera.circuit=="OPEN" then return false end
	if cameraSnapshot then return true end
	local camera = Workspace.CurrentCamera
	if not camera then return false end
	cameraSnapshot = {
		camera = camera,
		kind = camera.CameraType,
  subject = camera.CameraSubject,
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
	if v82.camera then v82.camera.data.CameraRestores+=1 end
	pcall(function()
		if Workspace.CurrentCamera == saved.camera then
			saved.camera.CFrame = saved.cframe
			saved.camera.Focus = saved.focus
			saved.camera.CameraType = saved.kind
   saved.camera.CameraSubject = saved.subject
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

v82.camera={mode="LOCKED",manualUntil=0,circuit="CLOSED",lastMove=-math.huge,failures=0,window={},data={
 CameraFallbackAttempts=0,CameraFallbackSuccesses=0,UnderMapCandidatesRejected=0,CameraPosesBlacklisted=0,
 CameraRestores=0,ReusedGoodCameraSolutions=0,UserCameraDeferrals=0,UnsafeCameraCandidatesRejected=0,
 CameraMoveAttempts=0,CameraMovesApplied=0,CameraMoveTargetAcquisitions=0,CameraMoveSuccessfulPaints=0,CameraMoveFailures=0,
 CameraMovesSuppressedSafeMode=0,CameraMovesSuppressedCircuitBreaker=0,CameraMovesSuppressedUserInput=0,CameraMovesSuppressedTargetCooldown=0}}
function v82.acquisitionState(entry,state)
 entry.AcquisitionState=state;lastAcquireDetail=state
end
function v82.mapPlane(entry)
 local p=entry.part;local cf,size=p.CFrame,p.Size
 local top=p.Position.Y+(math.abs(cf.RightVector.Y)*size.X+math.abs(cf.UpVector.Y)*size.Y+math.abs(cf.LookVector.Y)*size.Z)*0.5
 return top
end
function v82.poseKey(cf)
 local p=cf.Position;local l=cf.LookVector
 return string.format("%.0f/%.0f/%.0f:%.2f/%.2f/%.2f",p.X,p.Y,p.Z,l.X,l.Y,l.Z)
end
function v82.blacklistPose(entry,cf,why)
 if not cf then return end
 entry.cameraBlacklist=entry.cameraBlacklist or {};entry.cameraBlacklistOrder=entry.cameraBlacklistOrder or {}
 local key=v82.poseKey(cf);if entry.cameraBlacklist[key] then return end
 if #entry.cameraBlacklistOrder>=128 then entry.cameraBlacklistedOut=true;return end
 entry.cameraBlacklist[key]=why;table.insert(entry.cameraBlacklistOrder,key);v82.camera.data.CameraPosesBlacklisted+=1
 if entry.lastCamera and v82.poseKey(entry.lastCamera)==key then entry.lastCamera=nil;cameraCache[entry.part]=nil end
end
function v82.safePose(entry,cf)
 if entry.cameraBlacklistedOut then return false end
 local p,look=cf.Position,cf.LookVector
 if p.X~=p.X or p.Y~=p.Y or p.Z~=p.Z or math.abs(p.X)>1e7 or math.abs(p.Y)>1e7 or math.abs(p.Z)>1e7 then return false end
 local plane=v82.mapPlane(entry)
 -- Only the rare camera path inspects selected geometry; cursor-first work is unchanged.
 if not v82.camera.ceilingAt or os.clock()>=v82.camera.ceilingAt then
  v82.camera.ceilingAt=os.clock()+0.5;v82.camera.ceiling=plane
  for _,protected in ipairs(entries) do if protected.active and validProvince(protected.part) then v82.camera.ceiling=math.max(v82.camera.ceiling,v82.mapPlane(protected)) end end
 end
 local tops={};for _,protected in ipairs(entries) do if protected.active and validProvince(protected.part) then table.insert(tops,v82.mapPlane(protected)) end end
 table.sort(tops);local median=tops[math.max(1,math.ceil(#tops/2))] or plane
 local height=math.max(0.1,2*(plane-entry.part.Position.Y))
 local margin=math.max(CFG.CameraClearance,height*0.5)
 entry.cameraGeometry={TargetTopY=plane,TargetCenterY=entry.part.Position.Y,MapMedianSurfaceY=median,BoundingHeight=height,Margin=margin}
 plane=math.max(plane,median)
 if p.Y<=plane+margin or look.Y>=0 or p.Y<=entry.part.Position.Y then
  v82.camera.data.UnderMapCandidatesRejected+=1;v82.blacklistPose(entry,cf,"below safe province plane/upward from map")
  return false
 end
 if entry.cameraBlacklist and entry.cameraBlacklist[v82.poseKey(cf)] then return false end
 local ok,parts=pcall(function()
  local params=OverlapParams.new();params.FilterType=Enum.RaycastFilterType.Exclude
  params.FilterDescendantsInstances=player.Character and {player.Character} or {}
  return Workspace:GetPartBoundsInBox(CFrame.new(p),Vector3.new(2,2,2),params)
 end)
 if not ok then
  v82.camera.data.UnsafeCameraCandidatesRejected+=1;lastAcquireDetail="Camera occupancy query unavailable; automatic pose refused";return false
 end
 for _,part in ipairs(parts) do
  if part:IsA("BasePart") and part.CanQuery~=false then
   v82.camera.data.UnsafeCameraCandidatesRejected+=1;v82.blacklistPose(entry,cf,"camera intersects queryable geometry");return false
  end
 end
 return true
end
function v82.cameraAllowed(entry)
 local c=v82.camera;local d=c.data
 if c.mode~="AGGRESSIVE" then d.CameraMovesSuppressedSafeMode+=1;return false end
 if c.circuit=="OPEN" then d.CameraMovesSuppressedCircuitBreaker+=1;return false end
 if os.clock()<c.manualUntil then d.UserCameraDeferrals+=1;d.CameraMovesSuppressedUserInput+=1;return false end
 if not entry or entry.AcquisitionState~="PROVEN_UNREACHABLE_CURRENT_VIEW" or not shouldTarget(entry)
  or not targetColor(entry) or not focused or not running or not activationTool or activationTool.Parent~=player.Character
  or v82.overload or entry.paletteBlocked then return false end
 if (entry.CameraFallbackAttemptsThisDirtyEpisode or 0)>0 or os.clock()-c.lastMove<CFG.CameraGlobalGap
  or os.clock()-(entry.LastCameraFallbackAt or -math.huge)<CFG.CameraEntryGap then d.CameraMovesSuppressedTargetCooldown+=1;return false end
 return true
end
function v82.applyPose(entry,cf,focus)
 if not v82.cameraAllowed(entry) or not v82.safePose(entry,cf) then return false end
 if not saveView() then return false end
 entry.CameraFallbackAttemptsThisDirtyEpisode=(entry.CameraFallbackAttemptsThisDirtyEpisode or 0)+1
 entry.LastCameraFallbackAt=os.clock();v82.camera.lastMove=os.clock();v82.camera.data.CameraMovesApplied+=1
 Workspace.CurrentCamera.CFrame=cf;Workspace.CurrentCamera.Focus=CFrame.new(focus)
 entry.activeCameraPose=cf
 return true
end
function v82.cameraResult(entry,acquired,painted)
 local c=v82.camera;local d=c.data
 if painted then d.CameraMoveSuccessfulPaints+=1;entry.LastGoodCameraSolution=entry.activeCameraPose;return end
 if acquired then d.CameraMoveTargetAcquisitions+=1;d.CameraFallbackSuccesses+=1;c.failures=0
 else d.CameraMoveFailures+=1;c.failures+=1;entry.LastGoodCameraSolution=nil end
 table.insert(c.window,acquired);if #c.window>8 then table.remove(c.window,1) end
 local successes=0;for _,ok in ipairs(c.window) do if ok then successes+=1 end end
 if c.failures>=CFG.CameraFailureLimit or (#c.window>=5 and successes/#c.window<0.3) then c.circuit="OPEN" end
end
function v82.restoreAfterService()
 if cameraSnapshot and not ownedInput and not inputBusy then restoreView() end
 if currentEntry then currentEntry.activeCameraPose=nil end
end
local function cameraOrigins(part,point)
 -- One offline upper-side candidate. No live orbit/search loop.
 local current=Workspace.CurrentCamera.CFrame.Position
 local top=v82.mapPlane({part=part});local h=math.max(CFG.CameraHeightMin,part.Size.Magnitude*1.5)
 return {Vector3.new(point.X,math.max(current.Y,top+h),point.Z+0.01)}
end

local function screenRayHits(camera, screenPoint, part)
	local ray = camera:ScreenPointToRay(screenPoint.X, screenPoint.Y)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local character = player.Character
	params.FilterDescendantsInstances = character and {character} or {}
	local hit = Workspace:Raycast(ray.Origin, ray.Direction * 10000, params)
	return hit and hit.Instance == part and (not hit.Normal or hit.Normal.Y>=-0.05)
end

local function acquireTarget(entry)
 if not v82.cameraAllowed(entry) then return false end
 local camera=Workspace.CurrentCamera;if not camera or not validProvince(entry.part) then return false end
 local point=targetPoints(entry.part)[1]
 local cached=entry.LastGoodCameraSolution
 local pose=cached or CFrame.lookAt(cameraOrigins(entry.part,point)[1],point)
 v82.camera.data.CameraMoveAttempts+=1
 if not v82.applyPose(entry,pose,point) then return false end
 -- Cursor is still genuine; one constrained pose is followed by fresh projection.
 RunService.RenderStepped:Wait()
 return alive and running and shouldTarget(entry) and os.clock()>=v82.camera.manualUntil
end

-- Fast cursor path; camera is opt-in, proof-gated, one move per dirty episode.
local dirty, dirtyCursor = {}, 0
local freshHead,freshTail,freshCount=nil,nil,0
local wake = Instance.new("BindableEvent")
local transitionCount, projectionsLeft, raysLeft = 0, CFG.MaxProjections, CFG.MaxRays
local nextWorkerAt,nextReconcileAt=nil,0
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
function v7.draw(entry)
 if not entry.box or not entry.active then return end
 entry.box.Enabled=v82.outlines~=false
 local r,g,b=normalizedRGB(entry.part.Color);local light=r and (r*0.2126+g*0.7152+b*0.0722)>145
 entry.box.FillTransparency=v82.fill and 0.90 or 1
 if v7.lock==entry then entry.box.OutlineColor=Color3.fromRGB(255,190,20)
 elseif CFG.ShowDirtyState and entry.dirtyIndex then entry.box.OutlineColor=light and Color3.fromRGB(155,0,55) or Color3.fromRGB(255,95,125)
 else entry.box.OutlineColor=light and Color3.fromRGB(15,55,145) or Color3.fromRGB(135,255,220) end
 entry.box.FillColor=entry.box.OutlineColor
end
local function removeDirty(entry)
	if v82.account then v82.account(entry,os.clock()) end
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
	v82.onDirty(entry,now)
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
-- v8.2 queue accounting: cooldown time is never eligible scheduler wait.
function v82.account(entry,now)
 if not entry.clockAt then entry.clockAt=now;return end
 local from=entry.clockAt;entry.clockAt=now
 if not entry.dirtyIndex or entry.inService or now<=from then return end
 local deferred=math.max(0,math.min(now,entry.retryAt or 0)-from)
 local eligible=math.max(0,now-from-deferred)
 entry.eligibleMs=(entry.eligibleMs or 0)+eligible*1000
 entry.deferredMs=(entry.deferredMs or 0)+deferred*1000
 if entry.deferKind=="QUARANTINE" or entry.deferKind=="GROUP" then entry.quarantineMs=(entry.quarantineMs or 0)+deferred*1000 end
end
function v82.defer(entry,seconds,kind)
 local now=os.clock();v82.account(entry,now)
 if now+seconds>=(entry.retryAt or 0) then entry.retryAt=now+seconds;entry.deferKind=kind or "RETRY" end
end
function v82.queueOrigin(entry,origin)
 entry.queueOrigin=origin
 if not entry.episodeOrigin then entry.episodeOrigin=origin end
end
function v82.onDirty(entry,now)
 entry.dirtyEpisode=(entry.dirtyEpisode or 0)+1
 entry.CameraFallbackAttemptsThisDirtyEpisode=0;entry.CursorOnlyFailuresSinceSuccess=0
 entry.clockAt=now;entry.eligibleMs,entry.deferredMs,entry.quarantineMs=0,0,0;entry.inService=false
 entry.episodeOrigin=nil;v82.queueOrigin(entry,running and "BULK_EXISTING_DIRTY" or "BOOTSTRAP_DIRTY")
 v82.data.PeakDirtyCount=math.max(v82.data.PeakDirtyCount,#dirty)
end
function v82.push(list,value,limit)
 if #list>=limit then table.remove(list,1) end;table.insert(list,value)
end
-- Color signals prove local state changes, not the identity of the external painter.
function v82.activeCombat(entry,now)
 return mode=="NORMAL" and entry.observedWrongChangeAt~=nil and now-entry.observedWrongChangeAt<=CFG.CombatActivityWindow
end
function v82.clearFreshPenalty(entry,now)
 v82.account(entry,now)
 local key=entry.groupId;local group=key and v82.groups[key]
 if key then
  v82.combat.FreshGroupClears+=1;entry.groupId=nil
  if group then
   group.ids[entry.id]=nil
   local n=0;for _ in pairs(group.ids) do n+=1 end
   if n<2 then
    for id in pairs(group.ids) do local other=v82.ids[id]
     if other and other.groupId==key then other.groupId=nil
      if other.deferKind=="GROUP" then v82.account(other,now);other.retryAt=now;other.deferKind=nil end
     end
    end
    v82.groups[key]=nil;v82.groupCount=math.max(0,v82.groupCount-1)
   end
  end
 end
 if (entry.ConsecutiveFailures or 0)>0 or (entry.ExtraDwell or 0)>0 or (entry.retryAt or 0)>now then v82.combat.FreshPenaltyResets+=1 end
 health.reset(entry,false);entry.retryAt=now;entry.deferKind=nil;entry.forceFullService=nil;entry.hotUntil=nil
 entry.eligibleAt=now;entry.externalEventAt=now
 if health.sameEntry==entry.id then health.sameEntry=nil;health.sameFailures=0 end
end
function v82.attack(entry,now)
 if mode=="NORMAL" then v82.clearFreshPenalty(entry,now) end
 entry.AttackFrequency=(entry.AttackFrequency or 0)*math.exp(-math.max(0,now-(entry.lastExternalChange or now))/2)+1
 entry.lastExternalChange=now;entry.attackCount=(entry.attackCount or 0)+1
 v82.push(v82.attacks,now,256)
 if entry.lastCorrectedTime and now-entry.lastCorrectedTime<CFG.HotReattackWindow then
  entry.ImmediateReattacks=(entry.ImmediateReattacks or 0)+1
  if entry.ImmediateReattacks>=2 then
   if (entry.hotUntil or 0)<now then v82.data.HotTargetsDetected+=1 end
   -- Fresh NORMAL defense is immediately eligible. It still gets only one
   -- transaction before a scheduler boundary; stale failures retain backoff.
   if mode~="NORMAL" then
    entry.hotUntil=now+CFG.HotWindow
    if #dirty>1 then v82.defer(entry,CFG.HotRotationGap,"HOT");v82.data.HotTargetRotations+=1 end
   end
  end
 else entry.ImmediateReattacks=0 end
 entry.episodeOrigin="FRESH_ATTACK";v82.queueOrigin(entry,"FRESH_ATTACK")
end
function v82.percentile(values,p)
 if #values==0 then return 0 end
 table.sort(values);return values[math.max(1,math.ceil(#values*p))]
end
function v82.queueSnapshot(now)
 local eligible,total,deferred={},{},{}
 for _,e in ipairs(dirty) do
  v82.account(e,now)
  table.insert(total,math.max(0,now-(e.dirtySince or now))*1000)
  table.insert(deferred,e.deferredMs or 0)
  if not e.inService and now>=e.retryAt then table.insert(eligible,e.eligibleMs or 0) end
 end
 local r={MaxDirtyAgeMs=0,Quarantined=0}
 for _,e in ipairs(dirty) do if now<e.retryAt then r.Quarantined+=1 end end
 for _,pair in ipairs({{"EligibleQueue",eligible},{"TotalDirtyAge",total},{"DeferredAge",deferred}}) do
  for _,q in ipairs({50,90,99}) do r[pair[1].."P"..q.."Ms"]=v82.percentile(table.clone(pair[2]),q/100) end
 end
 r.MaxDirtyAgeMs=v82.percentile(total,1);r.P50DirtyAgeMs=r.TotalDirtyAgeP50Ms;r.P90DirtyAgeMs=r.TotalDirtyAgeP90Ms;r.P99DirtyAgeMs=r.TotalDirtyAgeP99Ms
 return r
end
function v82.updateLoad(now)
 if now<(v82.loadAt or 0) then return end;v82.loadAt=now+0.25
 local q=v82.queueSnapshot(now);v82.queue=q
 local rate=0;for _,at in ipairs(v82.attacks) do if now-at<2 then rate+=0.5 end end
 local cps=0;for _,bin in pairs(rateBins) do if now-bin.tick/2<2 then cps+=bin.Corrections/2 end end
 local n,misses,serviceMs=0,0,0
 for _,r in ipairs(v7.records) do
  if r.ServiceQualified then n+=1;if r.Result=="VALID_NO_EFFECT" then misses+=1 end;serviceMs+=r.ServiceMs end
 end
 v82.data.FreshAttackRate=rate;v82.data.RecentCorrectionRate=cps
 v82.data.ValidNoEffectRate=n>0 and misses/n or 0
 v82.data.ActiveServiceMs=policy and policy.current and policy.current.validAt and (now-policy.current.validAt)*1000 or 0
 v82.data.PeakAttackRate=math.max(v82.data.PeakAttackRate,rate);v82.data.PeakQueueAge=math.max(v82.data.PeakQueueAge,q.MaxDirtyAgeMs)
 local trigger=#dirty>=CFG.OverloadDepth or q.EligibleQueueP90Ms>=CFG.OverloadQueueMs
  or (#dirty>=3 and rate>cps+1) or (#dirty>=4 and v82.data.ActiveServiceMs>(CFG.TargetDwellMax+0.25)*1000) or (#dirty>=4 and q.MaxDirtyAgeMs>2500 and v82.data.ValidNoEffectRate>0.35)
 if not v82.overload and trigger then
  v82.overload=true;v82.overloadAt=now;v82.clearSince=nil;v82.data.OverloadEntries+=1
 elseif v82.overload then
  local clear=#dirty<=CFG.OverloadExitDepth and q.EligibleQueueP90Ms<CFG.OverloadQueueMs*0.5 and (rate<=cps+0.5 or #dirty==0)
  if clear then v82.clearSince=v82.clearSince or now else v82.clearSince=nil end
  if v82.clearSince and now-v82.clearSince>=CFG.OverloadExitQuiet and now-v82.overloadAt>=CFG.OverloadMinHold then
   v82.overload=false;v82.data.TimeInOverloadMs+=(now-v82.overloadAt)*1000;v82.overloadAt=nil;v82.data.OverloadExits+=1
  end
 end
end
-- Urgency always precedes palette reuse. Read-only scoring; no cursor/input ownership.
function v82.rank(entry,now)
 v82.account(entry,now)
 local wait=(entry.eligibleMs or 0)/1000
 local fresh=entry.freshLinked and now<entry.recentUntil
 local age=math.max(0,now-(entry.dirtySince or now));local since=math.max(0,now-(entry.lastServicedAt or entry.dirtySince or now))
 local hot=(entry.hotUntil or 0)>now
 local tier=wait>=CFG.HardEligibleAge and 0 or fresh and 1 or age>=3 and wait>=0.2 and 2 or 3
 if hot and tier~=0 and #dirty>1 then tier=math.min(4,tier+1) end
 local score=4*math.min(wait,2)+2*math.min(since,2)+0.1*math.min(age,10)
  + (fresh and math.max(0,1-(now-(entry.freshAttackAt or now))) or 0)
  -0.15*math.min(entry.ConsecutiveFailures or 0,5)-(hot and 0.5 or 0)
 local same=mode=="CIVIL WAR" and colorsMatch(paletteColor(),targetColor(entry)) and v82.batchCount<CFG.CivilMicroBatch
 return tier,score,same and 1 or 0
end
function v82.beginService(service)
 local e=service.entry;local now=os.clock();v82.account(e,now)
 service.queueOrigin=e.queueOrigin or "BOOTSTRAP_DIRTY";service.episodeOrigin=e.episodeOrigin
 service.eligibleQueueMs=e.eligibleMs or 0;service.deferredAgeMs=e.deferredMs or 0;service.quarantineAgeMs=e.quarantineMs or 0
 service.totalDirtyAgeMs=math.max(0,now-(e.dirtySince or now))*1000
 service.queueWaitMs=service.eligibleQueueMs;service.dwellBefore=service.arm.dwell
 service.episode=e.dirtyEpisode;service.externalEventAt=e.externalEventAt;service.eligibleAt=e.eligibleAt or e.dirtySince;service.schedulerPickedAt=now
 service.recoverySample=(e.ConsecutiveFailures or 0)>0 or (e.quarantineLevel or 0)>0 or e.groupId~=nil
 service.overloadSample=v82.overload;service.cameraSearchesBefore=metrics.CameraFallbacks
 e.inService=true;e.clockAt=now;v82.data.SchedulerSelections+=1
end
function v82.groupSuccess(entry)
 if not entry.groupId then return end
 local key=entry.groupId;local group=v82.groups[key]
 if group then
  for id in pairs(group.ids) do
   local e=v82.ids[id]
   if e then e.groupId=nil;if e.deferKind=="GROUP" then v82.account(e,os.clock());e.retryAt=os.clock();e.deferKind=nil end end
  end
  v82.groups[key]=nil;v82.groupCount=math.max(0,v82.groupCount-1)
 end
 entry.groupId=nil
end
function v82.noteFailure(service)
 local e=service.entry;local now=os.clock()
 if service.result=="VALID_NO_EFFECT" then
  if service.episode~=e.dirtyEpisode then return end
  if v82.activeCombat(e,now) then v82.combat.ActiveCombatMisses+=1;return end
  if service.normal then v82.combat.StaleMisses+=1 end
  v82.push(v82.misses,{id=e.id,at=now,episode=e.dirtyEpisode},12)
  local ids,count={},0
  for _,r in ipairs(v82.misses) do
   local other=v82.ids[r.id]
   if now-r.at<8 and other and other.active and (r.episode==nil or r.episode==other.dirtyEpisode) and not v82.activeCombat(other,now) and (other.ConsecutiveValidNoEffects or 0)>=2 and not ids[r.id] then ids[r.id]=true;count+=1 end
  end
  if count>=2 and count<=4 then
   local sorted={};for id in pairs(ids) do table.insert(sorted,id) end;table.sort(sorted)
   local key=table.concat(sorted,":");local group=v82.groups[key]
   if not group then
    if v82.groupCount>=32 then v82.groups={};v82.groupCount=0;for _,entry in ipairs(entries) do entry.groupId=nil end end
    group={ids=ids,level=0,untilAt=0};v82.groups[key]=group;v82.groupCount+=1;v82.data.PathologicalGroupsDetected+=1
   end
   group.level=math.min(4,group.level+1);local delay=({0.65,1.25,2,4})[group.level];group.untilAt=now+delay
   v82.data.GroupCooldowns+=1;v82.data.GroupCooldownMs=delay*1000
   for id in pairs(ids) do local other=v82.ids[id];if other then other.groupId=key;v82.defer(other,delay,"GROUP") end end
   health.event(e,"PATHOLOGICAL_GROUP","isolate repeated qualified misses",nil,delay,"healthy work remains eligible")
  end
  if v82.overload then
   local delay=math.min(1.25,0.10*2^math.min(4,math.max(0,(e.ConsecutiveValidNoEffects or 1)-1)))
   v82.defer(e,delay,"OVERLOAD");v82.data.AttemptsDeferredByOverload+=1
  end
 end
end
function v82.endService(service)
 local e=service.entry;local now=os.clock()
 e.inService=false;e.lastServicedAt=now
 -- A correction followed by a new attack during UP belongs to a new episode.
 -- Completing the old transaction must not erase its fresh queue clocks/origin.
 local sameEpisode=service.episode==e.dirtyEpisode
 if sameEpisode then e.clockAt=now;e.eligibleMs,e.deferredMs,e.quarantineMs=0,0,0 end
 if service.success then
  e.RecentCorrections=(e.RecentCorrections or 0)+1
  for _,g in pairs(v82.groups) do if now<g.untilAt and not g.ids[e.id] then v82.data.HealthyServicesCompletedWhileGroupDeferred+=1;break end end
  v82.groupSuccess(e)
  local key=colorKey(service.target);if key==v82.batchKey then v82.batchCount+=1 else v82.batchKey=key;v82.batchCount=1 end
 else
  v82.noteFailure(service)
  if sameEpisode then v82.queueOrigin(e,(service.result=="TARGET_LOST" or service.result=="ACQUIRE_FAILED") and "TARGET_RECOVERY" or service.result=="VALID_NO_EFFECT" and "DEFERRED_RETRY" or "RETRY") end
 end
 local list=service.normal and v82.normalSamples or v82.civilSamples
 v82.push(list,{origin=service.queueOrigin,eligible=service.eligibleQueueMs,total=service.totalDirtyAgeMs,deferred=service.deferredAgeMs},256)
 service.dwellAfter=service.arm.dwell
end
function v82.trainingReason(service)
 if not service then return "unknown" end
 if not service.success then return service.result or "not successful" end
 if service.recoverySample then return "target recovery/cooldown" end
 if service.entry.groupId then return "pathological group" end
 if service.overloadSample or service.eligibleQueueMs>=CFG.OverloadQueueMs then return "overload/eligible queue" end
 if service.cameraSearchesBefore~=metrics.CameraFallbacks then return "camera recovery" end
 if service.finishedLate then return "late confirmation" end
 return nil
end
function v82.learnSuccess(arm,latency,service)
 local reason=v82.trainingReason(service)
 if reason then v82.rejectedDwell[reason]=(v82.rejectedDwell[reason] or 0)+1;return end
 v82.data.HealthyDwellSampleCount+=1
 arm.training=arm.training or {};v82.push(arm.training,{id=service.entry.id,latency=latency},CFG.DwellHistory)
 local latencies,ids,distinct={},{},0
 for _,sample in ipairs(arm.training) do table.insert(latencies,sample.latency);if not ids[sample.id] then ids[sample.id]=true;distinct+=1 end end
 v82.data.DistinctDwellTrainingEntries=distinct
 arm.latencies=latencies
 if #latencies>=CFG.DwellMinSamples then
  local value=math.clamp(v82.percentile(table.clone(latencies),0.9)+CFG.DwellMargin,CFG.TargetDwellMin,CFG.TargetDwellMax)
  if value>arm.dwell and distinct<CFG.DwellTrainingDiversity then
   v82.rejectedDwell["insufficient diverse entries"]=(v82.rejectedDwell["insufficient diverse entries"] or 0)+1
  else
   arm.dwell=value>arm.dwell and math.min(value,arm.dwell+0.015) or math.max(value,arm.dwell-0.04)
   health.DwellIncreaseReason="healthy diverse success P90 + margin"
  end
 end
end

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
 policy.trial={State="BASELINE",Started=nil,Attempts=0,ObservedAttempts=0,RetainedSuccesses=0,RetainedMisses=0,
  ConsecutiveMisses=0,UniqueTransferred={},HoldIds={},FallbackReason="none",RetainedProof=false}
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
function policy.fallback(reason)
 local t=policy.trial
 if t.State~="FALLBACK" then v82.combat.NativeHoldFallbacks+=1 end
 t.State="FALLBACK";t.FallbackReason=reason;policy.choice="PER_TARGET";policy.locked=true
 policy.reason=reason.."; native hold released, PER_TARGET cached for this tool session"
end
function policy.observeTrial(service)
 if not service.normal or service.strategy~="CONTINUOUS" or not service.qualified then return end
 local t=policy.trial
 if not service.success and not service.validNoEffect then
  policy.fallback("Held input/target became uncertain: "..tostring(service.result));return
 end
 t.ObservedAttempts+=1
 if t.State=="PROBING" then t.Attempts+=1 end
 if service.success then t.ConsecutiveMisses=0 else t.ConsecutiveMisses+=1 end
 if service.retained and t.State=="PROBING" then
  if service.success and not service.finishedLate and service.correctionHoldValid and service.nativeDownObservedAt and service.holdId then
   t.RetainedSuccesses+=1;t.UniqueTransferred[service.entry.id]=true
   local hold=t.HoldIds[service.holdId] or {};t.HoldIds[service.holdId]=hold;hold[service.entry.id]=true
   local count=0;for _ in pairs(hold) do count+=1 end
   if count>=CFG.HoldMinimumTransferredSuccesses then t.RetainedProof=true end
  elseif service.validNoEffect then t.RetainedMisses+=1 end
 end
 if t.ConsecutiveMisses>=2 then policy.fallback("Two qualified native hold attempts produced no observed correction");return end
 if t.State=="CONFIRMED" then
  local recent=policy.stats(policy.normal.CONTINUOUS)
  if recent.WindowAttempts>=6 and recent.SuccessRate<0.75 then policy.fallback("Confirmed hold reliability dropped below 75%") end
 end
end
function policy.decide()
 if not running or CFG.ActivationStrategy=="PER_TARGET" or policy.locked then return end
 local t=policy.trial;local p,c=policy.normal.PER_TARGET,policy.normal.CONTINUOUS
 if t.State=="BASELINE" or t.State=="WAITING_FOR_TARGETS" then
  if p.Successes<3 or p.Attempts<CFG.StrategyMinAttempts then policy.choice="PER_TARGET";policy.reason="Collecting qualified PER_TARGET baseline";return end
  if #dirty<2 or confirmedGeneration~=equippedGeneration then
   t.State="WAITING_FOR_TARGETS";policy.choice="PER_TARGET";policy.reason="Hold experiment needs two dirty targets and confirmed native DOWN + color";return
  end
  t.State="PROBING";t.Started=os.clock();policy.choice="CONTINUOUS";policy.reason="Bounded real-target hold-and-move trial";return
 end
 if t.State~="PROBING" then return end
 if os.clock()-(t.Started or os.clock())>CFG.HoldProbeMaxSeconds then policy.fallback("Native hold trial timed out without sufficient evidence");return end
 if t.Attempts<CFG.StrategyMinAttempts then return end
 local ps,cs=policy.stats(p),policy.stats(c)
 local unique=0;for _ in pairs(t.UniqueTransferred) do unique+=1 end
 local reliable=t.RetainedProof and unique>=2 and cs.SuccessRate>=0.80 and cs.SuccessRate>=ps.SuccessRate-0.05
 -- Compare observed correction throughput over charged real work, not input API speed.
 if reliable and cs.CorrectionsPerSecond>ps.CorrectionsPerSecond*1.10 then
  t.State="CONFIRMED";policy.choice="CONTINUOUS";policy.locked=true
  policy.reason="Multiple genuine held transfers corrected; higher observed CPS at comparable reliability"
 elseif t.Attempts>=CFG.StrategyMaxProbeAttempts then
  policy.fallback(t.RetainedProof and "Hold trial did not beat PER_TARGET reliably" or "No multiple-target correction proof under one native DOWN")
 end
end
function policy.strategy()
 policy.session()
 if mode=="CIVIL WAR" then return "PER_TARGET",policy.civil end
 if CFG.ActivationStrategy=="PER_TARGET" then return "PER_TARGET",policy.normal.PER_TARGET end
 policy.decide()
 return policy.choice,policy.normal[policy.choice]
end
function policy.learn(arm,success,latency,service)
 -- Waiting for the next permitted DOWN is not PaintBucket response latency.
 -- Keep acquisition-to-color telemetry intact; train NORMAL dwell on native service only.
 if service and service.normal and service.nativeDownObservedAt and service.correctedAt then
  latency=math.max(0,service.correctedAt-service.nativeDownObservedAt)
 end
 if success then arm.streak=0;v82.learnSuccess(arm,latency,service)
 elseif service and service.validNoEffect then
  local e=service.entry;arm.streak+=1
  e.ExtraDwell=math.min(service.normal and CFG.NormalMissExtraDwellMax or CFG.EntryExtraDwellMax,(e.ExtraDwell or 0)+0.02)
  health.DwellIncreaseReason="qualified miss stays entry-local; shared baseline learns healthy successes only"
  v82.rejectedDwell["qualified no-effect"]=(v82.rejectedDwell["qualified no-effect"] or 0)+1
 end
 arm.dwell=math.clamp(arm.dwell,CFG.TargetDwellMin,CFG.TargetDwellMax)
end
function v7.lockTarget(entry)
	assert(not v7.lock,"Another target still owns the transaction")
	v7.lock=entry;v7.draw(entry)
	local now=os.clock()
	if v7.lastTargetId~=entry.id then
		v7.TargetSwitches+=1;table.insert(v7.switches,now)
		while #v7.switches>64 do table.remove(v7.switches,1) end
		local seq=v7.sequence or {};v7.sequence=seq;table.insert(seq,entry.id);if #seq>3 then table.remove(seq,1) end
		if #seq==3 and seq[1]==seq[3] and seq[1]~=seq[2] then
			v7.AtoBtoASequences+=1
			local pair=tostring(math.min(seq[1],seq[2]))..":"..tostring(math.max(seq[1],seq[2]))
			if v7.lastPair==pair then v7.SamePairOscillations+=1 else v7.SamePairOscillations=1;v7.lastPair=pair end
			if v7.SamePairOscillations>=2 then
				v7.OscillationDetected=true;v7.OscillationStops+=1;entry.forceFullService=true
				v7.sequence={};v7.SamePairOscillations=0
				health.OscillationPrevented+=1;health.PairCooldowns+=1
				for _,other in ipairs(entries) do
					if other.id==seq[2] then
						local weaker=(entry.ConsecutiveFailures or 0)>(other.ConsecutiveFailures or 0) and entry or other
						v82.defer(weaker,CFG.EntryCooldowns[3],"QUARANTINE")
						health.event(weaker,"ABAB","weaker target pair cooldown",nil,CFG.EntryCooldowns[3],"deferred")
						if weaker==entry then entry.forceFullService=nil;v7.lock=nil;v7.draw(entry);return false end
						break
					end
				end
			end
		end
	end
	v7.lastTargetId=entry.id
	return true
end
function v7.unlockTarget(entry)
	if v7.lock==entry then v7.lock=nil;v7.draw(entry) end
end
function v7.record(service,stalled)
	if service.record then return end
	local e=service.entry;local actual=e.part.Color;local normalized=colorsMatch(actual,service.target)
	local result=service.success and "SUCCESS" or service.result or (stalled and "VALID_NO_EFFECT" or "INTERRUPTED")
	local record={QueueOrigin=service.queueOrigin,EligibleQueueWaitMs=service.eligibleQueueMs or 0,DeferredCooldownAgeMs=service.deferredAgeMs or 0,
  QuarantineAgeMs=service.quarantineAgeMs or 0,TotalDirtyAgeMs=service.totalDirtyAgeMs or 0,
  DirtyEventToEligibleMs=service.deferredAgeMs or 0,EligibleToSchedulerPickMs=service.eligibleQueueMs or 0,
  SchedulerPickToAcquireMs=service.acquiredAt and (service.acquiredAt-service.started)*1000 or 0,
  GlobalDwellBefore=(service.dwellBefore or 0)*1000,GlobalDwellAfter=(service.dwellAfter or 0)*1000,
  DwellSampleRejected=v82.trainingReason(service) or "accepted",EntryId=e.id,Position=tostring(e.part.Position),Label=entryLabel(e),IntendedRGB=rgbText(service.target),
		PaletteAttributeBefore=rgbText(service.attributeBefore),AttributeAfterSet="NOT WRITTEN BY AUTOPAINTER",
		PaletteAttributeAfter=rgbText(service.attributeAfter),AttributeAfterEquip=rgbText(service.attributeAfterEquip),
		PaletteUISelection=service.paletteUISelection or "normal palette chosen by player",
		PaletteProof=service.paletteProof or "NORMAL exposed palette; no internal closure assumption",
		PreviousIntendedRGB=rgbText(service.previousIntended),ActualRGBBefore=rgbText(service.actualBefore),ActualRGBAfter=rgbText(actual),
		NormalizedMatch=normalized,DeltaRGB=colorDelta(actual,service.target),MouseTargetCorrect=mouse.Target==e.part,TargetAcquired=service.acquiredAt~=nil,ServiceQualified=service.qualified,FullWindowCompleted=service.validNoEffect==true,
		AcquisitionMs=service.acquiredAt and (e.lastAcquireSeconds or 0)*1000 or 0,QueueWaitMs=service.queueWaitMs or 0,
		PalettePreparationMs=service.paletteMs or 0,ServiceMs=service.validAt and math.max(0,os.clock()-service.validAt)*1000 or 0,AcquiredToCorrectMs=service.latency and service.latency*1000 or "unobserved",
		Result=result,ActualChanged=not colorsMatch(service.actualBefore,actual)}
 record.Civil=service.civil
 record.PaintMs=service.validAt and math.max(0,(service.paintEndedAt or service.endedAt or os.clock())-service.validAt)*1000 or 0
 record.ReleaseMs=service.releaseStartedAt and math.max(0,(service.endedAt or os.clock())-service.releaseStartedAt)*1000 or 0
 record.TotalDefenseResponseMs=service.attackAt and math.max(0,(service.success and e.lastCorrectedTime or os.clock())-service.attackAt)*1000 or 0
 record.DefenseResponseMs=service.success and service.attackAt and record.TotalDefenseResponseMs or nil
 record.TransactionId=service.id;record.Stage=service.stage or "PAINT_SERVICE"
 record.DirtyEpisode=service.episode;record.ExternalColorEventAt=service.externalEventAt
 record.EligibleAt=service.eligibleAt;record.SchedulerPickedAt=service.schedulerPickedAt
 record.TargetAcquiredAt=service.acquiredAt;record.NativeDownSentAt=service.nativeDownAt;record.NativeDownObservedAt=service.nativeDownObservedAt
 record.CorrectionObservedAt=service.correctedAt;record.RetainedNativeHold=service.retained;record.NativeHoldId=service.holdId
 record.EffectivePaintWindowMs=service.dwell*1000
 record.NativeDownSpacingMs=service.downSpacingMs;record.CadenceWaitMs=service.cadenceWaitMs or 0
 record.AcquiredToNativeDownMs=service.nativeDownAt and service.acquiredAt and math.max(0,service.nativeDownAt-service.acquiredAt)*1000 or 0
 record.NativeDownToCorrectionMs=service.correctedAt and service.nativeDownObservedAt and (service.correctedAt-service.nativeDownObservedAt)*1000 or nil
 record.ActiveCombatAtFinish=v82.activeCombat(e,os.clock())


	service.record=record
	if #v7.records>=20 then table.remove(v7.records,1) end;table.insert(v7.records,record)
	v7.ActualRGB,v7.TargetRGB,v7.DeltaRGB=record.ActualRGBAfter,record.IntendedRGB,record.DeltaRGB
	if service.civil and service.qualified and not normalized and record.ActualChanged then
		local previous=v7.previousCivilResult
		if previous and not colorsMatch(previous.target,service.target) and colorsMatch(previous.actual,actual) then
			v7.SuspectedStalePalette=true;palette.status="Different intended Civil colors yielded the same observed result; stopped for palette diagnosis"
			running=false;lastMessage=palette.status
		end
		v7.previousCivilResult={target=service.target,actual=actual}
	end
end
function policy.begin(entry,strategy,arm,started)
 v82.transactionId=(v82.transactionId or 0)+1
	local service={entry=entry,strategy=strategy,arm=arm,started=started,normal=mode=="NORMAL",
		generation=equippedGeneration,qualified=false,success=false,retained=false,dwell=math.min(CFG.TargetDwellMax,arm.dwell+(entry.ExtraDwell or 0)),benchmark=true,
		target=targetColor(entry),actualBefore=entry.part.Color,attributeBefore=paletteColor(),civil=mode=="CIVIL WAR",
		paletteValid=false,attackAt=entry.attackAt,queueWaitMs=entry.dirtyQueueInsertTime and (started-entry.dirtyQueueInsertTime)*1000 or 0}
	service.id=v82.transactionId
 if service.normal then
  -- Misses provide no evidence for longer waits. Recovery costs live in retry
  -- state, not the healthy shared window. The bounded hold probe is separate.
  service.dwell=arm.dwell
  if strategy=="CONTINUOUS" and policy.trial.State=="PROBING" then service.dwell=math.max(service.dwell,CFG.HoldProbeWindow) end
  v82.combat.NormalMissWindowMs=service.dwell*1000
 end
 v82.beginService(service)
	policy.current=service;entry.service=service
	return service
end
function policy.qualify(service)
	if service.qualified then return end
	service.qualified=true
	service.validAt=math.max(service.entry.acquiredAt or os.clock(),ownedInput and ownedInput.MouseObservedAt or os.clock())
	service.nativeDownAt=ownedInput and ownedInput.Started
 service.nativeDownObservedAt=ownedInput and ownedInput.MouseObservedAt
 service.holdId=ownedInput and ownedInput.HoldId
 pacing.record(ownedInput,service)
 service.entry.lastPaintAttempt=service.validAt
	service.entry.lastValidService=service
	service.method=ownedInput and ownedInput.Method or nil
	service.acquiredAt=service.entry.acquiredAt
	metrics.Attempts+=1
end
function health.finish(service)
 local entry=service.entry
 if service.success then service.result="SUCCESS";if service.episode==entry.dirtyEpisode then health.reset(entry,true) end;return end
 if service.interruption then service.result=service.interruption
 elseif not focused then service.result="FOCUS_LOST"
 elseif not activationTool or activationTool.Parent~=player.Character then service.result="TOOL_UNAVAILABLE"
 elseif releaseBlocked then service.result="RELEASE_RECOVERY"
 elseif not service.result then service.result="INTERRUPTED" end
 local reason=service.result
 if service.episode~=entry.dirtyEpisode then service.validNoEffect=false;return end
 if reason~="VALID_NO_EFFECT" then service.validNoEffect=false end
 if reason=="INTERRUPTED" then health.InterruptedAttempts+=1 end
 if reason=="VALID_NO_EFFECT" then health.ValidNoEffectAttempts+=1 end
 if reason=="CLEAN_BEFORE_DOWN" or not entry.active or not shouldTarget(entry) then return end
 -- Session/focus/tool interruptions do not quarantine a province or train timing.
 if reason=="FOCUS_LOST" or reason=="TOOL_UNAVAILABLE" or reason=="RELEASE_RECOVERY" or not running then return end
 entry.LastFailureReason=reason;entry.ConsecutiveFailures=(entry.ConsecutiveFailures or 0)+1
 entry.ConsecutiveAcquireFailures=reason=="ACQUIRE_FAILED" and (entry.ConsecutiveAcquireFailures or 0)+1 or 0
 entry.ConsecutiveTargetLosses=reason=="TARGET_LOST" and (entry.ConsecutiveTargetLosses or 0)+1 or 0
 entry.ConsecutiveValidNoEffects=reason=="VALID_NO_EFFECT" and (entry.ConsecutiveValidNoEffects or 0)+1 or 0
 if health.sameEntry==entry.id then health.sameFailures+=1 else health.sameEntry=entry.id;health.sameFailures=1 end
 health.LongestConsecutiveSameEntryFailures=math.max(health.LongestConsecutiveSameEntryFailures,health.sameFailures)
 local count=entry.ConsecutiveFailures;local cooldown=CFG.Retry;local action="defer; rotate eligible dirty work";local old=nil
 if reason~="VALID_NO_EFFECT" and count>=2 then old=health.invalidate(entry,count>=CFG.MaxConsecutiveEntryFailures);action="invalidate cursor" end
 if count>=CFG.MaxConsecutiveEntryFailures and not (reason=="VALID_NO_EFFECT" and v82.activeCombat(entry,os.clock())) then
  if count%CFG.MaxConsecutiveEntryFailures==0 then entry.quarantineLevel=math.min(#CFG.EntryCooldowns,(entry.quarantineLevel or 0)+1) end
  cooldown=CFG.EntryCooldowns[math.max(1,entry.quarantineLevel or 1)]
  health.TargetQuarantines+=1;action=reason=="VALID_NO_EFFECT" and "entry timing cooldown" or "invalidate cache; quarantine"
 end
 if v82.overload and reason=="VALID_NO_EFFECT" and count<3 then cooldown=count==1 and 0.10 or 0.20 end
 if reason=="TARGET_LOST" then
  if entry.activeCameraPose then v82.blacklistPose(entry,entry.activeCameraPose,"target lost after camera recovery");entry.activeCameraPose=nil end
  if count==1 then old=health.invalidate(entry,false);entry.sampleCursor=2 end
  if count>=3 then v82.data.TargetLostQuarantines+=1;entry.forceSafeCamera=true end
  v82.data.TargetLostRecoveries+=1
 end
 local liveCombat=reason=="VALID_NO_EFFECT" and v82.activeCombat(entry,os.clock())
 if liveCombat then cooldown=CFG.Retry;action="active color changes: rotate once, no pathological quarantine" end
 entry.failures=count;v82.defer(entry,cooldown,not liveCombat and count>=3 and "QUARANTINE" or "RETRY");entry.waitSince=os.clock()
 entry.lastServicedAt=os.clock();metrics.Deferred+=1
 if reason=="VALID_NO_EFFECT" then metrics.Stalled+=1;noEffect+=1 end
 health.event(entry,reason,action,old,cooldown,"deferred")
end
function policy.finish(service,stalled)
	if not service or service.finished then return end
	service.finished=true;service.endedAt=os.clock();policy.account()
 if service.entry.activeCameraPose then
  if not service.success then service.entry.LastGoodCameraSolution=nil end
  local c=v82.camera;c.paintWindow=c.paintWindow or {};table.insert(c.paintWindow,service.success)
  if #c.paintWindow>8 then table.remove(c.paintWindow,1) end
  local successes=0;for _,ok in ipairs(c.paintWindow) do if ok then successes+=1 end end
  if #c.paintWindow>=5 and successes/#c.paintWindow<0.3 then c.circuit="OPEN" end
 end
	health.finish(service)
 if not service.success then
  local reason=service.validNoEffect and "entry-only qualified no-effect" or "excluded "..tostring(service.result or "unqualified")
  v82.rejectedDwell[reason]=(v82.rejectedDwell[reason] or 0)+1
 end
	local arm=service.arm
	if service.qualified and service.benchmark and (service.success or (service.validNoEffect and service.paletteValid)) then
		local ended=os.clock();local latency=service.latency or 0
		arm.Attempts+=1;if service.success then arm.Successes+=1 end
		if service.retained then arm.RetainedAttempts+=1 end
		local sample={success=service.success,latency=latency,
			elapsed=math.max(0.001,arm.workSeconds-arm.lastSampleSeconds),service=math.max(0,ended-(service.validAt or ended))}
		service.sample=sample
		if stalled and not service.success then v7.FailedValidServices+=1;service.failedCounted=true end
		arm.lastSampleSeconds=arm.workSeconds
		if #arm.window>=CFG.StrategyWindow then table.remove(arm.window,1) end
		table.insert(arm.window,sample)
		policy.learn(arm,service.success,latency,service)
		metrics.CompletedServices+=1;metrics.ServiceTotal+=sample.service
		if service.normal then policy.observeTrial(service);policy.decide() end
	elseif service.qualified then arm.Aborted+=1;metrics.AbortedServices+=1;if service.normal then policy.observeTrial(service) end end
	if service.entry.service==service then service.entry.service=nil end
	if policy.current==service then policy.current=nil end
	v82.endService(service)
	v7.record(service,stalled)
	v7.unlockTarget(service.entry)
	if v82.restoreAfterService then v82.restoreAfterService() end
end

function v7.stats()
	local r={};for _,key in ipairs({"InputState","DuplicateDownStates","DuplicateUpStates","InputStateResyncs","SuccessfulInputResyncs","FailedInputResyncs","TargetQuarantines","CacheInvalidations","BadTargetRecoveries","InterruptedAttempts","ValidNoEffectAttempts","DwellIncreaseReason","LongestConsecutiveSameEntryFailures","OscillationPrevented","PairCooldowns"}) do r[key]=health[key] end
	r.GlobalDwellMs=(mode=="NORMAL" and policy.normal.PER_TARGET.dwell or policy.civil.dwell)*1000
	r.CurrentEntryExtraDwellMs=currentEntry and (currentEntry.ExtraDwell or 0)*1000 or 0
	r.ConsecutiveFailuresCurrentTarget=currentEntry and (currentEntry.ConsecutiveFailures or 0) or 0
	r.MaxDirtyAgeMs=0;for _,e in ipairs(dirty) do r.MaxDirtyAgeMs=math.max(r.MaxDirtyAgeMs,(os.clock()-(e.dirtySince or os.clock()))*1000) end
	for _,key in ipairs({"RawMismatchButNormalizedMatch","ActualRGB","TargetRGB","DeltaRGB","CleanSkippedBeforeCursor","CleanSkippedBeforeDown","CursorMovesToAlreadyCleanProvince","CursorMovesTriggeredByReconciliation","ReleasesSent","ReleasesObserved","ReleasesConfirmedByButtonState","ReleaseTimeouts","TargetSwitches","AtoBtoASequences","SamePairOscillations","OscillationDetected","OscillationStops","ServicesPreempted","FailedValidServices","PaletteFailures","SuspectedStalePalette","LateCorrections"}) do r[key]=v7[key] end
	local count=0;for _,at in ipairs(v7.switches) do if os.clock()-at<=1 then count+=1 end end;r.TargetSwitchesPerSecond=count
	r.ActiveTargetLock=v7.lock and entryLabel(v7.lock) or "none"
	local times=table.clone(v7.defense);table.sort(times)
	r.MedianDefenseResponseMs=#times>0 and times[math.ceil(#times*0.5)] or 0
	r.P90DefenseResponseMs=#times>0 and times[math.ceil(#times*0.9)] or 0
	r.AverageDefenseResponseMs=metrics.FreshAttackCorrections>0 and metrics.AttackResponseTotal/metrics.FreshAttackCorrections or 0
	r.FastestDefenseResponseMs=metrics.MinimumAttackResponseMs;r.SlowestDefenseResponseMs=metrics.MaximumAttackResponseMs
	local queue,pal,paint=0,0,0
	for _,record in ipairs(v7.records) do queue+=record.QueueWaitMs;pal+=record.PalettePreparationMs;paint+=record.ServiceMs end
	r.AverageQueueWaitMs=#v7.records>0 and queue/#v7.records or 0
	r.AveragePalettePreparationMs=#v7.records>0 and pal/#v7.records or 0
	r.AveragePaintServiceMs=#v7.records>0 and paint/#v7.records or 0
	r.ReconciliationRepairs=metrics.ReconciliationFinds
	for k,value in pairs(palette.summary()) do r[k]=value end
	return r
end
function v7.report()
	local lines={"V7 CORRECTNESS / RELEASE / COLOR AUTHORITY", "Server -> client replication latency is unknown without a server timestamp.",
		"RawMismatchButNormalizedMatch counts comparisons, not distinct provinces. Tolerance: at most 1 RGB byte/channel."}
	local stats=v7.stats();local keys={};for key in pairs(stats) do table.insert(keys,key) end;table.sort(keys)
	for _,key in ipairs(keys) do table.insert(lines,key.."="..tostring(stats[key])) end
	table.insert(lines,"CIVIL ASSIGNMENTS (native palette controls, not arbitrary RGB)")
	for _,e in ipairs(entries) do table.insert(lines,entryLabel(e).." | AssignedCivilRGB="..rgbText(e.civilColor).." | AssignedCivilColorKey="..colorKey(e.civilColor)) end
	table.insert(lines,"LAST 20 TARGET TRANSACTIONS (normalized local observations; not server acknowledgments)")
	local fields={"EntryId","Position","IntendedRGB","PaletteAttributeBefore","AttributeAfterSet","PaletteAttributeAfter","AttributeAfterEquip","PaletteUISelection","PaletteProof","PreviousIntendedRGB","ActualRGBBefore","ActualRGBAfter","DeltaRGB","NormalizedMatch","MouseTargetCorrect","TargetAcquired","ServiceQualified","FullWindowCompleted","ActualChanged","QueueWaitMs","AcquisitionMs","PalettePreparationMs","ServiceMs","AcquiredToCorrectMs","PaintMs","ReleaseMs","DefenseResponseMs","Result","QueueOrigin","EligibleQueueWaitMs","DeferredCooldownAgeMs","QuarantineAgeMs","TotalDirtyAgeMs","DirtyEventToEligibleMs","EligibleToSchedulerPickMs","SchedulerPickToAcquireMs","GlobalDwellBefore","GlobalDwellAfter","DwellSampleRejected","TotalDefenseResponseMs","TransactionId","Stage","DirtyEpisode","ExternalColorEventAt","EligibleAt","SchedulerPickedAt","TargetAcquiredAt","NativeDownSentAt","NativeDownObservedAt","CorrectionObservedAt","RetainedNativeHold","NativeHoldId","EffectivePaintWindowMs","AcquiredToNativeDownMs","NativeDownToCorrectionMs","ActiveCombatAtFinish","NativeDownSpacingMs","CadenceWaitMs"}
	for _,record in ipairs(v7.records) do
		table.insert(lines,record.Label)
		for _,key in ipairs(fields) do table.insert(lines,"  "..key.."="..tostring(record[key])) end
	end
	table.insert(lines,"PER-ENTRY HEALTH (all protected entries)")
	for _,e in ipairs(entries) do
		table.insert(lines,string.format("%s | ConsecutiveAcquireFailures=%d | ConsecutiveTargetLosses=%d | ConsecutiveValidNoEffects=%d | LastFailureReason=%s | RetryAfter=%.3f | CacheInvalidations=%d | RecoverySuccesses=%d | EntryExtraDwellMs=%.1f",entryLabel(e),e.ConsecutiveAcquireFailures or 0,e.ConsecutiveTargetLosses or 0,e.ConsecutiveValidNoEffects or 0,tostring(e.LastFailureReason),e.retryAt,e.CacheInvalidations or 0,e.RecoverySuccesses or 0,(e.ExtraDwell or 0)*1000))
	end
	table.insert(lines,"LAST 20 RECOVERY EVENTS")
	for _,event in ipairs(health.events) do
		table.insert(lines,string.format("Entry=%s At=%.3f Reason=%s Action=%s OldCache=%s CooldownMs=%.1f Outcome=%s",tostring(event.Entry),event.At,event.Reason,event.Action,event.OldCache,event.CooldownMs,event.Outcome))
	end
	return table.concat(lines,"\n")
end

function palette.performance()
 local r=table.clone(palette.metrics)
 for k,v in pairs(palette.bindingMetrics) do r[k]=v end
 r.LastPaletteRebindReason=palette.bindingReason
 local state,bound,pending,missing,verified=palette.generationStatus()
 r.PaletteGenerationState=state;r.ExpectedVerifiedNativeCapacity=palette.nativeExpected
 r.NativeVerifiedThisSession=verified;r.PaletteBlocked=palette.blocked~=nil
 r.PaletteBlockedReason=palette.blocked and palette.blocked.reason or "none"
 r.PaletteBlockedDurationMs+=palette.blocked and (os.clock()-palette.blocked.at)*1000 or 0
 r.OpenerState=palette.verifiedOpener() and "VERIFIED_EQUIVALENT_BINDING" or "UNVERIFIED_OR_UNAVAILABLE"
 r.CloserState=palette.closer and palette.closer.semanticVerified and palette.valid(palette.closer) and "VERIFIED_EQUIVALENT_BINDING" or "UNVERIFIED_OR_UNAVAILABLE"
 r.AutoCloseEffective=palette.verifiedOpener() and "AUTO" or "KEEP OPEN (no verified opener)"
 r.AveragePaletteSelectionMs=r.PaletteSelections>0 and r.PaletteSelectionTotal/r.PaletteSelections or 0
 local arm=policy.stats(policy.civil)
 r.CivilSuccessfulPaints=arm.Successes;r.CivilCorrectionsPerSecond=arm.CorrectionsPerSecond;r.AverageCivilServiceMs=arm.AverageServiceMs
 local count,defense,defenseN,queue,acq,paint,release,pal=0,0,0,0,0,0,0,0
 for _,record in ipairs(v7.records) do if record.Civil then
  count+=1;queue+=record.QueueWaitMs;acq+=record.AcquisitionMs;paint+=record.PaintMs;release+=record.ReleaseMs;pal+=record.PalettePreparationMs
  if record.DefenseResponseMs then defense+=record.DefenseResponseMs;defenseN+=1 end
 end end
 r.AverageCivilDefenseResponseMs=defenseN>0 and defense/defenseN or 0
 r.AverageCivilPaletteMs=count>0 and pal/count or 0
 r.CivilTimingSampleCount=count;r.CivilDefenseSampleCount=defenseN
 r.AverageCivilQueueMs=count>0 and queue/count or 0;r.AverageCivilAcquisitionMs=count>0 and acq/count or 0
 r.AverageCivilPaintMs=count>0 and paint/count or 0;r.AverageCivilReleaseBoundaryMs=count>0 and release/count or 0
 r.PaletteStep=palette.current.PaletteStep;r.ResumeRequired=palette.resumeNeeded
 return r
end
function palette.baseline()
 local p=policy.stats(policy.normal.PER_TARGET)
 return string.format("NORMAL BASELINE COMPARISON (user-verified v7; informational, not a benchmark guarantee)\nBaseline RecentSuccessRate=100%% RecentCorrectionsPerSecond=16.15 AvgServiceMs=49.5 AvgAcquiredToColorMs=45.4\nCurrent WindowAttempts=%d WindowSuccesses=%d SuccessRate=%.2f%% CorrectionsPerSecond=%.3f AvgServiceMs=%.3f AvgAcquiredToColorMs=%.3f\nNo regression/improvement conclusion from tiny or unmatched samples; compare equal workload/server conditions.",p.WindowAttempts,p.WindowSuccesses,p.SuccessRate*100,p.CorrectionsPerSecond,p.AverageServiceMs,p.AverageAcquiredToColorMs)
end
function v82.stats()
 local now=os.clock();v82.updateLoad(now)
 local r=table.clone(v82.data)
 for k,v in pairs(v82.combat) do r[k]=v end
 for k,v in pairs(pacing.stats()) do r[k]=v end
 local trial=policy.trial;r.NativeHoldExperimentState=trial.State;r.NativeHoldTransferredSuccesses=trial.RetainedSuccesses
 r.NativeHoldRetainedMisses=trial.RetainedMisses;r.NativeHoldMultiTargetProof=trial.RetainedProof;r.NativeHoldFallbackReason=trial.FallbackReason
 r.CooldownBenchmarkActive=benchmark.active;r.CooldownBenchmarkState=benchmark.state
 r.NativeHoldProbeAttempts=trial.Attempts;r.NativeHoldObservedAttempts=trial.ObservedAttempts;r.ActivationStrategySetting=CFG.ActivationStrategy
 for k,value in pairs(v82.queue) do r[k]=value end
 r.Overload=v82.overload;r.TimeInOverloadMs+=v82.overloadAt and (now-v82.overloadAt)*1000 or 0
 r.TargetsInPathologicalGroup=0
 for _,entry in ipairs(entries) do if entry.groupId and v82.groups[entry.groupId] then r.TargetsInPathologicalGroup+=1 end end
 local elapsed=math.max(1,now-v82.startedAt)
 r.CurrentReconciliationInterval=v82.reconcileInterval;r.ReconciliationChecksPerSecond=metrics.ReconciliationChecks/elapsed
 r.RepairsPer10kChecks=metrics.ReconciliationChecks>0 and metrics.ReconciliationFinds*10000/metrics.ReconciliationChecks or 0
 r.PaletteRebindAttemptsPerSecond=palette.bindingMetrics.PaletteRebindAttempts/elapsed
 r.SchedulerSelectionsPerSecond=v82.data.SchedulerSelections/elapsed
 r.RejectedDwellSamplesByReason="";local keys={};for k in pairs(v82.rejectedDwell) do table.insert(keys,k) end;table.sort(keys)
 for _,k in ipairs(keys) do r.RejectedDwellSamplesByReason..=k..":"..v82.rejectedDwell[k].."; " end
 for k,value in pairs(v82.camera.data) do r[k]=value end
 r.CameraControlMode=v82.camera.mode;r.CameraCircuitBreaker=v82.camera.circuit
 r.CameraMoveSuccessRate=r.CameraMovesApplied>0 and r.CameraMoveTargetAcquisitions/r.CameraMovesApplied or 0
 r.CameraMovePaintSuccessRate=r.CameraMovesApplied>0 and r.CameraMoveSuccessfulPaints/r.CameraMovesApplied or 0
 r.CameraFallbackSuccessRate=r.CameraMoveSuccessRate
 r.AcquisitionState=currentEntry and currentEntry.AcquisitionState or lastAcquireDetail
 if now>=(v82.percentileAt or 0) then
  v82.percentileAt=now+0.5;v82.percentiles={}
  for _,pair in ipairs({{"NORMAL",v82.normalSamples},{"CIVIL",v82.civilSamples}}) do
   local groups={Queue={},FreshAttackQueue={},BootstrapQueue={},BulkExistingQueue={},RetryQueue={},TargetRecoveryQueue={}}
   for _,sample in ipairs(pair[2]) do
    table.insert(groups.Queue,sample.eligible)
    local origin=sample.origin;local key=origin=="FRESH_ATTACK" and "FreshAttackQueue" or origin=="BOOTSTRAP_DIRTY" and "BootstrapQueue" or origin=="BULK_EXISTING_DIRTY" and "BulkExistingQueue" or origin=="TARGET_RECOVERY" and "TargetRecoveryQueue" or "RetryQueue"
    table.insert(groups[key],sample.eligible)
   end
   for group,values in pairs(groups) do for _,q in ipairs({50,90,99}) do v82.percentiles[pair[1]..group.."P"..q.."Ms"]=v82.percentile(table.clone(values),q/100) end end
  end
 end
 for k,value in pairs(v82.percentiles or {}) do r[k]=value end
 r.GeneratedColorCreation="PROVEN";r.GeneratedColorApplicationViaCurrentNativePath="UNVERIFIED"
 r.GeneratedColorSupport="RGB creation proven by OG code; native application beyond verified swatches unverified. Two Picker candidates rejected, not a generation limit."
 r.ExpandedCustomUICandidates=palette.custom and #palette.custom.inventory or 0
 local custom=0;for _ in pairs(palette.customCandidates or {}) do custom+=1 end;r.CustomColorUICandidates=custom
 r.SelectionStrokeActive=v82.selection and v82.selection.held or false
 r.SelectionAdds=v82.selection and v82.selection.adds or 0;r.SelectionRemoves=v82.selection and v82.selection.removes or 0
 return r
end
local function reportPerformance()
	policy.account()
	local now = os.clock(); local duration = runSeconds + (runStartedAt and now-runStartedAt or 0)
	local acq, corrected = 0, 0
	for _, bin in pairs(rateBins) do if now-bin.tick/2 < 5 then acq+=bin.Acquisitions;corrected+=bin.Corrections end end
	local result = table.clone(metrics); local window=math.min(5,math.max(1,duration))
	result.ActiveTarget=currentEntry and currentEntry.active and entryLabel(currentEntry) or "none"
	result.DirtyCount=#dirty;result.AcquisitionsPerSecond=acq/window;result.CorrectionsPerSecond=corrected/window
	result.AverageAcquisitionMs=metrics.Acquisitions>0 and metrics.AcquireTotal*1000/metrics.Acquisitions or 0
	result.AverageAcquiredToColorMs=metrics.Corrections>0 and metrics.ColorTotal*1000/metrics.Corrections or 0
	result.AverageSwitchMs=metrics.Switches>0 and metrics.SwitchTotal*1000/metrics.Switches or 0
	result.VirtualInputHold=held and ownedInput ~= nil and ownedInput.Method==primaryMethod and not ownedInput.ReleaseSent
	result.SessionConfirmed=confirmedGeneration==equippedGeneration
	result.Runtime=duration;result.AutoPainterRPCs=0
	result.OverallCorrectionsPerSecond=duration>0 and metrics.Corrections/duration or 0
	result.ActivationStrategy=mode=="CIVIL WAR" and "PER_TARGET (CIVIL WAR)" or (CFG.ActivationStrategy=="PER_TARGET" and "PER_TARGET" or policy.choice)
	result.StrategyConfigured=CFG.ActivationStrategy
	result.StrategyDecisionCached=policy.locked
	result.StrategyDecisionReason=mode=="CIVIL WAR" and "Separate palette colors require fresh per-target activation" or (CFG.ActivationStrategy=="PER_TARGET" and "PER_TARGET pinned; failed live hold transfers do not trigger automatic experiments" or policy.reason)
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
	for key,value in pairs(v7.stats()) do result[key]=value end
	for key,value in pairs(palette.performance()) do result[key]=value end
	for key,value in pairs(v82.stats()) do result[key]=value end
	result.Strategies={PER_TARGET=policy.stats(policy.normal.PER_TARGET),CONTINUOUS=policy.stats(policy.normal.CONTINUOUS),CIVIL_WAR=policy.stats(policy.civil)}
	return result
end
local function rebuildDirty()
	for _,entry in ipairs(entries) do syncDirty(entry,"rebuild") end
	wakeWork()
end
noteCorrection = function(entry)
	if not colorsMatch(entry.part.Color,targetColor(entry)) then return end
	local service=entry.service or entry.lastValidService
	if not service or service.success or not colorsMatch(service.target,targetColor(entry)) then return end
	if not service.paletteValid then return end
	local releasing=service.qualified and ownedInput and ownedInput.ReleaseSent
	if service.finished or releasing then
		-- Replication may arrive during the paired UP boundary, before policy.finish.
		local boundary=service.endedAt or (ownedInput and ownedInput.ReleaseAt) or 0
		if not service.qualified or os.clock()-boundary>CFG.LateConfirmation then return end
	else
		if currentEntry~=entry or not held or not ownedInput or ownedInput.Kind=="PALETTE"
			or ownedInput.ReleaseSent or mouse.Target~=entry.part then return end
		inputEvidence(ownedInput);if not ownedInput.MouseObserved then return end
		if not entry.acquiredAt then entry.earlyCorrectionAt=os.clock();return end
		policy.qualify(service)
	end
	local observedAt=entry.earlyCorrectionAt or os.clock()
	local latency=math.max(0,observedAt-(service.acquiredAt or entry.acquiredAt or observedAt))
	entry.corrected=true;v82.account(entry,observedAt);health.reset(entry,true);entry.lastCorrectedTime=observedAt
	corrections+=1;metrics.Corrections+=1;metrics.ColorTotal+=latency;bumpRate("Corrections")
	service.success,service.latency,service.paletteValid=true,latency,true;service.correctedAt=observedAt
 service.correctionHoldValid=ownedInput~=nil and not ownedInput.ReleaseSent and not ownedInput.ExternalUp and UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1)
 if entry.activeCameraPose and service.qualified then v82.cameraResult(entry,true,true) end
	if service.finished then
		service.finishedLate=true;v82.groupSuccess(entry)
		v7.LateCorrections+=1
		if service.sample and not service.sample.success then
			service.sample.success=true;service.sample.latency=latency;service.arm.Successes+=1
			if service.failedCounted then v7.FailedValidServices=math.max(0,v7.FailedValidServices-1);service.failedCounted=false end
		end
		if service.record then
			service.record.Result="SUCCESS_LATE";service.record.DwellSampleRejected="late confirmation";service.record.CorrectionObservedAt=observedAt;service.record.NativeDownToCorrectionMs=service.nativeDownObservedAt and math.max(0,observedAt-service.nativeDownObservedAt)*1000 or nil;service.record.TotalDefenseResponseMs=service.attackAt and (observedAt-service.attackAt)*1000 or 0;service.record.NormalizedMatch=true;service.record.ActualRGBAfter=rgbText(entry.part.Color)
			service.record.DeltaRGB=colorDelta(entry.part.Color,service.target);service.record.AcquiredToCorrectMs=latency*1000
		end
	end
	local attack=service.attackAt or entry.attackAt
	if attack then
		local ms=math.max(0,observedAt-attack)*1000
		metrics.FreshAttackCorrections+=1;metrics.AttackResponseTotal+=ms
		if metrics.FreshAttackCorrections==1 then metrics.MinimumAttackResponseMs=ms else metrics.MinimumAttackResponseMs=math.min(metrics.MinimumAttackResponseMs,ms) end
		metrics.MaximumAttackResponseMs=math.max(metrics.MaximumAttackResponseMs,ms)
		if #v7.defense>=64 then table.remove(v7.defense,1) end;table.insert(v7.defense,ms);entry.attackAt=nil
	end
	v7.sequence={};v7.lastPair=nil;v7.SamePairOscillations=0
	activation.ColorChanged,activation.TargetColorObserved=true,true
	if service.method==primaryMethod and service.generation==equippedGeneration then
		activation.Preferred=primaryMethod;confirmedGeneration=equippedGeneration;primaryFailures=0;holdStalls=0
	end
	activation.Status="Normalized target color locally observed after valid native activation"
	switchedAt=observedAt
end
syncDirty = function(entry,source)
	metrics.QueueEvaluations+=1
	if not entry.active then return end
	if not validProvince(entry.part) then removeProvince(entry.part);return end
	local now,color,target=os.clock(),entry.part.Color,targetColor(entry)
 if benchmark.active and benchmark.observe then benchmark.observe(entry) end
	local wasDirty=entry.dirtyIndex~=nil
	local changed=not colorsMatch(entry.lastSeenColor,color)
	local wrong=target~=nil and not colorsMatch(color,target) -- Eligibility uses Color only; never Mouse.Target.
	local colorEvent=source=="color"
	local hovered=false
	if colorEvent then
		metrics.ColorEventsReceived+=1;entry.lastColorEventTime=now
		hovered=mouse.Target==entry.part -- Diagnostics only; not used by eligibility.
	end
	entry.lastSeenColor=color
	if wrong and changed then
  if colorEvent then entry.observedWrongChangeAt=now;entry.observedWrongChangeVersion=(entry.observedWrongChangeVersion or 0)+1;if wasDirty then v82.combat.CoalescedCombatChanges+=1 end end
		entry.lastWrongColorChange=now;entry.latestDirtyTimestamp=now;entry.latestExternalChangeTime=now
		if wasDirty and colorEvent then v82.data.CoalescedDirtyEvents+=1;entry.attackCount=(entry.attackCount or 0)+1 end
	end
	if wrong then
		addDirty(entry,now)
		if not wasDirty and entry.wasClean and (colorEvent or source=="reconcile") then
			entry.attackAt=now;entry.freshAttackAt=now;entry.externalEventAt=now;entry.eligibleAt=now
   if mode~="NORMAL" then entry.failures,entry.retryAt=0,0 end
			v82.attack(entry,now)
   entry.externalEventAt=colorEvent and now or nil;entry.freshDetection=source
			markFresh(entry,now)
		end
		if colorEvent then
			if not hovered then metrics.DirtyEventsWithoutHover+=1 end
			local latency=(os.clock()-now)*1000
			entry.localQueueLatencyMs=latency
			metrics.ColorEventQueued+=1;metrics.ColorEventQueueTotal+=latency
			metrics.MaxColorEventToDirtyQueueMs=math.max(metrics.MaxColorEventToDirtyQueueMs,latency)
			local record={Path=entryLabel(entry),Time=now,HoveredAtEvent=hovered,
				LocalColorEventReceivedAt=now,LocalDirtyQueuedAt=entry.dirtyQueueInsertTime,LocalColorEventToQueueMs=latency,QueueWasAlreadyDirty=wasDirty,
				DirtyQueued=entry.dirtyIndex~=nil,QueueLatencyMs=latency,Color=tostring(color),Target=tostring(target)}
			if #eventLog>=24 then table.remove(eventLog,1) end
			table.insert(eventLog,record);if not hovered then lastOffHoverEvent=record end
		end
	else
		removeDirty(entry);entry.failures,entry.retryAt=0,0
		if wasDirty then entry.lastCorrectedTime=now end
		if target and not benchmark.active then noteCorrection(entry) end
		if not entry.service then entry.attackAt=nil end
	end
	if source=="reconcile" and wasDirty~=wrong then metrics.ReconciliationFinds+=1 end
	entry.wasClean=not wrong
	v7.draw(entry)
	if colorEvent or wasDirty~=wrong then wakeWork() end
end
local function reconcile()
	local before=metrics.ReconciliationFinds;local now=os.clock()
	-- Queue repair only. The single worker owns all input/camera operations.
	local i=1
	while i<=#entries do
		local entry=entries[i];metrics.ReconciliationChecks+=1;syncDirty(entry,"reconcile")
		if entries[i]==entry then i+=1 end
	end
 if metrics.ReconciliationFinds>before then
  v82.reconcileRapidUntil=now+CFG.RepairReconcileHold;v82.reconcileInterval=CFG.RepairReconcile;v82.reconcileZero=0
 elseif now<(v82.reconcileRapidUntil or 0) then v82.reconcileInterval=CFG.RepairReconcile
 else
  v82.reconcileZero+=#entries
  v82.reconcileInterval=v82.reconcileZero>=10000 and 2 or now-v82.startedAt>=5 and CFG.HealthyReconcile or 0.75
 end
end
local function dirtyEventReport()
	local lines={"HOVER-INDEPENDENT DIRTY EVENTS (callback time; not server replication time)",
		"Eligibility = not colorsMatch(province.Color, targetColor(entry)); hover is diagnostic only."}
	local e=lastOffHoverEvent
	if e then
		table.insert(lines,string.format("Last off-cursor province: %s\nColorChanged received=true\nHovered at event=%s\nDirty queued=%s\nQueue latency=%.3f ms\nLocalColorEventReceivedAt=%.3f\nLocalDirtyQueuedAt=%.3f\nLocalColorEventToQueueMs=%.3f\nQueueWasAlreadyDirty=%s",e.Path,tostring(e.HoveredAtEvent),tostring(e.DirtyQueued),e.QueueLatencyMs,e.Time,e.LocalDirtyQueuedAt,e.LocalColorEventToQueueMs,tostring(e.QueueWasAlreadyDirty)))
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
	v82.updateLoad(now);expireFresh(now);decisionSerial+=1
	local best,bestTier,bestDistance,bestScore,bestPalette=nil,math.huge,math.huge,-math.huge,-1
	local cursor=UserInputService:GetMouseLocation()
	local exhausted=false;local minimumRetry=math.huge
	local function consider(entry: any)
		if entry.decisionSerial==decisionSerial then return end
		entry.decisionSerial=decisionSerial
		if not entry.active then return end
		if now<entry.retryAt then minimumRetry=math.min(minimumRetry,entry.retryAt);return end
		if mode=="CIVIL WAR" and palette.blocked and not colorsMatch(paletteColor(),entry.civilColor) then
   entry.paletteBlocked=true;palette.bindingMetrics.SuppressedPaletteUnavailableRetries+=1
   minimumRetry=math.min(minimumRetry,now+0.2);return
  end
  entry.paletteBlocked=nil
  metrics.Candidates+=1
		if not validProvince(entry.part) then removeProvince(entry.part);return end
		if colorsMatch(entry.part.Color,targetColor(entry)) then v7.CleanSkippedBeforeCursor+=1;syncDirty(entry,"check");return end
		local candidate,budget=visiblePoint(entry)
		if budget then exhausted=true;return end
		candidate=candidate or {entry=entry,tier=entry.lastCamera and 2 or 3}
		local tier=candidate.tier
		if entry.freshLinked then tier=-1 end
		-- Aging eventually wins even against a stream of freshly attacked targets.
		if now-entry.waitSince>=CFG.PriorityAge then tier=-2 end
		local distance=candidate.point and ((candidate.point.X-cursor.X)^2+(candidate.point.Y-cursor.Y)^2)
			or (entry.part.Position-Workspace.CurrentCamera.CFrame.Position).Magnitude^2
		if v82.overload then
   local urgency,score,same=v82.rank(entry,now)
   if urgency<bestTier or (urgency==bestTier and (score>bestScore+0.25 or math.abs(score-bestScore)<=0.25 and (same>bestPalette or same==bestPalette and distance<bestDistance))) then
    best,bestTier,bestScore,bestPalette,bestDistance=candidate,urgency,score,same,distance
   end
   return
  end
		if tier<bestTier or (tier==-2 and bestTier==-2 and entry.waitSince<best.entry.waitSince) or (tier==bestTier and (tier~=-2 or entry.waitSince==best.entry.waitSince) and (distance<bestDistance or
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
	-- Read-only lookahead gets reconsidered, never ownership of input or palette.
 if v82.lookahead and now-v82.lookahead.at<0.25 then consider(v82.lookahead.entry) end
 if exhausted then return best end
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
-- Cadence is independent of dwell. The initial floor uses the user's 40/40 row
-- (native spacing P90 225.02 ms), rounded upward; it is not a discovered minimum.
function pacing.context()
 local upgrades=player:FindFirstChild("Upgrades");local level=upgrades and upgrades:FindFirstChild("EquippedPaintCooldown")
 local ok,value=pcall(function() return level and level.Value end)
 return ok and value~=nil and tostring(value) or "unavailable"
end
function pacing.record(owner,service)
 if not owner or not owner.MouseObservedAt then return end
 local list=owner.PaintMode=="NORMAL" and pacing.normal or pacing.civil
 if not owner.CadenceRecorded then
  owner.CadenceRecorded=true
  if pacing.lastDown and pacing.lastTool==owner.Tool then
   local ms=(owner.MouseObservedAt-pacing.lastDown)*1000
   owner.CadenceSpacingMs=ms
   v82.push(list,ms,64)
  end
  pacing.lastDown=owner.MouseObservedAt;pacing.lastTool=owner.Tool
 end
 if service then service.downSpacingMs=owner.CadenceSpacingMs end
end
function pacing.wait(entry,token,service)
 if benchmark.active or mode~="NORMAL" or service.strategy~="PER_TARGET" then return true end
 local context=pacing.context()
 if pacing.calibratedContext and context~=pacing.calibratedContext then
  pacing.interval=CFG.NormalDownSpacingDefault;pacing.calibratedContext=nil;pacing.calibratedGeneration=nil;pacing.source="UPGRADE_CHANGED: benchmark again"
 elseif pacing.calibratedGeneration and pacing.calibratedGeneration~=equippedGeneration then
  pacing.interval=CFG.NormalDownSpacingDefault;pacing.calibratedContext=nil;pacing.calibratedGeneration=nil;pacing.source="TOOL_SESSION_CHANGED: benchmark again"
 end
 local started=os.clock();local deadline=pacing.lastTool==activationTool and (pacing.lastDown or -math.huge)+pacing.interval or -math.huge
 while os.clock()<deadline do
  if not liveToken(token) or not shouldTarget(entry) or mouse.Target~=entry.part or not activationTool or activationTool.Parent~=player.Character then return false end
  RunService.Heartbeat:Wait()
 end
 service.cadenceWaitMs=(os.clock()-started)*1000
 return liveToken(token) and shouldTarget(entry) and mouse.Target==entry.part
end
function pacing.stats()
 local r={NormalMinimumDownSpacingMs=pacing.interval*1000,NormalCadenceSource=pacing.source,NormalCadenceCalibratedContext=pacing.calibratedContext or "none",NormalCadenceToolGeneration=pacing.calibratedGeneration or "none"}
 for name,values in pairs({Normal=pacing.normal,Civil=pacing.civil}) do
  local sum=0;for _,v in ipairs(values) do sum+=v end
  r[name.."ActualDownSpacingMeanMs"]=#values>0 and sum/#values or 0
  r[name.."ActualDownSpacingMinMs"]=v82.percentile(table.clone(values),0)
  r[name.."ActualDownSpacingP90Ms"]=v82.percentile(table.clone(values),.9)
  r[name.."ActualDownSpacingMaxMs"]=v82.percentile(table.clone(values),1)
 end
 return r
end

local function ownedTargetSafe(entry,previous)
	if not ownedInput or ownedInput.ReleaseSent then return true end
	local actual=mouse.Target
	return actual==entry.part or (previous and actual==previous and lookup[previous] and validProvince(previous))
end
local function moveCursor(candidate,token)
	local entry,point=candidate.entry,candidate.point
	if not shouldTarget(entry) then v7.CleanSkippedBeforeCursor+=1;syncDirty(entry,"check");return false end
	if not liveToken(token) or not entry.active or not validProvince(entry.part) then return false end
	local before=mouse.Target
	if not ownedTargetSafe(entry,before) then if not settleRelease() then return false end end
	local moved=true
	if mouse.Target~=entry.part or not guiClear(UserInputService:GetMouseLocation()) then
		local destination=Vector2.new(point.X,point.Y)
		local ok
		local readable, mover = pcall(function() return virtualInput and virtualInput.SendMousePosition end)
		if readable and type(mover)=="function" then
			if not shouldTarget(entry) then v7.CleanSkippedBeforeCursor+=1;syncDirty(entry,"check");return false end
			ok=callInput(function() virtualInput:SendMousePosition(destination) end)
			if not ok then
				settleRelease();lastAcquireDetail="Virtual cursor movement rejected; recovering through camera";return false
			end
		end
		if not ok then
			-- Movement recovery is serialized and released before trying a different API.
			if not settleRelease() then return false end
			if type(mousemoverel)=="function" then
				if not shouldTarget(entry) then v7.CleanSkippedBeforeCursor+=1;syncDirty(entry,"check");return false end
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
 if not shouldTarget(entry) then v7.CleanSkippedBeforeCursor+=1;syncDirty(entry,"check");return false end
 local initialCamera=Workspace.CurrentCamera;local initialPose=initialCamera.CFrame;local recoveryDeadline=os.clock()+0.32
 local function usable()
  return liveToken(token) and shouldTarget(entry) and os.clock()<recoveryDeadline and activationTool and activationTool.Parent==player.Character
   and Workspace.CurrentCamera==initialCamera and initialCamera.CFrame==initialPose
 end
 local function attempt(point)
  if not point or not usable() then return false end
  metrics.CursorAcquireAttempts+=1
  if moveCursor(point,token) then metrics.CursorAcquireSuccesses+=1;entry.CursorOnlyFailuresSinceSuccess=0;v82.acquisitionState(entry,"ACQUIRE_OK");return true end
  v82.acquisitionState(entry,"ACQUIRE_TEMP_MISMATCH");return false
 end
 if attempt(candidate.point and candidate) then return true end
 if not usable() then return false end
 if candidate.point then
  v82.acquisitionState(entry,"ACQUIRE_STALE_CACHE");health.invalidate(entry,false)
 end
 geometry(entry)
 -- Current-camera proof: fresh projection, all alternate surface points, bounded
 -- screen-space offsets, then a fresh frame and final projection/real-target check.
 local completedPasses=0
 for pass=1,2 do
  if not usable() then return false end
  entry.lastFrame=nil -- proof must not recycle a cached projection
  local used=0
  while used<#entry.surfacePoints do
   local index=used+1
   local point,budget=probe(entry,index)
   if budget then
    v82.acquisitionState(entry,"ACQUIRE_PROJECTION_BUDGET_EXHAUSTED")
    waitWork();if not usable() then return false end
    point,budget=probe(entry,index)
    if budget then return false end -- no false 'unreachable' verdict
   end
   used+=1
   if point and attempt({entry=entry,index=index,point=point,tier=1}) then return true end
  end
  if projectionsLeft<=0 then v82.acquisitionState(entry,"ACQUIRE_PROJECTION_BUDGET_EXHAUSTED");waitWork();if not usable() or projectionsLeft<=0 then return false end end
  projectionsLeft-=1;metrics.Projections+=1
  local projected,visible=initialCamera:WorldToViewportPoint(entry.part.Position)
  if visible and projected.Z>0 then
   for _,offset in ipairs({Vector2.new(4,0),Vector2.new(-4,0),Vector2.new(0,4),Vector2.new(0,-4)}) do
    if not usable() then return false end
    if raysLeft<=0 then v82.acquisitionState(entry,"ACQUIRE_PROJECTION_BUDGET_EXHAUSTED");waitWork();if not usable() or raysLeft<=0 then return false end end
    local point=Vector3.new(projected.X+offset.X,projected.Y+offset.Y,projected.Z)
    raysLeft-=1;metrics.Raycasts+=1
    if guiClear(point) and screenRayHits(initialCamera,Vector2.new(point.X+GuiService:GetGuiInset().X,point.Y+GuiService:GetGuiInset().Y),entry.part)
     and attempt({entry=entry,index=1,point=point,tier=1}) then return true end
   end
  end
  completedPasses+=1
  if pass==1 then v82.acquisitionState(entry,mode=="CIVIL WAR" and "ACQUIRE_POST_PALETTE_REVALIDATION_PENDING" or "ACQUIRE_PENDING_FRAME");waitWork() end
 end
 if not usable() or completedPasses~=2 then return false end
 if mouse.Target==entry.part and guiClear(UserInputService:GetMouseLocation()) then v82.acquisitionState(entry,"ACQUIRE_OK");return true end
 entry.CursorOnlyFailuresSinceSuccess=(entry.CursorOnlyFailuresSinceSuccess or 0)+1
 v82.acquisitionState(entry,"PROVEN_UNREACHABLE_CURRENT_VIEW")
 if not v82.cameraAllowed(entry) then return false end
 if not settleRelease() then return false end
 metrics.CameraFallbacks+=1;metrics.FullCameraSearches+=1;v82.camera.data.CameraFallbackAttempts+=1
 local applied=acquireTarget(entry)
 local acquired=false
 if applied and liveToken(token) and shouldTarget(entry) then
  local point,budget=visiblePoint(entry)
  if budget then waitWork();if liveToken(token) and shouldTarget(entry) then point=visiblePoint(entry) end end
  if point then acquired=moveCursor(point,token) end
 end
 if entry.activeCameraPose then v82.cameraResult(entry,acquired,false) end
 if acquired then
  v82.acquisitionState(entry,"ACQUIRE_OK");return true
 end
 entry.LastGoodCameraSolution=nil;restoreView();entry.activeCameraPose=nil
 return false
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
	if not shouldTarget(entry) then v7.CleanSkippedBeforeDown+=1;syncDirty(entry,"check");return false end
	local tool=activationTool
	if not guiClear(UserInputService:GetMouseLocation()) then settleRelease();activation.Status="Interactive GUI blocks native input";return false end
	if not tool or tool.Parent~=player.Character or not tool.Enabled or not inputAllowed(entry,tool,token) then return false end
	if ownedInput then
		if ownedInput.Tool==tool and not ownedInput.ReleaseSent then return true end
		if not settleRelease() then return false end
	end
	if not primaryMethod or primaryFailures>=CFG.ConfirmedNoEffectLimit then return false end
	if UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) then
		health.resync(tool);activation.Status="Mouse1 state conflict; target will be reacquired after release";return false
	end
	if not shouldTarget(entry) then v7.CleanSkippedBeforeDown+=1;syncDirty(entry,"check");return false end
	local owner={Method=primaryMethod,Tool=tool,PaintMode=mode,Before=entry.part.Color,Down=downSeen,
		EquippedDown=equippedDownSeen,ToolDown=toolDownSeen,Started=os.clock()}
	owner.HoldId=pressAttempts+1
	ownedInput,held=owner,true;health.InputState="DOWN_SENT"
	activation.Method,activation.Attempted,activation.Observed=primaryMethod.Name,true,false
	activation.Observation,activation.ColorChanged,activation.TargetColorObserved="none",false,false
	pressAttempts+=1
	local ok,problem=callInput(primaryMethod.Down);owner.DownFailed=not ok
	if not ok then
		inputErrors+=1;result("VirtualInput down failed: "..tostring(problem))
		if string.find(string.lower(tostring(problem)),"duplicate",1,true) then
			health.DuplicateDownStates+=1;health.resync(tool)
		else primaryFailures+=1;settleRelease() end
		return false
	end
	return liveToken(token) and not owner.ReleaseSent
end

local function preparePalette(target)
	-- NORMAL follows the real palette; never write its attribute or assume re-equip resets a closure.
	return ensureBucket()~=nil and colorsMatch(paletteColor(),target)
end
local function restorePalette()
	restorePending=false
	-- No unverified attribute restore. Select the normal palette color before the next NORMAL run.
end

local function stop(reason)
 if benchmark.active and not benchmark.finishing then
  local state=not focused and "PAUSED - FOCUS" or (activationTool and activationTool.Parent~=player.Character) and "PAUSED - TOOL" or "PAUSED - TARGET"
  benchmark.pause(state,reason or "Paused",state=="PAUSED - TARGET");return
 end
 palette.activeSnapshot=nil
	v82.resumeIntent=nil
	local wasCivil = running and mode == "CIVIL WAR"
	if policy.current and not policy.current.finished then
		policy.current.interruption=not focused and "FOCUS_LOST" or (activationTool and activationTool.Parent~=player.Character) and "TOOL_UNAVAILABLE" or "INTERRUPTED"
	end
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

function v82.prepareLookahead(service)
 if service.lookedAhead then return end;service.lookedAhead=true;v82.data.LookaheadChecks+=1
 local now=os.clock();local best=nil;local bestTier=math.huge;local bestScore=-math.huge
 for i=1,math.min(#dirty,16) do
  local e=dirty[(dirtyCursor+i-1)%#dirty+1]
  if e~=service.entry and e.active and now>=e.retryAt and shouldTarget(e) then
   local tier,score=v82.rank(e,now)
   if tier<bestTier or tier==bestTier and score>bestScore then best=e;bestTier=tier;bestScore=score end
  end
 end
 if best then
  local point=visiblePoint(best)
  v82.lookahead={entry=best,point=point,paletteControl=best.civilControl,at=now,paletteSwitch=not colorsMatch(paletteColor(),targetColor(best))}
 else v82.lookahead=nil end
end
function palette.maintain(token)
 if os.clock()<palette.maintenanceAt or palette.blocked then return end
 palette.maintenanceAt=os.clock()+0.5
 for _,item in ipairs(palette.controls) do
  if item.semanticVerified and item.pendingVerification and (item.retryAfter or 0)<=os.clock() then
   if not settleRelease() then return end
   palette.current={Steps={},PaletteStep="VERIFYING_AMBIGUOUS"};palette.activeSnapshot=palette.snapshot(item)
   local ready=palette.ensureOpen(item,token)
   if ready then palette.verifyCandidates(item,token) end
   palette.activeSnapshot=nil;palette.generationStatus();return
  end
 end
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
		if mode=="CIVIL WAR" then palette.refreshAccess();palette.maintain(token) end
  local candidate=chooseFast(os.clock())
		if not candidate then
			if projectionsLeft<=0 or raysLeft<=0 then waitWork();continue end
			currentEntry=nil
			if not settleRelease() then running=false;break end
			waitWork();continue
		end
		transitionCount+=1
		local entry=candidate.entry
		if not shouldTarget(entry) then v7.CleanSkippedBeforeCursor+=1;syncDirty(entry,"check");continue end
		if not v7.lockTarget(entry) then
			if not settleRelease() then running=false;break end
			continue
		end
		currentEntry=entry;activation.TargetAcquired=false
		entry.acquiredAt,entry.earlyCorrectionAt,entry.corrected=nil,nil,false
		local target=targetColor(entry)
		local tool=ensureBucket()
		if not tool then lastMessage="PaintBucket unavailable; waiting for native tool";running=false;v82.resumeIntent={mode=mode,target=normalTarget,at=os.clock()+CFG.FocusStable};break end
		discoverActivation(tool)
		local strategy,arm=policy.strategy()
		if entry.forceFullService then strategy="PER_TARGET";arm=mode=="CIVIL WAR" and policy.civil or policy.normal.PER_TARGET end
		policy.setCharge(arm)
		-- A benchmark phase boundary also ends the old hold; samples cannot mix strategies.
		if strategy=="PER_TARGET" or (ownedInput and ownedInput.Strategy~=strategy) then
			if not settleRelease() then running=false;break end
		end
		local began=os.clock()
		local service=policy.begin(entry,strategy,arm,began)
		local paletteStarted=os.clock()
		if mode=="CIVIL WAR" then
   if not shouldTarget(entry) then service.result="CLEAN_BEFORE_DOWN";syncDirty(entry,"check");policy.finish(service,false);continue end
   if (entry.ConsecutiveTargetLosses or 0)>=2 and not colorsMatch(paletteColor(),target) then
    local feasible=visiblePoint(entry)
    if not feasible and not (entry.forceSafeCamera and acquireFast({entry=entry,tier=3},token)) then
     v82.data.TargetLostBeforePalette+=1;service.result="TARGET_LOST";policy.finish(service,false);continue
    end
   end
			local prepared,why=palette.prepare(entry,token,service)
			service.paletteMs=(os.clock()-paletteStarted)*1000
			if not prepared then
				service.result="PALETTE_PREPARATION_FAILED: "..tostring(why);v7.PaletteFailures+=1
				lastMessage=service.result;palette.status=lastMessage
    if not shouldTarget(entry) then service.result="CLEAN_BEFORE_DOWN";syncDirty(entry,"check")
    elseif not focused or not activationTool or activationTool.Parent~=player.Character or workerToken~=token then service.result=not focused and "FOCUS_LOST" or "TOOL_UNAVAILABLE";running=false;palette.resumeNeeded=true
    else
     service.result="PALETTE_UNAVAILABLE";entry.paletteRetry=math.min(5,(entry.paletteRetry or 0)+1)
     v82.defer(entry,math.min(4,CFG.PaletteColorRetry*entry.paletteRetry),"PALETTE")
     if entry.civilControl then entry.civilControl.retryAfter=entry.retryAt end
    end
    policy.finish(service,false);if not running then break end;continue
			end
			service.paletteValid=true;entry.paletteRetry=0
   service.stage="POST_PALETTE_TARGET_REVALIDATION"
   local projected,budget=visiblePoint(entry)
   if budget then waitWork();if not liveToken(token) then break end;projected=visiblePoint(entry) end
   candidate=projected or {entry=entry,tier=entry.lastCamera and 2 or 3}
		else
			service.paletteValid=colorsMatch(paletteColor(),target)
			service.attributeAfter=paletteColor();service.attributeAfterEquip=paletteColor();service.paletteMs=0
		end
		if not liveToken(token) or not entry.active then break end
		if not entry.dirtyIndex or colorsMatch(entry.part.Color,target) then service.result="CLEAN_BEFORE_DOWN";syncDirty(entry,"check");policy.finish(service,false);continue end
		began=os.clock()
  if strategy=="CONTINUOUS" and ownedInput and (not candidate.point or mouse.Target==nil or not lookup[mouse.Target] or not guiClear(UserInputService:GetMouseLocation())) then
   if not settleRelease() then running=false;break end
  end
		service.retained=ownedInput~=nil and not ownedInput.ReleaseSent
		metrics.AcquisitionAttempts+=1
		if not acquireFast(candidate,token) then
			service.result=colorsMatch(entry.part.Color,target) and "CLEAN_BEFORE_DOWN" or service.civil and "TARGET_LOST" or "ACQUIRE_FAILED"
   if service.civil and service.result=="TARGET_LOST" then v82.data.TargetLostAfterPalette+=1 end
			if ownedInput then settleRelease() end
			policy.finish(service,false);continue
		end
		if not liveToken(token) or not entry.active then break end
		-- Camera recovery may have released the hold; only actual transfers count as retained.
		service.retained=service.retained and ownedInput~=nil and not ownedInput.ReleaseSent
		rememberAcquired(entry,began);service.acquiredAt=entry.acquiredAt
		if colorsMatch(entry.part.Color,target) then
			v7.CleanSkippedBeforeDown+=1;service.result="CLEAN_BEFORE_DOWN"
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
			if outcome=="correct" then syncDirty(entry,"check") else service.result="INPUT_STATE_CONFLICT" end
			policy.finish(service,false);continue
		end
		if not pacing.wait(entry,token,service) then
   service.result=colorsMatch(entry.part.Color,target) and "CLEAN_BEFORE_DOWN" or "TARGET_LOST";policy.finish(service,false);continue
  end
  entry.lastPaintAttempt=os.clock()
		if not startOrRetainHold(entry,token) then
   if mouse.Target~=entry.part then v82.data.TargetLostBeforeDown+=1 end
			service.result=service.result or (colorsMatch(entry.part.Color,target) and "CLEAN_BEFORE_DOWN" or mouse.Target~=entry.part and "TARGET_LOST" or "INPUT_STATE_CONFLICT")
			policy.finish(service,false);continue
		end
		ownedInput.Strategy=strategy
		local stalled=false
		while liveToken(token) and entry.active and ownedInput and not ownedInput.ReleaseSent do
			if ownedInput.ExternalUp then activation.Status="Unexpected native mouse-up; hold stopped";lastMessage=activation.Status;running=false;break end
			if not validProvince(entry.part) or activationTool.Parent~=player.Character then service.result="TOOL_UNAVAILABLE";break end
			if mouse.Target~=entry.part or not guiClear(UserInputService:GetMouseLocation()) then
				service.result="TARGET_LOST";activation.Status="Real target lost; release and reacquire";settleRelease();break
			end
			entry.lastHoveredTime=os.clock()
			inputEvidence(ownedInput)
			if not ownedInput.MouseObserved and os.clock()-ownedInput.Started>=CFG.InputVerify then
				service.result="INPUT_STATE_CONFLICT";primaryFailures+=1;activation.Status="VirtualInput Mouse.Button1Down not observed; bounded recovery"
				settleRelease();break
			end
			if ownedInput.MouseObserved and not UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) then
				service.result="INPUT_STATE_CONFLICT";health.resync(activationTool);break
			end
			if ownedInput.MouseObserved then policy.qualify(service) end
			if colorsMatch(entry.part.Color,target) or service.success then
				noteCorrection(entry);syncDirty(entry,"check");break
			end
			-- Full dwell begins only once genuine acquisition AND input observation are valid.
			if service.qualified and service.paletteValid and os.clock()>=service.validAt+service.dwell then
				if service.civil and service.previousIntended and colorsMatch(entry.part.Color,service.previousIntended) and not colorsMatch(entry.part.Color,target) then
					service.result="SUSPECTED_PREVIOUS_PALETTE_COLOR";service.paletteValid=false;v7.PaletteFailures+=1
					break
				end
				stalled=true;service.validNoEffect=true;service.result="VALID_NO_EFFECT";holdStalls+=1
				activation.Status="Full adaptive dwell elapsed; target deferred, native cooldown unchanged"
				if strategy=="CONTINUOUS" and holdStalls>=CFG.StallsBeforeHoldRecovery then holdStalls=0;settleRelease() end
				break
			end
			v82.prepareLookahead(service)
			waitWork()
		end
		service.paintEndedAt=os.clock();service.releaseStartedAt=os.clock()
		if strategy=="PER_TARGET" then
			if not settleRelease() then running=false end
		end
		policy.finish(service,stalled)
  if strategy=="CONTINUOUS" and policy.choice=="PER_TARGET" then if not settleRelease() then running=false end end
		if entry.forceFullService then
			entry.forceFullService=nil
			if entry.dirtyIndex and service.episode==entry.dirtyEpisode and not v82.activeCombat(entry,os.clock()) then v82.defer(entry,0.5,"QUARANTINE") end
		end
	end
	if settleRelease() then restoreView() end
	policy.finish(policy.current,false)
	policy.setCharge(nil)
	if v7.lock then v7.unlockTarget(v7.lock) end
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
		civilColor = nil,
	}
	entry.index=#entries+1
	entries[entry.index] = entry
	lookup[part] = entry;v82.ids[entry.id]=entry;v82.camera.ceilingAt=nil

	local box = Instance.new("Highlight")
	box.Name = "HandsFreeProtected"
	box.Adornee = part
	box.FillTransparency = 1
 box.OutlineTransparency = 0
 box.DepthMode = Enum.HighlightDepthMode.Occluded
 box.OutlineColor = targetColor(entry) or paletteColor()
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
	entry.active = false;v82.groupSuccess(entry);v82.ids[entry.id]=nil;v82.camera.ceilingAt=nil
	removeDirty(entry)
	if currentEntry==entry then forceRelease() end
	lookup[part] = nil
	cameraCache[part]=nil
	local last=table.remove(entries)
	if entry.index<=#entries then entries[entry.index],last.index=last,entry.index end
	entry.surfacePoints=nil
	if entry.ancestryConn then entry.ancestryConn:Disconnect() end
	wakeWork()
	if entry.colorConn then entry.colorConn:Disconnect() end
	if entry.destroyConn then entry.destroyConn:Disconnect() end
	entry.service=nil;entry.lastValidService=nil
	if entry.box then entry.box:Destroy() end
end

local function clearAll()
	stop("Cleared")
	while #entries>0 do removeProvince(entries[#entries].part) end
	table.clear(entries)
	table.clear(lookup)
end

v82.selection={held=false,visited={},adds=0,removes=0,restoreTool=nil,restorePending=false,restoreQuiet=nil}
function v82.selectionStopStroke()
 v82.selection.held=false;table.clear(v82.selection.visited)
 if v82.selection.hover then v82.selection.hover.Adornee=nil end
end
function v82.selectionUnequip()
 local tool=findBucket();local hum=humanoid()
 if tool and tool.Parent==player.Character then
  if not hum then return false end
  v82.selection.restoreTool=v82.selection.restoreTool or tool
  pcall(function() hum:UnequipTools() end)
  return tool.Parent~=player.Character
 end
 return true
end
function v82.observeSelection()
 if selecting~="ADD" and selecting~="REMOVE" then return end
 if not v82.selectionUnequip() then v82.selectionStopStroke();lastMessage="Unequip PaintBucket before selection; native tool could not be detached";return end
 local part=mouse.Target
 if not guiClear(UserInputService:GetMouseLocation()) or not validProvince(part) then
  if v82.selection.hover then v82.selection.hover.Adornee=nil end;return
 end
 if v82.selection.hover then v82.selection.hover.Adornee=part end
 if not v82.selection.held or v82.selection.visited[part] then return end
 v82.selection.visited[part]=true
 if selecting=="ADD" then if addProvince(part) then v82.selection.adds+=1 end
 elseif lookup[part] then removeProvince(part);v82.selection.removes+=1 end
 lastMessage=string.format("Selecting: %d protected · release to end stroke; DONE to finish",#entries)
end
function v82.restoreSelectionTool()
 if not v82.selection.restorePending then return end
 if UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) then v82.selection.restoreQuiet=nil;return end
 v82.selection.restoreQuiet=v82.selection.restoreQuiet or os.clock()
 if os.clock()-v82.selection.restoreQuiet<CFG.ActivationReleaseQuiet then return end
 local tool=v82.selection.restoreTool;v82.selection.restoreTool=nil;v82.selection.restorePending=false;v82.selection.restoreQuiet=nil
 local hum=humanoid()
 if tool and tool.Parent and hum and focused then pcall(function() hum:EquipTool(tool) end) end
end
-- UI -------------------------------------------------------------------------

local gui = Instance.new("ScreenGui")
gui.Name = GUI_NAME
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = playerGui
v82.selection.hover=Instance.new("Highlight");v82.selection.hover.Name="SelectionHover"
v82.selection.hover.FillTransparency=0.94;v82.selection.hover.OutlineTransparency=0
v82.selection.hover.OutlineColor=Color3.fromRGB(160,140,255);v82.selection.hover.FillColor=v82.selection.hover.OutlineColor
v82.selection.hover.DepthMode=Enum.HighlightDepthMode.Occluded;v82.selection.hover.Parent=gui


local frame = Instance.new("Frame")
frame.Size = UDim2.fromOffset(410, 575)
frame.Position = UDim2.fromOffset(12, 12)
frame.BackgroundColor3 = Color3.fromRGB(30,30,40)
frame.BorderSizePixel = 0
frame.Active = true
frame.Parent = gui

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1,0,0,34)
title.BackgroundColor3 = Color3.fromRGB(49,49,64)
title.BorderSizePixel = 0
title.Text = "AutoPainter · HANDS FREE v8.2 Cadence Follow-up"
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

v82.cameraLockButton=Instance.new("TextButton");v82.cameraLockButton.Name="CameraEmergencyLock"
v82.cameraLockButton.Text="Camera movement: LOCKED";v82.cameraLockButton.Size=UDim2.fromOffset(245,28)
v82.cameraLockButton.Position=UDim2.fromOffset(12,12);v82.cameraLockButton.Parent=gui
v82.cameraLockButton.Activated:Connect(function()
 forceRelease();restoreView();v82.camera.mode="LOCKED";v82.cameraLockButton.Text="Camera movement: LOCKED"
end)
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
v7.learnButton=button("Learn native palette colors",500);v7.learnButton.Size=UDim2.fromOffset(190,30)
v7.openerButton=button("Learn palette opener",500);v7.openerButton.Position=UDim2.fromOffset(210,500);v7.openerButton.Size=UDim2.fromOffset(190,30)
v7.closerButton=button("Learn palette closer",535);v7.closerButton.Size=UDim2.fromOffset(190,30)
v7.dirtyButton=button("Dirty markers: ON",535);v7.dirtyButton.Position=UDim2.fromOffset(210,535);v7.dirtyButton.Size=UDim2.fromOffset(190,30)
local palettePanel=Instance.new("Frame")
palettePanel.Name="PaletteDatabasePanel";palettePanel.Size=UDim2.fromOffset(245,575);palettePanel.Position=UDim2.fromOffset(416,0)
palettePanel.BackgroundColor3=frame.BackgroundColor3;palettePanel.Parent=frame
palette.buttons={}
for i,label in ipairs({"Copy Learned Palette","Export Palette Profile","Import Palette Profile","Reroll Civil Colors","Pool: ALL LEARNED","Combat HUD: OFF","Close palette: AUTO"}) do
 local b=button(label,10+(i-1)*44);b.Parent=palettePanel;b.Size=UDim2.new(1,-20,0,36);palette.buttons[i]=b
end
for i,label in ipairs({"Validate Native Palette","Camera movement: LOCKED","Protected outlines: ON"}) do
 local b=button(label,365+(i-1)*32);b.Parent=palettePanel;b.Size=UDim2.new(1,-20,0,28);palette.buttons[7+i]=b
end
palette.inspectButton=button("Inspect custom UI",579);palette.inspectButton.Parent=palettePanel;palette.inspectButton.Size=UDim2.new(1,-20,0,28)
palette.probe1=button("Test native Picker (UI only)",611);palette.probe1.Parent=palettePanel;palette.probe1.Size=UDim2.new(1,-20,0,28)
palette.probe2=button("Test ColorPicker (UI only)",643);palette.probe2.Parent=palettePanel;palette.probe2.Size=UDim2.new(1,-20,0,28)
palette.copyCustom=button("Copy Custom UI Report",675);palette.copyCustom.Parent=palettePanel;palette.copyCustom.Size=UDim2.new(1,-20,0,28)
palettePanel.Size=UDim2.fromOffset(245,783)
benchmark.button=button("Paint Cooldown Benchmark",711);benchmark.button.Parent=palettePanel;benchmark.button.Size=UDim2.new(1,-20,0,28)
benchmark.copyButton=button("Copy Cooldown Benchmark",743);benchmark.copyButton.Parent=palettePanel;benchmark.copyButton.Size=UDim2.new(1,-20,0,28)
benchmark.cancelButton=Instance.new("TextButton");benchmark.cancelButton.Text="CANCEL BENCHMARK";benchmark.cancelButton.Size=UDim2.fromOffset(210,30)
benchmark.cancelButton.Position=UDim2.fromOffset(12,305);benchmark.cancelButton.Parent=gui;benchmark.cancelButton.Visible=false
benchmark.liveCopy=Instance.new("TextButton");benchmark.liveCopy.Text="Copy Current Benchmark";benchmark.liveCopy.Size=UDim2.fromOffset(210,30)
benchmark.liveCopy.Position=UDim2.fromOffset(230,305);benchmark.liveCopy.Parent=gui;benchmark.liveCopy.Visible=false
benchmark.liveStart=Instance.new("TextButton");benchmark.liveStart.Text="Paint Cooldown Benchmark";benchmark.liveStart.Size=UDim2.fromOffset(245,30)
benchmark.liveStart.Position=UDim2.fromOffset(12,305);benchmark.liveStart.Parent=gui;benchmark.liveStart.Visible=false
benchmark.resumeButton=Instance.new("TextButton");benchmark.resumeButton.Text="RESUME BENCHMARK";benchmark.resumeButton.Size=UDim2.fromOffset(430,42)
benchmark.resumeButton.Position=UDim2.fromOffset(12,345);benchmark.resumeButton.Parent=gui;benchmark.resumeButton.Visible=false
benchmark.addButton=Instance.new("TextButton");benchmark.addButton.Text="ADD BENCHMARK PROVINCES";benchmark.addButton.Size=UDim2.fromOffset(430,32)
benchmark.addButton.Position=UDim2.fromOffset(12,395);benchmark.addButton.Parent=gui;benchmark.addButton.Visible=false
palette.fillButton=button("Protected fill: OFF",461);palette.fillButton.Parent=palettePanel;palette.fillButton.Size=UDim2.new(1,-20,0,28)
palette.fillButton.Activated:Connect(function() v82.fill=not v82.fill;for _,entry in ipairs(entries) do v7.draw(entry) end;palette.fillButton.Text="Protected fill: "..(v82.fill and "ON" or "OFF") end)
palette.seedBox=Instance.new("TextBox");palette.seedBox.Name="CivilRandomSeed";palette.seedBox.PlaceholderText="Reroll seed (blank = random)"
palette.seedBox.Text="";palette.seedBox.TextSize=14;palette.seedBox.Size=UDim2.new(1,-20,0,34);palette.seedBox.Position=UDim2.fromOffset(10,325);palette.seedBox.Parent=palettePanel
palette.info=Instance.new("TextLabel");palette.info.Position=UDim2.fromOffset(10,495);palette.info.Size=UDim2.new(1,-20,0,80)
palette.info.BackgroundTransparency=1;palette.info.TextColor3=Color3.new(1,1,1);palette.info.TextWrapped=true;palette.info.TextSize=14;palette.info.Parent=palettePanel
local performanceFields={"ActivationStrategy","StrategyConfigured","StrategyDecisionCached","StrategyDecisionReason","VirtualInputHold",
	"DownEvents","UpEvents","Attempts","CompletedServices","AbortedServices","SuccessfulPaints","SuccessRate","CorrectionsPerSecond","OverallCorrectionsPerSecond",
	"AverageTargetDwellMs","AdaptiveDwellMs","AverageAcquisitionMs","AverageAcquiredToColorMs","AverageSwitchMs","ActiveTarget","DirtyCount","Deferred","Stalled",
	"CachedCursorHits","CachedCameraHits","FullCameraSearches","TargetAcquisitionsPerSecond","CursorAcquireSuccessRate","CameraFallbackRate",
	"ColorEventsReceived","DirtyEventsWithoutHover","AverageColorEventToDirtyQueueMs","MaxColorEventToDirtyQueueMs","ReconciliationFinds","ReconciliationChecks",
	"FreshAttackCorrections","AverageAttackColorChangeToCorrectedMs","MinimumAttackResponseMs","MaximumAttackResponseMs","RecentlyChangedQueueDepth",
	"SessionConfirmed","Runtime","AutoPainterRPCs"}
local function performanceReport()
	local m=reportPerformance();local lines={"AUTOPAINTER v8.2 — observed corrections; native RPCs unobserved"}
	for _,key in ipairs(performanceFields) do table.insert(lines,key.."="..tostring(m[key])) end
	table.insert(lines,"STRATEGY BENCHMARK (rolling completed services; work time includes acquisition/release/retry; clean idle excluded)")
	for _,name in ipairs({"PER_TARGET","CONTINUOUS","CIVIL_WAR"}) do
		local stats=m.Strategies[name];table.insert(lines,name)
		for _,key in ipairs({"Attempts","Successes","RetainedAttempts","Aborted","WorkSeconds","WindowAttempts","WindowSuccesses","SuccessRate","CorrectionsPerSecond","AverageServiceMs","AverageAcquiredToColorMs","DwellMs"}) do
			table.insert(lines,"  "..key.."="..tostring(stats[key]))
		end
	end
	table.insert(lines,dirtyEventReport())
	table.insert(lines,v7.report())
	table.insert(lines,palette.baseline())
	local pm=palette.performance();local pk={};for k in pairs(pm) do table.insert(pk,k) end;table.sort(pk)
	for _,key in ipairs(pk) do table.insert(lines,key.."="..tostring(pm[key])) end
	table.insert(lines,"V8.2 OVERLOAD / QUEUE / CAMERA / EFFICIENCY")
 local extra=v82.stats();local keys={};for k in pairs(extra) do table.insert(keys,k) end;table.sort(keys)
 for _,k in ipairs(keys) do table.insert(lines,k.."="..tostring(extra[k])) end
 for path,class in pairs(palette.customCandidates or {}) do table.insert(lines,"Custom UI candidate (UNVERIFIED): "..path.." ["..class.."]") end
	if palette.custom then table.insert(lines,palette.customReport()) end
 return table.concat(lines,"\n")
end
local function copyActivationReport()
	local report=activationReport().."\n"..performanceReport().."\n"..palette.inspect()
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
doneButton.Text = "DONE / FINISH SETUP"
doneButton.Visible = false
doneButton.Parent = gui

local function activeCount() return #entries end
local function dirtyCount() return #dirty end

local function updateUI()
	if not alive then return end
 benchmark.resumeButton.Visible=benchmark.active and benchmark.paused and not selecting;benchmark.addButton.Visible=benchmark.active and benchmark.paused and not selecting
 benchmark.cancelButton.Visible=benchmark.active;benchmark.liveCopy.Visible=benchmark.active;benchmark.liveStart.Visible=running and not benchmark.active
	v82.cameraLockButton.Visible=running;v82.cameraLockButton.Text="Camera movement: "..v82.camera.mode
 frame.Visible = not running and not selecting and not benchmark.active
	liveStatus.Visible = running or selecting=="PALETTE" or benchmark.active
	modeButton.Text = "Mode: " .. mode
	startButton.Text = running and "STOP AUTO" or (palette.resumeNeeded and "RESUME" or "START AUTO")
	local c = normalTarget or paletteColor()
	counts.Text = string.format(
		"Selected: %d · Dirty: %d · Mode: %s\nCorrections: %d · Aim fails: %d · No effect: %d · Input errors: %d",
		activeCount(), dirtyCount(), mode, corrections, aimFailures, noEffect, inputErrors
	)
	status.Text = lastMessage..(palette.status~=lastMessage and ("\n"..palette.status) or "")
		.. "\nAcquire: " .. lastAcquireDetail
		.. "\nTarget acquired: " .. tostring(activation.TargetAcquired) .. " · Method: " .. activation.Method
		.. "\nActivation attempted: " .. tostring(activation.Attempted)
		.. " · Activation observed: " .. activation.Observation
		.. "\nColor changed: " .. tostring(activation.ColorChanged) .. " · Target color: " .. tostring(activation.TargetColorObserved)
		.. (mode == "NORMAL" and ("\nNormal target: " .. tostring(c))
			or "\nCivil War: unique target color per province")

	local perf=reportPerformance()
	liveStatus.Text=string.format("AUTO v8.2 · Q / Escape to stop · %s\n%s · %s\nDirty %d · Attempts %d · Success %d (%.0f%%) · Corrections/s %.2f\nDwell %.0f / limit %.0f ms · Acquire %.1f ms · To color %.1f ms · Switch %.1f ms\nAcq/s %.1f · Cursor %.0f%% · Camera fallback %.0f%%\nCursor cache %d · Camera cache %d · Full search %d\nDeferred %d · Stalls %d · Hold %s · Down/Up %d/%d\nColor events %d · Away from cursor %d · Queue avg/max %.2f/%.2f ms\nFresh queue %d · Attack corrections %d · Response %.1f ms\nTarget: %s",
		perf.ActivationStrategy,activation.Method,activation.Observation,
		perf.DirtyCount,perf.Attempts,perf.SuccessfulPaints,perf.SuccessRate*100,perf.CorrectionsPerSecond,
		perf.AverageTargetDwellMs,perf.AdaptiveDwellMs,perf.AverageAcquisitionMs,perf.AverageAcquiredToColorMs,perf.AverageSwitchMs,
		perf.TargetAcquisitionsPerSecond,perf.CursorAcquireSuccessRate*100,perf.CameraFallbackRate*100,
		perf.CachedCursorHits,perf.CachedCameraHits,perf.FullCameraSearches,perf.Deferred,perf.Stalled,tostring(perf.VirtualInputHold),perf.DownEvents,perf.UpEvents,
		perf.ColorEventsReceived,perf.DirtyEventsWithoutHover,perf.AverageColorEventToDirtyQueueMs,perf.MaxColorEventToDirtyQueueMs,
		perf.RecentlyChangedQueueDepth,perf.FreshAttackCorrections,perf.AverageAttackColorChangeToCorrectedMs,perf.ActiveTarget)

 palette.buttons[7].Text="Close palette: "..(palette.verifiedOpener() and (palette.closeRequired and "REQUIRED" or "AUTO") or "KEEP OPEN (no opener)")
 palette.info.Text=string.format("Learned %d · verified %d · live %d/%d (%s)\nRGB creation PROVEN · application %s\nGenerated applied %d · native capacity %d · selected %d · additional %d",perf.SemanticKnownCapacity,perf.NativeVerifiedThisSession,perf.BoundNativeColors,perf.SemanticKnownCapacity,perf.PaletteGenerationState,perf.GeneratedColorApplicationViaCurrentNativePath,perf.GeneratedColorsAssigned,perf.VerifiedNativeCapacity,#entries,perf.Shortage)
 if running and mode=="CIVIL WAR" then liveStatus.Text..="\nPalette: "..palette.current.PaletteStep.." | "..tostring(palette.current.IntendedRGB).." | "..tostring(palette.current.Click and palette.current.Click.TargetControlName or "already selected") end
 if running and palette.compactHUD then
  local recent=mode=="CIVIL WAR" and perf.Strategies.CIVIL_WAR or perf.Strategies[perf.ActivationStrategy]
  liveStatus.Size=UDim2.fromOffset(365,150)
  liveStatus.Text=string.format("%s · Q/Escape STOP · OVERLOAD %s\nDirty %d · CPS %.2f · Success %.0f%%\nEligible queue P50/P90 %.0f/%.0f ms\nOldest %.0f ms · Cooling %d · Camera %d\nNative %d/%d · Gen %d\n%s",mode,tostring(perf.Overload),perf.DirtyCount,perf.CorrectionsPerSecond,recent.SuccessRate*100,perf.EligibleQueueP50Ms or 0,perf.EligibleQueueP90Ms or 0,perf.MaxDirtyAgeMs,perf.Quarantined or 0,perf.CameraFallbackAttempts,perf.BoundNativeColors,perf.SemanticKnownCapacity,perf.CurrentPaletteGeneration,perf.ActiveTarget)
 else liveStatus.Size=UDim2.fromOffset(470,250) end
 if benchmark.active then liveStatus.Size=UDim2.fromOffset(470,250);liveStatus.Text="PAINT COOLDOWN BENCHMARK\n"..benchmark.state.."\n"..benchmark.detail.."\nNormal worker paused · one unchanged color · AutoPainterRPCs=0\nColor results observed asynchronously. Escape PAUSES · RESUME continues · Cancel ends this run." end
 if selecting=="PALETTE" then
		liveStatus.Text="NATIVE PALETTE SETUP · "..tostring(palette.learning or "Captured").."\n"..palette.status.."\nClick only the normal game's palette controls, then DONE / FINISH SETUP."
	end

end

local function beginSelection(kind)
 stop("Selection mode");v82.selectionStopStroke()
 selecting=kind
 if (kind=="ADD" or kind=="REMOVE") and not v82.selectionUnequip() then
  selecting=nil;lastMessage="Unequip PaintBucket manually before selection; native tool could not be detached";updateUI();return false
 end
 frame.Visible=false;doneButton.Visible=true
 lastMessage=kind=="ADD" and "Click or hold-drag provinces to protect" or "Click or hold-drag provinces to remove"
 updateUI();return true
end
local function finishSelection()
 palette.observeChrome()
 if selecting=="PALETTE" then palette.status=string.format("Palette learned: %d semantic colors",#palette.controls) end
 v82.selectionStopStroke()
 if v82.selection.restoreTool then v82.selection.restorePending=true;v82.selection.restoreQuiet=nil end
 palette.learning=nil;palette.pending=nil;selecting=nil;frame.Visible=true;doneButton.Visible=false
 lastMessage="Selection finished; release Mouse1 before START";updateUI()
end

local function beginPaletteLearning(kind)
	if running or workerActive or starting or ownedInput then stop("Stop before palette learning");return false end
	palette.prune()
	beginSelection("PALETTE")
	palette.learning=kind or "COLORS";palette.pending=nil
	lastMessage="Click the normal game's palette "..tostring(kind or "COLORS").." controls, then finish setup"
	return true
end
v7.learnButton.Activated:Connect(function() beginPaletteLearning("COLORS") end)
v7.openerButton.Activated:Connect(function() beginPaletteLearning("OPENER") end)
v7.closerButton.Activated:Connect(function() beginPaletteLearning("CLOSER") end)
v7.dirtyButton.Activated:Connect(function()
	CFG.ShowDirtyState=not CFG.ShowDirtyState;v7.dirtyButton.Text="Dirty markers: "..(CFG.ShowDirtyState and "ON" or "OFF")
	for _,entry in ipairs(entries) do v7.draw(entry) end
end)

function palette.reroll(seed)
 v82.resumeIntent=nil
 if running or workerActive or starting or ownedInput or selecting then return false,"Stop and finish selection before reroll" end
 if seed~=nil and (type(seed)~="number" or seed~=seed or seed%1~=0 or seed<1 or seed>2147483646) then return false,"Seed must be an integer 1..2147483646" end
 palette.seed=seed;palette.seedSupplied=seed~=nil
 local ok,why=palette.assign(true)
 if ok then rebuildDirty();palette.status="Civil assignments rerolled; START required" else palette.status=why end
 updateUI();return ok,why
end
function palette.exportProfile()
 local ok,text=pcall(function() return game:GetService("HttpService"):JSONEncode(palette.profile()) end)
 if not ok then return false,"Profile encoding failed" end
 -- A durable file is preferred; clipboard remains available when file APIs are absent.
 if type(writefile)=="function" and pcall(writefile,"AutoPainterPaletteProfile.json",text) then return true end
 return palette.copy(text,"AutoPainterPaletteProfile.json")
end
function palette.importProfile(text)
 if text==nil then
  if type(readfile)~="function" then return false,"readfile unavailable; pass profile JSON to ImportPaletteProfile(text)" end
  local ok,value=pcall(readfile,"AutoPainterPaletteProfile.json");if not ok then return false,"Palette profile file unavailable" end;text=value
 end
 if type(text)~="string" or #text>1000000 then return false,"Invalid/oversized profile JSON" end
 local ok,data=pcall(function() return game:GetService("HttpService"):JSONDecode(text) end)
 if not ok then return false,"Invalid palette profile JSON" end
 return palette.import(data)
end
palette.buttons[1].Activated:Connect(function() palette.copy(palette.database(true),"AutoPainterLearnedPalette.txt") end)
palette.buttons[2].Activated:Connect(function() local ok,why=palette.exportProfile();palette.status=ok and "Palette profile exported" or tostring(why);updateUI() end)
palette.buttons[3].Activated:Connect(function() local ok,why=palette.importProfile();if not ok then palette.status=tostring(why) end;updateUI() end)
palette.buttons[4].Activated:Connect(function()
 local text=palette.seedBox.Text;local seed=text~="" and tonumber(text) or nil
 if text~="" and not seed then palette.status="Invalid seed";updateUI();return end
 local ok,why=palette.reroll(seed);if not ok then palette.status=tostring(why);updateUI() end
end)
palette.buttons[5].Activated:Connect(function()
 if running or workerActive then return end
 local pools={"ALL LEARNED","HIGH CONTRAST","VIVID","DARK","LIGHT"};local i=table.find(pools,palette.pool) or 1
 palette.pool=pools[i%#pools+1];palette.buttons[5].Text="Pool: "..palette.pool;palette.status="Pool changed; reroll to replace existing assignments";updateUI()
end)
palette.buttons[6].Activated:Connect(function() palette.compactHUD=not palette.compactHUD;palette.buttons[6].Text="Combat HUD: "..(palette.compactHUD and "ON" or "OFF");updateUI() end)
palette.buttons[7].Activated:Connect(function() if running or workerActive then return end;palette.closeRequired=not palette.closeRequired;palette.buttons[7].Text="Close palette: "..(palette.closeRequired and "REQUIRED" or "AUTO");updateUI() end)

local function startAutoImpl()
	local startToken = workerToken
	if running then return true end
	if not alive or not focused or selecting or workerActive or inputBusy or restoringPalette or v82.selection.restorePending or (benchmark.active and not benchmark.restoring) then return false end
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

	if mode=="CIVIL WAR" then
		local assigned,why=palette.assign()
		if not assigned then lastMessage=why;palette.status=why;updateUI();return false end
	end
	normalTarget = paletteColor()
	if mode == "NORMAL" and not preparePalette(normalTarget) then
		lastMessage = "Could not prepare the normal PaintBucket color"
		updateUI()
		return false
	end

	if not v82.resuming then v82.groups={};v82.groupCount=0;v82.misses={} end;v82.lookahead=nil
	policy.current=nil;v7.lock=nil;dirtyCursor=0;nextWorkerAt=nil;health.sameEntry=nil;health.sameFailures=0
	v7.sequence={};v7.lastTargetId=nil;v7.lastPair=nil
	for _,arm in pairs(not v82.resuming and (mode=="NORMAL" and policy.normal or {policy.civil}) or {}) do
		arm.noEffects={};arm.streak=0
  if mode=="NORMAL" and not v82.resuming then arm.dwell=CFG.TargetDwellDefault;arm.latencies={};arm.training={} end
		if #arm.latencies>=CFG.DwellMinSamples then
			local sorted=table.clone(arm.latencies);table.sort(sorted)
			arm.dwell=math.min(arm.dwell,math.clamp(sorted[math.ceil(#sorted*0.9)]+CFG.DwellMargin,CFG.TargetDwellMin,CFG.TargetDwellMax))
		else arm.dwell=CFG.TargetDwellDefault end
	end
	palette.rebindAll("Explicit START/RESUME")
	for _, e in ipairs(entries) do
		if e.active then
			if not v82.resuming then health.reset(e,false);e.cameraBlacklist=nil;e.cameraBlacklistOrder=nil;e.cameraBlacklistedOut=nil;e.groupId=nil;e.eligibleMs,e.deferredMs,e.quarantineMs=0,0,0;v82.queueOrigin(e,"BOOTSTRAP_DIRTY") end
   e.service=nil;e.forceFullService=nil;e.clockAt=os.clock();e.inService=false
			e.waitSince = os.clock()
			if not v82.resuming then e.retryAt=0 end
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
   palette.currentEntry=nil;palette.activeSnapshot=nil
			inputErrors += 1
			stop("Activation/controller error: " .. tostring(problem))
			settleRelease()
		end
		policy.finish(policy.current,false)
		if v7.lock then v7.unlockTarget(v7.lock) end
		workerActive = false
		if not running and restorePending then restoringPalette=true;restorePalette();restoringPalette=false end
		if not alive and finishClose then finishClose() end
	end)
	updateUI()
	return true
end

local function startAuto()
 if benchmark.active and not benchmark.restoring then return false end
 if not v82.resuming then v82.resumeIntent=nil end
	if starting then return false end
	starting = true
	local ok, value = pcall(startAutoImpl)
	starting = false
	if not ok then stop("Activation start error: " .. tostring(value)); updateUI(); return false end
	if value then palette.resumeNeeded=false end
	return value
end

-- Isolated resumable diagnostic. Completed rows are immutable evidence; reset
-- paints are separate native transactions and never train production timing.
function benchmark.open() return benchmark.active and alive and not benchmark.cancelled end
function benchmark.log(action,reason)
 v82.push(benchmark.events,{At=os.clock(),State=benchmark.state,Action=action,Reason=reason,Interval=benchmark.index},64)
end
function benchmark.pause(state,reason,manual,delay)
 if not benchmark.open() then return end
 local changed=not benchmark.paused or benchmark.state~=state or benchmark.pauseReason~=reason
 benchmark.paused=true;benchmark.manual=benchmark.manual or manual==true
 benchmark.state=state;benchmark.pauseReason=reason;benchmark.detail=reason
 benchmark.retryReadyAt=os.clock()+(delay or 0);benchmark.stableAt=nil
 if running then running=false;workerToken+=1 end
 v82.resumeIntent=nil;forceRelease();palette.activeSnapshot=nil
 if changed then benchmark.log("PAUSE",reason) end
end
function benchmark.valid()
 if not benchmark.open() or benchmark.paused then return false end
 if not focused or GuiService.MenuIsOpen or UserInputService:GetFocusedTextBox() then benchmark.pause("PAUSED - FOCUS","Return focus to Roblox / close chat; evidence retained",false);return false end
 if not benchmark.tool or not benchmark.tool.Enabled or benchmark.tool.Parent~=player.Character or activationTool~=benchmark.tool or benchmark.generation~=equippedGeneration then
  benchmark.pause("PAUSED - TOOL","Equip the native PaintBucket; evidence retained",false);return false
 end
 if benchmark.state=="RUNNING TEST" and not colorsMatch(paletteColor(),benchmark.color) then
  benchmark.pause("PAUSED - TARGET","Benchmark color changed. Restore "..rgbText(benchmark.color).." through the native palette, then Resume.",true);return false
 end
 return running and workerToken==benchmark.token
end
function benchmark.ready(phase)
 while benchmark.open() do
  local tool=findBucket()
  if not focused or GuiService.MenuIsOpen or UserInputService:GetFocusedTextBox() then benchmark.pause("PAUSED - FOCUS","Return focus to Roblox / close chat; evidence retained",false)
  elseif selecting then benchmark.pause("PAUSED - TARGET","Finish selection, then RESUME BENCHMARK",true)
  elseif not tool or not tool.Enabled or tool.Parent~=player.Character then benchmark.pause("PAUSED - TOOL","Equip the native PaintBucket; evidence retained",false)
  elseif not benchmark.paused and benchmark.tool and (tool~=benchmark.tool or equippedGeneration~=benchmark.generation) then benchmark.pause("PAUSED - TOOL","Tool session changed; rebinding at a released boundary",false)
  else
   if benchmark.paused then
    if ownedInput or releaseBlocked then
     if not settleRelease() then benchmark.manual=true;benchmark.pauseReason="Release still unresolved — release Mouse1, then Resume" end
    end
    if not benchmark.manual and not ownedInput and not releaseBlocked and not UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) then
     benchmark.stableAt=benchmark.stableAt or os.clock()
     if os.clock()>=benchmark.retryReadyAt and os.clock()-benchmark.stableAt>=CFG.FocusStable then
      discoverActivation(tool)
      if primaryMethod and primaryMethod.Name=="VirtualInput.SendMouseButton" then
       primaryFailures=0 -- Bounded unqualified-sample count still stops repeated failures until explicit Resume.
       benchmark.paused=false;benchmark.segment+=1;benchmark.tool=tool;benchmark.generation=equippedGeneration
       workerToken+=1;benchmark.token=workerToken;running=true;benchmark.state=phase
       benchmark.log("RESUME",benchmark.pauseReason);benchmark.pauseReason=nil
      else benchmark.manual=true;benchmark.pauseReason="VirtualInput unavailable; restore support and Resume" end
     end
    end
   else
    if not benchmark.tool then discoverActivation(tool);benchmark.tool=tool;benchmark.generation=equippedGeneration end
    if not primaryMethod then benchmark.pause("PAUSED - TOOL","VirtualInput unavailable; restore support then Resume",true)
    else benchmark.state=phase;return true end
   end
  end
  RunService.Heartbeat:Wait()
 end
 return false
end
function benchmark.resume()
 if not benchmark.open() or not benchmark.paused then return false end
 benchmark.manual=false;benchmark.stableAt=nil;benchmark.retryReadyAt=os.clock()
 benchmark.log("RESUME_REQUEST",benchmark.pauseReason);return true
end
function benchmark.observe(entry)
 local record=benchmark.pending and benchmark.pending[entry]
 if not record or not record.DownAt or record.ColorAt or os.clock()>(record.ObserveUntil or math.huge) then return end
 if colorsMatch(entry.part.Color,record.Target) then record.ColorAt=os.clock() end
end
function benchmark.waitUntil(deadline)
 while benchmark.valid() and os.clock()<deadline do RunService.Heartbeat:Wait() end
 return benchmark.valid()
end
function benchmark.mean(values)
 local sum=0;for _,value in ipairs(values) do sum+=value end;return #values>0 and sum/#values or 0
end
function benchmark.summarize(row,final)
 row.Attempts,row.Successes,row.ValidNoEffect,row.Unqualified,row.Pending=0,0,0,0,0
 row.Latencies,row.Spacings={},{}
 for _,record in ipairs(row.Records) do
  if record.DownSent then row.Attempts+=1 end
  if record.SpacingMs then table.insert(row.Spacings,record.SpacingMs) end
  if record.Qualified and record.ColorAt then
   record.Result="OBSERVED_SUCCESS";row.Successes+=1;table.insert(row.Latencies,math.max(0,record.ColorAt-record.DownObservedAt)*1000)
  elseif record.ObservationInterrupted then record.Result="UNQUALIFIED_OBSERVATION_INTERRUPTED";row.Unqualified+=1
  elseif not record.Qualified then record.Result=record.Result or "UNQUALIFIED";row.Unqualified+=1
  elseif final or os.clock()>=(record.ObserveUntil or math.huge) then record.Result="VALID_NO_EFFECT";row.ValidNoEffect+=1
  else record.Result="PENDING_COLOR";row.Pending+=1 end
 end
 row.SuccessPercent=row.Attempts>0 and row.Successes/row.Attempts*100 or 0
end
function benchmark.progress(row)
 benchmark.summarize(row,false)
 if benchmark.paused then benchmark.detail=benchmark.pauseReason;return end
 benchmark.detail=string.format("Interval %d/13 — %d ms\nSamples %d/%d · Successes %d · No-effect %d · Unqualified %d\nDo not touch mouse/color/tool",benchmark.index,row.IntervalMs,row.Attempts,benchmark.samples,row.Successes,row.ValidNoEffect,row.Unqualified)
end
function benchmark.shot(entry,interval,phase)
 if not benchmark.ready(phase) then return nil end
 if not entry.active or not validProvince(entry.part) then return {EntryId=entry.id,Position="removed",Result="UNQUALIFIED_REMOVED"} end
 if colorsMatch(entry.part.Color,normalTarget) then return {EntryId=entry.id,Position=tostring(entry.part.Position),Result="CLEAN_SKIPPED"} end
 currentEntry=entry;v7.lock=entry;v7.draw(entry)
 local record={EntryId=entry.id,Position=tostring(entry.part.Position),Target=normalTarget,Segment=benchmark.segment,Qualified=false}
 benchmark.inProgress=record
 local candidate,budget=visiblePoint(entry)
 if budget then RunService.Heartbeat:Wait();if benchmark.valid() then candidate=visiblePoint(entry) end end
 local acquired=benchmark.valid() and acquireFast(candidate or {entry=entry,tier=3},benchmark.token)
 if not benchmark.valid() then settleRelease();v7.unlockTarget(entry);currentEntry=nil;return nil end
 if not acquired or mouse.Target~=entry.part then
  record.Result="UNQUALIFIED_ACQUIRE";record.AcquireFailed=true
 elseif colorsMatch(entry.part.Color,normalTarget) then record.Result="CLEAN_SKIPPED"
 else
  if benchmark.lastNativeDown then benchmark.waitUntil(benchmark.lastNativeDown+interval) end
  if not benchmark.valid() then settleRelease();v7.unlockTarget(entry);currentEntry=nil;return nil end
  if mouse.Target~=entry.part or not colorsMatch(paletteColor(),normalTarget) then record.Result="UNQUALIFIED_TARGET_OR_PALETTE"
  elseif colorsMatch(entry.part.Color,normalTarget) then record.Result="CLEAN_SKIPPED"
  else
   record.DownAt=os.clock();record.ObserveUntil=record.DownAt+benchmark.settle;benchmark.pending[entry]=record
   local before=pressAttempts;local pressed=startOrRetainHold(entry,benchmark.token);local owner=ownedInput
   record.DownSent=pressAttempts>before
   if record.DownSent and owner then record.DownAt=owner.Started;record.ObserveUntil=record.DownAt+benchmark.settle end
   if pressed and owner then
    while benchmark.valid() and not owner.ReleaseSent and mouse.Target==entry.part do
     inputEvidence(owner)
     if owner.MouseObserved and os.clock()>=record.DownAt+benchmark.clickHold then break end
     if os.clock()>=record.DownAt+CFG.InputVerify then break end
     RunService.Heartbeat:Wait()
    end
    inputEvidence(owner);record.DownObserved=owner.MouseObserved;record.DownObservedAt=owner.MouseObservedAt
    record.Qualified=owner.MouseObserved and benchmark.valid() and mouse.Target==entry.part and not owner.ReleaseSent
    if record.ColorAt and record.DownObservedAt and record.ColorAt<record.DownObservedAt then
     record.Qualified=false;record.Result="UNQUALIFIED_COLOR_BEFORE_DOWN"
    end
    if record.DownObservedAt then benchmark.lastNativeDown=record.DownObservedAt end
   end
   if not record.Qualified then record.Result=record.Result or "UNQUALIFIED_INPUT_OR_TARGET" end
  end
 end
 local released=settleRelease();v7.unlockTarget(entry);currentEntry=nil
 if not released then benchmark.pause("PAUSED - TARGET","Release unresolved; release Mouse1, then Resume",true)
 elseif record.Result and record.Result~="CLEAN_SKIPPED" and not record.Qualified then
  benchmark.badSamples+=1
  benchmark.pause("PAUSED - TARGET","Unqualified sample saved; safely moving to another target",benchmark.badSamples>=3,.15)
 else benchmark.badSamples=0 end
 return record
end
function benchmark.safeShot(entry,interval,phase)
 benchmark.inProgress=nil
 local before=pressAttempts;local ok,value=pcall(benchmark.shot,entry,interval,phase)
 local partial=benchmark.inProgress;benchmark.inProgress=nil
 if ok then return value end
 -- A diagnostic exception is another recoverable, unqualified sample, not a new worker.
 if partial then
  partial.DownSent=pressAttempts>before;partial.Qualified=false;partial.Result="UNQUALIFIED_EXCEPTION"
  if ownedInput then inputEvidence(ownedInput);partial.DownObservedAt=ownedInput.MouseObservedAt;partial.DownAt=ownedInput.Started end
 end
 settleRelease();if v7.lock then v7.unlockTarget(v7.lock) end;currentEntry=nil
 benchmark.pause("PAUSED - TARGET","Inspection/input error retained: "..tostring(value)..". Restore target/tool and Resume.",true)
 return partial
end
function benchmark.chooseResetColor()
 local target=palette.find(benchmark.color)
 if not target or not target.semanticVerified then return nil,"Benchmark target has no verified native swatch for returning to its color" end
 for _,item in ipairs(palette.available()) do
  if item.semanticVerified and not colorsMatch(item.color,benchmark.color) then return item.color end
 end
 return nil,"No second verified native palette color is available"
end
function benchmark.prepareColor(color,entry,phase)
 normalTarget=color;rebuildDirty()
 while benchmark.open() do
  if not benchmark.ready(phase) then return false end
  if colorsMatch(paletteColor(),color) then return true end
  local item=palette.find(color)
  if not item or not item.semanticVerified then
   benchmark.pause("WAITING FOR DIRTY","Select native target color "..rgbText(color)..", then Resume; no verified swatch writer",true)
  else
   -- Proxy keeps the real entry's Civil assignment/control entirely unchanged.
   local aimEntry=entry
   for _,candidate in ipairs(benchmark.cohort) do if candidate.active and not colorsMatch(candidate.part.Color,color) then aimEntry=candidate;break end end
   local proxy={id=aimEntry.id,part=aimEntry.part,active=aimEntry.active,civilColor=color,civilControl=item,lastWorld=aimEntry.lastWorld}
   local started=os.clock();local service={};local ok,why=palette.prepare(proxy,benchmark.token,service)
   benchmark.reset.PaletteMs+=(os.clock()-started)*1000
   if ok then return true end
   if not benchmark.paused then benchmark.pause("PAUSED - TARGET","Open/restore the native palette, then Resume: "..tostring(why),true) end
  end
 end
 return false
end
function benchmark.ensureCohort()
 while benchmark.open() do
  local valid,seen={},{}
  for _,entry in ipairs(benchmark.cohort) do if entry.active and validProvince(entry.part) then table.insert(valid,entry);seen[entry]=true end end
  for _,entry in ipairs(entries) do if #valid>=benchmark.samples then break end;if not seen[entry] and validProvince(entry.part) then table.insert(valid,entry);seen[entry]=true end end
  benchmark.cohort=valid
  if #valid>=benchmark.samples then return true end
  benchmark.pause("WAITING FOR DIRTY",string.format("Need %d more protected provinces. Nothing is broken. Add them, then Resume.",benchmark.samples-#valid),true)
  if not benchmark.ready("SETUP") then return false end
 end
 return false
end
function benchmark.resetCohort()
 local color,why=benchmark.chooseResetColor();benchmark.resetColor=color
 if not benchmark.autoReset or not color then benchmark.manualResetReason=why or "Solo reset disabled";return false end
 benchmark.reset.Phases+=1;local started=os.clock()
 local needsReset=false
 for _,entry in ipairs(benchmark.cohort) do if not colorsMatch(entry.part.Color,color) then needsReset=true;break end end
 if needsReset and not benchmark.prepareColor(color,benchmark.cohort[1],"RESETTING") then return false end
 for i,entry in ipairs(benchmark.cohort) do
  local failures=0
  while benchmark.open() and entry.active and not colorsMatch(entry.part.Color,color) do
   benchmark.detail=string.format("Resetting provinces... %d/%d\nDo not touch mouse/color/tool\nNext %d ms test starts automatically",i-1,benchmark.samples,benchmark.current.IntervalMs)
   local record=benchmark.safeShot(entry,math.max(CFG.NormalDownSpacingDefault,pacing.interval),"RESETTING")
   if record then
    benchmark.reset.Attempts+=record.DownSent and 1 or 0
    if record.Qualified then
     while benchmark.valid() and not record.ColorAt and os.clock()<record.ObserveUntil do RunService.Heartbeat:Wait() end
    end
    if colorsMatch(entry.part.Color,color) then benchmark.reset.Successes+=1;failures=0
    else benchmark.reset.Failures+=1;failures+=1 end
    benchmark.pending[entry]=nil
    v82.push(benchmark.reset.Records,record,60)
    if failures>=3 then benchmark.pause("PAUSED - TARGET","Reset target not confirmed: Entry "..entry.id..". Reposition/open palette and Resume",true);failures=0 end
   end
   if not benchmark.ready("RESETTING") then return false end
  end
  if not entry.active then benchmark.pause("PAUSED - TARGET","Reset province removed; add a replacement and Resume",true);return false end
 end
 benchmark.reset.TotalMs+=(os.clock()-started)*1000
 return benchmark.prepareColor(benchmark.color,benchmark.cohort[1],"SETUP")
end
function benchmark.prepareInterval()
 if not benchmark.ensureCohort() then return false end
 local dirtyCount=0;for _,e in ipairs(benchmark.cohort) do if not colorsMatch(e.part.Color,benchmark.color) then dirtyCount+=1 end end
 if benchmark.autoReset and (benchmark.index>1 or dirtyCount<benchmark.samples) then benchmark.resetCohort() end
 while benchmark.open() do
  if not benchmark.ready("SETUP") or not benchmark.ensureCohort() then return false end
  dirtyCount=0;for _,e in ipairs(benchmark.cohort) do if not colorsMatch(e.part.Color,benchmark.color) then dirtyCount+=1 end end
  if dirtyCount>=benchmark.samples then return benchmark.prepareColor(benchmark.color,benchmark.cohort[1],"SETUP") end
  benchmark.pause("WAITING FOR DIRTY",string.format("PAUSED — need %d more wrong-color protected provinces. Nothing is broken.\n%s\nRecolor/add them, select target %s, then Resume.",benchmark.samples-dirtyCount,benchmark.manualResetReason or "Native reset is not ready",rgbText(benchmark.color)),true)
 end
 return false
end
function benchmark.safePrepareInterval()
 while benchmark.open() do
  local ok,value=pcall(benchmark.prepareInterval)
  if ok then return value end
  settleRelease();if v7.lock then v7.unlockTarget(v7.lock) end;currentEntry=nil
  palette.currentEntry=nil;palette.activeSnapshot=nil
  benchmark.pause("PAUSED - TARGET","Reset/setup error retained: "..tostring(value)..". Restore the palette/tool and Resume.",true)
  if not benchmark.ready("SETUP") then return false end
 end
 return false
end
function benchmark.recommend()
 local best=nil
 for _,row in ipairs(benchmark.rows) do
  if row.Status=="COMPLETE" and not row.ContextChanged and row.ToolGeneration==equippedGeneration and row.Attempts>=30 and row.Unqualified==0 and row.SuccessPercent>=98 and row.CleanSkipped==0 and #row.Spacings>=row.Attempts-2 and row.Upgrade==pacing.context() then
   local actual=math.ceil(v82.percentile(table.clone(row.Spacings),.9))/1000
   if not best or actual<best.Seconds then best={Seconds=actual,RequestedMs=row.IntervalMs,SuccessPercent=row.SuccessPercent,Attempts=row.Attempts} end
  end
 end
 return best
end
function benchmark.run()
 for index,row in ipairs(benchmark.rows) do
  if not benchmark.open() then break end
  benchmark.index=index;benchmark.current=row;benchmark.pending={};row.Status="SETUP"
  if not benchmark.safePrepareInterval() then break end
  row.Status="RUNNING TEST";row.Upgrade=pacing.context();row.ToolGeneration=equippedGeneration;local lastObserved,lastDispatch,lastSegment=nil,nil,nil
  for _,entry in ipairs(benchmark.cohort) do
   local record=nil
   repeat
    if not benchmark.ready("RUNNING TEST") then break end
    benchmark.progress(row);record=benchmark.safeShot(entry,row.IntervalMs/1000,"RUNNING TEST")
   until record or not benchmark.open()
   if not record then break end
   if row.Upgrade~=pacing.context() or row.ToolGeneration~=equippedGeneration then row.ContextChanged=true end
   if record.Result=="CLEAN_SKIPPED" then row.CleanSkipped+=1 end
   if record.AcquireFailed then row.AcquireFailures+=1 end
   if record.DownObservedAt and lastSegment==record.Segment then record.SpacingMs=lastObserved and (record.DownObservedAt-lastObserved)*1000 or nil end
   if record.DownSent and lastSegment==record.Segment then record.DispatchSpacingMs=lastDispatch and (record.DownAt-lastDispatch)*1000 or nil end
   if record.DownObservedAt then lastObserved=record.DownObservedAt;lastSegment=record.Segment end
   if record.DownSent then lastDispatch=record.DownAt end
   table.insert(row.Records,record);benchmark.progress(row)
  end
  if not benchmark.open() then benchmark.summarize(row,false);break end
  local deadline=os.clock()+benchmark.settle
  while benchmark.open() and os.clock()<deadline do
   if not benchmark.ready("RUNNING TEST") then break end
   benchmark.detail=string.format("%d ms: observing delayed colors; no new input",row.IntervalMs);RunService.Heartbeat:Wait()
  end
  if not benchmark.open() then benchmark.summarize(row,false);break end
  benchmark.summarize(row,true);row.Status="COMPLETE";benchmark.pending={}
  benchmark.detail=string.format("%d ms TEST COMPLETE — %d/%d\nPreparing next test automatically",row.IntervalMs,row.Successes,row.Attempts)
  benchmark.log("INTERVAL_COMPLETE",benchmark.detail)
 end
end
function benchmark.report()
 local lines={"PAINT COOLDOWN BENCHMARK — resumable native input, AutoPainterRPCs=0",
  "State="..tostring(benchmark.state).." | "..tostring(benchmark.detail),"PauseReason="..tostring(benchmark.pauseReason).." | ResumeRequiresClick="..tostring(benchmark.manual),
  "TargetRGB="..rgbText(benchmark.color).." | SamplesPerInterval="..tostring(benchmark.samples).." | EquippedPaintCooldown="..tostring(benchmark.upgrade),
  "Set +100% Paint Speed in-game before testing. Raw upgrade is recorded, not interpreted. Native local color evidence is not server acceptance/causality proof.",
  "Colors observed asynchronously; measured attempts do not wait for color. Spacing is observed native DOWN-to-DOWN within uninterrupted segments; pauses and reset clicks excluded.",
  "ObserveSeconds="..tostring(benchmark.settle).." | SoloReset="..tostring(benchmark.autoReset).." | ManualResetReason="..tostring(benchmark.manualResetReason),
  "RequestedMs | Status | Attempts | Successes | VALID_NO_EFFECT | Unqualified | Pending | Success% | DOWN-color mean/P90 ms | Actual DOWN-DOWN min/mean/P90/max ms | LateSpacings | AcquireFailures | CleanSkipped"}
 for _,row in ipairs(benchmark.rows or {}) do
  if row.Status~="COMPLETE" then benchmark.summarize(row,false) end
  local l,s=row.Latencies or {},row.Spacings or {};local sorted=table.clone(s);table.sort(sorted);local late=0
  for _,value in ipairs(s) do if value>row.IntervalMs+10 then late+=1 end end
  table.insert(lines,string.format("%d | %s | %d | %d | %d | %d | %d | %.2f | %.2f/%.2f | %.2f/%.2f/%.2f/%.2f | %d | %d | %d",row.IntervalMs,row.Status,row.Attempts or 0,row.Successes or 0,row.ValidNoEffect or 0,row.Unqualified or 0,row.Pending or 0,row.SuccessPercent or 0,benchmark.mean(l),v82.percentile(table.clone(l),.9),sorted[1] or 0,benchmark.mean(s),v82.percentile(table.clone(s),.9),sorted[#sorted] or 0,late,row.AcquireFailures,row.CleanSkipped))
  if row.ContextChanged then table.insert(lines,"  ContextChanged=true — tool/upgrade changed; excluded from cadence recommendation") end
 end
 local recommendation=benchmark.recommend();table.insert(lines,"MeasuredCadenceCandidateMs="..tostring(recommendation and recommendation.Seconds*1000 or "none").." (P90 actual spacing of a completed >=98% row; not an absolute minimum)")
 table.insert(lines,"RESET PHASE ONLY — excluded from measured rows, production dwell and strategy")
 table.insert(lines,"ResetRGB="..rgbText(benchmark.resetColor).." | CurrentNativePaletteRGB="..rgbText(paletteColor()))
 for k,v in pairs(benchmark.reset or {}) do if k~="Records" then table.insert(lines,k.."="..tostring(v)) end end
 table.insert(lines,"PAUSE / RECOVERY HISTORY")
 for _,e in ipairs(benchmark.events or {}) do table.insert(lines,string.format("%.3f | %s | %s | %s",e.At,e.State,e.Action,e.Reason or "")) end
 table.insert(lines,"PER-ATTEMPT LOCAL EVIDENCE")
 for _,row in ipairs(benchmark.rows or {}) do for _,r in ipairs(row.Records) do table.insert(lines,string.format("%d ms | Entry %d @ %s | Segment=%s | DispatchAt=%s | NativeDownObservedAt=%s | ColorAt=%s | ActualSpacingMs=%s | Qualified=%s | %s",row.IntervalMs,r.EntryId,r.Position,tostring(r.Segment),tostring(r.DownAt),tostring(r.DownObservedAt),tostring(r.ColorAt),tostring(r.SpacingMs),tostring(r.Qualified),tostring(r.Result))) end end
 return table.concat(lines,"\n")
end
function benchmark.start(options)
 options=options or {};if type(options)~="table" then return false,"Expected options table" end
 local count=options.SamplesPerInterval or 40
 if type(count)~="number" or count%1~=0 or count<30 or count>50 then return false,"SamplesPerInterval must be 30–50" end
 if benchmark.active or not alive or not focused or selecting or starting or palette.validating or releaseBlocked or inputBusy then return false,"Finish selection/recovery and focus Roblox first" end
 if not running and UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) then return false,"Release Mouse1 first" end
 benchmark.saved={mode=mode,target=normalTarget,running=running,camera=v82.camera.mode,paletteMetrics=table.clone(palette.metrics),transactions=palette.transactions,current=palette.current,previousIntended=v7.previousIntended}
 stop("Paint cooldown benchmark requested")
 benchmark.active=true;benchmark.ownsWorker=false;benchmark.cancelled=false;benchmark.paused=false;benchmark.manual=false;benchmark.pauseReason=nil
 benchmark.tool=nil;benchmark.token=nil;benchmark.generation=nil;benchmark.color=nil;benchmark.upgrade=nil;benchmark.resetColor=nil;benchmark.segment=1;benchmark.badSamples=0;benchmark.pending={};benchmark.cohort={};benchmark.events={}
 benchmark.current=nil;benchmark.index=nil;benchmark.samples=count;benchmark.settle=.60;benchmark.clickHold=.02;benchmark.autoReset=options.AutoReset~=false
 benchmark.reset={Phases=0,Attempts=0,Successes=0,Failures=0,PaletteMs=0,TotalMs=0,Records={}};benchmark.manualResetReason=nil;benchmark.lastNativeDown=nil
 benchmark.restoreStatus="pending";benchmark.state="SETUP";benchmark.detail="Pausing normal worker; evidence is preserved through recoverable interruptions"
 benchmark.rows={};for _,ms in ipairs({200,175,150,140,130,120,110,100,90,80,70,60,50}) do table.insert(benchmark.rows,{IntervalMs=ms,Status="NOT_RUN",Attempts=0,AcquireFailures=0,CleanSkipped=0,Records={}}) end
 updateUI()
 task.spawn(function()
  local ok,problem=pcall(function()
   while workerActive and benchmark.open() do RunService.Heartbeat:Wait() end
   if not benchmark.open() then return end
   benchmark.saved.paletteMetrics=table.clone(palette.metrics)
   if not settleRelease() then benchmark.pause("PAUSED - TARGET","Release unresolved; release Mouse1 then Resume",true) end
   local tool=ensureBucket();if tool then discoverActivation(tool) end
   benchmark.color=paletteColor();benchmark.upgrade=pacing.context();benchmark.tool=tool;benchmark.generation=equippedGeneration
   mode="NORMAL";normalTarget=benchmark.color;v82.camera.mode="LOCKED";policy.setCharge(nil)
   palette.validating=true;palette.transactions={};palette.current={};v7.previousIntended=nil
   for _,entry in ipairs(entries) do entry.lastValidService=nil end
   rebuildDirty();workerToken+=1;benchmark.token=workerToken;workerActive=true;benchmark.ownsWorker=true;running=not benchmark.paused
   benchmark.run()
  end)
  -- Unexpected script exceptions are retained as a stopped report; no input loop retries errors.
  benchmark.finishing=true;local released=settleRelease();running=false;workerToken+=1;v82.resumeIntent=nil
  if v7.lock then v7.unlockTarget(v7.lock) end;currentEntry=nil
  for _,row in ipairs(benchmark.rows) do if row.Status~="COMPLETE" then
   for _,record in ipairs(row.Records) do
    if record.Qualified and not record.ColorAt and os.clock()<(record.ObserveUntil or 0) then record.ObservationInterrupted=true end
   end
   benchmark.summarize(row,false)
  end end
  benchmark.pending={};benchmark.cohort={}
  local complete=benchmark.rows[#benchmark.rows].Status=="COMPLETE"
  benchmark.state=complete and "COMPLETE" or benchmark.cancelled and "CANCELLED BY USER" or "PAUSED - TARGET"
  benchmark.detail=complete and "Full sweep complete — copy report; production cadence uses the fastest qualifying observed row" or benchmark.cancelled and "Cancelled by user; all evidence retained" or "Controller closed / diagnostic exception: "..tostring(problem)
  if complete then local best=benchmark.recommend();if best then pacing.interval=best.Seconds;pacing.calibratedContext=pacing.context();pacing.calibratedGeneration=equippedGeneration;pacing.source="COMPLETED_NATIVE_SWEEP_P90: requested "..best.RequestedMs.." ms" end end
  mode=benchmark.saved.mode;normalTarget=benchmark.saved.target;v82.camera.mode=benchmark.saved.camera
  palette.metrics=benchmark.saved.paletteMetrics;palette.transactions=benchmark.saved.transactions;palette.current=benchmark.saved.current;palette.validating=false;v7.previousIntended=benchmark.saved.previousIntended
  if benchmark.ownsWorker then workerActive=false end;benchmark.active=false;benchmark.finishing=false;rebuildDirty()
  pacing.lastDown=benchmark.lastNativeDown;pacing.lastTool=benchmark.tool
  if alive and released and focused and not workerActive and benchmark.saved.running and complete and benchmark.tool and benchmark.tool.Parent==player.Character and (mode~="NORMAL" or colorsMatch(paletteColor(),normalTarget)) then
   benchmark.restoring=true;v82.resuming=true;local resumed=startAuto();v82.resuming=false;benchmark.restoring=false
   benchmark.restoreStatus=resumed and "Previous running mode resumed" or "Previous mode restored; START required"
  else benchmark.restoreStatus="Previous mode restored; paused" end
  if not complete and benchmark.color and not colorsMatch(paletteColor(),benchmark.color) then
   benchmark.restoreStatus..="; native palette differs — choose "..rgbText(benchmark.color).." before NORMAL START"
  end
  benchmark.saved=nil;benchmark.tool=nil
  if alive then updateUI() elseif finishClose then finishClose() end
 end)
 return true
end
function benchmark.cancel()
 if not benchmark.active then return false end
 benchmark.cancelled=true;benchmark.paused=false;benchmark.manual=false;running=false;workerToken+=1;forceRelease()
 benchmark.state="CANCELLED BY USER";benchmark.log("CANCEL","Explicit Cancel Benchmark");return true
end

-- Explicit, bounded native-UI investigation. No guessed RGB writers, no game
-- property injection; candidate names do not confer a custom-color capability.
palette.custom={state="UNVERIFIED",result="No native custom-color input contract verified",inventory={},trials={}}
function palette.inspectCustomUI()
 -- Explicit read-only snapshot, never called by the painting worker. Search ALL
 -- current PlayerGui roots, not only learned PaletteGui controls; do not collect
 -- chat/private free text or execute/require a candidate's scripts.
 local result={};local inspected=0
 for _,o in ipairs(playerGui:GetDescendants()) do
  if not o:IsDescendantOf(gui) then
   inspected+=1
   local path=o:GetFullName();local lower=string.lower(path)
   local relevant=false
   for _,word in ipairs({"palette","color","colour","rgb","hsv","hue","tint","paint","saturation","hex"}) do
    if string.find(lower,word,1,true) then relevant=true;break end
   end
   if relevant and (o:IsA("GuiButton") or o:IsA("TextButton") or o:IsA("ImageButton") or o:IsA("TextBox") or o:IsA("Frame")) then
    local text=o:IsA("TextBox") and o.Text or o:IsA("TextButton") and o.Text or ""
    if o:IsA("TextBox") and not text:match("^[%x#%s%,%.%-]+$") then text="<non-color text omitted>" end
    if #text>80 then text="<long text omitted>" end
    local okVisible,visible=pcall(palette.visible,o)
    table.insert(result,{Path=path,Class=o.ClassName,Visible=okVisible and visible or false,VisibilityReadable=okVisible,Position=tostring(o.AbsolutePosition),Size=tostring(o.AbsoluteSize),Text=text,object=o})
   end
  end
 end
 table.sort(result,function(a,b) return a.Path<b.Path end)
 palette.custom.inventory=result;palette.custom.objectsInspected=inspected;palette.custom.inspectedAt=os.clock()
 return result
end
-- OG golden-ratio/random color construction preserved as a PURE dormant helper.
-- No output is ever assigned to a Civil entry or counted as verified capacity.
function palette.generatedPreview(count,seed,currentColors)
 if running or workerActive or ownedInput then return nil,"Stop before generating a diagnostic preview" end
 if type(count)~="number" or count%1~=0 or count<1 or count>512 or type(seed)~="number" or seed%1~=0 or seed<1 or seed>2147483646 then return nil,"Count 1..512 and integer seed 1..2147483646 required" end
 if currentColors~=nil and type(currentColors)~="table" then return nil,"Optional currentColors must be a table" end
 local rand=palette.rng(seed);local hue=rand(1000000)/1000000;local result={};local used={}
 for _,item in ipairs(palette.controls) do if item.color then table.insert(used,item.color) end end
 for index=1,count do
  local chosen=nil
  for attempt=1,4096 do
   hue=(hue+0.618033988749895)%1
   local c=attempt<=3072 and Color3.fromHSV(hue,(76+rand(24))/100,(84+rand(16))/100)
    or Color3.fromRGB(rand(256)-1,rand(256)-1,rand(256)-1)
   local r,g,b=normalizedRGB(c);c=Color3.fromRGB(r,g,b)
   local current=currentColors and currentColors[index];local unique=typeof(current)~="Color3" or palette.distance(c,current)>=(0.18*255)^2
   for _,old in ipairs(used) do if colorsMatch(c,old) then unique=false;break end end
   if unique then chosen=c;break end
  end
  if not chosen then return nil,"Bounded unique-color search exhausted; no assignments changed" end
  table.insert(result,chosen);table.insert(used,chosen)
 end
 return result,"DORMANT_PREVIEW_ONLY: GeneratedColorCreation=PROVEN; GeneratedColorApplicationViaCurrentNativePath=UNVERIFIED; no application assignments changed"
end
function palette.customReport()
 local lines={"NATIVE CUSTOM COLOR UI — "..palette.custom.state,palette.custom.result,
  "GeneratedColorCreation=PROVEN (OG HSV/RGB algorithm). GeneratedColorApplicationViaCurrentNativePath=UNVERIFIED. Only additional native application capacity is gated on native UI -> intended PaintBucketColor -> matching province.",
  "User live evidence 2026-10-03: PaintSGui.Picker and ColorTitle.ColorPicker REJECTED as custom RGB routes (no new GUI or selected-color change). Manual recheck only with new evidence.",
  "Expanded scope: all current PlayerGui color/palette/RGB/HSV/hue/tint/paint/hex controls, including hidden controls outside learned roots.",
  "ObjectsInspected="..tostring(palette.custom.objectsInspected or 0).." CandidateControls="..#palette.custom.inventory,
  "Game-only source investigation: use updated LOCKED diagnostic scan, section 10 NATIVE CUSTOM-COLOR WRITERS / UI PATHS. Read failures are not evidence of absence.",
  "OG Civil generated HSV/RGB values in a direct game-remote payload. That transport is not a native custom-color UI mechanism and remains excluded."}
 for _,trial in ipairs(palette.custom.trials) do
  table.insert(lines,string.format("Candidate=%s | InputSent=%s | UIChanged=%s | AttributeBefore=%s | AttributeAfter=%s | Result=%s",trial.Path,tostring(trial.InputSent),tostring(trial.UIChanged),trial.Before,trial.After,trial.Result))
 end
 for _,row in ipairs(palette.custom.inventory) do
  table.insert(lines,row.Path.." ["..row.Class.."] Visible="..tostring(row.Visible).." Position="..row.Position.." Size="..row.Size.." Text="..tostring(row.Text))
 end
 return table.concat(lines,"\n")
end
function palette.probeCustom(index)
 if running or workerActive or starting or selecting or ownedInput or releaseBlocked or not focused then return false end
 local paths={{"PaletteGui","ColorPallet","PaintSGui","Picker"},{"PaletteGui","ColorPallet","ColorTitle","ColorPicker"}}
 local segments=paths[index];if not segments then return false end
 local object=playerGui
 for _,name in ipairs(segments) do
  local found=nil
  for _,child in ipairs(object:GetChildren()) do if child.Name==name then if found then palette.custom.result="Ambiguous picker path; no input sent";return false end;found=child end end
  object=found;if not object then palette.custom.result="Candidate not present: "..table.concat(segments,".");palette.inspectCustomUI();return false end
 end
 if not (object:IsA("TextButton") or object:IsA("ImageButton")) or not palette.visible(object) then palette.custom.result="Candidate is not a visible native button";return false end
 local tool=ensureBucket();if not tool then return false end;discoverActivation(tool);if not virtualInput then return false end
 local before={};for _,row in ipairs(palette.inspectCustomUI()) do if row.Visible then before[row.object]=true end end
 local item=palette.capture(object,object.AbsolutePosition+object.AbsoluteSize*0.5+GuiService:GetGuiInset())
 local record=palette.rootRecord(item);record.indexDirty=true -- explicit discovery may precede deferred DescendantAdded
 local trial={Path=object:GetFullName(),Before=rgbText(paletteColor()),After="pending",InputSent=false,UIChanged=false,Result="pending"}
 if #palette.custom.trials>=8 then table.remove(palette.custom.trials,1) end;table.insert(palette.custom.trials,trial)
 v82.resumeIntent=nil;palette.validating=true;running=true;workerActive=true;workerToken+=1;local token=workerToken
 palette.current={Steps={},PaletteStep="CUSTOM_UI_PROBE"}
 task.spawn(function()
  local ok,why=pcall(function()
   -- Exactly one native click: unlike retrying swatches, an unknown toggle must
   -- not be clicked again just because opening it exposed no RGB controls.
   local clicked,reason=palette.click(item,token,"INSPECT_PICKER",function() return true end)
   trial.InputSent=palette.current.Click and palette.current.Click.MouseDownSent or false
   for _=1,2 do if palette.allowed(token) then RunService.RenderStepped:Wait() end end
   for _,row in ipairs(palette.inspectCustomUI()) do if row.Visible and not before[row.object] then trial.UIChanged=true end end
   trial.After=rgbText(paletteColor());trial.Result=clicked and (trial.UIChanged and "New native GUI observed; RGB/HSV writer and province result still UNVERIFIED" or "No new RGB/HSV GUI observed; no custom capability assumed") or tostring(reason)
  end)
  if not ok then trial.Result=tostring(why) end
  settleRelease();running=false;workerActive=false;palette.validating=false;palette.activeSnapshot=nil
  if item.rootRecord then item.rootRecord.items[item]=nil end;if item.button and palette.byButton[item.button]==item then palette.byButton[item.button]=nil end
  palette.custom.result=trial.Result;lastMessage=trial.Result;updateUI()
  if not alive and finishClose then finishClose() end
 end)
 return true
end

function palette.validateNative()
 if running or workerActive or starting or selecting or ownedInput or releaseBlocked or not focused then return false end
 local tool=ensureBucket();if not tool then palette.status="Equip PaintBucket before native palette validation";return false end
 discoverActivation(tool)
 if not virtualInput then palette.status="VirtualInput unavailable; native palette validation cannot run";return false end
 v82.resumeIntent=nil;palette.validating=true;running=true;workerActive=true;workerToken+=1;local token=workerToken
 palette.validation={Completed=0,Failed=0,Total=#palette.controls};palette.current={Steps={},PaletteStep="VALIDATING"}
 task.spawn(function()
  local ok,why=pcall(function()
   palette.rebindAll("Explicit native candidate validation")
   for _,item in ipairs(palette.controls) do
    if not liveToken(token) then break end
    local ready,reason=palette.ensureOpen(item,token)
    if ready and item.pendingVerification then ready,reason=palette.verifyCandidates(item,token)
    elseif ready and not item.semanticVerified then
     ready,reason=palette.click(item,token,"VERIFYING_NATIVE_COLOR",function() return colorsMatch(paletteColor(),item.color) end,item.color)
     if ready then palette.rememberNative(item) end
    end
    if ready then item.validated=true;palette.validation.Completed+=1 else palette.validation.Failed+=1;item.bindingFailure=tostring(reason) end
    palette.status=string.format("Native bindings: %d/%d; unavailable: %d. STOP cancels.",palette.validation.Completed,palette.validation.Total,palette.validation.Failed)
    updateUI();RunService.RenderStepped:Wait()
   end
  end)
  settleRelease();running=false;workerActive=false;palette.currentEntry=nil;palette.validating=false
  if not ok then palette.status="Palette validation interrupted: "..tostring(why) end
  lastMessage=palette.status;updateUI()
  if not alive and finishClose then finishClose() end
 end)
 return true
end

local function toggleAuto()
 if benchmark.active then stop("Emergency stop during cooldown benchmark");updateUI();return end
	if running then stop("Stopped") else startAuto() end
	updateUI()
end

palette.inspectButton.Activated:Connect(function() palette.inspectCustomUI();palette.custom.result="Read-only inventory ready; test each visible candidate explicitly";lastMessage=palette.custom.result;updateUI() end)
palette.probe1.Activated:Connect(function() palette.probeCustom(1) end)
palette.probe2.Activated:Connect(function() palette.probeCustom(2) end)
palette.copyCustom.Activated:Connect(function() palette.copy(palette.customReport(),"AutoPainterCustomUIReport.txt") end)
palette.buttons[8].Activated:Connect(function() palette.validateNative() end)
palette.buttons[9].Activated:Connect(function()
 if running or workerActive then return end
 local modes={"LOCKED","AGGRESSIVE","OFF"};v82.camera.mode=modes[(table.find(modes,v82.camera.mode) or 1)%3+1];v82.camera.circuit="CLOSED";v82.camera.failures=0;v82.camera.window={};v82.camera.paintWindow={}
 palette.buttons[9].Text="Camera movement: "..v82.camera.mode;updateUI()
end)
palette.buttons[10].Activated:Connect(function()
 v82.outlines=v82.outlines==false;for _,entry in ipairs(entries) do v7.draw(entry) end
 palette.buttons[10].Text="Protected outlines: "..(v82.outlines and "ON" or "OFF")
end)

modeButton.Activated:Connect(function()
	if benchmark.active then lastMessage="Benchmark owns mode; Cancel Benchmark before changing mode";updateUI();return end
	if running or v82.resumeIntent then stop("Stopped before changing mode") end
	mode = mode == "NORMAL" and "CIVIL WAR" or "NORMAL"
	if mode=="NORMAL" then normalTarget=paletteColor() end
	rebuildDirty()
	lastMessage = mode == "NORMAL"
		and "Normal mode uses the current PaintBucket palette color"
		or "Civil War assigns each province a distinct learned native palette color"
	updateUI()
end)

addButton.Activated:Connect(function() beginSelection("ADD") end)
removeButton.Activated:Connect(function() beginSelection("REMOVE") end)
clearButton.Activated:Connect(function() clearAll(); updateUI() end)
doneButton.Activated:Connect(finishSelection)
startButton.Activated:Connect(toggleAuto)

connectLifetime(UserInputService.InputBegan, function(input, processed)
	if ownedInput and ownedInput.ReleaseSent and input.UserInputType==Enum.UserInputType.MouseButton1 then ownedInput.QuietSince=nil end
	if palette.learning and input.UserInputType==Enum.UserInputType.MouseButton1 then palette.onClick(UserInputService:GetMouseLocation());return end
	if input.KeyCode == Enum.KeyCode.Escape then
		if selecting then finishSelection() else stop("Emergency stop") end
		updateUI()
		return
	end
	if processed or UserInputService:GetFocusedTextBox() then return end
 if table.find({Enum.KeyCode.W,Enum.KeyCode.A,Enum.KeyCode.S,Enum.KeyCode.D,Enum.KeyCode.Up,Enum.KeyCode.Down,Enum.KeyCode.Left,Enum.KeyCode.Right},input.KeyCode) then v82.camera.manualUntil=os.clock()+CFG.CameraManualQuiet;if cameraSnapshot then forceRelease();restoreView() end end
	if input.KeyCode == Enum.KeyCode.Q then
		toggleAuto()
		return
	end
	if (selecting=="ADD" or selecting=="REMOVE") and input.UserInputType == Enum.UserInputType.MouseButton1 then
		if not guiClear(UserInputService:GetMouseLocation()) then return end
  v82.selection.held=true;table.clear(v82.selection.visited);v82.observeSelection();updateUI()
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
 if input.UserInputType==Enum.UserInputType.Touch or input.UserInputType==Enum.UserInputType.MouseWheel or (input.UserInputType==Enum.UserInputType.MouseMovement and UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2)) then
  v82.camera.manualUntil=os.clock()+CFG.CameraManualQuiet
  if cameraSnapshot then forceRelease();restoreView() end
 end
	if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
		local d = input.Position - dragStart
		frame.Position = UDim2.new(
			frameStart.X.Scale, frameStart.X.Offset + d.X,
			frameStart.Y.Scale, frameStart.Y.Offset + d.Y
		)
	end
end)

connectLifetime(UserInputService.InputEnded, function(input)
 if input.UserInputType==Enum.UserInputType.MouseButton1 then v82.selectionStopStroke() end
	if input == dragInput or input.UserInputType == Enum.UserInputType.MouseButton1 then
		dragging = false
		dragInput = nil
	end
end)

finishClose = function()
	if ownedInput or inputBusy or workerActive or benchmark.active then return end
	disconnectInput(inputConnections)
	disconnectInput(toolConnections)
	disconnectInput(equippedMouseConnections)
	health.lastMethod,health.lastTool=nil,nil;table.clear(palette.roots)
 benchmark.cohort={};benchmark.pending={};benchmark.saved=nil;benchmark.tool=nil;pacing.lastTool=nil
 for _,record in pairs(palette.rootRecords) do for _,c in ipairs(record.connections) do c:Disconnect() end end
 table.clear(palette.rootRecords);table.clear(palette.byKey)
 if palette.custom then table.clear(palette.custom.inventory);table.clear(palette.custom.trials) end
	wake:Destroy()
	gui:Destroy()
end
local function closeController()
	if not alive then return end
	stop("Closed");v82.selectionStopStroke();v82.selection.restoreTool=nil;v82.selection.restorePending=false
	alive = false
	disconnectInput(lifetimeConnections)
	palette.learning=nil;palette.pending=nil;table.clear(palette.controls);table.clear(palette.byButton);palette.opener,palette.closer=nil,nil
	while #entries>0 do removeProvince(entries[#entries].part) end
	gui.Enabled = false
	finishClose()
end
close.Activated:Connect(closeController)
gui.Destroying:Connect(closeController)

connectLifetime(player:GetAttributeChangedSignal("PaintBucketColor"), function()
	palette.onColor()
	if running and not benchmark.active and not palette.validating and mode=="NORMAL" and not colorsMatch(paletteColor(),normalTarget) then stop("NORMAL target color changed — restart required") end
end)

connectLifetime(playerGui.ChildAdded,palette.markRootChanged)
connectLifetime(playerGui.ChildRemoved,palette.markRootChanged)
connectLifetime(mouse.Move,function()
 v82.observeSelection()
 -- Release on the actual move notification, not only the next worker heartbeat.
 -- Palette clicks have their separate validated GUI owner.
 if ownedInput and not ownedInput.ReleaseSent and ownedInput.Kind~="PALETTE" then
  local part=mouse.Target
  if not part or not lookup[part] or not validProvince(part) or not guiClear(UserInputService:GetMouseLocation()) then forceRelease() end
 end
end)
connectLifetime(RunService.RenderStepped,function() v82.observeSelection() end)
connectLifetime(UserInputService.WindowFocusReleased,function()
 local resume=(running or workerActive) and not palette.validating and not benchmark.active
 focused=false;v82.selectionStopStroke();palette.resumeNeeded=resume
 stop("Client lost focus; waiting for stable focus/tool before resume")
 if resume then v82.resumeIntent={mode=mode,target=normalTarget,at=math.huge} end
end)
connectLifetime(UserInputService.WindowFocused,function()
 focused=true
 if v82.resumeIntent then v82.resumeIntent.at=os.clock()+CFG.FocusStable;lastMessage="Focus returning — waiting for stable tool/input" end
 wakeWork();updateUI()
end)
connectLifetime(player:GetPropertyChangedSignal("Character"),function()
 palette.invalidateBindings("Character changed")
 if running and not palette.validating and not benchmark.active then
  local intent={mode=mode,target=normalTarget,at=os.clock()+CFG.FocusStable}
  stop("Character changed; waiting for native tool");palette.resumeNeeded=true;v82.resumeIntent=intent
 end
end)

connectLifetime(Workspace.DescendantRemoving, function(object)
	if lookup[object] then removeProvince(object) end
	if running and not palette.validating and not benchmark.active and (object==activationTool or object==player.Character) then
  local intent={mode=mode,target=normalTarget,at=os.clock()+CFG.FocusStable};stop("Tool lost; released native hold");v82.resumeIntent=intent
 end
end)

connectLifetime(Workspace:GetPropertyChangedSignal("CurrentCamera"), function()
	if running then stop("Camera changed; restart Auto") end
end)

connectLifetime(RunService.Heartbeat, function()
	transitionCount=0;projectionsLeft=CFG.MaxProjections;raysLeft=CFG.MaxRays
	local now=os.clock()
	expireFresh(now)
 if alive then v82.restoreSelectionTool();palette.observeChrome() end
 if alive and v82.resumeIntent and focused and now>=v82.resumeIntent.at and not workerActive and not starting and not ownedInput and not releaseBlocked and not selecting and not UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) then
  local intent=v82.resumeIntent;intent.at=now+0.5
  if findBucket() and humanoid() and humanoid().Health>0 then
   if intent.mode=="NORMAL" and not colorsMatch(paletteColor(),intent.target) then v82.resumeIntent=nil;lastMessage="NORMAL target color changed — restart required"
   else v82.resumeIntent=nil;v82.resuming=true;local resumed=startAuto();v82.resuming=false;if not resumed then v82.resumeIntent=intent end end
  end
 end
	if alive and now>=nextReconcileAt then nextReconcileAt=now+v82.reconcileInterval;reconcile() end
	if workerActive and (ownedInput or (#dirty>0 and (not nextWorkerAt or now>=nextWorkerAt))) then wakeWork() end
	if alive and os.clock() - lastStatusAt >= CFG.StatusInterval then
		lastStatusAt = os.clock()
		updateUI()
	end
end)

updateUI()

benchmark.button.Activated:Connect(function() benchmark.start() end)
benchmark.liveStart.Activated:Connect(function() benchmark.start() end)
benchmark.resumeButton.Activated:Connect(benchmark.resume)
benchmark.addButton.Activated:Connect(function() if benchmark.active and benchmark.paused then beginSelection("ADD") end end)
benchmark.copyButton.Activated:Connect(function() palette.copy(benchmark.report(),"AutoPainterCooldownBenchmark.txt") end)
benchmark.liveCopy.Activated:Connect(function() palette.copy(benchmark.report(),"AutoPainterCooldownBenchmark.txt") end)
benchmark.cancelButton.Activated:Connect(benchmark.cancel)

local api = {
 StartPaintCooldownBenchmark=benchmark.start,CancelPaintCooldownBenchmark=benchmark.cancel,ResumePaintCooldownBenchmark=benchmark.resume,
 PausePaintCooldownBenchmark=function() if not benchmark.active then return false end;benchmark.pause("PAUSED - TARGET","Paused by user; evidence retained",true);return true end,
 GetPaintCooldownBenchmarkReport=benchmark.report,
 CopyPaintCooldownBenchmark=function() return palette.copy(benchmark.report(),"AutoPainterCooldownBenchmark.txt") end,
 GetPaintCooldownBenchmarkState=function() return {Active=benchmark.active,State=benchmark.state,Detail=benchmark.detail,Paused=benchmark.paused,PauseReason=benchmark.pauseReason,RestoreStatus=benchmark.restoreStatus} end,
 ValidateNativePalette=palette.validateNative,
 InspectCustomColorUI=palette.inspectCustomUI,ProbeCustomColorUI=palette.probeCustom,GetCustomColorUIReport=palette.customReport,
 GetDormantGeneratedColorPreview=palette.generatedPreview,
 GetCapacityPreflight=palette.preflight,
 GetV82Diagnostics=v82.stats,
 SetCameraMode=function(value)
  if benchmark.active and value~="LOCKED" and value~="SAFE" then return false end
  if value=="SAFE" then value="LOCKED" end
  if not table.find({"LOCKED","AGGRESSIVE","OFF"},value) then return false end
  if value=="AGGRESSIVE" and (running or workerActive) then return false end
  if cameraSnapshot then forceRelease();restoreView() end
  v82.camera.mode=value;v82.camera.circuit="CLOSED";v82.camera.failures=0;v82.camera.window={};v82.camera.paintWindow={};return true
 end,
 SetProtectedOutlines=function(value) v82.outlines=value~=false;for _,e in ipairs(entries) do v7.draw(e) end end,

 GetLearnedPaletteReport=function() return palette.database(false) end,
 CopyLearnedPalette=function() return palette.copy(palette.database(true),"AutoPainterLearnedPalette.txt") end,
 GetPaletteProfile=palette.profile, ImportPaletteData=palette.import,
 ExportPaletteProfile=palette.exportProfile, ImportPaletteProfile=palette.importProfile,
 RerollCivilColors=palette.reroll,
 SetCivilPool=function(value)
  if running or workerActive or ownedInput or not table.find({"ALL LEARNED","HIGH CONTRAST","VIVID","DARK","LIGHT"},value) then return false end
  palette.pool=value;palette.buttons[5].Text="Pool: "..value;return true
 end,
 GetPaletteTransactionReport=palette.transactionReport,
 GetNormalBaselineReport=palette.baseline,

	GetPerformanceStats = reportPerformance,
	GetTargetStats = function(part)
		local e=lookup[part];if not e then return nil end
		return {QueueOrigin=e.queueOrigin,EpisodeOrigin=e.episodeOrigin,EligibleQueueWaitMs=e.eligibleMs or 0,DeferredCooldownAgeMs=e.deferredMs or 0,QuarantineAgeMs=e.quarantineMs or 0,AttackFrequency=e.AttackFrequency or 0,RecentCorrections=e.RecentCorrections or 0,ImmediateReattacks=e.ImmediateReattacks or 0,LatestExternalChangeTime=e.latestExternalChangeTime,
   ConsecutiveAcquireFailures=e.ConsecutiveAcquireFailures or 0,ConsecutiveTargetLosses=e.ConsecutiveTargetLosses or 0,
            ConsecutiveValidNoEffects=e.ConsecutiveValidNoEffects or 0,ConsecutiveFailures=e.ConsecutiveFailures or 0,
            LastFailureReason=e.LastFailureReason,RetryAfter=e.retryAt,CacheInvalidations=e.CacheInvalidations or 0,
            RecoverySuccesses=e.RecoverySuccesses or 0,EntryExtraDwellMs=(e.ExtraDwell or 0)*1000,
            Dirty=e.dirtyIndex~=nil,LastScreenPoint=e.lastScreen,LastWorldPoint=e.lastWorld,
			LastCamera=e.lastCamera,AcquisitionSeconds=e.lastAcquireSeconds,RecentFailures=e.failures or 0,RetryAt=e.retryAt,
			AcquisitionFailures=e.acquisitionFailures or 0,LastAcquiredTime=e.lastAcquiredTime,
			GeometryCFrame=e.pointFrame,GeometrySize=e.pointSize,LastColorEventTime=e.lastColorEventTime,LastSeenColor=e.lastSeenColor,
			EntryId=e.id,Position=e.part.Position,Label=entryLabel(e),AssignedCivilRGB=rgbText(e.civilColor),AssignedCivilColorKey=colorKey(e.civilColor),
			ActualRGB=rgbText(e.part.Color),TargetRGB=rgbText(targetColor(e)),DeltaRGB=colorDelta(e.part.Color,targetColor(e)),
			LocalColorEventReceivedAt=e.lastColorEventTime,LocalDirtyQueuedAt=e.dirtyQueueInsertTime,LocalColorEventToQueueMs=e.localQueueLatencyMs,
			LastWrongColorChange=e.lastWrongColorChange,FreshAttackAt=e.freshAttackAt,
			AssignedColorName=e.civilControl and e.civilControl.signature.Name,LearnedPaletteIndex=e.civilControl and e.civilControl.index,PaletteControlPath=e.civilControl and e.civilControl.path,
			MarkerType="PROVINCE_SILHOUETTE",MarkerColor=e.box and e.box.OutlineColor,
   AcquisitionState=e.AcquisitionState,CursorOnlyFailuresSinceSuccess=e.CursorOnlyFailuresSinceSuccess or 0,CameraFallbackAttemptsThisDirtyEpisode=e.CameraFallbackAttemptsThisDirtyEpisode or 0,
			TargetColor=targetColor(e),DirtySince=e.dirtySince,DirtyQueueInsertTime=e.dirtyQueueInsertTime,
			LastHoveredTime=e.lastHoveredTime,LastPaintAttempt=e.lastPaintAttempt,LastCorrectedTime=e.lastCorrectedTime,LastDirtyTime=e.lastDirtyTime}
	end,
	GetPerformanceReport = performanceReport,
	GetDirtyEventReport = dirtyEventReport,
	GetColorDiagnostics = v7.report,
	GetPaletteInventory = palette.inspect,
	BeginPaletteLearning = beginPaletteLearning,
	FinishPaletteLearning = finishSelection,
	GetRecoveryEvents=function() local out={};for _,event in ipairs(health.events) do table.insert(out,table.clone(event)) end;return out end,
	GetServiceRecords = function()
		local out={};for _,r in ipairs(v7.records) do table.insert(out,table.clone(r)) end;return out
	end,
	ColorsMatch = colorsMatch,
	SetActivationStrategy = function(value)
		if value~="ADAPTIVE" and value~="CONTINUOUS" and value~="PER_TARGET" then return false end
		if running or workerActive or starting or ownedInput or benchmark.active then return false end
		CFG.ActivationStrategy=value;policy.reset();wakeWork();updateUI();return true
	end,
	Destroy = closeController,
	GetActivationReport = activationReport,
	CopyActivationReport = copyActivationReport,
	Start = startAuto,
	Stop = function() stop("Stopped by API"); updateUI() end,
	SetMode = function(value)
  if benchmark.active then return false end
		if value ~= "NORMAL" and value ~= "CIVIL WAR" then return false end
		if running or v82.resumeIntent then stop("Stopped before changing mode") end
		mode = value
		if mode=="NORMAL" then normalTarget=paletteColor() end
		rebuildDirty()
		updateUI()
		return true
	end,
	AddProvince = addProvince,
	RemoveProvince = removeProvince,
	Clear = clearAll,
	GetStats = function()
		return {
			Version = 8.2, Build = "8.2-followup",
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
