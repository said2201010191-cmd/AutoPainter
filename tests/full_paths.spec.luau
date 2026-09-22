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
	world.env.task.wait = function()
		local thread = coroutine.running()
		world.schedule(0, function()
			local ok, problem = coroutine.resume(thread)
			assert(ok, problem)
		end)
		return coroutine.yield()
	end
	local sources, reads = {}, {}
	world.env.decompile = function(object)
		table.insert(reads, object)
		return sources[object] or "return {}"
	end
	forbidExecution(world)
	return world, api, roots, sources, reads
end
local function noMutation(world, api, writes, attributes, connections)
	assert(world.propertyWrites == writes, "Collector wrote Instance properties")
	assert(world.attributeWrites == attributes, "Collector wrote attributes")
	assert(world.connections == connections, "Collector added connections")
	noTraffic(world, api)
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
	local prefix = deferred and "deferred full paths: " or "immediate full paths: "

	test(prefix .. "all requested roots modules alternative tools and extra controllers inspected once", function()
		local world, api, roots, sources, reads = fullFixture(deferred)
		local wanted, total = {}, 0
		for name, root in pairs(roots) do
			for _, class in ipairs({ "LocalScript", "ModuleScript" }) do
				local object = child(world, class, name .. class, root)
				wanted[object] = true; total += 1; sources[object] = "return {}"
			end
		end
		local alt = child(world, "LocalScript", "PaintAlternate", child(world, "Tool", "OtherTool", roots.Backpack))
		wanted[alt] = true; total += 1
		world.flush()
		local writes, attributes, connections = world.propertyWrites, world.attributeWrites, world.connections
		local report = api.GetFullPaintPathsReport()
		assert(#reads == total)
		for _, object in ipairs(reads) do assert(wanted[object]); wanted[object] = nil end
		assert(next(wanted) == nil)
		contains(report, "EnumeratedUnique=" .. total .. " TextReturned=" .. total .. " ReadFailures=0 NotRead=0")
		contains(report, "CoverageGaps=0")
		contains(report, "ClassName=ModuleScript"); contains(report, "ClassName=LocalScript")
		noMutation(world, api, writes, attributes, connections); api.Destroy()
	end)

	test(prefix .. "excluded server Script and platform containers disclosed without execution", function()
		local world, api, roots, _, reads = fullFixture(deferred)
		for _, name in ipairs({ "ServerScriptService", "ServerStorage", "CoreGui" }) do
			child(world, "ModuleScript", "NotInspected", child(world, "Folder", name, world.env.game))
		end
		child(world, "LocalScript", "OtherPlayer", child(world, "Player", "SomeoneElse", world.player.Parent))
		child(world, "Script", "ServerBranch", roots.ReplicatedStorage)
		local allowed = child(world, "ModuleScript", "Allowed", roots.Workspace)
		local report = api.GetFullPaintPathsReport()
		assert(#reads == 1 and reads[1] == allowed)
		contains(report, "Excluded: CoreGui"); contains(report, "Script class (including RunContext Client)")
		contains(report, "Excluded Script-class observations"); noTraffic(world, api); api.Destroy()
	end)

	test(prefix .. "missing roots and root enumeration failures are explicit", function()
		local world, api, roots = fullFixture(deferred)
		roots.PlayerScripts:Destroy(); roots.StarterPlayerScripts:Destroy()
		world.descendantError = roots.ReplicatedStorage
		child(world, "ModuleScript", "InvisibleToCollector", roots.ReplicatedStorage)
		world.flush()
		local report = api.GetFullPaintPathsReport()
		contains(report, "LocalPlayer.PlayerScripts: absent/not replicated")
		contains(report, "StarterPlayer.StarterPlayerScripts: absent/not replicated")
		contains(report, "ReplicatedStorage: GetDescendants failed")
		contains(report, "ENUMERATION FAILED")
		noTraffic(world, api); api.Destroy()
	end)

	test(prefix .. "additional root discovery failure cannot look like a complete scan", function()
		local world, api = fullFixture(deferred)
		rawset(world.env.game, "GetChildren", function() error("denied") end)
		local report = api.GetFullPaintPathsReport()
		contains(report, "Additional DataModel roots: GetChildren failed; discovery incomplete")
		contains(report, "CoverageGaps=1"); api.Destroy()
	end)

	test(prefix .. "decompile unavailable records every unread candidate", function()
		local world, api, roots = fullFixture(deferred)
		child(world, "ModuleScript", "ModuleA", roots.ReplicatedStorage)
		child(world, "LocalScript", "ClientB", roots.PlayerScripts)
		world.env.decompile = nil
		local report = api.GetFullPaintPathsReport()
		contains(report, "decompile=UNAVAILABLE")
		contains(report, "EnumeratedUnique=2 TextReturned=0 ReadFailures=0 NotRead=2")
		assert(occurrences(report, "Status=NOT_READ: decompile unavailable") == 2)
		noTraffic(world, api); api.Destroy()
	end)

	test(prefix .. "thrown empty invalid UTF8 and non-string failures keep later reads running", function()
		local world, api, roots = fullFixture(deferred)
		for _, name in ipairs({ "A", "B", "C", "D", "E" }) do child(world, "ModuleScript", name, roots.ReplicatedStorage) end
		world.env.decompile = function(object)
			if object.Name == "A" then error("read denied") end
			if object.Name == "B" then return "" end
			if object.Name == "C" then return "\255" end
			if object.Name == "D" then return {} end
			return 'r:InvokeServer("PaintPart")'
		end
		local report = api.GetFullPaintPathsReport()
		contains(report, "read denied")
		contains(report, "EnumeratedUnique=5 TextReturned=1 ReadFailures=4 NotRead=0")
		contains(report, "SourceBytes=unavailable")
		contains(report, "RemoteCallText=1 PaintPartOccurrences=1")
		noTraffic(world, api); api.Destroy()
	end)

	test(prefix .. "all requested keywords indexed including every PaintPart occurrence", function()
		local world, api, roots, sources = fullFixture(deferred)
		local terms = { "PaintPart", "ServerControls", "ClientControls", "InvokeServer", "FireServer", "InvokeClient", "FireClient",
			"Province", "Provinces", "PaintBucket", "PaintBucketColor", "Peace", "War", "IsBannable", "RemotesReady",
			"admin", "developer", "private server", "test mode", "batch", "multi", "ownership", "capture", "paint", "color" }
		local lines = {}; for i, term in ipairs(terms) do lines[i * 40] = string.upper(term) end
		local source = protocolLines(1040, lines)
		sources[child(world, "ModuleScript", "Keywords", roots.ReplicatedStorage)] = source
		local report = api.GetFullPaintPathsReport()
		for i, term in ipairs(terms) do contains(report, "* L" .. i * 40 .. " | " .. string.upper(term)) end
		contains(report, "SourceBytes=" .. #source)
		contains(report, "PaintPartOccurrences=1"); api.Destroy()
	end)

	test(prefix .. "remote call syntax includes colon dot literal-index multiline and repeated calls", function()
		local world, api, roots, sources = fullFixture(deferred)
		sources[child(world, "ModuleScript", "Calls", roots.ReplicatedStorage)] = table.concat({
			'a:InvokeServer("PaintPart"); b:FireServer("PaintPart")',
			'c.InvokeClient(c, player); d["FireClient"](d, player)',
			'e:\nInvokeServer\n("again")',
			'f[\n"FireServer"\n]\n(f, "again")',
			'g:FireAllClients("capture")',
			'local send = h.FireServer\nsend(h, "paint")',
			'-- x:InvokeClient(player) -- textual match only',
		}, "\n")
		local report = api.GetFullPaintPathsReport()
		contains(report, "RemoteCallText=8 PaintPartOccurrences=2")
		contains(fullSection(report, 1), "METHOD REFERENCE / alias candidate")
		contains(fullSection(report, 1), "FireAllClients")
		assert(occurrences(fullSection(report, 2), "Context=F") == 2)
		contains(report, "Comments/strings/dead code can match")
		noTraffic(world, api); api.Destroy()
	end)

	test(prefix .. "nine sections use shared merged context and do not certify permissions", function()
		local world, api, roots, sources = fullFixture(deferred)
		local source = protocolLines(120, {
			[20] = 'if admin and privateServer and testMode then',
			[24] = 'for _, storedPart in ipairs(batchTargets) do',
			[28] = 'r:InvokeServer("PaintPart", {Part = storedPart, Color = color}, "War")',
			[45] = 'local token = capability:GetAttribute("permission")',
			[90] = 'ownership:Capture(province)',
		})
		sources[child(world, "ModuleScript", "Candidate", roots.ReplicatedStorage)] = source
		local report = api.GetFullPaintPathsReport()
		for i = 1, 9 do assert(#fullSection(report, i) > 20) end
		contains(report, "Lines=L12-L57")
		contains(report, "Lines=L82-L102")
		assert(occurrences(report, '* L28 | r:InvokeServer') == 1)
		for id in string.gmatch(report, "Context=(F%d+)") do contains(report, "[" .. id .. "] S") end
		contains(fullSection(report, 9), "A stored/off-cursor route: UNRESOLVED")
		contains(fullSection(report, 9), "B batch/multi-target route: UNRESOLVED")
		contains(fullSection(report, 9), "No route is automatically certified or ruled out")
		noTraffic(world, api); api.Destroy()
	end)

	test(prefix .. "snapshot deterministic for distinct paths independent of enumeration order", function()
		local world, api, roots, sources = fullFixture(deferred)
		for _, name in ipairs({ "Z", "A", "M" }) do
			sources[child(world, "ModuleScript", name, roots.ReplicatedStorage)] = 'r:FireServer("paint")'
		end
		local report = api.GetFullPaintPathsReport()
		world.reverseDescendants = true
		assert(api.GetFullPaintPathsReport() == report)
		api.Destroy()
	end)

	test(prefix .. "identical names remain distinct instances overlapping roots deduplicate instances", function()
		local world, api, roots, _, reads = fullFixture(deferred)
		child(world, "LocalScript", "Duplicate", roots.Character)
		child(world, "LocalScript", "Duplicate", roots.Character)
		local report = api.GetFullPaintPathsReport()
		assert(#reads == 2 and reads[1] ~= reads[2])
		contains(report, "EnumeratedUnique=2 TextReturned=2")
		assert(occurrences(report, "FullName=" .. roots.Character:GetFullName() .. ".Duplicate ClassName=LocalScript") == 2)
		api.Destroy()
	end)

	test(prefix .. "no match does not imply no supported routes and source still counted", function()
		local world, api, roots, sources = fullFixture(deferred)
		sources[child(world, "ModuleScript", "EmptySemantic", roots.ReplicatedStorage)] = "return 123"
		local report = api.GetFullPaintPathsReport()
		contains(report, "SourceBytes=10 RemoteCallText=0 PaintPartOccurrences=0")
		contains(report, "No matching text in returned source; not proof of absence.")
		contains(report, "Late replication"); api.Destroy()
	end)

	test(prefix .. "source cannot execute modules remotes callbacks or property assignments", function()
		local world, api, roots, sources = fullFixture(deferred)
		sources[child(world, "ModuleScript", "DangerousIfExecuted", roots.ReplicatedStorage)] =
			'require(script.Parent.Other)\nremote:FireServer("paint")\npart.Color = color\nplayer:SetAttribute("token", 1)\nerror("execute trap")'
		world.flush()
		local writes, attributes, connections = world.propertyWrites, world.attributeWrites, world.connections
		local spawns, defers = world.taskSpawns, world.taskDefers
		local report = api.GetFullPaintPathsReport()
		contains(report, "execute trap")
		noMutation(world, api, writes, attributes, connections)
		assert(world.taskSpawns == spawns and world.taskDefers == defers)
		api.Destroy()
	end)

	test(prefix .. "UI Full report and copy buttons use exact complete snapshot", function()
		local world, api, roots, sources, reads = fullFixture(deferred)
		sources[child(world, "ModuleScript", "UIAction", roots.ReplicatedStorage)] = protocolLines(800, { [20] = "paint", [780] = "ownership" })
		assert(#reads == 0)
		press(world, "Full Paint Paths Report"); assert(#reads == 1)
		local box = reportWidgets(world); contains(box.Text, "CLIENT_PAINT_PATHS_FULL_REPORT")
		local copied
		world.env.setclipboard = function(value) copied = value end
		press(world, "Copy Full Paint Paths Report")
		assert(#reads == 1)
		contains(copied, "END CLIENT_PAINT_PATHS_FULL_REPORT")
		contains(copied, "* L780 | ownership")
		assert(#copied > #box.Text)
		noTraffic(world, api); api.Destroy()
	end)

	test(prefix .. "one click copy builds report when none exists with file fallback", function()
		local world, api, roots, _, reads = fullFixture(deferred)
		child(world, "ModuleScript", "CopyFirst", roots.ReplicatedStorage)
		local saved
		world.env.writefile = function(path, value) assert(path == "CLIENT_PAINT_PATHS_FULL_REPORT.txt"); saved = value end
		press(world, "Copy Full Paint Paths Report")
		assert(#reads == 1); contains(saved, "CLIENT_PAINT_PATHS_FULL_REPORT")
		noTraffic(world, api); api.Destroy()
	end)

	test(prefix .. "clipboard failure falls back to file and export failures can retry", function()
		local world, api, roots = fullFixture(deferred)
		child(world, "ModuleScript", "Export", roots.ReplicatedStorage)
		world.env.setclipboard = function() error("unavailable") end
		local fileCalls = 0
		world.env.writefile = function() fileCalls += 1; error("disk unavailable") end
		assert(not api.CopyFullPaintPathsReport())
		world.env.writefile = function(path, value) fileCalls += 1; contains(value, "END CLIENT_PAINT_PATHS_FULL_REPORT") end
		assert(api.CopyFullPaintPathsReport()); assert(fileCalls == 2)
		api.Destroy()
	end)

	test(prefix .. "full and PaintBucket reports retain independent export snapshots", function()
		local world, api, roots = fullFixture(deferred)
		child(world, "ModuleScript", "Broad", roots.ReplicatedStorage)
		child(world, "LocalScript", "BucketOnly", world.bucket)
		local full = api.GetFullPaintPathsReport()
		local narrow = api.GetProtocolReport()
		local copied
		world.env.setclipboard = function(value) copied = value end
		assert(api.CopyFullPaintPathsReport()); assert(copied == full)
		assert(api.CopyProtocolReport()); assert(copied == narrow)
		api.Destroy()
	end)

	test(prefix .. "shared busy gate blocks repeated full narrow and export work while decompile yields", function()
		local world, api, roots = fullFixture(deferred)
		child(world, "ModuleScript", "Yielding", roots.ReplicatedStorage)
		local reads, report = 0, nil
		world.env.decompile = function() reads += 1; return coroutine.yield() end
		local worker = coroutine.create(function() report = api.GetFullPaintPathsReport() end)
		assert(coroutine.resume(worker))
		contains(api.GetFullPaintPathsReport(), "Status=busy")
		contains(api.GetProtocolReport(), "Status=busy")
		contains(api.GetLocalScriptReport(), "Status=busy")
		assert(not api.CopyFullPaintPathsReport()); assert(not api.CopyProtocolReport())
		press(world, "Full Paint Paths Report"); assert(reads == 1)
		assert(coroutine.resume(worker, "return {}"))
		contains(report, "TextReturned=1")
		noTraffic(world, api); api.Destroy()
	end)

	test(prefix .. "closing during decompile prevents further reads cache export and stale UI writes", function()
		local world, api, roots = fullFixture(deferred)
		child(world, "ModuleScript", "A", roots.ReplicatedStorage)
		child(world, "ModuleScript", "B", roots.ReplicatedStorage)
		local reads, worker = 0, nil; world.env.decompile = function() reads += 1; worker = coroutine.running(); return coroutine.yield() end
		press(world, "Full Paint Paths Report")
		api.Destroy(); world.flush()
		local writes = world.propertyWrites
		assert(coroutine.resume(worker, "PaintPart"))
		assert(not api.CopyFullPaintPathsReport()); contains(api.GetFullPaintPathsReport(), "Status=closed")
		assert(reads == 1 and world.propertyWrites == writes and world.connections == 0)
	end)

	test(prefix .. "returned source discarded when instance leaves scope during read", function()
		local world, api, roots = fullFixture(deferred)
		local object = child(world, "ModuleScript", "Moving", roots.ReplicatedStorage)
		world.env.decompile = function() return coroutine.yield() end
		local report
		local worker = coroutine.create(function() report = api.GetFullPaintPathsReport() end)
		assert(coroutine.resume(worker)); object.Parent = nil; world.flush()
		assert(coroutine.resume(worker, 'r:FireServer("paint")'))
		contains(report, "text discarded")
		contains(report, "TextReturned=0 ReadFailures=0 NotRead=1")
		api.Destroy()
	end)

	test(prefix .. "respawn new scripts wait for next snapshot and do not enable requests", function()
		local world, api, roots = fullFixture(deferred)
		local old = child(world, "LocalScript", "Old", roots.Character)
		world.env.decompile = function() return coroutine.yield() end
		local report
		local worker = coroutine.create(function() report = api.GetFullPaintPathsReport() end)
		assert(coroutine.resume(worker))
		roots.Character.Parent = nil; world.equip(); child(world, "LocalScript", "New", world.character); world.flush()
		assert(coroutine.resume(worker, "PaintPart"))
		contains(report, "text discarded")
		world.env.decompile = function() return "PaintPart" end
		local nextReport = api.GetFullPaintPathsReport()
		contains(nextReport, ".New ClassName=LocalScript")
		assert(not string.find(nextReport, "FullName=" .. old:GetFullName() .. " ClassName", 1, true))
		noTraffic(world, api); api.Destroy()
	end)

	test(prefix .. "internal failure releases gate and does not export previous report as fresh", function()
		local world, api, roots = fullFixture(deferred)
		child(world, "ModuleScript", "Good", roots.ReplicatedStorage)
		api.GetFullPaintPathsReport()
		local method = roots.ReplicatedStorage.GetDescendants
		rawset(roots.ReplicatedStorage, "GetDescendants", function() return "bad injected API result" end)
		contains(api.GetFullPaintPathsReport(), "Status=inspection failed internally")
		local copied = false; world.env.setclipboard = function() copied = true end
		assert(not api.CopyFullPaintPathsReport()); assert(not copied)
		rawset(roots.ReplicatedStorage, "GetDescendants", method)
		assert(api.CopyFullPaintPathsReport() and copied); api.Destroy()
	end)

	test(prefix .. "large selections source corpus and repeated scans retain no connections or request work", function()
		local world, api, roots, _, reads = fullFixture(deferred)
		for i = 1, 400 do child(world, "ModuleScript", string.format("M%04d", i), roots.ReplicatedStorage) end
		for _ = 1, 100 do api.AddProvince(world.province()) end
		api.CommitSelections(); world.flush()
		local connections = world.connections
		for _ = 1, 3 do
			local report = api.GetFullPaintPathsReport()
			contains(report, "EnumeratedUnique=400 TextReturned=400")
		end
		assert(#reads == 1200 and world.connections == connections)
		noTraffic(world, api); api.Clear(); api.Destroy(); world.flush(); assert(world.connections == 0)
	end)

	test(prefix .. "unlocked and closed APIs refuse inspection and copy", function()
		local world, api = diagnosticStart(deferred, { DiagnosticOnly = true, LockDiagnostics = false })
		local reads = 0; world.env.decompile = function() reads += 1 end
		contains(api.GetFullPaintPathsReport(), "Status=refused")
		assert(not api.CopyFullPaintPathsReport()); assert(reads == 0)
		api.Destroy()
		contains(api.GetFullPaintPathsReport(), "Status=closed")
		assert(not api.CopyFullPaintPathsReport())
	end)

	test(prefix .. "no file fallback starts after closing during clipboard yield", function()
		local world, api, roots = fullFixture(deferred)
		child(world, "ModuleScript", "Export", roots.ReplicatedStorage)
		local files = 0
		world.env.setclipboard = function() coroutine.yield(); error("failed") end
		world.env.writefile = function() files += 1 end
		local worker = coroutine.create(function() api.CopyFullPaintPathsReport() end)
		assert(coroutine.resume(worker)); api.Destroy(); world.flush()
		assert(coroutine.resume(worker)); assert(files == 0)
	end)

	test(prefix .. "version four diagnostic instance is refused before controller invocation", function()
		local world, api = sourceFixture(deferred)
		installLoaderMock(world)
		local ui = world.playerGui:FindFirstChild("AutoPainterFinalUI")
		ui:SetAttribute("AutoPainterDiagnosticsVersion", 4)
		local invoked = false
		ui:FindFirstChild("Controller").OnInvoke = function() invoked = true end
		local ok = pcall(function() world.load(DIAGNOSTIC_LOADER_SOURCE) end)
		assert(not ok and not invoked); api.Destroy()
	end)
	test(prefix .. "long multiline call tokens keep every line through opening parenthesis", function()
		local world, api, roots, sources = fullFixture(deferred)
		local source = 'r:' .. string.rep('\n', 30) .. 'InvokeServer' .. string.rep('\n', 30) .. '("PaintPart")'
		sources[child(world, "ModuleScript", "SplitCall", roots.ReplicatedStorage)] = source
		local report = api.GetFullPaintPathsReport()
		contains(fullSection(report, 1), "L1:C2 InvokeServer")
		contains(report, "Lines=L1-L61")
		contains(report, '* L61 | ("PaintPart")')
		api.Destroy()
	end)

	test(prefix .. "time budget yields without spawning collector tasks and resumes safely", function()
		local world, api, roots = fullFixture(deferred)
		for i = 1, 30 do child(world, "ModuleScript", "Yield" .. i, roots.ReplicatedStorage) end
		local clockValue, waits = 0, 0
		world.env.os.clock = function() clockValue += 0.001; return clockValue end
		local wait = world.env.task.wait
		world.env.task.wait = function() waits += 1; return wait() end
		local report
		local before = world.taskSpawns
		local worker = coroutine.create(function() report = api.GetFullPaintPathsReport() end)
		assert(coroutine.resume(worker)); world.flush()
		assert(coroutine.status(worker) == "dead" and waits > 0)
		assert(world.taskSpawns == before)
		contains(report, "EnumeratedUnique=30 TextReturned=30")
		noTraffic(world, api); api.Destroy()
	end)

	test(prefix .. "source removed before its turn is recorded not passed to decompile", function()
		local world, api, roots = fullFixture(deferred)
		local a = child(world, "ModuleScript", "A", roots.ReplicatedStorage)
		local b = child(world, "ModuleScript", "B", roots.ReplicatedStorage)
		world.env.decompile = function(object)
			assert(object == a)
			b:Destroy()
			return "return {}"
		end
		local report = api.GetFullPaintPathsReport()
		contains(report, "EnumeratedUnique=2 TextReturned=1 ReadFailures=0 NotRead=1")
		contains(report, "NOT_READ: left visible scope")
		noTraffic(world, api); api.Destroy()
	end)

	test(prefix .. "closing at time-slice checkpoint never reads another script", function()
		local world, api, roots, _, reads = fullFixture(deferred)
		for i = 1, 40 do child(world, "ModuleScript", "Cancel" .. i, roots.ReplicatedStorage) end
		local clockValue = 0
		world.env.os.clock = function() clockValue += 0.003; return clockValue end
		local report
		local worker = coroutine.create(function() report = api.GetFullPaintPathsReport() end)
		assert(coroutine.resume(worker))
		api.Destroy(); world.flush()
		assert(coroutine.status(worker) == "dead")
		assert(#reads == 0)
		contains(report, "Closed during root enumeration")
		assert(world.connections == 0)
	end)

	test(prefix .. "locked selection and remote replacement during inspection generate zero requests", function()
		local world, api, roots = fullFixture(deferred)
		child(world, "ModuleScript", "Hold", roots.ReplicatedStorage)
		local worker
		world.env.decompile = function() worker = coroutine.running(); return coroutine.yield() end
		press(world, "Full Paint Paths Report")
		press(world, "Add")
		local part = world.province(); world.mouse.Target = part
		world.input.InputBegan:Fire({ UserInputType = world.env.Enum.UserInputType.MouseButton1 }, false); world.flush()
		api.SetFast(true); api.SetColor(world.Color3.new(1, 0, 0))
		world.remote:Destroy()
		child(world, "RemoteFunction", "ServerControls", world.remotes); world.flush()
		api.CommitSelections(); api.RemoveProvince(part); api.Clear()
		assert(coroutine.resume(worker, "PaintPart"))
		world.step(1)
		noTraffic(world, api); assert(api.GetStats().DiagnosticLocked); api.Destroy()
	end)

end
