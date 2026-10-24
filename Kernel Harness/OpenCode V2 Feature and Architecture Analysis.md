# OpenCode V2: feature and architecture analysis for Kernel

**Purpose:** Give Milestone 0 a behavior inventory and a Swift architecture starting point.

**Reference snapshot:** OpenCode `dev` at `20a6cc72917586eb5314be075f96dbb21d16c480` (2026-10-24). OpenCode changes quickly; confirm this baseline before turning the inventory into acceptance criteria.

## Executive summary

OpenCode is not just a model loop or a terminal UI. Its core product is a project/location-scoped agent runtime with durable sessions, model/provider routing, tools and permission gates, configuration and extension discovery, an event/API surface, and multiple clients. The TUI, web UI, desktop app, CLI, and embedded SDK are different ways to drive or host that runtime.

For Kernel, the most important architectural lesson is to define the harness as a UI-independent core with durable session semantics. KernelHarnessKit owns the logic and business abstractions; the closed-source macOS app owns composition, presentation, and the complete user experience. The app consumes the package directly. A small CLI executable is an optional development/test surface, not a second product UI. OpenCode’s HTTP server, generated client, web UI, and desktop UI implementation are not porting targets.

Foundation Models should be Kernel’s primary model/session/tool interface. This does not mean limiting Kernel to Apple's on-device model: any conforming provider can be used through `LanguageModelSession`, including Anthropic’s `ClaudeForFoundationModels`, and OpenAI-compatible providers are available through Apple’s `FoundationModelsUtilities`. Kernel can also build or adopt other conformers. Kernel still owns its coding-agent business logic—durable sessions, policies, tools, workspace access, project context, orchestration and product-level model selection. Provider-specific features that Apple's abstractions cannot express need an explicit extension path rather than being silently discarded.

“Feature parity” needs an explicit boundary. Matching OpenCode’s local coding-agent behavior is a meaningful first goal. Matching every platform surface, 149 documented HTTP operations, provider login flow, browser automation, remote pairing, Console subscription, and hosted/team feature is a much larger product program. Do not use “parity” as a single unqualified acceptance criterion.

## 1. OpenCode product and runtime architecture

At a high level, the architecture is:

```text
TUI / CLI / Web UI / Desktop / external API clients
                      │
          generated client + shared protocol
                      │ HTTP / events
               OpenCode server
                      │
      Core runtime (scoped by project/location)
       ├─ session lifecycle, runner, event log
       ├─ model/provider resolution and credentials
       ├─ tools, permissions, agents, plugins, MCP
       ├─ filesystem, shell/PTY, Git, LSP, formatters
       └─ SQLite persistence, snapshots, recovery

Embedded SDK ────────────────┘ (hosts the same server/API in-process)
```

The V2 repository is a TypeScript monorepo. The useful architectural seams visible in the source tree are:

| OpenCode area | Responsibility | Kernel implication |
|---|---|---|
| `packages/core` | Sessions, execution, models, tools, permissions, project/location services, filesystem/process integrations, database | Main behavior to study and port. Keep public domain contracts independent from any UI. |
| `packages/schema` | Shared serializable domain/API schemas | Study the domain/event contracts; define the Swift Core's own versioned Codable types. Do not preserve HTTP API schemas just for parity. |
| `packages/protocol` | HTTP API definitions, grouped operations, client, event types | Not needed for the planned direct package-to-app integration. Reuse the idea of explicit contracts, not the generated HTTP client. |
| `packages/server` | HTTP routes, auth/pairing, event feed, request middleware | Out of scope for the planned Kernel Core port. The app calls the package directly. |
| `packages/ai` | Provider protocol implementations and model transport | Port only the provider behavior Kernel needs. Prefer Foundation Models conformers for the shared path; account for provider-only features explicitly. |
| `packages/plugin` | Extension API, registrations, transforms and hooks | Extension points are a separate compatibility surface with security/lifecycle costs. |
| `packages/sdk` | In-process host using the same API without a network listener | Kernel's direct Swift package API is the embedding surface; no server-hosting SDK layer is required. |
| `packages/cli`, `packages/tui` | CLI commands and terminal client | A minimal CLI executable may support development and tests. TUI parity is out of scope. |
| `packages/app`, `packages/desktop`, `packages/session-ui` | Web/desktop app and reusable conversation UI | The Kernel app owns its UI and composition. These presentation implementations are not porting targets. |

