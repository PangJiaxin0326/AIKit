import Foundation
import Testing
@testable import AIKitRuntime
import AIKitCore
import AIKitCapability
import AIKitSafety
import AIKitTestSupport

@Suite struct PromptBuilderTests {
    @Test func systemPromptIncludesPreambleFragmentAndMemory() {
        let context = ResolvedContext(
            stack: [.init("home")],
            systemPromptFragment: "Home screen rules.",
            toolNames: ["navigate"],
            metadata: [:]
        )
        let memory = [UsageEvent(viewID: .init("home"), kind: .userInstruction, text: "go home")]
        let request = PromptBuilder.build(
            instruction: "Take me home",
            context: context,
            memory: memory,
            transcript: [],
            toolManifest: [
                ToolDescriptor(name: "navigate", description: "nav", inputSchema: .object([:])),
                ToolDescriptor(name: "other", description: "x", inputSchema: .object([:])),
            ],
            model: "test-model"
        )
        #expect(request.system?.contains(PromptBuilder.basePreamble) == true)
        #expect(request.system?.contains("Home screen rules.") == true)
        #expect(request.system?.contains("<recent-actions>") == true)
        #expect(request.tools.map(\.name) == ["navigate"])
        #expect(request.messages.first?.role == .user)
    }

    @Test func emptyContextDoesNotExposeTools() {
        let request = PromptBuilder.build(
            instruction: "Take me home",
            context: .empty,
            memory: [],
            transcript: [],
            toolManifest: [
                ToolDescriptor(name: "navigate", description: "nav", inputSchema: .object([:])),
            ],
            model: "test-model",
            toolCallFallbackHint: true
        )
        #expect(request.tools.isEmpty)
        #expect(request.system?.contains(PromptBuilder.toolFallbackInstruction) == false)
    }
}

@Suite struct OutputParserTests {
    @Test func parsesFinalText() throws {
        let response = LLMResponse(content: [.text("all done")], stopReason: .endTurn)
        #expect(try OutputParser.parse(response) == .final("all done"))
    }

    @Test func parsesToolCalls() throws {
        let response = LLMResponse(
            content: [.toolUse(id: "1", name: "navigate", input: .object(["to": .string("x")]))],
            stopReason: .toolUse
        )
        guard case .toolCalls(let calls) = try OutputParser.parse(response) else {
            Issue.record("expected toolCalls")
            return
        }
        #expect(calls.first?.name == "navigate")
    }

    @Test func emptyResponseThrows() {
        #expect(throws: OutputParser.ParserError.self) {
            try OutputParser.parse(LLMResponse(content: [], stopReason: .endTurn))
        }
    }

    @Test func recoversFencedToolCallFallback() throws {
        let text = "I'll handle that.\n```tool\n"
            + "{\"name\":\"navigate\",\"input\":{\"destination\":\"home\"}}\n```"
        let response = LLMResponse(content: [.text(text)], stopReason: .endTurn)
        guard case .mixed(let narration, let calls) = try OutputParser.parse(
            response, allowToolCallFallback: true
        ) else {
            Issue.record("expected mixed")
            return
        }
        #expect(narration == "I'll handle that.")
        #expect(calls.first?.name == "navigate")
        #expect(calls.first?.input.objectValue?["destination"]?.stringValue == "home")
    }

    @Test func fallbackDisabledTreatsFenceAsText() throws {
        let text = "```tool\n{\"name\":\"x\",\"input\":{}}\n```"
        let response = LLMResponse(content: [.text(text)], stopReason: .endTurn)
        guard case .final = try OutputParser.parse(response) else {
            Issue.record("expected final text when fallback is off")
            return
        }
    }

    @Test func malformedFencedToolCallThrows() {
        let text = "```tool\n{\"name\": oops \n```"
        let response = LLMResponse(content: [.text(text)], stopReason: .endTurn)
        #expect(throws: OutputParser.ParserError.self) {
            try OutputParser.parse(response, allowToolCallFallback: true)
        }
    }

    @Test func malformedNativeToolInputSentinelThrowsWithRaw() {
        let raw = "{\"destination\":"
        let response = LLMResponse(
            content: [.toolUse(
                id: "t1",
                name: "navigate",
                input: .object(["__aikit_malformed_tool_input_raw": .string(raw)])
            )],
            stopReason: .toolUse
        )

        do {
            _ = try OutputParser.parse(response)
            Issue.record("expected malformed tool input")
        } catch OutputParser.ParserError.malformedToolInput(let name, let rawValue) {
            #expect(name == "navigate")
            #expect(rawValue == raw)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func roundTripRandomToolCalls() throws {
        for _ in 0..<50 {
            let name = "tool_\(Int.random(in: 0...999))"
            let input: JSONValue = .object([
                "n": .number(Double(Int.random(in: 0...100))),
                "s": .string(UUID().uuidString),
            ])
            let response = LLMResponse(
                content: [.toolUse(id: UUID().uuidString, name: name, input: input)],
                stopReason: .toolUse
            )
            guard case .toolCalls(let calls) = try OutputParser.parse(response) else {
                Issue.record("expected toolCalls")
                return
            }
            #expect(calls.first?.name == name)
            #expect(calls.first?.input == input)
        }
    }
}

@Suite struct RetryPolicyTests {
    @Test func exponentialBackoffCaps() {
        let backoff = RetryPolicy.Backoff.exponential(base: 0.4, cap: 4.0)
        #expect(backoff.delay(forAttempt: 1) == 0.4)
        #expect(backoff.delay(forAttempt: 2) == 0.8)
        #expect(backoff.delay(forAttempt: 10) == 4.0)
    }

