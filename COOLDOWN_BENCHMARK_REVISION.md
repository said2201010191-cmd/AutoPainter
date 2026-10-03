# Cooldown benchmark-only revision

Based on `e67a01b500adce0ad3bca25dc0176a807bd4809b`. Implements all 18 sections of **AutoPainter_COOLDOWN_BENCHMARK_ONLY_FINAL_FIX_SPEC.md**. This guide supersedes the benchmark instructions in LIVE_FOLLOWUP.md.

## Scope and evidence

Production NORMAL cadence stays at **226 ms**, provisional and **not a proven minimum**. NORMAL/Civil service, dwell, strategy, scheduler, camera, targeting, palette learning/rebinding, generated-color diagnostics, outlines and selection code are unchanged. The test runner hashes the entire production source against the base, excluding only the isolated benchmark and its three diagnostic UI/pause bridges.

Deterministic tests are not a Roblox live validation. No live benchmark or paint was run for this revision. Native DOWN/color observations cannot prove server acceptance or which player caused the change.

## One-start operation

1. Stop AutoPainter. Finish selection and prepare **40 visible protected provinces**. Optional protected reserves let a bad tile be replaced without user action. You can use 30–50 samples through `StartPaintCooldownBenchmark({SamplesPerInterval=30})`; the button defaults to 40.
2. Learn/import and **Validate Native Palette**. Select a verified target color using the native palette. A second, different, live verified swatch is mandatory for automatic reset. Reveal the swatches, or learn/validate the native opener and closer when the palette covers the map.
3. Equip and enable the normal PaintBucket, choose **LOCKED** camera mode, set the desired +100% Paint Speed in-game, close chat/menus and release Mouse1. The raw upgrade value is recorded; the script does not guess how that value maps to a percentage.
4. Press **Paint Cooldown Benchmark** once. A failed preflight opens a scrollable **BENCHMARK NOT READY** message listing missing conditions and fixes. No measured rows/input start on a failed preflight. Visibility is estimated by projection/raycast without moving the cursor/camera; genuine `Mouse.Target` is still required for each actual attempt.
5. Leave mouse, tool and color alone. The worker runs **200, 175, 150, 140, 130, 120, 110, 100, 90, 80, 70, 60, 50 ms**, automatically resetting the same cohort through the native palette and PaintBucket between rows. If the first cohort is already wrong-color, its first reset is unnecessary; otherwise it is reset first.
6. Wait for **COMPLETE**, then press **Copy Cooldown Benchmark**. Clipboard falls back to `AutoPainterCooldownBenchmark.txt`. Copy only exports existing data.

Reset phases also prepare protected reserves (at most twice the requested cohort on initial setup). This permits immediate replacements without palette switches inside the measured segment. A replacement stays in the cohort for later rows. This does **not** require 390–520 different provinces.

## Target failures versus global interruptions

- Acquisition failure, missed/unqualified DOWN, target loss or per-target inspection error: safely release, preserve evidence, quarantine that entry for the run, take a protected reserve. No target-level pause and no immediate retry storm.
- Reset failure: at most two safely released attempts for that entry, then quarantine/replace. Qualified measured no-effects never quarantine targets merely because a faster cadence has poor reliability.
- Insufficient usable/unused protected targets: explicit **PAUSED - COHORT** explains how many additional visible provinces are needed. Add them with the benchmark button, finish selection, Resume. All prior results remain. A genuinely exhausted cohort cannot provide 40 distinct qualified targets without more usable targets.
- Focus/chat/menu, unequipped/disabled/replaced tool, detached native target/reset bindings, or unresolved Mouse1: release and pause globally. Automatically resume after safe stable recovery. Native palette transaction failures retry at a released boundary with a delay; a broken native input API requires restoring support and Resume.
- Escape/STOP is an intentional user pause. Resume continues. **Cancel Benchmark** is the only ordinary `CANCELLED BY USER` path. Closing the controller/diagnostic exception is reported separately.
- In-progress global interruptions retain raw evidence; unfinished observations are never converted to false no-effects. After a global interruption or exceptional mid-row reset, timing starts a new segment—no interval bridges a palette/reset/pause boundary.

Only one diagnostic worker owns cursor/input; it joins the paused production worker before starting. Civil assignments are untouched. Completion restores the previous mode and resumes it only when safe. Cancel restores the previous mode **paused**, without surprise input. Genuine terrain/native palette effects cannot be undone by restoring controller state; cancellation during reset can leave reset color selected, which the final status explains.

## Timing and report

A measured attempt waits only for genuine target acquisition, the requested time since **observed native DOWN**, DOWN acknowledgement and release. It does **not** wait for the target's color before the next target. No catch-up bursts. Color observations have a 600 ms window from observed DOWN and the row drains outstanding windows before reset/classification. Input/frame/release overhead may make actual spacing larger than requested.

Each row exports:

`RequestedMs | Status | RawAttempts | QualifiedAttempts | Successes | VALID_NO_EFFECT | Unqualified | AcquireFailures | SuccessPercentQualified | DOWN-color mean/P90 ms | Actual DOWN-DOWN min/mean/P90/max ms | LateSpacings | CleanSkipped`

The denominator is **qualified attempts**. Raw/unqualified evidence remains visible. A row completes only after its requested qualified sample count. Per-attempt paths include stable entry ID/position, segment, dispatch/native-DOWN/color timestamps, actual spacing, qualification/result/error. Reset attempts, successes, failures, unqualified/acquire failures, palette time, total duration and recent reset records are separate. Quarantined IDs/reasons and pause/recovery history are exported.

After all 13 rows: fastest observed actual-P90 row meeting **100%, 99%, 97.5%, 95%** qualified success; first adjacent crossing below 95% as the observed knee, or “not observed”; a >=99% cadence suggestion. Mixed tool/upgrade rows are excluded from suggestions. Unqualified attempts do not masquerade as no-effects or alter the qualified denominator. Finite 30–50 target samples cannot prove a long-run 99% guarantee. **No result changes production cadence, dwell or strategy.**

## Validation

- **1,036 deterministic tests pass** across immediate/deferred signals, historical/locked builds and the current runtime.
- **35/35 Luau files compile**; Markdown-wrapped references are compiled from extracted bodies without modifying the originals.
- Benchmark suite: 72 tests, including all 13 intervals over exactly the same cohort, all 13 low-reliability rows, one/three acquisition failures, three observed-DOWN target losses, bounded reset failures, protected replacements, release uncertainty, no catch-up, preflight failures, actual UI button paths, auto recovery, qualified denominators and threshold selection.
- All production source outside the explicitly allowed diagnostic bridges matches the base hash.

Still requiring Roblox validation: the complete 13-row unattended sweep; native reset reliability on the user's actual palette/geometry; actual +100% Paint Speed spacing/reliability curve; release/focus/tool recovery under real input delivery. This build is **ready for that live test**, not live-proven.
