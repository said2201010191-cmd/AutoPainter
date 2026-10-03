-- Production policy from two public reports; private/benchmark measurements stay separate.
local Mock=require("./V82Mock")
local passed,failed=0,0
SOURCE=SOURCE:gsub("local api = {",[[local api = {
 __test={benchmark=benchmark,pacing=pacing,cfg=CFG,palette=palette,policy=policy,entry=function(p) return lookup[p] end,generation=function() return equippedGeneration end},]],1)
local function test(name,fn) local ok,why=pcall(fn);if ok then passed+=1;print("PASS "..name) else failed+=1;print("FAIL "..name..": "..tostring(why)) end end
local function setup(deferred,n,colors)
 local w=Mock.new(deferred);local a=w.load(SOURCE);local p={};w.protected={};w.nativeRepeat=false
 if colors then w.makePalette(colors);w.learn(a) end
 for i=1,n do local part=w.province(-250+(i-1)%16*35,-140+math.floor((i-1)/16)*35);p[i]=part;w.protected[part]=true;a.AddProvince(part) end
 w.paintListener=w.mouse.Button1Down:Connect(function()
  local part,color=w.mouse.Target,w.nativePaletteColor
  if part and part.Parent==w.provinces and not (w.reject and w.reject[part]) then
   w.schedule(.05,function() if part.Parent then part.Color=color end end)
  end
 end)
 return w,a,p,a.__test
end
local function clean(w,a) a.CancelPaintCooldownBenchmark();w.step(.2);a.Stop();w.step(.2);a.Destroy();w.step(.1);w.paintListener:Disconnect();w.assertClean() end
local function downs(w)
 local r={};for _,e in ipairs(w.activationEvents) do if e.kind=="down" then table.insert(r,e.at) end end;return r
end
local function assertFloor(w,floor)
 local d=downs(w);assert(#d>1);for i=2,#d do assert(d[i]-d[i-1]>=floor-1e-6,tostring(d[i]-d[i-1])) end
end
for _,deferred in ipairs({false,true}) do
 local pre=(deferred and "deferred " or "immediate ").."public150 "
 test(pre.."requested config report build and actual observations are distinct",function()
  local w,a,p,t=setup(deferred,8);assert(t.cfg.NormalDownSpacingDefault==.150)
  w.start(a,2);local m=a.GetPerformanceStats()
  assert(a.GetStats().Build=="8.2-native-rgb" and m.NormalRequestedDownSpacingMs==150 and m.NormalProductionFloorMs==150)
  assert(m.NormalCadenceSource=="PUBLIC_LIVE_2RUN_150MS_BASELINE" and m.NormalCadencePolicySource==m.NormalCadenceSource)
  assert(m.NormalActualDownSpacingMinMs>=149.999 and m.NormalActualDownSpacingMeanMs<226)
  assert(m.SuccessfulPaints==8 and m.GlobalDwellMs==120 and a.GetStats().Dirty==0);assertFloor(w,.150);clean(w,a)
 end)
 test(pre.."private 59 ms recommendation cannot lower the production floor",function()
  local w,a,p,t=setup(deferred,6);t.pacing.interval=.059;t.pacing.source="private mock recommendation"
  w.start(a,2);assertFloor(w,.150);assert(t.pacing.interval==.150 and t.pacing.source==t.cfg.NormalCadenceSource)
  assert(a.GetPerformanceStats().GlobalDwellMs==120);clean(w,a)
 end)
 test(pre.."objective private sweep may suggest 59 while production stays 150",function()
  local w,a,p,t=setup(deferred,0);local b=t.benchmark
  for _,ms in ipairs({200,175,150,140,130,120,110,100,90,80,70,60,50}) do
   local spacing={};for _=1,39 do table.insert(spacing,ms==50 and 59 or ms+8) end
   table.insert(b.rows,{IntervalMs=ms,Status="COMPLETE",QualifiedAttempts=40,Attempts=40,RawAttempts=40,Unqualified=0,Successes=40,ValidNoEffect=0,SuccessPercentQualified=100,Spacings=spacing,Latencies={},Records={}})
  end
  local report=a.GetPaintCooldownBenchmarkReport()
  assert(report:find("SuggestedProductionCadenceMs=59",1,true) and report:find("SUGGESTION ONLY, never applied",1,true))
  assert(report:find("Production NORMAL requested cadence: 150.0 ms",1,true) and not report:find("226 ms is the provisional baseline",1,true))
  assert(t.pacing.interval==.150);b.rows={};clean(w,a)
 end)
 for _,reason in ipairs({"UPGRADE_CHANGED","TOOL_SESSION_CHANGED"}) do
  test(pre..reason.." returns to public baseline not old default or private measurement",function()
   local w,a,p,t=setup(deferred,4);t.pacing.interval=.226
   if reason=="UPGRADE_CHANGED" then t.pacing.calibratedContext="different" else t.pacing.calibratedGeneration=-3 end
   w.start(a,1.2);assert(t.pacing.interval==.150 and t.pacing.source:find(reason,1,true))
   assert(t.pacing.source:find(t.cfg.NormalCadenceSource,1,true) and a.GetPerformanceStats().GlobalDwellMs==120);clean(w,a)
  end)
 end
 test(pre.."Civil mode bypasses even a conservative NORMAL interval without waiting",function()
  local w,a,p,t=setup(deferred,1,128);assert(a.RerollCivilColors(42));a.SetMode("CIVIL WAR")
  t.pacing.interval=1;t.pacing.lastDown=w.now
  local start=w.now;local service={strategy="PER_TARGET"}
  assert(t.pacing.wait(t.entry(p[1]),-999,service) and w.now==start and service.cadenceWaitMs==nil)
  assert(t.cfg.TargetDwellDefault==.12 and t.cfg.TargetDwellMin==.12);clean(w,a)
 end)
 test(pre.."benchmark bypasses production gate but reset keeps former 226 cadence",function()
  local w,a,p,t=setup(deferred,30,2);w.humanoid:EquipTool(w.bucket);w.flush()
  local intervals={};local original=t.benchmark.safeShot
  t.benchmark.safeShot=function(entry,interval,phase)
   if phase=="RESETTING" then table.insert(intervals,interval) end
   return original(entry,interval,phase)
  end
  assert(a.StartPaintCooldownBenchmark({SamplesPerInterval=30}));w.step(18)
  assert(#intervals>=30);for _,seconds in ipairs(intervals) do assert(seconds==.226) end
  assert(t.benchmark.rows[1].Successes==30 and t.benchmark.rows[2].Attempts>0 and t.pacing.interval==.150)
  assert(a.GetPerformanceStats().GlobalDwellMs==120 and w.networkAttempts==0);clean(w,a)
 end)
 test(pre.."NORMAL Civil NORMAL switches preserve 150 policy and independent dwell",function()
  local w,a,p,t=setup(deferred,8,128);a.RerollCivilColors(52);local assigned={};for i,part in ipairs(p) do assigned[i]=t.entry(part).civilKey end
  for _=1,3 do a.SetMode("CIVIL WAR");a.SetMode("NORMAL") end
  w.start(a,2);assert(t.pacing.interval==.150 and a.GetStats().Dirty==0 and a.GetPerformanceStats().GlobalDwellMs==120)
  for i,part in ipairs(p) do assert(t.entry(part).civilKey==assigned[i]) end;clean(w,a)
 end)
 test(pre.."cadence is excluded from native service and dwell samples",function()
  local w,a,p,t=setup(deferred,16);w.start(a,3)
  local waiting=0;for _,r in ipairs(a.GetServiceRecords()) do
   assert(r.Result=="SUCCESS" and r.NativeDownToCorrectionMs<80 and r.EffectivePaintWindowMs==120)
   if r.CadenceWaitMs>40 then waiting+=1;assert(r.AcquiredToCorrectMs>r.NativeDownToCorrectionMs+35) end
  end
  assert(waiting>=8 and a.GetPerformanceStats().GlobalDwellMs==120 and a.GetStats().Dirty==0);clean(w,a)
 end)
 test(pre.."qualified no-effects stay target-local while other targets finish",function()
  local w,a,p,t=setup(deferred,20);w.reject={[p[1]]=true,[p[2]]=true};w.start(a,5)
  for i=3,20 do assert(a.ColorsMatch(p[i].Color,w.nativePaletteColor)) end
  assert(a.GetPerformanceStats().GlobalDwellMs==120 and t.pacing.interval==.150)
  local missed=0;for _,r in ipairs(a.GetServiceRecords()) do if r.Result=="VALID_NO_EFFECT" then missed+=1;assert(r.EffectivePaintWindowMs==120) end end
  assert(missed>0);clean(w,a)
 end)
 test(pre.."focus loss during 150 gate emits no deferred input",function()
  local w,a,p,t=setup(deferred,5);w.start(a,.10);w.input.WindowFocusReleased:Fire();w.flush();w.step(.5)
  assert(#downs(w)==1 and not w.button and not a.GetStats().Running and t.pacing.interval==.150);clean(w,a)
 end)
 test(pre.."new loader refuses an older running controller rather than silently retaining 226",function()
  local w,a,p,t=setup(deferred,0);local current=a.GetStats;a.GetStats=function() local m=current();m.Build="8.2-followup";return m end
  local ok,why=pcall(function() w.load(SOURCE) end)
  assert(not ok and tostring(why):find("close the older",1,true));a.GetStats=current
  assert(w.load(SOURCE)==a and next(w.downs)==nil);clean(w,a)
 end)
 test(pre.."128 assignments and bound colors survive recreation under new policy",function()
  local w,a,p,t=setup(deferred,128,128);assert(a.RerollCivilColors(17));local keys,seen={},{}
  for i,part in ipairs(p) do local key=t.entry(part).civilKey;assert(key and not seen[key]);seen[key]=true;keys[i]=key end
  w.recreatePalette(128);w.flush();assert(a.GetPerformanceStats().BoundNativeColors==128)
  for i,part in ipairs(p) do assert(t.entry(part).civilKey==keys[i]) end
  assert(a.GetCapacityPreflight().NativeApplicationCapacity==128);clean(w,a)
 end)
 test(pre.."129+ gets unique generated assignments but no paint proof from assignment",function()
  local w,a,p,t=setup(deferred,186,128);a.SetMode("CIVIL WAR");assert(a.RerollCivilColors(18))
  local c=a.GetCapacityPreflight()
  assert(not a.GetStats().Running and c.GeneratedColorApplicationViaCurrentNativePath=="SOURCE_TRACED_NOT_LIVE_VERIFIED" and c.GeneratedVerifiedCapacity==0)
  assert(c.Shortage==0 and c.GeneratedAdditionalRequired==58)
  assert(t.entry(p[129]).civilControl.generated and next(w.downs)==nil and w.networkAttempts==0);clean(w,a)
 end)
 test(pre.."dormant generated candidates exclude all native colors and are reproducible after rebind",function()
  local w,a,p,t=setup(deferred,186,128);local before=a.GetDormantGeneratedColorPreview(58,841)
  w.recreatePalette(128);w.flush();local after=a.GetDormantGeneratedColorPreview(58,841)
  for i,c in ipairs(before) do
   assert(a.ColorsMatch(c,after[i]));for j=1,i-1 do assert(not a.ColorsMatch(c,before[j])) end
   for _,native in ipairs(t.palette.controls) do assert(not a.ColorsMatch(c,native.color)) end
  end
  assert(t.entry(p[129]).civilColor==nil and a.GetPerformanceStats().GeneratedVerifiedCapacity==0);clean(w,a)
 end)
end
assert(failed==0,tostring(failed).." public150 tests failed")
print(tostring(passed).." public150 tests passed (deterministic; native generated application still requires live proof)")