    @Test func classifierCategories() {
        #expect(ErrorClassifier.category(of: LLMError.httpStatus(code: 503, body: "")) == .transient)
        #expect(ErrorClassifier.category(of: LLMError.httpStatus(code: 400, body: "")) == .fatal)
        #expect(ErrorClassifier.category(of: GuardrailViolation(railID: "r", stage: .preToolUse, reason: "x")) == .guardrailViolation)
        #expect(ErrorClassifier.category(of: OutputParser.ParserError.empty) == .malformedOutput)
        #expect(ErrorClassifier.category(of: ToolRegistryError.decodingFailed(name: "navigate", detail: "bad type")) == .malformedOutput)
        #expect(ErrorClassifier.category(of: GenericToolError(message: "x", isRetriable: true)) == .toolRetriable)
    }

    @Test func handlerAbortsGuardrail() async {
        let handler = ErrorHandler()
        let decision = await handler.handle(
            GuardrailViolation(railID: "r", stage: .preToolUse, reason: "blocked"),
            attempt: 1,
            policy: .default
        )
        guard case .abort = decision else {
            Issue.record("expected abort")
            return
        }
    }

    @Test func handlerFallsBackOnMalformed() async {
        let handler = ErrorHandler()
        let decision = await handler.handle(
            OutputParser.ParserError.malformedToolInput(name: "navigate", raw: "{"),
            attempt: 1,
            policy: .default
        )
        guard case .fallback(let prompt) = decision else {
            Issue.record("expected fallback")
            return
        }
        #expect(prompt.contains("navigate"))
    }
}

@Suite struct OrchestratorTests {
    private func makeOrchestrator(
        provider: MockProvider,
        guardrails: PolicyEngine = PolicyEngine()
    ) async -> Orchestrator {
        let registry = ToolRegistry()
        await registry.register(NavigateTool { input, _ in
            .init(navigated: input.destination == "settings")
        })
        let resolver = ContextResolver()
        await resolver.push(ViewContext(
            id: .init("home"),
            displayName: "Home",
            systemPromptFragment: "You can navigate.",
            toolNames: ["navigate"]
        ))
        return Orchestrator(
            llm: LLMClient(provider: provider),
            tools: registry,
            memory: InMemoryMemoryStore(),
            contextResolver: resolver,
            guardrails: guardrails,
            options: .init(model: "test", stream: false)
        )
    }

    @Test func endToEndToolThenFinal() async throws {
        let provider = MockProvider(responses: [
            LLMResponse(
                content: [.toolUse(
                    id: "t1", name: "navigate",
                    input: .object(["destination": .string("settings")])
                )],
                stopReason: .toolUse
            ),
            LLMResponse(content: [.text("You're on settings now.")], stopReason: .endTurn),
        ])
        let orchestrator = await makeOrchestrator(provider: provider)

        var toolCalled = false
        var finalAnswer: String?
        for try await event in await orchestrator.run("Go to settings") {
            switch event {
            case .toolCall(let name, _): toolCalled = (name == "navigate")
            case .finalAnswer(let text): finalAnswer = text
            case .error(let error): Issue.record("unexpected error: \(error)")
            default: break
            }
        }
        #expect(toolCalled)
        #expect(finalAnswer == "You're on settings now.")
    }

