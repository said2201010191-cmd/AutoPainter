# AutoPainter behavior and performance review

## Scope and evidence

Reviewed both complete ZIP files and the repository before implementation. The repository initially contained only a two-line README on `main`. The final implementation starts from FastClient's central scheduler, bounded protected requests, selection lookup, and exact remote protocol, and replaces its remaining scheduling/cleanup mechanisms. Both supplied source files are stored unchanged as references. Comments or embedded loader text in the supplied source were treated as material to analyze, not instructions to execute.

This is client-only. The server implementation, game place, and live PaintBucket behavior were not available for instrumentation. The tests execute the actual final source with a mocked Roblox environment; their performance numbers are simulations, not live Roblox measurements. Therefore an absolute fastest setting or numeric live-game speedup cannot honestly be established here.

## Original behavior, traced

| Feature | Original behavior | Final behavior |
|---|---|---|
| Selection | Mouse target must be named `Province`; Add mode allows repeated clicks and creates a clone each time. | Also requires a BasePart inside Workspace; lookup prevents duplicates. Touch selection is supported. |
| Protected storage | Array of Province, Coroutine, Event, Highlight records. Each selection creates a coroutine that merely installs a Stepped callback and exits. | Dense array plus Instance lookup; swap-remove, intrusive FIFO, indexed retry heap. |
| Painting trigger | Each province's Stepped listener checks painting, debounce, prior-second PPS, PaintBucket, and color. | Color changes enqueue dirty work; adding, retargeting, completion, retry expiry, and remote restoration wake the scheduler. |
| Remote | `Character.PaintBucket.Remotes.ServerControls:InvokeServer("PaintPart", {Part = province, Color = desired}, "Peace")`. | Exactly the same path and arguments; cached and refreshed when the hierarchy changes. |
| Normal mode | One yielding callback per province if debounce works; no global cap. | One pending RPC per province, global adaptive window, token bucket, and frame-start budget. |
| Safe mode | Disables the province debounce while InvokeServer runs and then uses legacy `wait(1)`; no global pacing across many provinces. | Fixed total outstanding concurrency 1, globally paced at 4 requests/sec, plus 1 second between same-province attempts. |
| Fast Paint | Leaves debounce open. Every Stepped event can start another request; `wait(3)` occurs inside each overlapping callback and does not impose a shared delay. | Higher bounded rate/window, adaptive tuning, no same-province duplicate spam. |
| Toggle Paint | Button/Q controls new entry into callbacks; cannot cancel an already-sent invocation. | Same pause/resume meaning; pending operations remain accounted for. |
| Keep Territory Color | `savedColor = color` when added. The condition parses as `(province.Color ~= color and not keepTerColor) or (keepTerColor and province.Color ~= savedColor)`. The original precedence is valid, though hard to read. | Explicit target selection, same saved-selected-color semantics. |
| Unprotect | Disconnects matching events and destroys their clones, but never removes their array records. | Removes every selection record, listener, timer and visual. Pending RPC identity remains bounded until it returns. |
| Clear | Disconnects and destroys but leaves the array full of references. Closing the already-ended registration coroutine does not cancel yielded event callbacks. | Clears the registry and ready/retry structures; future work stops for these selections. |
| Country Color | Click a province to copy its Color; selection is handled independently of other mode booleans. | One exclusive selection mode with explicit cancellation. |
| Random color | Button/R selects random integer RGB components and updates the swatch. | Preserved; pending old-target operations cannot race with a newer same-province request. |
| PPS | Counts attempts before InvokeServer; snapshots once per second without correcting for actual elapsed time. If last interval exceeds 1000, the next interval is blocked, creating burst/stall oscillation. | Separate attempts, returns, errors, unconfirmed outcomes, and observed desired-color matches. |
| UI/lifetime | UI can reset on respawn while global listeners/loops continue; per-drag connections accumulate; four sounds, multiple decorative tweens, unbounded clone risks. | ResetOnSpawn false, explicit shutdown, fixed drag listeners, no decorative loops, clone-free selection outlines. |

The original also dereferences `player.Character` without a nil check, assumes both remote containers exist, and does not protect InvokeServer. An exception after disabling debounce can leave a province permanently disabled. Its `Transparency = 1000000` is nonsensical (valid range is 0–1). Clones may retain collision/query behavior and descendants. The outer coroutine serves no useful concurrency role. The packaged original is additionally wrapped in Markdown fences, so the unmodified reference is not directly executable Luau.

