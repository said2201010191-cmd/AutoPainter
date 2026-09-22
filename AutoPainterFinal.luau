-- AutoPainterFinal: client-only successor to AutoPainterFastClient.luau.
-- Legacy call shape only; the normal game's PaintBucket protocol is UNVERIFIED.
-- Run through the public client loader; no place access or installation required.
-- Each client uses its own LocalPlayer, UI, selection, and bounded request window.

local CONFIG = {
	DiagnosticOnly = true, -- Default to zero traffic while the first-request kick is unresolved.
	DiagnosticMaxNodes = 96,
	DiagnosticMaxDepth = 8,
	DiagnosticMaxAttributes = 12,
	DiagnosticMaxSelections = 24,
	DiagnosticMaxText = 24000,
	DiagnosticPageCharacters = 4000, -- Display pages only; never truncates the inventory.
	DiagnosticPageLines = 40,
	ProtocolBefore = 8,
	ProtocolAfter = 12,
	Normal = { Initial = 8, Min = 2, Max = 24, MaxPerProvince = 2, Rate = 160, Burst = 8, Batch = 16 },
	Fast = { Initial = 16, Min = 4, Max = 64, MaxPerProvince = 6, Rate = 360, Burst = 16, Batch = 32 },
	Safe = { Initial = 1, Min = 1, Max = 1, MaxPerProvince = 1, Rate = 4, Burst = 1, Batch = 1 },
	HardOutstanding = 64, -- Includes stalled calls and calls using an old remote.
	SafeProvinceInterval = 1,
	Adaptive = true,
	TuneInterval = 2,
	MinTuneReturns = 8,
	RetryBase = 0.20,
	RetryMax = 5,
	StallSeconds = 15, -- Diagnostic only: a timeout cannot cancel a server operation.
	WatchdogInterval = 0.5,
	TelemetryInterval = 1,
}

local options = ...
if type(options) ~= "table" then options = {} end
local diagnosticOnly = CONFIG.DiagnosticOnly
if type(options.DiagnosticOnly) == "boolean" then diagnosticOnly = options.DiagnosticOnly end
local diagnosticLocked = options.LockDiagnostics == true
if diagnosticLocked then diagnosticOnly = true end

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Input = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local player = Players.LocalPlayer
assert(player, "AutoPainter must run on the client")
local playerGui = player:WaitForChild("PlayerGui")
local GUI_NAME = "AutoPainterFinalUI"

-- Re-running the loader reuses the running instance without ending selection.
local existing = playerGui:FindFirstChild(GUI_NAME)
if existing then
	local bridge = existing:FindFirstChild("Controller")
	if bridge and bridge:IsA("BindableFunction") then
		if diagnosticOnly and existing:GetAttribute("AutoPainterDiagnosticsVersion") ~= 5 then
			error("Close the older AutoPainter panel before loading this diagnostic build; it lacks the current report.")
		end
		local running = bridge:Invoke()
		if diagnosticOnly then running.SetDiagnostic(true, diagnosticLocked) end
		return running
	end
	existing:Destroy()
end

local alive = true
local connections, cacheConnections = {}, {}
local entries, lookup = {}, {}
local pendingHead, pendingTail = nil, nil -- Selection transaction, NOT outstanding RPCs.
local pendingCount = 0
local readyHead, readyTail = nil, nil
local readyCount = 0
local delayed = {} -- Indexed min-heap: at most one retry timer per province.
local jobs, pendingByPart = {}, {} -- A part's group survives removal/re-add and respawn.
local selectionId = 0
local outstanding, stalled = 0, 0
local color = Color3.fromRGB(255, 255, 255)
local painting, fast, safe, keepColor = true, false, false, false
local mode = CONFIG.Normal
local window = mode.Initial
local tokens, tokenTime = mode.Burst, os.clock()
local frameBudget = mode.Batch
local remote, character, bucket, remotes = nil, nil, nil, nil
local resolvedRemote = nil
local cacheDirty = false
local cacheVersion = 0
local pumpQueued, pumping = false, false
local rtt = 0.15
local stats = { Attempted = 0, Returned = 0, Failures = 0, Observed = 0, Stalls = 0, Suppressed = 0 }
local sample = { Returned = 0, Failures = 0, Latency = 0, BusyTime = 0 }
local epoch = os.clock()
local probe = nil
local steady = nil
local probeDirection = 1
local tuneCooldown = 0
local lastWatchdog, lastDisplay = epoch, epoch
local lastObserved, lastReturned = 0, 0
local evaluate, removeEntry, kick, refreshCache, invalidateCache
local ui, main, doneButton, statusLabel, detailLabel, colorButton
local selectionMode = nil
local api = {}

local function connect(signal, fn, list)
	local connection = signal:Connect(fn)
	table.insert(list or connections, connection)
	return connection
end

local function disconnectAll(list)
	for _, connection in ipairs(list) do connection:Disconnect() end
	table.clear(list)
end

local function targetColor(entry)
	-- Preserve original semantics: selected color at registration, not Part.Color.
	return keepColor and entry.savedColor or color
end

local function valid(part)
	return part:IsA("BasePart") and part.Name == "Province" and part:IsDescendantOf(Workspace)
end

local function unqueue(entry)
	if not entry.queued then return end
	if entry.previous then entry.previous.next = entry.next else readyHead = entry.next end
	if entry.next then entry.next.previous = entry.previous else readyTail = entry.previous end
	entry.previous, entry.next, entry.queued = nil, nil, false
	readyCount -= 1
end

local function enqueue(entry)
	if entry.queued or not entry.active or not entry.committed then return end
	entry.queued, entry.previous, entry.next = true, readyTail, nil
	if readyTail then readyTail.next = entry else readyHead = entry end
	readyTail = entry
	readyCount += 1
end

local function heapSwap(a, b)
	delayed[a], delayed[b] = delayed[b], delayed[a]
	delayed[a].heapIndex, delayed[b].heapIndex = a, b
end

local function siftUp(index)
	while index > 1 do
		local parent = math.floor(index / 2)
		if delayed[parent].due <= delayed[index].due then break end
		heapSwap(parent, index)
		index = parent
	end
	return index
end

local function siftDown(index)
	while index * 2 <= #delayed do
		local child = index * 2
		if child < #delayed and delayed[child + 1].due < delayed[child].due then child += 1 end
		if delayed[index].due <= delayed[child].due then break end
		heapSwap(index, child)
		index = child
	end
end

local function unschedule(entry)
	local index = entry.heapIndex
	if not index then return end
	local last = table.remove(delayed)
	entry.heapIndex = nil
	if index <= #delayed then
		delayed[index], last.heapIndex = last, index
		siftDown(siftUp(index))
	end
end

local function schedule(entry, due)
	if not entry.active or not entry.committed then return end
	unqueue(entry)
	unschedule(entry)
	entry.due = due
	table.insert(delayed, entry)
	entry.heapIndex = #delayed
	siftUp(entry.heapIndex)
end

local function resetSample(now)
	for key in pairs(sample) do sample[key] = 0 end
	epoch, probe, steady, tuneCooldown = now, nil, nil, 0
	probeDirection = 1
end

local function retryDelay(entry)
	entry.failures = math.min(entry.failures + 1, 8)
	-- Bounded deterministic staggering avoids synchronized retries, without RNG hot work.
	return math.min(CONFIG.RetryMax, CONFIG.RetryBase * 2 ^ (entry.failures - 1))
		* (0.9 + (entry.index % 5) * 0.05)
end

local function canOverlap(part, desired)
	local group = pendingByPart[part]
	-- Count stalled and old-remote calls too. Never overlap different target colors.
	return not group or (group.count < mode.MaxPerProvince and group.color == desired)
end

evaluate = function(entry, now)
	if not alive or not entry.active then return end
	local part = entry.part
	if not valid(part) then removeEntry(entry); return end
	-- Pending selections may be validated/removed by lifecycle events, never scheduled.
	if not entry.committed then return end
	local desired = targetColor(entry)
	local matched = part.Color == desired
	-- Count a target-color transition once, not once for each overlapping request.
	-- This observation is independent of RPC outcomes and may be caused by others.
	if matched and not entry.matched then stats.Observed += 1 end
	entry.matched = matched
	if matched or diagnosticOnly or not painting or selectionMode then
		unqueue(entry)
		unschedule(entry)
		return
	end
	if not canOverlap(part, desired) then unqueue(entry); unschedule(entry); return end
	local due = entry.notBefore
	if safe then due = math.max(due, entry.lastSent + CONFIG.SafeProvinceInterval) end
	if due > now then schedule(entry, due); return end
	unschedule(entry)
	enqueue(entry)
	if kick then kick() end
end

local function unlinkPending(entry)
	if entry.committed then return end
	if entry.pendingPrevious then entry.pendingPrevious.pendingNext = entry.pendingNext else pendingHead = entry.pendingNext end
	if entry.pendingNext then entry.pendingNext.pendingPrevious = entry.pendingPrevious else pendingTail = entry.pendingPrevious end
	entry.pendingPrevious, entry.pendingNext = nil, nil
	pendingCount -= 1
end

removeEntry = function(entry)
	if not entry.active then return end
	entry.active = false
	unlinkPending(entry)
	unqueue(entry)
	unschedule(entry)
	lookup[entry.part] = nil
	disconnectAll(entry.connections)
	entry.box:Destroy()
	entry.box = nil
	local index, last = entry.index, table.remove(entries)
	if index <= #entries then entries[index], last.index = last, index end
	entry.part = nil
end

local function clearProvinces()
	while #entries > 0 do removeEntry(entries[#entries]) end
	-- Real pending RPCs retain their own bounded accounting until they return.
	resetSample(os.clock())
end

local function addProvince(part)
	if not alive or not part or not valid(part) or lookup[part] then return false end
	-- Adorn the actual part: no duplicate geometry, physics, scripts or clone queries.
	local box = Instance.new("SelectionBox")
	box.Name = "ProtectedProvince"
	box.Adornee = part
	box.Color3 = color
	box.SurfaceTransparency = 1
	box.LineThickness = 0.025
	box.Parent = ui
	selectionId += 1
	local entry = { part = part, savedColor = color, active = true, committed = false, box = box, id = selectionId,
		connections = {}, index = #entries + 1, failures = 0, notBefore = 0,
		failureEpoch = 0, lastSent = -math.huge, queued = false, matched = part.Color == color }
	entries[entry.index], lookup[part] = entry, entry
	entry.pendingPrevious = pendingTail
	if pendingTail then pendingTail.pendingNext = entry else pendingHead = entry end
	pendingTail = entry
	pendingCount += 1
	connect(part:GetPropertyChangedSignal("Color"), function() evaluate(entry, os.clock()) end, entry.connections)
	connect(part:GetPropertyChangedSignal("Name"), function() evaluate(entry, os.clock()) end, entry.connections)
	connect(part.AncestryChanged, function() evaluate(entry, os.clock()) end, entry.connections)
	connect(part.Destroying, function() removeEntry(entry) end, entry.connections)
	-- No evaluate, queue, token use, worker creation or scheduler wake on registration.
	return true
