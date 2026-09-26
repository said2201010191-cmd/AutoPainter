# Native-input architecture and limits

The user's completed game-only report covered 165 unique scripts/modules, with 165 returned texts and no failures, timeouts or skips. The two reported PaintPart call sites were the equipped and StarterPack copies of the normal PaintBucket client. No separate stored-target or batch path was found in that snapshot. This supports using the existing private-server hold behavior; it does not reveal hidden server checks.

## Runtime responsibilities

AutoPainterFinal.luau contains no game remote invocation, callback replacement, source inspection, require, mouse-target assignment, synthetic event firing, moderation interception or tool-function invocation. LocalPlayer is resolved dynamically for each client.

The native tool owns its real Mouse.Target/Hit, the PaintPart payload, remote discovery, Peace/War mode, upgrade cooldown and the private-server repeat loop. AutoPainter controls only its own UI/selections, the existing PaintBucketColor attribute, a real local camera when enabled, and the available native cursor/button APIs.

The old concurrency window, tokens, adaptive RPC tuning, per-province request limits and RPC retry workers are absent from the active native runtime. They do not fit this native hold model. Native tool/server concurrency is not observable or controlled by this script.

The separate AutoPainterDiagnostics.luau keeps the read-only collector and historical selection/reporting scaffold. Its transport implementation is removed and its diagnostic lock is unconditional.

## Capabilities and explicit test

The controller checks these environment functions without calling them at startup:

- mousemoverel, preferred for movement from the actual UserInputService mouse location.
- mousemoveabs, fallback when relative movement is unavailable.
- mouse1press and mouse1release.
- isrbxactive, optional additional focus check.

No VirtualInputManager, fireclickdetector, firesignal, hook, debug callback access or invented fallback is used. Missing functions disable input. The Cursor API selector can explicitly choose Relative or Absolute for another manual test; changing it invalidates the previous input-test result. “Callable” reports only the exposed function types, not a verified implementation or an attestation of hardware input.

TEST NATIVE INPUT requires an explicitly chosen, committed, visible province and an equipped, enabled PaintBucket on a living character. It never rotates the camera. After moving the cursor it requires the exact actual Mouse.Target, a clear GUI location and a short stable-target period before pressing. The controller subscribes normally to Mouse.Button1Down/Button1Up to check delivery; it never invokes those event callbacks itself.

PASS covers observed input events and AutoPainter's structural absence of game RPCs. It cannot prove the native tool received those same events, updated its cached color, painted successfully or drained a server call. AutoPainterRPCs=0 is not a network interception measurement. Native request counts, returns and failures remain explicitly unobserved.

The environment owns the semantics of its input functions. An external input function that blocks the entire client cannot be interrupted by Luau. Verify the result in the real client before enabling automation.

## Selection and color

Add only creates a lookup entry, snapshot color and SelectionBox. Done/Cancel commits the current additions atomically. All selection tools suspend native input without changing the Auto Paint toggle. Escape is intentionally an emergency stop and also finishes the selection session.

The normal target constraint is exact: a BasePart's immediate Parent must be workspace.Provinces. Its Name need not be Province. Nested descendants do not qualify.

Keep Territory Color OFF: committed provinces follow the current global color. ON: each uses its registration color. A pending province retains the color selected when clicked, including when R is used between clicks. The global swatch and native manual bucket follow the global selected color while the controller is idle.

During a held per-province target, the existing PaintBucketColor attribute temporarily carries that target's saved color. After observed button-up it restores the global color. Do not manually paint while automation owns the cursor/button. Palette changes release the current hold before retargeting. No Color property on a game province is written.

The user supplied the normal palette's attribute writer. The exact native listener and local-variable refresh behavior still need live verification; attribute equality alone cannot prove the tool's cached payload color changed.

## Dirty set and priority

Color/ancestry events maintain an array plus lookup map; no full-table polling is performed every frame. Pending/correct provinces do not enter the dirty set. Removal uses swap-remove and disconnects all selection listeners.

A selection decision takes a finite snapshot of dirty entries and evaluates at most 48 candidates per frame. Rapid color changes do not continuously restart that decision. Projection is a cheap visibility preference; actual aiming also checks ray hits and the real mouse target. Unreachable attempts get a short retry interval so one obstruction cannot monopolize the controller.

Scoring prefers the selected priority target, visible targets, recent changes, repeated contention, camera alignment and waiting time. After 12 seconds of eligibility, the oldest waiting candidate takes precedence over ordinary scores. A completed visit resets its waiting time. This prevents a permanent priority target from starving other eligible provinces; it is not a 12-second service guarantee for arbitrarily many targets.

