# Hands Free v8 — frozen NORMAL, Civil palette database

**NORMAL live performance was previously verified by the user. Civil War palette automation remains live-unverified until the user tests v8.** Deterministic tests cannot establish GUI behavior, internal tool color, server replication latency, or live corrections/sec.

## Loader

Close the previous panel, then run locally:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/said2201010191-cmd/AutoPainter/main/AutoPainterHandsFree.luau", true))()
```

The file/repository must be public. Each client uses its own LocalPlayer and state. No Studio, place editing, server installation, account-specific identity or credentials are required. v8 rejects an older controller and duplicate v8 loads reuse the existing one. Reference files, AutoPainterFinal and locked diagnostics remain separate.

## Frozen NORMAL baseline

The user reported NORMAL at 293 successful paints, DirtyCount=0, approximately 7.82 ms acquisition, no clean-target cursor moves, no oscillation and no release timeouts. The recent PER_TARGET window was 16/16 successful, approximately 16.15 corrections/sec, 49.5 ms service, 45.4 ms acquired-to-color and a learned 120 ms dwell limit. These are observations from the user's v7 session, not a v8 performance claim.

Seven source regions are hashed against commit `1e0bff91b5d8057c74967585523c839a8a422939`: timing defaults; normalized matcher; activation/release; camera solver; queue/strategy/target lock; service accounting; and dirty/reconciliation/cursor/retry/worker code. Those regions are byte-for-byte unchanged. Hashes live in `tests/normal_v7_baseline_hashes.json` and run with the Hands Free tests. Changes to Civil-only palette functions and reporting/UI are outside those frozen regions.

NORMAL remains PER_TARGET by default. It starts with a 250 ms dwell ceiling and learns within 120–350 ms from the same v7 outcomes. There are no new waits, palette clicks, palette writes or re-equip steps in its service path. CONTINUOUS/ADAPTIVE remain explicit experimental API settings; v8 does not select them automatically under the default.

`NORMAL BASELINE COMPARISON` shows the current rolling PER_TARGET sample next to the user's reference values. Small samples or different contention/server workloads do not prove a regression or improvement.

## Native palette database and learning

The normal game's actual selectable swatches remain authoritative. v8 does not assign arbitrary RGB, write PaintBucketColor, invoke UI handlers, fire protected signals, or assume re-equipping updates a cached LocalScript variable.

1. Equip the normal bucket and open its native palette while automation is stopped.
2. Click **Learn native palette colors**. Click distinct native swatches, then **DONE / FINISH SETUP**. The setup display shows learned count, last color/name, duplicate observations and invalid clicks. A first click that leaves the attribute unchanged supplies no new color evidence: choose another color and return to that swatch.
3. If the palette can close, use **Learn palette opener**, click the game's opener, then finish. Use **Learn palette closer** for the game's closer if its palette blocks the map. These actions record only the controls you explicitly click.
4. Capacity counts distinct, currently valid learned colors. Invalid/deleted rows remain visible in the database report but do not count as usable colors. A dynamic picker that changes the meaning of one button requires another adapter; it is not treated as many swatches.

Mode changes and focus loss preserve the database. The database has a 512-control memory bound; reports print **every stored mapping without an inventory truncation**. A 126-color palette fits completely. Closing/reloading clears memory; profiles can restore mappings.

### Copy Learned Palette

Press **Copy Learned Palette** while stopped. It copies all rows as:

```text
Name | RGB | FullGuiPath
```

If setclipboard is unavailable/denied, the fallback writes `AutoPainterLearnedPalette.txt`. It performs no clicks, paints, scans or learning. **Copy Activation Report** separately includes the expanded uncapped database, assignments and recent palette transactions.

### Export and import profiles

**Export Palette Profile** saves `AutoPainterPaletteProfile.json` when writefile is available; otherwise it copies the JSON. It contains place ID, relative PlayerGui path segments/classes, full diagnostic paths, RGB/key, GUI signature and normalized center coordinates. It contains no code or secrets. Paths resolve under the current player's PlayerGui, not a saved username.

**Import Palette Profile** reads that fixed local file when readfile is available. Alternatively retain the loader's returned API and call `api.ImportPaletteProfile(jsonText)`. Import is allowed only while stopped and outside selection. It checks schema, place, RGB/key consistency, duplicate/near-identical colors, unambiguous current GUI paths and button signatures before replacing the database atomically. Hidden but structurally present controls may import; missing/recreated/different controls require relearning.

Imported coordinates are never replayed. Each automatic use recomputes the current center, checks its top control and verifies the resulting selected color. Import establishes structural correspondence; it cannot read or prove the native LocalScript's cached variable. `CurrentSessionVerified` becomes true after observed use. Profile export/import never executes or requires script content.

## Civil assignments and pools

Select provinces, finish selection, choose CIVIL WAR and press **Reroll Civil Colors** while stopped. START also fills any missing assignments. Colors are shuffled and drawn without replacement from valid learned mappings. Existing assignments persist across corrections and START/STOP. Switching to NORMAL uses only its global target; switching back restores per-entry Civil comparisons.

A blank reroll seed generates and reports a new `CivilRandomSeed`; an integer 1–2147483646 reproduces a reroll with the same ordered palette, ordered selections and pool. Changing a seed or pool does not recolor existing assignments until an explicit reroll. Reroll updates targets/markers but sends no input; START is still required.

Pool choices:

- **ALL LEARNED** (default): random ordering with a best-effort RGB distance floor between selected colors.
- **HIGH CONTRAST:** seeded first color, then farthest-point selection against existing assignments using RGB distance.
- **VIVID:** max channel at least 150 and channel spread at least 90.
- **DARK / LIGHT:** RGB luminance approximation at most 0.35 / at least 0.68.

A filtered shortage falls back to ALL LEARNED and reports that fact. Overall shortage stops before partial assignment; color reuse is disabled. Every selected color is native-learned. The distance heuristic favors distinguishable colors but is not a perceptual/adjacency guarantee. With 126 usable colors, unique capacity is 126 provinces.

## Civil palette transaction

The unchanged single worker/ActiveTargetLock owns palette preparation, acquisition, painting and release. The Civil adapter performs:

1. Compare actual exposed PaintBucketColor with the assigned color. A normalized match skips opening and swatch clicking.
2. If a swatch is hidden, click the learned opener and verify that swatch becomes visible. Never toggle an already-visible palette through its opener.
3. Compute the current button center from AbsolutePosition/AbsoluteSize. Convert inset viewport coordinates to full-window VirtualInput coordinates once. The hit query performs the inverse conversion. Do not replay old learned offsets.
4. Verify the exact top button, move the real cursor, wait one RenderStepped frame, then recheck current geometry, real cursor position and top button. DOWN/UP use a 25 ms legitimate click hold (frame scheduling can lengthen it).
5. Verify normalized PaintBucketColor. Accept `ATTRIBUTE` evidence even if Activated was missed, or `ACTIVATED+ATTRIBUTE` when both are seen. Activated alone does not pass. An already-correct color is reported separately as `ALREADY_CORRECT_ATTRIBUTE`.
6. On failure, resolve the owned UP, check focus/tool/control state, recalculate the center and retry **once**. The retry uses two render frames and a 40 ms hold. Each click has a 160 ms postcondition window. No unbounded click loop exists.
7. Close only if the palette blocks the prospective map point/current target cursor, or **Close palette: REQUIRED** was explicitly selected. The closer must satisfy the visibility/blocking postcondition. `AUTO` avoids unnecessary close/reopen cycles. If a blocking palette lacks a closer, the report asks for it.
8. Return to the frozen genuine-Mouse.Target acquisition and normal PaintBucket paint path. The province result ultimately verifies the working paint color.

Palette step states are IDLE, OPENING, SELECTING, VERIFYING, CLOSING, COMPLETE and FAILED. Opener, swatch and closer failures have distinct messages. Failed transactions stop the Civil run. Focus loss cancels/release-cleans without invalidating the database; focus return shows **RESUME** and requires an explicit click/Q action.

A current-center click outside the viewport or behind another control is refused. Scroll/reveal the native palette if necessary; this version does not blindly scroll unknown UI. Layout/size/inset movement is recomputed. Imported structural/signature changes require relearning.

Coordinate references: [GuiBase2d.AbsolutePosition](https://raw.githubusercontent.com/Roblox/creator-docs/main/content/en-us/reference/engine/classes/GuiBase2d.yaml), [GetGuiObjectsAtPosition](https://raw.githubusercontent.com/Roblox/creator-docs/main/content/en-us/reference/engine/classes/BasePlayerGui.yaml), [VirtualInput](https://create.roblox.com/docs/reference/engine/classes/VirtualInput). The v8 change is confined to native palette UI coordinates; proven province targeting is unchanged.

## NORMAL quality-of-life controls

**Combat HUD** selects a compact running display: dirty count, recent success rate, corrections/sec, median/P90 local response and current target. It changes display only. Q/Escape still stops. NORMAL's target stays captured at START; a manual palette change stops with **NORMAL target color changed — restart required**. After focus loss, **RESUME** is explicit and never sends input merely because focus returned.

## Exact NORMAL regression test

1. Close the old panel, load v8, select the intended native palette color and verify an ordinary manual paint. Use NORMAL with default PER_TARGET.
2. Select ten wrong-color and two already-correct provinces, finish selection and START. Require recognized successes, DirtyCount=0, CursorMovesToAlreadyCleanProvince=0 and ReleaseTimeouts=0. Already-correct tiles must receive no visits.
3. While the pointer is elsewhere, have a friend recolor a protected clean province. Require off-cursor ColorChanged/dirty evidence and cached correction. Repeated wrong-to-wrong changes remain one dirty episode.
4. Run a comparable 20–30-second defense workload, stop and Copy Activation Report. Compare its rolling NORMAL window to the user baseline only after enough matched observations. v8 tests/hash preservation do not establish identical live performance.
5. Change the palette during NORMAL and test focus loss. Both must stop; returning focus alone must send no input.

## Exact Civil palette acceptance test

1. Learn at least 20 swatches (or import your exported profile with its UI present). Use Copy Learned Palette and verify every learned row, including the last one. Learn opener/closer if required.
2. Select 12 provinces, finish selection, choose CIVIL WAR and leave pool at ALL LEARNED. Enter a seed such as `4242` and press **Reroll Civil Colors**. Require Selected=12, UniqueAssignedCivilColors=12, DuplicateAssignedCivilColors=0 and CapacityAvailable=true. Reroll must not move the cursor or paint.
3. Copy the assignments/report before START. Each row must identify a real learned native color, stable entry ID and position. Start with all twelve different from their assigned targets if you want to require twelve successful paints.
4. START. Require each province to reach its assigned color, DirtyCount=0, SuccessfulPaints>0, no palette-preparation failure, no click spam, no release timeout and no repeated oscillation. Check actual assigned/result RGB; attribute equality alone is not proof of the tool's internal cache.
5. Have a friend recolor three protected provinces while the pointer is elsewhere. All three must queue independently of hover and return to their original assignments. No reroll should occur.
6. Stop and Copy Activation Report. If it fails, retain the full failed transaction: step, geometry/cursor/top button, input events, selected RGB, retry and failure reason. Stop on a wrong resulting color rather than repeatedly rerolling away the evidence.
7. Export the profile; reload only after closing the panel, import, and repeat a small three-province test. If import reports a changed GUI, relearn rather than trusting old coordinates.

## Full Copy Activation Report fields

The report exports collected observations and read-only UI mapping data. It never starts input. Clipboard fallback is `AutoPainterActivationReport.txt`.

**Existing NORMAL/engine evidence:** ActivationStrategy, StrategyConfigured, StrategyDecisionCached, StrategyDecisionReason, VirtualInputHold, DownEvents, UpEvents, Attempts, CompletedServices, AbortedServices, SuccessfulPaints, SuccessRate, CorrectionsPerSecond, OverallCorrectionsPerSecond, AverageTargetDwellMs, AdaptiveDwellMs, AverageAcquisitionMs, AverageAcquiredToColorMs, AverageSwitchMs, ActiveTarget, DirtyCount, Deferred, Stalled, CachedCursorHits, CachedCameraHits, FullCameraSearches, TargetAcquisitionsPerSecond, CursorAcquireSuccessRate, CameraFallbackRate, SessionConfirmed, Runtime and AutoPainterRPCs.

**Correctness/release/defense:** RawMismatchButNormalizedMatch, ActualRGB, TargetRGB, DeltaRGB, CleanSkippedBeforeCursor, CleanSkippedBeforeDown, CursorMovesToAlreadyCleanProvince, CursorMovesTriggeredByReconciliation, ReleasesSent, ReleasesObserved, ReleasesConfirmedByButtonState, ReleaseTimeouts, ActiveTargetLock, TargetSwitches, TargetSwitchesPerSecond, AtoBtoASequences, SamePairOscillations, OscillationDetected, OscillationStops, ServicesPreempted, FailedValidServices, PaletteFailures, SuspectedStalePalette and LateCorrections. Average/Median/P90/Fastest/SlowestDefenseResponseMs; average queue/palette/service times. Median/P90 use the latest 64 observed defense corrections.

**Dirty evidence:** ColorEventsReceived, DirtyEventsWithoutHover, AverageColorEventToDirtyQueueMs, MaxColorEventToDirtyQueueMs, ReconciliationFinds, ReconciliationRepairs, ReconciliationChecks, FreshAttackCorrections, AverageAttackColorChangeToCorrectedMs, MinimumAttackResponseMs, MaximumAttackResponseMs, RecentlyChangedQueueDepth and last off-cursor event path/ID, LocalColorEventReceivedAt, LocalDirtyQueuedAt, LocalColorEventToQueueMs, QueueWasAlreadyDirty, Hovered and DirtyQueued. Per-entry API also exposes DirtySince, LastWrongColorChange, FreshAttackAt, LastHoveredTime, LastPaintAttempt and LastCorrectedTime. Server→client replication latency is unknown without a server timestamp.

**LEARNED NATIVE PALETTE COLORS (all rows):** LearnedIndex (numbered row), Name, FullGuiPath, RGB, ColorKey, ButtonVisible, ButtonValid, AbsolutePosition, AbsoluteSize, LearnedClickOffset, LastSuccessfulUse, SuccessfulAutomaticSelections, FailedAutomaticSelections and CurrentSessionVerified. The learned offset is diagnostic only; clicks use the current center.

**Capacity/randomness:** CivilSelectedCount, UniqueAssignedCivilColors, DuplicateAssignedCivilColors, UnassignedCivilColors, LearnedPaletteColors, CivilCapacity, CapacityAvailable, CivilColorPool, ColorPoolFallback, CivilRandomSeed and PaletteStatus. FULL CIVIL ASSIGNMENTS prints EntryId/Position, AssignedColorName, AssignedRGB, LearnedPaletteIndex, PaletteControlPath, LastActualRGB and DIRTY/CLEAN for every selection.

**Palette step/transaction evidence (last 20 transactions):** PaletteStep, EntryId, IntendedRGB, CurrentPaintBucketRGB, PaletteSuccessVia, FinalPaletteRGB, FailureReason, PaletteMs, OpenerAttempted, OpenerActivatedObserved, PaletteBecameVisible, OpenerFailures, CloserAttempts and CloserFailures. Each action includes Role, Retry (0 or 1), TargetControlName, TargetControlPath, TargetControlVisible, TargetControlPosition, CursorPositionBefore, CursorPositionAfter, TopButtonAtClick, VirtualInputMoveSucceeded, MouseDownSent, MouseUpSent, ActivatedObserved, AttributeChangedObserved, FinalPaletteRGB, PaletteSuccessVia and FailureReason.

**Civil performance:** PaletteSelections, PaletteSelectionSuccesses, PaletteSelectionFailures, AveragePaletteSelectionMs, OpenerUses/OpenerFailures, CloserUses/CloserFailures, PaletteSkipsAlreadyCorrect, CivilSuccessfulPaints, CivilCorrectionsPerSecond, AverageCivilServiceMs, AverageCivilDefenseResponseMs, AverageCivilQueueMs, AverageCivilPaletteMs, AverageCivilAcquisitionMs, AverageCivilPaintMs, AverageCivilReleaseBoundaryMs, CivilTimingSampleCount, CivilDefenseSampleCount and ResumeRequired. Civil strategy rates use its rolling work-time sample; phase means use Civil records present in the last 20 total target transactions. ReleaseBoundaryMs is the remaining local post-result/full-window boundary, not a server timestamp. Late confirmations retain the existing late-result flag.

**Last 20 target result records:** EntryId, Position, IntendedRGB, PaletteAttributeBefore, AttributeAfterSet (NOT WRITTEN), PaletteAttributeAfter, AttributeAfterEquip, PaletteUISelection, PaletteProof, PreviousIntendedRGB, ActualRGBBefore, ActualRGBAfter, DeltaRGB, NormalizedMatch, MouseTargetCorrect, ActualChanged, QueueWaitMs, AcquisitionMs, PalettePreparationMs, ServiceMs, AcquiredToCorrectMs and Result. NORMAL BASELINE COMPARISON and separate PER_TARGET/CONTINUOUS/CIVIL_WAR strategy samples are also included.

## Validation

Run `python3 tests/run_tests.py /path/to/luau`. Current regression results: **622 deterministic tests** (222 legacy native controller, 246 locked diagnostic, 154 Hands Free v8). The Hands Free suite runs 77 scenarios with immediate and deferred events, including the existing NORMAL scenarios. Seven frozen code hashes and the older camera hash are checked. All **27 Luau files compile** (the original reference's Markdown fence is removed only in a temporary compilation copy).

Added coverage includes 126-row export, random uniqueness/reproducibility, pools, stable restoration, current-center/inset geometry, 25/40 ms click boundaries, missed Activated with selected-color evidence, failed attribute verification, maximum one retry, opener/closer postconditions, focus cancellation/resume, profile validation, copy/file actions and mode isolation. Profile JSON serialization is mocked; the schema/GUI validation is exercised separately.

No direct game RPC, Mouse.Target assignment, GetMouseData/ClientControls/metamethod hook, validator bypass, protected signal firing or automation concealment is introduced. NORMAL live performance was previously verified by the user. Civil War palette automation remains live-unverified until the user tests v8.
