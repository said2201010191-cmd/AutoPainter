# Hands Free v7 — correctness before speed

v7 replaces raw Color3 equality, changes palette authority, locks complete target transactions, and fixes release bookkeeping. NORMAL defaults to PER_TARGET. The working projection/cursor/camera algorithms remain; only clean-target guards were inserted in the camera fallback. A hash test verifies the original solver after removing those guard lines.

**Live Roblox correctness/speed remains unverified until the user tests this build.** Mock tests do not establish the game's palette behavior, replication timing or painting throughput.

## Loader and version reset

Close the previous Hands Free panel, then load:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/said2201010191-cmd/AutoPainter/main/AutoPainterHandsFree.luau", true))()
```

v7 refuses to reuse an older controller. All strategy evidence, dwell histories and success counters start fresh. Duplicate v7 loads share the current controller. Each player uses their own LocalPlayer, tool, controls and state. No Studio, place editing, server setup or credentials are required. The repository/file must be publicly readable. Original/reference files, AutoPainterFinal and locked diagnostics remain separate.

## One color definition

Every semantic color comparison uses `colorsMatch(actual, target)`: round each Color3 channel to an RGB byte and allow at most one byte difference per channel. The same matcher governs eligibility, reconciliation, pre-cursor/pre-DOWN skips, palette checks, success recognition, NORMAL and CIVIL WAR. No Color3 object equality remains in the controller.

RawMismatchButNormalizedMatch counts matching comparisons whose original float channels differed; it is not a distinct-province count. ActualRGB, TargetRGB and DeltaRGB explain the normalized result. Civil assignments use actual learned native palette values, normalized to RGB bytes. Near-indistinguishable learned colors are deduplicated with the same matcher.

## Native palette evidence and the remaining setup requirement

The supplied extracts establish that native palette clicks update the tool's cached variable and PaintBucketColor. They do **not** contain the palette GUI paths or complete click-handler/UI hierarchy. This build therefore does not guess button names or equate swatch background color with working paint color.

Civil War now uses a **learned native palette UI route**. It never writes PaintBucketColor or assumes re-equipping resets the LocalScript's cached color. Learning observes a real click on a game GuiButton followed by the native PaintBucketColor change. It records that exact button, selectable RGB and click geometry. During automation, VirtualInput moves/clicks that same control, observes its normal Activated event, verifies the exposed color with colorsMatch, then acquires the province and paints. It does not fire UI signals or invoke a click handler. The internal cached color is only confirmed by the eventual province result; the report labels that distinction.

Civil War stops before painting if the controls are unlearned, there are too few distinct learned colors, a control is hidden/removed/obscured, geometry changed, a native click is not observed, or the palette value does not match. The report states the number of **learned available colors**, not an invented total palette capacity. A dynamic slider/RGB picker using one changing button is unsupported by this fixed-swatch adapter and is reported explicitly. Its exact source/UI contract would be needed for another adapter.

### One-time palette learning per script load

1. Equip the normal PaintBucket and open its native palette manually. Stop automation.
2. Click **Learn native palette colors** in AutoPainter. The main panel hides. Click at least eight distinct native swatch buttons, then **DONE / FINISH SETUP**. The setup label reports learned colors. A click that leaves the attribute unchanged provides no new evidence: select another color and re-click that swatch if necessary.
3. If the palette closes during normal painting, use **Learn palette opener**, click the normal control that opens it, then finish setup. If the palette must close before targeting, use **Learn palette closer** similarly. These buttons are captured from your explicit clicks; AutoPainter does not search-and-click arbitrary UI candidates.
4. Keep the same UI geometry for this run. Relearn controls after layout/viewport changes or recreated tool GUI. Learning prunes invalid old controls. Copy Activation Report includes a read-only inventory of palette-related button paths for diagnosis.
5. Civil War assigns only these actually observed selectable colors. With eight selections it requires eight distinct assignments before starting. Existing assignments remain stable on later recolors. With insufficient learned colors, it stops with the exact shortfall rather than sharing colors or inventing RGB values.

Setup generates no automated paint/input calls. Your own native palette clicks remain ordinary game input. After learning, START handles the palette and target transactions automatically. No manual clicks are needed per province.

## Transaction and scheduling rules

One worker owns cursor, camera, palette and input. ActiveTargetLock covers release, palette preparation, genuine target acquisition, native DOWN, result observation and paired UP. Fresh attacks are considered at the next safe boundary; v7 does not enable optional mid-service preemption. ServicesPreempted remains zero. STOP/focus/tool loss still cancel safely.

Fresh attack priority is granted **only on clean → dirty**. Red → green → orange while the target remains blue is one dirty episode. DirtySince/FreshAttackAt remain unchanged, LastWrongColorChange advances, and wrong-to-wrong changes do not reset retries. Successful screen/world/camera caches survive becoming clean. ColorChanged queues without hover; Mouse.Target is used for acquisition/activation and diagnostic observation, not eligibility.

A reconciliation reads colors every 120 ms and repairs membership. It directly moves no input or camera; repaired dirty work wakes the normal worker. CursorMovesTriggeredByReconciliation is therefore zero by design, and tests verify no input from queue-only repair while paused. Server-to-client replication delay remains unknown without a server timestamp.

Clean checks occur before choosing work, before actual cursor calls, during yielded camera acquisition and immediately before DOWN. A target corrected by another player is skipped. CursorMovesToAlreadyCleanProvince should remain zero. An in-progress native call cannot be made atomic with replication; the metric describes the state at the last check before issuing the call.

ABA sequences without a recognized correction are counted. Repeated same-pair alternation forces a complete PER_TARGET service and adds a bounded retry delay to that target. It does not speed up cursor motion. Genuine success resets the no-success sequence. A valid service still has a bounded maximum, so a contested target cannot own the worker forever.

## Release and success accounting

Exactly one paired UP is sent for each owned DOWN. ReleasesObserved counts release-event confirmation. If Button1Up is delayed/missing, continuously observed unpressed button state for a 60 ms quiet grace establishes the local boundary. A new press resets that grace. No next DOWN starts before ownership resolves. An UP error with a still-pressed state stops and records ReleaseTimeouts; it is not hidden or retried indefinitely. Raw DownEvents/UpEvents include observed PlayerMouse events, including native GUI/physical input, and need not equal owned paint attempts.

Success is a normalized target-color observation associated with valid native activation, not an API return. A correction wakes the owner immediately and ends dwell. PER_TARGET then releases; CONTINUOUS can retain the hold only when enabled after v7 successes. A matching result within one second after a valid released service can be recorded once as SUCCESS_LATE; this is local association, not proof of server causality. A later external match cleans the queue without claiming a paint. LateCorrections makes this distinction visible.

Different Civil intentions yielding the same wrong observed result trigger SuspectedStalePalette and stop further automatic Civil work for diagnosis. The last twenty records preserve intentions, palette evidence and actual outcomes. Contention or delayed replication can also cause unexpected results; suspicion is not a server-side diagnosis.

## Dwell and activation defaults

- Default: PER_TARGET in NORMAL and CIVIL WAR.
- Dwell: 250 ms initially; bounded to 120–350 ms.
- Learning: rolling P90 of up to 24 successful acquired-to-correct times plus 40 ms. Decreases are gradual. A genuine full-window miss can raise the limit; acquisition, palette-preparation and release failures do not train it as a paint timeout.
- Retry: bounded exponential delays; one dirty-to-dirty change does not erase them. A real new clean-to-dirty episode can reset its target's delay.
- VirtualInput.SendMouseButton remains primary. Only real repeated activation failures/unavailability unlock the existing alternate-method recovery, not color mismatches.
- ADAPTIVE remains optional through the top-of-file setting or `SetActivationStrategy("ADAPTIVE")` while stopped. Continuous sampling is gated on at least three recognized PER_TARGET successes in the new session. v6 evidence is never imported.

NORMAL reads the exposed native palette color at START. It does not rewrite it or re-equip per province. Choose and verify the desired color through the normal palette first. Civil War's last palette selection remains the real tool color after STOP; v7 does not perform an unverified attribute restore. Choose a new native palette color before switching to NORMAL if desired.

## Exact NORMAL live test

1. Close the old panel and load v7. Select the intended native palette color and verify one ordinary manual paint.
2. Holster while selecting ten wrong-color provinces and two already-correct provinces. Finish selection, use NORMAL/PER_TARGET, then START.
3. Required: SuccessfulPaints > 0, DirtyCount reaches zero, correct provinces receive no cursor visit, and CursorMovesToAlreadyCleanProvince=0. Inspect actual/target/delta RGB if the result is not recognized.
4. Leave the map clean. With the cursor over A, have a friend recolor protected B. The selection marker is updated by the local color callback before scheduling: dirty is thick red, active is yellow, clean is thin green. Rendering can combine fast updates in one frame; the event log separately proves off-cursor queue receipt.
5. Required: B queues with hover=false, reuses its cached target, and becomes correct. Q/Escape must release. Copy Activation Report.

## Exact CIVIL WAR live test

1. Complete native palette learning above. Select eight provinces, finish selection, switch to CIVIL WAR, START.
2. Before painting, require CivilSelectedCount=8, UniqueAssignedCivilColors=8, DuplicateAssignedCivilColors=0. If this is not met, use the reported setup limitation; do not continue with arbitrary colors.
3. Required: each province matches its own assignment, SuccessfulPaints>=8, DirtyCount=0, CursorMovesToAlreadyCleanProvince=0, AtoBtoASequences approximately zero, and no unresolved release. The assigned and result RGB for each stable entry ID must agree under colorsMatch.
4. Recolor two different protected provinces externally. Both must queue without hover and return to their own original assignments, not the most recently selected global color.
5. If the palette route stops, copy the whole report, including palette inventory and transaction records. Do not interpret attribute equality alone as proof of the native cached color. The exact palette source/UI paths are still useful to replace learning with a game-specific supported adapter.

## Exact combat live test

1. Start from a clean protected set. Have a friend repeatedly recolor different provinces while your pointer is elsewhere. Do not manually aim for the recolored tiles.
2. Check off-cursor dirty records and red/active/clean markers. Wrong-to-wrong changes must retain the original dirty episode and retry schedule.
3. Require bounded complete services rather than endless rapid A-B-A switching. Check ActiveTargetLock, TargetSwitchesPerSecond, AtoBtoASequences, OscillationStops and ServicesPreempted.
4. Compare local event → queue, queue → acquisition and acquisition → normalized correction. The primary defense metric starts at local ColorChanged receipt, not at the remote player's click or unknown server mutation.
5. Run for a comparable 20–30 seconds, Q/Escape, then Copy Activation Report. Also test focus loss, unequip, Clear and closure before unattended use.

## Full Copy Activation Report contents

Copy exports existing observations plus read-only UI inventory. It uses setclipboard, otherwise writes `AutoPainterActivationReport.txt`. It neither starts a test nor clicks a control.

- **Identity and color:** EntryId, position/label (`Entry 14 @ (x,y,z)`), AssignedCivilRGB/key, ActualRGB, TargetRGB, DeltaRGB, RawMismatchButNormalizedMatch; CivilSelectedCount, UniqueAssignedCivilColors, DuplicateAssignedCivilColors, UnassignedCivilColors, learned palette count/status.
- **Dirty evidence:** ColorEventsReceived, DirtyEventsWithoutHover, LocalColorEventReceivedAt, LocalDirtyQueuedAt, LocalColorEventToQueueMs, QueueWasAlreadyDirty, hover/queued flags, DirtySince, LastWrongColorChange, FreshAttackAt; ReconciliationRepairs and CursorMovesTriggeredByReconciliation. Per-entry timestamps are also available from GetTargetStats(part).
- **Clean skips/results:** CleanSkippedBeforeCursor, CleanSkippedBeforeDown, CursorMovesToAlreadyCleanProvince, SuccessfulPaints, FailedValidServices, LateCorrections, Attempts, CompletedServices, AbortedServices, SuccessRate, rolling/overall corrections/sec, AdaptiveDwellMs, Deferred and Stalled.
- **Ownership/thrash:** ActiveTargetLock, TargetSwitches, TargetSwitchesPerSecond, AtoBtoASequences, SamePairOscillations, OscillationDetected, OscillationStops, ServicesPreempted, VirtualInputHold, DownEvents, UpEvents, ReleasesSent, ReleasesObserved, ReleasesConfirmedByButtonState and ReleaseTimeouts.
- **Defense timing:** AverageDefenseResponseMs, MedianDefenseResponseMs, P90DefenseResponseMs, FastestDefenseResponseMs, SlowestDefenseResponseMs, average queue/palette/service durations and per-transaction QueueWaitMs, AcquisitionMs, PalettePreparationMs, ServiceMs, AcquiredToCorrectMs. Median/P90 use the last 64 defense corrections; average/min/max accumulate since load.
- **Targeting:** AverageAcquisitionMs, AverageSwitchMs, cached cursor/camera hits, FullCameraSearches, TargetAcquisitionsPerSecond, CursorAcquireSuccessRate and CameraFallbackRate.
- **Strategy:** configured/active strategy, cached decision/reason, session confirmation, separate PER_TARGET/CONTINUOUS/CIVIL_WAR counters and rolling work-time rates. Attempts are local services, not native RPC counts.
- **Last twenty transactions:** EntryId, Position, IntendedRGB, PaletteAttributeBefore, AttributeAfterSet (`NOT WRITTEN BY AUTOPAINTER`), PaletteAttributeAfter, AttributeAfterEquip, PaletteUISelection, PaletteProof, PreviousIntendedRGB, ActualRGBBefore, ActualRGBAfter, DeltaRGB, NormalizedMatch, MouseTargetCorrect, ActualChanged, all phase timings and Result.
- **Palette diagnostics:** PaletteFailures, SuspectedStalePalette, selected native button paths and a capped read-only inventory of paint/color/palette-related game buttons. Inventory appearance/names alone are not treated as authority to click them.

Counters accumulate since loading. Deferred/Stalled are event counts, not unique provinces. Observed color changes can also be caused by other players. AutoPainterRPCs=0 describes this controller's transport; native requests are neither intercepted nor counted.

## Validation and boundaries

Run `python3 tests/run_tests.py /path/to/luau`.

**572 deterministic tests pass:** 222 legacy native-controller, 246 locked diagnostic and 104 current Hands Free tests (52 scenarios under immediate/deferred events). All **26 Luau files compile**, removing only the original reference's Markdown fence in a temporary compilation copy. The v6 Hands Free tests were revised for the changed palette/strategy/release contract; old raw assumptions are not treated as v7 acceptance tests. Standalone analysis reports only missing Roblox/executor globals/types.

Coverage includes quantized equality, ±1 tolerance, eight distinct learned palette results and restoration, unsupported/insufficient/stale/dynamic/hidden palettes, no attribute writes, clean skips, dirty episodes without hover, reconciliation, target lock, oscillation recovery, immediate/late results, dwell bounds, missed/stuck UP, quiet-state reset, canceled/yielding input, cleanup, bounded records and zero game RPC transport.

No PaintPart call, Mouse.Target assignment, GetMouseData/ClientControls hook, metamethod hook, protected-signal firing, validator replacement, decompilation or moderation concealment is introduced. Native UI Activated connections observe events; they do not invoke the game's handlers. Roblox's exposed VirtualInput restrictions remain intact. References: [VirtualInput](https://create.roblox.com/docs/reference/engine/classes/VirtualInput), [GUI coordinate properties](https://create.roblox.com/docs/reference/engine/classes/GuiBase2d).
