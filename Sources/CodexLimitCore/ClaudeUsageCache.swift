import Foundation

public struct ClaudeUsageCacheSnapshot: Equatable, Sendable {
    public let limits: RateLimitSnapshot
    public let organizationID: String?
    public let lastUsageChangeAt: Date?

    public init(limits: RateLimitSnapshot, organizationID: String?, lastUsageChangeAt: Date?) {
        self.limits = limits
        self.organizationID = organizationID
        self.lastUsageChangeAt = lastUsageChangeAt
    }
}

public enum ClaudeUsageCache {
    private struct History: Decodable { let samples: [Sample] }

    private struct Sample: Decodable {
        let t: Double
        let org: String?
        let u: [String: Double]
    }

    private struct Meter {
        let identifier: String
        let minutes: Int
    }

    private static let meters: [String: Meter] = [
        "fh": Meter(identifier: "five_hour", minutes: 300),
        "sd": Meter(identifier: "seven_day", minutes: 10_080),
        "so": Meter(identifier: "seven_day_opus", minutes: 10_080),
        "oa": Meter(identifier: "seven_day_oauth_apps", minutes: 10_080),
        "cw": Meter(identifier: "seven_day_cowork", minutes: 10_080),
        "om": Meter(identifier: "seven_day_model", minutes: 10_080),
        "op": Meter(identifier: "promotional", minutes: 10_080),
        "sn": Meter(identifier: "seven_day_sonnet", minutes: 10_080),
    ]

    public static func decode(_ data: Data) throws -> ClaudeUsageCacheSnapshot? {
        let history = try JSONDecoder().decode(History.self, from: data)
        guard let latest = history.samples.max(by: { $0.t < $1.t }) else { return nil }
        let organizationSamples = history.samples
            .filter { $0.org == latest.org }
            .sorted { $0.t < $1.t }

        let windows = meters.compactMap { alias, meter -> RateLimitWindow? in
            guard let utilization = latest.u[alias] else { return nil }
            return RateLimitWindow(
                identifier: meter.identifier,
                usedPercent: utilization,
                windowDurationMinutes: meter.minutes,
                resetsAt: nil
            )
        }.sorted {
            if $0.windowDurationMinutes == $1.windowDurationMinutes {
                return ($0.identifier ?? "") < ($1.identifier ?? "")
            }
            return $0.windowDurationMinutes < $1.windowDurationMinutes
        }
        guard !windows.isEmpty else { return nil }

        let fetchedAt = Date(timeIntervalSince1970: latest.t / 1_000)
        return ClaudeUsageCacheSnapshot(
            limits: RateLimitSnapshot(planType: nil, windows: windows, fetchedAt: fetchedAt),
            organizationID: latest.org,
            lastUsageChangeAt: lastChangeDate(in: organizationSamples)
        )
    }

    private static func lastChangeDate(in samples: [Sample]) -> Date? {
        guard samples.count > 1 else { return nil }
        var previous = samples[0]
        var result: Date?
        for sample in samples.dropFirst() {
            if sample.u != previous.u {
                result = Date(timeIntervalSince1970: sample.t / 1_000)
            }
            previous = sample
        }
        return result
    }
}
