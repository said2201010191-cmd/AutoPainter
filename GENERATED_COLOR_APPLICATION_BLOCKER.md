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

## Public-150 revision: additional evidence and actual coverage

The all-in-one specification/evidence file supplied for this revision contains live outcome reports, not complete native LocalScript bodies. Its Civil custom-UI section explicitly records **ObjectsInspected=0, CandidateControls=0**. That means the expanded inventory was not present in that report; it does **not** prove that arbitrary-RGB controls are absent. The 128 learned RGB/button mappings and palette transaction records confirm the existing swatch route, not an arbitrary setter.

The following routes were traced or checked, with their limits kept separate:

| Route | What the available evidence establishes | Application conclusion |
| --- | --- | --- |
| OG Civil `nextUniqueColor -> entry.target -> send` | Entire preserved source reread; generated color goes directly into the game's paint payload. No native palette write occurs in this chain. | RGB creation/application under the excluded old transport; cannot transplant that transport. |
| OG Randomize / selected saved color | Original source chooses random RGB locally and later supplies it in a direct payload. Its own preview is not the bucket's working-color setter. | No additional native application path. |
| Learned native swatches | All 128 live mappings, recent successful palette transactions, and user-supplied normal client excerpts: swatch BrickColor.Color updates the cached tool color and PaintBucketColor. | Supported for those learned outputs only; preserved. |
| External attribute write / re-equip | User already observed cached-color mismatch. No complete native subscription/initialization contract proves arbitrary attribute RGB reaches the working variable after an external update. | Not enabled or retested as an assumed setter. |
| Native `PaintSGui.Picker` | Prior user test reported no new custom editor or selected-color change. Full handler source is absent. It could be some other tool, but its purpose cannot be inferred from its name. | Negative observation for this specific interaction, not a global impossibility proof. |
| Native `ColorTitle.ColorPicker` | Same prior negative observation, with no full input handler source to explain its behavior. | No supported arbitrary-color contract established. |
| Other RGB/HSV/hex fields, sliders, alternate tools/settings | Reviewed existing broad diagnostic coverage and searched supplied source/evidence artifacts. No actual new editor handler/source was supplied. The report's expanded UI inventory was empty/unrun. | Unknown; no guessed event or setter is invoked. |
| Shipped client color readers/writers | Prior 165/165 scan summary establishes paint-call coverage; no complete exported reader/writer source corpus is available here. The locked scanner already indexes RGB/HSV/hex/TextBox/FocusLost/slider/attribute references with context. | Need actual source output to follow aliases and callbacks; keyword coverage is not a complete data-flow proof. |

A read-only check of the currently open Roblox window found **a different game**, without this PaintBucket/palette/controller. No input, game navigation, palette probe, test paint or state change was attempted there. The prior window observation cited above was from an earlier investigation and is not a claim about the current client.

The blocker is therefore precise: **the accessible artifacts do not expose any supported operation that maps an arbitrary non-swatch RGB into the current native PaintBucket's cached working color.** The fixed learned swatch application layer itself cannot represent that extra output. Whether the game contains an unexported RGB editor or supported setter remains unknown; this revision does not claim exhaustive nonexistence.

To remove the blocker, the missing material is the current full native palette/picker LocalScripts and any modules they use, plus PaintBucket's initialization/color-update handlers (or a demonstrated ordinary UI workflow that selects an arbitrary RGB). Read-only locked source extraction is sufficient; no remote, hook or execution of inspected modules is needed. A supported setter must update the same color actually read by normal activation, not only a preview or replicated-looking attribute. Once identified, the application transaction and stable 129+ assignments can be implemented and tested end to end. Until then those application assignments, their retry application, and the required province-129 live proof remain unimplemented. Existing generator uniqueness tests do not count as those application tests.
