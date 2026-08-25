import Foundation
import CodexLimitCore

enum ClaudeCodeIntegration {
    static let usageUpdatedNotification = Notification.Name("com.vitashka2001.AILimitBar.claudeCodeUsageUpdated")
    static let commandArgument = "--capture-claude-usage"
    /// Claude Code re-runs the status line command on this cadence on top of its
    /// event-driven updates, so limits keep arriving during a long response instead
    /// of only after one finishes.
    static let refreshIntervalSeconds = 30

    enum InstallResult {
        case installed
        case conflict
        case failed
    }

    static var isInstalled: Bool {
        guard let root = readSettings(),
              let statusLine = root["statusLine"] as? [String: Any],
              let command = statusLine["command"] as? String else {
            return false
        }
        return command.contains(commandArgument)
    }

    static var isAvailable: Bool {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let executableURLs = [
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude"),
            home.appendingPathComponent(".local/bin/claude"),
            home.appendingPathComponent(".claude/local/claude"),
        ]
        if executableURLs.contains(where: { fileManager.isExecutableFile(atPath: $0.path) }) {
            return true
        }

        let extensionRoots = [
            home.appendingPathComponent(".vscode/extensions"),
            home.appendingPathComponent(".vscode-insiders/extensions"),
            home.appendingPathComponent(".cursor/extensions"),
        ]
        return extensionRoots.contains { root in
            guard let entries = try? fileManager.contentsOfDirectory(atPath: root.path) else { return false }
            return entries.contains { $0.lowercased().hasPrefix("anthropic.claude-code-") }
        }
    }

    static func install(executableURL: URL) -> InstallResult {
        var root = readSettings() ?? [:]
        if let statusLine = root["statusLine"] as? [String: Any],
           let command = statusLine["command"] as? String,
           !command.contains(commandArgument) {
            return .conflict
        }

        root["statusLine"] = [
            "type": "command",
            "command": "\(shellQuote(executableURL.path)) \(commandArgument)",
            "refreshInterval": refreshIntervalSeconds,
        ]
        return writeSettings(root) ? .installed : .failed
    }

    /// Keeps an existing bridge pointing at this bundle and on the current refresh
    /// cadence. Without it, moving the app leaves a command that silently fails, and
    /// installs made before `refreshInterval` existed only update after a response.
    @discardableResult
    static func repairIfNeeded(executableURL: URL) -> Bool {
        guard var root = readSettings(),
              let statusLine = root["statusLine"] as? [String: Any],
              let command = statusLine["command"] as? String,
              command.contains(commandArgument) else {
            return false
        }

        let expected = "\(shellQuote(executableURL.path)) \(commandArgument)"
        let interval = (statusLine["refreshInterval"] as? NSNumber)?.intValue
        guard command != expected || interval != refreshIntervalSeconds else { return false }

        root["statusLine"] = [
            "type": "command",
            "command": expected,
            "refreshInterval": refreshIntervalSeconds,
        ]
        return writeSettings(root)
    }

    static func uninstall() -> Bool {
        guard var root = readSettings(),
              let statusLine = root["statusLine"] as? [String: Any],
              let command = statusLine["command"] as? String,
              command.contains(commandArgument) else {
            return true
        }
        root.removeValue(forKey: "statusLine")
        return writeSettings(root)
    }

    static func captureStatusLineInput() -> Bool {
        do {
            let input = FileHandle.standardInput.readDataToEndOfFile()
            let previous = try? Data(contentsOf: cacheURL)
            guard let updated = try ClaudeCodeUsageCache.updatedData(
                from: input,
                previousData: previous
            ) else {
                return true
            }
            try FileManager.default.createDirectory(
                at: applicationSupportURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try updated.write(to: cacheURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: cacheURL.path
            )
            DistributedNotificationCenter.default().postNotificationName(
                usageUpdatedNotification,
                object: nil
            )
            return true
        } catch {
            return false
        }
    }

    static var cacheURL: URL {
        applicationSupportURL.appendingPathComponent("claude-code-usage.json")
    }

    private static var applicationSupportURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AI Limit Bar", isDirectory: true)
    }

    private static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }

    private static func readSettings() -> [String: Any]? {
        guard let data = try? Data(contentsOf: settingsURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return root
    }

    private static func writeSettings(_ root: [String: Any]) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: settingsURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let data = try JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try data.write(to: settingsURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: settingsURL.path
            )
            return true
        } catch {
            return false
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