## What FastClient already fixed, and what remained

FastClient correctly introduced one Heartbeat scheduler, global 40/80 request bounds, per-province counters, a duplicate-selection lookup, protected InvokeServer execution, nil-safe remote discovery, actual selection removal/clear, valid clone transparency, and non-colliding/non-queryable clones. Its visible counter counts non-throwing returns rather than attempts. It removed the old PPS limiter and obsolete loader advertisement.

Remaining bottlenecks and failure cases:

1. Its reverse scan always starts with the last province. When the window is full, later entries can repeatedly consume capacity before earlier entries are considered. All-correct selections still incur per-frame scans.
2. Fast mode permits three identical outstanding calls per province. There is no evidence that repeating an idempotent same-color operation increases useful paint throughput; it consumes slots, server work, bandwidth, and can reorder old/new colors.
3. It refetches character/tool/folder/remote for every request. No explicit mechanism handles replacement or distinguishes an old generation's late results.
4. It trusts Color immediately after a call returns. A lagging property update can trigger another unnecessary call; non-throwing returns are not proof of a paint.
5. Errors immediately retry without backoff or telemetry. A missing/inaccessible province can waste capacity indefinitely.
6. Safe mode has a per-province interval but can still open dozens of calls globally. Fixed 40/80 limits do not account for latency, server queueing, workload size or observed throughput.
7. Removing a province searches and shifts the array. Cleanup of destroyed entries is delayed by capacity checks and by pausing. Removed-and-re-added provinces can overlap their old in-flight requests because the new record starts at zero.
8. UI/input/Heartbeat connections and the endless PPS loop lack explicit lifetime cleanup; the UI resets on respawn. Clone descendants and repeated drag callbacks remain unnecessary resources.

## Final architecture and tradeoffs

**One event-driven central dispatcher.** The FIFO contains only dirty, eligible selections. Entries hold their own previous/next links, allowing O(1) append, removal, and dequeue without accumulating tombstones or shifting arrays. A map prevents duplicate selection; a dense array supports occasional retarget-all operations and O(1) swap-removal. Swap-removal does not change FIFO fairness.

**Idle work stays idle.** Each selected part has lightweight Color, Name, AncestryChanged, and Destroying listeners. They run only on relevant changes, not once per frame. A persistent Workspace.DescendantRemoving listener also handles destroyed objects whose own deferred callbacks may be disconnected. Correct provinces receive no Heartbeat scans. Only due retries are processed in an indexed min-heap (O(log n) insertion/removal). There is one timer entry at most per selection, with immediate removal on clear. One Heartbeat handles tokens/frame budgets, retry expiry, a bounded watchdog, adaptation, and low-frequency telemetry.

