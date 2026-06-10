import Foundation
import FoundationModels
import Testing
import AIToolKit
@testable import AIKitRuntime
import AIKitCore
import AIKitCapability
import AIKitSafety
import AIKitTestSupport

/// A `ContextHarvesting` that resolves nothing — sufficient for self-contained
/// workflow plans, which never trigger a harvest.
private struct StubHarvester: ContextHarvesting {
    func harvest(_ slots: [WorkflowContextSlot]) async -> ContextPacket {
        ContextPacket(slots: slots.map {
            HarvestedSlot(
                slotID: $0.slotID, source: $0.source,
                status: .missing, candidates: [], required: $0.required
            )
        })
    }
}

private struct FixedHarvester: ContextHarvesting {
    var packet: ContextPacket

    func harvest(_ slots: [WorkflowContextSlot]) async -> ContextPacket {
        packet
    }
}

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
                ToolDescriptor(name: "navigate", description: "nav", argumentsSchema: GeneratedContent.generationSchema),
                ToolDescriptor(name: "other", description: "x", argumentsSchema: GeneratedContent.generationSchema),
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
                ToolDescriptor(name: "navigate", description: "nav", argumentsSchema: GeneratedContent.generationSchema),
            ],
            model: "test-model",
            toolCallFallbackHint: true
        )
        #expect(request.tools.isEmpty)
        #expect(request.system?.contains(PromptBuilder.toolFallbackInstruction) == false)
    }

    @Test func workflowPlanningDefaultsToLeanSchemaWithExample() throws {
        let context = ResolvedContext(
            stack: [.init("home")],
            systemPromptFragment: "",
            toolNames: ["navigate"],
            metadata: [:]
        )
        let request = PromptBuilder.build(
            instruction: "Open settings",
            context: context,
            memory: [],
            transcript: [],
            toolManifest: [
                ToolDescriptor(name: "navigate", description: "nav", argumentsSchema: GeneratedContent.generationSchema),
            ],
            model: "test-model",
            workflowPlanningHint: true
        )

        #expect(request.system?.contains("Emit only") == true)
        #expect(request.system?.contains("Example WorkflowSpec") == true)
        #expect(request.tools.map(\.name) == [WorkflowSpec.toolName])

        let schemaJSON = try #require(try request.tools.first?.argumentsSchema.jsonString())
        let schemaObject = try #require(GeneratedContent(json: schemaJSON).objectValue)
        let required = try #require(schemaObject["required"]?.arrayValue)
        #expect(required.compactMap(\.stringValue) == ["schema_version", "nodes"])
        let properties = try #require(schemaObject["properties"]?.objectValue)
        #expect(properties["final"] == nil)
        #expect(properties["limits"] == nil)
    }
}

@Suite struct OutputParserTests {
    @Test func parsesFinalText() throws {
        let response = LLMResponse(content: [.text("all done")], stopReason: .endTurn)
        #expect(try OutputParser.parse(response) == .final("all done"))
    }

    @Test func parsesToolCalls() throws {
        let response = LLMResponse(
            content: [.toolUse(id: "1", name: "navigate", arguments: .object(["to": .string("x")]))],
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
            + "{\"name\":\"navigate\",\"arguments\":{\"destination\":\"home\"}}\n```"
        let response = LLMResponse(content: [.text(text)], stopReason: .endTurn)
        guard case .mixed(let narration, let calls) = try OutputParser.parse(
            response, allowToolCallFallback: true
        ) else {
            Issue.record("expected mixed")
            return
        }
        #expect(narration == "I'll handle that.")
        #expect(calls.first?.name == "navigate")
        #expect(calls.first?.arguments.objectValue?["destination"]?.stringValue == "home")
    }

    @Test func fallbackDisabledTreatsFenceAsText() throws {
        let text = "```tool\n{\"name\":\"x\",\"arguments\":{}}\n```"
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
                arguments: .object(["__aikit_malformed_tool_input_raw": .string(raw)])
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
            let input: GeneratedContent = .object([
                "n": .number(Double(Int.random(in: 0...100))),
                "s": .string(UUID().uuidString),
            ])
            let response = LLMResponse(
                content: [.toolUse(id: UUID().uuidString, name: name, arguments: input)],
                stopReason: .toolUse
            )
            guard case .toolCalls(let calls) = try OutputParser.parse(response) else {
                Issue.record("expected toolCalls")
                return
            }
            #expect(calls.first?.name == name)
            #expect(calls.first?.arguments == input)
        }
    }
}

@Suite struct WorkflowSpecTests {
    @Test func parsesTopologicalWorkflowJSONAndResolvesReferences() throws {
        let spec = WorkflowSpec(
            workflowID: "wf_join",
            intent: "Join two source values.",
            nodes: [
                WorkflowNode(
                    id: "a",
                    tool: "tool1",
                    input: .object(["x": .string("LLM value")])
                ),
                WorkflowNode(
                    id: "b",
                    tool: "tool2",
                    input: .object(["y": .string("LLM value")])
                ),
                WorkflowNode(
                    id: "c",
                    tool: "tool3",
                    dependsOn: ["a", "b"],
                    input: .object([
                        "left": workflowRef(node: "a", path: "/value"),
                        "right": workflowRef(node: "b", path: "/value"),
                    ])
                ),
            ],
            final: .nodeOutput("c")
        )
        let json = try workflowJSONString(spec)
        let response = LLMResponse(content: [.text(json)], stopReason: .endTurn)
        guard case .workflow(let plan) = try OutputParser.parse(response) else {
            Issue.record("expected workflow spec")
            return
        }

        let validated = try WorkflowValidator.validate(
            plan,
            policy: WorkflowValidationPolicy(availableTools: ["tool1", "tool2", "tool3"])
        )
        #expect(validated.levels.map { $0.map(\.id).sorted() } == [["a", "b"], ["c"]])

        let input = try WorkflowReferenceResolver.resolve(
            plan.nodes[2].input,
            outputs: [
                "a": .object(["value": .string("left-value")]),
                "b": .object(["value": .string("right-value")]),
            ],
            currentNodeID: "c"
        )
        #expect(input.objectValue?["left"]?.stringValue == "left-value")
        #expect(input.objectValue?["right"]?.stringValue == "right-value")
    }

