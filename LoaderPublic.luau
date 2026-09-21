-- Run in the same client execution environment as the original loader.
-- The final script defaults to diagnostics ON until its game protocol is verified.
-- The repository/file must be public; no credentials are used.
local url = "https://raw.githubusercontent.com/said2201010191-cmd/AutoPainter/main/AutoPainterFinal.luau"
assert(type(loadstring) == "function", "This loader needs a client execution environment with loadstring support.")
local ok, source = pcall(function() return game:HttpGet(url, true) end)
assert(ok and type(source) == "string", "AutoPainter download failed. Check public access to the repository and your connection.")
local run, problem = loadstring(source, "AutoPainterFinal")
assert(run, problem)
return run()
