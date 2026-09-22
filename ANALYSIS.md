# AutoPainter behavior and performance review

**Latest live status:** the user reports that the first Safe-mode PaintPart request causes a moderation disconnect. Previous modeled throughput/correctness results do not establish protocol validity. The latest inventory names normal tool LocalScripts, but their source has not yet been supplied; no rate limits or protocol fields were guessed/changed. See [PROTOCOL_DIAGNOSIS.md](PROTOCOL_DIAGNOSIS.md) for the investigation and new default-on, zero-request diagnostic mode. The live issue is unresolved.

## Scope and evidence

Reviewed both complete ZIP files and the repository before implementation. The repository initially contained only a two-line README on `main`. The final implementation starts from FastClient's central scheduler, bounded protected requests, selection lookup, and exact remote protocol, and replaces its remaining scheduling/cleanup mechanisms. Both supplied source files are stored unchanged as references. Comments or embedded loader text in the supplied source were treated as material to analyze, not instructions to execute.

This is client-only. The server implementation, game place, and live PaintBucket behavior were not available for instrumentation. The tests execute the actual final source with a mocked Roblox environment; their performance numbers are simulations, not live Roblox measurements. Therefore an absolute fastest setting or numeric live-game speedup cannot honestly be established here.

## Original behavior, traced

| Feature | Original behavior | Final behavior |
|---|---|---|
| Selection | Mouse target must be named `Province`; Add mode allows repeated clicks and creates a clone each time. | Also requires a BasePart inside Workspace; lookup prevents duplicates. Pending selection has highlights only until Done/Escape. Touch follows the same transaction. |
| Protected storage | Array of Province, Coroutine, Event, Highlight records. Each selection creates a coroutine that merely installs a Stepped callback and exits. | Dense array plus Instance lookup; swap-remove, intrusive FIFO, indexed retry heap. |
| Painting trigger | Each province's Stepped listener checks painting, debounce, prior-second PPS, PaintBucket, and color. | Only committed selections can enter the FIFO. Color changes, commit, retargeting, completion, retry expiry and remote restoration can wake eligible work. Selection tools suspend dispatch; adding alone never wakes it. |
| Remote | `Character.PaintBucket.Remotes.ServerControls:InvokeServer("PaintPart", {Part = province, Color = desired}, "Peace")`. | Exactly the same path and arguments; cached and refreshed when the hierarchy changes. |
| Normal mode | One yielding callback per province if debounce works; no global cap. | Two pending same-color RPCs per province by default, a global adaptive window, token bucket, and frame-start budget. |
| Safe mode | Disables the province debounce while InvokeServer runs and then uses legacy `wait(1)`; no global pacing across many provinces. | Fixed total outstanding concurrency 1, globally paced at 4 requests/sec, plus 1 second between same-province attempts. |
| Fast Paint | Leaves debounce open. Every Stepped event can start another request; `wait(3)` occurs inside each overlapping callback and does not impose a shared delay. | Higher bounded rate/window and up to six concurrent same-color contributions per province by default, with fair FIFO allocation. |
| Toggle Paint | Button/Q controls new entry into callbacks; cannot cancel an already-sent invocation. | Same pause/resume meaning; pending operations remain accounted for. |
| Keep Territory Color | `savedColor = color` when added. The condition parses as `(province.Color ~= color and not keepTerColor) or (keepTerColor and province.Color ~= savedColor)`. The original precedence is valid, though hard to read. | Explicit target selection, same saved-selected-color semantics. |
| Unprotect | Disconnects matching events and destroys their clones, but never removes their array records. | Removes every selection record, listener, timer and visual. Pending RPC identity remains bounded until it returns. |
| Clear | Disconnects and destroys but leaves the array full of references. Closing the already-ended registration coroutine does not cancel yielded event callbacks. | Clears the registry and ready/retry structures; future work stops for these selections. |
| Country Color | Click a province to copy its Color; selection is handled independently of other mode booleans. | One exclusive selection mode; click only copies color, and Done/Cancel/Escape finishes selection. |
| Random color | Button/R selects random integer RGB components and updates the swatch. | Preserved; all pending old-target operations must drain before a different color is sent to that province. |
| PPS | Counts attempts before InvokeServer; snapshots once per second without correcting for actual elapsed time. If last interval exceeds 1000, the next interval is blocked, creating burst/stall oscillation. | Separate attempts, returns, errors, and independent observed target-color transitions. Unchanged color is not an invocation failure. |
| UI/lifetime | UI can reset on respawn while global listeners/loops continue; per-drag connections accumulate; four sounds, multiple decorative tweens, unbounded clone risks. | ResetOnSpawn false, explicit shutdown, fixed drag listeners, no decorative loops, clone-free selection outlines. |

