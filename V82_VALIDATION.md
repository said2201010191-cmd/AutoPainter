# v8.2 Live Fix validation

Base `17be81eab4fbd520b2bdbac5c2e390a64c51553b`; build `8.2-live-fix`. See [spec coverage](V82_SPEC_IMPLEMENTATION.md) for all 178 sections and the subsequent NORMAL 120 ms regression instruction.

| Suite/check | Result |
|---|---|
| Existing native controller |222 passed|
| Locked diagnostics |246 passed|
| Existing Hands Free |208 passed|
| Existing v8.2 |106 passed|
| New live-fix cases |64 passed|
| **Total deterministic** |**846 passed**|
| **Repository Luau compilation** |**32/32 passed**|
| Normalized color matcher |Source hash unchanged|
| Proven native cursor mover |Source hash unchanged, retaining prior v8.2 GUI obstruction gate|
| Native palette click/settle/hold sequence |Source guard unchanged|
| Active-runtime forbidden operation guard |No game RPC calls, hooks, signal firing, Mouse.Target assignment, PaintBucketColor write, require or decompile|

Run:

```sh
python3 tests/run_tests.py /path/to/luau
python3 tests/check_luau.py /path/to/luau-compile
```

Reference scripts are preserved; Markdown-wrapped originals are compiled through temporary unwrapped copies only. Test lexical seams never ship in the runtime. Immediate and deferred signals are covered. Existing tests were updated where new requirements explicitly replaced old expectations (250 ms default, automatic SAFE camera movement, rectangular markers, initial START on an incomplete palette); their intended lifecycle/fairness checks remain.

New evidence includes:

- 120 ms initialization/reset/mode/benchmark paths, healthy quick corrections, no global poisoning by unqualified or target-local no-effects.
- More than 100 failed acquisitions with zero CFrame/Focus/CameraType/CameraSubject writes; Civil failures/palette work likewise remain locked.
- Fresh-frame budget and target refresh recovery without camera; proof states, one move per dirty episode, exact four-property restore, rotated/elevated map guard, three-failure breaker, manual camera override, clean/overload suppression.
- Legacy 128-color import/validation, persistent signatures,25 newly constructed palettes with randomized child creation order, all 128 bindings recovered automatically without further clicks or manual Validate. Delayed layout resolves without another index traversal.
- Semantic assignments and capacity survive detach/mismatch/recreation. Duplicate identical discriminators remain ambiguous; START/REROLL cannot partially assign.
- Verified chrome persistence, AUTO close without opener suppression, real global outage blocking, failed-opener suppression until actual state changes, current-color work during outage, generation races.
- Actual-geometry Highlight adornment without province property writes; selection/cleanup regressions remain.
- Both specified native picker paths exercised through explicit GUI input; visible UI changes recorded but no invented generated capacity or paint. Focus cancellation releases and does not arm resume.

Final review additionally repaired an isolated missing swatch being incorrectly treated as a global outage, false reopening after an opener failure with unchanged prerequisites, stale deferred GUI indexing during explicit picker discovery, delayed layout binding, root-versus-swatch visibility diagnostics, and exact CameraSubject restoration. The healthy native paint path remains unchanged except the requested 120 ms default/state reset.

**Not live-proven:** the new camera lock/rendering, automatic 128/128 rebinding, NORMAL long-run reliability and real corrections/sec. Older live evidence belongs to the user. Mock timing cannot predict Roblox server/replication/GUI behavior. Follow the exact NORMAL/Civil/10-minute camera procedures in [ACTIVATION_GUIDE.md](ACTIVATION_GUIDE.md).

**Conditional work not enabled:** arbitrary generated colors, guided RGB field mapping and the complete custom-color province verification adapter. Two real UI candidate paths have explicit inspection/probe controls; their RGB input/confirmation contract is still unverified. A live window was visible, but the desktop interaction did not complete as the app state changed. The script reports UNVERIFIED and exact native shortage, never bypasses this missing capability.

Highlight rendering is subject to Roblox's 255 simultaneous effects limit and spatial camera occupancy is conservatively checked with bounding boxes. Compiler success is not a clean Roblox engine typecheck; standalone analyzer lacks Roblox/executor definitions. Local ColorChanged timing excludes server replication latency; matching paint can also be external and is not a server acknowledgement.
