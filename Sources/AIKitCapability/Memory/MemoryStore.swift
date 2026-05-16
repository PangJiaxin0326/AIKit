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
        let filtered = view.map { id in events.filter { $0.viewID == id } } ?? events
        return Array(filtered.sorted { $0.timestamp > $1.timestamp }.prefix(max(0, limit)))
    }

    public func search(query: String, limit: Int) async throws -> [UsageEvent] {
        guard !query.isEmpty else { return [] }
        let lowered = query.lowercased()
        let matches = events.filter {
            $0.payloadText.lowercased().contains(lowered)
                || $0.kind.rawValue.lowercased().contains(lowered)
        }
        return Array(matches.sorted { $0.timestamp > $1.timestamp }.prefix(max(0, limit)))
    }

    public func delete(id: UUID) async throws {
        events.removeAll { $0.id == id }
    }
}
