import Foundation

public struct ClaudeUsageSnapshot: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case api
        case claudeCode
        case desktop
        case config
    }

    /// Claude Desktop rewrites its history roughly every 15 minutes, so anything
    /// tighter would label almost every sample as out of date.
    public static let recentInterval: TimeInterval = 20 * 60

    public let limits: RateLimitSnapshot
    public let organizationID: String?
    public let lastUsageChangeAt: Date?
    /// The freshest source that contributed to `limits`.
    public let source: Source

    public init(
        limits: RateLimitSnapshot,
        organizationID: String?,
        lastUsageChangeAt: Date?,
        source: Source
    ) {
        self.limits = limits
        self.organizationID = organizationID
        self.lastUsageChangeAt = lastUsageChangeAt
        self.source = source
    }

    /// Whether the newest sample is recent enough to describe as current. Claude's
    /// local sources publish on their own schedule, so this only picks the wording
    /// of the status line: an older sample still holds the correct numbers.
    public func isRecent(at date: Date = Date()) -> Bool {
        date.timeIntervalSince(limits.fetchedAt) <= Self.recentInterval
    }

    /// True when a window carries no reset timestamp and the sample is older than
    /// the window itself, so the quota may have silently rolled over.
    public func hasUnverifiableWindow(at date: Date = Date()) -> Bool {
        limits.windows.contains {
            $0.couldHaveResetUnnoticed(measuredAt: limits.fetchedAt, now: date)
        }
    }

    /// Combines the local sources window by window instead of picking one wholesale.
    /// Claude Desktop reports percentages without reset timestamps, so on its own it
    /// would otherwise discard the reset times the other two sources do provide.
    public static func merged(_ snapshots: [ClaudeUsageSnapshot], at now: Date) -> ClaudeUsageSnapshot? {
        let ordered = snapshots.sorted { $0.limits.fetchedAt > $1.limits.fetchedAt }
        guard let newest = ordered.first else { return nil }

        var windows: [String: RateLimitWindow] = [:]
        for snapshot in ordered {
            for window in snapshot.limits.windows {
                let key = window.identifier ?? "\(window.windowDurationMinutes)"
                guard let existing = windows[key] else {
                    windows[key] = window
                    continue
                }
                // A reset instant is an absolute fact about the window, so an older
                // source may fill it in — but only while it still lies ahead.
                if existing.resetsAt == nil,
                   let resetsAt = window.resetsAt,
                   resetsAt > now {
                    windows[key] = RateLimitWindow(
                        identifier: existing.identifier,
                        usedPercent: existing.usedPercent,
                        windowDurationMinutes: existing.windowDurationMinutes,
                        resetsAt: resetsAt
                    )
                }
            }
        }

        let ordering = windows.values.sorted {
            if $0.windowDurationMinutes == $1.windowDurationMinutes {
                return ($0.identifier ?? "") < ($1.identifier ?? "")
            }
            return $0.windowDurationMinutes < $1.windowDurationMinutes
        }
        guard !ordering.isEmpty else { return nil }

        return ClaudeUsageSnapshot(
            limits: RateLimitSnapshot(
                planType: ordered.compactMap(\.limits.planType).first,
                windows: ordering,
                fetchedAt: newest.limits.fetchedAt
            ).rollingOver(at: now),
            organizationID: ordered.compactMap(\.organizationID).first,
            lastUsageChangeAt: ordered.compactMap(\.lastUsageChangeAt).max(),
            source: newest.source
        )
    }
}
