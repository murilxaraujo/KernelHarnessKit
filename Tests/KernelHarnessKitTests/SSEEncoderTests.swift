import Testing
import Foundation
@testable import KernelHarnessKit

@Suite("SSEEncoder")
struct SSEEncoderTests {
    private let encoder = SSEEncoder()

    @Test func encodesTextChunk() {
        let s = encoder.encode(.textChunk("hi"))
        #expect(s.hasPrefix("event: agent_text_chunk\n"))
        #expect(s.contains("data:"))
        #expect(s.hasSuffix("\n\n"))
        #expect(s.contains(#""text":"hi""#))
    }

    @Test func encodesHarnessPhase() {
        let s = encoder.encode(.harnessPhaseStart(name: "extract", index: 0, total: 3))
        #expect(s.contains("event: harness_phase_start"))
        #expect(s.contains(#""index":0"#))
        #expect(s.contains(#""total":3"#))
        #expect(s.contains(#""name":"extract""#))
    }

    @Test func encodesToolCallResult() {
        let s = encoder.encode(.toolExecutionCompleted(
            callId: "call_abc",
            name: "read_file",
            result: .success("hello")
        ))
        #expect(s.contains("agent_tool_call_result"))
        #expect(s.contains(#""id":"call_abc""#))
        #expect(s.contains(#""isError":false"#))
        #expect(s.contains(#""output":"hello""#))
    }

    @Test func encodesToolCallStart() {
        let s = encoder.encode(.toolExecutionStarted(
            callId: "call_xyz",
            name: "write_file",
            input: ["path": .string("x.md")]
        ))
        #expect(s.contains("agent_tool_call_start"))
        #expect(s.contains(#""id":"call_xyz""#))
        #expect(s.contains(#""name":"write_file""#))
    }

    @Test func encodesHarnessComplete() {
        let s = encoder.encode(.harnessComplete)
        #expect(s.contains("event: harness_complete"))
        #expect(s.contains("data: {}"))
    }

    @Test func payloadIsValidJSON() throws {
        let s = encoder.encode(.statusChange(.working))
        let lines = s.components(separatedBy: "\n")
        let dataLine = lines.first(where: { $0.hasPrefix("data:") })
        let payload = dataLine?.dropFirst("data: ".count)
        let data = Data((payload ?? "").utf8)
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(parsed?["status"] as? String == "working")
    }
}
