import Foundation

/// The OAuth credentials Claude Code keeps in the login keychain. Only the access
/// token is ever used: refreshing it here would rotate the refresh token out from
/// under Claude Code and sign it out, so an expired token simply waits for Claude
/// Code to renew it.
public struct ClaudeOAuthCredentials: Sendable {
    public let accessToken: String
    public let expiresAt: Date?

    public init(accessToken: String, expiresAt: Date?) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
    }

    /// `security -w` prints a printable value as text but anything else as hex,
    /// and Claude Code stores the item through hex input, so both forms are read.
    public static func decode(keychainOutput: Data) -> ClaudeOAuthCredentials? {
        if let credentials = decode(keychainOutput) { return credentials }
        let hex = String(decoding: keychainOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard hex.count.isMultiple(of: 2), hex.allSatisfy(\.isHexDigit) else { return nil }
        var bytes = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return decode(bytes)
    }

    public static func decode(_ data: Data) -> ClaudeOAuthCredentials? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty else {
            return nil
        }
        let expiresAt = (oauth["expiresAt"] as? NSNumber).map {
            Date(timeIntervalSince1970: $0.doubleValue / 1_000)
        }
        return ClaudeOAuthCredentials(accessToken: token, expiresAt: expiresAt)
    }

    /// Leaves a margin so a request is never sent with a token about to lapse.
    public func isUsable(at date: Date = Date(), margin: TimeInterval = 60) -> Bool {
        guard let expiresAt else { return true }
        return expiresAt.timeIntervalSince(date) > margin
    }
}

/// Parses the payload of `GET /api/oauth/usage`, the same endpoint Claude Code's
/// `/usage` command reads and whose body it caches in `~/.claude.json`.
public enum ClaudeUsageAPI {
    private struct Window {
        let identifier: String
        let minutes: Int
    }

    /// Only the stable, user-meaningful meters. The payload also carries internal
    /// code names for unreleased limits, which would render as noise.
    private static let meters: [String: Window] = [
        "five_hour": Window(identifier: "five_hour", minutes: 300),
        "seven_day": Window(identifier: "seven_day", minutes: 10_080),
        "seven_day_opus": Window(identifier: "seven_day_opus", minutes: 10_080),
        "seven_day_sonnet": Window(identifier: "seven_day_sonnet", minutes: 10_080),
        "seven_day_oauth_apps": Window(identifier: "seven_day_oauth_apps", minutes: 10_080),
        "seven_day_cowork": Window(identifier: "seven_day_cowork", minutes: 10_080),
    ]

    public static func decodeResponse(_ data: Data, fetchedAt: Date = Date()) throws -> RateLimitSnapshot? {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let windows = windows(fromUtilization: root)
        guard !windows.isEmpty else { return nil }
        return RateLimitSnapshot(planType: nil, windows: windows, fetchedAt: fetchedAt)
    }

    /// Decoded loosely on purpose: alongside the meters the payload holds a
    /// `limits` array, an `extra_usage` object and new keys added freely, so a
    /// strict `Codable` shape would throw on the whole response.
    public static func windows(fromUtilization utilization: [String: Any]) -> [RateLimitWindow] {
        meters.compactMap { key, window -> RateLimitWindow? in
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
    }

    /// `ISO8601DateFormatter` is not `Sendable`, and a handful of dates per refresh
    /// does not justify shared mutable state, so each parse gets its own.
    private static func date(fromISO8601 value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
