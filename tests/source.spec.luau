-- Source inspection calls only an injected read-only decompiler, never game code.
local function sourceFixture(deferred)
	local world, api = lockedInventoryStart(deferred)
	world.forbidSourceRead = true
	return world, api
end
local function forbidExecution(world)
	world.env.require = function() error("Executed a module") end
	world.env.loadstring = function() error("Compiled returned source") end
	world.env.getscriptclosure = function() error("Read a closure") end
	world.env.hookmetamethod = function() error("Installed a hook") end
end
local function sourceBody(report)
	local beginMarker, endMarker = "BEGIN DECOMPILED SOURCE\n", "\nEND DECOMPILED SOURCE"
	local first = assert(string.find(report, beginMarker, 1, true)) + #beginMarker
	local last = assert(string.find(report, endMarker, first, true))
	return string.sub(report, first, last - 1)
end

for _, deferred in ipairs({ false, true }) do
	local prefix = deferred and "deferred source: " or "immediate source: "
	test(prefix .. "actual diagnostic loader locks source action without automatic decompilation", function()
		local world = Mock.new(deferred); installLoaderMock(world)
		child(world, "LocalScript", "LocalScript", world.bucket)
		local calls = 0
		world.env.decompile = function() calls += 1; return "-- explicitly requested source" end
		local api = world.load(DIAGNOSTIC_LOADER_SOURCE)
		assert(api.GetStats().DiagnosticLocked and calls == 0)
		press(world, "Inspect"); assert(calls == 0)
		press(world, "Inspect source"); assert(calls == 1)
		assert(world.load(DIAGNOSTIC_LOADER_SOURCE) == api and calls == 1)
		assert(not api.SetDiagnostic(false)); noTraffic(world, api); api.Destroy()
	end)

	test(prefix .. "unavailable decompiler explicitly lists candidates without fallback", function()
		local world, api = sourceFixture(deferred)
		child(world, "LocalScript", "LocalScript", world.bucket); forbidExecution(world)
		local report = api.GetLocalScriptReport()
		contains(report, "decompile=unavailable"); contains(report, "LocalScriptsFound=1")
		contains(report, "Status=unavailable; decompile is not a function")
		world.env.decompile = {}; contains(api.GetLocalScriptReport(), "decompile=unavailable")
		noTraffic(world, api); api.Destroy()
	end)

	test(prefix .. "backpack-only LocalScript RemoteScript VipTextures are read serially by full path", function()
		local world, api = sourceFixture(deferred)
		local backpack = child(world, "Backpack", "Backpack", world.player)
		world.bucket.Parent = backpack
		for _, name in ipairs({ "VipTextures", "RemoteScript", "LocalScript" }) do child(world, "LocalScript", name, world.bucket) end
		world.flush(); local paths = {}
		world.env.decompile = function(object)
			assert(object:IsA("LocalScript") and object:IsDescendantOf(world.bucket))
			table.insert(paths, object:GetFullName()); return "-- source for " .. object.Name
		end
		forbidExecution(world)
		local report = api.GetLocalScriptReport()
		assert(#paths == 3 and paths[1] < paths[2] and paths[2] < paths[3])
		for _, path in ipairs(paths) do contains(report, "FullName=" .. path) end
		contains(report, "LocalScriptsFound=3"); contains(report, "TextReturned=3 Failures=0 Skipped=0")
		noTraffic(world, api); api.Destroy()
	end)

	test(prefix .. "equipped and backpack tools included; other players tools modules and server scripts excluded", function()
		local world, api = sourceFixture(deferred)
		local backpack = child(world, "Backpack", "Backpack", world.player)
		local stored = child(world, "Tool", "PaintBucket", backpack)
		local allowed = { [child(world, "LocalScript", "Active", world.bucket)] = true,
			[child(world, "LocalScript", "Stored", child(world, "Folder", "Nested", stored))] = true }
		child(world, "ModuleScript", "ModuleScript", world.bucket)
		child(world, "Script", "ServerScript", stored)
		child(world, "LocalScript", "Outside", world.character)
		child(world, "LocalScript", "WrongTool", child(world, "Tool", "OtherTool", backpack))
		child(world, "LocalScript", "OtherPlayer", child(world, "Tool", "PaintBucket", world.workspace))
		child(world, "LocalScript", "NotTool", child(world, "Folder", "PaintBucket", backpack))
		local calls = 0
		world.env.decompile = function(object) assert(allowed[object]); calls += 1; return "return nil" end
		local report = api.GetLocalScriptReport(); assert(calls == 2)
		contains(report, "LocalScriptsFound=2"); noTraffic(world, api); api.Destroy()
	end)

	test(prefix .. "duplicate full paths are distinct LocalScripts and each inspected once", function()
		local world, api = sourceFixture(deferred)
		local a = child(world, "LocalScript", "Same", world.bucket)
		local b = child(world, "LocalScript", "Same", world.bucket); local seen = {}
		world.env.decompile = function(object) assert(not seen[object]); seen[object] = true; return "-- duplicate name" end
		contains(api.GetLocalScriptReport(), "TextReturned=2"); assert(seen[a] and seen[b])
		noTraffic(world, api); api.Destroy()
	end)

	test(prefix .. "full returned source preserved and protocol tokens indexed without interpreting execution order", function()
		local world, api = sourceFixture(deferred); child(world, "LocalScript", "RemoteScript", world.bucket)
		local source = 'error("DO NOT EXECUTE")\nlocal c = tool.Remotes.ClientControls\nc.OnClientInvoke = function(mode)\nreturn Color3.new(1, 0, 0)\nend\ntool.Equipped:Connect(function() end)\ntool.Activated:Connect(function()\nlocal state = true\nlocal timestamp = os.clock()\nlocal token = nil\nother:FireServer("setup")\nServerControls:InvokeServer("PaintPart", {Part = tile, Color = color}, "Peace")\nend)\n'
		world.env.decompile = function() return source end; forbidExecution(world)
		local report = api.GetLocalScriptReport(); assert(sourceBody(report) == source)
		for _, term in ipairs({ "ClientControls", "ServerControls", "InvokeServer", "FireServer", "PaintPart", "Peace", "color", "equip", "activate", "tool/state", "mode", "client response", "timing", "session" }) do contains(report, term) end
		contains(report, 'L11 [FireServer] other:FireServer("setup")')
		contains(report, "L12 [ServerControls, InvokeServer, PaintPart, Peace, color]")
		contains(report, "Text matches alone cannot establish call order")
		noTraffic(world, api); api.Destroy()
	end)

	test(prefix .. "decompiler failures invalid returns and error strings are explicit; later scripts still inspected", function()
		local world, api = sourceFixture(deferred)
		for _, name in ipairs({ "A", "B", "C", "D", "E", "F" }) do child(world, "LocalScript", name, world.bucket) end
		local calls = 0
		world.env.decompile = function(object)
			calls += 1
			if object.Name == "A" then error("Injected decompiler failure") end
			if object.Name == "B" then return {} end
			if object.Name == "C" then return "" end
			if object.Name == "D" then return string.char(255) end
			if object.Name == "E" then return "-- DECOMPILER ERROR: text returned instead of exception" end
			return "return nil"
		end
		local report = api.GetLocalScriptReport(); assert(calls == 6)
		contains(report, "Status=decompiler failed"); contains(report, "Injected decompiler failure")
		contains(report, "TextReturned=2 Failures=4 Skipped=0")
		contains(report, "DECOMPILER ERROR: text returned instead of exception")
		contains(report, "Status=text returned; decompiler accuracy/completeness unverified")
		world.env.decompile = function() return "-- recovered" end
		contains(api.GetLocalScriptReport(), "TextReturned=6 Failures=0 Skipped=0")
		noTraffic(world, api); api.Destroy()
	end)

	test(prefix .. "inspection makes zero property writes requests listeners or target function calls with bounded read workers", function()
		local world, api = sourceFixture(deferred); child(world, "LocalScript", "LocalScript", world.bucket)
		local client = child(world, "RemoteFunction", "ClientControls", world.remotes)
		client.OnClientInvoke = function() error("Invoked tool callback") end
		world.env.decompile = function() return 'ClientControls.OnClientInvoke("Peace")\nServerControls:InvokeServer("PaintPart")' end
		forbidExecution(world); world.flush()
		local writes, attributes, connections = world.propertyWrites, world.attributeWrites, world.connections
		local spawns, defers, attempted = world.taskSpawns, world.taskDefers, api.GetStats().Attempted
		for _ = 1, 3 do api.GetLocalScriptReport() end
		assert(world.propertyWrites == writes and world.attributeWrites == attributes)
		assert(world.connections == connections and world.taskSpawns == spawns + 3 and world.taskDefers == defers)
		assert(api.GetStats().Attempted == attempted and api.GetStats().DiagnosticLocked)
		assert(not api.SetDiagnostic(false)); noTraffic(world, api); api.Destroy()
	end)

	test(prefix .. "normal metadata inspection never decompiles and retains complete descendant inventory", function()
		local world, api = sourceFixture(deferred); child(world, "LocalScript", "LocalScript", world.bucket)
		world.env.decompile = function() error("Metadata inspection must not decompile") end
		contains(inventorySection(api.GetDiagnosticReport()), "Name=LocalScript")
		press(world, "Inspect"); local box = reportWidgets(world); contains(box.Text, "AUTOPAINTER LOCAL SNAPSHOT")
		noTraffic(world, api); api.Destroy()
	end)

	test(prefix .. "source API refuses unlocked diagnostics without changing toggles properties or invoking decompile", function()
		local world, api = diagnosticStart(deferred)
		world.env.decompile = function() error("Must refuse unlocked session") end
		local before = world.propertyWrites; local painting = api.GetStats().Painting
		contains(api.GetLocalScriptReport(), "Status=refused; use LoaderDiagnostic.luau")
		assert(world.propertyWrites == before and api.GetStats().Painting == painting)
		assert(not api.GetStats().DiagnosticLocked); noTraffic(world, api); api.Destroy()
	end)

	test(prefix .. "missing tool no scripts and enumeration failure are explicit and recoverable", function()
		local world, api = sourceFixture(deferred)
		world.env.decompile = function() error("No scripts to inspect") end
		contains(api.GetLocalScriptReport(), "LocalScriptsFound=0")
		world.bucket.Parent = nil; world.flush()
		contains(api.GetLocalScriptReport(), "Status=no PaintBucket Tool")
		world.bucket.Parent = world.character; world.descendantError = world.bucket; world.flush()
		contains(api.GetLocalScriptReport(), "RootStatus=GetDescendants failed")
		world.descendantError = nil; contains(api.GetLocalScriptReport(), "LocalScriptsFound=0")
		noTraffic(world, api); api.Destroy()
	end)

	test(prefix .. "one yielded decompile at a time; repeated UI and API calls cannot build a backlog", function()
		local world, api = sourceFixture(deferred); child(world, "LocalScript", "LocalScript", world.bucket)
		local worker, calls = nil, 0
		world.env.decompile = function() calls += 1; worker = coroutine.running(); return coroutine.yield() end
		press(world, "Inspect source"); assert(calls == 1 and worker)
		for _ = 1, 50 do
			press(world, "Inspect source"); contains(api.GetLocalScriptReport(), "Status=busy")
		end
		assert(calls == 1); assert(api.GetStats().DiagnosticLocked)
		assert(coroutine.resume(worker, "-- completed")); world.step(0.06); world.flush()
		local box = reportWidgets(world); contains(box.Text, "PAINTBUCKET LOCALSCRIPT SOURCE")
		world.env.decompile = function() return "-- next scan" end
		contains(api.GetLocalScriptReport(), "-- next scan")
		noTraffic(world, api); api.Destroy()
	end)

	test(prefix .. "UI source pages reconstruct complete long Unicode output and keep no history", function()
		local world, api = sourceFixture(deferred); child(world, "LocalScript", "RemoteScript", world.bucket)
		local source = string.rep('-- 色: color\n', 900) .. '-- ' .. string.rep("界", 1800)
		world.env.decompile = function() return source end
		local expected = api.GetLocalScriptReport(); local baseline = world.connections
		press(world, "Inspect source"); local box, label = reportWidgets(world)
		local pages = tonumber(string.match(label.Text, "/(%d+)$")); assert(pages > 1)
		local chunks = {}
		for i = 1, pages do
			assert(#box.Text <= 4000 and utf8.len(box.Text) ~= nil)
			table.insert(chunks, box.Text); press(world, "Next")
		end
		assert(table.concat(chunks) == expected and sourceBody(expected) == source)
		press(world, "Inspect source"); assert(label.Text == "Page 1/" .. pages)
		assert(world.connections == baseline)
		noTraffic(world, api); api.Destroy(); world.flush(); assert(world.connections == 0)
	end)

	test(prefix .. "respawn while first decompile yields skips stale remaining scripts", function()
		local world, api = sourceFixture(deferred)
		child(world, "LocalScript", "A", world.bucket); child(world, "LocalScript", "B", world.bucket)
		local worker, calls, report
		calls = 0
		world.env.decompile = function() calls += 1; worker = coroutine.running(); return coroutine.yield() end
		local thread = coroutine.create(function() report = api.GetLocalScriptReport() end)
		assert(coroutine.resume(thread)); assert(calls == 1)
		world.equip(); world.flush()
		assert(coroutine.resume(worker, "-- old snapshot")) world.step(0.06);
		assert(calls == 1); contains(report, "Status=skipped; script/tool left")
		contains(report, "TextReturned=1 Failures=0 Skipped=1")
		noTraffic(world, api); api.Destroy()
	end)

	test(prefix .. "detached tool with absent Character and Backpack cannot pass ownership via nil equality", function()
		local world, api = sourceFixture(deferred)
		child(world, "LocalScript", "A", world.bucket); child(world, "LocalScript", "B", world.bucket)
		local worker, calls, report = nil, 0, nil
		world.env.decompile = function() calls += 1; worker = coroutine.running(); return coroutine.yield() end
		local thread = coroutine.create(function() report = api.GetLocalScriptReport() end)
		assert(coroutine.resume(thread))
		world.bucket.Parent = nil; world.player.Character = nil; world.flush()
		assert(coroutine.resume(worker, "-- old snapshot")); world.step(0.06); assert(calls == 1)
		contains(report, "Status=skipped; script/tool left"); noTraffic(world, api); api.Destroy()
	end)

	test(prefix .. "moving the same owned PaintBucket into Backpack during inspection remains within scope", function()
		local world, api = sourceFixture(deferred)
		child(world, "LocalScript", "A", world.bucket); child(world, "LocalScript", "B", world.bucket)
		local backpack = child(world, "Backpack", "Backpack", world.player)
		local worker, calls, report = nil, 0, nil
		world.env.decompile = function()
			calls += 1
			if calls == 1 then worker = coroutine.running(); return coroutine.yield() end
			return "-- B in Backpack"
		end
		local thread = coroutine.create(function() report = api.GetLocalScriptReport() end)
		assert(coroutine.resume(thread)); world.bucket.Parent = backpack; world.flush()
		assert(coroutine.resume(worker, "-- A captured before movement")) world.step(0.06);
		assert(calls == 2); contains(report, "TextReturned=2 Failures=0 Skipped=0")
		contains(report, "CurrentFullName=" .. backpack:GetFullName() .. ".PaintBucket.A")
		noTraffic(world, api); api.Destroy()
	end)

	test(prefix .. "destroyed or moved-out next script is skipped before invoking decompiler", function()
		local world, api = sourceFixture(deferred)
		child(world, "LocalScript", "A", world.bucket)
		local b = child(world, "LocalScript", "B", world.bucket); local c = child(world, "LocalScript", "C", world.bucket)
		local calls = 0
		world.env.decompile = function()
			calls += 1; b:Destroy(); c.Parent = world.workspace; return "-- A"
		end
		contains(api.GetLocalScriptReport(), "TextReturned=1 Failures=0 Skipped=2"); assert(calls == 1)
		noTraffic(world, api); api.Destroy()
	end)

	test(prefix .. "closing UI during decompile suppresses stale UI writes and stops later scripts", function()
		local world, api = sourceFixture(deferred)
		child(world, "LocalScript", "A", world.bucket); child(world, "LocalScript", "B", world.bucket)
		local worker, calls = nil, 0
		world.env.decompile = function() calls += 1; worker = coroutine.running(); return coroutine.yield() end
		press(world, "Inspect source"); api.Destroy(); world.flush()
		local writes = world.propertyWrites
		assert(coroutine.resume(worker, "-- completed after shutdown")); world.step(0.06); world.flush()
		assert(calls == 1 and world.connections == 0)
		assert(world.playerGui:FindFirstChild("AutoPainterFinalUI") == nil)
		contains(api.GetLocalScriptReport(), "Status=unavailable; AutoPainter is closed")
		noTraffic(world, api)
	end)

	test(prefix .. "source inspection during pending selection and after commit never creates paint work", function()
		local world, api = sourceFixture(deferred); child(world, "LocalScript", "LocalScript", world.bucket)
		world.env.decompile = function() return 'ServerControls:InvokeServer("PaintPart")' end
		press(world, "Add"); selectMany(world, 20); press(world, "Inspect source")
		assert(api.GetStats().PendingSelections == 20)
		finishSelection(world, api); api.SetFast(true); key(world, "Q"); key(world, "Q")
		press(world, "Inspect source"); world.step(10)
		assert(api.GetStats().CommittedSelections == 20 and api.GetStats().DiagnosticLocked)
		noTraffic(world, api); api.Destroy()
	end)

	test(prefix .. "previous version-two panel refused instead of silently reusing older source API", function()
		local world = Mock.new(deferred)
		local ui = child(world, "ScreenGui", "AutoPainterFinalUI", world.playerGui)
		ui:SetAttribute("AutoPainterDiagnosticsVersion", 2)
		local bridge = child(world, "BindableFunction", "Controller", ui)
		bridge.OnInvoke = function() error("Must not reuse version-two panel") end
		local ok, problem = pcall(function() world.load(SOURCE, { LockDiagnostics = true }) end)
		assert(not ok); contains(tostring(problem), "lacks the current report")
		assert(world.networkAttempts == 0); ui:Destroy()
	end)
end
