-- Full bodies, no inferred working-color truth. All fixture source is inert text.
for _,deferred in ipairs({false,true}) do
 local prefix=deferred and "deferred color evidence: " or "immediate color evidence: "
 test(prefix.."explicit scan keeps full unrelated aliases before and after keyword windows",function()
  local w,a,roots,sources,reads=fullFixture(deferred)
  local script=child(w,"LocalScript","PaletteHandler",roots.PlayerGui)
  local body='local hiddenAlias = function(value) return value end\n'..string.rep('-- padding\n',60)..'local c = Color3.fromRGB(1,2,3)\n'..string.rep('-- padding\n',60)..'return hiddenAlias(c)'
  sources[script]=body
  assert(a.StartDiagnosticScan("ColorEvidence"));waitForScan(w,a)
  local report=a.GetNativeColorEvidence();contains(report,body);contains(report,"ObjectsInspected=");contains(report,"InventoryComplete=true")
  contains(report,"RetainedSourceBytes="..#body);assert(#reads==1);noTraffic(w,a);a.Destroy()
 end)
 test(prefix.."all PlayerGui controls inventoried beyond palette names without trusting user text",function()
  local w,a,roots,sources,reads=fullFixture(deferred)
  local root=child(w,"ScreenGui","AlternateSettings",roots.PlayerGui)
  local frame=child(w,"Frame","GenericEditor",root);frame.Visible=false
  local field=child(w,"TextBox","Input",frame);field.Text="12,34,56"
  local note=child(w,"TextBox","PrivateNote",root);note.Text="private chat secret"
  frame:SetAttribute("ApiToken","123456");frame:SetAttribute("Tint",w.Color3.fromRGB(10,20,30))
  local mod=child(w,"ModuleScript","Utility",root);sources[mod]="return function(v) return v end"
  local before=#w.writeLog;assert(a.StartDiagnosticScan("ColorEvidence"));waitForScan(w,a)
  local report=a.GetNativeColorEvidence()
  contains(report,frame:GetFullName());contains(report,"Visible=false");contains(report,"Text=12,34,56");contains(report,"Tint=Color3(10,20,30)")
  assert(not report:find("private chat secret",1,true) and not report:find("123456",1,true));contains(report,"ApiToken=<redacted>")
  for i=before+1,#w.writeLog do assert(w.writeLog[i].object:IsDescendantOf(w.playerGui:FindFirstChild("AutoPainterFinalUI"))) end
  assert(#reads==1);a.Destroy()
 end)
 test(prefix.."compact cached source is reread once to obtain missing full bodies",function()
  local w,a,roots,sources,reads=fullFixture(deferred);local s=child(w,"ModuleScript","PlainModule",roots.ReplicatedStorage);sources[s]="local first=17\nreturn first"
  scanReport(w,a,"GameOnly");assert(#reads==1)
  assert(a.StartDiagnosticScan("ColorEvidence"));waitForScan(w,a);assert(#reads==2);contains(a.GetNativeColorEvidence(),sources[s])
  assert(a.StartDiagnosticScan("ColorEvidence"));waitForScan(w,a);assert(#reads==2);contains(a.GetNativeColorEvidence(),sources[s]);a.Destroy()
 end)
 test(prefix.."copy is file-first and never starts or repeats any source read",function()
  local w,a,roots,sources,reads=fullFixture(deferred)
  assert(not a.CopyNativeColorEvidence());assert(#reads==0);contains(a.GetNativeColorEvidence(),"NOT_STARTED")
  child(w,"LocalScript","PaintInit",w.bucket);assert(a.StartDiagnosticScan("ColorEvidence"));waitForScan(w,a)
  local saved;w.env.writefile=function(path,text) assert(path=="AutoPainterNativeColorEvidence.txt");saved=text end
  w.env.setclipboard=function() error("file should win") end
  local n=#reads;press(w,"Copy Native Color Evidence");assert(saved and #reads==n);contains(saved,"FULL SCRIPT/MODULE BODIES");a.Destroy()
 end)
 test(prefix.."clipboard fallback and closed collector do not reread or write",function()
  local w,a,roots=fullFixture(deferred);assert(a.StartDiagnosticScan("ColorEvidence"));waitForScan(w,a)
  w.env.writefile=function() error("file denied") end;local copy;w.env.setclipboard=function(s) copy=s end
  assert(a.CopyNativeColorEvidence() and copy);a.Destroy();assert(not a.CopyNativeColorEvidence());contains(a.GetNativeColorEvidence(),"CLOSED")
 end)
 test(prefix.."timeout is explicit and the two outstanding-call cap still bounds the corpus scan",function()
  local w,a,roots,sources,reads=fullFixture(deferred)
  for i=1,4 do child(w,"ModuleScript","Unknown"..i,roots.ReplicatedStorage) end
  local calls=0;w.env.decompile=function() calls+=1;return coroutine.yield() end
  assert(a.StartDiagnosticScan("ColorEvidence"));waitForScan(w,a)
  local report=a.GetNativeColorEvidence();assert(calls==2);contains(report,"TimedOut=2");contains(report,"SKIPPED_CAPACITY");noTraffic(w,a);a.Destroy()
 end)
 test(prefix.."actual button invokes full mode and preserves remote lock",function()
  local w,a,roots,sources,reads=fullFixture(deferred);child(w,"LocalScript","NoColorName",roots.PlayerGui)
  press(w,"Native Color Source Scan (full bodies)");waitForScan(w,a)
  assert(a.GetDiagnosticScanState().Mode=="ColorEvidence" and #reads==1 and not a.SetDiagnostic(false))
  contains(a.GetNativeColorEvidence(),"working color");a.SetPainting(true);w.step(.2);noTraffic(w,a);a.Destroy()
 end)
 test(prefix.."GUI and tool snapshots include genuine exposed values without invoking callbacks",function()
  local w,a,roots,sources,reads=fullFixture(deferred)
  w.player:SetAttribute("PaintBucketColor",w.Color3.fromRGB(7,8,9))
  local value=child(w,"Color3Value","LocalColor",w.bucket);value.Value=w.Color3.fromRGB(10,11,12)
  local s=child(w,"LocalScript","Init",w.bucket);sources[s]='local working = player:GetAttribute("PaintBucketColor")\ntool.Equipped:Connect(function() print(working) end)'
  assert(a.StartDiagnosticScan("ColorEvidence"));waitForScan(w,a);local report=a.GetNativeColorEvidence()
  contains(report,"ExposedPaintBucketColor=Color3(7,8,9)");contains(report,"Value=Color3(10,11,12)");contains(report,sources[s]);noTraffic(w,a);a.Destroy()
 end)
 test(prefix.."cancel retains completed full body and enumerated failure evidence",function()
  local w,a,roots,sources,reads=fullFixture(deferred)
  local s=child(w,"LocalScript","A_Paint",roots.PlayerScripts);sources[s]='return "full-first"'
  local b=child(w,"ModuleScript","B_Paint",roots.PlayerScripts)
  w.env.decompile=function(o) if o==s then return sources[s] end;return coroutine.yield() end
  assert(a.StartDiagnosticScan("ColorEvidence"));w.step(.5);assert(a.CancelDiagnosticScan());waitForScan(w,a)
  local report=a.GetNativeColorEvidence();contains(report,sources[s]);contains(report,"CANCELLED");contains(report,b:GetFullName());noTraffic(w,a);a.Destroy()
 end)
 test(prefix.."source bytes cannot masquerade as live application proof",function()
  local w,a,roots,sources,reads=fullFixture(deferred);local m=child(w,"ModuleScript","NativeCustom",roots.ReplicatedStorage)
  sources[m]='return function(color) error("must never execute") end'
  assert(a.StartDiagnosticScan("ColorEvidence"));waitForScan(w,a)
  contains(a.GetNativeColorEvidence(),"Data-flow conclusion=PENDING MANUAL TRACE");assert(a.GetStats().Attempted==0);a.Destroy()
 end)
end