The runtime’s project/location boundary is important: configuration, agents, providers, tools, and plugins are resolved for a working directory, while persistent session state and background execution are coordinated by the runtime. The session runner is not merely a stateless request/response function. It accepts durable input, serializes work per session, streams events, can be interrupted, and can recover work that was in flight at process shutdown.

The source includes a session coordinator and a durable inbox with `steer` and `queue` delivery behavior. It records session messages/events in SQLite-backed storage and projects those events into queryable session state. This is richer than a thread/message repository alone: admission, delivery order, interruption, execution claims, recovery, event replay, and read models all affect observable behavior.

## 2. OpenCode feature inventory

This is a product-level inventory, not a promise that every item belongs in Kernel Milestone 0.

### Agent execution and sessions

- Streaming model responses, reasoning/text/tool-call parts, multiple tool calls, retries, usage/cost details, and provider-specific request behavior.
- Persistent sessions with message history, search/listing, rename/archive/delete, fork/child sessions, session-level agent/model selection, and import/export.
- Prompt admission with queued or steering input, interrupt/cancel, wait, forms/questions, background work, and recovery of interrupted execution.
- Context assembly from system prompts, project instructions, attachments, skills, tools, references, and session history.
- Automatic/manual context compaction, with local summaries and selected provider-native compaction support.
- Undo/revert of conversation and assistant-attributed file changes through Git-backed snapshots (not a general rollback of shell side effects).
- Session statistics, token/cost accounting, tool usage, and model usage summaries.

### Agents and orchestration

- Built-in primary and subagent roles, custom agents, per-agent model/variant selection, step limits, visibility and ordered permissions.
- Subagent sessions with isolated conversation context, background execution, parent/child relationship, and result delivery.
- Plan/build/review/explore workflows, custom slash commands, prompt templates, command-specific model/agent selection, and command-triggered subagents.
- Todo planning, user questions/forms, and provider/model-generated title, summary, and compaction maintenance work.

### Tools and coding environment

- File read/write/edit/patch; glob and grep; shell execution; web search/fetch; todo, question, skill and subagent tools; MCP tools/resources; and desktop browser tools.
- Tool schemas, output limits, streamed progress, cancellation, result/error reporting, and tool lifecycle hooks.
- Ordered permission decisions (`allow`, `ask`, `deny`) matching actions against resources such as paths, commands, URLs, agents, skills, and MCP tools; pending approval UI and saved approvals.
- External-directory checks and shell-command scanning before shell execution. The docs explicitly warn that shell commands have host-user authority and scanner inference is best effort.
- Workspace/project discovery, file watching, Git status/diffs/branches, worktree creation, formatters, LSP integrations, snapshots, and shell/PTY sessions.
- Attachments and supported media handling, including image preparation for model context.

### Models, providers, and integrations

- Model catalog and capabilities (tool support, input/output modalities, context/output limits, pricing, reasoning settings, variants, aliases).
- Multiple provider protocols, compatible endpoints, local model discovery (including Ollama, LM Studio and vLLM), provider-specific options, retries, streaming/transport policies, credentials and OAuth/device/CLI sign-in.
- Integration authentication and credential management; provider and model availability is location/project aware.
- MCP local stdio and remote Streamable HTTP, OAuth, tool/prompt/resource discovery, server instructions, connection state, and elicitation/forms.
- Configurable web-search providers and remote/local references.

### Configuration and extensibility

- JSON/JSONC configuration merged across system, global, project, and nested project locations, with environment/file substitutions and live reload.
- File-based agents, commands, skills and project instructions (`AGENTS.md`); configurable models/providers, permissions, MCP, formatters, LSP, snapshots, compaction, worktrees, watcher behavior, and plugins.
- Plugins can add/transform agents, models, tools, MCP servers, references, integrations, VCS/worktree/search providers; register hooks and RPC; and store plugin-scoped data. Plugin registrations have load/unload lifecycles.
- Managed policy can impose restrictions that project settings cannot override.

### Interfaces and distribution

