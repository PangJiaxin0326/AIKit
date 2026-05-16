import Foundation
import Testing
@testable import AIKitCore
import AIKitTestSupport

@Suite struct JSONValueTests {
    @Test func roundTrip() throws {
        let value: JSONValue = .object([
            "name": .string("navigate"),
            "count": .number(3),
            "flag": .bool(true),
            "nested": .array([.string("a"), .null]),
        ])
        let data = try value.data()
        let decoded = try JSONValue(data: data)
        #expect(decoded == value)
    }

    @Test func allStringsRecursive() {
        let value: JSONValue = .object([
            "a": .string("x"),
            "b": .array([.string("y"), .number(1)]),
        ])
        #expect(Set(value.allStrings) == ["x", "y"])
    }

    /// REVIEW2 finding **C**: integral knobs must serialize as integers so
    /// strict backends (Ollama/llama.cpp/vLLM) accept `num_ctx` etc.
    @Test func intEncodesWithoutDecimalPoint() throws {
        let value: JSONValue = .object(["num_ctx": .int(4096), "t": .number(0.5)])
        let json = String(decoding: try value.data(), as: UTF8.self)
        #expect(json.contains("\"num_ctx\":4096"))
        #expect(!json.contains("4096.0"))
        #expect(json.contains("\"t\":0.5"))
    }

    @Test func integerLiteralProducesIntCase() {
        let v: JSONValue = 4096
        #expect(v == .int(4096))
        #expect(v.intValue == 4096)
        #expect(JSONValue.number(8.0).intValue == 8)
        #expect(JSONValue.number(8.5).intValue == nil)
        #expect(JSONValue.string("x").intValue == nil)
    }

    @Test func numbersStillDecodeAsNumberForLosslessRoundTrip() throws {
        // Decoding never yields `.int`; whole-number doubles stay `.number`.
        let decoded = try JSONValue(data: Data("{\"n\":3}".utf8))
        #expect(decoded == .object(["n": .number(3)]))
    }

    /// REVIEW3 finding **#4**: a constructed `.int` and a decoded whole-number
    /// `.number` must compare and hash alike, recursively.
    @Test func canonicalNumericEquality() throws {
        #expect(JSONValue.int(5) == JSONValue.number(5.0))
        #expect(JSONValue.number(5.0) == JSONValue.int(5))
        #expect(JSONValue.number(-0.0) == JSONValue.int(0))
        #expect(JSONValue.int(5) != JSONValue.number(5.5))
        #expect(JSONValue.int(5) != JSONValue.number(6.0))

        let built: JSONValue = .object(["a": .array([.int(1), .int(2)])])
        let decoded = try JSONValue(data: Data("{\"a\":[1,2]}".utf8))
        #expect(built == decoded)
    }

    @Test func canonicalNumericHashing() {
        #expect(JSONValue.int(5).hashValue == JSONValue.number(5.0).hashValue)
        var set: Set<JSONValue> = [.int(4096)]
        #expect(set.contains(.number(4096.0)))
        set.insert(.number(4096.0))
        #expect(set.count == 1)
    }

    /// The exact footgun: a hand-built request vs. one whose `extraBody`
    /// numbers came back through a JSON round-trip.
    @Test func requestEqualityAcrossIntAndNumber() {
        let built = LLMRequest(model: "m", extraBody: ["num_ctx": .int(4096)])
        let decoded = LLMRequest(model: "m", extraBody: ["num_ctx": .number(4096)])
        #expect(built == decoded)
        #expect(built.hashValue == decoded.hashValue)
    }

    /// Non-finite / out-of-range doubles must stay distinct and never trap.
    @Test func nonFiniteNumbersAreSafe() {
        #expect(JSONValue.number(.nan) != JSONValue.int(0))
        #expect(JSONValue.number(.infinity) != JSONValue.int(0))
        #expect(JSONValue.number(1e30) != JSONValue.int(0))
        _ = JSONValue.number(.infinity).hashValue
        _ = JSONValue.number(.nan).hashValue
        _ = JSONValue.number(1e30).hashValue
    }
}

