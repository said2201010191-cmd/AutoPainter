-- Appended to scheduler.spec by the runner: exercises real production UI callbacks.
local function uiButton(world, text)
	for _, object in ipairs(world.objects) do
		if object:IsA("TextButton") and object.Text == text and object:IsDescendantOf(world.playerGui) then return object end
	end
	error("Live button not found: " .. text)
end
local function press(world, text)
	uiButton(world, text).Activated:Fire(); world.flush()
end
local function clickTile(world, part)
	world.mouse.Target = part
	world.input.InputBegan:Fire({ UserInputType = world.env.Enum.UserInputType.MouseButton1 }, false)
	world.flush()
end
local function key(world, name, processed)
	world.input.InputBegan:Fire({ KeyCode = world.env.Enum.KeyCode[name] }, processed == true)
	world.flush()
end
local function finishSelection(world, api)
	press(world, api.GetStats().SelectionMode .. " · Done / Cancel")
end
local function outlines(world)
	local found = {}
	for _, object in ipairs(world.objects) do
		if object:IsA("SelectionBox") and object:IsDescendantOf(world.playerGui) then
			assert(object.Adornee and not found[object.Adornee], "Duplicate/detached selection outline")
			found[object.Adornee] = object
		end
	end
	return found
end
local function selectMany(world, count)
	local parts = {}
	for _ = 1, count do
		local part = world.province(); table.insert(parts, part); clickTile(world, part)
	end
	return parts
