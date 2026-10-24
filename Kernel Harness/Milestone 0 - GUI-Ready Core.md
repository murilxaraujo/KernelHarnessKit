# Milestone 0: GUI-Ready Core Foundation

**Status:** Planned
**Purpose:** Deliver the smallest reliable KernelHarnessKit surface that the closed-source Kernel macOS app can compose into a native coding-agent UI.
**Related:** [OpenCode V2 feature and architecture analysis](OpenCode%20V2%20Feature%20and%20Architecture%20Analysis.md), [current high-level design](KernelHarnessKit-HLD.md)

## Milestone outcome

The Kernel app can consume KernelHarnessKit directly to create and reopen a project-scoped conversation, submit a prompt, observe typed streaming events, allow the runtime to execute tools under an injected permission policy, and see the resulting conversation after a restart. The same Core API works with a deterministic mock model and an OpenAI-compatible Chat Completions model. Core does not depend on SwiftData, a server, or a UI framework.

This milestone makes the **package ready to be composed by the GUI**. It does not build the GUI, implement SwiftData in this repository, or attempt full OpenCode feature parity.

## Locked scope and decisions

- KernelHarnessKit remains an open-source, low-level harness library. The Kernel app owns app composition, UI, app state, and the SwiftData adapter.
- Core owns platform-neutral `Project` and `Location` domain models. A Project groups Locations; each Location stores a standardized root URL for a concrete working directory, and a session binds to one Location. The app owns persistence, presentation, and sandbox/bookmark access; filesystem operations remain an injected workspace capability. Worktree management is deferred.
- Foundation Models is the primary model/session interface. Kernel adds an extension point for provider identity, capabilities, configuration, and provider-specific options.
- Each Session has a persisted default `ModelRef`; each Run records the model actually used. Changing the session default affects future turns and does not rewrite prior run history.
- First provider targets: a deterministic mock and an OpenAI Chat Completions provider, preferably using Apple's `FoundationModelsUtilities` conformer after a compatibility spike.
- The first end-to-end flow is streamed response → file tool → follow-up model turn, with persistence and event delivery.
- Tool execution always passes through Core permission policy. The CLI/test profile may allow every registered tool. Policy remains injectable so the app can define its own decisions and approval UI.
- Persistence is expressed through platform-neutral Core protocols. The app supplies SwiftData; tests use in-memory storage for fast cases and a file-backed adapter for restart/recovery tests.
- Persisted Project/Location/Session/Message/Tool/Run records are authoritative in this milestone. Events are a live stream over those state changes, not a durable event journal; after restart, the app reloads current state from records rather than replaying old events.
- A session has at most one active turn in the first version. Reject concurrent submissions with a typed busy result; queue and steer semantics are deferred.
- Interrupted assistant text is retained as an incomplete message. Stream deltas live, checkpoint partial text at a bounded cadence, and flush it on graceful cancellation; a hard process crash may lose only text since the last durable checkpoint.
- OpenCode-like configuration may be used by local tests or a development CLI. Kernel does not promise OpenCode configuration or application compatibility.
- Existing capabilities—including deterministic phase harnesses, MCP, workspace, permissions, and coordination—remain in the package. Refactor shared APIs when useful; do not replace the deterministic workflow engine as part of this milestone.
- No HTTP server/API, TUI, web UI, full CLI product, provider catalog, or source-compatibility commitment is included.

## GUI-facing contract

At milestone completion, the package must expose a small, documented composition surface. Names and exact types may evolve during implementation; the behavior is the contract.

1. **Project/location operations:** represent projects and their locations as Core domain values, with stable IDs; a Project groups one or more Locations and a session binds to one Location. A Location stores a standardized root URL, while the app resolves sandbox/bookmark access and injects the workspace implementation. A GUI may initially expose one Location per Project. Core does not assume a particular project browser or filesystem implementation.
2. **Session operations:** create, fetch/reopen, list, and update/archive a session within a project/location identity.
3. **Turn operations:** submit a user input, obtain a cancellable run handle, and receive a typed asynchronous event stream. Permit one active turn per session; reject a concurrent submission with a typed busy result. The consumer must not need to construct or mutate a Foundation Models `LanguageModelSession` directly.
4. **Renderable state:** load ordered messages/content parts and current run/session status; event payloads carry stable session, message, turn, and tool-call IDs where applicable.
5. **Permission interaction:** receive an approval-required decision as a typed request, answer it through Core, and observe allow/deny/result events. A policy can also auto-allow or deny without a UI callback.
6. **Model selection:** persist a session default `ModelRef` and record the model used by each Run. Configure through a Kernel-owned model descriptor/adapter boundary, with capability metadata and a safe place for provider-specific configuration. Credentials are injected or resolved by the consumer; they are not stored in session records.
7. **Persistence injection:** provide project/location/session/message/tool/run storage through Core protocols. Lifecycle events are emitted after durable state changes and are not stored as a journal. Text deltas are live and may be ahead of the latest durable assistant checkpoint. No Core domain type imports SwiftData or assumes a particular database.
8. **Errors and cancellation:** expose terminal completion, failure, and cancellation distinctly; cancellation must not be reported as a successful turn.

