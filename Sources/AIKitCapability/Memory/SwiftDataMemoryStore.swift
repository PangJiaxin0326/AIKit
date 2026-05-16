import Foundation
import SwiftData
import AIKitCore

/// Persisted row backing a `UsageEvent`. `ViewContext.ID` and
/// `UsageEvent.Kind` are stored by their raw string so the model stays a
/// flat, migration-friendly record.
@Model
final class StoredUsageEvent {
    var id: UUID
    var timestamp: Date
    var viewRawValue: String
    var kindRawValue: String
    var payload: Data

    init(
        id: UUID,
        timestamp: Date,
        viewRawValue: String,
        kindRawValue: String,
        payload: Data
    ) {
        self.id = id
        self.timestamp = timestamp
        self.viewRawValue = viewRawValue
        self.kindRawValue = kindRawValue
        self.payload = payload
    }

    var asUsageEvent: UsageEvent {
        UsageEvent(
            id: id,
            timestamp: timestamp,
            viewID: ViewContext.ID(viewRawValue),
            kind: UsageEvent.Kind(rawValue: kindRawValue) ?? .error,
            payload: payload
        )
    }
}

/// SwiftData-backed `MemoryStore` with no third-party dependencies. The log is
/// append-only: `append` only ever inserts, never replaces, and the sole
/// destructive operation is `delete(id:)`.
public actor SwiftDataMemoryStore: MemoryStore {
    public enum StoreError: Error, Sendable {
        case open(String)
    }

    private let container: ModelContainer
    private let context: ModelContext

    /// - Parameter path: file path, or `nil` for an in-memory store.
    public init(path: String? = nil) throws {
        let configuration = path.map {
            ModelConfiguration(url: URL(fileURLWithPath: $0))
        } ?? ModelConfiguration(isStoredInMemoryOnly: true)
        do {
            container = try ModelContainer(
                for: StoredUsageEvent.self,
                configurations: configuration
            )
        } catch {
            throw StoreError.open(String(describing: error))
        }
        context = ModelContext(container)
    }

    public func append(_ event: UsageEvent) async throws {
        context.insert(StoredUsageEvent(
            id: event.id,
            timestamp: event.timestamp,
            viewRawValue: event.viewID.rawValue,
            kindRawValue: event.kind.rawValue,
            payload: event.payload
        ))
        try context.save()
    }

    public func recent(limit: Int, view: ViewContext.ID?) async throws -> [UsageEvent] {
        let raw = view?.rawValue
        var descriptor = FetchDescriptor<StoredUsageEvent>(
            predicate: raw.map { value in
                #Predicate<StoredUsageEvent> { $0.viewRawValue == value }
            },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = max(0, limit)
        return try context.fetch(descriptor).map(\.asUsageEvent)
    }

    public func search(query: String, limit: Int) async throws -> [UsageEvent] {
        guard !query.isEmpty else { return [] }
        let lowered = query.lowercased()
        let descriptor = FetchDescriptor<StoredUsageEvent>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        // Keyword search runs in Swift so the payload blob can be decoded as
        // text; it mirrors `InMemoryMemoryStore` and treats the query
        // literally (no LIKE-style wildcards).
        let matches = try context.fetch(descriptor).filter { row in
            let text = String(decoding: row.payload, as: UTF8.self).lowercased()
            return text.contains(lowered)
                || row.kindRawValue.lowercased().contains(lowered)
        }
        return Array(matches.prefix(max(0, limit)).map(\.asUsageEvent))
    }

    public func delete(id: UUID) async throws {
        try context.delete(
            model: StoredUsageEvent.self,
            where: #Predicate<StoredUsageEvent> { $0.id == id }
        )
        try context.save()
    }
}
