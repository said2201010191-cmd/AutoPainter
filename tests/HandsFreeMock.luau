local Native = require("./NativeMock")
local Mock = {}
function Mock.new(deferred)
	local w = Native.new(deferred)
	w.backpack=w.instance("Backpack");w.backpack.Parent=w.player
	w.activationEvents={};w.responses={};w.downs={};w.ups={};w.activeMethod=nil
	w.color=w.Color3.new(1,0,0);w.player:SetAttribute("PaintBucketColor",w.color)
	w.env.Color3.fromHSV=function(h,s,v) return w.Color3.new(h,s,v) end
	local function waitFrame() return w.env.task.wait(1/60) end
	rawset(w.runService.Heartbeat,"Wait",waitFrame)
	rawset(w.runService.RenderStepped,"Wait",function()
		waitFrame()
		if not w.noAcquire then
			local focus=w.workspace.CurrentCamera.Focus.Position
			for _,p in ipairs(w.parts) do if (p.Position-focus).Magnitude<p.Size.Magnitude then w.mouse.Target=p;break end end
		end
	end)
	-- Camera acquisition itself stays byte-for-byte unchanged; these minimal vectors
	-- support its already-target-acquired path without simulating Roblox geometry.
	w.env.CFrame.lookAt=function(pos,target)
		local c=w.cf(pos,target);c.UpVector=w.v(0,1,0);c.RightVector=w.v(1,0,0);return c
	end
	local province=w.province
	w.province=function(x,z)
		local p=province(x,z);p.CFrame.UpVector=w.v(0,1,0);p.CFrame.RightVector=w.v(1,0,0);return p
	end
	rawset(w.bucket,"Deactivated",w.signal());rawset(w.bucket,"Equipped",w.signal())
	w.toolMouse=w.instance("Mouse")
	rawset(w.humanoid,"UnequipTools",function() w.bucket.Parent=w.backpack end)
	rawset(w.humanoid,"EquipTool",function(_,tool) tool.Parent=w.character;tool.Equipped:Fire(w.toolMouse) end)
	local function down(name)
		assert(not w.activeMethod,"Overlapping activation methods")
		w.activeMethod=name;w.downs[name]=(w.downs[name] or 0)+1
		table.insert(w.activationEvents,{kind="down",method=name,at=w.now,part=w.mouse.Target})
		local r=w.responses[name] or {}
		if r.delay then w.env.task.wait(r.delay) end
		if r.throw then error("down denied") end
		if r.mouse then w.button=true;w.mouse.Button1Down:Fire() end
		if r.equippedMouse then w.toolMouse.Button1Down:Fire() end
		if r.tool or name=="Tool:Activate" then w.bucket.Activated:Fire() end
		if r.paint then
			w.schedule(r.paintDelay or 0.05,function()
				if w.activeMethod==name and w.mouse.Target then
					w.mouse.Target.Color=r.wrongColor or w.player:GetAttribute("PaintBucketColor")
				end
			end)
		end
	end
	local function up(name)
		table.insert(w.activationEvents,{kind="up",method=name,at=w.now})
		w.ups[name]=(w.ups[name] or 0)+1
		local r=w.responses[name] or {}
		if r.upThrow then error("up denied") end
		local function finish()
			w.activeMethod=nil;w.button=false
			if r.noUp then return end
			if r.mouse then w.mouse.Button1Up:Fire() end
			if r.equippedMouse then w.toolMouse.Button1Up:Fire() end
			if r.tool or name=="Tool:Activate" then w.bucket.Deactivated:Fire() end
		end
		if r.upDelay then w.schedule(r.upDelay,finish) else finish() end
	end
	w.env.mouse1press=function() down("mouse1press") end
	w.env.mouse1release=function() up("mouse1press") end
	rawset(w.input,"CreateVirtualInput",function()
		w.virtualDiscoveries=(w.virtualDiscoveries or 0)+1
		if w.virtualDenied then error("unavailable") end
		if not w.virtualAvailable then return nil end
		return {SendMouseButton=function(_,pos,button,isDown,repeats)
			assert(pos==w.cursor and button==w.env.Enum.UserInputType.MouseButton1 and repeats==0)
			if isDown then down("VirtualInput.SendMouseButton") else up("VirtualInput.SendMouseButton") end
		end}
	end)
	rawset(w.bucket,"Activate",function() down("Tool:Activate") end)
	rawset(w.bucket,"Deactivate",function() up("Tool:Activate") end)
	w.begin=function(api)
		w.env.task.spawn(function() w.started=api.Start() end)
		w.step(0.25)
	end
	w.findText=function(text)
		for _,o in ipairs(w.objects) do if o.Text==text and not o._destroyed then return o end end
	end
	return w
end
return Mock
