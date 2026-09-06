import AIKitProviders
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Foundation
import FoundationModels
import Synchronization
import Testing
import AIToolKit
import VolcengineArkFoundationModels
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
        #expect(manifest.contains(".iOS(\"27.0\")"))
        #expect(manifest.contains(".macOS(\"27.0\")"))
        #expect(manifest.contains(".visionOS(\"27.0\")"))
    }
}

@Suite struct GeneratedContentValueTests {
    @Test func roundTrip() throws {
        let value: GeneratedContent = .object([
            "name": .string("navigate"),
            "count": .number(3),
            "flag": .bool(true),
            "nested": .array([.string("a"), .nullContent]),
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
}

@Suite struct ProviderCatalogTests {
    @Test func providerDefinitionsExposeDashboardMetadata() {
        #expect(AIKitProviderDefinition.all.map(\.kind) == [
            .ark,
            .appleIntelligence,
        ])
        #expect(AIKitProviderDefinition.ark.displayName == "Volcengine Ark")
        #expect(AIKitProviderDefinition.ark.apiKeyStrategy == .bearerToken)
        #expect(AIKitProviderDefinition.ark.apiKeyStrategy.requiresCredential)
        #expect(AIKitProviderDefinition.ark.supportsModelCatalogRefresh)
        #expect(AIKitProviderDefinition.appleIntelligence.displayName == "Apple Intelligence")
        #expect(AIKitProviderDefinition.appleIntelligence.apiKeyStrategy == .none)
        #expect(AIKitProviderDefinition.appleIntelligence.staticModelIDs == [
            "apple-intelligence",
            "private-cloud-compute",
        ])
        #expect(!AIKitProviderDefinition.appleIntelligence.supportsModelCatalogRefresh)
        #expect(AIKitProviderKind(providerName: "Other") == nil)
        #expect(AIKitProviderKind(providerName: "Doubao") == nil)
        #expect(AIKitProviderKind(providerName: "Volcengine Ark") == .ark)
        #expect(AIKitProviderKind(providerName: "Apple Intelligence") == .appleIntelligence)
    }
}

@Suite struct LanguageModelSelectionTests {
    @Test func resolvesAppleIntelligenceEndpoints() throws {
        let onDevice = try AIKitLanguageModel.resolve(
            provider: .appleIntelligence, modelID: nil
        )
        #expect(onDevice.modelID == "apple-intelligence")
        #expect(onDevice.providerKind == .appleIntelligence)

        let explicit = try AIKitLanguageModel.resolve(
            provider: .appleIntelligence, modelID: "apple-intelligence"
        )
        #expect(explicit.modelID == "apple-intelligence")

        let cloud = try AIKitLanguageModel.resolve(
            provider: .appleIntelligence, modelID: "private-cloud-compute"
        )
        #expect(cloud.modelID == "private-cloud-compute")
        #expect(cloud.providerKind == .appleIntelligence)
    }

    @Test func rejectsUnknownAppleModel() {
        #expect(throws: AIKitModelResolutionError.unknownModel(
            .appleIntelligence, modelID: "gpt-4"
        )) {
            try AIKitLanguageModel.resolve(
                provider: .appleIntelligence, modelID: "gpt-4"
            )
        }
    }

    @Test func resolvesArkModelWithCredential() throws {
        let model = try AIKitLanguageModel.resolve(
            provider: .ark, modelID: "doubao-seed-2-0-lite-260215", apiKey: "sk-ark"
        )
        #expect(model.modelID == "doubao-seed-2-0-lite-260215")
        #expect(model.providerKind == .ark)
        #expect(model.isAvailable)
        #expect(model.capabilities.contains(.toolCalling))
        guard case .volcengineArk(let ark) = model else {
            Issue.record("Expected a Volcengine Ark model")
            return
        }
        #expect(ark.configuration.apiKey == "sk-ark")
    }

    @Test func arkRequiresCredentialAndModel() {
        #expect(throws: AIKitModelResolutionError.missingAPIKey(.ark)) {
            try AIKitLanguageModel.resolve(provider: .ark, modelID: "m", apiKey: " ")
        }
        #expect(throws: AIKitModelResolutionError.missingModel(.ark)) {
            try AIKitLanguageModel.resolve(provider: .ark, modelID: nil, apiKey: "k")
        }
    }

    @Test func resolvesThroughCredentialStore() throws {
        var credentials = AIKitProviderCredentialStore()
        credentials.setAPIKey("sk-store", for: .ark)
        let model = try AIKitLanguageModel.resolve(
            provider: .ark, modelID: "ep-test", credentials: credentials
        )
        guard case .volcengineArk(let ark) = model else {
            Issue.record("Expected a Volcengine Ark model")
            return
        }
        #expect(ark.configuration.apiKey == "sk-store")
    }

    @Test func arkAvailabilityReflectsConfiguration() {
        let missingKey = AIKitLanguageModel.volcengineArk(
            VolcengineArkLanguageModel(apiKey: " ", model: "ep-test")
        )
        #expect(!missingKey.isAvailable)
        guard case .unavailable(let reason) = missingKey.availability else {
            Issue.record("Expected unavailable")
            return
        }
        #expect(reason.contains("API key"))
    }

    @Test func arkSessionsComeFromTheOfficialInitializer() async throws {
        // The session is the official entry point for any model; the enum
        // only constructs it. A scripted mock proves the same path end to
        // end below — here the Ark model must at least produce a session
        // carrying the instructions.
        let model = AIKitLanguageModel.volcengineArk(apiKey: "k", model: "ep-test")
        let session = model.makeSession(instructions: Instructions("Be brief."))
        #expect(!session.isResponding)
    }
}

