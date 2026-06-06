import Foundation
import SwiftData
import AIKitCore

/// Sendable task-level usage aggregate emitted by the runtime when a session
/// finishes. The SwiftData model stays inside `SwiftDataSessionUsageStore`.
public struct AIKitSessionUsageSummary: Sendable, Hashable, Codable {
    public let id: UUID
    public let taskID: String
    public let modelName: String
    public let providerName: String?
    public let startedAt: Date
    public let endedAt: Date?
    public let durationSeconds: TimeInterval
    public let roundTripCount: Int
    public let messageCount: Int
    public let usage: TokenUsage
    public let outcome: AIKitSessionUsageOutcome
    public let recordedAt: Date

    public init(
        id: UUID = UUID(),
        taskID: String,
        modelName: String,
        providerName: String? = nil,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        durationSeconds: TimeInterval,
        roundTripCount: Int,
        messageCount: Int,
        usage: TokenUsage,
        outcome: AIKitSessionUsageOutcome = .completed,
        recordedAt: Date = Date()
    ) {
        self.id = id
        self.taskID = taskID
        self.modelName = modelName
        self.providerName = providerName
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSeconds = max(0, durationSeconds)
        self.roundTripCount = max(0, roundTripCount)
        self.messageCount = max(0, messageCount)
        self.usage = TokenUsage(
            inputTokens: max(0, usage.inputTokens),
            outputTokens: max(0, usage.outputTokens)
        )
        self.outcome = outcome
        self.recordedAt = recordedAt
    }
}

/// Runtime-owned sink for durable AI session usage records.
public protocol AIKitSessionUsageRecording: Sendable {
    func record(_ summary: AIKitSessionUsageSummary) async throws
}

/// SwiftData-backed usage history. Host apps pass their `ModelContainer` once;
/// AIKit owns all per-task record creation and persistence.
@ModelActor
public actor SwiftDataSessionUsageStore: AIKitSessionUsageRecording {
    public func record(_ summary: AIKitSessionUsageSummary) async throws {
        let id = summary.id
        var descriptor = FetchDescriptor<AIKitSessionUsageRecord>(
            predicate: #Predicate<AIKitSessionUsageRecord> { $0.id == id }
        )
        descriptor.fetchLimit = 1

        if let existing = try modelContext.fetch(descriptor).first {
            existing.apply(summary)
        } else {
            let record = AIKitSessionUsageRecord(summary: summary)
            modelContext.insert(record)
        }

        try modelContext.save()
    }
}
