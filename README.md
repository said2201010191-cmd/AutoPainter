# AutoPainter

**Current status: the normal PaintBucket protocol is unverified. The user reports a kick on the very first Safe-mode request. This revision adds diagnostics; it does not fix or live-validate that rejection.** The script now defaults to diagnostics ON, so selecting and committing provinces, equipping the bucket, and toggling painting produce zero AutoPainter game requests. Rate/concurrency values are unchanged.

For this investigation, close the older AutoPainter panel and run the locked diagnostic loader:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/said2201010191-cmd/AutoPainter/main/LoaderDiagnostic.luau", true))()
```

Click **Protocol Extract**, then **Copy Protocol Report**. The default view is compact and does not include the full inventory or raw source. Extraction scans all LocalScript descendants of your current Character/Backpack PaintBucket tools using the existing environment-provided `decompile` function. It includes script paths, original line numbers and matching code with **8 lines before / 12 lines after**, clipped to file boundaries. Overlapping and adjacent windows merge per script. No inspection runs automatically on startup.

The report contains **REMOTE CALL SUMMARY**, **PAINTPART FLOW** and **MERGED CONTEXT BLOCKS**. Summaries reference block IDs so each surrounding code block is printed once. All 18 requested terms are searched case-insensitively; the remote summary also finds all four colon-call methods, including whitespace/newlines and repeated calls on a line. Matches in comments/strings are textual evidence only. No matching context is silently truncated; dense matches can still cover much of a script.

**Copy Protocol Report** copies the entire latest compact report with `setclipboard`, independent of the current UI page. If there is no compact snapshot yet, it builds one first. If clipboard access is absent or throws an error, it uses `writefile("AutoPainterProtocolReport.txt", report)` in your client environment's file area. That fixed file is replaced on subsequent exports. If neither capability works, an explicit status appears and the paginated report remains available. Press Protocol Extract again to refresh the snapshot after tool/character changes. No upload is performed.

**Full inventory (optional) → Inspect** retains the complete **PAINTBUCKET DESCENDANTS** section and does not decompile. **Full source (optional) → Inspect source** retains all returned source. Both remain separate actions with Prev / Next pages. `GetDiagnosticReport()`, `GetLocalScriptReport()` and `GetProtocolReport()` return complete strings. `CopyProtocolReport()` exports the compact snapshot and returns success/status. Showing a full report never changes which report Copy Protocol Report exports.

Diagnostics must stay **LOCKED ON** for source extraction or export. AutoPainter sends zero game requests and does not execute inspected scripts, require modules, call their functions, change game properties, or hook moderation. The optional decompiler/clipboard/file functions belong to your existing client environment; their implementations cannot be certified here. Missing decompiler capability and failures are reported rather than guessed around. Inspections and exports each allow only one active operation and create no waiting-task backlog. The newest compact string is retained separately from the current view, without source/Instance history. UI version 4 refuses older panels, so close the old panel before loading this build. Already-sent calls and independently running normal tool code cannot be canceled by diagnostics.

See [PROTOCOL_DIAGNOSIS.md](PROTOCOL_DIAGNOSIS.md) for the evidence table, missing normal client/module/server-contract sources, exact diagnostic behavior and limits. A real successful request is still needed before any protocol repair can be called fixed.

`AutoPainterFinal.luau` is a standalone client script. Join the game, run the public loader in the same client execution environment as the old loader, click Protect Province, select provinces, and press Done to activate them with your own existing PaintBucket. The UI starts automatically; the diagnostic gate suppresses dispatch by default.

No Studio access, place editing, publishing, server installation, or changes to existing game objects are required. Each player is resolved dynamically through `Players.LocalPlayer` and gets independent UI, selections, counters and request limits. There are no Roblox account identifiers or credentials in the script.

## Public loader

Use the public file with the same client execution environment as your previous loader:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/said2201010191-cmd/AutoPainter/main/AutoPainterFinal.luau", true))()
```

[LoaderPublic.luau](LoaderPublic.luau) is an equivalent loader with explicit download/compile error messages. Both use the same exact path. The repository/file must be public for anonymous loader access. If it is made private again during development, anonymous raw requests cannot retrieve it. No PAT, cookie, signed private URL, or other secret belongs in a client loader. For reproducible sessions, replace `main` in the URL with a reviewed full commit SHA once the file is publicly accessible.

