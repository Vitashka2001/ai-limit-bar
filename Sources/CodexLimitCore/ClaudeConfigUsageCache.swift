import Foundation

public struct ClaudeConfigUsageCacheSnapshot: Equatable, Sendable {
    public let limits: RateLimitSnapshot
    public let accountID: String?

    public init(limits: RateLimitSnapshot, accountID: String?) {
        self.limits = limits
        self.accountID = accountID
    }
}

/// Reads the usage utilization Claude Code itself persists in `~/.claude.json`
/// after talking to the service. Unlike the Desktop history it carries reset
/// timestamps, and unlike the status line it does not need a live session.
public enum ClaudeConfigUsageCache {
    private struct Window {
        let identifier: String
        let minutes: Int
    }

    /// Only the stable, user-meaningful meters. The payload also carries internal
    /// code names for unreleased limits, which would render as noise.
    private static let windows: [String: Window] = [
        "five_hour": Window(identifier: "five_hour", minutes: 300),
        "seven_day": Window(identifier: "seven_day", minutes: 10_080),
        "seven_day_opus": Window(identifier: "seven_day_opus", minutes: 10_080),
        "seven_day_sonnet": Window(identifier: "seven_day_sonnet", minutes: 10_080),
        "seven_day_oauth_apps": Window(identifier: "seven_day_oauth_apps", minutes: 10_080),
        "seven_day_cowork": Window(identifier: "seven_day_cowork", minutes: 10_080),
    ]

    /// Decoded loosely on purpose: alongside the meters, `utilization` also holds an
    /// unrelated `limits` array and an `extra_usage` object, and Claude Code adds new
    /// keys freely. A strict `Codable` shape would throw on the whole payload.
    public static func decode(_ data: Data) throws -> ClaudeConfigUsageCacheSnapshot? {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cached = root["cachedUsageUtilization"] as? [String: Any],
              let fetchedAtMs = (cached["fetchedAtMs"] as? NSNumber)?.doubleValue,
              let utilization = cached["utilization"] as? [String: Any] else {
            return nil
        }

        let decoded = windows.compactMap { key, window -> RateLimitWindow? in
            guard let meter = utilization[key] as? [String: Any],
                  let used = (meter["utilization"] as? NSNumber)?.doubleValue else { return nil }
            return RateLimitWindow(
                identifier: window.identifier,
                usedPercent: used,
                windowDurationMinutes: window.minutes,
                resetsAt: (meter["resets_at"] as? String).flatMap(date(fromISO8601:))
            )
        }.sorted {
            if $0.windowDurationMinutes == $1.windowDurationMinutes {
                return ($0.identifier ?? "") < ($1.identifier ?? "")
            }
            return $0.windowDurationMinutes < $1.windowDurationMinutes
        }
        guard !decoded.isEmpty else { return nil }

        return ClaudeConfigUsageCacheSnapshot(
            limits: RateLimitSnapshot(
                planType: nil,
                windows: decoded,
                fetchedAt: Date(timeIntervalSince1970: fetchedAtMs / 1_000)
            ),
            accountID: cached["accountUuid"] as? String
        )
    }

    /// `ISO8601DateFormatter` is not `Sendable`, and a handful of dates per refresh
    /// does not justify shared mutable state, so each parse gets its own.
    private static func date(fromISO8601 value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
