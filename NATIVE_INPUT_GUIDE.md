# Native-input reliability and performance guide

The user reports a successful native-input live test without a kick. Their game-only scan returned 165/165 script texts with no reported gaps and found equipped/template versions of the same normal PaintBucket paint call, including private-server repeat-on-hold. This revision addresses targeting failure patterns in deterministic mocks; neither the exact problematic live province nor new throughput has been verified here.

## Protocol ownership and color

The controller has no game remote calls, callback replacement, hooks, require, script inspection, fabricated mouse data or calls into native tool functions. The normal PaintBucket alone owns remote discovery, PaintPart, Peace/War, upgrade cooldown, genuine Mouse.Target/Hit and hold repetition. Each player has independent LocalPlayer state.

Choose a color through the normal palette and manually verify it before starting. Auto Paint snapshots exposed `PaintBucketColor` as `DesiredGlobalColor` (white fallback). With Keep Territory Color OFF, all protected provinces use that snapshot. AutoPainter never writes the attribute or asserts that attribute equality proves propagation into the tool's cached variable. An external palette change stops automation; finish choosing and restart explicitly.

Country Color/Pick, R, Randomize and `api.SetColor` change only the preview. `GetColor` returns preview; `GetDesiredColor` returns the actual target snapshot. Keep Territory Color saves the real palette color when each province is added. Saved colors differing from the current palette remain dirty but PALETTE_BLOCKED. No per-target palette rewriting occurs.

Selections remain pending and highlighted until Done / Cancel, which means finish and preserve. Selection pauses input and restores camera without changing the toggle. Escape commits pending selections and stops. Holster while selecting: the normal equipped tool can independently respond to physical clicks; AutoPainter neither suppresses nor intercepts it.

## Single input owner and sticky acquisition

One Heartbeat state machine owns input/camera; a RenderStepped listener only advances frame identity and records frame duration. No per-province loop, input worker, wait-task queue or tween backlog is created. A yielding native input API cannot overlap another owned input call. Stop/remove/close requests latch a release until that call returns. A function that blocks the entire client cannot be interrupted by Luau.

States are `IDLE → AIM_VISIBLE → TARGET_CONFIRM → PRESS → HOLD → RELEASING`. Recovery may enter `CAMERA_MOVE → CAMERA_SETTLE → AIM_AFTER_CAMERA`. Selection decisions cannot replace an active target mid-acquisition or hold. Invalid/removal, desired-color changes, correction, acquisition failure, user intervention and input/lifecycle errors release or abandon it.

Projection and ray hits are only candidate evidence. Down requires the genuine `Mouse.Target` to equal the exact selected immediate child of `workspace.Provinces`, an unobstructed cursor, suitable input state, a live character and equipped enabled PaintBucket. After moving, FAST/ULTRA require a subsequent rendered frame with a matching target. An already correctly aimed singleton can take the direct path without an unnecessary move. NORMAL also requires two matching frames and 0.05 s stability.

Mouse target loss during hold releases input. Down/up observations come from ordinary subscriptions; callbacks are never invoked or replaced. Missing down stops, and missing up blocks further input. Release errors retry at most three times. Cleanup disconnects listeners and clears selection/highlights; unresolved release retains only a manual-up guard that also blocks duplicate loading.

## Bounded geometry and camera recovery

Per-part geometry includes center, top, axis midpoints, corners and a dimension-adaptive top grid, capped at **64 points**. CFrame/Size changes rebuild world positions. The last genuinely successful local point is tried first, then points ordered by local distance, then the rest. Current projection, GUI and ray results are rechecked; cached success never authorizes input by itself.

A center occluder triggers other surface probes. A transient miss receives a settling interval, not an immediate target switch. Budget exhaustion resumes the surface search next frame. Each Heartbeat is capped at **96 projections** (viewport and screen each count) and **32 rays**, shared by active acquisition and next-target precomputation. Cosmetic inactive labels do not block targeting; interactive buttons/text boxes/Active controls and AutoPainter's own window do.

Camera recovery order:

1. Existing view/surface search.
2. Rotate from current position toward the target.
3. Small translation with similar direction.
4. Moderate elevated view.
5. Overhead view.
6. One alternate side angle.

Each moved pose waits its settle time and another rendered frame. Minimum pose intervals prevent rapid alternation. Part X/Z dimensions, aspect and FOV inform framing distance, clamped to 35–1200 studs. A timed-out attempt continues remaining stages on a later retry. Once all stages are exhausted, that camera sequence is not replayed from the same pose until geometry/view changes. Surface acquisition can still recover if an occluder disappears.

