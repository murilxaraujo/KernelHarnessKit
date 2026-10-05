# Foundation Models integration

KernelHarnessKit uses Apple's Foundation Models APIs directly. Supply a
`LanguageModel` to `QueryContext`; the harness creates a `LanguageModelSession`
for each run and relies on it for transcript state, streaming, and native tool
execution.

```swift
import FoundationModels
import KernelHarnessKit

let tools = ToolRegistry()
tools.registerBuiltIns()

let context = QueryContext(
    model: SystemLanguageModel.default,
    toolRegistry: tools,
    permissionChecker: DefaultPermissionChecker(mode: .auto),
    workspace: InMemoryWorkspace(),
    systemPrompt: "You are a helpful assistant."
)
```

Provider packages that conform to Apple's `LanguageModel` protocol can be
passed in directly. Use `@Generable` and `GenerationSchema` with Foundation
Models APIs for typed and dynamic structured generation.

KernelHarnessKit adapts its registered tools to Foundation Models' `Tool`
protocol at session construction. The adapter preserves the harness's
permission checker and workspace context; Foundation Models performs tool
argument generation, tool invocation sequencing, and transcript updates.

The package targets macOS, iOS, and watchOS 27.0 or later, matching the
Foundation Models API generation used by this integration.
