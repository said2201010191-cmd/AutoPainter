# Mandatory generated-color application: incomplete, exact blocker

The requested end state remains **unimplemented**: first 128 provinces use verified native colors; provinces 129+ receive distinct generated RGB colors, retained until reroll. A generator, preview, capacity warning, or outline does not fulfill that request. This is a missing application feature, not an optional cosmetic improvement.

## End-to-end OG application trace

The preserved `CivilWarOldLoader.luau` establishes the old route:

1. `nextUniqueColor` (lines 79–103) produces a `Color3` with golden-ratio hue stepping, randomized saturation/value, quantized RGB uniqueness and distance rejection; random RGB is the fallback.
2. `addCivilProvince` (lines 266–304) stores that generated value in `entry.target`. The outline shows that same value; it does not paint the province.
3. `startCivilWar` enqueues selected entries. `pump` (lines 357–382) resolves the equipped bucket's `Remotes.ServerControls`, checks eligibility/capacity and calls `send`.
4. `send` (lines 332–350) puts **the generated `entry.target` directly into the `Color` field of `PaintPart`**, alongside the stored province Instance and `"Peace"`. That payload is the application mechanism. It does not pass through the native palette or modify the native tool's cached selected-color variable.
5. The old Color callback observes the resulting province color and queues mismatches. The server handler is absent; source tracing identifies the supplied payload, while the user's previous visual result supplies the old live evidence. The old call was not executed in this revision.

`AutoPainterOriginal.luau` likewise generates RGB at its Randomize/R handlers and later transmits the selected/saved value directly in its old paint payload. There is no hidden arbitrary-RGB native palette setter in either preserved reference.

## Why the current application architecture cannot express arbitrary RGB

The verified native route is:

`native swatch click -> native LocalScript's working color -> real Mouse.Button1Down / Mouse.Target -> normal bucket paint request -> observed province color`

A fixed 128-swatch interface has only those 128 selectable outputs. Reordering clicks, rerolling generated values, repainting, or changing AutoPainter's outlines cannot make that interface select a 129th RGB. An attribute write alone does not establish that the tool's cached working color changed, and would not solve the end-to-end requirement.

Reusing the OG direct payload would change the transport to direct game RPCs and violate the current explicit architecture boundary. No such transport was restored; no callback/target spoofing, hooks, or validator modifications were added.

## Investigation coverage and remaining evidence gap

- Read the preserved OG generation, assignment, enqueue/pump, remote resolution and send/observe functions end to end.
- Reviewed the supplied normal-client excerpts: palette selection assigns a `BrickColor.Color`, stores `PaintBucketColor`, and the native handler sends its cached working color for the genuine mouse target. Those excerpts do not expose a general-purpose native RGB setter.
- The prior user-run 165/165 game-only scan found only runtime/template copies of normal PaintBucket painting. That is evidence about exposed paint call sites, **not proof that no other color-editor workflow exists**.
- The prior `PaintSGui.Picker` and `ColorTitle.ColorPicker` native UI tests are negative results for those specific candidates only.
- Existing current-client diagnostics already cover all relevant PlayerGui RGB/HSV/hex/color controls and the full game-only source report's `NATIVE CUSTOM-COLOR WRITERS / UI PATHS` section. No new full source dump containing a supported arbitrary-RGB writer is present in the supplied workspace.
- A read-only inspection of the open Roblox window during this revision showed the native swatch palette and 128/128 learned controls, but did not expose an arbitrary-RGB editor or its handler. No click, paint, source execution, or live benchmark was performed in that inspection. A screenshot cannot establish hidden editor behavior.

## Supported capability needed to unblock implementation

At least one actual game-supported route must exist and be identified:

1. A native RGB/hex/HSV/custom-color editor that accepts arbitrary values, updates the same working color read by the normal PaintBucket, and is operable through ordinary input; **or**
2. An existing supported client tool-color API/state setter whose source contract demonstrably updates that working color (not merely a preview or an unobserved attribute), while the normal bucket remains the only paint sender.

The specific missing source is the **complete current native palette/color-picker input handlers plus the PaintBucket working-color reader/update subscriptions**. These must link a non-swatch RGB input to the actual cached color used for painting. If the shipped game has no such capability, the requested native-only 129+ application cannot be implemented solely by rearranging AutoPainter; the game would have to expose a supported color-selection capability. That is a technical constraint, not a recommendation to install server code or a claim of completed functionality.

Once a supported route is established, the application layer can use swatch transactions for native assignments and a custom-color transaction for generated assignments, under the existing exclusive target lock. Required proof before enabling it: choose an RGB absent from the swatches, use only that supported route, observe the actual selected/working color, acquire the genuine target, activate the native bucket, observe normalized target RGB, then restore the same assignment after external recolor. Unique seeded assignments and reroll must be tested across 128 native plus generated entries.

**Release status: generated-color application beyond 128 remains blocked and is not shipped as working.** The benchmark revision does not claim to complete this feature.
