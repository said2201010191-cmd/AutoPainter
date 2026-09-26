local Mock = require("./MockRoblox")
local NativeMock = {}
function NativeMock.new(deferred)
	local w = Mock.new(deferred)
	local Vec, vecmt = {}, {}
	vecmt.__index = function(v, key)
		if key == "Magnitude" then return math.sqrt(v.X*v.X + v.Y*v.Y + v.Z*v.Z) end
		if key == "Unit" then return v / v.Magnitude end
		return Vec[key]
	end
	local function v(x,y,z) return setmetatable({X=x,Y=y,Z=z or 0,_kind="Vector3"}, vecmt) end
	vecmt.__add=function(a,b) return v(a.X+b.X,a.Y+b.Y,a.Z+b.Z) end
	vecmt.__sub=function(a,b) return v(a.X-b.X,a.Y-b.Y,a.Z-b.Z) end
	vecmt.__mul=function(a,b)
		if type(b)=="number" then return v(a.X*b,a.Y*b,a.Z*b) end
		return v(a.X*b.X,a.Y*b.Y,a.Z*b.Z)
	end
	vecmt.__div=function(a,b) return v(a.X/b,a.Y/b,a.Z/b) end
	function Vec:Dot(b) return self.X*b.X + self.Y*b.Y + self.Z*b.Z end
	local Cf={}
	local function cf(pos,target)
		return setmetatable({Position=pos,LookVector=target and (target-pos).Unit or v(0,-1,0),target=target}, {__index=Cf})
	end
	function Cf:PointToWorldSpace(offset) w.pointTransforms+=1;return self.Position+offset end
	w.env.Vector3={new=v}
	w.env.CFrame={new=function(pos) return cf(pos or v(0,0,0)) end,lookAt=cf}
	w.v=v;w.cf=cf
	w.rayCount=0;w.pointTransforms=0
	w.cameraEvents={};w.parts={};w.nativeEvents={};w.nativePaints=0;w.button=false
	w.mouse=w.instance("Mouse")
	w.input.MouseEnabled=true;w.input.MouseBehavior=w.env.Enum.MouseBehavior.Default
	w.cursor=v(10,80);w.focus=true
	rawset(w.input,"GetMouseLocation",function() return w.cursor end)
	rawset(w.input,"IsMouseButtonPressed",function() return w.button end)
	rawset(w.input,"GetFocusedTextBox",function() return w.textFocused end)
	w.inset=v(0,36)
	w.gui={MenuIsOpen=false,GetGuiInset=function() return w.inset end}
	local originalGet=w.env.game.GetService
	w.env.game.GetService=function(self,name)
		if name=="GuiService" then return w.gui end
		return originalGet(self,name)
	end
	rawset(w.playerGui,"GetGuiObjectsAtPosition",function(_,x,y)
		if w.guiError then error("gui query denied") end
		if w.blockedGUI then return {w.blockedGUI} end
		return {}
	end)
	rawset(w.runService,"RenderStepped",w.signal())
	w.step=function(seconds,fps)
		local count=math.ceil(seconds*(fps or 60));local delta=seconds/count
		for _=1,count do
			w.now+=delta;w.flush();w.runService.RenderStepped:Fire(delta);w.flush()
			local before=w.workspace.CurrentCamera and w.workspace.CurrentCamera.CFrame
			w.runService.Heartbeat:Fire(delta);w.flush()
			local after=w.workspace.CurrentCamera and w.workspace.CurrentCamera.CFrame
			if before~=after then table.insert(w.cameraEvents,{at=w.now,frame=after}) end
		end
	end
	local function newCamera()
		local camera=w.instance("Camera")
		camera.CFrame=cf(v(0,100,0));camera.Focus=cf(v(0,0,0));camera.CameraType=w.env.Enum.CameraType.Custom
		camera.ViewportSize=v(800,600);camera.FieldOfView=70;camera.Parent=w.workspace
		rawset(camera,"WorldToViewportPoint",function(_,point)
			local focus=camera.CFrame.target or v(0,0,0)
			local p=v(point.X-focus.X+400, point.Z-focus.Z+300,1)
			return p,p.X>=0 and p.X<800 and p.Y>=0 and p.Y<600
		end)
		rawset(camera,"WorldToScreenPoint",function(_,point) local p,on=camera:WorldToViewportPoint(point);return p-w.inset,on end)
		rawset(camera,"ViewportPointToRay",function(_,x,y) return {Origin=camera.CFrame.Position,Direction=v(x,y,1)} end)
		return camera
	end
	w.newCamera=newCamera
	w.workspace.CurrentCamera=newCamera()
	local function atScreen(x,y)
		if w.forceMiss then return nil end
		if w.forceTarget then return w.forceTarget end
		for _,p in ipairs(w.parts) do
			if p.Parent==w.provinces and not (w.occluded and w.occluded[p]) then
				local pt,onscreen=w.workspace.CurrentCamera:WorldToViewportPoint(p.Position)
				if onscreen and math.abs(x-pt.X)<=p.Size.X/2 and math.abs(y-pt.Y)<=p.Size.Z/2 then return p end
			end
		end
		return nil
	end
	rawset(w.workspace,"Raycast",function(_,origin,direction)
		w.rayCount+=1
		local x,y=direction.X/direction.Z,direction.Y/direction.Z
		local hit=atScreen(x,y)
		if w.rayRule then hit=w.rayRule(x,y,hit) end
		return hit and {Instance=hit} or nil
	end)
	local originalEquip=w.equip
	w.equip=function()
		originalEquip()
		w.bucket.Enabled=true
		local hum=w.instance("Humanoid");hum.Health=100;hum.Parent=w.character
		w.humanoid=hum
	end
	w.equip()
	w.provinces=w.instance("Folder");w.provinces.Name="Provinces";w.provinces.Parent=w.workspace
	w.province=function(x,z)
		local p=w.instance("Part");p.Name="Province";p.Position=v(x or (#w.parts*50),0,z or 0)
		p.Size=v(30,1,30);p.CFrame=cf(p.Position);p.Color=w.Color3.new(0,0,0);p.Parent=w.provinces
		table.insert(w.parts,p);return p
	end
	local function move(x,y)
		if w.moveError then error("move failed") end
		table.insert(w.nativeEvents,{kind="move",at=w.now,x=x,y=y})
		w.cursor=v(x,y)
		local function propagate()
			if not w.staleMouse then
				local target=atScreen(x,y)
				w.mouse.Target=w.noMouseTargets and w.noMouseTargets[target] and nil or target
				if w.noMouseTargets and w.noMouseTargets[target] then w.mouse.Target=nil end
			end
			w.mouse.Move:Fire()
		end
		if w.moveDelay then w.schedule(w.moveDelay,propagate) else propagate() end
	end
	w.env.mousemoverel=function(dx,dy)
		table.insert(w.nativeEvents,{kind="relative",at=w.now,dx=dx,dy=dy})
		move(w.cursor.X+dx*(w.relativeGain or 1),w.cursor.Y+dy*(w.relativeGain or 1))
	end
	w.env.mousemoveabs=function(x,y)
		table.insert(w.nativeEvents,{kind="absolute",at=w.now,x=x,y=y})
		local offset=w.absoluteOffset or v(0,0);move(x+offset.X,y+offset.Y)
	end
	w.env.isrbxactive=function() return w.focus end
	w.env.mouse1press=function()
		table.insert(w.nativeEvents,{kind="down",at=w.now,part=w.mouse.Target,color=w.player:GetAttribute("PaintBucketColor")})
		w.button=true
		if w.pressError then error("press failed after changing input") end
		if not w.suppressDown then
			if w.downDelay then w.schedule(w.downDelay,function() w.mouse.Button1Down:Fire() end) else w.mouse.Button1Down:Fire() end
			if w.simulateNative then
				local function tick()
					if not w.button then return end
					w.nativePaints+=1
					if w.nativePaint then w.nativePaint(w.mouse.Target,w.player:GetAttribute("PaintBucketColor")) end
					w.schedule(0.1,tick)
				end
				tick()
			end
		end
	end
	w.env.mouse1release=function()
		table.insert(w.nativeEvents,{kind="up",at=w.now})
		if w.releaseError then error("release failed") end
		w.button=false
		if not w.suppressUp then
			if w.upDelay then w.schedule(w.upDelay,function() w.mouse.Button1Up:Fire() end) else w.mouse.Button1Up:Fire() end
		end
	end
	w.manualUp=function() w.button=false;w.mouse.Button1Up:Fire();w.flush() end
	w.manualTarget=function(part) w.mouse.Target=part;w.mouse.Move:Fire();w.flush() end
	w.eventCount=function(kind)
		local n=0;for _,e in ipairs(w.nativeEvents) do if e.kind==kind then n+=1 end end;return n
	end
	return w
end
return NativeMock
