-- These tests deliberately load the unmodified default: diagnostics ON.
local function diagnosticStart(deferred, options)
	local world = Mock.new(deferred)
	return world, world.load(SOURCE, options)
end
local function noTraffic(world, api)
	local s = api.GetStats()
	assert(world.networkAttempts == 0 and #world.calls == 0 and world.taskSpawns == 0)
	assert(s.Attempted == 0 and s.InFlight == 0 and s.Failures == 0 and s.Returned == 0)
	assert(s.Ready == 0 and s.Delayed == 0 and s.Suppressed == 0)
end
local function contains(text, value) assert(string.find(text, value, 1, true), "Missing report detail: " .. value) end
local function installLoaderMock(world)
	local downloads = 0
	world.env.game.HttpGet = function(_, url, flag)
		assert(url == "https://raw.githubusercontent.com/said2201010191-cmd/AutoPainter/main/AutoPainterFinal.luau" and flag == true)
		downloads += 1; return SOURCE
	end
	world.env.loadstring = function(source, name)
		local chunk, err = loadstring(source, name)
		if chunk then setfenv(chunk, world.env) end
		return chunk, err
	end
	return function() return downloads end
end

for _, deferred in ipairs({ false, true }) do
	local prefix = deferred and "deferred diagnostics: " or "immediate diagnostics: "
	test(prefix .. "default UI Add, Done and first Safe enable sequence remain zero traffic", function()
		local world, api = diagnosticStart(deferred)
		assert(api.GetStats().DiagnosticOnly and not api.GetStats().DiagnosticLocked)
		world.bucket.Parent = nil; world.flush()
		key(world, "Q"); press(world, "Add"); selectMany(world, 20); finishSelection(world, api)
		world.bucket.Parent = world.character; world.flush()
		api.SetSafe(true); key(world, "Q"); world.step(30)
		assert(api.GetStats().Painting and api.GetStats().CommittedSelections == 20 and api.GetStats().PendingSelections == 0)
		assert(api.GetStats().RemoteReady); noTraffic(world, api)
		api.Destroy(); world.flush(); assert(world.connections == 0)
	end)

	test(prefix .. "Q, R, Fast, Safe, Keep and repeated commits cannot escape diagnostics", function()
		local world, api = diagnosticStart(deferred)
		press(world, "Add"); local parts = selectMany(world, 20); finishSelection(world, api)
		for i = 1, 30 do
			key(world, "Q"); key(world, "R"); api.SetFast(i % 2 == 0); api.SetSafe(i % 3 == 0)
			api.SetKeepColor(i % 2 == 1); parts[1].Color = api.GetColor(); world.flush()
			api.CommitSelections(); world.step(0.1)
		end
		noTraffic(world, api); assert(api.GetStats().DiagnosticOnly)
		api.Destroy()
	end)

	test(prefix .. "snapshot resolves fresh path and reports actual Tool/Humanoid state", function()
		local world, api = diagnosticStart(deferred)
		local humanoid = world.instance("Humanoid"); humanoid.Name = "Humanoid"; humanoid.Parent = world.character
		humanoid.Health = 75; humanoid.Sit = false; humanoid.PlatformStand = false
		world.bucket.Enabled = false; world.bucket.RequiresHandle = true; world.bucket.ManualActivationOnly = false
		local handle = world.instance("Part"); handle.Name = "Handle"; handle.Parent = world.bucket
		local report = api.GetDiagnosticReport()
		contains(report, "Remote path resolves=true"); contains(report, "Same=true")
		contains(report, "Tool parent is current Character=true")
		contains(report, "Enabled=false RequiresHandle=true ManualActivationOnly=false")
		contains(report, "Health=75 Sit=false PlatformStand=false"); contains(report, "Humanoid state=Running")
		contains(report, "normal tool protocol UNVERIFIED"); contains(report, "not a server-readiness check")
		noTraffic(world, api); api.Destroy()
	end)

	test(prefix .. "missing character, absent tool, backpack tool and wrong remote class are distinguished", function()
		local world, api = diagnosticStart(deferred)
		local backpack = world.instance("Backpack"); backpack.Parent = world.player
		world.bucket.Parent = backpack; world.flush()
		local report = api.GetDiagnosticReport()
		contains(report, "Equipped hierarchy: <missing>"); contains(report, "Backpack hierarchy (not equipped)")
		contains(report, "Remote path resolves=false"); assert(not api.GetStats().RemoteReady)
		world.bucket.Parent = world.character; world.flush(); world.remote:Destroy(); world.flush()
		local wrong = world.instance("RemoteEvent"); wrong.Name = "ServerControls"; wrong.Parent = world.remotes; world.flush()
		report = api.GetDiagnosticReport(); contains(report, "[RemoteEvent]"); contains(report, "Remote path resolves=false")
		world.player.Character = nil; world.flush()
		report = api.GetDiagnosticReport(); contains(report, "Character summary: <missing>"); contains(report, "Humanoid summary: <missing>")
		world.step(2); noTraffic(world, api); api.Destroy()
	end)

	test(prefix .. "respawn and remote replacement refresh diagnostics without activating committed work", function()
		local world, api = diagnosticStart(deferred); add(world, api, 100)
		world.player.Character = nil; world.flush(); world.equip(); world.flush()
		world.remote:Destroy(); world.flush()
		local replacement = world.instance("RemoteFunction"); replacement.Name = "ServerControls"; replacement.Parent = world.remotes
		world.flush(); world.step(20)
		contains(api.GetDiagnosticReport(), "Remote path resolves=true")
		assert(api.GetStats().CommittedSelections == 100); noTraffic(world, api); api.Destroy()
	end)

	test(prefix .. "state inventory reports candidate values/scripts without executing or modifying them", function()
		local world, api = diagnosticStart(deferred)
		local selected = world.instance("Color3Value"); selected.Name = "SelectedColor"; selected.Value = world.Color3.new(0.2, 0.4, 0.6); selected.Parent = world.bucket
		local localScript = world.instance("LocalScript"); localScript.Name = "BucketClient"; localScript.Enabled = true; localScript.Parent = world.bucket
		local module = world.instance("ModuleScript"); module.Name = "PaintLogic"; module.Parent = world.bucket
		local extra = world.instance("RemoteEvent"); extra.Name = "ClientState"; extra.Parent = world.remotes
		world.bucket:SetAttribute("Ready", false); world.bucket:SetAttribute("Cooldown", 0.5)
		world.env.require = function() error("Diagnostic executed a game module") end
		local changed = 0; local connection = selected:GetPropertyChangedSignal("Value"):Connect(function() changed += 1 end)
		local report = api.GetDiagnosticReport()
		contains(report, "Value=Color3(0.20000, 0.40000, 0.60000)")
		contains(report, "BucketClient [LocalScript]"); contains(report, "PaintLogic [ModuleScript]")
		contains(report, "ClientState [RemoteEvent]"); contains(report, "@Ready = false"); contains(report, "@Cooldown = 0.5")
		contains(report, "source not read/executed"); contains(report, "Module not required/read")
		assert(changed == 0 and selected.Value == world.Color3.new(0.2, 0.4, 0.6))
		noTraffic(world, api); connection:Disconnect(); api.Destroy()
	end)

	test(prefix .. "strings and numeric credentials are redacted without inventing a session contract", function()
		local world, api = diagnosticStart(deferred)
		world.bucket:SetAttribute("SessionToken", "DO_NOT_EXPORT_ABC")
		world.bucket:SetAttribute("Nonce", 92837465)
		world.bucket:SetAttribute("Mode", "PRIVATE_UNKNOWN_MODE_VALUE")
		local value = world.instance("StringValue"); value.Name = "Secret"; value.Value = "DO_NOT_EXPORT_XYZ"; value.Parent = world.bucket
		local report = api.GetDiagnosticReport()
		contains(report, "@SessionToken = <redacted string>"); contains(report, "@Nonce = <redacted number>")
		contains(report, "@Mode = <string value omitted>")
		for _, hidden in ipairs({ "DO_NOT_EXPORT_ABC", "92837465", "PRIVATE_UNKNOWN_MODE_VALUE", "DO_NOT_EXPORT_XYZ" }) do
			assert(not string.find(report, hidden, 1, true), "Credential/string content leaked")
		end
		noTraffic(world, api); api.Destroy()
	end)

	test(prefix .. "Inspect button shows bounded read-only report; snapshots add no listeners or tasks", function()
		local world, api = diagnosticStart(deferred)
		press(world, "Add"); selectMany(world, 2); finishSelection(world, api)
		local before = world.connections; local spawns, defers = world.taskSpawns, world.taskDefers
		for _ = 1, 20 do press(world, "Inspect") end
		local box
		for _, object in ipairs(world.objects) do if object.Name == "DiagnosticReport" then box = object end end
		assert(box and box.Visible and box.TextEditable == false and box.ClearTextOnFocus == false)
		contains(box.Text, "Selected=2 Pending=0 Committed=2")
		assert(world.connections == before and world.taskSpawns == spawns and world.taskDefers == defers)
		noTraffic(world, api); api.Destroy(); world.flush(); assert(world.connections == 0)
	end)

	test(prefix .. "wide/deep hierarchies and large attributes produce explicitly truncated bounded reports", function()
		local world, api = diagnosticStart(deferred)
		for i = 1, 300 do
			local child = world.instance("Folder"); child.Name = "Node" .. i; child.Parent = world.bucket
			for a = 1, 20 do child:SetAttribute("Flag" .. a, true) end
		end
		local report = api.GetDiagnosticReport()
		local summary = string.split(report, "\n\nPAINTBUCKET DESCENDANTS\n")[1]
		assert(#summary <= 24000)
		contains(summary, "Summary truncated"); contains(report, "more attributes omitted")
		local count = 0; for _ in string.gmatch(summary, "  child:") do count += 1 end
		assert(count <= 95)
		noTraffic(world, api); api.Destroy()
		local deepWorld, deepApi = diagnosticStart(deferred)
		local parent = deepWorld.bucket
		for i = 1, 40 do
			local child = deepWorld.instance("Folder"); child.Name = "Depth" .. i; child.Parent = parent; parent = child
		end
		local deepReport = deepApi.GetDiagnosticReport()
		local deepSummary = string.split(deepReport, "\n\nPAINTBUCKET DESCENDANTS\n")[1]
		contains(deepSummary, "Summary truncated")
		assert(not string.find(deepSummary, "Depth9", 1, true), "Depth bound was not respected")
		noTraffic(deepWorld, deepApi); deepApi.Destroy()
	end)

	test(prefix .. "turning diagnostics on clears unsent queue while real calls retain honest accounting", function()
		local world, api = start(deferred); api.SetFast(true); world.behavior = { noPaint = true, latency = 0.3 }
		add(world, api, 100); world.step(0.02)
		local sent = #world.calls; assert(sent > 0 and api.GetStats().Ready > 0)
		api.SetDiagnostic(true)
		assert(api.GetStats().Ready == 0 and api.GetStats().Delayed == 0 and api.GetStats().InFlight == sent)
		contains(api.GetDiagnosticReport(), "Already-sent operations cannot be canceled")
		world.step(2); assert(#world.calls == sent and api.GetStats().InFlight == 0 and api.GetStats().Returned == sent)
		api.Destroy()
	end)

	test(prefix .. "diagnostics clears error retry timers; exiting leaves paint OFF until explicit resume", function()
		local world, api = start(deferred); world.behavior = { errors = true, latency = 0.05 }
		add(world, api, 1); world.step(0.1); assert(api.GetStats().Delayed > 0)
		api.SetDiagnostic(true); local sent = #world.calls; world.step(3)
		assert(api.GetStats().Delayed == 0 and #world.calls == sent)
		world.behavior = {}; api.SetDiagnostic(false); world.step(1)
		assert(not api.GetStats().DiagnosticOnly and not api.GetStats().Painting and #world.calls == sent)
		key(world, "Q"); world.step(1); assert(#world.calls > sent)
		api.Destroy()
	end)

	test(prefix .. "transport guard suppresses reserved but not-yet-started workers without counting a request", function()
		local world, api = start(deferred); api.SetFast(true)
		local workers = {}
		world.env.task.spawn = function(fn, ...) world.taskSpawns += 1; table.insert(workers, { fn = fn, args = table.pack(...) }) end
		add(world, api, 1); world.step(0.02)
		assert(#workers == 6 and world.networkAttempts == 0 and api.GetStats().InFlight == 6)
		api.SetDiagnostic(true)
		for _, worker in ipairs(workers) do worker.fn(table.unpack(worker.args, 1, worker.args.n)) end
		local s = api.GetStats()
		assert(world.networkAttempts == 0 and s.Attempted == 0 and s.Suppressed == 6 and s.InFlight == 0 and s.PendingProvinces == 0)
		assert(s.Failures == 0 and s.Returned == 0); api.Destroy()
	end)

	test(prefix .. "locked diagnostic loader defaults to zero calls and Q/settings cannot unlock it", function()
		local world = Mock.new(deferred); local downloads = installLoaderMock(world)
		local api = world.load(DIAGNOSTIC_LOADER_SOURCE)
		assert(downloads() == 1 and api.GetStats().DiagnosticOnly and api.GetStats().DiagnosticLocked)
		press(world, "Add"); selectMany(world, 20); finishSelection(world, api)
		press(world, "LOCKED"); assert(not api.SetDiagnostic(false))
		key(world, "Q"); key(world, "Q"); api.SetSafe(true); api.SetFast(true); world.step(30)
		noTraffic(world, api); api.Destroy()
	end)

	test(prefix .. "lock requests cannot create the inconsistent state locked-but-live", function()
		local world, api = start(deferred)
		assert(api.SetDiagnostic(false, true))
		assert(api.GetStats().DiagnosticOnly and api.GetStats().DiagnosticLocked)
		add(world, api, 1); world.step(2); noTraffic(world, api); api.Destroy()
	end)

	test(prefix .. "diagnostic reload pauses current instance without committing pending selection or adding listeners", function()
		local world, api = start(deferred); press(world, "Add"); selectMany(world, 20)
		local baseline = world.connections
		local again = world.load(SOURCE, { DiagnosticOnly = true, LockDiagnostics = true })
		assert(again == api and api.GetStats().SelectionMode == "Add" and api.GetStats().PendingSelections == 20)
		assert(api.GetStats().DiagnosticLocked and world.connections == baseline)
		finishSelection(world, api); world.step(3); noTraffic(world, api); api.Destroy()
	end)

	test(prefix .. "older UI lacking diagnostics is refused without invoking its controller", function()
		local world = Mock.new(deferred)
		local ui = world.instance("ScreenGui"); ui.Name = "AutoPainterFinalUI"; ui.Parent = world.playerGui
		local bridge = world.instance("BindableFunction"); bridge.Name = "Controller"; bridge.Parent = ui
		bridge.OnInvoke = function() error("Older controller must not be invoked") end
		local ok, problem = pcall(function() world.load(SOURCE) end)
		assert(not ok); contains(tostring(problem), "Close the older AutoPainter panel")
		assert(world.networkAttempts == 0 and world.connections == 0); ui:Destroy()
	end)

	test(prefix .. "100 diagnostic sessions/inspections/removal/clear cycles do not grow live state", function()
		local world, api = diagnosticStart(deferred); local baseline = world.connections
		for _ = 1, 100 do
			press(world, "Add"); local parts = selectMany(world, 10); finishSelection(world, api)
			press(world, "Inspect"); api.RemoveProvince(parts[1]); press(world, "Clear")
			assert(world.connections == baseline and api.GetStats().Selected == 0 and api.GetStats().PendingSelections == 0)
		end
		world.step(1); noTraffic(world, api); api.Destroy(); world.flush(); assert(world.connections == 0)
	end)

	test(prefix .. "report tracks committed/pending targets and Keep snapshots without sending paint", function()
		local world, api = diagnosticStart(deferred); api.SetKeepColor(true)
		api.SetColor(world.Color3.new(1, 0, 0)); press(world, "Add"); selectMany(world, 1); finishSelection(world, api)
		api.SetColor(world.Color3.new(0, 0, 1)); press(world, "Add"); selectMany(world, 1)
		local report = api.GetDiagnosticReport()
		contains(report, "Selected=2 Pending=1 Committed=1")
		contains(report, "target=Color3(1.00000, 0.00000, 0.00000)")
		contains(report, "target=Color3(0.00000, 0.00000, 1.00000)")
		key(world, "R"); finishSelection(world, api); noTraffic(world, api); api.Destroy()
	end)
end
