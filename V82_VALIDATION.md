# v8.2 Cadence Follow-up validation

Base `79a6de16a29ac1fecce8b90910b7962a66ab9474`; build `8.2-followup`. See [LIVE_FOLLOWUP.md](LIVE_FOLLOWUP.md) for all sections of the 2026-10-03 authoritative follow-up, live procedures and conditional limitations.

| Suite / check | Result |
|---|---:|
| Historical native controller |222 passed|
| Locked diagnostics |252 passed|
| Hands Free regressions |208 passed|
| v8.2 overload / palette / camera / selection |106 passed|
| Prior live-fix regressions |64 passed|
| Combat / explicitly opted-in hold experiments |52 passed|
| Cooldown benchmark, updated pause/reset contract |32 passed|
| New cadence / solo reset / recovery / generated semantics |60 passed|
| **Total deterministic tests** |**996 passed**|
| **Every repository Luau file** |**35/35 compiled**|

Commands:

```sh
python3 tests/run_tests.py /path/to/luau
python3 tests/check_luau.py /path/to/luau-compile
```

The Luau compiler checks syntax/bytecode, not Roblox-engine types or live executor behavior. Historical Markdown-wrapped references are unwrapped only in temporary compile copies. Original/FastClient/CivilWarOldLoader/Final and the locked diagnostic script remain unchanged.

Source guards still verify the authoritative normalized matcher, native cursor mover and native palette click/settle/hold sequence. Active Hands Free scans forbid game RPC calls, target assignment, hooks, signal firing, unverified PaintBucketColor writes, require and decompile. Immediate and deferred events run for both existing and new controller scenarios.

All prior scenario counts are retained. Expectations intentionally updated: PER_TARGET is now pinned by default; hold tests explicitly opt in; short multi-target fixtures allow the real new native DOWN cadence to elapse; one synthetic experimental strategy-comparison fixture explicitly disables that gate to isolate the no-throughput-advantage decision. Benchmark temporary interruptions now pause/resume, while explicit Cancel restores the old mode paused. These are specification changes, not removed safety tests.

New tests use the actual production runtime, including its default 226 ms gate. They cover:

- Separate 120 ms dwell and observed native DOWN spacing; healthy native response latency excludes cadence waiting. Clean/STOP during the wait produces no late DOWN. Upgrade changes invalidate a prior measured cadence.
- Full 13-row solo sweeps using the same 30 distinct provinces, the real learned-palette state machine, 360 reset paints and two native palette selections per reset phase. Reset/measurement work cannot train production dwell/strategy or production correction counts.
- Escape, explicit Resume button, chat/menu/focus/tool pauses, disabled tool, repeated pause/resume, native reset failure, a recoverable sample exception, bounded repeated unqualified acquisitions, and manual waits exceeding the old timeout.
- Insufficient selection followed by the actual Add Benchmark Provinces / Done / Resume UI callbacks. Mode and camera cannot be switched under diagnostic ownership.
- Completed and partial evidence/row identity survives pauses; copies send no input. Color before observed DOWN is not credited. Colors after the observation deadline are not credited. Cancel cannot classify an unfinished observation window as a false no-effect.
- Cancel during reset stops future input; completed rows remain. Final completion restores a previously running Civil scheduler with original assignments. Retired cohort/tool references are cleared.
- 128 semantic native controls and stable Civil assignments survive PaletteGui recreation while the benchmark is paused, then the full sweep completes. Prior 25-generation persistence and ambiguity tests still pass.
- Calibration uses actual P90 rather than requested interval, rejects incomplete/unqualified/changed-context rows, and never creates a claimed absolute minimum.
- The 186/128/58 capacity case explicitly reports generation PROVEN versus application UNVERIFIED, no duplicate warning, and no fake extra assignment. A reproducible 58-color generator preview excludes native colors/normalized duplicates/current-color proximity without input or assignments.

Mock native paint effects are fixture-only Color changes after Mouse.Button1Down. Runtime game properties are not fabricated. Unit results prove scheduler/state accounting under those models, not paint causality or server acceptance.

**Source findings:** OG arbitrary RGB creation is present; the old scripts applied it using direct remote payloads. No supplied/current native arbitrary-RGB writer is established. **Live unknowns:** the minimum reliable cadence, combat acceptance/CPS of this new revision, and arbitrary-RGB application through the current native tool. Historical Civil reliability was user-proven; its new-build preservation is deterministic, pending any live regression check. No live paint/benchmark was run by the agent.
