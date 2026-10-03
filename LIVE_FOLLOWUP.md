# Hands Free v8.2 — Cadence Follow-up (2026-10-03)

Build `8.2-followup`, based on `main` commit `79a6de16a29ac1fecce8b90910b7962a66ab9474`. Implements the authoritative **AutoPainter_Astra_COMPLETE_LIVE_FOLLOWUP_v2_2026-10-03.md**. This guide supersedes earlier defaults, benchmark interruption/reset instructions, and generated-color wording.

**Evidence boundaries:** the two NORMAL combat runs, Civil's 359/361 results, 128/128 persistence and the 40/40 cooldown row were reported by the user. This revision has deterministic tests and source review, not a new Roblox live test. Native color observations do not prove server acceptance or which player caused a color change. No new live speed/reliability claim is made.

## NORMAL: cadence is separate from dwell

- **PER_TARGET is the default.** The unsuccessful live CONTINUOUS result is incorporated. No automatic hold experiment runs on START, mode switch, respawn or a new tool session. The old bounded `ADAPTIVE`/`CONTINUOUS` experiment remains an explicit stopped-only API option for genuinely new evidence.
- Healthy target dwell still starts at **120 ms**. Matching color ends service immediately. Qualified no-effects stay target-local; acquisition, target loss, input conflict and interrupted services do not train longer dwell.
- A distinct **native DOWN-spacing gate** controls the next NORMAL press. Initial minimum: **226 ms**, the supplied 200-ms benchmark row's **225.02 ms observed P90**, rounded upward. This is a provisional reliable-control setting derived from the only completed live row, **not a discovered minimum or a guarantee under combat**. It intentionally prioritizes observed corrections over click frequency.
- A successful full benchmark sweep can lower or raise that gate to the fastest qualifying row's **measured P90 actual native spacing**, rounded upward. It never treats a requested label as delivered cadence. Qualification requires a complete row, 30+ attempts, at least 98% observed success, no unqualified/clean-skipped samples, enough uninterrupted spacing samples, and unchanged tool/upgrade context. With 40 attempts, 98% requires 40/40. This small sample remains evidence for further live testing, not statistical certification.
- Cadence and dwell are independent: waiting before DOWN does **not** train dwell. NORMAL dwell learns native DOWN→color latency. Acquired→color, acquired→DOWN, spacing wait, qualified service and release are reported separately. Successful service and release retain their existing immediate paths. The configured spacing is in-memory, resets on script reload, and reverts to the provisional control when the exposed upgrade value or equipped-tool session changes.
- Fresh attack priority, episode identity, stale entry/group penalty clearing, wrong→wrong coalescing, target-local retry, hard aging, recovery and one worker remain. The gate never generates input while the target becomes clean, focus/tool is lost, or STOP is pressed. It does not alter the game's cooldown or produce game RPCs.
- **Camera remains LOCKED.** Targeting/projection code is not redesigned. Civil palette timing is not shortened and Civil presses do not use the NORMAL cadence gate.

Useful tunable: `CFG.NormalDownSpacingDefault`. Do not lower it on the assumption that the old 120 ms dwell was a reliable click interval. Use the full benchmark's actual spacing and then a matched combat run.

## Resumable, solo Paint Cooldown Benchmark

Explicitly press **Paint Cooldown Benchmark**. It pauses and joins the production worker, then owns the same genuine target/native VirtualInput path exclusively. It never runs on load. Default: **40 protected provinces**; `StartPaintCooldownBenchmark({SamplesPerInterval=30})` accepts 30–50.

Intervals remain **200, 175, 150, 140, 130, 120, 110, 100, 90, 80, 70, 60, 50 ms**. In a measured interval the native palette color is unchanged. Each distinct province gets a bounded DOWN/UP attempt after genuine `Mouse.Target` acquisition. The next attempt does **not** wait for that province's color confirmation. Existing Color signals observe results asynchronously for 600 ms after each attempt; there is also a 600 ms settle period after each interval. No catch-up bursts or overlapping input owners are created.

**Solo reset is ON by default.** The benchmark reuses its same cohort between intervals:

