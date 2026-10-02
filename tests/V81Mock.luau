local Base=require("./V8Mock")
local Mock={}
function Mock.new(deferred)
 local w=Base.new(deferred)
 local camera=w.workspace.CurrentCamera
 rawset(camera,"ScreenPointToRay",function() return {Origin=camera.CFrame.Position,Direction=(camera.Focus.Position-camera.CFrame.Position).Unit} end)
 w.cannotAcquire={};w.targetLosses={};w.faultDowns=0;w.faultUps=0
 local rel=w.env.mousemoverel
 w.env.mousemoverel=function(...) rel(...);if w.cannotAcquire[w.mouse.Target] then w.mouse.Target=nil end end
 local create=w.input.CreateVirtualInput
 rawset(w.input,"CreateVirtualInput",function(self)
  local handle=create(self);if not handle then return nil end
  local move=handle.SendMousePosition
  handle.SendMousePosition=function(self,point)
   move(self,point)
   if w.cannotAcquire[w.mouse.Target] then w.mouse.Target=nil end
  end
  local send=handle.SendMouseButton
  handle.SendMouseButton=function(self,pos,button,down,repeats)
   if down and w.duplicateDown and w.duplicateDown>0 then
    w.duplicateDown-=1;w.faultDowns+=1;w.button=true
    error("VirtualInput::SendMouseButton: duplicate button state")
   end
   if not down and w.duplicateUp and w.duplicateUp>0 then
    w.duplicateUp-=1;w.faultUps+=1;w.button=false;w.activeMethod=nil
    w.repeatGeneration=(w.repeatGeneration or 0)+1
    error("VirtualInput::SendMouseButton: duplicate button state")
   end
   local target=w.mouse.Target
   send(self,pos,button,down,repeats)
   if down and target and (w.targetLosses[target] or 0)>0 then
    w.targetLosses[target]-=1;w.mouse.Target=nil
   end
  end
  return handle
 end)
 local wait=w.runService.RenderStepped.Wait
 rawset(w.runService.RenderStepped,"Wait",function(...)
  wait(...);if w.cannotAcquire[w.mouse.Target] then w.mouse.Target=nil end
 end)
 return w
end
return Mock