end

local function evaluateAll(now)
	-- Only on explicit resume/selection finish, never a full per-frame scan.
	local index = 1
	while index <= #entries do
		local entry = entries[index]
		evaluate(entry, now)
		if entries[index] == entry then index += 1 end -- Removal can swap the last entry here.
	end
end

local function commitPending(now)
	-- No yield: mark the entire transaction committed before evaluating its first entry.
	local first, entry = pendingHead, pendingHead
	while entry do entry.committed = true; entry = entry.pendingNext end
	pendingHead, pendingTail, pendingCount = nil, nil, 0
	entry = first
	while entry do
		local nextEntry = entry.pendingNext
		entry.pendingPrevious, entry.pendingNext = nil, nil
		entry.matched = entry.part.Color == targetColor(entry) -- Pending observations are not paints.
		if painting then evaluate(entry, now) end
		entry = nextEntry
	end
end

local function releaseRequest(job)
	jobs[job] = nil
	job.group.count -= 1
	if job.group.count == 0 then pendingByPart[job.part] = nil end
	outstanding -= 1
	if job.stalled then stalled -= 1 end
end

local function finishRequest(job, ok)
	-- Release first, even if the selection, remote, mode or UI changed during the yield.
	releaseRequest(job)
	local now = os.clock()
	local elapsed = now - job.started
	if ok then stats.Returned += 1 else stats.Failures += 1 end
	if not alive then return end
	if job.version == cacheVersion then
		if ok then
			sample.Returned += 1
			sample.Latency += elapsed
			if not job.stalled then rtt += (elapsed - rtt) * 0.15 end
		else sample.Failures += 1 end
	end
	local entry = lookup[job.part]
	if entry then
		if entry.id == job.selectionId and job.version == cacheVersion and targetColor(entry) == job.color then
			if ok then
				-- An older sibling's return must not erase a newer error's cooldown.
				if job.failureEpoch == entry.failureEpoch then entry.failures, entry.notBefore = 0, 0 end
			else
				entry.failureEpoch += 1
				entry.notBefore = math.max(entry.notBefore, now + retryDelay(entry))
			end
		end
		evaluate(entry, now)
	end
	if not ok and job.version == cacheVersion then invalidateCache() end
	kick()
end

local function invoke(job)
	-- The scheduler reserves capacity BEFORE spawning. No tasks wait for a slot.
	-- Final transport guard also covers a reserved worker that has not started yet.
	if diagnosticOnly or not alive or not painting or selectionMode then
		releaseRequest(job)
		job.remote = nil
		stats.Suppressed += 1
		return
	end
	stats.Attempted += 1
	local ok = pcall(function()
		job.remote:InvokeServer("PaintPart", { Part = job.part, Color = job.color }, "Peace")
	end)
	job.remote = nil
	finishRequest(job, ok)
end

local function refill(now)
	tokens = math.min(mode.Burst, tokens + (now - tokenTime) * mode.Rate)
	tokenTime = now
end

local function pump()
	pumpQueued = false
	if not alive or pumping or diagnosticOnly or not painting or selectionMode or not remote then return end
	if not ui:IsDescendantOf(playerGui) then api.Destroy(); return end
	pumping = true
	local now = os.clock()
	refill(now)
	local visited = 0
	while readyHead and tokens >= 1 and frameBudget > 0
		and outstanding < CONFIG.HardOutstanding and (outstanding - stalled) < window
		and (not safe or outstanding < 1)
		and visited < mode.Batch do
		local entry = readyHead
		unqueue(entry)
		visited += 1
		local desired = targetColor(entry)
		if not entry.active or not entry.committed then continue end
		if not valid(entry.part) then removeEntry(entry)
		elseif entry.part.Color == desired or not canOverlap(entry.part, desired)
			or entry.notBefore > now or (safe and now < entry.lastSent + CONFIG.SafeProvinceInterval) then
			evaluate(entry, now)
		else
			local group = pendingByPart[entry.part]
			if not group then
				group = { count = 0, color = desired }
				pendingByPart[entry.part] = group
			end
			group.count += 1
			local job = { part = entry.part, color = desired, remote = remote,
				started = now, version = cacheVersion, stalled = false, group = group,
				selectionId = entry.id, failureEpoch = entry.failureEpoch }
			entry.lastSent = now
			jobs[job] = true
			outstanding += 1
			tokens -= 1
			frameBudget -= 1
			task.spawn(invoke, job)
			-- One request per visit. Extra capacity goes behind all waiting provinces.
			evaluate(entry, now)
			if not remote or not alive or diagnosticOnly or not painting or selectionMode then break end
		end
	end
	pumping = false
end

kick = function()
	if not alive or pumpQueued or pumping or diagnosticOnly or not painting or selectionMode or not remote or not readyHead then return end
	if frameBudget <= 0 or outstanding >= CONFIG.HardOutstanding or (outstanding - stalled) >= window then return end
	if safe and outstanding >= 1 then return end
	refill(os.clock())
	if tokens < 1 then return end
	pumpQueued = true
	task.defer(pump) -- Coalesce color/return bursts; never recurse from a completion.
end

refreshCache = function()
	cacheDirty = false
	if not alive then return end
	disconnectAll(cacheConnections)
	local oldRemote = resolvedRemote
	character = player.Character
	bucket = character and character:FindFirstChild("PaintBucket")
	remotes = bucket and bucket:FindFirstChild("Remotes")
	local candidate = remotes and remotes:FindFirstChild("ServerControls")
	remote = candidate and candidate:IsA("RemoteFunction") and character:IsDescendantOf(Workspace) and candidate or nil
	resolvedRemote = remote
	local function watchChildren(parent, childName)
		if not parent then return end
		connect(parent.ChildAdded, function(child)
			if child.Name == childName then invalidateCache() end
		end, cacheConnections)
		connect(parent.ChildRemoved, function(child)
			if child.Name == childName then invalidateCache() end
		end, cacheConnections)
	end
	watchChildren(character, "PaintBucket")
	watchChildren(bucket, "Remotes")
	watchChildren(remotes, "ServerControls")
	for _, object in ipairs({ character, bucket, remotes, candidate }) do
		connect(object.AncestryChanged, invalidateCache, cacheConnections)
		connect(object:GetPropertyChangedSignal("Name"), invalidateCache, cacheConnections)
	end
	if remote ~= oldRemote then
		cacheVersion += 1
		window = mode.Initial
		resetSample(os.clock())
	end
	kick()
end

invalidateCache = function()
	if not alive or cacheDirty then return end
	cacheDirty = true
	remote = nil -- Stop dispatch immediately; hierarchy changes may precede a deferred refresh.
	task.defer(refreshCache)
end

local function retargetAll()
	local now = os.clock()
	for index = #entries, 1, -1 do
		local entry = entries[index]
		entry.notBefore, entry.failures = 0, 0
		entry.failureEpoch += 1
		entry.matched = entry.part.Color == targetColor(entry)
		entry.box.Color3 = targetColor(entry)
		evaluate(entry, now)
	end
	resetSample(now)
end

local function updateMode()
	mode = safe and CONFIG.Safe or (fast and CONFIG.Fast or CONFIG.Normal)
	window = mode.Initial
	tokens, tokenTime = math.min(tokens, mode.Burst), os.clock()
	frameBudget = math.min(frameBudget, mode.Batch)
	resetSample(tokenTime)
	for index = #entries, 1, -1 do evaluate(entries[index], tokenTime) end
	kick()
end

local function tune(now)
	local duration = now - epoch
	if duration < CONFIG.TuneInterval then return end
	local returns, failures = sample.Returned, sample.Failures
	local returnRate = returns / duration -- No server contract: a return is not a confirmed hit.
	local latency = returns > 0 and sample.Latency / returns or rtt
	local busy = sample.BusyTime / duration >= 0.20
	if CONFIG.Adaptive and not safe and not diagnosticOnly and painting and not selectionMode and remote then
		local badErrors = failures >= 2 and failures / math.max(1, returns + failures) >= 0.10
		local congestion = steady and busy and returns >= CONFIG.MinTuneReturns
			and latency > steady.latency * 1.5 and returnRate < steady.rate * 0.95
		if badErrors or congestion then
			window = math.max(mode.Min, math.floor(window * 0.6))
			probe, steady, tuneCooldown = nil, nil, 3
		elseif returns >= CONFIG.MinTuneReturns then
			if probe then
				local improved = probe.direction == 1 and returnRate >= probe.rate * 1.05 and latency <= probe.latency * 1.35
				local cheaper = probe.direction == -1 and returnRate >= probe.rate * 0.97 and latency <= probe.latency * 1.10
				if not (improved or cheaper) then
					window = math.max(mode.Min, probe.window)
					tuneCooldown = 3
					probeDirection = -probe.direction
				end
				probe = nil
			elseif tuneCooldown > 0 then tuneCooldown -= 1
			elseif busy and returnRate < mode.Rate * 0.90 then
				if window >= mode.Max then probeDirection = -1
				elseif window <= mode.Min then probeDirection = 1 end
				probe = { window = window, rate = returnRate, latency = latency, direction = probeDirection }
				window = math.clamp(window + probeDirection * math.max(1, math.ceil(window * 0.25)), mode.Min, mode.Max)
			end
			if busy and not probe then
				steady = { rate = returnRate, latency = latency }
			end
		end
	end
	for key in pairs(sample) do sample[key] = 0 end
	epoch = now
end

-- UI retains the original controls and shortcuts, without decorative animation loops.
local function make(class, parent, properties)
	local object = Instance.new(class)
	for key, value in pairs(properties) do object[key] = value end
	object.Parent = parent
	return object
end

ui = make("ScreenGui", playerGui, { Name = GUI_NAME, ResetOnSpawn = false,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling })
ui:SetAttribute("AutoPainterDiagnosticsVersion", 5)
main = make("Frame", ui, { Name = "Panel", AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.new(0.9, 0, 0.85, 0),
	BackgroundColor3 = Color3.fromRGB(33, 33, 42), BorderSizePixel = 0 })
make("UISizeConstraint", main, { MaxSize = Vector2.new(440, 520), MinSize = Vector2.new(240, 200) })
local top = make("TextLabel", main, { Text = "Paint Admin Panel · FINAL", TextSize = 20,
	Font = Enum.Font.SourceSansBold, TextColor3 = Color3.new(1, 1, 1),
	BackgroundColor3 = Color3.fromRGB(49, 49, 64), BorderSizePixel = 0,
	Size = UDim2.new(1, 0, 0, 36), Active = true })
local close = make("TextButton", top, { Text = "×", TextSize = 24, BackgroundTransparency = 1,
	TextColor3 = Color3.new(1, 1, 1), Position = UDim2.new(1, -36, 0, 0), Size = UDim2.fromOffset(36, 36) })
