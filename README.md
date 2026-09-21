# AutoPainter

`AutoPainterFinal.luau` is a standalone client script. Join the game, run the public loader in the same client execution environment as the old loader, select provinces, and use your own existing PaintBucket. The UI and scheduler start automatically.

No Studio access, place editing, publishing, server installation, or changes to existing game objects are required. Each player is resolved dynamically through `Players.LocalPlayer` and gets independent UI, selections, counters and request limits. There are no Roblox account identifiers or credentials in the script.

## Public loader

After making this repository public:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/said2201010191-cmd/AutoPainter/main/AutoPainterFinal.luau", true))()
```

[LoaderPublic.luau](LoaderPublic.luau) is an equivalent loader with explicit download/compile error messages. Both use the same exact path. The repository remains private during development; an anonymous raw request cannot retrieve a private file. No PAT, cookie, signed private URL, or other secret belongs in a client loader. For reproducible sessions, replace `main` in the URL with a reviewed full commit SHA once the file is publicly accessible.

As with the original loader, the player's execution environment must already provide client `loadstring` and `game:HttpGet`. The stock Roblox client does not provide an arbitrary-script launcher, and ordinary LocalScripts do not provide client `loadstring`. This package assumes your existing loader environment; it does not require a Studio or server setup. See [Roblox's capability documentation](https://create.roblox.com/docs/scripting/capabilities).

When upgrading from an older running version, close its panel before loading the new version. Re-running while a panel exists focuses that running instance, avoiding duplicate schedulers. Already-sent calls cannot be canceled by closing the UI.

## Existing protocol

The client only reads the equipped object path:

`Players.LocalPlayer.Character → PaintBucket → Remotes → ServerControls`

Every invocation retains the existing arguments:

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

The FIFO grants **one request per visit**, then moves the province to the back if it can accept more. An initial set of dirty provinces receives a first pass before extra passes. A newly selected province joins the existing FIFO order; a previously queued province may still have one earlier ticket, but cannot repeatedly jump ahead. At most one ready ticket exists per selection.

A part's outstanding count survives remove, Clear, re-add and respawn. Changing target color waits for all previous-color calls to that part to drain, preventing overlapping contradictory colors. Switching to a lower-concurrency mode also lets already-sent calls drain instead of pretending to cancel them. Once the desired visible color is observed, new requests stop until it differs again; already-sent contributions may still finish.

## Congestion, errors and limits

The adaptive global window uses **non-throwing return rate, round-trip latency, actual invocation errors, and capacity pressure**. It never uses missing color observations to shrink the window. Higher windows are retained when return throughput improves without excessive latency; lower-window probes can retain the same throughput with fewer outstanding calls. Set `Adaptive = false` for fixed-window comparisons using each mode's Initial setting.

Only an actual thrown `InvokeServer` error triggers per-province exponential backoff, starting around 0.2 seconds and capped around 5 seconds with ±10% staggering. An older successful sibling cannot erase a newer error's cooldown. Old selection/remote results release their own accounting without applying their cooldown to a newly selected province or replacement remote. Nil, false and other non-throwing server returns are recorded as returns; no acknowledgment contract is invented.

There is no color-confirmation waiting period or unconfirmed-color penalty. A healthy return can immediately refill a same-province slot while the visible color remains unchanged.

The **64-call hard outstanding cap** includes old-remote and stalled calls. After 15 seconds an unreturned call is marked stalled, retained in its part's count and the hard cap, and excluded from the healthy Normal/Fast adaptive window. Other provinces may use spare hard capacity. Safe retains its total one-call limit even for stalled calls. If all 64 calls never return, dispatch stops; a client timeout cannot cancel a server operation or safely fabricate released capacity.

Rate, burst and per-frame budgets apply independently of the concurrency window. No task is created to wait for capacity. One task is created only after reserving a real request slot. Retry timers are bounded to one per selected province; correct/idle provinces are not scanned each frame.

## Controls

- **Country Color:** click a province to copy its color. Done/Cancel or Escape cancels selection.
- **Protect / Unprotect Province:** select or remove provinces, then Done. Repeated Add clicks do not register duplicates.
- **Clear Provinces:** remove every selection, outline, per-part listener, ready ticket and retry timer. Bounded real pending-call records remain until those calls return.
- **Toggle Paint / Q:** pause or resume new dispatch; in-flight calls remain accounted for.
- **Fast Paint:** enable the higher request rate/window and six-per-province default.
- **Safe Mode:** override Fast with conservative pacing and one total outstanding call.
- **Keep Territory Color:** use the selected color when each province was added, preserving both reference scripts' semantics. It does not capture the province's preexisting color.
- **Randomize Color / R:** choose a random RGB color. While Keep Territory Color is on, existing selections keep their saved target colors.
- Drag the top bar to move the panel; close × to stop and clean up. Selection boxes adorn real parts instead of cloning geometry. Decorative sounds and animation loops are omitted.

## Telemetry

The primary display is **returns/sec**, not claimed successful hits or paints. The secondary display shows target-color matches/sec, active/window, stalled calls, and cumulative errors.

`GetStats()` exposes Attempted, Returned, Failures, Observed, Stalls, Selected, Ready, Delayed, InFlight, Stalled, Window, MaxPerProvince, PendingProvinces, RTT, RemoteReady and Running. `Observed` counts mismatch-to-target observations once per selected province transition, independently of how many calls overlap. It can include another player's color change and can miss transient changes between replication updates. Retargeting to a color already visible is not counted. The previous `Unconfirmed` field and color-confirmation settings were removed.

## Validation

Run the actual final source through the deterministic Luau mock suite:

```sh
python3 tests/run_tests.py /path/to/luau
```

The revised suite has 57 passing tests. It covers controlled same-province overlap, one-slot-per-visit fairness, multi-contribution captures, no-color-change returns, nil/false returns, actual-error backoff, out-of-order completions, color barriers, clear/remove/re-add, respawn, stalled hard caps, independent players, lifecycle cleanup and the exact public loader path. Both runtime and loader compile with the official Luau compiler.

These are simulated correctness/performance tests, not a live-game benchmark. In a fixture requiring 24 contributions at 200 ms simulated latency, Fast capped at one per province took 5.15 seconds; Fast capped at six took 0.85 seconds. Actual performance depends on server behavior, throttling, network latency, replication and FPS. See [ANALYSIS.md](ANALYSIS.md) for the review and revision details.
