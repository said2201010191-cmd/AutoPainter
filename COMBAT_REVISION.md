# Hands Free v8.2 Combat

Build `8.2-combat`, based on main `edcc47081643cf627a9d4e2eeba6eefaa3de577b`. Implements **AutoPainter_v8.2_Full_Live_Findings_For_Astra.md**, plus the subsequent isolated **Paint Cooldown Benchmark** request. This document supersedes older default/penalty descriptions in the historical guides.

The existing PaintBucket remains the only game paint sender. No game RPC, target/callback spoofing, signal firing, source execution, hook or moderation workaround was added. Normalized matching, native cursor movement and the proven native palette click sequence are source-guarded. Camera movement defaults **LOCKED**.

**Previous NORMAL/Civil results were live-reported by the user. This revision's recovery, hold strategy, benchmark cadence and performance remain live-unverified.** Local color observations are not server acknowledgments and cannot identify who recolored a province. The target of 5–6+ sustained corrections/sec is not a claimed result.

## NORMAL recovery and controlled hold experiment

- Shared dwell initializes/resets to **120 ms**. NORMAL qualified misses no longer accumulate extra dwell; acquisition/recovery/interruption/no-effect/overload samples never train shared timing. Only diverse healthy success samples may raise it. Civil retains its existing separate history and transaction timing.
- A genuine clean→dirty episode clears old NORMAL entry penalties and group membership immediately. Old group records carry episode IDs, so they cannot re-quarantine a newly attacked episode. An attack during the previous transaction's UP boundary keeps its own fresh queue clock.
- Wrong→wrong changes remain one dirty episode. Recent local wrong-color activity suppresses pathological-group classification and escalating no-effect quarantine; a qualified miss rotates with a short retry. Repeated stale failures without new color activity retain bounded backoff. Acquisition/input failures remain independently protected.
- Fresh attacks beat ordinary retries; eligible-age protection still gives older work turns. No fresh event interrupts an active transaction. One worker owns input and palette.
- Default setting **ADAPTIVE starts with PER_TARGET**. After at least four qualified baseline attempts, three successes, confirmed native DOWN+color and two dirty targets, it performs a bounded CONTINUOUS trial. The trial's maximum window is **240 ms**, solely to give held native painting a chance; it does not change the shared 120 ms default or the game's cooldown.
- Trial bound: eight qualified attempts or eight seconds. Promotion requires successful corrections on at least two distinct transferred targets under the **same observed native DOWN**, at least 80% success, comparable reliability to PER_TARGET, and more than 10% measured work-throughput improvement. Singleton presses/API return times do not count as held-transfer proof.
- Two qualified no-effects, input/target uncertainty, insufficient evidence, no measured advantage, or later degraded held reliability falls back to PER_TARGET. The decision is cached per equipped-tool session. Explicit `CONTINUOUS` also uses this guarded experiment; it cannot force unproven holding. `PER_TARGET` opts out entirely.
- Release occurs on STOP, focus/tool loss, mode changes, unsafe real cursor target, recovery, or empty dirty work. A real mouse-move signal now releases immediately if the cursor leaves protected/game-valid targets or enters an interactive GUI. No new DOWN overlaps unresolved UP.

Set a control strategy while stopped through the returned API:

```lua
local painter = loadstring(game:HttpGet("COMMIT_PINNED_RAW_URL", true))()
painter.SetActivationStrategy("PER_TARGET") -- control run
-- Or ADAPTIVE for the guarded A/B experiment. Choose before START.
```

## Paint Cooldown Benchmark — explicit diagnostic only

Press **Paint Cooldown Benchmark** in the stopped panel or beneath the running HUD. It pauses/joins the normal worker before obtaining input ownership. It does not automatically run on load/START. Default sample size is **40 distinct dirty protected provinces per interval**. API `StartPaintCooldownBenchmark({SamplesPerInterval=30})` accepts integers 30–50.

Requested DOWN-to-DOWN intervals, in order:

**200, 175, 150, 140, 130, 120, 110, 100, 90, 80, 70, 60, 50 ms.**

The diagnostic captures the current native palette color once and uses it throughout, with no palette switching or attribute writes. It temporarily uses NORMAL target comparisons and LOCKED camera; Civil assignments remain unchanged. Each attempt acquires a genuine protected `Mouse.Target`, sends the existing VirtualInput DOWN, observes the native DOWN, holds briefly (20 ms minimum), and confirms native UP before the next attempt. It does **not** wait for color confirmation to schedule the next attempt. Existing province Color callbacks collect outcomes asynchronously, including after the cursor leaves that province.

Each next DOWN has a deadline relative to the previous **observed native DOWN**. Acquisition, release confirmation, frame quantization or delayed API delivery can make actual spacing longer. There are no catch-up bursts. Reports separate API dispatch time, observed native DOWN time, actual native spacing, and DOWN→color latency. A 600 ms settle period follows each interval. `VALID_NO_EFFECT` means qualified native input with no observed normalized target color by that observation boundary, not server rejection. Partial/canceled/unqualified attempts do not become false valid misses. No benchmark sample trains the normal dwell or strategy model.

