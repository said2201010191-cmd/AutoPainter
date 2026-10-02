-- AutoPainter Hands Free v8.1
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
	assert(existing.GetStats().Version==8.1,"Close the older Hands Free panel; v8.1 must load its recovery and palette binding state")
	assert(not existing.GetStats().Closed, "Previous activation release is unresolved; this controller cannot overlap it")
	return existing
end

local CFG = {
	MaxConsecutiveEntryFailures = 3,
	EntryCooldowns = {0.25,0.40,0.65,1.0},
	DistinctNoEffectEntries = 3,
	GlobalNoEffectWindow = 2.0,
	EntryExtraDwellMax = 0.10,
	ActivationStrategy = "PER_TARGET", -- ADAPTIVE, PER_TARGET or CONTINUOUS; no native cooldown changes.
	TargetDwellDefault = 0.25,
	TargetDwellMin = 0.12,
	TargetDwellMax = 0.35,
	DwellHistory = 24,
	DwellMinSamples = 4,
	DwellMargin = 0.04,
	StrategyMinAttempts = 4,
	StrategyMaxProbeAttempts = 8,
	StrategyWindow = 16,
	StrategyReliabilityMargin = 0.20,
	StrategyThroughputMargin = 0.20,
	ReconcileInterval = 0.12,
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
-- Semantic metadata survives Tool/GUI recreation. No GUI scan occurs on the NORMAL service path.
palette.bindingGeneration=1;palette.bindingEpoch=1;palette.roots={};palette.bindingReason="Initial binding"
palette.bindingMetrics={PaletteGuiGenerations=1,PaletteRebindAttempts=0,PaletteControlsRebound=0,
 PaletteRebindFailures=0,OpenerRebinds=0,CloserRebinds=0}
function palette.invalidateBindings(reason)
 palette.bindingReason=reason
 -- Generation invalidates failed lookup caches; resolution remains lazy and non-yielding.
 palette.bindingEpoch+=1
end
function palette.bindingRoot(item)
 local first=item.segments and item.segments[1];if not first then return nil end
 local root,ambiguous=nil,false
 for _,child in ipairs(playerGui:GetChildren()) do
  if child.Name==first.Name and child.ClassName==first.ClassName then
   if root then ambiguous=true end;root=child
  end
 end
 local key=first.ClassName..":"..first.Name
 local identity=ambiguous and "AMBIGUOUS" or root or false
 if palette.roots[key]~=identity then
  palette.bindingGeneration+=1;palette.bindingMetrics.PaletteGuiGenerations=palette.bindingGeneration
  palette.roots[key]=identity;palette.invalidateBindings("Palette root replaced/attached/detached: "..first.Name)
 end
 return not ambiguous and root or nil
end
function palette.identityMatches(button,item)
 local signature=palette.signature(button)
 for _,key in ipairs({"ClassName","Name","Text","Image","BackgroundRGB"}) do
  if signature[key]~=item.signature[key] then return false end
 end
 return button:IsA("TextButton") or button:IsA("ImageButton")
end
function palette.resolvePaletteControl(item)
 if not item then return nil end
 if item.invalid then
  item.bindingState="INVALID";if item.button then palette.byButton[item.button]=nil;item.button=nil end;return nil
 end
 local old=item.button
 if old and old:IsDescendantOf(playerGui) then
  if item.bindingState~="SIGNATURE_MISMATCH" then return old end
 end
 local root=palette.bindingRoot(item)
 if item.checkedGeneration==palette.bindingEpoch and os.clock()<(item.rebindAt or 0) then return nil end
 item.checkedGeneration=palette.bindingEpoch;item.rebindAt=os.clock()+0.2
 palette.bindingMetrics.PaletteRebindAttempts+=1
 if old then palette.byButton[old]=nil end
 item.button=nil;item.bindingState=root and "REBIND_PENDING" or "DETACHED"
 if not root then return nil end
 local button=playerGui
 for _,segment in ipairs(item.segments or {}) do
  local found=nil
  for _,child in ipairs(button:GetChildren()) do
   if child.Name==segment.Name and child.ClassName==segment.ClassName then
    if found then
     item.bindingState="SIGNATURE_MISMATCH";palette.bindingMetrics.PaletteRebindFailures+=1
     item.bindingFailure="Ambiguous exact path";return nil
    end
    found=child
   end
  end
  if not found then item.bindingState="REBIND_PENDING";return nil end
  button=found
 end
 if button==playerGui or not palette.identityMatches(button,item) then
  item.bindingState="SIGNATURE_MISMATCH";item.bindingFailure="Replacement signature differs"
  palette.bindingMetrics.PaletteRebindFailures+=1;return nil
 end
 item.button=button;item.path=button:GetFullName();item.bindingState="REBOUND"
 item.lastBoundGeneration=palette.bindingGeneration;item.bindingFailure=nil;item.rebindAt=nil
 palette.byButton[button]=item;palette.bindingMetrics.PaletteControlsRebound+=1
 if item==palette.opener then palette.bindingMetrics.OpenerRebinds+=1 end
 if item==palette.closer then palette.bindingMetrics.CloserRebinds+=1 end
 return button
end
function palette.valid(item)
 return palette.resolvePaletteControl(item)~=nil
end
function palette.rebindAll(reason)
 if reason then palette.invalidateBindings(reason) end
 for _,item in ipairs(palette.controls) do palette.resolvePaletteControl(item) end
 palette.resolvePaletteControl(palette.opener);palette.resolvePaletteControl(palette.closer)
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
 size=button.AbsoluteSize,successes=0,failures=0,lastUse=nil,validated=true,
 bindingState="BOUND",lastBoundGeneration=palette.bindingGeneration}
