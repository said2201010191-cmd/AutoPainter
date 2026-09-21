-- Read-only AutoPainter session: the request gate is locked for this instance.
-- Close any older AutoPainter panel first. No credentials, hooks or test paints.
local url = "https://raw.githubusercontent.com/said2201010191-cmd/AutoPainter/main/AutoPainterFinal.luau"
assert(type(loadstring) == "function", "This loader needs your existing client loadstring environment.")
local ok, source = pcall(function() return game:HttpGet(url, true) end)
assert(ok and type(source) == "string", "AutoPainter download failed. Check public repository access and your connection.")
local run, problem = loadstring(source, "AutoPainterFinal")
assert(run, problem)
return run({ DiagnosticOnly = true, LockDiagnostics = true })
