import Foundation

public struct ClaudeCodeUsageCacheSnapshot: Equatable, Sendable {
    public let limits: RateLimitSnapshot
    public let lastUsageChangeAt: Date?

    public init(limits: RateLimitSnapshot, lastUsageChangeAt: Date?) {
        self.limits = limits
        self.lastUsageChangeAt = lastUsageChangeAt
    }
}

public enum ClaudeCodeUsageCache {
    private struct StatusLineInput: Decodable {
        let rateLimits: RateLimits?

        enum CodingKeys: String, CodingKey {
            case rateLimits = "rate_limits"
        }
    }

    private struct RateLimits: Decodable {
        let fiveHour: InputWindow?
        let sevenDay: InputWindow?

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
        }
    }

    private struct InputWindow: Decodable {
        let usedPercentage: Double
        let resetsAt: Double?

        enum CodingKeys: String, CodingKey {
            case usedPercentage = "used_percentage"
            case resetsAt = "resets_at"
        }
    }

    private struct StoredCache: Codable {
        let version: Int
        let capturedAt: Double
        let lastUsageChangeAt: Double?
        let windows: [StoredWindow]
    }

    private struct StoredWindow: Codable, Equatable {
        let identifier: String
        let usedPercent: Double
        let windowDurationMinutes: Int
        let resetsAt: Double?
    }

    public static func updatedData(
        from statusLineData: Data,
        previousData: Data?,
        capturedAt: Date = Date()
    ) throws -> Data? {
        let input = try JSONDecoder().decode(StatusLineInput.self, from: statusLineData)
        guard let rateLimits = input.rateLimits else { return nil }

        var windows: [StoredWindow] = []
        if let fiveHour = rateLimits.fiveHour {
            windows.append(StoredWindow(
                identifier: "five_hour",
                usedPercent: fiveHour.usedPercentage,
                windowDurationMinutes: 300,
                resetsAt: fiveHour.resetsAt
            ))
        }
        if let sevenDay = rateLimits.sevenDay {
            windows.append(StoredWindow(
                identifier: "seven_day",
                usedPercent: sevenDay.usedPercentage,
                windowDurationMinutes: 10_080,
                resetsAt: sevenDay.resetsAt
            ))
        }
        guard !windows.isEmpty else { return nil }

        let previous = previousData.flatMap { try? JSONDecoder().decode(StoredCache.self, from: $0) }
        let lastChange = previous?.windows == windows
            ? previous?.lastUsageChangeAt
            : capturedAt.timeIntervalSince1970
        let cache = StoredCache(
            version: 1,
            capturedAt: capturedAt.timeIntervalSince1970,
            lastUsageChangeAt: lastChange,
            windows: windows
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(cache)
    }

    public static func decode(_ data: Data) throws -> ClaudeCodeUsageCacheSnapshot? {
        let cache = try JSONDecoder().decode(StoredCache.self, from: data)
        guard cache.version == 1, !cache.windows.isEmpty else { return nil }
        let windows = cache.windows.map {
            RateLimitWindow(
                identifier: $0.identifier,
                usedPercent: $0.usedPercent,
                windowDurationMinutes: $0.windowDurationMinutes,
                resetsAt: $0.resetsAt.map(Date.init(timeIntervalSince1970:))
            )
        }
        return ClaudeCodeUsageCacheSnapshot(
            limits: RateLimitSnapshot(
                planType: nil,
                windows: windows,
                fetchedAt: Date(timeIntervalSince1970: cache.capturedAt)
            ),
            lastUsageChangeAt: cache.lastUsageChangeAt.map(Date.init(timeIntervalSince1970:))
        )
    }
}
