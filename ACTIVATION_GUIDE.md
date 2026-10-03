# Current release guidance

Use [COMBAT_REVISION.md](COMBAT_REVISION.md) for v8.2 Combat, the guarded hold trial, fixed-cadence benchmark and generated-color findings. The previous revision notes below are historical; their default PER_TARGET and NORMAL extra-dwell description has been superseded.

---

# Hands Free v8.2 Live Fix

Build `8.2-live-fix`, based on v8.2 commit `17be81eab4fbd520b2bdbac5c2e390a64c51553b`. The native PaintBucket remains the sole game paint sender. The controller uses genuine PlayerMouse.Target, province Color, native palette buttons and VirtualInput. It sends no game RPCs and writes no PaintBucketColor attribute. No Studio, place changes or credentials are required.

**This revision is not live-proven.** Previous fast NORMAL/Civil behavior was reported by the user. Deterministic tests cannot establish current Roblox performance, server acceptance, replication latency or rendering correctness.

## Load and preserve your palette

1. Export the old palette profile and close the old panel. The new loader deliberately refuses to reuse an older v8.2 controller. One input owner only.
2. Run the commit-pinned loader supplied with this release. Anonymous raw loading requires the repository/file to be public.
3. Import your profile, open the native palette, and press **Validate Native Palette**. Old profiles without native semantic proof may require one native click per color, so initial validation can take several seconds. STOP cancels it. Validation selects palette colors but starts no paint worker.
4. Confirm learned 128, verified 128, live 128/128 and READY. Export the updated profile: it contains the verified semantic disambiguators used in future generations.
5. For NORMAL, choose your desired color through the normal palette after validation. START captures that color. Manual color changes during NORMAL stop it; restart explicitly with the new color.

## NORMAL dwell regression

The default and minimum dwell are **120 ms**. New arms, benchmark resets, tool sessions and an explicit NORMAL START cannot reinstall the old 250 ms fallback. Explicit NORMAL START discards stale timing training and starts at 120 ms; focus recovery retains the current run's evidence. Civil and NORMAL histories remain separate.

Success still ends service immediately;120 ms is a maximum initial service window, not a delay after a 50 ms correction. Qualified no-effects add at most 100 ms to that entry, with bounded retry/quarantine. They never train shared dwell. Acquisition failure, target loss, interruption, palette failure and input recovery never train shared dwell either. Only healthy qualified success latency can raise shared dwell, requiring four distinct entries; overload, camera, recovery and late samples are excluded. Fast successes pull the baseline back to 120 ms.

## Camera ownership

**Camera movement: LOCKED is the default. SAFE is an API alias for LOCKED.** LOCKED/OFF never acquire a camera snapshot or write Camera.CFrame, Focus, CameraType or CameraSubject. Inaccessible entries defer; visible healthy work continues. Target loss and exhausted budgets cannot unlock the camera.

The healthy path stays cached cursor point -> visible point -> genuine Mouse.Target -> native PER_TARGET DOWN -> matching color -> UP. On failure, the controller tries fresh/alternate projections and screen offsets under the current camera, waits for a fresh frame/budget, retries, and checks the real target. A 320 ms recovery budget prevents one bad cursor point monopolizing the worker. Incomplete proof remains pending/mismatch; it cannot be called unreachable.

AGGRESSIVE requires explicit opt-in while stopped. Only PROVEN_UNREACHABLE_CURRENT_VIEW can consult it. It is suppressed during overload, unstable focus/tool/session, palette blocking, recent manual camera input, entry cooldown or an open circuit breaker. It permits one constrained movement per dirty episode, at least 2 seconds between global movements and 8 seconds between attempts on one entry. A single upper-side pose is computed and checked before application using rotated province bounds, median surface elevation, geometry-scaled clearance and occupancy. There is no live orbit or multi-pose search.

Three consecutive failed moves, or poor acquisition/paint ROI over the bounded recent window, open the circuit. Temporary camera state is restored exactly at failure/end of transaction/STOP/focus loss/manual camera interaction, including CameraSubject. Camera solutions are retained for reuse only after qualified paint success, never after acquisition alone. No camera state is retained between target services. The visible emergency Camera movement button locks immediately.

## Palette persistence and outage handling