1. Select a second **already verified learned native swatch**, using the unchanged native palette click/confirmation flow.
2. Repaint cohort provinces that do not already match that reset color, through native input, and wait for locally observed reset color. Reset presses use a conservative cadence.
3. Select the original measured color through the native palette.
4. Run the next interval automatically.

Reset palette clicks, reset paints and measured attempts have separate evidence/counters. None trains production dwell/strategy or adds production successful paints. Existing Civil colors/control assignments never change. Native palette verification and bindings learned during legitimate input are retained. The ordinary dirty engine necessarily observes genuine reset color events; those events are not claimed as production corrections.

If the original color cannot be reselected from a verified swatch, or no second verified color exists, the benchmark says exactly why and waits for **manual reset**. There is no 60-second expiry. Recolor enough cohort provinces externally through the normal game, return the native palette to the displayed target color, and press Resume. If too few protected provinces exist, press **ADD BENCHMARK PROVINCES** while paused, finish selection and Resume. A removed cohort member can be replaced with another protected province. A valid cohort is not silently replaced by a different set between intervals.

States: **SETUP**, **RUNNING TEST**, **RESETTING**, **WAITING FOR DIRTY**, **PAUSED - FOCUS**, **PAUSED - TOOL**, **PAUSED - TARGET**, **COMPLETE**, **CANCELLED BY USER**.

- **Escape/Q/STOP pauses**, releases input and retains the coroutine, completed rows, partial row and per-attempt timestamps. Use the large **RESUME BENCHMARK** button.
- Focus/chat/menu or tool loss releases immediately and pauses. Returning to a valid focused/equipped/unpressed state resumes after the existing 350 ms focus-stability check. A prior manual pause is not overridden by focus return.
- One acquisition/input failure is recorded **UNQUALIFIED**, released and skipped. The next target continues after a short recovery. Three consecutive unqualified samples require explicit Resume; they cannot create an endless input loop. Errors during target inspection or reset preparation are also retained as recoverable pauses.
- A benchmark target-color change pauses with the required original RGB. Restore it using the native palette, then Resume. Mode changes and camera automation are blocked during the benchmark.
- A changed tool/upgrade invalidates that row for production cadence calibration; its evidence is retained. Spacing statistics exclude cross-pause segments and reset input. Input API dispatch and observed Mouse.Button1Down times remain distinct.
- **Cancel Benchmark** permanently ends this run, releases input, restores the previous mode/configuration and leaves it **paused**. The newest Escape/Cancel semantics supersede the older automatic-restart-on-cancel behavior. No extra palette clicks are sent after Cancel. If canceled during reset, the report warns to choose the original color before a NORMAL START.
- **Completion** restores the prior mode/running state when safe. A prior stopped state remains stopped. A prior Civil run resumes its original assignments. Palette/terrain effects from genuine benchmark painting cannot be undone by restoring controller state.
- Closing/unloading the entire controller ends its work and cleanup; it cannot preserve in-memory results across a reload. Copy before closing. Unrecoverable setup/program errors retain a stopped report rather than retrying a broken controller indefinitely.

**Copy Current Benchmark** / **Copy Cooldown Benchmark** only export collected data via clipboard, or `AutoPainterCooldownBenchmark.txt`. They never start a scan or paint. Row fields: requested interval, state, attempts, observed successes, VALID_NO_EFFECT, unqualified/pending, success%, DOWN→color mean/P90, native spacing min/mean/P90/max, late spacing count, acquisition failures, clean skips. The report includes raw upgrade, per-attempt IDs/positions/dispatch/native DOWN/color times, segment, pause reasons/history, reset totals/palette time, and a measured cadence candidate. “VALID_NO_EFFECT” means no target color observed within the local window; it does not assert a server rejection.

APIs: `StartPaintCooldownBenchmark(options)`, `PausePaintCooldownBenchmark()`, `ResumePaintCooldownBenchmark()`, `CancelPaintCooldownBenchmark()`, `GetPaintCooldownBenchmarkState()`, `GetPaintCooldownBenchmarkReport()`, `CopyPaintCooldownBenchmark()`. Optional `AutoReset=false` explicitly selects manual reset.

