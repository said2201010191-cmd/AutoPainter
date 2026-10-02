local Base=require("./V81Mock")
local Mock={}
function Mock.new(deferred)
 local w=Base.new(deferred)
 w.env.OverlapParams={new=function() return {} end}
 rawset(w.workspace,"GetPartBoundsInBox",function() return w.cameraObstacles or {} end)
 rawset(w.input,"IsMouseButtonPressed",function(_,button) return button==w.env.Enum.UserInputType.MouseButton1 and w.button or button==w.env.Enum.UserInputType.MouseButton2 and w.rightButton or false end)
 local wait=w.runService.RenderStepped.Wait
 rawset(w.runService.RenderStepped,"Wait",function(...)
  wait(...)
  if not w.noAcquire and w.workspace.CurrentCamera.CameraType==w.env.Enum.CameraType.Scriptable then
   -- v8.1 mock used the first part within a bounding sphere, incorrectly choosing
   -- neighbors 40 studs away. Select the actual nearest surface at camera focus.
   local focus=w.workspace.CurrentCamera.Focus.Position;local closest,dist=nil,math.huge
   for _,p in ipairs(w.parts) do local d=(p.Position-focus).Magnitude
    if p.Parent==w.provinces and d<math.min(dist,p.Size.Magnitude/2) then closest,dist=p,d end
   end
   if closest and not w.cannotAcquire[closest] and not w.blockCameraTarget then w.mouse.Target=closest end
  end
 end)
 return w
end
return Mock
