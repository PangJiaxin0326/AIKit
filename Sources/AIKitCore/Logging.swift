import OSLog

/// Namespaced loggers. Each module owns one with subsystem `com.aikit.<module>`.
public enum AIKitLog {
    public static let core = Logger(subsystem: "com.aikit.core", category: "core")
    public static let capability = Logger(subsystem: "com.aikit.capability", category: "capability")
    public static let runtime = Logger(subsystem: "com.aikit.runtime", category: "runtime")
    public static let safety = Logger(subsystem: "com.aikit.safety", category: "safety")
    public static let ui = Logger(subsystem: "com.aikit.ui", category: "ui")
}