Each swatch has semantic RGB/key/path/class/name/text/image/visual signature plus its native-verified region and normalized position. The old bug discarded successful disambiguation and classified the same ten duplicate-style paths as ambiguous every generation. The new resolver uses the saved discriminator only when it identifies exactly one compatible equivalent control; creation order is not proof. Unresolved candidates still require native input verification. Delayed GUI layout is reconsidered against the cached candidate set without another full GUI traversal.

Generation status is DETACHED, INDEXING/REBINDING, VERIFYING_AMBIGUOUS, READY or DEGRADED. Only restoration of the complete expected set is READY. START/REROLL preflight is atomic and waits for READY; existing assignments are never rerolled on detachment. Already running Civil work can use available controls while unresolved colors defer. Ambiguous previously verified mappings have serialized maintenance at worker boundaries. No second palette/input worker runs.

Opener and closer keep the same semantic identity system. Learning observes actual visibility transitions; equivalent verified bindings survive recreation. **AUTO cannot close without a verified live opener.** Otherwise it displays KEEP OPEN. If the open palette obstructs a target and cannot safely be closed, that target defers. It does not gamble on a toggle or close away the only access path.

Palette transactions capture root/generation/tool/session/binding/visibility snapshots. A mid-transaction generation change aborts and restarts from a released boundary. Reports separate root visibility from the desired swatch visibility and distinguish NO_LIVE_OPENER, NATIVE_SWATCH_UNAVAILABLE, OPENER_ACTIVATION_FAILED, OPENER_CLICK_UNOBSERVED, PALETTE_DID_NOT_OPEN and focus/generation changes.

A global prerequisite failure enters PALETTE_BLOCKED once. Palette-dependent services wait for an actual visibility/binding/generation/access change rather than repeatedly failing. A missing individual swatch does not block other colors. A target requiring the already-selected verified native color can still paint during an outage. Once access returns, running Civil work resumes without START or relearning. Explicit STOP always cancels resume intent.

## Selection visuals

The original used a Highlight on cloned province geometry. This revision keeps the silhouette approach with **Highlight.Adornee pointing at the actual selected BasePart/MeshPart/UnionOperation**. No clones, rectangular SelectionBoxes or proxy hitboxes are created. Contour defaults ON; fill defaults OFF and can be toggled to subtle. Hover, clean, dirty and active markers use actual geometry; native province color and physical/query properties are untouched.

Protect/Unprotect drag still tracks only genuine Mouse.Target, deduplicates each stroke and sends no automated input while selecting. DONE does not start painting. Destroy/remove/clear removes the marker and connections.

