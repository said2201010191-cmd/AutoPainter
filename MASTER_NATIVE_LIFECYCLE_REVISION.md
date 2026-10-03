# Native Lifecycle revision — master specification implementation

Base: `7329de907140d23c78ebf937454026e4f20266c7`. Build identity: `8.2-master-ab`.

The complete 20,647-line / 1,465,104-byte supplied master file was read before edits. SHA-256: `131edbdc7b7e7873e3ef3b330d74b3f4526f4aa158a1d164cfd38ece747cb628`. Its implementation sections take priority over earlier claims embedded in the appended reports. Every appended report was consumed, including per-attempt records, failures, assignments and palette mappings; repeated inventory rows were aggregated for comparison. The actual 128 native RGB values are retained as a test fixture without account or GUI path data.

## What the existing evidence establishes

| Supplied live evidence | Useful finding |
| --- | --- |
| Older NORMAL | 431 observed successes, ~99.08% overall; recent 16/16, ~4.07 CPS, ~244.5 ms actual mean spacing. Not proof of a minimum cadence. |
| Public benchmark 1 | 150 requested: 38/40; 140: 38/40; 130: 21/40. |
| Public benchmark 2 | 150 requested: 40/40; 140: 24/40. The run later paused with 39/40 usable cohort entries. |
| Private benchmark | Control only; 40/40 through 50 requested. Never applied to production. |
| NORMAL multiplayer combat | Recent 10/16, ~3.66 CPS; ~169.4 ms actual mean; fresh queue P50/P90/P99 ~8.59/14.46/22.92 seconds. |
| Earlier Civil comparison | Last 20 transactions successful; native palette preparation mean ~110.49 ms. Refresh and extra elapsed time are confounded. |
| 192-selection generated proof | 64 generated observed provinces and 86 exact generated results. This establishes user-observed native RGB application. |
| Latest heavy Civil | 1,872 exact generated results; recent Civil 16/16, ~7.35 CPS; last-20 actual spacings include ~149.96–150.02 ms. SelectionAdds=940 is cumulative, not a proof that 940 were simultaneously rendered. Two preparation failures and CoreGUI input errors also appear. |

The source explains a concrete difference, but does not yet establish the live root cause. `PaintBucket.LocalScript` creates `v39 = 0` **inside Equipped**, reloads working color `v15` there, and sets `v39 = tick()` **after its normal InvokeServer returns**. Public native `doPaint` checks elapsed time relative to that returned-call timestamp. Thus a real Button1Down plus correct Mouse.Target does not prove the native tool sent a paint call. Color replication latency is not the same as remote round-trip/return latency. Generated Civil creates a new native equipped session; ordinary NORMAL keeps its session. Same-swatch clicks update `v15` but do not reset the equipped-session clock. See the existing [full source trace](NATIVE_GENERATED_COLOR_TRACE.md), extracted runtime lines 316–325 and 455–474.

No native handler, timestamp, closure, validator, signal or remote was replaced or hooked. The normal tool remains responsible for all actual requests.

## NORMAL A/B/C/D diagnostic

New buttons replace the two already-rejected Picker experiment shortcuts. Read-only custom UI investigation APIs remain available.

- **NORMAL A/B: Start A B C** runs **A → B → C → C → B → A** using the existing single worker, target acquisition, exclusive lock, target-local retry policy, fixed 120 ms paint window and one unchanged NORMAL color. Default: 40 qualified attempts or 60 seconds per phase; at most 120 total services per phase. Idle phases finish as `INSUFFICIENT_QUALIFIED_WORK`; they never generate work by painting clean provinces.
- **A CURRENT:** original retained tool session, no palette interaction.
- **B EQUIP_REFRESH:** resolved UP, genuine UnequipTools/EquipTool, unchanged existing color attribute, new native PaletteGui plus three matching working-color indicators, then genuine target acquisition and native input. No attribute writes in this NORMAL branch.
- **C SAME_SWATCH:** actual current-center native UI click on the matching learned swatch. Unlike a color-changing Civil click, an already-correct attribute is insufficient: the normal `MouseButton1Click` event must also be observed. Missing mapping is explicitly skipped. Missing/broken access or release stops safely with a reason.
- **NORMAL D: actual spacing:** available after A/B completion if needed. Runs A-like services at observed-DOWN floors 175, 190, 200, 210 and 225 ms. Prior A/B records are retained. Not a new cooldown sweep; no reset colors or Civil timing changes.
- **Copy NORMAL A/B Report** exports only collected evidence, with file fallback `AutoPainterNormalABReport.txt`.
- Q/Escape/STOP cancels safely. Focus loss, external tool/character loss, changing color/upgrades/cohort invalidates the experiment; it never automatically resumes as an experimental paint worker. The selected cohort, desired color and production choice remain stored.