@Suite struct ProviderCredentialStoreTests {
    /// Fresh, isolated defaults per test; the suite name is unique so tests
    /// can't see each other's writes or the real app domain.
    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "AIKitCredentialTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test func savedKeyRoundTrips() throws {
        let storage = AIKitInMemoryCredentialStorage()
        var store = AIKitProviderCredentialStore()
        store.setAPIKey("sk-ark-123", for: .ark)
        try store.save(storage: storage)

        let loaded = try AIKitProviderCredentialStore.load(storage: storage, migrating: nil)
        #expect(loaded.apiKey(for: .ark) == "sk-ark-123")
    }

    @Test func clearedKeyStaysCleared() throws {
        let storage = AIKitInMemoryCredentialStorage()
        var store = AIKitProviderCredentialStore()
        store.setAPIKey("sk-ark", for: .ark)
        try store.save(storage: storage)

        store.setAPIKey("", for: .ark)
        try store.save(storage: storage)
        #expect(
            try AIKitProviderCredentialStore.load(storage: storage, migrating: nil)
                .apiKey(for: .ark).isEmpty
        )
    }

    @Test func credentialFreeProvidersStoreNothing() throws {
        let storage = AIKitInMemoryCredentialStorage()
        var store = AIKitProviderCredentialStore()
        store.setAPIKey("ignored", for: .appleIntelligence)
        try store.save(storage: storage)

        let loaded = try AIKitProviderCredentialStore.load(storage: storage, migrating: nil)
        #expect(loaded.apiKey(for: .appleIntelligence).isEmpty)
    }
}

// MARK: - Mock model through a real session

private struct EchoTool: Tool {
    @Generable
    struct Input {
        var text: String
    }

    let name = "echo"
    let description = "Echoes its input."

    func call(arguments input: Input) async throws -> String {
        "echo: \(input.text)"
    }
}

@Suite struct MockLanguageModelSessionTests {
    @Test func sessionReturnsScriptedText() async throws {
        let model = MockLanguageModel(finalText: "hello world")
        let session = LanguageModelSession(model: model, instructions: "Be brief.")
        let response = try await session.respond(to: "hi")
        #expect(response.content == "hello world")
        #expect(model.receivedRequests.count == 1)
    }

    @Test func sessionRunsScriptedToolCallsNatively() async throws {
        let model = MockLanguageModel(turns: [
            .init(toolCalls: [.init(
                name: "echo",
                argumentsJSON: #"{"text":"ping"}"#
            )]),
            .init(text: "done"),
        ])
        let session = LanguageModelSession(model: model, tools: [EchoTool()])
        let response = try await session.respond(to: "go")
        #expect(response.content == "done")
        // Round 2's transcript must carry the tool call and its output.
        let second = try #require(model.receivedRequests.last)
        let hasToolOutput = second.transcript.contains { entry in
            if case .toolOutput = entry { return true }
            return false
        }
        #expect(hasToolOutput)
    }

    @Test func streamingSnapshotsAccumulate() async throws {
        let model = MockLanguageModel(turns: [
            .init(text: "streamed answer", inputTokens: 7, outputTokens: 3)
        ])
        let session = LanguageModelSession(model: model)
        var last = ""
        for try await snapshot in session.streamResponse(to: "hi") {
            last = snapshot.content
        }
        #expect(last == "streamed answer")
    }

