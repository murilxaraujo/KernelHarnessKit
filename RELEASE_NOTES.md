# KernelHarnessKit 0.3.0

KernelHarnessKit 0.3.0 adopts Apple's Foundation Models framework as its native model-execution API and expands the agent harness with built-in workspace, shell, Git, and planning tools. This release also stabilizes the tool, permission, phase, and event contracts.

## Highlights

- Run agents with Apple's `LanguageModel` and `LanguageModelSession` APIs, including `SystemLanguageModel` and compatible provider implementations.
- Register built-in file/workspace, todo, sub-agent, and user-input tools with `ToolRegistry.registerBuiltIns()`; macOS additionally gets shell and Git status/diff/log tools.
- Add `LocalFileWorkspace` for workspace access backed by the local filesystem.
- Add JSON Schema-based phase output validation and strengthen deterministic harness phase execution.
- Expand and stabilize the transport-neutral agent event contract, including typed events for permission decisions, todo updates, sub-agents, and harness progress.
- Improve MCP HTTP/SSE client behavior and tool argument/schema handling.

## Breaking changes

- Agent execution now uses Foundation Models APIs. The previous `LLMProvider`, OpenAI-compatible provider/registry, and provider-based `QueryContext` interfaces have been removed.
- The package now requires Swift tools 6.4 and macOS 27, iOS 27, or watchOS 27. Linux and tvOS are no longer declared supported platforms.
- The package manifest now exposes only the `KernelHarnessKit` library product. The previous `KernelHarnessPostgres` product and `kernel-harness-demo` executable are not included in this release.
- The agent tool protocol, permission model, phase definitions, and event payload contract have been revised and stabilized. Consumers implementing custom tools or decoding event payloads should review the updated API documentation.

## Upgrade notes

- Replace provider-based `QueryContext` construction with a Foundation Models `LanguageModel`, for example `SystemLanguageModel.default`.
- Review the [Foundation Models integration guide](https://murilxaraujo.github.io/KernelHarnessKit/documentation/kernelharnesskit/foundationmodelsintegration/) and updated tutorials before upgrading.
- Update the Swift package dependency to `from: "0.3.0"` and check deployment targets against the supported platform minimums.

## Validation

- `swift build -c release`
- `swift test --parallel`
