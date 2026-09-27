-- Civil War AutoPainter: dedicated dirty-first target-color scheduler.
-- Every selected province gets a unique random target color.
-- Only provinces that differ from their target are scheduled.
-- One in-flight request per province prevents one stubborn tile from monopolizing the queue.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local player = assert(Players.LocalPlayer, "Run on the client")
local playerGui = player:WaitForChild("PlayerGui")
local mouse = player:GetMouse()

local CONFIG = {
	Rate = 300,               -- High throughput, but lower than the old 360 spam profile.
	Burst = 24,
	BatchPerFrame = 24,
	MaxBlocking = 24,        -- Non-stalled requests that may block progress.
	HardOutstanding = 64,    -- Includes requests already classified as stalled.
	StallAfter = 0.80,       -- Release global scheduler capacity quickly when one request hangs.
	RetryFailure = 0.25,
	RetryReturned = 0.06,    -- Small replication grace after a returned request.
	SweepInterval = 0.05,
	WatchdogInterval = 0.10,
	TelemetryInterval = 0.25,
}

local GUI_NAME = "AutoPainterCivilWarUI"
local old = playerGui:FindFirstChild(GUI_NAME)
if old then old:Destroy() end

local selecting = false
local running = false
local alive = true
local selected = {}
local entries = {}
local usedColors = {}
local hueSeed = math.random()
local colorIndex = 0
local selectionCount = 0

local queue = {}
local queueHead = 1
local jobs = {}
local blockingOutstanding = 0
local hardOutstanding = 0
local stalledCount = 0
local attempted = 0
local returned = 0
local failures = 0
local observedMatches = 0
local lastSweep = 0
local lastWatchdog = 0
local lastTelemetry = 0
local tokens = CONFIG.Burst
local tokenTime = os.clock()
local cachedRemote = nil

local function validProvince(part)
	return part ~= nil
		and part:IsA("BasePart")
		and part.Name == "Province"
		and part:IsDescendantOf(Workspace)
end

local function colorKey(c)
	local r = math.clamp(math.round(c.R * 255), 0, 255)
	local g = math.clamp(math.round(c.G * 255), 0, 255)
	local b = math.clamp(math.round(c.B * 255), 0, 255)
	return string.format("%02X%02X%02X", r, g, b)
end

local function colorDistance(a, b)
	local dr, dg, db = a.R - b.R, a.G - b.G, a.B - b.B
	return math.sqrt(dr * dr + dg * dg + db * db)
end

local function nextUniqueColor(current)
	-- Golden-ratio hue stepping gives strong separation between consecutive targets.
	-- Also reject colors that are too close to the tile's current color so every selection visibly changes.
	for _ = 1, 4096 do
		colorIndex += 1
		local h = (hueSeed + colorIndex * 0.618033988749895) % 1
		local s = 0.76 + math.random() * 0.24
		local v = 0.84 + math.random() * 0.16
		local c = Color3.fromHSV(h, s, v)
		local key = colorKey(c)
		if not usedColors[key] and (not current or colorDistance(c, current) >= 0.18) then
			usedColors[key] = true
			return c
		end
	end

	while true do
		local c = Color3.fromRGB(math.random(0, 255), math.random(0, 255), math.random(0, 255))
		local key = colorKey(c)
		if not usedColors[key] and (not current or colorDistance(c, current) >= 0.18) then
			usedColors[key] = true
			return c
		end
	end
end

local function resolveRemote()
	if cachedRemote and cachedRemote.Parent and cachedRemote:IsDescendantOf(game) then
		return cachedRemote
	end
	cachedRemote = nil
	local character = player.Character
	local bucket = character and character:FindFirstChild("PaintBucket")
	local remotes = bucket and bucket:FindFirstChild("Remotes")
	local candidate = remotes and remotes:FindFirstChild("ServerControls")
	if candidate and candidate:IsA("RemoteFunction") then
		cachedRemote = candidate
	end
	return cachedRemote
end

