import Foundation
import FoundationModels
import Testing
import AIKit
import AIKitTestSupport

// MARK: - Helpers

@Generable
private struct PresenterToolArguments {
    let destination: String
}

@Generable
private struct PresenterToolOutput {
    let navigated: Bool
}

private struct PresenterNavigateTool: Tool {
    var name: String { "navigate" }
    var description: String { "Navigate to a destination." }

    func call(arguments: PresenterToolArguments) async throws -> PresenterToolOutput {
        PresenterToolOutput(navigated: true)
    }
}

/// Hangs cancellably, so a mid-stream cancellation can be exercised.
private struct PresenterSleepingTool: Tool {
    var name: String { "park" }
    var description: String { "Sleep well past the test's patience." }

    func call(arguments: PresenterToolArguments) async throws -> PresenterToolOutput {
        try await Task.sleep(for: .seconds(60))
        return PresenterToolOutput(navigated: false)
    }
}

/// Builds the session outside the main actor: a profile assembled in a
/// `@MainActor` context is main-actor-connected and cannot be sent into
/// `LanguageModelSession(profile:)` (the region-isolation trap pinned in
/// the package notes).
private func makeSession(
    model: MockLanguageModel,
    tools: [any Tool]
) -> LanguageModelSession {
    LanguageModelSession(
        profile: LanguageModelSession.Profile {
            Instructions("Assist the user.")
            tools
        }
        .model(model)
    )
}

@MainActor
private func makePresenter(
    model: MockLanguageModel,
    tools: [any Tool] = []
) -> AIKitConversationPresenter {
    AIKitConversationPresenter(
        conversation: AIKitConversation(session: makeSession(model: model, tools: tools))
    )
}

// MARK: - Phase 3 gates: UI projection of official session surfaces

@Suite struct PresenterTests {
    /// The final lines are a pure transcript projection — the user's prompt
    /// and the terminal answer — and no streamed text is left dangling.
    @MainActor
    @Test func linesDeriveFromTheTranscript() async throws {
        let presenter = makePresenter(model: MockLanguageModel(finalText: "Hello there."))

        await presenter.send("hi")

        #expect(presenter.lines.map(\.role) == [.user, .assistant])
        #expect(presenter.lines.last?.text == "Hello there.")
        #expect(presenter.streamingText.isEmpty)
        #expect(presenter.reasoningText.isEmpty)
        #expect(!presenter.isResponding)
        #expect(presenter.lastError == nil)
    }

    /// Tool calls and outputs appear exactly once each, in transcript order,
    /// alongside reasoning — no duplicated activity.
    @MainActor
    @Test func toolActivityAppearsExactlyOnce() async throws {
        let model = MockLanguageModel(turns: [
            .init(
                reasoning: "The user wants settings.",
                toolCalls: [.init(
                    id: "t1", name: "navigate",
                    argumentsJSON: #"{"destination":"settings"}"#
                )]
            ),
            .init(text: "You're in settings."),
        ])
        let presenter = makePresenter(model: model, tools: [PresenterNavigateTool()])

        await presenter.send("open settings")

        let toolCalls = presenter.lines.filter { $0.role == .toolCall }
        let toolOutputs = presenter.lines.filter { $0.role == .toolOutput }
        #expect(toolCalls.count == 1)
        #expect(toolCalls.first?.text == "navigate")
        #expect(toolOutputs.count == 1)
        #expect(presenter.lines.contains { $0.role == .reasoning })
        #expect(presenter.lines.last?.role == .assistant)
        #expect(presenter.lines.last?.text == "You're in settings.")
    }

    /// Cancellation leaves no false final answer: the rolled-back attempt
    /// contributes no lines and no leftover streaming text.
    @MainActor
    @Test func cancellationLeavesNoFalseFinalAnswer() async throws {
        let model = MockLanguageModel(turns: [
            .init(toolCalls: [.init(
                id: "t1", name: "park", argumentsJSON: #"{"destination":"x"}"#
            )]),
            .init(text: "never delivered"),
        ])
        let presenter = makePresenter(model: model, tools: [PresenterSleepingTool()])

        let turn = Task { await presenter.send("go") }
        while model.receivedRequests.isEmpty {
            await Task.yield()
        }
        turn.cancel()
        await turn.value

        #expect(!presenter.lines.contains { $0.role == .assistant })
        #expect(presenter.streamingText.isEmpty)
        #expect(!presenter.isResponding)
    }

    /// Usage mirrors the official cumulative session usage.
    @MainActor
    @Test func usageMirrorsTheOfficialTotals() async throws {
        let model = MockLanguageModel(turns: [
            .init(text: "One.", inputTokens: 10, outputTokens: 2),
            .init(text: "Two.", inputTokens: 20, outputTokens: 3),
        ])
        let presenter = makePresenter(model: model)

        await presenter.send("first")
        await presenter.send("second")

        #expect(presenter.totalUsage == TokenUsage(inputTokens: 30, outputTokens: 5))
        #expect(presenter.totalUsage == TokenUsage(presenter.conversation.session.usage))
    }
}