end
local function assertSilent(world, api, count)
	local s = api.GetStats()
	assert(#world.calls == 0 and s.Attempted == 0 and s.Returned == 0 and s.Failures == 0)
	assert(s.InFlight == 0 and s.Observed == 0 and s.PendingProvinces == 0)
	assert(s.Ready == 0 and s.Delayed == 0)
	if count then assert(s.PendingSelections == count and s.Selected == count and s.CommittedSelections == 0) end
end

for _, deferred in ipairs({ false, true }) do
	local prefix = deferred and "deferred selection: " or "immediate selection: "
	for _, modeCase in ipairs({ { name = "Normal", limit = 2 }, { name = "Fast", limit = 6 }, { name = "Safe", limit = 1 } }) do
		test(prefix .. modeCase.name .. " UI clicks 1 then 20: zero requests/work/tokens; atomic Done starts FIFO", function()
			local world, api = start(deferred)
			if modeCase.name == "Fast" then api.SetFast(true) elseif modeCase.name == "Safe" then api.SetSafe(true) end
			world.perPartLimit = modeCase.limit
			press(world, "Add")
			local spawns, defers, tokens = world.taskSpawns, world.taskDefers, api.GetStats().RequestTokens
			local parts = selectMany(world, 1); world.step(1); assertSilent(world, api, 1)
			for _, part in ipairs(selectMany(world, 19)) do table.insert(parts, part) end
			world.step(20); assertSilent(world, api, 20)
			assert(world.taskSpawns == spawns and world.taskDefers == defers, "Selection woke a task")
			assert(api.GetStats().RequestTokens == tokens, "Selection used request tokens")
			local boxes = outlines(world)
			for _, part in ipairs(parts) do assert(boxes[part] and boxes[part].SurfaceTransparency == 1) end
			world.onInvoke = function(part)
				local s = api.GetStats()
				assert(s.PendingSelections == 0 and s.CommittedSelections == 20 and not s.SelectionMode)
				assert(table.find(parts, part))
			end
			finishSelection(world, api)
			assert(api.GetStats().Painting)
			world.step(8)
			for i, part in ipairs(parts) do assert(world.calls[i].part == part, "Commit lost click-order FIFO") end
			assert(api.GetStats().Observed == 20 and world.peak <= (modeCase.name == "Safe" and 1 or 16))
			api.Destroy(); world.step(1); assert(world.connections == 0)
		end)
	end

	test(prefix .. "Done while Toggle Paint is OFF stays silent until Q resumes", function()
		local world, api = start(deferred)
		key(world, "Q"); press(world, "Add"); selectMany(world, 20)
		finishSelection(world, api); world.step(5)
		local s = api.GetStats()
		assert(not s.Painting and s.PendingSelections == 0 and s.CommittedSelections == 20)
		assert(#world.calls == 0 and s.Attempted == 0 and s.Ready == 0 and s.Delayed == 0)
		key(world, "Q"); world.step(3)
		assert(api.GetStats().Painting and api.GetStats().Observed == 20)
		api.Destroy()
	end)

	test(prefix .. "Q OFF/ON while Add is open never dispatches pending provinces", function()
		local world, api = start(deferred); press(world, "Add"); selectMany(world, 2)
		key(world, "Q"); world.step(1); key(world, "Q"); world.step(1)
		assertSilent(world, api, 2); assert(api.GetStats().Painting)
		finishSelection(world, api); world.step(1); assert(api.GetStats().Observed == 2)
		api.Destroy()
	end)

	test(prefix .. "all existing active work pauses while Add is open; returns still accounted", function()
		local world, api = start(deferred); api.SetFast(true)
		world.behavior = { noPaint = true, latency = 0.2 }
		local old = add(world, api, 1)[1]; world.step(0.02); assert(#world.calls == 6)
		press(world, "Add"); local fresh = selectMany(world, 1)[1]; world.step(2)
		assert(#world.calls == 6 and api.GetStats().Returned == 6 and api.GetStats().InFlight == 0)
		assert(api.GetStats().Painting and api.GetStats().PendingSelections == 1)
		finishSelection(world, api); world.step(0.1)
		assert(world.activeParts[old] == 6 and world.activeParts[fresh] == 6)
		api.Destroy(); world.step(1)
	end)

	test(prefix .. "Country Color click copies only, keeps picker open, and does not register or dispatch", function()
		local world, api = start(deferred); local samplePart = world.province()
		samplePart.Color = world.Color3.new(0.2, 0.4, 0.6)
		press(world, "Pick"); clickTile(world, samplePart); world.step(3)
		assertSilent(world, api, 0); assert(api.GetColor() == samplePart.Color)
		assert(uiButton(world, "Pick").BackgroundColor3 == samplePart.Color)
		assert(api.GetStats().SelectionMode == "Color" and next(outlines(world)) == nil)
		finishSelection(world, api); world.step(1); assertSilent(world, api, 0)
		api.Destroy()
	end)

	test(prefix .. "Country Color with active provinces cannot restart them until Done", function()
		local world, api = start(deferred)
		local part = add(world, api, 1)[1]; world.step(1)
		local sent = #world.calls; local samplePart = world.province(); samplePart.Color = world.Color3.new(0, 0, 1)
		press(world, "Pick"); clickTile(world, samplePart); world.step(2)
		assert(#world.calls == sent and api.GetStats().Selected == 1 and api.GetStats().Ready == 0)
		finishSelection(world, api); world.step(1)
		assert(part.Color == samplePart.Color and #world.calls > sent)
		api.Destroy()
	end)

	test(prefix .. "Remove click sends no replacement and stops future work despite six live calls", function()
		local world, api = start(deferred); api.SetFast(true); world.behavior = { noPaint = true, latency = 0.3 }
		local part = add(world, api, 1)[1]; world.step(0.02); local sent = #world.calls
		press(world, "Remove"); clickTile(world, part)
		assert(api.GetStats().Selected == 0 and api.GetStats().InFlight == 6)
		assert(api.GetStats().Ready == 0 and api.GetStats().Delayed == 0)
		finishSelection(world, api); world.step(3)
		assert(#world.calls == sent and api.GetStats().InFlight == 0 and api.GetStats().PendingProvinces == 0)
		api.Destroy()
	end)

	test(prefix .. "Clear button removes pending plus committed state; only existing calls return", function()
		local world, api = start(deferred); api.SetFast(true); world.behavior = { noPaint = true, latency = 0.3 }
		add(world, api, 1); world.step(0.02); press(world, "Add"); selectMany(world, 20)
		local sent = #world.calls
		press(world, "Clear") -- Same callback even when panel is hidden in selection mode.
		local s = api.GetStats()
		assert(s.Selected == 0 and s.PendingSelections == 0 and s.CommittedSelections == 0)
		assert(s.Ready == 0 and s.Delayed == 0 and s.InFlight == 6 and next(outlines(world)) == nil)
		finishSelection(world, api); world.step(2)
		assert(#world.calls == sent and api.GetStats().InFlight == 0 and api.GetStats().PendingProvinces == 0)
		api.Destroy(); world.flush(); assert(world.connections == 0)
	end)

	test(prefix .. "Escape finishes once and preserves clicked selections without temporary listeners", function()
		local world, api = start(deferred); api.SetPainting(false)
		local baseline = world.connections
		press(world, "Add"); selectMany(world, 3)
		assert(world.connections == baseline + 12)
		key(world, "Escape", true) -- CoreGui processing must not leave selection stuck.
		assert(api.GetStats().PendingSelections == 0 and api.GetStats().CommittedSelections == 3)
		assert(not api.GetStats().SelectionMode and not api.GetStats().Painting)
		key(world, "Escape"); world.step(1)
		assert(world.connections == baseline + 12 and #world.calls == 0)
		api.Clear(); world.flush(); assert(world.connections == baseline)
		api.Destroy()
	end)

	test(prefix .. "duplicate pending clicks and pending Remove/re-add preserve unique highlight and latest saved color", function()
		local world, api = start(deferred); api.SetKeepColor(true)
		press(world, "Add"); local part = selectMany(world, 1)[1]
		for _ = 1, 20 do clickTile(world, part) end
		assertSilent(world, api, 1)
		local box = outlines(world)[part]
		press(world, "Remove"); clickTile(world, part); assertSilent(world, api, 0)
		assert(not box.Parent)
		api.SetColor(world.Color3.new(1, 0, 0)); press(world, "Add"); clickTile(world, part)
		assertSilent(world, api, 1); assert(outlines(world)[part] ~= box)
		finishSelection(world, api); world.step(1); assert(part.Color == world.Color3.new(1, 0, 0))
		api.Destroy()
	end)

	test(prefix .. "respawn and absent/restored tool while selecting never commit or dispatch", function()
		local world, api = start(deferred); press(world, "Add"); selectMany(world, 20)
		world.player.Character = nil; world.flush(); world.step(1); assertSilent(world, api, 20)
		world.equip(); world.flush(); world.step(1); assertSilent(world, api, 20)
		world.bucket.Parent = nil; world.flush(); world.step(1); assertSilent(world, api, 20)
		world.bucket.Parent = world.character; world.flush(); world.step(1); assertSilent(world, api, 20)
		finishSelection(world, api); world.step(3)
		assert(api.GetStats().Observed == 20)
		for _, call in ipairs(world.calls) do assert(call.remote == world.remote) end
		api.Destroy()
	end)

	test(prefix .. "remote replacement and late old-call results cannot activate a re-added pending part", function()
		local world, api = start(deferred); api.SetFast(true); world.behavior = { hang = true }
		local part = add(world, api, 1)[1]; world.step(0.02)
		api.RemoveProvince(part); press(world, "Add"); clickTile(world, part)
		world.remote:Destroy(); world.flush()
		local replacement = world.instance("RemoteFunction"); replacement.Name = "ServerControls"; replacement.Parent = world.remotes
		world.flush()
		for index, call in ipairs(world.calls) do world.complete(call, index % 2 == 0) end
		world.flush(); world.step(2)
		assert(#world.calls == 6 and api.GetStats().InFlight == 0 and api.GetStats().PendingSelections == 1)
		assert(api.GetStats().Ready == 0 and api.GetStats().Delayed == 0)
		world.behavior = {}; finishSelection(world, api); world.step(1)
		assert(world.calls[7].remote == replacement and api.GetStats().Observed == 1)
		api.Destroy()
	end)

	test(prefix .. "replacement with ONLY pending selections produces zero requests", function()
		local world, api = start(deferred); press(world, "Add"); selectMany(world, 20)
		world.remote:Destroy(); world.flush()
		local replacement = world.instance("RemoteFunction"); replacement.Name = "ServerControls"; replacement.Parent = world.remotes
		world.flush(); world.step(2); assertSilent(world, api, 20)
		finishSelection(world, api); world.step(2); assert(world.calls[1].remote == replacement)
		api.Destroy()
	end)

	test(prefix .. "100 open/finish/clear cycles leave no pending state, outlines, tasks or listener growth", function()
		local world, api = start(deferred); api.SetPainting(false)
		local baseline = world.connections
		for iteration = 1, 100 do
			press(world, "Add"); local parts = selectMany(world, 20)
			if iteration % 2 == 0 then key(world, "Escape") else finishSelection(world, api) end
			press(world, "Clear"); world.flush()
			assert(api.GetStats().PendingSelections == 0 and api.GetStats().Selected == 0)
			assert(world.connections == baseline and next(outlines(world)) == nil and #world.events == 0)
			for _, part in ipairs(parts) do part:Destroy() end
		end
		assert(#world.calls == 0 and world.taskSpawns == 0)
		api.Destroy(); world.flush(); assert(world.connections == 0)
	end)

	test(prefix .. "destroyed/renamed/detached pending entries leave no stale links and cannot commit", function()
		local world, api = start(deferred); local baseline = world.connections
		press(world, "Add"); local parts = selectMany(world, 4)
		parts[1]:Destroy(); parts[2].Name = "Other"; parts[3].Parent = nil
		world.flush(); assertSilent(world, api, 1)
		assert(world.connections == baseline + 4)
		finishSelection(world, api); world.step(1)
		for _, call in ipairs(world.calls) do assert(call.part == parts[4]) end
		api.Destroy(); world.flush(); assert(world.connections == 0)
	end)

	test(prefix .. "large UI commit respects hard 64, no waiting-task backlog, and cleanup during stalls", function()
		local world, api = start(deferred); api.SetFast(true); world.behavior = { hang = true }
		press(world, "Add"); selectMany(world, 200); world.step(2); assertSilent(world, api, 200)
		finishSelection(world, api); world.step(80)
		assert(#world.calls == 64 and world.taskSpawns == 64 and #world.events == 0)
		assert(api.GetStats().InFlight == 64 and api.GetStats().Stalled == 64)
		assert(api.GetStats().Ready + api.GetStats().Delayed <= 200)
		local defers = world.taskDefers; world.step(60)
		assert(#world.calls == 64 and world.taskSpawns == 64 and world.taskDefers == defers)
		press(world, "Clear"); assert(api.GetStats().Ready == 0 and api.GetStats().Delayed == 0)
		for _, call in ipairs(world.calls) do world.complete(call, false) end
		world.flush(); assert(api.GetStats().InFlight == 0 and api.GetStats().PendingProvinces == 0)
		api.Destroy(); world.flush(); assert(world.connections == 0)
	end)

	for _, modeCase in ipairs({ { name = "Normal", limit = 2 }, { name = "Fast", limit = 6 }, { name = "Safe", limit = 1 } }) do
		test(prefix .. modeCase.name .. " single contested tile reaches configured overlap ONLY after UI commit", function()
			local world, api = start(deferred)
			if modeCase.name == "Fast" then api.SetFast(true) elseif modeCase.name == "Safe" then api.SetSafe(true) end
			world.perPartLimit = modeCase.limit; world.behavior = { noPaint = true, latency = 0.3 }
			press(world, "Add"); local part = selectMany(world, 1)[1]; world.step(3); assertSilent(world, api, 1)
			finishSelection(world, api); world.step(3)
			assert(world.peakParts[part] == modeCase.limit and api.GetStats().Returned >= modeCase.limit * 2)
			assert(api.GetStats().Observed == 0 and api.GetStats().Failures == 0)
			api.Destroy(); world.step(1)
		end)
	end

	test(prefix .. "first-pass fairness after commit lets a contested tile overlap without starving 30 others", function()
		local world, api = start(deferred); api.SetFast(true)
		press(world, "Add"); local parts = selectMany(world, 31)
		world.behavior = { latency = 0.2, hitsRequired = function(part) return part == parts[1] and 100 or 1 end }
		finishSelection(world, api); world.step(2)
		for i, part in ipairs(parts) do
			assert(world.calls[i].part == part)
			if i > 1 then assert(part.Color == api.GetColor()) end
		end
		assert(world.peakParts[parts[1]] == 6)
		api.Destroy(); world.step(1)
	end)

	test(prefix .. "selection exit honors all six old-target calls before latest new target", function()
		local world, api = start(deferred); api.SetFast(true); world.behavior = { hang = true }
		local part = add(world, api, 1)[1]; world.step(0.02); assert(#world.calls == 6)
		press(world, "Add"); api.SetColor(world.Color3.new(1, 0, 0)); api.SetColor(world.Color3.new(0, 0, 1))
		clickTile(world, part) -- Already committed: cannot duplicate it as pending.
		assert(api.GetStats().PendingSelections == 0)
		finishSelection(world, api); world.step(1); assert(#world.calls == 6)
		for i = 6, 2, -1 do world.complete(world.calls[i], true); world.flush(); assert(#world.calls == 6) end
		world.complete(world.calls[1], true); world.flush(); assert(#world.calls == 12)
		for i = 7, 12 do assert(world.calls[i].color == api.GetColor()) end
		api.Destroy(); for i = 7, 12 do world.complete(world.calls[i], false) end
		world.flush(); assert(api.GetStats().InFlight == 0)
	end)

	test(prefix .. "reload while Add is open does not commit, duplicate listeners or paint", function()
		local world, api = start(deferred); press(world, "Add"); selectMany(world, 20)
		local baseline = world.connections
		assert(world.load(SOURCE) == api); world.step(3)
		assertSilent(world, api, 20); assert(world.connections == baseline and api.GetStats().SelectionMode == "Add")
		finishSelection(world, api); world.step(2); assert(api.GetStats().Observed == 20)
		api.Destroy()
	end)

	test(prefix .. "closing UI discards pending selections and never sends them", function()
		local world, api = start(deferred); press(world, "Add"); selectMany(world, 20)
		press(world, "×"); world.step(2)
		assertSilent(world, api, 0); assert(not api.GetStats().Running and world.connections == 0)
		assert(next(outlines(world)) == nil)
	end)

	test(prefix .. "direct API additions also require explicit commit despite all wake sources", function()
		local world, api = start(deferred); local part = world.province(); api.AddProvince(part)
		api.SetFast(true); api.SetSafe(true); api.SetSafe(false); api.SetPainting(false); api.SetPainting(true)
		api.SetColor(world.Color3.new(1, 0, 0)); part.Color = world.Color3.new(0, 1, 0)
		world.equip(); world.step(3); assertSilent(world, api, 1)
		api.CommitSelections(); world.step(1); assert(part.Color == api.GetColor())
		api.Destroy()
	end)

	test(prefix .. "Randomize button and R change one current color/swatch without paint when unselected", function()
		math.randomseed(78223)
		local world, api = start(deferred); local initial = api.GetColor()
		press(world, "Change"); local randomized = api.GetColor()
		assert(randomized ~= initial and uiButton(world, "Pick").BackgroundColor3 == randomized)
		world.step(1); assertSilent(world, api, 0)
		key(world, "R"); assert(api.GetColor() ~= randomized and uiButton(world, "Pick").BackgroundColor3 == api.GetColor())
		world.step(1); assertSilent(world, api, 0)
		local latest = api.GetColor(); key(world, "R", true); assert(api.GetColor() == latest)
		api.Destroy()
	end)

	test(prefix .. "Keep OFF pending and committed provinces follow latest global color", function()
		local world, api = start(deferred)
		local red, blue = world.Color3.new(1, 0, 0), world.Color3.new(0, 0, 1)
		api.SetColor(red); press(world, "Add"); local parts = selectMany(world, 2)
		api.SetColor(blue); world.step(1); assertSilent(world, api, 2)
		for _, part in ipairs(parts) do assert(outlines(world)[part].Color3 == blue) end
		finishSelection(world, api); world.step(1)
		for _, part in ipairs(parts) do assert(part.Color == blue) end
		api.SetColor(red); world.step(1)
		for _, part in ipairs(parts) do assert(part.Color == red) end
		api.Destroy()
	end)

	test(prefix .. "Keep ON snapshots clicked color per province, including multiple colors in one pending session", function()
		local world, api = start(deferred); api.SetKeepColor(true)
		local red, blue, green = world.Color3.new(1, 0, 0), world.Color3.new(0, 0, 1), world.Color3.new(0, 1, 0)
		api.SetColor(red); press(world, "Add"); local a = selectMany(world, 1)[1]
		api.SetColor(blue); local b = selectMany(world, 1)[1]; api.SetColor(green)
		world.step(1); assertSilent(world, api, 2)
		assert(outlines(world)[a].Color3 == red and outlines(world)[b].Color3 == blue)
		finishSelection(world, api); world.step(1); assert(a.Color == red and b.Color == blue)
		local sent = #world.calls; key(world, "R"); world.step(1)
		assert(a.Color == red and b.Color == blue and #world.calls == sent)
		local newest = api.GetColor(); press(world, "Add"); local c = selectMany(world, 1)[1]
		finishSelection(world, api); world.step(1); assert(c.Color == newest)
		api.Destroy()
	end)

	test(prefix .. "Randomize and R throughout Add never enqueue pending provinces in either Keep mode", function()
		for _, keep in ipairs({ false, true }) do
			local world, api = start(deferred); api.SetKeepColor(keep); api.SetFast(true)
			press(world, "Add"); local parts = selectMany(world, 20); local original = api.GetColor()
			for _ = 1, 10 do press(world, "Change"); key(world, "R"); world.step(0.1) end
			assertSilent(world, api, 20)
			local target = keep and original or api.GetColor()
			finishSelection(world, api); world.step(2)
			for _, part in ipairs(parts) do assert(part.Color == target) end
			api.Destroy()
		end
	end)

	test(prefix .. "unverified manual bucket Color3Value is untouched; local color changes cannot call its listeners", function()
		local world, api = start(deferred)
		-- A plausible name is not evidence that this is a safe paint-color setter.
		local manual = world.instance("Color3Value"); manual.Name = "SelectedColor"
		manual.Value = world.Color3.new(0.2, 0.3, 0.4); manual.Parent = world.bucket
		local changed = 0
		local connection = manual:GetPropertyChangedSignal("Value"):Connect(function() changed += 1 end)
		local initial = manual.Value
		api.SetKeepColor(true); press(world, "Change"); key(world, "R")
		local samplePart = world.province(); samplePart.Color = world.Color3.new(0.5, 0.6, 0.7)
		press(world, "Pick"); clickTile(world, samplePart); finishSelection(world, api); world.step(1)
		assert(api.GetColor() == samplePart.Color and manual.Value == initial and changed == 0)
		assertSilent(world, api, 0)
		connection:Disconnect(); api.Destroy(); world.flush(); assert(world.connections == 0)
	end)
end

for _, deferred in ipairs({ false, true }) do
	local prefix = deferred and "deferred boundary: " or "immediate boundary: "
	test(prefix .. "visible Clear control stops a running queue with outstanding calls", function()
		local world, api = start(deferred); api.SetFast(true)
		world.behavior = { noPaint = true, latency = 0.3 }; add(world, api, 100); world.step(0.02)
		local sent = #world.calls; assert(sent > 0 and api.GetStats().Ready > 0)
		assert(uiButton(world, "Clear").Parent.Parent.Parent.Visible) -- Main panel is visible.
		press(world, "Clear"); world.step(2)
		assert(#world.calls == sent and api.GetStats().Selected == 0 and api.GetStats().InFlight == 0)
		api.Destroy()
	end)
	test(prefix .. "pending color/lifecycle events cannot affect request or observation counters", function()
		local world, api = start(deferred); press(world, "Add"); local part = selectMany(world, 1)[1]
		for _ = 1, 10 do
			part.Color = api.GetColor(); world.flush()
			part.Color = world.Color3.new(0, 0, 0); world.flush()
		end
		world.step(2); assertSilent(world, api, 1)
		part.Color = api.GetColor(); world.flush(); finishSelection(world, api); world.step(2)
		assert(api.GetStats().Observed == 0 and #world.calls == 0)
		part.Color = world.Color3.new(0, 0, 0); world.step(1); assert(api.GetStats().Observed == 1)
		api.Destroy()
	end)
	test(prefix .. "touch selection follows same pending transaction and respects processed input", function()
		local world, api = start(deferred); local part = world.province()
		world.workspace.CurrentCamera = { ViewportPointToRay = function()
			return { Origin = {}, Direction = setmetatable({}, { __mul = function() return {} end }) }
		end }
		world.workspace.Raycast = function() return { Instance = part } end
		press(world, "Add")
		world.input.TouchTapInWorld:Fire({ X = 10, Y = 10 }, true); world.flush(); assertSilent(world, api, 0)
		world.input.TouchTapInWorld:Fire({ X = 10, Y = 10 }, false); world.flush(); world.step(1)
		assertSilent(world, api, 1); assert(outlines(world)[part])
		finishSelection(world, api); world.step(1); assert(api.GetStats().Observed == 1)
		api.Destroy()
	end)
	test(prefix .. "Done/escape repetition, invalid tile, and immediate remove before commit cannot leak work", function()
		local world, api = start(deferred); press(world, "Add")
		local invalid = world.instance("Folder"); invalid.Name = "Province"; invalid.Parent = world.workspace
		clickTile(world, invalid); clickTile(world, nil); assertSilent(world, api, 0)
		local part = selectMany(world, 1)[1]
		part.Parent = nil
		-- Queue Done before the deferred lifecycle callbacks have been delivered.
		uiButton(world, "Add · Done / Cancel").Activated:Fire(); world.flush(); key(world, "Escape")
		world.step(2); assertSilent(world, api, 0)
		api.Destroy(); world.flush(); assert(world.connections == 0 and not api.GetStats().SelectionMode)
	end)
end
