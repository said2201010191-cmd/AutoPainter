# AutoPainter Hands Free v8.2

The user supplied live evidence for v8.1's fast NORMAL and Civil painting. **Nothing in v8.2 is yet live-proven.** Deterministic tests establish controller behavior under simulated input/replication, not Roblox throughput, native input delivery, server timing, or all possible GUI layouts.

## Upgrade and run

1. In v8.1, STOP and **Export Palette Profile** before closing the old panel. In-memory selections must be selected again after loading a new controller; saved semantic palette profiles survive reloads.
2. Run the commit-pinned `AutoPainterHandsFree.luau` loader from the implementation response. The latest-build loader is `LoaderHandsFree.luau`. The repository must be public for anonymous raw loading. No secrets, Studio installation, place editing, or server changes are required. The client environment must expose the native input and loader APIs already confirmed in your client.
3. Equip the normal PaintBucket. Import the existing profile with the native palette available; v1 and v2 profiles are accepted. Use **Validate Native Palette** while stopped to resolve duplicate swatches through native UI clicks. This can change the normal bucket's selected color; choose the intended NORMAL color again afterward. Validation does not start any province service. STOP/Q/Escape cancels it.
4. Choose NORMAL or CIVIL WAR. Protect/Unprotect supports single clicks and holding Mouse1 while moving across real mouse targets. The native bucket is normally unequipped during selection, then restored after DONE and a quiet release boundary. If normal unequip fails, selection refuses to arm and asks you to unequip manually. DONE does not START automation.
5. NORMAL captures the normal palette color at START. Civil uses stable, unique learned colors; **Reroll Civil Colors** changes assignments only while stopped. START is blocked with the exact shortage if selected count exceeds semantic native capacity.
6. Q/Escape/STOP releases owned input. Focus/tool loss pauses input and, **as required by v8.2**, resumes after stable focus and a valid native tool. Explicit STOP, selection, or mode changes cancel pending resume. A changed NORMAL palette color requires explicit restart. Duplicate loads reuse the current v8.2 controller; close older versions first.

All painting remains native: real cursor, real `PlayerMouse.Target`, native `VirtualInput.SendMouseButton`, normal PaintBucket client, real province Color. AutoPainter sends **zero game RPCs** and writes no `PaintBucketColor`. No hooks, direct UI signal firing, target fabrication, or validator changes are present.

## Scheduler and overload

One worker owns target, palette, camera and input. Ordinary scheduling retains cursor-first behavior. Automatic overload samples queue depth, eligible-wait P90, incoming attacks versus corrections, old dirty/no-effect pressure and unusually long active service. Defaults: depth 12, eligible P90 750 ms; exit requires depth at most 4, low eligible wait and 1.5 s quiet, with a 2 s minimum hold. These are tuning parameters near the file top, not promises of a particular server's capacity.

Under overload, each eligible target gets one qualified window, then an entry-local defer: approximately 100, 200, 400, 800, 1250 ms for repeated valid misses. Existing health quarantine applies independently; the longer deadline wins. Repeated qualified misses in a pair/small group get local 650/1250/2000/4000 ms group cooldowns. Healthy work continues; genuine success clears its group's penalty.

A dirty entry occupies one queue slot. Wrong-to-wrong changes update metadata without resetting the episode, retry or fresh priority. Immediate post-correction attacks mark a hot target and impose a 100 ms rotation gap when other work exists.

Overload urgency tiers: eligible wait >=1.5 s, fresh attacks, old dirt with some eligible wait, routine dirt. Hot entries lose a tier except at hard aging. Score within a tier:

`4*min(eligibleSeconds,2) + 2*min(secondsSinceService,2) + 0.1*min(dirtyAge,10) + freshRecency - 0.15*min(failureStreak,5) - hotPenalty(0.5)`.

Scores within 0.25 may prefer the current Civil palette color, then shortest movement. Palette reuse never outranks a more urgent tier; a reuse preference lasts at most four consecutive same-color services. Assignments are unique by default, so this does not enable color reuse. Read-only lookahead examines at most 16 entries once per service; it cannot move input or prepare a palette mid-transaction.

No single worker can guarantee bounded queue latency when attack demand exceeds useful native paint capacity. Backoff/priority reduce waste; they cannot create extra server capacity.

## Queue clocks and dwell