local function enqueue(entry)
	if not alive or not running or not entry.active or entry.queued or entry.inFlight then return end
	if not validProvince(entry.part) then return end
	if entry.part.Color == entry.target then return end
	if os.clock() < entry.retryAt then return end
	entry.queued = true
	queue[#queue + 1] = entry
end

local function compactQueue()
	if queueHead <= 128 or queueHead <= #queue / 2 then return end
	local fresh = {}
	for i = queueHead, #queue do
		fresh[#fresh + 1] = queue[i]
	end
	queue = fresh
	queueHead = 1
end

local function popQueue()
	while queueHead <= #queue do
		local entry = queue[queueHead]
		queue[queueHead] = nil
		queueHead += 1
		if entry then
			entry.queued = false
			compactQueue()
			return entry
		end
	end
	queue = {}
	queueHead = 1
	return nil
end

local gui = Instance.new("ScreenGui")
gui.Name = GUI_NAME
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = playerGui

local frame = Instance.new("Frame")
frame.Name = "CivilWarPanel"
frame.Size = UDim2.fromOffset(330, 184)
frame.Position = UDim2.new(1, -346, 0, 70)
frame.BackgroundColor3 = Color3.fromRGB(30, 30, 40)
frame.BorderSizePixel = 0
frame.Active = true
frame.Parent = gui

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, 0, 0, 30)
title.BackgroundColor3 = Color3.fromRGB(50, 50, 66)
title.BorderSizePixel = 0
title.TextColor3 = Color3.new(1, 1, 1)
title.Font = Enum.Font.SourceSansBold
title.TextSize = 18
title.Text = "Civil War · TARGET MODE"
title.Active = true
title.Parent = frame

local status = Instance.new("TextLabel")
status.Position = UDim2.fromOffset(8, 34)
status.Size = UDim2.new(1, -16, 0, 44)
status.BackgroundTransparency = 1
status.TextColor3 = Color3.fromRGB(215, 215, 225)
status.TextSize = 14
status.TextWrapped = true
status.Text = "NEW → select provinces → START. Each province gets its own permanent target color."
status.Parent = frame

local function button(text, x, width)
	local b = Instance.new("TextButton")
	b.Position = UDim2.fromOffset(x, 84)
	b.Size = UDim2.fromOffset(width, 32)
	b.BackgroundColor3 = Color3.fromRGB(75, 75, 95)
	b.BorderSizePixel = 0
	b.TextColor3 = Color3.new(1, 1, 1)
	b.TextSize = 15
	b.Font = Enum.Font.SourceSansBold
	b.Text = text
	b.Parent = frame
	return b
end

local newButton = button("NEW", 8, 92)
local startButton = button("START", 108, 104)
local cancelButton = button("CANCEL", 220, 102)

local countLabel = Instance.new("TextLabel")
countLabel.Position = UDim2.fromOffset(8, 120)
countLabel.Size = UDim2.new(1, -16, 0, 26)
countLabel.BackgroundTransparency = 1
countLabel.TextColor3 = Color3.fromRGB(100, 255, 150)
countLabel.TextSize = 14
countLabel.Text = "Selected: 0 · Dirty: 0"
countLabel.Parent = frame

local perfLabel = Instance.new("TextLabel")
perfLabel.Position = UDim2.fromOffset(8, 146)
perfLabel.Size = UDim2.new(1, -16, 0, 28)
perfLabel.BackgroundTransparency = 1
perfLabel.TextColor3 = Color3.fromRGB(190, 190, 215)
perfLabel.TextSize = 13
perfLabel.Text = "Ready"
perfLabel.Parent = frame

local function dirtyCount()
	local n = 0
	for _, entry in ipairs(entries) do
		if entry.active and validProvince(entry.part) and entry.part.Color ~= entry.target then
			n += 1
		end
	end
	return n
end

local function updateCount()
	countLabel.Text = string.format("Selected: %d · Dirty: %d", selectionCount, dirtyCount())
end

local function destroyEntry(entry)
	if not entry.active then return end
	entry.active = false
	entry.queued = false
	selected[entry.part] = nil
	if entry.connection then entry.connection:Disconnect(); entry.connection = nil end
	if entry.ancestry then entry.ancestry:Disconnect(); entry.ancestry = nil end
	if entry.box then entry.box:Destroy(); entry.box = nil end
end

local function clearCivilState()
	running = false
	selecting = false
	for _, entry in ipairs(entries) do destroyEntry(entry) end
	table.clear(entries)
	table.clear(selected)
	table.clear(usedColors)
	table.clear(queue)
	queueHead = 1
	selectionCount = 0
	colorIndex = 0
	hueSeed = math.random()
	updateCount()
end

local function addCivilProvince(part)
	if not selecting or not validProvince(part) or selected[part] then return end
	local target = nextUniqueColor(part.Color)
	local box = Instance.new("SelectionBox")
	box.Name = "CivilWarTarget"
	box.Adornee = part
	box.Color3 = target
	box.SurfaceTransparency = 0.90
	box.LineThickness = 0.03
	box.Parent = gui

	local entry = {
		part = part,
		target = target,
		active = true,
		queued = false,
		inFlight = nil,
		retryAt = 0,
		box = box,
	}
	selected[part] = entry
	entries[#entries + 1] = entry
	selectionCount += 1

	entry.connection = part:GetPropertyChangedSignal("Color"):Connect(function()
		if not entry.active then return end
		if part.Color == entry.target then
			observedMatches += 1
		else
			enqueue(entry)
		end
		updateCount()
	end)
	entry.ancestry = part.AncestryChanged:Connect(function()
		if entry.active and not validProvince(part) then
			destroyEntry(entry)
			selectionCount = math.max(0, selectionCount - 1)
			updateCount()
		end
	end)
	updateCount()
end

local function finishJob(job, ok)
	if not jobs[job] then return end
	jobs[job] = nil
	hardOutstanding = math.max(0, hardOutstanding - 1)
	if not job.stalled then
		blockingOutstanding = math.max(0, blockingOutstanding - 1)
	else
		stalledCount = math.max(0, stalledCount - 1)
	end

	local entry = job.entry
	if entry and entry.active and entry.inFlight == job then
		entry.inFlight = nil
		if ok then returned += 1 else failures += 1 end
		entry.retryAt = os.clock() + (ok and CONFIG.RetryReturned or CONFIG.RetryFailure)
		if not ok then cachedRemote = nil end
		if running and validProvince(entry.part) and entry.part.Color ~= entry.target then
			task.delay(ok and CONFIG.RetryReturned or CONFIG.RetryFailure, function()
				if alive then enqueue(entry) end
			end)
		end
	end
end

local function send(entry, remote)
	local job = {
		entry = entry,
		started = os.clock(),
		stalled = false,
	}
	entry.inFlight = job
	jobs[job] = true
	blockingOutstanding += 1
	hardOutstanding += 1
	attempted += 1

	task.spawn(function()
		local ok = pcall(function()
			remote:InvokeServer("PaintPart", { Part = entry.part, Color = entry.target }, "Peace")
		end)
		finishJob(job, ok)
	end)
end

local function refill(now)
	tokens = math.min(CONFIG.Burst, tokens + (now - tokenTime) * CONFIG.Rate)
	tokenTime = now
end

local function pump(now)
	if not running then return end
	local remote = resolveRemote()
	if not remote then return end
	refill(now)
	local sent = 0
	while tokens >= 1
		and sent < CONFIG.BatchPerFrame
		and blockingOutstanding < CONFIG.MaxBlocking
		and hardOutstanding < CONFIG.HardOutstanding do
		local entry = popQueue()
		if not entry then break end
		if entry.active and validProvince(entry.part) and not entry.inFlight and entry.part.Color ~= entry.target then
			if now >= entry.retryAt then
				tokens -= 1
				sent += 1
				send(entry, remote)
			else
				task.delay(math.max(0, entry.retryAt - now), function()
					if alive then enqueue(entry) end
				end)
			end
		end
	end
end

local function beginCivilWar()
	clearCivilState()
	selecting = true
	status.Text = "SELECTING: click every province you want. The outline is that province's target color."
	newButton.BackgroundColor3 = Color3.fromRGB(35, 145, 110)
	perfLabel.Text = "Selection mode"
end

local function startCivilWar()
	if not selecting then
		status.Text = "Press NEW first, then select provinces."
		return
	end
	if selectionCount == 0 then
		status.Text = "Select at least one province first."
		return
	end
	selecting = false
	running = true
	cachedRemote = nil
	tokens = CONFIG.Burst
	tokenTime = os.clock()
	for _, entry in ipairs(entries) do enqueue(entry) end
	status.Text = "RUNNING: DIRTY provinces are fixed first; a stalled province is isolated so the rest keep moving."
	newButton.BackgroundColor3 = Color3.fromRGB(75, 75, 95)
end

local function cancelCivilWar()
	clearCivilState()
	status.Text = "Cancelled. Press NEW to start another civil war."
	newButton.BackgroundColor3 = Color3.fromRGB(75, 75, 95)
	perfLabel.Text = "Ready"
end

newButton.Activated:Connect(beginCivilWar)
startButton.Activated:Connect(startCivilWar)
cancelButton.Activated:Connect(cancelCivilWar)

UserInputService.InputBegan:Connect(function(input, processed)
	if processed or not selecting or UserInputService:GetFocusedTextBox() then return end
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		addCivilProvince(mouse.Target)
	elseif input.KeyCode == Enum.KeyCode.Escape then
		cancelCivilWar()
	end
end)

UserInputService.TouchTapInWorld:Connect(function(position, processed)
	if processed or not selecting then return end
	local camera = Workspace.CurrentCamera
	if not camera then return end
	local ray = camera:ViewportPointToRay(position.X, position.Y)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = player.Character and { player.Character } or {}
	local hit = Workspace:Raycast(ray.Origin, ray.Direction * 10000, params)
	if hit then addCivilProvince(hit.Instance) end
end)

-- Draggable mini-panel.
local dragging, dragStart, startPosition, dragInput

title.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		dragging = true
		dragStart = input.Position
		startPosition = frame.Position
		dragInput = input
	end
end)

UserInputService.InputChanged:Connect(function(input)
	if dragging and (input == dragInput or input.UserInputType == Enum.UserInputType.MouseMovement) then
		local delta = input.Position - dragStart
		frame.Position = UDim2.new(
			startPosition.X.Scale,
			startPosition.X.Offset + delta.X,
			startPosition.Y.Scale,
			startPosition.Y.Offset + delta.Y
		)
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if input == dragInput or input.UserInputType == Enum.UserInputType.MouseButton1 then
		dragging = false
		dragInput = nil
	end
end)

RunService.Heartbeat:Connect(function()
	if not alive then return end
	local now = os.clock()

	if running and now - lastSweep >= CONFIG.SweepInterval then
		lastSweep = now
		for _, entry in ipairs(entries) do
			if entry.active and not entry.inFlight and not entry.queued and validProvince(entry.part)
				and entry.part.Color ~= entry.target and now >= entry.retryAt then
				enqueue(entry)
			end
		end
	end

	if now - lastWatchdog >= CONFIG.WatchdogInterval then
		lastWatchdog = now
		for job in pairs(jobs) do
			if not job.stalled and now - job.started >= CONFIG.StallAfter then
				job.stalled = true
				blockingOutstanding = math.max(0, blockingOutstanding - 1)
				stalledCount += 1
				-- Do NOT resend this same province while its old call is still alive.
				-- It is quarantined, while every other dirty province can continue.
			end
		end
	end

	pump(now)

	if now - lastTelemetry >= CONFIG.TelemetryInterval then
		lastTelemetry = now
		updateCount()
		local remoteReady = resolveRemote() ~= nil
		perfLabel.Text = string.format(
			"%s · active %d · stalled %d · sent %d · returned %d · errors %d",
			remoteReady and "Bucket ready" or "Equip PaintBucket",
			blockingOutstanding,
			stalledCount,
			attempted,
			returned,
			failures
		)
	end
end)

gui.Destroying:Connect(function()
	alive = false
	running = false
	selecting = false
	for _, entry in ipairs(entries) do destroyEntry(entry) end
end)

return {
	BeginCivilWar = beginCivilWar,
	StartCivilWar = startCivilWar,
	CancelCivilWar = cancelCivilWar,
	Selected = selected,
	GetStats = function()
		return {
			Selected = selectionCount,
			Dirty = dirtyCount(),
			Blocking = blockingOutstanding,
			Outstanding = hardOutstanding,
			Stalled = stalledCount,
			Attempted = attempted,
			Returned = returned,
			Failures = failures,
			ObservedMatches = observedMatches,
			Running = running,
		}
	end,
}
