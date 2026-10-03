local Mock=require("./V82Mock")
local Fixture={}
local function setup(SOURCE,deferred,count)
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

Fixture.setup=setup;Fixture.clean=clean;Fixture.nativeClean=nativeClean
return Fixture