Every arm uses **timestamps observed from genuine native DOWN events**, not API return time. The gate cannot promise perfectly exact spacing because input/frame propagation adds delay; actual min/mean/P50/P90/max are exported. No cadence wait enters dwell training. Diagnostic services do not train production strategy/dwell.

Report includes attempts, qualified attempts, successes, overall and qualified recent success, VALID_NO_EFFECT, no-effect percentage, useful CPS over whole phase wall time, actual spacing, DOWN→color, acquisition/preparation/service, fresh response P50/P90/P99, overall/fresh/retry queue percentiles, dirty/peak dirty, phase attack rate, overload time, target losses, retries, pathological-group attempts and every bounded sample's timestamps/result/RGB. Idle time is included in phase CPS so phases with insufficient attack pressure cannot be mistaken for matched throughput tests.

**Production policy is intentionally not declared solved:** default remains A, PER_TARGET, 150 ms floor from the last observed native DOWN, 120 ms healthy dwell. No automatic 200 ms change or production winner. The explicit **NORMAL production path: A/B/C** button allows choosing a supported tested path while stopped. Civil bypasses this NORMAL floor. After matched live data, choose the path with reliable corrections, healthier queues and higher useful CPS; a B/C winner must beat the control in both directions of the paired order. A faster arm with lower reliability is not automatically better. If elapsed time differs, compare D or repeat with matched actual spacing before attributing causality to refresh.

### Live NORMAL procedure

1. Export palette, STOP/close older controller, load the pinned build and import/rebind the profile. Choose one native color normally; leave mode NORMAL and camera LOCKED. Keep >30 visible protected provinces and the same multiplayer/server/upgrade conditions throughout.
2. Arrange ongoing external recoloring with comparable attack pressure. Press **NORMAL A/B: Start A B C** once. It does not recolor/reset the map to manufacture samples. Keep Roblox focused. Report incomplete phases as insufficient evidence, not success.
3. When complete, **Copy NORMAL A/B Report** and **Copy Activation Report**. Only run D if A/B/C do not explain the difference; no cooldown benchmark is required.
4. Select a candidate production path explicitly, then run several minutes of fresh multiplayer combat. Compare useful CPS, qualified miss rate, fresh queue P50/P90/P99, target recovery and Dirty=0 after pressure stops. No new production winner is live-proven by this release.

## Generated color quality and naming

Native application is preserved byte-for-byte: `palette.prepareGenerated`, the native palette click sequence and `acquireFast` are unchanged. The user's supplied live proof supersedes the earlier application-unverified status of the previous investigation; this revised generator still needs its own live regression.

Overflow selection uses bounded **farthest-point max-min sampling in OKLab**, Euclidean distance ×100. Candidate pool defaults to 1,536 seeded byte-RGB values, grows to twice overflow count (maximum 16,384), with bounded sampling attempts and useful lightness 0.25–0.91. Each candidate is compared against all native colors and every retained/assigned generated color. After selecting the largest minimum distance, remaining candidates update their nearest distance. Shared ±1 RGB collision checks remain mandatory. No impossible fixed minimum perceptual distance is promised as the space crowds; exhaustion returns explicitly without partial assignment.

The same seed reproduces results. Colors stay fixed across retries/recolor/GUI replacement, with explicit reroll generating new assignments. Labels are **GEN #001 — RGB r,g,b**, source GENERATED, native index NONE/0. HUD/current target and full assignment report show that label. While stopped, hover a protected province and press **I** to inspect source, exact RGB, ordinal and native palette index. Native game labels are never overwritten.

`GENERATED PERCEPTUAL COLORS` exports the metric, pool size, closest native/generated RGBs and distances for every generated assignment, plus overall minima. Report generation performs no input.

Deterministic result using the **actual exported 128-color palette**, 182 total assignments, seed 182:

- Generated count: 54.
- Minimum generated→native distance: **6.760437 OKLab ×100**.
- Minimum generated→generated distance: **6.742392 OKLab ×100**.
- No normalized collisions. Visual distinctness still depends on the display, province size and color vision; numeric separation is not a live visual guarantee.

