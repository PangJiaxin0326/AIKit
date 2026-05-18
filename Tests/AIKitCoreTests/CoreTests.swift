import Foundation
import Testing
@testable import AIKitCore
import AIKitTestSupport

@Suite struct PackageManifestTests {
    @Test func platformMinimumsMatchGuide() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let packageRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let manifest = try String(
            contentsOf: packageRoot.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        #expect(manifest.contains(".iOS(.v17)"))
        #expect(manifest.contains(".macOS(.v14)"))
        #expect(manifest.contains(".visionOS(.v1)"))
    }
}

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
        #expect(AppleIntelligenceProvider().supportsNativeTools == false)
        #expect(AnthropicProvider(apiKey: "k").supportsNativeTools == true)
        #expect(OpenAIProvider(apiKey: "k").supportsNativeTools == true)
    }

    @Test func appleIntelligencePromptIncludesToolManifest() {
        let request = LLMRequest(
            model: AppleIntelligenceProvider.defaultModel,
            system: "You are embedded in an app.",
            messages: [
                .init(role: .user, text: "Open settings"),
                .init(role: .tool, content: [
                    .toolResult(
                        toolUseID: "t1",
                        content: "{\"navigated\":true}",
                        isError: false
                    ),
                ]),
            ],
            tools: [
                ToolDescriptor(
                    name: "navigate",
                    description: "Navigate to a screen.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "destination": .object(["type": .string("string")]),
                        ]),
                    ])
                ),
            ]
        )

        let rendered = AppleIntelligenceProvider.renderedPrompt(for: request)
        #expect(rendered.instructions?.contains("You are embedded in an app.") == true)
        #expect(rendered.instructions?.contains("Available AIKit tools") == true)
        #expect(rendered.instructions?.contains("navigate") == true)
        #expect(rendered.prompt.contains("User:\nOpen settings"))
        #expect(rendered.prompt.contains("Tool result"))
    }
}