These operations form the Core-to-GUI boundary. View models, SwiftUI views, navigation, user-facing permission copy, Keychain/credential UI, SwiftData models, and app-level policy remain in the Kernel app.

## Task 0.2 contract proposal

This section makes the behavioral contract concrete. Swift declarations are
illustrative API shapes, not implemented source-compatibility promises. Task
0.3 defines storage transactions; Task 0.4 defines provider adapters. Both must
conform to these domain semantics.

### Domain records and identity

- To coexist with the existing thread-oriented public types, the implementation
  names the new persisted records `SessionMessage`, `SessionRun`,
  `SessionToolCall`, and `SessionPermissionRequest`; the contract uses the
  shorter conceptual names Message, Run, ToolCall, and PermissionRequest.
- Persisted entity IDs are `UUID`s generated by Core or accepted from a
  consumer at creation. Provider tool-call IDs remain provider metadata; Core
  assigns each durable tool invocation its own `UUID` and maps the provider ID
  to it.
- `Project` contains `id`, `name`, `createdAt`, and `updatedAt`. It groups
  Locations, but does not contain filesystem access or app-specific settings.
- `Location` contains `id`, `projectID`, `rootURL`, optional display name, and
  timestamps. `rootURL` must be a standardized absolute file URL. Within one
  Project, Core normalizes the URL with `standardizedFileURL`; adding an
  already-present normalized root returns the existing
  Location. Core does not merge Projects. Relocation retains the Location ID
  only through an explicit root-URL update; updating to a root already used by
  another Location in that Project fails rather than merging records. A missing
  path is not silently remapped. The app owns sandbox/bookmark resolution and the injected
  `WorkspaceProvider`. Symlink and volume-case canonicalization are not part of
  URL standardization in this milestone.
- `Session` contains `id`, `locationID`, optional title, lifecycle status, the
  default `ModelRef`, and timestamps. Archiving prevents new turns but keeps
  history readable. A Session always resolves to exactly one Location.
- `Message` contains `id`, `sessionID`, `runID`, a monotonic session sequence,
  role, ordered content parts, lifecycle status, optional usage, and timestamps.
  Roles are `user`, `assistant`, and `tool`; a tool-role message must reference
  its `ToolCall` UUID so it cannot be confused with an arbitrary author. System
  instructions remain runtime configuration and are not transcript messages
  unless a consumer explicitly chooses to persist a consumer-owned
  representation.
- Content parts preserve order and are Codable/Sendable: text, image (media type
  and bytes or an explicitly supported durable reference), tool-call reference,
  and tool-result reference. Tool-call and tool-result parts link to the Core
  tool-call UUID; they do not rely on provider-specific string IDs for joins.
- Message status is `inProgress`, `complete`, `failed`, or `interrupted`. User messages
  are created complete. An assistant message becomes `inProgress` on its first
  durable creation/checkpoint, `complete` only when its turn's final response
  commits, `failed` when generation fails, and `interrupted` on cancellation or
  recovery when it is not complete.
  If no assistant text was produced, Core need not create an empty assistant
  message.
- A `Run` is one submitted user turn. It contains `id`, `sessionID`, user
  message ID, `ModelRef` actually used, status, start/end timestamps, and a
  typed failure when applicable. It may produce multiple assistant and tool
  messages; those messages reference the Run and are ordered by their session
  sequence. Status is
  `running`, `awaitingApproval`, or terminal `completed`, `failed`, `cancelled`,
  `interrupted`. A restart converts any nonterminal run to `interrupted`; Core
  does not resume provider generation or repeat tools implicitly.
  Transitions are `running ↔ awaitingApproval` followed by exactly one terminal
  state; no transition leaves a terminal state.
- A `ToolCall` record contains its own UUID, `runID`, assistant message ID,
  provider call ID (optional), tool name, validated JSON input, status, linked
  permission request ID (optional), result/error, and timestamps. Status is
  `pending`, `awaitingApproval`, `running`, `succeeded`, `failed`, `denied`, or
  `interrupted`. Persist intent before executing a side effect; persist result
  and terminal status afterward. On recovery, an in-flight call becomes
  `interrupted` and is never auto-replayed. Direct allow transitions
  `pending → running`; approval transitions `pending → awaitingApproval →
  running` or `denied`; execution ends in `succeeded`, `failed`, or
  `interrupted`.