    @Test func usageReachesTheSessionSurface() async throws {
        let model = MockLanguageModel(turns: [
            .init(text: "ok", inputTokens: 11, outputTokens: 4)
        ])
        let session = LanguageModelSession(model: model)
        let response = try await session.respond(to: "hi")
        #expect(response.usage.input.totalTokenCount == 11)
        #expect(response.usage.output.totalTokenCount == 4)
    }

    /// Documents the official usage semantics consumers must respect:
    /// `Response.usage` carries ONLY the final model call of a turn, while
    /// `session.usage` accumulates every call over the session's lifetime.
    /// Anything accounting a whole turn (tool rounds included) must read
    /// the session surface — AIKit's orchestrator depends on this split.
    @Test func responseUsageIsLastCallSessionUsageAccumulates() async throws {
        let model = MockLanguageModel(turns: [
            .init(toolCalls: [.init(
                id: "t1", name: "echo", argumentsJSON: #"{"text":"ping"}"#
            )], inputTokens: 100, outputTokens: 10),
            .init(text: "done", inputTokens: 200, outputTokens: 20),
        ])
        let session = LanguageModelSession(model: model, tools: [EchoTool()])
        let response = try await session.respond(to: "go")
        #expect(response.content == "done")
        #expect(response.usage.input.totalTokenCount == 200)
        #expect(response.usage.output.totalTokenCount == 20)
        #expect(session.usage.input.totalTokenCount == 300)
        #expect(session.usage.output.totalTokenCount == 30)
    }

    @Test func exhaustionSurfaces() async throws {
        let model = MockLanguageModel(finalText: "once")
        let session = LanguageModelSession(model: model)
        _ = try await session.respond(to: "first")
        let second = LanguageModelSession(model: model)
        await #expect(throws: (any Error).self) {
            try await second.respond(to: "again")
        }
    }

    @Test func scriptedFailureSurfaces() async throws {
        let model = MockLanguageModel(results: [
            .failure(LanguageModelError.rateLimited(.init(
                resetDate: nil, debugDescription: "slow down"
            ))),
        ])
        let session = LanguageModelSession(model: model)
        await #expect(throws: (any Error).self) {
            try await session.respond(to: "hi")
        }
    }
}

// MARK: - HTTP-stub tests (model catalog + Ark executor wire mapping)
//
// The URLProtocol stub is process-global, so every test that touches it
// lives in this one serialized suite.

@Suite(.serialized) struct HTTPStubTests {
    @Test func fetchesArkModels() async throws {
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

    @Test func arkModelListRequiresAPIKey() async {
        let catalog = AIKitModelCatalog(session: URLProtocolStub.makeSession())

        await #expect(throws: AIKitModelCatalogError.missingAPIKey) {
            try await catalog.fetchModels(for: .ark)
        }
    }

    @Test func appleIntelligenceListIsStatic() async throws {
        URLProtocolStub.setStub(nil)
        let catalog = AIKitModelCatalog(session: URLProtocolStub.makeSession())

        let models = try await catalog.fetchModels(for: .appleIntelligence)

        #expect(models == ["apple-intelligence", "private-cloud-compute"])
        #expect(URLProtocolStub.recordedRequests.isEmpty)
    }