- Interactive TUI, minimal interactive mode, non-interactive `run`, service management, API command, auth/model/MCP/plugin/session/debug commands, and ACP editor protocol.
- HTTP API and event stream; generated client; embedded SDK hosting the same API in-process.
- Web UI and desktop app; server pairing/password and optional remote access.
- Update/install/distribution flows, plus OpenCode Console integrations and paid model services. These hosted/business product areas are not the same as the local open-source harness core.

The V2 HTTP API reference currently lists 149 operations. Many are explicitly experimental, so route count is not a sensible Milestone 0 target. It is evidence that API compatibility is its own scope.

## 3. Suggested parity boundaries

Use three labels in the eventual matrix to make exclusions explicit:

1. **Core behavior parity:** session loop, data model, tools, permissions, config, persistence, provider calls, events, and recovery.
2. **Client parity:** CLI, TUI, native Mac UI, HTTP/API, web and desktop integration. For Kernel, the app is a separate consumer; only a small test CLI is currently proposed. No OpenCode UI or HTTP surface is planned.
3. **Service/product parity:** broad provider OAuth/catalog coverage, remote pairing, ACP, hosted Console/billing, management policies, and distribution/update infrastructure.

Agreed first comparison target: **local single-user coding-agent Core behavior**. The first vertical slice is a mock model plus an OpenAI Chat Completions provider, driving streamed text → file tool → follow-up model turn, with persistence and event delivery. Tool execution goes through Kernel's permission policy; the initial CLI/test profile grants full access to its available tools, while tests can exercise ask/deny policies explicitly. Durable sessions, model switching, file and shell tools, cancellation, context management, Git-aware undo, and broader Core parity follow in priority order. HTTP/API compatibility, web UI, and TUI are not part of the target.

## 4. KernelHarnessKit baseline in this checkout

The current package already has useful harness primitives:

- Agent loop and event streaming (`Engine`, `Streaming`), with a Foundation Models `LanguageModel` dependency in `QueryContext`.
- Type-erased tool registry, tool schemas, built-in workspace/planning/coordination/Git/shell tools.
- Permission checker, workspace provider, todos, subagent and batch execution, human-input hook.
- HTTP and SSE MCP clients plus a tool bridge.
- Thread/message/todo/run/usage persistence protocols and model types.
- Deterministic phase-based workflow engine, which is a Kernel-specific feature rather than an OpenCode parity requirement.

`swift package describe` confirms this checkout currently publishes one library target, `KernelHarnessKit`, with one test target. The README and HLD describe a broader direction than this OpenCode port: a Foundation Models-first framework for application workflows, including deterministic harness phases and repository interfaces. It does not yet define the full OpenCode-style durable session runtime/API architecture.

The largest architectural gaps to resolve before porting behavior are:

- **Provider model and capabilities:** Core currently takes Apple `LanguageModel` directly. This aligns with the intended Foundation Models-first design. Make provider/model selection and capabilities explicit, use `LanguageModelSession` for the common interaction path, and define how adapters expose provider-only features outside that protocol.
- **Session contract:** A `Thread` abstraction and repositories are not yet equivalent to durable sessions, typed message parts, queued/steered input, event history, fork/child sessions, execution claims, resumability, compaction, or revert.
- **Durability model:** Core needs persistence abstractions that support different platforms. The Mac app will use SwiftData; tests and a CLI can supply their own adapter. The first milestone uses persisted records as authoritative state and live events as output, without a durable event journal. Partial assistant output is checkpointed so interrupted turns can be recovered.
- **Permission model:** The current checker evaluates a tool name/read-only/path/command and returns a decision. OpenCode’s configurable ordered rules, resource matching, approvals that can be saved, and per-agent/session scopes are a wider policy language.
- **Runtime/tool breadth:** Current MCP clients do not by themselves provide the full local stdio + remote OAuth MCP lifecycle, catalog discovery, prompt/resource APIs, and connection management. Also missing from the packaged Core direction are full config discovery/reload, skills/commands, snapshots, context compaction, formatters/LSP, and a client-facing API/service.
- **Product boundary:** Preserve the existing low-level harness abstractions, including deterministic phases, for future app features such as review harnesses. Align their APIs with the new common domain/session/tool abstractions as needed. Cross-platform support should use abstractions and platform-specific implementations rather than forcing the Mac app to avoid SwiftData.