- A `PermissionRequest` contains a UUID, run/tool-call IDs, tool name, the
  validated input needed for the app's prompt, reason, status (`pending`,
  `allowed`, `denied`, `cancelled`), and timestamps. Policy allow/deny decisions need no UI
  request. An approval-required decision persists the request before emitting
  it; Core executes the tool only after an explicit allow is persisted. A
  denied call produces a durable denied tool result for the model/runtime.
  Cancelling a Run marks any still-pending request `cancelled`; resolved
  requests cannot be changed.
- `ModelRef` is the stable, secret-free pair `providerID` + `modelID`, with
  optional provider-specific JSON configuration. It must not contain API keys,
  credential references that reveal secrets, or ephemeral session objects.
  Capability metadata is resolved from the configured provider at runtime;
  each Run snapshots the actual `ModelRef` so changing a Session default only
  affects future runs. Provider-specific settings that affect reproducibility
  may be copied into a non-secret run configuration snapshot.

All persisted records use stable explicit Codable representations, rather than
depending on synthesized enum case names as a permanent wire format. Additive
fields require backward-compatible defaults; incompatible schema changes use
an explicit schema version and migration. The package owns the portable domain
values, while the app owns their SwiftData representation.

### Event envelope and ordering

Session events are typed, transport-neutral, and distinct from both the current
low-level `AgentEvent` and the historical JSON `EngineEventEnvelope`. The
coordinator adapts existing agent/harness events into this public session
contract; legacy deterministic harness consumers remain unaffected.

Each event carries `protocolVersion`, unique `eventID`, monotonically increasing
`sequence` within a Run, `occurredAt`, `sessionID`, `runID`, and optional
`messageID`, `toolCallID`, and `permissionRequestID`. The payload is a Codable
sum type, not a string that the app must parse. Events are live-only; sequence
numbers order the stream but do not imply restart replay or gap recovery.

The first typed event payload set is:

| Event | Required payload | Emission rule |
|---|---|---|
| `userMessageCommitted` | Message ID | After the user message and Run are durably created |
| `runStatusChanged` | Previous/new Run status | After the status write succeeds |
| `assistantMessageStarted` | Message ID | When the assistant record is created |
| `textDelta` | Message ID, appended text | Live; may be ahead of the latest durable checkpoint |
| `toolCallStarted` | Tool-call ID, name, validated input | After durable intent and permission allow, before side effect |
| `permissionRequested` | Full `PermissionRequest` | After the pending request is durable; Run enters `awaitingApproval` |
| `permissionResolved` | Request ID, allow/deny, optional reason | After decision is durable |
| `toolCallFinished` | Tool-call ID, terminal status, result/error | After result/status is durable |
| `assistantMessageFinished` | Message ID, usage | After complete message is durable |
| `runFinished` | Typed terminal outcome: completed, failed (with `SessionFailure`), cancelled, or interrupted | After terminal Run state is durable |

The event envelope and payload are conceptually:

```swift
public struct SessionEvent: Codable, Sendable, Identifiable {
    public let id: UUID                 // eventID
    public let protocolVersion: String  // initially "1.0"
    public let sequence: Int64          // monotonically increasing per run
    public let occurredAt: Date
    public let sessionID: UUID
    public let runID: UUID
    public let messageID: UUID?
    public let toolCallID: UUID?
    public let permissionRequestID: UUID?
    public let payload: SessionEventPayload
}

public enum SessionEventPayload: Codable, Sendable {
    case userMessageCommitted(messageID: UUID)
    case runStatusChanged(from: SessionRunStatus, to: SessionRunStatus)
    case assistantMessageStarted(messageID: UUID)
    case textDelta(messageID: UUID, text: String)
    case toolCallStarted(toolCallID: UUID, name: String, input: [String: JSONValue])
    case permissionRequested(PermissionRequest)
    case permissionResolved(requestID: UUID, resolution: PermissionResolution)
    case toolCallFinished(toolCallID: UUID, outcome: SessionToolCallOutcome)
    case assistantMessageFinished(messageID: UUID, usage: UsageSnapshot?)
    case runFinished(SessionRunOutcome)
}
```

These declarations illustrate payload semantics. Production Codable must use
explicit tagged encoding and schema-version rules; it must not rely on Swift's
synthesized associated-value enum representation.

