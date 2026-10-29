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
/// after talking to the service. It is the body of `/api/oauth/usage`, refreshed
/// roughly once per prompt, so it serves as the fallback while the live request
/// cannot run.
public enum ClaudeConfigUsageCache {
    public static func decode(_ data: Data) throws -> ClaudeConfigUsageCacheSnapshot? {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cached = root["cachedUsageUtilization"] as? [String: Any],
              let fetchedAtMs = (cached["fetchedAtMs"] as? NSNumber)?.doubleValue,
              let utilization = cached["utilization"] as? [String: Any] else {
            return nil
        }

        let windows = ClaudeUsageAPI.windows(fromUtilization: utilization)
        guard !windows.isEmpty else { return nil }

        return ClaudeConfigUsageCacheSnapshot(
            limits: RateLimitSnapshot(
                planType: nil,
                windows: windows,
                fetchedAt: Date(timeIntervalSince1970: fetchedAtMs / 1_000)
            ),
            accountID: cached["accountUuid"] as? String
        )
    }
}
