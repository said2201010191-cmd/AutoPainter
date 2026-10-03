# Native generated RGB: source trace and implementation

## Finding and scope

The current shipped PaintBucket **does reload its private working color on a real equip**. This resolves the previously missing client-side data-flow evidence. A standalone attribute write while already equipped still does not update that private variable.

This revision implements a guarded **Civil-only native equip reload** for colors beyond 128. It does not claim live generated-color application is proven. The remaining acceptance test is a real non-palette RGB transition on province 129+, produced by normal native input. Server acceptance/quantization and repeated re-equip behavior must be tested live.

Live collection on 2026-10-03: **165/165 complete LocalScript/ModuleScript bodies**, **998,879 source bytes**, zero read failures/timeouts/skips, **5,307 GUI/tool objects**. The collector used the existing game-only root allowlist, retained full bodies (not keyword excerpts), and made zero game-remote calls. The user ran/exported the locked collector because desktop coordinate control was unavailable. No inspected script/module was executed or required.

Full source remains in the local `AutoPainterNativeColorEvidence.txt` export. This repository records paths, hashes and the analysis instead of publishing the complete client corpus. See [NATIVE_COLOR_SOURCE_INDEX.md](NATIVE_COLOR_SOURCE_INDEX.md) for all 165 inspected scripts/modules. Line numbers below refer to extracted full bodies, including the decompiler header; the decompiler's own original-line annotations differ.

## Actual PaintBucket data flow

Runtime: `Workspace.Seporial.PaintBucket.LocalScript` (`S00002`). Template: `StarterPack.PaintBucket.LocalScript` (`S00125`). Their returned source bodies are byte-identical.

| Stage | Extracted lines in S00002 | Exact data flow |
| --- | --- | --- |
| Initialization | 66–72 | Read `LocalPlayer:GetAttribute("PaintBucketColor")`; white fallback; copy to working variable `v15`. |
| Swatch wiring | 148–183 | `SetupGui` clones the native palette. Each direct `GuiButton` child of ColorPallet gets a MouseButton1Click handler. Handler maps button Name through BrickColor, assigns `v15`, then writes PaintBucketColor and native display colors. |
| PaintSGui.Picker | 191–219 | Toggle eyedropper flag `v13`, preserve previous mode in `v14`, update mode/preview indicators. Does not open an RGB editor. |
| ColorTitle.ColorPicker | 251–280 | Same eyedropper flag/mode toggle. Its BackgroundColor3 is an output/indicator, not a color input. |
| **Real equip** | **316–325** | Guard against duplicate equip using `v17`; then **reload `v15` from PaintBucketColor**, set equipped flag, increment session generation `v19`. No BrickColor conversion of a supplied attribute value. |
| Eyedropper sample | 326–365 | With picking enabled and genuine target directly under workspace.Provinces, copy `v36.Target.Color` to `v15`, mirror to attribute/indicators, restore prior mode; return before painting. |
| Native paint | 455–474 | Genuine mouse target and direct Provinces parent check; native upgrade cooldown; payload Color is **the same captured `v15`**; third argument is current Peace/War mode. |
| Working-color outputs after equip | 501–504; 287–292 | Set SelectionBox.Color3 and LineHandleAdornment.Color3 from `v15`; rebuild PaletteGui; ColorPicker.BackgroundColor3 is also assigned `v15`. |
| Unequip | 538–581 | Reset equipped flag/generation, destroy cloned PaletteGui, remove adornment targets, clear picking state. Next real equip reaches the attribute reader again. |

There are four categories of working-color writer: startup, equip, swatch click and eyedropper sampling. No PaintBucketColor change subscription exists in either complete PaintBucket body. No external setter/module is called by these handlers. The attribute is a **persistent input at initialization/equip and a mirror during swatch/picker use**, not a continuously authoritative signal while equipped.

`BrickColor.new(v15).Name` only labels the selected color. It does not assign a quantized BrickColor back into `v15`. The native RPC payload uses `v15` directly.

`RemoteScript` (`S00004`, template `S00127`) retains the genuine GetMouseData callback (real Hit.Position and Target), animations/sounds and equip tracking. It has no color setter. `VipTextures` (`S00005`, template `S00128`) loads `ReplicatedStorage.GamepassConfig` for a VIP tool icon; no paint working-color flow. All HideBT scripts (`S00013`, `S00003`, `S00126`) show/hide/reposition the palette; no working-color writer.

## Other candidates actually inspected

- **Every LocalScript under PaletteGui:** only the HideBT LocalScript exists in the live clone, runtime template and StarterPack template. Picker handlers live in the full parent PaintBucket LocalScript, not separate picker modules.
- **PaintSGui.Picker and ColorTitle.ColorPicker:** source establishes eyedroppers, explaining the earlier negative RGB-editor tests. They can copy an already-existing arbitrary province color, but cannot generate an unseen RGB without some other source province; no local fake-color sampling is used.
- **Full PlayerGui, including hidden/alternate roots:** inventoried without a palette-name filter. Editable fields belong to date/time, admin command/settings/messages, flag search and map-preset names. No RGB/HSV/hex editor feeding the bucket was found in this snapshot. This is a snapshot conclusion, not a universal claim about future GUIs.
- **HDAdmin PageSettings (S00050):** HSV calculations derive admin-theme foreground/background colors; callbacks change AppTheme. No edge to PaintBucketColor or `v15`. HDAdmin message-color/command inputs are separate admin workflows, not the ordinary PaintBucket setter.
- **HUD BordersController (S00088/S00133):** local border/label UI and border-reset state, not the PaintBucket working color.
- **HUD FlagsController (S00091/S00136):** flag asset selection/search and button appearance, not paint color state.
- **MapPresetsClient (S00010/S00121):** save/load/delete/reset/swap map actions, preset names and private-owner access. These are neither arbitrary RGB inputs nor a supported bucket-color setter; no such action was invoked.
- **Other settings/upgrades/date/teleport and returned modules:** full bodies searched for color construction, readers/writers, event subscriptions and remote usage. `PaintBucketColor` and `PaintPart` occur only in the two matching PaintBucket implementations. RGB constants elsewhere style UI/lighting; only the admin-theme module uses HSV conversions outside PaintBucket.
- **OG Civil:** `CivilWarOldLoader.luau` lines 79–106 generate HSV/RGB; lines 268–279 retain the per-province target; line 347 puts that value directly in its own PaintPart payload. Generation was never the blocker. That excluded direct transport is not restored.