    @Test func httpErrorSurfacesTyped() async {
        URLProtocolStub.setStub(.init(statusCode: 503, body: Data("down".utf8)))
        let catalog = AIKitModelCatalog(session: URLProtocolStub.makeSession())

        await #expect(throws: AIKitModelCatalogError.httpStatus(code: 503, body: "down")) {
            try await catalog.fetchModels(for: .ark, apiKey: "k")
        }
    }

    // MARK: Ark wire mapping through the official session
    //
    // Drives the provider exactly the way production does — a public
    // `LanguageModelSession` over `VolcengineArkLanguageModel` — against the
    // URLProtocol stub, registered process-globally so the executor's default
    // transport resolves to it. Assertions read only public surfaces: the
    // response content, the official transcript, and usage. The generation
    // channel's event representation is the framework's private business.

    private struct SessionOutcome {
        var text = ""
        var reasoning = ""
        var toolCalls: [(name: String, arguments: GeneratedContent)] = []
        var finishReason: String?
        var inputTokens = 0
        var outputTokens = 0
    }

    private func respond(
        model: VolcengineArkLanguageModel,
        prompt: Prompt = Prompt("hi"),
        tools: [any Tool] = [],
        schema: GenerationSchema? = nil,
        history: [Transcript.Entry] = []
    ) async throws -> SessionOutcome {
        URLProtocolStub.registerGlobally()
        defer { URLProtocolStub.unregisterGlobally() }
        let session = LanguageModelSession(
            model: model, tools: tools, transcript: Transcript(entries: history)
        )

        var outcome = SessionOutcome()
        let usage: LanguageModelSession.Usage
        if let schema {
            usage = try await session.respond(to: prompt, schema: schema).usage
        } else {
            let response = try await session.respond(to: prompt)
            outcome.text = response.content
            usage = response.usage
        }
        outcome.inputTokens = usage.input.totalTokenCount
        outcome.outputTokens = usage.output.totalTokenCount

        // The session's transcript carries every entry of the turn — all
        // rounds included, which a final response's `transcriptEntries`
        // slice is not guaranteed to.
        for entry in session.transcript {
            switch entry {
            case .reasoning(let reasoning):
                outcome.reasoning += reasoning.segments.compactMap { segment in
                    guard case .text(let text) = segment else { return nil }
                    return text.content
                }.joined()
            case .toolCalls(let calls):
                for call in calls {
                    outcome.toolCalls.append(
                        (name: call.toolName, arguments: call.arguments)
                    )
                }
            case .response(let response):
                if let reason = try? response.metadata["finishReason"]?.value(String.self) {
                    outcome.finishReason = reason
                }
            default:
                break
            }
        }
        return outcome
    }


    /// Declares the full capability set: the session gates guided generation
    /// and image input on the model's declared capabilities before anything
    /// reaches the wire, and these tests exercise exactly those wire paths.
    private func makeModel() -> VolcengineArkLanguageModel {
        VolcengineArkLanguageModel(
            apiKey: "test-key",
            model: "ep-test",
            capabilities: LanguageModelCapabilities(
                [.toolCalling, .reasoning, .guidedGeneration, .vision]
            )
        )
    }

    @Test func malformedProviderStreamCannotSucceedWithPartialText() async {
        let wire = "data: {\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}\n\ndata: invalid\n\n"
        URLProtocolStub.setStub(.init(body: Data(wire.utf8)))
        await #expect(throws: (any Error).self) {
            try await respond(model: makeModel())
        }
    }

    @Test func emptyToolOutputRetainsItsProtocolMessage() async throws {
        let call = #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"empty_1","function":{"name":"empty_output","arguments":"{\"destination\":\"settings\"}"}}]},"finish_reason":"tool_calls"}]}"# + "\n\ndata: [DONE]\n\n"
        let final = #"data: {"choices":[{"delta":{"content":"done"},"finish_reason":"stop"}]}"# + "\n\ndata: [DONE]\n\n"
        URLProtocolStub.setStubs([.init(body: Data(call.utf8)), .init(body: Data(final.utf8))])
        _ = try await respond(model: makeModel(), tools: [EmptyOutputTool()])
        let body = try recordedRequestJSON()
        let messages = try #require(body["messages"]?.arrayValue)
        #expect(messages.contains { $0.objectValue?["role"]?.stringValue == "tool" })
    }

    @Test func streamsTextFinishReasonAndUsage() async throws {
        let sse = """
        data: {"choices":[{"delta":{"content":"hello"},"finish_reason":null}]}

        data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

        data: {"choices":[],"usage":{"prompt_tokens":11,"completion_tokens":4}}

        data: [DONE]
        """.data(using: .utf8)!
        URLProtocolStub.setStub(.init(body: sse))

        let drained = try await respond(model: makeModel())

        #expect(drained.text == "hello")
        #expect(drained.finishReason == "stop")
        #expect(drained.inputTokens == 11)
        #expect(drained.outputTokens == 4)
    }

    @Test func streamsToolCallArgumentOnlyDeltas() async throws {
        let toolCallSSE = """
        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"navigate","arguments":"{"}}]},"finish_reason":null}]}

        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\\"destination\\""}}]},"finish_reason":null}]}

        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":":\\"settings\\"}"}}]},"finish_reason":"tool_calls"}]}

        data: [DONE]
        """.data(using: .utf8)!
        let finalSSE = """
        data: {"choices":[{"delta":{"content":"done"},"finish_reason":"stop"}]}

        data: [DONE]
        """.data(using: .utf8)!
        URLProtocolStub.setStubs([.init(body: toolCallSSE), .init(body: finalSSE)])
        let destinations = Mutex<[String]>([])
        let tool = StubNavigateTool { destination in
            destinations.withLock { $0.append(destination) }
        }

        let outcome = try await respond(model: makeModel(), tools: [tool])

        // The argument-only deltas assembled into one decodable object and
        // the session executed the tool with it — the full native loop.
        #expect(destinations.withLock { $0 } == ["settings"])
        #expect(outcome.toolCalls.map(\.name) == ["navigate"])
        let arguments = try #require(outcome.toolCalls.first?.arguments.objectValue)
        #expect(arguments["destination"]?.stringValue == "settings")
        #expect(outcome.text == "done")
        #expect(outcome.finishReason == "stop")
    }

    @Test func streamsReasoningSeparately() async throws {
        let sse = """
        data: {"choices":[{"delta":{"reasoning_content":"hmm "},"finish_reason":null}]}

        data: {"choices":[{"delta":{"reasoning_content":"ok"},"finish_reason":null}]}

        data: {"choices":[{"delta":{"content":"answer"},"finish_reason":"stop"}]}

        data: [DONE]
        """.data(using: .utf8)!
        URLProtocolStub.setStub(.init(body: sse))

        let drained = try await respond(model: makeModel())

        #expect(drained.reasoning == "hmm ok")
        #expect(drained.text == "answer")
    }

    @Test func sendsDefaultEndpointAuthAndWireDefaults() async throws {
        let sse = """
        data: {"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}

        data: [DONE]
        """.data(using: .utf8)!
        URLProtocolStub.setStub(.init(body: sse))

        _ = try await respond(model: makeModel())

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

    @Test func mapsSchemaToResponseFormat() async throws {
        let sse = """
        data: {"choices":[{"delta":{"content":"{}"},"finish_reason":"stop"}]}

        data: [DONE]
        """.data(using: .utf8)!
        URLProtocolStub.setStub(.init(body: sse))

        _ = try await respond(
            model: makeModel(),
            schema: GeneratedContent.generationSchema
        )

        let sent = try recordedRequestJSON()
        let format = sent["response_format"]?.objectValue
        #expect(format?["type"]?.stringValue == "json_schema")
        #expect(format?["json_schema"]?.objectValue?["strict"]?.boolValue == true)
        #expect(format?["json_schema"]?.objectValue?["schema"] != nil)
    }

    @Test func usesCustomChatCompletionsPath() async throws {
        let sse = """
        data: {"choices":[{"delta":{"content":"custom path"},"finish_reason":"stop"}]}

        data: [DONE]
        """.data(using: .utf8)!
        URLProtocolStub.setStub(.init(body: sse))
        let model = VolcengineArkLanguageModel(configuration: .init(
            apiKey: "test-key",
            model: "ep-test",
            baseURL: URL(string: "https://ark.example.com/api/v3")!,
            chatCompletionsPath: "deployments/ep-test/chat/completions?api-version=2026-06-01"
        ))

        let drained = try await respond(model: model)

        #expect(drained.text == "custom path")
        let request = try #require(URLProtocolStub.recordedRequests.last)
        #expect(
            request.url?.absoluteString ==
            "https://ark.example.com/api/v3/deployments/ep-test/chat/completions?api-version=2026-06-01"
        )
    }

    @Test func rateLimitSurfacesAsOfficialError() async {
        URLProtocolStub.setStub(.init(statusCode: 429, body: Data("slow down".utf8)))

        await #expect(throws: LanguageModelError.self) {
            _ = try await respond(model: makeModel())
        }
    }

    @Test func serverErrorSurfacesAsArkError() async {
        URLProtocolStub.setStub(.init(statusCode: 500, body: Data("boom".utf8)))

        await #expect(throws: VolcengineArkError.self) {
            _ = try await respond(model: makeModel())
        }
    }

    @Test func encodesImageAttachmentSegments() async throws {
        let sse = """
        data: {"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}

        data: [DONE]
        """.data(using: .utf8)!
        URLProtocolStub.setStub(.init(body: sse))
        let imageURL = FileManager.default.temporaryDirectory.appendingPathComponent("aikit-image-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: imageURL) }
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let pixels = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(imageURL as CFURL,
            UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, pixels, nil)
        #expect(CGImageDestinationFinalize(destination))
        // The framework loads even historical attachments. Use a valid local
        // image so this test never relies on network or data-URL loading.
        let history: [Transcript.Entry] = [
            .prompt(Transcript.Prompt(segments: [
                .text(Transcript.TextSegment(content: "What is shown?")),
                .attachment(Transcript.AttachmentSegment(
                    content: .image(Transcript.ImageAttachment(imageURL: imageURL))
                )),
            ])),
            .response(Transcript.Response(assetIDs: [], segments: [
                .text(Transcript.TextSegment(content: "A test image.")),
            ])),
        ]

        _ = try await respond(model: makeModel(), history: history)

        let sent = try recordedRequestJSON()
        let messages = try #require(sent["messages"]?.arrayValue)
        let message = try #require(messages.first?.objectValue)
        let parts = try #require(message["content"]?.arrayValue)
        let image = try #require(parts[1].objectValue?["image_url"]?.objectValue)
        #expect(parts[1].objectValue?["type"]?.stringValue == "image_url")
        #expect(image["url"]?.stringValue?.hasPrefix("data:image/jpeg;base64,") == true)
    }

    @Test func inlinesInMemoryImageAttachmentsAsBase64() async throws {
        let sse = """
        data: {"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}

        data: [DONE]
        """.data(using: .utf8)!
        URLProtocolStub.setStub(.init(body: sse))

        // A CGImage-backed attachment has no `url`; the provider must inline
        // its pixels as a base64 `data:` URL instead of dropping the image to
        // a text description (which left vision models blind).
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let cgImage = try #require(context.makeImage())
        let prompt = Prompt {
            "What is shown?"
            Attachment(cgImage)
        }

        _ = try await respond(model: makeModel(), prompt: prompt)

        let sent = try recordedRequestJSON()
        let messages = try #require(sent["messages"]?.arrayValue)
        let message = try #require(messages.first?.objectValue)
        let parts = try #require(message["content"]?.arrayValue)
        #expect(parts[1].objectValue?["type"]?.stringValue == "image_url")
        let image = try #require(parts[1].objectValue?["image_url"]?.objectValue)
        let url = try #require(image["url"]?.stringValue)
        #expect(url.hasPrefix("data:image/jpeg;base64,"))
        #expect(url.count > "data:image/jpeg;base64,".count)
    }
}