end
function palette.learningStatus()
 return string.format("Learned: %d | Last: %s | Duplicates ignored: %d | Invalid clicks: %d",#palette.controls,palette.lastLearned,palette.duplicates,palette.invalidClicks)
end
function palette.onClick(point)
 if not palette.learning then return end
 local button,blocked=palette.topButton(point)
 if blocked=="CONTROLLER_UI" then return end
 if not button or not palette.visible(button) then palette.invalidClicks+=1;palette.status=palette.learningStatus();return end
 local item=palette.capture(button,point)
 if palette.learning=="OPENER" then palette.opener=item;palette.status="Opener learned; finish setup";palette.learning=nil;return end
 if palette.learning=="CLOSER" then palette.closer=item;palette.status="Closer learned (only used when it blocks the target point)";palette.learning=nil;return end
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
 palette.byButton[item.button]=item;table.insert(palette.controls,item)
 palette.lastLearned=item.button.Name.." ("..rgbText(item.color)..")";palette.status=palette.learningStatus()
end
function palette.find(color)
 for _,item in ipairs(palette.controls) do if palette.valid(item) and colorsMatch(item.color,color) then return item end end
 return nil
end
function palette.prune()
 palette.rebindAll() -- Detachment never destroys learned semantic identity.
end
function palette.available()
 local out={};for _,item in ipairs(palette.controls) do if palette.valid(item) then table.insert(out,item) end end
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
 local available=palette.available();local used,missing,chosen={}, {}, {}
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
 local capacity=#palette.available();local detached,pending,mismatch=0,0,0
 for _,item in ipairs(palette.controls) do
  if item.bindingState=="DETACHED" then detached+=1 elseif item.bindingState=="REBIND_PENDING" then pending+=1 elseif item.bindingState=="SIGNATURE_MISMATCH" then mismatch+=1 end
 end
 return {BoundPaletteControls=capacity,DetachedPaletteControls=detached,RebindPending=pending,SignatureMismatches=mismatch,
 CivilCapacityStatus=capacity==0 and #palette.controls>0 and (detached+pending)>0 and "temporarily unavailable" or "available",CivilSelectedCount=#entries,UniqueAssignedCivilColors=unique,DuplicateAssignedCivilColors=duplicate,
 UnassignedCivilColors=#entries-assigned,LearnedPaletteColors=#palette.controls,CivilCapacity=capacity,CapacityAvailable=capacity>=#entries,
 CivilColorPool=palette.pool,ColorPoolFallback=palette.poolFallback or "none",CivilRandomSeed=palette.seed or "not assigned",PaletteStatus=palette.status}
end
function palette.allowed(token)
 return alive and running and workerToken==token and focused and activationTool and activationTool.Parent==player.Character
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
 if not root then return true end -- Native GUI disappeared during the transaction; stop/rebind before map input.
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
 palette.current=trace
 if #palette.transactions>=20 then table.remove(palette.transactions,1) end;table.insert(palette.transactions,trace)
 service.attributeBefore=paletteColor();service.previousIntended=v7.previousIntended;v7.previousIntended=entry.civilColor
 local function finish(ok,why)
  trace.PaletteStep=ok and "COMPLETE" or "FAILED";trace.FailureReason=why or "";trace.FinalPaletteRGB=rgbText(paletteColor())
  trace.PaletteMs=(os.clock()-started)*1000
  service.paletteUISelection=item and item.path or "unavailable"
  service.paletteProof="Native selected-color observation: "..trace.PaletteSuccessVia.."; working color confirmed only by province result"
  service.attributeAfter=paletteColor();service.attributeAfterEquip=paletteColor()
  if not ok then palette.status=trace.FailureReason end
  return ok,why
 end
 if not item then return finish(false,"No valid native palette mapping for assignment") end
 if not palette.allowed(token) then return finish(false,"Focus/tool/session unavailable") end
 if colorsMatch(paletteColor(),entry.civilColor) then
  palette.metrics.PaletteSkipsAlreadyCorrect+=1;trace.PaletteSuccessVia="ALREADY_CORRECT_ATTRIBUTE"
 else
  if not palette.visible(item.button) then
   trace.OpenerAttempted=true;palette.metrics.OpenerUses+=1
   local opened,why=palette.click(palette.opener,token,"OPENING",function() return palette.visible(item.button) end)
   local click=trace.Click;trace.OpenerActivatedObserved=click and click.ActivatedObserved or false
   trace.PaletteBecameVisible=palette.visible(item.button)
   if not opened then trace.OpenerFailures=1;palette.metrics.OpenerFailures+=1;return finish(false,"OPENER_FAILED: "..tostring(why)) end
  end
  trace.PaletteBecameVisible=palette.visible(item.button)
  palette.metrics.PaletteSelections+=1;local selectingAt=os.clock()
  local selected,why=palette.click(item,token,"SELECTING",function() return colorsMatch(paletteColor(),entry.civilColor) end,entry.civilColor)
  palette.metrics.PaletteSelectionTotal+=(os.clock()-selectingAt)*1000
  if not selected then palette.metrics.PaletteSelectionFailures+=1;return finish(false,"SWATCH_FAILED: "..tostring(why)) end
  palette.metrics.PaletteSelectionSuccesses+=1;trace.PaletteSuccessVia=trace.Click.PaletteSuccessVia
 end
 if palette.mapBlocked(entry,item) then
  if not palette.valid(palette.closer) then return finish(false,"PALETTE_BLOCKS_TARGET: learn a closer or move/close native palette") end
  trace.CloserAttempts=1;palette.metrics.CloserUses+=1
  local closed,why=palette.click(palette.closer,token,"CLOSING",function()
   if palette.closeRequired then return not palette.visible(item.button) end
   return not palette.mapBlocked(entry,item)
  end)
  if not closed then trace.CloserFailures=1;palette.metrics.CloserFailures+=1;return finish(false,"CLOSER_FAILED: "..tostring(why)) end
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
  if not compact then table.insert(lines,"BindingState="..tostring(item.bindingState).." | CurrentButtonPath="..(button and button:GetFullName() or "unbound").." | LastBoundGeneration="..tostring(item.lastBoundGeneration).." | BindingFailure="..tostring(item.bindingFailure)) end
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
 local fields={"PaletteStep","EntryId","IntendedRGB","CurrentPaintBucketRGB","PaletteSuccessVia","FinalPaletteRGB","FailureReason","PaletteMs","OpenerAttempted","OpenerActivatedObserved","PaletteBecameVisible","OpenerFailures","CloserAttempts","CloserFailures"}
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
 local data={Version=1,PlaceId=game.PlaceId,Controls={}}
 local function row(item)
  if not item then return nil end
  local r,g,b=normalizedRGB(item.color)
  local segments={};for _,part in ipairs(item.segments) do table.insert(segments,{Name=part.Name,ClassName=part.ClassName}) end
  return {Path=segments,FullGuiPath=item.path,RGB=r and {r,g,b} or nil,ColorKey=item.key,Signature=table.clone(item.signature),NormalizedClick={0.5,0.5},LearnedIndex=item.index,SuccessfulAutomaticSelections=item.successes,FailedAutomaticSelections=item.failures,Invalid=item.invalid==true}
 end
 for _,item in ipairs(palette.controls) do table.insert(data.Controls,row(item)) end
 data.Opener=row(palette.opener);data.Closer=row(palette.closer)
 return data
end
function palette.import(data)
 if running or workerActive or starting or ownedInput or selecting then return false,"Stop/finish selection before import" end
 if type(data)~="table" or data.Version~=1 or data.PlaceId~=game.PlaceId or type(data.Controls)~="table" or #data.Controls>PAL.MaxControls then return false,"Invalid profile version/game/size" end
 local built,seen={},{}
 local function resolve(row,needsColor)
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
  local identity=table.concat(pathKeys,"/")
  if needsColor then
   if seen[identity] then error("Duplicate control path") end;seen[identity]=true
  end
  local item={path=type(row.FullGuiPath)=="string" and row.FullGuiPath or identity,segments=segments,signature=table.clone(row.Signature),
   normalized=Vector2.new(0.5,0.5),successes=type(row.SuccessfulAutomaticSelections)=="number" and math.max(0,row.SuccessfulAutomaticSelections) or 0,
   failures=type(row.FailedAutomaticSelections)=="number" and math.max(0,row.FailedAutomaticSelections) or 0,
   validated=false,imported=true,bindingState="REBIND_PENDING",invalid=row.Invalid==true}
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
 palette.controls=built;palette.byButton={};palette.nextIndex=#built
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
	if not shouldTarget(entry) then return false end
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
		if not shouldTarget(entry) then return false end
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
			if not shouldTarget(entry) then return false end

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
					if not shouldTarget(entry) then return false end
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
	if not CFG.ShowDirtyState then entry.box.LineThickness=0.025;entry.box.Color3=targetColor(entry) or paletteColor();return end
	if v7.lock==entry then entry.box.LineThickness=0.085;entry.box.Color3=Color3.fromRGB(255,220,0)
	elseif entry.dirtyIndex then entry.box.LineThickness=0.07;entry.box.Color3=Color3.fromRGB(255,55,70)
	else entry.box.LineThickness=0.025;entry.box.Color3=Color3.fromRGB(75,230,145) end
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
	if p.Successes<3 then policy.choice="PER_TARGET";policy.reason="Waiting for three normalized paint successes before continuous sampling";return end
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
	if CFG.ActivationStrategy=="CONTINUOUS" and policy.normal.PER_TARGET.Successes<3 then return "PER_TARGET",policy.normal.PER_TARGET end
	if CFG.ActivationStrategy=="CONTINUOUS" or CFG.ActivationStrategy=="PER_TARGET" then
		return CFG.ActivationStrategy,policy.normal[CFG.ActivationStrategy]
	end
	policy.decide()
	return policy.choice,policy.normal[policy.choice]
end
function policy.learn(arm,success,latency,service)
	if success then
		arm.streak=0
		if #arm.latencies>=CFG.DwellHistory then table.remove(arm.latencies,1) end
		table.insert(arm.latencies,latency)
		if #arm.latencies>=CFG.DwellMinSamples then
			local sorted=table.clone(arm.latencies);table.sort(sorted)
			local value=math.clamp(sorted[math.ceil(#sorted*0.9)]+CFG.DwellMargin,CFG.TargetDwellMin,CFG.TargetDwellMax)
			-- Success-only P90 retains slower opportunities; bounded decay removes stale global penalties.
			arm.dwell=math.max(arm.dwell-(service and service.normal and 0.04 or 0.02),value)
			if service and service.normal then health.DwellIncreaseReason="successful P90 + margin" end
		end
	elseif service and service.validNoEffect then
		arm.streak+=1
		if service.normal then
			local e=service.entry;e.ExtraDwell=math.min(CFG.EntryExtraDwellMax,(e.ExtraDwell or 0)+0.02)
			arm.noEffects=arm.noEffects or {};local now=os.clock();arm.noEffects[e.id]=now
			local distinct=0
			for id,at in pairs(arm.noEffects) do if now-at>CFG.GlobalNoEffectWindow then arm.noEffects[id]=nil else distinct+=1 end end
			if distinct>=CFG.DistinctNoEffectEntries then
				arm.dwell=math.min(CFG.TargetDwellMax,arm.dwell+0.02);arm.noEffects={}
				health.DwellIncreaseReason="qualified no-effect on "..distinct.." distinct entries"
			else health.DwellIncreaseReason="entry-local qualified no-effect; global unchanged" end
		else arm.dwell=math.min(CFG.TargetDwellMax,arm.dwell+0.04) end
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
						weaker.retryAt=math.max(weaker.retryAt,now+CFG.EntryCooldowns[3])
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
	local record={EntryId=e.id,Position=tostring(e.part.Position),Label=entryLabel(e),IntendedRGB=rgbText(service.target),
		PaletteAttributeBefore=rgbText(service.attributeBefore),AttributeAfterSet="NOT WRITTEN BY AUTOPAINTER",
		PaletteAttributeAfter=rgbText(service.attributeAfter),AttributeAfterEquip=rgbText(service.attributeAfterEquip),
		PaletteUISelection=service.paletteUISelection or "normal palette chosen by player",
		PaletteProof=service.paletteProof or "NORMAL exposed palette; no internal closure assumption",
		PreviousIntendedRGB=rgbText(service.previousIntended),ActualRGBBefore=rgbText(service.actualBefore),ActualRGBAfter=rgbText(actual),
		NormalizedMatch=normalized,DeltaRGB=colorDelta(actual,service.target),MouseTargetCorrect=mouse.Target==e.part,TargetAcquired=service.acquiredAt~=nil,ServiceQualified=service.qualified,FullWindowCompleted=service.validNoEffect==true,
		AcquisitionMs=service.acquiredAt and (e.lastAcquireSeconds or 0)*1000 or 0,QueueWaitMs=service.queueWaitMs or 0,
		PalettePreparationMs=service.paletteMs or 0,ServiceMs=service.validAt and math.max(0,os.clock()-service.validAt)*1000 or 0,AcquiredToCorrectMs=service.latency and service.latency*1000 or "unobserved",
		Result=result,ActualChanged=not colorsMatch(service.actualBefore,actual)}
	if service.civil then
		record.Civil=true;record.DefenseResponseMs=service.success and service.attackAt and math.max(0,(service.entry.lastCorrectedTime or os.clock())-service.attackAt)*1000 or nil
		record.PaintMs=service.validAt and (service.success and math.max(0,(service.entry.lastCorrectedTime or os.clock())-service.validAt)*1000 or math.min(record.ServiceMs,service.dwell*1000)) or 0
		record.ReleaseMs=math.max(0,record.ServiceMs-record.PaintMs)
	end
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
	local service={entry=entry,strategy=strategy,arm=arm,started=started,normal=mode=="NORMAL",
		generation=equippedGeneration,qualified=false,success=false,retained=false,dwell=math.min(CFG.TargetDwellMax,arm.dwell+(mode=="NORMAL" and (entry.ExtraDwell or 0) or 0)),benchmark=true,
		target=targetColor(entry),actualBefore=entry.part.Color,attributeBefore=paletteColor(),civil=mode=="CIVIL WAR",
		paletteValid=false,attackAt=entry.attackAt,queueWaitMs=entry.dirtyQueueInsertTime and (started-entry.dirtyQueueInsertTime)*1000 or 0}
	policy.current=service;entry.service=service
	return service
end
function policy.qualify(service)
	if service.qualified then return end
	service.qualified=true
	service.validAt=math.max(service.entry.acquiredAt or os.clock(),ownedInput and ownedInput.MouseObservedAt or os.clock())
	service.entry.lastPaintAttempt=service.validAt
	service.entry.lastValidService=service
	service.method=ownedInput and ownedInput.Method or nil
	service.acquiredAt=service.entry.acquiredAt
	metrics.Attempts+=1
end
function health.finish(service)
 local entry=service.entry
 if service.success then service.result="SUCCESS";health.reset(entry,true);return end
 if service.interruption then service.result=service.interruption
 elseif not focused then service.result="FOCUS_LOST"
 elseif not activationTool or activationTool.Parent~=player.Character then service.result="TOOL_UNAVAILABLE"
 elseif releaseBlocked then service.result="RELEASE_RECOVERY"
 elseif not service.result then service.result="INTERRUPTED" end
 local reason=service.result
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
 if count>=CFG.MaxConsecutiveEntryFailures then
  if count%CFG.MaxConsecutiveEntryFailures==0 then entry.quarantineLevel=math.min(#CFG.EntryCooldowns,(entry.quarantineLevel or 0)+1) end
  cooldown=CFG.EntryCooldowns[math.max(1,entry.quarantineLevel or 1)]
  health.TargetQuarantines+=1;action=reason=="VALID_NO_EFFECT" and "entry timing cooldown" or "invalidate cache; quarantine"
 end
 entry.failures=count;entry.retryAt=math.max(entry.retryAt or 0,os.clock()+cooldown);entry.waitSince=os.clock()
 entry.lastServicedAt=os.clock();metrics.Deferred+=1
 if reason=="VALID_NO_EFFECT" then metrics.Stalled+=1;noEffect+=1 end
 health.event(entry,reason,action,old,cooldown,"deferred")
end
function policy.finish(service,stalled)
	if not service or service.finished then return end
	service.finished=true;service.endedAt=os.clock();policy.account()
	health.finish(service)
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
		if service.normal then policy.decide() end
	elseif service.qualified then arm.Aborted+=1;metrics.AbortedServices+=1 end
	if service.entry.service==service then service.entry.service=nil end
	if policy.current==service then policy.current=nil end
	v7.record(service,stalled)
	v7.unlockTarget(service.entry)
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
	local fields={"EntryId","Position","IntendedRGB","PaletteAttributeBefore","AttributeAfterSet","PaletteAttributeAfter","AttributeAfterEquip","PaletteUISelection","PaletteProof","PreviousIntendedRGB","ActualRGBBefore","ActualRGBAfter","DeltaRGB","NormalizedMatch","MouseTargetCorrect","TargetAcquired","ServiceQualified","FullWindowCompleted","ActualChanged","QueueWaitMs","AcquisitionMs","PalettePreparationMs","ServiceMs","AcquiredToCorrectMs","PaintMs","ReleaseMs","DefenseResponseMs","Result"}
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
	for key,value in pairs(v7.stats()) do result[key]=value end
	for key,value in pairs(palette.performance()) do result[key]=value end
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
	entry.corrected=true;health.reset(entry,true);entry.lastCorrectedTime=observedAt
	corrections+=1;metrics.Corrections+=1;metrics.ColorTotal+=latency;bumpRate("Corrections")
	service.success,service.latency,service.paletteValid=true,latency,true
	if service.finished then
		v7.LateCorrections+=1
		if service.sample and not service.sample.success then
			service.sample.success=true;service.sample.latency=latency;service.arm.Successes+=1
			if service.failedCounted then v7.FailedValidServices=math.max(0,v7.FailedValidServices-1);service.failedCounted=false end
		end
		if service.record then
			service.record.Result="SUCCESS_LATE";service.record.NormalizedMatch=true;service.record.ActualRGBAfter=rgbText(entry.part.Color)
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
	if wrong and changed then entry.lastWrongColorChange=now end
	if wrong then
		addDirty(entry,now)
		if not wasDirty and entry.wasClean and (colorEvent or source=="reconcile") then
			entry.attackAt=now;entry.freshAttackAt=now;entry.failures,entry.retryAt=0,0
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
		if target then noteCorrection(entry) end
		if not entry.service then entry.attackAt=nil end
	end
	if source=="reconcile" and wasDirty~=wrong then metrics.ReconciliationFinds+=1 end
	entry.wasClean=not wrong
	v7.draw(entry)
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
	if not shouldTarget(entry) then v7.CleanSkippedBeforeCursor+=1;syncDirty(entry,"check");return false end
	if not liveToken(token) or not entry.active or not validProvince(entry.part) then return false end
	local before=mouse.Target
	if not ownedTargetSafe(entry,before) then if not settleRelease() then return false end end
	local moved=true
	if mouse.Target~=entry.part then
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
	if candidate.point then
		metrics.CursorAcquireAttempts+=1
		if moveCursor(candidate,token) then metrics.CursorAcquireSuccesses+=1;return true end
		if liveToken(token) and shouldTarget(entry) then
			local oldIndex=candidate.index
			local oldCache=health.invalidate(entry,false)
			health.event(entry,"CURSOR_POINT_MISMATCH","invalidate cursor; alternate projected surface",oldCache,0,"fresh projection")
			geometry(entry)
			entry.sampleCursor=(oldIndex or 1)%#entry.surfacePoints+1
			local alternate=visiblePoint(entry)
			if alternate and moveCursor(alternate,token) then metrics.CursorAcquireSuccesses+=1;return true end
		end
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
	if not shouldTarget(entry) then v7.CleanSkippedBeforeCursor+=1;syncDirty(entry,"check");return false end
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
	local owner={Method=primaryMethod,Tool=tool,Before=entry.part.Color,Down=downSeen,
		EquippedDown=equippedDownSeen,ToolDown=toolDownSeen,Started=os.clock()}
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
		if not shouldTarget(entry) then v7.CleanSkippedBeforeCursor+=1;syncDirty(entry,"check");continue end
		if not v7.lockTarget(entry) then
			if not settleRelease() then running=false;break end
			continue
		end
		currentEntry=entry;activation.TargetAcquired=false
		entry.acquiredAt,entry.earlyCorrectionAt,entry.corrected=nil,nil,false
		local target=targetColor(entry)
		local tool=ensureBucket()
		if not tool then lastMessage="PaintBucket unavailable; stopped";running=false;break end
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
			local prepared,why=palette.prepare(entry,token,service)
			service.paletteMs=(os.clock()-paletteStarted)*1000
			if not prepared then
				service.result="PALETTE_PREPARATION_FAILED: "..tostring(why);v7.PaletteFailures+=1
				lastMessage=service.result;palette.status=lastMessage;palette.resumeNeeded=true;running=false;policy.finish(service,false);break
			end
			service.paletteValid=true
		else
			service.paletteValid=colorsMatch(paletteColor(),target)
			service.attributeAfter=paletteColor();service.attributeAfterEquip=paletteColor();service.paletteMs=0
		end
		if not liveToken(token) or not entry.active then break end
		if not entry.dirtyIndex or colorsMatch(entry.part.Color,target) then service.result="CLEAN_BEFORE_DOWN";syncDirty(entry,"check");policy.finish(service,false);continue end
		began=os.clock()
		service.retained=ownedInput~=nil and not ownedInput.ReleaseSent
		metrics.AcquisitionAttempts+=1
		if not acquireFast(candidate,token) then
			service.result=colorsMatch(entry.part.Color,target) and "CLEAN_BEFORE_DOWN" or "ACQUIRE_FAILED"
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
		entry.lastPaintAttempt=os.clock()
		if not startOrRetainHold(entry,token) then
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
			waitWork()
		end
		if strategy=="PER_TARGET" then
			if not settleRelease() then running=false end
		end
		policy.finish(service,stalled)
		if entry.forceFullService then
			entry.forceFullService=nil
			if entry.dirtyIndex then entry.retryAt=math.max(entry.retryAt,os.clock()+0.5) end
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
	lookup[part] = entry

	local box = Instance.new("SelectionBox")
	box.Name = "HandsFreeProtected"
	box.Adornee = part
	box.SurfaceTransparency = 1
	box.LineThickness = 0.025
	box.Color3 = targetColor(entry) or paletteColor()
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

-- UI -------------------------------------------------------------------------

local gui = Instance.new("ScreenGui")
gui.Name = GUI_NAME
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = playerGui

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
title.Text = "AutoPainter · HANDS FREE v8.1"
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
palette.seedBox=Instance.new("TextBox");palette.seedBox.Name="CivilRandomSeed";palette.seedBox.PlaceholderText="Reroll seed (blank = random)"
palette.seedBox.Text="";palette.seedBox.TextSize=14;palette.seedBox.Size=UDim2.new(1,-20,0,34);palette.seedBox.Position=UDim2.fromOffset(10,325);palette.seedBox.Parent=palettePanel
palette.info=Instance.new("TextLabel");palette.info.Position=UDim2.fromOffset(10,365);palette.info.Size=UDim2.new(1,-20,0,200)
palette.info.BackgroundTransparency=1;palette.info.TextColor3=Color3.new(1,1,1);palette.info.TextWrapped=true;palette.info.TextSize=14;palette.info.Parent=palettePanel
local performanceFields={"ActivationStrategy","StrategyConfigured","StrategyDecisionCached","StrategyDecisionReason","VirtualInputHold",
	"DownEvents","UpEvents","Attempts","CompletedServices","AbortedServices","SuccessfulPaints","SuccessRate","CorrectionsPerSecond","OverallCorrectionsPerSecond",
	"AverageTargetDwellMs","AdaptiveDwellMs","AverageAcquisitionMs","AverageAcquiredToColorMs","AverageSwitchMs","ActiveTarget","DirtyCount","Deferred","Stalled",
	"CachedCursorHits","CachedCameraHits","FullCameraSearches","TargetAcquisitionsPerSecond","CursorAcquireSuccessRate","CameraFallbackRate",
	"ColorEventsReceived","DirtyEventsWithoutHover","AverageColorEventToDirtyQueueMs","MaxColorEventToDirtyQueueMs","ReconciliationFinds","ReconciliationChecks",
	"FreshAttackCorrections","AverageAttackColorChangeToCorrectedMs","MinimumAttackResponseMs","MaximumAttackResponseMs","RecentlyChangedQueueDepth",
	"SessionConfirmed","Runtime","AutoPainterRPCs"}
local function performanceReport()
	local m=reportPerformance();local lines={"AUTOPAINTER v8.1 — observed corrections; native RPCs unobserved"}
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
	frame.Visible = not running and not selecting
	liveStatus.Visible = running or selecting=="PALETTE"
	modeButton.Text = "Mode: " .. mode
	startButton.Text = running and "STOP AUTO" or (palette.resumeNeeded and "RESUME" or "START AUTO")
	local c = normalTarget or paletteColor()
	counts.Text = string.format(
		"Selected: %d · Dirty: %d · Mode: %s\nCorrections: %d · Aim fails: %d · No effect: %d · Input errors: %d",
		activeCount(), dirtyCount(), mode, corrections, aimFailures, noEffect, inputErrors
	)
	status.Text = lastMessage.."\n"..palette.status
		.. "\nAcquire: " .. lastAcquireDetail
		.. "\nTarget acquired: " .. tostring(activation.TargetAcquired) .. " · Method: " .. activation.Method
		.. "\nActivation attempted: " .. tostring(activation.Attempted)
		.. " · Activation observed: " .. activation.Observation
		.. "\nColor changed: " .. tostring(activation.ColorChanged) .. " · Target color: " .. tostring(activation.TargetColorObserved)
		.. (mode == "NORMAL" and ("\nNormal target: " .. tostring(c))
			or "\nCivil War: unique target color per province")

	local perf=reportPerformance()
	liveStatus.Text=string.format("AUTO v8.1 · Q / Escape to stop · %s\n%s · %s\nDirty %d · Attempts %d · Success %d (%.0f%%) · Corrections/s %.2f\nDwell %.0f / limit %.0f ms · Acquire %.1f ms · To color %.1f ms · Switch %.1f ms\nAcq/s %.1f · Cursor %.0f%% · Camera fallback %.0f%%\nCursor cache %d · Camera cache %d · Full search %d\nDeferred %d · Stalls %d · Hold %s · Down/Up %d/%d\nColor events %d · Away from cursor %d · Queue avg/max %.2f/%.2f ms\nFresh queue %d · Attack corrections %d · Response %.1f ms\nTarget: %s",
		perf.ActivationStrategy,activation.Method,activation.Observation,
		perf.DirtyCount,perf.Attempts,perf.SuccessfulPaints,perf.SuccessRate*100,perf.CorrectionsPerSecond,
		perf.AverageTargetDwellMs,perf.AdaptiveDwellMs,perf.AverageAcquisitionMs,perf.AverageAcquiredToColorMs,perf.AverageSwitchMs,
		perf.TargetAcquisitionsPerSecond,perf.CursorAcquireSuccessRate*100,perf.CameraFallbackRate*100,
		perf.CachedCursorHits,perf.CachedCameraHits,perf.FullCameraSearches,perf.Deferred,perf.Stalled,tostring(perf.VirtualInputHold),perf.DownEvents,perf.UpEvents,
		perf.ColorEventsReceived,perf.DirtyEventsWithoutHover,perf.AverageColorEventToDirtyQueueMs,perf.MaxColorEventToDirtyQueueMs,
		perf.RecentlyChangedQueueDepth,perf.FreshAttackCorrections,perf.AverageAttackColorChangeToCorrectedMs,perf.ActiveTarget)

	local capacity=perf.CivilCapacity
 palette.info.Text=string.format("Civil capacity: %d unique colors\nSelected: %d\nCapacity available: %s\nSeed: %s\n%s\n%s",capacity,#entries,perf.CivilCapacityStatus=="temporarily unavailable" and "TEMPORARILY UNAVAILABLE (learned data retained)" or capacity>=#entries and "YES" or "NO",tostring(palette.seed or "automatic"),palette.status,palette.current.PaletteStep)
 if running and mode=="CIVIL WAR" then liveStatus.Text..="\nPalette: "..palette.current.PaletteStep.." | "..tostring(palette.current.IntendedRGB).." | "..tostring(palette.current.Click and palette.current.Click.TargetControlName or "already selected") end
 if running and palette.compactHUD then
  local recent=perf.Strategies.PER_TARGET
  liveStatus.Size=UDim2.fromOffset(330,112)
  liveStatus.Text=string.format("AUTO · Q/Escape STOP · %s\nDirty %d · Recent %.0f%% · Corrections/s %.2f\nMedian/P90 response %.1f / %.1f ms\n%s",mode,perf.DirtyCount,recent.SuccessRate*100,perf.CorrectionsPerSecond,perf.MedianDefenseResponseMs,perf.P90DefenseResponseMs,perf.ActiveTarget)
 else liveStatus.Size=UDim2.fromOffset(470,250) end
 if selecting=="PALETTE" then
		liveStatus.Text="NATIVE PALETTE SETUP · "..tostring(palette.learning or "Captured").."\n"..palette.status.."\nClick only the normal game's palette controls, then DONE / FINISH SETUP."
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
	if selecting=="PALETTE" then palette.status=string.format("Palette learned: %d verified colors",#palette.available()) end
	palette.learning=nil;palette.pending=nil
	selecting = nil
	frame.Visible = true
	doneButton.Visible = false
	lastMessage = "Selection finished"
	updateUI()
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
	if not alive or not focused or selecting or workerActive or inputBusy or restoringPalette then return false end
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

	policy.current=nil;v7.lock=nil;dirtyCursor=0;nextWorkerAt=nil;health.sameEntry=nil;health.sameFailures=0
	v7.sequence={};v7.lastTargetId=nil;v7.lastPair=nil
	for _,arm in pairs(mode=="NORMAL" and policy.normal or {policy.civil}) do
		arm.noEffects={};arm.streak=0
		if #arm.latencies>=CFG.DwellMinSamples then
			local sorted=table.clone(arm.latencies);table.sort(sorted)
			arm.dwell=math.clamp(sorted[math.ceil(#sorted*0.9)]+CFG.DwellMargin,CFG.TargetDwellMin,CFG.TargetDwellMax)
		else arm.dwell=CFG.TargetDwellDefault end
	end
	palette.rebindAll("Explicit START/RESUME")
	for _, e in ipairs(entries) do
		if e.active then
			health.reset(e,false);e.service=nil;e.forceFullService=nil
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
		if v7.lock then v7.unlockTarget(v7.lock) end
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
	if value then palette.resumeNeeded=false end
	return value
end

local function toggleAuto()
	if running then stop("Stopped") else startAuto() end
	updateUI()
end

modeButton.Activated:Connect(function()
	if running then stop("Stopped before changing mode") end
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
	if input.KeyCode == Enum.KeyCode.Q then
		toggleAuto()
		return
	end
	if (selecting=="ADD" or selecting=="REMOVE") and input.UserInputType == Enum.UserInputType.MouseButton1 then
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
	health.lastMethod,health.lastTool=nil,nil;table.clear(palette.roots)
	wake:Destroy()
	gui:Destroy()
end
local function closeController()
	if not alive then return end
	stop("Closed")
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
	if running and mode=="NORMAL" and not colorsMatch(paletteColor(),normalTarget) then stop("NORMAL target color changed — restart required") end
end)

connectLifetime(UserInputService.WindowFocusReleased, function()
	focused=false
	palette.resumeNeeded=running or workerActive
	stop("Client lost focus; activation stopped")
end)
connectLifetime(UserInputService.WindowFocused, function() focused=true;palette.rebindAll("Focus returned");if palette.resumeNeeded then lastMessage="Focus restored — press RESUME";updateUI() end;wakeWork() end)
connectLifetime(player:GetPropertyChangedSignal("Character"), function()
 palette.invalidateBindings("Character changed")
	if running then palette.resumeNeeded=true;stop("Character changed; re-equip and press RESUME") end
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
		return {ConsecutiveAcquireFailures=e.ConsecutiveAcquireFailures or 0,ConsecutiveTargetLosses=e.ConsecutiveTargetLosses or 0,
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
			MarkerThickness=e.box and e.box.LineThickness,MarkerColor=e.box and e.box.Color3,
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
			Version = 8.1,
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
