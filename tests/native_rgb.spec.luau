-- Emulate only the newly observed native Equipped reader. Not live application proof.
local Mock=require("./V82Mock")
local passed,failed=0,0
SOURCE=SOURCE:gsub("local api = {",[[local api = {
 __rgb={palette=palette,entry=function(p) return lookup[p] end},]],1)
local function test(name,fn) local ok,why=pcall(fn);if ok then passed+=1;print("PASS "..name) else failed+=1;print("FAIL "..name..": "..tostring(why)) end end
local function setup(deferred,count)
 local w=Mock.new(deferred);local a=w.load(SOURCE);w.makePalette(128);w.learn(a)
 local parts={};w.protected={}
 for i=1,count do local p=w.province(-250+((i-1)%18)*26,-240+math.floor((i-1)/18)*24);p.Size=w.v(20,1,20);parts[i]=p;w.protected[p]=true;a.AddProvince(p) end
 local box=w.instance("SelectionBox");box.Name="PaintBucketSelectionBox";box.Color3=w.color;box.Parent=w.playerGui
 local line=w.instance("LineHandleAdornment");line.Name="PaintBucketLineHandle";line.Color3=w.color;line.Parent=w.playerGui
 rawset(w.bucket,"Unequipped",w.signal())
 local gui=nil
 w.nativeEquip=w.bucket.Equipped:Connect(function()
  w.equipReads=(w.equipReads or 0)+1
  if w.failNativeReload then return end
  local c=w.player:GetAttribute("PaintBucketColor")
  if w.rebuildNativePalette then w.recreatePalette(128) end
  w.nativePaletteColor=c;box.Color3=c;line.Color3=c
  if gui then gui:Destroy() end
  gui=w.instance("ScreenGui");gui.Name="PaletteGui";gui.Parent=w.playerGui
  local pallet=w.instance("Frame");pallet.Name="ColorPallet";pallet.Parent=gui
  local title=w.instance("TextLabel");title.Name="ColorTitle";title.Parent=pallet
  local picker=w.instance("ImageButton");picker.Name="ColorPicker";picker.BackgroundColor3=c;picker.Parent=title
  if w.generatedEquipHook then w.generatedEquipHook() end
 end)
 local unequip=w.humanoid.UnequipTools
 rawset(w.humanoid,"UnequipTools",function(self)
  if w.failUnequip then return end
  unequip(self);w.bucket.Unequipped:Fire()
  if w.afterUnequip then w.afterUnequip() end
 end)
 local equip=w.humanoid.EquipTool
 rawset(w.humanoid,"EquipTool",function(self,tool) if not w.failEquip then equip(self,tool) end end)
 return w,a,parts,a.__rgb.palette
end
local function clean(w,a)
 a.Stop();w.step(.2);a.Destroy();w.step(.2);w.nativeEquip:Disconnect();w.assertClean()
end
local function nativeClean(w,a,p)
 for i=1,math.min(128,#p) do p[i].Color=a.GetTargetStats(p[i]).TargetColor end;w.flush()
end
for _,deferred in ipairs({false,true}) do
 local pre=(deferred and "deferred " or "immediate ").."native RGB "
 test(pre.."182 allocations are 128 native plus 54 unique non-native RGB, stable on recolor and rebind",function()
  local w,a,p,pal=setup(deferred,182);a.SetMode("CIVIL WAR");assert(a.RerollCivilColors(182))
  local used,keys={},{}
  for i,part in ipairs(p) do local e=a.__rgb.entry(part);assert(not used[e.civilKey]);used[e.civilKey]=true;keys[i]=e.civilKey
   assert((e.civilControl.generated==true)==(i>128))
   if i>128 then for _,item in ipairs(pal.controls) do assert(not a.ColorsMatch(item.color,e.civilColor)) end end
  end
  for i=129,182 do p[i].Color=w.Color3.fromRGB(0,0,0) end;w.flush();w.recreatePalette(128);w.flush()
  assert(pal.assign(false));for i,part in ipairs(p) do assert(a.__rgb.entry(part).civilKey==keys[i]) end
  assert(a.GetPerformanceStats().GeneratedColorsAssigned==54 and a.GetPerformanceStats().GeneratedExactResults==0 and w.networkAttempts==0)
  assert(a.RerollCivilColors(183));assert(a.__rgb.entry(p[129]).civilKey~=keys[129]);clean(w,a)
 end)
 test(pre.."same seed reproduces generated assignments without painting",function()
  local w,a,p=setup(deferred,182);assert(a.RerollCivilColors(58));local keys={}
  for i=129,182 do keys[i]=a.__rgb.entry(p[i]).civilKey end
  assert(a.RerollCivilColors(58));for i=129,182 do assert(a.__rgb.entry(p[i]).civilKey==keys[i]) end
  assert(next(w.downs)==nil and w.networkAttempts==0);clean(w,a)
 end)
 test(pre.."129th province uses genuine equip reader then native DOWN result",function()
  local w,a,p=setup(deferred,129);a.SetMode("CIVIL WAR");assert(a.RerollCivilColors(9));nativeClean(w,a,p)
  local target=a.__rgb.entry(p[129]).civilColor
  w.start(a,2)
  assert(a.ColorsMatch(p[129].Color,target),a.GetStats().LastMessage.."\n"..a.GetGeneratedColorReport())
  assert(a.GetStats().Dirty==0 and a.GetStats().Running and w.networkAttempts==0)
  local m=a.GetPerformanceStats();assert(m.GeneratedPreparations==1 and m.GeneratedExactResults==1 and m.GeneratedObservedProvinces==1)
  assert(a.GetGeneratedColorReport():find("EXACT_GENERATED_RGB_OBSERVED",1,true));clean(w,a)
 end)
 test(pre.."all 54 generated entries complete with distinct stable colors in the mock",function()
  local w,a,p=setup(deferred,182);a.SetMode("CIVIL WAR");assert(a.RerollCivilColors(82));nativeClean(w,a,p)
  w.rebuildNativePalette=true;w.start(a,18)
  assert(a.GetStats().Dirty==0,a.GetStats().LastMessage.." dirty="..a.GetStats().Dirty)
  assert(a.GetPerformanceStats().GeneratedObservedProvinces==54 and a.GetPerformanceStats().GeneratedExactResults==54)
  assert(a.GetPerformanceStats().BoundNativeColors==128 and a.GetPerformanceStats().LearnedPaletteColors==128)
  local expected=a.__rgb.entry(p[144]).civilKey;p[144].Color=w.Color3.fromRGB(1,1,1);w.step(1)
  assert(a.GetStats().Dirty==0 and a.__rgb.entry(p[144]).civilKey==expected);assert(w.networkAttempts==0);clean(w,a)
 end)
 test(pre.."attribute alone cannot pass preparation when native working-color reader does not update",function()
  local w,a,p=setup(deferred,129);a.SetMode("CIVIL WAR");a.RerollCivilColors(4);nativeClean(w,a,p);w.failNativeReload=true
  w.start(a,1.1)
  local m=a.GetPerformanceStats();assert(m.GeneratedPreparationFailures>=1 and m.GeneratedExactResults==0)
  assert(next(w.downs)==nil and w.networkAttempts==0);w.step(3);assert(not a.GetStats().Running and a.GetPerformanceStats().GeneratedPreparationAttempts==1);clean(w,a)
 end)
 test(pre.."native echoes alone are not counted as application without province result",function()
  local w,a,p=setup(deferred,129);a.SetMode("CIVIL WAR");a.RerollCivilColors(4);nativeClean(w,a,p);w.stalled={[p[129]]=true}
  w.start(a,.8);assert(a.GetPerformanceStats().GeneratedPreparations>=1 and a.GetPerformanceStats().GeneratedExactResults==0)
  assert(a.GetPerformanceStats().GeneratedColorApplicationViaCurrentNativePath=="SOURCE_TRACED_NOT_LIVE_VERIFIED");clean(w,a)
 end)
 test(pre.."focus loss between unequip and state write sends no DOWN or color write",function()
  local w,a,p=setup(deferred,129);a.SetMode("CIVIL WAR");a.RerollCivilColors(4);nativeClean(w,a,p)
  local before=w.player:GetAttribute("PaintBucketColor")
  w.afterUnequip=function() w.input.WindowFocusReleased:Fire() end
  w.start(a,.8);assert(next(w.downs)==nil and a.ColorsMatch(before,w.player:GetAttribute("PaintBucketColor")))
  assert(a.__rgb.palette.generated.reload==nil);clean(w,a)
 end)
 test(pre.."STOP inside native equip prevents paint and relinquishes transaction",function()
  local w,a,p=setup(deferred,129);a.SetMode("CIVIL WAR");a.RerollCivilColors(4);nativeClean(w,a,p)
  local armed=false;w.afterUnequip=function() armed=true end
  w.generatedEquipHook=function() if armed then a.Stop() end end
  w.start(a,.9);assert(not a.GetStats().Running and next(w.downs)==nil and a.__rgb.palette.generated.reload==nil);clean(w,a)
 end)
 test(pre.."failed equip never loops native DOWN and has bounded preparation timeout",function()
  local w,a,p=setup(deferred,129);a.SetMode("CIVIL WAR");a.RerollCivilColors(4);nativeClean(w,a,p)
  w.humanoid:EquipTool(w.bucket);w.flush();w.afterUnequip=function() w.failEquip=true end
  w.start(a,1.5);assert(next(w.downs)==nil and a.GetPerformanceStats().GeneratedPreparationFailures>=1 and a.__rgb.palette.generated.reload==nil);clean(w,a)
 end)
 for _,action in ipairs({"REMOVE","CLEAR","MODE"}) do
  test(pre..action.." during generated preparation never sends stale input",function()
   local w,a,p=setup(deferred,129);a.SetMode("CIVIL WAR");a.RerollCivilColors(4);nativeClean(w,a,p)
   w.afterUnequip=function()
    if action=="REMOVE" then a.RemoveProvince(p[129]) elseif action=="CLEAR" then a.Clear() else a.SetMode("NORMAL") end
   end
   w.start(a,1);assert(next(w.downs)==nil and a.__rgb.palette.generated.reload==nil and w.networkAttempts==0);clean(w,a)
  end)
 end
 test(pre.."NORMAL and native-only Civil never invoke generated preparation",function()
  local w,a,p=setup(deferred,12);w.start(a,3);assert(a.GetStats().Dirty==0)
  a.Stop();w.step(.2);a.SetMode("CIVIL WAR");a.RerollCivilColors(7);w.start(a,5)
  assert(a.GetStats().Dirty==0 and a.GetPerformanceStats().GeneratedPreparationAttempts==0)
  assert(a.GetPerformanceStats().NormalRequestedDownSpacingMs==150 and w.networkAttempts==0);clean(w,a)
 end)
end
if failed>0 then error(tostring(failed).." native RGB tests failed") end
print(tostring(passed).." native RGB tests passed (mock native reader; live application unverified)")
