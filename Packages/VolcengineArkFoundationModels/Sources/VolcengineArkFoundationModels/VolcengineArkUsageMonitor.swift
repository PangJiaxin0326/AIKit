import Foundation

/// Process-wide observation point for per-request Ark token usage.
///
/// The FoundationModels session surface does not expose provider token
/// accounting, and `VolcengineArkConfiguration` is `Hashable`/`Codable` so it
/// cannot carry a closure. Hosts that need real usage numbers (metrics
/// harnesses, billing meters) install a handler here; the executor reports
/// every completed chat-completions call.
public enum VolcengineArkUsageMonitor {
    public struct Event: Sendable {
        public let usage: VolcengineArkTokenUsage
        public let model: String
        public let durationSeconds: Double
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: (@Sendable (Event) -> Void)?

    /// Installs (or clears) the process-wide usage handler. The handler is
    /// called synchronously on the executor's task; keep it cheap.
    public static func setHandler(_ newHandler: (@Sendable (Event) -> Void)?) {
        lock.lock()
        defer { lock.unlock() }
        handler = newHandler
    }

    static func report(usage: VolcengineArkTokenUsage, model: String, duration: Double) {
        lock.lock()
        let current = handler
        lock.unlock()
        current?(Event(usage: usage, model: model, durationSeconds: duration))
    }
}
