local Mock=require("./NativeMock")
local passed=0
local function test(name,fn) fn();passed+=1;print("PASS",name) end
local function start(deferred,options)
	local w=Mock.new(deferred)
	local api=w.load(SOURCE,options)
	return w,api
end
local function button(w,text)
	for _,obj in ipairs(w.objects) do
		if obj.ClassName=="TextButton" and obj.Text==text and obj:IsDescendantOf(w.playerGui) then
			obj.Activated:Fire();w.flush();return
		end
	end
	error("Missing button "..text)
end
local function add(w,api,n)
	local parts={}
	for _=1,n do local p=w.province();api.AddProvince(p);table.insert(parts,p) end
	api.CommitSelections();return parts
end
local function zeroRPC(w,api)
	assert(w.networkAttempts==0 and #w.calls==0 and api.GetStats().AutoPainterRPCs==0)
	assert(#w.errors==0,table.concat(w.errors,"\n"))
end
local function verify(w,api,p)
	assert(api.SetTestTarget(p));assert(api.TestNativeInput())
	w.step(1.6)
	assert(api.GetStats().Tested,api.GetStats().TestResult)
	assert(not api.GetStats().Held and not api.GetStats().Releasing)
	zeroRPC(w,api)
end
local function waitHold(w,api,maximum)
	local endTime=w.now+(maximum or 4)
	while api.GetStats().State~="HOLD" and w.now<endTime do w.step(0.02) end
	assert(api.GetStats().State=="HOLD","Did not hold: "..api.GetStats().State.." "..api.GetStats().TestResult)
end
for _,deferred in ipairs({false,true}) do
	local prefix=deferred and "deferred native: " or "immediate native: "
	test(prefix.."startup and callable detection never move click or paint",function()
		local w,api=start(deferred)
		w.step(10);assert(#w.nativeEvents==0 and not api.GetStats().Painting)
		local c=api.GetCapabilities();assert(c.Callable and c.Move=="mousemoverel" and not c.Tested)
		assert(not api.SetPainting(true));zeroRPC(w,api);api.Destroy()
	end)
	test(prefix.."unsupported APIs report unavailable without fallback",function()
		local w=Mock.new(deferred);w.env.mouse1release=nil
		local api=w.load(SOURCE);add(w,api,1);assert(not api.GetCapabilities().Callable)
		assert(not api.TestNativeInput());assert(not api.SetPainting(true));w.step(3)
		assert(#w.nativeEvents==0);zeroRPC(w,api);api.Destroy()
	end)
	test(prefix.."absolute mover is used when relative mover unavailable",function()
		local w=Mock.new(deferred);w.env.mousemoverel=nil
		local api=w.load(SOURCE);local p=add(w,api,1)[1]
		assert(api.GetCapabilities().Move=="mousemoveabs");verify(w,api,p);api.Destroy()
	end)
	test(prefix.."actual Add click path creates twenty pending highlights without any input",function()
		local w,api=start(deferred)
		button(w,"Protect Province")
		for _=1,20 do
			local p=w.province()
			w.mouse.Target=p
			w.input.InputBegan:Fire({UserInputType=w.env.Enum.UserInputType.MouseButton1},false);w.flush()
		end
		local s=api.GetStats();assert(s.PendingSelections==20 and s.Dirty==0)
		local count=0;for _,o in ipairs(w.objects) do if o.ClassName=="SelectionBox" and o.Parent then count+=1 end end
		assert(count==20);w.step(10);assert(#w.nativeEvents==0)
		button(w,"Add · Done / Cancel")
		assert(api.GetStats().Dirty==20 and not api.GetStats().Painting);assert(#w.nativeEvents==0)
		zeroRPC(w,api);api.Destroy()
	end)
	test(prefix.."explicit chosen visible test performs one real-target down and up then stops",function()
		local w,api=start(deferred);local p=add(w,api,1)[1]
		w.simulateNative=true
		verify(w,api,p)
		assert(w.eventCount("down")==1 and w.eventCount("up")==1 and w.nativePaints>=3)
		local e;for _,event in ipairs(w.nativeEvents) do if event.kind=="down" then e=event end end
		assert(e.part==p);assert(not api.GetStats().Painting)
		w.step(5);assert(w.eventCount("down")==1);zeroRPC(w,api);api.Destroy()
	end)
	test(prefix.."test selection UI requires prior commitment and never auto-runs a test",function()
		local w,api=start(deferred);local p=add(w,api,1)[1]
		button(w,"Choose Test Province");w.mouse.Target=p
		w.input.InputBegan:Fire({UserInputType=w.env.Enum.UserInputType.MouseButton1},false);w.flush()
		assert(api.GetStats().TestTarget==p and #w.nativeEvents==0)
		button(w,"Test Target · Done / Cancel")
		button(w,"TEST NATIVE INPUT");w.step(1.6)
		assert(api.GetStats().Tested);zeroRPC(w,api);api.Destroy()
	end)
	test(prefix.."test refuses offscreen province and never moves the camera",function()
		local w,api=start(deferred);local p=w.province(2000);api.AddProvince(p);api.CommitSelections()
		local cam=w.workspace.CurrentCamera;local frame=cam.CFrame
		assert(api.SetTestTarget(p));assert(not api.TestNativeInput());assert(cam.CFrame==frame and #w.nativeEvents==0)
		zeroRPC(w,api);api.Destroy()
	end)
	test(prefix.."stale or wrong genuine Mouse.Target prevents every down",function()
		local w,api=start(deferred);local p=add(w,api,1)[1]
		w.staleMouse=true;w.mouse.Target=nil
		assert(api.SetTestTarget(p));assert(api.TestNativeInput());w.step(3)
		assert(not api.GetStats().Tested and w.eventCount("down")==0);zeroRPC(w,api);api.Destroy()
	end)
	test(prefix.."down function without native event fails instead of authorizing automation",function()
		local w,api=start(deferred);local p=add(w,api,1)[1];w.suppressDown=true
		assert(api.SetTestTarget(p));assert(api.TestNativeInput());w.step(2)
		assert(not api.GetStats().Tested and w.eventCount("up")==1 and not w.button)
		assert(not api.SetPainting(true));zeroRPC(w,api);api.Destroy()
	end)
	test(prefix.."missing up event prevents any next target or new press until manual up",function()
		local w,api=start(deferred);local p=add(w,api,2)[1];w.suppressUp=true
		assert(api.SetTestTarget(p));assert(api.TestNativeInput());w.step(3)
		assert(not api.GetStats().Tested and api.GetStats().Releasing and w.eventCount("down")==1)
		assert(not api.SetPainting(true));w.manualUp();w.step(1)
		assert(not api.GetStats().Releasing);zeroRPC(w,api);api.Destroy()
	end)
	test(prefix.."normal hold delegates native repeats rather than clicking each cooldown",function()
		local w,api=start(deferred);local p=add(w,api,1)[1];verify(w,api,p)
		w.simulateNative=true;local downs=w.eventCount("down")
		assert(api.SetPainting(true));waitHold(w,api);w.step(1.5)
		assert(w.eventCount("down")==downs+1 and w.nativePaints>=10 and api.GetStats().Held)
		api.EmergencyStop();w.step(1);assert(not w.button);zeroRPC(w,api);api.Destroy()
	end)
	test(prefix.."target color observation releases immediately without attributing RPC success",function()
		local w,api=start(deferred);local p=add(w,api,1)[1];verify(w,api,p)
		api.SetPainting(true);waitHold(w,api)
		p.Color=api.GetColor();w.flush()
		assert(w.eventCount("up")==2 and not w.button)
		w.step(2);assert(api.GetStats().Dirty==0 and api.GetStats().NativeRPCs=="unobserved")
		zeroRPC(w,api);api.Destroy()
	end)
	test(prefix.."real target loss releases and cannot paint a replacement via controller",function()
		local w,api=start(deferred);local p=add(w,api,1)[1];verify(w,api,p)
		api.SetPainting(true);waitHold(w,api)
		w.manualTarget(w.province(250))
		assert(not w.button);assert(api.GetStats().Releasing)
		api.EmergencyStop();w.step(1);zeroRPC(w,api);api.Destroy()
	end)
	test(prefix.."dwell rotates fairly across dirty targets despite heavy priority",function()
		local w,api=start(deferred);local parts=add(w,api,4);verify(w,api,parts[1])
		api.SetDwell(0.25);api.SetPriority(parts[1]);api.SetPainting(true)
		w.step(20)
		local seen={};for _,e in ipairs(w.nativeEvents) do if e.kind=="down" then seen[e.part]=true end end
		for _,p in ipairs(parts) do assert(seen[p],"Target starved") end
		zeroRPC(w,api);api.Destroy();w.flush()
	end)
	test(prefix.."priority dwell is longer but bounded and emergency stop still releases",function()
		local w,api=start(deferred);local p=add(w,api,1)[1];verify(w,api,p)
		api.SetDwell(0.5);api.SetPriority(p);api.SetPainting(true);waitHold(w,api)
		w.step(0.7);assert(w.button)
		w.step(0.4);assert(not w.button)
		api.EmergencyStop();zeroRPC(w,api);api.Destroy();w.flush()
	end)
	test(prefix.."camera automation targets an offscreen province and restores camera on pause",function()
		local w,api=start(deferred);local p=add(w,api,1)[1];verify(w,api,p)
		p.Color=api.GetColor();w.flush()
		local far=w.province(2000);api.AddProvince(far);api.CommitSelections()
		local camera=w.workspace.CurrentCamera;local original=camera.CFrame
		api.SetPainting(true);waitHold(w,api)
		assert(api.GetStats().Target==far and camera.CameraType==w.env.Enum.CameraType.Scriptable)
		api.EmergencyStop();w.step(1)
		assert(camera.CFrame==original and camera.CameraType==w.env.Enum.CameraType.Custom)
		zeroRPC(w,api);api.Destroy()
	end)
	test(prefix.."visible-only never moves camera to reach offscreen province",function()
		local w,api=start(deferred);local p=add(w,api,1)[1];verify(w,api,p)
		p.Color=api.GetColor();local far=w.province(2000);api.AddProvince(far);api.CommitSelections();w.flush()
		local camera=w.workspace.CurrentCamera;local original=camera.CFrame
		api.SetVisibleOnly(true);api.SetPainting(true);w.step(4)
		assert(camera.CFrame==original and w.eventCount("down")==1);zeroRPC(w,api);api.Destroy()
	end)
	test(prefix.."camera disabled still moves real cursor between visible targets",function()
		local w,api=start(deferred);local parts=add(w,api,2);verify(w,api,parts[1])
		local camera=w.workspace.CurrentCamera;local original=camera.CFrame
		api.SetCameraAutomation(false);api.SetDwell(0.25);api.SetPainting(true);w.step(6)
		assert(w.eventCount("down")>=3 and camera.CFrame==original);zeroRPC(w,api);api.Destroy();w.flush()
	end)
	test(prefix.."GUI obstruction and occlusion prevent native down",function()
		local w,api=start(deferred);local p=add(w,api,1)[1]
		local b=w.instance("TextButton");b.Visible=true;w.blockedGUI=b
		assert(api.SetTestTarget(p));assert(api.TestNativeInput());w.step(3)
		assert(w.eventCount("down")==0)
		w.blockedGUI=nil;w.occluded={[p]=true}
		assert(api.TestNativeInput());w.step(3);assert(w.eventCount("down")==0)
		zeroRPC(w,api);api.Destroy()
	end)
	test(prefix.."global color country pick and R synchronize existing bucket attribute with no input",function()
		local w,api=start(deferred);local p=add(w,api,1)[1]
		local red=w.Color3.new(1,0,0);api.SetColor(red);assert(w.player:GetAttribute("PaintBucketColor")==red)
		p.Color=w.Color3.new(0,0,1);button(w,"Country Color / Pick");w.mouse.Target=p
		w.input.InputBegan:Fire({UserInputType=w.env.Enum.UserInputType.MouseButton1},false);w.flush()
		assert(api.GetColor()==p.Color)
		w.input.InputBegan:Fire({KeyCode=w.env.Enum.KeyCode.R},false);w.flush()
		assert(w.player:GetAttribute("PaintBucketColor")==api.GetColor())
		w.step(1);assert(#w.nativeEvents==0);zeroRPC(w,api);api.Destroy()
	end)
	test(prefix.."Keep snapshots use per-target native color then restore manual bucket global color",function()
		local w,api=start(deferred);api.SetKeepColor(true)
		local red,blue=w.Color3.new(1,0,0),w.Color3.new(0,0,1)
		api.SetColor(red);local a=add(w,api,1)[1];verify(w,api,a)
		api.SetColor(blue);local b=add(w,api,1)[1]
		api.SetPriority(a);api.SetPainting(true);waitHold(w,api)
		assert(api.GetColor()==blue and w.player:GetAttribute("PaintBucketColor")==red)
		api.EmergencyStop();w.step(1);assert(w.player:GetAttribute("PaintBucketColor")==blue)
		api.RemoveProvince(a);api.SetPriority(b);api.SetPainting(true);waitHold(w,api)
		assert(w.player:GetAttribute("PaintBucketColor")==blue);zeroRPC(w,api);api.Destroy();w.flush()
	end)
	test(prefix.."Keep off retargets existing province after global color change",function()
		local w,api=start(deferred);local p=add(w,api,1)[1];verify(w,api,p)
		p.Color=api.GetColor();w.flush();assert(api.GetStats().Dirty==0)
		api.SetColor(w.Color3.new(1,0,0));assert(api.GetStats().Dirty==1)
		zeroRPC(w,api);api.Destroy()
	end)
	test(prefix.."Add while active releases and pending selections stay ineligible until Done",function()
		local w,api=start(deferred);local p=add(w,api,1)[1];verify(w,api,p)
		api.SetPainting(true);waitHold(w,api);button(w,"Protect Province")
		local pending=w.province(250);api.AddProvince(pending)
		local n=w.eventCount("down");w.step(3)
		assert(api.GetStats().Painting and api.GetStats().PendingSelections==1 and w.eventCount("down")==n)
		button(w,"Add · Done / Cancel");w.step(3);assert(w.eventCount("down")>n)
		zeroRPC(w,api);api.Destroy();w.flush()
	end)
	test(prefix.."remove clear destroy and re-add release state without stale selection listeners",function()
		local w,api=start(deferred);local baseline=w.connections;local p=add(w,api,1)[1];verify(w,api,p)
		api.SetPainting(true);waitHold(w,api);api.RemoveProvince(p);w.step(1)
		assert(api.GetStats().Selected==0 and not w.button and w.connections==baseline)
		for _=1,50 do api.AddProvince(p);assert(not api.AddProvince(p));api.CommitSelections();api.Clear() end
		assert(w.connections==baseline and api.GetStats().Dirty==0)
		zeroRPC(w,api);api.Destroy();w.flush();assert(w.connections==0)
	end)
	test(prefix.."respawn releases old hold and can recover after equipping live bucket",function()
		local w,api=start(deferred);local p=add(w,api,1)[1];verify(w,api,p)
		api.SetPainting(true);waitHold(w,api)
		w.player.Character=nil;w.flush();w.step(1);assert(not w.button)
		w.equip();w.flush();waitHold(w,api)
		assert(api.GetStats().Target==p);zeroRPC(w,api);api.Destroy();w.flush()
	end)
	test(prefix.."unequip and death prevent further down",function()
		local w,api=start(deferred);local p=add(w,api,1)[1];verify(w,api,p)
		api.SetPainting(true);waitHold(w,api)
		w.bucket.Parent=nil;w.flush();w.step(2);assert(not w.button)
		local n=w.eventCount("down")
		w.bucket.Parent=w.character;w.humanoid.Health=0;w.flush();w.step(3)
		assert(w.eventCount("down")==n);zeroRPC(w,api);api.Destroy()
	end)
	test(prefix.."focus menu text and mouse-lock loss stop native input",function()
		for _,reason in ipairs({"focus","menu","text","lock"}) do
			local w,api=start(deferred);local p=add(w,api,1)[1];verify(w,api,p)
			api.SetPainting(true);waitHold(w,api)
			if reason=="focus" then w.input.WindowFocusReleased:Fire()
			elseif reason=="menu" then w.gui.MenuIsOpen=true
			elseif reason=="text" then w.textFocused=true
			else w.input.MouseBehavior=w.env.Enum.MouseBehavior.LockCenter end
			w.flush();w.step(1)
			assert(not w.button and not api.GetStats().Painting);zeroRPC(w,api);api.Destroy()
		end
	end)
	test(prefix.."press and movement errors pause and release attempted input",function()
		for _,kind in ipairs({"pressError","moveError"}) do
			local w,api=start(deferred);local p=add(w,api,1)[1]
			w[kind]=true;assert(api.SetTestTarget(p));assert(api.TestNativeInput());w.step(3)
			assert(not api.GetStats().Tested and not w.button and api.GetStats().InputErrors>0)
			zeroRPC(w,api);api.Destroy();w.flush()
		end
	end)
	test(prefix.."release failure retries boundedly and refuses new input until manual up",function()
		local w,api=start(deferred);local p=add(w,api,1)[1];verify(w,api,p)
		api.SetPainting(true);waitHold(w,api);w.releaseError=true
		api.EmergencyStop();w.step(4)
		assert(w.eventCount("up")==4 and api.GetStats().Releasing and not api.SetPainting(true))
		w.manualUp();w.step(1);assert(not api.GetStats().Releasing)
		zeroRPC(w,api);api.Destroy();w.flush()
	end)
	test(prefix.."close while held handles immediate and deferred up with full cleanup",function()
		local w,api=start(deferred);local p=add(w,api,1)[1];verify(w,api,p)
		api.SetPainting(true);waitHold(w,api);api.Destroy();w.flush()
		assert(not w.button and w.connections==0 and not w.playerGui:FindFirstChild("AutoPainterFinalUI"))
		zeroRPC(w,api)
	end)
	test(prefix.."close with failed release retains minimal guard until manual up",function()
		local w,api=start(deferred);local p=add(w,api,1)[1];verify(w,api,p)
		api.SetPainting(true);waitHold(w,api);w.releaseError=true;api.Destroy();w.flush()
		assert(w.connections==1)
		assert(not pcall(function() w.load(SOURCE) end))
		w.manualUp();assert(w.connections==0 and not w.playerGui:FindFirstChild("AutoPainterFinalUI"));zeroRPC(w,api)
	end)
	test(prefix.."duplicate loader reuses state and does not click or commit pending provinces",function()
		local w,api=start(deferred);api.AddProvince(w.province())
		local before=w.connections;assert(w.load(SOURCE)==api and w.connections==before)
		assert(api.GetStats().PendingSelections==1 and #w.nativeEvents==0);zeroRPC(w,api);api.Destroy()
	end)
	test(prefix.."diagnostic options cannot generate input camera movement or game-color writes",function()
		local w,api=start(deferred,{DiagnosticOnly=true,LockDiagnostics=true})
		local writes=w.attributeWrites;local camera=w.workspace.CurrentCamera.CFrame
		local p=add(w,api,1)[1];api.SetColor(w.Color3.new(1,0,0));api.SetTestTarget(p)
		assert(not api.TestNativeInput() and not api.SetPainting(true));w.step(5)
		assert(w.attributeWrites==writes and w.workspace.CurrentCamera.CFrame==camera and #w.nativeEvents==0)
		zeroRPC(w,api);api.Destroy()
	end)
	test(prefix.."idle correct selections create no recurring input or worker backlog",function()
		local w,api=start(deferred);local p=add(w,api,1)[1];verify(w,api,p)
		for _=1,100 do local q=w.province();q.Color=api.GetColor();api.AddProvince(q) end
		api.CommitSelections();p.Color=api.GetColor();w.flush()
		local spawns=w.taskSpawns;local n=#w.nativeEvents
		api.SetPainting(true);w.step(30)
		assert(#w.nativeEvents==n and w.taskSpawns==spawns)
		zeroRPC(w,api);api.Destroy()
	end)
end
-- Count is printed by the runner after extra regression cases.
-- print(string.format("%d native tests passed (mock engine; not live input/server verification)",passed))
