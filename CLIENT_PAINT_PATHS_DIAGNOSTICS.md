# Incremental, locked paint-path diagnostics

This revision changes diagnostic inspection, UI and export only. The painting scheduler, remote protocol, colors and selection behavior are unchanged and stay disabled by the locked diagnostic loader.

## Use the new build

If the previous build is already stuck inside a decompiler call, restart the Roblox client once before using this build. Closing that older panel cannot prove its external decompiler stopped. No Studio or place access is needed.

Run the public diagnostic loader, then use these separate buttons:

- **Quick Paint Path Scan**: recommended first. Enumerates the five high-priority roots and reads only likely relevant paths.
- **Full Client Scan**: optional. Reads all high-priority candidates first, then enumerates and inspects the broader roots.
- **CANCEL SCAN**: immediately stops scheduling new reads; the coordinator finishes with partial results.
- **Copy Current Report**: exports only collected results, including partial results while a scan is active. It never starts or resumes inspection.

Public loader:

    loadstring(game:HttpGet("https://raw.githubusercontent.com/said2201010191-cmd/AutoPainter/main/LoaderDiagnostic.luau", true))()

Clipboard export uses the existing setclipboard function. If unavailable or failing, writefile saves CLIENT_PAINT_PATHS_FULL_REPORT.txt in the environment's file area. No report is uploaded. If neither capability works, collected results remain available through GetFullPaintPathsReport() and the UI pages.

Optional PaintBucket-only Protocol Extract, full source and descendant inventory remain available. Copy Protocol Report now also requires an already-collected report; it never starts inspection. All decompilation actions share the same watchdog and outstanding-call cap.

## Progress and order

The UI shows scripts discovered, current script index/total, text returned, failed, timed out, skipped, cached, actual outstanding decompiles, current full path, and last timed-out path. The current path is published before calling the external decompiler.

High-priority roots are LocalPlayer.PlayerScripts, Backpack, Character, PlayerGui and ReplicatedStorage. Names/full paths containing Paint, Province, Territory, Country, Map, Bucket, War, Peace, Remote, Admin, Capture or Color are prioritized, case-insensitively. Within the relevant and remaining groups, the listed root order takes precedence over path order.

Quick mode skips non-relevant paths and does not enumerate broad roots. Full mode processes all five high-priority roots before broad-root discovery: other LocalPlayer descendants, ReplicatedFirst, StarterPlayer (including readable StarterPlayerScripts), StarterGui, StarterPack, Workspace and additional readable DataModel containers. Overlapping roots deduplicate by Instance identity; identical paths can still be distinct Instances.

CoreGui engine internals, other players' containers under Players, server-only containers and the Script class are excluded and disclosed. Workspace-visible tools/controllers remain included. Absent/unreplicated roots and enumeration failures are explicit gaps.

## Timeout and strict task bounds

Important parameters near the top of AutoPainterFinal.luau:

| Parameter | Default | Meaning |
|---|---:|---|
| DiagnosticDecompileTimeout | 6 seconds | Stop waiting for an individual decompile |
| DiagnosticMaxUnreturned | 2 | Hard maximum of external decompiler calls that have not actually returned |
| DiagnosticWatchdogPoll | 0.05 seconds | Cooperative deadline/cancellation polling |
| DiagnosticSliceSeconds | 0.008 seconds | Local processing budget before yielding |
| DiagnosticSliceItems | 128 | Additional iteration bound before yielding |

There is one incremental scan coordinator and at most two unreturned decompile workers. No per-script waiting tasks, unlimited replacement workers or task cancellation are used.

A TIMED_OUT call **continues occupying its slot**. With one stalled call, the other slot processes subsequent scripts sequentially. If both calls stall, remaining uncached candidates receive SKIPPED_CAPACITY and the report completes with coverage gaps. Repeated scans cannot start replacements beyond that cap. A slot is released only when its actual call returns.

Cancel stops scheduling immediately and stops waiting within the next watchdog poll while the scheduler is running. It does not pretend to cancel an already-entered external call. Timeout/cancel/busy guards cover the narrow source readers too. A live late return releases its own slot and becomes available to the cache.

**Unavoidable limitation:** Roblox tasks are cooperatively scheduled. If the environment's decompiler blocks the entire VM/native client thread without yielding, an in-client watchdog cannot run or forcibly interrupt it. This design handles yielded/stalled calls while the scheduler remains responsive; it cannot guarantee recovery from a frozen executor/client. Roblox's task API does not provide a proven safe cancellation contract for a third-party decompiler: https://create.roblox.com/docs/reference/engine/libraries/task

Closing the new UI while decompiles remain outstanding leaves a hidden local controller with all ordinary listeners disconnected. It refuses loader reruns until those calls really return, preventing close/reload from multiplying abandoned workers. It removes itself when the last call returns. If calls never return, restart the client. This guards normal loader/UI usage; it cannot retroactively account for calls created by older builds or unrelated scripts.

## Cache and cancellation

Completed per-script results are cached by Instance identity, including read errors. Raw returned text is cached before context indexing, so cancellation during indexing does not require another decompile. Once indexed, the raw text is replaced by compact analysis fragments. Rerunning rediscovers current objects and reuses completed cached results.

Timeout records remain associated with their outstanding call; they are never repeatedly retried while it remains outstanding. A late result can replace the timeout cache on a subsequent scan. Capacity skips and absent decompile capability are not permanent cached read results.

Instances are weak cache keys; completed report rows retain text/metadata rather than Instances. New Instances, even at the same path, are independently inspected. Cache lifetime is the current diagnostic session, not a disk cache or source-change detector. If source changes inside the same Instance, a fresh session is required to refresh a completed cached result; do not start a fresh session over still-outstanding reads.

## Report and read-only contract

CLIENT_PAINT_PATHS_FULL_REPORT format 2 preserves all nine requested sections. Each discovered script/module has FullName, ClassName, status and byte count when available. Call sites, PaintPart occurrences and candidate categories reference shared merged context, with eight preceding and twelve following lines. Script-specific block IDs prevent collisions when cached fragments are reused. No source/count cap silently truncates the report.

The collector calls only the environment-provided decompile function. It does not require/execute modules, execute inspected source, call target functions, send game remotes, paint, hook callbacks, spoof state or change game properties/attributes. Progress/report rendering changes only AutoPainter's own local UI. Clipboard/file export occurs only on explicit Copy. The decompiler provider remains responsible for the implementation of that external function.

The report distinguishes pending, failed, timed-out, unavailable, quick-mode-skipped, cancelled and capacity-blocked results. No read failure is evidence that a painting route does not exist. Sections about stored targets, batch APIs, admin/private/test branches or alternate remotes remain candidates needing manual source review. Source inspection cannot establish hidden server validation or live acceptance.

## Validation

337 deterministic tests pass, including 66 tests for the new incremental full/quick scanner and the existing 271 tests adapted where source workers/copy semantics intentionally changed. Coverage includes an indefinitely yielded decompiler, one-stall continuation, two-stall capacity exhaustion, progress/full paths, cancellation/resume, cached success/failure/late returns, copying during a stall, UI buttons, close/reload guarding, root priority, source/context extraction, cleanup and a 300-module corpus.

These are mock-engine tests and Luau compilation checks, not live executor or game validation. No real paint request or live source scan is performed from this workspace.
