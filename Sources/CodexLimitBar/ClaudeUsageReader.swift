import Foundation
import CodexLimitCore

enum ClaudeUsageReadResult: Equatable, Sendable {
    case available(ClaudeUsageSnapshot)
    case notInstalled
    case noData
    case failed
}

/// Gathers every local place Claude leaves its usage numbers and merges them.
/// None of them publishes on a fixed schedule, so relying on any single one leaves
/// long gaps; together they cover each other.
enum ClaudeUsageReader {
    static func read(fileManager: FileManager = .default, now: Date = Date()) -> ClaudeUsageReadResult {
        var snapshots: [ClaudeUsageSnapshot] = []
        var readFailed = false

        func load(_ url: URL, _ transform: (Data) throws -> ClaudeUsageSnapshot?) {
            guard fileManager.fileExists(atPath: url.path) else { return }
            do {
                if let snapshot = try transform(Data(contentsOf: url)) {
                    snapshots.append(snapshot)
                }
            } catch {
                readFailed = true
            }
        }

        load(ClaudeCodeIntegration.cacheURL) { data in
            try ClaudeCodeUsageCache.decode(data).map {
                ClaudeUsageSnapshot(
                    limits: $0.limits,
                    organizationID: nil,
                    lastUsageChangeAt: $0.lastUsageChangeAt,
                    source: .claudeCode
                )
            }
        }

        load(desktopHistoryURL(fileManager: fileManager)) { data in
            try ClaudeUsageCache.decode(data).map {
                ClaudeUsageSnapshot(
                    limits: $0.limits,
                    organizationID: $0.organizationID,
                    lastUsageChangeAt: $0.lastUsageChangeAt,
                    source: .desktop
                )
            }
        }

        load(configURL(fileManager: fileManager)) { data in
            try ClaudeConfigUsageCache.decode(data).map {
                ClaudeUsageSnapshot(
                    limits: $0.limits,
                    organizationID: nil,
                    lastUsageChangeAt: nil,
                    source: .config
                )
            }
        }

        if let merged = ClaudeUsageSnapshot.merged(snapshots, at: now) {
            return .available(merged)
        }
        if readFailed { return .failed }
        return desktopIsInstalled(fileManager: fileManager) ? .noData : .notInstalled
    }

    static func desktopHistoryURL(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json")
    }

    /// Claude Code persists the utilization it last fetched here. It is the only
    /// local source that survives both a closed session and a closed Desktop app.
    static func configURL(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
    }

    static func desktopIsInstalled(fileManager: FileManager = .default) -> Bool {
        desktopApplicationURL(fileManager: fileManager) != nil
    }

    static func desktopApplicationURL(fileManager: FileManager = .default) -> URL? {
        let candidates = [
            URL(fileURLWithPath: "/Applications/Claude.app"),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Claude.app"),
        ]
        return candidates.first { fileManager.fileExists(atPath: $0.path) }
    }
}