    @Test func malformedToolInputCorrectedOnSecondAttemptWithoutOrphanToolMessage() async throws {
        let registry = ToolRegistry()
        await registry.register(NavigateTool { input, _ in
            .init(navigated: input.destination == "settings")
        })
        let resolver = ContextResolver()
        await resolver.push(ViewContext(
            id: .init("home"), displayName: "Home", toolNames: ["navigate"]
        ))
        let provider = MockProvider(responses: [
            LLMResponse(content: [.toolUse(
                id: "bad", name: "navigate",
                input: .object(["destination": .number(42)])
            )], stopReason: .toolUse),
            LLMResponse(content: [.toolUse(
                id: "good", name: "navigate",
                input: .object(["destination": .string("settings")])
            )], stopReason: .toolUse),
            LLMResponse(content: [.text("Recovered.")], stopReason: .endTurn),
        ])
        let orchestrator = Orchestrator(
            llm: LLMClient(provider: provider),
            tools: registry,
            memory: InMemoryMemoryStore(),
            contextResolver: resolver,
            guardrails: PolicyEngine(),
            options: .init(
                model: "test", stream: false,
                retry: .init(maxAttempts: 2, backoff: .none)
            )
        )

        var final: String?
        for try await event in await orchestrator.run("go to settings") {
            if case .finalAnswer(let text) = event { final = text }
            if case .error(let error) = event { Issue.record("unexpected: \(error)") }
        }
        #expect(final == "Recovered.")

        let retryRequest = try #require(provider.receivedRequests.dropFirst().first)
        #expect(hasOnlyMatchedToolResults(in: retryRequest.messages))
        let toolMessage = try #require(retryRequest.messages.first { $0.role == .tool })
        let errorResult = try #require(toolResultBlocks(in: toolMessage).first)
        #expect(errorResult.id == "bad")
        #expect(errorResult.isError)
        let correction = try #require(retryRequest.messages.last)
        #expect(correction.role == .user)
        #expect(correction.plainText.contains("Re-issue"))
        #expect(!retryRequest.messages.dropFirst().contains { message in
            message.role == .tool && toolResultBlocks(in: message).contains {
                $0.id.hasPrefix("correction-")
            }
        })
    }

    @Test func malformedNativeToolInputCorrectedWithoutInvokingTool() async throws {
        let invocations = ToolInvocationRecorder()
        let registry = ToolRegistry()
        await registry.register(NavigateTool { input, _ in
            await invocations.record(input.destination)
            return .init(navigated: input.destination == "settings")
        })
        let resolver = ContextResolver()
        await resolver.push(ViewContext(
            id: .init("home"), displayName: "Home", toolNames: ["navigate"]
        ))
        let raw = "{\"destination\":"
        let provider = MockProvider(responses: [
            LLMResponse(content: [.toolUse(
                id: "bad", name: "navigate",
                input: .object(["__aikit_malformed_tool_input_raw": .string(raw)])
            )], stopReason: .toolUse),
            LLMResponse(content: [.toolUse(
                id: "good", name: "navigate",
                input: .object(["destination": .string("settings")])
            )], stopReason: .toolUse),
            LLMResponse(content: [.text("Recovered.")], stopReason: .endTurn),
        ])
        let orchestrator = Orchestrator(
            llm: LLMClient(provider: provider),
            tools: registry,
            memory: InMemoryMemoryStore(),
            contextResolver: resolver,
            guardrails: PolicyEngine(),
            options: .init(
                model: "test", stream: false,
                retry: .init(maxAttempts: 2, backoff: .none)
            )
        )

        var final: String?
        for try await event in await orchestrator.run("go to settings") {
            if case .finalAnswer(let text) = event { final = text }
            if case .error(let error) = event { Issue.record("unexpected: \(error)") }
        }

        #expect(final == "Recovered.")
        #expect(await invocations.destinations == ["settings"])

        let retryRequest = try #require(provider.receivedRequests.dropFirst().first)
        #expect(retryRequest.messages.allSatisfy { $0.role != .tool })
        let correction = try #require(retryRequest.messages.last)
        #expect(correction.role == .user)
        #expect(correction.plainText.contains(raw))
    }

    @Test func retriableToolFailureCreatesErrorToolResultAndRecovers() async throws {
        let attempts = ToolAttemptCounter()
        let registry = ToolRegistry()
        await registry.register(NavigateTool { _, _ in
            if await attempts.shouldFailOnce() {
                throw GenericToolError(message: "temporary navigation failure", isRetriable: true)
            }
            return .init(navigated: true)
        })
        let resolver = ContextResolver()
        await resolver.push(ViewContext(
            id: .init("home"), displayName: "Home", toolNames: ["navigate"]
        ))
        let provider = MockProvider(responses: [
            LLMResponse(content: [.toolUse(
                id: "first", name: "navigate",
                input: .object(["destination": .string("settings")])
            )], stopReason: .toolUse),
            LLMResponse(content: [.toolUse(
                id: "retry", name: "navigate",
                input: .object(["destination": .string("settings")])
            )], stopReason: .toolUse),
            LLMResponse(content: [.text("Recovered.")], stopReason: .endTurn),
        ])
        let orchestrator = Orchestrator(
            llm: LLMClient(provider: provider),
            tools: registry,
            memory: InMemoryMemoryStore(),
            contextResolver: resolver,
            guardrails: PolicyEngine(),
            options: .init(
                model: "test", stream: false,
                retry: .init(maxAttempts: 2, backoff: .none)
            )
        )

        var final: String?
        var toolResults: [String] = []
        for try await event in await orchestrator.run("go to settings") {
            if case .toolResult(_, let output) = event {
                toolResults.append(String(decoding: output, as: UTF8.self))
            }
            if case .finalAnswer(let text) = event { final = text }
            if case .error(let error) = event { Issue.record("unexpected: \(error)") }
        }
        #expect(final == "Recovered.")
        #expect(toolResults.contains { $0.contains("temporary navigation failure") })

        let retryRequest = try #require(provider.receivedRequests.dropFirst().first)
        #expect(hasOnlyMatchedToolResults(in: retryRequest.messages))
        let toolMessage = try #require(retryRequest.messages.first { $0.role == .tool })
        let errorResult = try #require(toolResultBlocks(in: toolMessage).first)
        #expect(errorResult.id == "first")
        #expect(errorResult.isError)
        #expect(errorResult.content.contains("temporary navigation failure"))
    }

    @Test func failedMultiToolBatchMarksUnexecutedCallsSkippedBeforeRetry() async throws {
        let attempts = ToolAttemptCounter()
        let skippedFlag = InvocationFlag()
        let registry = ToolRegistry()
        await registry.register(NavigateTool { _, _ in
            if await attempts.shouldFailOnce() {
                throw GenericToolError(message: "temporary navigation failure", isRetriable: true)
            }
            return .init(navigated: true)
        })
        await registry.register(EmptyInputTool {
            await skippedFlag.mark()
        })
        let resolver = ContextResolver()
        await resolver.push(ViewContext(
            id: .init("home"),
            displayName: "Home",
            toolNames: ["navigate", EmptyInputTool.name]
        ))
        let provider = MockProvider(responses: [
            LLMResponse(content: [
                .toolUse(
                    id: "first", name: "navigate",
                    input: .object(["destination": .string("settings")])
                ),
                .toolUse(id: "second", name: EmptyInputTool.name, input: .object([:])),
            ], stopReason: .toolUse),
            LLMResponse(content: [.toolUse(
                id: "retry", name: "navigate",
                input: .object(["destination": .string("settings")])
            )], stopReason: .toolUse),
            LLMResponse(content: [.text("Recovered.")], stopReason: .endTurn),
        ])
        let orchestrator = Orchestrator(
            llm: LLMClient(provider: provider),
            tools: registry,
            memory: InMemoryMemoryStore(),
            contextResolver: resolver,
            guardrails: PolicyEngine(),
            options: .init(
                model: "test", stream: false,
                retry: .init(maxAttempts: 2, backoff: .none)
            )
        )

        var final: String?
        for try await event in await orchestrator.run("run both tools") {
            if case .finalAnswer(let text) = event { final = text }
            if case .error(let error) = event { Issue.record("unexpected: \(error)") }
        }

        #expect(final == "Recovered.")
        #expect(await skippedFlag.didInvoke == false)

        let retryRequest = try #require(provider.receivedRequests.dropFirst().first)
        #expect(hasOnlyMatchedToolResults(in: retryRequest.messages))
        let results = retryRequest.messages
            .filter { $0.role == .tool }
            .flatMap(toolResultBlocks)
        #expect(results.map(\.id) == ["first", "second"])
        #expect(results.allSatisfy { $0.isError })
        #expect(results.first { $0.id == "first" }?.content.contains("temporary navigation failure") == true)
        #expect(results.first { $0.id == "second" }?.content.contains("Skipped") == true)
    }

    @Test func postToolUseReceivesIsErrorTrueForToolFailure() async throws {
        let recorder = PostToolUseRecorder()
        let registry = ToolRegistry()
        await registry.register(NavigateTool { _, _ in
            throw GenericToolError(message: "permanent navigation failure")
        })
        let resolver = ContextResolver()
        await resolver.push(ViewContext(
            id: .init("home"), displayName: "Home", toolNames: ["navigate"]
        ))
        let provider = MockProvider(responses: [
            LLMResponse(content: [.toolUse(
                id: "failed", name: "navigate",
                input: .object(["destination": .string("settings")])
            )], stopReason: .toolUse),
        ])
        let orchestrator = Orchestrator(
            llm: LLMClient(provider: provider),
            tools: registry,
            memory: InMemoryMemoryStore(),
            contextResolver: resolver,
            guardrails: PolicyEngine(rails: [RecordingPostToolUseRail(recorder: recorder)]),
            options: .init(
                model: "test", stream: false,
                retry: .init(maxAttempts: 1, backoff: .none)
            )
        )

        var caught: (any Error)?
        for try await event in await orchestrator.run("go to settings") {
            if case .error(let error) = event { caught = error }
        }
        #expect(caught is GenericToolError)
        #expect(await recorder.values == [true])
    }

    @Test func postToolUseBlockSuppressesFailedToolResultEvent() async throws {
        let registry = ToolRegistry()
        await registry.register(NavigateTool { _, _ in
            throw GenericToolError(message: "contains blocked output")
        })
        let resolver = ContextResolver()
        await resolver.push(ViewContext(
            id: .init("home"), displayName: "Home", toolNames: ["navigate"]
        ))
        let provider = MockProvider(responses: [
            LLMResponse(content: [.toolUse(
                id: "failed", name: "navigate",
                input: .object(["destination": .string("settings")])
            )], stopReason: .toolUse),
        ])
        let orchestrator = Orchestrator(
            llm: LLMClient(provider: provider),
            tools: registry,
            memory: InMemoryMemoryStore(),
            contextResolver: resolver,
            guardrails: PolicyEngine(rails: [BlockingPostToolUseRail()]),
            options: .init(
                model: "test", stream: false,
                retry: .init(maxAttempts: 1, backoff: .none)
            )
        )

        var caught: (any Error)?
        var emittedToolResult = false
        for try await event in await orchestrator.run("go to settings") {
            if case .toolResult = event { emittedToolResult = true }
            if case .error(let error) = event { caught = error }
        }
        #expect(caught is GuardrailViolation)
        #expect(emittedToolResult == false)
    }

    @Test func streamingEmitsDeltas() async throws {
        let registry = ToolRegistry()
        let resolver = ContextResolver()
        await resolver.push(ViewContext(id: .init("v"), displayName: "V"))
        let orchestrator = Orchestrator(
            llm: LLMClient(provider: MockProvider(finalText: "hello stream")),
            tools: registry,
            memory: InMemoryMemoryStore(),
            contextResolver: resolver,
            guardrails: PolicyEngine(),
            options: .init(model: "test", stream: true)
        )
        var deltas: [String] = []
        var final: String?
        for try await event in await orchestrator.run("hi") {
            if case .llmDelta(let d) = event { deltas.append(d) }
            if case .finalAnswer(let f) = event { final = f }
        }
        #expect(deltas.joined() == "hello stream")
        #expect(final == "hello stream")
    }

    @Test func malformedStreamedToolJSONDoesNotInvokeTool() async throws {
        let flag = InvocationFlag()
        let registry = ToolRegistry()
        await registry.register(EmptyInputTool {
            await flag.mark()
        })
        let resolver = ContextResolver()
        await resolver.push(ViewContext(
            id: .init("v"), displayName: "V", toolNames: [EmptyInputTool.name]
        ))
        let orchestrator = Orchestrator(
            llm: LLMClient(provider: MalformedStreamingToolProvider()),
            tools: registry,
            memory: InMemoryMemoryStore(),
            contextResolver: resolver,
            guardrails: PolicyEngine(),
            options: .init(model: "test", maxIterations: 1, stream: true)
        )

        var emittedToolCall = false
        for try await event in await orchestrator.run("invoke ping") {
            if case .toolCall = event { emittedToolCall = true }
        }

        let invoked = await flag.didInvoke
        #expect(emittedToolCall == false)
        #expect(invoked == false)
    }

    @Test func mixedNarrationSurfacedNonStreaming() async throws {
        let provider = MockProvider(responses: [
            LLMResponse(content: [
                .text("Let me open that for you."),
                .toolUse(
                    id: "t1", name: "navigate",
                    input: .object(["destination": .string("settings")])
                ),
            ], stopReason: .toolUse),
            LLMResponse(content: [.text("Done.")], stopReason: .endTurn),
        ])
        let orchestrator = await makeOrchestrator(provider: provider)
        var deltas: [String] = []
        var sawUsage = false
        for try await event in await orchestrator.run("open settings") {
            if case .llmDelta(let d) = event { deltas.append(d) }
            if case .usage = event { sawUsage = true }
            if case .error(let e) = event { Issue.record("unexpected: \(e)") }
        }
        #expect(deltas.contains("Let me open that for you."))
        #expect(sawUsage)
    }

    @Test func defaultsToProviderModelWhenOptionUnset() async throws {
        let provider = MockProvider(
            responses: [LLMResponse(content: [.text("hi")], stopReason: .endTurn)],
            defaultModel: "provider-default"
        )
        let resolver = ContextResolver()
        await resolver.push(ViewContext(id: .init("v"), displayName: "V"))
        let orchestrator = Orchestrator(
            llm: LLMClient(provider: provider),
            tools: ToolRegistry(),
            memory: InMemoryMemoryStore(),
            contextResolver: resolver,
            guardrails: PolicyEngine(),
            options: .init(stream: false)
        )
        for try await _ in await orchestrator.run("hi") {}
        #expect(provider.receivedRequests.first?.model == "provider-default")
    }

    @Test func piiRedactorRedactsToolInputBeforeInvocation() async throws {
        let seen = SeenInput()
        let registry = ToolRegistry()
        await registry.register(NavigateTool { input, _ in
            await seen.record(input.destination)
            return .init(navigated: true)
        })
        let resolver = ContextResolver()
        await resolver.push(ViewContext(
            id: .init("home"), displayName: "Home", toolNames: ["navigate"]
        ))
        let provider = MockProvider(responses: [
            LLMResponse(content: [.toolUse(
                id: "t1", name: "navigate",
                input: .object(["destination": .string("email me at a@b.com")])
            )], stopReason: .toolUse),
            LLMResponse(content: [.text("ok")], stopReason: .endTurn),
        ])
        let orchestrator = Orchestrator(
            llm: LLMClient(provider: provider),
            tools: registry,
            memory: InMemoryMemoryStore(),
            contextResolver: resolver,
            guardrails: PolicyEngine(rails: [PIIRedactor(mode: .redact)]),
            options: .init(stream: false)
        )
        for try await event in await orchestrator.run("go") {
            if case .error(let e) = event { Issue.record("unexpected: \(e)") }
        }
        let destination = await seen.value
        #expect(destination?.contains("[REDACTED]") == true)
        #expect(destination?.contains("a@b.com") == false)
    }
}