There must be enough **actually dirty** provinces for every interval. With 40 samples, the full run needs 520 target services: select enough unused dirty provinces, or have a friend externally recolor a batch between intervals. The same province may be reused in a later interval only if dirty again; it is never reused within one interval. The benchmark never recolors terrain just to create a fixture and never paints clean targets. It displays the exact shortfall and waits up to 60 seconds; a shortfall produces an incomplete report rather than silently reducing sample size. Avoid competing recolors during each measured interval because they confound color attribution.

**Cancel Benchmark** restores the previous mode/running state after releasing input, where still safe. Normal completion does the same. If originally stopped, it remains stopped. STOP/Q/Escape, focus/tool loss, changed palette color, close or unresolved release leaves it safely paused; these actions never cause a surprise restart. Actual paints performed during a benchmark cannot be undone. Palette learning, assignments, selections and strategy histories persist. After restoring Civil, its scheduler can restore provinces to their original Civil colors.

**Copy Cooldown Benchmark / Copy Current Benchmark** exports collected evidence only, through clipboard or `AutoPainterCooldownBenchmark.txt`; it never starts painting. API: `CancelPaintCooldownBenchmark()`, `GetPaintCooldownBenchmarkState()`, `GetPaintCooldownBenchmarkReport()`, `CopyPaintCooldownBenchmark()`.

### Exact live benchmark procedure

1. Export your palette, close the old panel, load the new pinned build. Set **+100% Paint Speed in the game**; the report captures the exposed `EquippedPaintCooldown` value but cannot interpret that as proof of +100%.
2. Choose one color through the normal palette and manually verify the native bucket paints that color. Select at least 40 visible wrong-color provinces. Keep Camera LOCKED. Arrange enough unused targets or external resets between intervals.
3. Press **Paint Cooldown Benchmark**. Do not move the mouse or change the palette during a sample. It shows the interval, number of DOWNs and any dirty-target shortfall. You may cancel at any time.
4. Complete the 13 intervals if enough dirty work exists. Copy the report. Compare **success percentage and actual native spacing**, not the requested label alone. A 50 ms row delivered at 80 ms is evidence for 80 ms, not 50 ms.
5. Send the entire report, including per-attempt timestamps and raw upgrade value. The benchmark makes no automatic production timing change; live evidence determines the next policy.

## Civil behavior preserved

Native swatch click, current center/top-button verification, settle/hold timing, attribute postcondition and sequential target transaction are unchanged. Same-color work still skips palette clicks; a bounded same-color preference cannot defeat fresher/aged work. Existing read-only next-target lookahead now carries the semantic palette control and is reconsidered at the next safe scheduling boundary; it never moves input or changes a palette in parallel.

The 128 semantic mappings, native verification and stable Civil assignments survive detached GUI generations/rebinding. Focus/tool interruption affects the current transaction, not learned identity. Outline Highlights follow the actual province; drag selection and deduplication remain intact.

## Generated colors: investigation and precise limit

| Evidence examined | What it establishes / limitation |
|---|---|
| `CivilWarOldLoader.luau` | OG golden-ratio HSV/random RGB generator produced unique values, then supplied them directly to `ServerControls:InvokeServer("PaintPart", ...)`. It did not expose a native RGB palette writer. This reference is preserved and never executed by Hands Free. |
| Original AutoPainter color logic | Arbitrary selected HSV values were carried in direct paint payloads; not proof the normal tool accepts arbitrary palette colors. |
| User's extracted normal client flow | Selected BrickColor is written to PaintBucketColor by the native palette; genuine mouse input supplies the paint target. No provided excerpt establishes an arbitrary RGB writer. |
| Both user-tested Picker controls | `PaintSGui.Picker` and `ColorTitle.ColorPicker` are recorded as **rejected** arbitrary-RGB candidates. Successful input with no selected-color/new editor change is not capability proof. Old explicit probe controls remain for new evidence only. |
| Current visible Roblox UI, read-only screenshot | The live native swatch palette and ongoing client were visible. No exposed arbitrary RGB editor was established. This is partial visual coverage, not an exhaustive source search or a live paint test. No live input/paint benchmark was run by the agent. |
| Expanded current-client inspection implemented | **Inspect custom UI** traverses all current PlayerGui roots, including alternate settings/tint/color/hex/RGB/HSV containers and hidden controls, not just the two Picker paths. Non-color free text is omitted. It is explicit, read-only and outside the painting hot path. |
| Expanded locked source collector implemented | Game-only readable/decompiled client scripts now include `10. NATIVE CUSTOM-COLOR WRITERS / UI PATHS`: RGB/HSV/hex conversions, custom-color controls, TextBox/FocusLost/slider/hue/saturation and PaintBucketColor writers, with merged source context. Existing watchdog/cache/cancel/coverage failure reporting remains. No source is executed/required. |

The actual newly collected complete game-source/GUI reports are **not available in the workspace**, and desktop inspection does not expose LocalScript closure/source contents. The expanded collector must run in the user's client and its report must be returned before another native RGB route can be proven. This revision does not claim the game has no such route; it has **no verified route**.