## Exact live procedure

1. Export the learned palette, close the previous controller, load this revision's pinned loader. Import the profile and check **128 semantic/128 bound** after any necessary native palette opening. Set **+100% Paint Speed in the game**; the raw upgrade report does not independently establish that boost.
2. Choose a verified native target color and manually verify the normal bucket paints it. Protect **30–40 visible provinces**, then finish selection. Keep camera LOCKED. Learn/retain at least two verified native swatches, including the measured color. Run alone without competing recolors during the sweep.
3. Start **Paint Cooldown Benchmark**. Let all 13 intervals run; the same cohort should reset natively between rows. Do not manipulate cursor, tool or palette during an active phase. A reset costs additional time/paints; progress explicitly says RESETTING.
4. To interrupt, press Escape. Check Mouse1 released and evidence remains; press **RESUME BENCHMARK** to continue. Focus/tool interruptions should recover without destroying the run. For WAITING FOR DIRTY, follow the displayed shortfall/reset instructions. Cancel only if you want to end the run.
5. Copy the entire report. Compare **actual** spacing and observed success. A requested 50 ms row delivered at 100 ms is only 100 ms evidence. A color observation after native DOWN still does not establish server causality.
6. Check `NormalCadenceSource` and `NormalMinimumDownSpacingMs` after completion. Run NORMAL with the same speed/tool/server and repeated external attacks for several minutes. Copy Activation Report. Compare matched workloads using rolling success, successful CPS, VALID_NO_EFFECT and queue percentiles—not cursor speed.
7. Civil has sufficient historical live evidence. A short preservation check is enough unless a regression appears: switch while stopped, verify original Civil assignments and native palette restoration; recreate PaletteGui and confirm 128/128 rebinding without reroll/relearning.

Send **Copy Current Benchmark** plus **Copy Activation Report** after that NORMAL run. Especially retain:

- `NormalMinimumDownSpacingMs`, `NormalCadenceSource`, `NormalCadenceCalibratedContext`, `NormalCadenceToolGeneration`; Normal/Civil `ActualDownSpacingMinMs`, `MeanMs`, `P90Ms`, `MaxMs`.
- Rolling PER_TARGET attempts/successes/CPS; effective/global dwell, `VALID_NO_EFFECT` rate, qualified paint time, release and palette timings.
- Last 20 transactions: `NativeDownSpacingMs`, `CadenceWaitMs`, `TargetAcquiredAt`, `NativeDownSentAt`, `NativeDownObservedAt`, `CorrectionObservedAt`, `AcquiredToNativeDownMs`, `NativeDownToCorrectionMs`, `ReleaseMs`.
- Fresh/overall/retry/recovery queue P50/P90/P99, overload duration/peak attack rate, episode/fresh penalty resets, input/release recovery, `CameraMovesApplied=0`, clean-target skips, off-cursor event records.

All queue/detection clocks start at local observation; server→client replication latency remains unknown.

## Generated color correction and OG trace

**GeneratedColorCreation=PROVEN. GeneratedColorApplicationViaCurrentNativePath=UNVERIFIED.** The 128 swatches are the currently verified **application capacity**, not the number of RGB colors that can be generated. For 186 protected provinces: 128 verified native, **58 generated additional required**. Capacity warnings appear once. Legacy `GeneratedVerifiedCapacity=0` remains for API compatibility and means zero *verified extra application slots*; it is always accompanied by the two explicit capability fields.

Source investigation, against the preserved repository references:

