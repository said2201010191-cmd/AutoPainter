local function protocolLines(count, replacements)
	local lines = {}
	for i = 1, count do lines[i] = replacements[i] or "-- filler " .. i end
	return table.concat(lines, "\n")
end
local function protocolFixture(deferred, source)
	local world, api = sourceFixture(deferred)
	local target = child(world, "LocalScript", "LocalScript", world.bucket)
	local reads = 0
	world.env.decompile = function(object) assert(object == target); reads += 1; return source end
	return world, api, function() return reads end
end
local function occurrences(text, needle)
	local count, cursor = 0, 1
	while true do
		local at = string.find(text, needle, cursor, true)
		if not at then return count end
		count += 1; cursor = at + #needle
	end
end
local function protocolSection(text, startName, endName)
	local first = assert(string.find(text, "\n" .. startName .. "\n", 1, true))
	local last = endName and assert(string.find(text, "\n" .. endName .. "\n", first + 1, true)) or #text + 1
	return string.sub(text, first, last - 1)
end
local function renderedLineCounts(report)
	local counts = {}
	for number in string.gmatch(report, "\n[%* ] L(%d+)") do counts[number] = (counts[number] or 0) + 1 end
	return counts
end

for _, deferred in ipairs({ false, true }) do
	local prefix = deferred and "deferred protocol: " or "immediate protocol: "
	test(prefix .. "compact default view and exact UI buttons do not inspect automatically", function()
		local world = Mock.new(deferred); installLoaderMock(world)
		child(world, "LocalScript", "LocalScript", world.bucket)
		local reads = 0
		world.env.decompile = function() reads += 1; return 'x:InvokeServer("PaintPart")' end
		local api = world.load(DIAGNOSTIC_LOADER_SOURCE)
		local box = reportWidgets(world); contains(box.Text, "PROTOCOL EXTRACT")
		assert(reads == 0 and not string.find(box.Text, "BEGIN DECOMPILED SOURCE", 1, true))
		press(world, "Protocol Extract"); assert(reads == 1)
		contains(box.Text, "ProtocolReportFormat=1"); assert(api.GetStats().DiagnosticLocked)
		noTraffic(world, api); api.Destroy()
	end)

	test(prefix .. "all eighteen requested terms searched case-insensitively with path and line numbers", function()
		local terms = { "ServerControls", "ClientControls", "InvokeServer", "InvokeClient", "FireServer", "FireClient",
			"PaintPart", "Peace", "Activated", "Equipped", "Unequipped", "Color", "BrickColor", "RemoteFunction",
			"RemoteEvent", "mode", "state", "cooldown" }
		local replacements = {}
		for i, term in ipairs(terms) do replacements[i * 40] = string.upper(term) end
		local world, api = protocolFixture(deferred, protocolLines(740, replacements))
		local report = api.GetProtocolReport()
		contains(report, "MatchLines=18"); contains(report, "MergedBlocks=18")
		for i, term in ipairs(terms) do contains(report, "* L" .. i * 40); contains(report, "| " .. string.upper(term)) end
		contains(report, "Script=" .. world.bucket:GetFullName() .. ".LocalScript")
		noTraffic(world, api); api.Destroy()
	end)

	test(prefix .. "one match includes exactly eight preceding and twelve following lines", function()
		local world, api = protocolFixture(deferred, protocolLines(50, { [20] = "Color = selected" }))
		local report = api.GetProtocolReport(); local counts = renderedLineCounts(report)
		contains(report, "Lines=L12-L32"); contains(report, "* L20 [Color] | Color = selected")
		for i = 12, 32 do assert(counts[tostring(i)] == 1) end
		assert(not counts['11'] and not counts['33']); contains(report, "MergedBlocks=1")
		assert(not string.find(report, "BEGIN DECOMPILED SOURCE", 1, true))
		noTraffic(world, api); api.Destroy()
	end)

	test(prefix .. "overlapping adjacent and separated windows merge without dropped or duplicate lines", function()
		local world, api = protocolFixture(deferred, protocolLines(120, {
			[20] = "Color", [25] = "mode", [46] = "state", [90] = "cooldown" }))
		local report = api.GetProtocolReport(); local counts = renderedLineCounts(report)
		contains(report, "Lines=L12-L58"); contains(report, "Lines=L82-L102"); contains(report, "MergedBlocks=2")
		for i = 12, 58 do assert(counts[tostring(i)] == 1) end
		for i = 82, 102 do assert(counts[tostring(i)] == 1) end
		assert(not counts['59'] and not counts['81'])
		noTraffic(world, api); api.Destroy()
	end)

	test(prefix .. "file-edge and CRLF windows preserve line numbers and visible code", function()
		local source = protocolLines(30, { [1] = "Peace", [30] = "BrickColor" }):gsub("\n", "\r\n")
		local world, api = protocolFixture(deferred, source)
		local report = api.GetProtocolReport(); local counts = renderedLineCounts(report)
		contains(report, "Lines=L1-L13"); contains(report, "Lines=L22-L30")
		assert(counts['1'] == 1 and counts['30'] == 1 and not counts['14'] and not counts['21'])
		contains(report, "* L30 [Color, BrickColor] | BrickColor")
		noTraffic(world, api); api.Destroy()
	end)

	test(prefix .. "remote summary includes all four methods repeated same-line and multiline colon calls", function()
		local source = protocolLines(130, {
			[20] = 'a:InvokeServer("one"); b:FireServer("two")', [21] = 'c:InvokeClient(player)',
			[22] = 'd:FireClient(player)', [80] = 'e:', [81] = '  InvokeServer', [82] = ' ("three")',
			[110] = '-- literal:FireServer("not necessarily executed")' })
		local world, api = protocolFixture(deferred, source)
		local report = api.GetProtocolReport(); local summary = protocolSection(report, "REMOTE CALL SUMMARY", "PAINTPART FLOW")
		contains(report, "CallSites=6")
		for _, method in ipairs({ "InvokeServer", "FireServer", "InvokeClient", "FireClient" }) do contains(summary, ":" .. method .. "(") end
		assert(occurrences(summary, "Context=B") == 6)
		contains(summary, "L20:C2"); contains(summary, "L80:C2")
		contains(report, "comments/strings or unused code")
		for id in string.gmatch(summary, "Context=(B%d+)") do contains(report, "[" .. id .. "] Script=") end
		noTraffic(world, api); api.Destroy()
	end)

	test(prefix .. "PaintPart flow references shared context once across both summaries", function()
		local world, api = protocolFixture(deferred, protocolLines(60, {
			[20] = 'local r = tool.Remotes.ServerControls', [24] = 'local c = tool.Remotes.ClientControls',
			[27] = 'r:InvokeServer("PaintPart", args, "Peace")' }))
		local report = api.GetProtocolReport(); local flow = protocolSection(report, "PAINTPART FLOW", "MERGED CONTEXT BLOCKS")
		assert(occurrences(flow, "Context=B0001") == 3)
		contains(report, "FlowLines=3 MergedBlocks=1")
		contains(report, "Lines=L12-L39"); assert(occurrences(report, "[B0001] Script=") == 1)
		noTraffic(world, api); api.Destroy()
	end)

	test(prefix .. "all owned PaintBucket LocalScripts searched separately without merging across scripts", function()
		local world, api = sourceFixture(deferred)
		local backpack = child(world, "Backpack", "Backpack", world.player)
		local stored = child(world, "Tool", "PaintBucket", backpack)
		local a = child(world, "LocalScript", "LocalScript", world.bucket)
		local b = child(world, "LocalScript", "RemoteScript", stored)
		local c = child(world, "LocalScript", "VipTextures", stored)
		child(world, "ModuleScript", "Excluded", stored); child(world, "Script", "ExcludedServer", stored)
		local seen = {}
		world.env.decompile = function(object)
			assert(object == a or object == b or object == c); seen[object] = true
			return protocolLines(30, { [15] = "RemoteFunction" })
		end
		local report = api.GetProtocolReport(); assert(seen[a] and seen[b] and seen[c])
		contains(report, "TextReturned=3"); contains(report, "MergedBlocks=3")
		for object in pairs(seen) do contains(report, "Script=" .. object:GetFullName()) end
		noTraffic(world, api); api.Destroy()
	end)

	test(prefix .. "no matches and decompiler absence/errors remain explicit without raw-source fallback", function()
		local world, api = protocolFixture(deferred, "-- filler only")
		local report = api.GetProtocolReport(); contains(report, "MatchLines=0")
		contains(report, "No matching context blocks."); assert(not string.find(report, "-- filler only", 1, true))
		world.env.decompile = nil; contains(api.GetProtocolReport(), "decompile=unavailable")
		world.env.decompile = function() error("fixture read failed") end
		report = api.GetProtocolReport(); contains(report, "Status=decompiler failed")
		contains(report, "Failures=1"); noTraffic(world, api); api.Destroy()
	end)

	test(prefix .. "read-only extraction leaves properties counters tasks and callbacks untouched", function()
		local world, api = protocolFixture(deferred, 'error("not executed")\nClientControls.OnClientInvoke = function() end\nx:InvokeServer("PaintPart")')
		forbidExecution(world); world.flush()
		local writes, attributes, listeners, tasks = world.propertyWrites, world.attributeWrites, world.connections, world.taskDefers
		local report = api.GetProtocolReport(); contains(report, "PaintPart")
		assert(world.propertyWrites == writes and world.attributeWrites == attributes and world.connections == listeners)
		assert(world.taskDefers == tasks); assert(not api.SetDiagnostic(false))
		noTraffic(world, api); api.Destroy()
	end)

	test(prefix .. "full source and inventory remain optional while compact pages contain no raw report", function()
		local world, api = protocolFixture(deferred, protocolLines(700, { [350] = 'x:InvokeServer("PaintPart")' }))
		local expected = api.GetProtocolReport()
		assert(#expected < #api.GetLocalScriptReport())
		press(world, "Protocol Extract"); local box, label = reportWidgets(world)
		local pages = tonumber(string.match(label.Text, "/(%d+)$")); local pieces = {}
		for _ = 1, pages do table.insert(pieces, box.Text); press(world, "Next") end
		assert(table.concat(pieces) == expected)
		press(world, "Inspect source"); contains(api.GetLocalScriptReport(), "BEGIN DECOMPILED SOURCE")
		press(world, "Inspect"); contains(inventorySection(api.GetDiagnosticReport()), "LocalScript")
		noTraffic(world, api); api.Destroy()
	end)

	test(prefix .. "copy button refuses to scan then copies already-collected compact report", function()
		local world, api, reads = protocolFixture(deferred, protocolLines(600, { [20] = "Color", [300] = 'x:InvokeServer("PaintPart")' }))
		local copied, copies, files = nil, 0, 0
		world.env.setclipboard = function(text) copied = text; copies += 1 end
		world.env.writefile = function() files += 1 end
		press(world, "Copy Protocol Report"); assert(reads() == 0 and copies == 0 and files == 0)
		press(world, "Protocol Extract"); press(world, "Copy Protocol Report"); assert(reads() == 1 and copies == 1 and files == 0)
		local expected = copied; contains(copied, "REMOTE CALL SUMMARY"); contains(copied, "END PROTOCOL EXTRACT")
		assert(not string.find(copied, "BEGIN DECOMPILED SOURCE", 1, true))
		press(world, "Inspect source"); assert(reads() == 2)
		press(world, "Copy Protocol Report"); assert(reads() == 2 and copies == 2 and copied == expected)
		for _, object in ipairs(world.objects) do
			if object.Name == "ProtocolExportStatus" then contains(object.Text, "Copied complete Protocol Report"); assert(object.Visible) end
		end
		noTraffic(world, api); api.Destroy()
	end)

	test(prefix .. "writefile fallback uses exact filename and entire compact UTF-8 report", function()
		local world, api = protocolFixture(deferred, '-- 色\nColor = "青"')
		local expected = api.GetProtocolReport(); local name, saved
		world.env.writefile = function(path, text) name, saved = path, text end
		local ok, status = api.CopyProtocolReport()
		assert(ok and name == "AutoPainterProtocolReport.txt" and saved == expected)
		contains(status, "Saved AutoPainterProtocolReport.txt")
		noTraffic(world, api); api.Destroy()
	end)

	test(prefix .. "clipboard throw falls back to file and failures release export guard for retry", function()
		local world, api = protocolFixture(deferred, "PaintPart")
		world.env.setclipboard = function() error("clipboard unavailable") end
		api.GetProtocolReport()
		local saved = 0
		world.env.writefile = function() saved += 1 end
		assert(api.CopyProtocolReport()); assert(saved == 1)
		world.env.writefile = function() error("storage unavailable") end
		local ok, status = api.CopyProtocolReport(); assert(not ok); contains(status, "unavailable or failed")
		world.env.setclipboard = function() end; assert(api.CopyProtocolReport())
		noTraffic(world, api); api.Destroy()
	end)

	test(prefix .. "no export capability reports failure and retains whole report for manual pages", function()
		local world, api, reads = protocolFixture(deferred, "PaintPart")
		api.GetProtocolReport()
		local ok, status = api.CopyProtocolReport(); assert(not ok)
		contains(status, "Protocol Report remains available in pages")
		local copied
		world.env.setclipboard = function(text) copied = text end
		assert(api.CopyProtocolReport()); assert(reads() == 1); contains(copied, "PaintPart")
		noTraffic(world, api); api.Destroy()
	end)

	test(prefix .. "locked defaults allow explicit extraction and closed instances refuse export", function()
		local world, api = diagnosticStart(deferred)
		world.env.decompile = function() error("must refuse") end
		world.env.setclipboard = function() error("must refuse") end
		world.env.writefile = function() error("must refuse") end
		local writes = world.propertyWrites
		assert(api.GetStats().DiagnosticLocked); contains(api.GetProtocolReport(), "LocalScriptsFound=0"); assert(not api.CopyProtocolReport())
		assert(world.propertyWrites == writes)
		api.Destroy(); contains(api.GetProtocolReport(), "AutoPainter is closed"); assert(not api.CopyProtocolReport())
		noTraffic(world, api)
	end)

	test(prefix .. "yielded decompile prevents extraction/copy backlog and exports only after completion", function()
		local world, api = protocolFixture(deferred, "PaintPart")
		local worker, reads, exports = nil, 0, 0
		world.env.decompile = function() reads += 1; worker = coroutine.running(); return coroutine.yield() end
		world.env.setclipboard = function() exports += 1 end
		press(world, "Protocol Extract"); assert(worker and reads == 1 and exports == 0)
		for _ = 1, 40 do
			press(world, "Protocol Extract"); press(world, "Copy Protocol Report")
			contains(api.GetProtocolReport(), "Status=busy"); assert(not api.CopyProtocolReport())
		end
		assert(reads == 1 and exports == 0)
		assert(coroutine.resume(worker, "PaintPart")); world.step(0.06); world.flush(); assert(exports == 0)
		press(world, "Copy Protocol Report"); assert(exports == 1)
		noTraffic(world, api); api.Destroy()
	end)

	test(prefix .. "yielded clipboard prevents repeated exports and cleanup avoids stale UI writes", function()
		local world, api = protocolFixture(deferred, "PaintPart")
		api.GetProtocolReport()
		local worker, calls = nil, 0
		world.env.setclipboard = function() calls += 1; worker = coroutine.running(); coroutine.yield() end
		press(world, "Copy Protocol Report"); assert(calls == 1)
		for _ = 1, 30 do press(world, "Copy Protocol Report"); assert(not api.CopyProtocolReport()) end
		api.Destroy(); world.flush(); local writes = world.propertyWrites
		assert(coroutine.resume(worker)); world.step(0.06); world.flush()
		assert(calls == 1 and world.propertyWrites == writes and world.connections == 0)
		noTraffic(world, api)
	end)

	test(prefix .. "closing during source read cancels subsequent export without writing clipboard or file", function()
		local world, api = protocolFixture(deferred, "PaintPart")
		local worker
		world.env.decompile = function() worker = coroutine.running(); return coroutine.yield() end
		world.env.setclipboard = function() error("Must not export after shutdown") end
		world.env.writefile = function() error("Must not export after shutdown") end
		press(world, "Protocol Extract"); press(world, "Copy Protocol Report"); api.Destroy(); world.flush()
		assert(coroutine.resume(worker, "PaintPart")); world.step(0.06); world.flush()
		assert(world.connections == 0); noTraffic(world, api)
	end)

	test(prefix .. "closing during failed clipboard call prevents fallback file writes", function()
		local world, api = protocolFixture(deferred, "PaintPart")
		api.GetProtocolReport()
		local worker, files = nil, 0
		world.env.setclipboard = function() worker = coroutine.running(); coroutine.yield(); error("failed after close") end
		world.env.writefile = function() files += 1 end
		press(world, "Copy Protocol Report"); api.Destroy(); world.flush()
		assert(coroutine.resume(worker)); world.step(0.06); world.flush(); assert(files == 0)
		noTraffic(world, api)
	end)

	test(prefix .. "fresh extract replaces cached snapshot and repeated inspect/copy cycles leak no listeners", function()
		local world, api = protocolFixture(deferred, "Color = old")
		local copied; world.env.setclipboard = function(text) copied = text end
		local connections, spawns, defers = world.connections, world.taskSpawns, world.taskDefers
		for i = 1, 20 do
			world.env.decompile = function() return "Color = " .. i end
			press(world, "Protocol Extract"); press(world, "Copy Protocol Report")
			contains(copied, "| Color = " .. i .. "\n")
		end
		assert(world.connections == connections and world.taskSpawns == spawns + 20 and world.taskDefers == defers)
		noTraffic(world, api); api.Destroy(); world.flush(); assert(world.connections == 0)
	end)

	test(prefix .. "version-three UI is refused so loader cannot silently reuse the raw-only build", function()
		local world = Mock.new(deferred)
		local ui = child(world, "ScreenGui", "AutoPainterFinalUI", world.playerGui)
		ui:SetAttribute("AutoPainterDiagnosticsVersion", 3)
		local bridge = child(world, "BindableFunction", "Controller", ui)
		bridge.OnInvoke = function() error("Must not reuse previous build") end
		local ok, problem = pcall(function() world.load(SOURCE, { LockDiagnostics = true }) end)
		assert(not ok); contains(tostring(problem), "lacks the current report")
		assert(world.networkAttempts == 0); ui:Destroy()
	end)
end