Camera Automation can first rotate from its existing position, then try two bounded-distance viewpoints near a target. It does not teleport the character, modify the tool, remove obstacles or fabricate raycast results. Visible Only prohibits those camera moves. Failed targeting remains a coverage/reachability issue, not permission to bypass it.

## Settings near the top of AutoPainterFinal.luau

| Setting | Default | Meaning |
|---|---:|---|
| TargetDwell | 2.5 s | Maximum ordinary hold duration |
| PriorityDwellMultiplier | 2 | Longer hold for the priority target |
| MaxDwell | 12 s | Hard hold-duration clamp |
| TestHold | 0.35 s | Explicit input-test hold |
| ReleaseGap | 0.6 s | Minimum settling gap after up, not an RPC-drain guarantee |
| InputEventTimeout | 0.6 s | Missing input acknowledgment detection |
| AimTimeout | 2 s | Abandon an unsuccessful targeting attempt |
| AimRetry | 1 s | Per-target delay after a visit/failure |
| TargetStableSeconds / Frames | 0.10 s / 2 | Real-target stability before down |
| ColorSettle | 0.10 s | Local color-listener settling margin |
| CandidatesPerFrame | 48 | Bound on priority evaluation per frame |
| AgingSeconds | 12 s | Threshold for oldest-eligible-first selection |
| CameraAutomation | ON | Permit local camera control when Auto Paint starts |
| VisibleOnly | OFF | With ON, leave the camera where it is and use visible targets |
| CameraMinDistance / MaxDistance | 35 / 1200 studs | Candidate camera-to-target distance bounds |

The UI controls Auto Paint, camera automation, visible-only, dwell, priority and emergency stop. Auto Paint remains OFF until the explicit input test passes. There is no public-server per-cooldown click fallback: where the native tool does not repeat on hold, a hold may produce only one paint.

## Release, cleanup and races

One central Heartbeat state machine owns input; there are no per-province tasks or request workers. New target selection, camera movement and target-color changes wait for a real button-up observation and the release gap.

Failed release calls retry at most three times. Missing up acknowledgment or release failure prevents another press and asks for a manual release. Normal shutdown disconnects all listeners and removes highlights. If button release remains unresolved, a hidden controller with one manual-up listener prevents normal loader reruns until release is observed. Forced external destruction of that guard cannot be treated as a safe cancellation of native input.

The controller releases when the target changes, the province is removed/destroyed, the tool is unequipped, the character dies/respawns, a menu/text box takes input, the cursor is locked, focus is lost or the user stops. It restores its camera when still owned and does not overwrite a replacement camera. Respawn can resume an already-enabled session only after a living character has the normal bucket equipped. It does not auto-equip the bucket.

**Native-loop timing remains unresolved.** The supplied excerpt has a shared holding flag around a yielding doPaint. If that native doPaint is waiting inside InvokeServer when up occurs, and the flag is set true by a new down before the old call returns, the original loop might resume alongside a later loop. The 0.6-second gap reduces ordinary overlap risk but cannot prove drain or prevent it under arbitrarily long latency. AutoPainter cannot count/cancel those native calls without the forbidden interception or cooperation from the tool. The exact complete native loop, sameMouse handling and color listener are still needed to assess this fully.

Likewise, a user moving the cursor can race the native tool's own task before AutoPainter observes target loss. This controller cannot make an atomic guarantee that the unmodified native tool never paints the new real target. Keep hands off the mouse during a hold and use Escape to stop. No server acceptance, moderation immunity or live throughput guarantee is claimed.

## Validation

344 tests pass: 98 exercise the actual native runtime with immediate/deferred event delivery, and 246 exercise the separate locked diagnostic collector. Tests cover capability absence, the exact UI selection/test path, genuine-target mismatch, native event acknowledgments, one down across native repeats, dwell/fairness, camera restore, occlusion, manual-button ownership, color/Keep semantics, late release, failures, cancellation, duplication, respawn, cleanup and zero direct game transport.

Mock camera/raycast/input geometry verifies controller decisions, not Roblox rendering, OS coordinates or a particular executor implementation. A real live input test is required.

API references: [Roblox Mouse](https://create.roblox.com/docs/reference/engine/classes/Mouse), [Camera projection](https://create.roblox.com/docs/reference/engine/classes/Camera#WorldToViewportPoint), [GUI hit testing](https://create.roblox.com/docs/reference/engine/classes/BasePlayerGui#GetGuiObjectsAtPosition). Candidate executor names follow the [UNC input names](https://github.com/unified-naming-convention/NamingStandard/blob/main/UNCCheckEnv.lua); they are detected locally rather than assumed available.
