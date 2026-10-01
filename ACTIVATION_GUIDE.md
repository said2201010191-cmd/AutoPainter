# Hands Free v4 — activation-only revision

The live messages `Acquire: Real Mouse.Target acquired` and `Automatic Mouse1 did not reach the normal PaintBucket input loop` come from **AutoPainterHandsFree.luau**, not the older AutoPainterFinal controller. This revision changes the Hands Free activation layer and its diagnostics/lifecycle integration. The entire existing camera/acquisition block is byte-for-byte unchanged and protected by a hash regression test. NORMAL and optional CIVIL WAR modes retain their existing targeting and color preparation.

## Loader

Close the older Hands Free panel, then run:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/said2201010191-cmd/AutoPainter/main/AutoPainterHandsFree.luau", true))()
```

The repository/file must be public. No Studio, place edits, server changes, credentials or account-specific objects are required. The older Final controller, its LoaderPublic, reference files, CivilWarOldLoader and locked diagnostics are not changed by this revision. Do not run two different painter controllers at once.

## What START does

1. Keeps the existing selection, equip, palette and camera acquisition flow.
2. Subscribes to genuine PlayerMouse down/up, Tool.Activated/Deactivated, and the actual Mouse supplied by Tool.Equipped if it differs from Player:GetMouse(). No callbacks are replaced or invoked by the controller.
3. Once the real `mouse.Target` is the selected province, tries available activation methods one at a time:
   - `mouse1press()` paired with `mouse1release()`, if both exist.
   - `UserInputService:CreateVirtualInput()` and its `SendMouseButton` API, if creation succeeds and returns an object.
   - The equipped tool's public `Tool:Activate()` / `Tool:Deactivate()` methods.
4. Records input observation and province-color change separately. A successful API return is insufficient. Tool.Activated by itself does not establish that the game's Mouse.Button1Down handler ran.
5. Prefers a method only after an input event and the requested target color are observed during that attempt. It then releases and uses the same method on the next dirty province automatically. No physical click or cursor movement is required after START.

The normal PaintBucket remains the sole sender of paint requests. AutoPainter contains no game RPC transport, hook, signal-firing API, connection inspection, script execution, require, decompiler invocation, fabricated target, validator replacement or moderation interception. Input travels through the exposed input API or the Tool's public activation method. No internal VirtualInputManager/VirtualUser fallback or permission escalation is attempted.

The old input layer observed only Player:GetMouse().Button1Down and claimed that missing this event meant the normal input loop had not run. That inference was too strong. This version also observes the tool's genuine Equipped Mouse and distinguishes event delivery from paint effects.

## Bounded verification and stopping

A trial waits up to **0.35 seconds** for an input observation, and up to the existing **0.90-second PaintTimeout** for the target-color effect. These are verification deadlines, not native cooldown changes. They are near the top of the script for tuning if live evidence shows a longer legitimate response time.

Each method has a paired release. Another method cannot start until release is observed. For an entirely unobserved/no-op press, a successful paired release plus a quiet interval and a non-pressed physical mouse state can establish the local input boundary. If both API calls error before any input is observed, the non-pressed state and quiet interval are still required. A real down with no matching release blocks fallback. There is no delayed duplicate up that can interrupt the next hold.

The controller serializes external input calls, including yielding functions. STOP during a pending call latches release until it returns. A client function that blocks the entire process cannot be interrupted by this Luau code. START cannot create another worker while startup, activation or cleanup is pending. Tool/character changes, target loss, focus loss, Clear and closure stop/release the owned input. Duplicate loads share the v4 controller.

Unconfirmed methods are not repeatedly hammered. Each gets one trial per equipped-tool/session sequence. A previously observed method can tolerate three consecutive no-effect holds before it is retired and the remaining methods are tried. When none confirms the local input-plus-color evidence, the UI explicitly stops and reports that the normal paint path remains unconfirmed. No color effect may also mean contested ownership, native cooldown, stale palette state or server delay; the report does not call it proof that the input API or server failed.

A color transition could be caused by another player or the server. No server acknowledgment or native function-entry trace is available without the interception deliberately excluded here. Confirmation means **observable local evidence**, not causal proof or a no-kick guarantee.

## Diagnostics and input-consuming UI

While running, the button panel is replaced with a visible, non-interactive diagnostic label. This prevents a stationary cursor over START from pressing that control again or having input consumed by the panel. Q or Escape stops and returns the controls. The camera and cursor acquisition code is unchanged.

The live label and **Copy Activation Report** show:

- Target acquired.
- Activation method and whether an attempt was made.
- Activation observed: Mouse.Button1Down, Tool.Activated only, or none.
- Color changed and whether the requested target color was observed.
- Per-method outcomes, API/release errors, and bounded failure reason.

The copy button exports existing evidence only. It uses setclipboard when available, otherwise writefile to `AutoPainterActivationReport.txt`. APIs: `GetActivationReport()`, `CopyActivationReport()`, and `GetStats().Activation`.

Only PaintBucket descendant LocalScripts' Source properties are read, under protected access. Counts of readable/unavailable texts and Button1Down/Activated mentions are reported. Source restrictions are not bypassed; no decompilation is performed. Mentions may occur in comments or unused code and do not prove event wiring. The supplied live extract establishes the Mouse.Button1Down path; an alternate Tool.Activated paint handler remains unproven unless live effects support it.

## Live procedure

1. Close the old Hands Free panel and use the loader above. Select the same wrong-color provinces with the already-working camera flow. Start with NORMAL and the normal bucket palette color.
2. Press START once. Do not move or click the mouse. Watch the method name, Activation observed and Color changed fields. It should proceed automatically to the next dirty province after a confirming color transition and release.
3. If all methods fail, automation should stop after the bounded sequence. Click Copy Activation Report and share that report. Do not interpret an isolated Tool.Activated event as successful paint-loop entry.
4. After NORMAL is verified, check CIVIL WAR separately. Its pre-existing unique-color/equip preparation is retained, not newly proven to update the native tool's cached color by this activation change.
5. Verify Q/Escape releases, Clear stops, and a respawn requires restart. Check a second START does not create duplicate input owners.

No live executor is connected to this development environment. The user must run this build to establish which method, if any, reaches their tool's legitimate path. The revision is not claimed live-fixed before that observation.

## Validation and API basis

Run `python3 tests/run_tests.py /path/to/luau`.

**534 deterministic tests pass:** 222 legacy native-controller tests, 246 locked-diagnostic tests and 66 new Hands Free activation tests. New scenarios run under immediate and deferred events, including no-op press, virtual input fallback, Tool.Activated without painting, alternate Equipped Mouse, release failures, yielding down, cancellation, reuse, finite no-effect retry, selection cleanup, respawn, modes and zero AutoPainter RPCs. The camera/acquisition hash check ensures that code was not rewritten.

Roblox documents [Tool:Activate](https://create.roblox.com/docs/reference/engine/classes/Tool#Activate) as simulating equipped-tool activation; this does not establish a Mouse.Button1Down handler in this particular tool. [CreateVirtualInput](https://create.roblox.com/docs/reference/engine/classes/UserInputService#CreateVirtualInput) can return nil when unavailable. [VirtualInput.SendMouseButton](https://create.roblox.com/docs/reference/engine/classes/VirtualInput#SendMouseButton) uses screen-position input and can reject restricted GUI interaction or invalid button state. These restrictions remain intact.
