local Base=require("./HandsFreeMock")
local Fast={}
function Fast.new(deferred)
	local w=Base.new(deferred)
	w.virtualAvailable=true;w.cursorMoves=0;w.violations=0;w.paintCalls=0
	local spawn=w.env.task.spawn
	local function waitable(signal)
		rawset(signal,"Wait",function()
			local thread=coroutine.running();local connection
			connection=signal:Connect(function(...)
				connection:Disconnect();spawn(thread,...)
			end)
			return coroutine.yield()
		end)
	end
	local originalInstance=w.env.Instance.new
	w.env.Instance.new=function(class)
		local o=originalInstance(class)
		if class=="BindableEvent" then
			local event=w.signal();waitable(event);rawset(o,"Event",event)
			rawset(o,"Fire",function(_,...) event:Fire(...) end)
		end
		return o
	end
	local atPoint=function(x,y)
		for _,p in ipairs(w.parts) do
			local pt,visible=w.workspace.CurrentCamera:WorldToViewportPoint(p.Position)
			if p.Parent==w.provinces and visible and math.abs(x-pt.X)<p.Size.X/2 and math.abs(y-pt.Y)<p.Size.Z/2 then return p end
		end
		return nil
	end
	local create=w.input.CreateVirtualInput
	rawset(w.input,"CreateVirtualInput",function(self)
		local handle=create(self)
		if not handle then return nil end
		handle.SendMousePosition=function(_,pos)
			if w.moveDenied then error("move denied") end
			w.cursorMoves+=1
			local function move()
				w.cursor=w.v(pos.X,pos.Y);w.mouse.Target=w.badCursorTarget or (not w.staleCursor and atPoint(pos.X,pos.Y) or w.mouse.Target)
				w.mouse.Move:Fire()
			end
			if w.cursorDelay then w.schedule(w.cursorDelay,move) else move() end
			if w.paintDuringCursor and w.activeMethod=="VirtualInput.SendMouseButton" and w.mouse.Target then
				w.mouse.Target.Color=w.player:GetAttribute("PaintBucketColor")
				w.env.task.wait(0.005)
			end
		end
		local button=handle.SendMouseButton
		handle.SendMouseButton=function(self,pos,which,isDown,repeats)
			button(self,pos,which,isDown,repeats)
			if isDown and w.nativeRepeat then
				local generation=w.repeatGeneration or 0
				local function repeatPaint()
					if w.activeMethod~="VirtualInput.SendMouseButton" or generation~=(w.repeatGeneration or 0) then return end
					local part=w.mouse.Target
					if part and part.Parent==w.provinces then
						w.paintCalls+=1
						if w.protected and not w.protected[part] then w.violations+=1 end
						if not w.stalled or not w.stalled[part] then part.Color=w.nativeResultColor and w.nativeResultColor(part,w.player:GetAttribute("PaintBucketColor")) or w.player:GetAttribute("PaintBucketColor") end
					end
					w.schedule(w.nativeInterval or 0.04,repeatPaint)
				end
				w.schedule(w.nativeInterval or 0.04,repeatPaint)
			elseif not isDown then w.repeatGeneration=(w.repeatGeneration or 0)+1 end
		end
		return handle
	end)
	w.responses["VirtualInput.SendMouseButton"]={mouse=true}
	w.nativeRepeat=true
	w.start=function(api,seconds) w.env.task.spawn(api.Start);w.step(seconds or 0.2) end
	w.assertClean=function() assert(#w.errors==0,table.concat(w.errors,"\n"));assert(w.networkAttempts==0) end
	return w
end
return Fast