private actor SeenInput {
    private(set) var value: String?
    func record(_ v: String) { value = v }
}

private actor InvocationFlag {
    private(set) var didInvoke = false
    func mark() { didInvoke = true }
}

private actor ToolAttemptCounter {
    private var attempts = 0

    func shouldFailOnce() -> Bool {
        attempts += 1
        return attempts == 1
    }
}

private actor ToolInvocationRecorder {
    private(set) var destinations: [String] = []

    func record(_ destination: String) {
        destinations.append(destination)
    }
}

private actor PostToolUseRecorder {
    private(set) var values: [Bool] = []

    func record(_ isError: Bool) {
        values.append(isError)
    }
}

private struct RecordingPostToolUseRail: Guardrail {
    let id = "record-post-tool-use"
    let stages: Set<Verifier.Stage> = [.postToolUse]
    let recorder: PostToolUseRecorder

    func evaluate(_ payload: GuardrailPayload) async -> Verifier.Outcome {
        if case .postToolUse(_, _, let isError) = payload {
            await recorder.record(isError)
        }
        return .pass
    }
}

private struct BlockingPostToolUseRail: Guardrail {
    let id = "block-post-tool-use"
    let stages: Set<Verifier.Stage> = [.postToolUse]

    func evaluate(_ payload: GuardrailPayload) async -> Verifier.Outcome {
        if case .postToolUse(_, _, true) = payload {
            return .block(reason: "blocked failed tool output")
        }
        return .pass
    }
}