Conversion reference: [Ottosson's original OKLab definition](https://bottosson.github.io/posts/oklab/).

## Bounded province-shaped renderer

The old per-province Highlight allocation is removed. Selected entries own **local geometry proxies** cloned from the real Part/MeshPart/UnionOperation, preserving mesh geometry rather than substituting SelectionBoxes. Proxies are grouped by five visual states (clean-light/dark, dirty-light/dark, active) and eight spatial shards: **at most 40 protected Highlights**, plus the existing independent selection-hover Highlight. Spatial coloring separates adjoining proxies into different groups to reduce merged silhouettes. A dense same-shard boundary can still merge on the GPU; this must be assessed live.

Proxies have CanCollide/CanTouch/CanQuery=false, Anchored=true, CastShadow=false, 0.99 transparency, matching original CFrame/Size. Near-transparent geometry keeps them renderable for Highlight; the remaining 1% surface contribution and occlusion must be checked live. Clones are sanitized while unparented, keeping only mesh geometry; executable/physical/other children are removed before Workspace parenting. Original province Instances are never changed or reparented. CFrame/Size/shape/mesh signals keep proxies aligned or rebuild them. Correct entries have no paint work, only event subscriptions.

OFF **destroys** all protected proxy/group/Highlight resources and geometry listeners; selection/dirty state stays intact. ON reconstructs them without reselection. Empty state groups stay within the fixed 40-Highlight budget until OFF/clear, avoiding resource allocation churn on every healthy correction. Removing/clearing/destroying a selection releases its proxy/listeners. An uncloneable source is reported as a visual gap rather than silently replacing it with a rectangle or writing Archivable on the game part.

Roblox documents the [255-Highlight limit and disabled-slot behavior](https://create.roblox.com/docs/effects/highlighting). Grouping removes AutoPainter's per-selection Highlight limit. It cannot guarantee remaining engine capacity if another system already consumes most slots, nor prove GPU output from object counts.

Metrics: SelectedProvinceCount, VisualizedProvinceCount, VisualMissingCount, HighlightInstanceCount, ProxyPartCount, VisualRendererGeneration, VisualRebuilds, VisualRebuildFailures, VisualStateMigrations, VisualResourcesReleasedOnOff. `RenderVisibilityProof` explicitly says counts represent attached geometry, not observed pixels.

Deterministic geometry/resource tests cover **128, 255, 256, 300, 500, 900 and 1,000 selections**, ON→OFF→ON, three repeated 900-entry rebuilds, add/remove/clear, fill preservation, state migration, moved/resized parts, mesh types and clone sanitization. All selected cloneable entries have proxies, protected Highlight count ≤40, OFF resources=0, and repeated rebuilds do not increase connection count.

### Live renderer/generated procedure

1. Select 300, then 500, then 900+ provinces. Inspect actual outlines/fills, not only counts. Toggle OFF→ON at 500 and 900. Add/remove afterward; toggle fill and NORMAL/Civil; reroll while stopped; clear all. Confirm all expected silhouettes return and real mouse still targets original provinces.
2. Use Civil with >128, reroll and inspect GEN labels/RGB. Confirm exact generated results remain recognized and that previously corrected provinces restore their own unchanged RGB after external recolor.
3. Send Activation Report plus observed maximum simultaneous visible province count. **Maximum live visualized count for this renderer: not yet measured. Live OFF→ON result: not yet measured.**

## Validation and remaining decisions

**1,182 deterministic tests pass; 41/41 Luau files compile.** This includes all previous 1,112 cases and 70 master-revision cases. The source-shaped mock comparison gives A 15/30 versus B 20/20; C ~51–52% in that model. Those are deliberately constructed mock outcomes, not live A/B evidence or a production decision. Tests are not live acceptance proof. Existing test cases were retained; per-province Highlight assertions now check the replacement model/proxy architecture and actual resource release. A reverse-patch scope guard continues to verify the prior entire controller, and explicit hashes protect generated transport, palette clicks and acquisition.

Remaining live-dependent requirements: matched A/B explanation and production winner; fresh multiplayer NORMAL reliability/CPS; >255 actual visible silhouettes and rebuild; perceptual output and generated/native application regression. These cannot be honestly established by deterministic tests or the older reports. No live paints were performed by the coding agent in this revision.
