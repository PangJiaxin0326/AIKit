import FoundationModels
import AIKitCore
import AIKitCapability
import AIKitRuntime
import AIKitSafety

extension OrchestratorModel {
    /// One of AIKit's shipped models.
    @available(*, deprecated, message: "Apply the model to the profile with `.model(_:)`; usage-record labels move to AIKitConversation.UsageLabels.")
    public init(_ model: AIKitLanguageModel) {
        self.init(model: model.base, modelID: model.modelID,
                  providerName: model.providerKind.definition.displayName)
    }
}

extension Orchestrator {
    /// Convenience over one of AIKit's shipped models.
    @available(*, deprecated, message: "The Orchestrator pipeline is superseded by the official session driven directly: build a DynamicProfile (model, generation options, `.guardrails(_:)`, `.refusalEscapeHatch()`), run it with LanguageModelSession(profile:) — or AIKitConversation for retry/deadline/usage policies. See the AIKit README migration table.")
    public init(
        model: AIKitLanguageModel,
        tools: [any Tool],
        memory: any MemoryStore,
        contextResolver: ContextResolver,
        guardrails: PolicyEngine,
        usageRecorder: (any AIKitSessionUsageRecording)? = nil,
        options: Options = .init()
    ) {
        self.init(
            model: OrchestratorModel(model),
            tools: tools,
            memory: memory,
            contextResolver: contextResolver,
            guardrails: guardrails,
            usageRecorder: usageRecorder,
            options: options
        )
    }

}
