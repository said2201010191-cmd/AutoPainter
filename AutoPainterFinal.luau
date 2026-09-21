-- AutoPainterFinal: client-only successor to AutoPainterFastClient.luau.
-- Existing protocol: ServerControls:InvokeServer("PaintPart", {Part, Color}, "Peace").
-- Run through the public client loader; no place access or installation required.
-- Each client uses its own LocalPlayer, UI, selection, and bounded request window.

local CONFIG = {
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

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Input = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local player = Players.LocalPlayer
assert(player, "AutoPainter must run on the client")
local playerGui = player:WaitForChild("PlayerGui")
local GUI_NAME = "AutoPainterFinalUI"

-- Re-running the loader focuses the running instance instead of doubling traffic.
local existing = playerGui:FindFirstChild(GUI_NAME)
if existing then
	local bridge = existing:FindFirstChild("Controller")
	if bridge and bridge:IsA("BindableFunction") then
		return bridge:Invoke()
	end
	existing:Destroy()
end

local alive = true
local connections, cacheConnections = {}, {}
local entries, lookup = {}, {}
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
local stats = { Attempted = 0, Returned = 0, Failures = 0, Observed = 0, Stalls = 0 }
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
	if entry.queued or not entry.active then return end
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
	local desired = targetColor(entry)
	local matched = part.Color == desired
	-- Count a target-color transition once, not once for each overlapping request.
	-- This observation is independent of RPC outcomes and may be caused by others.
	if matched and not entry.matched then stats.Observed += 1 end
	entry.matched = matched
	if matched then
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

removeEntry = function(entry)
	if not entry.active then return end
	entry.active = false
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
	local entry = { part = part, savedColor = color, active = true, box = box, id = selectionId,
		connections = {}, index = #entries + 1, failures = 0, notBefore = 0,
		failureEpoch = 0, lastSent = -math.huge, queued = false, matched = part.Color == color }
	entries[entry.index], lookup[part] = entry, entry
	connect(part:GetPropertyChangedSignal("Color"), function() evaluate(entry, os.clock()) end, entry.connections)
	connect(part:GetPropertyChangedSignal("Name"), function() evaluate(entry, os.clock()) end, entry.connections)
	connect(part.AncestryChanged, function() evaluate(entry, os.clock()) end, entry.connections)
	connect(part.Destroying, function() removeEntry(entry) end, entry.connections)
	evaluate(entry, os.clock())
	return true
end

local function finishRequest(job, ok)
	-- Release first, even if the selection, remote, mode or UI changed during the yield.
	jobs[job] = nil
	job.group.count -= 1
	if job.group.count == 0 then pendingByPart[job.part] = nil end
	outstanding -= 1
	if job.stalled then stalled -= 1 end
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
	if not alive or pumping or not painting or not remote then return end
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
			stats.Attempted += 1
			tokens -= 1
			frameBudget -= 1
			task.spawn(invoke, job)
			-- One request per visit. Extra capacity goes behind all waiting provinces.
			evaluate(entry, now)
			if not remote or not alive or not painting then break end
		end
	end
	pumping = false
end

kick = function()
	if not alive or pumpQueued or pumping or not painting or not remote or not readyHead then return end
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
	if CONFIG.Adaptive and not safe and painting and remote then
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
statusLabel = make("TextLabel", main, { Text = "Ready", TextSize = 16, BackgroundTransparency = 1,
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
	selectionMode = value
	main.Visible, doneButton.Visible = value == nil, value ~= nil
	if value then doneButton.Text = value .. " · Done / Cancel" end
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
switch(safeButton, safe); switch(paintButton, painting); switch(fastButton, fast); switch(keepButton, keepColor)

function api.SetColor(value)
	if not alive then return end
	assert(typeof(value) == "Color3", "Expected Color3")
	color = value
	colorButton.BackgroundColor3 = value
	colorButton.TextColor3 = (value.R + value.G + value.B > 1.5) and Color3.new(0, 0, 0) or Color3.new(1, 1, 1)
	if not keepColor then retargetAll() end
end
function api.SetPainting(value)
	if not alive then return end
	painting = value == true
	switch(paintButton, painting)
	tokens, tokenTime = math.min(tokens, 1), os.clock()
	resetSample(tokenTime)
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
api.AddProvince = addProvince
function api.RemoveProvince(part)
	if lookup[part] then removeEntry(lookup[part]) end
end
api.Clear = clearProvinces
function api.GetStats()
	local result = table.clone(stats)
	result.Selected, result.Ready, result.Delayed = #entries, readyCount, #delayed
	result.InFlight, result.Stalled, result.Window = outstanding, stalled, window
	result.MaxPerProvince = mode.MaxPerProvince
	local pendingProvinces = 0
	for _ in pairs(pendingByPart) do pendingProvinces += 1 end
	result.PendingProvinces = pendingProvinces
	result.RTT, result.RemoteReady, result.Running = rtt, remote ~= nil, alive
	return result
end
function api.Destroy(fromDestroying)
	if not alive then return end
	alive = false
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
connect(doneButton.Activated, function() setSelectionMode(nil) end)
connect(close.Activated, api.Destroy)

local function selectPart(part)
	if not part or not valid(part) then return end
	if selectionMode == "Color" then api.SetColor(part.Color); setSelectionMode(nil)
	elseif selectionMode == "Add" then addProvince(part)
	elseif selectionMode == "Remove" then api.RemoveProvince(part) end
end
local mouse = player:GetMouse()
connect(Input.InputBegan, function(input, processed)
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
bridge.OnInvoke = function() setSelectionMode(nil); return api end

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
	if painting and remote and readyHead and outstanding - stalled >= window then sample.BusyTime += dt end
	tune(now)
	kick()
	if now - lastDisplay >= CONFIG.TelemetryInterval then
		local elapsed = now - lastDisplay
		local observedRate, returnRate = (stats.Observed - lastObserved) / elapsed, (stats.Returned - lastReturned) / elapsed
		local state = not painting and "Paused" or (not remote and "Equip PaintBucket" or (safe and "Safe" or (fast and "Fast" or "Normal")))
		statusLabel.Text = string.format("%.1f returns/s · %d selected · %s", returnRate, #entries, state)
		detailLabel.Text = string.format("%.1f target matches/s · %d/%d active · %d stalled · %d errors", observedRate,
			outstanding - stalled, window, stalled, stats.Failures)
		lastDisplay, lastObserved, lastReturned = now, stats.Observed, stats.Returned
	end
end)
api.SetColor(color)
return api