    @Test func rejectsNonTopologicalWorkflowOrder() throws {
        let plan = WorkflowSpec(
            workflowID: "wf_bad_order",
            intent: "Reference a later node.",
            nodes: [
                WorkflowNode(
                    id: "c",
                    tool: "tool3",
                    dependsOn: ["a"],
                    input: .object(["left": workflowRef(node: "a", path: "/value")])
                ),
                WorkflowNode(id: "a", tool: "tool1"),
            ],
            final: .nodeOutput("c")
        )
        #expect(throws: WorkflowError.self) {
            _ = try WorkflowValidator.validate(
                plan,
                policy: WorkflowValidationPolicy(availableTools: ["tool1", "tool3"])
            )
        }
    }

    @Test func parsesNativeWorkflowToolCall() throws {
        let spec = WorkflowSpec(
            workflowID: "wf_open_settings",
            intent: "Open settings.",
            nodes: [
                WorkflowNode(
                    id: "open_settings",
                    tool: "navigate",
                    input: .object(["destination": .string("settings")])
                ),
            ],
            final: .nodeOutput("open_settings")
        )
        let input = try GeneratedContent(json: workflowJSONString(spec))
        let response = LLMResponse(
            content: [.toolUse(id: "wf", name: WorkflowSpec.toolName, arguments: input)],
            stopReason: .toolUse
        )
        guard case .workflow(let plan) = try OutputParser.parse(response) else {
            Issue.record("expected workflow spec")
            return
        }
        #expect(plan.nodes.compactMap(\.tool) == ["navigate"])
    }

    @Test func workflowGuardrailViolationIgnoresContinueWithNullPolicy() async throws {
        let flag = InvocationFlag()
        let registry = ToolRegistry()
        await registry.register(NavigateTool { _ in
            await flag.mark()
            return .init(navigated: true)
        })
        let resolver = ContextResolver()
        await resolver.push(ViewContext(
            id: .init("home"), displayName: "Home", toolNames: ["navigate"]
        ))
        let spec = WorkflowSpec(
            workflowID: "wf_guardrail_terminal",
            intent: "Prove guardrails cannot be swallowed by node policy.",
            nodes: [
                WorkflowNode(
                    id: "go",
                    tool: "navigate",
                    input: .object(["destination": .string("email me at a@b.com")]),
                    policy: WorkflowNodePolicy(onError: .continueWithNull)
                ),
            ],
            final: .message("done")
        )
        let provider = MockProvider(responses: [
            LLMResponse(
                content: [.text(try workflowJSONString(spec))],
                stopReason: .endTurn
            ),
        ])
        let orchestrator = Orchestrator(
            llm: LLMClient(provider: provider),
            tools: registry,
            memory: InMemoryMemoryStore(),
            contextResolver: resolver,
            guardrails: PolicyEngine(rails: [PIIRedactor()]),
            options: .init(model: "test", stream: false)
        )

        var caught: (any Error)?
        var final: String?
        for try await event in await orchestrator.run("open it") {
            if case .error(let error) = event { caught = error }
            if case .finalAnswer(let text) = event { final = text }
        }
        #expect(caught is GuardrailViolation)
        #expect(final == nil)
        #expect(await flag.didInvoke == false)
    }

    @Test func workflowPostToolUseReceivesToolOutput() async throws {
        let recorder = PostToolUseOutputRecorder()
        let registry = ToolRegistry()
        await registry.register(SensitiveOutputTool())
        let resolver = ContextResolver()
        await resolver.push(ViewContext(
            id: .init("home"), displayName: "Home", toolNames: [SensitiveOutputTool.toolName]
        ))
        let spec = WorkflowSpec(
            workflowID: "wf_post_outputs",
            intent: "Inspect post-tool output payloads.",
            nodes: [
                WorkflowNode(id: "read", tool: SensitiveOutputTool.toolName),
            ],
            final: .message("done")
        )
        let provider = MockProvider(responses: [
            LLMResponse(
                content: [.text(try workflowJSONString(spec))],
                stopReason: .endTurn
            ),
        ])
        let orchestrator = Orchestrator(
            llm: LLMClient(provider: provider),
            tools: registry,
            memory: InMemoryMemoryStore(),
            contextResolver: resolver,
            guardrails: PolicyEngine(rails: [
                RecordingPostToolUseOutputRail(recorder: recorder)
            ]),
            options: .init(model: "test", stream: false)
        )

        for try await event in await orchestrator.run("read") {
            if case .error(let error) = event {
                Issue.record("unexpected error: \(error)")
            }
        }
        let entries = await recorder.entries
        #expect(entries.count == 1)
        #expect(entries.first?.text.contains("top-secret") == true)
    }

    @Test func promptBuilderCanExposeWorkflowSchema() {
        let context = ResolvedContext(
            stack: [.init("home")],
            systemPromptFragment: "",
            toolNames: ["navigate", "setProfile"],
            metadata: [:]
        )
        let request = PromptBuilder.build(
            instruction: "Open settings and remember my theme",
            context: context,
            memory: [],
            transcript: [],
            toolManifest: [
                ToolDescriptor(name: "navigate", description: "nav", argumentsSchema: GeneratedContent.generationSchema),
                ToolDescriptor(name: "setProfile", description: "profile", argumentsSchema: GeneratedContent.generationSchema),
            ],
            model: "test-model",
            workflowPlanningHint: true
        )
        #expect(request.system?.contains("WorkflowSpec is a topological DAG") == true)
        #expect(request.system?.contains("- navigate: nav") == true)
        #expect(request.system?.contains("Arguments schema:") == true)
        #expect(request.system?.contains("- setProfile: profile") == true)
        #expect(request.tools.map { $0.name } == [WorkflowSpec.toolName])
    }
}

@Suite struct WorkflowTwoRoundRunnerTests {
    private func destinationPacket(
        candidates: [HarvestedCandidate]
    ) -> ContextPacket {
        ContextPacket(slots: [
            HarvestedSlot(
                slotID: "destination",
                source: "current_destination",
                status: .resolved,
                candidates: candidates,
                required: true
            ),
        ])
    }