## 5. Recommended Swift architecture direction

```text
Kernel macOS app (closed source; composition, SwiftUI, app state, presentation)
             │ direct Swift package API
             ▼
Kernel Core (open source; logic, business abstractions, durable state)
 ├─ Domain: Project/Location, Session, Message/Part, Agent, Event, ModelRef
 ├─ Engine: session coordinator, durable input queue, model/tool step runner
 ├─ Policy: ordered permissions, approval requests and saved decisions
 ├─ Capabilities: tools, workspace, shell, Git, MCP, subagents, plugins/hooks
 ├─ Context: prompt assembly, instructions, skills, attachments, compaction
 ├─ Model integration: FoundationModels sessions, model selection/capabilities,
 │                    credentials and provider-specific extension points
  └─ Persistence contracts: session/event storage abstractions, migrations,
                            recovery; app supplies SwiftData adapter
             ▲
 Model conformers/adapters: SystemLanguageModel, ClaudeForFoundationModels,
                            FoundationModelsUtilities chat completions,
                            future custom providers

Optional test CLI executable (exercises Core; not the Kernel UI)
```

Key design recommendations:

- Use Swift concurrency (`actor`, `AsyncSequence`/`AsyncThrowingStream`, task cancellation) for per-session serialization and streaming, but represent execution/admission state explicitly. Actors alone do not supply durable ordering or crash recovery.
- Define Codable, versioned messages/events and stable IDs early. Store events/messages so the UI can reconstruct state, reconnect to streams, and render tool progress without relying on transient callbacks.
- Put every external side effect behind a capability interface. Centralize permission evaluation before a tool/process/filesystem operation; do not rely on model instructions for safety.
- Use Foundation Models' `LanguageModel`, `LanguageModelExecutor`, `LanguageModelSession`, transcript, tool, and streaming contracts as the primary model boundary. Extend Kernel's model interface for provider-specific functionality that the Foundation Models surface cannot represent. Do not assume every model/provider supports every Foundation Models capability.
- Keep persistence behind Core-owned abstractions and keep storage details out of public domain types. The Mac app will provide a SwiftData implementation; tests and a CLI can use separate adapters. Core logic must not depend on SwiftData.
- Treat `Location`/project configuration as a runtime boundary. Define precedence, path normalization, file watching, and hot reload as explicit behavior.
- Keep app composition, view models, UX decisions, and app-only Apple integrations outside the Core target. Foundation Models is a first-class Core integration, while individual providers can be independent package dependencies/conformers. Retain the option for direct provider integrations when their capabilities exceed the shared Foundation Models interface.
- Reconcile Foundation Models session/transcript lifecycle with Kernel-owned persistence, restart recovery, compaction, and model switching. Do not assume an in-memory `LanguageModelSession` alone provides the durable session semantics Kernel needs.
- Do not promise a source-compatible OpenCode plugin API as a side effect of feature parity. Specify a Swift-native extension API and sandbox/trust model separately.

## 6. Planning recommendations for the GUI-ready Core milestone

The project decisions are now captured in [Milestone 0: GUI-Ready Core Foundation](Milestone%200%20-%20GUI-Ready%20Core.md), which is the actionable task plan. The recommendations below explain the design questions and validation work behind that plan; they are not a separate milestone or a request to reopen the agreed product boundaries.

Milestone 0 should reduce architectural uncertainty, not attempt to port all of OpenCode. Suggested deliverables:

