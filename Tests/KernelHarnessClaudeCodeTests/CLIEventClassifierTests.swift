import Foundation
import Testing
@testable import KernelHarnessClaudeCode

@Suite("CLIEventClassifier")
struct CLIEventClassifierTests {
    @Test("system init event produces initMetadata")
    func initEvent() {
        let line = #"{"type":"system","subtype":"init","session_id":"abc-123","apiKeySource":"none","model":"haiku"}"#
        #expect(CLIEventClassifier.classify(line: line) == .initMetadata(sessionId: "abc-123", apiKeySource: "none"))
    }

    @Test("stream_event text_delta produces textDelta")
    func textDelta() {
        let line = #"{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"hello"}}}"#
        #expect(CLIEventClassifier.classify(line: line) == .textDelta("hello"))
    }

    @Test("stream_event thinking_delta produces thinkingDelta (dropped by provider)")
    func thinkingDelta() {
        let line = #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"let me think"}}}"#
        #expect(CLIEventClassifier.classify(line: line) == .thinkingDelta("let me think"))
    }

    @Test("stream_event signature_delta is ignored")
    func signatureDelta() {
        let line = #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"abc"}}}"#
        #expect(CLIEventClassifier.classify(line: line) == .ignored)
    }

    @Test("content_block_start for tool_use produces toolUseStart")
    func toolUseStart() {
        let line = #"{"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_abc","name":"mcp__khk__echo","input":{}}}}"#
        #expect(CLIEventClassifier.classify(line: line) == .toolUseStart(index: 1, id: "toolu_abc", name: "mcp__khk__echo"))
    }

    @Test("input_json_delta produces toolUseInputDelta")
    func inputJSONDelta() {
        let line = #"{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"message\":"}}}"#
        #expect(CLIEventClassifier.classify(line: line) == .toolUseInputDelta(index: 1, partialJSON: "{\"message\":"))
    }

    @Test("content_block_stop produces blockStop")
    func blockStop() {
        let line = #"{"type":"stream_event","event":{"type":"content_block_stop","index":2}}"#
        #expect(CLIEventClassifier.classify(line: line) == .blockStop(index: 2))
    }

    @Test("message_stop produces messageStop")
    func messageStop() {
        let line = #"{"type":"stream_event","event":{"type":"message_stop"}}"#
        #expect(CLIEventClassifier.classify(line: line) == .messageStop)
    }

    @Test("rate_limit_event produces rateLimit")
    func rateLimit() {
        let line = #"{"type":"rate_limit_event","rate_limit_info":{"resetsAt":1776981600,"rateLimitType":"five_hour"}}"#
        #expect(CLIEventClassifier.classify(line: line) == .rateLimit(resetsAt: 1_776_981_600, type: "five_hour"))
    }

    @Test("result success produces turnResult with usage")
    func resultSuccess() {
        let line = #"{"type":"result","subtype":"success","is_error":false,"result":"DONE","usage":{"input_tokens":10,"output_tokens":5}}"#
        let event = CLIEventClassifier.classify(line: line)
        if case let .turnResult(success, usage, error, subtype) = event {
            #expect(success)
            #expect(error == nil)
            #expect(subtype == nil)
            #expect(usage?.promptTokens == 10)
            #expect(usage?.completionTokens == 5)
        } else {
            Issue.record("expected turnResult, got \(event)")
        }
    }

    @Test("result error produces turnResult with errorMessage")
    func resultError() {
        let line = #"{"type":"result","subtype":"error","is_error":true,"result":"Credit balance is too low"}"#
        let event = CLIEventClassifier.classify(line: line)
        if case let .turnResult(success, _, error, subtype) = event {
            #expect(!success)
            #expect(error?.contains("Credit balance is too low") == true)
            #expect(subtype == "error")
        } else {
            Issue.record("expected turnResult, got \(event)")
        }
    }

    @Test("result error_max_turns folds errors array and subtype into message")
    func resultMaxTurnsError() {
        let line = #"{"type":"result","subtype":"error_max_turns","is_error":true,"errors":["Reached maximum number of turns (1)"]}"#
        let event = CLIEventClassifier.classify(line: line)
        if case let .turnResult(success, _, error, subtype) = event {
            #expect(!success)
            #expect(error?.contains("Reached maximum") == true)
            #expect(subtype == "error_max_turns")
        } else {
            Issue.record("expected turnResult, got \(event)")
        }
    }

    @Test("synthetic user tool_result produces toolResultIngested")
    func toolResultIngested() {
        let line = #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_abc","type":"tool_result","content":[{"type":"text","text":"echoed: hi"}]}]}}"#
        let event = CLIEventClassifier.classify(line: line)
        #expect(event == .toolResultIngested(toolUseId: "toolu_abc", content: "echoed: hi", isError: false))
    }

    @Test("message_start produces messageStart")
    func messageStartEvent() {
        let line = #"{"type":"stream_event","event":{"type":"message_start","message":{"id":"m1"}}}"#
        #expect(CLIEventClassifier.classify(line: line) == .messageStart)
    }

    @Test("assistant envelope is ignored (stream_events are the source of truth)")
    func assistantEnvelopeIgnored() {
        let line = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"HELLO"}]}}"#
        #expect(CLIEventClassifier.classify(line: line) == .ignored)
    }

    @Test("malformed line returns ignored")
    func malformedIgnored() {
        #expect(CLIEventClassifier.classify(line: "not json") == .ignored)
        #expect(CLIEventClassifier.classify(line: "") == .ignored)
    }
}
