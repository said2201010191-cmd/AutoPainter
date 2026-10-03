local Mock=require("./V82Mock")
local passed,failed=0,0
SOURCE=SOURCE:gsub("local api = {",[[local api = {
 __test={benchmark=benchmark,pacing=pacing,policy=policy,generation=function() return equippedGeneration end,cfg=CFG,entry=function(p) return lookup[p] end,palette=palette},]],1)
local function test(name,fn) local ok,why=pcall(fn);if ok then passed+=1;print("PASS "..name) else failed+=1;print("FAIL "..name..": "..tostring(why)) end end
local function setup(deferred,n,learn,delay)
 local w=Mock.new(deferred);local a=w.load(SOURCE);local parts={};w.protected={};w.nativeRepeat=false
 if learn then w.makePalette(learn);w.learn(a) end
 for i=1,n do local p=w.province(-250+(i-1)%16*35,-140+math.floor((i-1)/16)*35);a.AddProvince(p);parts[i]=p;w.protected[p]=true end
 w.mockPaint=w.mouse.Button1Down:Connect(function()
  local p=w.mouse.Target;local color=w.nativePaletteColor
  if p and p.Parent==w.provinces and delay then w.schedule(delay,function() if p.Parent then p.Color=color end end) end
 end)
 return w,a,parts,a.__test
end
local function clean(w,a) a.CancelPaintCooldownBenchmark();w.step(.2);a.Stop();w.step(.2);a.Destroy();w.step(.2);w.mockPaint:Disconnect();w.assertClean() end
for _,deferred in ipairs({false,true}) do
 local pre=(deferred and "deferred " or "immediate ").."followup "
 test(pre.."production uses PER_TARGET and a separate evidence-based native spacing gate",function()
  local w,a,p,t=setup(deferred,6,nil,.05);w.start(a,2)
  assert(a.GetStats().Dirty==0 and t.cfg.ActivationStrategy=="PER_TARGET")
  local m=a.GetPerformanceStats();assert(m.GlobalDwellMs==120, "dwell="..tostring(m.GlobalDwellMs));assert(m.NormalMinimumDownSpacingMs==226 and m.Strategies.CONTINUOUS.Attempts==0)
  local downs={};for _,e in ipairs(w.activationEvents) do if e.kind=="down" then table.insert(downs,e.at) end end
  assert(#downs==6, "downs="..#downs);for i=2,#downs do assert(downs[i]-downs[i-1]>=.225999) end
  assert(m.NormalActualDownSpacingMinMs>=225.999 and m.SuccessfulPaints==6);clean(w,a)
 end)
 test(pre.."solo sweep resets same 30 provinces using real learned palette and preserves Civil assignments",function()
  local w,a,p,t=setup(deferred,30,128,.06);a.RerollCivilColors(42);local assigned={};for i,part in ipairs(p) do assigned[i]=a.GetTargetStats(part).AssignedCivilColorKey end
  assert(a.StartPaintCooldownBenchmark({SamplesPerInterval=30}));w.step(200)
  local b=t.benchmark;assert(b.state=="COMPLETE",b.state..": "..b.detail)
  for _,r in ipairs(b.rows) do assert(r.Status=="COMPLETE" and r.Attempts==30 and r.Successes==30 and r.Unqualified==0) end
  assert(b.reset.Phases==12 and b.reset.Successes==360 and b.reset.Attempts==360)
  assert(w.paletteClicks>=24 and a.GetPerformanceStats().Strategies.PER_TARGET.Attempts==0 and a.GetPerformanceStats().SuccessfulPaints==0)
  for i,part in ipairs(p) do assert(a.GetTargetStats(part).AssignedCivilColorKey==assigned[i]) end
  assert(t.pacing.source:find("COMPLETED_NATIVE_SWEEP",1,true) and t.pacing.interval<.226)
  assert(w.networkAttempts==0 and w.violations==0);clean(w,a)
 end)
 test(pre.."Escape preserves partial row and Resume continues without discarding evidence",function()
  local w,a,p,t=setup(deferred,40,nil,.06);assert(a.StartPaintCooldownBenchmark());w.step(.65)
  local b=t.benchmark;local first=b.rows[1].Records[1];local n=#b.rows[1].Records
  w.input.InputBegan:Fire({KeyCode=w.env.Enum.KeyCode.Escape,UserInputType=w.env.Enum.UserInputType.Keyboard},false);w.flush();w.step(.3)
  assert(b.active and b.paused and b.manual and not w.button and first==b.rows[1].Records[1])
  assert(a.GetPaintCooldownBenchmarkReport():find("PAUSE",1,true));assert(a.ResumePaintCooldownBenchmark());w.step(.8)
  assert(b.active and #b.rows[1].Records>n and first==b.rows[1].Records[1]);clean(w,a)
 end)
 test(pre.."focus loss preserves completed rows and automatically resumes on stable focus",function()
  local w,a,p,t=setup(deferred,40,nil,.06);a.StartPaintCooldownBenchmark();w.step(1)
  local b=t.benchmark;local n=#b.rows[1].Records
  w.input.WindowFocusReleased:Fire();w.flush();w.step(.5)
  assert(b.active and b.state=="PAUSED - FOCUS" and not w.button and #b.rows[1].Records==n)
  w.input.WindowFocused:Fire();w.flush();w.step(1)
  assert(b.active and not b.paused and #b.rows[1].Records>n);clean(w,a)
 end)
 test(pre.."tool loss pauses and re-equipping resumes in a new timing segment",function()
  local w,a,p,t=setup(deferred,40,nil,.06);a.StartPaintCooldownBenchmark();w.step(.5)
  w.bucket.Parent=w.backpack;w.flush();w.step(.5);local b=t.benchmark;assert(b.active and b.state=="PAUSED - TOOL" and not w.button)
  w.humanoid:EquipTool(w.bucket);w.flush();w.step(.7);assert(b.active and not b.paused and b.segment>1);clean(w,a)
 end)
 test(pre.."no second verified color waits for manual reset without destroying first interval",function()
  local w,a,p,t=setup(deferred,30,nil,.06);a.StartPaintCooldownBenchmark({SamplesPerInterval=30});w.step(8)
  local b=t.benchmark;assert(b.rows[1].Status=="COMPLETE" and b.state=="WAITING FOR DIRTY" and b.paused,b.detail)
  local first=b.rows[1].Successes;w.step(70);assert(b.active and b.rows[1].Successes==first)
  for _,part in ipairs(p) do part.Color=w.Color3.new(0,0,1) end;w.flush();assert(a.ResumePaintCooldownBenchmark());w.step(.8)
  assert(b.rows[2].Attempts>0 and b.rows[1].Successes==30);clean(w,a)
 end)
 test(pre.."one acquisition failure is unqualified and next target still receives service",function()
  local w,a,p,t=setup(deferred,30,nil,.06);w.cannotAcquire[p[1]]=true;a.StartPaintCooldownBenchmark({SamplesPerInterval=30});w.step(10)
  local b=t.benchmark;assert(b.rows[1].Status=="COMPLETE" and b.rows[1].Unqualified==1 and b.rows[1].Successes==29,b.detail)
  assert(b.active and b.state=="WAITING FOR DIRTY" and t.pacing.interval==.226);clean(w,a)
 end)
 test(pre.."RGB generation and native application have independent honest statuses",function()
  local w,a,p,t=setup(deferred,186,128,nil);local cap=a.GetCapacityPreflight();local m=a.GetPerformanceStats()
  assert(cap.GeneratedColorCreation=="PROVEN" and cap.GeneratedColorApplicationViaCurrentNativePath=="UNVERIFIED")
  assert(cap.NativeApplicationCapacity==128 and cap.GeneratedAdditionalRequired==58 and m.GeneratedVerifiedCapacity==0)
  local preview=a.GetDormantGeneratedColorPreview(58,17)
  assert(#preview==58 and not cap.Message:find("no generated capacity",1,true));clean(w,a)
 end)
 test(pre.."cadence wait cannot inflate dwell or qualified service latency",function()
  local w,a,p,t=setup(deferred,12,nil,.06);w.start(a,3.5)
  local paced=0
  for _,r in ipairs(a.GetServiceRecords()) do
   assert(r.Result=="SUCCESS" and r.NativeDownToCorrectionMs<80 and r.EffectivePaintWindowMs==120)
   if r.CadenceWaitMs>100 then paced+=1;assert(r.AcquiredToCorrectMs>r.NativeDownToCorrectionMs+90) end
  end
  assert(paced>5 and a.GetPerformanceStats().GlobalDwellMs==120);clean(w,a)
 end)
 test(pre.."clean event during pacing prevents another DOWN",function()
  local w,a,p,t=setup(deferred,4,nil,.05);w.start(a,.10)
  for _,part in ipairs(p) do part.Color=w.color end;w.flush();w.step(.5)
  assert((w.downs["VirtualInput.SendMouseButton"] or 0)==1 and a.GetStats().Dirty==0 and not w.button);clean(w,a)
 end)
 test(pre.."STOP during cadence wait does not create deferred input",function()
  local w,a,p,t=setup(deferred,4,nil,.05);w.start(a,.10);a.Stop();w.step(.5)
  assert((w.downs["VirtualInput.SendMouseButton"] or 0)==1 and not w.button and not a.GetStats().Running);clean(w,a)
 end)
 test(pre.."chat focus pauses evidence and closing chat resumes safely",function()
  local w,a,p,t=setup(deferred,30,nil,.08);a.StartPaintCooldownBenchmark({SamplesPerInterval=30});w.step(.6)
  w.textFocused=true;w.step(.4);local b=t.benchmark;local n=#b.rows[1].Records
  assert(b.active and b.state=="PAUSED - FOCUS" and not w.button)
  w.step(1);assert(#b.rows[1].Records==n);w.textFocused=nil;w.step(.9)
  assert(not b.paused and #b.rows[1].Records>n);clean(w,a)
 end)
 test(pre.."three unqualified acquisitions pause boundedly then Resume repairs progress",function()
  local w,a,p,t=setup(deferred,30,nil,.05);for i=1,3 do w.cannotAcquire[p[i]]=true end
  a.StartPaintCooldownBenchmark({SamplesPerInterval=30});w.step(7)
  local b=t.benchmark;assert(b.active and b.paused and b.manual and b.rows[1].Unqualified==3)
  local n=#b.rows[1].Records;w.step(3);assert(#b.rows[1].Records==n)
  w.cannotAcquire={};assert(a.ResumePaintCooldownBenchmark());w.step(2)
  assert(b.rows[1].Successes>0 and b.rows[1].Unqualified==3);clean(w,a)
 end)
 test(pre.."insufficient selection survives additions and explicit Resume",function()
  local w,a,p,t=setup(deferred,20,nil,.06);a.StartPaintCooldownBenchmark({SamplesPerInterval=30});w.step(.4)
  local b=t.benchmark;assert(b.active and b.state=="WAITING FOR DIRTY" and next(w.downs)==nil)
  assert(b.addButton.Visible);b.addButton.Activated:Fire();w.flush()
  for i=21,30 do local part=w.province(-250+(i-1)%16*35,-140+math.floor((i-1)/16)*35);a.AddProvince(part);w.protected[part]=true end
  w.findText("DONE / FINISH SETUP").Activated:Fire();w.flush();w.step(.4);assert(next(w.downs)==nil);b.resumeButton.Activated:Fire();w.flush();w.step(.8)
  assert(b.rows[1].Attempts>0 and #b.cohort==30);clean(w,a)
 end)
 test(pre.."color after observation deadline is never retroactively called success",function()
  local w,a,p,t=setup(deferred,30,nil,.9);a.StartPaintCooldownBenchmark({SamplesPerInterval=30});w.step(8)
  local r=t.benchmark.rows[1];assert(r.Status=="COMPLETE" and r.Successes==0 and r.ValidNoEffect==30)
  w.step(2);a.GetPaintCooldownBenchmarkReport();assert(r.Successes==0 and a.GetPerformanceStats().SuccessfulPaints==0);clean(w,a)
 end)
 test(pre.."color before observed delayed DOWN cannot be claimed as benchmark success",function()
  local w,a,p,t=setup(deferred,30,nil,nil);w.responses["VirtualInput.SendMouseButton"].delay=.04
  w.schedule(.02,function() for _,part in ipairs(p) do part.Color=w.color end end)
  a.StartPaintCooldownBenchmark({SamplesPerInterval=30});w.step(.8)
  assert(t.benchmark.rows[1].Successes==0 and t.benchmark.rows[1].ValidNoEffect==0);clean(w,a)
 end)
 test(pre.."unexpected sample exception is retained as recoverable pause",function()
  local w,a,p,t=setup(deferred,30,nil,.06);local original=t.benchmark.shot;local once=true
  t.benchmark.shot=function(...) if once then once=false;error("mock target inspection exception") end;return original(...) end
  a.StartPaintCooldownBenchmark({SamplesPerInterval=30});w.step(.3)
  assert(t.benchmark.active and t.benchmark.paused and t.benchmark.pauseReason:find("mock target",1,true) and not w.button)
  a.ResumePaintCooldownBenchmark();w.step(.9);assert(t.benchmark.rows[1].Successes>0);clean(w,a)
 end)
 test(pre.."native reset failure pauses without modifying measured rows",function()
  local w,a,p,t=setup(deferred,30,128,.05);w.ignorePaletteClicks=true
  a.StartPaintCooldownBenchmark({SamplesPerInterval=30});w.step(10)
  local b=t.benchmark;assert(b.active and b.paused and b.rows[1].Status=="COMPLETE" and b.rows[1].Successes==30)
  assert(b.rows[2].Attempts==0 and b.reset.Attempts==0 and not w.button)
  w.ignorePaletteClicks=false;a.ResumePaintCooldownBenchmark();w.step(10)
  assert(b.rows[2].Attempts>0 and b.rows[1].Successes==30);clean(w,a)
 end)
 test(pre.."cancel in native reset preserves row and stops every later input",function()
  local w,a,p,t=setup(deferred,30,128,.06);a.StartPaintCooldownBenchmark({SamplesPerInterval=30})
  for _=1,250 do if t.benchmark.reset.Attempts>=2 then break end;w.step(.05) end
  local b=t.benchmark;assert(b.reset.Attempts>=2 and b.rows[1].Successes==30)
  b.cancelButton.Activated:Fire();w.flush();w.step(.4);local n=#w.activationEvents
  w.step(2);assert(not b.active and b.state=="CANCELLED BY USER" and b.rows[1].Successes==30 and #w.activationEvents==n and not w.button);clean(w,a)
 end)
 test(pre.."128 semantic colors and Civil assignments survive GUI recreation during benchmark pause",function()
  local w,a,p,t=setup(deferred,30,128,.06);a.RerollCivilColors(69);local key=a.GetTargetStats(p[1]).AssignedCivilColorKey
  a.StartPaintCooldownBenchmark({SamplesPerInterval=30});w.step(.5);a.PausePaintCooldownBenchmark();w.step(.15)
  w.recreatePalette(128);w.flush();local m=a.GetPerformanceStats();assert(m.SemanticKnownCapacity==128 and m.BoundNativeColors==128)
  assert(a.GetTargetStats(p[1]).AssignedCivilColorKey==key)
  a.ResumePaintCooldownBenchmark();w.step(190);assert(t.benchmark.state=="COMPLETE" and t.benchmark.rows[13].Successes==30)
  assert(a.GetTargetStats(p[1]).AssignedCivilColorKey==key and a.GetPerformanceStats().BoundNativeColors==128);clean(w,a)
 end)
 test(pre.."complete benchmark restores previously running Civil with one input owner",function()
  local w,a,p,t=setup(deferred,30,128,.05);a.RerollCivilColors(75);a.SetMode("CIVIL WAR");w.start(a,.4)
  local key=a.GetTargetStats(p[1]).AssignedCivilColorKey;local attempts=t.policy.civil.Attempts
  a.StartPaintCooldownBenchmark({SamplesPerInterval=30});w.step(205)
  assert(t.benchmark.state=="COMPLETE" and a.GetStats().Mode=="CIVIL WAR" and a.GetStats().Running)
  assert(a.GetStats().Dirty==0 and a.GetTargetStats(p[1]).AssignedCivilColorKey==key and t.policy.civil.Attempts>attempts)
  assert(w.violations==0 and w.networkAttempts==0 and a.GetPerformanceStats().ReleaseTimeouts==0);clean(w,a)
 end)
 test(pre.."recommendation uses measured P90 and rejects incomplete unqualified changed-context rows",function()
  local w,a,p,t=setup(deferred,0,nil,nil);local b=t.benchmark
  local function row(requested,actual) local s={};for _=1,39 do table.insert(s,actual) end;return {Status="COMPLETE",Attempts=40,Unqualified=0,SuccessPercent=100,CleanSkipped=0,Spacings=s,Upgrade=t.pacing.context(),ToolGeneration=t.generation(),IntervalMs=requested} end
  b.rows={row(50,110),row(100,150)};assert(b.recommend().Seconds==.110)
  b.rows[1].Unqualified=1;assert(b.recommend().Seconds==.150)
  b.rows[1].Unqualified=0;b.rows[1].ContextChanged=true;assert(b.recommend().Seconds==.150)
  b.rows[2].ToolGeneration=-1;assert(b.recommend()==nil);b.rows[2].ToolGeneration=t.generation()
  b.rows[2].Status="RUNNING TEST";assert(b.recommend()==nil);b.rows={};clean(w,a)
 end)
 test(pre.."upgrade change invalidates measured cadence without touching dwell",function()
  local w,a,p,t=setup(deferred,3,nil,.05);t.pacing.interval=.08;t.pacing.calibratedContext="old level";t.pacing.source="mock prior sweep"
  w.start(a,1);assert(t.pacing.interval==.226 and t.pacing.source:find("UPGRADE_CHANGED",1,true))
  assert(a.GetPerformanceStats().GlobalDwellMs==120 and a.GetStats().Dirty==0);clean(w,a)
 end)
 test(pre.."benchmark keeps mode and camera locked through the actual menu and API",function()
  local w,a,p,t=setup(deferred,30,nil,.05);a.StartPaintCooldownBenchmark({SamplesPerInterval=30});w.step(.2);a.PausePaintCooldownBenchmark();w.step(.2)
  local mode=w.findText("Mode: NORMAL");mode.Activated:Fire();w.flush()
  assert(a.GetStats().Mode=="NORMAL" and not a.SetMode("CIVIL WAR") and not a.SetCameraMode("AGGRESSIVE"))
  assert(a.GetPerformanceStats().CameraMovesApplied==0 and not w.button);clean(w,a)
 end)
 test(pre.."copy paused report preserves partial timestamps and does not schedule input",function()
  local w,a,p,t=setup(deferred,30,nil,.06);local copy;w.env.setclipboard=function(text) copy=text end
  a.StartPaintCooldownBenchmark({SamplesPerInterval=30});w.step(.5);a.PausePaintCooldownBenchmark();w.step(.2)
  local b=t.benchmark;local first=b.rows[1].Records[1];local n=#w.activationEvents
  b.liveCopy.Activated:Fire();w.flush();w.step(.2)
  assert(copy:find("PER-ATTEMPT LOCAL EVIDENCE",1,true) and copy:find("PauseReason=",1,true) and #w.activationEvents==n)
  assert(first==b.rows[1].Records[1] and first.DownObservedAt);clean(w,a)
 end)
 test(pre.."generated preview makes 58 unique non-palette colors reproducibly without assigning or input",function()
  local w,a,p,t=setup(deferred,186,128,nil);local current={};for i=1,58 do current[i]=p[i].Color end
  local x=a.GetDormantGeneratedColorPreview(58,171,current);local y=a.GetDormantGeneratedColorPreview(58,171,current)
  for i=1,58 do
   assert(a.ColorsMatch(x[i],y[i]) and t.palette.distance(x[i],current[i])>=(.18*255)^2)
   for j=1,i-1 do assert(not a.ColorsMatch(x[i],x[j])) end
   for _,native in ipairs(t.palette.controls) do assert(not a.ColorsMatch(x[i],native.color)) end
  end
  assert(next(w.downs)==nil and t.entry(p[129]).civilColor==nil and a.GetPerformanceStats().GeneratedColorsAssigned==0);clean(w,a)
 end)
 test(pre.."capacity warning is printed once and distinguishes generation from transport",function()
  local w,a,p,t=setup(deferred,186,128,nil);a.SetMode("CIVIL WAR");w.start(a,.4)
  assert(not a.GetStats().Running);local found=false
  for _,o in ipairs(w.playerGui:GetDescendants()) do
   if o.ClassName=="TextLabel" and type(o.Text)=="string" and o.Text:find("Selected provinces:",1,true) then
    local _,n=o.Text:gsub("Selected provinces:","");assert(n==1 and o.Text:find("RGB generation is proven",1,true));found=true
   end
  end
  assert(found and a.GetCapacityPreflight().GeneratedAdditionalRequired==58);clean(w,a)
 end)
 test(pre.."repeated pause resume keeps one worker and bounded evidence",function()
  local w,a,p,t=setup(deferred,40,nil,.06);a.StartPaintCooldownBenchmark();w.step(.3)
  for _=1,12 do a.PausePaintCooldownBenchmark();w.step(.05);assert(not w.button);a.ResumePaintCooldownBenchmark();w.step(.45) end
  local b=t.benchmark;assert(b.active and #b.events<=64 and #b.rows[1].Records<=40 and w.violations==0 and a.GetPerformanceStats().ReleaseTimeouts==0)
  assert(a.GetPerformanceStats().Strategies.PER_TARGET.Attempts==0);clean(w,a)
 end)
 test(pre.."cancellation cannot turn an unfinished observation into a false no-effect",function()
  local w,a,p,t=setup(deferred,30,nil,nil);a.StartPaintCooldownBenchmark({SamplesPerInterval=30});w.step(.1)
  a.CancelPaintCooldownBenchmark();w.step(.2);local r=t.benchmark.rows[1];assert(r.Attempts>0)
  w.step(1);a.GetPaintCooldownBenchmarkReport();assert(r.ValidNoEffect==0 and r.Unqualified>0 and r.Pending==0)
  assert(#t.benchmark.cohort==0 and t.benchmark.tool==nil and not w.button);clean(w,a)
 end)
 test(pre.."native menu and disabled tool pause rather than send unqualified spam",function()
  local w,a,p,t=setup(deferred,30,nil,.06);a.StartPaintCooldownBenchmark({SamplesPerInterval=30});w.step(.3)
  w.gui.MenuIsOpen=true;w.step(.3);assert(t.benchmark.state=="PAUSED - FOCUS" and not w.button)
  w.gui.MenuIsOpen=false;w.bucket.Enabled=false;w.step(.4);assert(t.benchmark.state=="PAUSED - TOOL" and not w.button)
  w.bucket.Enabled=true;w.step(.8);assert(t.benchmark.active and not t.benchmark.paused);clean(w,a)
 end)
end
assert(failed==0,tostring(failed).." followup tests failed")
print(tostring(passed).." live-followup tests passed (deterministic; native live cadence unverified)")