1. **Approved parity matrix:** Every feature above marked `M0`, `later`, `not planned`, with acceptance-level behavior and explicit product boundaries (Core, Kernel app, optional test CLI, and hosted functions). HTTP/API and alternate UI clients are out of scope.
2. **Core domain/API RFC:** Session and child-session lifecycle; message/part schema; event names and versioning; prompt admission (`queue`/`steer`); tool call lifecycle; permission requests/replies; cancellation; persistence and migration strategy. The vertical slice uses the CLI/test full-access policy; separate fixtures verify ask/deny behavior.
3. **Model integration RFC:** Foundation Models session/transcript and tool contract, model capability metadata, credential boundary, and the Kernel model-interface extension for provider-specific features. First provider targets are a mock model and `FoundationModelsUtilities`' OpenAI Chat Completions provider. Anthropic and other conformers remain supported future providers.
4. **Security/threat model:** Shell/process authority, filesystem boundaries, symlink/path handling, external directories, approval persistence, secret storage, MCP trust, plugin trust, and Git snapshot limitations.
5. **Module/dependency map:** SwiftPM product/target boundaries, macOS deployment target, allowed dependencies, provider adapter boundaries, and platform abstractions for storage and other OS-specific services.
6. **Reference behavior fixtures:** Small, provider-independent fixtures for normal text response, parallel/sequential tool calls, permission ask/deny, cancellation during a tool, queued vs steering prompts, restart recovery, compaction boundary, and file undo. These form the conformance suite for later ports.
7. **One disposable vertical-slice spike (recommended):** A mock `LanguageModel` and one real provider conformer drive a persisted session through streamed text → file tool under the CLI/test full-access policy → follow-up model turn. Verify restart/replay and event delivery. A small CLI may exercise the flow. Keep it exploratory until the RFCs are approved.

### Planning exit criteria

- “OpenCode parity” is scoped to Core behavior and has a testable feature order, not just a checklist.
- Core can be consumed directly by the Mac app; an optional CLI can exercise it without introducing a server/API requirement.
- Provider, session persistence, event evolution, and permission contracts have decisions and test fixtures.
- The team knows which current `KernelHarnessKit` abstractions can be retained, adapted, or kept as separate workflow features.
- The first implementation milestone is small enough to ship as an end-to-end vertical slice.

## 7. Decisions captured from the project owner

| Topic | Decision |
|---|---|
| Product boundary | Port mostly OpenCode Core behavior and useful domain schemas/logic. The Kernel app consumes the package directly and owns composition and UI. No OpenCode server/API, TUI, or web UI port. |
| Project/location domain | Core owns platform-neutral `Project` and `Location` models. A Project groups Locations; a session binds to one Location, which stores a standardized root URL. The app owns persistence, presentation, sandbox/bookmark access, and workspace implementation. Worktree management is deferred. |
| Location lifecycle | Within a Project, adding the same standardized root returns the existing Location. A moved root keeps its Location ID only through an explicit update; no implicit relocation or Project merge. |
| Turn admission | One active turn per session. Reject concurrent submissions with a typed busy result; queue and steer semantics are deferred. |
| First slice | Start with the proposed local single-user coding-agent slice: a mock model and a Chat Completions provider, with streamed response, a file tool under the CLI/test full-access policy, persistence, and a follow-up turn. |
| Model integration | Foundation Models is the primary interface. Extend Kernel's model interface for provider-specific capabilities rather than limiting Kernel to Apple's on-device model or the shared Foundation Models surface. |
| Model selection | Persist a session default `ModelRef` and record the actual model per run. Changing a session's default applies to future turns only. |
| Persistence | Use platform-neutral Core abstractions. The Mac app will use SwiftData; tests and CLI can provide different implementations. Persisted project/location/session/message/tool/run records are authoritative; events are live, not journaled. Interrupted assistant text is retained through bounded durable checkpoints. |
| Runtime contract | Milestone 0 Task 0.2 defines Project/Location/Session/Message/Run/ToolCall/PermissionRequest/ModelRef, a typed correlated event envelope, and the `SessionCoordinating` surface. Task 0.3 now defines and implements the atomic store baseline; Task 0.4 details provider adapters. |
| Persistence operations | Use one coordinator-facing `SessionStore` with atomic domain operations; existing per-entity repositories may remain beneath adapters but cannot independently guarantee admission/recovery invariants. Checkpoint partial assistant text every 1 s or 4 KiB of new UTF-8 text, whichever comes first, plus lifecycle flushes. The package has actor-isolated in-memory and file-backed test adapters; SwiftData remains app-owned. |
| Configuration | Tests and CLI can use OpenCode-like config files, but Kernel does not promise OpenCode app/config compatibility. The goal is matching under-the-hood logic. |
| Initial permissions | Tests and CLI start with full permissions for the tools available to the agent. Preserve permission abstractions so the app can define its own interaction/policy. |
| Existing harness features | Retain existing abstractions, including deterministic phase workflows, for future features such as review hard harnesses. Update their APIs as needed to align with the new shared abstractions. |
| API stability | Optimize for implementation speed. The app and library will evolve together; no large compatibility effort is required at this stage. |

