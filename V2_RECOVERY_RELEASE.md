# Hands Free v8.2 V2 Recovery

Build `8.2-v2-recovery`, based on main `b4ef5e7a1ba246297d69fa044c2fd65a0c2144d6`.
The supplied **FINAL V2 EVERYTHING INCLUDED** master overrides the older appended specifications. All 36,197 lines were consumed for the evidence audit, including all 14 complete report blocks. Local audit SHA-256 and block inventory are retained with the development artifacts; the private raw reports are not republished.

## NORMAL: production B

The supplied paired **A B C C B A** live report is the decision evidence:

| Phase | Qualified successes | VALID_NO_EFFECT | Useful corrections/sec | Mean actual DOWN spacing |
|---|---:|---:|---:|---:|
| A1, retained equipped session | 22/40 | 18 | 3.2992 | 168.6 ms |
| B2, genuine re-equip | 39/40 | 1 | 5.4097 | 181.0 ms |
| C3, native same-swatch click | 39/40 | — | 4.1717 | 234.2 ms |
| C4, native same-swatch click | 40/40 | — | 4.6243 | 215.4 ms |
| B5, genuine re-equip | 39/40 | 0 | 5.4224 | 180.4 ms |
| A6, retained equipped session | 35/40 | 5 | 4.9827 | 175.6 ms |

These are **user-supplied previous-build live results**, not a new run by this agent. B is now the default production path: resolve UP, genuine unequip, one native heartbeat boundary, genuine equip, verify fresh native GUI/working-color echoes, acquire real target, native DOWN, observe actual province color, native UP. Ordinary B never writes the color attribute. The requested/observed-DOWN floor remains 150 ms and healthy NORMAL dwell remains 120 ms. No universal 200 ms floor, new cadence controller, or Civil delay was added. A and C remain explicit control choices, and the existing A/B and 13-row cooldown diagnostics remain available.

The inspected native client scopes its last-paint clock to `Equipped` and updates it after the native remote returns. This supports the lifecycle hypothesis; neither those client lines nor the A/B report prove every server acceptance rule. Fresh multiplayer production-B combat remains required.

## Civil target-loss storm: established defects and remaining uncertainty

The 19:53 report has 681 pre-palette and 129 post-palette losses in a **110-native-color cohort**, alongside 807 target-loss quarantines. Generated RGB does not explain this particular collapse. The report lacks the viewport, GUI, raycast and cursor evidence needed to identify its original live trigger conclusively.

Code-level amplification defects found and addressed:

- A failed `visiblePoint` pre-palette check discarded its budget-exhaustion return and immediately produced TARGET_LOST. Budget exhaustion now yields/retries as `PROJECTION_BUDGET`, without target penalties or dwell training.
- A genuinely offscreen, occluded or GUI-obscured province entered the same retry/quarantine machinery as a broken target. These cases now have visibility deferrals, retaining dirty state and assignments without accumulating failure streaks. No palette/paint input is spent on those entries while blocked.
- Failures were only correlated per province. A bounded 24-outcome/2-second window now detects four distinct failing entries, or at least three distinct entries with a majority of losses in six or more samples.
- Global failure used to multiply into independent quarantines. Recovery now releases input, blocks paint DOWNs, refreshes all selected cursor/surface/camera caches once, rereads geometry/ancestry/current camera/viewport, and rotates through bounded no-paint probe acquisitions with the camera untouched.
- Two genuine acquisitions are required before resuming. They may be separate acquisitions of the same remaining healthy dirty target, avoiding a deadlock when all other entries are unacquirable. Known individual probe failures are isolated within the same camera context instead of retriggering global recovery indefinitely. Success or a new context removes that exemption.

No fixed wait is added to healthy services. Visibility/recovery rechecks are 500 ms only while affected; release ownership remains mandatory. If no real targets can be acquired, the UI reports `GLOBAL_TARGETING_RECOVERY` and waits safely. Clear the obstructing GUI or expose the selected map with ordinary controls; the recovery code never moves the camera. STOP, focus/tool loss and destruction still release input. One worker owns both recovery and normal service; there are no new workers per province.

