local Base=require("./FastHoldMock")
local Mock={}
function Mock.new(deferred)
 local w=Base.new(deferred)
 w.nativePaletteColor=w.color;w.paletteClicks=0;w.uiButtons={};w.buttonColors={};w.internalWrites=0;w.buttonActions={}
 local root=w.instance("ScreenGui");root.Name="NativePaintPalette";root.Enabled=true;root.Parent=w.playerGui
 w.paletteRoot=root
 local function hit(point)
  if not root.Enabled then return nil end
  for _,b in ipairs(w.uiButtons) do
   local p=b.AbsolutePosition+w.inset;local size=b.AbsoluteSize
   if b.Visible and point.X>=p.X and point.X<p.X+size.X and point.Y>=p.Y and point.Y<p.Y+size.Y then return b end
  end
 end
 local renderWait=w.runService.RenderStepped.Wait
 rawset(w.runService.RenderStepped,"Wait",function(...) renderWait(...);if hit(w.cursor) then w.mouse.Target=w.uiUnderlyingTarget end end)
 rawset(w.playerGui,"GetGuiObjectsAtPosition",function(_,x,y)
  if w.blockedGUI then return {w.blockedGUI} end
  local b=hit(w.v(x+w.inset.X,y+w.inset.Y));if b then return {b} end
  if w.mapOverlay and w.mapOverlay.Visible and y<350 then return {w.mapOverlay} end
  return {}
 end)
 function w.makePalette(n)
  for i=1,n do
   local b=w.instance("TextButton");b.Name="Swatch"..i;b.Visible=true;b.Active=true
   b.AbsolutePosition=w.v(20+((i-1)%16)*45,360+math.floor((i-1)/16)*24);b.AbsoluteSize=w.v(40,20);b.BackgroundColor3=w.Color3.new(0,0,0);b.Parent=root
   w.buttonColors[b]=w.Color3.fromRGB((i*23)%230,(i*41)%230,(i*67)%230);table.insert(w.uiButtons,b)
  end
 end
 function w.recreatePalette(n,chrome)
  root:Destroy();w.uiButtons={};w.buttonColors={};w.buttonActions={}
  root=w.instance("ScreenGui");root.Name="NativePaintPalette";root.Enabled=true;root.Parent=w.playerGui
  w.paletteRoot=root;w.makePalette(n)
  if chrome then return w.makeChrome() end
 end
 function w.detachPalette() root.Parent=nil end
 function w.attachPalette() root.Parent=w.playerGui end
 local function selectButton(b)
  if w.buttonActions[b] then w.buttonActions[b]() end
  local c=w.buttonColors[b]
  if w.ignorePaletteClicks and w.uiAutomatic then return end
  if c then
   if not w.stalePalette then w.nativePaletteColor=c end
   w.player:SetAttribute("PaintBucketColor",c);w.internalWrites+=1
  end
  if not w.noPaletteClicked then b.MouseButton1Click:Fire() end
  if not w.noPaletteActivated then b.Activated:Fire() end
  if w.afterPaletteSelect then w.afterPaletteSelect(b) end
 end
 w.nativeResultColor=function(_,attribute)
  if w.resultOverride then return w.resultOverride(attribute) end
  local color=w.nativePaletteColor
  if w.quantize then return w.Color3.fromRGB(math.round(color.R*255),math.round(color.G*255),math.round(color.B*255)) end
  return color
 end
 local create=w.input.CreateVirtualInput
 rawset(w.input,"CreateVirtualInput",function(self)
  local handle=create(self);if not handle then return nil end
  local move=handle.SendMousePosition
  handle.SendMousePosition=function(self,point) move(self,point);if hit(point) then w.mouse.Target=w.uiUnderlyingTarget end;if w.afterCursorMove then w.afterCursorMove(w.mouse.Target) end end
  local send=handle.SendMouseButton
  handle.SendMouseButton=function(self,pos,button,down,repeats)
   local b=hit(pos)
   if down and b then
    assert(not w.button);w.button=true;w.uiPressed=b;w.uiDownAt=w.now;w.mouse.Button1Down:Fire();if w.onPaletteDown then w.onPaletteDown(b) end;return
   elseif not down and w.uiPressed then
    local pressed=w.uiPressed;w.uiPressed=nil;w.button=false;w.mouse.Button1Up:Fire()
    if pressed==b and (not w.minPaletteHold or w.now-w.uiDownAt>=w.minPaletteHold) then w.paletteClicks+=1;w.uiAutomatic=true;selectButton(b);w.uiAutomatic=false end
    return
   end
   return send(self,pos,button,down,repeats)
  end
  return handle
 end)
 function w.humanSelect(button)
  w.cursor=button.AbsolutePosition+w.inset+w.v(5,5);w.button=true
  w.input.InputBegan:Fire({UserInputType=w.env.Enum.UserInputType.MouseButton1},true);w.flush()
  selectButton(button);w.flush();w.button=false
 end
 function w.learn(api)
  assert(api.BeginPaletteLearning("COLORS"))
  for _,b in ipairs(w.uiButtons) do w.humanSelect(b) end
  api.FinishPaletteLearning();w.flush()
 end
 function w.makeChrome()
  local function control(name,x)
   local b=w.instance("TextButton");b.Name=name;b.Text=name;b.Visible=true;b.Active=true;b.AbsolutePosition=w.v(x,100);b.AbsoluteSize=w.v(40,20);b.BackgroundColor3=w.color;b.Parent=root;table.insert(w.uiButtons,b);return b
  end
  local opener,closer=control("OpenPalette",20),control("ClosePalette",70)
  local function show(value)
   for b in pairs(w.buttonColors) do b.Visible=value end
   if w.mapOverlay then w.mapOverlay.Visible=value end
  end
  w.buttonActions[opener]=function() show(true) end;w.buttonActions[closer]=function() show(false) end
  return opener,closer,show
 end
 function w.getButton(text)
  for _,o in ipairs(w.playerGui:GetDescendants()) do if o.ClassName=="TextButton" and o.Text==text then return o end end
 end
 return w
end
return Mock
