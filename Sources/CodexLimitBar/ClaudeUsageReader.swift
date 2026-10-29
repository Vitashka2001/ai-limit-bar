import Foundation
import CodexLimitCore

enum ClaudeUsageReadResult: Equatable, Sendable {
    case available(ClaudeUsageSnapshot)
    case notInstalled
    case noData
    case failed
}

/// Merges the live `/api/oauth/usage` result with every local place Claude leaves
/// its usage numbers. The live request is the only one on a fixed schedule; the
/// local sources keep the indicator populated while it cannot run.
enum ClaudeUsageReader {
    static func read(
        live: RateLimitSnapshot? = nil,
        fileManager: FileManager = .default,
        now: Date = Date()
    ) -> ClaudeUsageReadResult {
        var snapshots: [ClaudeUsageSnapshot] = []
        var readFailed = false

        if let live {
            snapshots.append(ClaudeUsageSnapshot(
                limits: live,
                organizationID: nil,
                lastUsageChangeAt: nil,
                source: .api
            ))
        }

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
