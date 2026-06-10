import Foundation
import FoundationModels
import Testing
import AIToolKit
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
        #expect(manifest.contains(".iOS(\"26.5\")"))
        #expect(manifest.contains(".macOS(\"26.5\")"))
        #expect(manifest.contains(".visionOS(\"26.5\")"))
    }
}

@Suite struct GeneratedContentValueTests {
    @Test func roundTrip() throws {
        let value: GeneratedContent = .object([
            "name": .string("navigate"),
            "count": .number(3),
            "flag": .bool(true),
            "nested": .array([.string("a"), .null]),
        ])
        let decoded = try GeneratedContent(data: value.data())
        let object = try #require(decoded.objectValue)
        #expect(object["name"]?.stringValue == "navigate")
        #expect(object["count"]?.intValue == 3)
        #expect(object["flag"]?.boolValue == true)
        let nested = try #require(object["nested"]?.arrayValue)
        #expect(nested.first?.stringValue == "a")
        #expect(nested.last?.kind == .null)
    }

    @Test func allStringsRecursive() {
        let value: GeneratedContent = .object([
            "a": .string("x"),
            "b": .array([.string("y"), .number(1)]),
        ])
        #expect(Set(value.allStrings) == ["x", "y"])
    }

    @Test func intEncodesWithoutDecimalPoint() throws {
        let value: GeneratedContent = .object(["seed": .int(4096), "top_p": .number(0.5)])
        let json = String(decoding: value.data(), as: UTF8.self)
        #expect(json.contains("\"seed\": 4096"))
        #expect(!json.contains("4096.0"))
        #expect(json.contains("\"top_p\": 0.5"))
    }

    @Test func intValueRejectsNonIntegralNumbers() {
        #expect(GeneratedContent.number(8.0).intValue == 8)
        #expect(GeneratedContent.number(8.5).intValue == nil)
        #expect(GeneratedContent.string("x").intValue == nil)
    }

    @Test func requestEqualityIncludesResponseSchema() {
        let plain = LLMRequest(model: "m")
        #expect(plain == LLMRequest(model: "m"))
        #expect(plain.hashValue == LLMRequest(model: "m").hashValue)

        let constrained = LLMRequest(
            model: "m",
            responseSchema: GeneratedContent.generationSchema
        )
        #expect(plain != constrained)
    }
}

