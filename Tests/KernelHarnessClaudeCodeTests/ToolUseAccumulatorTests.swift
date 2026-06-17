import Foundation
import Testing
@testable import KernelHarnessKit
@testable import KernelHarnessClaudeCode

@Suite("ToolUseAccumulator")
struct ToolUseAccumulatorTests {
    @Test("accumulates partial JSON fragments into ContentBlock.toolUse")
    func fullToolUseRoundTrip() {
        var accumulator = ToolUseAccumulator()
        accumulator.begin(index: 1, id: "toolu_abc", name: "echo")
        accumulator.append(index: 1, partialJSON: #"{"mess"#)
        accumulator.append(index: 1, partialJSON: #"age":"h"#)
        accumulator.append(index: 1, partialJSON: #"i"}"#)
        let block = accumulator.finalize(index: 1)

        if case .toolUse(let id, let name, let input) = block {
            #expect(id == "toolu_abc")
            #expect(name == "echo")
            #expect(input["message"] == .string("hi"))
        } else {
            Issue.record("expected toolUse, got \(String(describing: block))")
        }
    }

    @Test("empty input produces empty dictionary")
    func emptyInput() {
        var accumulator = ToolUseAccumulator()
        accumulator.begin(index: 0, id: "toolu_x", name: "noop")
        let block = accumulator.finalize(index: 0)
        if case .toolUse(_, _, let input) = block {
            #expect(input.isEmpty)
        } else {
            Issue.record("expected toolUse")
        }
    }

    @Test("finalize on unopened index returns nil")
    func unopenedIndexReturnsNil() {
        var accumulator = ToolUseAccumulator()
        #expect(accumulator.finalize(index: 99) == nil)
    }

    @Test("multiple parallel tool_use indices are independent")
    func parallelTools() {
        var accumulator = ToolUseAccumulator()
        accumulator.begin(index: 0, id: "t1", name: "a")
        accumulator.begin(index: 1, id: "t2", name: "b")
        accumulator.append(index: 0, partialJSON: #"{"x":1}"#)
        accumulator.append(index: 1, partialJSON: #"{"y":2}"#)
        let b0 = accumulator.finalize(index: 0)
        let b1 = accumulator.finalize(index: 1)
        if case .toolUse(_, let name, let input) = b0 {
            #expect(name == "a")
            #expect(input["x"] == .integer(1))
        } else { Issue.record("b0 wrong shape") }
        if case .toolUse(_, let name, let input) = b1 {
            #expect(name == "b")
            #expect(input["y"] == .integer(2))
        } else { Issue.record("b1 wrong shape") }
    }
}
