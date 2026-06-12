import Foundation

#if DEBUG
/// Debug-only observation point for the raw chat-completions wire traffic.
///
/// Mirrors `VolcengineArkUsageMonitor`: the executor's `Configuration` is
/// `Hashable`, so it cannot carry a closure — a debug host that
/// needs to see the exact bytes on the wire (what the session sends, what
/// the model streams back) installs a process-wide handler here. Compiled
/// out of release builds; release call sites are `#if DEBUG`-guarded too.
public enum VolcengineArkWireTrace {
    public enum Event: Sendable {
        /// The exact request body (UTF-8 JSON) about to be POSTed.
        case request(model: String, body: Data)
        /// One raw SSE line exactly as received from the wire.
        case responseLine(String)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: (@Sendable (Event) -> Void)?

    /// Installs (or clears) the process-wide wire-trace handler. The handler
    /// is called synchronously on the executor's task; keep it cheap.
    public static func setHandler(_ newHandler: (@Sendable (Event) -> Void)?) {
        lock.lock()
        defer { lock.unlock() }
        handler = newHandler
    }

    static func report(_ event: @autoclosure () -> Event) {
        lock.lock()
        let current = handler
        lock.unlock()
        current?(event())
    }
}
#endif