`SessionRunStatus` is the session-runtime lifecycle type and is distinct from
the existing deterministic `HarnessRunStatus`. `SessionRunOutcome` is one of
`completed`, `failed(SessionFailure)`, `cancelled`, or
`interrupted`. `SessionFailure` carries a stable error code, safe display
message, and optional retryable flag. `SessionToolCallOutcome` is one of
succeeded (durable result), failed (safe failure), denied (durable denial
result), or interrupted (with side-effect disposition).
`PermissionResolution` is allow or deny; cancellation of a pending request is a
runtime lifecycle change, not an app-authored approval decision.

Text deltas may be lost since the most recent checkpoint on hard crash. A
graceful cancellation flushes the latest partial text and emits a terminal
cancelled state. A failure has a typed, non-secret error code and safe display
message; provider diagnostics must not expose credentials or raw secrets.
Lifecycle events follow successful writes. A failed write fails the operation
and must not be reported as a successful durable transition. No terminal event
is followed by another event for that Run. Startup recovery updates persisted
state to `interrupted`; reopening a Session returns that state in its snapshot
and does not replay a `runFinished` event from the prior process. When multiple
events describe one committed transition, emit `runStatusChanged` first, then
the transition-specific event; assign sequence numbers in actual delivery
order.

### Public coordinator shape

The app composes one coordinator from Core storage contracts, a model resolver,
tool registry, a Location-scoped workspace factory, and an injected permission
policy. It never creates a Foundation `LanguageModelSession` itself.

```swift
public struct TurnHandle: Sendable {
    public let runID: UUID
    public let events: AsyncThrowingStream<SessionEvent, Error>
}

public enum TurnSubmission: Sendable {
    case accepted(TurnHandle)
    case busy(activeRunID: UUID)
}

public protocol SessionCoordinating: Sendable {
    func createProject(name: String) async throws -> Project
    func listProjects() async throws -> [Project]
    func renameProject(id: UUID, name: String) async throws
    func listLocations(projectID: UUID) async throws -> [Location]
    func addLocation(to projectID: UUID, rootURL: URL, name: String?) async throws -> Location
    func renameLocation(id: UUID, name: String?) async throws
    func updateLocationRoot(locationID: UUID, rootURL: URL) async throws -> Location
    func createSession(locationID: UUID, model: ModelRef, title: String?) async throws -> Session
    func loadSession(id: UUID) async throws -> SessionSnapshot?
    func listSessions(locationID: UUID) async throws -> [SessionSummary]
    func archiveSession(id: UUID) async throws
    func setDefaultModel(_ model: ModelRef, sessionID: UUID) async throws
    func submitTurn(sessionID: UUID, text: String) async throws -> TurnSubmission
    func resolvePermission(requestID: UUID, decision: PermissionResolution) async throws
    func cancel(runID: UUID) async throws
}
```

The concrete coordinator is composed with an injected store, model resolver,
tool registry, Location-scoped workspace factory, and permission policy. The
store's atomic operations and transaction boundaries are specified in Task 0.3;
the signatures above intentionally describe app-facing behavior, not a
premature repository layout.

`SessionSnapshot` contains the Session, ordered persisted Messages, the latest
Run (including a terminal interrupted Run), an active Run if present, and
pending PermissionRequests. `SessionSummary` is the list-screen projection and
must not require loading full message content.
`PermissionResolution` is an explicit allow/deny value; it cannot change a
request after its first successful resolution. A busy response is a normal
admission result, not a thrown execution error and not a persisted Run.
Archiving an active Session is rejected with a typed busy/conflict error rather
than silently cancelling the Run; archived Sessions remain readable.
Submission errors before admission (for example, missing/archived Session,
missing Location access, unavailable model configuration, or storage failure)
throw typed coordinator errors. Once accepted, model/tool failures arrive as
persisted Run state and terminal stream events. `cancel(runID:)` is idempotent
for terminal runs and cancellation is never reported as completion.

### Consumer call flow

```swift
let session = try await coordinator.createSession(
    locationID: location.id,
    model: selectedModel,
    title: nil
)

switch try await coordinator.submitTurn(sessionID: session.id, text: prompt) {
case .busy(let activeRunID):
    showBusyState(activeRunID)
case .accepted(let handle):
    for try await event in handle.events {
        switch event.payload {
        case .textDelta(let messageID, let delta): append(delta, to: messageID)
        case .permissionRequested(let request): presentApproval(request)
        case .runFinished(let outcome): renderTerminalOutcome(outcome)
        default: updateConversation(event)
        }
    }
}
```

The app calls `resolvePermission` from its approval action and `cancel` from its
stop action. It reloads `SessionSnapshot` after relaunch; the event stream is
not a transcript or a recovery log.

### Model adapter boundary