statusLabel = make("TextLabel", main, { Text = diagnosticOnly and "DIAGNOSTIC: no new requests" or "Ready", TextSize = 16, BackgroundTransparency = 1,
	TextColor3 = Color3.fromRGB(80, 255, 123), Position = UDim2.fromOffset(8, 39), Size = UDim2.new(1, -16, 0, 23) })
detailLabel = make("TextLabel", main, { Text = "Q: pause/resume · R: random color", TextSize = 13,
	BackgroundTransparency = 1, TextColor3 = Color3.fromRGB(195, 195, 210),
	Position = UDim2.fromOffset(8, 63), Size = UDim2.new(1, -16, 0, 22) })
local scroll = make("ScrollingFrame", main, { BackgroundTransparency = 1, BorderSizePixel = 0,
	Position = UDim2.fromOffset(8, 92), Size = UDim2.new(1, -16, 1, -100),
	AutomaticCanvasSize = Enum.AutomaticSize.Y, CanvasSize = UDim2.new(), ScrollBarThickness = 4 })
make("UIListLayout", scroll, { Padding = UDim.new(0, 7), SortOrder = Enum.SortOrder.LayoutOrder })
doneButton = make("TextButton", ui, { Text = "Done / Cancel", Visible = false,
	AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 8),
	Size = UDim2.fromOffset(230, 44), BackgroundColor3 = Color3.fromRGB(35, 145, 110),
	TextColor3 = Color3.new(1, 1, 1), TextSize = 20, BorderSizePixel = 0 })

local rowOrder = 0
local function option(label, action)
	rowOrder += 1
	local row = make("Frame", scroll, { Size = UDim2.new(1, -6, 0, 36), LayoutOrder = rowOrder,
		BackgroundColor3 = Color3.fromRGB(49, 49, 64), BorderSizePixel = 0 })
	make("TextLabel", row, { Text = label, BackgroundTransparency = 1, TextSize = 17,
		Font = Enum.Font.SourceSansBold, TextColor3 = Color3.new(1, 1, 1),
		TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.fromOffset(8, 0), Size = UDim2.new(1, -100, 1, 0) })
	return make("TextButton", row, { Text = action, TextSize = 16,
		BackgroundColor3 = Color3.fromRGB(85, 85, 100), BorderSizePixel = 0,
		TextColor3 = Color3.new(1, 1, 1), Position = UDim2.new(1, -82, 0, 4), Size = UDim2.fromOffset(76, 28) })
end

local function setSelectionMode(value)
	if not alive then return end
	local finishing = value == nil and (selectionMode ~= nil or pendingCount > 0)
	selectionMode = value
	main.Visible, doneButton.Visible = value == nil, value ~= nil
	if value then doneButton.Text = value .. " · Done / Cancel" end
	-- All selection tools suspend new dispatch without changing Toggle Paint.
	-- Switching tools keeps the transaction open. Done/Cancel/Escape finish it.
	if finishing then
		local now = os.clock()
		commitPending(now)
		if painting then evaluateAll(now) end
		resetSample(now)
	end
end

local function switch(button, enabled)
	button.Text = enabled and "ON" or "OFF"
	button.BackgroundColor3 = enabled and Color3.fromRGB(35, 145, 110) or Color3.fromRGB(170, 45, 80)
end

colorButton = option("Country Color", "Pick")
colorButton.BackgroundColor3 = color
connect(colorButton.Activated, function() setSelectionMode("Color") end)
connect(option("Protect Province", "Add").Activated, function() setSelectionMode("Add") end)
connect(option("Unprotect Province", "Remove").Activated, function() setSelectionMode("Remove") end)
connect(option("Clear Provinces", "Clear").Activated, clearProvinces)
local safeButton = option("Safe Mode", "OFF")
local paintButton = option("Toggle Paint  [Q]", "ON")
local fastButton = option("Fast Paint", "OFF")
local keepButton = option("Keep Territory Color", "OFF")
local randomButton = option("Randomize Color  [R]", "Change")
local diagnosticButton = option("Diagnostics · no requests", "ON")
local function reportAction(text)
	rowOrder += 1
	return make("TextButton", scroll, { Text = text, LayoutOrder = rowOrder,
		Size = UDim2.new(1, -6, 0, 36), TextSize = 17, Font = Enum.Font.SourceSansBold,
		BackgroundColor3 = Color3.fromRGB(60, 100, 125), TextColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0 })
end
local fullPathsButton = reportAction("Full Paint Paths Report")
local copyFullPathsButton = reportAction("Copy Full Paint Paths Report")
local protocolButton = reportAction("Protocol Extract")
local copyProtocolButton = reportAction("Copy Protocol Report")
rowOrder += 1
local exportStatus = make("TextLabel", scroll, { Name = "ProtocolExportStatus", Text = "", Visible = false,
	LayoutOrder = rowOrder, Size = UDim2.new(1, -6, 0, 32), AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundTransparency = 1, TextColor3 = Color3.fromRGB(195, 230, 210), TextSize = 14, TextWrapped = true })
local inspectButton = option("Full inventory (optional)", "Inspect")
local sourceButton = option("Full source (optional)", "Inspect source")
sourceButton.TextSize, sourceButton.TextWrapped = 12, true
local sourceInspectionBusy = false
local protocolReport, protocolExportBusy = nil, false
local reportNav = make("Frame", scroll, { Name = "DiagnosticPages", Visible = false,
	LayoutOrder = rowOrder + 1, Size = UDim2.new(1, -6, 0, 32), BackgroundTransparency = 1 })
local reportPrevious = make("TextButton", reportNav, { Text = "Prev", Size = UDim2.fromOffset(70, 28),
	BackgroundColor3 = Color3.fromRGB(85, 85, 100), TextColor3 = Color3.new(1, 1, 1), TextSize = 16 })
local reportNext = make("TextButton", reportNav, { Text = "Next", Position = UDim2.new(1, -70, 0, 0),
	Size = UDim2.fromOffset(70, 28), BackgroundColor3 = Color3.fromRGB(85, 85, 100),
	TextColor3 = Color3.new(1, 1, 1), TextSize = 16 })
local reportPageLabel = make("TextLabel", reportNav, { Name = "PageLabel", Text = "", BackgroundTransparency = 1,
	Position = UDim2.fromOffset(74, 0), Size = UDim2.new(1, -148, 1, 0),
	TextColor3 = Color3.new(1, 1, 1), TextSize = 14 })
local reportBox = make("TextBox", scroll, { Name = "DiagnosticReport", Text = "", Visible = false,
	LayoutOrder = rowOrder + 2, Size = UDim2.new(1, -6, 0, 120), AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundColor3 = Color3.fromRGB(25, 25, 32), TextColor3 = Color3.new(1, 1, 1),
	Font = Enum.Font.Code, TextSize = 13, TextWrapped = true, RichText = false,
	TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
	TextEditable = false, ClearTextOnFocus = false, MultiLine = true })
