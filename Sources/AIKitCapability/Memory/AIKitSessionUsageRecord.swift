import Foundation
import SwiftData
import AIKitCore

/// Outcome captured for a completed usage record. Stored by raw value in
/// `AIKitSessionUsageRecord` so future cases remain migration-friendly.
public enum AIKitSessionUsageOutcome: String, Codable, Sendable, Hashable {
    case completed
    case failed
    case cancelled
    case refused
}

/// Durable aggregate usage stats for one AIKit session.
///
/// The record intentionally stores only an opaque `taskID`, not a relationship
/// to a task model, so usage history can remain after task details are deleted.
@Model
public final class AIKitSessionUsageRecord {
    #Index<AIKitSessionUsageRecord>([\.taskID], [\.startedAt], [\.modelName])

    public var id: UUID = UUID()
    public var taskID: String = ""
    public var modelName: String = ""
    public var providerName: String?
    public var startedAt: Date = Date(timeIntervalSince1970: 0)
    public var endedAt: Date?
    public var durationSeconds: TimeInterval = 0
    public var roundTripCount: Int = 0
    public var messageCount: Int = 0
    public var inputTokens: Int = 0
    public var outputTokens: Int = 0
    public var outcomeRawValue: String = AIKitSessionUsageOutcome.completed.rawValue
    public var recordedAt: Date = Date(timeIntervalSince1970: 0)

    public init(
        id: UUID = UUID(),
        taskID: String,
        modelName: String,
        providerName: String? = nil,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        durationSeconds: TimeInterval,
        roundTripCount: Int,
        messageCount: Int = 0,
        inputTokens: Int,
        outputTokens: Int,
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
        self.inputTokens = max(0, inputTokens)
        self.outputTokens = max(0, outputTokens)
        self.outcomeRawValue = outcome.rawValue
        self.recordedAt = recordedAt
    }

    public convenience init(
        id: UUID = UUID(),
        taskID: String,
        modelName: String,
        providerName: String? = nil,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        durationSeconds: TimeInterval,
        roundTripCount: Int,
        messageCount: Int = 0,
        usage: TokenUsage,
        outcome: AIKitSessionUsageOutcome = .completed,
        recordedAt: Date = Date()
    ) {
        self.init(
            id: id,
            taskID: taskID,
            modelName: modelName,
            providerName: providerName,
            startedAt: startedAt,
            endedAt: endedAt,
            durationSeconds: durationSeconds,
            roundTripCount: roundTripCount,
            messageCount: messageCount,
            inputTokens: usage.inputTokens,
            outputTokens: usage.outputTokens,
            outcome: outcome,
            recordedAt: recordedAt
        )
    }

    public var usage: TokenUsage {
        get {
            TokenUsage(inputTokens: inputTokens, outputTokens: outputTokens)
        }
        set {
            inputTokens = max(0, newValue.inputTokens)
            outputTokens = max(0, newValue.outputTokens)
        }
    }

    public var outcome: AIKitSessionUsageOutcome {
        get {
            AIKitSessionUsageOutcome(rawValue: outcomeRawValue) ?? .failed
        }
        set {
            outcomeRawValue = newValue.rawValue
        }
    }

    public var totalTokens: Int {
        inputTokens + outputTokens
    }
}
