import Foundation
import AIKitSafety

/// Aggregates live activity across conversations and host-run external work:
/// the global busy state, per-item status text, recent guardrail warnings,
/// and a Cancel All that reaches everything registered. It never executes
/// model turns — conversations and hosts report in, UI observes.
///
/// One store per app surface that needs a global busy indicator; hand the
/// same instance to every `AIKitConversation` and to `.guardrails(_:activity:)`
/// so warnings land beside the work they belong to.
public actor AIKitActivityStore {
    /// One in-flight unit of work — a conversation turn or host-run external
    /// work — with its user-facing status text.
    public struct WorkItem: Sendable, Hashable, Identifiable {
        public let id: Int
        public var label: String?
        public let startedAt: Date
    }

    /// A `Sendable` view of everything in flight, plus recent warnings.
    public struct Snapshot: Sendable, Equatable {
        public var items: [WorkItem]
        public var warnings: [GuardrailWarning]

        public var isBusy: Bool { !items.isEmpty }

        /// The most recent labelled item's text, for a single-line busy
        /// indicator. `nil` means show a generic busy label while `isBusy`.
        public var statusText: String? {
            items.reversed().lazy.compactMap(\.label).first
        }

        public static let idle = Snapshot(items: [], warnings: [])
    }

    private var nextID = 0
    private var items: [WorkItem] = []
    private var cancelHandlers: [Int: @Sendable () -> Void] = [:]
    private var warnings: [GuardrailWarning] = []
    private let maxWarnings = 16
    private var observers: [UUID: AsyncStream<Snapshot>.Continuation] = [:]
    /// Observer ids whose stream terminated before the actor processed their
    /// registration task.
    private var terminatedObservers: Set<UUID> = []

    public init() {}

    // MARK: - Work items

    /// Registers in-flight work and returns its id. Pair with `end(_:)`;
    /// `onCancel` is invoked by `cancelAll()` so UI cancel controls reach
    /// work the store does not run.
    @discardableResult
    public func begin(
        _ label: String? = nil,
        onCancel: (@Sendable () -> Void)? = nil
    ) -> Int {
        nextID += 1
        let id = nextID
        items.append(WorkItem(id: id, label: label, startedAt: Date()))
        if let onCancel { cancelHandlers[id] = onCancel }
        broadcast()
        return id
    }

    /// Updates an item's user-facing status text. No-op once it ended.
    public func update(_ id: Int, label: String?) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].label = label
        broadcast()
    }

    /// Ends an item, returning subscribers to idle when nothing else is in
    /// flight. Idempotent.
    public func end(_ id: Int) {
        cancelHandlers[id] = nil
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items.remove(at: index)
        broadcast()
    }

    /// Cancels everything in flight via the registered cancel callbacks and
    /// keeps work visible until its owner reports settlement with `end`. Safe to call from UI (a Cancel All button).
    public func cancelAll() {
        let handlers = cancelHandlers.values
        cancelHandlers.removeAll()
        for cancel in handlers { cancel() }
        broadcast()
    }

    // MARK: - Warnings

    /// Guardrail warnings surface here — never in the transcript. Kept to
    /// the most recent few; `clearWarnings()` when the UI has shown them.
    public func record(_ warning: GuardrailWarning) {
        warnings.append(warning)
        if warnings.count > maxWarnings {
            warnings.removeFirst(warnings.count - maxWarnings)
        }
        broadcast()
    }

    public func clearWarnings() {
        guard !warnings.isEmpty else { return }
        warnings.removeAll()
        broadcast()
    }

    // MARK: - Observation

    public func snapshot() -> Snapshot {
        Snapshot(items: items, warnings: warnings)
    }

    /// A live stream of the store's state: the current snapshot is emitted
    /// immediately on subscription, then again on every change. Each
    /// subscriber gets an independent stream.
    public nonisolated func updates() -> AsyncStream<Snapshot> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            Task { await self.registerObserver(id, continuation) }
            continuation.onTermination = { _ in
                Task { await self.unregisterObserver(id) }
            }
        }
    }

    private func registerObserver(
        _ id: UUID,
        _ continuation: AsyncStream<Snapshot>.Continuation
    ) {
        guard terminatedObservers.remove(id) == nil else { return }
        observers[id] = continuation
        continuation.yield(snapshot())
    }

    private func unregisterObserver(_ id: UUID) {
        if observers.removeValue(forKey: id) == nil {
            terminatedObservers.insert(id)
        }
    }

    private func broadcast() {
        let snapshot = snapshot()
        for continuation in observers.values {
            continuation.yield(snapshot)
        }
    }
}

extension AIKitActivityStore: GuardrailActivitySink {
    /// Warnings raised inside the session machinery land beside the work
    /// they belong to. Awaited delivery preserves ordering with turn completion.
    public func guardrailWarned(_ warning: GuardrailWarning) async {
        record(warning)
    }
}
