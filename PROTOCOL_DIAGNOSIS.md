# PaintBucket protocol investigation — unresolved first-request rejection

The user reports that selection and committing while painting is OFF succeed, but the very first Safe-mode PaintPart request causes a disconnect. The selection fix and concurrency tests do not establish that the game's normal tool protocol is correct. No rate, burst or concurrency settings were reduced in this revision. **The live issue is not fixed or live-validated.**

## Available evidence

The supplied ZIP contains `AutoPainterOriginal.luau` and `AutoPainterFastClient.luau`. The repository additionally contains the final AutoPainter, loaders, documentation and mock tests. Neither the ZIP nor repository contains the game's normal PaintBucket LocalScript, its required modules, its color UI/controller, or the server callback/validation contract. There is no live Roblox engine bridge attached to this workspace. The latest user-supplied inventory identifies Backpack PaintBucket LocalScripts named LocalScript, RemoteScript and VipTextures, plus Remotes.ClientControls (RemoteFunction). Their source contents have not yet been supplied; names alone do not establish the protocol.

The original constructs the same three arguments in `paintProvinceLoop`, and calls the equipped-character path directly. FastClient copies that call into `requestPaint`; the final version keeps it in `invoke`. There is no earlier game remote invocation in these supplied AutoPainter files. This establishes agreement between the three AutoPainter implementations, **not agreement with the normal game tool**.

```lua
ServerControls:InvokeServer(
    "PaintPart",
    { Part = province, Color = desiredColor },
    "Peace"
)
```

| Question | What the available AutoPainter source establishes | What remains unknown about the normal tool/server |
|---|---|---|
| Earlier remote call or handshake? | AutoPainter makes no game remote call before PaintPart. | Whether normal initialization/equip/activation calls another remote or receives a setup callback first. |
| Mode/state before painting? | AutoPainter changes its own UI/scheduler settings only. | Normal tool state transitions and whether the server requires them. |
| Is `"Peace"` always correct? | It is an unconditional literal inherited from the original. | Its meaning, valid values, and when normal code chooses it. No alternate value was guessed. |
| Where must Color come from? | A private AutoPainter Color3, or its per-province add-time snapshot. | Whether the normal bucket uses a value/attribute/module/GUI state, or whether the server constrains this argument. |
| Must the tool be equipped? | Final resolves PaintBucket directly under current Character and checks Character is in Workspace. It does not verify Tool class, Enabled, Handle, or Humanoid in its request path. | Whether this is sufficient, whether normal equip handlers finish additional initialization, and what the server checks. Local ancestry alone is not proof of server acceptance. |
| Token/session/state issued by server? | None is captured or sent by the supplied AutoPainter code. | Whether one exists, its legitimate lifecycle and how the normal client obtains/uses it. |
| Cooldown/timestamp/state machine? | Only AutoPainter's own pacing, error cooldowns and request counters are implemented. | The game's own cooldown, timestamps, action sequencing and validation rules. |
| Part representation? | The actual selected Workspace BasePart named Province is passed as `Part`; it is not a clone. | Whether the normal flow uses this Instance, an ID, a parent, a hit result, coordinates, or a different structure. |
| Extra arguments/payload fields? | Exactly command, `{Part, Color}`, and `"Peace"`. | Normal argument order/types and optional/required additional fields. |
| Property/attribute changed first? | No game-tool property/attribute is written by the final painter. | Whether a legitimate setter is part of the normal client flow and what its handlers do. |
| Different remote? | AutoPainter resolves `LocalPlayer.Character.PaintBucket.Remotes.ServerControls` as a RemoteFunction. | Whether the current normal client uses that exact instance/path/direction, another remote, or a wrapper. |
| Humanoid, ancestry, distance or other validation? | Final previously checked only Character in Workspace, the remote class, and province validity. | Exact server validation; client-visible metadata cannot prove or replace it. |

The reported first-request failure directs investigation toward the normal call contract and legitimate preconditions. It does not identify which field/check caused the rejection. This revision deliberately makes no protocol repair claim and sends no exploratory variants.

## Diagnostic implementation

`AutoPainterFinal.luau` now starts with `CONFIG.DiagnosticOnly = true`. Pending selection, Done, color controls, normal remote caching and respawn recovery still work. A separate **Diagnostics · no requests** control gates evaluation, the deferred pump, capacity reservation and the final invocation boundary. No task waits for a request slot. Turning diagnostics ON clears unsent ready/retry work. Calls that were already sent are counted until their real return; they cannot be canceled. The Suppressed counter covers reserved workers stopped before invocation, not server errors or successfully canceled network calls.

`LoaderDiagnostic.luau` starts the same script with diagnostics **locked ON** for that instance. Q, Toggle Paint, Safe/Fast and `SetDiagnostic(false)` cannot unlock it. Re-loading diagnostics on a compatible instance enables/locks the same instance without committing selection. An older UI without the current version-3 diagnostic capability marker is refused before invoking its controller; close the older panel first, including version-1 or version-2 diagnostic panels. The normal unlocked diagnostic control, if explicitly turned OFF, sets Toggle Paint OFF, requiring a separate deliberate resume. There is no automatic test-paint button.

