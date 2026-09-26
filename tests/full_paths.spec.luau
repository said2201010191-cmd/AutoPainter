-- Exercises the actual production collector; injected source is never executed.
local function fullFixture(deferred)
	local world, api = sourceFixture(deferred)
	local originalGame = world.env.game
	local dataModel = world.instance("DataModel"); dataModel.Name = "game"
	dataModel.GetService = originalGame.GetService
	world.env.game = dataModel
	world.workspace.Parent = dataModel
	local players = child(world, "Players", "Players", dataModel)
	world.player.Parent = players
	local roots = { Character = world.character, PlayerGui = world.playerGui, Workspace = world.workspace }
	for _, name in ipairs({ "PlayerScripts", "Backpack" }) do roots[name] = child(world, name, name, world.player) end
	for _, name in ipairs({ "ReplicatedStorage", "ReplicatedFirst", "StarterPlayer", "StarterGui", "StarterPack" }) do
		roots[name] = child(world, name, name, dataModel)
	end
	roots.StarterPlayerScripts = child(world, "StarterPlayerScripts", "StarterPlayerScripts", roots.StarterPlayer)
	roots.Extra = child(world, "Folder", "ExtraControllers", dataModel)
	world.flush()
	local sources, reads = {}, {}
	world.env.decompile = function(object)
		table.insert(reads, object)
		return sources[object] or "return {}"
	end
	forbidExecution(world)
	return world, api, roots, sources, reads
end
local function noGameWrites(world, start)
	for i = start + 1, #world.writeLog do
		local object = world.writeLog[i].object
		assert(object:IsDescendantOf(world.playerGui), "Scan wrote outside its own UI")
	end
end
local function waitForScan(world, api, maximum)
	local untilTime = world.now + (maximum or 30)
	while api.GetDiagnosticScanState().Running and world.now < untilTime do world.step(0.05) end
	assert(not api.GetDiagnosticScanState().Running, "Scan did not terminate")
	noTraffic(world, api)
	return api.GetFullPaintPathsReport()
end
local function scanReport(world, api, mode)
	assert(api.StartDiagnosticScan(mode or "Full"))
	return waitForScan(world, api)
end
local function fullSection(report, index)
	local starts = {
		"1. ALL PAINT/PROVINCE REMOTE CALLS", "2. ALL PaintPart CALL SITES",
		"3. ALL ALTERNATE PROVINCE-MODIFICATION PATHS", "4. ADMIN / PRIVATE / TEST PATHS",
		"5. BATCH / MULTI-TARGET PATHS", "6. STORED-INSTANCE TARGETING PATHS",
		"7. PERMISSION / CAPABILITY / TOKEN STATE", "8. READ FAILURES / COVERAGE GAPS",
		"9. FINAL SUPPORTED CLIENT ROUTES", "SHARED MERGED CONTEXT BLOCKS",
	}
	return protocolSection(report, starts[index], starts[index + 1])
end