The runtime's common execution path uses Foundation Models' `LanguageModel`
and `LanguageModelSession` behind Core. A provider registry resolves a persisted
`ModelRef` to an adapter containing the conforming model, declared capabilities,
and optional typed provider extension. The GUI can list/select descriptors
without importing provider SDKs or holding a session object. The extension
must preserve provider-only configuration rather than silently discard it;
unsupported capabilities fail before starting the affected operation. A
credential resolver is injected at composition time, and secrets never enter
`Project`, `Location`, `Session`, `Message`, `Run`, or event payloads.

This contract keeps the existing `runAgent` and `QueryContext` useful as an
execution baseline, but the coordinator owns durable transcript projection,
permission suspension/resolution, run admission, and ID correlation. It is a
new high-level API, not a rename of `Thread` or `HarnessRun`.

## Task 0.3 persistence and recovery proposal

### Storage boundary

The coordinator depends on one platform-neutral `SessionStore` contract. It
offers domain queries plus atomic domain operations; it does not expose a
SwiftData context, SQL connection, file handle, or generic mutable database
transaction to Core. An adapter may compose internal repositories, but it must
commit each operation below as one transaction. The existing
`ThreadRepository`, `MessageRepository`, and `HarnessRunRepository` remain valid
for existing consumers; they are not sufficient by themselves for the new
coordinator because independent writes cannot provide cross-record atomicity.

The minimum atomic operations are:

| Store operation | One atomic commit must guarantee |
|---|---|
| `addLocation(projectID, normalizedRoot)` | Project exists; root is normalized; return the existing Location if the same Project already owns that root; otherwise insert exactly one Location. |
| `updateLocationRoot(locationID, normalizedRoot)` | Location exists; reject a collision with another Location in the same Project; update root and timestamp together. |
| `beginTurn(sessionID, input, runID, messageID)` | Session is active; no nonterminal Run owns it; snapshot the current `ModelRef`; insert the Run and complete user Message with the next session sequence; reserve the active-run claim. Return `.busy(activeRunID:)` without writes if occupied. |
| `checkpointAssistant(messageID, revision, accumulatedText)` | Replace durable partial text only if the revision is newer; update text, revision, and timestamp together, so a delayed write cannot overwrite newer text. |
| `persistAssistantToolCalls(message, calls)` | Insert the assistant tool-call Message and all ToolCall intents/ordinals before any tool closure can run. |
| `requestPermission(request, toolCallID)` | Persist the pending request, link it to the ToolCall, and move the Run to `awaitingApproval` in one commit. |
| `resolvePermission(requestID, decision)` | Compare-and-set a pending request; persist the ToolCall's corresponding state/result. Return the Run to `running` only when no pending requests remain. Repeating the same decision is idempotent; a conflicting decision returns `alreadyResolved`. |
| `markToolCallRunning(toolCallID)` | Confirm permission is allowed, if required, and persist `running` before invoking the tool. |
| `denyToolCall(toolCallID, result)` | For an immediate policy denial, persist denied status/result and ordered tool-result projection without creating a UI PermissionRequest or invoking the tool. |
| `completeToolCall(toolCallID, outcome)` | Persist the result/error, terminal ToolCall state, and ordered transcript projection together. |
| `finishRun(runID, outcome, finalAssistantCheckpoints)` | Flush final assistant content, message statuses, Run terminal state/end time, and active-run release together. |
| Cancellation outcome of `finishRun` | Flush latest text; cancel pending PermissionRequests; mark unresolved ToolCalls interrupted; persist Run cancellation and release the active claim only after execution tasks stop or are joined. |
| `recoverRun(runID, recoveryTime)` | In one idempotent transaction, mark a nonterminal Run interrupted, its partial assistant Message interrupted, unresolved ToolCalls interrupted, and pending PermissionRequests cancelled; release the active claim. |

Read operations return Projects, Locations, Sessions, ordered Messages, Runs,
ToolCalls, pending PermissionRequests, and `SessionSnapshot`/`SessionSummary`
projections. Message order uses a monotonic per-Session sequence allocated by
the store, never timestamp ties. ToolCalls retain their provider-response
ordinal and reserve result-message sequence at intent commit; results are
projected in that ordinal order even if executions finish in a different order.
The store returns committed values or typed conflicts;
the coordinator publishes events only after successful commits.

`SessionStore` serializes competing writes against the same backing store. The
active-Run claim is a store invariant, not an in-memory coordinator flag. A
busy admission creates neither a user Message nor a Run. A failure before a
commit creates no partial logical operation. A failure after an external tool
side effect is an uncertain outcome and must not trigger automatic retry.

### Turn write and event order

1. `beginTurn` atomically commits the user input and Run before model execution;
   then Core emits `userMessageCommitted` and `runStatusChanged(running)`.
