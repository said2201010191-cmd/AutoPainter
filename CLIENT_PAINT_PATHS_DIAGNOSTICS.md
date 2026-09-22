# Comprehensive locked client paint-path diagnostics

This build extends **diagnostics only**. AutoPainter's paint scheduler, request payload, limits, colors, selection transactions and remote cache are unchanged. No requests are enabled. The diagnostic loader enforces `DiagnosticOnly = true` and `LockDiagnostics = true`.

## Use

Close the older AutoPainter panel (diagnostic versions 1–4), then run:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/said2201010191-cmd/AutoPainter/main/LoaderDiagnostic.luau", true))()
```

Click **Full Paint Paths Report**, then **Copy Full Paint Paths Report**. Clicking Copy first also builds the report. The entire report is copied through the environment's existing `setclipboard`; if unavailable or failing, it is saved through `writefile` as `CLIENT_PAINT_PATHS_FULL_REPORT.txt` in that environment's file area. If neither works, the complete report remains available in Prev/Next pages. Export is explicit, local and independent of the current displayed page. Nothing is uploaded.

The report is headed `CLIENT_PAINT_PATHS_FULL_REPORT`. To refresh its snapshot, click Full Paint Paths Report again. Copy exports the latest completed full snapshot. Existing PaintBucket-only Protocol Extract, source inspection and descendant inventory remain separate actions.

## What is inspected

Every enumerated **LocalScript** and **ModuleScript**, including scripts with no matching text, receives a manifest entry with an ID, full path, class, read status, source byte count when available, remote-shaped call count and PaintPart occurrence count.

Roots:

- LocalPlayer.PlayerScripts, PlayerGui, Backpack, Character and other visible LocalPlayer descendants.
- ReplicatedStorage, ReplicatedFirst, StarterPlayer (including StarterPlayerScripts where present), StarterGui and StarterPack.
- Workspace, including visible tools/controllers regardless of their names.
- Other readable top-level DataModel containers discovered at inspection time.

Overlapping roots are deduplicated by Instance identity. Identical full paths remain separate IDs. Results sort by path/class; identical path/class ties use snapshot discovery order. Every root records enumeration counts; absent/unreplicated roots, failed enumeration, unreadable metadata, failed/invalid decompilation and scripts that leave scope are explicit gaps.

Excluded: CoreGui engine internals, other players' containers under Players, server-only containers and the Script class (including RunContext Client). Those exclusions are printed. Workspace-visible tools remain included. Server-only/unreplicated, unparented, late-created or already-removed code is not available in this snapshot.

The existing environment-provided `decompile` function is the only source-reading capability used. Missing decompile is reported for every candidate. No direct Source/bytecode/closure fallback, require, execution of returned source, call to inspected functions, remotes, callback hooks, spoofing, moderation interception, state/attribute writes or synthetic input is used by the collector. The environment provider determines what its decompile implementation does internally; returned text is explicitly unverified.

## Compact report layout

All requested search terms are searched case-insensitively, with additional ownership/state/permission and method-reference candidates. The report contains:

1. ALL PAINT/PROVINCE REMOTE CALLS
2. ALL PaintPart CALL SITES
3. ALL ALTERNATE PROVINCE-MODIFICATION PATHS
4. ADMIN / PRIVATE / TEST PATHS
5. BATCH / MULTI-TARGET PATHS
6. STORED-INSTANCE TARGETING PATHS
7. PERMISSION / CAPABILITY / TOKEN STATE
8. READ FAILURES / COVERAGE GAPS
9. FINAL SUPPORTED CLIENT ROUTES

Remote call text includes colon, dot and literal-index invocation syntax, whitespace/newline-separated tokens, repeated same-line calls and method references for alias tracing. All remote-shaped calls are retained, including those whose paint relevance is unknown. FireAllClients is included alongside the four requested remote methods; server-facing/client-facing names in shared module source do not grant ordinary clients new capabilities.

Each PaintPart occurrence has a line/column reference. Category indexes point to shared context blocks printed once: eight preceding and twelve following lines, merging overlapping/adjacent windows per script. Each block identifies the script and numbered source lines. All blocks are retained; there is no hidden source/script/report truncation cap. Large relevant codebases can still produce large reports, but one export contains every page without repeating the same context in each category.

## What the report can and cannot conclude

The categories are **textual candidates**, not a semantic call graph or live trace. Comments, strings, dead code, local-only color changes, generic loops, and aliases of the real mouse target can all match. Dynamic method construction, wrapper chains and indirect arguments require manual source tracing. A decompiler can return incomplete/error-comment text without throwing.

A–D remain **UNRESOLVED** in the generated report until its evidence is reviewed: stored/off-cursor targets, batch APIs, ordinary-player access to admin/private/test branches, and alternative painting remotes. No keyword match proves an authorized supported route. No-match results never claim that an alternate route is impossible.

E prints exact snapshot counts: unique enumerated candidates, text returned, read failures, not-read candidates, returned source bytes, remote call text, PaintPart occurrences and coverage gaps. Enumeration failures leave the unknown number of missing scripts explicitly unknown. Coverage percentages for the entire shipped game would be unjustified.

No actual client corpus or live game is accessible to the repository tests. After running this build in the game, share the exported report for protocol analysis. No paint-path diagnosis or successful paint is claimed by this build.

## Lifecycle and verification

One shared inspection runs at a time across the full and PaintBucket-only actions. No per-script jobs, retries or waiting-worker queue are created. The collector yields cooperatively when its local processing exceeds approximately 12 ms, checking shutdown and current scope after yields. A synchronous external decompiler call cannot be forcibly interrupted; while it is yielded/hung, additional inspections are refused. Closing prevents subsequent decompiler calls, cached results, stale UI updates and fallback file export.

Only the latest completed full report string is retained; no source-object history/listeners are retained after completion. The existing narrow report has its own export snapshot. Showing results changes AutoPainter's own UI; the collector itself performs no Instance property/attribute writes. Explicit copy/file export is the requested external side effect.

Validation: **333 deterministic tests pass**, including 62 new full-coverage tests across immediate/deferred signals and all 271 existing tests. The tests cover zero collector game traffic/property writes, no source execution, roots/modules, gaps/failures, duplicates, multiline calls, all search terms, shared context, export fallback, UI actions, lifecycle/busy guards, respawn/removal, cooperative yielding and a 400-module corpus. Official Luau compilation validates the final source, loaders and tests. These are mock/runtime syntax checks, not proof of decompiler quality, live server acceptance or moderation behavior.
