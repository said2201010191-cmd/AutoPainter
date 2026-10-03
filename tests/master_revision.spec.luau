local Fixture=require("./MasterFixture")
local NativeColors=require("./native_palette_128")
local passed,failed=0,0
SOURCE=SOURCE:gsub("local api = {",[[local api = {
 __rgb={palette=palette,entry=function(p) return lookup[p] end},
 __master={palette=palette,v=v82,visual=v7.visual,perceptual=palette.perceptual,entry=function(p) return lookup[p] end},]],1)
local function test(name,fn) local ok,why=pcall(fn);if ok then passed+=1;print("PASS "..name) else failed+=1;print("FAIL "..name..": "..tostring(why)) end end
local function setup(deferred,n) return Fixture.setup(SOURCE,deferred,n) end
local function cleanup(w,a) Fixture.clean(w,a) end
local function entries(w,a,p) for _,part in ipairs(p) do assert(a.__master.entry(part)) end end
local function startAB(w,a,options)
 local ok,why
 w.env.task.spawn(function() ok,why=a.StartNormalAB(options) end);w.step(.1)
 assert(ok,tostring(why));return a.__master.v.normalAB
end
for _,deferred in ipairs({false,true}) do
 local pre=(deferred and "deferred " or "immediate ").."master "
 for _,count in ipairs({128,255,256,300,500,900,1000}) do
  test(pre..count.." proxy resources all attached and OFF ON rebuilt",function()
   local w,a,p=setup(deferred,count);local before=w.connections
   local m=a.GetVisualRendererStats();assert(m.VisualizedProvinceCount==count and m.VisualMissingCount==0)
   assert(m.HighlightInstanceCount<=40 and m.ProxyPartCount==count)
   local old=a.__master.entry(p[1]).proxy
   for _,part in ipairs(p) do local e=a.__master.entry(part);assert(e.proxy.ClassName==part.ClassName and e.proxy.CFrame==part.CFrame and e.proxy.Size==part.Size)
    assert(e.proxy.CanQuery==false and e.proxy.CanTouch==false and e.proxy.CanCollide==false and e.proxy.Anchored)
    assert(e.proxy.Parent==e.box.Adornee and part.Parent==w.provinces)
   end
   a.SetProtectedOutlines(false);m=a.GetVisualRendererStats();assert(m.HighlightInstanceCount==0 and m.ProxyPartCount==0 and old._destroyed and a.GetStats().Selected==count)
   a.SetProtectedOutlines(true);m=a.GetVisualRendererStats();assert(m.VisualizedProvinceCount==count and m.VisualMissingCount==0 and m.VisualRebuilds==1)
   assert(a.__master.entry(p[1]).proxy~=old and w.connections==before)
   local extra=w.province(320,180);a.AddProvince(extra);assert(a.GetVisualRendererStats().VisualizedProvinceCount==count+1)
   a.RemoveProvince(p[1]);assert(a.GetVisualRendererStats().VisualizedProvinceCount==count)
   a.Clear();assert(a.GetVisualRendererStats().ProxyPartCount==0 and a.GetVisualRendererStats().HighlightInstanceCount==0)
   assert(w.networkAttempts==0 and next(w.downs)==nil);cleanup(w,a)
  end)
 end
 test(pre.."proxy geometry moves without game writes or input and state migration retains live proxy",function()
  local w,a,p=setup(deferred,4);local e=a.__master.entry(p[1]);local proxy=e.proxy
  p[1].CFrame=w.cf(w.v(10,2,30));p[1].Size=w.v(15,2,15);w.flush()
  assert(proxy.CFrame==p[1].CFrame and proxy.Size==p[1].Size)
  p[1].Color=w.color;w.flush();assert(e.proxy==proxy and not proxy._destroyed and proxy.Parent==e.box.Adornee)
  a.__master.visual.toggle(false);a.SetMode("CIVIL WAR");a.RerollCivilColors(98);a.__master.visual.toggle(true)
  assert(a.GetVisualRendererStats().VisualMissingCount==0 and next(w.downs)==nil);cleanup(w,a)
 end)
 test(pre.."clone strips scripts and physical children while retaining SpecialMesh",function()
  local w,a,p=setup(deferred,0);local part=w.province();local mesh=w.instance("SpecialMesh");mesh.Parent=part
  local script=w.instance("LocalScript");script.Parent=part;local touch=w.instance("TouchTransmitter");touch.Parent=part
  a.AddProvince(part);local proxy=a.__master.entry(part).proxy
  assert(#proxy:GetChildren()==1 and proxy:GetChildren()[1].ClassName=="SpecialMesh" and script.Parent==part)
  assert(w.networkAttempts==0);cleanup(w,a)
 end)
 test(pre.."noncloneable province reports missing geometry without rectangle fallback or selection loss",function()
  local w,a,p=setup(deferred,0);local part=w.province();part.Archivable=false;a.AddProvince(part)
  assert(a.GetStats().Selected==1 and a.GetVisualRendererStats().VisualMissingCount==1 and a.GetVisualRendererStats().VisualRebuildFailures>0)
  assert(part.Archivable==false and next(w.downs)==nil);cleanup(w,a)
 end)
 test(pre.."repeated 900 OFF ON cycles leave no geometry or listener accumulation",function()
  local w,a,p=setup(deferred,900);local connections=w.connections
  for _=1,3 do a.SetProtectedOutlines(false);a.SetProtectedOutlines(true);assert(w.connections==connections) end
  a.Clear();assert(not a.__master.visual.root and next(a.__master.visual.groups)==nil);cleanup(w,a)
 end)
 test(pre.."OKLab identity/reference red distance and farthest candidate choice",function()
  local w,a=setup(deferred,0);local c=a.__master.perceptual
  local red=c.lab(w.Color3.fromRGB(255,0,0));assert(math.abs(red[1]-.62795536)<1e-6 and math.abs(red[2]-.22486306)<1e-6)
  assert(c.distance(red,red)==0)
  local used={w.Color3.fromRGB(255,0,0)};local pool=c.make(a.__master.palette.rng(17),used,1)
  local best=-1;for _,item in ipairs(pool) do best=math.max(best,item.near) end
  local picked=c.take(pool);assert(math.abs(c.distance(c.lab(picked),red)-best)<1e-8);cleanup(w,a)
 end)
 test(pre.."actual native 128 plus 54 max-min colors are deterministic unique labeled and stable",function()
  local w,a,p,pal=setup(deferred,182)
  -- Replace mock learned RGBs with all 128 RGBs in user's actual exported palette.
  pal.byKey={}
  for i,item in ipairs(pal.controls) do
   local c=NativeColors[i];item.color=w.Color3.fromRGB(c[1],c[2],c[3]);item.key=string.format("%02X%02X%02X",c[1],c[2],c[3]);pal.byKey[item.key]=item
  end
  a.SetMode("CIVIL WAR");assert(a.RerollCivilColors(182));local keys={}
  for i,part in ipairs(p) do local e=a.__master.entry(part);keys[i]=e.civilKey
   assert(e.civilControl.generated==(i>128 and true or nil))
   if i>128 then
    assert(e.civilControl.ordinal==i-128 and e.civilControl.index==0 and e.civilControl.signature.Name:find("GEN #",1,true))
    for j=1,i-1 do assert(not a.ColorsMatch(e.civilColor,a.__master.entry(p[j]).civilColor)) end
   end
  end
  local report=a.GetGeneratedDistanceReport();assert(report:find("OKLab Euclidean x100",1,true) and report:find("NativePaletteIndex=NONE",1,true))
  local minN=tonumber(report:match("GeneratedMinPerceptualDistanceToNative=([%d%.]+)"));local minG=tonumber(report:match("GeneratedMinPerceptualDistanceToGenerated=([%d%.]+)"))
  assert(minN and minG and minN>3 and minG>3)
  print(string.format("DISTANCE actual native 128 + 54 seed182: native %.6f generated %.6f pool1536",minN,minG))
  assert(a.RerollCivilColors(182));for i,part in ipairs(p) do assert(a.__master.entry(part).civilKey==keys[i]) end
  p[150].Color=w.Color3.fromRGB(0,0,0);w.flush();assert(a.__master.entry(p[150]).civilKey==keys[150])
  assert(a.RerollCivilColors(183));assert(a.__master.entry(p[150]).civilKey~=keys[150]);cleanup(w,a)
 end)
 test(pre.."900 Civil assignments remain unique under perceptual crowding without extra input",function()
  local w,a,p=setup(deferred,900);a.SetMode("CIVIL WAR");assert(a.RerollCivilColors(900))
  local keys={};for _,part in ipairs(p) do local e=a.__master.entry(part);assert(not keys[e.civilKey]);keys[e.civilKey]=true end
  assert(a.GetPerformanceStats().GeneratedColorsAssigned==772 and next(w.downs)==nil)
  local r=a.GetGeneratedDistanceReport();assert(r:find("GEN #772",1,true) and not r:find("DistanceToNative=0.000000",1,true))
  cleanup(w,a)
 end)
 for _,class in ipairs({"MeshPart","UnionOperation","WedgePart"}) do
  test(pre..class.." proxy preserves source geometry type and rebuilds without authority writes",function()
   local w,a,p=setup(deferred,0);local part=w.province();part.ClassName=class;part.MeshId="native-mesh";a.AddProvince(part)
   local proxy=a.__master.entry(part).proxy;assert(proxy.ClassName==class and proxy.MeshId==part.MeshId)
   local nested=w.instance("SpecialMesh");local script=w.instance("Script");script.Parent=nested;nested.Parent=part;w.flush()
   proxy=a.__master.entry(part).proxy
   for _,child in ipairs(proxy:GetDescendants()) do assert(not child:IsA("Script") and not child:IsA("LocalScript")) end
   assert(script.Parent==nested and part.Parent==w.provinces);cleanup(w,a)
  end)
 end
 test(pre.."129th generated native transport still produces exact mock RGB after max-min assignment",function()
  local w,a,p=setup(deferred,129);a.SetMode("CIVIL WAR");a.RerollCivilColors(987);Fixture.nativeClean(w,a,p)
  w.start(a,2);assert(a.GetStats().Dirty==0 and a.GetPerformanceStats().GeneratedExactResults==1 and w.networkAttempts==0);cleanup(w,a)
 end)
 test(pre.."AB preflight is explicit and never runs under Civil or camera automation",function()
  local w,a,p=setup(deferred,3);a.SetMode("CIVIL WAR");assert(not a.StartNormalAB());a.SetMode("NORMAL");a.SetCameraMode("AGGRESSIVE");assert(not a.StartNormalAB())
  a.SetCameraMode("LOCKED");assert(not a.StartNormalAB({SpacingControls=true}));assert(next(w.downs)==nil);cleanup(w,a)
 end)
 test(pre.."A control remains 150 actual floor with no palette/equip refresh",function()
  local w,a,p=setup(deferred,12);local before=w.equipReads or 0;w.start(a,3)
  assert(a.GetStats().Dirty==0 and (w.equipReads or 0)<=before+1 and a.GetNormalABState().Production=="A")
  local last=nil;for _,event in ipairs(w.activationEvents) do if event.kind=="down" then if last then assert(event.at-last>=.150-1e-6) end;last=event.at end end
  assert(a.GetPerformanceStats().AdaptiveDwellMs==120);cleanup(w,a)
 end)
 test(pre.."B normal refresh leaves intended RGB unchanged and paint result required",function()
  local w,a,p=setup(deferred,8);local expected=w.player:GetAttribute("PaintBucketColor");assert(a.SetNormalProductionPath("B"));w.start(a,3)
  assert(a.GetStats().Dirty==0,a.GetStats().LastMessage)
  assert(a.ColorsMatch(expected,w.player:GetAttribute("PaintBucketColor")) and (w.equipReads or 0)>=8 and a.GetPerformanceStats().GeneratedPreparations==0)
  for _,part in ipairs(p) do assert(a.ColorsMatch(part.Color,expected)) end
  assert(w.networkAttempts==0);cleanup(w,a)
 end)
 test(pre.."C same swatch really clicks despite already-matching attribute",function()
  local w,a,p=setup(deferred,6);w.humanSelect(w.uiButtons[1]);local expected=w.player:GetAttribute("PaintBucketColor");local before=w.paletteClicks
  assert(a.SetNormalProductionPath("C"));w.start(a,3)
  assert(a.GetStats().Dirty==0,a.GetStats().LastMessage);assert(w.paletteClicks-before>=6 and a.ColorsMatch(expected,w.player:GetAttribute("PaintBucketColor")))
  assert(a.GetPerformanceStats().GeneratedPreparations==0);cleanup(w,a)
 end)
 test(pre.."C rejects unchanged attribute when native swatch callback absent",function()
  local w,a,p=setup(deferred,3);w.humanSelect(w.uiButtons[1]);w.noPaletteClicked=true
  assert(a.SetNormalProductionPath("C"));w.start(a,2)
  assert(not a.GetStats().Running and a.GetStats().Dirty==3 and a.GetStats().LastMessage:find("refresh failed",1,true))
  assert(next(w.downs)==nil);cleanup(w,a)
 end)
 test(pre.."AB six phases complete using one cohort with external dirty events and retain evidence",function()
  local w,a,p=setup(deferred,20);w.humanSelect(w.uiButtons[1]);local keep=true
  local function attack() if not keep then return end;for _,part in ipairs(p) do part.Color=w.Color3.fromRGB(0,0,0) end;w.schedule(.5,attack) end
  w.schedule(.5,attack);local ab=startAB(w,a,{Samples=10,SecondsPerPhase=5});w.step(32);keep=false
  assert(not ab.active and ab.completed and #ab.phases==6,ab.state.." / "..a.GetStats().LastMessage)
  assert(ab.production=="A" and a.GetPerformanceStats().NormalRequestedDownSpacingMs==150)
  for _,phase in ipairs(ab.phases) do assert(phase.qualified>=10,phase.key.." "..tostring(phase.state));assert(phase.successes>0) end
  local report=a.GetNormalABReport();assert(report:find("PreparationMs",1,true) and report:find("QueueFreshMs",1,true) and report:find("ActualDownSpacingMs",1,true))
  assert(w.networkAttempts==0 and not a.GetStats().Running);cleanup(w,a)
 end)
 test(pre.."AB idle phase deadlines complete without mouse polling or paint",function()
  local w,a,p=setup(deferred,2);w.humanSelect(w.uiButtons[1]);for _,part in ipairs(p) do part.Color=w.player:GetAttribute("PaintBucketColor") end
  local ab=startAB(w,a,{Samples=10,SecondsPerPhase=5});w.step(32)
  assert(ab.completed and #ab.phases==6 and next(w.downs)==nil,ab.state)
  for _,phase in ipairs(ab.phases) do assert(phase.qualified==0 and phase.state=="INSUFFICIENT_QUALIFIED_WORK") end
  cleanup(w,a)
 end)
 for _,action in ipairs({"STOP","FOCUS","COLOR","REMOVE","CLEAR"}) do
  test(pre.."AB "..action.." aborts safely without an automatic experimental resume",function()
   local w,a,p=setup(deferred,8);w.humanSelect(w.uiButtons[1]);local ab=startAB(w,a,{SecondsPerPhase=5})
   if action=="STOP" then a.CancelNormalAB() elseif action=="FOCUS" then w.input.WindowFocusReleased:Fire() elseif action=="COLOR" then w.player:SetAttribute("PaintBucketColor",w.Color3.fromRGB(1,2,3)) elseif action=="REMOVE" then a.RemoveProvince(p[2]) else a.Clear() end
   w.step(.5);assert(not ab.active and not a.GetStats().Running and not w.button)
   if action=="FOCUS" then w.input.WindowFocused:Fire();w.step(1);assert(not a.GetStats().Running) end
   cleanup(w,a)
  end)
 end
 test(pre.."B focus loss after unequip sends no new paint input or color write",function()
  local w,a,p=setup(deferred,4);assert(a.SetNormalProductionPath("B"));local old=w.player:GetAttribute("PaintBucketColor")
  w.afterUnequip=function() w.input.WindowFocusReleased:Fire() end;w.start(a,1)
  assert(not a.GetStats().Running and next(w.downs)==nil and a.ColorsMatch(old,w.player:GetAttribute("PaintBucketColor")) and a.__master.v.normalAB.reload==nil);cleanup(w,a)
 end)
 test(pre.."source-shaped cooldown model separates retained NORMAL session from real equip reset",function()
  local rates={}
  for _,key in ipairs({"A","B","C"}) do
   local w,a,p=setup(deferred,20);w.humanSelect(w.uiButtons[1]);w.nativeRepeat=false
   local session={lastReturn=-math.huge};local qualified,accepted=0,0
   local equip=w.bucket.Equipped:Connect(function() session={lastReturn=-math.huge} end)
   local paint=w.mouse.Button1Down:Connect(function()
    local part=w.mouse.Target
    if not part or part.Parent~=w.provinces or w.uiPressed then return end
    qualified+=1
    local current=session
    if w.now-current.lastReturn<.10 then return end
    accepted+=1;local color=w.nativePaletteColor
    w.schedule(.05,function() if part.Parent then part.Color=color end end)
    w.schedule(.09,function() current.lastReturn=w.now end)
   end)
   assert(a.SetNormalProductionPath(key));w.start(a,5)
   assert(a.GetStats().Dirty==0 or a.GetPerformanceStats().SuccessfulPaints>0)
   rates[key]=accepted/math.max(1,qualified)
   assert(a.GetPerformanceStats().AdaptiveDwellMs==120 and w.networkAttempts==0)
   print(string.format("MODEL ONLY %s: attempts=%d accepted=%d success=%.3f",key,qualified,accepted,rates[key]))
   paint:Disconnect();equip:Disconnect();cleanup(w,a)
  end
  assert(rates.B>rates.A and rates.B==1)
 end)
 test(pre.."D observed-down floors follow AB without erasing paired evidence or changing production",function()
  local w,a,p=setup(deferred,20);w.humanSelect(w.uiButtons[1]);local keep=true
  local function attack() if not keep then return end;for _,part in ipairs(p) do part.Color=w.Color3.fromRGB(0,0,0) end;w.schedule(.4,attack) end
  w.schedule(.4,attack);local ab=startAB(w,a,{Samples=10,SecondsPerPhase=5});w.step(32)
  assert(ab.completed and #ab.phases==6)
  startAB(w,a,{SpacingControls=true,Samples=10,SecondsPerPhase=5});w.step(28);keep=false
  assert(ab.completed and #ab.phases==11 and ab.production=="A",ab.state)
  for i=7,11 do local phase=ab.phases[i];local previous=nil;assert(phase.qualified>=10)
   for _,r in ipairs(phase.samples) do if r.NativeDownObservedAt then
    if previous then assert(r.NativeDownObservedAt-previous>=ab.variants[phase.key].floor-1e-6) end
    previous=r.NativeDownObservedAt
   end end
  end
  assert(a.GetPerformanceStats().NormalRequestedDownSpacingMs==150);cleanup(w,a)
 end)
 test(pre.."fill survives OFF ON and uses bounded same-state resources",function()
  local w,a,p=setup(deferred,500);a.SetProtectedFill(true)
  assert(a.__master.entry(p[1]).box.FillTransparency==.90)
  a.SetProtectedOutlines(false);a.SetProtectedOutlines(true)
  assert(a.__master.entry(p[1]).box.FillTransparency==.90 and a.GetVisualRendererStats().VisualizedProvinceCount==500)
  assert(a.GetVisualRendererStats().HighlightInstanceCount<=40 and next(w.downs)==nil);cleanup(w,a)
 end)
 test(pre.."diagnostic reports and inspection do not move cursor or create input",function()
  local w,a,p=setup(deferred,129);a.SetMode("CIVIL WAR");a.RerollCivilColors(92);local moves=w.cursorMoves
  local e=a.__master.entry(p[129]);assert(a.GetTargetStats(p[129]).ColorSource=="GENERATED")
  w.mouse.Target=p[129];w.input.InputBegan:Fire({KeyCode=w.env.Enum.KeyCode.I},false);w.flush()
  assert(a.GetStats().LastMessage:find("Source: GENERATED",1,true));a.CopyActivationReport();a.GetGeneratedDistanceReport();a.GetNormalABReport()
  assert(w.cursorMoves==moves and next(w.downs)==nil);cleanup(w,a)
 end)
end
if failed>0 then error(tostring(failed).." master revision tests failed") end
print(tostring(passed).." master revision tests passed (deterministic; A/B and GPU visibility need live validation)")
