# Fast native-input controller

The user's completed game-only report returned 165 unique script/module texts without failures or timeouts. It found only equipped/template versions of the normal PaintBucket PaintPart call and its private-server hold loop. The user subsequently reported a successful native-input live test without a moderation kick. The faster controller in this revision has not yet been measured live.

## Ownership and color authority

AutoPainterFinal.luau has no game remote calls, callback replacement, hooks, require, script inspection, fabricated mouse targets or native-tool function invocation. Each client uses its own Players.LocalPlayer and independent state. The ordinary tool alone chooses remotes, sends PaintPart, handles Peace/War, upgrade cooldowns, actual Mouse.Target/Hit and repeat-on-hold behavior.

Before starting, choose a color through the **normal PaintBucket palette** and verify it manually. Auto Paint snapshots the exposed PaintBucketColor as DesiredGlobalColor, falling back to white like the normal client. Every protected province uses that snapshot when Keep Territory Color is OFF. Start does not write an attribute or claim to refresh the equipped tool's cached local color. An attribute change during automation stops the session; finish choosing in the normal palette and explicitly restart.

Country Color/Pick, Randomize, R and api.SetColor now change a clearly labelled **preview swatch only**. api.GetColor returns that preview; api.GetDesiredColor and GetStats().DesiredGlobalColor return the actual target snapshot. Starting Auto Paint resets the preview to the palette snapshot. These controls cannot reliably select the normal tool's payload color through the currently confirmed protocol, so they no longer write PaintBucketColor. No game color property is written.

Keep Territory Color ON preserves the palette color captured when each province was clicked, including pending selections. Later global palette changes do not replace those snapshots. A wrong-color saved target is serviced only when its saved color matches the current palette snapshot. Other saved colors remain dirty and appear as **Waiting for palette**; they receive no camera/cursor/hold work. Choose their color through the normal palette and restart to service them. Mixed-color automated native painting needs a confirmed legitimate cache-refresh route; attribute writes alone are insufficient.

## Strict eligibility and selection

A target must be a committed protected BasePart with immediate Parent equal to workspace.Provinces, and its actual Color must differ from its desired color. A correct province is removed from the dirty set by its Color signal. New wrong colors enter immediately. The controller rechecks actual Color before selecting, aiming, moving the camera and pressing, covering delayed signal delivery. Pending and unprotected provinces never enter the automatic work set. The explicit input test also refuses an already-correct province.

Protect only registers/highlights pending entries. Done/Cancel commits them together without turning Auto Paint on. Selection suspends existing automation and restores its camera. Escape stops and finishes the selection session. Remove disconnects the entry's listeners and clears its state; Clear stops and removes everything. Holster the normal bucket while manually selecting: AutoPainter cannot suppress legitimate clicks received independently by an equipped tool.

Protected, Wrong Color and Correct Color count committed selections; Pending is separate. Dirty is the Wrong Color count, including any saved colors waiting for the normal palette. With no dirty entries there is no selection scan, cursor movement, camera movement or generated button input. The small status update and one central Heartbeat remain active.

## FAST and NORMAL

All timings below govern the controller's targeting/input, never the tool's paint cooldown.

| Setting | FAST (default) | NORMAL |
|---|---:|---:|
| Ordinary TargetDwell | 0.45 s | 0.90 s |
| PriorityDwellMultiplier | 1.75 | 1.75 |
| MaxDwell | 2 s | 2 s |
| ReleaseGap | 0.10 s | 0.25 s |
| AimTimeout | 0.75 s | 1.50 s |
| AimRetry | 0.20 s | 0.40 s |
| CursorInterval | 0.025 s | 0.050 s |
| TargetStableSeconds | 0.03 s | 0.08 s |
| TargetStableFrames | 1 | 2 |
| IdleRetry | 0.08 s | 0.20 s |
| CandidatesPerFrame | 128 | 64 |

The separate explicit test has a 0.35-second maximum hold. There is no ColorSettle delay because the controller no longer changes native color state between targets. Profile changes reset the editable base dwell. Dwell can be adjusted from 0.25 to 2 seconds in the menu.

While holding, a Color signal that observes the desired result releases immediately. Otherwise the maximum is base dwell plus 0.25 seconds per decaying contention point, with the added amount capped at 1.05 seconds. Each wrong-color change adds a point; points decay over 20 seconds. Thus fresh contention produces approximately 0.70 / 0.95 / 1.20 / 1.45 / 1.50 second FAST caps. Priority multiplies that cap by 1.75, still bounded by 2 seconds. The cap is fixed at button-down so further events cannot extend one hold indefinitely. Priority never overrides correct-color exclusion or fairness.

## Target choice and bounded work

Color/ancestry events maintain arrays plus identity/index maps; removal uses swap-remove. There is one Heartbeat controller and no per-target worker/task backlog. Each decision snapshots only dirty entries, processes at most the profile's candidate budget per frame, and shares a hard budget of **32 raycasts per frame** with aiming. Exhausting that budget yields the decision until the next frame; it does not masquerade as an occlusion or trigger camera movement.

