local Mock=require("./V82Mock")
local passed,failed=0,0
SOURCE=SOURCE:gsub("local api = {",[[local api = {
 __test={v=v82,p=palette,h=health,policy=policy,cfg=CFG,entry=function(part) return lookup[part] end,
  dirty=dirty,metrics=metrics,sync=syncDirty,acquire=acquireFast,point=visiblePoint,
  beginSelection=beginSelection,finishSelection=finishSelection,marker=function(part) return lookup[part].box end},]],1)
local function test(name,fn)
 local ok,why=pcall(fn);if ok then passed+=1;print("PASS "..name) else failed+=1;print("FAIL "..name..": "..tostring(why)) end
end
local function setup(deferred,n,colors)
 local w=Mock.new(deferred);local a=w.load(SOURCE);local t=a.__test;local parts={};w.protected={}
 if colors then w.makePalette(colors);w.learn(a) end
 for i=1,n or 0 do local p=w.province(-250+(i-1)%16*35,-170+math.floor((i-1)/16)*35);a.AddProvince(p);parts[i]=p;w.protected[p]=true end
 if colors and n and n>0 then a.RerollCivilColors(2082) end
 w.mouse.Target=nil;return w,a,parts,t
end
local function clean(w,a) a.Stop();w.step(.15);a.Destroy();w.flush();w.assertClean() end
local function cameraWrites(w,first)
 local counts={CFrame=0,Focus=0,CameraType=0,CameraSubject=0}
 for i=first or 1,#w.writeLog do local row=w.writeLog[i];if row.object==w.workspace.CurrentCamera and counts[row.key] then counts[row.key]+=1 end end
 return counts
end
local function zeroCamera(w,first) for name,n in pairs(cameraWrites(w,first)) do assert(n==0,name.." writes="..n) end end
local function duplicates(w,n)
 local names={"Black","Fossil","Quill grey","Ghost grey","Pearl","Institutional white","Lily white","Mid gray","Dark stone grey","Medium stone grey"}
 for i=1,math.min(10,n) do
  local original=w.uiButtons[i];original.Name=names[i];original.Text=names[i]
  local b=w.instance("TextButton");b.Name=names[i];b.Text=names[i];b.BackgroundColor3=original.BackgroundColor3
  b.Visible=true;b.Active=true;b.AbsolutePosition=w.v(20+(i-1)*45,330);b.AbsoluteSize=w.v(40,20);b.Parent=w.paletteRoot
  w.buttonColors[b]=w.buttonColors[original];table.insert(w.uiButtons,b)
 end
end
local function oldProfile(a)
 local data=a.GetPaletteProfile();for _,row in ipairs(data.Controls) do row.SemanticVerified=false;row.NativeSignature=nil end;return data
end
local function chrome(w,a)
 local opener,closer,show=w.makeChrome();show(false)
 a.BeginPaletteLearning("OPENER");w.humanSelect(opener);a.FinishPaletteLearning()
 a.BeginPaletteLearning("CLOSER");w.humanSelect(closer);a.FinishPaletteLearning();show(true)
 return opener,closer,show
end
for _,deferred in ipairs({false,true}) do
 local pre=(deferred and "deferred " or "immediate ").."live fix "
 test(pre.."NORMAL starts at120 after mode benchmark stop and tool-session resets",function()
  local w,a,p,t=setup(deferred,3,8)
  for _,strategy in ipairs({"PER_TARGET","ADAPTIVE","CONTINUOUS","PER_TARGET"}) do
   a.SetActivationStrategy(strategy);assert(t.policy.normal.PER_TARGET.dwell==.12 and t.policy.normal.CONTINUOUS.dwell==.12)
  end
  t.policy.normal.PER_TARGET.dwell=.25;t.policy.normal.PER_TARGET.latencies={.22,.23,.24,.25}
  a.SetMode("CIVIL WAR");a.SetMode("NORMAL");w.start(a,.5);assert(a.GetPerformanceStats().GlobalDwellMs==120)
  a.Stop();w.step(.1);t.policy.normal.PER_TARGET.dwell=.35;w.start(a,.1);assert(a.GetPerformanceStats().GlobalDwellMs==120)
  clean(w,a)
 end)
 test(pre.."unqualified failures and target-local no-effect cannot restore250 default",function()
  local w,a,p,t=setup(deferred,20);w.cannotAcquire[p[1]]=true;w.stalled={[p[2]]=true};w.start(a,8)
  assert(a.GetPerformanceStats().GlobalDwellMs==120)
  for i=3,20 do assert(a.ColorsMatch(p[i].Color,w.color)) end
  assert(t.entry(p[2]).ExtraDwell==0 and t.entry(p[2]).ConsecutiveValidNoEffects>0 and t.entry(p[3]).ExtraDwell==0)
  for _,r in ipairs(a.GetServiceRecords()) do assert(r.GlobalDwellBefore==120 and r.GlobalDwellAfter==120) end
  clean(w,a)
 end)
 test(pre.."fresh successful native services preserve120 dwell while cadence is paced",function()
  local w,a,p,t=setup(deferred,12);w.start(a,3)
  local m=a.GetPerformanceStats();assert(m.SuccessfulPaints==12 and m.DirtyCount==0 and m.GlobalDwellMs==120)
  assert(m.AveragePaintServiceMs<80 and m.CursorMovesToAlreadyCleanProvince==0 and m.ReleaseTimeouts==0)
  assert(w.networkAttempts==0);clean(w,a)
 end)
 test(pre.."LOCKED default survives over100 failed transactions with exactly zero camera writes",function()
  local w,a,p,t=setup(deferred,20);local first=#w.writeLog+1
  for _,part in ipairs(p) do w.cannotAcquire[part]=true end
  w.start(a,48)
  assert(t.metrics.AcquisitionAttempts>=100,"Attempts="..t.metrics.AcquisitionAttempts)
  assert(a.GetPerformanceStats().CameraControlMode=="LOCKED" and a.GetPerformanceStats().CameraMovesApplied==0)
  assert(a.GetStats().Running and a.GetPerformanceStats().GlobalDwellMs==120)
  a.Stop();w.step(.1);zeroCamera(w,first);clean(w,a)
 end)
 test(pre.."SAFE alias stays camera locked through Civil palette changes and target losses",function()
  local w,a,p,t=setup(deferred,10,16);a.SetCameraMode("SAFE");a.SetMode("CIVIL WAR")
  w.cannotAcquire[p[1]]=true;w.targetLosses[p[2]]=100;local first=#w.writeLog+1;w.start(a,10)
  for i=3,10 do assert(a.ColorsMatch(p[i].Color,t.entry(p[i]).civilColor)) end
  assert(a.GetPerformanceStats().CameraMoveAttempts==0);zeroCamera(w,first);clean(w,a)
 end)
 test(pre.."projection exhaustion fresh frame succeeds without consulting camera",function()
  local w,a,p,t=setup(deferred,2);t.cfg.MaxProjections=1;t.cfg.MaxRays=1;a.SetCameraMode("AGGRESSIVE")
  w.start(a,1);assert(a.GetStats().Dirty==0 and a.GetPerformanceStats().CameraMoveAttempts==0);clean(w,a)
 end)
 test(pre.."one stale genuine Mouse.Target frame is not proof of unreachable view",function()
  local w,a,p,t=setup(deferred,1);w.cursorDelay=.025;a.SetCameraMode("AGGRESSIVE");w.start(a,.8)
  assert(a.GetStats().Dirty==0 and a.GetPerformanceStats().CameraMovesApplied==0)
  assert(t.entry(p[1]).AcquisitionState=="ACQUIRE_OK");clean(w,a)
 end)
 test(pre.."AGGRESSIVE cannot move without the complete explicit acquisition proof",function()
  local w,a,p,t=setup(deferred,1);a.SetCameraMode("AGGRESSIVE");local cf=w.cf(w.v(0,100,0),p[1].Position)
  for _,state in ipairs({"ACQUIRE_PENDING_FRAME","ACQUIRE_STALE_CACHE","ACQUIRE_PROJECTION_BUDGET_EXHAUSTED","ACQUIRE_TEMP_MISMATCH","ACQUIRE_POST_PALETTE_REVALIDATION_PENDING"}) do
   t.entry(p[1]).AcquisitionState=state;assert(not t.v.applyPose(t.entry(p[1]),cf,p[1].Position))
  end
  assert(a.GetPerformanceStats().CameraMovesApplied==0);clean(w,a)
 end)
 test(pre.."AGGRESSIVE one failed move per dirty episode restores all camera fields",function()
  local w,a,p,t=setup(deferred,0);local part=w.province(950,0);a.AddProvince(part);w.protected[part]=true
  local camera=w.workspace.CurrentCamera;camera.CameraSubject=w.humanoid
  local cf,focus,kind,subject=camera.CFrame,camera.Focus,camera.CameraType,camera.CameraSubject
  w.cannotAcquire[part]=true;w.blockCameraTarget=true;a.SetCameraMode("AGGRESSIVE");w.start(a,5)
  assert(t.entry(part).CameraFallbackAttemptsThisDirtyEpisode==1 and a.GetPerformanceStats().CameraMovesApplied==1)
  assert(camera.CFrame==cf and camera.Focus==focus and camera.CameraType==kind and camera.CameraSubject==subject)
  assert(t.entry(part).LastGoodCameraSolution==nil and a.GetStats().Dirty==1);clean(w,a)
 end)
 test(pre.."three rare failed moves open circuit and suppress later dirty targets",function()
  local w,a,p,t=setup(deferred,0)
  for i=1,5 do local part=w.province(900+i*40,0);a.AddProvince(part);w.cannotAcquire[part]=true;w.protected[part]=true end
  w.blockCameraTarget=true;a.SetCameraMode("AGGRESSIVE");w.start(a,12)
  local m=a.GetPerformanceStats();assert(m.CameraMovesApplied==3 and m.CameraCircuitBreaker=="OPEN",tostring(m.CameraMovesApplied).." "..m.CameraCircuitBreaker)
  assert(m.CameraMovesSuppressedCircuitBreaker>0);clean(w,a)
 end)
 test(pre.."AGGRESSIVE geometry guards reject underside elevated and rotated bounds before writes",function()
  local w,a,p,t=setup(deferred,1);local entry=t.entry(p[1]);p[1].Position=w.v(0,400,0);p[1].CFrame=w.cf(p[1].Position)
  p[1].CFrame.RightVector=w.v(.7,.7,0);p[1].CFrame.UpVector=w.v(-.7,.7,0);p[1].Size=w.v(80,20,30)
  local first=#w.writeLog+1;assert(not t.v.safePose(entry,w.cf(w.v(0,420,0),p[1].Position)))
  assert(not t.v.safePose(entry,w.cf(w.v(0,-500,0),p[1].Position)))
  assert(t.v.safePose(entry,w.cf(w.v(0,550,0),p[1].Position)))
  zeroCamera(w,first);clean(w,a)
 end)
 test(pre.."manual camera gesture cancels an AGGRESSIVE recovery immediately",function()
  local w,a,p,t=setup(deferred,0);local part=w.province(950,0);a.AddProvince(part);w.protected[part]=true
  a.SetCameraMode("AGGRESSIVE");local original=w.workspace.CurrentCamera.CFrame;w.nativeRepeat=false;w.start(a,.06)
  w.input.InputChanged:Fire({UserInputType=w.env.Enum.UserInputType.MouseWheel});w.flush();w.step(.1)
  assert(w.workspace.CurrentCamera.CFrame==original and not a.GetStats().Held);clean(w,a)
 end)
 test(pre.."clean targets never move camera even with AGGRESSIVE opt in",function()
  local w,a,p,t=setup(deferred,1);p[1].Color=w.color;w.flush();a.SetCameraMode("AGGRESSIVE");local first=#w.writeLog+1
  w.start(a,1);zeroCamera(w,first);assert(w.cursorMoves==0 and next(w.downs)==nil);clean(w,a)
 end)
 test(pre.."overload recovery yields to healthy visible targets without camera",function()
  local w,a,p,t=setup(deferred,20);a.SetCameraMode("AGGRESSIVE");w.cannotAcquire[p[1]]=true;w.start(a,6)
  for i=2,20 do assert(a.ColorsMatch(p[i].Color,w.color)) end
  assert(a.GetPerformanceStats().CameraMovesApplied==0);clean(w,a)
 end)
 test(pre.."legacy128 validation persists semantic winners over25 randomized generations automatically",function()
  local w,a,p,t=setup(deferred,0);w.makePalette(128);duplicates(w,128);w.learn(a);local profile=oldProfile(a)
  w.recreatePalette(128);duplicates(w,128);w.flush();assert(a.ImportPaletteData(profile))
  assert(a.GetPerformanceStats().BoundNativeColors==118);a.ValidateNativePalette();w.step(12)
  assert(a.GetPerformanceStats().BoundNativeColors==128);local clicks=w.paletteClicks
  local rand=t.p.rng(2082)
  for generation=1,25 do
   w.recreatePalette(128);duplicates(w,128)
   -- Actually construct replacement instances in randomized order, with equivalent geometry.
   local descriptors={}
   for _,button in ipairs(w.uiButtons) do table.insert(descriptors,{name=button.Name,text=button.Text,bg=button.BackgroundColor3,pos=button.AbsolutePosition,size=button.AbsoluteSize,color=w.buttonColors[button]});button:Destroy() end
   w.uiButtons={};w.buttonColors={}
   for i=#descriptors,2,-1 do local j=rand(i);descriptors[i],descriptors[j]=descriptors[j],descriptors[i] end
   for _,d in ipairs(descriptors) do local b=w.instance("TextButton");b.Name=d.name;b.Text=d.text;b.BackgroundColor3=d.bg;b.Visible=true;b.Active=true;b.AbsolutePosition=d.pos;b.AbsoluteSize=d.size;b.Parent=w.paletteRoot;w.buttonColors[b]=d.color;table.insert(w.uiButtons,b) end
   w.flush();local m=a.GetPerformanceStats()
   assert(m.BoundNativeColors==128 and m.AmbiguousColors==0 and m.PaletteGenerationState=="READY","generation "..generation)
   assert(m.ExpectedVerifiedNativeCapacity==128 and w.paletteClicks==clicks)
  end
  assert(t.p.controls[1].nativeSignature and t.p.controls[1].semanticVerified)
  assert(a.GetPerformanceStats().PersistedDisambiguationsRebound>=250 and w.networkAttempts==0);clean(w,a)
 end)
 test(pre.."profile includes native discriminator and binds equivalent fresh controls",function()
  local w,a,p,t=setup(deferred,0);w.makePalette(12);duplicates(w,12);w.learn(a);local profile=a.GetPaletteProfile()
  assert(profile.Controls[1].NativeSignature and profile.Controls[1].SemanticVerified)
  w.recreatePalette(12);duplicates(w,12);w.flush();a.ImportPaletteData(profile)
  assert(a.GetPerformanceStats().BoundNativeColors==12 and a.GetPerformanceStats().AmbiguousColors==0 and w.paletteClicks==0);clean(w,a)
 end)
 test(pre.."equally matching discriminator remains ambiguous and blocks atomic reroll",function()
  local w,a,p,t=setup(deferred,1,4);local profile=a.GetPaletteProfile();w.recreatePalette(4)
  local first=w.uiButtons[1];local duplicate=w.instance("TextButton")
  duplicate.Name=first.Name;duplicate.Text=first.Text;duplicate.BackgroundColor3=first.BackgroundColor3;duplicate.AbsolutePosition=first.AbsolutePosition;duplicate.AbsoluteSize=first.AbsoluteSize;duplicate.Parent=w.paletteRoot
  w.flush();a.ImportPaletteData(profile);local key=t.entry(p[1]).civilKey
  assert(a.GetPerformanceStats().PaletteGenerationState=="VERIFYING_AMBIGUOUS")
  assert(not a.RerollCivilColors(1) and t.entry(p[1]).civilKey==key);clean(w,a)
 end)
 test(pre.."temporary detachment retains semantic128 and restores ready without reassigning",function()
  local w,a,p,t=setup(deferred,12,128);local keys={};for i,part in ipairs(p) do keys[i]=t.entry(part).civilKey end
  w.detachPalette();w.flush();local m=a.GetPerformanceStats()
  assert(m.LearnedSemanticColors==128 and m.VerifiedNativeCapacity==128 and m.PaletteGenerationState=="DETACHED")
  assert(not a.RerollCivilColors(1));w.recreatePalette(128);w.flush();m=a.GetPerformanceStats();assert(m.PaletteGenerationState=="READY" and m.BoundNativeColors==128)
  for i,part in ipairs(p) do assert(t.entry(part).civilKey==keys[i]) end;clean(w,a)
 end)
 test(pre.."incompatible replacement degrades only that binding without erasing prior native proof",function()
  local w,a,p,t=setup(deferred,0,128);w.recreatePalette(128);w.uiButtons[1].Text="DifferentAction";w.flush()
  local m=a.GetPerformanceStats();assert(m.BoundNativeColors==127 and m.PaletteGenerationState=="DEGRADED" and m.VerifiedNativeCapacity==128)
  assert(t.p.controls[1].semanticVerified and t.p.controls[1].bindingState=="SIGNATURE_MISMATCH");clean(w,a)
 end)
 test(pre.."AUTO cannot close without a verified live opener",function()
  local w,a,p,t=setup(deferred,2,4);local opener,closer,show=w.makeChrome()
  a.BeginPaletteLearning("CLOSER");w.humanSelect(closer);a.FinishPaletteLearning();show(true)
  t.p.closeRequired=true;a.SetMode("CIVIL WAR");w.start(a,1.2)
  assert(a.GetStats().Dirty==0 and a.GetPerformanceStats().CloserUses==0)
  assert(a.GetPerformanceStats().AutoCloseEffective=="KEEP OPEN (no verified opener)")
  for _,r in ipairs(t.p.controls) do assert(t.p.visible(r.button)) end;clean(w,a)
 end)
 test(pre.."verified chrome survives generations and open close transitions",function()
  local w,a,p,t=setup(deferred,3,8);local opener,closer,show=chrome(w,a)
  assert(t.p.verifiedOpener());local keys={};for i,part in ipairs(p) do keys[i]=t.entry(part).civilKey end
  for _=1,5 do w.recreatePalette(8,true);w.flush();assert(t.p.verifiedOpener() and t.p.valid(t.p.closer)) end
  t.p.closeRequired=true;a.SetMode("CIVIL WAR");w.start(a,3)
  assert(a.GetStats().Dirty==0 and a.GetPerformanceStats().OpenerUses>=2 and a.GetPerformanceStats().CloserUses==3)
  for i,part in ipairs(p) do assert(t.entry(part).civilKey==keys[i]) end;clean(w,a)
 end)
 test(pre.."closed global prerequisite generates one blocked state instead of failure storm",function()
  local w,a,p,t=setup(deferred,20,32);a.SetMode("CIVIL WAR");w.start(a,.01)
  w.paletteRoot.Enabled=false;w.step(20)
  local m=a.GetPerformanceStats();assert(m.PaletteBlocked and m.PaletteFailures<=2 and m.PaletteBlockedEntries==1,tostring(m.PaletteFailures))
  assert(m.SuppressedPaletteUnavailableRetries>0 and #a.GetServiceRecords()<=3,"suppressed="..m.SuppressedPaletteUnavailableRetries.." records="..#a.GetServiceRecords())
  w.paletteRoot.Enabled=true;w.step(8);assert(a.GetStats().Dirty==0 and a.GetPerformanceStats().PaletteBlockedRecoveries==1,"dirty="..a.GetStats().Dirty.." recoveries="..a.GetPerformanceStats().PaletteBlockedRecoveries.." "..a.GetStats().LastMessage);clean(w,a)
 end)
 test(pre.."failed verified opener is not retried until prerequisite actually changes",function()
  local w,a,p,t=setup(deferred,4,8);local opener,closer,show=chrome(w,a);show(false)
  w.buttonActions[opener]=function() end;a.SetMode("CIVIL WAR");w.start(a,10)
  assert(w.paletteClicks==2 and a.GetPerformanceStats().OpenerFailures==1 and a.GetPerformanceStats().PaletteBlocked)
  show(true);w.step(3);assert(a.GetStats().Dirty==0);clean(w,a)
 end)
 test(pre.."runtime outage permits already-current native color but blocks color switching",function()
  local w,a,p,t=setup(deferred,2,4);a.SetMode("CIVIL WAR");w.start(a,1)
  local selected=w.player:GetAttribute("PaintBucketColor");local same
  for _,part in ipairs(p) do if a.ColorsMatch(t.entry(part).civilColor,selected) then same=part end end;assert(same)
  w.detachPalette();w.flush();for _,part in ipairs(p) do part.Color=w.Color3.new(0,0,0) end;w.flush();local clicks=w.paletteClicks
  w.step(2);assert(a.ColorsMatch(same.Color,selected) and a.GetStats().Dirty==1 and w.paletteClicks==clicks)
  w.recreatePalette(4);w.flush();w.step(2);assert(a.GetStats().Dirty==0);clean(w,a)
 end)
 test(pre.."snapshot reports generation change during UI click and keeps assignments",function()
  local w,a,p,t=setup(deferred,2,4);a.SetMode("CIVIL WAR");local key=t.entry(p[1]).civilKey
  w.onPaletteDown=function() w.onPaletteDown=nil;w.recreatePalette(4) end;w.start(a,2)
  assert(t.entry(p[1]).civilKey==key)
  local saw=false;for _,trace in ipairs(t.p.transactions) do if trace.PaletteGenerationAtFailure then saw=true;assert(trace.PaletteStateSnapshotId and trace.PaletteGenerationAtStart) end end
  assert(saw);w.step(3);assert(a.GetStats().Dirty==0);clean(w,a)
 end)
 test(pre.."silhouettes adorn actual geometry no cloned hitboxes or world property writes",function()
  local w,a,p,t=setup(deferred,3);local before=#w.writeLog+1
  for _,part in ipairs(p) do local h=t.marker(part);assert(h.ClassName=="Highlight" and h.Adornee==part and h.FillTransparency==1) end
  t.beginSelection("ADD");w.mouse.Target=p[1];w.mouse.Move:Fire();w.flush()
  assert(t.v.selection.hover.ClassName=="Highlight" and t.v.selection.hover.Adornee==p[1])
  for i=before,#w.writeLog do local row=w.writeLog[i];assert(not table.find(p,row.object),"province mutated") end
  t.finishSelection();w.step(.15);clean(w,a)
 end)
 test(pre.."capacity167 shows exact39 shortage independent of transient live118",function()
  local w,a,p,t=setup(deferred,167,128);for i=1,10 do t.p.detachBinding(t.p.controls[i]) end
  local pf=a.GetCapacityPreflight();assert(pf.VerifiedNativeCapacity==128 and pf.Shortage==39 and pf.GeneratedVerifiedCapacity==0)
  assert(not a.RerollCivilColors(1));a.SetMode("CIVIL WAR");w.start(a,.2);assert(not a.GetStats().Running and w.paintCalls==0);clean(w,a)
 end)
 test(pre.."custom UI inspection is read-only and nonexistent candidates remain unverified",function()
  local w,a,p,t=setup(deferred,1,8);local before=w.propertyWrites;local clicks=w.paletteClicks
  local inventory=a.InspectCustomColorUI();assert(#inventory>0 and not a.ProbeCustomColorUI(1) and not a.ProbeCustomColorUI(2))
  assert(w.paletteClicks==clicks and w.propertyWrites==before and w.paintCalls==0 and w.networkAttempts==0)
  assert(a.GetCustomColorUIReport():find("UNVERIFIED",1,true) and a.GetPerformanceStats().GeneratedVerifiedCapacity==0);clean(w,a)
 end)
 test(pre.."late GUI layout settles persistent ambiguous mappings without a new index or click",function()
  local w,a,p,t=setup(deferred,0);w.makePalette(12);duplicates(w,12);w.learn(a)
  w.recreatePalette(12);duplicates(w,12);local positions={}
  for _,b in ipairs(w.uiButtons) do positions[b]=b.AbsolutePosition;b.AbsolutePosition=w.v(0,0) end
  w.flush();assert(a.GetPerformanceStats().AmbiguousColors==10)
  local scans=a.GetPerformanceStats().FullGuiTraversals
  for b,pos in pairs(positions) do b.AbsolutePosition=pos end
  local m=a.GetPerformanceStats();assert(m.BoundNativeColors==12 and m.PaletteGenerationState=="READY" and m.FullGuiTraversals==scans and w.paletteClicks==0);clean(w,a)
 end)
 test(pre.."both actual native picker paths use explicit GUI input and never invent generated capacity",function()
  local w,a,p,t=setup(deferred,0);w.paletteRoot.Name="PaletteGui"
  local pallet=w.instance("Frame");pallet.Name="ColorPallet";pallet.Parent=w.paletteRoot
  for index,region in ipairs({"PaintSGui","ColorTitle"}) do
   local container=w.instance("Frame");container.Name=region;container.Parent=pallet
   local b=w.instance(index==1 and "ImageButton" or "TextButton");b.Name=index==1 and "Picker" or "ColorPicker"
   b.Text="Custom";b.Image="picker";b.Visible=true;b.Active=true;b.BackgroundColor3=w.color;b.AbsolutePosition=w.v(20+(index-1)*60,110);b.AbsoluteSize=w.v(40,20);b.Parent=container;table.insert(w.uiButtons,b)
   w.buttonActions[b]=function() local box=w.instance("TextBox");box.Name="UnverifiedRGB"..index;box.Text="128";box.Visible=true;box.AbsolutePosition=w.v(200,200);box.AbsoluteSize=w.v(40,20);box.Parent=pallet end
   assert(a.ProbeCustomColorUI(index),"probe "..index.." refused "..a.GetCustomColorUIReport());w.step(.5)
   assert(w.paletteClicks==index and w.paintCalls==0 and not a.GetStats().Running,"clicks="..w.paletteClicks.." running="..tostring(a.GetStats().Running).." "..a.GetCustomColorUIReport())
  end
  assert(a.GetCustomColorUIReport():find("UIChanged=true",1,true) and a.GetPerformanceStats().GeneratedVerifiedCapacity==0)
  assert(a.GetPerformanceStats().CustomColorUIAvailable=="UNVERIFIED" and w.networkAttempts==0);clean(w,a)
 end)
 test(pre.."custom UI probe fails cleanly on focus loss without arming a paint resume",function()
  local w,a,p,t=setup(deferred,0);w.paletteRoot.Name="PaletteGui";local pallet=w.instance("Frame");pallet.Name="ColorPallet";pallet.Parent=w.paletteRoot
  local container=w.instance("Frame");container.Name="PaintSGui";container.Parent=pallet
  local b=w.instance("ImageButton");b.Name="Picker";b.Visible=true;b.Active=true;b.BackgroundColor3=w.color;b.AbsolutePosition=w.v(20,110);b.AbsoluteSize=w.v(40,20);b.Parent=container;table.insert(w.uiButtons,b)
  w.onPaletteDown=function() w.input.WindowFocusReleased:Fire() end
  assert(a.ProbeCustomColorUI(1));w.step(.5);assert(not a.GetStats().Running and not a.GetStats().Held and not t.v.resumeIntent and w.paintCalls==0)
  w.input.WindowFocused:Fire();w.step(.5);assert(not a.GetStats().Running);clean(w,a)
 end)
 test(pre.."reports expose camera ROI generation barrier blocked state and120 default",function()
  local w,a,p,t=setup(deferred,2,8);local report=a.GetPerformanceReport()
  for _,key in ipairs({"CameraCircuitBreaker","CameraMovesApplied","CameraMovePaintSuccessRate","CameraMovesSuppressedSafeMode","PaletteGenerationState","ExpectedVerifiedNativeCapacity","PaletteBlockedRecoveries","PersistedDisambiguationsRebound"}) do assert(report:find(key,1,true),key) end
  assert(t.cfg.TargetDwellDefault==.12 and t.cfg.TargetDwellMin==.12);clean(w,a)
 end)
end
assert(failed==0,tostring(failed).." live-fix tests failed")
print(passed.." v8.2 live-fix tests passed (mock evidence, not live Roblox proof)")
