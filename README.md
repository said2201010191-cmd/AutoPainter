# Current Hands Free build: v8.2

Use **[AutoPainterHandsFree.luau](AutoPainterHandsFree.luau)** for the new build, based on v8.1. Full setup, tuning, all new report fields and exact NORMAL/Civil/30–45-minute live procedures are in [ACTIVATION_GUIDE.md](ACTIVATION_GUIDE.md). [V82_SPEC_IMPLEMENTATION.md](V82_SPEC_IMPLEMENTATION.md) maps every required specification section to implementation and validation.

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/said2201010191-cmd/AutoPainter/main/AutoPainterHandsFree.luau", true))()
```

For repeatable tests/friend distribution, use the commit-pinned loader supplied with the implementation response. Public anonymous raw loading requires a public repository. No Studio/project access, credentials, server modifications, or direct AutoPainter paint RPCs are required.

v8.2 adds automatic overload/fairness, separate eligible/deferred clocks, pathological group cooldowns, healthy-only dwell learning, generation-indexed native palette binding with observed verification of duplicate swatches, explicit Civil post-palette target reacquisition, camera safeguards, slower adaptive reconciliation, stronger outlines and genuine-target drag selection. PER_TARGET, normalized recognition, native palette click timing, input ownership and stable Civil assignments remain.

Export the v8.1 palette profile before closing the old controller. Import it in v8.2, open the native palette, then use **Validate Native Palette** to verify ambiguous mappings. Validation changes native palette selection but does not paint. Select the NORMAL palette color again afterward. Focus/tool loss now resumes after stable recovery; explicit STOP cancels resume.

**782 deterministic tests pass; all31 Luau files compile.** The user supplied live v8.1 evidence; **v8.2 correctness and speed remain live-unverified**. Generated colors beyond native capacity are disabled because no legitimate custom-picker protocol is confirmed. A137/128 selection reports shortage9 and blocks START/REROLL without reuse or dropping selections.

The historical native/diagnostic entry points below remain unchanged and are separate from Hands Free v8.2.

---

# AutoPainter — native hold, bounded targeting

`AutoPainterFinal.luau` is a **client-only native-input controller**. It sends **zero game RPCs**. The existing normal PaintBucket owns every paint request, mouse callback, mode and cooldown. No Studio, server changes, account-specific values or secrets are required. Auto Paint starts OFF; the native input test runs only when explicitly requested.

## Public loader

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/said2201010191-cmd/AutoPainter/main/AutoPainterFinal.luau", true))()
```

The repository/file must be publicly readable. `LoaderPublic.luau` is equivalent with explicit download/compile errors. Close the older AutoPainter panel before loading this UI version (10). No private credentials belong in the loader.

## Reliability and speed changes

- One sticky target owns acquisition, camera, cursor, hold and release. Other priority changes choose the next target; they cannot cause mid-acquisition ping-pong.
- Camera fallback proceeds through ordered, separately settled poses: existing view, rotation, small translation, elevated, overhead, then one side angle. Unreachable targets receive bounded exponential retry delays; an exhausted camera sequence is not replayed from the same pose.
- A bounded surface solver handles wide/thin parts and blocked centers, remembers successful local points, and retries nearby points first. Genuine `Mouse.Target == province` remains required before down.
- Cursor fallback compares exposed relative/absolute APIs and viewport/screen conventions using real target observations. An explicit **CALIBRATE INPUT (cursor only)** button generates no button press.
- One dirty province bypasses general scheduling; two/three use direct references. Larger sets prefer nearby visible work with aging and offscreen fairness. Next-target precomputation during hold does not move input or camera.
- Matching color releases immediately by default. **Contest Hold: SMART** optionally allows a short, bounded grace for a heavily contested singleton. No-effect holds back off that target without claiming the server rejected anything.
- **Copy Target Failure Report**, **Copy Benchmark Report**, **Reset Benchmark**, **Snap Left/Right**, a draggable collapsed HUD and detailed timing/counter APIs support live diagnosis.

Correct, unprotected and pending provinces receive no automated targeting/input. Color signals maintain the dirty set; there is no patrol of clean provinces. Selection pauses automation and commits on Done / Cancel without changing the Auto Paint toggle. Escape finishes selection and stops automation.

## Profiles