Unreachable delays grow exponentially from profile base, capped at **4 s**. Other dirty targets continue during cooldown. A failed singleton keeps its camera stationary between attempts. Failures are recorded separately from no-effect holds. This cannot make geometry targetable when the real cursor cannot hit it; the report identifies evidence for further diagnosis instead of endlessly spinning the camera.

## Scheduling, regions and contention

Color events maintain the dirty array and lookup map. Pending, correct and unprotected parts get no automated selection, projection, ray or input work. Dirty=0 idles. Palette changes/commit explicitly reevaluate once; no full-frame clean scan exists.

One dirty entry uses a direct lock/wake path. Two/three use direct references and lightweight resumable selection. Larger sets inspect only dirty entries, under profile candidate and shared geometry budgets. Pure next-target precomputation during HOLD caches a candidate, surface/visibility and distance without touching cursor/camera. It is revalidated after observed up.

Visible candidates normally prefer the shortest cursor movement. Oldest visible work overrides distance after **4 s**; priority dirty targets receive preference subject to aging. After **8 visible selections**, an aged offscreen target can receive a turn. Offscreen candidates prefer smaller camera angle. Visible Only excludes offscreen work. A **0.35 s** view-residence preference prevents unnecessary immediate regional changes; priority/aged targets can override it. These are fairness mechanisms, not a guaranteed wall-clock service bound when geometry/input is unavailable.

Camera ownership persists across targets and clean idle. Stop, selection, closure, lifecycle/error and explicit camera-off restore the original snapshot only while the same camera is still owned. The controller never moves the character or removes obstacles.

Wrong-color transitions feed a bounded contest score with **20 s** decay. Approximate maximum dwell tiers are base profile, 0.45, 0.7 and 1.0 s; the editable dwell can increase them up to 2 s. Priority multiplies by 1.75, capped at the larger of the configured dwell and 1 s. Dwell is a maximum. With Contest Hold OFF (default), correction releases immediately.

SMART allows only a highly contested singleton to hold through a correction for **0.15 s**, capped by the original hold deadline (configuration hard cap 0.25 s). Repeated flips do not extend that deadline; another dirty target ends the grace. It intentionally permits brief correct-color holding and is optional.

A completed, acknowledged hold with unchanged color records `NoEffectHolds` and backs off only that target by 0.08, 0.15, then 0.30 s. It does not count a server failure: valid native contributions may precede visible ownership/color changes. The same stable camera/point is reused.

## Timing profiles and adaptation

| Setting | ULTRA | FAST (default) | NORMAL |
|---|---:|---:|---:|
| TargetDwell | 0.24 | 0.32 | 0.90 |
| ReleaseGap | 0.025 | 0.05 | 0.15 |
| AimTimeout | 0.80 | 1.05 | 2.40 |
| AimRetry | 0.08 | 0.12 | 0.40 |
| CursorInterval | 0.012 | 0.016 | 0.05 |
| TargetStableSeconds / Frames | 0 / 1 | 0 / 1 | 0.05 / 2 |
| IdleRetry | 0.016 | 0.03 | 0.20 |
| CameraPoseMinInterval | 0.07 | 0.08 | 0.15 |
| CameraSettleSeconds | 0.035 | 0.04 | 0.08 |
| UnreachableRetry | 0.30 | 0.40 | 0.75 |
| MoveVerify (failed move wait) | 0.04 | 0.05 | 0.10 |
| CandidatesPerFrame | 256 | 128 | 64 |

Times are seconds. The acquisition deadlines are longer than the suggested starting values so ordered poses and mode fallback can actually settle. They never impose a minimum wait on success. MoveVerify applies when genuine target acquisition has not occurred; it is not an extra delay on a valid next-frame target. Repeated settled failures gradually raise verification wait to at most 0.12 s.

Observed button-up permits immediate next-target acquisition. The next down separately waits the profile safety gap, measured up-latency estimate and reliability floor. ULTRA's gap stays at least 0.05 s until **eight down/up cycles** have been observed. Missing acknowledgments stop safely rather than silently switching profiles. These input observations do not attest server handling or native-loop completion.

## Coordinate audit and calibration

