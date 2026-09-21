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
	return parts
end

for _, deferred in ipairs({ false, true }) do
	local prefix = deferred and "deferred: " or "immediate: "
	test(prefix .. "distinct work, deduplication, FIFO fairness and idle silence", function()
		local world, api = start(deferred)
		local parts = add(world, api, 100)
		assert(not api.AddProvince(parts[1]))
		world.step(2)
		local stats = api.GetStats()
		assert(stats.Attempted == 100 and stats.Returned == 100 and stats.Observed == 100)
		assert(stats.InFlight == 0 and stats.Ready == 0 and stats.Delayed == 0)
		for index, call in ipairs(world.calls) do assert(call.part == parts[index], "FIFO order") end
		assert(world.peak <= 8)
		world.step(10)
		assert(#world.calls == 100, "Idle provinces generated traffic")
		api.Destroy(); world.flush(); assert(world.connections == 0)
	end)
	test(prefix .. "delayed replication avoids duplicate RPCs", function()
		local world, api = start(deferred)
		world.behavior = { latency = 0.1, replicationDelay = 0.06 }
		add(world, api, 60); world.step(3)
		assert(api.GetStats().Attempted == 60 and api.GetStats().Observed == 60)
		assert(api.GetStats().Unconfirmed == 0)
		api.Destroy()
	end)
	test(prefix .. "latest color wins and original Keep Territory Color semantics", function()
		local world, api = start(deferred)
		world.behavior = { latency = 0.4 }
		local part = add(world, api, 1)[1]; world.step(0.02)
		local red, blue = world.Color3.new(1, 0, 0), world.Color3.new(0, 0, 1)
		api.SetColor(red); api.SetColor(blue)
		world.step(2)
		assert(part.Color == blue and #world.calls == 2)
		api.SetKeepColor(true); world.step(1)
		assert(part.Color == world.Color3.new(1, 1, 1))
		api.SetColor(red); world.step(1); assert(#world.calls == 3)
		api.SetKeepColor(false); world.step(1); assert(part.Color == red)
		api.Destroy()
	end)
	test(prefix .. "clear and re-add cannot bypass in-flight deduplication", function()
		local world, api = start(deferred)
		world.behavior = { latency = 0.4 }
		local part = add(world, api, 1)[1]; world.step(0.02)
		api.Clear(); assert(api.GetStats().Selected == 0 and api.GetStats().InFlight == 1)
		api.SetColor(world.Color3.new(1, 0, 0)); api.AddProvince(part)
		world.step(0.2); assert(#world.calls == 1)
		world.step(1); assert(#world.calls == 2 and world.peak == 1)
		assert(part.Color == world.Color3.new(1, 0, 0))
		api.Destroy()
	end)
	test(prefix .. "errors release capacity, back off and recover", function()
		local world, api = start(deferred)
		world.behavior = { errors = true, latency = 0.05 }
		add(world, api, 40); world.step(6)
		assert(api.GetStats().Failures > 0 and api.GetStats().InFlight <= 8)
		assert(api.GetStats().Window < 8, "Error feedback did not reduce the window")
		assert(#world.calls < 240, "Retries did not back off")
		world.behavior = {}; world.step(9)
		assert(api.GetStats().Observed == 40 and api.GetStats().InFlight == 0)
		api.Destroy()
	end)
	test(prefix .. "returned calls without paint are not counted as paint", function()
		local world, api = start(deferred)
		world.behavior = { noPaint = true }; add(world, api, 20); world.step(8)
		local stats = api.GetStats()
		assert(stats.Returned > 20 and stats.Observed == 0 and stats.Unconfirmed >= 20)
		assert(stats.Attempted < 140 and stats.Window < 8)
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
		api.AddProvince(part); world.step(0.3)
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
		assert(#world.calls == 1 and not api.GetStats().RemoteReady)
		world.equip(); world.flush(); world.step(1)
		assert(#world.calls == 2 and world.calls[2].remote == world.remote)
		world.remote:Destroy(); world.flush()
		part.Color = world.Color3.new(0, 0, 0); world.step(0.3); assert(#world.calls == 2)
		local replacement = world.instance("RemoteFunction")
		replacement.Parent = world.remotes; replacement.Name = "ServerControls"
		world.step(2); assert(#world.calls == 3 and world.calls[3].remote == replacement)
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
		api.Clear(); for _, part in ipairs(parts) do api.AddProvince(part) end
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
		world.flush(); assert(api.GetStats().Selected == 25 and api.GetStats().Ready == 25)
		api.SetPainting(true); world.step(2); assert(#world.calls == 25)
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
		if operation == 1 then api.AddProvince(part); selected[part] = true
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
	world.flush(); world.step(1)
	assert(api.GetStats().Selected == 1 and part.Color == samplePart.Color)
	world.input.InputBegan:Fire({ KeyCode = world.env.Enum.KeyCode.Q }, false); world.flush()
	local sent = #world.calls
	world.input.InputBegan:Fire({ KeyCode = world.env.Enum.KeyCode.R }, false); world.flush(); world.step(1)
	assert(#world.calls == sent)
	world.input.InputBegan:Fire({ KeyCode = world.env.Enum.KeyCode.Q }, false); world.flush(); world.step(1)
	assert(#world.calls == sent + 1)
	button("Remove").Activated:Fire(); world.flush(); world.mouse.Target = part
	world.input.InputBegan:Fire({ UserInputType = world.env.Enum.UserInputType.MouseButton1 }, false)
	world.flush(); assert(api.GetStats().Selected == 0)
	button("×").Activated:Fire(); world.flush(); assert(not api.GetStats().Running)
end)
print(string.format("%d tests passed (mock engine; no live throughput claim)", passed))