The original also dereferences `player.Character` without a nil check, assumes both remote containers exist, and does not protect InvokeServer. An exception after disabling debounce can leave a province permanently disabled. Its `Transparency = 1000000` is nonsensical (valid range is 0–1). Clones may retain collision/query behavior and descendants. The outer coroutine serves no useful concurrency role. The packaged original is additionally wrapped in Markdown fences, so the unmodified reference is not directly executable Luau.

## What FastClient already fixed, and what remained

FastClient correctly introduced one Heartbeat scheduler, global 40/80 request bounds, per-province counters, a duplicate-selection lookup, protected InvokeServer execution, nil-safe remote discovery, actual selection removal/clear, valid clone transparency, and non-colliding/non-queryable clones. Its visible counter counts non-throwing returns rather than attempts. It removed the old PPS limiter and obsolete loader advertisement.

Remaining bottlenecks and failure cases:

1. Its reverse scan always starts with the last province. When the window is full, later entries can repeatedly consume capacity before earlier entries are considered. All-correct selections still incur per-frame scans.
2. Fast mode permits three outstanding calls per province. Such calls can be useful contributions in this game, but the fixed policy lacks fair per-round allocation, independent global rate pacing, and a barrier separating old and new target colors.
3. It refetches character/tool/folder/remote for every request. No explicit mechanism handles replacement or distinguishes an old generation's late results.
4. It offers no distinction between request outcomes and province-level color transitions. A province may need many returned contributions before its color changes; neither unchanged color nor a non-throwing return establishes the outcome of an individual hit.
5. Errors immediately retry without backoff or telemetry. A missing/inaccessible province can waste capacity indefinitely.
6. Safe mode has a per-province interval but can still open dozens of calls globally. Fixed 40/80 limits do not account for latency, server queueing, workload size or observed throughput.
7. Removing a province searches and shifts the array. Cleanup of destroyed entries is delayed by capacity checks and by pausing. Removed-and-re-added provinces can overlap their old in-flight requests because the new record starts at zero.
8. UI/input/Heartbeat connections and the endless PPS loop lack explicit lifetime cleanup; the UI resets on respawn. Clone descendants and repeated drag callbacks remain unnecessary resources.

## Revision: requests may be individual contributions

The previous final version imposed one outstanding call per province, waited briefly for visible color confirmation, and used unconfirmed outcomes to back off and reduce concurrency. Those assumptions were too conservative for the supplied gameplay model. Several valid contributions may be required to capture a province. The revision removes that penalty and supports controlled same-province overlap.

The script remains client-only and self-starting from the public loader. It requires no place/project access, Studio setup, publishing, server scripts, or modifications to the existing PaintBucket hierarchy. There are no account-specific identifiers. The runtime is scoped to Players.LocalPlayer, so each player uses their own equipped remote and independent UI/state. As with the old loader, its execution environment must already supply client loadstring and game:HttpGet. A stock Roblox client does not itself offer an arbitrary-code launcher; no alternate installation is required by this package.

## Selection-safety revision

The live issue was reproducible in the prior source: `addProvince()` called `evaluate()`, and painting defaulted to ON, so the very first Add click could schedule PaintPart. The fix introduces a transaction with an explicit `committed` field plus an intrusive pending list. This is separate from `pendingByPart`, which accounts for actual unreturned RPCs.

Registration now creates only the unique registry entry, color snapshot, outline and lifecycle listeners. It does not evaluate, enqueue, create a retry timer, spend tokens, update request statistics, or wake a paint worker. `evaluate`, enqueue, timer insertion and dispatch independently reject uncommitted entries. Pending color/ancestry events can validate and remove entries but cannot turn them into work. Removal unlinks pending entries in O(1); the existing array/map and ready FIFO stay intact.