Roblox's [WorldToViewportPoint](https://create.roblox.com/docs/reference/engine/classes/Camera#WorldToViewportPoint) ignores GUI inset; [WorldToScreenPoint](https://create.roblox.com/docs/reference/engine/classes/Camera#WorldToScreenPoint) accounts for it. [GetMouseLocation](https://create.roblox.com/docs/reference/engine/classes/UserInputService#GetMouseLocation) returns top-left screen pixel coordinates without applying ScreenInsets. Relative movement uses viewport projection minus mouse location, without blindly adding GUI inset. Both projections and inset are captured for comparison.

Executor `mousemoveabs` origin/scale is not established by Roblox documentation. Auto mode tries the preferred exposed mover, then bounded alternatives: relative, absolute viewport, absolute GUI-adjusted screen. It remembers the successful absolute convention and prefers the mode with the better genuine-target success rate, then acquisition time. It never treats a non-error API return as successful acquisition, and it does not try unbounded offsets or fake target data. A desktop-origin/DPI convention beyond these candidates remains a possible live limitation.

Explicit **CALIBRATE INPUT (cursor only)** requires an unlocked/focused client, equipped bucket and chosen visible committed test target. It compares exposed modes/variants with zero down/up calls. **TEST NATIVE INPUT** is separate and explicitly holds the real native button; the normal tool may paint. Neither runs automatically. Reports include ProjectedViewportPoint, ProjectedScreenPoint, ActualMouseLocation, GuiInset, MoveMode and RealMouseTarget. Changing explicit mover selection invalidates the input test.

## Telemetry, failure reports and UI

`GetPerformanceStats()` exposes correction/hold/no-effect/acquisition/failure/camera/switch/ray/projection/cache counters; unreachable count; per-mode successes; current state/target/pose/candidate/retry; observed input latency; effective gap; and mean/P95 acquire, hold, release, switch and dead-time metrics.

- Acquire: target lock to down attempt.
- Hold: down attempt to release request.
- Release: release request to frame acknowledging up.
- Switch: observed previous up to next down.
- DeadTime: previous hold end to next down, including release and next acquisition. Intentional clean-idle and paused time is excluded.
- SuccessfulCorrections: desired-color transitions observed during an owned exact-target hold. Another player/server action may cause them; this is not causal/server-success attribution.
- Corrections/s: rolling five-second observed corrections. Native RPC counts/latency remain unobserved.

Means cover the session; P95 uses the last **128 samples**, sorted only on report/API access. UI updates at 4 Hz without that sorting. Call **Reset Benchmark** after the native test and before a comparable run. Test/acquisition counters otherwise include explicit testing activity. Runtime counts Auto Paint ON, including natural idle/waits; metrics are local observations.

Failure history is capped at **20** value snapshots/strings, with no Instance references retained in history. **Copy Target Failure Report** exports paths, geometry, camera, stage, candidate, ray hit, real mouse target, both coordinate spaces, GUI blocking and attempt duration. **Copy Benchmark Report** exports the compact session summary. Clipboard falls back to `AutoPainterTargetFailures.txt` / `AutoPainterBenchmark.txt`; copy triggers no input. `GetTargetStats(part)`, `GetMovementStats()`, `GetTargetFailureReport()` and `GetBenchmarkReport()` expose the same information programmatically.

Title bars drag and clamp to viewport. Collapse/expand remembers session position; Snap Left/Right places the panel at an edge. The HUD shows Auto, Protected, Dirty, current target, corrections/s and STOP. Drag/menu input suspends automation until release, and never becomes AutoPainter province-selection input. Q toggles; Escape stops even if UI consumed the key.

## Remaining limits and validation

AutoPainterRPCs=0 is enforced structurally; it does not mean the native tool sends no requests. Native hold repetition may exist only in private servers. No public-server per-cooldown click fallback is added.

Observed up plus a gap cannot prove an outstanding native InvokeServer has returned. The native holding flag/sameMouse lifetime around a yielding call could permit an old loop to resume after a later down. The controller cannot attest or change that without more native/server evidence. A successful input test does not guarantee no kick; no moderation control is installed. Leave the cursor alone during automation: real user movement can race a native repeat before the controller observes it.

**468 tests pass: 222 native and 246 locked-diagnostic tests; all 20 repository Luau files compile.** Native cases run under immediate and deferred signals, including yielding input functions, delayed target propagation, unreachable/reachable combinations, transient rays, occluded centers, wide/thin/edge geometry, coordinate fallback, 1–3-target paths, bounded work, fairness, contest grace, cleanup, respawn and zero direct RPCs. Mocks do not reproduce every engine geometry, executor or native server timing behavior. Follow the [README live procedure](README.md#live-test-procedure), especially on the originally failing province.