private func toolResultBlocks(
    in message: Message
) -> [(id: String, content: String, isError: Bool)] {
    message.content.compactMap { block in
        if case .toolResult(let id, let content, let isError) = block {
            return (id, content, isError)
        }
        return nil
    }
}

private func hasOnlyMatchedToolResults(in messages: [Message]) -> Bool {
    var seenToolUseIDs: Set<String> = []
    for message in messages {
        if message.role == .assistant {
            for block in message.content {
                if case .toolUse(let id, _, _) = block {
                    seenToolUseIDs.insert(id)
                }
            }
        }
        if message.role == .tool {
            for result in toolResultBlocks(in: message)
            where !seenToolUseIDs.contains(result.id) {
                return false
            }
        }
    }
    return true
}

private struct EmptyInputTool: Tool {
    struct Input: Codable, Sendable {}
    struct Output: Codable, Sendable {
        let ok: Bool
    }

    static let name = "emptyInput"
    static let description = "A no-input test tool."
    static let schema = ToolSchema.object(properties: [:])

    let handler: @Sendable () async -> Void

    init(handler: @escaping @Sendable () async -> Void) {
        self.handler = handler
    }

    func invoke(_ input: Input, in context: ToolContext) async throws -> Output {
        await handler()
        return Output(ok: true)
    }
}

