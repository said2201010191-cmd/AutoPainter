# v8.2 validation record

Base: v8.1 `bcea953d87f29e6c5b368b715ec63f145ff8c16a`. Runtime: `AutoPainterHandsFree.luau`, version8.2. Specification coverage is recorded individually for all107 numbered sections in [V82_SPEC_IMPLEMENTATION.md](V82_SPEC_IMPLEMENTATION.md).

## Results

| Check | Result |
|---|---|
| Existing native-controller suites | 222 passed |
| Locked diagnostic suites | 246 passed |
| Existing Hands Free regression suite | 208 passed |
| New v8.2 regression suite | 106 passed |
| Total deterministic tests | **782 passed** |
| All repository Luau files | **31/31 compiled** |
| Normalized color matcher guard | Byte-identical to v8.1 |
| Native palette click/settle/hold guard | Same native sequence/timings; new clean gate excluded from guard |
| Cursor movement guard | Same implementation except explicit GUI-obstruction movement gate after palette work |
| Forbidden active-runtime operations | No direct InvokeServer/FireServer, hooks, direct signal firing, Mouse.Target assignment, palette attribute write, require or decompile |
| 128 duplicate-style swatches | All128 bound, zero ambiguous after observed native candidate selection |
| 25 recreated palettes | Semantic identities/assignments preserved; binding work scales with generations |
| Stable generation for three simulated minutes | Constant full traversal and rebind counts, including repeated Civil corrections |
| Event-perfect reconciliation | More than10x fewer checks than120ms baseline; dropped event recovered |
| 55 NORMAL / 80 Civil workload | Healthy work continues around hot, unpaintable or unavailable targets |
| Eligible/deferred clock separation | Exact arithmetic including100s quarantine |
| Camera / selection | Unsafe poses refused; original view restored; genuine-target drag add/remove; zero AutoPainter game requests |

Commands:

```sh
python3 tests/run_tests.py /path/to/luau
python3 tests/check_luau.py /path/to/luau-compile
```

The compiler checks the original Markdown-wrapped reference through a temporary unwrapped copy; the committed reference is untouched. The test-only lexical seam exists solely in `tests/v82_regression.spec.luau`, not in the shipped script. Both immediate and deferred signal delivery are covered. The mock fixture models input/tool/palette/color behavior; it does not call game remotes or simulate authoritative server validation.

## Final review changes beyond the initial implementation

- Exhausted projection budgets wait for a fresh frame instead of triggering unnecessary camera fallback.
- A correct PlayerMouse.Target does not skip cursor movement if an interactive GUI still owns its current position; before DOWN the real target and clear GUI are checked again.
- Missing palette color/control defers locally; closed palette with already-correct selected color skips reopening.
- Native candidate validation discovers the existing input handle once, owns the single worker slot, can be canceled, and cannot start painting or auto-resume a paint worker.
- Longer group cooldowns keep their accounting category when a shorter overload retry is requested.
- Root detachment and signature changes invalidate stale live bindings without deleting semantic identities or repeatedly scanning PlayerGui.
- Failed candidate trials can retry their cached candidate list after cooldown without rescanning; profile geometry is schema-checked.
- Relearning opener/closer retires old semantic references; recreated roots disconnect old listeners.
- Selection refuses to arm when normal tool unequip fails; focus loss stops the stroke. Explicit STOP/mode changes cancel pending focus resume.
- Paint/release/defense timings now exist for NORMAL and Civil, and late attribution is excluded from dwell training.

## What these checks do not establish

**v8.2 is not live-proven.** The user’s v8.1 live evidence remains the only real-client performance baseline. Native input delivery, actual128-control duplication/layout, mouse/camera ray behavior, replication, server-side cooldown/state and long-session combat need the exact procedures in [ACTIVATION_GUIDE.md](ACTIVATION_GUIDE.md), including30–45+minutes of Civil combat and real GUI recreation.

Standalone `luau-analyze` was also inspected. Without Roblox/executor type definitions it reports unavailable globals/types and type-inference limits. Compilation and deterministic runtime tests passed; a clean Roblox engine typecheck is **not** claimed.

Custom generated colors beyond the native palette were not enabled. No verified legitimate custom-color UI contract was supplied or observable in a live client here. Candidate controls are only inventoried and labeled UNVERIFIED; generated capacity remains0 and impossible unique assignments are blocked. This is the specification’s explicit game-support-dependent branch, not an alternative transport.

Spatial camera occupancy uses conservative bounding boxes and may reject some otherwise viewable hollow/complex geometry. Restoring the user's saved camera returns their original view; safe-pose acceptance governs new automatic candidates. Dirty ColorChanged timestamps measure local callback/queue behavior, not unknown server-to-client latency. A successful color observation can also reflect another player's matching paint; it is not a server acknowledgment.
