local Mock=require("./V82Mock")
local passed,failed=0,0
SOURCE=SOURCE:gsub("local api = {",[[local api = {
 __test={benchmark=benchmark,policy=policy,pacing=pacing,cfg=CFG,palette=palette,entry=function(p) return lookup[p] end},]],1)
local function test(name,fn) local ok,why=pcall(fn);if ok then passed+=1;print("PASS "..name) else failed+=1;print("FAIL "..name..": "..tostring(why)) end end
local function setup(deferred,n,delay,colors)
 local w=Mock.new(deferred);local a=w.load(SOURCE);local parts={};w.protected={};w.nativeRepeat=false
 w.makePalette(colors or 2);w.learn(a);w.humanoid:EquipTool(w.bucket);w.flush()
 for i=1,n do local p=w.province(-250+(i-1)%16*35,-140+math.floor((i-1)/16)*35);a.AddProvince(p);parts[i]=p;w.protected[p]=true end
 local b=a.__test.benchmark
 w.mockPaint=w.mouse.Button1Down:Connect(function()
  local p=w.mouse.Target;local color=w.nativePaletteColor
  if p and p.Parent==w.provinces and (not w.accept or w.accept(p,color,b)) then
   local seconds=b.state=="RESETTING" and .05 or delay
   if seconds then w.schedule(seconds,function() if p.Parent then p.Color=color end end) end
  end
 end)
 return w,a,parts,b
end
local function clean(w,a) a.CancelPaintCooldownBenchmark();w.step(.2);a.Stop();w.step(.3);a.Destroy();w.step(.1);w.mockPaint:Disconnect();w.assertClean() end
local function start(a,n) local ok,why=a.StartPaintCooldownBenchmark({SamplesPerInterval=n or 30});assert(ok,why) end
local function noPause(b) for _,event in ipairs(b.events) do assert(event.Action~="PAUSE",event.Reason) end end
for _,deferred in ipairs({false,true}) do
 local pre=(deferred and "deferred " or "immediate ").."benchmark-only "
 test(pre.."all thirteen intervals complete using exactly the same 30 provinces, asynchronously",function()
  local w,a,p,b=setup(deferred,30,.24);local source=a.__test.pacing.source;start(a);w.step(220)
  assert(b.state=="COMPLETE",b.detail)
  local expected={200,175,150,140,130,120,110,100,90,80,70,60,50};local original={}
  for _,part in ipairs(p) do original[a.__test.entry(part).id]=true end
  for i,row in ipairs(b.rows) do
   assert(row.IntervalMs==expected[i] and row.RawAttempts==30 and row.QualifiedAttempts==30 and row.Successes==30 and row.ValidNoEffect==0)
   assert(#row.Spacings==29 and row.Status=="COMPLETE")
   local seen={};for _,r in ipairs(row.Records) do assert(original[r.EntryId] and not seen[r.EntryId]);seen[r.EntryId]=true;assert(r.Qualified and r.DownObserved and r.ColorAt) end
   for _,ms in ipairs(row.Spacings) do assert(ms>=expected[i]-.001) end
   assert(row.Records[2].DownAt<row.Records[1].ColorAt,"next DOWN waited for color")
  end
  assert(b.reset.Attempts==360 and b.reset.Successes==360 and b.reset.Unqualified==0 and b.reset.Phases==12)
  assert(a.__test.pacing.interval==.226 and a.__test.pacing.source==source and a.GetPerformanceStats().GlobalDwellMs==120)
  assert(a.GetPerformanceStats().Strategies.PER_TARGET.Attempts==0 and a.GetPerformanceStats().SuccessfulPaints==0)
  assert(w.networkAttempts==0 and w.violations==0 and not w.button);noPause(b);clean(w,a)
 end)
 test(pre.."all thirteen low-reliability rows finish; valid misses do not train production",function()
  local w,a,p,b=setup(deferred,30,nil);start(a);w.step(.15);assert(b.rows[1].ValidNoEffect==0)
  w.step(180);assert(b.state=="COMPLETE",b.detail)
  for _,row in ipairs(b.rows) do assert(row.QualifiedAttempts==30 and row.ValidNoEffect==30 and row.Successes==0 and row.SuccessPercentQualified==0) end
  assert(a.GetPerformanceStats().GlobalDwellMs==120 and a.__test.pacing.interval==.226);noPause(b);clean(w,a)
 end)
 for _,bad in ipairs({1,3}) do
  test(pre..bad.." unqualified targets are replaced without a pause and never retried",function()
   local w,a,p,b=setup(deferred,30+bad,.05);for i=1,bad do w.cannotAcquire[p[i]]=true end;start(a);w.step(230)
   assert(b.state=="COMPLETE",b.detail);assert(b.rows[1].Unqualified==bad and b.rows[1].QualifiedAttempts==30 and b.rows[1].RawAttempts==30+bad)
   assert(#b.quarantineEvidence==bad);for _,r in ipairs(b.rows) do assert(r.Successes==30 and r.SuccessPercentQualified==100) end
   for i=2,13 do assert(b.rows[i].Unqualified==0) end;noPause(b);clean(w,a)
  end)
 end
 test(pre.."reset misses on one target are bounded and replaced automatically",function()
  local w,a,p,b=setup(deferred,31,.05)
  w.accept=function(part,color,bench) return not (part==p[1] and bench.state=="RESETTING") end
  start(a);w.step(200);assert(b.state=="COMPLETE",b.detail)
  assert(#b.quarantineEvidence==1 and b.quarantineEvidence[1].Reason:find("RESET_TARGET_NOT_CONFIRMED",1,true))
  local failures=0;for _,e in ipairs(b.events) do if e.Action=="QUARANTINE" then failures+=1 end end
  assert(failures==1 and b.reset.Failures==2);for _,row in ipairs(b.rows) do assert(row.QualifiedAttempts==30 and row.Successes==30) end
  noPause(b);clean(w,a)
 end)
 for _,precondition in ipairs({"TOOL","DISABLED","FOCUS","CHAT","MENU","HELD","CAMERA","COHORT","TARGET","RESET","DETACHED","OPENER","AUTO_RESET"}) do
  test(pre.."preflight refuses "..precondition.." with no input or partial rows",function()
   local w,a,p,b=setup(deferred,30,.05,precondition=="RESET" and 1 or 2)
   if precondition=="TOOL" then w.bucket.Parent=w.backpack
   elseif precondition=="DISABLED" then w.bucket.Enabled=false
   elseif precondition=="FOCUS" then w.input.WindowFocusReleased:Fire();w.flush()
   elseif precondition=="CHAT" then w.textFocused=true
   elseif precondition=="MENU" then w.gui.MenuIsOpen=true
   elseif precondition=="HELD" then w.button=true
   elseif precondition=="CAMERA" then a.SetCameraMode("AGGRESSIVE")
   elseif precondition=="COHORT" then a.RemoveProvince(p[1])
   elseif precondition=="TARGET" then w.player:SetAttribute("PaintBucketColor",w.Color3.new(1,0,1))
   elseif precondition=="DETACHED" then w.paletteRoot:Destroy()
   elseif precondition=="OPENER" then for _,button in ipairs(w.paletteRoot:GetChildren()) do button.Visible=false end end
   local ok,why=a.StartPaintCooldownBenchmark({SamplesPerInterval=30,AutoReset=precondition~="AUTO_RESET"})
   assert(not ok and why:find("BENCHMARK NOT READY",1,true),tostring(why));assert(not b.active and #b.rows==0 and next(w.downs)==nil)
   w.button=false;clean(w,a)
  end)
 end
 test(pre.."request range 30 through 50 is enforced; both 40 and 50 can start",function()
  local w,a,p,b=setup(deferred,50,.05)
  assert(not a.StartPaintCooldownBenchmark({SamplesPerInterval=29}) and not a.StartPaintCooldownBenchmark({SamplesPerInterval=51}))
  start(a,50);w.step(.15);assert(b.samples==50);a.CancelPaintCooldownBenchmark();w.step(.3)
  start(a,40);w.step(.15);assert(b.samples==40);clean(w,a)
 end)
 for _,event in ipairs({"FOCUS","TOOL","MENU","CHAT"}) do
  test(pre..event.." global interruption preserves evidence and resumes automatically",function()
   local w,a,p,b=setup(deferred,32,.05);start(a);w.step(.5);local first=b.rows[1].Records[1]
   if event=="FOCUS" then w.input.WindowFocusReleased:Fire()
   elseif event=="TOOL" then w.bucket.Parent=w.backpack
   elseif event=="MENU" then w.gui.MenuIsOpen=true else w.textFocused=true end
   w.flush();w.step(.5);local n=#b.rows[1].Records
   assert(b.active and b.paused and not b.manual and not w.button and first==b.rows[1].Records[1])
   w.step(.5);assert(#b.rows[1].Records==n)
   if event=="FOCUS" then w.input.WindowFocused:Fire()
   elseif event=="TOOL" then w.humanoid:EquipTool(w.bucket)
   elseif event=="MENU" then w.gui.MenuIsOpen=false else w.textFocused=nil end
   w.flush();w.step(1);assert(not b.paused and #b.rows[1].Records>n and first==b.rows[1].Records[1]);clean(w,a)
  end)
 end
 test(pre.."explicit cancel is the only ordinary cancelled state and stops all later input",function()
  local w,a,p,b=setup(deferred,30,.05);start(a);w.step(.5);a.PausePaintCooldownBenchmark();w.step(.2)
  assert(b.active and b.state=="PAUSED - USER");a.ResumePaintCooldownBenchmark();w.step(.5)
  assert(b.active and not b.paused);a.CancelPaintCooldownBenchmark();w.step(.3);local n=#w.activationEvents
  w.step(1);assert(b.state=="CANCELLED BY USER" and not b.active and #w.activationEvents==n and not w.button);clean(w,a)
 end)
 test(pre.."genuine cohort exhaustion is explicit and does not retry a quarantined target",function()
  local w,a,p,b=setup(deferred,30,.05);w.cannotAcquire[p[1]]=true;start(a);w.step(10)
  assert(b.paused and b.state=="PAUSED - COHORT" and b.rows[1].Unqualified==1 and b.rows[1].QualifiedAttempts==29,b.detail)
  local n=#w.activationEvents;w.step(2);assert(#w.activationEvents==n)
  local replacement=w.province(290,-70);a.AddProvince(replacement);w.protected[replacement]=true;a.ResumePaintCooldownBenchmark();w.step(3)
  assert(b.rows[1].Status=="COMPLETE" and b.rows[1].Successes==30 and not b.paused,b.detail);clean(w,a)
 end)
 test(pre.."palette generation loss is global and automatically rebinds without losing evidence",function()
  local w,a,p,b=setup(deferred,30,.05);start(a);w.step(.5);w.paletteRoot:Destroy();w.flush();w.step(.5)
  assert(b.paused and b.state=="PAUSED - PALETTE" and not w.button);local first=b.rows[1].Records[1]
  w.recreatePalette(2);w.flush();w.step(1);assert(not b.paused and b.rows[1].Records[1]==first);clean(w,a)
 end)
 test(pre.."reset timing and palette clicks cannot enter measured spacing or production learning",function()
  local w,a,p,b=setup(deferred,30,.05);start(a);w.step(30)
  local row=b.rows[2];assert(row.Status=="COMPLETE" and #row.Spacings==29 and not row.Records[1].SpacingMs)
  assert(row.Records[1].DownAt-b.rows[1].Records[30].DownAt>5)
  for _,ms in ipairs(row.Spacings) do assert(ms>=175-.001 and ms<220) end
  assert(b.reset.PaletteMs>0 and b.reset.TotalMs>5000 and a.GetPerformanceStats().Strategies.PER_TARGET.Attempts==0);clean(w,a)
 end)
 test(pre.."copy before start, while running, paused and after cancel never starts input",function()
  local w,a,p,b=setup(deferred,40,.05);local copy;w.env.setclipboard=function(text) copy=text end
  local button=w.findText("Copy Cooldown Benchmark");button.Activated:Fire();w.flush();assert(copy:find("Not started",1,true) and not b.active)
  b.button.Activated:Fire();w.flush();w.step(.2);assert(b.active and b.samples==40)
  b.liveCopy.Activated:Fire();w.flush();assert(copy:find("RawAttempts",1,true))
  a.PausePaintCooldownBenchmark();w.step(.2);local n=#w.activationEvents;b.liveCopy.Activated:Fire();w.flush();assert(#w.activationEvents==n)
  b.cancelButton.Activated:Fire();w.flush();w.step(.2);button.Activated:Fire();w.flush();assert(copy:find("CANCELLED BY USER",1,true));clean(w,a)
 end)
 test(pre.."actual native DOWN timing includes delayed delivery and release, no catch-up",function()
  local w,a,p,b=setup(deferred,30,.24);w.responses["VirtualInput.SendMouseButton"].delay=.03;w.responses["VirtualInput.SendMouseButton"].upDelay=.22
  start(a);w.step(2);a.CancelPaintCooldownBenchmark();w.step(.4)
  assert(#b.rows[1].Spacings>=2);for _,r in ipairs(b.rows[1].Records) do if r.DownObservedAt then assert(r.DownObservedAt-r.DownAt>=.029) end end
  for _,ms in ipairs(b.rows[1].Spacings) do assert(ms>=220) end
  assert(not w.button and a.GetPerformanceStats().ReleaseTimeouts==0);clean(w,a)
 end)
 test(pre.."three native DOWN target losses are unqualified, replaced, and do not pause",function()
  local w,a,p,b=setup(deferred,33,.05);local broken={[p[1]]=true,[p[2]]=true,[p[3]]=true}
  local loss=w.mouse.Button1Down:Connect(function() if broken[w.mouse.Target] and b.state=="RUNNING TEST" then w.mouse.Target=nil end end)
  start(a);w.step(14);local row=b.rows[1]
  assert(row.Status=="COMPLETE" and row.QualifiedAttempts==30 and row.Unqualified==3 and row.Successes==30,b.detail)
  for i=1,3 do assert(row.Records[i].DownSent and row.Records[i].DownObserved and not row.Records[i].Qualified) end
  noPause(b);loss:Disconnect();clean(w,a)
 end)
 test(pre.."release uncertainty is global and prohibits any later DOWN until unpressed",function()
  local w,a,p,b=setup(deferred,30,.05);w.responses["VirtualInput.SendMouseButton"].upDelay=1.1
  start(a);w.step(.6);assert(b.paused and b.state=="PAUSED - RELEASE" and w.button,b.detail)
  local downs=w.downs["VirtualInput.SendMouseButton"];w.step(.4);assert(w.downs["VirtualInput.SendMouseButton"]==downs)
  w.responses["VirtualInput.SendMouseButton"].upDelay=0;w.step(1);assert(not b.paused and b.active);clean(w,a)
 end)
 test(pre.."qualification excludes early color, while evidence and automatic recovery remain",function()
  local w,a,p,b=setup(deferred,31,.05);w.responses["VirtualInput.SendMouseButton"].delay=.04
  w.schedule(.01,function() p[1].Color=w.nativePaletteColor end)
  start(a);w.step(12)
  local first=b.rows[1].Records[1];assert(not first.Qualified and first.Result=="UNQUALIFIED_COLOR_BEFORE_DOWN")
  assert(b.rows[1].QualifiedAttempts==30 and b.rows[1].Successes==30);noPause(b);clean(w,a)
 end)
 test(pre.."known input unavailability fails preflight without any game input",function()
  local w,a,p,b=setup(deferred,30,.05)
  rawset(w.input,"CreateVirtualInput",function() error("mock unavailable") end)
  local ok,why=a.StartPaintCooldownBenchmark({SamplesPerInterval=30})
  assert(not ok and why:find("VirtualInput",1,true) and not b.active and next(w.downs)==nil);clean(w,a)
 end)
 test(pre.."preflight error UI exposes complete readable message and closes cleanly",function()
  local w,a,p,b=setup(deferred,20,.05);assert(not a.StartPaintCooldownBenchmark({SamplesPerInterval=30}))
  local modal=b.notReadyPanel;assert(modal and modal.Parent and modal.Name=="BenchmarkPreflightMessage")
  local dismiss=w.findText("OK — fix setup and try again");assert(dismiss);dismiss.Activated:Fire();w.flush();assert(b.notReadyPanel==nil)
  clean(w,a)
 end)
 test(pre.."missing text box/menu checks cannot be bypassed by the benchmark button",function()
  local w,a,p,b=setup(deferred,40,.05);w.textFocused=true;b.button.Activated:Fire();w.flush()
  assert(not b.active and b.state=="BENCHMARK NOT READY" and #b.rows==0 and next(w.downs)==nil);clean(w,a)
 end)

 test(pre.."reliability thresholds use qualified denominator and actual timing",function()
  local w,a,p,b=setup(deferred,0,.05)
  local function row(ms,success) local spacing={};for _=1,39 do table.insert(spacing,ms) end;return {IntervalMs=ms,Status="COMPLETE",QualifiedAttempts=40,SuccessPercentQualified=success,Unqualified=3,Spacings=spacing} end
  b.rows={row(200,100),row(175,99),row(150,97.5),row(130,95),row(50,50)}
  assert(b.recommend(100).RequestedMs==200 and b.recommend(99).RequestedMs==175 and b.recommend(97.5).RequestedMs==150 and b.recommend(95).RequestedMs==130)
  b.rows={};clean(w,a)
 end)
end
assert(failed==0,tostring(failed).." cooldown benchmark tests failed")
print(tostring(passed).." cooldown benchmark tests passed (deterministic; live cadence unverified)")