private struct MalformedStreamingToolProvider: LLMProvider {
    let defaultModel = "malformed-stream"

    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        LLMResponse(content: [.text("unused")], stopReason: .endTurn)
    }

    func stream(
        _ request: LLMRequest
    ) -> AsyncThrowingStream<LLMResponseChunk, any Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.toolUseStart(id: "bad_1", name: EmptyInputTool.name))
            continuation.yield(.toolUseInputDelta(id: "bad_1", json: "{\"unterminated\":"))
            continuation.yield(.toolUseStop(id: "bad_1"))
            continuation.yield(.stop(.toolUse))
            continuation.finish()
        }
    }
}

/// Always sleeps before answering, so a turn deadline must interrupt it.
private final class SlowProvider: LLMProvider, @unchecked Sendable {
    let defaultModel = "slow"
    private let delay: Duration
    init(delay: Duration) { self.delay = delay }

    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        try await Task.sleep(for: delay)
        return LLMResponse(content: [.text("late")], stopReason: .endTurn)
    }

    func stream(
        _ request: LLMRequest
    ) -> AsyncThrowingStream<LLMResponseChunk, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await Task.sleep(for: delay)
                    continuation.yield(.textDelta("late"))
                    continuation.yield(.stop(.endTurn))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

@Suite struct FallbackTranscriptTests {
    /// REVIEW2 finding **A**: a fenced-fallback recovery must be recorded as a
    /// structured `tool_use` block, with the following `tool_result` carrying
    /// the matching id — not the raw JSON as assistant text.
    @Test func fencedFallbackRecordsStructuredToolUse() async throws {
        let registry = ToolRegistry()
        await registry.register(NavigateTool { input, _ in
            .init(navigated: input.destination == "settings")
        })
        let resolver = ContextResolver()
        await resolver.push(ViewContext(
            id: .init("home"), displayName: "Home",
            systemPromptFragment: "You can navigate.", toolNames: ["navigate"]
        ))
        let fenced = "Working on it.\n```tool\n"
            + "{\"name\":\"navigate\",\"input\":{\"destination\":\"settings\"}}\n```"
        let provider = MockProvider(responses: [
            LLMResponse(content: [.text(fenced)], stopReason: .endTurn),
            LLMResponse(content: [.text("Done.")], stopReason: .endTurn),
        ])
        let orchestrator = Orchestrator(
            llm: LLMClient(provider: provider),
            tools: registry,
            memory: InMemoryMemoryStore(),
            contextResolver: resolver,
            guardrails: PolicyEngine(),
            options: .init(model: "test", stream: false, toolCallFallback: true)
        )

        var toolCalled = false
        var final: String?
        for try await event in await orchestrator.run("go to settings") {
            if case .toolCall(let n, _) = event { toolCalled = (n == "navigate") }
            if case .finalAnswer(let t) = event { final = t }
            if case .error(let e) = event { Issue.record("unexpected: \(e)") }
        }
        #expect(toolCalled)
        #expect(final == "Done.")

        let second = try #require(provider.receivedRequests.dropFirst().first)
        let assistant = try #require(second.messages.first { $0.role == .assistant })
        let toolUseID = try #require(assistant.content.compactMap { block -> String? in
            if case .toolUse(let id, let name, _) = block, name == "navigate" {
                return id
            }
            return nil
        }.first)
        #expect(!toolUseID.isEmpty)
        // The raw fenced JSON must not survive as assistant text.
        #expect(!assistant.content.contains { block in
            if case .text(let t) = block { return t.contains("```tool") }
            return false
        })
        let toolMessage = try #require(second.messages.first { $0.role == .tool })
        let resultID = try #require(toolMessage.content.compactMap { block -> String? in
            if case .toolResult(let id, _, _) = block { return id }
            return nil
        }.first)
        #expect(resultID == toolUseID)
    }

    /// REVIEW2 finding **B**: the fenced-fallback prompt instruction is gated
    /// on provider capability when `toolCallFallback` is left unset.
    @Test func fallbackHintGatedByProviderCapability() async throws {
        func systemPrompt(nativeTools: Bool) async throws -> String {
            let resolver = ContextResolver()
            await resolver.push(ViewContext(
                id: .init("v"), displayName: "V", toolNames: ["navigate"]
            ))
            let registry = ToolRegistry()
            await registry.register(NavigateTool { _, _ in .init(navigated: true) })
            let provider = MockProvider(
                responses: [LLMResponse(content: [.text("ok")], stopReason: .endTurn)],
                supportsNativeTools: nativeTools
            )
            let orchestrator = Orchestrator(
                llm: LLMClient(provider: provider),
                tools: registry,
                memory: InMemoryMemoryStore(),
                contextResolver: resolver,
                guardrails: PolicyEngine(),
                options: .init(model: "test", stream: false)
            )
            for try await _ in await orchestrator.run("hi") {}
            return try #require(provider.receivedRequests.first?.system)
        }
        let native = try await systemPrompt(nativeTools: true)
        let local = try await systemPrompt(nativeTools: false)
        #expect(!native.contains(PromptBuilder.toolFallbackInstruction))
        #expect(local.contains(PromptBuilder.toolFallbackInstruction))
    }
}

/// A guardrail that sleeps before answering, to prove the turn deadline races
/// guardrail passes too (REVIEW3 #2).
private struct SlowGuardrail: Guardrail {
    let id = "slow"
    let stages: Set<Verifier.Stage>
    let delay: Duration
    func evaluate(_ payload: GuardrailPayload) async -> Verifier.Outcome {
        try? await Task.sleep(for: delay)
        return .pass
    }
}

