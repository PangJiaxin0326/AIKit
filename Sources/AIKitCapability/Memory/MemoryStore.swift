import Foundation
import AIKitCore

/// Append-only log of usage events with windowed reads. Entries are never
/// mutated in place; the only destructive operation is `delete`, used to
/// forget a single record. Backend is pluggable; `search` is keyword-based in
/// v1 (shaped to allow a vector backend later).
public protocol MemoryStore: Sendable {
    func append(_ event: UsageEvent) async throws
    func recent(limit: Int, view: ViewContext.ID?) async throws -> [UsageEvent]
    func search(query: String, limit: Int) async throws -> [UsageEvent]
    func delete(id: UUID) async throws
}

/// In-memory `MemoryStore` for tests and ephemeral hosts.
public actor InMemoryMemoryStore: MemoryStore {
    private var events: [UsageEvent] = []

    public init() {}

    public func append(_ event: UsageEvent) async throws {
        events.append(event)
    }

    public func recent(limit: Int, view: ViewContext.ID?) async throws -> [UsageEvent] {
        let limit = max(0, limit)
        guard limit > 0 else { return [] }
        var result: [UsageEvent] = []
        result.reserveCapacity(limit)
        for event in events.reversed() {
            if let view, event.viewID != view { continue }
            result.append(event)
            if result.count == limit { break }
        }
        return result
    }

    public func search(query: String, limit: Int) async throws -> [UsageEvent] {
        let limit = max(0, limit)
        guard !query.isEmpty, limit > 0 else { return [] }
        let lowered = query.lowercased()
        var result: [UsageEvent] = []
        result.reserveCapacity(limit)
        for event in events.reversed() {
            guard event.payloadText.lowercased().contains(lowered)
                    || event.kind.rawValue.lowercased().contains(lowered)
            else { continue }
            result.append(event)
            if result.count == limit { break }
        }
        return result
    }

    public func delete(id: UUID) async throws {
        events.removeAll { $0.id == id }
    }
}