Done/Cancel/Escape have consistent finish semantics: preserve clicked tiles, mark the entire pending list committed without yielding, clear its links/count, then evaluate in click order. Painting OFF commits without queuing; the next explicit resume evaluates eligible committed selections. The occasional resume/finish pass handles events received while dispatch was paused; it does not add a per-frame selection scan.

All selection modes suspend new dispatch for existing committed provinces too, while retaining the user's Toggle Paint setting. Responses/stalls remain counted, errors preserve their cooldowns, and removal/Clear never fabricate cancellation. Country Color no longer exits immediately on click: Done/Escape explicitly resumes eligible work. Escape also finishes when CoreGui processes the key, without blocking CoreGui. Duplicate loading no longer closes/commits a selection session. Closing the UI discards pending entries and listeners. No moderation or input-hook bypass is involved.

Color semantics use a single global setter. Keep OFF follows its latest value; Keep ON uses the selected color at click/add time, even when global color changes before Done. The UI swatch updates immediately. Pending color transitions do not contribute observed-paint telemetry. Existing in-flight groups still drain the previous target before a different color can be sent.

### Manual PaintBucket inspection and limitation

Both supplied reference scripts were searched and traced for PaintBucket resolution, local color assignment and PaintPart payload construction. Their color variable belongs to AutoPainter itself; they do not contain the normal tool's client code, hierarchy dump, Color3Value contract, attribute contract or local color setter. The available repository contains the AutoPainter sources/tests, not the game project or a live engine bridge. Therefore the manual bucket's real selected-color representation and its change-handler side effects cannot be determined from this material.

The requested safe fallback is used: manual bucket state is unchanged. A synthetic fixture with a plausible `SelectedColor` Color3Value confirms that neither Randomize, R nor Country Color guesses at it or invokes its change listener. This is a test of noninterference, not evidence of supported synchronization. Testing a working manual binding (including Keep ON) requires the actual existing client mechanism; it would be misleading to invent a fixture and claim it matches the game. No server protocol, extra remote, secret, or fake paint operation was added.

### Selection regression evidence

The 70 new checks run with both immediate and deferred signals and execute the actual production script. They cover the real Add button and tile-click path, one then twenty highlighted pending selections with zero calls/attempts/workers/deferred scheduler wakes/token consumption in Normal/Fast/Safe; atomic Done; OFF then Q; R during Add; Country Color; Remove; Clear; repeated Escape; duplicate clicks; remove/re-add; respawn/tool absence/remote replacement; pending lifecycle destruction; one hundred selection cycles; duplicate loaders; close; touch input; and invalid/processed input.

After commit, tests retain exact 2/6/1 same-province peaks, FIFO first-pass fairness, a 64-call hard cap with stalled calls, no waiting-worker buildup, and old/new-color group barriers. Color tests cover global/button/R swatches, Keep OFF retargeting, Keep ON add-time snapshots, and mixed saved colors in one pending transaction. The 57 previous tests still pass with their setup explicitly committing selections. Test fixtures instrument task creation and actual invocation counts, rather than inferring silence from Part.Color. Full-source compilation succeeds with the official Luau compiler. Standalone luau-analyze reports its expected missing Roblox globals/type definitions; no full Roblox static-type validation or live-engine test is claimed.

## Revised architecture and invariants

**Fair scheduling with useful overlap.** A dirty selection has at most one intrusive FIFO ticket. Each visit may reserve one request, then moves the province behind all current waiting entries if it has room for another. All initially eligible provinces receive their first turn before additional passes. Late committed selections join the existing queue; an older ticket can run first, but repeated completions cannot jump the queue. No full selection scan is performed each frame. Color/lifecycle events, request completions, due retry timers, target/mode changes and remote restoration wake work.

**Separate request groups from selection records.** `pendingByPart[part]` holds a count and immutable target color for the live group. Every request refers to that group and snapshots its part, color, remote version, selection identity and error epoch. Each return/error releases one count; the map entry is removed only after the last call returns. Clear/remove release all selection state while these genuinely outstanding operations remain bounded. Re-adding the same part cannot reset its pending count. Old-remote and stalled calls also count against its limit.