**Bounded cooperative overlap.** InvokeServer yields the calling task, so independent tasks can overlap network waits without parallel Luau execution. A shared worker function is spawned only after both a real slot and a useful distinct province are reserved. There are no tasks waiting for capacity, no one-task-per-frame-per-province loops, and no pool of idle sleeping workers. One coalesced `task.defer` pumps completion/color bursts; `task.spawn` starts each reserved invocation immediately. Creating at most one necessary invocation task per RPC is simpler than a manually resumed worker pool and preserves Roblox task-scheduler behavior. No render/physics callback waits on an RPC. See [RemoteFunction](https://create.roblox.com/docs/reference/engine/classes/RemoteFunction) and [Roblox task scheduling](https://create.roblox.com/docs/scripting/scheduler).

**Completion and observation are separate.** Pending calls remain indexed by Part, independently of selection records. Each request captures its color; changing a selection coalesces to the latest target and waits for the older call to finish. Returns release counters before other processing. A short post-return grace period gives replication time to arrive. A desired-color observation can wake work immediately and cancel a retry timer. An error or a returned-but-unobserved result backs off; a stale response never resurrects a removed entry. The return value is not interpreted as a boolean acknowledgment because the existing server's return contract is unknown.

**Adaptive window with independent pacing.** Every two seconds with sufficient returns and sustained capacity pressure, the controller measures observed paint rate, mean round-trip time, errors, and unconfirmed results. It probes up by roughly 25%, keeping a gain of at least 5% without over 35% latency growth. When a larger window fails to help, it later probes down and accepts a smaller window if at least 97% of throughput is retained without material latency growth. Errors, repeated unconfirmed results with no observations, or a latency/throughput regression reduce the window. A cooldown limits oscillation. Token-bucket and frame budgets bound traffic even with extremely fast/erroring responses. Adaptive samples reset when the desired workload, mode, or resolved remote changes; an ordinary refresh of the same remote does not erase error feedback.

This is a heuristic, not an optimizer with knowledge of Roblox's server queue. A small selection cannot use a large window. A short burst should start promptly instead of waiting for calibration. Changing opponents, targets, or replication timing can distort measurements, which is why adaptation is bounded and can be disabled for A/B comparisons. Concurrency cannot overcome a server-side serial bottleneck or per-player rate limit. Client-side batching here means dispatching several distinct queued requests in one scheduler pass; the server still receives the original individual calls.

**Caching and lifetime.** Services and LocalPlayer are resolved once. Direct child/ancestry/name signals rebuild the equipped Character → PaintBucket → Remotes → ServerControls chain. While unavailable, a twice-per-second fallback also catches objects renamed into the expected path. There are no remote searches per paint. Respawn replaces the cached chain; old requests remain counted until they actually return. UI lifetime cleanup disconnects global and per-selection listeners, destroys outlines, and clears queues. A named client BindableFunction makes repeat loading focus the existing instance instead of creating a second painter.

**No fabricated timeout cancellation.** Stalled calls remain in the hard global cap and same-province gate. Other distinct work can use spare hard capacity in Normal/Fast; Safe Mode retains its one-call total limit even for stalled calls. All 64 permanently stuck calls halt further dispatch; this is necessary to avoid unlimited outstanding operations. Actual server operations cannot be unsent by Clear, pause, local task cancellation, or respawn. The hard bound is per running painter instance; repeatedly destroying and recreating entire clients is not a method of canceling old server work.

## Validation and measured scope

- Official Luau compiler syntax/bytecode validation of the final source.
- Final code review against the official Roblox API definitions for the classes/events/properties used.
- 31 deterministic tests, including both immediate and deferred event delivery, successful nil returns, delayed replication, protected failures, missing/replaced tools and remotes, respawn during requests, rapid color changes, same-province exclusion, FIFO order, pause, destruction, duplicate loading, and zero-latency replies at 15/60/240 FPS.
- Two 100-cycle tests each add 100 selections, remove 50, clear all, and assert that the connection count returns to baseline. A randomized 700-step test checks registration counts, queue/timer bounds, nonnegative accounting, and `Attempted = Returned + Failures + InFlight`.
- A hung-remote simulation reaches 64 outstanding calls, holds there across Clear/re-add, and resumes after responses return. It never opens a second simultaneous request to one province.
- Simulated fixed 350 ms latency: adaptive Fast observed **575** completed target-color matches in 10 simulated seconds versus **432** with Fast fixed at its initial 16-call window. Adaptive reached a 25-call window. This ~33% difference is a test-fixture result, **not a claimed Roblox speedup**.
- Simulated capacity plateau: the adaptive window fell from 16 to 6 while producing **1,618** observations in 42 simulated seconds. This checks that tuning can seek fewer outstanding calls when increasing concurrency stops helping.

Engine rendering, actual touch coordinates, Roblox network serialization, custom server locks/throttles, replication ordering under the real game, and live FPS/PPS are not validated by this mock. Final visual and live-game checks remain necessary in Studio/your private game.

## Suggested live comparison and future speed work

Use the same game/server, number of selected provinces, initial colors, target, device, and connection for each comparison. Compare time until all desired colors are actually visible, observed paint/sec, attempts/observations, RTT, and errors. Run separate tests for initial painting and sustained defense against other players; a client cannot prove paint attribution when multiple players choose the same color.

Try 100–500 distinct provinces and both Normal/Fast for at least 30–60 seconds of sustained demand. Repeat with adaptation disabled and different initial windows. Increase the request ceiling only if the current ceiling is reached without a rising RTT, error rate, or duplicate/unconfirmed ratio. Tune the replication grace from observed late updates. Reducing competing client render work can also help if low FPS is the bottleneck. Consider pooled workers only if a Roblox MicroProfiler capture actually shows task allocation as material at the achieved request rate. Consider controlled duplicate/speculative requests only with evidence that the existing server benefits; the current implementation deliberately does not assume that.

Any further improvement must preserve the existing individual PaintPart API. No server-side batching or redesign is required or proposed as part of this deliverable.