@Suite struct ProviderCapabilityTests {
    /// REVIEW3 finding **#1**: Ollama tool support is per-model, so the
    /// provider cannot guarantee native tool calling and must report `false`
    /// (which makes the additive fenced fallback the default). Fixed-contract
    /// providers still report `true`.
    @Test func nativeToolGuarantees() {
        #expect(OllamaProvider().supportsNativeTools == false)
        #expect(AnthropicProvider(apiKey: "k").supportsNativeTools == true)
        #expect(OpenAIProvider(apiKey: "k").supportsNativeTools == true)
    }
}

@Suite struct EndpointResolutionTests {
    @Test func toleratesV1SuffixAndTrailingSlash() throws {
        let cases: [(String, String)] = [
            ("https://api.openai.com", "https://api.openai.com/v1/chat/completions"),
            ("http://localhost:11434/v1", "http://localhost:11434/v1/chat/completions"),
            ("http://localhost:11434/v1/", "http://localhost:11434/v1/chat/completions"),
            ("http://h/v1/chat/completions", "http://h/v1/chat/completions"),
        ]
        for (input, expected) in cases {
            let resolved = try URL(string: input)!
                .resolvingEndpoint(apiPrefix: "v1", endpoint: "chat/completions")
            #expect(resolved.absoluteString == expected)
        }
    }

    @Test func ollamaApiPrefix() throws {
        #expect(
            try URL(string: "http://localhost:11434")!
                .resolvingEndpoint(apiPrefix: "api", endpoint: "chat")
                .absoluteString == "http://localhost:11434/api/chat"
        )
        #expect(
            try URL(string: "http://localhost:11434/api")!
                .resolvingEndpoint(apiPrefix: "api", endpoint: "chat")
                .absoluteString == "http://localhost:11434/api/chat"
        )
    }

    @Test func transportErrorClassificationIsPreserved() {
        #expect(LLMError.from(transport: URLError(.timedOut)) == .timeout(URLError(.timedOut).localizedDescription))
        #expect(LLMError.from(transport: URLError(.cancelled)) == .cancelled)
        #expect(LLMError.from(transport: CancellationError()) == .cancelled)
    }
}

@Suite struct MockProviderTests {
    @Test func nonStreamingRoundTrip() async throws {
        let provider = MockProvider(finalText: "hello world")
        let client = LLMClient(provider: provider)
        let response = try await client.complete(
            LLMRequest(model: "test", messages: [.init(role: .user, text: "hi")])
        )
        #expect(response.text == "hello world")
        #expect(response.stopReason == .endTurn)
    }

    @Test func streamingRoundTrip() async throws {
        let provider = MockProvider(responses: [
            LLMResponse(
                content: [
                    .text("partial "),
                    .toolUse(id: "t1", name: "navigate", input: .object(["to": .string("home")])),
                ],
                stopReason: .toolUse
            )
        ])
        let client = LLMClient(provider: provider)
        var chunks: [LLMResponseChunk] = []
        for try await chunk in client.stream(LLMRequest(model: "test")) {
            chunks.append(chunk)
        }
        #expect(chunks.contains(.textDelta("partial ")))
        #expect(chunks.contains(.toolUseStart(id: "t1", name: "navigate")))
        #expect(chunks.contains(.stop(.toolUse)))
    }

    @Test func exhaustionThrows() async {
        let provider = MockProvider(finalText: "once")
        let client = LLMClient(provider: provider)
        _ = try? await client.complete(LLMRequest(model: "test"))
        await #expect(throws: LLMError.self) {
            try await client.complete(LLMRequest(model: "test"))
        }
    }
}

@Suite(.serialized) struct HTTPProviderTests {
    @Test func decodesMessagesResponse() async throws {
        let body = """
        {
          "content": [
            {"type": "text", "text": "Hi there"},
            {"type": "tool_use", "id": "tu_1", "name": "navigate", "input": {"to": "settings"}}
          ],
          "stop_reason": "tool_use",
          "usage": {"input_tokens": 12, "output_tokens": 7}
        }
        """.data(using: .utf8)!
        URLProtocolStub.setStub(.init(body: body))
        let provider = AnthropicProvider(
            apiKey: "test-key",
            session: URLProtocolStub.makeSession()
        )
        let response = try await provider.complete(
            LLMRequest(model: "claude-opus-4-7", messages: [.init(role: .user, text: "hi")])
        )
        #expect(response.text == "Hi there")
        #expect(response.stopReason == .toolUse)
        #expect(response.usage.inputTokens == 12)
        #expect(response.toolUses.first?.name == "navigate")
    }