@Suite struct ToolCallFallbackMatrixTests {
    /// REVIEW3 finding **#1**: the fenced fallback must fire exactly when
    /// intended across `supportsNativeTools` × `toolCallFallback`. The model
    /// emits *only* a fenced ```tool block (no native tool_use), so the tool
    /// runs iff the fallback is active.
    private func run(
        nativeTools: Bool, fallback: Bool?
    ) async throws -> (toolRan: Bool, final: String?) {
        let registry = ToolRegistry()
        await registry.register(NavigateTool { _, _ in .init(navigated: true) })
        let resolver = ContextResolver()
        await resolver.push(ViewContext(
            id: .init("home"), displayName: "Home", toolNames: ["navigate"]
        ))
        let fenced = "```tool\n{\"name\":\"navigate\","
            + "\"input\":{\"destination\":\"home\"}}\n```"
        let provider = MockProvider(
            responses: [
                LLMResponse(content: [.text(fenced)], stopReason: .endTurn),
                LLMResponse(content: [.text("Done.")], stopReason: .endTurn),
            ],
            supportsNativeTools: nativeTools
        )
        let orchestrator = Orchestrator(
            llm: LLMClient(provider: provider),
            tools: registry,
            memory: InMemoryMemoryStore(),
            contextResolver: resolver,
            guardrails: PolicyEngine(),
            options: .init(
                model: "test", stream: false, toolCallFallback: fallback
            )
        )
        var toolRan = false
        var final: String?
        for try await event in await orchestrator.run("go home") {
            if case .toolCall(let n, _) = event { toolRan = (n == "navigate") }
            if case .finalAnswer(let t) = event { final = t }
            if case .error(let e) = event { Issue.record("unexpected: \(e)") }
        }
        return (toolRan, final)
    }

    @Test func matrix() async throws {
        // (nativeTools, toolCallFallback) -> fallback active?
        let expectations: [(Bool, Bool?, Bool)] = [
            (true,  nil,   false),  // native + auto  -> off
            (true,  true,  true),   // forced on
            (true,  false, false),  // forced off
            (false, nil,   true),   // local + auto   -> ON (the #1 fix)
            (false, true,  true),   // forced on
            (false, false, false),  // forced off
        ]
        for (native, fallback, active) in expectations {
            let (toolRan, final) = try await run(
                nativeTools: native, fallback: fallback
            )
            let label: Comment = "native=\(native) fallback=\(String(describing: fallback))"
            #expect(toolRan == active, label)
            if active {
                #expect(final == "Done.", label)
            } else {
                // Fenced JSON was delivered verbatim as the final answer.
                #expect(final?.contains("navigate") == true, label)
            }
        }
    }
}

@Suite struct ReasoningEventTests {
    private func session(
        stream: Bool
    ) async -> Orchestrator {
        let resolver = ContextResolver()
        await resolver.push(ViewContext(id: .init("v"), displayName: "V"))
        let provider = MockProvider(responses: [
            LLMResponse(
                content: [.reasoning("thinking..."), .text("answer")],
                stopReason: .endTurn
            )
        ])
        return Orchestrator(
            llm: LLMClient(provider: provider),
            tools: ToolRegistry(),
            memory: InMemoryMemoryStore(),
            contextResolver: resolver,
            guardrails: PolicyEngine(),
            options: .init(model: "test", stream: stream)
        )
    }

    /// REVIEW3 finding **#3**: reasoning is surfaced as a distinct event.
    @Test func nonStreamingEmitsReasoningOnce() async throws {
        let orchestrator = await session(stream: false)
        var reasoning = ""
        var reasoningEvents = 0
        var final: String?
        for try await event in await orchestrator.run("hi") {
            if case .reasoningDelta(let r) = event {
                reasoning += r
                reasoningEvents += 1
            }
            if case .finalAnswer(let t) = event { final = t }
        }
        #expect(reasoning == "thinking...")
        #expect(reasoningEvents == 1)
        #expect(final == "answer")
    }

    @Test func streamingEmitsReasoningDeltas() async throws {
        let orchestrator = await session(stream: true)
        var reasoning = ""
        var deltas = ""
        var final: String?
        for try await event in await orchestrator.run("hi") {
            if case .reasoningDelta(let r) = event { reasoning += r }
            if case .llmDelta(let d) = event { deltas += d }
            if case .finalAnswer(let t) = event { final = t }
        }
        #expect(reasoning == "thinking...")
        #expect(deltas == "answer")
        #expect(final == "answer")
    }
}