Each transaction exports eligible queue wait, cooldown age, quarantine age (a subset of cooldown), and total dirty-episode age separately. Eligible time excludes cooldown and active service. Service clocks reset at each safe boundary, while total dirty age lasts until clean. Queue samples retain at most 256 per mode, split into FRESH_ATTACK, BOOTSTRAP_DIRTY, BULK_EXISTING_DIRTY, RETRY, TARGET_RECOVERY and DEFERRED_RETRY. Current-set percentile snapshots update at 4 Hz; recent mode/origin percentile reports at 2 Hz.

PER_TARGET remains default. Dwell retains 250 ms startup, 120 ms minimum and 350 ms hard maximum, exiting immediately on normalized success. Shared successful P90 plus 40 ms margin learns from diverse healthy services; at least four distinct entries are required for upward changes, limited to 15 ms per update. Downward recovery is bounded at 40 ms/update. Recovery, camera fallback, overloaded/high-queue and late confirmations are excluded. Qualified no-effects add at most 100 ms **only to that entry**. No acquisition, target-loss, input, focus, release or palette failure trains shared paint dwell.

Result recognition is a locally observed normalized color match, not a server acknowledgment or proof of exclusive causation. A matching transition within the existing one-second late window can become SUCCESS_LATE, canceling dirty retry without training dwell. Server-to-client replication latency remains unknown without a server timestamp.

## Native palette identity and capacity

Semantic identity survives detached/destroyed GUI: index, RGB/key, path segments, class/name/text/image/background signature, parent/container region, sibling/order, normalized geometry and learned click offset. Profile v2 includes this richer metadata. Actual clicks always use current geometry, never imported coordinates.

Each actual root generation builds one index of its own descendants. Structural changes coalesce; unchanged missing controls do not cause repeated full scans. Cached lookups check live identity in constant time. Root absence reports CLOSED and preserves expected semantic capacity. Opener/closer can have their own cached root. If the current selected color already matches, a closed palette need not reopen.

Duplicate exact paths are filtered by signature, then ranked by parent/region, normalized location and sibling/order. Ambiguous bindings remain VERIFY_REQUIRED until a **real native click** yields the expected selected color. At most eight compatible candidates are tried per operation, each with the existing maximum two native click attempts. Candidate failures are exported by name/path; a color's failed verification is cached and cooled down. One unavailable color defers its own target without stopping other Civil work. No ambiguous candidate is declared verified solely from geometry.

**Validate Native Palette** resolves ambiguous controls for the current generation without painting. With the 128-color duplicate-style fixture, the result is 128 bound, zero ambiguous. The actual game's 128 controls still require your live test. Historical semantic knowledge, currently verified/bound controls and temporary absence are shown separately. Imported RGB metadata is not proof that a game's palette still selects that color; actual selection and province results remain the runtime checks.

Selected 137 with 128 semantic unique colors reports shortage 9 and blocks REROLL/START without deleting selections or reusing colors. Semantic absence of a GUI is not permanent loss of native capacity.

## Civil transaction and recovery

The transaction is: lock entry, still-dirty check, native palette preparation if needed, observe selected color, **POST_PALETTE_TARGET_REVALIDATION**, reacquire actual mouse target, clean check, native DOWN, observe normalized province result, native UP, unlock. Native swatch center/top-hit/settle/25–40 ms click timing is preserved from v8.1.

Target loss after palette success keeps the selected color, so the retry skips palette selection when the observed attribute still matches. Repeated geometry loss invalidates cursor, tries alternate surfaces, then clears camera cache and permits safe fallback; continued losses quarantine only that entry. Geometry feasibility is checked before more palette spending for repeatedly failing targets. Exhausted projection budgets wait for a fresh frame instead of being misclassified as off-screen geometry. If mouse target is already correct but the cursor still sits on an interactive GUI, the cursor is moved to the verified map point before DOWN.

## Camera and selection visuals

SAFE is default; optional OFF disables automatic camera movement and AGGRESSIVE broadens only safe searches. Candidates must be finite, above the target/selected province bounding plane with clearance, aim downward, and pass a local occupancy query. Underside ray hits are rejected. Movement/angular cost prefers smaller changes; the last successful pose is cached. Failed poses are blacklisted for the entry/session; after the bounded blacklist fills, camera attempts for that entry stop until a new START instead of recycling known-bad poses.

