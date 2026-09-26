-- Game-only allowlist and static PlayerModule exception regressions.
for _, deferred in ipairs({ false, true }) do
	local prefix = deferred and "deferred game-only: " or "immediate game-only: "
	local function defaultTree(world, parent)
		local module = child(world, "ModuleScript", "PlayerModule", parent)
		local camera = child(world, "ModuleScript", "CameraModule", module)
		local controls = child(world, "ModuleScript", "ControlModule", module)
		local deeper = child(world, "ModuleScript", "CameraUtils", camera)
		return module, camera, controls, deeper
	end
	test(prefix .. "exact UI runs only allowlisted roots and legacy Full is safely restricted", function()
		local world, api, roots, _, reads = fullFixture(deferred)
		child(world, "ModuleScript", "PaintAllowed", roots.StarterPack)
		child(world, "ModuleScript", "PaintExcluded", roots.Extra)
		rawset(world.env.game, "GetChildren", function() error("DataModel enumeration forbidden") end)
		press(world, "Game-Only Full Scan")
		local report = waitForScan(world, api)
		assert(api.GetDiagnosticScanState().Mode == "GameOnly")
		assert(#reads == 1); contains(report, "Mode=GameOnly"); contains(report, "No additional DataModel roots")
		scanReport(world, api, "Full"); assert(#reads == 1 and api.GetDiagnosticScanState().Cached == 1)
		assert(api.GetDiagnosticScanState().Mode == "GameOnly")
		api.Destroy()
	end)
	test(prefix .. "thousands of internal scripts are pruned before descendant enumeration", function()
		local world, api, roots, _, reads = fullFixture(deferred)
		local forbidden = {}
		for _, name in ipairs({ "CorePackages", "CoreGui", "ServerScriptService", "ServerStorage", "RobloxReplicatedStorage" }) do
			local root = child(world, "Folder", name, world.env.game)
			for i = 1, 200 do child(world, "ModuleScript", "Paint" .. i, root) end
			table.insert(forbidden, root)
		end
		local nested = child(world, "Folder", "CorePackages", roots.ReplicatedStorage)
		child(world, "ModuleScript", "PaintNested", nested); table.insert(forbidden, nested)
		local internalClass = child(world, "CoreGui", "RenamedInternal", roots.Workspace)
		child(world, "ModuleScript", "PaintNested", internalClass); table.insert(forbidden, internalClass)
		for _, root in ipairs(forbidden) do rawset(root, "GetChildren", function() error("EXCLUDED ROOT ENUMERATED") end) end
		child(world, "LocalScript", "PaintGame", roots.PlayerScripts)
		local before = world.descendantReads
		local report = scanReport(world, api, "GameOnly")
		assert(#reads == 1 and api.GetDiagnosticScanState().Discovered == 1)
		assert(world.descendantReads == before)
		assert(not report:find("EXCLUDED ROOT ENUMERATED", 1, true))
		contains(report, "EXCLUDED SUBTREE:")
		api.Destroy()
	end)
	test(prefix .. "every allowlisted root includes unrelated modules but not extra local descendants", function()
		local world, api, roots, _, reads = fullFixture(deferred)
		local count = 0
		for name, root in pairs(roots) do
			child(world, "ModuleScript", "OrdinaryUtility", root)
			if name ~= "Extra" then count += 1 end
		end
		child(world, "ModuleScript", "PaintPrivateExtra", world.player)
		scanReport(world, api, "GameOnly"); assert(#reads == count)
		api.Destroy()
	end)
	test(prefix .. "overlapping Character Workspace and StarterPlayer roots never double traverse", function()
		local world, api, roots, _, reads = fullFixture(deferred)
		local part = child(world, "ModuleScript", "PaintBody", roots.Character)
		local starter = child(world, "ModuleScript", "PaintStarter", roots.StarterPlayerScripts)
		local before = world.childrenReads[roots.Character] or 0
		scanReport(world, api, "GameOnly")
		assert(#reads == 2 and reads[1] == part and reads[2] == starter)
		assert(world.childrenReads[roots.Character] - before == 1)
		assert(world.childrenReads[roots.StarterPlayerScripts] == 1)
		api.Destroy()
	end)
	test(prefix .. "identical script names and full paths remain distinct instances", function()
		local world, api, roots, _, reads = fullFixture(deferred)
		local a = child(world, "ModuleScript", "PaintDuplicate", roots.Workspace)
		local b = child(world, "ModuleScript", "PaintDuplicate", roots.Workspace)
		assert(a:GetFullName() == b:GetFullName())
		scanReport(world, api, "GameOnly")
		assert(#reads == 2 and reads[1] ~= reads[2]); api.Destroy()
	end)
	test(prefix .. "other players containers and workspace characters are not enumerated", function()
		local world, api, roots, _, reads = fullFixture(deferred)
		local other = child(world, "Player", "Other", world.player.Parent)
		table.insert(world.otherPlayers, other)
		local private = child(world, "PlayerScripts", "PlayerScripts", other)
		local model = child(world, "Model", "OtherCharacter", roots.Workspace); other.Character = model
		local tool = child(world, "Tool", "PaintBucket", model)
		child(world, "LocalScript", "PaintRemoteScript", tool)
		child(world, "ModuleScript", "PaintPrivate", private)
		local misplaced = child(world, "Player", "NotLocal", roots.Workspace)
		child(world, "ModuleScript", "PaintPrivate", misplaced)
		child(world, "LocalScript", "PaintOwn", world.bucket)
		local report = scanReport(world, api, "GameOnly")
		assert(#reads == 1 and reads[1]:IsDescendantOf(world.bucket))
		assert(not world.childrenReads[model] and not world.childrenReads[private] and not world.childrenReads[misplaced])
		contains(report, "other player's"); api.Destroy()
	end)
	test(prefix .. "a new other-player character during decompile is excluded in later Workspace phase", function()
		local world, api, roots = fullFixture(deferred)
		local gameScript = child(world, "ModuleScript", "PaintFirst", roots.ReplicatedStorage)
		local calls, worker = {}, nil
		world.env.decompile = function(object)
			table.insert(calls, object)
			if object == gameScript then worker = coroutine.running(); return coroutine.yield() end
			return "PaintPart"
		end
		assert(api.StartDiagnosticScan("GameOnly")); world.step(0.5)
		local other = child(world, "Player", "LateJoin", world.player.Parent)
		table.insert(world.otherPlayers, other)
		other.Character = child(world, "Model", "LateCharacter", roots.Workspace)
		child(world, "LocalScript", "PaintLate", other.Character)
		assert(coroutine.resume(worker, "PaintPart")); waitForScan(world, api)
		assert(#calls == 1 and not world.childrenReads[other.Character]); api.Destroy()
	end)
	test(prefix .. "default camera controls and bootstrap pruned in both quick and full", function()
		local world, api, roots, sources, reads = fullFixture(deferred)
		local module = defaultTree(world, roots.PlayerScripts)
		local starter = defaultTree(world, roots.StarterPlayerScripts)
		sources[child(world, "LocalScript", "PlayerScriptsLoader", roots.PlayerScripts)] = "require(script.Parent.PlayerModule)"
		child(world, "LocalScript", "CameraScript", roots.PlayerScripts)
		child(world, "LocalScript", "ControlScript", roots.StarterPlayerScripts)
		child(world, "LocalScript", "PaintController", roots.PlayerScripts)
		scanReport(world, api, "Quick")
		local report = scanReport(world, api, "GameOnly")
		assert(#reads == 1)
		assert(not world.childrenReads[module] and not world.childrenReads[starter])
		contains(report, "default PlayerModule/camera/control/bootstrap"); api.Destroy()
	end)
	test(prefix .. "game Packages and game PlayerModule names outside default containers are retained", function()
		local world, api, roots, _, reads = fullFixture(deferred)
		local packages = child(world, "Folder", "Packages", roots.ReplicatedStorage)
		child(world, "ModuleScript", "PlayerModule", packages)
		child(world, "ModuleScript", "CameraModule", packages)
		child(world, "ModuleScript", "PaintPlayerModule", roots.PlayerScripts)
		scanReport(world, api, "GameOnly")
		assert(#reads == 3); api.Destroy()
	end)
	test(prefix .. "direct relative game reference admits only named module not its dependency subtree", function()
		local world, api, roots, sources, reads = fullFixture(deferred)
		local module, camera, controls, deeper = defaultTree(world, roots.PlayerScripts)
		local gameScript = child(world, "LocalScript", "PaintController", roots.PlayerScripts)
		sources[gameScript] = "local camera = require(script.Parent.PlayerModule.CameraModule)"
		sources[camera] = "return require(script.Parent.ControlModule)"
		local report = scanReport(world, api, "GameOnly")
		assert(#reads == 2 and reads[1] == gameScript and reads[2] == camera)
		assert(not world.childrenReads[module] and not world.childrenReads[camera])
		contains(report, "DIRECT GAME REFERENCE: " .. gameScript:GetFullName() .. " -> " .. camera:GetFullName())
		for _, read in ipairs(reads) do assert(read ~= controls and read ~= deeper) end
		api.Destroy()
	end)
	test(prefix .. "simple aliases service paths literal indexes and child lookups grant exact exceptions", function()
		local world, api, roots, sources, reads = fullFixture(deferred)
		local module, camera, controls = defaultTree(world, roots.PlayerScripts)
		local gameScript = child(world, "LocalScript", "PaintController", roots.ReplicatedStorage)
		sources[gameScript] = [[
local players = game:GetService("Players")
local player = players.LocalPlayer
local scripts = player:WaitForChild("PlayerScripts")
local pm = scripts:FindFirstChild("PlayerModule")
local c = require(pm["CameraModule"])
local d = require(game.Players.LocalPlayer.PlayerScripts.PlayerModule.ControlModule)
local root = require(pm)
]]
		scanReport(world, api, "GameOnly")
		assert(#reads == 4)
		local seen = {}; for _, object in ipairs(reads) do seen[object] = true end
		assert(seen[module] and seen[camera] and seen[controls])
		api.Destroy()
	end)
	test(prefix .. "references are cached and same module mentioned by several game scripts is read once", function()
		local world, api, roots, sources, reads = fullFixture(deferred)
		local module = defaultTree(world, roots.PlayerScripts)
		for _, name in ipairs({ "PaintA", "PaintB" }) do
			sources[child(world, "LocalScript", name, roots.PlayerScripts)] =
				"require(script.Parent.PlayerModule)\nrequire(script.Parent.PlayerModule)"
		end
		scanReport(world, api, "Quick")
		assert(#reads == 3 and reads[3] == module)
		local report = scanReport(world, api, "GameOnly")
		assert(#reads == 3 and api.GetDiagnosticScanState().Cached == 3)
		assert(occurrences(report, "DIRECT GAME REFERENCE:") == 1)
		api.Destroy()
	end)
	test(prefix .. "comments strings and long strings cannot open default-module exceptions", function()
		local world, api, roots, sources, reads = fullFixture(deferred)
		defaultTree(world, roots.PlayerScripts)
		local controller = child(world, "LocalScript", "PaintStrings", roots.PlayerScripts)
		sources[controller] = [====[
-- require(script.Parent.PlayerModule)
--[=[ require(script.Parent.PlayerModule.CameraModule) ]=]
local a = "require(script.Parent.PlayerModule)"
local b = 'require(script.Parent.PlayerModule.ControlModule)'
local c = [==[ require(script.Parent.PlayerModule) ]==]
local d = "PlayerModule"
local e = "quote \" require(script.Parent.PlayerModule)"
local f = 'quote \' require(script.Parent.PlayerModule)'
local g = 'x'
return {}
]====]
		local report = scanReport(world, api, "GameOnly")
		assert(#reads == 1 and not report:find("DIRECT GAME REFERENCE:", 1, true)); api.Destroy()
	end)
	test(prefix .. "dynamic reference failure does not expand scope and is recorded", function()
		local world, api, roots, sources, reads = fullFixture(deferred)
		defaultTree(world, roots.PlayerScripts)
		sources[child(world, "LocalScript", "PaintDynamic", roots.PlayerScripts)] =
			'local p = script.Parent.PlayerModule\np = unknown()\nrequire(p)\nrequire(script.Parent[name])\nrequire(findModule())'
		local report = scanReport(world, api, "GameOnly")
		assert(#reads == 1); contains(report, "unresolved/dynamic require expressions=3"); api.Destroy()
	end)
	test(prefix .. "reference never opens excluded CorePackages or other nonallowlisted roots", function()
		local world, api, roots, sources, reads = fullFixture(deferred)
		local core = child(world, "Folder", "CorePackages", world.env.game)
		child(world, "ModuleScript", "PaintModule", core)
		sources[child(world, "LocalScript", "PaintReferences", roots.ReplicatedStorage)] =
			'require(game.CorePackages.PaintModule)\nrequire(game.ExtraControllers.PaintModule)\nrequire(game.ReplicatedStorage.MissingModule)'
		child(world, "ModuleScript", "PaintModule", roots.Extra)
		local report = scanReport(world, api, "GameOnly")
		assert(#reads == 1 and not world.childrenReads[core] and not world.childrenReads[roots.Extra])
		contains(report, "static require path absent/unreadable")
		api.Destroy()
	end)
	test(prefix .. "a referenced default module uses same timeout cap and cached results", function()
		local world, api, roots = fullFixture(deferred)
		local module = defaultTree(world, roots.PlayerScripts)
		child(world, "LocalScript", "PaintController", roots.PlayerScripts)
		local calls = 0
		world.env.decompile = function(object)
			calls += 1
			if object == module then return coroutine.yield() end
			return "return require(script.Parent.PlayerModule)"
		end
		local report = scanReport(world, api, "GameOnly")
		assert(calls == 2 and api.GetDiagnosticScanState().TimedOut == 1)
		contains(report, module:GetFullName() .. " ClassName=ModuleScript Status=TIMED_OUT")
		scanReport(world, api, "GameOnly"); assert(calls == 2); api.Destroy()
	end)
	test(prefix .. "game-only cancel while stalled preserves report cache and stops future scripts", function()
		local world, api, roots = fullFixture(deferred)
		local a = child(world, "ModuleScript", "PaintA", roots.ReplicatedStorage)
		local b = child(world, "ModuleScript", "PaintB", roots.ReplicatedStorage)
		child(world, "ModuleScript", "PaintLater", roots.Workspace)
		local calls, worker = {}, nil
		world.env.decompile = function(object)
			table.insert(calls, object)
			if object == b then worker = coroutine.running(); return coroutine.yield() end
			return "PaintPart"
		end
		assert(api.StartDiagnosticScan("GameOnly")); world.step(0.5)
		assert(#calls == 2 and calls[1] == a)
		press(world, "CANCEL SCAN"); waitForScan(world, api)
		local copied; world.env.setclipboard = function(report) copied = report end
		press(world, "Copy Current Report"); assert(#calls == 2); contains(copied, "CANCELLED")
		assert(coroutine.resume(worker, "PaintPart"))
		scanReport(world, api, "GameOnly")
		assert(#calls == 3 and api.GetDiagnosticScanState().Cached == 2); api.Destroy()
	end)
	test(prefix .. "queued script moved into excluded ancestry is never inspected", function()
		local world, api, roots = fullFixture(deferred)
		local a = child(world, "ModuleScript", "PaintA", roots.PlayerScripts)
		local b = child(world, "ModuleScript", "PaintB", roots.PlayerScripts)
		local calls, worker = {}, nil
		world.env.decompile = function(object)
			table.insert(calls, object)
			assert(object == a); worker = coroutine.running(); return coroutine.yield()
		end
		assert(api.StartDiagnosticScan("GameOnly")); world.step(0.5)
		b.Parent = child(world, "Folder", "CorePackages", roots.PlayerScripts)
		assert(coroutine.resume(worker, "PaintPart"))
		local report = waitForScan(world, api)
		assert(#calls == 1); contains(report, "Status=SKIPPED_SCOPE"); api.Destroy()
	end)
	test(prefix .. "subtree enumeration failure does not hide readable siblings", function()
		local world, api, roots, _, reads = fullFixture(deferred)
		local broken = child(world, "Folder", "Broken", roots.ReplicatedStorage)
		child(world, "ModuleScript", "PaintHidden", broken)
		child(world, "ModuleScript", "PaintReadable", roots.ReplicatedStorage)
		world.childrenError = broken
		local report = scanReport(world, api, "GameOnly")
		assert(#reads == 1); contains(report, broken:GetFullName() .. ": GetChildren failed")
		api.Destroy()
	end)
	test(prefix .. "game-only discovery and inspection write no game state and stay locked", function()
		local world, api, roots, sources = fullFixture(deferred)
		sources[child(world, "ModuleScript", "PaintTrap", roots.ReplicatedFirst)] =
			'require(script.Parent.X)\nr:InvokeServer("PaintPart")\nLocalPlayer:SetAttribute("x",1)'
		local writes, attributes, connections = #world.writeLog, world.attributeWrites, world.connections
		scanReport(world, api, "GameOnly")
		noGameWrites(world, writes)
		assert(world.attributeWrites == attributes and world.connections == connections)
		assert(not api.SetDiagnostic(false))
		noTraffic(world, api); api.Destroy()
	end)
end
