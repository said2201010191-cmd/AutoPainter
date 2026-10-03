# v8.2 Combat validation

Base: `edcc47081643cf627a9d4e2eeba6eefaa3de577b`; build `8.2-combat`. See [COMBAT_REVISION.md](COMBAT_REVISION.md) for every section of the authoritative live-findings specification, the later isolated cooldown benchmark request, and exact live test procedures.

| Suite / check | Result |
|---|---:|
| Historical native controller |222 passed|
| Locked diagnostics, including custom-color source discovery |252 passed|
| Existing Hands Free regressions |208 passed|
| Existing v8.2 overload / palette / camera / selection |106 passed|
| Existing live-fix regressions |64 passed|
| New combat / guarded hold experiment |52 passed|
| New isolated Paint Cooldown Benchmark |32 passed|
| **Total deterministic tests** |**936 passed**|
| **Every repository Luau file** |**34/34 compiled**|

Commands:

```sh
python3 tests/run_tests.py /path/to/luau
python3 tests/check_luau.py /path/to/luau-compile
```

The compile checker unwraps Markdown fences only in temporary copies of historical reference scripts; original source files remain byte-identical. Compiler success is a syntax/bytecode check, not a Roblox-engine typecheck or a live executor/server guarantee. Source guards preserve the normalized matcher, native cursor mover (existing GUI obstruction check excepted), and native palette click/settle/hold sequence. Forbidden-operation checks reject game RPC calls, target assignment, hooks, signal firing, unverified PaintBucketColor writes, require and decompile in the active Hands Free runtime. The separate locked scanner performs source inspection only.

Changed old expectations are intentional: ADAPTIVE now starts PER_TARGET and runs the requested controlled experiment; NORMAL no longer accumulates per-entry dwell above the healthy baseline from misses; fresh NORMAL attacks clear stale hot delays. Their existing safety, fairness and cleanup scenarios remain.

Immediate and deferred event delivery both pass. New coverage includes fresh/group episode reset; wrong→wrong coalescing; active combat versus stale misses; hard aging; new attacks during UP; successful native retained transfers; no hold benefit/one-shot tool fallback; bounded experiment evidence and per-session decision; post-confirmation reliability loss; STOP/focus/tool/mode loss; duplicate input recovery; real mouse-move release; complete local timing chain; excluded dwell samples; zero locked camera writes; 128-color recreation and stable Civil identity; expanded alternate-UI inventory with private-text omission; dormant deterministic native-excluding colors; shape/drag/dedup; and locked scanner source coverage/failures.

The benchmark suite runs all 13 actual production intervals with 30 distinct targets per interval, asynchronous late colors, external fixture replenishment between intervals, and unchanged color. It proves another DOWN can precede the previous color result. It tests final no-effect classification, no timing-model training, insufficient-target waiting, 30–50 bounds, single-worker Civil pause/restore, every safety interruption, real UI start/copy/cancel wiring, API failure, slow UP and delayed API dispatch versus native DOWN timestamps. Mock external color writes belong only to the test fixture, never the shipped runtime.

**No new live claims:** user-reported earlier NORMAL/Civil performance and palette persistence are accepted historical evidence. This build's sustained corrections/sec, actual hold-and-move effectiveness, input cadence at +100% Paint Speed, queue improvement and rendering behavior require Roblox tests. No live benchmark was run by the agent.

**Conditional feature not enabled:** generated native colors beyond the learned palette. OG arbitrary RGB was applied by direct RPC, and both known Picker candidates were live-rejected by the user. Broader UI and locked source discovery now covers alternate routes, but no actual arbitrary-RGB native writer/confirmation contract is available for end-to-end verification. Generated verified capacity stays 0; exact shortage is reported. A pure dormant generator is not advertised as paint capability.