local reportText, reportPage, reportOffsets = "", 1, {}
local function displayReportPage()
	local first = reportOffsets[reportPage] or 1
	local last = reportOffsets[reportPage + 1] and reportOffsets[reportPage + 1] - 1 or #reportText
	reportBox.Text = string.sub(reportText, first, last)
	reportPageLabel.Text = string.format("Page %d/%d", reportPage, math.max(1, #reportOffsets))
	reportBox.Visible, reportNav.Visible = true, true
end
local function showReport(text)
	reportText, reportPage = text, 1
	table.clear(reportOffsets)
	local first = 1
	while first <= #text do
		table.insert(reportOffsets, first)
		local last = math.min(#text, first + CONFIG.DiagnosticPageCharacters - 1)
		local cursor = first
		for _ = 1, CONFIG.DiagnosticPageLines do
			local newline = string.find(text, "\n", cursor, true)
			if not newline or newline > last then break end
			cursor = newline + 1
		end
		if cursor > first then last = cursor - 1 end
		-- If a long line needs splitting, preserve complete UTF-8 code points.
		while last < #text and string.byte(text, last + 1) >= 128 and string.byte(text, last + 1) < 192 do last -= 1 end
		first = last + 1
	end
	displayReportPage()
end
switch(safeButton, safe); switch(paintButton, painting); switch(fastButton, fast); switch(keepButton, keepColor)
switch(diagnosticButton, diagnosticOnly)
if diagnosticLocked then diagnosticButton.Text = "LOCKED" end

function api.SetColor(value)
	if not alive then return end
	assert(typeof(value) == "Color3", "Expected Color3")
	color = value
	colorButton.BackgroundColor3 = value
	colorButton.TextColor3 = (value.R + value.G + value.B > 1.5) and Color3.new(0, 0, 0) or Color3.new(1, 1, 1)
	-- The supplied game sources do not expose the manual bucket's color contract.
	-- Do not guess at attributes/values or send a PaintPart just to change its color.
	if not keepColor then retargetAll() end
end
function api.GetColor() return color end
function api.SetPainting(value)
	if not alive then return end
	painting = value == true
	switch(paintButton, painting)
	tokens, tokenTime = math.min(tokens, 1), os.clock()
	resetSample(tokenTime)
	if painting and not selectionMode then evaluateAll(tokenTime) end
	kick()
end
function api.SetFast(value)
	if not alive then return end
	fast = value == true; switch(fastButton, fast); updateMode()
end
function api.SetSafe(value)
	if not alive then return end
	safe = value == true; switch(safeButton, safe); updateMode()
end
function api.SetKeepColor(value)
	if not alive then return end
	keepColor = value == true; switch(keepButton, keepColor); retargetAll()
end
function api.SetDiagnostic(value, lock)
	if not alive then return false end
	if lock == true then diagnosticLocked = true; value = true end
	if diagnosticLocked and value ~= true then return false end
	diagnosticOnly = value == true
	switch(diagnosticButton, diagnosticOnly)
	if diagnosticLocked then diagnosticButton.Text = "LOCKED" end
	-- Clear only unsent work. Sent calls remain counted until their real return.
	while readyHead do unqueue(readyHead) end
	while delayed[1] do unschedule(delayed[1]) end
	resetSample(os.clock())
	-- Leaving inspection never starts traffic as a side effect of this control.
	if not diagnosticOnly then api.SetPainting(false) end
	return true
end
api.AddProvince = addProvince
-- Programmatic additions obey the same transaction boundary as the UI.
function api.CommitSelections() setSelectionMode(nil) end
function api.RemoveProvince(part)
	if lookup[part] then removeEntry(lookup[part]) end
end
api.Clear = clearProvinces
function api.GetStats()
	local result = table.clone(stats)
	result.Selected, result.Ready, result.Delayed = #entries, readyCount, #delayed
	result.PendingSelections, result.CommittedSelections = pendingCount, #entries - pendingCount
	result.Painting, result.SelectionMode = painting, selectionMode
	result.DiagnosticOnly, result.DiagnosticLocked = diagnosticOnly, diagnosticLocked
	result.InFlight, result.Stalled, result.Window = outstanding, stalled, window
	result.MaxPerProvince = mode.MaxPerProvince
	result.RequestTokens = tokens
	local pendingProvinces = 0
	for _ in pairs(pendingByPart) do pendingProvinces += 1 end
	result.PendingProvinces = pendingProvinces
	result.RTT, result.RemoteReady, result.Running = rtt, remote ~= nil, alive
	return result
end

function api.GetDiagnosticReport()
	-- Explicit snapshot only: no polling tree scans, remote calls, script execution,
	-- source decompilation, property writes, hooks, or retained snapshot Instances.
	local lines, length, truncated = {}, 0, false
	local function clean(value)
		local text = tostring(value):gsub("[%c]", " ")
		local last = math.min(#text, 180)
		while last < #text and string.byte(text, last + 1) >= 128 and string.byte(text, last + 1) < 192 do last -= 1 end
		return string.sub(text, 1, last)
	end
	local function line(value)
		if length + #value + 1 > CONFIG.DiagnosticMaxText - 100 then truncated = true; return end
		table.insert(lines, value); length += #value + 1
	end
	local function path(object)
		if not object then return "<missing>" end
		local ok, name = pcall(function() return object:GetFullName() end)
		return ok and clean(name) or "<unavailable>"
	end
	local function sensitive(name)
		local lower = string.lower(name)
		for _, word in ipairs({ "token", "session", "nonce", "secret", "password", "cookie", "auth", "key" }) do
			if string.find(lower, word, 1, true) then return true end
		end
		return false
	end
	local function fullText(value)
		-- Escape controls without dropping any part of long names/paths.
		return (tostring(value):gsub("\\", "\\\\"):gsub("[%c]", function(character)
			return string.format("\\x%02X", string.byte(character))
		end))
	end
	local function fullPath(object)
		if not object then return "<missing>" end
		return object:GetFullName()
	end
	local function valueText(value, name)
		local kind = typeof(value)
		if sensitive(name or "") then return "<redacted " .. kind .. ">" end
		if kind == "Color3" then return string.format("Color3(%.5f, %.5f, %.5f)", value.R, value.G, value.B) end
		if kind == "boolean" or kind == "number" or kind == "EnumItem" then return clean(value) end
		if kind == "nil" then return "<nil>" end
		-- Unknown strings can be server-issued credentials; show presence/type, not contents.
		if kind == "string" then return "<string value omitted>" end
		if kind == "Instance" then return "<Instance " .. path(value) .. ">" end
		if kind == "Vector2" or kind == "Vector3" or kind == "CFrame" or kind == "BrickColor"
			or kind == "NumberRange" or kind == "UDim" or kind == "UDim2" then return clean(value) end
		return "<" .. kind .. ">"
	end
	local function descendantInventory(root, expectedRemote)
		-- Separate native enumeration: no summary queue, node/depth/attribute/text caps.
		local output = { "PAINTBUCKET DESCENDANTS", "ReportFormat=2" }
		local function emit(value) table.insert(output, value) end
		if not root then
			emit("Status=missing equipped PaintBucket; no enumeration performed")
			emit("END PAINTBUCKET DESCENDANTS")
			return table.concat(output, "\n")
		end
		emit("Root=" .. fullText(fullPath(root)))
		local ok, descendants = pcall(function() return root:GetDescendants() end)
		if not ok then
			emit("Status=enumeration unavailable; completeness cannot be established")
			emit("END PAINTBUCKET DESCENDANTS")
			return table.concat(output, "\n")
		end
		emit("SnapshotDescendants=" .. #descendants)
		local records, unreadable, remoteFound = {}, 0, false
		for _, object in ipairs(descendants) do
			local record, recordPath = {}, "<unavailable>"
			if object == expectedRemote then remoteFound = true end
			local readable = pcall(function()
				recordPath = fullPath(object)
				table.insert(record, "FullName=" .. fullText(recordPath))
				table.insert(record, "ClassName=" .. fullText(object.ClassName))
				table.insert(record, "Name=" .. fullText(object.Name))
				table.insert(record, "Parent FullName=" .. fullText(fullPath(object.Parent)))
				table.insert(record, "RemoteEvent=" .. tostring(object:IsA("RemoteEvent"))
					.. " RemoteFunction=" .. tostring(object:IsA("RemoteFunction")))
				if object:IsA("LocalScript") or object:IsA("Script") then
					local enabledOK, enabled = pcall(function() return object.Enabled end)
					table.insert(record, "Enabled=" .. (enabledOK and valueText(enabled, "Enabled") or "<unavailable>"))
					if not enabledOK then unreadable += 1 end
				end
				if object:IsA("ValueBase") then
					local valueOK, value = pcall(function() return object.Value end)
					table.insert(record, "ValueBaseType=" .. fullText(object.ClassName)
						.. " ValueType=" .. (valueOK and typeof(value) or "<unavailable>"))
					local text = valueOK and valueText(value, object.Name) or "<unavailable>"
					if valueOK and typeof(value) == "Instance" and not sensitive(object.Name) then
						text = "<Instance " .. fullText(fullPath(value)) .. ">"
					end
					table.insert(record, "Value=" .. text)
					if not valueOK then unreadable += 1 end
				end
				local attributesOK, values = pcall(function() return object:GetAttributes() end)
				if attributesOK then
					local names = {}
					for name in pairs(values) do table.insert(names, name) end
					table.sort(names)
					table.insert(record, "Attributes=" .. #names)
					for _, name in ipairs(names) do
						table.insert(record, "  @" .. fullText(name) .. " (" .. typeof(values[name]) .. ") = " .. valueText(values[name], name))
					end
				else
					table.insert(record, "Attributes=<unavailable>")
					unreadable += 1
				end
			end)
			if not readable then
				unreadable += 1
				table.insert(record, "ReadError=<metadata unavailable; descendant retained in count>")
			end
			table.insert(records, { path = recordPath, text = table.concat(record, "\n") })
		end
		table.sort(records, function(a, b)
			-- Duplicate full paths are possible; metadata provides a deterministic tie break.
			if a.path == b.path then return a.text < b.text end
			return a.path < b.path
		end)
		for index, record in ipairs(records) do emit("\n[" .. index .. "]\n" .. record.text) end
		emit(string.format("\nListed=%d Expected=%d UnreadableFields=%d", #records, #descendants, unreadable))
		emit("FreshRemoteInInventory=" .. (expectedRemote and tostring(remoteFound) or "not resolved"))
		emit("String/credential values remain redacted. No scripts were read, decompiled or executed.")
		emit("END PAINTBUCKET DESCENDANTS")
		return table.concat(output, "\n")
	end
	local function property(object, name)
		if not object then return "<missing>" end
		local ok, value = pcall(function() return object[name] end)
		return ok and valueText(value, name) or "<unavailable>"
	end
	local function attributes(object)
		local ok, values = pcall(function() return object:GetAttributes() end)
		if not ok then line("  attributes: <unavailable>"); return end
		local names, count = {}, 0
		for name in pairs(values) do
			count += 1
			if #names < CONFIG.DiagnosticMaxAttributes then table.insert(names, name) end
		end
		table.sort(names)
		for _, name in ipairs(names) do line("  @" .. clean(name) .. " = " .. valueText(values[name], name)) end
		if count > #names then line("  [more attributes omitted]") end
	end
	local function describe(object, label)
		if not object then line(label .. ": <missing>"); return end
		line(label .. ": " .. path(object) .. " [" .. clean(object.ClassName) .. "]")
		attributes(object)
		if object:IsA("Tool") then
			line("  Enabled=" .. property(object, "Enabled") .. " RequiresHandle=" .. property(object, "RequiresHandle")
				.. " ManualActivationOnly=" .. property(object, "ManualActivationOnly"))
			local handle = object:FindFirstChild("Handle")
			line("  Handle=" .. path(handle) .. " BasePart=" .. tostring(handle ~= nil and handle:IsA("BasePart")))
		elseif object:IsA("Humanoid") then
			line("  Health=" .. property(object, "Health") .. " Sit=" .. property(object, "Sit")
				.. " PlatformStand=" .. property(object, "PlatformStand"))
			local ok, state = pcall(function() return object:GetState() end)
			line("  Humanoid state=" .. (ok and clean(state) or "<unavailable>"))
		elseif object:IsA("ValueBase") then
			local ok, value = pcall(function() return object.Value end)
			line("  Value=" .. (ok and valueText(value, object.Name) or "<unavailable>"))
		elseif object:IsA("LocalScript") or object:IsA("Script") then
			line("  Enabled=" .. property(object, "Enabled") .. "; source not read/executed")
		elseif object:IsA("ModuleScript") then line("  Module not required/read") end
	end

	line("AUTOPAINTER LOCAL SNAPSHOT · normal tool protocol UNVERIFIED")
	line("Read-only snapshot; no network probe or test paint is performed.")
	line("DiagnosticOnly=" .. tostring(diagnosticOnly) .. " Locked=" .. tostring(diagnosticLocked)
		.. " PaintingToggle=" .. tostring(painting) .. " SelectionMode=" .. (selectionMode or "none"))
	line(string.format("Selected=%d Pending=%d Committed=%d Ready=%d Delayed=%d", #entries,
		pendingCount, #entries - pendingCount, readyCount, #delayed))
	line(string.format("Attempted=%d Returned=%d Errors=%d InFlight=%d Stalled=%d SuppressedBeforeSend=%d",
		stats.Attempted, stats.Returned, stats.Failures, outstanding, stalled, stats.Suppressed))
	line("Already-sent operations cannot be canceled by diagnostics. Other tool scripts are unchanged.")
	line("Selected global color=" .. valueText(color, "Color") .. " KeepTerritoryColor=" .. tostring(keepColor))
	line('Legacy payload only: InvokeServer("PaintPart", {Part = selected BasePart, Color = target Color3}, "Peace")')
	line('"Peace", argument contract, prerequisites and server acceptance are NOT verified.')
	local currentCharacter = player.Character
	local currentBucket = currentCharacter and currentCharacter:FindFirstChild("PaintBucket")
	local currentRemotes = currentBucket and currentBucket:FindFirstChild("Remotes")
	local currentRemote = currentRemotes and currentRemotes:FindFirstChild("ServerControls")
	local backpack = player:FindFirstChild("Backpack")
	local storedBucket = backpack and backpack:FindFirstChild("PaintBucket")
	local humanoid = currentCharacter and currentCharacter:FindFirstChildOfClass("Humanoid")
	local resolved = currentRemote ~= nil and currentRemote:IsA("RemoteFunction")
		and currentCharacter:IsDescendantOf(Workspace)
	line("Observed Character in Workspace=" .. tostring(currentCharacter ~= nil and currentCharacter:IsDescendantOf(Workspace)))
	line("Observed Tool parent is current Character=" .. tostring(currentBucket ~= nil
		and currentBucket:IsA("Tool") and currentBucket.Parent == currentCharacter))
	line("Remote path resolves=" .. tostring(resolved) .. "; this is not a server-readiness check")
	line("Fresh remote=" .. path(currentRemote) .. " Cached remote=" .. path(remote)
		.. " Same=" .. tostring(currentRemote ~= nil and currentRemote == remote)
		.. " CacheDirty=" .. tostring(cacheDirty) .. " Version=" .. tostring(cacheVersion))
	describe(currentCharacter, "Character summary")
	describe(humanoid, "Humanoid summary")

	-- Bounded breadth-first inventory of equipped/backpack tools only, not the world.
	local queue, seen = {}, {}
	local function append(object, label, depth)
		if not object or seen[object] then return end
		if #queue >= CONFIG.DiagnosticMaxNodes then truncated = true; return end
		seen[object] = true
		table.insert(queue, { object = object, label = label, depth = depth })
	end
	append(currentBucket, "Equipped hierarchy", 0)
	append(storedBucket, "Backpack hierarchy (not equipped)", 0)
	if not currentBucket then line("Equipped hierarchy: <missing>") end
	if not storedBucket then line("Backpack PaintBucket: <missing>") end
	local index = 1
	while index <= #queue and not (length >= CONFIG.DiagnosticMaxText - 200) do
		local item = queue[index]
		describe(item.object, item.label)
		local children = item.object:GetChildren()
		if item.depth < CONFIG.DiagnosticMaxDepth then
			for _, child in ipairs(children) do
				if #queue >= CONFIG.DiagnosticMaxNodes then truncated = true; break end
				append(child, "  child", item.depth + 1)
			end
		elseif #children > 0 then truncated = true end
		index += 1
	end
	if index <= #queue then truncated = true end
	line("Selected targets (bounded sample; saved color is selected color at add time):")
	for i = 1, math.min(#entries, CONFIG.DiagnosticMaxSelections) do
		local entry = entries[i]
		line(string.format("  %d %s committed=%s valid=%s", i, path(entry.part), tostring(entry.committed), tostring(valid(entry.part))))
		line("    current=" .. valueText(entry.part.Color, "Color") .. " target=" .. valueText(targetColor(entry), "Color")
			.. " saved=" .. valueText(entry.savedColor, "Color"))
	end
	if #entries > CONFIG.DiagnosticMaxSelections then line("  [more selected targets omitted]") end
	line("String/credential values omitted; metadata presence does not establish a protocol or permission.")
	if truncated then table.insert(lines, "[Summary truncated to configured bounds; full inventory follows]") end
	return table.concat(lines, "\n") .. "\n\n" .. descendantInventory(currentBucket, currentRemote)
end

local function buildSourceReport(compact)
	-- Optional environment capability only. Never read Source/closures, execute the
	-- returned text, require modules, invoke tool callbacks, or probe game remotes.
	local heading = compact and "PROTOCOL EXTRACT\nProtocolReportFormat=1\n"
		or "PAINTBUCKET LOCALSCRIPT SOURCE\nSourceReportFormat=1\n"
	if not alive then return heading .. "Status=unavailable; AutoPainter is closed" end
	if not diagnosticOnly or not diagnosticLocked then
		return heading .. "Status=refused; use LoaderDiagnostic.luau with diagnostics LOCKED ON"
	end
	if sourceInspectionBusy then return heading .. "Status=busy; one inspection is already running; no new work started" end
	sourceInspectionBusy = true
	local ok, report = pcall(function()
		local output = { heading .. "DiagnosticOnly=true Locked=true",
			"Scope=LocalPlayer Character/Backpack PaintBucket Tool descendants of class LocalScript only.",
			"Only the existing environment decompile function is called; target scripts/functions are never executed.",
			"Decompiler output is unverified text, not original source or proof of a working protocol.",
			"No live state/closures are extracted; source text stays local and is not uploaded." }
		local function emit(value) table.insert(output, value) end
		local function safeName(value)
			return (value:gsub("\\", "\\\\"):gsub("[%c]", function(c) return string.format("\\x%02X", string.byte(c)) end))
		end
		local function fullPath(object)
			local readable, name = pcall(function() return object:GetFullName() end)
			return readable and name or "<unavailable>"
		end
		local remoteSummary, flowSummary, contextBlocks = {}, {}, {}
		local blockCount, matchCount, callCount, flowCount = 0, 0, 0, 0
		local protocolTerms = { "ServerControls", "ClientControls", "InvokeServer", "InvokeClient",
			"FireServer", "FireClient", "PaintPart", "Peace", "Activated", "Equipped", "Unequipped",
			"Color", "BrickColor", "RemoteFunction", "RemoteEvent", "mode", "state", "cooldown" }
		local function extractProtocol(source, scriptPath)
			local lines, starts, hits, calls, spans = {}, {}, {}, {}, {}
			local first = 1
			while first <= #source do
				local newline = string.find(source, "\n", first, true)
				table.insert(starts, first)
				table.insert(lines, string.sub(source, first, newline and newline - 1 or #source))
				if not newline then break end
				first = newline + 1
			end
			for number, text in ipairs(lines) do
				local lower, labels = string.lower(text), {}
				for _, term in ipairs(protocolTerms) do
					if string.find(lower, string.lower(term), 1, true) then table.insert(labels, term) end
				end
				if #labels > 0 then hits[number] = labels end
			end
			local function sourceLine(position)
				local low, high = 1, #starts
				while low < high do
					local middle = math.ceil((low + high) / 2)
					if starts[middle] <= position then low = middle else high = middle - 1 end
				end
				return low
			end
			-- Textual call sites, including whitespace/newlines and multiple calls on a line.
			-- This never evaluates code or assumes a comment/string is an executed call.
			for _, method in ipairs({ "InvokeServer", "FireServer", "InvokeClient", "FireClient" }) do
				local cursor = 1
				while true do
					local position, last = string.find(source, ":%s*" .. method .. "%s*%(", cursor)
					if not position then break end
					local number = sourceLine(position)
					table.insert(calls, { position = position, number = number, method = method })
					if not hits[number] then hits[number] = { method .. " call" } end
					cursor = last + 1
				end
			end
			table.sort(calls, function(a, b) return a.position < b.position end)
			for number = 1, #lines do
				if hits[number] then
					matchCount += 1
					local from, to = math.max(1, number - CONFIG.ProtocolBefore), math.min(#lines, number + CONFIG.ProtocolAfter)
					local previous = spans[#spans]
					if previous and from <= previous.to + 1 then previous.to = math.max(previous.to, to)
					else table.insert(spans, { from = from, to = to }) end
				end
			end
			local blocksByHit = {}
			for _, span in ipairs(spans) do
				blockCount += 1
				local id = string.format("B%04d", blockCount)
				local output = { "\n[" .. id .. "] Script=" .. safeName(scriptPath),
					string.format("Lines=L%d-L%d", span.from, span.to) }
				for number = span.from, span.to do
					local labels = hits[number]
					if labels then blocksByHit[number] = id end
					table.insert(output, (labels and "* " or "  ") .. "L" .. number
						.. (labels and " [" .. table.concat(labels, ", ") .. "]" or "") .. " | " .. lines[number])
				end
				table.insert(contextBlocks, table.concat(output, "\n"))
			end
			if #calls > 0 then table.insert(remoteSummary, "\nScript=" .. safeName(scriptPath)) end
			for _, call in ipairs(calls) do
				callCount += 1
				table.insert(remoteSummary, string.format("L%d:C%d :%s( Context=%s | %s", call.number,
					call.position - starts[call.number] + 1, call.method, blocksByHit[call.number], lines[call.number]))
			end
			local flowHeader = false
			for number, text in ipairs(lines) do
				local lower = string.lower(text)
				if string.find(lower, "paintpart", 1, true) or string.find(lower, "servercontrols", 1, true)
					or string.find(lower, "clientcontrols", 1, true) then
					if not flowHeader then table.insert(flowSummary, "\nScript=" .. safeName(scriptPath)); flowHeader = true end
					flowCount += 1
					table.insert(flowSummary, "L" .. number .. " Context=" .. blocksByHit[number] .. " | " .. text)
				end
			end
		end
		local inspectSource = decompile -- Optional global; no guessed aliases or fallback mechanisms.
		local available = type(inspectSource) == "function"
		emit("decompile=" .. (available and "available (environment-provided; implementation not verified)" or "unavailable; no source can be inspected"))
		local roots, seenRoots, candidates, seenScripts = {}, {}, {}, {}
		local function collectRoots(container)
			if not container then return end
			for _, object in ipairs(container:GetChildren()) do
				if object.Name == "PaintBucket" and object:IsA("Tool") and not seenRoots[object] then
					seenRoots[object] = true; table.insert(roots, object)
				end
			end
		end
		collectRoots(player.Character)
		collectRoots(player:FindFirstChild("Backpack"))
		table.sort(roots, function(a, b) return fullPath(a) < fullPath(b) end)
		for _, root in ipairs(roots) do
			emit("Root=" .. safeName(fullPath(root)))
			local listed, descendants = pcall(function() return root:GetDescendants() end)
			if not listed then emit("RootStatus=GetDescendants failed; this root's scripts could not be enumerated")
			else
				for _, object in ipairs(descendants) do
					if object:IsA("LocalScript") and not seenScripts[object] then
						seenScripts[object] = true
						table.insert(candidates, { object = object, root = root, path = fullPath(object) })
					end
				end
			end
		end
		table.sort(candidates, function(a, b) return a.path < b.path end)
		emit("LocalScriptsFound=" .. #candidates)
		if #roots == 0 then emit("Status=no PaintBucket Tool in current Character or Backpack") end
		local searches = {
			{ "ServerControls", "servercontrols" }, { "ClientControls", "clientcontrols" },
			{ "InvokeServer", "invokeserver" }, { "FireServer", "fireserver" },
			{ "PaintPart", "paintpart" }, { "Peace", "peace" },
			{ "color", "color", "colour", "brickcolor" },
			{ "equip", "equipped", "unequipped" }, { "activate", "activated", "deactivated" },
			{ "tool/state", "tool", "state", "enabled", "humanoid", "parent" },
			{ "mode", "mode" }, { "client response", "onclientinvoke", "onclientevent", "return" },
			{ "timing", "cooldown", "debounce", "timestamp", "tick(", "os.clock", "wait(" },
			{ "session", "token", "session", "nonce" },
		}
		local function searchText(source)
			emit("TEXT SEARCH INDEX (1-based source lines; includes comments and unused code)")
			local first, lineNumber, hits = 1, 1, 0
			while first <= #source do
				local newline = string.find(source, "\n", first, true)
				local text = string.sub(source, first, newline and newline - 1 or #source)
				local lower, labels = string.lower(text), {}
				for _, search in ipairs(searches) do
					for i = 2, #search do
						if string.find(lower, search[i], 1, true) then table.insert(labels, search[1]); break end
					end
				end
				if #labels > 0 then
					hits += 1
					emit("L" .. lineNumber .. " [" .. table.concat(labels, ", ") .. "] " .. text)
				end
				if not newline then break end
				first, lineNumber = newline + 1, lineNumber + 1
			end
			emit("MatchingLines=" .. hits .. "; inspect full source for arguments, callback responses and preceding statements.")
			emit("Text matches alone cannot establish call order, runtime values, server acceptance or a return contract.")
		end
		local returned, failures, skipped = 0, 0, 0
		for index, candidate in ipairs(candidates) do
			emit("\n[LocalScript " .. index .. "]\nFullName=" .. safeName(candidate.path))
			if not alive then emit("Status=aborted; AutoPainter closed during inspection"); break end
			local root, object = candidate.root, candidate.object
			local currentCharacter, currentBackpack = player.Character, player:FindFirstChild("Backpack")
			local stillOwned = root.Name == "PaintBucket" and root:IsA("Tool")
				and ((currentCharacter ~= nil and root.Parent == currentCharacter)
					or (currentBackpack ~= nil and root.Parent == currentBackpack))
			if not stillOwned or not object:IsA("LocalScript") or not object:IsDescendantOf(root) then
				skipped += 1; emit("Status=skipped; script/tool left the current player's PaintBucket scope")
			elseif not available then
				skipped += 1; emit("Status=unavailable; decompile is not a function in this environment")
			else
				-- Serial protected reads: no spawned jobs, retry loop, or waiting backlog.
				local readOK, source = pcall(inspectSource, object)
				if not alive then emit("Status=aborted; AutoPainter closed while decompile was running"); break end
				if not readOK then
					failures += 1
					emit("Status=decompiler failed\nError=" .. (type(source) == "string" and utf8.len(source)
						and source or "<error is not readable UTF-8 text>"))
				elseif type(source) ~= "string" or #source == 0 or not utf8.len(source) then
					failures += 1; emit("Status=decompiler failed; expected nonempty UTF-8 source text; returned type=" .. type(source))
				else
					returned += 1
					emit("Status=text returned; decompiler accuracy/completeness unverified\nSourceBytes=" .. #source)
					emit("CurrentFullName=" .. safeName(fullPath(object)))
					if compact then extractProtocol(source, candidate.path)
					else
						emit("BEGIN DECOMPILED SOURCE\n" .. source .. "\nEND DECOMPILED SOURCE")
						searchText(source)
					end
				end
			end
		end
		emit(string.format("\nTextReturned=%d Failures=%d Skipped=%d", returned, failures, skipped))
		if compact then
			emit(string.format("MatchLines=%d CallSites=%d FlowLines=%d MergedBlocks=%d", matchCount, callCount, flowCount, blockCount))
			emit("\nREMOTE CALL SUMMARY")
			emit(#remoteSummary > 0 and table.concat(remoteSummary, "\n") or "No matching colon-call text found.")
			emit("\nPAINTPART FLOW")
			emit(#flowSummary > 0 and table.concat(flowSummary, "\n") or "No PaintPart/ServerControls/ClientControls text found.")
			emit("\nMERGED CONTEXT BLOCKS")
			emit(string.format("Context=8 lines before / 12 after by default; current=%d/%d. Overlapping/adjacent windows merge per script.", CONFIG.ProtocolBefore, CONFIG.ProtocolAfter))
			emit("Summary Context=Bxxxx references the surrounding code printed once below. * marks matching lines.")
			emit("Text matches can occur in comments/strings or unused code; they do not prove execution order or server acceptance.")
			emit(#contextBlocks > 0 and table.concat(contextBlocks, "\n") or "No matching context blocks.")
			emit("END PROTOCOL EXTRACT")
		else emit("END PAINTBUCKET LOCALSCRIPT SOURCE") end
		return table.concat(output, "\n")
	end)
	sourceInspectionBusy = false
	if not ok then return heading .. "Status=inspection failed; diagnostic lock remains enabled; retry inspection", true end
	return report, true
end

function api.GetLocalScriptReport()
	local report = buildSourceReport(false)
	return report
end

function api.GetProtocolReport()
	if alive and diagnosticOnly and diagnosticLocked and not sourceInspectionBusy then protocolReport = nil end
	local report, completed = buildSourceReport(true)
	if completed and alive then protocolReport = report end
	return report
end

function api.CopyProtocolReport()
	if not alive then return false, "AutoPainter is closed." end
	if not diagnosticOnly or not diagnosticLocked then return false, "Use the LOCKED diagnostic loader." end
	if protocolExportBusy or sourceInspectionBusy then return false, "Inspection/export is busy; no new work started." end
	protocolExportBusy = true
	local ok, exported, message = pcall(function()
		if not protocolReport then api.GetProtocolReport() end
		if not alive or not protocolReport then return false, "No completed protocol report to export." end
		local snapshot = protocolReport -- Export the entire compact snapshot, never the current page/raw report.
		if type(setclipboard) == "function" then
			local copied = pcall(setclipboard, snapshot)
			if copied then return true, "Copied complete Protocol Report to clipboard." end
		end
		if not alive then return false, "AutoPainter closed before file export; no fallback write started." end
		if type(writefile) == "function" then
			local saved = pcall(writefile, "AutoPainterProtocolReport.txt", snapshot)
			if saved then return true, "Saved AutoPainterProtocolReport.txt in the client environment's file area." end
		end
		return false, "Clipboard/file export unavailable or failed. Protocol Report remains available in pages."
	end)
	protocolExportBusy = false
	if not ok then return false, "Protocol export failed; the diagnostic lock remains enabled." end
	return exported, message
end

-- Comprehensive diagnostics are isolated from the unchanged paint scheduler.
local fullPaintPathsReport = nil
function api.GetFullPaintPathsReport()
	local heading = "CLIENT_PAINT_PATHS_FULL_REPORT\nFullPaintPathsReportFormat=1\n"
	if not alive then return heading .. "Status=closed" end
	if not diagnosticOnly or not diagnosticLocked then return heading .. "Status=refused; diagnostics must be LOCKED" end
	if sourceInspectionBusy then return heading .. "Status=busy; no extra inspection started" end
	sourceInspectionBusy, fullPaintPathsReport = true, nil
	local ok, result = pcall(function()
		local manifest, gaps, rootLog, candidates, seen, roots = {}, {}, {}, {}, {}, {}
		local sections, blocks = {}, {}
		for i = 1, 7 do sections[i] = {} end
		local excludedScripts = 0
		local counts = { returned = 0, failed = 0, skipped = 0, bytes = 0, calls = 0, paint = 0, blocks = 0 }
		local inspectSource = decompile -- Optional existing capability; never require/execute a target.
		local available = type(inspectSource) == "function"
		local lastYield = os.clock()
		local function checkpoint()
			if not alive then return false end
			if os.clock() - lastYield >= 0.012 then task.wait(); lastYield = os.clock() end
			return alive
		end
		local function clean(value)
			return (tostring(value):gsub("\\", "\\\\"):gsub("[%c]", function(c) return string.format("\\x%02X", string.byte(c)) end))
		end
		local function nameOf(object)
			local readable, value = pcall(function() return object:GetFullName() end)
			return readable and clean(value) or "<FullName unreadable>"
		end
		local function gap(text) table.insert(gaps, text) end
		local function childOf(parent, name, label)
			local readable, object = pcall(function() return parent and parent:FindFirstChild(name) end)
			if not readable or not object then gap(label .. (readable and ": absent/not replicated" or ": lookup failed")) end
			return readable and object or nil
		end
		local rootsSeen = {}
		local function root(object, label, current)
			if not object or rootsSeen[object] then return end
			rootsSeen[object] = true
			table.insert(roots, { object = object, label = label, current = current })
		end
		for _, name in ipairs({ "PlayerScripts", "PlayerGui", "Backpack" }) do
			local object = childOf(player, name, "LocalPlayer." .. name)
			root(object, "LocalPlayer." .. name, function() return player:FindFirstChild(name) == object end)
		end
		local currentCharacter = player.Character
		if not currentCharacter then gap("LocalPlayer.Character: absent at snapshot") end
		root(currentCharacter, "LocalPlayer.Character", function() return player.Character == currentCharacter end)
		-- Includes additional local-player controllers without inspecting other players' private containers.
		root(player, "LocalPlayer (all visible descendants)", function() return Players.LocalPlayer == player end)
		for _, name in ipairs({ "ReplicatedStorage", "ReplicatedFirst", "StarterPlayer", "StarterGui", "StarterPack", "Workspace" }) do
			local object = childOf(game, name, name)
			root(object, name, function() return game:FindFirstChild(name) == object end)
			if name == "StarterPlayer" then childOf(object, "StarterPlayerScripts", "StarterPlayer.StarterPlayerScripts") end
		end
		local excluded = { Players = true, CoreGui = true, ServerScriptService = true, ServerStorage = true }
		local listed, topLevel = pcall(function() return game:GetChildren() end)
		if not listed then gap("Additional DataModel roots: GetChildren failed; discovery incomplete")
		else
			for _, object in ipairs(topLevel) do
				local rootName = object.Name
				if not excluded[rootName] then
					root(object, "Additional client-visible root: " .. clean(rootName), function() return game:FindFirstChild(rootName) == object end)
				end
			end
		end
		table.sort(roots, function(a, b) return a.label < b.label end)
		for _, item in ipairs(roots) do
			if not checkpoint() then gap("Closed during root enumeration; remaining roots not enumerated"); break end
			local readable, objects = pcall(function() return item.object:GetDescendants() end)
			if not readable then gap(item.label .. ": GetDescendants failed"); table.insert(rootLog, item.label .. " | ENUMERATION FAILED")
			else
				local found, visited = 0, 0
				for _, object in ipairs(objects) do
					visited += 1
					local metadataOK, class = pcall(function() return object.ClassName end)
					if not metadataOK then gap(item.label .. ": unreadable descendant ClassName")
					elseif class == "Script" then
						excludedScripts += 1
					elseif class == "LocalScript" or class == "ModuleScript" then
						found += 1
						if not seen[object] then
							seen[object] = true
							local path = nameOf(object)
							if path == "<FullName unreadable>" then gap(item.label .. ": script FullName unreadable") end
							table.insert(candidates, { object = object, path = path, class = class, order = #candidates + 1 })
						end
					end
					if not checkpoint() then break end
				end
				if visited < #objects then gap(item.label .. ": enumeration processing interrupted") end
				table.insert(rootLog, item.label .. " | Descendants=" .. #objects .. " Visited=" .. visited .. " ScriptsSeen=" .. found)
			end
		end
		table.sort(candidates, function(a, b)
			if a.path ~= b.path then return a.path < b.path end
			if a.class ~= b.class then return a.class < b.class end
			return a.order < b.order
		end)
		local function inScope(object)
			for _, item in ipairs(roots) do
				local readable, eligible = pcall(function() return item.current() and object:IsDescendantOf(item.object) end)
				if readable and eligible then return true end
			end
			return false
		end
		local terms = { "PaintPart", "ServerControls", "ClientControls", "InvokeServer", "FireServer", "InvokeClient", "FireClient", "FireAllClients",
			"Province", "Provinces", "PaintBucket", "PaintBucketColor", "Peace", "War", "IsBannable", "RemotesReady",
			"admin", "developer", "private server", "test mode", "batch", "multi", "ownership", "capture", "paint", "color" }
		local categoryTerms = {
			[3] = { "province", "ownership", "capture", "paint", "color", "colour", "brickcolor", "setattribute" },
			[4] = { "admin", "developer", "privateserver", "private server", "isstudio", "testmode", "test mode", "vipserver" },
			[5] = { "batch", "multi", "targets", "parts", "ipairs", "pairs" },
			[6] = { "part", "target", "selected", "stored", "mouse", "instance" },
			[7] = { "permission", "capability", "token", "nonce", "session", "isbannable", "remotesready", "getattribute", "onclientinvoke", "onclientevent" },
		}
		for i, term in ipairs(terms) do terms[i] = string.lower(term) end
		local methodTerms = { "invokeserver", "fireserver", "invokeclient", "fireclient", "fireallclients" }
		local function any(lower, list)
			for _, term in ipairs(list) do if string.find(lower, term, 1, true) then return true end end
			return false
		end
		local function extract(source, id, path)
			local lines, starts, hits, refs, spans, calls = {}, {}, {}, {}, {}, {}
			local first = 1
			while first <= #source do
				local newline = string.find(source, "\n", first, true)
				table.insert(starts, first)
				table.insert(lines, string.sub(source, first, newline and newline - 1 or #source))
				if not newline then break end
				first = newline + 1
				if not checkpoint() then return nil end
			end
			local function lineAt(position)
				local low, high = 1, #starts
				while low < high do
					local middle = math.ceil((low + high) / 2)
					if starts[middle] <= position then low = middle else high = middle - 1 end
				end
				return low
			end
			for number, line in ipairs(lines) do
				local lower = string.lower(line)
				local categories = {}
				if any(lower, methodTerms) then categories[1] = true end
				if string.find(lower, "paintpart", 1, true) then categories[2] = true end
				for section, words in pairs(categoryTerms) do if any(lower, words) then categories[section] = true end end
				if any(lower, terms) or next(categories) then hits[number] = categories end
				if not checkpoint() then return nil end
			end
			-- Keep all remote-shaped call text, including unrelated/aliased receivers, rather than
			-- assuming names identify the paint remote. Dot, colon, and literal-index syntax.
			local callPositions = {}
			for _, method in ipairs({ "InvokeServer", "FireServer", "InvokeClient", "FireClient", "FireAllClients" }) do
				for _, pattern in ipairs({ "[:%.]%s*" .. method .. "%s*%(", "%[%s*['\"]" .. method .. "['\"]%s*%]%s*%(" }) do
					local cursor = 1
					while true do
						local position, last = string.find(source, pattern, cursor)
						if not position then break end
						if not callPositions[position] then
							callPositions[position] = true
							local number, lastLine = lineAt(position), lineAt(last)
							table.insert(calls, { position = position, line = number, method = method })
							for n = number, lastLine do hits[n] = hits[n] or {} end
						end
						cursor = last + 1
						if not checkpoint() then return nil end
					end
				end
			end
			table.sort(calls, function(a, b) return a.position < b.position end)
			for number = 1, #lines do
				if hits[number] then
					local from, to = math.max(1, number - CONFIG.ProtocolBefore), math.min(#lines, number + CONFIG.ProtocolAfter)
					local previous = spans[#spans]
					if previous and from <= previous.to + 1 then previous.to = math.max(previous.to, to)
					else table.insert(spans, { from = from, to = to }) end
				end
				if not checkpoint() then return nil end
			end
			for _, span in ipairs(spans) do
				counts.blocks += 1
				local blockId = string.format("F%05d", counts.blocks)
				local output = { "[" .. blockId .. "] " .. id .. " FullName=" .. path,
					string.format("Lines=L%d-L%d", span.from, span.to) }
				for number = span.from, span.to do
					if hits[number] then refs[number] = blockId end
					table.insert(output, (hits[number] and "* " or "  ") .. "L" .. number .. " | " .. lines[number])
					if not checkpoint() then return nil end
				end
				table.insert(blocks, table.concat(output, "\n"))
			end
			local directCallLines = {}
			for _, call in ipairs(calls) do
				directCallLines[call.line] = true
				table.insert(sections[1], string.format("%s L%d:C%d %s Context=%s", id, call.line,
					call.position - starts[call.line] + 1, call.method, refs[call.line]))
			end
			for number = 1, #lines do
				if hits[number] and hits[number][1] and not directCallLines[number] then
					table.insert(sections[1], id .. " L" .. number .. " METHOD REFERENCE / alias candidate Context=" .. refs[number])
				end
			end
			-- PaintPart indexes every literal occurrence, including two occurrences on one line.
			local cursor, paintCount, lowerSource = 1, 0, string.lower(source)
			while true do
				local at, last = string.find(lowerSource, "paintpart", cursor, true)
				if not at then break end
				local number = lineAt(at)
				paintCount += 1
				table.insert(sections[2], string.format("%s L%d:C%d Context=%s", id, number, at - starts[number] + 1, refs[number]))
				cursor = last + 1
				if not checkpoint() then return nil end
			end
			-- Category indexes reference the same blocks once each: compact, conservative candidates.
			for section = 3, 7 do
				local categoryBlocks = {}
				for number = 1, #lines do
					if hits[number] and hits[number][section] and not categoryBlocks[refs[number]] then
						categoryBlocks[refs[number]] = true
						table.insert(sections[section], id .. " Context=" .. refs[number])
					end
				end
			end
			return #calls, paintCount
		end
		for index, candidate in ipairs(candidates) do
			local id = string.format("S%05d", index)
			local entry = id .. " FullName=" .. candidate.path .. " ClassName=" .. candidate.class
			local status, bytes, callCount, paintCount = "", "unavailable", 0, 0
			if not checkpoint() then status = "NOT_READ: closed"; counts.skipped += 1
			elseif not inScope(candidate.object) then status = "NOT_READ: left visible scope"; counts.skipped += 1
			elseif not available then status = "NOT_READ: decompile unavailable"; counts.skipped += 1
			else
				local readPath = nameOf(candidate.object)
				local readOK, source = pcall(inspectSource, candidate.object)
				if not readOK then
					status = "FAILED: decompiler threw"
					if type(source) == "string" and utf8.len(source) then status ..= " | " .. clean(source) end
					counts.failed += 1
				elseif type(source) ~= "string" or #source == 0 or not utf8.len(source) then
					status = "FAILED: nonempty UTF-8 text not returned"; counts.failed += 1
				elseif not alive or not inScope(candidate.object) or readPath ~= nameOf(candidate.object) then
					status = "NOT_READ: closed or scope/path changed during decompile; text discarded"; counts.skipped += 1
				else
					bytes = #source
					callCount, paintCount = extract(source, id, readPath)
					if not callCount then status = "NOT_READ: extraction interrupted"; counts.skipped += 1
					else
						status = "TEXT_RETURNED_UNVERIFIED"
						counts.returned += 1; counts.bytes += bytes; counts.calls += callCount; counts.paint += paintCount
						if readPath ~= candidate.path then entry ..= " SourceFullName=" .. readPath end
					end
				end
			end
			if status ~= "TEXT_RETURNED_UNVERIFIED" then gap(id .. " " .. candidate.path .. " | " .. status) end
			table.insert(manifest, entry .. " Status=" .. status .. " SourceBytes=" .. tostring(bytes)
				.. " RemoteCallText=" .. tostring(callCount or 0) .. " PaintPartOccurrences=" .. tostring(paintCount or 0))
			candidate.object = nil -- Do not retain Instances in the completed report/cache.
		end
		local output = { heading .. "DiagnosticOnly=true Locked=true AutoPainterRequestsEnabled=false",
			"Static text inspection only. No remotes, script execution, module require, hooks, state writes or automatic export.",
			"decompile=" .. (available and "available; environment implementation unverified" or "UNAVAILABLE"),
			"All categories are CANDIDATES, not confirmed supported routes. Comments/strings/dead code can match.",
			"FireClient/InvokeClient/FireAllClients text may belong to server branches of shared modules; it is not an ordinary client capability.",
			"All remote-shaped calls are retained, even when paint relevance is unknown. Dynamic method names/wrappers need manual tracing.",
			"Coverage is a client-visible snapshot, not the entire server/game. No source/count limit silently truncates this report.",
			"Excluded: CoreGui engine internals, other players' Players containers, server-only containers, and Script class (including RunContext Client).",
			"Excluded Script-class observations across overlapping roots=" .. excludedScripts,
			"Workspace includes visible tools/controllers regardless of name. Additional DataModel roots are enumerated when readable.",
			"SCRIPT/MODULE MANIFEST (IDs disambiguate identical full paths)", table.concat(manifest, "\n") }
		local headings = { "1. ALL PAINT/PROVINCE REMOTE CALLS", "2. ALL PaintPart CALL SITES",
			"3. ALL ALTERNATE PROVINCE-MODIFICATION PATHS", "4. ADMIN / PRIVATE / TEST PATHS",
			"5. BATCH / MULTI-TARGET PATHS", "6. STORED-INSTANCE TARGETING PATHS", "7. PERMISSION / CAPABILITY / TOKEN STATE" }
		for i, title in ipairs(headings) do
			table.insert(output, "\n" .. title)
			table.insert(output, #sections[i] > 0 and table.concat(sections[i], "\n") or "No matching text in returned source; not proof of absence.")
		end
		table.insert(output, "\n8. READ FAILURES / COVERAGE GAPS")
		table.insert(output, table.concat(rootLog, "\n"))
		local summary = string.format("EnumeratedUnique=%d TextReturned=%d ReadFailures=%d NotRead=%d SourceBytes=%d RemoteCallText=%d PaintPartOccurrences=%d CoverageGaps=%d",
			#candidates, counts.returned, counts.failed, counts.skipped, counts.bytes, counts.calls, counts.paint, #gaps)
		table.insert(output, summary)
		table.insert(output, #gaps > 0 and table.concat(gaps, "\n") or "No enumeration/read failures recorded for the listed snapshot roots.")
		table.insert(output, "Decompiler text accuracy/completeness cannot be certified, including returned error-comment text. Late replication, removed/unparented scripts and server-only logic are outside this snapshot.")
		table.insert(output, "\n9. FINAL SUPPORTED CLIENT ROUTES")
		table.insert(output, "A stored/off-cursor route: UNRESOLVED. Inspect sections 1/2/3/6 and trace target aliases to their source.")
		table.insert(output, "B batch/multi-target route: UNRESOLVED. Loops and multiple names do not establish a server batch contract.")
		table.insert(output, "C private/admin/test route: UNRESOLVED. A shipped branch/flag does not prove ordinary-player permission.")
		table.insert(output, "D alternate painting remote: UNRESOLVED. Trace receiver discovery, wrappers, arguments and return state in the shared context.")
		table.insert(output, "E coverage: " .. summary)
		table.insert(output, "No route is automatically certified or ruled out by keyword matching. Server validation/acceptance remains untested; diagnostics remain LOCKED.")
		table.insert(output, "\nSHARED MERGED CONTEXT BLOCKS\n8 lines before / 12 after; overlapping and adjacent windows merge per script. * marks search hits. Source is printed once; category indexes reference Fxxxxx.")
		table.insert(output, table.concat(blocks, "\n\n"))
		table.insert(output, "END CLIENT_PAINT_PATHS_FULL_REPORT")
		return table.concat(output, "\n")
	end)
	sourceInspectionBusy = false
	if not ok then return heading .. "Status=inspection failed internally; coverage incomplete; no report cached; diagnostics remain LOCKED" end
	if alive then fullPaintPathsReport = result end
	return result
end

function api.CopyFullPaintPathsReport()
	if not alive then return false, "AutoPainter is closed." end
	if not diagnosticOnly or not diagnosticLocked then return false, "Use the LOCKED diagnostic loader." end
	if sourceInspectionBusy or protocolExportBusy then return false, "Inspection/export is busy; no extra work started." end
	protocolExportBusy = true
	local ok, exported, message = pcall(function()
		if not fullPaintPathsReport then api.GetFullPaintPathsReport() end
		if not alive or not fullPaintPathsReport then return false, "No completed full report to export." end
		local snapshot = fullPaintPathsReport
		if type(setclipboard) == "function" and pcall(setclipboard, snapshot) then return true, "Copied complete Full Paint Paths Report." end
		if not alive then return false, "AutoPainter closed; no fallback write started." end
		if type(writefile) == "function" and pcall(writefile, "CLIENT_PAINT_PATHS_FULL_REPORT.txt", snapshot) then
			return true, "Saved CLIENT_PAINT_PATHS_FULL_REPORT.txt in the client environment's file area."
		end
		return false, "Clipboard/file export unavailable or failed. Full report remains available in pages."
	end)
	protocolExportBusy = false
	if not ok then return false, "Full report export failed; diagnostics remain LOCKED." end
	return exported, message
end

function api.Destroy(fromDestroying)
	if not alive then return end
	alive = false
	selectionMode = nil
	reportText = ""
	protocolReport = nil
	fullPaintPathsReport = nil
	table.clear(reportOffsets)
	disconnectAll(connections)
	disconnectAll(cacheConnections)
	clearProvinces()
	remote, resolvedRemote, character, bucket, remotes = nil, nil, nil, nil, nil
	if fromDestroying ~= true then ui:Destroy() end
end

local function randomize()
	api.SetColor(Color3.fromRGB(math.random(0, 255), math.random(0, 255), math.random(0, 255)))
end
connect(safeButton.Activated, function() api.SetSafe(not safe) end)
connect(paintButton.Activated, function() api.SetPainting(not painting) end)
connect(fastButton.Activated, function() api.SetFast(not fast) end)
connect(keepButton.Activated, function() api.SetKeepColor(not keepColor) end)
connect(randomButton.Activated, randomize)
connect(diagnosticButton.Activated, function() api.SetDiagnostic(not diagnosticOnly) end)
connect(inspectButton.Activated, function()
	showReport(api.GetDiagnosticReport())
end)
connect(protocolButton.Activated, function()
	if sourceInspectionBusy or not alive then return end
	exportStatus.Text, exportStatus.Visible = "Preparing compact Protocol Report...", true
	local report = api.GetProtocolReport()
	if alive then
		showReport(report)
		exportStatus.Text = "Report ready. Copy Protocol Report exports all pages."
	end
end)
connect(copyProtocolButton.Activated, function()
	if sourceInspectionBusy or protocolExportBusy or not alive then return end
	exportStatus.Text, exportStatus.Visible = "Preparing Protocol Report export...", true
	local _, message = api.CopyProtocolReport()
	if alive then
		if protocolReport then showReport(protocolReport) end
		exportStatus.Text, exportStatus.Visible = message, true
	end
end)
connect(fullPathsButton.Activated, function()
	if sourceInspectionBusy or not alive then return end
	exportStatus.Text, exportStatus.Visible = "Inspecting client scripts/modules (read-only)...", true
	local report = api.GetFullPaintPathsReport()
	if alive then showReport(report); exportStatus.Text = "Full report ready. Copy Full Paint Paths Report exports all pages." end
end)
connect(copyFullPathsButton.Activated, function()
	if sourceInspectionBusy or protocolExportBusy or not alive then return end
	exportStatus.Text, exportStatus.Visible = "Preparing Full Paint Paths Report export...", true
	local _, message = api.CopyFullPaintPathsReport()
	if alive then
		if fullPaintPathsReport then showReport(fullPaintPathsReport) end
		exportStatus.Text, exportStatus.Visible = message, true
	end
end)
connect(sourceButton.Activated, function()
	if sourceInspectionBusy or not alive then return end
	local report = api.GetLocalScriptReport()
	if alive then showReport(report) end
end)
connect(reportPrevious.Activated, function()
	if reportPage > 1 then reportPage -= 1; displayReportPage() end
end)
connect(reportNext.Activated, function()
	if reportPage < #reportOffsets then reportPage += 1; displayReportPage() end
end)
connect(doneButton.Activated, function() setSelectionMode(nil) end)
connect(close.Activated, api.Destroy)

local function selectPart(part)
	if not part or not valid(part) then return end
	if selectionMode == "Color" then api.SetColor(part.Color)
	elseif selectionMode == "Add" then addProvince(part)
	elseif selectionMode == "Remove" then api.RemoveProvince(part) end
end
local mouse = player:GetMouse()
connect(Input.InputBegan, function(input, processed)
	-- Escape finishes this local selection even if CoreGui also handles that key.
	if input.KeyCode == Enum.KeyCode.Escape and selectionMode then setSelectionMode(nil); return end
	if processed or Input:GetFocusedTextBox() then return end
	if input.KeyCode == Enum.KeyCode.R then randomize()
	elseif input.KeyCode == Enum.KeyCode.Q then api.SetPainting(not painting)
	elseif input.KeyCode == Enum.KeyCode.Escape then setSelectionMode(nil)
	elseif input.UserInputType == Enum.UserInputType.MouseButton1 and selectionMode then selectPart(mouse.Target) end
end)
connect(Input.TouchTapInWorld, function(position, processed)
	if processed or not selectionMode then return end
	local camera = Workspace.CurrentCamera
	if not camera then return end
	local ray = camera:ViewportPointToRay(position.X, position.Y)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = player.Character and { player.Character } or {}
	local hit = Workspace:Raycast(ray.Origin, ray.Direction * 10000, params)
	if hit then selectPart(hit.Instance) end
end)

local dragInput, dragStart, dragPosition
connect(top.InputBegan, function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		dragInput, dragStart, dragPosition = input, input.Position, main.Position
	end
end)
connect(Input.InputChanged, function(input)
	if dragInput and (input == dragInput or (dragInput.UserInputType == Enum.UserInputType.MouseButton1
		and input.UserInputType == Enum.UserInputType.MouseMovement)) then
		local delta = input.Position - dragStart
		main.Position = UDim2.new(dragPosition.X.Scale, dragPosition.X.Offset + delta.X,
			dragPosition.Y.Scale, dragPosition.Y.Offset + delta.Y)
	end
end)
connect(Input.InputEnded, function(input) if input == dragInput then dragInput = nil end end)
connect(ui.Destroying, function() api.Destroy(true) end)
connect(ui.AncestryChanged, function() if not ui:IsDescendantOf(playerGui) then api.Destroy() end end)
local bridge = make("BindableFunction", ui, { Name = "Controller" })
bridge.OnInvoke = function() return api end -- Reload must not commit an open selection.

connect(player:GetPropertyChangedSignal("Character"), invalidateCache)
-- This signal survives destruction of a part/tool and its own deferred signals.
connect(Workspace.DescendantRemoving, function(object)
	local entry = lookup[object]
	if entry then task.defer(evaluate, entry, os.clock()) end
	if object == character or object == bucket or object == remotes or object == resolvedRemote then invalidateCache() end
end)
refreshCache()
connect(RunService.Heartbeat, function(dt)
	if not alive then return end
	if not ui:IsDescendantOf(playerGui) then api.Destroy(); return end
	local now = os.clock()
	frameBudget = mode.Batch
	-- Only due retries are visited. Idle/correct provinces receive no frame work.
	while delayed[1] and delayed[1].due <= now do
		local entry = delayed[1]
		unschedule(entry)
		evaluate(entry, now)
	end
	if now - lastWatchdog >= CONFIG.WatchdogInterval then
		lastWatchdog = now
		-- Fallback only while missing, including an object renamed into the expected path.
		if not remote and not cacheDirty then invalidateCache() end
		for job in pairs(jobs) do
			if not job.stalled and now - job.started >= CONFIG.StallSeconds then
				job.stalled = true
				stalled += 1
				stats.Stalls += 1
			end
		end
	end
	if painting and not diagnosticOnly and not selectionMode and remote and readyHead and outstanding - stalled >= window then sample.BusyTime += dt end
	tune(now)
	kick()
	if now - lastDisplay >= CONFIG.TelemetryInterval then
		local elapsed = now - lastDisplay
		local observedRate, returnRate = (stats.Observed - lastObserved) / elapsed, (stats.Returned - lastReturned) / elapsed
		local state = diagnosticOnly and "DIAGNOSTIC: no new requests"
			or (selectionMode and "Selecting (dispatch paused)" or (not painting and "Paused"
			or (not remote and "Equip PaintBucket" or (safe and "Safe" or (fast and "Fast" or "Normal")))))
		statusLabel.Text = string.format("%.1f returns/s · %d selected · %s", returnRate, #entries, state)
		detailLabel.Text = string.format("%.1f target matches/s · %d/%d active · %d stalled · %d errors", observedRate,
			outstanding - stalled, window, stalled, stats.Failures)
		lastDisplay, lastObserved, lastReturned = now, stats.Observed, stats.Returned
	end
end)
api.SetColor(color)
if diagnosticOnly then
	showReport("PROTOCOL EXTRACT\nUse Full Paint Paths Report to inspect client-visible LocalScripts/modules, then Copy Full Paint Paths Report. Protocol Extract remains available for PaintBucket-only context.\n"
		.. "Diagnostics must remain LOCKED. Full inventory and raw source are optional separate actions. No inspection runs automatically.")
end
return api