    private func runner(
        provider: MockProvider,
        registry: ToolRegistry,
        packet: ContextPacket,
        options: WorkflowTwoRoundRunner.Options,
        planCache: WorkflowPlanCache? = nil
    ) -> WorkflowTwoRoundRunner {
        WorkflowTwoRoundRunner(
            llm: LLMClient(provider: provider),
            tools: registry,
            harvester: FixedHarvester(packet: packet),
            plannerToolNames: ["navigate"],
            options: options,
            planCache: planCache
        )
    }

    @Test func structuredOutputCanBePlannerOnly() async throws {
        let registry = ToolRegistry()
        await registry.register(NavigateTool { input in
            .init(navigated: input.destination == "settings")
        })
        let plan = """
        {"nodes":[{"id":"go","tool":"navigate","input":{"destination":{"$slot":"destination"}}}],
         "context_slots":[{"slot_id":"destination","source":"current_destination"}]}
        """
        let binding = """
        {"binding_status":"complete",
         "nodes":[{"id":"go","tool":"navigate","input":{"destination":{"$bind":"dest_1"}}}],
         "missing_slots":[],"message":null}
        """
        let provider = MockProvider(responses: [
            LLMResponse(content: [.text(plan)], stopReason: .endTurn),
            LLMResponse(content: [.text(binding)], stopReason: .endTurn),
        ])
        let packet = destinationPacket(candidates: [
            HarvestedCandidate(
                candidateID: "dest_1",
                label: "Settings",
                kind: "screen",
                value: .string("settings"),
                isCurrent: false
            ),
            HarvestedCandidate(
                candidateID: "dest_2",
                label: "Home",
                kind: "screen",
                value: .string("home"),
                isCurrent: false
            ),
        ])
        let subject = runner(
            provider: provider,
            registry: registry,
            packet: packet,
            options: .init(
                model: "test",
                sources: ["current_destination"],
                useStructuredPlannerOutput: true
            )
        )

        let result = await subject.run(intent: "open it")
        guard case .executed = result.outcome else {
            Issue.record("expected execution, got \(result.outcome)")
            return
        }

        let requests = provider.receivedRequests
        #expect(requests.count == 2)
        #expect(requests[0].responseSchema != nil)
        #expect(requests[1].responseSchema == nil)
    }

    @Test func planCacheAndAutoBindSkipPlannerOnRepeat() async throws {
        let invocations = ToolInvocationRecorder()
        let registry = ToolRegistry()
        await registry.register(NavigateTool { input in
            await invocations.record(input.destination)
            return .init(navigated: true)
        })
        let plan = """
        {"nodes":[{"id":"go","tool":"navigate","input":{"destination":{"$slot":"destination"}}}],
         "context_slots":[{"slot_id":"destination","source":"current_destination"}]}
        """
        let provider = MockProvider(responses: [
            LLMResponse(content: [.text(plan)], stopReason: .endTurn),
        ])
        let packet = destinationPacket(candidates: [
            HarvestedCandidate(
                candidateID: "dest_1",
                label: "Settings",
                kind: "screen",
                value: .string("settings"),
                isCurrent: true
            ),
        ])
        let cache = WorkflowPlanCache()
        let subject = runner(
            provider: provider,
            registry: registry,
            packet: packet,
            options: .init(model: "test", sources: ["current_destination"]),
            planCache: cache
        )

        let first = await subject.run(intent: "open this")
        let second = await subject.run(intent: "  Open   This  ")

        guard case .executed = first.outcome else {
            Issue.record("expected first execution")
            return
        }
        guard case .executed = second.outcome else {
            Issue.record("expected second execution")
            return
        }
        #expect(provider.receivedRequests.count == 1)
        #expect(await cache.hits == 1)
        #expect(await invocations.destinations == ["settings", "settings"])
    }