**Local state report → Inspect** takes a fresh read-only snapshot, displayed in a selectable, non-editable UI text box with Prev / Next pages. `GetDiagnosticReport()` returns the same report for local inspection. It shows:

- Diagnostic/lock/toggle/selection state, pending and committed counts, actual invocation outcomes and outstanding/stalled calls.
- Current Character ancestry, Humanoid health/state, observed Tool ancestry, Enabled, RequiresHandle, ManualActivationOnly and Handle presence/class.
- Fresh versus cached remote path/class, cache version and whether the expected remote path resolves. It explicitly labels this as **not a server-readiness test**.
- Equipped/backpack PaintBucket hierarchy, local script/module/remote names/classes, bounded attribute metadata and supported value-object observations.
- A bounded sample of selected parts and current/global/saved/target colors.
- A separate **PAINTBUCKET DESCENDANTS** section, independently enumerated with `PaintBucket:GetDescendants()`. Each returned descendant includes its unshortened FullName, ClassName, Name, Parent FullName, RemoteEvent/RemoteFunction flags, readable Script/LocalScript Enabled, safe ValueBase type/value, and all attribute names/types with redacted sensitive values. Entries sort by full path; duplicate paths use formatted metadata as a stable tie-break. The footer reports listed/expected counts, unreadable fields and whether the freshly resolved ServerControls actually appeared.

The metadata report does not execute modules, read/decompile script source, invoke remotes, change game properties/attributes, generate fake clicks, equip tools automatically, or hook input/network/moderation. Its own UI capability marker is local UI state only. It never interprets a matching attribute or a token-looking name as authorization.

Snapshots are requested explicitly, never scanned each frame. The existing **summary only** keeps its defaults of 96 tool hierarchy nodes, 8 levels, 12 attributes per object, 24 selected targets and 24,000 bytes. The separate descendant inventory bypasses those caps and retains every object returned by the native enumeration. Missing equipment, enumeration failures and unreadable fields are explicitly reported rather than presented as a successful empty inventory. Collection/formatting storage scales with the actual tool inventory; sorting costs O(N log N). The UI retains only the newest report string and numeric page offsets, with at most 4,000 bytes / 40 newlines per page and complete UTF-8 characters. Paging does not rescan or accumulate history, object references or listeners. `GetDiagnosticReport()` returns the full unpaginated string. String values and credential-like named values are omitted/redacted, so the report indicates presence/type rather than exposing tokens or claiming their semantics. This means a string-valued mode is not disclosed by this generic report; its actual meaning and normal selection logic still require the legitimate source.

The zero-request guarantee concerns **AutoPainter**. The diagnostic loader downloads public source via HTTP, but performs no game RemoteEvent/RemoteFunction test/probe. Independently running normal tool code is not intercepted; its manual clicks may still cause its own requests.

## Inventory correction

The supplied live excerpt resolves `Workspace.Seporial.PaintBucket.Remotes.ServerControls` but shows only Handle in the equipped hierarchy. The exact reason that earlier output stopped cannot be established from the excerpt. This revision independently enumerates all equipped PaintBucket descendants instead of relying on that capped summary traversal. `ReportFormat=2`, explicit counts and `FreshRemoteInInventory` make missing native-enumeration results visible. This metadata action reads/decompiles/executes no script source and modifies no tool property/attribute or protocol field. Inspect changes only AutoPainter's report display; the report function itself performs reads only.

## Optional locked LocalScript source inspection

**PaintBucket LocalScript source → Inspect source** calls `GetLocalScriptReport()` only on explicit request. The API refuses unlocked diagnostics or closed instances without changing painting state. It enumerates current LocalPlayer Character/Backpack children named PaintBucket of class Tool, then includes only their LocalScript descendants. ModuleScripts, server Scripts, other tools and other players are excluded. Script identities are deduplicated and full paths are sorted. Ownership/ancestry is rechecked before each decompiler call; stale candidates after respawn/removal are skipped. Moving the same owned tool between Character and Backpack remains within scope.

The only source-reading capability used is an existing global `decompile` function. If absent or not a function, the report lists candidates and explicitly reports unavailable; it does not guess alternate APIs. AutoPainter does not access `.Source`, bytecode, closures, live locals or script functions, require modules, execute returned text, touch ClientControls handlers, or add any game RemoteEvent/RemoteFunction invocation. The local report collector makes no property/attribute writes. Displaying its result changes only AutoPainter's own UI.