**No contradictory-color overlap.** Concurrent contributions to a part share one target color. If the selected target changes, all calls using the previous target drain before the latest target is sent. Rapid intermediate color choices are coalesced. The mock rejects different-color overlaps and tests out-of-order completion of all six old-color calls. This prevents concurrently running old-color calls from racing a new-color call; it cannot guarantee server processing order after a server callback has already returned if that callback launches additional asynchronous work.

**Actual errors cause backoff.** Unchanged Color causes neither a cooldown nor a transport-failure classification. There is no post-return color-confirmation grace period. A non-throwing return can immediately refill a slot even when ownership has not changed. Actual invocation errors trigger exponential per-selection backoff. A request snapshots an error epoch; a later success from an older sibling cannot erase a newer error's cooldown. Selection IDs and remote versions prevent old results from applying a cooldown to replacement state. Nil, false and other returned values are not interpreted without an established server return contract.

**Adaptive global concurrency measures responsiveness.** Every two seconds with enough returns and sustained global capacity pressure, the controller probes larger or smaller windows using returned requests/sec and mean round-trip time. An upward probe needs at least a 5% throughput gain and no more than 35% latency growth. A downward probe can retain at least 97% throughput without material latency growth. Actual error rate or a latency/throughput regression reduces the window. Color observations are entirely absent from this control loop. Mode, target-workload and resolved-remote changes reset sample history. This is a bounded heuristic, not knowledge of the server's internal contribution handling or throttles.

**Independent traffic bounds.** The adaptive window, global 64-call hard cap, per-province cap, token-bucket rate, burst budget, per-frame starts budget and per-selection error cooldown all apply before spawning a worker. The script creates no task waiting for capacity. One coalesced deferred pump handles event bursts. At most 64 invocation workers can be outstanding, including calls that never return; the queue contains selection entries rather than a backlog of prebuilt requests. Timer storage has at most one indexed heap entry per selected province. Jobs and pending groups have no reference to removed selection entries.

**Stalls remain real outstanding calls.** At 15 seconds an unreturned call is labeled stalled and removed from the healthy Normal/Fast adaptive-window count, but remains in the 64-call hard cap and per-part count. Other eligible work can use spare hard capacity. Safe mode retains one total outstanding call even when stalled. All 64 permanently stalled calls stop new dispatch; their capacity is not falsely freed or endlessly retried. Pausing, Clear, UI shutdown and respawn cannot undo server operations already sent. Bounds apply to one running painter instance; repeated destruction/recreation of whole instances is not a network cancellation mechanism.

**Existing low-overhead structures remain.** Services and LocalPlayer are cached. Hierarchy signals rebuild Character → PaintBucket → Remotes → ServerControls, with a low-frequency unavailable-only fallback. The dense selection array supports occasional bulk retargeting and swap-removal; the lookup prevents duplicate registration. Color/name/ancestry/destruction listeners keep entries current, and a persistent Workspace removal listener survives destruction of a part's own callbacks. SelectionBox outlines avoid cloning geometry and descendants. UI shutdown disconnects all listeners and destroys selection visuals. One local UI BindableFunction prevents duplicate loading; it does not create or modify any server remote.

## Defaults and rationale

| Mode | Per-province cap | Initial global window | Global adaptive range | Rate/sec | Burst | Starts/frame |
|---|---:|---:|---:|---:|---:|---:|
| Normal | 2 | 8 | 2–24 | 160 | 8 | 16 |
| Fast | 6 | 16 | 4–64 | 360 | 16 | 32 |
| Safe | 1 | 1 | fixed 1 | 4 | 1 | 1 |

Two provides moderate Normal overlap. Six lets one contested province use a meaningful portion of Fast's initial window and two provinces use twelve slots, while bounding excess work after capture and avoiding unlimited single-target pressure. FIFO allocation preserves throughput across a larger selection. Six is a starting value within the proposed 4–8 range, not an assertion that six outperforms eight on the actual server. All limits are near the top of the file. Lowering a cap lets existing calls drain; it cannot cancel them.