    @Test func httpErrorSurfaces() async {
        URLProtocolStub.setStub(.init(statusCode: 500, body: Data("boom".utf8)))
        let provider = AnthropicProvider(
            apiKey: "test-key",
            session: URLProtocolStub.makeSession()
        )
        await #expect(throws: LLMError.self) {
            try await provider.complete(LLMRequest(model: "claude-opus-4-7"))
        }
    }

    @Test func emptyKeyIsAllowedForLocalBackends() async throws {
        // No-auth local backends must work with an empty key: the provider
        // omits the auth header instead of throwing `missingAPIKey`.
        let body = """
        {"content": [{"type": "text", "text": "ok"}], "stop_reason": "end_turn"}
        """.data(using: .utf8)!
        URLProtocolStub.setStub(.init(body: body))
        let provider = AnthropicProvider(apiKey: "", session: URLProtocolStub.makeSession())
        let response = try await provider.complete(
            LLMRequest(model: "local-model", messages: [.init(role: .user, text: "hi")])
        )
        #expect(response.text == "ok")
    }

    @Test func openAIDecodesStreamingUsageChunk() async throws {
        // The trailing `stream_options.include_usage` chunk has empty choices.
        let sse = """
        data: {"choices":[{"delta":{"content":"hello"},"finish_reason":null}]}

        data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

        data: {"choices":[],"usage":{"prompt_tokens":11,"completion_tokens":4}}

        data: [DONE]
        """.data(using: .utf8)!
        URLProtocolStub.setStub(.init(body: sse))
        let provider = OpenAIProvider(
            apiKey: "k", session: URLProtocolStub.makeSession()
        )
        var usage: TokenUsage?
        var text = ""
        for try await chunk in provider.stream(LLMRequest(model: "gpt-4o")) {
            switch chunk {
            case .textDelta(let d): text += d
            case .usage(let u): usage = u
            default: break
            }
        }
        #expect(text == "hello")
        #expect(usage?.inputTokens == 11)
        #expect(usage?.outputTokens == 4)
    }

    @Test func ollamaDecodesChatAndToolCalls() async throws {
        let body = """
        {"model":"llama3.1","message":{"role":"assistant","content":"",\
        "tool_calls":[{"function":{"name":"navigate","arguments":{"destination":"home"}}}]},\
        "done":true,"done_reason":"stop","prompt_eval_count":8,"eval_count":3}
        """.data(using: .utf8)!
        URLProtocolStub.setStub(.init(body: body))
        let provider = OllamaProvider(session: URLProtocolStub.makeSession())
        let response = try await provider.complete(
            LLMRequest(model: "llama3.1", messages: [.init(role: .user, text: "go home")])
        )
        #expect(response.stopReason == .toolUse)
        #expect(response.toolUses.first?.name == "navigate")
        #expect(response.toolUses.first?.input.objectValue?["destination"]?.stringValue == "home")
        #expect(response.usage.inputTokens == 8)
        #expect(response.usage.outputTokens == 3)
    }

    /// REVIEW2 finding **F2**: tool calls mean `.toolUse` regardless of
    /// `done_reason` — the single `stopReason()` source must enforce that.
    @Test func ollamaToolCallsOverrideLengthDoneReason() async throws {
        let body = """
        {"model":"llama3.1","message":{"role":"assistant","content":"",\
        "tool_calls":[{"function":{"name":"navigate","arguments":{"to":"x"}}}]},\
        "done":true,"done_reason":"length","prompt_eval_count":1,"eval_count":1}
        """.data(using: .utf8)!
        URLProtocolStub.setStub(.init(body: body))
        let provider = OllamaProvider(session: URLProtocolStub.makeSession())
        let response = try await provider.complete(
            LLMRequest(model: "llama3.1", messages: [.init(role: .user, text: "hi")])
        )
        #expect(response.stopReason == .toolUse)
        #expect(response.toolUses.first?.name == "navigate")
    }

    /// REVIEW3 finding **#3**: reasoning / chain-of-thought must be decoded
    /// and exposed, not silently dropped.
    @Test func anthropicDecodesThinkingBlock() async throws {
        let body = """
        {"content":[{"type":"thinking","thinking":"let me think"},\
        {"type":"text","text":"answer"}],"stop_reason":"end_turn"}
        """.data(using: .utf8)!
        URLProtocolStub.setStub(.init(body: body))
        let provider = AnthropicProvider(
            apiKey: "k", session: URLProtocolStub.makeSession()
        )
        let response = try await provider.complete(
            LLMRequest(model: "claude-opus-4-7")
        )
        #expect(response.reasoning == "let me think")
        #expect(response.text == "answer")
    }

    @Test func ollamaDecodesThinking() async throws {
        let body = """
        {"model":"qwq","message":{"role":"assistant","content":"final",\
        "thinking":"reasoned"},"done":true,"done_reason":"stop"}
        """.data(using: .utf8)!
        URLProtocolStub.setStub(.init(body: body))
        let provider = OllamaProvider(session: URLProtocolStub.makeSession())
        let response = try await provider.complete(LLMRequest(model: "qwq"))
        #expect(response.reasoning == "reasoned")
        #expect(response.text == "final")
    }

    @Test func openAIDecodesReasoningContent() async throws {
        let body = """
        {"choices":[{"message":{"content":"ans","reasoning_content":"cot"},\
        "finish_reason":"stop"}]}
        """.data(using: .utf8)!
        URLProtocolStub.setStub(.init(body: body))
        let provider = OpenAIProvider(
            apiKey: "k", session: URLProtocolStub.makeSession()
        )
        let response = try await provider.complete(LLMRequest(model: "deepseek-r1"))
        #expect(response.reasoning == "cot")
        #expect(response.text == "ans")
    }

    @Test func anthropicStreamsThinkingDelta() async throws {
        let sse = """
        data: {"type":"content_block_delta","index":0,\
        "delta":{"type":"thinking_delta","thinking":"hmm "}}

        data: {"type":"content_block_delta","index":0,\
        "delta":{"type":"thinking_delta","thinking":"ok"}}

        data: {"type":"content_block_delta","index":1,\
        "delta":{"type":"text_delta","text":"answer"}}

        data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}
        """.data(using: .utf8)!
        URLProtocolStub.setStub(.init(body: sse))
        let provider = AnthropicProvider(
            apiKey: "k", session: URLProtocolStub.makeSession()
        )
        var reasoning = ""
        var text = ""
        for try await chunk in provider.stream(LLMRequest(model: "claude-opus-4-7")) {
            switch chunk {
            case .reasoningDelta(let d): reasoning += d
            case .textDelta(let d): text += d
            default: break
            }
        }
        #expect(reasoning == "hmm ok")
        #expect(text == "answer")
    }

    @Test func decodesChatCompletion() async throws {
        let body = """
        {
          "choices": [{
            "message": {
              "content": "done",
              "tool_calls": [{
                "id": "call_1",
                "type": "function",
                "function": {"name": "setSetting", "arguments": "{\\"key\\":\\"theme\\"}"}
              }]
            },
            "finish_reason": "tool_calls"
          }],
          "usage": {"prompt_tokens": 5, "completion_tokens": 9}
        }
        """.data(using: .utf8)!
        URLProtocolStub.setStub(.init(body: body))
        let provider = OpenAIProvider(
            apiKey: "test-key",
            session: URLProtocolStub.makeSession()
        )
        let response = try await provider.complete(
            LLMRequest(model: "gpt-4o", messages: [.init(role: .user, text: "hi")])
        )
        #expect(response.text == "done")
        #expect(response.stopReason == .toolUse)
        #expect(response.toolUses.first?.name == "setSetting")
        #expect(response.toolUses.first?.input.objectValue?["key"]?.stringValue == "theme")
    }
}
