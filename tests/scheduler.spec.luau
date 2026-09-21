-- SOURCE is embedded by run_tests.py, so this exercises the production script.
local Mock = require("./MockRoblox")
local passed = 0
local function test(name, callback)
	callback()
	passed += 1
	print("PASS", name)
end
local function start(deferred)
	local world = Mock.new(deferred)
	return world, world.load(SOURCE)
end
local function add(world, api, count)
	local parts = {}
	for _ = 1, count do
		local part = world.province(); api.AddProvince(part); table.insert(parts, part)
	end
	api.CommitSelections()
	return parts
end

for _, deferred in ipairs({ false, true }) do
	local prefix = deferred and "deferred: " or "immediate: "
	test(prefix .. "unique selection, FIFO first round and silence after color matches", function()
		local world, api = start(deferred)
		local parts = add(world, api, 100)
		assert(not api.AddProvince(parts[1]))
		world.step(2)
		local stats = api.GetStats()
		assert(stats.Attempted >= 100 and stats.Attempted <= 200 and stats.Returned == stats.Attempted and stats.Observed == 100)
		assert(stats.InFlight == 0 and stats.Ready == 0 and stats.Delayed == 0)
		for index = 1, 100 do assert(world.calls[index].part == parts[index], "FIFO first-round order") end
		assert(world.peak <= 8)
		local sent = #world.calls; world.step(10)
		assert(#world.calls == sent, "Idle provinces generated traffic")
		api.Destroy(); world.flush(); assert(world.connections == 0)
	end)
	test(prefix .. "delayed replication does not classify valid returns as errors", function()
		local world, api = start(deferred)
		world.behavior = { latency = 0.1, replicationDelay = 0.06 }
		add(world, api, 60); world.step(3)
		assert(api.GetStats().Attempted > 60 and api.GetStats().Observed == 60)
		assert(api.GetStats().Failures == 0 and api.GetStats().Delayed == 0)
		assert(api.GetStats().Unconfirmed == nil and api.GetStats().InFlight == 0)
		api.Destroy()
	end)
	test(prefix .. "latest color wins and original Keep Territory Color semantics", function()
		local world, api = start(deferred)
		world.behavior = { latency = 0.4 }
		local part = add(world, api, 1)[1]; world.step(0.02)
		local red, blue = world.Color3.new(1, 0, 0), world.Color3.new(0, 0, 1)
		api.SetColor(red); api.SetColor(blue)
		world.step(2)
		assert(part.Color == blue and #world.calls == 4)
		api.SetKeepColor(true); world.step(1)
		assert(part.Color == world.Color3.new(1, 1, 1))
		local sent = #world.calls; api.SetColor(red); world.step(1); assert(#world.calls == sent)
		api.SetKeepColor(false); world.step(1); assert(part.Color == red)
		api.Destroy()
	end)
	test(prefix .. "clear and re-add preserve group counts and old-color barrier", function()
		local world, api = start(deferred)
		world.behavior = { latency = 0.4 }
		local part = add(world, api, 1)[1]; world.step(0.02)
		api.Clear(); assert(api.GetStats().Selected == 0 and api.GetStats().InFlight == 2)
		api.SetColor(world.Color3.new(1, 0, 0)); api.AddProvince(part); api.CommitSelections()
		world.step(0.2); assert(#world.calls == 2)
		world.step(1); assert(#world.calls == 4 and world.peak == 2)
		assert(part.Color == world.Color3.new(1, 0, 0))
		api.Destroy()
	end)
	test(prefix .. "errors release capacity, back off and recover", function()
		local world, api = start(deferred)
		world.behavior = { errors = true, latency = 0.05 }
		add(world, api, 40); world.step(6)
		assert(api.GetStats().Failures > 0 and api.GetStats().InFlight <= 8)
		assert(api.GetStats().Window < 8, "Error feedback did not reduce the window")
		local early, late = 0, 0
		for _, call in ipairs(world.calls) do
			if call.at < 2 then early += 1 elseif call.at >= 4 then late += 1 end
		end
		assert(late < early / 2 and #world.calls < 320, "Errors did not reduce retry traffic")
		world.behavior = {}; world.step(9)
		assert(api.GetStats().Observed == 40 and api.GetStats().InFlight == 0)
		api.Destroy()
	end)
	test(prefix .. "unchanged color does not back off returned requests or shrink the window", function()
		local world, api = start(deferred)
		world.behavior = { noPaint = true }; add(world, api, 20); world.step(8)
		local stats = api.GetStats()
		assert(stats.Returned > 300 and stats.Observed == 0 and stats.Unconfirmed == nil)
		assert(stats.Window >= 8 and stats.Failures == 0 and stats.Delayed == 0)
		world.behavior = {}; world.step(9); assert(api.GetStats().Observed == 20)
		api.Destroy()
	end)
	test(prefix .. "Safe mode global pacing and per-province delay", function()
		local world, api = start(deferred)
		api.SetFast(true); api.SetSafe(true)
		local parts = add(world, api, 20); world.step(2)
		assert(#world.calls <= 9 and world.peak <= 1 and api.GetStats().Window == 1)
		api.Clear(); world.step(1)
		local part = parts[1]; part.Color = world.Color3.new(0, 0, 0)
		api.AddProvince(part); api.CommitSelections(); world.step(0.3)
		part.Color = world.Color3.new(0, 0, 0); world.step(2)
		local last = -math.huge
		for _, call in ipairs(world.calls) do
			if call.part == part then assert(call.at - last >= 0.999); last = call.at end
		end
		api.Destroy()
	end)
	test(prefix .. "respawn, absent tool, remote replacement and late old return", function()
		local world, api = start(deferred)
		world.behavior = { latency = 0.5 }
		local part = add(world, api, 1)[1]; world.step(0.02)
		world.player.Character = nil; world.flush()
		api.SetColor(world.Color3.new(1, 0, 0)); world.step(0.6)
		assert(#world.calls == 2 and not api.GetStats().RemoteReady)
		world.equip(); world.flush(); world.step(1)
		assert(#world.calls == 4 and world.calls[3].remote == world.remote)
		world.remote:Destroy(); world.flush()
		part.Color = world.Color3.new(0, 0, 0); world.step(0.3); assert(#world.calls == 4)
		local replacement = world.instance("RemoteFunction")
		replacement.Parent = world.remotes; replacement.Name = "ServerControls"
		world.step(2); assert(#world.calls == 6 and world.calls[5].remote == replacement)
		world.bucket.Parent = nil; world.flush(); assert(not api.GetStats().RemoteReady)
		world.bucket.Parent = world.character; world.flush(); assert(api.GetStats().RemoteReady)
		api.Destroy()
	end)
	test(prefix .. "stalled calls stay bounded across clear/re-add and recover on return", function()
		local world, api = start(deferred)
		api.SetFast(true); world.behavior = { hang = true }
		local parts = add(world, api, 200); world.step(65)
		assert(#world.calls == 64 and api.GetStats().InFlight == 64)
		assert(api.GetStats().Stalled == 64)
		api.Clear(); for _, part in ipairs(parts) do api.AddProvince(part) end; api.CommitSelections()
		world.step(20); assert(#world.calls == 64)
		world.behavior = {}
		for _, call in ipairs(table.clone(world.calls)) do world.complete(call, false) end
		world.flush(); world.step(6)
		assert(api.GetStats().Observed == 200 and api.GetStats().InFlight == 0)
		assert(world.peak <= 64)
		api.Destroy()
	end)
	test(prefix .. "destroyed, renamed and reparented provinces are removed", function()
		local world, api = start(deferred)
		api.SetPainting(false)
		local parts = add(world, api, 100)
		for i = 1, 25 do parts[i]:Destroy() end
		for i = 26, 50 do parts[i].Name = "Other" end
		for i = 51, 75 do parts[i].Parent = nil end
		world.flush(); assert(api.GetStats().Selected == 25 and api.GetStats().Ready == 0)
		api.SetPainting(true); world.step(2); assert(api.GetStats().Observed == 25)
		api.Destroy()
	end)
	test(prefix .. "100 repeated clear cycles release connections and pending timers", function()
		local world, api = start(deferred)
		api.SetPainting(false)
		local baseline = world.connections
		for _ = 1, 100 do
			local parts = add(world, api, 100)
			for i = 1, 50 do api.RemoveProvince(parts[i]) end
			api.Clear(); world.flush()
			local stats = api.GetStats()
			assert(stats.Selected == 0 and stats.Ready == 0 and stats.Delayed == 0)
			assert(world.connections == baseline, "Connection leak")
			for _, part in ipairs(parts) do part:Destroy() end
		end
		api.Destroy(); world.flush(); assert(world.connections == 0)
	end)
	test(prefix .. "duplicate loader and UI destruction", function()
		local world, api = start(deferred)
		local baseline = world.connections
		assert(world.load(SOURCE) == api and world.connections == baseline)
		add(world, api, 30); world.step(0.02)
		world.playerGui:FindFirstChild("AutoPainterFinalUI"):Destroy(); world.flush()
		local sent = #world.calls
		world.step(3)
		assert(#world.calls == sent and not api.GetStats().Running)
		assert(api.GetStats().InFlight == 0 and world.connections == 0)
	end)
end

test("adaptive growth under sustained distinct-province demand", function()
	local world, api = start(true)
	api.SetFast(true)
	world.behavior = { latency = 0.35 }
	add(world, api, 1600); world.step(10)
	assert(api.GetStats().Window > 16 and api.GetStats().Observed > 500)
	print("SIMULATED adaptive", api.GetStats().Window, "window;", api.GetStats().Observed, "observations in 10s")
	api.Destroy(); world.step(1)
end)

test("adaptive search lowers a wasteful window when throughput plateaus", function()
	local world, api = start(true)
	api.SetFast(true)
	world.behavior = { latency = function(active) return math.max(0.1, active * 0.025) end }
	add(world, api, 3000); world.step(42)
	assert(api.GetStats().Window < 16, "Plateau probes did not find a cheaper window")
	assert(api.GetStats().Observed > 1250)
	print("SIMULATED plateau", api.GetStats().Window, "window;", api.GetStats().Observed, "observations in 42s")
	api.Destroy(); world.step(2)
end)

test("adaptive performance versus fixed initial window (simulated latency)", function()
	local observations = {}
	for _, adaptive in ipairs({ false, true }) do
		local world = Mock.new(true)
		local source = adaptive and SOURCE or string.gsub(SOURCE, "Adaptive = true", "Adaptive = false", 1)
		local api = world.load(source); api.SetFast(true)
		world.behavior = { latency = 0.35 }; add(world, api, 1600); world.step(10)
		table.insert(observations, api.GetStats().Observed)
		api.Destroy(); world.step(1)
	end
	assert(observations[2] > observations[1] * 1.15)
	print("SIMULATED 10s: fixed", observations[1], "adaptive", observations[2])
end)

test("randomized add/remove/clear, pending retries, and target changes", function()
	math.randomseed(61521)
	local world, api = start(true)
	local parts = add(world, api, 100)
	local selected = {}; for _, part in ipairs(parts) do selected[part] = true end
	for iteration = 1, 700 do
		local part = parts[math.random(1, #parts)]
		local operation = math.random(1, 9)
		if operation == 1 then api.AddProvince(part); api.CommitSelections(); selected[part] = true
		elseif operation == 2 then api.RemoveProvince(part); selected[part] = nil
		elseif operation == 3 then part.Color = world.Color3.new(0, 0, 0)
		elseif operation == 4 then api.SetColor(world.Color3.fromRGB(iteration % 256, 100, 200))
		elseif operation == 5 then api.SetSafe(iteration % 2 == 0)
		elseif operation == 6 then api.SetFast(iteration % 2 == 0)
		elseif operation == 7 then world.behavior = { errors = iteration % 2 == 0 }
		elseif operation == 8 then api.SetKeepColor(iteration % 2 == 0)
		elseif iteration % 19 == 0 then api.Clear(); table.clear(selected) end
		world.step(0.035)
		local count = 0; for _ in pairs(selected) do count += 1 end
		local stats = api.GetStats()
		assert(stats.Selected == count and stats.Ready + stats.Delayed <= count)
		assert(stats.Attempted == stats.Returned + stats.Failures + stats.InFlight)
		assert(stats.InFlight == world.active and stats.InFlight >= 0 and stats.InFlight <= 64)
		local pending = 0; for _ in pairs(world.activeParts) do pending += 1 end
		assert(stats.PendingProvinces == pending, "Pending province group leaked or released early")
	end
	api.Clear(); api.Destroy(); world.step(2); assert(world.connections == 0)
end)

test("zero-latency replies, pause and FPS-independent rate ceiling", function()
	for _, fps in ipairs({ 15, 60, 240 }) do
		local world, api = start(true)
		world.behavior = { latency = 0 }; api.SetFast(true); add(world, api, 1000)
		world.step(1, fps)
		assert(#world.calls <= 376 and world.peak <= 64)
		local sent = #world.calls; api.SetPainting(false); world.step(1, fps)
		assert(#world.calls == sent)
		api.Destroy()
	end
end)

test("Safe mode retains its single-call ceiling even when a call stalls", function()
	local world, api = start(true)
	api.SetSafe(true); world.behavior = { hang = true }; add(world, api, 20)
	world.step(35)
	assert(#world.calls == 1 and api.GetStats().Stalled == 1)
	api.Destroy(); world.complete(world.calls[1], false); world.flush()
	assert(api.GetStats().InFlight == 0 and world.connections == 0)
end)

test("UI buttons, exclusive selection, mouse input and keyboard shortcuts", function()
	local world, api = start(true)
	local function button(text)
		for _, object in ipairs(world.objects) do
			if object:IsA("TextButton") and object.Text == text then return object end
		end
		error("Button not found: " .. text)
	end
	button("Add").Activated:Fire(); world.flush()
	local part = world.province(); world.mouse.Target = part
	world.input.InputBegan:Fire({ UserInputType = world.env.Enum.UserInputType.MouseButton1 }, false)
	world.flush(); assert(api.GetStats().Selected == 1)
	button("Add · Done / Cancel").Activated:Fire(); world.flush()
	button("Pick").Activated:Fire(); world.flush()
	local samplePart = world.province(); samplePart.Color = world.Color3.new(0, 1, 0); world.mouse.Target = samplePart
	world.input.InputBegan:Fire({ UserInputType = world.env.Enum.UserInputType.MouseButton1 }, false)
	world.flush(); button("Color · Done / Cancel").Activated:Fire(); world.flush(); world.step(1)
	assert(api.GetStats().Selected == 1 and part.Color == samplePart.Color)
	world.input.InputBegan:Fire({ KeyCode = world.env.Enum.KeyCode.Q }, false); world.flush()
	local sent = #world.calls
	world.input.InputBegan:Fire({ KeyCode = world.env.Enum.KeyCode.R }, false); world.flush(); world.step(1)
	assert(#world.calls == sent)
	world.input.InputBegan:Fire({ KeyCode = world.env.Enum.KeyCode.Q }, false); world.flush(); world.step(1)
	assert(#world.calls == sent + 2)
	button("Remove").Activated:Fire(); world.flush(); world.mouse.Target = part
	world.input.InputBegan:Fire({ UserInputType = world.env.Enum.UserInputType.MouseButton1 }, false)
	world.flush(); assert(api.GetStats().Selected == 0)
	button("×").Activated:Fire(); world.flush(); assert(not api.GetStats().Running)
end)

for _, deferred in ipairs({ false, true }) do
	local prefix = deferred and "deferred overlap: " or "immediate overlap: "
	test(prefix .. "Normal 2, Fast 6 and Safe 1 caps on a continuously contested province", function()
		for _, config in ipairs({ { name = "Normal", limit = 2 }, { name = "Fast", limit = 6 }, { name = "Safe", limit = 1 } }) do
			local world, api = start(deferred)
			if config.name == "Fast" then api.SetFast(true) elseif config.name == "Safe" then api.SetSafe(true) end
			world.perPartLimit = config.limit; world.behavior = { noPaint = true, latency = 0.2 }
			local part = add(world, api, 1)[1]; world.step(3)
			local stats = api.GetStats()
			assert(world.peakParts[part] == config.limit and stats.MaxPerProvince == config.limit)
			assert(stats.Returned >= config.limit * 2 and stats.Observed == 0 and stats.Failures == 0)
			assert(stats.Delayed == (config.name == "Safe" and 1 or 0))
			api.Destroy(); world.step(1); assert(api.GetStats().PendingProvinces == 0)
		end
	end)
	test(prefix .. "one request per FIFO round before extra same-province allocation", function()
		local world, api = start(deferred); api.SetFast(true)
		world.behavior = { hang = true }
		local parts = add(world, api, 4); world.step(0.1)
		assert(#world.calls == 16)
		for index, call in ipairs(world.calls) do assert(call.part == parts[(index - 1) % 4 + 1]) end
		api.Destroy()
		for _, call in ipairs(world.calls) do world.complete(call, false) end
		assert(api.GetStats().InFlight == 0 and api.GetStats().PendingProvinces == 0)
	end)
	test(prefix .. "heavily contested province receives extras without starving easy provinces", function()
		local world, api = start(deferred); api.SetFast(true)
		local contested = world.province(); api.AddProvince(contested)
		local others = add(world, api, 25)
		world.behavior = { latency = 0.2, hitsRequired = function(part) return part == contested and 80 or 1 end }
		world.step(1.5)
		for index, part in ipairs(others) do
			assert(world.calls[index + 1].part == part and part.Color == world.Color3.new(1, 1, 1))
		end
		assert(world.peakParts[contested] == 6 and contested.Color ~= world.Color3.new(1, 1, 1))
		world.step(3); assert(contested.Color == world.Color3.new(1, 1, 1))
		assert(api.GetStats().Observed == 26)
		api.Destroy()
	end)
	test(prefix .. "late selections wait at most one existing FIFO ticket from a busy province", function()
		local world = Mock.new(deferred)
		local source = string.gsub(SOURCE, "Fast = { Initial = 16", "Fast = { Initial = 4", 1)
		local api = world.load(source); api.SetFast(true)
		world.behavior = { noPaint = true, latency = 0.2 }
		add(world, api, 1); world.step(0.02); assert(#world.calls == 4)
		local others = add(world, api, 20); world.step(1.5)
		-- The busy province may already hold one ready ticket when these are added.
		local first = world.calls[5].part == others[1] and 5 or 6
		for index, part in ipairs(others) do assert(world.calls[first + index - 1].part == part, "A returning contested province jumped the queue") end
		api.Destroy(); world.step(1)
	end)
	test(prefix .. "six pending calls survive repeated remove/clear/re-add without cap bypass", function()
		local world, api = start(deferred); api.SetFast(true); world.behavior = { hang = true }
		local part = add(world, api, 1)[1]; world.step(0.02); assert(#world.calls == 6)
		for _ = 1, 100 do
			api.RemoveProvince(part); api.AddProvince(part); api.CommitSelections(); api.Clear(); api.AddProvince(part); api.CommitSelections(); world.flush()
		end
		assert(#world.calls == 6 and api.GetStats().PendingProvinces == 1)
		world.step(20); assert(api.GetStats().Stalled == 6 and #world.calls == 6)
		api.Clear(); assert(api.GetStats().Ready == 0 and api.GetStats().Delayed == 0)
		for index = 6, 1, -1 do world.complete(world.calls[index], false) end
		world.flush(); assert(api.GetStats().InFlight == 0 and api.GetStats().PendingProvinces == 0)
		api.Destroy(); world.flush(); assert(world.connections == 0)
	end)
	test(prefix .. "newest target waits for every old-color call, including out-of-order returns", function()
		local world, api = start(deferred); api.SetFast(true); world.behavior = { hang = true }
		local part = add(world, api, 1)[1]; world.step(0.02)
		local blue = world.Color3.new(0, 0, 1)
		api.SetColor(world.Color3.new(1, 0, 0)); api.SetColor(blue)
		for index = 6, 2, -1 do world.complete(world.calls[index], true); world.flush(); assert(#world.calls == 6) end
		world.behavior = {}; world.complete(world.calls[1], true); world.flush()
		assert(#world.calls == 12)
		for index = 7, 12 do assert(world.calls[index].color == blue) end
		world.step(1); assert(part.Color == blue and api.GetStats().Observed == 1)
		api.Destroy()
	end)
	test(prefix .. "one error is not cleared by older successful sibling returns", function()
		local world, api = start(deferred); api.SetFast(true)
		world.behavior = { noPaint = true,
			latency = function(_, _, index) return index == 1 and 0.1 or 0.15 end,
			errors = function(_, index) return index == 1 end }
		add(world, api, 1); world.step(0.6)
		assert(api.GetStats().Failures == 1 and #world.calls >= 12)
		assert(world.calls[7].at >= world.calls[1].at + 0.1 + 0.19, "A sibling erased the error cooldown")
		api.Destroy(); world.step(1)
	end)
	test(prefix .. "respawn shares per-province accounting with six old-remote calls", function()
		local world, api = start(deferred); api.SetFast(true); world.behavior = { hang = true }
		add(world, api, 1); world.step(0.02)
		local oldCalls = table.clone(world.calls); world.player.Character = nil; world.flush()
		world.equip(); world.flush(); assert(#world.calls == 6)
		world.behavior = {}; world.complete(oldCalls[3], false); world.flush()
		assert(#world.calls == 7 and world.calls[7].remote == world.remote)
		assert(api.GetStats().Delayed == 0, "Old-generation error penalized the new remote")
		for index, call in ipairs(oldCalls) do if index ~= 3 then world.complete(call, false) end end
		world.flush(); world.step(1)
		assert(world.peak == 6 and api.GetStats().InFlight == 0 and api.GetStats().Observed == 1)
		api.Destroy()
	end)
	test(prefix .. "nil and false return values do not invent a rejection contract", function()
		for _, value in ipairs({ { value = nil }, { value = false } }) do
			local world, api = start(deferred); api.SetFast(true)
			world.behavior = { noPaint = true, returnValue = value.value }
			add(world, api, 1); world.step(2)
			assert(api.GetStats().Returned > 60 and api.GetStats().Failures == 0 and api.GetStats().Observed == 0)
			assert(api.GetStats().Delayed == 0 and api.GetStats().Window == 16)
			api.Destroy(); world.step(1)
		end
	end)
	test(prefix .. "destroyed province releases selection now and all group records on return", function()
		local world, api = start(deferred); api.SetFast(true)
		local baseline = world.connections
		world.behavior = { latency = 0.3 }
		local part = add(world, api, 1)[1]; world.step(0.02); part:Destroy(); world.flush()
		assert(api.GetStats().Selected == 0 and api.GetStats().InFlight == 6 and world.connections == baseline)
		world.step(1)
		assert(#world.calls == 6 and api.GetStats().InFlight == 0 and api.GetStats().PendingProvinces == 0)
		api.Destroy()
	end)
	test(prefix .. "switching from Fast to Safe drains old calls before resuming", function()
		local world, api = start(deferred); api.SetFast(true)
		world.behavior = { noPaint = true, latency = 0.4 }
		add(world, api, 1); world.step(0.02); api.SetSafe(true); world.step(0.8)
		assert(#world.calls == 6 and api.GetStats().InFlight == 0)
		world.step(2)
		for index = 7, #world.calls do
			assert(world.calls[index].concurrent == 1)
			if index > 7 then assert(world.calls[index].at - world.calls[index - 1].at >= 0.999) end
		end
		assert(#world.calls >= 8)
		api.Destroy(); world.step(1)
	end)
end

test("Fast 6 versus configurable Fast 1 on a province requiring 24 contributions", function()
	local times = {}
	for _, limit in ipairs({ 1, 6 }) do
		local world = Mock.new(true)
		local source = string.gsub(SOURCE, "MaxPerProvince = 6", "MaxPerProvince = " .. limit, 1)
		local api = world.load(source); api.SetFast(true)
		world.behavior = { hitsRequired = 24, latency = 0.2 }
		add(world, api, 1)
		while api.GetStats().Observed == 0 and world.now < 12 do world.step(1 / 60) end
		assert(api.GetStats().Observed == 1 and api.GetStats().Failures == 0)
		table.insert(times, world.now)
		api.Destroy(); world.step(1)
	end
	assert(times[2] < times[1] / 4)
	print(string.format("SIMULATED 24-contribution province: Fast 1 %.2fs; Fast 6 %.2fs", times[1], times[2]))
end)

test("adaptive growth uses return throughput even with no color observations", function()
	local world, api = start(true); api.SetFast(true)
	world.behavior = { noPaint = true, latency = 0.35 }; add(world, api, 100); world.step(10)
	assert(api.GetStats().Window > 16 and api.GetStats().Returned > 500 and api.GetStats().Observed == 0)
	assert(api.GetStats().Failures == 0 and api.GetStats().Delayed == 0)
	api.Destroy(); world.step(1)
end)

test("multiple players have independent UI, modes, selections, remotes and counters", function()
	local a, apiA = start(true); local b, apiB = start(true)
	apiA.SetFast(true); a.behavior = { noPaint = true }; b.behavior = { noPaint = true }
	add(a, apiA, 1); add(b, apiB, 2); a.step(1); b.step(1)
	assert(apiA ~= apiB and a.player ~= b.player)
	assert(apiA.GetStats().MaxPerProvince == 6 and apiB.GetStats().MaxPerProvince == 2)
	assert(apiA.GetStats().Selected == 1 and apiB.GetStats().Selected == 2)
	for _, call in ipairs(a.calls) do assert(call.remote == a.remote) end
	for _, call in ipairs(b.calls) do assert(call.remote == b.remote) end
	apiA.Clear(); assert(apiB.GetStats().Selected == 2)
	apiA.Destroy(); apiB.Destroy(); a.step(1); b.step(1)
end)

test("public loader fetches the exact path and starts the complete local UI", function()
	local world = Mock.new(true)
	local downloads = 0
	world.env.game.HttpGet = function(_, url, flag)
		assert(url == "https://raw.githubusercontent.com/said2201010191-cmd/AutoPainter/main/AutoPainterFinal.luau" and flag == true)
		downloads += 1
		return SOURCE
	end
	world.env.loadstring = function(source, name)
		local chunk, err = loadstring(source, name)
		if chunk then setfenv(chunk, world.env) end
		return chunk, err
	end
	local api = world.load(LOADER_SOURCE)
	assert(downloads == 1 and api.GetStats().Running and world.playerGui:FindFirstChild("AutoPainterFinalUI"))
	add(world, api, 1); world.step(1); assert(api.GetStats().Observed == 1)
	api.Destroy()
end)