@Suite struct NearMissDiagnosticTests {
    @Test func detectsMistaggedFencedToolCall() {
        let json = "Here you go:\n```json\n"
            + "{\"name\":\"navigate\",\"input\":{\"destination\":\"home\"}}\n```"
        #expect(OutputParser.nearMissFencedToolBlock(in: json))
        // A correctly tagged block is not a near-miss (it gets recovered).
        let tagged = "```tool\n{\"name\":\"x\",\"input\":{}}\n```"
        #expect(!OutputParser.nearMissFencedToolBlock(in: tagged))
        // Prose with no tool-shaped JSON is not a near-miss.
        #expect(!OutputParser.nearMissFencedToolBlock(in: "All done, no tools."))
        #expect(!OutputParser.nearMissFencedToolBlock(
            in: "```json\n{\"result\": 42}\n```"
        ))
    }

    /// REVIEW3 minor: a ```json-fenced tool call is delivered as the final
    /// answer (never executed) but a diagnostic warning is surfaced.
    @Test func emitsWarningAndDoesNotExecute() async throws {
        let flag = InvocationFlag()
        let registry = ToolRegistry()
        await registry.register(NavigateTool { _, _ in
            await flag.mark()
            return .init(navigated: true)
        })
        let resolver = ContextResolver()
        await resolver.push(ViewContext(
            id: .init("home"), displayName: "Home", toolNames: ["navigate"]
        ))
        let mistagged = "```json\n"
            + "{\"name\":\"navigate\",\"input\":{\"destination\":\"home\"}}\n```"
        let provider = MockProvider(responses: [
            LLMResponse(content: [.text(mistagged)], stopReason: .endTurn)
        ])
        let orchestrator = Orchestrator(
            llm: LLMClient(provider: provider),
            tools: registry,
            memory: InMemoryMemoryStore(),
            contextResolver: resolver,
            guardrails: PolicyEngine(),
            options: .init(model: "test", stream: false, toolCallFallback: true)
        )
        var warned = false
        var final: String?
        for try await event in await orchestrator.run("go home") {
            if case .verification(let stage, let outcome) = event,
               stage == .finalResult, case .warn = outcome {
                warned = true
            }
            if case .finalAnswer(let t) = event { final = t }
            if case .error(let e) = event { Issue.record("unexpected: \(e)") }
        }
        #expect(warned)
        #expect(final?.contains("navigate") == true)
        let invoked = await flag.didInvoke
        #expect(invoked == false)
    }
}

@Suite struct TurnDeadlineTests {
    /// REVIEW2 finding **E**: a zero budget aborts before any work.
    @Test func zeroBudgetAbortsImmediately() async throws {
        let resolver = ContextResolver()
        await resolver.push(ViewContext(id: .init("v"), displayName: "V"))
        let orchestrator = Orchestrator(
            llm: LLMClient(provider: MockProvider(finalText: "hi")),
            tools: ToolRegistry(),
            memory: InMemoryMemoryStore(),
            contextResolver: resolver,
            guardrails: PolicyEngine(),
            options: .init(model: "test", stream: false, maxTurnDuration: 0)
        )
        var caught: (any Error)?
        var final: String?
        for try await event in await orchestrator.run("hi") {
            if case .error(let e) = event { caught = e }
            if case .finalAnswer(let t) = event { final = t }
        }
        #expect(caught is TurnDeadlineExceeded)
        #expect(final == nil)
    }

    /// The deadline must interrupt an in-flight slow call, not wait it out.
    @Test func deadlineInterruptsSlowCall() async throws {
        let resolver = ContextResolver()
        await resolver.push(ViewContext(id: .init("v"), displayName: "V"))
        let orchestrator = Orchestrator(
            llm: LLMClient(provider: SlowProvider(delay: .seconds(5))),
            tools: ToolRegistry(),
            memory: InMemoryMemoryStore(),
            contextResolver: resolver,
            guardrails: PolicyEngine(),
            options: .init(model: "test", stream: false, maxTurnDuration: 0.2)
        )
        let start = ContinuousClock.now
        var caught: (any Error)?
        for try await event in await orchestrator.run("hi") {
            if case .error(let e) = event { caught = e }
        }
        let elapsed = ContinuousClock.now - start
        #expect(caught is TurnDeadlineExceeded)
        #expect(elapsed < .seconds(3))
    }

    /// REVIEW3 finding **#2**: a hung tool must not be able to overrun the
    /// budget — the invocation is raced against the deadline too.
    @Test func deadlineInterruptsHangingTool() async throws {
        let registry = ToolRegistry()
        await registry.register(NavigateTool { _, _ in
            try await Task.sleep(for: .seconds(5))
            return .init(navigated: true)
        })
        let resolver = ContextResolver()
        await resolver.push(ViewContext(
            id: .init("home"), displayName: "Home", toolNames: ["navigate"]
        ))
        let provider = MockProvider(responses: [
            LLMResponse(content: [.toolUse(
                id: "t1", name: "navigate",
                input: .object(["destination": .string("home")])
            )], stopReason: .toolUse),
            LLMResponse(content: [.text("late")], stopReason: .endTurn),
        ])
        let orchestrator = Orchestrator(
            llm: LLMClient(provider: provider),
            tools: registry,
            memory: InMemoryMemoryStore(),
            contextResolver: resolver,
            guardrails: PolicyEngine(),
            options: .init(
                model: "test", stream: false,
                retry: .init(maxAttempts: 1), maxTurnDuration: 0.2
            )
        )
        let start = ContinuousClock.now
        var caught: (any Error)?
        for try await event in await orchestrator.run("go home") {
            if case .error(let e) = event { caught = e }
        }
        #expect(caught is TurnDeadlineExceeded)
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    /// The budget must also race a slow guardrail pass, not just LLM calls.
    @Test func deadlineInterruptsSlowGuardrail() async throws {
        let resolver = ContextResolver()
        await resolver.push(ViewContext(id: .init("v"), displayName: "V"))
        let orchestrator = Orchestrator(
            llm: LLMClient(provider: MockProvider(finalText: "hi")),
            tools: ToolRegistry(),
            memory: InMemoryMemoryStore(),
            contextResolver: resolver,
            guardrails: PolicyEngine(rails: [
                SlowGuardrail(stages: [.prePrompt], delay: .seconds(5))
            ]),
            options: .init(
                model: "test", stream: false,
                retry: .init(maxAttempts: 1), maxTurnDuration: 0.2
            )
        )
        let start = ContinuousClock.now
        var caught: (any Error)?
        for try await event in await orchestrator.run("hi") {
            if case .error(let e) = event { caught = e }
        }
        #expect(caught is TurnDeadlineExceeded)
        #expect(ContinuousClock.now - start < .seconds(3))
    }
}
