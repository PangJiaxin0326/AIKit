import Foundation
import AIKitCapability

/// Lightweight recorder for runtime tests that need to observe finalized
/// usage summaries without opening a SwiftData store.
public actor InMemorySessionUsageStore: AIKitSessionUsageRecording {
    private var summaries: [AIKitSessionUsageSummary] = []

    public init() {}

    public func record(_ summary: AIKitSessionUsageSummary) async throws {
        summaries.append(summary)
    }

    public func all() -> [AIKitSessionUsageSummary] {
        summaries
    }
}
