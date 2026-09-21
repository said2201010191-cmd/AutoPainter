# AutoPainter

`AutoPainterFinal.luau` is the client-side successor to `AutoPainterFastClient.luau`. It keeps the existing game protocol:

```lua
ServerControls:InvokeServer("PaintPart", { Part = province, Color = desiredColor }, "Peace")
```

No new server scripts, remote types, or server batching are required. Both supplied reference files are preserved byte-for-byte. The original attachment includes Markdown fences; those are intentionally preserved in the reference file, not in the runnable final script.

## Recommended setup for your game and friends

In Roblox Studio, create a **LocalScript** under **StarterPlayer → StarterPlayerScripts**, paste the complete contents of `AutoPainterFinal.luau`, and publish your game. Each joining player runs an independent client painter using their own equipped `PaintBucket`. Restrict access using your game's normal play permissions. The repository may remain **private**. Friends do not need GitHub accounts or tokens. This is a client-only installation, not a server redesign.

Ordinary Roblox LocalScripts cannot use the `loadstring(game:HttpGet(...))()` pattern: client-side `loadstring` is not a supported Roblox capability. The external loader below only works in a client environment that already provides both functions. See [Roblox script capabilities](https://create.roblox.com/docs/scripting/capabilities).

## Controls

- **Country Color:** click a province to copy its color; Done/Cancel or Escape cancels selection.
- **Protect Province:** select provinces, then Done. Clicking a selected province does not register it twice.
- **Unprotect Province / Clear Provinces:** remove selection, outlines, listeners, queue entries, and retry timers.
- **Toggle Paint / Q:** pause or resume dispatch. Already-sent operations may still finish.
- **Fast Paint:** use the higher rate limit and adaptive concurrency range.
- **Safe Mode:** overrides Fast Paint with one outstanding call (including stalled calls), a global 4 requests/second ceiling, and at least one second between requests to the same province.
- **Keep Territory Color:** preserve the **selected color at the time each province was added**, matching both supplied scripts. It does not capture that province's preexisting color.
- **Randomize Color / R:** select a random RGB color. While Keep Territory Color is on, this affects new selections and the next normal-color mode.
- Drag the top bar to move the panel. Close (×) stops the painter and cleans up. Re-running the script focuses an existing panel; close it before loading an updated version.

Selection uses outlines on the actual parts, instead of cloned provinces. The box outlines may differ from a mesh province's exact silhouette. Decorative sounds, introductory tweens, and the obsolete external-loader advertisement are omitted.

## Defaults and tuning

All settings are in `CONFIG` at the top of the final file. These are starting values, not measured Roblox limits or guaranteed rates.

| Mode | Initial window | Adaptive range | Request ceiling/sec | Burst | Starts/frame |
|---|---:|---:|---:|---:|---:|
| Normal | 8 | 2–24 | 160 | 8 | 16 |
| Fast | 16 | 4–64 | 360 | 16 | 32 |
| Safe | 1 | fixed 1 | 4 | 1 | 1 |

Each province has **one outstanding request maximum**, including requests from before removal/re-addition or respawn. A request that has returned gets a short 0.10–0.75 second replication grace period only if its requested color is still unobserved. Errors and unconfirmed results use exponential retry backoff, starting around 0.2 seconds and capped around 5 seconds (±10% staggering).

The controller samples every two seconds. Under sustained demand it tests a higher window and retains it when observed paint throughput improves without excessive latency. It also probes lower windows to find the same throughput with fewer requests outstanding. Errors, zero observed paint with repeated unconfirmed results, and latency/throughput regression reduce the window. Small selections and short runs often finish before tuning becomes relevant. Set `Adaptive = false` for controlled comparisons; each mode then keeps its initial window.

`Rate` and `Burst` bound dispatch independently of FPS and latency. They do not promise that many paints/second. Raising them helps only if the rate ceiling is the active bottleneck and the game/server still accepts useful work. At low FPS, `Batch` can also become the bottleneck. Avoid raising `HardOutstanding` without measurements.

## Honest telemetry and outstanding calls

The panel shows **observed paint/s**, returns/s, active/window, stalled calls, selected count, and total errors. Observed paint counts one observation of a requested target color per associated attempt, using real elapsed time. A successful return alone is not a paint acknowledgment. Another player can produce the same color change; without an explicit server acknowledgment the client cannot prove attribution or reliably see every transient intermediate color.

The returned controller's `GetStats()` additionally exposes Attempted, Returned, Failures, Observed, Unconfirmed, Stalls, Selected, Ready, Delayed, InFlight, Stalled, Window, RTT, RemoteReady, and Running. RTT is an exponentially smoothed round-trip estimate. No per-request log grows over time.

After 15 seconds an unreturned call is labeled stalled. It remains in the **64-call hard outstanding cap** and blocks further requests to that province. It stops occupying the healthy adaptive window, allowing other provinces to use any remaining hard capacity in Normal/Fast. Safe Mode keeps its one-call total limit; switching from another mode waits for older calls to drain. Returning or throwing releases its accounting exactly once. Clear, pause, respawn, or a local timeout cannot undo a server operation already sent. Consequently, clear releases all selection state immediately, but the bounded records and arguments for real pending calls remain until those calls return.

If all 64 calls never return, dispatch stops. There is no client-only way to guarantee both unlimited recovery from permanently unreturned calls and a real bound on server work. The script does not pretend that canceling a local coroutine cancels the server request. UI destruction stops new work and disconnects listeners; existing network calls may still complete afterward.

## Public external loader

The repository was **private at implementation time**. Its visibility is not changed by this work. A token-free, anonymous raw loader needs this file in a **public repository**, or an intentionally public static distribution copy. A private repository's browser login does not authenticate a Roblox HTTP request. Never put a PAT, cookie, signed private download URL, or other secret in a client script. GitHub documents access requirements in its [repository contents API](https://docs.github.com/en/rest/repos/contents).

Exact moving-main loader, once this repository is public, in a compatible external client environment:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/said2201010191-cmd/AutoPainter/main/AutoPainterFinal.luau", true))()
```

For reproducible friend sessions, prefer the Studio installation above. If using an external loader, replace `main` with the reviewed full commit SHA to pin everyone to the same version. Public does not mean private distribution: anyone may retrieve a public file. No dynamic loader or credential is required by the final implementation itself.

## Validation

The final source compiles with the official Luau compiler. `tests/` runs the actual script against a deterministic mock of Roblox events, tasks, Instances, and RemoteFunction behavior:

```sh
python3 tests/run_tests.py /path/to/luau
```

Tests cover immediate/deferred event delivery, FIFO fairness, color deduplication, delayed replication, old-color completion, errors, retries, Safe mode, missing/replaced remotes, respawn, stalled calls, destruction, repeated clear cycles, UI shutdown, duplicate loading, adaptive tuning, and rate limits at different frame rates. These tests do **not** replace a Studio/live-game test. No actual-game throughput improvement is claimed as measured. See [ANALYSIS.md](ANALYSIS.md) for the original/optimized behavior review, design rationale, simulated results, and a suggested live benchmark.