As with the original loader, the player's execution environment must already provide client `loadstring` and `game:HttpGet`. The stock Roblox client does not provide an arbitrary-script launcher, and ordinary LocalScripts do not provide client `loadstring`. This package assumes your existing loader environment; it does not require a Studio or server setup. See [Roblox's capability documentation](https://create.roblox.com/docs/scripting/capabilities).

When upgrading from an older running version, close its panel before loading the new version. Re-running while a panel exists returns that running instance, avoiding duplicate schedulers and preserving any open selection session. It does not install a newer version over a running instance. Already-sent calls cannot be canceled by closing the UI.

## Existing protocol

The client only reads the equipped object path:

`Players.LocalPlayer.Character → PaintBucket → Remotes → ServerControls`

Outside diagnostics, the retained legacy invocation has these arguments (not verified against the normal game client):

```lua
ServerControls:InvokeServer("PaintPart", { Part = province, Color = desiredColor }, "Peace")
```

No new RemoteEvents or RemoteFunctions are created. The only helper BindableFunction is local to the UI and prevents duplicate script instances. Reference files `AutoPainterOriginal.luau` and `AutoPainterFastClient.luau` remain unchanged. The original ZIP file includes Markdown fences; they are preserved only in that reference, not in the runnable final script.

## Same-province attacks

Several returned requests may be valid contributions before a province changes color. The current implementation therefore supports bounded same-color overlap and does not classify unchanged color as a failed or useless request.

| Mode | Outstanding per province | Initial global window | Adaptive global range | Request ceiling/sec | Burst | Starts/frame |
|---|---:|---:|---:|---:|---:|---:|
| Normal | 2 | 8 | 2–24 | 160 | 8 | 16 |
| Fast | 6 | 16 | 4–64 | 360 | 16 | 32 |
| Safe | 1 | 1 | Fixed 1 | 4 | 1 | 1 |

Change `Normal.MaxPerProvince`, `Fast.MaxPerProvince`, and `Safe.MaxPerProvince` in `CONFIG` near the top of the script. Safe also has an independent total outstanding limit of one and a one-second minimum between requests to the same province.

Six is a practical Fast starting point: one contested province can occupy six simultaneous calls, two can occupy twelve, and larger selections share the global window. Normal uses two for moderate overlap. These defaults are reasoned starting values, not measured engine limits or a claim that six is optimal for your server. Compare 4/6/8 in your actual game; keep the global hard cap intact while tuning.

The FIFO grants **one request per visit**, then moves the province to the back if it can accept more. An initial set of dirty provinces receives a first pass before extra passes. A newly committed province joins the existing FIFO order; a previously queued province may still have one earlier ticket, but cannot repeatedly jump ahead. At most one ready ticket exists per selection.

A part's outstanding count survives remove, Clear, re-add and respawn. Changing target color waits for all previous-color calls to that part to drain, preventing overlapping contradictory colors. Switching to a lower-concurrency mode also lets already-sent calls drain instead of pretending to cancel them. Once the desired visible color is observed, new requests stop until it differs again; already-sent contributions may still finish.

## Congestion, errors and limits

The adaptive global window uses **non-throwing return rate, round-trip latency, actual invocation errors, and capacity pressure**. It never uses missing color observations to shrink the window. Higher windows are retained when return throughput improves without excessive latency; lower-window probes can retain the same throughput with fewer outstanding calls. Set `Adaptive = false` for fixed-window comparisons using each mode's Initial setting.

Only an actual thrown `InvokeServer` error triggers per-province exponential backoff, starting around 0.2 seconds and capped around 5 seconds with ±10% staggering. An older successful sibling cannot erase a newer error's cooldown. Old selection/remote results release their own accounting without applying their cooldown to a newly selected province or replacement remote. Nil, false and other non-throwing server returns are recorded as returns; no acknowledgment contract is invented.

There is no color-confirmation waiting period or unconfirmed-color penalty. A healthy return can immediately refill a same-province slot while the visible color remains unchanged.

The **64-call hard outstanding cap** includes old-remote and stalled calls. After 15 seconds an unreturned call is marked stalled, retained in its part's count and the hard cap, and excluded from the healthy Normal/Fast adaptive window. Other provinces may use spare hard capacity. Safe retains its total one-call limit even for stalled calls. If all 64 calls never return, dispatch stops; a client timeout cannot cancel a server operation or safely fabricate released capacity.

Rate, burst and per-frame budgets apply independently of the concurrency window. No task is created to wait for capacity. One task is created only after reserving a real request slot. Retry timers are bounded to one per selected province; correct/idle provinces are not scanned each frame.

## Selection is separate from painting

**Protect Province → click tiles → highlights only → Done → eligible for painting.** A clicked tile is registered as pending. Registration does not evaluate paint work, enqueue it, consume tokens, create workers, alter request statistics, or wake the scheduler. Color changes, R, respawn, remote replacement, and duplicate loading cannot commit it. Pending entries still have lifecycle listeners so invalid/destroyed tiles can be removed promptly.

All selection tools temporarily suspend **new AutoPainter dispatch**, including for previously committed provinces. Already-sent calls continue and remain honestly counted. Toggle Paint itself is unchanged. Done / Cancel and Escape both mean **finish and preserve clicked selections**; there is no rollback. All pending entries are marked committed before any is evaluated, in click order. With diagnostics OFF and Toggle Paint ON, work resumes; Toggle Paint OFF or diagnostics ON prevents dispatch. Country Color stays open after copying a color and requires Done/Escape to finish, preventing the color-copy click from resuming painting.

Remove deletes a pending or committed entry immediately. Clear deletes both kinds plus highlights and queue/timer records; neither sends a new request. Closing × discards pending selections and stops the local painter. Existing game-tool behavior is not intercepted: this guarantee covers requests made by AutoPainter, not an independently running manual-tool script. There is no moderation, kick, or anti-cheat interception.

Programmatic `AddProvince(part)` has the same pending behavior. Call `CommitSelections()` explicitly to finish the transaction. `GetStats().PendingSelections` counts pending UI selections; `PendingProvinces` separately counts parts with genuinely outstanding RPCs.

## Current color and the normal manual bucket

Country Color, Randomize Color, and R all use one selected color and update the UI swatch immediately. `GetColor()` exposes it. A color change alone performs no remote call or fake click. Outside selection/diagnostic mode, an enabled scheduler may repaint **already committed** provinces to their new target as intended.

With **Keep Territory Color OFF**, pending and committed provinces follow the latest global color. With it **ON**, each province keeps the selected color at the moment it was clicked/added; committing does not overwrite that snapshot. Thus a single selection session may add A while red, change to blue, and add B: after Done, A targets red and B blue. The snapshot is the selected color, not the tile's existing color. Global color changes remain independent of that snapshot.

**Manual PaintBucket color synchronization is not implemented in this revision.** The supplied files only reveal an AutoPainter-local `color` variable and the explicit `Color` argument in `PaintPart`. They contain neither the normal PaintBucket's LocalScript nor an established writable Color3Value/attribute/client setter. No live tool hierarchy is accessible in this workspace. A plausible property name cannot establish that normal clicks read it or that writing it has no painting side effects. Accordingly, the manual bucket is left unchanged, including while Keep Territory Color is ON. No guessed attribute, new remote, hook, or paint request is used as a substitute. A verified existing client color setter and its change handlers are the missing evidence needed to add safe synchronization.

## Controls

- **Diagnostics · no requests:** ON by default during protocol investigation. Blocks all new AutoPainter remote invocations while allowing selection/commit/cache inspection. Turning an unlocked mode OFF also turns Toggle Paint OFF; it never resumes by itself. LOCKED instances cannot turn diagnostics OFF.
- **Full inventory (optional) / Inspect:** displays a bounded state summary followed by a complete equipped-tool descendant inventory, without remote probes or game-state writes. The inventory includes names, full paths, classes, parents, script Enabled flags, every attribute, safe ValueBase values/types and remote-kind flags. Credential-like values and unknown string values are redacted. UI pages preserve all report bytes; `GetDiagnosticReport()` returns the complete string. No automatic upload, clipboard write or snapshot history is created.

- **Country Color:** click a province to copy its color only; finish with Done/Cancel or Escape.
- **Protect / Unprotect Province:** add pending selections or remove selections, then Done. Repeated Add clicks do not register duplicates; newly clicked tiles cannot paint before Done.
- **Clear Provinces:** remove every selection, outline, per-part listener, ready ticket and retry timer. Bounded real pending-call records remain until those calls return.
- **Toggle Paint / Q:** pause or resume new dispatch; in-flight calls remain accounted for.
- **Fast Paint:** enable the higher request rate/window and six-per-province default.
- **Safe Mode:** override Fast with conservative pacing and one total outstanding call.
- **Keep Territory Color:** use the selected color when each province was added, preserving both reference scripts' semantics. It does not capture the province's preexisting color.
- **Randomize Color / R:** choose a random RGB color. While Keep Territory Color is on, existing selections keep their saved target colors.
- Drag the top bar to move the panel; close × to stop and clean up. Selection boxes adorn real parts instead of cloning geometry. Decorative sounds and animation loops are omitted.

## Telemetry

The primary display is **returns/sec**, not claimed successful hits or paints. The secondary display shows target-color matches/sec, active/window, stalled calls, and cumulative errors.

`GetStats()` exposes Attempted, Returned, Failures, Observed, Stalls, Selected, PendingSelections, CommittedSelections, SelectionMode, Painting, Ready, Delayed, InFlight, Stalled, Window, MaxPerProvince, RequestTokens, PendingProvinces, DiagnosticOnly, DiagnosticLocked, Suppressed, RTT, RemoteReady and Running. `Observed` counts mismatch-to-target observations once per selected province transition, independently of how many calls overlap. It can include another player's color change and can miss transient changes between replication updates. Retargeting to a color already visible is not counted. The previous `Unconfirmed` field and color-confirmation settings were removed.

## Validation

Run the actual final source through the deterministic Luau mock suite:

```sh
python3 tests/run_tests.py /path/to/luau
```

The revised suite has 271 passing tests: 57 scheduler checks, 70 selection/color/boundary regressions, 36 diagnostic checks, 24 complete-inventory regressions, 40 LocalScript source-inspection checks, and 44 compact extraction/export checks. Painting regressions explicitly opt out of diagnostics in their mocked startup; diagnostic checks test the actual default and locked loader. It covers controlled same-province overlap, one-slot-per-visit fairness, multi-contribution captures, no-color-change returns, nil/false returns, actual-error backoff, out-of-order completions, color barriers, clear/remove/re-add, respawn, stalled hard caps, independent players, lifecycle cleanup and the exact public loader path. The new suite drives the actual Add/Pick/Remove/Done/Clear button callbacks, mouse/touch input, Q/R/Escape, and checks pending highlights, zero traffic/task/token use, atomic commit, OFF-state preservation, lifecycle races, repeated sessions, and post-commit concurrency/fairness. It also verifies the safe fallback of leaving an unverified manual-bucket value untouched; it does not claim a working manual-color binding. Inventory tests reproduce a Handle-only summary while the independent descendant snapshot includes Remotes/ServerControls, exceed the old node/depth/attribute/text caps, check sorting/redaction/read failures and exact UTF-8 page reconstruction, and assert no game requests, property writes, tasks or listeners are created by inspection. Source tests also cover equipped/Backpack scope, excluded modules/server scripts/other tools, unavailable/error/invalid decompiler returns, unchanged full source, protocol text matches, zero writes/calls/execution, exclusive inspection, lock enforcement, respawn/shutdown and exact UTF-8 pagination. Compact-report tests cover all 18 terms, exact context windows, overlap/adjacency merging, file edges, repeated/multiline calls, shared context references, scope, complete clipboard/file exports, unavailable/failing capabilities, caching, exclusive operations and shutdown. The runtime, both loaders, all tests and FastClient compile with the official Luau compiler. The original reference contains Markdown fences; its extracted Luau body compiles separately while the reference file remains byte-for-byte unchanged. Mock acceptance of PaintPart is not evidence that the real server accepts it; the live rejection remains unresolved.

These are simulated correctness/performance tests, not a live-game benchmark. In a fixture requiring 24 contributions at 200 ms simulated latency, Fast capped at one per province took 5.15 seconds; Fast capped at six took 0.85 seconds. Actual performance depends on server behavior, throttling, network latency, replication and FPS. See [ANALYSIS.md](ANALYSIS.md) for the review and revision details.