Visible means a candidate projects onscreen outside blocking UI and an unobstructed ray hits that exact part. Among visible candidates, cursor distance wins, then waiting time, then decayed contention, then stable registration order. After **4 seconds** of waiting, the oldest visible target overrides distance. This is a priority-aging threshold, not a universal service-time guarantee.

An offscreen candidate normally waits while visible work exists. To avoid permanent starvation under continuous visible contention, after **8 visible visits**, an offscreen target that has waited at least 4 seconds receives an aging turn. When no visible target is eligible, camera alignment favors the smallest rotation. Visible Only disables all offscreen attempts, including aging turns. A priority target receives extended dwell rather than monopolizing selection.

Six surface offsets are transformed and cached per selected part, refreshed when CFrame or Size changes. The last successful offset is tried first; a failed ray invalidates that preference. Projection and ray hits are always revalidated for the current camera/occluders. Camera motion does not endlessly restart a large decision. A genuine Mouse.Target equal to the exact part, clear cursor location and stable-target interval are required immediately before down; ray/projection results alone cannot authorize it.

Camera automation first rotates from the current camera position, then can try two bounded-distance viewpoints. It never moves the character or removes obstacles. The initial camera snapshot is retained across targets and Dirty=0 idle periods. Stop/off, emergency stop, selection, closure and lifecycle/error handling restore it when still owned. Explicitly disabling camera automation also relinquishes the camera. Visible Only keeps the current view rather than restoring between visits. A replacement or externally controlled camera is not overwritten during restoration.

## Menu and input ownership

The full title bar and compact HUD title accept a left-button drag. Coordinates are clamped to the current viewport, respecting the top GUI inset; resizing reclamps the window. Position survives collapse/expand and duplicate loader calls in this session, but is not persisted to disk. **—** collapses and **+** expands. Auto Paint starts in the compact HUD, which shows AUTO, Protected, Dirty, Current Target and STOP.

Own-window hit testing blocks map selection regardless of whether Roblox marks the click as processed. Dragging/menu presses release owned input and suspend targeting until mouse-up plus the release gap. No task is spawned to wait for drag completion. Escape stops even if a menu processed the key. Dragging does not suppress the game's independent input handlers.

Capabilities are detected without exercising them: mousemoverel (preferred), mousemoveabs, mouse1press, mouse1release, and optional isrbxactive. Missing functions disable automation; there is no hook/event-firing/VirtualInputManager fallback. Cursor API can explicitly choose Relative or Absolute, invalidating the previous test. The explicit test requires an equipped, enabled bucket and living character, an unlocked cursor, focus, no text input/menu, and a selected visible wrong-color test target. It never moves the camera.

Native down/up event delivery is observed through ordinary event subscriptions. No callbacks are called by AutoPainter. Missing down acknowledgment stops even when FAST dwell is shorter than the acknowledgment timeout. Every next target waits for observed button-up and ReleaseGap. Failed release retries at most three times; unresolved up blocks further input. Closing normally disconnects everything and removes highlights. If release remains unresolved, one minimal manual-up guard blocks duplicate loads until release is observed.

## Limits that remain

AutoPainterRPCs=0 describes the controller's structural absence of game remote transport; native RPC counts, latency and completion are **unobserved**. The native tool may repeat only on private servers. This controller adds no public-server per-cooldown click fallback.

An up observation plus any fixed gap is not proof that the native loop drained an outstanding InvokeServer. A native shared holding flag surrounding a yielded paint call could allow an earlier loop to resume after a later down. FAST's shorter gap intentionally reduces input dead time; it cannot settle that native-source/server timing question. The full loop and its sameMouse lifetime would be needed to prove otherwise. The normal tool's cached color similarly cannot be attested by attribute equality alone; use its real palette and manual verification.

User cursor motion can race the native tool's next repeat before the controller observes target loss. Leave the cursor alone during a hold and use Escape to stop. An external executor function that blocks the whole client cannot be interrupted by this Luau controller. No moderation immunity or live PPS increase is claimed.

## Validation

**396 deterministic tests pass: 150 native-controller and 246 locked-diagnostic tests.** The native cases run with both immediate and deferred signals and include the input/UI selection path, strict dirty filtering, early release, profile bounds, visible/nearest selection, offscreen aging, ray budgets, moving-part caches, palette authority, no attribute writes, persistent camera, drag/resize/HUD, acknowledgment failures, respawn, cleanup and zero direct RPCs. All 19 Luau files compile. Geometry/input are mocks, not a live executor benchmark.

See [README.md](README.md) for the exact live procedure. API references: [Mouse](https://create.roblox.com/docs/reference/engine/classes/Mouse), [Camera projection](https://create.roblox.com/docs/reference/engine/classes/Camera#WorldToViewportPoint), [GUI input events](https://create.roblox.com/docs/reference/engine/classes/GuiObject#InputBegan), [ScreenGui inset](https://create.roblox.com/docs/reference/engine/classes/ScreenGui#IgnoreGuiInset), [GUI hit testing](https://create.roblox.com/docs/reference/engine/classes/BasePlayerGui#GetGuiObjectsAtPosition).