2. Create an assistant Message lazily on its first generated content. The first
   content/checkpoint is durable before `assistantMessageStarted`; later text
   deltas stream immediately.
3. Checkpoint the full accumulated assistant text after **1 second or 4 KiB of
   new UTF-8 text, whichever comes first**. Also flush before a tool side effect,
   before suspending for approval, on model completion/failure, and on graceful
   cancellation. Each checkpoint replaces the accumulated text with an
   increasing revision. Tool intent and any preceding assistant text commit
   before the tool starts.
4. For every tool call, persist validated intent first. If approval is needed,
   persist the request and `awaitingApproval` status, then emit status/request
   events. Persist the user's allow/deny before executing or returning a denied
   result. Persist `running` before side effects; persist the outcome before
   `toolCallFinished` and before the next model request.
5. On normal completion, atomically persist final assistant content/message(s),
   usage, completed Run, and release the active claim; only then emit terminal
   lifecycle events. Tool-call and tool-result ordering follows provider call
   order, not wall-clock completion order.
6. Text deltas are the only events allowed to precede the corresponding durable
   assistant checkpoint. During healthy storage operation, they may be ahead by
   at most the selected checkpoint bound. If checkpoint writes fail or stall,
   stop model execution and report persistence failure; do not claim the bound
   still holds.

For each durable transition, emit `runStatusChanged` first and its
transition-specific event next, both after the same successful commit. Events
are not written to `SessionStore` and are not replayed after restart. A failed
commit emits no success event. The stream ends after one `runFinished` event;
stream termination itself is not the source of truth for Run status.

### Cancellation and restart recovery

- Graceful cancellation is cooperative. Core asks the model and active tools to
  stop, joins their tasks, flushes the latest assistant text, cancels pending
  requests, marks unresolved ToolCalls, and commits the cancelled Run. A tool
  that ignores cancellation must not be declared stopped while its side effect
  can still run; if its outcome cannot be observed, mark it interrupted and
  uncertain.
- A process restart never resumes provider generation or repeats a tool. Before
  accepting new work, recovery applies only to Runs whose prior executor is
  known to be gone (for example, app-process-exclusive startup or an
  adapter-owned expired/fenced execution lease). Do not mark another live
  coordinator's Run interrupted merely because a second coordinator was
  constructed.
- Recovery is idempotent and transactional per Run. A ToolCall awaiting
  approval is known not to have started. A call persisted as `running` is
  conservatively marked `mayHaveExecuted`; a crash can occur after its external
  side effect but before the result commit. Keep its input and status for UI
  display, but never auto-replay it. An explicit future retry is a new operation
  and may duplicate an external side effect; generic exactly-once execution is
  not promised.
- Load the latest assistant checkpoint as an interrupted/incomplete Message.
  Text emitted after that checkpoint can be lost after a hard crash. Reopen
  shows persisted state, including the interrupted latest Run, without replaying
  events or external effects. Recovery failure blocks new turn admission for
  affected Sessions until the store can complete recovery.

### Adapter and conformance-test scope

- The in-memory adapter is actor-isolated and follows the same transaction and
  conflict semantics as the contract.
- The file-backed test adapter uses a versioned Codable snapshot and atomic file
  replacement per committed operation, via the in-memory actor's test-only
  persistence hook. Tests close and reopen it to simulate a process restart;
  this does not claim power-loss durability or production filesystem guarantees.
- SwiftData remains an app-owned adapter. The package provides reusable
  conformance tests for atomic location deduplication, busy admission without
  partial writes, stable message ordering, checkpoint monotonicity, permission
  compare-and-set, intent-before-execution, result-before-follow-up, failure
  without a success event, cancellation, idempotent recovery, and no duplicate
  tool side effect.

The store does not journal events. Its authoritative state is the latest
committed domain records; tests reconstruct after restart from those records.

## Ordered tasks

### 0.1 — Reconcile the design docs and current package baseline

- [x] Mark this milestone as the execution plan and link it from `README.md` and the OpenCode analysis.
- [x] Record the current reusable components and their gaps: `runAgent`, `QueryContext`, Foundation Model tool adapter, permissions, `Thread`/`Message` models and repositories, workspace tools, and deterministic `HarnessEngine`.
- [x] Identify stale HLD assumptions (first consumer/server, repository implementations, provider layout) and update only the sections that conflict with the agreed Kernel app boundary. Preserve the Nemesis example as a historical integration and future migration target.
- [x] Add the Kernel app as the primary consumer example and retain Nemesis as the more complex service/migration example. Compilable examples will follow the API definition in Task 0.2.
- [x] Confirm the current package/platform baseline and dependency constraints: macOS 27, iOS 27, watchOS 27; one Core library product; no app/UI or database runtime dependency.