@Suite struct MultimodalContentTests {
    @Test func mediaBlocksRoundTripAndLeavePlainTextStable() throws {
        let image = ImageContent(
            data: Data([0x01, 0x02, 0x03]),
            mimeType: "image/png",
            detail: .low
        )
        let audio = AudioContent(
            data: Data([0x04, 0x05]),
            mimeType: "audio/wav",
            format: .wav,
            transcript: "spoken words"
        )
        let message = Message(role: .user, content: [
            .text("Describe this"),
            .image(image),
            .audio(audio),
        ])

        #expect(message.plainText == "Describe this")
        #expect(message.images == [image])
        #expect(message.audio == [audio])

        let encoded = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(Message.self, from: encoded)
        #expect(decoded == message)
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

    @Test func openAIStreamingToolCallArgumentOnlyDeltas() async throws {
        let sse = """
        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"navigate","arguments":"{"}}]},"finish_reason":null}]}

        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\\"destination\\""}}]},"finish_reason":null}]}

        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":":\\"settings\\"}"}}]},"finish_reason":"tool_calls"}]}

        data: [DONE]
        """.data(using: .utf8)!
        URLProtocolStub.setStub(.init(body: sse))
        let provider = OpenAIProvider(
            apiKey: "k", session: URLProtocolStub.makeSession()
        )

        var starts: [(id: String, name: String)] = []
        var inputIDs: [String] = []
        var input = ""
        var stop: StopReason?
        for try await chunk in provider.stream(LLMRequest(model: "gpt-4o")) {
            switch chunk {
            case .toolUseStart(let id, let name):
                starts.append((id, name))
            case .toolUseInputDelta(let id, let json):
                inputIDs.append(id)
                input += json
            case .stop(let reason):
                stop = reason
            default:
                break
            }
        }

        #expect(starts.map(\.id) == ["call_1"])
        #expect(starts.map(\.name) == ["navigate"])
        #expect(inputIDs == ["call_1", "call_1", "call_1"])
        #expect(input == "{\"destination\":\"settings\"}")
        #expect(stop == .toolUse)
    }

    @Test func anthropicStreamingToolUseDeltasUseStartIDs() async throws {
        let sse = """
        data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_a","name":"navigate"}}

        data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\"destination\\":\\"settings\\"}"}}

        data: {"type":"content_block_stop","index":0}

        data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_b","name":"setSetting"}}

        data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\"key\\":\\"theme\\"}"}}

        data: {"type":"content_block_stop","index":1}

        data: {"type":"message_delta","delta":{"stop_reason":"tool_use"}}
        """.data(using: .utf8)!
        URLProtocolStub.setStub(.init(body: sse))
        let provider = AnthropicProvider(
            apiKey: "k", session: URLProtocolStub.makeSession()
        )

        var starts: [(id: String, name: String)] = []
        var inputIDs: [String] = []
        var stopIDs: [String] = []
        for try await chunk in provider.stream(LLMRequest(model: "claude-opus-4-7")) {
            switch chunk {
            case .toolUseStart(let id, let name):
                starts.append((id, name))
            case .toolUseInputDelta(let id, _):
                inputIDs.append(id)
            case .toolUseStop(let id):
                stopIDs.append(id)
            default:
                break
            }
        }

        #expect(starts.map(\.id) == ["toolu_a", "toolu_b"])
        #expect(starts.map(\.name) == ["navigate", "setSetting"])
        #expect(inputIDs == ["toolu_a", "toolu_b"])
        #expect(stopIDs == ["toolu_a", "toolu_b"])
    }

    @Test func openAIMalformedFunctionArgumentsArePreserved() async throws {
        let body = """
        {
          "choices": [{
            "message": {
              "tool_calls": [{
                "id": "call_bad",
                "type": "function",
                "function": {"name": "navigate", "arguments": "{\\"destination\\":"}
              }]
            },
            "finish_reason": "tool_calls"
          }]
        }
        """.data(using: .utf8)!
        URLProtocolStub.setStub(.init(body: body))
        let provider = OpenAIProvider(
            apiKey: "test-key",
            session: URLProtocolStub.makeSession()
        )
        let response = try await provider.complete(LLMRequest(model: "gpt-4o"))
        let input = try #require(response.toolUses.first?.input.objectValue)
        #expect(input["__aikit_malformed_tool_input_raw"]?.stringValue == "{\"destination\":")
        #expect(input != [:])
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

    @Test func openAIEncodesImageAudioAndDecodesVoiceOutput() async throws {
        let audioBytes = Data([0x09, 0x08, 0x07])
        let body = """
        {
          "choices": [{
            "message": {
              "audio": {
                "id": "audio_1",
                "expires_at": 1900000000,
                "data": "\(audioBytes.base64EncodedString())",
                "transcript": "spoken answer"
              }
            },
            "finish_reason": "stop"
          }]
        }
        """.data(using: .utf8)!
        URLProtocolStub.setStub(.init(body: body))
        let provider = OpenAIProvider(
            apiKey: "test-key",
            session: URLProtocolStub.makeSession()
        )
        let request = LLMRequest(
            model: "gpt-4o-audio-preview",
            messages: [
                Message(role: .user, content: [
                    .text("Describe this clip"),
                    .image(ImageContent(
                        data: Data([0x01, 0x02]),
                        mimeType: "image/jpeg",
                        detail: .high
                    )),
                    .audio(AudioContent(
                        data: Data([0x03, 0x04]),
                        mimeType: "audio/wav",
                        format: .wav
                    )),
                ]),
            ],
            audioOutput: AudioOutputOptions(voice: "alloy", format: .mp3)
        )

        let response = try await provider.complete(request)
        let outputAudio = try #require(response.audio.first)
        #expect(outputAudio.id == "audio_1")
        #expect(outputAudio.transcript == "spoken answer")
        #expect(outputAudio.format == .mp3)
        #expect(outputAudio.source.data?.mimeType == "audio/mpeg")
        #expect(outputAudio.source.data?.data == audioBytes)

        let sent = try recordedRequestJSON()
        let modalities = try #require(sent["modalities"]?.arrayValue)
        #expect(modalities.compactMap(\.stringValue) == ["text", "audio"])
        let audioOptions = try #require(sent["audio"]?.objectValue)
        #expect(audioOptions["voice"]?.stringValue == "alloy")
        #expect(audioOptions["format"]?.stringValue == "mp3")

        let messages = try #require(sent["messages"]?.arrayValue)
        let message = try #require(messages.first?.objectValue)
        let parts = try #require(message["content"]?.arrayValue)
        #expect(parts.count == 3)
        #expect(parts[0].objectValue?["type"]?.stringValue == "text")
        let imageURL = try #require(parts[1].objectValue?["image_url"]?.objectValue)
        #expect(parts[1].objectValue?["type"]?.stringValue == "image_url")
        #expect(imageURL["url"]?.stringValue == "data:image/jpeg;base64,AQI=")
        #expect(imageURL["detail"]?.stringValue == "high")
        let inputAudio = try #require(parts[2].objectValue?["input_audio"]?.objectValue)
        #expect(parts[2].objectValue?["type"]?.stringValue == "input_audio")
        #expect(inputAudio["data"]?.stringValue == "AwQ=")
        #expect(inputAudio["format"]?.stringValue == "wav")
    }

    @Test func anthropicEncodesImageContentBlocks() async throws {
        let body = """
        {"content": [{"type": "text", "text": "ok"}], "stop_reason": "end_turn"}
        """.data(using: .utf8)!
        URLProtocolStub.setStub(.init(body: body))
        let provider = AnthropicProvider(
            apiKey: "test-key",
            session: URLProtocolStub.makeSession()
        )

        _ = try await provider.complete(LLMRequest(
            model: "claude-opus-4-7",
            messages: [
                Message(role: .user, content: [
                    .text("What is shown?"),
                    .image(ImageContent(
                        data: Data([0xaa, 0xbb]),
                        mimeType: "image/png"
                    )),
                ]),
            ]
        ))

        let sent = try recordedRequestJSON()
        let messages = try #require(sent["messages"]?.arrayValue)
        let message = try #require(messages.first?.objectValue)
        let parts = try #require(message["content"]?.arrayValue)
        let source = try #require(parts[1].objectValue?["source"]?.objectValue)
        #expect(parts[1].objectValue?["type"]?.stringValue == "image")
        #expect(source["type"]?.stringValue == "base64")
        #expect(source["media_type"]?.stringValue == "image/png")
        #expect(source["data"]?.stringValue == "qrs=")
    }

    @Test func ollamaEncodesImageArrays() async throws {
        let body = """
        {"model":"llava","message":{"role":"assistant","content":"ok"},\
        "done":true,"done_reason":"stop"}
        """.data(using: .utf8)!
        URLProtocolStub.setStub(.init(body: body))
        let provider = OllamaProvider(model: "llava", session: URLProtocolStub.makeSession())

        _ = try await provider.complete(LLMRequest(
            model: "llava",
            messages: [
                Message(role: .user, content: [
                    .text("Describe this"),
                    .image(ImageContent(data: Data([0x0a, 0x0b]), mimeType: "image/png")),
                ]),
            ]
        ))

        let sent = try recordedRequestJSON()
        let messages = try #require(sent["messages"]?.arrayValue)
        let message = try #require(messages.first?.objectValue)
        #expect(message["content"]?.stringValue == "Describe this")
        let images = try #require(message["images"]?.arrayValue)
        #expect(images.compactMap(\.stringValue) == ["Cgs="])
    }

    @Test func providersRejectUnsupportedAudioInput() async {
        URLProtocolStub.setStub(.init(body: Data("{}".utf8)))
        let request = LLMRequest(
            model: "claude-opus-4-7",
            messages: [
                Message(role: .user, content: [
                    .audio(AudioContent(data: Data([0x01]), mimeType: "audio/wav", format: .wav)),
                ]),
            ]
        )
        let provider = AnthropicProvider(
            apiKey: "test-key",
            session: URLProtocolStub.makeSession()
        )
        await #expect(throws: LLMError.self) {
            try await provider.complete(request)
        }
    }
}

private func recordedRequestJSON() throws -> [String: JSONValue] {
    let request = try #require(URLProtocolStub.recordedRequests.last)
    let body = try recordedBodyData(from: request)
    return try #require(JSONValue(data: body).objectValue)
}

private func recordedBodyData(from request: URLRequest) throws -> Data {
    if let body = request.httpBody {
        return body
    }
    let stream = try #require(request.httpBodyStream)
    stream.open()
    defer { stream.close() }
    var data = Data()
    let bufferSize = 4_096
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }
    while stream.hasBytesAvailable {
        let count = stream.read(buffer, maxLength: bufferSize)
        if count < 0 { break }
        if count == 0 { break }
        data.append(buffer, count: count)
    }
    return data
}
