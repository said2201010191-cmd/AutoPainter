-- Deterministic Luau mock, not a Roblox engine/network benchmark.
local Mock = {}
function Mock.new(deferredSignals)
	local world = { now = 0, events = {}, calls = {}, active = 0, peak = 0,
		connections = 0, errors = {}, behavior = {}, objects = {}, activeParts = {},
		activeColors = {}, peakParts = {}, contributions = {}, perPartLimit = 6,
		taskSpawns = 0, taskDefers = 0, networkAttempts = 0,
		propertyWrites = 0, attributeWrites = 0, descendantReads = 0, childrenReads = {}, writeLog = {}, waits = 0 }
	local function resume(thread, ...)
		local ok, err = coroutine.resume(thread, ...)
		if not ok then table.insert(world.errors, tostring(err)) end
	end
	local function spawn(fn, ...)
		local thread = type(fn) == "thread" and fn or coroutine.create(fn)
		resume(thread, ...)
		return thread
	end
	function world.schedule(delay, fn, ...)
		table.insert(world.events, { at = world.now + delay, fn = fn, args = table.pack(...) })
	end
	local function signal()
		local listeners = {}
		local event = {}
		function event:Connect(fn)
			local connection = { Connected = true }
			listeners[connection] = fn
			world.connections += 1
			function connection:Disconnect()
				if self.Connected then
					self.Connected = false; listeners[self] = nil; world.connections -= 1
				end
			end
			return connection
		end
		function event:Fire(...)
			for connection, fn in pairs(table.clone(listeners)) do
				if connection.Connected then
					if deferredSignals then
						local args = table.pack(...)
						world.schedule(0, function()
							if connection.Connected then fn(table.unpack(args, 1, args.n)) end
						end)
					else spawn(fn, ...) end
				end
			end
		end
		function event:Clear()
			for connection in pairs(table.clone(listeners)) do connection:Disconnect() end
		end
		return event
	end
	world.signal = signal
	local methods = {}
	local mt = {}
	function mt.__index(object, key)
		if key == "Source" and world.forbidSourceRead then error("Unexpected direct Source read") end
		if methods[key] then return methods[key] end
		if object._props[key] ~= nil then return object._props[key] end
		return object._signals[key]
	end
	local function ancestry(object)
		object._signals.AncestryChanged:Fire(object, object.Parent)
		for _, child in ipairs(object._children) do ancestry(child) end
	end
	function mt.__newindex(object, key, value)
		world.propertyWrites += 1
		table.insert(world.writeLog, { object = object, key = key })
		local old = object._props[key]
		if old == value then return end
		if key == "Parent" and old then
			local function removing(child, ancestor)
				ancestor.DescendantRemoving:Fire(child)
				for _, descendant in ipairs(child._children) do removing(descendant, ancestor) end
			end
			local ancestor = old
			while ancestor do removing(object, ancestor); ancestor = ancestor.Parent end
		end
		object._props[key] = value
		if key == "Parent" then
			if old then
				local index = table.find(old._children, object)
				if index then table.remove(old._children, index) end
				old.ChildRemoved:Fire(object)
			end
			if value then table.insert(value._children, object); value.ChildAdded:Fire(object) end
			ancestry(object)
		end
		if object._changed[key] then object._changed[key]:Fire() end
	end
	function world.instance(class)
		local object = setmetatable({ _props = { ClassName = class, Name = class },
			_children = {}, _signals = {}, _changed = {}, _attributes = {}, _destroyed = false }, mt)
		for _, name in ipairs({ "AncestryChanged", "Destroying", "ChildAdded", "ChildRemoved", "DescendantRemoving",
			"Activated", "InputBegan", "InputChanged", "InputEnded", "TouchTapInWorld", "Heartbeat",
			"Button1Down", "Button1Up", "Move", "WindowFocused", "WindowFocusReleased", "FocusLost" }) do
			object._signals[name] = signal()
		end
		table.insert(world.objects, object)
		return object
	end
	function methods:IsA(class)
		return self.ClassName == class or (class == "BasePart" and self.ClassName == "Part")
			or (class == "ValueBase" and table.find({ "Color3Value", "StringValue", "NumberValue", "BoolValue", "IntValue", "ObjectValue" }, self.ClassName) ~= nil)
	end
	function methods:IsDescendantOf(parent)
		local current = self.Parent
		while current do if current == parent then return true end; current = current.Parent end
		return false
	end
	function methods:FindFirstChild(name)
		for _, child in ipairs(self._children) do if child.Name == name then return child end end
		return nil
	end
	function methods:FindFirstChildOfClass(class)
		for _, child in ipairs(self._children) do if child.ClassName == class then return child end end
		return nil
	end
	function methods:GetChildren()
		world.childrenReads[self] = (world.childrenReads[self] or 0) + 1
		if world.childrenError == self then error("Injected GetChildren read failure") end
		if world.childrenView and world.childrenView[self] then return table.clone(world.childrenView[self]) end
		return table.clone(self._children)
	end
	function methods:GetDescendants()
		world.descendantReads += 1
		if world.descendantError == self then error("Injected GetDescendants read failure") end
		local descendants, stack = {}, table.clone(self._children)
		while #stack > 0 do
			local object = table.remove(stack)
			table.insert(descendants, object)
			for _, child in ipairs(object._children) do table.insert(stack, child) end
		end
		if world.reverseDescendants then
			for i = 1, math.floor(#descendants / 2) do
				local other = #descendants - i + 1
				descendants[i], descendants[other] = descendants[other], descendants[i]
			end
		end
		return descendants
	end
	function methods:GetFullName()
		local names, object = {}, self
		while object do table.insert(names, 1, object.Name); object = object.Parent end
		return table.concat(names, ".")
	end
	function methods:SetAttribute(name, value)
		world.attributeWrites += 1
		local before = self._attributes[name]
		self._attributes[name] = value
		if before ~= value and self._attributeSignals and self._attributeSignals[name] then self._attributeSignals[name]:Fire() end
	end
	function methods:GetAttributeChangedSignal(name)
		if not self._attributeSignals then rawset(self, "_attributeSignals", {}) end
		if not self._attributeSignals[name] then self._attributeSignals[name] = signal() end
		return self._attributeSignals[name]
	end
	function methods:GetAttribute(name) return self._attributes[name] end
	function methods:GetAttributes()
		if world.attributesError == self then error("Injected GetAttributes read failure") end
		return table.clone(self._attributes)
	end
	function methods:GetState() return "Running" end
	function methods:WaitForChild(name) return assert(self:FindFirstChild(name), name) end
	function methods:GetPropertyChangedSignal(name)
		if not self._changed[name] then self._changed[name] = signal() end
		return self._changed[name]
	end
	function methods:Destroy()
		if self._destroyed then return end
		self._destroyed = true
		self.Destroying:Fire()
		for _, child in ipairs(table.clone(self._children)) do child:Destroy() end
		self.Parent = nil
		for _, event in pairs(self._signals) do event:Clear() end
		for _, event in pairs(self._changed) do event:Clear() end
	end
	function methods:GetMouse() return world.mouse end
	function methods:GetFocusedTextBox() return nil end
	function methods:Invoke(...) return self.OnInvoke(...) end
	function methods:InvokeServer(command, payload, context)
		world.networkAttempts += 1
		if world.onInvoke then world.onInvoke(payload.Part, payload.Color) end
		assert(self:IsA("RemoteFunction"))
		assert(command == "PaintPart" and context == "Peace")
		assert(payload.Part and payload.Color)
		local active = world.activeParts[payload.Part] or 0
		assert(active < world.perPartLimit, "Per-province cap exceeded")
		assert(active == 0 or world.activeColors[payload.Part] == payload.Color, "Different target colors overlapped")
		world.activeParts[payload.Part] = active + 1
		world.activeColors[payload.Part] = payload.Color
		world.peakParts[payload.Part] = math.max(world.peakParts[payload.Part] or 0, active + 1)
		world.active += 1; world.peak = math.max(world.peak, world.active)
		assert(world.active <= 64, "Global hard cap exceeded")
		local behavior = world.behavior
		local call = { at = world.now, part = payload.Part, color = payload.Color,
			remote = self, thread = coroutine.running(), done = false, concurrent = active + 1 }
		table.insert(world.calls, call)
		local callIndex = #world.calls
		if not behavior.hang then
			local latency = type(behavior.latency) == "function" and behavior.latency(world.active, payload.Part, callIndex) or (behavior.latency or 0.10)
			world.schedule(latency, function()
				local errors = behavior.errors
				if type(errors) == "function" then errors = errors(payload.Part, callIndex) end
				local success = not errors
				local noPaint = behavior.noPaint
				if type(noPaint) == "function" then noPaint = noPaint(payload.Part) end
				local progress = world.contributions[payload.Part] or {}
				world.contributions[payload.Part] = progress
				if success then progress[payload.Color] = (progress[payload.Color] or 0) + 1 end
				local required = behavior.hitsRequired or 1
				if type(required) == "function" then required = required(payload.Part) end
				if success and not noPaint and progress[payload.Color] >= required then
					if behavior.replicationDelay then
						world.schedule(behavior.replicationDelay, function()
							if not payload.Part._destroyed then payload.Part.Color = payload.Color end
						end)
					elseif not payload.Part._destroyed then payload.Part.Color = payload.Color end
				end
				world.complete(call, success)
			end)
		end
		local ok = coroutine.yield()
		if not ok then error("Injected InvokeServer failure") end
		return behavior.returnValue -- nil/false/other responses are not interpreted by production.
	end
	function methods:FireServer()
		world.networkAttempts += 1
		error("Unexpected RemoteEvent invocation")
	end
	function world.complete(call, success)
		assert(not call.done)
		call.done = true; world.active -= 1
		world.activeParts[call.part] -= 1
		if world.activeParts[call.part] == 0 then
			world.activeParts[call.part], world.activeColors[call.part] = nil, nil
		end
		resume(call.thread, success)
	end
	function world.flush()
		local passes = 0
		while true do
			local index, at = nil, math.huge
			for i, event in ipairs(world.events) do
				if event.at <= world.now and event.at < at then index, at = i, event.at end
			end
			if not index then break end
			local event = table.remove(world.events, index)
			spawn(event.fn, table.unpack(event.args, 1, event.args.n))
			passes += 1
			assert(passes < 100000, "Unbounded same-frame work")
		end
		assert(#world.errors == 0, table.concat(world.errors, "\n"))
	end
	function world.step(seconds, fps)
		local count = math.ceil(seconds * (fps or 60))
		local delta = seconds / count
		for _ = 1, count do
			world.now += delta
			world.flush()
			world.runService.Heartbeat:Fire(delta)
			world.flush()
		end
	end
	local colors = {}
	local function color(r, g, b)
		local key = tostring(r) .. "/" .. tostring(g) .. "/" .. tostring(b)
		if not colors[key] then colors[key] = { R = r, G = g, B = b, _kind = "Color3" } end
		return colors[key]
	end
	world.Color3 = { new = color, fromRGB = function(r, g, b) return color(r / 255, g / 255, b / 255) end }
	local function udim(scale, offset) return { Scale = scale or 0, Offset = offset or 0 } end
	local function udim2(xs, xo, ys, yo) return { X = udim(xs, xo), Y = udim(ys, yo) } end
	world.workspace = world.instance("Workspace")
	world.player = world.instance("Player")
	world.playerGui = world.instance("PlayerGui"); world.playerGui.Parent = world.player
	world.runService = world.instance("RunService")
	world.input = world.instance("UserInputService")
	world.mouse = {}
	function world.equip()
		local character = world.instance("Model"); character.Parent = world.workspace
		local bucket = world.instance("Tool"); bucket.Name = "PaintBucket"; bucket.Parent = character
		local remotes = world.instance("Folder"); remotes.Name = "Remotes"; remotes.Parent = bucket
		local remote = world.instance("RemoteFunction"); remote.Name = "ServerControls"; remote.Parent = remotes
		world.player.Character = character
		world.character, world.bucket, world.remotes, world.remote = character, bucket, remotes, remote
		return remote
	end
	function world.province()
		local part = world.instance("Part"); part.Name = "Province"
		part.Color = color(0, 0, 0); part.Parent = world.workspace
		return part
	end
	world.equip()
	local enum = setmetatable({}, { __index = function(self, key)
		local category = setmetatable({}, { __index = function(_, member) return key .. "." .. member end })
		rawset(self, key, category); return category
	end })
	world.otherPlayers = {}
	local services = { Players = { LocalPlayer = world.player,
		GetPlayers = function()
			local result = table.clone(world.otherPlayers); table.insert(result, world.player); return result
		end,
		GetPlayerFromCharacter = function(_, character)
			if world.player.Character == character then return world.player end
			for _, other in ipairs(world.otherPlayers) do if other.Character == character then return other end end
			return nil
		end }, RunService = world.runService,
		UserInputService = world.input, Workspace = world.workspace }
	world.env = setmetatable({
		game = { GetService = function(_, name) return assert(services[name]) end },
		Instance = { new = world.instance }, Color3 = world.Color3, Enum = enum,
		Vector2 = { new = function(x, y) return { X = x, Y = y } end },
		UDim = { new = udim }, UDim2 = { new = udim2,
			fromOffset = function(x, y) return udim2(0, x, 0, y) end,
			fromScale = function(x, y) return udim2(x, 0, y, 0) end },
		RaycastParams = { new = function() return {} end },
		typeof = function(value) return type(value) == "table" and value._kind or type(value) end,
		os = { clock = function() return world.now end },
		task = {
			wait = function(duration)
				world.waits += 1
				local thread = coroutine.running()
				world.schedule(math.max(duration or 1 / 60, 1 / 60), function() resume(thread) end)
				return coroutine.yield()
			end,
			spawn = function(fn, ...) world.taskSpawns += 1; return spawn(fn, ...) end,
			defer = function(fn, ...) world.taskDefers += 1; world.schedule(0, fn, ...) end,
		},
	}, { __index = getfenv() })
	function world.load(source, options)
		local chunk = assert(loadstring(source, "AutoPainterFinal"))
		setfenv(chunk, world.env)
		local api = chunk(options)
		world.flush()
		return api
	end
	return world
end
return Mock
