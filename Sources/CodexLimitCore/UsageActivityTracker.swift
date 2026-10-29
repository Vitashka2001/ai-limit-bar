import Foundation

/// Remembers when a provider's usage last grew, so the menu bar can follow the
/// service that is actually being used. Only growth counts: a window emptying at
/// its reset is the passage of time, not activity.
public struct UsageActivityTracker: Equatable, Sendable {
    public private(set) var signature: [String: Double]
    public private(set) var lastActivityAt: Date?

    public init(signature: [String: Double] = [:], lastActivityAt: Date? = nil) {
        self.signature = signature
        self.lastActivityAt = lastActivityAt
    }

    public static func signature(of windows: [RateLimitWindow]) -> [String: Double] {
        Dictionary(windows.enumerated().map { index, window in
            (window.identifier ?? "\(window.windowDurationMinutes)-\(index)", window.usedPercent)
        }, uniquingKeysWith: { first, _ in first })
    }

    /// Records a new observation and reports whether it counts as activity.
    /// The very first observation only sets the baseline: without a previous
    /// value there is nothing to compare against.
    @discardableResult
    public mutating func observe(_ windows: [RateLimitWindow], at date: Date) -> Bool {
        let next = Self.signature(of: windows)
        defer { signature = next }
        guard !signature.isEmpty else { return false }
        let grew = next.contains { key, used in used > (signature[key] ?? 0) }
        if grew { lastActivityAt = date }
        return grew
    }
}
