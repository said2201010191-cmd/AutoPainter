-- V2 production defaults (unmodified source). Native lifecycle comes from the
-- inspected client reader, mocked in MasterFixture; this is not Roblox live proof.
local Fixture=require("./MasterFixture")
local NativeColors=require("./native_palette_128")
local passed,failed=0,0
SOURCE=SOURCE:gsub("local api = {",[[local api = {
 __rgb={palette=palette,entry=function(p) return lookup[p] end},
 __v2={v=v82,health=health,policy=policy,cfg=CFG,entry=function(p) return lookup[p] end,visible=visiblePoint},]],1)
local function test(n,fn) local ok,why=pcall(fn);if ok then passed+=1;print("PASS V2 "..n) else failed+=1;print("FAIL V2 "..n..": "..tostring(why)) end end
local function setup(d,n) return Fixture.setup(SOURCE,d,n) end
local function clean(w,a) Fixture.clean(w,a) end
local function native128(w,pal)
 pal.byKey={}
 for i,item in ipairs(pal.controls) do local c=NativeColors[i];item.color=w.Color3.fromRGB(c[1],c[2],c[3]);item.key=string.format("%02X%02X%02X",c[1],c[2],c[3]);pal.byKey[item.key]=item end
end
for _,deferred in ipairs({false,true}) do
 local pre=deferred and "deferred " or "immediate "
 test(pre.."default production B preserves target RGB, 150ms floor, 120ms healthy dwell and zero RPC",function()
  local w,a,p=setup(deferred,20);local expected=w.player:GetAttribute("PaintBucketColor");w.start(a,5)
  assert(a.GetNormalABState().Production=="B" and a.GetStats().Dirty==0,a.GetStats().LastMessage)
  assert(w.equipReads>=20 and a.GetPerformanceStats().GlobalDwellMs==120 and a.GetPerformanceStats().NormalRequestedDownSpacingMs==150)
  for _,part in ipairs(p) do assert(a.ColorsMatch(part.Color,expected)) end
  local last=nil;for _,e in ipairs(w.activationEvents) do if e.kind=="down" then if last then assert(e.at-last>=.15-1e-6) end;last=e.at end end
  assert(a.GetPerformanceStats().AutoPainterRPCs==0);clean(w,a)
 end)
 test(pre.."B refuses to paint when fresh native echoes are missing",function()
  local w,a=setup(deferred,2);w.failNativeReload=true;w.start(a,2)
  assert(not a.GetStats().Running and next(w.downs)==nil and a.GetStats().LastMessage:find("refresh failed",1,true));clean(w,a)
 end)
 test(pre.."B actual result required, native re-equip is not a correction",function()
  local w,a,p=setup(deferred,2);w.stalled={[p[1]]=true,[p[2]]=true};w.start(a,2)
  assert(w.equipReads>1 and a.GetPerformanceStats().SuccessfulPaints==0 and a.GetPerformanceStats().GlobalDwellMs==120);clean(w,a)
 end)
 test(pre.."native-only Civil is unchanged and does not inherit B cadence",function()
  local w,a,p=setup(deferred,20);a.SetMode("CIVIL WAR");a.RerollCivilColors(15);w.start(a,6)
  assert(a.GetStats().Dirty==0 and a.GetPerformanceStats().PaletteSelectionFailures==0)
  assert((w.equipReads or 0)<=1 and a.GetPerformanceStats().NormalActualDownSpacingMeanMs==0);clean(w,a)
 end)
 test(pre.."one bad target cannot monopolize nineteen healthy targets",function()
  local w,a,p=setup(deferred,20);w.cannotAcquire[p[1]]=true;w.start(a,6)
  for i=2,20 do assert(a.ColorsMatch(p[i].Color,w.player:GetAttribute("PaintBucketColor"))) end
  local m=a.GetPerformanceStats();assert(m.TargetLossStorms==0 and m.GlobalDwellMs==120)
  assert(a.__v2.entry(p[1]).ConsecutiveFailures<20);clean(w,a)
 end)
 test(pre.."cross-entry loss stops DOWNs, refreshes once, then real probes permit recovery",function()
  local w,a,p=setup(deferred,20);for _,part in ipairs(p) do w.cannotAcquire[part]=true end
  w.start(a,5);local h=a.__v2.v.targetHealth;local m=a.GetPerformanceStats()
  assert(h.active and m.TargetLossStorms>=1 and m.GlobalTargetCacheInvalidations==20 and next(w.downs)==nil,h.status)
  assert(m.TargetQuarantines<20 and m.GlobalDwellMs==120)
  w.cannotAcquire={};w.step(6)
  assert(not h.active and a.GetStats().Dirty==0 and a.GetPerformanceStats().GlobalTargetRecoverySuccesses>=1,h.status.." dirty "..a.GetStats().Dirty)
  assert(a.GetPerformanceStats().CameraMovesApplied==0);clean(w,a)
 end)
 test(pre.."persistent cross-entry loss never creates repeated per-entry quarantines or input",function()
  local w,a,p=setup(deferred,30);for _,part in ipairs(p) do w.cannotAcquire[part]=true end
  w.start(a,20);local m=a.GetPerformanceStats()
  assert(m.TargetLossStormActive and m.TargetLossStorms==1 and m.TargetQuarantines<10 and next(w.downs)==nil)
  assert(#a.__v2.v.targetHealth.events<=40 and #a.__v2.v.targetHealth.window<=24);clean(w,a)
 end)
 test(pre.."mixed broken and healthy cohort passes independent probes and continues healthy services",function()
  local w,a,p=setup(deferred,20);for i=1,4 do w.cannotAcquire[p[i]]=true end;w.start(a,8)
  for i=5,20 do assert(a.ColorsMatch(p[i].Color,w.player:GetAttribute("PaintBucketColor")),"healthy entry "..i) end
  assert(a.GetPerformanceStats().GlobalDwellMs==120);clean(w,a)
 end)
 test(pre.."offscreen is a visibility defer, no palette/paint or health poisoning",function()
  local w,a,p=setup(deferred,2);p[1].CFrame=w.cf(w.v(2000,0,2000));p[1].Position=w.v(2000,0,2000);w.start(a,3)
  local e=a.__v2.entry(p[1]);assert(e.ConsecutiveFailures==0 and e.visibilityClass=="OFFSCREEN")
  assert(a.ColorsMatch(p[2].Color,w.player:GetAttribute("PaintBucketColor")) and a.GetPerformanceStats().OffscreenDeferredCount>0)
  p[1].CFrame=w.cf(w.v(-120,0,-140));p[1].Position=w.v(-120,0,-140);w.step(1);assert(a.ColorsMatch(p[1].Color,w.player:GetAttribute("PaintBucketColor")));clean(w,a)
 end)
 test(pre.."projection budget is not TARGET_LOST and cannot increase dwell",function()
  local w,a,p=setup(deferred,1);w.stalled={[p[1]]=true};w.start(a,.2)
  local e=a.__v2.entry(p[1]);local h=a.__v2.v.targetHealth;local before=e.ConsecutiveFailures
  local handled=h.finish({entry=e,result="PROJECTION_BUDGET",episode=e.dirtyEpisode})
  assert(handled and e.ConsecutiveFailures==before and a.GetPerformanceStats().ProjectionBudgetDeferrals==1 and a.GetPerformanceStats().GlobalDwellMs==120);clean(w,a)
 end)
 test(pre.."classification records genuine target ancestry geometry viewport and GUI evidence",function()
  local w,a,p=setup(deferred,1);local h=a.__v2.v.targetHealth;local r=h.inspect(a.__v2.entry(p[1]),"BEFORE_DOWN")
  assert(r.EntryId==1 and r.ExpectedPath:find("Provinces",1,true) and r.Alive and r.InViewport)
  assert(r.CameraGeneration and r.CameraCFrame and r.Viewport and r.ProvinceCFrame and r.ActualMouseTarget and r.PointSource)
  h.remember(r);assert(a.GetTargetHealthReport():find("BEFORE_DOWN",1,true));clean(w,a)
 end)
 test(pre.."STOP during recovery cannot send late probe paint or retain lock",function()
  local w,a,p=setup(deferred,8);for _,part in ipairs(p) do w.cannotAcquire[part]=true end;w.start(a,3);a.Stop();w.step(.3)
  local moves=w.cursorMoves;w.cannotAcquire={};w.step(1)
  assert(w.cursorMoves==moves and next(w.downs)==nil and a.GetPerformanceStats().ActiveTargetLock=="none");clean(w,a)
 end)
 test(pre.."Randomize UI stages distinct RGB with zero input and correct source",function()
  local w,a,p,pal=setup(deferred,3);native128(w,pal);local old=w.player:GetAttribute("PaintBucketColor")
  local ok,why=a.RandomizeColor(135094411);assert(ok,tostring(why));local r=a.__v2.v.randomColor
  for _,item in ipairs(pal.controls) do assert(not a.ColorsMatch(item.color,r.color)) end
  assert(r.active and r.pending and next(w.downs)==nil and a.ColorsMatch(old,w.player:GetAttribute("PaintBucketColor")))
  assert(a.GetPerformanceStats().RandomColorExactProvinceResults==0 and a.GetPerformanceStats().RandomColorSource=="RANDOM_GENERATED")
  local first=r.color;assert(a.RandomizeColor(135094411));assert(not a.ColorsMatch(first,r.color));clean(w,a)
 end)
 test(pre.."Random NORMAL uses real native Equip reader then exact native-input province result",function()
  local w,a,p,pal=setup(deferred,6);native128(w,pal);assert(a.RandomizeColor(73));local r=a.__v2.v.randomColor;local target=r.color
  w.start(a,3);assert(a.GetStats().Dirty==0,a.GetStats().LastMessage)
  assert(r.active and not r.pending and r.prepared and r.exactResults==6,"results "..r.exactResults)
  for _,part in ipairs(p) do assert(a.ColorsMatch(part.Color,target)) end
  p[3].Color=w.Color3.fromRGB(0,0,0);w.step(.8);assert(a.ColorsMatch(p[3].Color,target) and r.color==target and r.exactResults==7)
  clean(w,a)
 end)
 test(pre.."random attribute/echo without province paint is never application proof",function()
  local w,a,p=setup(deferred,2);assert(a.RandomizeColor(73));w.stalled={[p[1]]=true,[p[2]]=true};w.start(a,1)
  assert(a.__v2.v.randomColor.prepared and a.GetPerformanceStats().RandomColorExactProvinceResults==0);clean(w,a)
 end)
 test(pre.."native swatch explicitly exits random source and preserves ordinary NORMAL color",function()
  local w,a,p=setup(deferred,2);assert(a.RandomizeColor(73));w.start(a,1);a.Stop();w.step(.2)
  w.humanSelect(w.uiButtons[4]);w.flush();assert(not a.__v2.v.randomColor.active)
  p[1].Color=w.Color3.fromRGB(0,0,0);w.start(a,1);assert(a.ColorsMatch(p[1].Color,w.uiButtons[4].swatch or w.player:GetAttribute("PaintBucketColor")));clean(w,a)
 end)
 test(pre.."random feature refuses running/Civil/benchmark ownership and short palette",function()
  local w,a,p=setup(deferred,2);a.SetMode("CIVIL WAR");assert(not a.RandomizeColor());a.SetMode("NORMAL")
  w.start(a,.2);assert(not a.RandomizeColor());a.Stop();w.step(.2)
  local pal=a.__rgb.palette;for i=#pal.controls,100,-1 do table.remove(pal.controls,i) end;assert(not a.RandomizeColor());clean(w,a)
 end)
 for _,n in ipairs({1,10,62,256,500,900}) do
  test(pre.."opaque geometry plus bounded real-part fallback "..n.." OFF ON",function()
   local w,a,p=setup(deferred,n);local m=a.GetVisualRendererStats();local con=w.connections
   assert(m.AttachedProxyProvinceCount==n and m.DirectFallbackCount==math.min(n,192) and m.HighlightInstanceCount<=232)
   assert(m.VisualizedProvinceCount==nil and m.RenderVisibilityProof:find("UNVERIFIED",1,true))
   for i,part in ipairs(p) do local e=a.__v2.entry(part);assert(e.proxy.Transparency==0 and e.proxy.CanQuery==false and e.proxy.CanCollide==false)
    if i<=192 then assert(e.directOutline.Adornee==part and e.directOutline.Enabled and e.directOutline.OutlineTransparency==0) end
   end
   a.SetProtectedFill(true);a.SetProtectedOutlines(false);assert(a.GetVisualRendererStats().HighlightInstanceCount==0)
   a.SetProtectedOutlines(true);assert(a.GetVisualRendererStats().AttachedProxyProvinceCount==n and w.connections==con)
   assert(a.__v2.entry(p[1]).directOutline.FillTransparency==.9 and next(w.downs)==nil);clean(w,a)
  end)
 end
 test(pre.."145 generated fixed-seed quality never regresses either old minimum",function()
  local w,a,p,pal=setup(deferred,273);native128(w,pal);a.SetMode("CIVIL WAR");assert(a.RerollCivilColors(135094411))
  local q=pal.perceptual.lastQuality;assert(q.Before.native<=q.After.native+1e-8 and q.Before.generated<=q.After.generated+1e-8)
  print(string.format("V2 QUALITY seed135094411 native128+generated145 before N %.6f G %.6f P10 %.6f P50 %.6f -> after N %.6f G %.6f P10 %.6f P50 %.6f time %.3f ms steps %d",q.Before.native,q.Before.generated,q.Before.p10,q.Before.p50,q.After.native,q.After.generated,q.After.p10,q.After.p50,q.GenerationMs,q.RefinementAccepted))
  local keys={};for i,part in ipairs(p) do local e=a.__v2.entry(part);assert(not keys[e.civilKey]);keys[e.civilKey]=true
   if i>128 then assert(e.civilControl.generated and e.civilControl.index==0 and e.civilControl.signature.Name:find("GEN #",1,true)) end
  end
  local first=a.__v2.entry(p[129]).civilKey;assert(a.RerollCivilColors(135094411));assert(a.__v2.entry(p[129]).civilKey==first)
  -- Keep the stress cohort on the exposed map; native GUI occlusion is tested separately.
  for i,part in ipairs(p) do part.CFrame=w.cf(w.v(-250+((i-1)%18)*26,0,-240+math.floor((i-1)/18)*15));part.Position=part.CFrame.Position;part.Size=w.v(20,1,12) end
  Fixture.nativeClean(w,a,p);w.start(a,50);assert(a.GetStats().Dirty==0 and a.GetPerformanceStats().GeneratedObservedProvinces==145,a.GetStats().LastMessage.." dirty="..a.GetStats().Dirty.." gen="..a.GetPerformanceStats().GeneratedObservedProvinces.."\n"..a.GetTargetHealthReport())
  clean(w,a)
 end)
end
for _,deferred in ipairs({false,true}) do
 local pre=deferred and "deferred " or "immediate "
 test(pre.."real Randomize button and R stage RGB, no paint or attribute write",function()
  local w,a,p=setup(deferred,2);local button
  for _,o in ipairs(w.playerGui:GetDescendants()) do if o:IsA("TextButton") and o.Text=="Randomize Color" then button=o end end
  assert(button);button.Activated:Fire();w.flush();local r=a.__v2.v.randomColor;assert(r.active and r.generation==1)
  local first=r.color;w.input.InputBegan:Fire({KeyCode=w.env.Enum.KeyCode.R},false);w.flush()
  assert(r.generation==2 and not a.ColorsMatch(first,r.color) and next(w.downs)==nil)
  assert(not a.SetNormalProductionPath("A"));clean(w,a)
 end)
 test(pre.."random focus loss before staged write aborts without claiming application",function()
  local w,a=setup(deferred,2);assert(a.RandomizeColor(7));local before=w.player:GetAttribute("PaintBucketColor")
  w.afterUnequip=function() w.input.WindowFocusReleased:Fire() end;w.start(a,1)
  assert(a.ColorsMatch(before,w.player:GetAttribute("PaintBucketColor")) and next(w.downs)==nil and a.GetPerformanceStats().RandomColorExactProvinceResults==0);clean(w,a)
 end)
 test(pre.."noncloneable real part still has fallback and cleanup does not destroy another fallback",function()
  local w,a,p=setup(deferred,1);local other=w.province(0,0);other.Archivable=false;a.AddProvince(other)
  local e=a.__v2.entry(other);assert(e.directOutline and e.directOutline.Adornee==other)
  a.RemoveProvince(p[1]);assert(e.directOutline.Parent and a.GetStats().Selected==1)
  a.Clear();assert(a.GetVisualRendererStats().HighlightInstanceCount==0);clean(w,a)
 end)
 test(pre.."GUI-blocked targets defer without paint until legitimate GUI closes",function()
  local w,a,p=setup(deferred,2);local blocker=w.instance("TextButton");blocker.Visible=true;blocker.Active=true;blocker.Parent=w.playerGui;w.blockedGUI=blocker
  w.start(a,2);assert(next(w.downs)==nil and a.__v2.entry(p[1]).visibilityClass=="GUI_OBSCURED")
  w.blockedGUI=nil;blocker:Destroy();w.step(1);assert(a.GetStats().Dirty==0);clean(w,a)
 end)
 test(pre.."Civil cross-entry collapse recovers with native assignments and bindings unchanged",function()
  local w,a,p=setup(deferred,20);a.SetMode("CIVIL WAR");a.RerollCivilColors(27);local keys={}
  for i,part in ipairs(p) do keys[i]=a.__v2.entry(part).civilKey;w.cannotAcquire[part]=true end
  w.start(a,5);assert(a.GetPerformanceStats().TargetLossStormActive and w.paletteClicks>0,a.GetTargetHealthReport()) -- palette input is allowed; paint is still absent
  assert(a.GetPerformanceStats().SuccessfulPaints==0)
  w.cannotAcquire={};w.step(8);assert(a.GetStats().Dirty==0 and a.GetPerformanceStats().BoundNativeColors==128)
  for i,part in ipairs(p) do assert(a.__v2.entry(part).civilKey==keys[i]) end
  clean(w,a)
 end)
 test(pre.."recovery evidence drops removed entry references",function()
  local w,a,p=setup(deferred,2);local h=a.__v2.v.targetHealth;local e=a.__v2.entry(p[1]);h.isolated[e.id]=1;h.proofs={[e.id]=1}
  a.RemoveProvince(p[1]);assert(h.isolated[e.id]==nil and h.proofs[e.id]==nil);clean(w,a)
 end)
end
if failed>0 then error(failed.." V2 tests failed") end
print(passed.." V2 tests passed (deterministic only; rendering/combat/random RGB require live confirmation)")