@Suite struct ProviderCapabilityTests {
    @Test func providerDefinitionsExposeDefaultEndpoints() {
        #expect(AIKitProviderDefinition.all.map(\.kind) == [
            .ark,
            .appleIntelligence,
        ])
        #expect(AIKitProviderDefinition.ark.displayName == "Volcengine Ark")
        #expect(AIKitProviderDefinition.ark.apiKeyStrategy == .bearerToken)
        #expect(
            AIKitProviderDefinition.ark.modelListURL.absoluteString ==
            "https://ark.cn-beijing.volces.com/api/v3/models"
        )
        #expect(
            AIKitProviderDefinition.ark.streamingEndpoint.absoluteString ==
            "https://ark.cn-beijing.volces.com/api/v3/chat/completions"
        )
        #expect(AIKitProviderDefinition.appleIntelligence.displayName == "Apple Intelligence")
        #expect(AIKitProviderDefinition.appleIntelligence.apiKeyStrategy == .none)
        #expect(AIKitProviderDefinition.appleIntelligence.staticModelIDs == [
            "apple-intelligence",
            "private-cloud-compute",
        ])
        #expect(!AIKitProviderDefinition.appleIntelligence.supportsModelCatalogRefresh)
        #expect(
            AIKitProviderDefinition.appleIntelligence.streamingEndpointDisplayName ==
            "On-device / Private Cloud Compute"
        )
        #expect(AIKitProviderKind(providerName: "Other") == nil)
        #expect(AIKitProviderKind(providerName: "Doubao") == nil)
        #expect(AIKitProviderKind(providerName: "Volcengine Ark") == .ark)
        #expect(AIKitProviderKind(providerName: "Apple Intelligence") == .appleIntelligence)
    }

    @Test func nativeToolGuarantees() {
        #expect(AppleIntelligenceProvider().supportsNativeTools == false)
        #expect(VolcengineArkProvider(apiKey: "k", model: "ep-test").supportsNativeTools == true)
    }

    @Test func providerNamesAreStableDisplayLabels() {
        #expect(
            LLMClient(provider: VolcengineArkProvider(apiKey: "k", model: "ep-test")).providerName ==
            "Volcengine Ark"
        )
        #expect(
            LLMClient(provider: AppleIntelligenceProvider()).providerName ==
            "Apple Intelligence"
        )
    }

    @Test func appleIntelligencePromptIncludesToolManifest() {
        let request = LLMRequest(
            model: "apple-intelligence",
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
                    argumentsSchema: GeneratedContent.generationSchema
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

@Suite struct TransportErrorTests {
    @Test func classificationIsPreserved() {
        #expect(
            LLMError.from(transport: URLError(.timedOut)) ==
            .timeout(URLError(.timedOut).localizedDescription)
        )
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
                    .toolUse(id: "t1", name: "navigate", arguments: .object(["to": .string("home")])),
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
    @Test func modelCatalogFetchesArkModels() async throws {
        let body = """
        {"data":[{"id":"doubao-seed-1-6"}]}
        """.data(using: .utf8)!
        URLProtocolStub.setStub(.init(body: body))
        let catalog = AIKitModelCatalog(session: URLProtocolStub.makeSession())

        let models = try await catalog.fetchModels(
            for: .ark,
            apiKey: "ark-key"
        )

        #expect(models == ["doubao-seed-1-6"])
        let request = try #require(URLProtocolStub.recordedRequests.last)
        #expect(request.url?.absoluteString == "https://ark.cn-beijing.volces.com/api/v3/models")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ark-key")
    }

    @Test func modelCatalogRequiresArkAPIKey() async {
        let catalog = AIKitModelCatalog(session: URLProtocolStub.makeSession())

        await #expect(throws: LLMError.self) {
            try await catalog.fetchModels(for: .ark)
        }
    }

    @Test func modelCatalogReturnsAppleIntelligenceStaticModels() async throws {
        URLProtocolStub.setStub(nil)
        let catalog = AIKitModelCatalog(session: URLProtocolStub.makeSession())

        let models = try await catalog.fetchModels(for: .appleIntelligence)

        #expect(models == ["apple-intelligence", "private-cloud-compute"])
        #expect(URLProtocolStub.recordedRequests.isEmpty)
    }

    @Test func arkHTTPErrorSurfaces() async {
        URLProtocolStub.setStub(.init(statusCode: 500, body: Data("boom".utf8)))
        let provider = VolcengineArkProvider(
            apiKey: "test-key",
            model: "ep-test",
            session: URLProtocolStub.makeSession()
        )
        await #expect(throws: LLMError.self) {
            try await provider.complete(LLMRequest(model: "ep-test"))
        }
    }

    @Test func arkDecodesStreamingUsageChunk() async throws {
        // The trailing `stream_options.include_usage` chunk has empty choices.
        let sse = """
        data: {"choices":[{"delta":{"content":"hello"},"finish_reason":null}]}

        data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

        data: {"choices":[],"usage":{"prompt_tokens":11,"completion_tokens":4}}

        data: [DONE]
        """.data(using: .utf8)!
        URLProtocolStub.setStub(.init(body: sse))
        let provider = VolcengineArkProvider(
            apiKey: "k", model: "ep-test", session: URLProtocolStub.makeSession()
        )
        var usage: TokenUsage?
        var text = ""
        for try await chunk in provider.stream(LLMRequest(model: "ep-test")) {
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

    @Test func arkStreamingToolCallArgumentOnlyDeltas() async throws {
        let sse = """
        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"navigate","arguments":"{"}}]},"finish_reason":null}]}

        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\\"destination\\""}}]},"finish_reason":null}]}

        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":":\\"settings\\"}"}}]},"finish_reason":"tool_calls"}]}

        data: [DONE]
        """.data(using: .utf8)!
        URLProtocolStub.setStub(.init(body: sse))
        let provider = VolcengineArkProvider(
            apiKey: "k", model: "ep-test", session: URLProtocolStub.makeSession()
        )

        var starts: [(id: String, name: String)] = []
        var inputIDs: [String] = []
        var stopIDs: [String] = []
        var input = ""
        var stop: StopReason?
        for try await chunk in provider.stream(LLMRequest(model: "ep-test")) {
            switch chunk {
            case .toolUseStart(let id, let name):
                starts.append((id, name))
            case .toolUseInputDelta(let id, let json):
                inputIDs.append(id)
                input += json
            case .toolUseStop(let id):
                stopIDs.append(id)
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
        #expect(stopIDs == ["call_1"])
        #expect(stop == .toolUse)
    }

    @Test func arkMalformedFunctionArgumentsArePreserved() async throws {
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
        let provider = VolcengineArkProvider(
            apiKey: "test-key",
            model: "ep-test",
            session: URLProtocolStub.makeSession()
        )
        let response = try await provider.complete(LLMRequest(model: "ep-test"))
        let input = try #require(response.toolUses.first?.arguments.objectValue)
        #expect(
            input["__aikit_malformed_tool_input_raw"]?.stringValue ==
            "{\"destination\":"
        )
        #expect(input != [:])
    }

    @Test func arkDecodesReasoningContent() async throws {
        let body = """
        {"choices":[{"message":{"content":"ans","reasoning_content":"cot"},\
        "finish_reason":"stop"}]}
        """.data(using: .utf8)!
        URLProtocolStub.setStub(.init(body: body))
        let provider = VolcengineArkProvider(
            apiKey: "k", model: "ep-test", session: URLProtocolStub.makeSession()
        )
        let response = try await provider.complete(LLMRequest(model: "ep-test"))
        #expect(response.reasoning == "cot")
        #expect(response.text == "ans")
    }

    @Test func arkStreamsReasoningDelta() async throws {
        let sse = """
        data: {"choices":[{"delta":{"reasoning_content":"hmm "},"finish_reason":null}]}

        data: {"choices":[{"delta":{"reasoning_content":"ok"},"finish_reason":null}]}

        data: {"choices":[{"delta":{"content":"answer"},"finish_reason":"stop"}]}

        data: [DONE]
        """.data(using: .utf8)!
        URLProtocolStub.setStub(.init(body: sse))
        let provider = VolcengineArkProvider(
            apiKey: "k", model: "ep-test", session: URLProtocolStub.makeSession()
        )
        var reasoning = ""
        var text = ""
        for try await chunk in provider.stream(LLMRequest(model: "ep-test")) {
            switch chunk {
            case .reasoningDelta(let d): reasoning += d
            case .textDelta(let d): text += d
            default: break
            }
        }
        #expect(reasoning == "hmm ok")
        #expect(text == "answer")
    }

    @Test func arkDecodesChatCompletion() async throws {
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
        let provider = VolcengineArkProvider(
            apiKey: "test-key",
            model: "ep-test",
            session: URLProtocolStub.makeSession()
        )
        let response = try await provider.complete(
            LLMRequest(model: "ep-test", messages: [.init(role: .user, text: "hi")])
        )
        #expect(response.text == "done")
        #expect(response.stopReason == .toolUse)
        #expect(response.toolUses.first?.name == "setSetting")
        #expect(response.toolUses.first?.arguments.objectValue?["key"]?.stringValue == "theme")
    }

    @Test func arkProviderUsesDefaultEndpointAndThinking() async throws {
        let body = """
        {"choices":[{"message":{"content":"ok"},"finish_reason":"stop"}]}
        """.data(using: .utf8)!
        URLProtocolStub.setStub(.init(body: body))
        let provider = VolcengineArkProvider(
            apiKey: "test-key",
            model: "ep-test",
            session: URLProtocolStub.makeSession()
        )

        _ = try await provider.complete(
            LLMRequest(model: "ep-test", messages: [.init(role: .user, text: "hi")])
        )

        let request = try #require(URLProtocolStub.recordedRequests.last)
        #expect(
            request.url?.absoluteString ==
            "https://ark.cn-beijing.volces.com/api/v3/chat/completions"
        )
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        let sent = try recordedRequestJSON()
        // The provider package owns the wire defaults: thinking off,
        // reasoning effort minimal.
        #expect(sent["thinking"]?.objectValue?["type"]?.stringValue == "disabled")
        #expect(sent["reasoning_effort"]?.stringValue == "minimal")
    }

    @Test func arkMapsResponseSchemaToResponseFormat() async throws {
        let body = """
        {"choices":[{"message":{"content":"{}"},"finish_reason":"stop"}]}
        """.data(using: .utf8)!
        URLProtocolStub.setStub(.init(body: body))
        let provider = VolcengineArkProvider(
            apiKey: "test-key",
            model: "ep-test",
            session: URLProtocolStub.makeSession()
        )

        _ = try await provider.complete(
            LLMRequest(
                model: "ep-test",
                messages: [.init(role: .user, text: "hi")],
                responseSchema: GeneratedContent.generationSchema
            )
        )

        let sent = try recordedRequestJSON()
        let format = sent["response_format"]?.objectValue
        #expect(format?["type"]?.stringValue == "json_schema")
        #expect(format?["json_schema"]?.objectValue?["strict"]?.boolValue == true)
        #expect(format?["json_schema"]?.objectValue?["schema"] != nil)
    }

    @Test func arkProviderUsesCustomChatCompletionsPath() async throws {
        let body = """
        {"choices":[{"message":{"content":"custom path"},"finish_reason":"stop"}]}
        """.data(using: .utf8)!
        URLProtocolStub.setStub(.init(body: body))
        let provider = VolcengineArkProvider(
            apiKey: "test-key",
            model: "ep-test",
            baseURL: URL(string: "https://ark.example.com/api/v3")!,
            chatCompletionsPath: "deployments/ep-test/chat/completions?api-version=2026-06-01",
            session: URLProtocolStub.makeSession()
        )

        let response = try await provider.complete(
            LLMRequest(model: "ep-test", messages: [.init(role: .user, text: "hi")])
        )

        #expect(response.text == "custom path")
        let request = try #require(URLProtocolStub.recordedRequests.last)
        #expect(
            request.url?.absoluteString ==
            "https://ark.example.com/api/v3/deployments/ep-test/chat/completions?api-version=2026-06-01"
        )
    }

    @Test func arkProviderAcceptsFullChatCompletionsURL() async throws {
        let body = """
        {"choices":[{"message":{"content":"ark path"},"finish_reason":"stop"}]}
        """.data(using: .utf8)!
        URLProtocolStub.setStub(.init(body: body))
        let endpoint = URL(string: "https://ark.cn-beijing.volces.com/api/v3/chat/completions")!
        let provider = VolcengineArkProvider(
            apiKey: "test-key",
            model: "ep-test",
            baseURL: endpoint,
            session: URLProtocolStub.makeSession()
        )

        let response = try await provider.complete(
            LLMRequest(model: "ep-test", messages: [.init(role: .user, text: "hi")])
        )

        #expect(response.text == "ark path")
        let request = try #require(URLProtocolStub.recordedRequests.last)
        #expect(request.url?.absoluteString == endpoint.absoluteString)
        let sent = try recordedRequestJSON()
        #expect(sent["thinking"]?.objectValue?["type"]?.stringValue == "disabled")
    }

    @Test func arkEncodesImageContentBlocks() async throws {
        let body = """
        {"choices":[{"message":{"content":"ok"},"finish_reason":"stop"}]}
        """.data(using: .utf8)!
        URLProtocolStub.setStub(.init(body: body))
        let provider = VolcengineArkProvider(
            apiKey: "test-key",
            model: "ep-test",
            session: URLProtocolStub.makeSession()
        )

        _ = try await provider.complete(LLMRequest(
            model: "ep-test",
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
        let imageURL = try #require(parts[1].objectValue?["image_url"]?.objectValue)
        #expect(parts[1].objectValue?["type"]?.stringValue == "image_url")
        #expect(imageURL["url"]?.stringValue == "data:image/png;base64,qrs=")
    }

    @Test func arkRejectsUnsupportedAudioInput() async {
        URLProtocolStub.setStub(.init(body: Data("{}".utf8)))
        let request = LLMRequest(
            model: "ep-test",
            messages: [
                Message(role: .user, content: [
                    .audio(AudioContent(data: Data([0x01]), mimeType: "audio/wav", format: .wav)),
                ]),
            ]
        )
        let provider = VolcengineArkProvider(
            apiKey: "test-key",
            model: "ep-test",
            session: URLProtocolStub.makeSession()
        )
        await #expect(throws: LLMError.self) {
            try await provider.complete(request)
        }
    }

    @Test func arkRejectsGeneratedAudioOutput() async {
        let provider = VolcengineArkProvider(
            apiKey: "test-key",
            model: "ep-test",
            session: URLProtocolStub.makeSession()
        )
        await #expect(throws: LLMError.self) {
            try await provider.complete(LLMRequest(
                model: "ep-test",
                audioOutput: AudioOutputOptions(voice: "alloy", format: .mp3)
            ))
        }
    }
}

private func recordedRequestJSON() throws -> [String: GeneratedContent] {
    let request = try #require(URLProtocolStub.recordedRequests.last)
    let body = try recordedBodyData(from: request)
    return try #require(GeneratedContent(data: body).objectValue)
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
