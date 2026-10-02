# Hands Free v6 — adaptive paint service and immediate defense

The live reports established that VirtualInput.SendMouseButton reaches Mouse.Button1Down and can paint, while v5's fast acquisition and continuous hold produced poor correction throughput. Civil War completed its targets. v6 preserves that targeting/camera code and Civil War palette preparation, then compares fresh activation with continuous hold using real selected-target outcomes. This new revision still requires live validation; deterministic tests cannot establish Roblox throughput.

## Public client loader

Close the previous Hands Free panel before loading v6. Duplicate loads deliberately return the existing controller.

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/said2201010191-cmd/AutoPainter/main/AutoPainterHandsFree.luau", true))()
```

The public file needs no credentials, Studio, place edits or server installation. Players.LocalPlayer supplies each player's independent state. Run only one painter controller at a time. AutoPainterFinal and the locked diagnostics remain separate and unchanged.

## NORMAL activation policy

`ActivationStrategy = "ADAPTIVE"` starts with PER_TARGET, based on the stronger recent live evidence for fresh activation. It then collects at least four completed target services for each strategy:

- PER_TARGET: acquire genuine Mouse.Target, VirtualInput DOWN, wait for correction or the full adaptive dwell, then paired UP. There is no extra between-target sleep.
- CONTINUOUS: retain the same DOWN across verified selected targets; color events advance immediately. Camera recovery, real target/input/tool/focus loss, stop, or no eligible dirty work releases it. One missed paint opportunity does not retire the method or force a release when another target is ready.

The comparison uses observed success rate, corrections per work-second, and acquired-to-color latency. Per-strategy work time includes targeting, paired-release overhead and deferred retry waits; fully clean idle is excluded. A 20-percentage-point success-rate difference or a 20% throughput improvement is meaningful evidence. Close results prefer PER_TARGET. At least two held transfers are needed to support CONTINUOUS; singleton fresh holds cannot prove its advantage. Sparse/inconclusive samples may extend to eight services per strategy, after which PER_TARGET is an explicitly unproven fallback if neither succeeds.

The decision is cached for the equipped-tool session. It does not oscillate on every target or stall. A new NORMAL equipped session starts a new sample. The one-time START palette preparation includes equipping, so a fresh START can establish a new equipped session. While stopped, `SetActivationStrategy("PER_TARGET")`, `SetActivationStrategy("CONTINUOUS")` or `SetActivationStrategy("ADAPTIVE")` allows controlled comparisons and clears prior policy evidence. The same setting is near the top of the file.

These are small observational samples of real target work, not a randomized causal experiment. Different target difficulty, native cooldown, replication and server timing can affect the result. Input API return speed is never a success criterion. Corrections can also have another player's cause; the report does not claim server acknowledgment.

VirtualInput stays primary. Mouse.Button1Down plus desired-color observation confirms it for the equipped session. Only repeated actual input errors/missing down observations, or API unavailability, unlock the existing sequential alternate-method recovery. Unchanged province color alone does not trigger mouse1press or Tool:Activate testing.

## Dwell and retries

Default target dwell is **0.32 seconds**, clamped to **0.20–0.45 seconds**. After four successful observations, each strategy learns from the 90th percentile of its last 24 acquired-to-color times plus an 80 ms margin. Decreases are limited to 20 ms per success. A full-window miss raises the limit by 40 ms, up to 450 ms, to avoid learning only from the fastest successes. Civil War has its own history.

Dwell starts only after genuine acquisition and observed activation are valid. A successful target-color event ends service immediately; the limit is not a mandatory delay. Acquisition taking another frame does not count as a paint stall. Only a valid service that remains wrong through the full dwell increments Stalled. Targeting/input preparation failures are separate deferrals.

Stalls retry after 0.12 seconds, doubling up to 1.6 seconds. Targeting failures start at 0.40 seconds. A fresh wrong-color event resets that target's retry delay and grants recent-attack priority. Other targets continue while one waits. The single worker wakes for color changes and retry deadlines; there is no task per province.

## Hover-independent dirty engine

For every protected entry, the dirty decision is solely:

```lua
entry.part.Color ~= targetColor(entry)
```

NORMAL returns the captured global normalTarget; CIVIL WAR returns entry.civilColor. Mouse.Target is consulted for acquisition, activation validation and diagnostic observation only, never to determine dirty eligibility.

Each selection subscribes to ColorChanged. Wrong color inserts it immediately in the dirty set and wakes the one worker; correct color removes it immediately. A separate intrusive recent-attack queue makes a newly recolored entry directly available without traversing earlier selections. Its priority lasts one second. Bounded rotating dirty traversal and two-second aging prevent a continuous stream of fresh attacks from starving older work. An already active target completes or reaches its bounded dwell before another takes over.

Every 0.15 seconds, a reconciliation sweep reads selected province colors and repairs membership. It directly performs no cursor, camera or input operations; repairs wake the ordinary worker. This is intentionally O(number of selections) at about 6.7 sweeps/second, rather than a per-frame scan. Clean provinces otherwise retain only their listeners/cache; they are not hovered or targeted. A clean reconciliation does not wake an idle worker. Destroyed/removed entries are swap-removed and disconnected.

Event diagnostics record callback receipt time, whether the real cursor was over that province, its queued state, and callback-to-queue latency. This proves local queuing without hover; it does not measure the unknown server-to-client replication delay or events never delivered to the client. ReconciliationFinds separately counts membership repairs.

## Targeting and color modes

Cached cursor point → visible surface projection → cached camera pose → original camera fallback remains the targeting order. Fresh/aged queue priority can precede the ordinary cache tiers. Genuine Mouse.Target must match before relying on native painting. The original camera-acquisition block is byte-for-byte protected by a regression hash.

NORMAL captures the normal bucket's exposed PaintBucketColor at START. It does not rewrite the palette or re-equip per province. Choose the color in the native palette first. The attribute by itself is not proof of the native LocalScript's cached color; verify with ordinary manual painting before a run. Changing the global palette while running stops NORMAL for an explicit restart.

CIVIL WAR preserves its working unique colors and release/attribute/re-equip preparation. It uses fresh per-target activation because different colors already require a release boundary. It shares dirty detection, reconciliation, recent-attack priority, target caches, adaptive dwell and retries. Civil War evidence does not contaminate NORMAL's strategy benchmark, and its dwell history survives its planned per-target equips.

Camera fallback releases first. Keeping DOWN while sweeping the map could let the normal tool paint intervening unselected tiles. Direct cursor jumps allow the previous protected target briefly while mouse state propagates; unexpected targets trigger release when observed. The client cannot atomically control an independent native callback or cancel requests the native tool already sent. No spoof or interception is used to hide that limit.

## Exact live procedure

1. Close v5 and load v6. In the private-server environment where native painting was confirmed, choose the desired color through the normal palette and verify one ordinary manual paint. Holster while selecting so native selection clicks do not paint.
2. Select about **12 visible wrong-color provinces** plus one already-correct province. Finish selection; leave NORMAL and the default ADAPTIVE setting. Press START once, then leave physical input alone.
3. Expect PER_TARGET first, followed by a small CONTINUOUS sample. Watch ActivationStrategy and the result in Copy Activation Report. At least four completed services per strategy are needed; if fewer targets stay dirty, more externally recolored targets may be needed to finish sampling. No artificial recolors or test paints are generated by the controller.
4. Let the chosen strategy run for 20–30 seconds under comparable contest conditions. The useful results are actual corrections, success rate and attack-response time. Acquisition rate alone is not the goal. A clean map naturally makes rolling corrections/sec fall to zero.
5. For the hover test, wait until DirtyCount=0, put the real cursor over selected Province A, and have a friend recolor selected Province B without moving your cursor toward B. AutoPainter should wake and acquire B itself. Afterward the report must contain B's full path, `ColorChanged received=true`, `Hovered at event=false`, `Dirty queued=true` and queue latency. Physical positioning here is only for the diagnostic setup, not required for automation.
6. Repeat B's recolor several times and compare cached cursor hits, FreshAttackCorrections and response latency. Include one contested target; it must not hold up all other work. Test an offscreen target afterward to exercise camera recovery.
7. Press Q/Escape to stop, then **Copy Activation Report** promptly. Clipboard fallback is `AutoPainterActivationReport.txt`. Copy exports existing observations; it does not activate input, inspect scripts or change game state. OverallCorrectionsPerSecond remains useful after stopping; rolling CorrectionsPerSecond decays after the last correction.
8. Test CIVIL WAR separately with a fresh load for isolated totals. Verify all colors finish and external recolors wake defense. Finally check focus loss, unequip, Clear, respawn and close release held input.

Send the **entire Copy Activation Report**, especially:

- Activation method/observation, SessionConfirmed, ActivationStrategy, StrategyDecisionCached and StrategyDecisionReason.
- PER_TARGET and CONTINUOUS attempts/successes, rolling success rates, corrections/sec, WorkSeconds, average service/color times and RetainedAttempts.
- DirtyCount, Attempts, CompletedServices, SuccessfulPaints, SuccessRate, rolling and OverallCorrectionsPerSecond, AdaptiveDwellMs, Deferred and Stalled.
- ColorEventsReceived, DirtyEventsWithoutHover, Average/MaxColorEventToDirtyQueueMs, ReconciliationFinds and the off-cursor event block.
- FreshAttackCorrections, AverageAttackColorChangeToCorrectedMs, Minimum/MaximumAttackResponseMs and RecentlyChangedQueueDepth.
- AverageAcquisitionMs, AverageSwitchMs, cache hits, CursorAcquireSuccessRate, CameraFallbackRate, hold state, DownEvents and UpEvents.

## Metric definitions and APIs

Global event/correction/defer counters and timing means accumulate since load. Attempts counts qualified native services, not RPCs. CompletedServices excludes interrupted services; AbortedServices is separate. SuccessfulPaints means target-color transitions observed during a valid held service, not proof of server causality. DownEvents/UpEvents are observed PlayerMouse events and may also include physical input. AverageTargetDwellMs includes service through release; AdaptiveDwellMs is the current maximum hold window.

Global corrections/sec and acquisitions/sec use approximately five-second rolling bins. OverallCorrectionsPerSecond divides all observed corrections by accumulated running time, including clean idle. Each strategy's rates and means use its last 16 completed services and attributed active-work time, including retries; clean idle is excluded. Civil War has a separate statistics block. Deferred/Stalled count events, not unique provinces. FreshAttackCorrections counts service corrections following observed wrong-color changes; response time starts at the local callback/reconciliation observation, not the unseen server mutation.

The latest 24 wrong-color event records and a last-off-cursor record are retained as strings/numbers only. `GetTargetStats(part)` exposes timestamps, last seen/target colors, dirty membership/insertion, cached points/pose/geometry, acquisition duration/failures and retry time. APIs also include `GetPerformanceStats()`, `GetPerformanceReport()`, `GetDirtyEventReport()`, `CopyActivationReport()` and `SetActivationStrategy(value)` while stopped.

## Boundaries and validation

AutoPainter sends **zero game RPCs**. The normal PaintBucket owns all paint requests and its cooldown. There are no Mouse.Target writes, ClientControls/GetMouseData hooks, metamethod hooks, protected-signal firing, validator replacement, script execution/require/decompile or moderation concealment. Input calls and releases remain serialized; no second worker can take cursor/camera/input ownership during pending cleanup.

Run `python3 tests/run_tests.py /path/to/luau`.

**614 deterministic tests pass:** 222 legacy native-controller, 246 locked-diagnostic and 146 Hands Free tests (73 scenarios under immediate/deferred signals). All **25 Luau files compile**, stripping only the original reference's Markdown fence in a temporary compilation copy. Standalone analysis has only unavailable Roblox/executor globals/types; it is not a Roblox-engine type-check pass.

New tests cover both benchmark winners, minimum samples, inconclusive evidence, per-session caching, singleton limitations, adaptive dwell/slow successes/stalls, valid-input timing, early release, off-cursor/offscreen dirty events, lost-signal reconciliation, fresh priority and aging, retry-work accounting, Civil War isolation, bounded logs/windows and lifecycle cleanup. They model native behavior and do not demonstrate that this version fixes live throughput.
