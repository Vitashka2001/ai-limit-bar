import Foundation
import CodexLimitCore

struct ClaudeUsageSnapshot: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case claudeCode
        case desktop
    }

    let limits: RateLimitSnapshot
    let organizationID: String?
    let lastUsageChangeAt: Date?
    let source: Source

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
    static let freshnessInterval: TimeInterval = 5 * 60

    static func read(fileManager: FileManager = .default) -> ClaudeUsageReadResult {
        var snapshots: [ClaudeUsageSnapshot] = []
        var readFailed = false

        if fileManager.fileExists(atPath: ClaudeCodeIntegration.cacheURL.path) {
            do {
                if let cached = try ClaudeCodeUsageCache.decode(Data(contentsOf: ClaudeCodeIntegration.cacheURL)) {
                    snapshots.append(ClaudeUsageSnapshot(
                        limits: cached.limits,
                        organizationID: nil,
                        lastUsageChangeAt: cached.lastUsageChangeAt,
                        source: .claudeCode
                    ))
                }
            } catch {
                readFailed = true
            }
        }

        let historyURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json")
        if fileManager.fileExists(atPath: historyURL.path) {
            do {
                if let cached = try ClaudeUsageCache.decode(Data(contentsOf: historyURL)) {
                    snapshots.append(ClaudeUsageSnapshot(
                        limits: cached.limits,
                        organizationID: cached.organizationID,
                        lastUsageChangeAt: cached.lastUsageChangeAt,
                        source: .desktop
                    ))
                }
            } catch {
                readFailed = true
            }
        }

        if let latest = snapshots.max(by: { $0.limits.fetchedAt < $1.limits.fetchedAt }) {
            return .available(latest)
        }
        if readFailed { return .failed }
        return desktopIsInstalled(fileManager: fileManager) ? .noData : .notInstalled
    }

    static func desktopIsInstalled(fileManager: FileManager = .default) -> Bool {
        let applicationURL = URL(fileURLWithPath: "/Applications/Claude.app")
        let userApplicationURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/Claude.app")
        return fileManager.fileExists(atPath: applicationURL.path)
            || fileManager.fileExists(atPath: userApplicationURL.path)
    }
}
