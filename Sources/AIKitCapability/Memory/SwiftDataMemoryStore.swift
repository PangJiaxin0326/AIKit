import Foundation
import SwiftData
import AIKitCore

/// Persisted row backing a `UsageEvent`. `ViewContext.ID` and
/// `UsageEvent.Kind` are stored by their raw string so the model stays a
/// flat, migration-friendly record.
@Model
final class StoredUsageEvent {
    #Index<StoredUsageEvent>([\.viewRawValue], [\.timestamp], [\.kindRawValue])

    var id: UUID = UUID()
    var timestamp: Date = Date(timeIntervalSince1970: 0)
    var viewRawValue: String = ""
    var kindRawValue: String = UsageEvent.Kind.error.rawValue
    var payloadText: String = ""
    var payload: Data = Data()

    init(
        id: UUID,
        timestamp: Date,
        viewRawValue: String,
        kindRawValue: String,
        payloadText: String,
        payload: Data
    ) {
        self.id = id
        self.timestamp = timestamp
        self.viewRawValue = viewRawValue
        self.kindRawValue = kindRawValue
        self.payloadText = payloadText
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
@ModelActor
public actor SwiftDataMemoryStore: MemoryStore {
    public enum StoreError: Error, Sendable {
        case open(String)
    }

    /// - Parameter path: file path, or `nil` for an in-memory store.
    public init(path: String? = nil) throws {
        let configuration = path.map {
            ModelConfiguration(
                url: URL(fileURLWithPath: $0),
                cloudKitDatabase: .none
            )
        } ?? ModelConfiguration(
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container: ModelContainer
        do {
            container = try ModelContainer(
                for: StoredUsageEvent.self,
                configurations: configuration
            )
        } catch {
            throw StoreError.open(String(describing: error))
        }
        let context = ModelContext(container)
        modelExecutor = DefaultSerialModelExecutor(modelContext: context)
        modelContainer = container
    }

    public func append(_ event: UsageEvent) async throws {
        modelContext.insert(StoredUsageEvent(
            id: event.id,
            timestamp: event.timestamp,
            viewRawValue: event.viewID.rawValue,
            kindRawValue: event.kind.rawValue,
            payloadText: event.payloadText,
            payload: event.payload
        ))
        try modelContext.save()
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
        return try modelContext.fetch(descriptor).map(\.asUsageEvent)
    }

    public func search(query: String, limit: Int) async throws -> [UsageEvent] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var descriptor = FetchDescriptor<StoredUsageEvent>(
            predicate: #Predicate<StoredUsageEvent> { row in
                row.payloadText.localizedStandardContains(trimmed)
                    || row.kindRawValue.localizedStandardContains(trimmed)
            },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = max(0, limit)
        return try modelContext.fetch(descriptor).map(\.asUsageEvent)
    }

    public func delete(id: UUID) async throws {
        try modelContext.delete(
            model: StoredUsageEvent.self,
            where: #Predicate<StoredUsageEvent> { $0.id == id }
        )
        try modelContext.save()
    }
}