**Done when:** A contributor can tell what exists, what will be adapted, and which document defines this milestone without contradictory product boundaries.

### 0.2 — Specify the GUI-facing domain and runtime contract

- [x] Define Core `Project` and `Location` models, stable IDs and lifecycle, and the session's stable Location reference. Define standardized URL and duplicate/move behavior. The app resolves sandbox/bookmark access. Keep filesystem operations injected through `WorkspaceProvider` and persistence consumer-supplied; do not implement worktree management in this milestone.
- [x] Define persistent Session/Message/content-part/ToolCall/Run/PermissionRequest/`ModelRef` representations, stable IDs, lifecycle states, and Codable/Sendable evolution rules. Store the session's default model and actual model per Run.
- [x] Define a transport-neutral, versionable typed event envelope and payload set with ID correlation and write/stream ordering rules.
- [x] Define first-version turn admission: one active turn per session; reject a concurrent submission with a typed busy result. Queue and steer behavior are deferred.
- [x] Define the public coordinator/facade the app calls, including session loading, turn admission, permission resolution, cancellation, and typed results. Keep `LanguageModelSession`, transcript conversion, and tool wiring behind this boundary.
- [x] Specify the Foundation Models common path, provider/model reference and capability extension, and secret-free provider configuration boundary without making the GUI depend on a provider SDK. Changing a session model default affects future turns only.

**Done when:** A small app-side view model can be sketched using only the proposed public API and typed outputs; no UI state has to be inferred from log strings or private callbacks. The API sketch in this section is reviewed and accepted before implementation begins.

**Contract review:** Accepted as the design baseline on 2026-10-24. Concrete Swift declarations remain subject to implementation review.

### 0.3 — Define persistence and interruption semantics

- [x] Define the coordinator-facing atomic `SessionStore` commands and read projections for Projects, Locations, Sessions, ordered Messages/tool lifecycle, and Run state. Persisted records—not an event journal—are authoritative.
- [x] Define atomic turn admission and same-Project normalized-root uniqueness; busy admission makes no writes, and duplicate roots return the existing Location.
- [x] Define turn write ordering, including 1-second/4-KiB assistant checkpoints, tool intent before side effects, and results before follow-up model execution.
- [x] Define event ordering and persistence boundary: deltas may be ahead of checkpoints; durable lifecycle events publish only after commit; historical events are not replayed.
- [x] Define snapshot loading and restart recovery, including preserving partial assistant text and marking interrupted work without replaying side effects.
- [x] Define safe recovery ownership, idempotent per-Run state repair, and the uncertain side-effect window for a ToolCall recorded as running.
- [x] Implement the actor-isolated in-memory store and minimal file-backed test adapter. Keep SwiftData as an app-owned adapter; legacy repositories remain supported.
- [x] Add store conformance tests and run them against the package test adapters; the Kernel app can mirror them for SwiftData.

**Done when:** Package tests restart between turns and during a simulated tool
call, reconstruct stable UI state, and verify that recovery leaves an uncertain
call interrupted instead of replaying it. Task 0.5 will prove the coordinator
does not invoke the tool executor again after recovery.

**Design review:** Atomic `SessionStore`, 1-second/4-KiB checkpoint bound, and conservative interrupted-tool recovery accepted on 2026-10-24. The public SwiftData adapter and end-to-end coordinator/tool-executor proof remain app/Task 0.5 integration work.

### 0.4 — Adapt the model boundary and prove provider behavior

- [ ] Add a Kernel model abstraction around the Foundation Models common path, including model/provider ID, declared capabilities, model configuration, and a typed provider-specific extension mechanism.
- [ ] Define credential injection/resolution boundaries. Keep API keys out of persisted session/message data and out of source-controlled config examples.
- [ ] Build a deterministic mock conformer that can script text deltas, tool calls, provider errors, and cancellation for tests.
- [ ] Spike `FoundationModelsUtilities.ChatCompletionsLanguageModel` against the selected Foundation Models and tool flow. Confirm tool calling, streaming, error propagation, and configuration behavior; document any limitations.
- [ ] Integrate the Completions provider as an optional provider target/dependency if the spike passes. Keep Core usable with the mock and other `LanguageModel` conformers without importing provider-only APIs into the domain layer.
- [ ] Add provider capability checks so unsupported features fail clearly instead of being silently ignored.

**Done when:** The same session/runtime tests pass against the mock, and an opt-in integration test can run one real streamed OpenAI-compatible turn with credentials supplied externally. Provider limitations and setup are documented.

