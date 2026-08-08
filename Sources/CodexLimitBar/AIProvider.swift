import AppKit
import CodexLimitCore

enum AIProvider: String, CaseIterable, Sendable {
    case codex
    case claude

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        }
    }

    var symbolName: String {
        switch self {
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .claude: return "asterisk"
        }
    }

    func matches(_ application: NSRunningApplication) -> Bool {
        let bundleIdentifier = application.bundleIdentifier?.lowercased() ?? ""
        let name = application.localizedName?.lowercased() ?? ""
        switch self {
        case .codex:
            return bundleIdentifier.contains("openai") && name.contains("codex") || name == "codex"
        case .claude:
            return bundleIdentifier == "com.anthropic.claudefordesktop" || name == "claude"
        }
    }
}

struct DisplayedLimit {
    let provider: AIProvider
    let window: RateLimitWindow
}