    @Test func safetyRedactsToolInputBeforeTwoRoundExecution() async throws {
        let seen = SeenInput()
        let registry = ToolRegistry()
        await registry.register(NavigateTool { input in
            await seen.record(input.destination)
            return .init(navigated: true)
        })
        let plan = """
        {"nodes":[{"id":"go","tool":"navigate","input":{"destination":"email me at a@b.com"}}],
         "context_slots":[]}
        """
        let provider = MockProvider(responses: [
            LLMResponse(content: [.text(plan)], stopReason: .endTurn),
        ])
        let subject = WorkflowTwoRoundRunner(
            llm: LLMClient(provider: provider),
            tools: registry,
            harvester: StubHarvester(),
            plannerToolNames: ["navigate"],
            options: .init(model: "test", sources: []),
            guardrails: PolicyEngine(rails: [PIIRedactor(mode: .redact)])
        )

        let result = await subject.run(intent: "open it")
        guard case .executed = result.outcome else {
            Issue.record("expected execution, got \(result.outcome)")
            return
        }
        let destination = await seen.value
        #expect(destination?.contains("[REDACTED]") == true)
        #expect(destination?.contains("a@b.com") == false)
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
        provider: any LLMProvider,
        guardrails: PolicyEngine = PolicyEngine(),
        usageRecorder: (any AIKitSessionUsageRecording)? = nil
    ) async -> Orchestrator {
        let registry = ToolRegistry()
        await registry.register(NavigateTool { input in
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
            usageRecorder: usageRecorder,
            options: .init(model: "test", stream: false, workflowPlanning: false)
        )
    }

    @Test func endToEndToolThenFinal() async throws {
        let provider = MockProvider(responses: [
            LLMResponse(
                content: [.toolUse(
                    id: "t1", name: "navigate",
                    arguments: .object(["destination": .string("settings")])
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

    @Test func snapshotGroupsActivityByTaskWithUsageAndDuration() async throws {
        let provider = MockProvider(responses: [
            LLMResponse(
                content: [.toolUse(
                    id: "t1", name: "navigate",
                    arguments: .object(["destination": .string("settings")])
                )],
                stopReason: .toolUse,
                usage: TokenUsage(inputTokens: 10, outputTokens: 2)
            ),
            LLMResponse(
                content: [.text("You're on settings now.")],
                stopReason: .endTurn,
                usage: TokenUsage(inputTokens: 5, outputTokens: 7)
            ),
        ])
        let orchestrator = await makeOrchestrator(provider: provider)

        for try await event in await orchestrator.run("Go to settings") {
            if case .error(let error) = event {
                Issue.record("unexpected error: \(error)")
            }
        }

        let snapshot = await orchestrator.snapshot(recentActivityLimit: 20)
        let task = try #require(snapshot.recentTasks.first)
        #expect(task.instruction == "Go to settings")
        #expect(task.isRunning == false)
        #expect(task.duration() >= 0)
        #expect(task.usage.inputTokens == 15)
        #expect(task.usage.outputTokens == 9)
        #expect(task.activities.contains { $0.kind == .userInstruction })
        #expect(task.activities.contains { $0.kind == .toolInvoked })
        #expect(task.activities.contains { $0.kind == .toolResult })
        #expect(task.activities.contains { $0.kind == .llmResponse })
    }

    @Test func finishedTurnRecordsSessionUsage() async throws {
        let provider = MockProvider(responses: [
            LLMResponse(
                content: [.toolUse(
                    id: "t1", name: "navigate",
                    arguments: .object(["destination": .string("settings")])
                )],
                stopReason: .toolUse,
                usage: TokenUsage(inputTokens: 10, outputTokens: 2)
            ),
            LLMResponse(
                content: [.text("You're on settings now.")],
                stopReason: .endTurn,
                usage: TokenUsage(inputTokens: 5, outputTokens: 7)
            ),
        ])
        let usageStore = InMemorySessionUsageStore()
        let orchestrator = await makeOrchestrator(
            provider: provider,
            usageRecorder: usageStore
        )

        for try await event in await orchestrator.run("Go to settings") {
            if case .error(let error) = event {
                Issue.record("unexpected error: \(error)")
            }
        }

        let summaries = await usageStore.all()
        let summary = try #require(summaries.first)
        #expect(summaries.count == 1)
        #expect(summary.taskID.hasPrefix("turn-"))
        #expect(summary.modelName == "test")
        #expect(summary.providerName == "MockProvider")
        #expect(summary.roundTripCount == 2)
        #expect(summary.messageCount == 2)
        #expect(summary.usage == TokenUsage(inputTokens: 15, outputTokens: 9))
        #expect(summary.outcome == .completed)
    }

    @Test func cancelledTurnRecordsSessionUsageOnce() async throws {
        let usageStore = InMemorySessionUsageStore()
        let orchestrator = await makeOrchestrator(
            provider: SlowProvider(delay: .seconds(5)),
            usageRecorder: usageStore
        )

        let stream = await orchestrator.run("Go to settings")
        let drainTask = Task {
            for try await event in stream {
                if case .error(let error) = event {
                    Issue.record("unexpected error: \(error)")
                }
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        await orchestrator.cancelActiveTurns()
        try await drainTask.value

        let summaries = await usageStore.all()
        let summary = try #require(summaries.first)
        #expect(summaries.count == 1)
        #expect(summary.outcome == .cancelled)
        #expect(summary.messageCount == 1)
        #expect(summary.roundTripCount == 0)
        #expect(summary.usage == .zero)
    }

    @Test func runWorkflowTaskHostsTwoRoundAsTrackedTurn() async throws {
        let registry = ToolRegistry()
        await registry.register(NavigateTool { input in
            .init(navigated: input.destination == "settings")
        })
        let resolver = ContextResolver()
        await resolver.push(ViewContext(
            id: .init("home"),
            displayName: "Home",
            systemPromptFragment: "You can navigate.",
            toolNames: ["navigate"]
        ))
        let memory = InMemoryMemoryStore()
        // A self-contained plan: the runner executes the DAG locally without a
        // binder round, so one scripted planner response is enough.
        let planJSON = """
        {"nodes":[{"id":"go","tool":"navigate","input":{"destination":"settings"}}],
         "context_slots":[]}
        """
        let provider = MockProvider(responses: [
            LLMResponse(content: [.text(planJSON)], stopReason: .endTurn),
        ])
        let orchestrator = Orchestrator(
            llm: LLMClient(provider: provider),
            tools: registry,
            memory: memory,
            contextResolver: resolver,
            guardrails: PolicyEngine(),
            options: .init(model: "test", stream: false, workflowPlanning: false)
        )

        var toolNames: [String] = []
        var sawFinal = false
        for try await event in await orchestrator.runWorkflowTask(
            intent: "open settings",
            harvester: StubHarvester(),
            plannerToolNames: ["navigate"],
            sources: []
        ) {
            switch event {
            case .toolCall(let name, _): toolNames.append(name)
            case .finalAnswer: sawFinal = true
            case .error(let error): Issue.record("unexpected error: \(error)")
            default: break
            }
        }
        #expect(toolNames.contains("navigate"))
        #expect(sawFinal)

        // The hosted workflow's node is recorded under the leaf view, so it
        // lands in the activity history scoped to that view — the whole point
        // of hosting it on the orchestrator instead of a side-run runner.
        let recent = try await memory.recent(limit: 20, view: .init("home"))
        #expect(recent.contains { $0.kind == .toolInvoked && $0.payloadText.contains("navigate") })
        #expect(recent.contains { $0.kind == .toolResult && $0.payloadText.contains("navigate") })

        // The turn finished, so the orchestrator is idle again (no leaked turn).
        let activity = await orchestrator.snapshot()
        #expect(activity.recentActivities.isEmpty == false)
    }

    @Test func runWorkflowTaskAppliesFinalResultGuardrail() async throws {
        let registry = ToolRegistry()
        await registry.register(NavigateTool { _ in
            .init(navigated: true)
        })
        let resolver = ContextResolver()
        await resolver.push(ViewContext(
            id: .init("home"), displayName: "Home", toolNames: ["navigate"]
        ))
        let planJSON = """
        {"nodes":[{"id":"go","tool":"navigate","input":{"destination":"settings"}}],
         "context_slots":[]}
        """
        let provider = MockProvider(responses: [
            LLMResponse(content: [.text(planJSON)], stopReason: .endTurn),
        ])
        let orchestrator = Orchestrator(
            llm: LLMClient(provider: provider),
            tools: registry,
            memory: InMemoryMemoryStore(),
            contextResolver: resolver,
            guardrails: PolicyEngine(rails: [OutputLengthCap(maxCharacters: 1)]),
            options: .init(model: "test", stream: false, workflowPlanning: false)
        )

        var final: String?
        var failure: String?
        for try await event in await orchestrator.runWorkflowTask(
            intent: "open settings",
            harvester: StubHarvester(),
            plannerToolNames: ["navigate"],
            sources: []
        ) {
            if case .finalAnswer(let text) = event { final = text }
            if case .failure(let reason) = event { failure = reason }
            if case .error(let error) = event { Issue.record("unexpected error: \(error)") }
        }
        #expect(final == nil)
        #expect(failure?.contains("builtin.outputLengthCap") == true)
    }

    @Test func workflowPlanningRejectsDirectToolCallsWithoutInvokingTool() async throws {
        let flag = InvocationFlag()
        let registry = ToolRegistry()
        await registry.register(NavigateTool { _ in
            await flag.mark()
            return .init(navigated: true)
        })
        let resolver = ContextResolver()
        await resolver.push(ViewContext(
            id: .init("home"), displayName: "Home", toolNames: ["navigate"]
        ))
        let provider = MockProvider(responses: [
            LLMResponse(
                content: [.toolUse(
                    id: "t1", name: "navigate",
                    arguments: .object(["destination": .string("settings")])
                )],
                stopReason: .toolUse
            ),
        ])
        let orchestrator = Orchestrator(
            llm: LLMClient(provider: provider),
            tools: registry,
            memory: InMemoryMemoryStore(),
            contextResolver: resolver,
            guardrails: PolicyEngine(),
            options: .init(model: "test", stream: false)
        )

        var caught: (any Error)?
        for try await event in await orchestrator.run("Go to settings") {
            if case .error(let error) = event { caught = error }
        }
        #expect(caught is OutputParser.ParserError)
        #expect(await flag.didInvoke == false)
        #expect(provider.receivedRequests.count == 1)
    }

    @Test func malformedToolInputCorrectedOnSecondAttemptWithoutOrphanToolMessage() async throws {
        let registry = ToolRegistry()
        await registry.register(NavigateTool { input in
            .init(navigated: input.destination == "settings")
        })
        let resolver = ContextResolver()
        await resolver.push(ViewContext(
            id: .init("home"), displayName: "Home", toolNames: ["navigate"]
        ))
        let provider = MockProvider(responses: [
            LLMResponse(content: [.toolUse(
                id: "bad", name: "navigate",
                arguments: .object(["destination": .number(42)])
            )], stopReason: .toolUse),
            LLMResponse(content: [.toolUse(
                id: "good", name: "navigate",
                arguments: .object(["destination": .string("settings")])
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
                retry: .init(maxAttempts: 2, backoff: .none),
                workflowPlanning: false
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
        await registry.register(NavigateTool { input in
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
                arguments: .object(["__aikit_malformed_tool_input_raw": .string(raw)])
            )], stopReason: .toolUse),
            LLMResponse(content: [.toolUse(
                id: "good", name: "navigate",
                arguments: .object(["destination": .string("settings")])
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
                retry: .init(maxAttempts: 2, backoff: .none),
                workflowPlanning: false
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
        await registry.register(NavigateTool { _ in
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
                arguments: .object(["destination": .string("settings")])
            )], stopReason: .toolUse),
            LLMResponse(content: [.toolUse(
                id: "retry", name: "navigate",
                arguments: .object(["destination": .string("settings")])
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
                retry: .init(maxAttempts: 2, backoff: .none),
                workflowPlanning: false
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
        await registry.register(NavigateTool { _ in
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
            toolNames: ["navigate", EmptyInputTool.toolName]
        ))
        let provider = MockProvider(responses: [
            LLMResponse(content: [
                .toolUse(
                    id: "first", name: "navigate",
                    arguments: .object(["destination": .string("settings")])
                ),
                .toolUse(id: "second", name: EmptyInputTool.toolName, arguments: .object([:])),
            ], stopReason: .toolUse),
            LLMResponse(content: [.toolUse(
                id: "retry", name: "navigate",
                arguments: .object(["destination": .string("settings")])
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
                retry: .init(maxAttempts: 2, backoff: .none),
                workflowPlanning: false
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
        await registry.register(NavigateTool { _ in
            throw GenericToolError(message: "permanent navigation failure")
        })
        let resolver = ContextResolver()
        await resolver.push(ViewContext(
            id: .init("home"), displayName: "Home", toolNames: ["navigate"]
        ))
        let provider = MockProvider(responses: [
            LLMResponse(content: [.toolUse(
                id: "failed", name: "navigate",
                arguments: .object(["destination": .string("settings")])
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
                retry: .init(maxAttempts: 1, backoff: .none),
                workflowPlanning: false
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
        await registry.register(NavigateTool { _ in
            throw GenericToolError(message: "contains blocked output")
        })
        let resolver = ContextResolver()
        await resolver.push(ViewContext(
            id: .init("home"), displayName: "Home", toolNames: ["navigate"]
        ))
        let provider = MockProvider(responses: [
            LLMResponse(content: [.toolUse(
                id: "failed", name: "navigate",
                arguments: .object(["destination": .string("settings")])
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
                retry: .init(maxAttempts: 1, backoff: .none),
                workflowPlanning: false
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
            id: .init("v"), displayName: "V", toolNames: [EmptyInputTool.toolName]
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
                    arguments: .object(["destination": .string("settings")])
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

    @Test func defaultsToProviderConfigurationModelWhenOptionUnset() async throws {
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
        await registry.register(NavigateTool { input in
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
                arguments: .object(["destination": .string("email me at a@b.com")])
            )], stopReason: .toolUse),
            LLMResponse(content: [.text("ok")], stopReason: .endTurn),
        ])
        let orchestrator = Orchestrator(
            llm: LLMClient(provider: provider),
            tools: registry,
            memory: InMemoryMemoryStore(),
            contextResolver: resolver,
            guardrails: PolicyEngine(rails: [PIIRedactor(mode: .redact)]),
            options: .init(stream: false, workflowPlanning: false)
        )
        for try await event in await orchestrator.run("go") {
            if case .error(let e) = event { Issue.record("unexpected: \(e)") }
        }
        let destination = await seen.value
        #expect(destination?.contains("[REDACTED]") == true)
        #expect(destination?.contains("a@b.com") == false)
    }

    @Test func workflowSpecExecutesTopologicalDAGWithoutSecondLLMCall() async throws {
        let recorder = WorkflowRecorder()
        let registry = ToolRegistry()
        await registry.register(FindContactTool(recorder: recorder))
        await registry.register(CreateReminderTool(recorder: recorder))
        await registry.register(NavigateTool { input in
            await recorder.record("navigate:\(input.destination)")
            return .init(navigated: true)
        })
        let resolver = ContextResolver()
        await resolver.push(ViewContext(
            id: .init("home"),
            displayName: "Home",
            toolNames: ["findContact", "createReminder", "navigate"]
        ))
        let workflow = try workflowJSONString(WorkflowSpec(
            workflowID: "wf_call_alex",
            intent: "Find Alex, create a reminder, and open reminders.",
            nodes: [
                WorkflowNode(
                    id: "find_alex",
                    tool: "findContact",
                    input: .object(["query": .string("Alex")])
                ),
                WorkflowNode(
                    id: "make_reminder",
                    tool: "createReminder",
                    dependsOn: ["find_alex"],
                    input: .object([
                        "title": .string("Call Alex"),
                        "contactID": workflowRef(node: "find_alex", path: "/contactID"),
                    ])
                ),
                WorkflowNode(
                    id: "open_reminders",
                    tool: "navigate",
                    dependsOn: ["make_reminder"],
                    input: .object(["destination": .string("reminders")])
                ),
            ],
            final: .message("Done.")
        ))
        let provider = MockProvider(responses: [
            LLMResponse(content: [.text(workflow)], stopReason: .endTurn),
        ])
        let orchestrator = Orchestrator(
            llm: LLMClient(provider: provider),
            tools: registry,
            memory: InMemoryMemoryStore(),
            contextResolver: resolver,
            guardrails: PolicyEngine(),
            options: .init(model: "test", stream: false)
        )

        var toolNames: [String] = []
        var final: String?
        for try await event in await orchestrator.run(
            "Find Alex, create a reminder to call them, then open reminders."
        ) {
            if case .toolCall(let name, _) = event { toolNames.append(name) }
            if case .finalAnswer(let answer) = event { final = answer }
            if case .error(let error) = event { Issue.record("unexpected: \(error)") }
        }

        #expect(toolNames == ["findContact", "createReminder", "navigate"])
        #expect(final == "Done.")
        #expect(provider.receivedRequests.count == 1)
        #expect(await recorder.events == [
            "find:Alex",
            "reminder:Call Alex:contact-alex",
            "navigate:reminders",
        ])
    }
}

private func workflowJSONString(_ spec: WorkflowSpec) throws -> String {
    workflowContent(spec).jsonString
}

private func workflowContent(_ spec: WorkflowSpec) -> GeneratedContent {
    .object([
        "schema_version": .string(spec.schemaVersion),
        "workflow_id": .string(spec.workflowID),
        "intent": .string(spec.intent),
        "mode": .string(spec.mode.rawValue),
        "nodes": .array(spec.nodes.map(workflowNodeContent)),
        "final": workflowFinalContent(spec.final),
    ])
}

private func workflowNodeContent(_ node: WorkflowNode) -> GeneratedContent {
    var object: [String: GeneratedContent] = [
        "id": .string(node.id),
        "kind": .string(node.kind.rawValue),
        "input": node.input,
    ]
    if let tool = node.tool {
        object["tool"] = .string(tool)
    }
    if !node.dependsOn.isEmpty {
        object["depends_on"] = .array(node.dependsOn.map { .string($0) })
    }
    if node.policy != .default {
        object["policy"] = workflowNodePolicyContent(node.policy)
    }
    return .object(object)
}

private func workflowNodePolicyContent(_ policy: WorkflowNodePolicy) -> GeneratedContent {
    var object: [String: GeneratedContent] = [
        "on_error": .string(policy.onError.rawValue),
    ]
    if policy.timeoutMS != WorkflowNodePolicy.defaultTimeoutMS {
        object["timeout_ms"] = .int(policy.timeoutMS)
    }
    if policy.retry != .default {
        object["retry"] = .object([
            "max_attempts": .int(policy.retry.maxAttempts),
            "backoff_ms": .int(policy.retry.backoffMS),
            "retry_only_if_tool_error_is_retriable": .bool(
                policy.retry.retryOnlyIfToolErrorIsRetriable
            ),
        ])
    }
    if let defaultOutput = policy.defaultOutput {
        object["default_output"] = defaultOutput
    }
    return .object(object)
}

private func workflowFinalContent(_ final: WorkflowFinal) -> GeneratedContent {
    var object: [String: GeneratedContent] = [
        "kind": .string(final.kind.rawValue),
    ]
    if let value = final.value {
        object["value"] = value
    }
    if let template = final.template {
        object["template"] = .string(template)
    }
    if !final.bindings.isEmpty {
        object["bindings"] = .object(final.bindings)
    }
    if let node = final.node {
        object["node"] = .string(node)
    }
    if let path = final.path {
        object["path"] = .string(path)
    }
    if let message = final.message {
        object["message"] = .string(message)
    }
    return .object(object)
}

private func workflowRef(node: String, path: String) -> GeneratedContent {
    .object([
        "$ref": .object([
            "source": .string("node"),
            "node": .string(node),
            "path": .string(path),
        ]),
    ])
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

private actor WorkflowRecorder {
    private(set) var events: [String] = []

    func record(_ event: String) {
        events.append(event)
    }
}

private actor PostToolUseRecorder {
    private(set) var values: [Bool] = []

    func record(_ isError: Bool) {
        values.append(isError)
    }
}

private struct PostToolUseOutputEntry: Sendable, Equatable {
    let text: String
}

private actor PostToolUseOutputRecorder {
    private(set) var entries: [PostToolUseOutputEntry] = []

    func record(output: Data) {
        entries.append(PostToolUseOutputEntry(
            text: String(decoding: output, as: UTF8.self)
        ))
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

private struct RecordingPostToolUseOutputRail: Guardrail {
    let id = "record-post-tool-use-output"
    let stages: Set<Verifier.Stage> = [.postToolUse]
    let recorder: PostToolUseOutputRecorder

    func evaluate(_ payload: GuardrailPayload) async -> Verifier.Outcome {
        if case .postToolUse(_, let output, false) = payload {
            await recorder.record(output: output)
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

private struct FindContactTool: Tool {
    @Generable
    struct Input: Codable, Sendable {
        var query: String
    }

    @Generable
    struct Output: Codable, Sendable {
        var contactID: String
        var displayName: String
    }

    static let toolName = "findContact"
    let name = Self.toolName
    let description = "Find a contact by name."
    let recorder: WorkflowRecorder

    func call(arguments input: Input) async throws -> Output {
        await recorder.record("find:\(input.query)")
        return Output(contactID: "contact-alex", displayName: input.query)
    }
}

private struct CreateReminderTool: Tool {
    @Generable
    struct Input: Codable, Sendable {
        var title: String
        var contactID: String
    }

    @Generable
    struct Output: Codable, Sendable {
        var reminderID: String
        var title: String
        var contactID: String
    }

    static let toolName = "createReminder"
    let name = Self.toolName
    let description = "Create a reminder, optionally attached to a contact."
    let recorder: WorkflowRecorder

    func call(arguments input: Input) async throws -> Output {
        await recorder.record("reminder:\(input.title):\(input.contactID)")
        return Output(
            reminderID: "reminder-1",
            title: input.title,
            contactID: input.contactID
        )
    }
}

private struct EmptyInputTool: Tool {
    @Generable
    struct Input: Codable, Sendable {
        init() {}
    }
    @Generable
    struct Output: Codable, Sendable {
        var ok: Bool
    }

    static let toolName = "emptyInput"
    let name = Self.toolName
    let description = "A no-input test tool."
    let handler: @Sendable () async -> Void

    init(handler: @escaping @Sendable () async -> Void) {
        self.handler = handler
    }

    func call(arguments input: Input) async throws -> Output {
        await handler()
        return Output(ok: true)
    }
}

private struct SensitiveOutputTool: Tool {
    @Generable
    struct Input: Codable, Sendable {
        init() {}
    }
    @Generable
    struct Output: Codable, Sendable {
        var secret: String
    }

    static let toolName = "sensitiveOutput"
    let name = Self.toolName
    let description = "Returns sensitive content for guardrail tests."

    func call(arguments input: Input) async throws -> Output {
        Output(secret: "top-secret")
    }
}

private struct MalformedStreamingToolProvider: LLMProvider {
    let configuration = LLMProviderConfiguration(
        apiKey: "",
        baseURL: URL(string: "mock://malformed-stream")!,
        defaultModel: "malformed-stream"
    )

    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        LLMResponse(content: [.text("unused")], stopReason: .endTurn)
    }

    func stream(
        _ request: LLMRequest
    ) -> AsyncThrowingStream<LLMResponseChunk, any Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.toolUseStart(id: "bad_1", name: EmptyInputTool.toolName))
            continuation.yield(.toolUseInputDelta(id: "bad_1", json: "{\"unterminated\":"))
            continuation.yield(.toolUseStop(id: "bad_1"))
            continuation.yield(.stop(.toolUse))
            continuation.finish()
        }
    }
}

/// Always sleeps before answering, so a turn deadline must interrupt it.
private final class SlowProvider: LLMProvider, @unchecked Sendable {
    let configuration = LLMProviderConfiguration(
        apiKey: "",
        baseURL: URL(string: "mock://slow")!,
        defaultModel: "slow"
    )
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
    /// A fenced-fallback recovery must be recorded as a structured `tool_use`
    /// block, with the following `tool_result` carrying the matching id.
    @Test func fencedFallbackRecordsStructuredToolUse() async throws {
        let registry = ToolRegistry()
        await registry.register(NavigateTool { input in
            .init(navigated: input.destination == "settings")
        })
        let resolver = ContextResolver()
        await resolver.push(ViewContext(
            id: .init("home"), displayName: "Home",
            systemPromptFragment: "You can navigate.", toolNames: ["navigate"]
        ))
        let fenced = "Working on it.\n```tool\n"
            + "{\"name\":\"navigate\",\"arguments\":{\"destination\":\"settings\"}}\n```"
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
            options: .init(
                model: "test", stream: false,
                toolCallFallback: true, workflowPlanning: false
            )
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

    /// The fenced-fallback prompt instruction is gated on provider capability
    /// when `toolCallFallback` is left unset.
    @Test func fallbackHintGatedByProviderCapability() async throws {
        func systemPrompt(nativeTools: Bool) async throws -> String {
            let resolver = ContextResolver()
            await resolver.push(ViewContext(
                id: .init("v"), displayName: "V", toolNames: ["navigate"]
            ))
            let registry = ToolRegistry()
            await registry.register(NavigateTool { _ in .init(navigated: true) })
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
                options: .init(model: "test", stream: false, workflowPlanning: false)
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

/// A guardrail that sleeps before answering, proving turn deadlines also race
/// guardrail passes.
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
    /// The fenced fallback must fire exactly when intended across
    /// `supportsNativeTools` × `toolCallFallback`. The model emits only a fenced
    /// ```tool block, so the tool runs iff the fallback is active.
    private func run(
        nativeTools: Bool, fallback: Bool?
    ) async throws -> (toolRan: Bool, final: String?) {
        let registry = ToolRegistry()
        await registry.register(NavigateTool { _ in .init(navigated: true) })
        let resolver = ContextResolver()
        await resolver.push(ViewContext(
            id: .init("home"), displayName: "Home", toolNames: ["navigate"]
        ))
        let fenced = "```tool\n{\"name\":\"navigate\","
            + "\"arguments\":{\"destination\":\"home\"}}\n```"
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
                model: "test", stream: false,
                toolCallFallback: fallback, workflowPlanning: false
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

    /// Reasoning is surfaced as a distinct event.
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
            + "{\"name\":\"navigate\",\"arguments\":{\"destination\":\"home\"}}\n```"
        #expect(OutputParser.nearMissFencedToolBlock(in: json))
        // A correctly tagged block is not a near-miss (it gets recovered).
        let tagged = "```tool\n{\"name\":\"x\",\"arguments\":{}}\n```"
        #expect(!OutputParser.nearMissFencedToolBlock(in: tagged))
        // Prose with no tool-shaped JSON is not a near-miss.
        #expect(!OutputParser.nearMissFencedToolBlock(in: "All done, no tools."))
        #expect(!OutputParser.nearMissFencedToolBlock(
            in: "```json\n{\"result\": 42}\n```"
        ))
    }

    /// A ```json-fenced tool call is delivered as the final answer and not
    /// executed, but a diagnostic warning is surfaced.
    @Test func emitsWarningAndDoesNotExecute() async throws {
        let flag = InvocationFlag()
        let registry = ToolRegistry()
        await registry.register(NavigateTool { _ in
            await flag.mark()
            return .init(navigated: true)
        })
        let resolver = ContextResolver()
        await resolver.push(ViewContext(
            id: .init("home"), displayName: "Home", toolNames: ["navigate"]
        ))
        let mistagged = "```json\n"
            + "{\"name\":\"navigate\",\"arguments\":{\"destination\":\"home\"}}\n```"
        let provider = MockProvider(responses: [
            LLMResponse(content: [.text(mistagged)], stopReason: .endTurn)
        ])
        let orchestrator = Orchestrator(
            llm: LLMClient(provider: provider),
            tools: registry,
            memory: InMemoryMemoryStore(),
            contextResolver: resolver,
            guardrails: PolicyEngine(),
            options: .init(
                model: "test", stream: false,
                toolCallFallback: true, workflowPlanning: false
            )
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
    /// A zero budget aborts before any work.
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

    /// A hung tool must not be able to overrun the budget; the invocation is
    /// raced against the deadline too.
    @Test func deadlineInterruptsHangingTool() async throws {
        let registry = ToolRegistry()
        await registry.register(NavigateTool { _ in
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
                arguments: .object(["destination": .string("home")])
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
                retry: .init(maxAttempts: 1), maxTurnDuration: 0.2,
                workflowPlanning: false
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

/// Unit coverage for the string-aware JSON extraction the two-round runner
/// relies on. The runner's integration tests only feed it clean JSON; these
/// pin the documented edge cases — code fences, a stray trailing brace from a
/// weak model's `{{slot}}` brace miscount, and `{{label}}` tokens inside string
/// values — that the scanner exists to survive.
@Suite struct WorkflowJSONExtractionTests {
    // MARK: firstBalancedObject

    @Test func returnsWholeObject() {
        #expect(WorkflowTwoRoundRunner.firstBalancedObject(in: #"{"a":1}"#) == #"{"a":1}"#)
    }

    @Test func dropsStrayTrailingBrace() {
        // Weak planners on the {{slot}} authoring path append an extra "}".
        #expect(WorkflowTwoRoundRunner.firstBalancedObject(in: #"{"a":1}}"#) == #"{"a":1}"#)
    }

    @Test func ignoresBracesInsideStrings() {
        let input = #"{"body":"Hi {{name}}!"}"#
        #expect(WorkflowTwoRoundRunner.firstBalancedObject(in: input) == input)
    }

    @Test func honoursEscapedQuotes() {
        let input = #"{"a":"say \"hi\""}"#
        #expect(WorkflowTwoRoundRunner.firstBalancedObject(in: input) == input)
    }

    @Test func skipsLeadingProse() {
        #expect(WorkflowTwoRoundRunner.firstBalancedObject(in: #"sure: {"a":1} done"#) == #"{"a":1}"#)
    }

    @Test func handlesNesting() {
        let input = #"{"a":{"b":2}}"#
        #expect(WorkflowTwoRoundRunner.firstBalancedObject(in: input) == input)
    }

    @Test func returnsNilWithoutBraces() {
        #expect(WorkflowTwoRoundRunner.firstBalancedObject(in: "no json here") == nil)
    }

    // MARK: extractJSONObject

    @Test func extractsToolUseInput() throws {
        let response = LLMResponse(
            content: [.toolUse(
                id: "t1", name: "navigate",
                arguments: .object(["destination": .string("settings")])
            )],
            stopReason: .toolUse
        )
        let value = try #require(WorkflowTwoRoundRunner.extractJSONObject(from: response))
        let object = try #require(value.objectValue)
        #expect(object["destination"]?.stringValue == "settings")
    }

    @Test func extractsFromFencedJSONBlock() throws {
        let response = LLMResponse(
            content: [.text("```json\n{\"k\":\"v\"}\n```")],
            stopReason: .endTurn
        )
        let value = try #require(WorkflowTwoRoundRunner.extractJSONObject(from: response))
        let object = try #require(value.objectValue)
        #expect(object["k"]?.stringValue == "v")
    }

    @Test func extractsDespiteTrailingBrace() throws {
        let response = LLMResponse(
            content: [.text("{\"k\":\"v\"}}")],
            stopReason: .endTurn
        )
        let value = try #require(WorkflowTwoRoundRunner.extractJSONObject(from: response))
        let object = try #require(value.objectValue)
        #expect(object["k"]?.stringValue == "v")
    }

    @Test func extractsAfterLeadingProse() throws {
        let response = LLMResponse(
            content: [.text("Here is the plan:\n{\"k\":\"v\"}")],
            stopReason: .endTurn
        )
        let value = try #require(WorkflowTwoRoundRunner.extractJSONObject(from: response))
        let object = try #require(value.objectValue)
        #expect(object["k"]?.stringValue == "v")
    }

    @Test func returnsNilWhenNoJSONPresent() {
        let response = LLMResponse(
            content: [.text("just some prose, no json")],
            stopReason: .endTurn
        )
        #expect(WorkflowTwoRoundRunner.extractJSONObject(from: response) == nil)
    }
}