for _, deferred in ipairs({ false, true }) do
	local prefix = deferred and "deferred watchdog: " or "immediate watchdog: "

	test(prefix .. "start returns before any enumeration or decompile and copying never starts work", function()
		local world, api, roots, _, reads = fullFixture(deferred)
		child(world, "ModuleScript", "Paint", roots.ReplicatedStorage)
		local enumerations = world.descendantReads
		local spawns = world.taskSpawns
		assert(not api.CopyCurrentReport()); contains(api.GetFullPaintPathsReport(), "NOT_STARTED")
		assert(#reads == 0 and world.descendantReads == enumerations and world.taskSpawns == spawns)
		assert(api.StartDiagnosticScan("Quick"))
		assert(#reads == 0 and world.descendantReads == enumerations)
		waitForScan(world, api); assert(#reads == 1); api.Destroy()
	end)

	test(prefix .. "quick and full buttons cancel and copy are distinct UI actions", function()
		local world, api, roots, _, reads = fullFixture(deferred)
		child(world, "ModuleScript", "Paint", roots.ReplicatedStorage)
		press(world, "Copy Current Report"); assert(#reads == 0)
		press(world, "Quick Paint Path Scan"); waitForScan(world, api); assert(#reads == 1)
		local copied; world.env.setclipboard = function(value) copied = value end
		press(world, "Copy Current Report"); assert(#reads == 1)
		contains(copied, "FullPaintPathsReportFormat=3")
		press(world, "Game-Only Full Scan"); press(world, "CANCEL SCAN"); waitForScan(world, api)
		assert(api.GetDiagnosticScanState().Status:find("CANCELLED"))
		api.Destroy()
	end)

	test(prefix .. "quick scans only relevant high roots full adds remaining and broad roots", function()
		local world, api, roots, _, reads = fullFixture(deferred)
		local relevant = child(world, "ModuleScript", "PaintController", roots.ReplicatedStorage)
		local irrelevant = child(world, "ModuleScript", "Unrelated", roots.PlayerScripts)
		local broad = child(world, "LocalScript", "ProvincePainter", roots.Workspace)
		local quick = scanReport(world, api, "Quick")
		assert(#reads == 1 and reads[1] == relevant)
		contains(quick, "SKIPPED_QUICK"); assert(not quick:find(broad:GetFullName(), 1, true))
		local full = scanReport(world, api, "Full")
		assert(#reads == 3 and reads[2] == irrelevant and reads[3] == broad)
		contains(full, "Cached=true"); contains(full, broad:GetFullName())
		api.Destroy()
	end)

	test(prefix .. "relevance beats non-relevant paths and requested high-root order breaks ties", function()
		local world, api, roots, _, reads = fullFixture(deferred)
		local wanted = {}
		for _, name in ipairs({ "PlayerScripts", "Backpack", "Character", "PlayerGui", "ReplicatedStorage" }) do
			table.insert(wanted, child(world, "ModuleScript", "Paint" .. name, roots[name]))
		end
		local remaining = child(world, "ModuleScript", "AAAA_Unrelated", roots.PlayerScripts)
		local broad = child(world, "ModuleScript", "AAAA_Paint", roots.Workspace)
		scanReport(world, api)
		for i, object in ipairs(wanted) do assert(reads[i] == object) end
		assert(reads[6] == remaining and reads[7] == broad)
		api.Destroy()
	end)

	test(prefix .. "all requested relevance terms and PaintBucket ancestor path qualify", function()
		local world, api, roots, _, reads = fullFixture(deferred)
		local terms = { "Paint", "Province", "Territory", "Country", "Map", "Bucket", "War", "Peace", "Remote", "Admin", "Capture", "Color" }
		for _, term in ipairs(terms) do child(world, "ModuleScript", term:upper(), roots.ReplicatedStorage) end
		child(world, "LocalScript", "LocalScript", world.bucket)
		scanReport(world, api, "Quick")
		assert(#reads == 13); api.Destroy()
	end)

	test(prefix .. "one never-returning decompile times out and later scripts still finish", function()
		local world, api, roots = fullFixture(deferred)
		local bad = child(world, "ModuleScript", "APaintStall", roots.ReplicatedStorage)
		local good = child(world, "ModuleScript", "BPaintGood", roots.ReplicatedStorage)
		local calls = 0
		world.env.decompile = function(object)
			calls += 1
			if object == bad then return coroutine.yield() end
			assert(object == good); return 'r:InvokeServer("PaintPart")'
		end
		local started = world.now
		local report = scanReport(world, api, "Quick")
		local state = api.GetDiagnosticScanState()
		assert(world.now - started >= 6 and world.now - started < 7)
		assert(calls == 2 and state.TimedOut == 1 and state.TextReturned == 1 and state.Outstanding == 1)
		contains(report, bad:GetFullName() .. " ClassName=ModuleScript Status=TIMED_OUT")
		contains(report, "PaintPart")
		assert(state.LastTimeout == bad:GetFullName())
		api.Destroy()
	end)

	test(prefix .. "two permanently stalled calls exhaust cap and finish report with explicit skipped rows", function()
		local world, api, roots = fullFixture(deferred)
		for i = 1, 20 do child(world, "ModuleScript", string.format("Paint%02d", i), roots.ReplicatedStorage) end
		local calls = 0
		world.env.decompile = function() calls += 1; return coroutine.yield() end
		local report = scanReport(world, api, "Quick")
		local state = api.GetDiagnosticScanState()
		assert(calls == 2 and state.Outstanding == 2 and state.TimedOut == 2 and state.Skipped == 18)
		contains(report, "SKIPPED_CAPACITY")
		for _ = 1, 5 do scanReport(world, api, "Full") end
		assert(calls == 2 and api.GetDiagnosticScanState().Outstanding == 2)
		noTraffic(world, api); api.Destroy()
	end)

	test(prefix .. "progress exposes exact stalled path counts and partial report remains copyable", function()
		local world, api, roots = fullFixture(deferred)
		local bad = child(world, "ModuleScript", "PaintExactPath", roots.ReplicatedStorage)
		world.env.decompile = function() return coroutine.yield() end
		assert(api.StartDiagnosticScan("Quick")); world.step(0.5)
		local label
		for _, object in ipairs(world.objects) do if object.Name == "ScanProgress" then label = object end end
		contains(label.Text, "Scripts discovered: 1"); contains(label.Text, "Current script: 1/1")
		for _, field in ipairs({ "Text returned:", "Failed:", "Timed out:", "Skipped:", "Current path:" }) do contains(label.Text, field) end
		contains(label.Text, bad:GetFullName())
		local copied; world.env.setclipboard = function(value) copied = value end
		assert(api.CopyCurrentReport()); contains(copied, "Status=PENDING")
		assert(api.GetDiagnosticScanState().Running)
		waitForScan(world, api)
		contains(label.Text, "Timed out: 1"); contains(label.Text, "Last timed out: " .. bad:GetFullName())
		api.Destroy()
	end)

	test(prefix .. "cancel stops additional reads immediately and resume uses completed cache", function()
		local world, api, roots = fullFixture(deferred)
		local a = child(world, "ModuleScript", "PaintA", roots.ReplicatedStorage)
		local b = child(world, "ModuleScript", "PaintB", roots.ReplicatedStorage)
		local c = child(world, "ModuleScript", "PaintC", roots.ReplicatedStorage)
		local calls, worker = {}, nil
		world.env.decompile = function(object)
			calls[object] = (calls[object] or 0) + 1
			if object == b then worker = coroutine.running(); return coroutine.yield() end
			return "PaintPart"
		end
		assert(api.StartDiagnosticScan("Quick")); world.step(0.5)
		assert(calls[a] == 1 and calls[b] == 1 and not calls[c])
		assert(api.CancelDiagnosticScan()); waitForScan(world, api)
		assert(not calls[c] and api.GetDiagnosticScanState().Outstanding == 1)
		assert(coroutine.resume(worker, "PaintPart"))
		scanReport(world, api, "Quick")
		assert(calls[a] == 1 and calls[b] == 1 and calls[c] == 1)
		assert(api.GetDiagnosticScanState().Cached == 2)
		api.Destroy()
	end)

	test(prefix .. "cancel before queued coordinator begins invokes no decompiler", function()
		local world, api, roots, _, reads = fullFixture(deferred)
		child(world, "ModuleScript", "Paint", roots.ReplicatedStorage)
		assert(api.StartDiagnosticScan("Quick")); api.CancelDiagnosticScan()
		waitForScan(world, api); assert(#reads == 0); api.Destroy()
	end)

	test(prefix .. "repeated starts and cancels cannot multiply coordinators or stalled workers", function()
		local world, api, roots = fullFixture(deferred)
		child(world, "ModuleScript", "PaintA", roots.ReplicatedStorage)
		child(world, "ModuleScript", "PaintB", roots.ReplicatedStorage)
		local calls = 0
		world.env.decompile = function() calls += 1; return coroutine.yield() end
		assert(api.StartDiagnosticScan("Quick")); world.step(0.3)
		for _ = 1, 100 do assert(not api.StartDiagnosticScan("Full")) end
		api.CancelDiagnosticScan()
		for _ = 1, 10 do assert(not api.StartDiagnosticScan("Full")) end
		waitForScan(world, api)
		scanReport(world, api, "Quick")
		assert(calls == 2 and api.GetDiagnosticScanState().Outstanding == 2)
		api.Destroy()
	end)

	test(prefix .. "late return releases only its own slot and cached result prevents another decompile", function()
		local world, api, roots = fullFixture(deferred)
		child(world, "ModuleScript", "PaintA", roots.ReplicatedStorage)
		local worker, calls = nil, 0
		world.env.decompile = function() calls += 1; worker = coroutine.running(); return coroutine.yield() end
		scanReport(world, api, "Quick")
		assert(api.GetDiagnosticScanState().Outstanding == 1)
		assert(coroutine.resume(worker, "PaintPart"))
		assert(api.GetDiagnosticScanState().Outstanding == 0)
		local report = scanReport(world, api, "Quick")
		assert(calls == 1 and api.GetDiagnosticScanState().Cached == 1)
		contains(report, "Late decompile result recovered")
		assert(api.GetDiagnosticScanState().TextReturned == 1)
		api.Destroy()
	end)

	test(prefix .. "capacity-skipped scripts become eligible after outstanding calls actually return", function()
		local world, api, roots = fullFixture(deferred)
		for i = 1, 4 do child(world, "ModuleScript", "Paint" .. i, roots.ReplicatedStorage) end
		local workers, calls = {}, 0
		world.env.decompile = function()
			calls += 1
			if calls <= 2 then table.insert(workers, coroutine.running()); return coroutine.yield() end
			return "PaintPart"
		end
		scanReport(world, api, "Quick"); assert(calls == 2)
		assert(coroutine.resume(workers[1], "PaintPart"))
		local report = scanReport(world, api, "Quick")
		assert(calls == 4 and api.GetDiagnosticScanState().TextReturned == 3)
		contains(report, "TIMED_OUT")
		assert(coroutine.resume(workers[2], "PaintPart"))
		api.Destroy()
	end)

	test(prefix .. "read errors invalid returns and unavailable capability are explicit without blocking", function()
		local world, api, roots = fullFixture(deferred)
		for _, name in ipairs({ "PaintA", "PaintB", "PaintC", "PaintD", "PaintE" }) do child(world, "ModuleScript", name, roots.ReplicatedStorage) end
		world.env.decompile = function(object)
			if object.Name == "PaintA" then error("read failure") end
			if object.Name == "PaintB" then return "" end
			if object.Name == "PaintC" then return "\255" end
			if object.Name == "PaintD" then return {} end
			return "PaintPart"
		end
		local report = scanReport(world, api, "Quick")
		assert(api.GetDiagnosticScanState().Failed == 4 and api.GetDiagnosticScanState().TextReturned == 1)
		contains(report, "read failure")
		world.env.decompile = function() error("cached successes and failures must not re-read") end
		scanReport(world, api, "Quick"); assert(api.GetDiagnosticScanState().Cached == 5)
		local more = child(world, "ModuleScript", "PaintF", roots.ReplicatedStorage)
		world.env.decompile = nil
		contains(scanReport(world, api, "Quick"), more:GetFullName() .. " ClassName=ModuleScript Status=SKIPPED_UNAVAILABLE")
		api.Destroy()
	end)

	test(prefix .. "all requested roots and modules inspected once in full scan", function()
		local world, api, roots, _, reads = fullFixture(deferred)
		local total = 0
		for name, root in pairs(roots) do
			for _, class in ipairs({ "LocalScript", "ModuleScript" }) do child(world, class, name .. class, root); if name ~= "Extra" then total += 1 end end
		end
		local report = scanReport(world, api)
		assert(#reads == total and api.GetDiagnosticScanState().Discovered == total)
		local seen = {}; for _, object in ipairs(reads) do assert(not seen[object]); seen[object] = true end
		contains(report, "ClassName=ModuleScript"); contains(report, "ClassName=LocalScript")
		api.Destroy()
	end)

	test(prefix .. "metadata roots enumeration errors exclusions and duplicate paths are explicit", function()
		local world, api, roots, _, reads = fullFixture(deferred)
		roots.PlayerScripts:Destroy(); roots.StarterPlayerScripts:Destroy()
		world.childrenError = roots.ReplicatedStorage
		child(world, "ModuleScript", "Hidden", roots.ReplicatedStorage)
		child(world, "LocalScript", "Same", roots.Character); child(world, "LocalScript", "Same", roots.Character)
		child(world, "Script", "Excluded", roots.Workspace)
		child(world, "ModuleScript", "Excluded", child(world, "Folder", "CoreGui", world.env.game))
		local report = scanReport(world, api)
		assert(#reads == 2 and reads[1] ~= reads[2])
		contains(report, "LocalPlayer.PlayerScripts: absent/not replicated")
		contains(report, "StarterPlayer.StarterPlayerScripts: absent/not replicated")
		contains(report, "ReplicatedStorage: GetChildren failed")
		contains(report, "Excluded: CorePackages, CoreGui")
		api.Destroy()
	end)

	test(prefix .. "all requested keywords and multiline remote syntax retain context and nine sections", function()
		local world, api, roots, sources = fullFixture(deferred)
		local terms = { "PaintPart", "ServerControls", "ClientControls", "InvokeServer", "FireServer", "InvokeClient", "FireClient",
			"Province", "Provinces", "PaintBucket", "PaintBucketColor", "Peace", "War", "IsBannable", "RemotesReady",
			"admin", "developer", "private server", "test mode", "batch", "multi", "ownership", "capture", "paint", "color" }
		local lines = {}
		for i, term in ipairs(terms) do lines[i * 40] = string.upper(term) end
		lines[1010] = 'a:InvokeServer("PaintPart"); b:FireServer("PaintPart")'
		lines[1040] = 'c.InvokeClient(c, player); d["FireClient"](d, player)'
		lines[1070] = 'local f = q.FireServer'
		local source = protocolLines(1100, lines) .. '\nr:' .. string.rep('\n', 20) .. 'InvokeServer' .. string.rep('\n', 20) .. '("capture")'
		sources[child(world, "ModuleScript", "PaintSource", roots.ReplicatedStorage)] = source
		local report = scanReport(world, api, "Quick")
		for i, term in ipairs(terms) do contains(report, "* L" .. i * 40 .. " | " .. string.upper(term)) end
		for i = 1, 9 do assert(#fullSection(report, i) > 10) end
		contains(fullSection(report, 1), "METHOD REFERENCE / alias candidate")
		assert(occurrences(fullSection(report, 2), "Context=") == 3)
		contains(report, "SourceBytes=" .. #source)
		contains(report, "A stored/off-cursor route: UNRESOLVED")
		api.Destroy()
	end)

	test(prefix .. "context windows merge and unique per-script block IDs prevent collisions across cache", function()
		local world, api, roots, sources = fullFixture(deferred)
		for _, name in ipairs({ "PaintA", "PaintB" }) do
			sources[child(world, "ModuleScript", name, roots.ReplicatedStorage)] = protocolLines(100, { [20] = "PaintPart", [25] = "Color" })
		end
		local report = scanReport(world, api, "Quick")
		contains(report, "Lines=L12-L37")
		assert(occurrences(report, "* L20 | PaintPart") == 2)
		for id in report:gmatch("Context=(S%d+%.F%d+)") do contains(report, "[" .. id .. "]") end
		local again = scanReport(world, api, "Full")
		assert(occurrences(again, "* L20 | PaintPart") == 2)
		api.Destroy()
	end)

	test(prefix .. "collector source text is inert and writes only owned progress UI", function()
		local world, api, roots, sources = fullFixture(deferred)
		sources[child(world, "ModuleScript", "PaintTrap", roots.ReplicatedStorage)] =
			'require(script.Parent.X)\nr:FireServer("PaintPart")\nplayer:SetAttribute("token", 1)\npart.Color = color\nerror("MUST NOT RUN")'
		world.flush()
		local writes, attributes, connections = #world.writeLog, world.attributeWrites, world.connections
		local report = scanReport(world, api, "Quick"); contains(report, "MUST NOT RUN")
		noGameWrites(world, writes)
		assert(world.attributeWrites == attributes and world.connections == connections)
		api.Destroy()
	end)

	test(prefix .. "report snapshot copy is separate from scan and supports file fallback", function()
		local world, api, roots, _, reads = fullFixture(deferred)
		child(world, "ModuleScript", "Paint", roots.ReplicatedStorage)
		scanReport(world, api, "Quick")
		local expected = api.GetFullPaintPathsReport()
		local saved
		world.env.setclipboard = function() error("denied") end
		world.env.writefile = function(path, text) assert(path == "CLIENT_PAINT_PATHS_FULL_REPORT.txt"); saved = text end
		assert(api.CopyCurrentReport()); assert(saved == expected and #reads == 1)
		world.env.writefile = function() error("disk") end
		assert(not api.CopyCurrentReport()); assert(#reads == 1)
		api.Destroy()
	end)

	test(prefix .. "copy during stalled inspection does not wait or invoke more code", function()
		local world, api, roots = fullFixture(deferred)
		child(world, "ModuleScript", "Paint", roots.ReplicatedStorage)
		local calls = 0; world.env.decompile = function() calls += 1; return coroutine.yield() end
		assert(api.StartDiagnosticScan("Quick")); world.step(0.5)
		local copied = 0; world.env.setclipboard = function() copied += 1 end
		for _ = 1, 50 do assert(api.CopyCurrentReport()) end
		assert(calls == 1 and copied == 50 and api.GetDiagnosticScanState().Running)
		api.CancelDiagnosticScan(); waitForScan(world, api); api.Destroy()
	end)

	test(prefix .. "destroy retains a reload guard until outstanding worker really returns", function()
		local world, api, roots = fullFixture(deferred)
		child(world, "ModuleScript", "Paint", roots.ReplicatedStorage)
		local worker; world.env.decompile = function() worker = coroutine.running(); return coroutine.yield() end
		assert(api.StartDiagnosticScan("Quick")); world.step(0.5)
		api.Destroy(); world.step(0.1)
		local ui = world.playerGui:FindFirstChild("AutoPainterFinalUI")
		assert(ui and ui.Enabled == false and world.connections == 0)
		local ok, problem = pcall(function() world.load(SOURCE, { LockDiagnostics = true }) end)
		assert(not ok); contains(tostring(problem), "still outstanding")
		assert(coroutine.resume(worker, "PaintPart")); world.flush()
		assert(world.playerGui:FindFirstChild("AutoPainterFinalUI") == nil)
		assert(api.GetDiagnosticScanState().Outstanding == 0)
	end)

	test(prefix .. "completed cache survives cancellation during indexing without re-decompile", function()
		local world, api, roots, sources, reads = fullFixture(deferred)
		sources[child(world, "ModuleScript", "PaintLarge", roots.ReplicatedStorage)] = protocolLines(6000, { [5900] = "PaintPart" })
		assert(api.StartDiagnosticScan("Quick"))
		while #reads == 0 do world.step(0.02) end
		api.CancelDiagnosticScan(); waitForScan(world, api)
		local report = scanReport(world, api, "Quick")
		assert(#reads == 1); contains(report, "* L5900 | PaintPart")
		api.Destroy()
	end)

	test(prefix .. "respawn and destroyed scripts are reported safely and new instances do not inherit cache", function()
		local world, api, roots = fullFixture(deferred)
		local old = child(world, "LocalScript", "PaintOld", world.bucket)
		local worker, calls = nil, 0
		world.env.decompile = function() calls += 1; worker = coroutine.running(); return coroutine.yield() end
		assert(api.StartDiagnosticScan("Quick")); world.step(0.5)
		roots.Character.Parent = nil; world.equip(); world.flush()
		assert(coroutine.resume(worker, "PaintPart"))
		local report = waitForScan(world, api); contains(report, "SKIPPED_SCOPE")
		child(world, "LocalScript", "PaintOld", world.bucket)
		world.env.decompile = function() calls += 1; return "PaintPart" end
		scanReport(world, api, "Quick"); assert(calls == 2)
		noTraffic(world, api); api.Destroy()
	end)

	test(prefix .. "large corpus resumes from cache without new workers or connections", function()
		local world, api, roots, _, reads = fullFixture(deferred)
		for i = 1, 300 do child(world, "ModuleScript", "Paint" .. i, roots.ReplicatedStorage) end
		local connections = world.connections
		scanReport(world, api, "Quick")
		local tasks = world.taskSpawns
		scanReport(world, api, "Full")
		assert(#reads == 300 and world.taskSpawns == tasks and world.connections == connections)
		assert(api.GetDiagnosticScanState().Cached == 300)
		api.Destroy(); world.flush(); assert(world.connections == 0)
	end)

	test(prefix .. "no match and quick coverage are not interpreted as proof of no supported paths", function()
		local world, api, roots = fullFixture(deferred)
		child(world, "ModuleScript", "PaintNoMatches", roots.ReplicatedStorage)
		local report = scanReport(world, api, "Quick")
		contains(report, "No indexed matching text yet; not proof of absence.")
		contains(report, "QUICK scope:")
		contains(report, "UNRESOLVED")
		api.Destroy()
	end)

	test(prefix .. "metadata inspection remains decompile-free during stalled scan", function()
		local world, api, roots = fullFixture(deferred)
		child(world, "ModuleScript", "Paint", roots.ReplicatedStorage)
		local calls = 0; world.env.decompile = function() calls += 1; return coroutine.yield() end
		assert(api.StartDiagnosticScan("Quick")); world.step(0.5)
		contains(api.GetDiagnosticReport(), "PAINTBUCKET DESCENDANTS")
		assert(calls == 1)
		contains(api.GetProtocolReport(), "Status=busy"); contains(api.GetLocalScriptReport(), "Status=busy")
		api.CancelDiagnosticScan(); waitForScan(world, api); api.Destroy()
	end)

	test(prefix .. "narrow inspection shares outstanding cap and cannot multiply stalled calls", function()
		local world, api, roots = fullFixture(deferred)
		child(world, "ModuleScript", "PaintA", roots.ReplicatedStorage)
		child(world, "ModuleScript", "PaintB", roots.ReplicatedStorage)
		local calls = 0; world.env.decompile = function() calls += 1; return coroutine.yield() end
		scanReport(world, api, "Quick")
		child(world, "LocalScript", "LocalScript", world.bucket)
		local report = api.GetLocalScriptReport()
		contains(report, "SKIPPED_CAPACITY"); assert(calls == 2)
		api.Destroy()
	end)

	test(prefix .. "locked selection randomization clear and remote replacement never create paint calls", function()
		local world, api, roots = fullFixture(deferred)
		child(world, "ModuleScript", "Paint", roots.ReplicatedStorage)
		world.env.decompile = function() return coroutine.yield() end
		assert(api.StartDiagnosticScan("Quick")); world.step(0.5)
		local part = world.province(); api.AddProvince(part); api.CommitSelections()
		api.SetFast(true); api.SetColor(world.Color3.new(1, 0, 0)); api.SetPainting(true)
		world.remote:Destroy(); child(world, "RemoteFunction", "ServerControls", world.remotes)
		api.RemoveProvince(part); api.Clear(); world.step(0.1)
		noTraffic(world, api)
		api.CancelDiagnosticScan(); waitForScan(world, api); api.Destroy()
	end)

	test(prefix .. "invalid mode unlocked and closed entry points start no inspection", function()
		local world, api, roots, _, reads = fullFixture(deferred)
		assert(not api.StartDiagnosticScan("invalid"))
		assert(not api.CancelDiagnosticScan()); assert(not api.CopyCurrentReport())
		assert(#reads == 0); api.Destroy()
		assert(not api.StartDiagnosticScan("Quick")); assert(not api.CopyCurrentReport())
		contains(api.GetFullPaintPathsReport(), "Status=closed")
		local other, unlocked = diagnosticStart(deferred)
		assert(not unlocked.StartDiagnosticScan("Quick")); assert(not unlocked.CopyCurrentReport())
		contains(unlocked.GetFullPaintPathsReport(), "Status=refused"); unlocked.Destroy()
	end)

	test(prefix .. "copy fallback is suppressed after close during clipboard yield", function()
		local world, api, roots = fullFixture(deferred)
		child(world, "ModuleScript", "Paint", roots.ReplicatedStorage)
		scanReport(world, api, "Quick")
		local worker, files = nil, 0
		world.env.setclipboard = function() worker = coroutine.running(); coroutine.yield(); error("denied") end
		world.env.writefile = function() files += 1 end
		press(world, "Copy Current Report")
		api.Destroy(); world.flush(); assert(coroutine.resume(worker)); world.flush()
		assert(files == 0 and world.connections == 0)
	end)

	test(prefix .. "version six panel is refused before invoking its old controller", function()
		local world, api = sourceFixture(deferred)
		local ui = world.playerGui:FindFirstChild("AutoPainterFinalUI")
		ui:SetAttribute("AutoPainterDiagnosticsVersion", 6)
		local called = false; ui:FindFirstChild("Controller").OnInvoke = function() called = true end
		assert(not pcall(function() world.load(SOURCE, { LockDiagnostics = true }) end))
		assert(not called); api.Destroy()
	end)
	test(prefix .. "cancel also stops optional narrow source inspection without freeing an outstanding slot", function()
		local world, api = sourceFixture(deferred)
		child(world, "LocalScript", "A", world.bucket); child(world, "LocalScript", "B", world.bucket)
		local worker, calls = nil, 0
		world.env.decompile = function() calls += 1; worker = coroutine.running(); return coroutine.yield() end
		press(world, "Inspect source")
		assert(api.CancelDiagnosticScan()); world.step(0.1)
		assert(calls == 1 and api.GetDiagnosticScanState().Outstanding == 1)
		assert(coroutine.resume(worker, "PaintPart")); world.step(0.1)
		assert(calls == 1 and api.GetDiagnosticScanState().Outstanding == 0)
		noTraffic(world, api); api.Destroy()
	end)

end