Safe mode additionally spaces starts to one province by at least one second and enforces one outstanding call globally, including stalled calls. The effective ceiling in all modes is also constrained by FPS, response latency, other selected provinces and token availability. A rough latency-limited upper bound for one perpetually contested province is its per-province window divided by round-trip latency; the server can impose a lower limit. Therefore a one-call cap can leave substantial contribution capacity unused even when the global window is large.

## Telemetry semantics

- Attempted: invocations that reached the final transport guard and called InvokeServer. Reserved workers suppressed before that call do not count.
- Suppressed: reserved but unsent workers prevented from invoking after diagnostics, pause, selection or shutdown; no server cancellation is claimed.
- Returned: invocations that returned without throwing; not proof of an accepted hit.
- Failures: protected invocations that threw an error.
- Observed: mismatch-to-target color observations on tracked provinces. One transition counts once, even with six concurrent calls. Another player can cause it; no per-request attribution is claimed. Target changes themselves do not count as observed paint.
- InFlight/Stalled: real unreturned calls, including old selection/character state.
- PendingProvinces: distinct parts with at least one real outstanding call.
- PendingSelections / CommittedSelections: selected entries before/after explicit selection commit. These are independent of RPC groups.
- Painting / SelectionMode: user toggle and temporary selection tool; selection mode suspends dispatch without changing Painting.
- RequestTokens: current token-bucket balance, useful for checking that registration consumes none.

The UI emphasizes returns/sec and separately shows target matches/sec. Rates use elapsed time. The previous Unconfirmed counter and confirmation-grace settings were removed. A color observation still stops new attacks while the visible part matches its target, preserving the original protector behavior. This revision does not assume that attacking an already-matching province is useful; no such behavior was requested.

## Read-only inventory correction

The reported Handle-only hierarchy output is now supplemented by a separate native `PaintBucket:GetDescendants()` snapshot. **PAINTBUCKET DESCENDANTS** lists every returned object, sorted by full path, with complete identity/parent information, readable script Enabled flags, all attribute metadata, safe ValueBase types/values and remote flags. The old summary bounds do not limit this inventory. Explicit totals and `FreshRemoteInInventory` expose incomplete native enumeration instead of silently substituting the cached remote. Strings and credential-like values remain redacted.

The complete report is returned by `GetDiagnosticReport()`. Its UI uses lossless UTF-8 pages (4,000 bytes / 40 newlines), retaining only the newest string and offsets. Snapshot work happens only on request; no per-object listeners or history are added. Inventory format 2 is retained; UI capability version 4 refuses panels lacking compact extraction/export. Added tests simulate the exact inconsistent Handle-only summary, exceed all previous caps, verify every requested field and read failures, reconstruct every UI page byte-for-byte and assert zero remote calls/property writes/task creation during inspection. This corrects reporting, with no change to the unverified paint protocol or the default/locked diagnostic gate.

## Optional LocalScript inspection

The locked build adds an explicit source action and `GetLocalScriptReport()`, separate from the unchanged metadata/inventory action. It accepts only LocalScript descendants of current LocalPlayer Character/Backpack PaintBucket tools and rechecks that scope before each read. It uses only the environment's existing `decompile` function, serially inside protected calls. There is no fallback source/closure access, module execution, target-function invocation, property write or game request. Absence/failure/invalid results are explicit; nonempty returned text is preserved and labeled unverified. A textual line index points to the requested protocol/color/state terms without inventing execution order or accepted arguments.

Only one inspection may run at a time. Repeated clicks/API calls cannot spawn waiting work. Respawn/removal skips stale candidates; shutdown prevents further reads and stale UI writes. The same paginated view retains only its newest report, plus one separate compact export snapshot. A never-returning external decompiler leaves one inspection busy; it is not replaced with accumulating timeout jobs. The decompiler provider's internals and reconstruction accuracy cannot be certified here. No actual game client source has yet been collected in this workspace, and no live protocol repair or test paint is claimed.

## Compact protocol extraction

The default diagnostic view now leads with Protocol Extract and Copy Protocol Report. The scoped source collector supports both compact and optional raw rendering, sharing the same lock, ownership checks, protected reads and single-inspection guard. Compact rendering splits each returned source into numbered lines, matches all 18 requested terms, merges 8-before/12-after intervals per script, and prints each context block once. Remote-call and PaintPart summaries point to those blocks. Remote-call search also retains every occurrence on a line and handles whitespace/newlines around method syntax. None of this text is compiled or executed.