### Remaining design work (not product-boundary decisions)

- Implement the Task 0.3 `SessionStore`, transaction guarantees, live-event ordering, and interruption behavior. Persisted records are authoritative; SwiftData is the Mac implementation choice, not a decision that Core uses SwiftData models.
- Implement the Kernel model-interface extension from the Task 0.2 contract, including capability metadata and provider-specific configuration. Credentials remain injected and secret-free from persisted records.
- Select the CLI/test persistence adapter and the exact OpenCode-like config subset needed for development.
- Keep the test/CLI full-access profile explicit and separate from app policy; it must not become an accidental production security policy.
- Sequence the remaining Core parity features (MCP, subagents, compaction, undo, project discovery, skills/commands, worktrees, etc.) after the first vertical slice.

## 8. References

- [OpenCode V2 documentation index](https://opencode.ai/v2/llms.txt)
- [OpenCode introduction](https://opencode.ai/v2/docs/)
- [Agents](https://opencode.ai/v2/docs/agents/), [Tools](https://opencode.ai/v2/docs/tools/), [Permissions](https://opencode.ai/v2/docs/permissions/)
- [Providers](https://opencode.ai/v2/docs/providers/), [Models](https://opencode.ai/v2/docs/models/), [MCP](https://opencode.ai/v2/docs/mcp-servers/)
- [Configuration](https://opencode.ai/v2/docs/config/), [Commands](https://opencode.ai/v2/docs/commands/), [Skills](https://opencode.ai/v2/docs/skills/), [Instructions](https://opencode.ai/v2/docs/instructions/)
- [Snapshots](https://opencode.ai/v2/docs/snapshots/), [Compaction](https://opencode.ai/v2/docs/compaction/), [CLI](https://opencode.ai/v2/docs/cli/commands/), [Web/service](https://opencode.ai/v2/docs/cli/web/)
- [HTTP API reference](https://opencode.ai/v2/docs/api/), [SDK](https://opencode.ai/v2/docs/build/sdk/), [Plugins](https://opencode.ai/v2/docs/build/plugins/)
- [OpenCode source at the analyzed snapshot](https://github.com/anomalyco/opencode/tree/20a6cc72917586eb5314be075f96dbb21d16c480/packages)
- [Apple Foundation Models Utilities](https://github.com/apple/foundation-models-utilities) and [its vendored agent skills](../.opencode/skills/README.md)
- [Anthropic Claude for Foundation Models documentation](https://platform.claude.com/docs/en/cli-sdks-libraries/libraries/apple-foundation-models)
- Local baseline: [`README.md`](../README.md), [`Package.swift`](../Package.swift), [`KernelHarnessKit-HLD.md`](KernelHarnessKit-HLD.md), the [GUI-ready milestone plan](Milestone%200%20-%20GUI-Ready%20Core.md), and the package sources under `../Sources/KernelHarnessKit/`.

## Licensing and clean implementation note

OpenCode’s repository declares MIT, but a port should still retain required notices if any code is reused and should verify the license of every imported asset/dependency. If Kernel is implemented independently, use this document as a behavioral/architecture study; avoid copying OpenCode branding, prose, prompts, or implementation wholesale. The boundary between the open-source Core and closed-source Mac app should also be stated in the repository’s license and contribution policy.

The Apple utilities repository is Apache-2.0. This checkout vendors only its two agent `SKILL.md` guides under `.opencode/skills/`; it does not vendor the Swift package implementation. OpenCode loads these as **development-time instructions for coding agents**. They are distinct from skills Kernel may later discover and activate in a user's model session. The upstream package itself offers a `ChatCompletionsLanguageModel`, runtime `Skills`, and transcript-history modifiers. Milestone 0 should evaluate whether to depend on those utilities (with their license and traits) or implement selected functionality in Kernel; copying the skills does not make those runtime APIs available.
