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
}