The OG-style deterministic generator is retained as **dormant, pure diagnostic helper** `GetDormantGeneratedColorPreview(count, seed)`, stopped-only, bounded to 512 colors. It excludes learned/previous generated colors using the normalized matcher, assigns nothing, changes no game properties and creates no input. Generated capacity remains **0**. With 128 verified native colors, 129 provinces correctly reports a shortage of 1 and cannot START unique Civil. No color reuse, invented custom writer, or direct-RPC fallback is enabled.

To investigate further, run the separate locked `AutoPainterDiagnostics.luau` build, choose Game-Only Full Scan and Copy Current Report, then send section 10 plus read failures/coverage. Also send the expanded Custom UI Report. Only an observed native UI → intended PaintBucketColor → normal bucket input → matching province result can enable generated colors beyond native capacity. This conditional adapter is the sole specification functionality not enabled.

## Remaining live tests and report fields

**NORMAL:** choose a native color, protect 20–50 visible provinces, START ADAPTIVE and run sustained external recoloring for several minutes. Confirm corrected entries become fresh immediately on the next wrong color, repeated wrong→wrong events coalesce, healthy dwell starts at 120 ms, stale bad targets defer while other work continues, and camera writes remain zero. Verify hold trial attempts are nonzero when prerequisites exist; it must either show same-DOWN multi-target proof and a measured win or fall back. Repeat a matched workload with PER_TARGET for a control. Test STOP/focus loss while held.

**Civil:** import/validate the known 128-color profile, select 20+ provinces, reroll once and START. Check each distinct assignment is restored after external recolors. Recreate native PaletteGui and confirm learned/verified/bound counts return to 128/128, assignments unchanged, no new palette failures, no native click spam or camera movement. Capacity >128 remains blocked truthfully.

**Selection:** while stopped, drag across a mix of provinces repeatedly; verify shaped outlines, unique registration, remove/clear and no AutoPainter DOWNs during selection.

Copy Activation Report includes both strategy windows and:
- `ActivationStrategySetting`, actual `ActivationStrategy`, `NativeHoldExperimentState`, `NativeHoldProbeAttempts`, `NativeHoldObservedAttempts`, `NativeHoldMultiTargetProof`, `NativeHoldTransferredSuccesses`, `NativeHoldRetainedMisses`, `NativeHoldFallbackReason`.
- `FreshPenaltyResets`, `FreshGroupClears`, `ActiveCombatMisses`, `StaleMisses`, `CoalescedCombatChanges`, effective per-service window, global dwell, queue-origin percentiles, eligible/deferred/quarantine age.
- Per-service `DirtyEpisode`, `ExternalColorEventAt`, `EligibleAt`, `SchedulerPickedAt`, `TargetAcquiredAt`, `NativeDownSentAt`, `NativeDownObservedAt`, `CorrectionObservedAt`, retained-hold ID, acquired→DOWN and DOWN→correction times.
- Existing palette generation/binding/capacity, camera, release/recovery, clean-target, oscillation, actual-color and defense-response fields.

All clocks begin with local events. Server→client replication latency and server causal attribution remain unknown.

## Authoritative specification coverage

| Section | Implementation / evidence |
|---|---|
| 1 NORMAL bottleneck | No camera redesign; recovery/miss/queue changes above; no claimed live CPS result. |
| 2A A/B CONTINUOUS | Controlled observed hold transfer trial, per-session selection/fallback, plus the separate user-requested fixed-cadence benchmark. |
| 2B–C fresh combat / pathology | Episode IDs, fresh penalty/group reset, wrong-color activity classification, stale backoff retained. |
| 2D cheaper misses | No NORMAL accumulated miss dwell; 120 ms base, qualified deadline, immediate success exit; new cadence report measures earliest reliable input externally. |
| 2E–G scheduling / telemetry / goal | Fresh priority with hard aging, one worker, coalescing, exact local timing chain; live target remains unverified. |
| 3 camera | LOCKED default; zero-write tests across successes/failures and benchmark. |
| 4–5 Civil | Proven click sequence unchanged; same-color fast path, event postconditions, bounded preference and read-only control lookahead preserved. |
| 6 generated colors | Broader UI/source discovery + OG comparison + dormant generator implemented. Native custom-color adapter conditional/unverified; 128/0 capacity honest. |
| 7 persistence | Existing full verification, safe rebind and interruption tests retained, additional 128-color recreation/assignment test. |
| 8 outlines / selection | Shape Highlight, real drag path, dedup/remove/clear tests retained. |
| 9 priorities | Changes concentrated on NORMAL recovery, experiment and diagnostics; no native transport replacement. |
| 10 tests | Full deterministic suite and every Luau file checked; details in V82_VALIDATION. |
| 11 delivery | Source/docs/tests committed together; pinned loader in release response. |
| 12 existing evidence | User's reported Civil/camera/palette evidence accepted; rejected Picker controls are not relabeled supported. |