private struct EmptyOutputTool: Tool {
    typealias Arguments = StubNavigateTool.Arguments
    let name = "empty_output"
    let description = "A tool with an empty successful output."
    func call(arguments: Arguments) async throws -> String { "" }
}

/// Records the destinations the model navigated to, so the tool-call tests
/// can assert the assembled argument deltas decoded correctly.
private struct StubNavigateTool: Tool {
    @Generable
    struct Arguments {
        let destination: String
    }

    @Generable
    struct Output {
        let navigated: Bool
    }

    var name: String { "navigate" }
    var description: String { "Navigate to a destination in the app." }

    let record: @Sendable (String) -> Void

    func call(arguments: Arguments) async throws -> Output {
        record(arguments.destination)
        return Output(navigated: true)
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

@Suite struct CredentialMigrationTests {
    private struct UnavailableStorage: AIKitCredentialStorage {
        func read() -> Data? { nil }
        func write(_ data: Data) throws { throw AIKitCredentialError.keychainStatus(-1) }
    }

    @Test func preferencesRemovedOnlyAfterSecureWrite() throws {
        let name = "AIKitMigration-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let old = try JSONEncoder().encode(["Ark": "test-key"])
        defaults.set(old, forKey: "AIKitProviderAPIKeys")
        #expect(throws: AIKitCredentialError.self) {
            try AIKitProviderCredentialStore.load(storage: UnavailableStorage(), migrating: defaults)
        }
        #expect(defaults.data(forKey: "AIKitProviderAPIKeys") == old)
        let storage = AIKitInMemoryCredentialStorage()
        let migrated = try AIKitProviderCredentialStore.load(storage: storage, migrating: defaults)
        #expect(migrated.apiKey(for: .ark) == "test-key")
        #expect(defaults.object(forKey: "AIKitProviderAPIKeys") == nil)
        #expect(try AIKitProviderCredentialStore.load(storage: storage, migrating: nil) == migrated)
    }

    @Test func existingSecureCredentialWinsMigration() throws {
        let name = "AIKitMigration-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(try JSONEncoder().encode(["Ark": "stale-key"]), forKey: "AIKitProviderAPIKeys")
        let storage = AIKitInMemoryCredentialStorage()
        try AIKitProviderCredentialStore(apiKeys: [.ark: "current-key"]).save(storage: storage)
        let migrated = try AIKitProviderCredentialStore.load(storage: storage, migrating: defaults)
        #expect(migrated.apiKey(for: .ark) == "current-key")
    }
}
