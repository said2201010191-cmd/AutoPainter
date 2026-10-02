# Hands Free v5 — continuous native hold

The user's live test confirmed `VirtualInput.SendMouseButton → Mouse.Button1Down → target color observed`. This revision builds on that evidence. NORMAL keeps one native hold across visible province targets, moves the genuine cursor, and uses ColorChanged events to advance immediately. It never sends a game RPC. The new continuous-targeting build has deterministic tests, but no live throughput benchmark yet.

## Loader

Close the previous Hands Free panel, then run:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/said2201010191-cmd/AutoPainter/main/AutoPainterHandsFree.luau", true))()
```

The file must be publicly readable. No Studio, place editing, server installation, credentials, or account-specific objects are required. Duplicate loads return the existing controller, so close v4 before loading v5. Run only one painter controller at a time. AutoPainterFinal, its loader, original reference files, and the locked diagnostics remain separate and unchanged.

## Fast NORMAL path

1. Choose the desired color through the normal bucket palette. START captures the exposed PaintBucketColor as the single desired color, using the existing one-time equip/palette preparation.
2. Color signals maintain a dense dirty set with constant-time insertion/removal. Correct and unprotected provinces receive no scheduling work. START/mode changes rebuild eligibility once; there is no clean-province patrol.
3. Prefer a cached cursor point, then another visible surface point, then a cached camera pose, then the existing camera search. Validate the visible ray and interactive GUI state, move the real cursor, and require the genuine PlayerMouse.Target to equal the selected province.
4. Use VirtualInput first. Mouse.Button1Down plus a target-color transition confirms it for the equipped-tool session. It is retained across targets; source inspection, mouse1press and Tool:Activate trials do not run per province.
5. Keep Mouse1 down while moving directly between usable visible targets. A matching ColorChanged event immediately makes the target clean and wakes the same worker. There is no fixed dwell or release gap after success.
6. A target still wrong after 0.22 seconds is temporarily deferred. Continue other eligible work; retry later. An unchanged color does not invalidate the input method or claim the native contribution failed.

There is one worker and one wake event, not a task per province. Target selection scans a bounded rotating window of dirty entries. Aging promotes waiting targets over the normal cache/visibility tiers. Cursor projections and raycasts share frame budgets; at most eight target transitions run before yielding to the next frame. The original proven camera-acquisition block is byte-for-byte preserved as the final fallback.

Each target caches its screen point, world surface point, camera pose, geometry, acquisition duration, recent failures and retry deadline. Moving/resizing a province invalidates its geometric cache. Cached visibility is still ray-checked and real Mouse.Target remains authoritative.

## Release and recovery boundaries

NORMAL retains the hold across verified visible cursor jumps. It releases for STOP, focus/tool/target loss, no eligible dirty work, camera recovery, input errors, selection, Clear or closing. Eight consecutive no-effect targets also cause a hold restart while retaining the same activation method. Unexpected native mouse-up stops automation. Q or Escape stops and restores the saved camera.

Camera fallback releases first: sweeping a camera while held could paint unselected provinces under the cursor. After a verified target is acquired, a new down resumes the native loop. Camera state otherwise remains in place between targets; it is restored when automation stops.

A cursor update can take time to propagate. The controller permits the previous protected target for up to 0.035 seconds during a direct jump, then releases if the intended target is not acquired. An unexpected/unprotected target causes release as soon as observed. This cannot make independent native input, mouse callbacks and server processing atomic. A native request already sent during cursor propagation can finish later; zero unintended native paints cannot be guaranteed. No callback interception or fabricated mouse state is used to hide that limitation.

Actual VirtualInput errors or missing Mouse.Button1Down on three holds unlock the existing bounded alternate-method recovery. A missing VirtualInput API allows recovery immediately. Alternate methods are tried sequentially with paired release and observable evidence; they do not use the fast continuous-VirtualInput path. A failed release blocks further input ownership. Target-color stalls alone never trigger activation-method rediscovery.

## Settings near the top of the source

| Setting | Default | Controls |
|---|---:|---|
| NoEffectWindow | 0.22 s | Maximum ordinary no-effect target service window |
| Retry / MaxRetry | 0.08 / 1.6 s | Initial/exponential maximum stall deferral |
| UnreachableRetry | 0.40 s | Initial targeting-failure deferral |
| CursorAcquire | 0.10 s | Real cursor-target acquisition deadline |
| HeldCursorGrace | 0.035 s | Previous protected target allowance during a cursor jump |
| PriorityAge | 2.0 s | Promote waiting dirty targets over normal visibility tiers |
| CandidatesPerStep | 32 | Dirty candidates considered per decision |
| PointsPerCandidate | 9 | Maximum surface samples per candidate |
| MaxProjections / MaxRays | 96 / 32 | Shared per-frame fast cursor-solver budgets |
| MaxTransitionsPerFrame | 8 | Bound immediate target transitions |
| StallsBeforeHoldRecovery | 8 | Consecutive stalls before paired release/restart |

The preserved camera fallback has its own bounded deadline/rendered waits. These settings do not modify or reproduce the normal tool's paint cooldown. The short watchdog trades longer single-target holds for faster rotation; tune it from live evidence if native/server latency exceeds it.

## CIVIL WAR and color authority

NORMAL uses one color and does not write the attribute or re-equip per target. Changing the global bucket color while NORMAL runs stops it so the user can restart with the new color. The exposed attribute alone is not proof of the native LocalScript's cached color; verify the normal palette by manually painting before the automated run.

CIVIL WAR retains unique colors per protected province and the existing release/attribute/re-equip preparation between different colors. It uses the same dirty set and targeting caches but necessarily has extra palette/equip delay. Its native cached-color propagation needs separate live verification. It does not slow NORMAL's target-switch path.

Selection pauses automation. Finish selection, then explicitly START. Holster the bucket while selecting if ordinary selection clicks would activate the game's independently running normal tool.

## Telemetry

The running panel is a non-interactive label so it does not consume automated cursor input. Copy Activation Report exports existing activation and performance observations, using setclipboard or the fallback `AutoPainterActivationReport.txt`. Copy never starts painting or inspection.

- Active target, dirty count and VirtualInput hold state describe current controller state.
- Acquisitions/sec and corrections/sec use a rolling approximately five-second window (the first second is normalized to one second).
- Average acquisition time measures target service acquisition, excluding palette preparation. Average acquired-to-color time measures the observed wait after a genuine target acquisition. A correction during a yielding cursor call is counted once with zero post-acquisition wait.
- Average switch time runs from a correction to the next acquisition, including intervening recovery/deferral work. Intentional clean-idle time is excluded.
- Cached cursor hits, cached camera hits, full camera searches, Deferred and Stalled are cumulative event counts since loading. Deferred/Stalled are not counts of distinct or currently waiting provinces.
- SessionConfirmed means Mouse.Button1Down and desired target color have both been observed in that equipped session. It does not imply a server acknowledgment or causal proof.
- AutoPainterRPCs remains 0. Native bucket requests are not intercepted or counted.

APIs: `GetPerformanceStats()`, `GetPerformanceReport()`, `GetTargetStats(part)`, `GetActivationReport()`, `CopyActivationReport()` and `GetStats()`. The display updates every 0.15 seconds; it does not scan all selected provinces.

## Live test procedure

1. Close the old controller and load v5. In the private-server environment where native hold was confirmed, choose the desired color using the normal palette and verify one ordinary manual paint.
2. Holster while selecting three visible wrong-color provinces and one already-correct province. Finish selection, leave NORMAL selected and press START. No physical input should be needed after START.
3. Expect VirtualInput.SendMouseButton, Mouse.Button1Down, then target-color observations. With no recovery needed, the three visible corrections should use one DOWN and one final UP when Dirty reaches 0. The correct province must not be targeted. The HUD should show no full camera search for usable visible targets.
4. Have a friend recolor a selected province. It should wake immediately and prefer its cached cursor point. Once clean again, leave it idle and confirm there is no continued automated input.
5. Add an offscreen province. Camera recovery should release first, reuse a cached pose when available, or run the existing camera acquisition. A new hold starts only after the real target is acquired. Expect additional down/up pairs for recovery.
6. Include a contested target with several easy targets. Other targets should continue after the 0.22-second no-effect window; the contested target remains dirty with bounded retries. Compare acquisitions, corrections, switch time and deferrals using Copy Activation Report after stopping.
7. Check Q/Escape, focus loss, unequip, Clear and close release the hold. Test CIVIL WAR separately after NORMAL is verified.

Native cooldown, native loop behavior, input delivery, render timing, replication and server response time remain limits. The continuous-hold route depends on the native tool's repeat behavior; a single-click-only server/tool cannot be made continuous by retaining one DOWN. Observed color changes can also come from other players. No claim is made that this revision is the fastest possible in every client or that a particular corrections/sec rate is guaranteed.

## Validation

Run `python3 tests/run_tests.py /path/to/luau`.

554 deterministic tests pass: 222 legacy native-controller tests, 246 locked-diagnostic tests and 86 Hands Free fast-hold tests (43 scenarios under immediate and deferred events). All 25 Luau files compile; only the original reference's Markdown fence is stripped in a temporary compilation copy. The standalone analyzer reports missing Roblox/executor globals/types; it is not a Roblox-engine type-check pass.

Fast-hold scenarios cover one DOWN across targets, zero clean-idle work, early color-event switching, correction during a yielding cursor call, stalled-target fairness, cache reuse/invalidation, cursor propagation, camera release boundaries, frame budgets, repeated Clear, respawn, tool/focus loss, interrupted/yielding input, late releases, duplicate loads, palette changes, CIVIL WAR separation and zero game RPC calls. The native mock loop validates control flow, not real game throughput.

Roblox API references: [CreateVirtualInput](https://create.roblox.com/docs/reference/engine/classes/UserInputService#CreateVirtualInput), [SendMouseButton](https://create.roblox.com/docs/reference/engine/classes/VirtualInput#SendMouseButton), [SendMousePosition](https://create.roblox.com/docs/reference/engine/classes/VirtualInput#SendMousePosition), [WorldToViewportPoint](https://create.roblox.com/docs/reference/engine/classes/Camera#WorldToViewportPoint). Exposed API restrictions remain intact.