Clipboard/file export is an explicit user action. It uses `setclipboard` first, then `writefile` at the exact requested filename when clipboard access is missing/fails, and reports failures without claiming success. It exports the full compact snapshot, never a truncated display page or optional raw/inventory report. No inspection/export task backlog or source history is created. Shutdown rechecks prevent file fallback after a yielding clipboard failure and prevent exports after a yielding decompile completes. The locked paint gate and actual game protocol are unchanged.

## Final review and validation

The full revised runtime, UI callbacks, loader and tests were reviewed. Syntax is checked with the official Luau compiler; no engine API names changed in this revision. Review covered request reservation before spawning, per-group release, no negative/stuck accounting after thrown errors, immutable per-call payloads, remove/re-add identity, target-color barriers, late old-remote responses, mixed-success/error cooldowns, mode changes, fairness, timer removal, UI shutdown and independent players.

The actual final source is executed by the deterministic mock suite, which now contains 271 tests (57 scheduler, 70 selection/color/boundary, 36 diagnostic, 24 inventory, 40 source-inspection, and 44 compact extraction/export checks). It covers both immediate and deferred event delivery and all previous lifecycle cases, revised where the gameplay assumption changed. New checks include:

1. Exact peak concurrency of Normal 2, Fast 6, Safe 1 on a continuously contested province.
2. One-slot-per-visit FIFO allocation and first-pass fairness across dirty provinces.
3. A heavily contested province receiving multiple slots while 25 easy provinces finish.
4. Late selections receiving service when another province initially filled the global window.
5. Repeated remove/Clear/re-add with six pending/stalled calls cannot bypass the per-part cap.
6. All six old-color calls must drain, including out-of-order returns, before a new color starts.
7. Successful sibling returns do not erase a newer actual-error cooldown.
8. Respawn with six old-remote calls, same-color slot reuse and late old errors.
9. Nil and false returns keep contributing traffic without inventing an acknowledgment contract.
10. Destruction releases selection/listener state immediately and group state on final return.
11. Switching Fast to Safe drains old overlap before its single-call pacing resumes.
12. Adaptive growth with zero color observations but healthy sustained returns.
13. Independent players have separate local UI, selections, modes, counters and remotes.
14. The public loader fetches the exact final path and starts the full script in the mocked client environment.

Existing hard-cap, hung-request, 100-cycle cleanup, 700-step randomized state/accounting, zero-latency and 15/60/240-FPS tests remain. The mock enforces the global hard cap and rejects mixed-target-color overlap. Randomized tests compare pending-group counts against the mock's actual active parts and check Attempted = Returned + Failures + InFlight.

**Simulation results, not live-game claims:** a single province requiring 24 contributions at 200 ms simulated latency took 5.15 seconds with configurable Fast MaxPerProvince = 1, versus 0.85 seconds with MaxPerProvince = 6. Both use this revised scheduler, isolating the effect of overlap. Many-province checks still produced 575 target observations in ten simulated seconds with adaptation versus 432 with the initial global window fixed at sixteen. A throughput-plateau fixture reduced the global window to six while retaining 1,618 observations in 42 simulated seconds.

A mock cannot validate the actual server's contribution rules, response contract, rate limits, replication timing, engine rendering or a particular external client execution environment. No live-game speed measurement has been performed. These results verify the intended bounded model and fault behavior, not universal optimal performance.

## Practical follow-up measurements

Compare Normal and Fast in the actual game for both 100–500 selected provinces and one or a few heavily contested provinces. Use the same server, device, targets, initial ownership and opponents where possible. Record returned requests/sec, actual capture time, errors and RTT. Compare Fast per-province caps 4, 6 and 8 while preserving the global cap. Increase request-rate ceilings only when they are the bottleneck and the server continues to accept useful contributions without excessive latency or errors. Disable adaptation for controlled fixed-window comparisons.

If a documented server return contract later becomes available, it can distinguish accepted contributions from non-throwing rejections. Until then, the script does not guess. No server modifications are needed for the current implementation.