New report fields: `TargetLossStormEntries`, `TargetLossStorms`, `TargetLossStormActive`, `GlobalTargetingState`, `GlobalTargetCacheInvalidations`, `GlobalTargetRecoveryAttempts`, `GlobalTargetRecoverySuccesses`, `OffscreenDeferredCount`, `TargetMismatchCount`, `StaleProjectionCount`, `GeometryReparentCount`, `ProjectionBudgetDeferrals`, `TargetContextGeneration`.

The last 40 acquisition audits include EntryId, stage, expected and actual target/ancestor paths, alive state, fresh projected point, initial cached/fresh candidate, actual cursor, viewport, camera pose/generation, province CFrame/size/parent, native palette visibility, top GUI object, classification and storm state. Storage is bounded; aggregate counters preserve totals. These local observations are not server-validation evidence.

## Overlay correction and fallback

The old `.99`-transparent proxy/model path failed live. This revision uses **opaque, original-color geometry clones** and AlwaysOnTop grouped Highlights, avoiding reliance on Highlight rendering of nearly transparent coincident geometry. All proxies retain province shape; remain local, anchored, non-queryable, non-collidable, non-touchable, and shadowless; and track source geometry/color without writing or reparenting game provinces.

For the first **192 selected provinces**, a direct Highlight adorns the **real province** as the ordinary-count fallback. At most 40 state/shard Highlights cover all proxies, plus those 192 direct fallbacks (232 controller Highlights, excluding the selection hover). The fallback also works structurally when a source part cannot be cloned. OFF destroys both render paths and listeners; ON rebuilds from selected state. Removal/clear releases them and maintains fallback coverage after swap removal.