| Source | Exact path from UI/generator to color |
|---|---|
| `AutoPainterOriginal.luau:412–424` | Randomize click / R builds arbitrary `Color3.fromRGB(math.random(0,255), ...)`, stores the local `color`, updates its own Country Color button background and plays the color sound. No native palette click, PaintBucket state writer or protection-outline recolor occurs here. Original protection uses a target clone at lines 296–306; changing the Randomize preview is not a native tool-color update. |
| `AutoPainterOriginal.luau:121–151` | Painting captures `savedColor` per province. The selected global/saved color goes directly in the old PaintPart payload. The native bucket's cached palette variable is not updated by this path. |
| `CivilWarOldLoader.luau:79–103` | `nextUniqueColor(current)` uses golden-ratio hue stepping, randomized saturation/value, rounded RGB deduplication, and RGB distance >=0.18 from the current province; then random RGB fallback. Creation beyond 128 is fully present. |
| `CivilWarOldLoader.luau:266–304` | Add province calls the generator, stores `entry.target` and sets the SelectionBox's Color3 to that assignment. Its Color callback queues mismatches. Civil's generator is invoked on selection; it is not the original Randomize button handler. |
| `CivilWarOldLoader.luau:322–347` | The generated exact RGB is delivered by the old direct `remote:InvokeServer("PaintPart", {Part=entry.part, Color=entry.target}, "Peace")`. This is the transport that applied it; an outline alone is only a preview. |
| User's normal PaintBucket source | Normal palette selection writes a selected BrickColor.Color to PaintBucketColor; genuine Mouse.Button1Down supplies Mouse.Target. The provided source/report does not establish an arbitrary-RGB editor/writer through native input. |
| User's two live Picker tests | PaintSGui.Picker and ColorTitle.ColorPicker did not expose a new editor or selected-color change. These are rejected specific candidates, not proof that all possible RGB routes are absent. |

The old remote path was **not executed against the current game**, because it is expressly excluded from this native-input revision and previously caused first-request moderation failures. Its present live acceptance is unknown. Source tracing and the user's old visual results establish generation and the old transport; they do not establish a working modern native custom-color path.

The existing **Inspect custom UI** still searches all PlayerGui color/RGB/HSV/hex/palette controls, including hidden controls and unrelated GUI roots. The separate LOCKED diagnostic's Game-Only Full Scan includes **10. NATIVE CUSTOM-COLOR WRITERS / UI PATHS**, with source context and coverage/read failures. This goes beyond the two rejected controls. No new live source dump or current arbitrary-RGB writer was available in this workspace, so no end-to-end current native route was verified in this revision. Send those sections if a different native control/workflow is found; no source execution/hooking or remote transport is added.

`GetDormantGeneratedColorPreview(count, seed, currentColors?)` preserves OG-style bounded, reproducible generation while stopped. It excludes normalized duplicates/native swatches and optionally rejects colors near each current province. It assigns nothing, writes no game property and sends no input. Native unique Civil assignment/reroll remains stable and refuses silent reuse when capacity is insufficient. The conditional 129+ application/assignment/outline feature remains disabled until a legitimate native UI→selected color→native paint→matching province path is proven.

## Specification coverage

| Sections | Result |
|---|---|
| 0–8, 19 live findings | Incorporated as evidence, without treating queue speed or native DOWN observations as guaranteed paint acceptance; no targeting redesign or forced hold trial. |
| 9 NORMAL direction | Existing queue/fresh/retry protections retained; independent native cadence, observed-spacing report/calibration, no dwell poisoning. |
| 10 control row | 40/40 at actual 208–225 ms retained as provisional control; not described as minimum. |
| 11 benchmark redesign | All listed phases, solo reset/manual fallback, pause/Resume, recoverable sample handling, completed/partial evidence and actual-spacing sweep implemented. |
| 12–14 generated colors | Creation/application statuses corrected, OG end-to-end source trace and dormant generator present; 129+ application conditional on unavailable native proof. |
| 15–16 Civil/focus | Native palette sequence/source guards and rebinding retained; benchmark focus/chat/tool interruptions recover without discarding rows. |
| 17 reporting | Existing timing/queue/Civil telemetry retained; observed cadence and reset/paused benchmark evidence added. |
| 18–21 delivery/boundaries | Deterministic tests/compiler checks, repository commit and pinned loader; no protected RPC, spoof, hooks, native-state injection or evasion. |

See [V82_VALIDATION.md](V82_VALIDATION.md) for exact test/compile counts. **NORMAL pacing and arbitrary-RGB application are not live-proven by this implementation.** The fastest reliable cadence still requires the user's completed sweep and sustained combat comparison.