| Setting | ULTRA | FAST (default) | NORMAL |
|---|---:|---:|---:|
| Ordinary maximum hold | 0.24 s | 0.32 s | 0.90 s |
| Next-down gap after observed up | 0.025 s* | 0.05 s | 0.15 s |
| Acquisition deadline | 0.80 s | 1.05 s | 2.40 s |
| Minimum camera-pose interval | 0.07 s | 0.08 s | 0.15 s |
| Camera settle time | 0.035 s | 0.04 s | 0.08 s |
| Genuine target confirmation | 1 rendered frame | 1 rendered frame | 2 frames + 0.05 s |
| Initial unreachable retry | 0.30 s | 0.40 s | 0.75 s |

\* ULTRA retains at least 0.05 s until eight down/up cycles have been observed. Measured up latency and reliability adjustments may increase the effective gap. Acquisition begins as soon as up is observed; only the next down waits. Deadlines permit staged recovery and do not delay a successful visible acquisition. Profiles never change the native tool cooldown.

## Live test procedure

1. Close the old panel and run the loader. Choose the desired color through the **normal PaintBucket palette**, then manually paint a tile to verify the bucket's actual cached color. AutoPainter does not write `PaintBucketColor`.
2. Holster the bucket while selecting; the equipped native tool independently responds to ordinary clicks. Protect a visible wrong-color province and one already-correct province, then **Done / Cancel**. Leave **Keep Territory Color OFF**, **Contest Hold OFF**, **Speed Mode FAST** and **Visible Only ON**.
3. Choose the committed wrong-color province using **Choose Test Province**, then Done. Equip PaintBucket. If cursor placement seems offset, run **CALIBRATE INPUT (cursor only)** first. It tests exposed coordinate variants without pressing Mouse1.
4. Explicitly run **TEST NATIVE INPUT**. Verify the real pointer hits the chosen province, the bucket uses the expected color, down/up occurs, and the client remains connected. A displayed PASS verifies input observations, not server acceptance or native request completion.
5. Click **Reset Benchmark**, then **Auto Paint / Q**. Leave the cursor alone. The wrong province should be serviced; the already-correct province must never be visited. After correction, check Dirty=0 and no continuing input. Have a friend recolor the protected province repeatedly to test immediate singleton reacquisition.
6. Add a second, then a third visible dirty province (holster while selecting). Check quick switching, early release and absence of left/right oscillation. Test **ULTRA** next; compare benchmark acquire/dead-time values and actual observed corrections. Use FAST if ULTRA is less reliable in your environment.
7. Turn Visible Only OFF with Camera Automation ON. Include the previously troublesome province and a reachable province. A failed target should show a retry cooldown while the other is serviced. Camera stages should settle individually. If the original province still fails, click **Copy Target Failure Report**; it includes its exact path, geometry, ray hit, genuine mouse target and both coordinate projections.
8. Optionally enable **Contest Hold SMART** for a repeatedly recolored singleton. It may hold for up to 0.15 s after a correction, bounded by the original dwell deadline, and yields when another dirty target needs service. Turn it OFF for immediate-release behavior.
9. After a comparable run, **Copy Benchmark Report**. Check Snap Left/Right, title-bar drag, collapse/expand and HUD counts. **Escape / STOP** must release Mouse1 and restore the saved camera. Also check removal, Clear, unequip and respawn before relying on unattended targeting.

Clipboard exports fall back to `AutoPainterTargetFailures.txt` / `AutoPainterBenchmark.txt` when `writefile` is available. Copy does not generate input or paint requests.

Choose colors in the normal palette before starting. **R / Randomize / Country Color** are explicitly preview-only. Keep Territory Color saves each selection's real palette color; a saved color differing from the current palette waits. AutoPainter does not pretend an attribute write updates the tool's cached local variable.

## Measurement and limits

Corrections are desired-color transitions observed while holding the exact target, not proof that this client caused them. The prior native-input live test worked without a kick; this revision has not been benchmarked or verified against the two original live failures. Native cooldown, server behavior, input delivery and frame propagation remain limiting factors. No moderation immunity or ability to exceed native limits is claimed.

See [NATIVE_INPUT_GUIDE.md](NATIVE_INPUT_GUIDE.md) for coordinate handling, timing definitions, cleanup and native-loop limits.

## Locked diagnostics and validation

The separate scanner is unchanged and locked:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/said2201010191-cmd/AutoPainter/main/LoaderDiagnostic.luau", true))()
```

Run `python3 tests/run_tests.py /path/to/luau`.

**468 deterministic tests pass: 222 native-controller and 246 diagnostic tests. All 20 repository Luau files compile**, removing only the original reference's Markdown wrapper in a temporary compile copy. Native scenarios run with immediate and deferred events. Original/FastClient source and locked diagnostics remain unchanged; retired direct-RPC tests are retained as historical references, not active-runtime tests.