`PAINTBUCKET LOCALSCRIPT SOURCE` includes each candidate's full path and complete returned UTF-8 text between source markers. Source text is preserved, including literals; the metadata report's credential redaction is unchanged. Nothing is uploaded or copied to the clipboard. Exceptions, invalid/empty/non-UTF-8 return values and scope changes have explicit status lines. Nonempty text is labeled **unverified decompiler output**, because a decompiler may return a partial listing or error comment as text. Original variable names, comments, control flow and correctness cannot be guaranteed by AutoPainter. The environment provider is responsible for the implementation of its optional decompiler; detecting a function does not certify its internals or prove that it is read-only.

A case-insensitive textual index marks 1-based lines containing ServerControls, ClientControls, InvokeServer, FireServer, PaintPart, Peace, color terms, Equipped/Activated, tool/state/mode terms, client callbacks/return statements and timing/session terms. The complete surrounding source remains available to inspect preceding calls, callback responses and multiline argument construction. Matches include comments and unused code; this is not a call graph, runtime trace, proof of a handshake or inferred return contract. No normal protocol has been reconstructed from the actual source yet.

Calls run serially under protected execution with one active inspection maximum and no spawned workers/retries/waiting queue. Reentrant API calls return busy; repeated UI clicks start no extra work. Failures release the busy flag. A yielded external decompiler cannot be canceled safely; if it never returns, the single inspection stays busy rather than launching replacements. Closing AutoPainter prevents further candidates and stale display writes when a pending call returns. The only retained report is the latest text and its page offsets, using the same lossless Prev / Next pagination as the inventory. Existing Inspect continues to produce the complete descendant inventory without decompiling.

The API choice avoids relying on Roblox's protected [Script.Source property](https://create.roblox.com/docs/reference/engine/classes/Script/Source). Protected calls can yield in [Luau](https://luau.org/library/), which is why scope/shutdown checks run again between candidates and why a busy guard remains necessary.

## Exact evidence still needed

1. The **current normal PaintBucket LocalScript**, including initialization, Equipped/Unequipped/Activated handlers, its remote wrappers and any OnClientEvent/OnClientInvoke handlers.
2. Every **ModuleScript required by that client flow**, plus the normal color/mode picker code or an established documented setter. A hierarchy listing alone cannot reveal closure-local state or side effects.
3. The diagnostic snapshot while unequipped and equipped, after selecting/committing a target. It is metadata evidence, not a replacement for the scripts above.
4. Whether a **normal manual paint** succeeds in the same game context without AutoPainter, and the exact disconnect message for the AutoPainter request. Do not share credentials or token contents.
5. For definitive server checks: a read-only copy of the relevant server `OnServerInvoke` handler/validation code, or the game's documented protocol. If only client code is available, server-only permission checks remain unverified.

These sources can be supplied as ordinary files by someone authorized to share them; this does not require installing server scripts or giving friends game-project access. Runtime diagnostics remain client-only. No live request is needed to collect the read-only snapshot. No further AutoPainter live request is proposed until the normal contract is understood. Completion of a protocol fix requires a real, legitimate single request succeeding without a moderation disconnect; no such success has been observed here.

## Validation and API references

The official Luau compiler checks the runtime/loaders/tests. The full deterministic suite has **227 passing tests**: all 187 prior regressions plus 40 source-inspection checks under immediate/deferred signals. The older painting tests explicitly opt out of the new diagnostic default in the mock; new tests load the actual default and locked loader. They cover the reported UI sequence with zero game remote attempts, every mode/hotkey, commit/clear, cache replacement, missing/wrong-class objects, state reporting, redaction, bounded summary output, complete uncapped descendant output, deterministic sorting, all attribute metadata, safe value types, Handle-only summary regression, explicit read failures, exact UTF-8 pagination, no snapshot property writes/task creation/listener growth, queued work, real outstanding-call accounting, pre-invocation suppression, duplicate loaders and refusal of older UIs.

Source-inspection regressions use injected mock decompilers to verify both Character/Backpack scope, complete returned text, unavailable/error returns, text indexing, no Source reads or target execution, zero property writes/remote calls/workers/listeners, lock refusal, yielded-call exclusion, stale-candidate skipping, shutdown and full UI page reconstruction. No actual game LocalScript was decompiled from this workspace.

The mock's historical remote accepts the inherited call shape by construction. It therefore **cannot validate the real game's protocol**, contribution acceptance, or moderation behavior. Passing these tests proves the diagnostic guard and client invariants in the modeled environment, not a live fix.

The report uses documented read APIs: [Tool properties](https://create.roblox.com/docs/reference/engine/classes/Tool), [Instance hierarchy/attributes](https://create.roblox.com/docs/reference/engine/classes/Instance), [Humanoid state](https://create.roblox.com/docs/reference/engine/classes/Humanoid#GetState), and [read-only TextBox display](https://create.roblox.com/docs/reference/engine/classes/TextBox#TextEditable). The [RemoteFunction API](https://create.roblox.com/docs/reference/engine/classes/RemoteFunction#InvokeServer) describes invocation mechanics, not this game's custom PaintPart contract.
