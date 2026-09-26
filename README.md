# AutoPainter — fast native hold

AutoPainterFinal.luau is a **client-only native-input controller**. AutoPainter sends **zero game RPCs**. The existing normal PaintBucket owns all paint requests, mode, cooldown and mouse callbacks. Auto Paint starts OFF; the native input test never runs automatically. No Studio, server changes, account-specific values or secrets are required.

## Public loader

    loadstring(game:HttpGet("https://raw.githubusercontent.com/said2201010191-cmd/AutoPainter/main/AutoPainterFinal.luau", true))()

The file must be publicly readable. LoaderPublic.luau is equivalent with explicit download/compile errors. Close the previous AutoPainter panel before loading this UI version. No private credentials belong in either loader.

## Live procedure

1. Join the private server normally. In the **normal PaintBucket palette**, choose the desired color. Manually paint one tile to verify the actual bucket uses that color. AutoPainter never rewrites PaintBucketColor.
2. Holster the bucket while selecting: an equipped native tool can respond to ordinary selection clicks. Click **Protect Province**, select several provinces, then **Done / Cancel**. Include a province already matching the chosen color. Pending selections produce no automated input.
3. Leave **Keep Territory Color OFF**, use **Speed Mode: FAST**, and initially enable **Visible Only**. Choose a committed, visible, wrong-color province using **Choose Test Province**, then Done. Equip PaintBucket.
4. Click **TEST NATIVE INPUT**. Leave the cursor alone. The test aims at that exact real target, holds briefly and releases. Confirm the bucket paints the chosen color and the client remains connected. A PASS checks native input-event delivery, not server acceptance or native request completion.
5. Press **Q / Auto Paint**. Start snapshots the normal palette's exposed color. Only wrong-color protected provinces should be visited; correct and unprotected provinces should receive no automated input. Correcting the held province should release immediately, before its maximum dwell.
6. After all selected provinces match, verify **Dirty: 0** and no further cursor/button activity. Have a friend repaint one selected province: Dirty should rise and that province should be serviced again.
7. Disable Visible Only and enable Camera Automation to test offscreen targets. The camera should move directly between dirty targets and stay in place between visits, including when all are clean. **Escape / STOP** releases input and restores the saved camera when AutoPainter still owns it.
8. Drag the full title bar or collapsed HUD to an edge. Check **— / +**, counts, current target and STOP. Dragging suspends automated input until mouse-up. To change the palette, stop first, choose through the normal palette, then restart. An external palette change also stops automation.

**Q** toggles Auto Paint. **R**, Randomize and Country Color/Pick are now explicitly **preview-only**: their swatch does not claim to change the normal bucket's cached color or a running target. Choose the desired color through the real palette before starting.

## What changed

- FAST defaults: 0.45 s ordinary maximum hold, 0.10 s release gap, 0.025 s cursor interval, 0.03 s stable target, 0.75 s acquisition timeout. NORMAL provides gentler targeting timings. Neither profile changes native cooldown.
- Color signals maintain a dirty set. Correct/unprotected/pending provinces are excluded; there is no periodic clean-province patrol.
- Ray-verified visible dirty targets come first, normally by smallest cursor movement. Aging prevents starvation; offscreen choices minimize camera rotation. Surface points are cached, with bounded per-frame ray work.
- Contention increases dwell gradually; priority extends it, capped at 2 seconds. Matching color always releases early. A held input is never carried to the next target.
- The camera remains active between targets. A draggable full panel and compact HUD show Protected / Wrong Color / Correct Color or Auto / Protected / Dirty / Current Target / STOP.
- **Keep Territory Color** saves the real palette color at selection time. A saved color different from the current palette remains dirty but waits, with a visible count. Automatic switching of the native tool's cached color is not claimed or attempted.

See [NATIVE_INPUT_GUIDE.md](NATIVE_INPUT_GUIDE.md) for settings, fairness and native timing limits. The user's prior native-input live test worked without a kick; this faster revision has deterministic tests, not a new live throughput measurement.

## Locked diagnostics

The separate read-only scanner remains unchanged and permanently locked:

    loadstring(game:HttpGet("https://raw.githubusercontent.com/said2201010191-cmd/AutoPainter/main/LoaderDiagnostic.luau", true))()

Original and FastClient reference scripts remain unchanged.

## Validation

    python3 tests/run_tests.py /path/to/luau

**396 deterministic tests pass: 150 native-controller tests and 246 diagnostic tests. All 19 repository Luau files compile**, with only the original reference's Markdown wrapper removed in a temporary compile copy. Historical direct-RPC test files remain references and are not active-runtime tests.
