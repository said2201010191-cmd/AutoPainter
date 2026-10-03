# Public 150 ms NORMAL revision

Base: `9900a73e73aee8a5e703a27e29d4bc75ebc6dedf`.
Build: `8.2-public150`. Export your learned palette and close the older controller before loading. A duplicate loader returns only this build; it refuses an older controller instead of silently keeping the old cadence.

## Evidence and production policy

The authoritative `AutoPainter_ASTRA_ALL_IN_ONE_EVIDENCE_AND_SPEC.md` was read in full, including its per-attempt and reset records. Its SHA-256 is `3b00d596350c64c314a5448ee9c837c7c898f07fde8252fbab398a3e4e11e625`. No raw player/session telemetry is needed in this repository to reproduce the code change.

| Requested interval | Combined public successes | Success rate |
| --- | ---: | ---: |
| 200 ms | 80/80 | 100% |
| 175 ms | 78/80 | 97.5% |
| **150 ms** | **78/80** | **97.5%** |
| 140 ms | 62/80 | 77.5% |
| 130 ms | 43/80 | 53.75% |
| 120 ms | 40/80 | 50% |

Public run 1 completed all 13 rows; public run 2 completed the boundary rows before cohort exhaustion. The private run completed every row at 40/40 but is control evidence only. Its roughly 59 ms result is not production policy. Raw attempt counts and aggregate outcomes in the supplied reports were cross-checked.

`NormalDownSpacingDefault = 0.150` is **requested** spacing, with source `PUBLIC_LIVE_2RUN_150MS_BASELINE`. The public reports observed about **158.33 ms actual** at that setting. The implementation does not force 150 ms actual or promise a universal cooldown. Frame scheduling, activation delivery, acquisition, releases and retries can make actual spacing longer.

- NORMAL still defaults to PER_TARGET, with the existing 120 ms healthy dwell. Cadence wait stays outside native DOWN-to-color dwell learning.
- NORMAL cannot automatically go below the configured public floor, even if stale measured/private state contains a smaller interval. Tool/upgrade invalidation returns to the public policy, not 226 ms or a private recommendation.
- The optional temporary global 175 ms backoff was not added. Existing target-local no-effect recovery/fairness stays unchanged.
- Camera remains LOCKED. Targeting, dirty detection, releases and worker ownership are unchanged.
- Civil bypasses the NORMAL cadence gate. Native palette transactions and timing are unchanged; no 150 ms Civil limiter was added.
- The benchmark still uses all 13 requested intervals and never applies recommendations. Its previously working **reset** cadence retains a 226 ms minimum independently of the new NORMAL default. Measurement/reset/cohort/pause algorithms are unchanged.

## Verification

Run:

```sh
python3 tests/run_tests.py /path/to/luau
python3 tests/check_luau.py /path/to/luau-compile
```

The new tests run with immediate and deferred events. They cover the 150 ms config/report/observed spacing, private suggestions staying diagnostic, stale lower intervals, tool/upgrade reset, mode switching, cadence/dwell separation, target-local misses, pause safety, older-loader refusal, unchanged benchmark reset timing and 128-color rebinding. Existing full-sweep, target replacement, reset, input, fairness, palette and locked diagnostic tests are retained.

`tests/public150_scope.json` records every allowed controller edit against the exact base source hash. The runner reverses those edits and compares the entire controller to the base, protecting Civil, benchmark and other production code from unlisted changes. Existing normalized matcher, cursor and palette click hashes also remain enforced.

**Validation: 1,066/1,066 deterministic tests passed; 36/36 Luau files compiled.** This includes the complete existing 1,036-test suite plus 30 new immediate/deferred public-policy tests. The compiler only strips the preserved original reference's Markdown fence in a temporary copy; repository source material is not rewritten. No live benchmark/paint was performed for this revision.

## Generated application: mandatory feature still blocked

**GeneratedColorCreation=PROVEN. GeneratedColorApplicationViaCurrentNativePath=UNVERIFIED.** No province 129+ has been painted with a generated non-swatch RGB through this revision. Do not interpret the dormant deterministic generator as application support.

The exact OG trace, known native selected-color path, two prior negative UI candidates, new evidence gaps and required supported capability are in [GENERATED_COLOR_APPLICATION_BLOCKER.md](GENERATED_COLOR_APPLICATION_BLOCKER.md). Additional internal application assignments remain disabled until their application route exists. No duplicate swatches or direct protected remote fallback are substituted.

## Next live test: NORMAL combat

No additional cooldown sweep is required before trying NORMAL.

1. Export palette if needed, stop/close the old controller, load this pinned build, and choose the desired color through the normal native PaintBucket palette.
2. Select visible provinces, commit selection, keep NORMAL/PER_TARGET and camera LOCKED. START. Confirm `Build=8.2-public150`, `NormalRequestedDownSpacingMs=150`, `NormalProductionFloorMs=150`, and `NormalCadenceSource=PUBLIC_LIVE_2RUN_150MS_BASELINE`.
3. Have a friend recolor selected provinces for several minutes. Confirm off-cursor dirty marking, eventual clean state, and no input on already-correct/unselected provinces. Pause/focus loss must release input.
4. Send **Copy Activation Report**, including actual DOWN spacing, `SuccessfulPaints`, `VALID_NO_EFFECT`, retry results, corrections/sec, defense latency, queue P50/P90/P99, native DOWN-to-color latency, dwell and release metrics. Longer actual spacing can include legitimate transaction delays; 158.33 ms is previous evidence, not a guaranteed result.
5. Check Civil with existing native assignments, then recreate the native palette GUI and verify 128/128 restoration and stable colors. This revision intentionally does not retune Civil.

The new NORMAL combat rate is **live-unverified**. Previous Civil/benchmark success is user-supplied live evidence; deterministic tests do not prove this revision's live performance. Generated native application remains unimplemented and unverified.
