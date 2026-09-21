-- The explicit inventory must be complete independently of the old summary traversal.
local function inventorySection(report)
	local start = assert(string.find(report, "\n\nPAINTBUCKET DESCENDANTS\n", 1, true))
	local section = string.sub(report, start + 2)
	contains(section, "END PAINTBUCKET DESCENDANTS")
	return section
end
local function inventoryPaths(section)
	local paths = {}
	for path in string.gmatch(section, "\nFullName=([^\n]+)") do table.insert(paths, path) end
	return paths
end
local function child(world, class, name, parent)
	local object = world.instance(class); object.Name = name; object.Parent = parent
	return object
end
local function reportWidgets(world)
	local box, label
	for _, object in ipairs(world.objects) do
		if object.Name == "DiagnosticReport" then box = object end
		if object.Name == "PageLabel" then label = object end
	end
	return assert(box), assert(label)
end
local function lockedInventoryStart(deferred)
	return diagnosticStart(deferred, { DiagnosticOnly = true, LockDiagnostics = true })
end

for _, deferred in ipairs({ false, true }) do
	local prefix = deferred and "deferred inventory: " or "immediate inventory: "
	test(prefix .. "Handle-only GetChildren summary still lists Remotes and ServerControls via GetDescendants", function()
		local world, api = lockedInventoryStart(deferred)
		world.character.Name = "Seporial"
		local handle = child(world, "Part", "Handle", world.bucket)
		world.childrenView = { [world.bucket] = { handle } } -- Reproduce the observed incomplete summary.
		world.flush()
		local before = world.descendantReads
		local report = api.GetDiagnosticReport(); local section = inventorySection(report)
		contains(report, "Fresh remote=Workspace.Seporial.PaintBucket.Remotes.ServerControls")
		contains(report, "child: Workspace.Seporial.PaintBucket.Handle [Part]")
		assert(world.descendantReads == before + 1)
		contains(section, "FullName=Workspace.Seporial.PaintBucket.Remotes\nClassName=Folder\nName=Remotes")
		contains(section, "FullName=Workspace.Seporial.PaintBucket.Remotes.ServerControls\nClassName=RemoteFunction\nName=ServerControls")
		contains(section, "Listed=3 Expected=3 UnreadableFields=0")
		contains(section, "FreshRemoteInInventory=true")
		noTraffic(world, api); assert(api.GetStats().DiagnosticLocked); api.Destroy()
	end)

	test(prefix .. "every descendant includes path/class/name/parent, script flags and remote kinds", function()
		local world, api = lockedInventoryStart(deferred)
		local client = child(world, "LocalScript", "BucketClient", world.bucket); client.Enabled = false
		local scriptObject = child(world, "Script", "ToolServer", world.bucket); scriptObject.Enabled = true
		child(world, "ModuleScript", "ColorMode", client)
		child(world, "RemoteEvent", "StateChanged", world.remotes)
		child(world, "UnreliableRemoteEvent", "AimState", world.remotes)
		local all = world.bucket:GetDescendants(); local section = inventorySection(api.GetDiagnosticReport())
		assert(#inventoryPaths(section) == #all)
		for _, object in ipairs(all) do
			contains(section, "FullName=" .. object:GetFullName() .. "\nClassName=" .. object.ClassName
				.. "\nName=" .. object.Name .. "\nParent FullName=" .. object.Parent:GetFullName())
		end
		contains(section, "RemoteEvent=true RemoteFunction=false")
		contains(section, "RemoteEvent=false RemoteFunction=true")
		contains(section, "Enabled=false"); contains(section, "Enabled=true")
		contains(section, "ClassName=ModuleScript"); contains(section, "ClassName=UnreliableRemoteEvent")
		noTraffic(world, api); api.Destroy()
	end)

	test(prefix .. "sort order is deterministic across enumeration order and duplicate full paths", function()
		local world, api = lockedInventoryStart(deferred)
		child(world, "Folder", "Zed", world.bucket); child(world, "Folder", "Alpha", world.bucket)
		local a = child(world, "Folder", "Duplicate", world.bucket); a:SetAttribute("Rank", 2)
		local b = child(world, "Folder", "Duplicate", world.bucket); b:SetAttribute("Rank", 1)
		child(world, "ModuleScript", "Duplicate", world.bucket)
		local first = inventorySection(api.GetDiagnosticReport()); local paths = inventoryPaths(first)
		for i = 2, #paths do assert(paths[i - 1] <= paths[i], "Inventory not sorted by full path") end
		world.reverseDescendants = true
		assert(inventorySection(api.GetDiagnosticReport()) == first, "Enumeration order changed output")
		assert(#paths == 7)
		noTraffic(world, api); api.Destroy()
	end)

	test(prefix .. "inventory exceeds old node/depth/text caps without missing any descendant", function()
		local world, api = lockedInventoryStart(deferred)
		for i = 1, 150 do child(world, "Folder", string.format("Wide%03d", i), world.bucket) end
		local parent = world.bucket
		for i = 1, 30 do parent = child(world, "Folder", "Deep" .. i, parent) end
		local leaf = child(world, "RemoteFunction", "DeepRemote", parent)
		local expected = #world.bucket:GetDescendants()
		local section = inventorySection(api.GetDiagnosticReport())
		assert(#section > 24000 and #inventoryPaths(section) == expected)
		contains(section, "FullName=" .. leaf:GetFullName())
		contains(section, string.format("Listed=%d Expected=%d UnreadableFields=0", expected, expected))
		contains(section, "FreshRemoteInInventory=true")
		noTraffic(world, api); api.Destroy()
	end)

	test(prefix .. "all attributes are sorted and redacted; safe ValueBase types and values are printed", function()
		local world, api = lockedInventoryStart(deferred)
		local colorValue = child(world, "Color3Value", "SelectedColor", world.bucket); colorValue.Value = world.Color3.new(0.1, 0.2, 0.3)
		local numberValue = child(world, "NumberValue", "Cooldown", world.bucket); numberValue.Value = 0.25
		local boolValue = child(world, "BoolValue", "Ready", world.bucket); boolValue.Value = false
		local modeValue = child(world, "StringValue", "Mode", world.bucket); modeValue.Value = "PRIVATE_STRING_VALUE"
		local credential = child(world, "IntValue", "SessionKey", world.bucket); credential.Value = 827364912
		for i = 20, 1, -1 do colorValue:SetAttribute(string.format("Flag%02d", i), i) end
		colorValue:SetAttribute("AccessToken", "DO_NOT_EXPORT_TOKEN")
		colorValue:SetAttribute("Nonce", 919283741)
		local section = inventorySection(api.GetDiagnosticReport())
		contains(section, "ValueBaseType=Color3Value ValueType=Color3\nValue=Color3(0.10000, 0.20000, 0.30000)")
		contains(section, "ValueBaseType=NumberValue ValueType=number\nValue=0.25")
		contains(section, "ValueBaseType=BoolValue ValueType=boolean\nValue=false")
		contains(section, "ValueBaseType=StringValue ValueType=string\nValue=<string value omitted>")
		contains(section, "ValueBaseType=IntValue ValueType=number\nValue=<redacted number>")
		contains(section, "Attributes=22"); contains(section, "@AccessToken (string) = <redacted string>")
		contains(section, "@Nonce (number) = <redacted number>")
		local last = 0
		for i = 1, 20 do
			local start = assert(string.find(section, string.format("@Flag%02d (number) = %d", i, i), 1, true))
			assert(start > last); last = start
		end
		for _, secret in ipairs({ "PRIVATE_STRING_VALUE", "DO_NOT_EXPORT_TOKEN", "919283741", "827364912" }) do
			assert(not string.find(section, secret, 1, true))
		end
		noTraffic(world, api); api.Destroy()
	end)

	test(prefix .. "long full paths and names are retained and control characters escaped", function()
		local world, api = lockedInventoryStart(deferred)
		local parent = child(world, "Folder", string.rep("LongName", 40), world.bucket)
		local leaf = child(world, "ModuleScript", "Line\nBreak", parent)
		local section = inventorySection(api.GetDiagnosticReport())
		contains(section, "FullName=" .. parent:GetFullName())
		contains(section, "Name=" .. parent.Name)
		contains(section, "Parent FullName=" .. parent:GetFullName())
		contains(section, "Name=Line\\x0ABreak")
		assert(not string.find(section, "Line\nBreak", 1, true))
		assert(#inventoryPaths(section) == 4)
		noTraffic(world, api); api.Destroy()
	end)

	test(prefix .. "inspection performs no property/attribute writes, remote calls, worker creation or module execution", function()
		local world, api = lockedInventoryStart(deferred)
		child(world, "LocalScript", "Client", world.bucket); child(world, "ModuleScript", "Logic", world.bucket)
		world.env.require = function() error("Inventory executed module code") end
		world.env.loadstring = function() error("Inventory compiled executable source") end
		world.flush()
		local writes, attributeWrites = world.propertyWrites, world.attributeWrites
		local connections, spawns, defers = world.connections, world.taskSpawns, world.taskDefers
		for _ = 1, 10 do inventorySection(api.GetDiagnosticReport()) end
		assert(world.propertyWrites == writes and world.attributeWrites == attributeWrites)
		assert(world.connections == connections and world.taskSpawns == spawns and world.taskDefers == defers)
		assert(api.GetStats().DiagnosticOnly and api.GetStats().DiagnosticLocked)
		assert(not api.SetDiagnostic(false)); noTraffic(world, api); api.Destroy()
	end)

	test(prefix .. "missing/equipment failure is explicit and never reports a falsely empty successful inventory", function()
		local world, api = lockedInventoryStart(deferred)
		world.player.Character = nil; world.flush()
		local section = inventorySection(api.GetDiagnosticReport())
		contains(section, "Status=missing equipped PaintBucket")
		world.equip(); world.flush(); world.descendantError = world.bucket
		section = inventorySection(api.GetDiagnosticReport())
		contains(section, "Status=enumeration unavailable; completeness cannot be established")
		assert(not string.find(section, "Listed=0 Expected=0", 1, true))
		world.descendantError = nil
		contains(inventorySection(api.GetDiagnosticReport()), "Listed=2 Expected=2 UnreadableFields=0")
		noTraffic(world, api); api.Destroy()
	end)

	test(prefix .. "unreadable attributes remain explicit without dropping that object or later descendants", function()
		local world, api = lockedInventoryStart(deferred)
		local unreadable = child(world, "Folder", "AAA", world.bucket)
		child(world, "Folder", "ZZZ", world.bucket); world.attributesError = unreadable
		local section = inventorySection(api.GetDiagnosticReport())
		contains(section, "Name=AAA"); contains(section, "Attributes=<unavailable>"); contains(section, "Name=ZZZ")
		contains(section, "Listed=4 Expected=4 UnreadableFields=1"); contains(section, "FreshRemoteInInventory=true")
		noTraffic(world, api); api.Destroy()
	end)

	test(prefix .. "respawn/remote replacement inventory is fresh and excludes old tool descendants", function()
		local world, api = lockedInventoryStart(deferred)
		child(world, "Folder", "OldOnly", world.bucket)
		contains(inventorySection(api.GetDiagnosticReport()), "Name=OldOnly")
		world.equip(); world.flush(); child(world, "Folder", "NewOnly", world.bucket)
		world.remote:Destroy(); world.flush()
		world.remote = child(world, "RemoteFunction", "ServerControls", world.remotes); world.flush()
		local section = inventorySection(api.GetDiagnosticReport())
		assert(not string.find(section, "Name=OldOnly", 1, true)); contains(section, "Name=NewOnly")
		contains(section, "FreshRemoteInInventory=true")
		noTraffic(world, api); api.Destroy()
	end)

	test(prefix .. "UI pagination preserves every UTF-8 byte and all descendant records without report history", function()
		local world, api = lockedInventoryStart(deferred)
		for i = 1, 70 do child(world, "Folder", "Tile" .. i .. string.rep("界", 22), world.bucket) end
		child(world, "Folder", string.rep("界", 1800), world.bucket) -- A line longer than one page.
		local expected = api.GetDiagnosticReport(); local baseline = world.connections
		press(world, "Inspect"); local box, label = reportWidgets(world)
		local pages = tonumber(string.match(label.Text, "/(%d+)$")); assert(pages and pages > 1)
		local chunks = {}
		press(world, "Prev"); assert(label.Text == "Page 1/" .. pages)
		for i = 1, pages do
			assert(label.Text == string.format("Page %d/%d", i, pages))
			assert(#box.Text <= 4000 and utf8.len(box.Text) ~= nil)
			local _, newlines = string.gsub(box.Text, "\n", ""); assert(newlines <= 40)
			table.insert(chunks, box.Text); press(world, "Next")
		end
		assert(table.concat(chunks) == expected, "Page rendering lost/duplicated report bytes")
		assert(world.connections == baseline)
		press(world, "Inspect"); assert(label.Text == "Page 1/" .. pages)
		noTraffic(world, api); api.Destroy(); world.flush(); assert(world.connections == 0)
	end)

	test(prefix .. "version-one UI is refused rather than silently reusing the incomplete inventory", function()
		local world = Mock.new(deferred)
		local ui = child(world, "ScreenGui", "AutoPainterFinalUI", world.playerGui)
		ui:SetAttribute("AutoPainterDiagnosticsVersion", 1)
		local bridge = child(world, "BindableFunction", "Controller", ui)
		bridge.OnInvoke = function() error("Must not reuse old inventory") end
		local ok, problem = pcall(function() world.load(SOURCE, { LockDiagnostics = true }) end)
		assert(not ok); contains(tostring(problem), "lacks the current report")
		assert(world.networkAttempts == 0); ui:Destroy()
	end)
end
