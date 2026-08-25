import Foundation

public enum RateLimitIndicatorLevel: Equatable, Sendable {
    case green
    case yellow
    case red

    public init(remainingPercent: Double) {
        switch remainingPercent {
        case 50...:
            self = .green
        case 20..<50:
            self = .yellow
        default:
            self = .red
        }
    }
}

public struct RateLimitWindow: Equatable, Sendable {
    public let identifier: String?
    public let usedPercent: Double
    public let windowDurationMinutes: Int
    public let resetsAt: Date?

    public init(
        identifier: String? = nil,
        usedPercent: Double,
        windowDurationMinutes: Int,
        resetsAt: Date?
    ) {
        self.identifier = identifier
        self.usedPercent = usedPercent
        self.windowDurationMinutes = windowDurationMinutes
        self.resetsAt = resetsAt
    }

    public var remainingPercent: Double {
        min(100, max(0, 100 - usedPercent))
    }

    /// A window whose reset moment has passed is empty again, even when no source
    /// has reported the new value yet.
    public func hasReset(at date: Date) -> Bool {
        guard let resetsAt else { return false }
        return resetsAt <= date
    }

    public func rolledOver(at date: Date) -> RateLimitWindow {
        guard hasReset(at: date) else { return self }
        return RateLimitWindow(
            identifier: identifier,
            usedPercent: 0,
            windowDurationMinutes: windowDurationMinutes,
            resetsAt: nil
        )
    }

    /// Without a reset timestamp a window can quietly roll over while the source is
    /// silent, so a sample older than the window itself can no longer be trusted.
    public func couldHaveResetUnnoticed(measuredAt: Date, now: Date) -> Bool {
        guard resetsAt == nil else { return false }
        return now.timeIntervalSince(measuredAt) >= TimeInterval(windowDurationMinutes) * 60
    }
}

public struct RateLimitSnapshot: Equatable, Sendable {
    public let planType: String?
    public let windows: [RateLimitWindow]
    public let fetchedAt: Date

    public init(planType: String?, windows: [RateLimitWindow], fetchedAt: Date = Date()) {
        self.planType = planType
        self.windows = windows
        self.fetchedAt = fetchedAt
    }

    public var fiveHour: RateLimitWindow? {
        windows.first { $0.windowDurationMinutes == 300 }
    }

    public var weekly: RateLimitWindow? {
        windows.first { $0.windowDurationMinutes == 10_080 }
    }

    public var displayWindow: RateLimitWindow? {
        windows.min { $0.windowDurationMinutes < $1.windowDurationMinutes }
    }

    public func rollingOver(at date: Date = Date()) -> RateLimitSnapshot {
        RateLimitSnapshot(
            planType: planType,
            windows: windows.map { $0.rolledOver(at: date) },
            fetchedAt: fetchedAt
        )
    }

    public var mostConstrainedWindow: RateLimitWindow? {
        windows.min {
            if $0.remainingPercent == $1.remainingPercent {
                return $0.windowDurationMinutes < $1.windowDurationMinutes
            }
            return $0.remainingPercent < $1.remainingPercent
        }
    }

    public static func decodeAppServerMessage(_ data: Data) throws -> RateLimitSnapshot? {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let limits = result["rateLimits"] as? [String: Any] else {
            return nil
        }

        var windows: [RateLimitWindow] = []
        if let primary = parseWindow(limits["primary"]) {
            windows.append(primary)
        }
        if let secondary = parseWindow(limits["secondary"]) {
            windows.append(secondary)
        }

        guard !windows.isEmpty else { return nil }
        return RateLimitSnapshot(
            planType: limits["planType"] as? String,
            windows: windows
        )
    }

    private static func parseWindow(_ value: Any?) -> RateLimitWindow? {
        guard let object = value as? [String: Any],
              let used = number(object["usedPercent"]),
              let duration = number(object["windowDurationMins"]) else {
            return nil
        }

        let resetTimestamp = number(object["resetsAt"])
        return RateLimitWindow(
            usedPercent: used,
            windowDurationMinutes: Int(duration),
            resetsAt: resetTimestamp.map { Date(timeIntervalSince1970: $0) }
        )
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }
}
