-- Test-only lexical seam: never present in the shipped controller. Tests exercise the
-- real algorithms/lifecycle; only Roblox/input/replication are deterministic fixtures.
local Mock=require("./V82Mock")
local passed,failed=0,0
SOURCE=SOURCE:gsub("local api = {",[[local api = {
 __test={v=v82,p=palette,h=health,policy=policy,cfg=CFG,entry=function(part) return lookup[part] end,
  choose=chooseFast,dirty=dirty,reconcile=reconcile,metrics=metrics,sync=syncDirty,point=visiblePoint,
  beginSelection=beginSelection,finishSelection=finishSelection,marker=function(part) return lookup[part].box end},]],1)
local function test(name,fn)
 local ok,err=pcall(fn);if not ok then failed+=1;print("FAIL "..name..": "..tostring(err));return end
 passed+=1;print("PASS "..name)
end
local function setup(deferred,n,paletteCount)
 local w=Mock.new(deferred);local a=w.load(SOURCE);local t=a.__test;local parts={};w.protected={}
 if paletteCount then w.makePalette(paletteCount);w.learn(a) end
 -- Dense but non-overlapping, all visible: isolate scheduling from camera geometry.
 for i=1,n or 0 do
  local p=w.province(-280+(i-1)%16*35,-210+math.floor((i-1)/16)*35);parts[i]=p;w.protected[p]=true;assert(a.AddProvince(p))
 end
 if paletteCount and n and n>0 then a.RerollCivilColors(2082) end
 w.mouse.Target=nil
 return w,a,parts,t
end
local function clean(w,a) a.Stop();w.step(.15);a.Destroy();w.flush();w.assertClean() end
local function duplicatePalette(w,count)
 local names={"Black","Fossil","Quill grey","Ghost grey","Pearl","Institutional white","Lily white","Mid gray","Dark stone grey","Medium stone grey"}
 for i=1,math.min(10,count) do
  local original=w.uiButtons[i];original.Name=names[i];original.Text=names[i]
  local b=w.instance("TextButton");b.Name=names[i];b.Text=names[i];b.BackgroundColor3=original.BackgroundColor3
  b.Visible=true;b.Active=true;b.AbsolutePosition=w.v(20+(i-1)*45,330);b.AbsoluteSize=w.v(40,20);b.Parent=w.paletteRoot
  table.insert(w.uiButtons,b);w.buttonColors[b]=w.buttonColors[original]
 end
end
for _,deferred in ipairs({false,true}) do
 local pre=(deferred and "deferred " or "immediate ").."v8.2 "
 test(pre.."eligible clock excludes intentional cooldown and service time exactly",function()
  local w,a,p,t=setup(deferred,1);local e=t.entry(p[1]);w.now=1;t.v.account(e,w.now)
  t.v.defer(e,2,"QUARANTINE");w.now=4;t.v.account(e,w.now)
  assert(e.eligibleMs==2000 and e.deferredMs==2000 and e.quarantineMs==2000)
  e.inService=true;w.now=9;t.v.account(e,w.now);assert(e.eligibleMs==2000)
  local q=t.v.queueSnapshot(w.now);assert(q.TotalDirtyAgeP90Ms==9000 and q.EligibleQueueP90Ms==0)
  clean(w,a)
 end)
 test(pre.."100-second quarantine does not appear as eligible wait",function()
  local w,a,p,t=setup(deferred,2);local e=t.entry(p[1]);t.v.defer(e,100,"QUARANTINE");w.now=99
  local q=t.v.queueSnapshot(w.now);assert(e.eligibleMs==0 and e.deferredMs==99000 and q.MaxDirtyAgeMs==99000)
  p[2].Color=w.color;w.flush();q=t.v.queueSnapshot(w.now);assert(q.EligibleQueueP90Ms==0);clean(w,a)
 end)
 test(pre.."wrong-to-wrong events coalesce without resetting dirty episode or retry",function()
  local w,a,p,t=setup(deferred,1);local e=t.entry(p[1]);t.v.defer(e,2,"RETRY");local since=e.dirtySince
  for i=1,15 do p[1].Color=w.Color3.fromRGB(i*5,90,120);w.flush() end
  assert(#t.dirty==1 and e.dirtySince==since and e.retryAt==2 and t.v.data.CoalescedDirtyEvents==15)
  assert(w.cursorMoves==0 and w.networkAttempts==0);clean(w,a)
 end)
 test(pre.."clean-to-dirty origin is fresh while initial selection is bootstrap",function()
  local w,a,p,t=setup(deferred,2);assert(t.entry(p[1]).queueOrigin=="BOOTSTRAP_DIRTY")
  p[2].Color=w.color;w.flush();p[2].Color=w.Color3.new(0,0,0);w.flush()
  assert(t.entry(p[2]).queueOrigin=="FRESH_ATTACK" and a.GetPerformanceStats().DirtyEventsWithoutHover==1);clean(w,a)
 end)
 test(pre.."overload hysteresis has a minimum hold and quiet exit",function()
  local w,a,p,t=setup(deferred,20);t.v.loadAt=nil;t.v.updateLoad(w.now);assert(t.v.overload)
  for _,part in ipairs(p) do part.Color=w.color end;w.flush();w.step(1);assert(t.v.overload)
  w.step(2);assert(not t.v.overload and t.v.data.OverloadEntries==1 and t.v.data.OverloadExits==1);clean(w,a)
 end)
 test(pre.."hard eligible aging outranks fresh routine work",function()
  local w,a,p,t=setup(deferred,3);local old=t.entry(p[1]);w.now=2;t.v.account(old,w.now)
  p[2].Color=w.color;w.flush();p[2].Color=w.Color3.new(0,0,0);w.flush()
  local tier=t.v.rank(old,w.now);local fresh=t.v.rank(t.entry(p[2]),w.now)
  assert(tier==0 and fresh==1);clean(w,a)
 end)
 test(pre.."hot immediate reattacks get one queue item and local rotation",function()
  local w,a,p,t=setup(deferred,2);local e=t.entry(p[1]);e.lastCorrectedTime=0
  t.v.attack(e,0.01);t.v.attack(e,0.02)
  assert(e.ImmediateReattacks==2 and e.hotUntil>.02 and e.retryAt>0 and #t.dirty==2)
  assert(t.v.data.HotTargetsDetected==1 and t.v.data.HotTargetRotations==1);clean(w,a)
 end)
 test(pre.."civil palette reuse cannot outrank a fresh attack and stops at four",function()
  local w,a,p,t=setup(deferred,3,4);a.SetMode("CIVIL WAR");local e=t.entry(p[1])
  w.player:SetAttribute("PaintBucketColor",e.civilColor);w.flush()
  p[2].Color=t.entry(p[2]).civilColor;w.flush();p[2].Color=w.Color3.new(0,0,0);w.flush()
  local tier,_,same=t.v.rank(e,w.now);local fresh=t.v.rank(t.entry(p[2]),w.now)
  assert(same==1 and fresh<tier);t.v.batchCount=4;local _,_,blocked=t.v.rank(e,w.now);assert(blocked==0);clean(w,a)
 end)
 test(pre.."cooling target never blocks eligible dirty work",function()
  local w,a,p,t=setup(deferred,3);t.v.defer(t.entry(p[1]),100,"QUARANTINE");w.start(a,.6)
  assert(a.ColorsMatch(p[2].Color,w.color) and a.ColorsMatch(p[3].Color,w.color));clean(w,a)
 end)
 test(pre.."50-target sustained NORMAL workload isolates three bad and five hot targets",function()
  local w,a,p,t=setup(deferred,55);w.stalled={[p[1]]=true,[p[2]]=true,[p[3]]=true}
  for tick=1,12 do w.schedule(tick*.65,function()
   for i=4,8 do p[i].Color=w.Color3.fromRGB(0,tick*4,20);w.flush();p[i].Color=w.Color3.fromRGB(0,tick*4+2,20) end
  end) end
  w.start(a,18)
  for i=4,#p do assert(a.ColorsMatch(p[i].Color,w.color),"healthy target "..i) end
  local m=a.GetPerformanceStats();assert(m.OverloadEntries>=1 and m.CoalescedDirtyEvents>=40 and m.GlobalDwellMs<=250)
  assert(m.AttemptsDeferredByOverload>0 and m.TargetQuarantines>0 and m.CursorMovesToAlreadyCleanProvince==0)
  assert(m.SuccessfulPaints>=52 and #t.v.normalSamples<=256)
  w.stalled={};w.step(7);assert(a.GetStats().Dirty==0);w.step(3);assert(not a.GetPerformanceStats().Overload);clean(w,a)
 end)
 test(pre.."three-entry no-effect group escalates bounded cooldown without global poisoning",function()
  local w,a,p,t=setup(deferred,6);w.stalled={[p[1]]=true,[p[2]]=true,[p[3]]=true}
  w.schedule(6,function() p[5].Color=w.Color3.new(0,0,0);p[6].Color=w.Color3.new(0,0,0) end)
  w.start(a,12);local m=a.GetPerformanceStats()
  assert(m.PathologicalGroupsDetected>0 and m.GroupCooldownMs<=4000 and m.TargetsInPathologicalGroup>=2)
  assert(m.GlobalDwellMs<=250 and m.HealthyServicesCompletedWhileGroupDeferred>0)
  for i=4,6 do assert(a.ColorsMatch(p[i].Color,w.color)) end
  w.stalled={};w.step(7);assert(a.GetStats().Dirty==0 and a.GetPerformanceStats().TargetsInPathologicalGroup==0);clean(w,a)
 end)
 test(pre.."global dwell rejects recovery overload camera and late samples",function()
  local w,a,p,t=setup(deferred,4);local arm=t.policy.newArm();arm.dwell=.12
  for _,reason in ipairs({"recovery","overload","camera","late"}) do
   local service={success=true,entry=t.entry(p[1]),eligibleQueueMs=0,cameraSearchesBefore=t.metrics.CameraFallbacks}
   if reason=="recovery" then service.recoverySample=true elseif reason=="overload" then service.overloadSample=true
   elseif reason=="camera" then service.cameraSearchesBefore=-1 else service.finishedLate=true end
   for _=1,8 do t.v.learnSuccess(arm,.30,service) end
  end
  assert(arm.dwell==.12 and (arm.training==nil or #arm.training==0));clean(w,a)
 end)
 test(pre.."upward global dwell requires diverse healthy entries and recovers downward",function()
  local w,a,p,t=setup(deferred,8);local arm=t.policy.newArm();arm.dwell=.12
  local function sample(part,latency) t.v.learnSuccess(arm,latency,{success=true,entry=t.entry(part),eligibleQueueMs=0,cameraSearchesBefore=t.metrics.CameraFallbacks}) end
  for _=1,8 do sample(p[1],.19) end;assert(arm.dwell==.12)
  for i=2,5 do sample(p[i],.19) end;assert(arm.dwell>.12 and arm.dwell<=.18)
  for i=1,32 do sample(p[i%8+1],.045) end;assert(arm.dwell==.12);clean(w,a)
 end)
 test(pre.."lookahead never moves cursor camera palette or input",function()
  local w,a,p,t=setup(deferred,3);local cursor=w.cursor;local cf=w.workspace.CurrentCamera.CFrame;local writes=w.attributeWrites
  t.v.prepareLookahead({entry=t.entry(p[1])})
  assert(t.v.lookahead and w.cursor==cursor and w.workspace.CurrentCamera.CFrame==cf and w.attributeWrites==writes and next(w.downs)==nil);clean(w,a)
 end)
 test(pre.."complete NORMAL timing record includes every transaction boundary and id",function()
  local w,a,p=setup(deferred,2);w.start(a,.6)
  local r=a.GetServiceRecords()[1]
  for _,key in ipairs({"DirtyEventToEligibleMs","EligibleToSchedulerPickMs","SchedulerPickToAcquireMs","AcquisitionMs","PalettePreparationMs","PaintMs","ReleaseMs","TotalDefenseResponseMs","TransactionId","EligibleQueueWaitMs","DeferredCooldownAgeMs","QuarantineAgeMs","TotalDirtyAgeMs"}) do assert(type(r[key])=="number",key) end
  assert(r.Result=="SUCCESS" and r.PaintMs>0 and r.ReleaseMs>=0);clean(w,a)
 end)
 test(pre.."bootstrap and fresh combat queue percentiles are separate by mode",function()
  local w,a,p,t=setup(deferred,1);t.v.normalSamples={{origin="BOOTSTRAP_DIRTY",eligible=9000},{origin="FRESH_ATTACK",eligible=20},{origin="TARGET_RECOVERY",eligible=80}}
  t.v.civilSamples={{origin="BOOTSTRAP_DIRTY",eligible=5000},{origin="FRESH_ATTACK",eligible=40}}
  t.v.percentileAt=nil;local m=a.GetV82Diagnostics()
  assert(m.NORMALBootstrapQueueP90Ms==9000 and m.NORMALFreshAttackQueueP90Ms==20 and m.CIVILFreshAttackQueueP90Ms==40 and m.NORMALTargetRecoveryQueueP90Ms==80);clean(w,a)
 end)
 test(pre.."full 128 palette duplicate names bind through native verified candidates",function()
  local w,a,p,t=setup(deferred,0);w.makePalette(128);duplicatePalette(w,128);w.learn(a)
  assert(#t.p.controls==128);local profile=a.GetPaletteProfile();for _,row in ipairs(profile.Controls) do row.NativeSignature=nil;row.SemanticVerified=false end
  w.recreatePalette(128);duplicatePalette(w,128);w.flush();assert(a.ImportPaletteData(profile))
  local m=a.GetPerformanceStats();assert(m.AmbiguousColors==10 and m.BoundNativeColors==118)
  assert(a.ValidateNativePalette());w.step(12)
  m=a.GetPerformanceStats();assert(m.BoundNativeColors==128 and m.AmbiguousColors==0 and m.AmbiguousResolutionsSucceeded==10,a.GetPaletteInventory())
  assert(w.paintCalls==0 and w.networkAttempts==0 and w.paletteClicks==128)
  for _,item in ipairs(t.p.controls) do if item.candidateCount==2 then assert(item.verifiedGeneration==item.rootRecord.generation) end end
  clean(w,a)
 end)
 test(pre.."25 duplicate-style palette generations retain 128 identities assignments and bounded binding work",function()
  local w,a,p,t=setup(deferred,0);w.makePalette(128);duplicatePalette(w,128);w.learn(a)
  for i=1,20 do local part=w.province(-260+i*20,-160);a.AddProvince(part);table.insert(p,part);w.protected[part]=true end
  assert(a.RerollCivilColors(128));local colors={};for i,part in ipairs(p) do colors[i]=a.GetTargetStats(part).AssignedCivilColorKey end
  assert(a.ValidateNativePalette());w.step(3)
  local connections=w.connections
  for _=1,25 do
   w.detachPalette();w.flush();assert(a.GetPerformanceStats().LearnedSemanticColors==128 and a.GetPerformanceStats().LivePaletteRoot=="CLOSED")
   w.recreatePalette(128);duplicatePalette(w,128);w.flush();t.p.rebindAll();w.step(.05)
   assert(a.GetPerformanceStats().BoundNativeColors==128)
   for i,part in ipairs(p) do assert(a.GetTargetStats(part).AssignedCivilColorKey==colors[i]) end
  end
  local m=a.GetPerformanceStats();assert(m.GenerationBindingPasses<=26 and m.PaletteRebindAttempts<=128*27)
  assert(w.connections==connections and w.paintCalls==0);clean(w,a)
 end)
 test(pre.."stable generation across three simulated minutes has constant traversal and bind counts",function()
  local w,a,p,t=setup(deferred,4,128);a.SetMode("CIVIL WAR");w.start(a,2);local before=a.GetPerformanceStats();local reads=w.descendantReads
  for i=1,180 do if i%5==0 then p[i%4+1].Color=w.Color3.new(0,0,0) end;w.step(1) end
  local after=a.GetPerformanceStats();assert(after.GenerationBindingPasses==before.GenerationBindingPasses and after.FullGuiTraversals==before.FullGuiTraversals)
  assert(after.PaletteRebindAttempts==before.PaletteRebindAttempts and w.descendantReads==reads);clean(w,a)
 end)
 test(pre.."capacity 137 against128 blocks reroll and START with exact shortage9",function()
  local w,a,p,t=setup(deferred,137,128);local preflight=a.GetCapacityPreflight()
  assert(preflight.Shortage==9 and preflight.VerifiedNativeCapacity==128 and preflight.SelectedCount==137)
  assert(not a.RerollCivilColors(1));a.SetMode("CIVIL WAR");w.start(a,.2)
  assert(not a.GetStats().Running and a.GetStats().Selected==137 and next(w.downs)==nil and a.GetStats().LastMessage:find("9",1,true));clean(w,a)
 end)
 test(pre.."closed palette preserves semantic capacity while clearly reporting detached live controls",function()
  local w,a,p,t=setup(deferred,12,128);w.detachPalette();w.flush();local m=a.GetPerformanceStats();local pf=a.GetCapacityPreflight()
  assert(m.LivePaletteRoot=="CLOSED" and pf.VerifiedNativeCapacity==128 and pf.CurrentlyBoundLiveControls==0 and pf.Shortage==0)
  assert(m.GeneratedColorsAssigned==0 and m.GeneratedColorSupport:find("UNVERIFIED",1,true));clean(w,a)
 end)
 test(pre.."one failed ambiguous color does not corrupt remaining native mappings",function()
  local w,a,p,t=setup(deferred,0);w.makePalette(128);duplicatePalette(w,128);w.learn(a);local profile=a.GetPaletteProfile();for _,row in ipairs(profile.Controls) do row.NativeSignature=nil;row.SemanticVerified=false end
  w.recreatePalette(128);duplicatePalette(w,128);w.flush();assert(a.ImportPaletteData(profile))
  for _,button in ipairs(w.uiButtons) do if button.Name=="Black" then w.buttonColors[button]=w.Color3.new(1,0,0) end end
  assert(a.ValidateNativePalette());w.step(12)
  assert(a.GetPerformanceStats().BoundNativeColors==127 and #t.p.controls==128 and t.p.controls[1].pendingVerification)
  assert(#t.p.controls[1].candidateFailures==2 and w.paintCalls==0);clean(w,a)
 end)
 test(pre.."failed native candidate retries cached list after cooldown without root scan",function()
  local w,a,p,t=setup(deferred,0);w.makePalette(3);duplicatePalette(w,3);w.learn(a);local profile=a.GetPaletteProfile();for _,row in ipairs(profile.Controls) do row.NativeSignature=nil;row.SemanticVerified=false end
  w.recreatePalette(3);duplicatePalette(w,3);w.flush();a.ImportPaletteData(profile);w.ignorePaletteClicks=true
  a.ValidateNativePalette();w.step(4);local scans=a.GetPerformanceStats().FullGuiTraversals
  w.ignorePaletteClicks=false;a.ValidateNativePalette();w.step(3)
  assert(a.GetPerformanceStats().BoundNativeColors==3 and a.GetPerformanceStats().FullGuiTraversals==scans);clean(w,a)
 end)
 test(pre.."v1 duplicate profile requires verification and never trusts saved coordinates",function()
  local w,a,p,t=setup(deferred,0);w.makePalette(3);duplicatePalette(w,3);w.learn(a);local profile=a.GetPaletteProfile();for _,row in ipairs(profile.Controls) do row.NativeSignature=nil;row.SemanticVerified=false end;profile.Version=1
  for _,row in ipairs(profile.Controls) do row.Geometry=nil;row.NormalizedClick={-1000,9999} end
  w.recreatePalette(3);duplicatePalette(w,3);w.flush();assert(a.ImportPaletteData(profile));assert(a.GetPerformanceStats().AmbiguousColors==3)
  a.ValidateNativePalette();w.step(2);assert(a.GetPerformanceStats().BoundNativeColors==3 and w.paintCalls==0);clean(w,a)
 end)
 test(pre.."malformed semantic geometry is rejected without input or partial import",function()
  local w,a,p,t=setup(deferred,1,4);local profile=a.GetPaletteProfile();for _,row in ipairs(profile.Controls) do row.NativeSignature=nil;row.SemanticVerified=false end;profile.Controls[1].Geometry.Normalized={X="bad",Y=0}
  assert(not a.ImportPaletteData(profile) and #t.p.controls==4 and w.paletteClicks==0);clean(w,a)
 end)
 test(pre.."Civil 80-target combat isolates one unavailable swatch and restores stable native assignments",function()
  local w,a,p,t=setup(deferred,80,128);a.SetMode("CIVIL WAR");local keys={}
  for i,part in ipairs(p) do keys[i]=a.GetTargetStats(part).AssignedCivilColorKey end
  local missing=t.entry(p[1]).civilControl.button;w.start(a,.01);missing.Parent=nil;w.flush()
  for tick=1,10 do w.schedule(tick*1.2,function() for i=2,6 do p[i].Color=w.Color3.fromRGB(tick,20,50) end end) end
  w.step(28)
  for i=2,#p do assert(a.ColorsMatch(p[i].Color,t.entry(p[i]).civilColor),"Civil healthy "..i) end
  assert(a.GetStats().Running and a.GetPerformanceStats().PaletteFailures>0 and a.GetPerformanceStats().ReleaseTimeouts==0)
  missing.Parent=w.paletteRoot;w.flush();w.step(5)
  for i,part in ipairs(p) do assert(a.GetTargetStats(part).AssignedCivilColorKey==keys[i] and a.ColorsMatch(part.Color,t.entry(part).civilColor)) end
  assert(a.GetStats().Dirty==0);clean(w,a)
 end)
 test(pre.."palette success then target loss sends zero paint DOWN and skips color on retry",function()
  local w,a,p,t=setup(deferred,1,4);a.SetMode("CIVIL WAR");w.nativePaletteColor=w.color;w.player:SetAttribute("PaintBucketColor",w.color);w.flush();a.SetCameraMode("OFF")
  w.afterPaletteSelect=function() w.cannotAcquire[p[1]]=true end
  w.start(a,.65);assert(w.paletteClicks==1 and next(w.downs)==nil and a.GetPerformanceStats().TargetLostAfterPalette>=1)
  assert(a.ColorsMatch(w.player:GetAttribute("PaintBucketColor"),t.entry(p[1]).civilColor))
  w.afterPaletteSelect=nil;w.cannotAcquire[p[1]]=nil;w.step(1)
  assert(a.GetStats().Dirty==0 and w.paletteClicks==1 and a.GetPerformanceStats().GlobalDwellMs<=250 and a.GetPerformanceStats().TargetLostEventuallyRecovered>=1)
  local records=a.GetServiceRecords();assert(records[1].Result=="TARGET_LOST" and records[#records].Result=="SUCCESS");clean(w,a)
 end)
 test(pre.."Civil avoids palette spending after repeated known-bad geometry",function()
  local w,a,p,t=setup(deferred,2,4);a.SetMode("CIVIL WAR");a.SetCameraMode("OFF")
  w.occluded={[p[1]]=true};w.rayRule=function(_,_,hit) return hit==p[1] and nil or hit end;w.cannotAcquire[p[1]]=true
  w.start(a,5);assert(a.ColorsMatch(p[2].Color,t.entry(p[2]).civilColor))
  assert(a.GetPerformanceStats().GlobalDwellMs<=250 and t.entry(p[1]).ConsecutiveFailures>=3);clean(w,a)
 end)
 test(pre.."focus and native GUI recreation resume stable assignments after focus grace",function()
  local w,a,p,t=setup(deferred,4,8);a.SetMode("CIVIL WAR");w.start(a,1)
  local keys={};for i,part in ipairs(p) do keys[i]=t.entry(part).civilKey end
  w.input.WindowFocusReleased:Fire();w.flush();w.recreatePalette(8);w.flush()
  p[2].Color=w.Color3.new(0,0,0);w.flush();local clicks=w.paletteClicks;w.step(.5);assert(w.paletteClicks==clicks and not a.GetStats().Running)
  w.input.WindowFocused:Fire();w.flush();w.step(.2);assert(not a.GetStats().Running);w.step(2)
  assert(a.GetStats().Running and a.GetStats().Dirty==0)
  for i,part in ipairs(p) do assert(t.entry(part).civilKey==keys[i]) end;clean(w,a)
 end)
 test(pre.."explicit STOP cancels pending automatic focus resume",function()
  local w,a,p=setup(deferred,2);w.start(a,.3);w.input.WindowFocusReleased:Fire();w.flush();a.Stop();w.input.WindowFocused:Fire();w.flush()
  p[1].Color=w.Color3.new(0,0,0);w.step(1);assert(not a.GetStats().Running);clean(w,a)
 end)
 test(pre.."camera rejects below-map upward and inside-geometry poses",function()
  local w,a,p,t=setup(deferred,1);local e=t.entry(p[1])
  assert(not t.v.safePose(e,w.cf(w.v(0,-5,0),p[1].Position)))
  assert(not t.v.safePose(e,w.cf(w.v(0,100,0),w.v(0,110,0))))
  local block=w.instance("Part");block.CanQuery=true;w.cameraObstacles={block}
  assert(not t.v.safePose(e,w.cf(w.v(0,100,0),p[1].Position)))
  assert(t.v.camera.data.UnderMapCandidatesRejected==2 and t.v.camera.data.UnsafeCameraCandidatesRejected==1);clean(w,a)
 end)
 test(pre.."bad camera pose stays blacklisted and safe pose can be reused",function()
  local w,a,p,t=setup(deferred,1);local e=t.entry(p[1]);local good=w.cf(w.v(0,100,0),p[1].Position)
  assert(t.v.safePose(e,good));t.v.blacklistPose(e,good,"test mismatch");assert(not t.v.safePose(e,good))
  assert(t.v.safePose(e,w.cf(w.v(0,110,20),p[1].Position)));clean(w,a)
 end)
 test(pre.."AGGRESSIVE opt-in far targets use bounded fallback and restore original camera",function()
  local w,a,p,t=setup(deferred,0);local cf=w.workspace.CurrentCamera.CFrame
  for i=1,3 do local part=w.province(600+i*90,40);part.Size=w.v(i==1 and 2 or 30,1,i==1 and 2 or 30);a.AddProvince(part);w.protected[part]=true end
  a.SetCameraMode("AGGRESSIVE");w.start(a,8);assert(a.GetStats().Dirty==0 and a.GetPerformanceStats().CameraFallbackSuccesses>=3,a.GetStats().LastMessage)
  assert(w.workspace.CurrentCamera.CFrame==cf and a.GetPerformanceStats().CameraRestores>=3 and a.GetPerformanceStats().UnderMapCandidatesRejected==0);clean(w,a)
 end)
 test(pre.."camera OFF and manual zoom never move camera during recovery",function()
  local w,a,p,t=setup(deferred,0);local part=w.province(900,0);a.AddProvince(part);w.protected[part]=true
  local cf=w.workspace.CurrentCamera.CFrame;a.SetCameraMode("OFF");w.start(a,.5);assert(w.workspace.CurrentCamera.CFrame==cf and a.GetStats().Dirty==1)
  a.Stop();w.step(.1);a.SetCameraMode("AGGRESSIVE");t.v.camera.manualUntil=w.now+1;w.start(a,.5)
  assert(w.workspace.CurrentCamera.CFrame==cf and a.GetPerformanceStats().UserCameraDeferrals>0)
  w.step(2);assert(a.GetStats().Dirty==0 and w.workspace.CurrentCamera.CFrame==cf);clean(w,a)
 end)
 test(pre.."reconciliation reduces steady checks over tenfold and repairs dropped event",function()
  local w,a,p,t=setup(deferred,50);for _,part in ipairs(p) do part.Color=w.color end;w.flush();w.step(60)
  local m=a.GetPerformanceStats();assert(m.ReconciliationChecks<50*60/.12/10 and m.CurrentReconciliationInterval>=1.5)
  p[37]._props.Color=w.Color3.new(0,0,0);w.step(1.6);assert(t.entry(p[37]).dirtyIndex and a.GetPerformanceStats().ReconciliationFinds==1)
  assert(a.GetPerformanceStats().CurrentReconciliationInterval==.12 and w.cursorMoves==0 and next(w.downs)==nil)
  w.step(5);assert(a.GetPerformanceStats().CurrentReconciliationInterval>=1.5);clean(w,a)
 end)
 test(pre.."ten thousand repair-free checks back off to two seconds",function()
  local w,a,p,t=setup(deferred,100);for _,part in ipairs(p) do part.Color=w.color end;w.flush()
  for _=1,101 do t.reconcile() end
  assert(a.GetPerformanceStats().CurrentReconciliationInterval==2 and a.GetStats().Dirty==0 and w.cursorMoves==0);clean(w,a)
 end)
 test(pre.."Protect drag selects thirty real targets once and owns no paint input",function()
  local w,a,p,t=setup(deferred,0);for i=1,30 do table.insert(p,w.province(i*12-200,-50)) end
  w.getButton("Protect Province").Activated:Fire();w.flush();assert(w.bucket.Parent==w.backpack)
  w.mouse.Target=p[1];w.button=true;w.input.InputBegan:Fire({UserInputType=w.env.Enum.UserInputType.MouseButton1},false);w.flush()
  for _,part in ipairs(p) do w.mouse.Target=part;w.mouse.Move:Fire();w.flush() end
  for i=#p,1,-1 do w.mouse.Target=p[i];w.mouse.Move:Fire();w.flush() end
  assert(a.GetStats().Selected==30 and t.v.selection.adds==30 and w.paintCalls==0 and next(w.downs)==nil)
  for _,part in ipairs(p) do assert(t.marker(part).Adornee==part and t.marker(part).ClassName=="Highlight" and t.marker(part).FillTransparency==1) end
  w.button=false;w.input.InputEnded:Fire({UserInputType=w.env.Enum.UserInputType.MouseButton1});w.flush();t.finishSelection();w.step(.15)
  assert(w.bucket.Parent==w.character and not a.GetStats().Running and not t.v.selection.held and next(t.v.selection.visited)==nil);clean(w,a)
 end)
 test(pre.."Unprotect drag removes thirty once without requests or extra listeners",function()
  local w,a,p,t=setup(deferred,30);w.getButton("Unprotect Province").Activated:Fire();w.flush();local connections=w.connections
  w.mouse.Target=p[1];w.button=true;w.input.InputBegan:Fire({UserInputType=w.env.Enum.UserInputType.MouseButton1},false);w.flush()
  for round=1,2 do for _,part in ipairs(p) do w.mouse.Target=part;w.mouse.Move:Fire();w.flush() end end
  assert(a.GetStats().Selected==0 and t.v.selection.removes==30 and #t.dirty==0 and w.connections==connections-90)
  w.button=false;w.input.InputEnded:Fire({UserInputType=w.env.Enum.UserInputType.MouseButton1});w.flush();t.finishSelection();w.step(.15);assert(w.paintCalls==0);clean(w,a)
 end)
 test(pre.."selection single click remains valid and GUI-start drag is ignored",function()
  local w,a,p,t=setup(deferred,0);local part=w.province(0,0);t.beginSelection("ADD");w.mouse.Target=part
  w.button=true;w.input.InputBegan:Fire({UserInputType=w.env.Enum.UserInputType.MouseButton1},true);w.flush();w.step(.03);assert(a.GetStats().Selected==0)
  w.input.InputBegan:Fire({UserInputType=w.env.Enum.UserInputType.MouseButton1},false);w.flush();assert(a.GetStats().Selected==1)
  w.button=false;w.input.InputEnded:Fire({UserInputType=w.env.Enum.UserInputType.MouseButton1});w.flush();t.finishSelection();w.step(.15);clean(w,a)
 end)
 test(pre.."selection focus loss ends stroke and emergency STOP cannot arm paint",function()
  local w,a,p,t=setup(deferred,0);local part=w.province(0,0);t.beginSelection("ADD");w.mouse.Target=part;w.button=true
  w.input.InputBegan:Fire({UserInputType=w.env.Enum.UserInputType.MouseButton1},false);w.flush();w.input.WindowFocusReleased:Fire();w.flush()
  assert(not t.v.selection.held and next(t.v.selection.visited)==nil and next(w.downs)==nil)
  w.button=false;w.input.WindowFocused:Fire();w.flush();t.finishSelection();w.step(.2);assert(not a.GetStats().Running);clean(w,a)
 end)
 test(pre.."outlines remain persistent toggle locally and never alter province Color",function()
  local w,a,p,t=setup(deferred,2);local c=p[1].Color;a.SetProtectedOutlines(false);assert(not t.marker(p[1]).Enabled)
  a.SetProtectedOutlines(true);assert(t.marker(p[1]).Enabled and p[1].Color==c)
  p[1].Color=w.color;w.flush();assert(t.marker(p[1]).ClassName=="Highlight" and t.marker(p[1]).FillTransparency==1);clean(w,a)
 end)
 test(pre.."selection cycles do not leak listeners roots or workers",function()
  local w,a,p,t=setup(deferred,0);local before=w.connections
  for _=1,30 do t.beginSelection("ADD");t.finishSelection();w.step(.15);t.beginSelection("REMOVE");t.finishSelection();w.step(.15) end
  assert(w.connections==before and next(w.downs)==nil and not t.v.selection.restorePending);clean(w,a)
 end)
 test(pre.."all v8.2 reports are read-only and expose overload palette camera clocks",function()
  local w,a,p,t=setup(deferred,3,8);local cursor=w.cursor;local clicks=w.paletteClicks;local report=a.GetActivationReport()..a.GetPerformanceReport()
  for _,field in ipairs({"OverloadEntries","EligibleQueueP90Ms","TotalDirtyAgeP99Ms","PathologicalGroupsDetected","RejectedDwellSamplesByReason","GenerationBindingPasses","UnderMapCandidatesRejected","CurrentReconciliationInterval","GeneratedColorSupport","SelectionAdds"}) do assert(report:find(field,1,true),field) end
  assert(w.cursor==cursor and w.paletteClicks==clicks and w.networkAttempts==0);clean(w,a)
 end)
 test(pre.."absent native palette auto-opens through separately learned live HUD opener",function()
  local w,a,p,t=setup(deferred,2,4);local opener=w.makeChrome()
  local hud=w.instance("ScreenGui");hud.Name="GameToolbar";hud.Enabled=true;hud.Parent=w.playerGui;opener.Parent=hud
  assert(a.BeginPaletteLearning("OPENER"));w.humanSelect(opener);a.FinishPaletteLearning()
  w.buttonActions[opener]=function() w.recreatePalette(4);table.insert(w.uiButtons,opener) end
  a.SetMode("CIVIL WAR");w.start(a,.01);w.detachPalette();w.flush();w.step(2)
  assert(a.GetStats().Dirty==0 and a.GetPerformanceStats().OpenerUses>=1 and a.GetPerformanceStats().LearnedSemanticColors==4);clean(w,a)
 end)
 test(pre.."semantic signature edits invalidate only the used color without a full root scan",function()
  local w,a,p,t=setup(deferred,1,8);local item=t.p.controls[1];local passes=a.GetPerformanceStats().GenerationBindingPasses
  item.button.Text="Different native action";assert(not t.p.resolvePaletteControl(item))
  assert(item.bindingState=="SIGNATURE_MISMATCH" and #t.p.controls==8 and a.GetPerformanceStats().GenerationBindingPasses==passes)
  clean(w,a)
 end)
 test(pre.."opener relearning retires old semantic references",function()
  local w,a,p,t=setup(deferred,0,4);local opener=w.makeChrome()
  for _=1,25 do assert(a.BeginPaletteLearning("OPENER"));w.humanSelect(opener);a.FinishPaletteLearning();t.p.rebindAll() end
  local items=0;for _,root in pairs(t.p.rootRecords) do for _ in pairs(root.items) do items+=1 end end
  assert(items==5);clean(w,a)
 end)
 test(pre.."selection refuses to arm when normal tool cannot be unequipped",function()
  local w,a,p,t=setup(deferred,0);local part=w.province(0,0)
  rawset(w.humanoid,"UnequipTools",function() error("native tool locked") end)
  w.getButton("Protect Province").Activated:Fire();w.flush();assert(a.GetStats().LastMessage:find("Unequip PaintBucket manually",1,true))
  w.mouse.Target=part;w.button=true;w.input.InputBegan:Fire({UserInputType=w.env.Enum.UserInputType.MouseButton1},false);w.flush()
  assert(a.GetStats().Selected==0 and next(w.downs)==nil);w.button=false;clean(w,a)
 end)
 test(pre.."validation cancellation releases input and never starts a paint worker",function()
  local w,a,p,t=setup(deferred,2);w.makePalette(8);duplicatePalette(w,8);w.learn(a);local profile=a.GetPaletteProfile();for _,row in ipairs(profile.Controls) do row.NativeSignature=nil;row.SemanticVerified=false end
  w.recreatePalette(8);duplicatePalette(w,8);w.flush();a.ImportPaletteData(profile)
  w.onPaletteDown=function() a.Stop() end;assert(a.ValidateNativePalette());w.step(.5)
  assert(not a.GetStats().Running and not a.GetStats().Held and w.paintCalls==0 and not t.p.validating)
  assert(#t.p.controls==8);clean(w,a)
 end)
 test(pre.."group cooldown type survives shorter overload retry accounting",function()
  local w,a,p,t=setup(deferred,1);local e=t.entry(p[1]);t.v.defer(e,4,"GROUP");t.v.defer(e,.1,"OVERLOAD")
  w.now=2;t.v.account(e,w.now);assert(e.deferKind=="GROUP" and e.quarantineMs==2000 and e.eligibleMs==0);clean(w,a)
 end)
 test(pre.."tool loss between services resumes only after a stable native tool returns",function()
  local w,a,p,t=setup(deferred,2);w.start(a,.5);w.bucket.Parent=nil;w.flush();w.step(.1);assert(not a.GetStats().Running)
  p[2].Color=w.Color3.new(0,0,0);w.flush();w.bucket.Parent=w.backpack;w.step(1)
  assert(a.GetStats().Running and a.GetStats().Dirty==0 and not a.GetStats().Held);clean(w,a)
 end)
 test(pre.."menu dragging and processed input cannot create selection strokes",function()
  local w,a,p,t=setup(deferred,0);local part=w.province(0,0);t.beginSelection("ADD");w.mouse.Target=part
  local ui=w.instance("TextButton");ui.Parent=w.playerGui;ui.Visible=true;ui.Active=true;w.blockedGUI=ui
  w.button=true;w.input.InputBegan:Fire({UserInputType=w.env.Enum.UserInputType.MouseButton1},false);w.flush();w.mouse.Move:Fire();w.step(.05)
  assert(a.GetStats().Selected==0 and w.paintCalls==0);w.button=false;w.input.InputEnded:Fire({UserInputType=w.env.Enum.UserInputType.MouseButton1});w.flush();w.blockedGUI=nil
  t.finishSelection();w.step(.15);clean(w,a)
 end)

 test(pre.."closed palette and already selected native color need zero opener or swatch clicks",function()
  local w,a,p,t=setup(deferred,1,1);a.SetMode("CIVIL WAR");w.start(a,.001);w.detachPalette();w.flush();w.step(.7)
  assert(a.GetStats().Dirty==0 and w.paletteClicks==0 and a.GetPerformanceStats().PaletteSkipsAlreadyCorrect>=1);clean(w,a)
 end)
 test(pre.."mode change cancels focus-resume intent instead of silently changing paint mode",function()
  local w,a,p,t=setup(deferred,2,4);w.start(a,.5);w.input.WindowFocusReleased:Fire();w.flush()
  a.SetMode("CIVIL WAR");w.input.WindowFocused:Fire();w.flush();w.step(1)
  assert(not a.GetStats().Running and not t.v.resumeIntent);clean(w,a)
 end)

end
assert(failed==0,tostring(failed).." v8.2 regression tests failed")
print(passed.." v8.2 overload/palette/camera/selection regression tests passed (deterministic; not live Roblox proof)")