### 0.5 — Implement the persisted, permission-aware session vertical slice

- [ ] Adapt the existing agent loop into a session coordinator that supports a user turn, not just a single transient model response.
- [ ] Preserve the complete ordered transcript, including tool-use and tool-result parts; verify that a follow-up model request receives the tool result.
- [ ] Route every tool call through the injected permission policy before side effects. Implement a full-access policy profile for tests/development and test explicit ask/deny outcomes.
- [ ] Make approval requests resumable at the Core API boundary: the run can suspend, receive an app decision, and continue or return a denied tool result.
- [ ] Emit typed streaming events tied to persisted IDs and status; ensure the app can distinguish running/awaiting-approval/completed/failed/cancelled.
- [ ] Add cancellation handling and ensure a cancelled run leaves a recoverable persisted state.

**Done when:** The end-to-end test completes `user prompt → streamed assistant/tool call → authorized file write → persisted tool result → follow-up assistant response`; the transcript and UI-facing state reload correctly afterward.

### 0.6 — Provide a GUI integration proof and package guidance

- [ ] Add a DocC article or minimal sample showing app composition: choose model, inject persistence/workspace/policy, create or reopen session, submit a turn, consume events, respond to approval, cancel, and reload.
- [ ] Add a package-level integration test that exercises the public API without reaching into implementation internals.
- [ ] Document the responsibility split: Core protocols and domain types here; SwiftData models/adapter, Keychain, view models, and UI in the app.
- [ ] If useful, add a minimal development executable/config loader only after tests can exercise the same public API. Do not block GUI readiness on a polished CLI.
- [ ] Coordinate an app-repository spike to implement the SwiftData adapter and a thin view-model consumer against the documented API. Record integration issues as Core tasks, not as a second Core persistence model.

**Done when:** A Kernel app developer can implement the SwiftData adapter and connect a basic conversation screen using the guide and public package API, with no HTTP service and no dependency on internal types.

## Acceptance checklist

- [ ] The app can create/list/reopen a Location-scoped session through the public package API.
- [ ] Core can persist a Project with one or more Locations, and each session resolves to exactly one Location; actual filesystem access is supplied by the app.
- [ ] A concurrent turn submission is rejected with a typed busy result and does not alter the active turn or transcript.
- [ ] A user turn streams typed events that include stable IDs and can be rendered without parsing strings.
- [ ] File tool execution is permission-checked; allow, ask/approve, and deny paths are covered by tests.
- [ ] The first assistant response, tool invocation/result, and follow-up response persist and reload in order.
- [ ] Cancellation and interruption produce explicit persisted states, retain partial assistant text through the latest durable checkpoint, and do not silently replay tool side effects.
- [ ] Mock and OpenAI-compatible Completions providers use the same Core orchestration contract; provider-specific options have a documented extension path.
- [ ] Core has no SwiftData, SwiftUI, HTTP server, or UI dependency.
- [ ] Existing deterministic harness abstractions still build and their tests pass after any shared API refactor.
- [ ] A package consumer guide and app-side integration spike validate the public boundary.

## Suggested test layers

1. **Unit:** Codable round trips, event ordering, permission decisions, model capability validation, session state transitions, repository transactions.
2. **Deterministic runtime:** scripted mock model + in-memory store/workspace for normal response, tool flow, ask/deny, provider failure, and cancellation.
3. **Recovery integration:** file-backed test store; restart after a completed turn and during an in-flight tool call; verify replay and no duplicate side effect.
4. **Provider integration:** opt-in OpenAI-compatible endpoint test with credentials from environment/secure local configuration; never required for the default test suite.
5. **Consumer integration:** app-side SwiftData adapter and view-model spike compile and pass against only the public package product.

## Explicitly deferred

MCP expansion, subagents, shell policy redesign, compaction/summarization, Git snapshots/undo, skills and commands, config discovery/reload, worktrees, provider catalogs/OAuth, advanced context assembly, plugin systems, and broad OpenCode parity. Keep existing versions of these abstractions working; add only what the GUI-ready vertical slice needs.

## Risks and implementation notes

- Foundation Models sessions are in-memory execution objects, not the durable session source of truth. Persist Kernel-owned state and reconstruct or continue sessions deliberately.
- Provider packages may expose different tool, usage, reasoning, and guided-generation behavior. Capability metadata and explicit unsupported cases are part of the integration, not polish.
- Approval must happen before a tool side effect. A GUI prompt is an app concern; the Core request/decision lifecycle is not.
- A store adapter must preserve ordering and atomicity required by Core. Do not claim crash-safe recovery based only on individually successful repository calls.
- The full-access test/CLI policy is a development profile only. It must not become the default app security policy.
