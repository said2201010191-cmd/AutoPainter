local Mock=require("./V82Mock")
local passed,failed=0,0
SOURCE=SOURCE:gsub("local api = {",[[local api = {
 __test={v=v82,p=palette,h=health,policy=policy,cfg=CFG,pacing=pacing,entry=function(part) return lookup[part] end,
 dirty=dirty,metrics=metrics,sync=syncDirty,choose=chooseFast,beginSelection=beginSelection,finishSelection=finishSelection},]],1)
local function test(name,fn) local ok,why=pcall(fn);if ok then passed+=1;print("PASS "..name) else failed+=1;print("FAIL "..name..": "..tostring(why)) end end
local function setup(deferred,n,colors)
 local w=Mock.new(deferred);local a=w.load(SOURCE);local t=a.__test;local parts={};w.protected={}
 if colors then w.makePalette(colors);w.learn(a) end
 for i=1,n or 0 do local p=w.province(-250+(i-1)%16*35,-170+math.floor((i-1)/16)*35);a.AddProvince(p);parts[i]=p;w.protected[p]=true end
 if colors and n and n>0 then a.RerollCivilColors(2030) end
 w.mouse.Target=nil;return w,a,parts,t
end
local function clean(w,a) a.Stop();w.step(.15);a.Destroy();w.flush();w.assertClean() end
local function wrong(w,p,i) p.Color=w.Color3.fromRGB(12+((i or 0)*7)%150,25,180);w.flush() end
local function poison(w,t,e)
 e.ExtraDwell=.1;e.retryAt=w.now+4;e.ConsecutiveFailures=8;e.ConsecutiveValidNoEffects=8;e.quarantineLevel=4;e.deferKind="GROUP";e.groupId="old"
 t.v.groups.old={ids={[e.id]=true},level=4,untilAt=w.now+4};t.v.groupCount=1
end
for _,deferred in ipairs({false,true}) do
 local pre=(deferred and "deferred " or "immediate ").."combat "
 test(pre.."fresh attack erases stale entry group dwell and becomes eligible immediately",function()
  local w,a,p,t=setup(deferred,3);local e=t.entry(p[1]);p[1].Color=w.color;w.flush();poison(w,t,e);wrong(w,p[1])
  assert(e.retryAt<=w.now and e.ExtraDwell==0 and e.ConsecutiveFailures==0 and e.groupId==nil)
  assert(e.queueOrigin=="FRESH_ATTACK" and e.freshLinked and t.v.groups.old==nil)
  assert(t.v.combat.FreshPenaltyResets==1 and t.v.combat.FreshGroupClears==1);clean(w,a)
 end)
 test(pre.."wrong to wrong churn coalesces without new fresh episode or deadline resets",function()
  local w,a,p,t=setup(deferred,1);local e=t.entry(p[1]);e.retryAt=w.now+1;local episode=e.dirtyEpisode
  for i=1,30 do wrong(w,p[1],i) end
  assert(#t.dirty==1 and e.dirtyEpisode==episode and e.retryAt==1 and not e.freshLinked)
  assert(t.v.combat.CoalescedCombatChanges==30);clean(w,a)
 end)
 test(pre.."new wrong color activity prevents NORMAL pathological group quarantine",function()
  local w,a,p,t=setup(deferred,3);a.SetActivationStrategy("PER_TARGET");w.nativeRepeat=false
  for i=1,80 do w.schedule(i*.05,function() for j,part in ipairs(p) do wrong(w,part,i+j) end end) end
  w.start(a,3);local m=a.GetPerformanceStats()
  assert(m.ActiveCombatMisses>3 and m.PathologicalGroupsDetected==0 and m.GlobalDwellMs==120)
  for _,r in ipairs(a.GetServiceRecords()) do if r.Result=="VALID_NO_EFFECT" then assert(r.EffectivePaintWindowMs==120) end end
  clean(w,a)
 end)
 test(pre.."unchanging stale failures still form bounded backoff groups",function()
  local w,a,p,t=setup(deferred,5);a.SetActivationStrategy("PER_TARGET");w.stalled={[p[1]]=true,[p[2]]=true,[p[3]]=true};w.start(a,8)
  local m=a.GetPerformanceStats();assert(m.PathologicalGroupsDetected>0 and m.GroupCooldowns>0 and m.GlobalDwellMs==120)
  assert(a.ColorsMatch(p[4].Color,w.color) and a.ColorsMatch(p[5].Color,w.color))
  assert(t.entry(p[1]).ExtraDwell==0);clean(w,a)
 end)
 test(pre.."fresh priority wins retries but hard eligible aging protects older work",function()
  local w,a,p,t=setup(deferred,3);a.SetActivationStrategy("PER_TARGET");t.v.overload=true;t.v.loadAt=100
  p[2].Color=w.color;w.flush();wrong(w,p[2]);t.v.lookahead={entry=t.entry(p[3]),at=w.now};local picked=t.choose(w.now);assert(picked.entry==t.entry(p[2]))
  t.entry(p[1]).eligibleMs=2000;picked=t.choose(w.now);assert(picked.entry==t.entry(p[1]));clean(w,a)
 end)
 test(pre.."new attack during release keeps its own episode timestamps and origin",function()
  local w,a,p,t=setup(deferred,1);a.SetActivationStrategy("PER_TARGET");w.responses["VirtualInput.SendMouseButton"].upDelay=.05
  w.start(a,.05);local before=t.entry(p[1]).dirtyEpisode
  -- Wait until native correction, then inject a new attack before the paired UP ends.
  w.schedule(.01,function() if a.ColorsMatch(p[1].Color,w.color) then wrong(w,p[1]) end end)
  w.step(.07);local e=t.entry(p[1]);assert(e.dirtyEpisode>before)
  assert(e.episodeOrigin=="FRESH_ATTACK" and e.externalEventAt~=nil);w.step(.5);clean(w,a)
 end)
 test(pre.."explicit experimental ADAPTIVE samples continuous and requires held multi-target correction proof",function()
  local w,a,p,t=setup(deferred,20);assert(t.cfg.ActivationStrategy=="PER_TARGET");assert(a.SetActivationStrategy("ADAPTIVE"));w.responses["VirtualInput.SendMouseButton"].upDelay=.02;w.start(a,3)
  local m=a.GetPerformanceStats()
  assert(m.Strategies.CONTINUOUS.Attempts>=4 and m.NativeHoldMultiTargetProof and m.NativeHoldTransferredSuccesses>=2,a.GetPerformanceReport())
  assert(m.NativeHoldExperimentState=="CONFIRMED" and m.DirtyCount==0)
  assert((w.downs["VirtualInput.SendMouseButton"] or 0)<#p and not w.button and m.ReleaseTimeouts==0)
  assert(w.violations==0 and w.networkAttempts==0);clean(w,a)
 end)
 test(pre.."one-click-only native tool fails held transfers and safely caches PER_TARGET",function()
  local w,a,p,t=setup(deferred,12);a.SetActivationStrategy("ADAPTIVE");w.nativeRepeat=false;w.responses["VirtualInput.SendMouseButton"]={mouse=true,paint=true,paintDelay=.04};w.start(a,4)
  local m=a.GetPerformanceStats();assert(m.NativeHoldExperimentState=="FALLBACK" and m.Strategies.CONTINUOUS.Attempts>=2)
  assert(m.NativeHoldTransferredSuccesses==0 and m.ActivationStrategy=="PER_TARGET" and m.DirtyCount==0)
  assert(not w.button and m.ReleaseTimeouts==0 and w.networkAttempts==0);clean(w,a)
 end)
 test(pre.."continuous without a measured advantage falls back and exposes the actual chosen strategy",function()
  local w,a,p,t=setup(deferred,25);t.cfg.NormalDownSpacingDefault=0;t.pacing.interval=0 -- Isolate experimental throughput comparison from the conservative production cadence.
  a.SetActivationStrategy("CONTINUOUS");local slowHold=w.runService.Heartbeat:Connect(function() w.nativeInterval=t.policy.trial.State=="PROBING" and .14 or .04 end);w.start(a,6)
  local m=a.GetPerformanceStats();assert(m.NativeHoldMultiTargetProof and m.NativeHoldProbeAttempts==8,a.GetPerformanceReport())
  assert(m.NativeHoldExperimentState=="FALLBACK" and m.ActivationStrategy=="PER_TARGET" and m.ActivationStrategySetting=="CONTINUOUS",a.GetPerformanceReport())
  assert(m.DirtyCount==0 and not w.button,a.GetPerformanceReport());slowHold:Disconnect();clean(w,a)
 end)
 test(pre.."hold experiment evidence is bounded and winning decision survives STOP in same tool session",function()
  local w,a,p,t=setup(deferred,35);a.SetActivationStrategy("ADAPTIVE");w.responses["VirtualInput.SendMouseButton"].upDelay=.02;w.start(a,3)
  local m=a.GetPerformanceStats();assert(m.NativeHoldExperimentState=="CONFIRMED" and m.NativeHoldProbeAttempts<=8)
  assert(m.NativeHoldObservedAttempts>m.NativeHoldProbeAttempts)
  local holds=0;for _ in pairs(t.policy.trial.HoldIds) do holds+=1 end;assert(holds<=8)
  a.Stop();w.step(.15);for i,part in ipairs(p) do wrong(w,part,i) end
  w.start(a,2);assert(t.policy.trial.State=="CONFIRMED" and a.GetPerformanceStats().NativeHoldProbeAttempts==m.NativeHoldProbeAttempts)
  clean(w,a)
 end)
 test(pre.."no successful baseline cannot unlock an assumed continuous winner",function()
  local w,a,p,t=setup(deferred,12);a.SetActivationStrategy("ADAPTIVE");w.nativeRepeat=false;w.start(a,2)
  assert(a.GetPerformanceStats().Strategies.CONTINUOUS.Attempts==0 and not t.policy.trial.RetainedProof);clean(w,a)
 end)
 test(pre.."insufficient simultaneous dirty targets never force continuous",function()
  local w,a,p,t=setup(deferred,1);a.SetActivationStrategy("ADAPTIVE")
  for i=1,8 do wrong(w,p[1],i);w.start(a,.2) end
  local m=a.GetPerformanceStats();assert(m.Strategies.CONTINUOUS.Attempts==0 and m.ActivationStrategy=="PER_TARGET");clean(w,a)
 end)
 test(pre.."confirmed continuous reliability drop automatically releases and falls back",function()
  local w,a,p,t=setup(deferred,20);a.SetActivationStrategy("ADAPTIVE");w.responses["VirtualInput.SendMouseButton"].upDelay=.02;w.start(a,2);assert(t.policy.trial.State=="CONFIRMED")
  w.stalled={};for i,part in ipairs(p) do w.stalled[part]=true;wrong(w,part,i) end
  w.step(1);assert(t.policy.trial.State=="FALLBACK" and t.policy.choice=="PER_TARGET")
  clean(w,a)
 end)
 for _,event in ipairs({"STOP","FOCUS","TOOL","MODE"}) do
  test(pre..event.." during held transfer resolves input before any next transaction",function()
   local w,a,p,t=setup(deferred,35);a.SetActivationStrategy("ADAPTIVE");w.start(a,1.3)
   -- Wait for the real controlled probe rather than forcing a fake held state.
   for _=1,50 do if a.GetStats().Held and t.policy.choice=="CONTINUOUS" then break end;w.step(.01) end
   assert(a.GetStats().Held and t.policy.choice=="CONTINUOUS")
   if event=="STOP" then a.Stop()
   elseif event=="FOCUS" then w.input.WindowFocusReleased:Fire()
   elseif event=="TOOL" then w.bucket.Parent=w.backpack
   else a.SetMode("CIVIL WAR") end
   w.flush();w.step(.12);assert(not w.button and not a.GetStats().Held)
   a.Stop();w.step(.1);assert(w.networkAttempts==0);clean(w,a)
  end)
 end
 test(pre.."duplicate input states recover without extra overlapping DOWN or stuck UP",function()
  local w,a,p,t=setup(deferred,16);w.duplicateDown=1;w.duplicateUp=1;w.start(a,4)
  local m=a.GetPerformanceStats();assert(m.DuplicateDownStates==1 and m.DuplicateUpStates==1 and m.SuccessfulInputResyncs>=1)
  assert(m.DirtyCount==0 and not w.button and m.ReleaseTimeouts==0);clean(w,a)
 end)
 test(pre.."unprotected real target cannot retain automatic hold",function()
  local w,a,p,t=setup(deferred,30);w.start(a,.5);local outsider=w.province(250,150)
  w.mouse.Target=outsider;w.mouse.Move:Fire();w.flush();w.step(.02);assert(not w.button or w.mouse.Target~=outsider)
  assert(w.violations==0);clean(w,a)
 end)
 test(pre.."timing chain distinguishes local event eligible pick acquire down and correction",function()
  local w,a,p,t=setup(deferred,2);a.SetActivationStrategy("PER_TARGET");w.start(a,.5);wrong(w,p[1]);w.step(.3)
  local records=a.GetServiceRecords();local r=records[#records]
  assert(r.Result=="SUCCESS" and r.ExternalColorEventAt and r.EligibleAt and r.SchedulerPickedAt and r.TargetAcquiredAt and r.NativeDownObservedAt and r.CorrectionObservedAt)
  assert(r.ExternalColorEventAt<=r.EligibleAt and r.EligibleAt<=r.SchedulerPickedAt and r.SchedulerPickedAt<=r.TargetAcquiredAt and r.NativeDownObservedAt<=r.CorrectionObservedAt)
  assert(r.EligibleQueueWaitMs<100 and r.DeferredCooldownAgeMs==0);clean(w,a)
 end)
 test(pre.."NORMAL misses overload and acquisition failures never poison shared successful dwell",function()
  local w,a,p,t=setup(deferred,20);a.SetActivationStrategy("PER_TARGET");for i=1,4 do w.cannotAcquire[p[i]]=true end
  for i=5,7 do w.stalled=w.stalled or {};w.stalled[p[i]]=true end
  w.start(a,6);assert(a.GetPerformanceStats().GlobalDwellMs==120)
  for i=8,20 do assert(a.ColorsMatch(p[i].Color,w.color)) end
  for _,r in ipairs(a.GetServiceRecords()) do assert(r.GlobalDwellAfter==120 and r.EffectivePaintWindowMs==120) end;clean(w,a)
 end)
 test(pre.."locked camera remains untouched through both activation strategies and failures",function()
  local w,a,p,t=setup(deferred,20);local first=#w.writeLog+1;w.start(a,2)
  w.cannotAcquire[p[1]]=true;wrong(w,p[1]);w.step(1);a.Stop();w.step(.1)
  for i=first,#w.writeLog do local r=w.writeLog[i];assert(r.object~=w.workspace.CurrentCamera or not table.find({"CFrame","Focus","CameraType","CameraSubject"},r.key)) end
  clean(w,a)
 end)
 test(pre.."Civil keeps per-target input zero redundant palette clicks and stable assignments",function()
  local w,a,p,t=setup(deferred,12,128);a.SetMode("CIVIL WAR");w.start(a,4);assert(a.GetStats().Dirty==0)
  local assigned={};for i,part in ipairs(p) do assigned[i]=t.entry(part).civilColor end
  a.Stop();w.step(.15);local clicks=w.paletteClicks;w.paletteRoot:Destroy();w.flush();w.recreatePalette(128);w.flush()
  assert(a.GetPerformanceStats().BoundNativeColors==128)
  for i,part in ipairs(p) do assert(a.ColorsMatch(assigned[i],t.entry(part).civilColor));wrong(w,part,i) end
  w.start(a,4);assert(a.GetStats().Dirty==0 and w.paletteClicks>clicks and t.policy.trial.Attempts==0)
  clean(w,a)
 end)
 test(pre.."dormant OG generator is deterministic unique native-excluding and never raises capacity",function()
  local w,a,p,t=setup(deferred,0,128);local before=#w.writeLog;local colors,why=a.GetDormantGeneratedColorPreview(40,2083);local again=a.GetDormantGeneratedColorPreview(40,2083)
  assert(colors and #colors==40 and why:find("DORMANT",1,true))
  for i,c in ipairs(colors) do assert(a.ColorsMatch(c,again[i]));for j=1,i-1 do assert(not a.ColorsMatch(c,colors[j])) end;for _,item in ipairs(t.p.controls) do assert(not a.ColorsMatch(c,item.color)) end end
  assert(#w.writeLog==before and a.GetPerformanceStats().GeneratedVerifiedCapacity==0 and next(w.downs)==nil)
  assert(not a.GetDormantGeneratedColorPreview(513,1));clean(w,a)
 end)
 test(pre.."expanded native UI inventory reaches alternate roots and hides non-color text",function()
  local w,a,p,t=setup(deferred,0);local root=w.instance("ScreenGui");root.Name="NativeSettings";root.Parent=w.playerGui
  local frame=w.instance("Frame");frame.Name="CustomTint";frame.Parent=root
  local rgb=w.instance("TextBox");rgb.Name="RGB";rgb.Text="12,34,56";rgb.Parent=frame
  local secret=w.instance("TextBox");secret.Name="ColorNote";secret.Text="private-note";secret.Parent=frame
  local before=#w.writeLog;local rows=a.InspectCustomColorUI();local found=false
  for _,r in ipairs(rows) do if r.object==rgb then found=true end;if r.object==secret then assert(r.Text=="<non-color text omitted>") end end
  assert(found and #w.writeLog==before and next(w.downs)==nil and a.GetCustomColorUIReport():find("REJECTED",1,true));clean(w,a)
 end)
 test(pre.."shape markers drag selection and duplicates remain native-input free",function()
  local w,a,p,t=setup(deferred,0);assert(t.beginSelection("ADD"));w.button=true;w.input.InputBegan:Fire({UserInputType=w.env.Enum.UserInputType.MouseButton1},false)
  for i=1,15 do local part=w.province(-200+i*20,0);w.mouse.Target=part;w.mouse.Move:Fire();w.flush();w.mouse.Move:Fire();w.flush() end
  w.button=false;w.input.InputEnded:Fire({UserInputType=w.env.Enum.UserInputType.MouseButton1},false);w.flush();t.finishSelection()
  assert(a.GetStats().Selected==15 and next(w.downs)==nil)
  for _,e in ipairs(t.dirty) do assert(e.box.ClassName=="Highlight" and e.box.Adornee==e.proxy.Parent and e.proxy.CFrame==e.part.CFrame) end
  clean(w,a)
 end)
end
assert(failed==0,tostring(failed).." combat tests failed")
print(tostring(passed).." combat regression tests passed (deterministic; not live Roblox proof)")