The user's pre-automation camera is restored after confirmed release, unless an immediately eligible target can reuse the same safe pose. Manual camera input defers automation for 350 ms. Restoration returns the view the user supplied; it is distinct from accepting a new automatic pose. Spatial occupancy is conservative: Roblox's [GetPartBoundsInBox](https://create.roblox.com/docs/reference/engine/classes/WorldRoot#GetPartBoundsInBox) checks bounding boxes, so some hollow/complex geometry may be rejected unnecessarily.

Protected outlines are high contrast, thickness 0.065; dirty 0.10; active 0.115, with fully transparent surfaces so real paint remains readable. Hover gets a separate local adornment. No cloned Parts interfere with raycasts. The outlines toggle is local and persistent through START/STOP.

Drag selection samples only the real current target on Mouse.Move and RenderStepped, with a visited set per stroke. It selects every valid target actually observed; it cannot reconstruct a tile that the engine never reported between input/frame events. No world scans, virtual selection clicks or worker-per-province tasks are created.

## Background work

ColorChanged remains primary and hover-independent. Reconciliation starts at 750 ms, settles at 1.5 s after clean checks and reaches 2 s after 10,000 repair-free checks. A real repair temporarily uses 120 ms for three seconds. It only repairs dirty membership. The perfect-event fixture stays below one tenth of v8.1's 120 ms reconciliation work. Stable palette-generation traversals and rebind attempts remain constant across three simulated minutes with repeated services.

## Game-dependent feature not enabled

Generated custom RGB colors beyond the learned native palette are **not implemented/enabled**: neither supplied game source nor a live client in this environment establishes a legitimate custom-picker input/confirmation route. The controller inventories RGB/HSV/hex/picker/slider candidates within known native palette roots without clicking them and reports them as UNVERIFIED. It does not infer a protocol from a control name. Sections 29–35, 64 and 71 are conditional on this game support; generated capacity stays zero. A readable real picker hierarchy/source plus observed native confirmation would be needed for a separate verified adapter. No arbitrary attribute write or RPC is substituted.

## Exact live acceptance procedure

### Setup and selection

1. Export old profile, close v8.1, load pinned v8.2. Import the 128 colors, open the native palette and press Validate Native Palette. Confirm LearnedSemanticColors=128, BoundNativeColors=128, AmbiguousColors=0. Copy Activation Report if not; it lists missing colors and candidate failures. Choose NORMAL color again after validation.
2. Protect 30 neighboring provinces by one drag, revisit several in the stroke, release/DONE. Confirm immediate outlines, no accidental deselection and no automated paint. Repeat Unprotect. Verify visibility on bright/dark tiles at normal zoom.
3. Keep Camera fallback SAFE. Use Combat HUD ON if desired.

### NORMAL combat

1. Select 50+ provinces with some initially correct. START in NORMAL / PER_TARGET. Confirm clean provinces are not targeted, input releases cleanly, AutoPainterRPCs=0.
2. Have friends attack many provinces, including five repeatedly and three deliberately hard-to-target examples. Confirm off-cursor dirty visuals precede cursor arrival, healthy work continues and cooldown entries do not monopolize service.
3. Compare eligible queue P50/P90/P99 with total dirty/deferred age, not with old combined queue averages. Watch Overload enter and leave after demand drops; healthy acquired-to-color latency and correction rate are the useful comparison.
4. Q/STOP, camera pan/zoom, focus loss/return, tool loss/return. Confirm safe release, stable automatic focus resume, STOP canceling resume, safe camera positions/restoration, no zero-service storm or input duplication.

### Civil native palette and recreation

1. Stop, choose Civil, protect 20–80 provinces (not more than available colors), reroll with a recorded seed. Confirm uniqueness before START. Confirm each result matches its own stable assignment, not merely the last swatch color.
2. Recolor several protected tiles externally with the cursor elsewhere. Confirm their original assigned colors are restored. Temporarily close the palette, recreate its GUI through the normal game lifecycle, and repeat focus/tool changes. Semantic identities must survive; current-generation ambiguous controls verify through native input as needed.
3. Validate Native Palette while stopped after a complete replacement; confirm 128/128 again. Copy Learned Palette produces all mappings through clipboard or `AutoPainterLearnedPalette.txt`; Export Palette Profile saves semantic v2 metadata.
4. Select 137 with native capacity128: verify exact shortage9 and blocked REROLL/START, with selections intact.
5. Run **30–45+ minutes** with multiple painters, repeated palette openings/recreations and focus changes. Compare report snapshots at start, 5, 15 and 30–45 minutes. Dwell must not ratchet from one bad pair; binding passes should track real generations and reconciliation checks remain low. This long live run has not been performed here.

### Copy Activation Report fields to return

Return the entire report (`AutoPainterActivationReport.txt` if clipboard is unavailable). It contains existing activation/input/correction evidence plus:

- OverloadEntries/Exits, TimeInOverloadMs, PeakDirtyCount, PeakAttackRate, PeakQueueAge, FreshAttackRate, RecentCorrectionRate, ValidNoEffectRate, ActiveServiceMs, AttemptsDeferredByOverload, HotTargetsDetected/Rotations, CoalescedDirtyEvents.
- EligibleQueueP50/P90/P99Ms, TotalDirtyAgeP50/P90/P99Ms, DeferredAgeP50/P90/P99Ms, MaxDirtyAgeMs; NORMAL/CIVIL Queue, FreshAttackQueue, BootstrapQueue, BulkExistingQueue, RetryQueue and TargetRecoveryQueue percentiles.
- Each recent TransactionId, Stage, QueueOrigin, DirtyEventToEligibleMs, EligibleToSchedulerPickMs, SchedulerPickToAcquireMs, AcquisitionMs, PalettePreparationMs, PaintMs, ReleaseMs, TotalDefenseResponseMs, result and normalized actual/target colors.
- PathologicalGroupsDetected, GroupCooldowns/Ms, TargetsInPathologicalGroup, HealthyServicesCompletedWhileGroupDeferred, HealthyDwellSampleCount, DistinctDwellTrainingEntries, RejectedDwellSamplesByReason, GlobalDwellBefore/After.
- TargetLostBeforePalette/AfterPalette/BeforeDown, TargetLostRecoveries/Quarantines/EventuallyRecovered and existing per-entry health, cache/input recovery and last20 recovery events.
- LearnedSemanticColors, BoundNativeColors, AmbiguousColors, SemanticKnownCapacity, VerifiedNativeCapacity, CurrentlyBoundLiveControls, ExpectedNativeCapacity, LivePaletteRoot, SelectedCount, Shortage, GeneratedVerifiedCapacity and GeneratedColorSupport.
- CurrentPaletteGeneration, GenerationBindingPasses, LazyColorRebinds, AmbiguousResolutionsSucceeded/Failed, FullGuiScans/Traversals, each color's BindingState/CandidateCount/BindingFailure, region, generation and exact per-candidate failures.
- CameraFallbackAttempts/Successes, UnderMapCandidatesRejected, UnsafeCameraCandidatesRejected, CameraPosesBlacklisted, CameraRestores, ReusedGoodCameraSolutions, UserCameraDeferrals, CameraControlMode.
- ReconciliationChecksPerSecond, RepairsPer10kChecks, CurrentReconciliationInterval, PaletteRebindAttemptsPerSecond, SchedulerSelectionsPerSecond, SelectionStrokeActive/SelectionAdds/SelectionRemoves.

## Validation and limits

Run `python3 tests/run_tests.py /path/to/luau` and `python3 tests/check_luau.py /path/to/luau-compile`.

**782 deterministic tests**: 222 older native-controller, 246 locked diagnostics, 208 existing Hands Free regressions (updated only for explicit v8.2 policies), 106 v8.2 regressions (53 scenarios under immediate and deferred signals). **31 Luau files compiled**, including the original reference via a temporary Markdown-unwrapped copy. Historical original/FastClient/Final/diagnostic files are unchanged.

Source guards preserve the normalized matcher and the native palette click/settle/hold sequence; the cursor mover differs only in the explicit post-palette interactive-GUI gate. Camera and scheduler guards were replaced where v8.2 expressly requires changes. New tests cover workload fairness, group isolation, clock separation, training exclusions/diversity, all128 duplicate-style bindings, 25 recreations, three-minute stable bindings, shortage137/128, closed palette auto-open/skip, focus/tool recovery, target loss after successful palette selection, native input cancellation, camera safety, reconciliation savings and real UI drag paths.

Compilation is syntax/bytecode validation. Standalone `luau-analyze` lacks Roblox/executor definitions and reaches type-inference limits on this controller; it is not a clean Roblox engine typecheck. No live Roblox test was performed. Actual duplicate palette layouts, safe camera behavior and long-run throughput require the procedures above.
