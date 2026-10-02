# AutoPainter Hands Free v8.1

The user has live-verified fast NORMAL painting and v8 Civil palette selection/painting. **v8.1 long-run NORMAL recovery and PaletteGui rebinding remain live-unverified until the user tests them.** Mock tests do not establish live input delivery, replication latency, server behavior, or corrections/sec.

## Load and preserve the learned palette

1. In the existing v8 panel, STOP and **Export Palette Profile** before closing it. The new loader cannot read another controller's private Lua tables. Export/import preserves the semantic mappings across a controller reload; GUI recreation within one v8.1 session needs no export.
2. Close the old panel; run:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/said2201010191-cmd/AutoPainter/main/AutoPainterHandsFree.luau", true))()
```

3. Equip the normal bucket, let its native palette GUI exist, and **Import Palette Profile**. Existing v8 profiles are supported. Each client uses its own `Players.LocalPlayer`, GUI, input ownership, selections and scheduler. Duplicate v8.1 loads reuse the same controller; older controllers must close first.

The public loader requires a public file/repository and the client environment's existing loadstring/HttpGet/VirtualInput facilities. No Studio, place editing, server installation, account-specific identity, or credentials are required. AutoPainter sends **zero game RPCs**. The normal PaintBucket owns all actual paint requests and cooldowns. There are no target/callback/validator hooks or spoofing.

## NORMAL recovery

The healthy path remains ColorChanged → cached cursor → genuine Mouse.Target → native PER_TARGET DOWN → normalized desired color → UP → next target. No recovery sleep is added to a successful service. The normalized matcher, camera solver, and native Civil preparation algorithm retain source guards against v8; the palette click/settle/hold algorithm also has a guard excluding binding/ownership annotations. Scheduler/release hashes from v7 are historical references, not a claim those recovery functions remain frozen.

A failed entry now has an explicit outcome and retry deadline. The first failure defers 120 ms. A second acquisition/target/input failure invalidates cursor cache; the third also invalidates camera cache and begins a 250 ms quarantine. Further cycles use 400, 650, then at most 1000 ms. These delays apply to that entry only. Success clears its streak, local dwell penalty and quarantine. Old dirty work ages ahead of fresh work; aged entries are ordered by time since service before distance. A-B-A-B without correction puts the weaker target on a pair cooldown while the other receives a full bounded transaction.

Cursor acquisition still uses cached point → visible projection → cached camera → original camera solver. A failed cursor point is invalidated and an alternate surface projection tried before camera fallback. Healthy target geometry/camera math is unchanged.

Outcomes are `SUCCESS`, `VALID_NO_EFFECT`, `ACQUIRE_FAILED`, `TARGET_LOST`, `INTERRUPTED`, `INPUT_STATE_CONFLICT`, `FOCUS_LOST`, `TOOL_UNAVAILABLE`, `RELEASE_RECOVERY`, and `CLEAN_BEFORE_DOWN`. Civil preparation errors retain their detailed stage-specific reason. Acquisition and qualification are reported separately; a target acquired before an input failure no longer appears as zero acquisition merely because no paint service qualified.

### Timing

- PER_TARGET remains the default. CONTINUOUS/ADAPTIVE are explicit experimental settings, never automatically selected by the default.
- Shared NORMAL dwell starts at 250 ms and learns a successful P90 + 40 ms margin, bounded to 120–350 ms. A successful result exits immediately; the dwell is a ceiling.
- A fully qualified no-effect requires actual target ownership, observed native DOWN, the full intended window, valid palette and resolved input/session state. Acquisition, lost-target, interrupted, focus, input-conflict and release-recovery outcomes **never increase paint dwell**.
- A valid miss adds 20 ms to that entry's allowance, capped at 100 ms and the overall 350 ms ceiling. Three distinct entries with qualified misses within two seconds may raise the global baseline by 20 ms. One difficult target cannot do so alone.
- Successful history pulls an elevated NORMAL baseline down by up to 40 ms per sample toward successful P90 + margin. Civil timing history remains independent.
- Explicit START clears failure/quarantine/abandoned-transaction state and stale timing penalties; it preserves valid targeting caches and successful latency history. Focus return requires explicit RESUME.

These parameters are near the top of `AutoPainterHandsFree.luau`. They do not change the native tool's cooldown or remote protocol.

### Input ownership

States: `IDLE`, `DOWN_SENT`, `DOWN_CONFIRMED`, `UP_SENT`, `RELEASE_CONFIRMED`, `RECOVERING`.

A physical pressed state prevents another DOWN. For an owned/recently owned state (same tool, within two seconds), one controlled UP is sent and a release boundary must resolve before a new target attempt. An unowned press stops automation without releasing someone else's input. Duplicate DOWN errors enter the same recovery instead of unlocking another activation method. A duplicate UP error with actual unpressed state can resolve after the existing 60 ms quiet grace. An unresolved release stops; the worker never moves on with unresolved Mouse1 ownership. A silently lost physical hold is an input conflict, not a paint miss.

## Civil palette persistence

The v8 palette interaction sequence is retained: CURRENT button center, exact top-button check, one render-frame settle, 25 ms click hold, real PaintBucketColor verification, and at most one retry (two settle frames, 40 ms hold). Attribute evidence can confirm selection even when Activated observation is missed. Existing opener/closer postconditions, unique random assignments, color pools and province transaction lock remain.

Each learned row has two identities:

- **Semantic identity:** index, RGB/key, relative PlayerGui path segments/classes, name/text/image/background signature, successful-use statistics, and assigned province references.
- **Live binding:** the currently resolved button Instance. It may disappear and be replaced.

`resolvePaletteControl` accepts the existing live binding or traverses the exact stored relative path under CURRENT PlayerGui, rejects duplicate/ambiguous path segments, verifies the replacement signature, then repairs the button lookup. It never binds a vaguely similar control elsewhere. Exact-path changes/incompatible signatures require targeted relearning; ordinary GUI recreation with the same identity does not.

Bindings use `BOUND`, `DETACHED`, `REBIND_PENDING`, `REBOUND`, `SIGNATURE_MISMATCH`, or `INVALID`. Detachment never deletes learned metadata. A missing root reports `CivilCapacityStatus=temporarily unavailable`; numeric CivilCapacity stays 0 until bindings return. All learned rows and assignments remain. Only incompatible controls become unusable; other colors can rebind normally.

Resolution is lazy before capacity queries, assignment/reroll, START, and palette use. Focus return, character changes, root replacement and imports invalidate lookup retry caches. Failed exact lookups are throttled to 200 ms within an unchanged binding epoch; a detected root replacement or explicit resume retries immediately. There is no new full-game scan or per-province task.

Openers and closers use the same semantic resolver. Civil assignments survive GUI loss unchanged: no automatic reroll. If loss occurs mid-transaction, owned input is released, the run stops safely, and explicit RESUME retries after the native GUI returns. A running idle Civil controller can bind a replacement lazily before its next correction. Respawn may stop the run; re-equip and RESUME.

### Learn / copy / profile

If no profile exists: open the native palette while stopped, click **Learn native palette colors**, manually choose distinct swatches, then **DONE / FINISH SETUP**. Learn an opener and, if the palette blocks the map, a closer. A click that does not change the exposed selected color supplies no new mapping evidence. Dynamic controls whose meaning changes are not treated as fixed swatches.

**Copy Learned Palette** exports every learned row as `Name | RGB | FullGuiPath`; fallback is `AutoPainterLearnedPalette.txt`. **Copy Activation Report** includes the uncapped database, live binding states and all Civil assignments. Neither copy action clicks or paints.

**Export Palette Profile** writes `AutoPainterPaletteProfile.json` (clipboard fallback). It includes semantic paths/signatures/RGB, not Instance pointers or executable code. **Import Palette Profile** reads that file if readfile is exposed; alternatively `api.ImportPaletteProfile(jsonText)` accepts JSON. Import validates place/schema/RGB/duplicates atomically, then resolves live bindings independently. Missing GUI metadata is retained pending rebind; one incompatible binding does not discard other rows. Imported coordinates are never blindly replayed: every click recalculates the current center and checks actual selected color. Reopening the controller without a profile still clears its in-memory database.

**Reroll Civil Colors** is stopped-only and draws unique validated native colors without replacement. Existing assignments stay fixed during defense. Seed and pools (ALL LEARNED, HIGH CONTRAST, VIVID, DARK, LIGHT) retain v8 behavior; a filtered shortage falls back to all usable learned colors. Reuse is disabled. Switching NORMAL/CIVIL does not erase the database or mix target colors.

## NORMAL live stress test

1. Close the older controller and load v8.1. Select the intended color through the normal bucket palette. Use NORMAL / default PER_TARGET; select 20 provinces, including several already matching; finish selection, START.
2. Confirm successful paints, clean provinces skipped, DirtyCount eventually 0, and `CursorMovesToAlreadyCleanProvince=0`. Healthy operation should remain responsive; no specific live throughput is promised by tests.
3. Have a friend repeatedly recolor different protected provinces for **at least 5 minutes**, including while your cursor is elsewhere. Verify immediate local dirty markers and off-cursor events; no hover patrol is involved. Server-to-client replication delay is unknown.
4. Include a difficult/temporarily obstructed province. Watch that it backs off while other dirty provinces continue. Recovery events should distinguish ACQUIRE_FAILED/TARGET_LOST from VALID_NO_EFFECT; no dozens of immediate zero-service retries or persistent A-B-A-B movement. MaxDirtyAgeMs can grow for an impossible target, but other targets must still receive service.
5. Remove the obstruction. Expect fresh cache acquisition, a successful correction and reset entry failure streak. A high shared dwell should recover with successful samples; unqualified failures must not train it.
6. STOP, test focus loss/return and tool removal/re-equip, and use explicit RESUME. Confirm no held button, duplicate-state storm or unresolved input overlap. Do not artificially force duplicate input by hooking the game; observe recovery if it occurs naturally.
7. Copy Activation Report after healthy, degraded and recovered phases. Include a short description of workload and any visibly problematic entry ID/position.

## Civil GUI-recreation live test

1. Export the already-learned 128-color database from v8 before upgrading; import it into v8.1 with the native GUI present. Confirm LearnedPaletteColors=128, BoundPaletteControls=128, CivilCapacity=128 (assuming all signatures still match).
2. Select 20+ provinces, choose CIVIL WAR, reroll once, and copy the assignment report. START. Check distinct assigned colors, successful defense, DirtyCount=0, no palette click spam or release timeout.
3. Recreate the native PaletteGui using the game's normal UI lifecycle or respawn. Do not close/reload AutoPainter for this in-session test. While absent, expect learned count/assignment colors retained and capacity temporarily unavailable.
4. Once the GUI returns, re-equip if needed and explicitly RESUME if stopped. Expect bound/capacity counts to recover, PaletteControlsRebound to rise and new CurrentButtonPath/LastBoundGeneration rows. Old Civil color keys must be unchanged. No relearning/reroll should be needed for identical paths/signatures.
5. Have a friend recolor three protected provinces while your cursor is elsewhere. Each should queue and restore its ORIGINAL assigned color.
6. Repeat GUI recreation/focus loss several times. Copy Activation Report and Copy Learned Palette before and after. If one signature genuinely changed, inspect its BindingState/BindingFailure and relearn that control; do not bypass the identity check.

## New Copy Activation Report fields

Existing strategy, color, input, queue, palette transaction, Civil assignment and NORMAL baseline sections remain. v8.1 adds:

- **Recovery/timing:** ConsecutiveFailuresCurrentTarget, TargetQuarantines, CacheInvalidations, BadTargetRecoveries, InterruptedAttempts, ValidNoEffectAttempts, DwellIncreaseReason, GlobalDwellMs, CurrentEntryExtraDwellMs, LongestConsecutiveSameEntryFailures, MaxDirtyAgeMs, OscillationPrevented, PairCooldowns.
- **Ownership:** InputState, DuplicateDownStates, DuplicateUpStates, InputStateResyncs, SuccessfulInputResyncs, FailedInputResyncs, plus existing releases sent/observed/quiet-confirmed/timeouts.
- **Palette binding:** LearnedPaletteColors, BoundPaletteControls, DetachedPaletteControls, RebindPending, SignatureMismatches, CivilCapacity, CivilCapacityStatus, PaletteGuiGenerations, PaletteRebindAttempts, PaletteControlsRebound, PaletteRebindFailures, OpenerRebinds, CloserRebinds, LastPaletteRebindReason. Each color includes BindingState, CurrentButtonPath, LastBoundGeneration and BindingFailure.
- **Last 20 recovery events:** entry ID, time, reason, action, old cache state, cooldown and outcome. Last 20 transactions now separate TargetAcquired, MouseTargetCorrect, ServiceQualified, FullWindowCompleted and Result.
- **Per-entry API:** `GetTargetStats(part)` includes ConsecutiveAcquireFailures, ConsecutiveTargetLosses, ConsecutiveValidNoEffects, ConsecutiveFailures, LastFailureReason, RetryAfter, CacheInvalidations, RecoverySuccesses and EntryExtraDwellMs, alongside stable ID/position/colors/cache/event times. `GetRecoveryEvents()` returns copies of the bounded recovery log.

For feedback send the **entire Copy Activation Report**, including last transactions/recoveries, bindings and assignments. A local color transition is not a server acknowledgment, and local ColorChanged-to-queue time excludes unknown replication latency.

## Validation

676 deterministic tests pass: 222 native-controller, 246 locked-diagnostic, and 208 Hands Free (104 cases with immediate/deferred signals). All 28 Luau files compile; the original reference's Markdown wrapper is removed only in a temporary compile copy. Existing reference files are preserved. Standalone analysis reports only unavailable Roblox/executor globals/types; it is not Roblox engine type validation.

Fault tests include 20 dirty entries with one impossible target; 10+ target losses; bounded cooldown/fairness/cache recovery; duplicate DOWN/UP and actual-state resync; no global dwell training from acquisition/input/release failures; distinct qualified misses and successful recovery; ABAB suppression; separate mode timing; 128 recreated controls; opener/closer replacement; temporary absence; mismatched signatures; profile import after recreation/while missing; focus loss; GUI loss mid-transaction; repeated rebind without listener growth; and zero AutoPainter RPCs.