The engine documents a finite simultaneous Highlight budget; local accounting cannot measure available GPU budget or prove pixels are visible. See [Roblox Highlight reference](https://create.roblox.com/docs/reference/engine/classes/Highlight). The new `AttachedProxyProvinceCount`, `DirectFallbackCount` and `RendererResourceCount` report attachments only. The misleading `VisualizedProvinceCount` field is removed. This build's direct fallback and scalable path both require live confirmation. No maximum visibly rendered count is claimed.

## Randomize Color and source labels

While stopped in NORMAL, press **Randomize Color** (palette panel, scroll down) or **R**. Learn/import and validate 128 native colors first, so the controller can prove the chosen RGB is outside that set. Selection uses the bounded OKLab pool, also separating it from the previous random RGB. The chip shows exact RGB and `RANDOM GENERATED`; inspection/report use native palette index `NONE`/0.

Randomize only stages the color and rebuilds dirty comparisons: **no input, tool changes, attribute writes or paints happen on the button press**. START applies it under the existing exclusive transaction: release, unequip, write native `PaintBucketColor` while unequipped, equip, verify native working-color echoes, acquire genuine target, activate native input. Subsequent production-B services preserve that RGB. The random assignment is stable until another Randomize or a manual native color change; Civil switches preserve the saved NORMAL random color and stage its reload on return.

`RandomColorExactProvinceResults` increments once per qualified native service only after its observed province RGB exactly matches the generated target; the color-event snapshot survives a reattack during UP. Attribute/GUI echoes alone do not count. Fields also include `RandomColorActive`, `RandomColorRGB`, `RandomColorSource`, `RandomColorNativePaletteIndex`, `RandomColorClosestNativeRGB`, `RandomColorDistanceToNative`, `RandomColorGeneration`, `RandomColorPending`, `RandomColorPreparationFailures`, `RandomColorProof`.

Civil generated labels now explicitly show `Source: GENERATED`, `GEN #nnn`, exact RGB, and no native palette index, including the running HUD. The game's own approximate BrickColor-style label is left alone.

## Generated-color quality

The native-first/generated-overflow assignment and Civil generated application transport are preserved. Refinement starts from the **exact old 1,536-candidate seeded greedy result**, searches up to 3,072 candidates, and attempts at most 32 weakest-point exchanges. A swap cannot lower either the minimum distance to native colors or the minimum between generated colors. Exact/shared-normalized RGB collisions remain forbidden; lightness stays in the existing 0.25–0.91 range. Generation occurs on assignment/reroll/randomize, outside painting.

Fixed seed **135094411**, same exported native 128, fresh cohort of 273 / generated 145:

| OKLab Euclidean ×100 | Old result | Refined result |
|---|---:|---:|
| Minimum to native | 5.004854 | 5.222758 |
| Minimum between generated | 5.004538 | 5.237494 |
| P10 nearest distance | 5.099231 | 5.289077 |
| P50 nearest distance | 5.573385 | 5.642013 |

21 exchanges were accepted. Improvements in the two minima are **4.35% and 4.65%**, below the aspirational 10–15%; no minimum was lowered and no extreme-lightness expansion was used. Local CLI wall-clock samples for a complete seeded reroll were approximately **302 ms before / 1,535 ms after**. These are development-machine timings, not Roblox frame or live input timings. The mock scheduler's fake clock reports zero generation milliseconds; the wall-clock measurement is separate.

The supplied live snapshot has minima 5.072589/5.070353. A fresh reproducible 273-assignment run of the unchanged old source yields 5.004854/5.004538 (same first generated colors); it is the paired algorithm baseline used above. Do not conflate the live snapshot's assignment history with a fresh seeded reroll.

## Deterministic validation and scope

Full suite: **1,242 tests passed**, including **60 new V2 tests**. **42/42 Luau files compiled** (reference wrappers are stripped only into compiler temp files; original references remain unchanged).

Coverage includes production B with native equip reader/echo/result, missing reader/focus aborts, cross-entry NORMAL/Civil collapse and recovery, persistent failed probes without DOWNs, mixed cohorts and one remaining healthy target, offscreen/GUI unblock, projection-budget exclusion, bounded audit/cleanup, random button/R/native-swatch exit/exact results, generated 145 native-input results in the mock, and 1/10/62/256/500/900 attachment/OFF–ON tests. Historical tests also cover 1,000 attachments, all 13 benchmark intervals, palette recreation, release/resync, fairness and no-direct-RPC rules.

Historical timing/control suites explicitly select the retained **A control** to keep testing those algorithms; the new V2 suite runs the unmodified **production-B default**. No tests were deleted. Tests expecting quarantine storms were changed to require their prevention; the mixed-failure scenario allows the bounded probe-recovery interval. Exact reverse-scope snapshots preserve historical freezes. Generated Civil preparation, native palette click timing, and cursor acquisition retain their exact source hashes.

## Required live tests (not performed by this build)

1. Export your learned palette and close the previous controller. Load the pinned revision; import/revalidate the profile. Confirm build `8.2-v2-recovery`, production **B**, camera **LOCKED**.
2. **Overlay first:** while stopped select 1, 10, 62. Verify both outline and fill physically. If these fail, send screenshot + Activation Report before stress. Then test 256, 500 and 900+, OFF → ON, remove/add and clear. Attached counts are not visible proof.
3. **NORMAL:** select 20–60 visible provinces, choose native color, START. Fight 4–5 players for several minutes. Send useful CPS, successful/no-effect counts, actual DOWN spacing, healthy dwell, queue percentiles and recovery audits. Stop opponents and verify Dirty=0.
4. **Civil sustained defense:** use the existing 128-color profile and first test 110 native assignments (matching the failing report). Fight for **at least 15–20 minutes**; capture early and late reports. GUI obstruction/offscreen entries should be classified without quarantine growth; a multi-entry genuine target mismatch must stop paint input, refresh once, probe, and recover when real targets are acquirable. It must not repeat hundreds of independent 1,000 ms quarantines. Then repeat with 273 / 145 generated assignments and verify stable colors and 128/128 rebinding after GUI recreation.
5. **Random NORMAL:** STOP, press Randomize, record exact RGB/source/native distance. Check no painting occurs until START. Paint a real selected province; require exact generated RGB absent from the native 128 and `RandomColorExactProvinceResults>0`. Recolor it externally and verify restoration. Select a native swatch while stopped and confirm the random source clears.
6. Return **Copy Activation Report** after the long Civil test, plus visible overlay screenshots and the random RGB result. The report includes global target-health audits, NORMAL B/actual timings, random proof, generated distances, binding capacity and renderer attachment counts.

Long-run NORMAL/Civil recovery, this overlay revision's pixels, and Randomize's actual Roblox application remain **live-unverified until the user tests them**. The exact trigger of the old collapse remains unknown without the new acquisition evidence. No direct protected game RPCs, target/hit spoofing, hooks, validator/moderation workarounds, new server installation or secrets were introduced. `AutoPainterRPCs=0` and the existing native input/tool path remain the boundary.
