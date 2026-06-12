import Foundation
import FoundationModels
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
        let defaults = try makeDefaults()
        var store = AIKitProviderCredentialStore()
        store.setAPIKey("sk-ark-123", for: .ark)
        store.save(defaults: defaults)

        let loaded = AIKitProviderCredentialStore.load(defaults: defaults)
        #expect(loaded.apiKey(for: .ark) == "sk-ark-123")
    }

    @Test func clearedKeyStaysCleared() throws {
        let defaults = try makeDefaults()
        var store = AIKitProviderCredentialStore()
        store.setAPIKey("sk-ark", for: .ark)
        store.save(defaults: defaults)

        store.setAPIKey("", for: .ark)
        store.save(defaults: defaults)
        #expect(
            AIKitProviderCredentialStore.load(defaults: defaults)
                .apiKey(for: .ark).isEmpty
        )
    }

    @Test func credentialFreeProvidersStoreNothing() throws {
        let defaults = try makeDefaults()
        var store = AIKitProviderCredentialStore()
        store.setAPIKey("ignored", for: .appleIntelligence)
        store.save(defaults: defaults)

        let loaded = AIKitProviderCredentialStore.load(defaults: defaults)
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

    // MARK: Ark wire mapping through the official executor
    //
    // Drives `VolcengineArkLanguageModelExecutor` exactly the way a
    // `LanguageModelSession` does — an official generation request streamed
    // into the official channel — against the URLProtocol stub.

    private struct DrainedEvents {
        var text = ""
        var reasoning = ""
        var toolCalls: [(id: String, name: String, arguments: String)] = []
        var finishReason: String?
        var inputTokens = 0
        var outputTokens = 0
    }

    private static let endEntryID = "aikit.core-tests.end"

    private func respond(
        model: VolcengineArkLanguageModel,
        transcript: Transcript = Transcript(entries: [
            .prompt(Transcript.Prompt(segments: [
                .text(Transcript.TextSegment(content: "hi")),
            ])),
        ]),
        tools: [Transcript.ToolDefinition] = [],
        schema: GenerationSchema? = nil
    ) async throws -> DrainedEvents {
        let executor = try VolcengineArkLanguageModelExecutor(
            configuration: model.configuration,
            session: URLProtocolStub.makeSession()
        )
        let request = LanguageModelExecutorGenerationRequest(
            id: UUID(),
            transcript: transcript,
            enabledTools: tools,
            schema: schema,
            generationOptions: GenerationOptions(),
            contextOptions: ContextOptions(),
            metadata: [:]
        )
        let channel = LanguageModelExecutorGenerationChannel()
        var drained = DrainedEvents()
        var toolIndexesByID: [String: Int] = [:]

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                // The official channel has no finish event; the sentinel ends
                // the drain loop whether respond returns or throws.
                do {
                    try await executor.respond(
                        to: request, model: model, streamingInto: channel
                    )
                } catch {
                    await channel.send(.response(
                        entryID: Self.endEntryID, action: .updateMetadata([:])
                    ))
                    throw error
                }
                await channel.send(.response(
                    entryID: Self.endEntryID, action: .updateMetadata([:])
                ))
            }

            for try await event in channel {
                if let response = event as? LanguageModelExecutorGenerationChannel.Response {
                    if response.entryID == Self.endEntryID { break }
                    switch response.action {
                    case .appendText(let fragment):
                        drained.text += fragment.content
                    case .updateMetadata(let metadata):
                        if let reason = metadata.values["finishReason"] as? String {
                            drained.finishReason = reason
                        }
                    case .updateUsage(let usage):
                        drained.inputTokens = usage.input.totalTokenCount
                        drained.outputTokens = usage.output.totalTokenCount
                    default:
                        continue
                    }
                } else if let reasoning = event as? LanguageModelExecutorGenerationChannel.Reasoning {
                    if case .appendText(let fragment) = reasoning.action {
                        drained.reasoning += fragment.content
                    }
                } else if let toolCalls = event as? LanguageModelExecutorGenerationChannel.ToolCalls {
                    if case .toolCall(let call) = toolCalls.action {
                        if toolIndexesByID[call.id] == nil {
                            toolIndexesByID[call.id] = drained.toolCalls.count
                            drained.toolCalls.append((id: call.id, name: call.name, arguments: ""))
                        }
                        if case .appendArguments(let fragment) = call.action,
                           let index = toolIndexesByID[call.id] {
                            drained.toolCalls[index].arguments += fragment.content
                        }
                    }
                }
            }
            try await group.next()
        }
        return drained
    }

    private func makeModel() -> VolcengineArkLanguageModel {
        VolcengineArkLanguageModel(apiKey: "test-key", model: "ep-test")
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
        let sse = """
        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"navigate","arguments":"{"}}]},"finish_reason":null}]}

        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\\"destination\\""}}]},"finish_reason":null}]}

        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":":\\"settings\\"}"}}]},"finish_reason":"tool_calls"}]}

        data: [DONE]
        """.data(using: .utf8)!
        URLProtocolStub.setStub(.init(body: sse))

        let drained = try await respond(model: makeModel())

        #expect(drained.toolCalls.map(\.id) == ["call_1"])
        #expect(drained.toolCalls.map(\.name) == ["navigate"])
        #expect(drained.toolCalls.first?.arguments == "{\"destination\":\"settings\"}")
        #expect(drained.finishReason == "tool_calls")
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
        let imageURL = try #require(URL(string: "data:image/png;base64,qrs="))
        let transcript = Transcript(entries: [
            .prompt(Transcript.Prompt(segments: [
                .text(Transcript.TextSegment(content: "What is shown?")),
                .attachment(Transcript.AttachmentSegment(
                    content: .image(Transcript.ImageAttachment(imageURL: imageURL))
                )),
            ])),
        ])

        _ = try await respond(model: makeModel(), transcript: transcript)

        let sent = try recordedRequestJSON()
        let messages = try #require(sent["messages"]?.arrayValue)
        let message = try #require(messages.first?.objectValue)
        let parts = try #require(message["content"]?.arrayValue)
        let image = try #require(parts[1].objectValue?["image_url"]?.objectValue)
        #expect(parts[1].objectValue?["type"]?.stringValue == "image_url")
        #expect(image["url"]?.stringValue == "data:image/png;base64,qrs=")
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