## Implemented application transaction

For 182 selected provinces, assignment uses 128 distinct verified native colors and 54 generated byte RGB values. Generated values avoid every learned native color and one another using the same normalized color matcher, remain stable across retries/recolors/GUI recreation, and regenerate on reroll. Same seed reproduces assignment. Assignment alone sends no input and does not increase verified application evidence.

Native swatches keep the existing working click state machine. Generated colors use the same exclusive target transaction:

1. Require active Civil service, current character/tool, focus, protected dirty target and exclusive lock.
2. Resolve owned Mouse1 release; never change tool/color while held.
3. Genuine `Humanoid:UnequipTools()`, observe tool in Backpack, allow native Unequipped callback to run.
4. Write **only** the existing local `PaintBucketColor` equip input.
5. Genuine `Humanoid:EquipTool(tool)`; observe new Equipped generation.
6. Require a new PaletteGui plus matching native SelectionBox, LineHandleAdornment and ColorPicker outputs. These objects are read only; the normal tool writes them from its cached color.
7. Rebind the semantic learned palette to the recreated GUI. Preserve every Civil assignment.
8. Continue the existing genuine target acquisition and VirtualInput DOWN/UP worker. AutoPainter never calls a game remote.
9. Record exact/normalized generated province observations separately. Indicators/attribute alone never count as paint success. A failed native preparation stops that run rather than repeatedly preparing every generated target.

The controller never accesses private closure variables. Working-color echoes are source-grounded preparation evidence; a genuine native DOWN and province transition provide the actual local application observation. Competing players can still affect causality; there is no server acknowledgment.

NORMAL requested DOWN spacing remains 150 ms and learned dwell remains 120 ms. Native Civil swatch timings, camera mode, targeting and cooldown benchmark are unchanged. A reverse-patch scope guard verifies every production edit against the prior build; existing matcher, cursor and palette-click hashes also remain enforced.

## Live validation — required, not yet performed

1. Export palette, STOP, close the old Hands Free panel and locked collector; load the pinned new build. Import/rebind the 128-color profile. No relearning should be required.
2. First use **129 protected visible provinces**, Civil mode, Reroll. Confirm 129 unique assignments, 128 native mappings and one generated RGB absent from the learned list. No paint before START.
3. START. For the generated entry require: real native re-equip observed, fresh PaletteGui and three matching native indicators, genuine Mouse.Target acquisition, observed Mouse.Button1Down, and actual province RGB equal to assigned generated RGB.
4. Copy Activation Report. The generated section must show the exact entry/position, IntendedRGB, AttributeBefore/AfterSet/AfterEquip, NativeEchoes, EquippedGeneration, NativeDownObserved, RealTargetAcquired, ActualRGB and `EXACT_GENERATED_RGB_OBSERVED`. If preparation fails, send its exact Step/Result and do not infer support from indicators alone.
5. Then select 182, reroll, require 54 generated assignments and eventual Dirty=0. Recolor native and generated provinces away from the cursor; require restoration of the original assigned colors. Verify 128 learned bindings survive repeated native palette recreation.
6. STOP/focus loss/respawn mid-preparation must release/stop without a stale DOWN. Observe repeated re-equip behavior and native event handling in public/private contexts; this has not been live tested in this revision.

Generated assignment and application code is implemented, **but end-to-end live generated-color support remains unverified until the above province result occurs**. No moderation, target-validation or server behavior is altered.

## Coverage limits

Zero read failures is not proof that the decompiler is semantically perfect. Server handlers are not available. Default engine PlayerModule/bootstrap trees, CoreGui/CorePackages, server-only containers and other players' characters/private containers are deliberately excluded. Dynamic HDAdmin require expressions and one unresolved static module path remain explicit coverage gaps. A later-created GUI or downloaded module can change coverage. No claim of absence is made beyond the collected snapshot.

## Deterministic validation for this revision

- **1,112 tests passed** across ten suites (222 native, 272 diagnostics, 208 Hands Free, 106 v8.2 regression, 64 live-fix, 52 combat, 72 benchmark, 60 follow-up, 30 public150, 26 new native-RGB cases).
- **38/38 repository Luau files compiled** with the official Luau CLI.
- New cases include 128+54 unique assignments, deterministic reroll, 54 generated mock results, off-cursor restoration, repeated GUI recreation/rebinding, stale working-color rejection, no result from indicators alone, cancellation/focus/tool failures, and zero direct game RPCs.
- The mock explicitly models the observed native Equipped reader. It cannot prove that the live server accepts arbitrary RGB, that the live decompiler output is perfect, or that repeated native tool sessions behave identically. The live 129+ test remains mandatory.
