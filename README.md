# AutoPainter — smart native hold

AutoPainterFinal.luau is now a **client-only native-input controller**. It sends **zero game RPCs**. Your existing normal PaintBucket LocalScript owns every paint request, remote selection, mode, cooldown and mouse callback.

Auto Paint starts **OFF**. No input test runs automatically. No Studio, server code, place edits, account-specific values or secrets are required.

## Loader

The repository/file must be publicly readable:

    loadstring(game:HttpGet("https://raw.githubusercontent.com/said2201010191-cmd/AutoPainter/main/AutoPainterFinal.luau", true))()

LoaderPublic.luau is an equivalent loader with clearer download/compile errors. Close the old AutoPainter panel first. Restart Roblox if an older diagnostic decompile is still stuck.

## First live test

1. Join the private server normally. Leave Auto Paint OFF. Holster PaintBucket while choosing selections: ordinary clicks with an equipped tool may legitimately paint.
2. Click **Protect Province**, select provinces, then **Done / Cancel**. Pending selections never trigger input.
3. Click **Choose Test Province**, click one already committed, visible province, then Done. Equip the normal PaintBucket.
4. Read the capability display. It requires mouse1press, mouse1release and either mousemoverel or mousemoveabs. Detection is local and does not press anything.
5. Click **TEST NATIVE INPUT**. Keep Roblox focused and your hands off the mouse during the short test. It does not move the camera. It moves the cursor, requires the exact real Mouse.Target, briefly holds Mouse1, then releases.
6. A PASS means native down/up events were observed while targeting the chosen province and AutoPainter sent no RPCs. **It does not prove that PaintBucket sent a request or the server accepted it.** Confirm normal painting works and there is no moderation kick before proceeding.
7. Enable **Auto Paint**. Use Camera Automation and Visible Only as appropriate. **Escape** or the visible STOP bar releases/stops the controller. **Q** toggles Auto Paint; **R** randomizes the global color.
8. If input fails, stop and use **Copy Native Input Report**. Clipboard export falls back to AutoPainterNativeInputReport.txt. Do not repeatedly enable automation after a failed live paint.

## Behavior

- Committed, wrong-color provinces form an event-driven dirty set.
- Priority combines an explicit priority target, contention, recent changes, visibility, camera alignment and waiting time. Oldest eligible work overrides score after the aging threshold.
- One native mouse-down starts a hold. There are no synthetic per-cooldown clicks, direct paint requests or parallel request workers.
- The controller releases on target-color observation, dwell expiry, real-target loss, pause, removal, focus/menu loss, unequip, death or shutdown.
- Camera movement and genuine cursor movement are separate from target validation. A projection or raycast alone never authorizes mouse-down.
- Global color uses the existing LocalPlayer PaintBucketColor attribute. Keep Territory Color stores each province's selected color at registration; its color is applied for that native hold and the global manual-bucket color is restored after release.
- The controller does not force Peace/War, remotes, cooldown upgrades or private-server flags. The native tool retains those decisions.
- A priority “lock” extends dwell and raises priority; it does not disable fairness indefinitely.

See [NATIVE_INPUT_GUIDE.md](NATIVE_INPUT_GUIDE.md) for settings, ownership/cleanup, test scope and timing limitations.

## Separate locked diagnostics

The existing game-only scans, cache, watchdog, cancel and report controls remain in AutoPainterDiagnostics.luau:

    loadstring(game:HttpGet("https://raw.githubusercontent.com/said2201010191-cmd/AutoPainter/main/LoaderDiagnostic.luau", true))()

That collector is now permanently locked, even if false diagnostic options are supplied. Its direct remote transport was removed. Close one panel before opening the other.

AutoPainterOriginal.luau and AutoPainterFastClient.luau remain unchanged reference files.

## Validation

Run:

    python3 tests/run_tests.py /path/to/luau

**344 deterministic tests pass: 98 native-input tests and 246 diagnostic tests. All 18 repository Luau files compile** (the original Markdown-wrapped reference is compiled from a temporary unfenced copy). The historical direct-RPC scheduler and selection tests remain as reference files; they are no longer treated as active-runtime tests.

No live executor or server test was performed from the development workspace. In particular, native-loop drain and server callback timing cannot be measured without additional source/observability.
