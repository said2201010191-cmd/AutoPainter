local Mock=require("./V82Mock")
local passed,failed=0,0
SOURCE=SOURCE:gsub("local api = {",[[local api = {
 __test={benchmark=benchmark,policy=policy,cfg=CFG,entry=function(p) return lookup[p] end},]],1)
local function test(name,fn) local ok,why=pcall(fn);if ok then passed+=1;print("PASS "..name) else failed+=1;print("FAIL "..name..": "..tostring(why)) end end
local function setup(deferred,n,delay)
 local w=Mock.new(deferred);local a=w.load(SOURCE);local parts={};w.protected={};w.nativeRepeat=false
 for i=1,n do local p=w.province(-250+(i-1)%16*35,-140+math.floor((i-1)/16)*35);a.AddProvince(p);parts[i]=p;w.protected[p]=true end
 w.mockPaint=w.mouse.Button1Down:Connect(function()
  local p=w.mouse.Target;local color=w.player:GetAttribute("PaintBucketColor")
  if p and delay then w.schedule(delay,function() if p.Parent then p.Color=color end end) end
 end)
 return w,a,parts,a.__test.benchmark
end
local function clean(w,a) a.CancelPaintCooldownBenchmark();w.step(.2);a.Stop();w.step(.3);a.Destroy();w.step(.1);w.mockPaint:Disconnect();w.assertClean() end
local function replenish(w,parts,b,a)
 local last=1
 return w.runService.Heartbeat:Connect(function()
  if b.active and b.state=="WAITING FOR DIRTY" and b.index>last then
   last=b.index;for _,p in ipairs(parts) do p.Color=w.Color3.new(0,0,1) end;a.ResumePaintCooldownBenchmark()
  end
 end)
end
for _,deferred in ipairs({false,true}) do
 local pre=(deferred and "deferred " or "immediate ").."cadence "
 test(pre.."all thirteen intervals sample 30 distinct targets and observe late colors without blocking next DOWN",function()
  local w,a,p,b=setup(deferred,30,.24);local refill=replenish(w,p,b,a)
  assert(a.StartPaintCooldownBenchmark({SamplesPerInterval=30}));w.step(80)
  assert(b.state=="COMPLETE",a.GetPaintCooldownBenchmarkReport())
  local expected={200,175,150,140,130,120,110,100,90,80,70,60,50}
  for i,row in ipairs(b.rows) do
   assert(row.IntervalMs==expected[i] and row.Attempts==30 and row.Successes==30 and row.ValidNoEffect==0)
   assert(#row.Spacings==29 and row.Status=="COMPLETE")
   local seen={};for _,r in ipairs(row.Records) do assert(not seen[r.EntryId]);seen[r.EntryId]=true;assert(r.Qualified and r.DownObserved and r.ColorAt) end
   for _,ms in ipairs(row.Spacings) do assert(ms>=expected[i]-.001) end
   assert(row.Records[2].DownAt<row.Records[1].ColorAt,"next DOWN waited for color")
  end
  assert(a.GetStats().Mode=="NORMAL" and not a.GetStats().Running and not w.button)
  assert(a.GetPerformanceStats().Strategies.PER_TARGET.Attempts==0 and a.GetPerformanceStats().SuccessfulPaints==0)
  assert(w.networkAttempts==0 and w.violations==0);refill:Disconnect();clean(w,a)
 end)
 test(pre.."qualified no effects are counted only after settle, never used to train dwell",function()
  local w,a,p,b=setup(deferred,30,nil);assert(a.StartPaintCooldownBenchmark({SamplesPerInterval=30}));w.step(.12)
  assert(b.rows[1].ValidNoEffect==0 and b.rows[1].Attempts>0)
  w.step(7);local row=b.rows[1];assert(row.Status=="COMPLETE" and row.ValidNoEffect==30 and row.Successes==0)
  assert(a.GetPerformanceStats().GlobalDwellMs==120 and a.GetPerformanceStats().Strategies.PER_TARGET.Attempts==0)
  a.CancelPaintCooldownBenchmark();w.step(.2);clean(w,a)
 end)
 test(pre.."wrong color and no clean targets create visible waiting not artificial paint work",function()
  local w,a,p,b=setup(deferred,29,.1);assert(a.StartPaintCooldownBenchmark());w.step(.4)
  assert(b.state=="WAITING FOR DIRTY" and b.detail:find("11 more",1,true) and next(w.downs)==nil)
  a.CancelPaintCooldownBenchmark();w.step(.2);assert(not b.active and b.state=="CANCELLED BY USER");clean(w,a)
 end)
 test(pre.."40 and 50 samples allowed but out of range denied",function()
  local w,a,p,b=setup(deferred,1,nil)
  assert(not a.StartPaintCooldownBenchmark({SamplesPerInterval=29}));assert(not a.StartPaintCooldownBenchmark({SamplesPerInterval=51}))
  assert(a.StartPaintCooldownBenchmark({SamplesPerInterval=50}));w.step(.2);assert(b.samples==50)
  assert(not a.StartPaintCooldownBenchmark());a.CancelPaintCooldownBenchmark();w.step(.2);clean(w,a)
 end)
 test(pre.."explicit cancel restores Civil mode and assignments paused without parallel workers",function()
  local w,a,p,b=setup(deferred,30,.04);w.makePalette(40);w.learn(a);a.RerollCivilColors(23);a.SetMode("CIVIL WAR")
  w.start(a,.4);assert(a.GetStats().Running);local saved=a.GetTargetStats(p[1]).AssignedCivilColorKey
  assert(a.StartPaintCooldownBenchmark({SamplesPerInterval=30}));w.step(.3)
  assert(b.active and a.GetStats().Mode=="NORMAL");assert(not a.SetMode("CIVIL WAR"))
  a.CancelPaintCooldownBenchmark();w.step(.4)
  assert(not b.active and a.GetStats().Mode=="CIVIL WAR" and not a.GetStats().Running)
  assert(a.GetTargetStats(p[1]).AssignedCivilColorKey==saved and b.restoreStatus:find("Previous mode restored; paused",1,true))
  clean(w,a)
 end)
 for _,event in ipairs({"FOCUS","TOOL","STOP","CLOSE","COLOR"}) do
  test(pre..event.." releases isolated input and preserves evidence until resume/cancel",function()
   local w,a,p,b=setup(deferred,35,.24);w.start(a,.05)
   assert(a.StartPaintCooldownBenchmark({SamplesPerInterval=30}));w.step(.12)
   if event=="FOCUS" then w.input.WindowFocusReleased:Fire()
   elseif event=="TOOL" then w.bucket.Parent=w.backpack
   elseif event=="STOP" then a.Stop()
   elseif event=="COLOR" then w.player:SetAttribute("PaintBucketColor",w.Color3.new(0,1,0))
   else a.Destroy() end
   w.flush();w.step(.5);assert(not w.button)
   if event=="CLOSE" then assert(not b.active) else assert(b.active and b.paused and not a.GetStats().Running) end
   if event=="FOCUS" then w.input.WindowFocused:Fire();w.flush();w.step(1);assert(b.active and not b.paused) end
   clean(w,a)
  end)
 end
 test(pre.."re-equipping the same bucket rebinds the isolated input session without discarding rows",function()
  local w,a,p,b=setup(deferred,35,.24);assert(a.StartPaintCooldownBenchmark({SamplesPerInterval=30}));w.step(.12)
  w.bucket.Equipped:Fire(w.toolMouse);w.flush();w.step(.8)
  assert(b.active and b.segment>1 and #b.rows[1].Records>0)
  clean(w,a)
 end)
 test(pre.."copy never starts benchmark and reports actual timing for every interval",function()
  local w,a,p,b=setup(deferred,30,.24)
  local report=a.GetPaintCooldownBenchmarkReport();assert(report:find("Not started",1,true) and next(w.downs)==nil)
  assert(a.StartPaintCooldownBenchmark({SamplesPerInterval=30}));w.step(.7)
  a.CancelPaintCooldownBenchmark();w.step(.2);report=a.GetPaintCooldownBenchmarkReport()
  assert(report:find("PER%-ATTEMPT") and report:find("Actual DOWN%-DOWN"))
  assert(#b.rows==13 and b.rows[13].IntervalMs==50 and b.rows[13].Status=="NOT_RUN");clean(w,a)
 end)
 test(pre.."real diagnostic button path starts cancels and copy never schedules input",function()
  local w,a,p,b=setup(deferred,40,.24)
  local copy=w.findText("Copy Cooldown Benchmark");assert(copy);copy.Activated:Fire();w.flush();assert(not b.active and next(w.downs)==nil)
  b.button.Activated:Fire();w.flush();w.step(.15);assert(b.active and b.samples==40 and b.cancelButton.Visible)
  b.cancelButton.Activated:Fire();w.flush();w.step(.2);assert(not b.active and b.state=="CANCELLED BY USER")
  clean(w,a)
 end)
 test(pre.."input API failures pause after bounded unqualified samples without retry spam",function()
  local w,a,p,b=setup(deferred,30,nil);w.responses["VirtualInput.SendMouseButton"].throw=true
  assert(a.StartPaintCooldownBenchmark({SamplesPerInterval=30}));w.step(2)
  assert(b.active and b.paused and b.manual and b.rows[1].Successes==0 and b.rows[1].ValidNoEffect==0)
  assert(not w.button and (w.downs["VirtualInput.SendMouseButton"] or 0)<=3);local n=#w.activationEvents;w.step(2);assert(#w.activationEvents==n);clean(w,a)
 end)
 test(pre.."timing reports native observed DOWN separately from delayed API dispatch",function()
  local w,a,p,b=setup(deferred,30,.24);w.responses["VirtualInput.SendMouseButton"].delay=.03
  assert(a.StartPaintCooldownBenchmark({SamplesPerInterval=30}));w.step(1)
  a.CancelPaintCooldownBenchmark();w.step(.2);local row=b.rows[1];assert(#row.Spacings>=2)
  for _,r in ipairs(row.Records) do if r.DownObservedAt then assert(r.DownObservedAt-r.DownAt>=.029) end end
  for _,ms in ipairs(row.Spacings) do assert(ms>=200) end
  assert(a.GetPaintCooldownBenchmarkReport():find("NativeDownObservedAt=",1,true));clean(w,a)
 end)
 test(pre.."slow release widens actual spacing instead of unsafe catch-up DOWN",function()
  local w,a,p,b=setup(deferred,30,.24);w.responses["VirtualInput.SendMouseButton"].upDelay=.22
  assert(a.StartPaintCooldownBenchmark({SamplesPerInterval=30}));w.step(1.5)
  a.CancelPaintCooldownBenchmark();w.step(.4);local row=b.rows[1]
  assert(#row.Spacings>=2);for _,ms in ipairs(row.Spacings) do assert(ms>=220) end
  assert(not w.button and a.GetPerformanceStats().ReleaseTimeouts==0);clean(w,a)
 end)
end
assert(failed==0,tostring(failed).." cooldown benchmark tests failed")
print(tostring(passed).." cooldown benchmark tests passed (deterministic; live cadence unverified)")