Roblox documents a255 simultaneous Highlight limit, including disabled Highlights; other game effects share the engine limit. The controller does not bypass it. Rendering of concavities/holes and readability at zoom must be checked live. [Highlight documentation](https://create.roblox.com/docs/reference/engine/classes/Highlight).

## Custom colors and exact capacity

The two actual reported paths are inspected relative to dynamic LocalPlayer.PlayerGui:

- PaletteGui.ColorPallet.PaintSGui.Picker
- PaletteGui.ColorPallet.ColorTitle.ColorPicker

**Inspect custom UI** is read-only. **Test native Picker (UI only)** and **Test ColorPicker (UI only)** run only when explicitly pressed while stopped. They inspect the current path/class/visibility, use the same native GUI input sequence, collect newly visible RGB/HSV/picker controls, record native selected color before/after, and never start painting. **Copy Custom UI Report** exports all collected results.

A live Roblox window was visible during development, but the requested picker interaction did not complete because the application changed during inspection. A working RGB/HSV writer was therefore not established. Names and newly visible text fields are not proof of an arbitrary RGB setter.

**Conditional generated-color support is not enabled.** No automatic RGB writer, generated assignments or claimed capacity are invented. The optional guided RGB-field learner and full UI -> selected-color -> chosen-province capability test require the actual picker input/confirmation contract; that portion remains pending. The UI remains UNVERIFIED, not falsely UNSUPPORTED or VERIFIED. Send Copy Custom UI Report after testing both candidates to establish whether that adapter is possible. No hidden property/closure/RPC substitute is used.

Capacity reports separate learned, verified, live-bound, generation state, custom capability, generated assignments, selected count and exact shortage.167 selections/128 native unique colors gives shortage 39 and blocks Civil START/REROLL without silent color reuse. GUI detachment does not reduce semantic capacity.

## Exact live tests

### NORMAL, including the newly reported 250 ms regression

1. Select 10+ visible provinces, choose one native palette color, NORMAL/PER_TARGET, camera LOCKED. START; confirm GlobalDwellMs=120 initially. Correct targets must never be visited.
2. Confirm successful paints count and dirty reaches zero. Successes around 50–70 ms should release immediately, not wait 120 ms.
3. Recolor protected targets away from the cursor, then fight for at least 10 minutes. Watch fresh off-cursor detection, queue wait and corrections/sec. One problematic target may get EntryExtraDwellMs/backoff; healthy targets must retain the fast shared baseline.
4. STOP/START; switch NORMAL -> Civil -> NORMAL while stopped; restart. Verify no 250 ms default returns. Repeat focus/tool loss and recovery. No unqualified failure may increase shared dwell.
5. Keep hard/offscreen targets selected. Confirm zero visible camera movement, CameraMovesApplied=0 and no repeated zero-service monopolization. Copy Activation Report on a regression.

### 128-color persistence and Civil

1. Import your 128-color profile, Validate, confirm verified 128/live 128/READY. Export updated profile. Select 12–20+ provinces and reroll once.
2. START Civil with camera LOCKED. Confirm unique assigned colors, successful paint recognition and dirty zero. Recolor three provinces off-cursor; each must return to its original assigned color.
3. Recreate/respawn the native palette GUI, close/reopen it, and repeat 25 times where practical. Without pressing Validate again, equivalent generations must return 128/128/READY, with the same assignments. Short REBINDING states are honest; persistent 118/128 is a failure worth reporting.
4. Learn opener from a genuinely closed palette and closer from an open palette. AUTO close must reopen safely. Remove/hide the opener: KEEP OPEN must take effect before any automatic close. Restore access: Civil should resume automatically.
5. Leave the palette unavailable for a minute. Palette failures must not grow into hundreds of services; PALETTE_BLOCKED duration may grow, and suppressed scheduling counts may increase. Current-color work may continue.
6. Verify irregular/long/concave neighboring province contours and drag feedback. Real Mouse.Target must still be the actual province. Highlight rendering and new generation behavior remain live-unverified.

### Optional AGGRESSIVE

Use separately from the LOCKED acceptance test. Opt in while stopped. Recover an offscreen target: at most one rare above-map movement per episode, exact restoration, no underwater/underside camera. Repeated failures must open the circuit. User pan/zoom/keyboard/touch wins immediately. STOP must release input and restore the camera. Default LOCKED never needs this mode to pass.

## Reports to send back

Copy Activation Report includes existing native input, dirty/defense, NORMAL/Civil service records and full learned palette/assignment databases, plus:

- GlobalDwellMs, CurrentEntryExtraDwellMs, GlobalDwellBefore/After, rejected training reasons, strategy/window successes and service timing.
- AcquisitionState, CursorOnlyFailuresSinceSuccess, CameraFallbackAttemptsThisDirtyEpisode; per-entry health and last 20 recovery records.
- CameraControlMode, CameraCircuitBreaker, CameraMoveAttempts, CameraMovesApplied, CameraMoveTargetAcquisitions, CameraMoveSuccessfulPaints, CameraMoveFailures, acquisition/paint success rates, suppressed locked/circuit/user/cooldown attempts and restores.
- PaletteGenerationState, ExpectedVerifiedNativeCapacity, NativeVerifiedThisSession, live/semantic capacity, PersistedDisambiguationsRebound, per-color native proof/signature and candidate failures.
- PaletteBlocked, reason/duration/entries/recoveries, SuppressedPaletteUnavailableRetries, effective close policy and opener/closer binding state.
- PaletteStateSnapshotId, root alive/visible at start/failure, swatch binding/visibility, generation start/failure and precise opener/click errors.
- The custom-UI inventory/trial report, explicitly UNVERIFIED until a real writer and resulting province paint are proven.

A locally observed correction can also be caused by another player painting the same color. It is not a server acknowledgment. Local event-to-queue timing excludes unknown server-to-client replication latency.
