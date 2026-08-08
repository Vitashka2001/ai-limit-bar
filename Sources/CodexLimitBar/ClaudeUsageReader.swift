import Foundation
import CodexLimitCore

struct ClaudeUsageSnapshot: Equatable, Sendable {
    let limits: RateLimitSnapshot
    let organizationID: String?
    let lastUsageChangeAt: Date?

    func isFresh(at date: Date = Date()) -> Bool {
        date.timeIntervalSince(limits.fetchedAt) <= ClaudeUsageReader.freshnessInterval
    }
}

enum ClaudeUsageReadResult: Equatable, Sendable {
    case available(ClaudeUsageSnapshot)
    case notInstalled
    case noData
    case failed
}

enum ClaudeUsageReader {
    static let freshnessInterval: TimeInterval = 15 * 60

    static func read(fileManager: FileManager = .default) -> ClaudeUsageReadResult {
        let applicationURL = URL(fileURLWithPath: "/Applications/Claude.app")
        let userApplicationURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/Claude.app")
        guard fileManager.fileExists(atPath: applicationURL.path)
                || fileManager.fileExists(atPath: userApplicationURL.path) else {
            return .notInstalled
        }

        let historyURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json")
        guard fileManager.fileExists(atPath: historyURL.path) else { return .noData }

        do {
            guard let cached = try ClaudeUsageCache.decode(Data(contentsOf: historyURL)) else {
                return .noData
            }
            return .available(ClaudeUsageSnapshot(
                limits: cached.limits,
                organizationID: cached.organizationID,
                lastUsageChangeAt: cached.lastUsageChangeAt
            ))
        } catch {
            return .failed
        }
    }
}
