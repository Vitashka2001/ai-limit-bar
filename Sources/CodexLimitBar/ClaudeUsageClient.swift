import Foundation
import CodexLimitCore
import OSLog

/// Polls `GET /api/oauth/usage` with Claude Code's own access token — the request
/// behind Claude Code's `/usage` command. Claude's local caches only refresh about
/// once per prompt, so during a long agent run they stand still; this request
/// reflects every response within a minute, the way Codex's app server does.
final class ClaudeUsageClient: @unchecked Sendable {
    enum State: Equatable {
        case idle
        case live
        /// No Claude Code login exists in the keychain.
        case signedOut
        /// The token lapsed or was rejected and asking Claude Code to renew it
        /// has not worked yet; the next attempt follows `renewalInterval`.
        case tokenExpired
        case rateLimited(until: Date)
        case failed
    }

    var onSnapshot: ((RateLimitSnapshot) -> Void)?
    var onStateChange: ((State) -> Void)?

    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let keychainService = "Claude Code-credentials"
    /// Opening the menu repeatedly must not turn into a burst of requests.
    private static let minimumInterval: TimeInterval = 15
    private static let initialBackoff: TimeInterval = 60
    private static let maximumBackoff: TimeInterval = 15 * 60
    private static let keychainTimeout: TimeInterval = 5
    /// A failed renewal usually means the user must sign in again, so retrying
    /// sooner would only keep spawning Claude Code for nothing.
    private static let renewalInterval: TimeInterval = 10 * 60
    private static let renewalTimeout: TimeInterval = 45

    private let queue = DispatchQueue(label: "com.vitashka2001.AILimitBar.claude-usage")
    private let session: URLSession
    private var inFlight = false
    private var lastAttemptAt: Date?
    private var blockedUntil: Date?
    private var backoff = initialBackoff
    private var lastRenewalAt: Date?
    /// Diagnostic switch: runs the renewal path once at launch even with a valid
    /// token, so it can be exercised without waiting hours for a real expiry.
    private var renewalForced = ProcessInfo.processInfo.environment["AI_LIMIT_BAR_FORCE_CLAUDE_RENEWAL"] == "1"
    private let logger = Logger(subsystem: "com.vitashka2001.AILimitBar", category: "claude-usage")

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    /// Requests fresh limits unless one is already running, the server asked for
    /// a pause, or — when not forced — the previous attempt is too recent.
    func refresh(force: Bool = false) {
        queue.async { [weak self] in
            self?.performRefresh(force: force)
        }
    }

    private func performRefresh(force: Bool) {
        let now = Date()
        guard !inFlight else { return }
        if let blockedUntil, now < blockedUntil { return }
        if !force, let lastAttemptAt, now.timeIntervalSince(lastAttemptAt) < Self.minimumInterval {
            return
        }
        lastAttemptAt = now

        guard var credentials = Self.readCredentials() else {
            emitState(.signedOut)
            return
        }
        if !credentials.isUsable(at: now) || renewalForced {
            renewalForced = false
            // Nothing else renews the token while Claude Code is closed, which
            // would otherwise freeze live limits until it happens to be opened.
            guard renewSignIn(now: now),
                  let renewed = Self.readCredentials(),
                  renewed.isUsable() else {
                emitState(.tokenExpired)
                return
            }
            credentials = renewed
        }
        send(credentials)
    }

    private func send(_ credentials: ClaudeOAuthCredentials) {
        var request = URLRequest(url: Self.endpoint)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        inFlight = true
        session.dataTask(with: request) { [weak self] data, response, error in
            guard let client = self else { return }
            client.queue.async { [weak client] in
                client?.handle(data: data, response: response as? HTTPURLResponse, error: error)
            }
        }.resume()
    }

    private func handle(data: Data?, response: HTTPURLResponse?, error: Error?) {
        inFlight = false
        let now = Date()
        guard error == nil, let response else {
            emitState(.failed)
            return
        }

        switch response.statusCode {
        case 200:
            guard let data,
                  let snapshot = try? ClaudeUsageAPI.decodeResponse(data, fetchedAt: now) else {
                emitState(.failed)
                return
            }
            backoff = Self.initialBackoff
            blockedUntil = nil
            onSnapshot?(snapshot)
            emitState(.live)
        case 401, 403:
            // The token was revoked or replaced before its stated expiry.
            if renewSignIn(now: now) {
                performRefresh(force: true)
            } else {
                emitState(.tokenExpired)
            }
        case 429:
            let delay = Self.retryAfter(response, now: now) ?? backoff
            backoff = min(backoff * 2, Self.maximumBackoff)
            let until = now.addingTimeInterval(min(delay, Self.maximumBackoff))
            blockedUntil = until
            emitState(.rateLimited(until: until))
        default:
            emitState(.failed)
        }
    }

    private func emitState(_ state: State) {
        onStateChange?(state)
    }

    /// Lets Claude Code renew its own sign-in by running its local `/usage` command:
    /// no model turn, no cost, no transcript, hooks, MCP servers or auto-memory.
    /// That command fetches usage with token refresh enabled, so Claude Code renews
    /// an expired token through its usual locked, keychain-writing path — exactly
    /// what any other open Claude Code window would do. Renewing it here instead
    /// would rotate the refresh token from under Claude Code and sign it out.
    /// Returns whether Claude Code ran successfully.
    private func renewSignIn(now: Date) -> Bool {
        if let lastRenewalAt, now.timeIntervalSince(lastRenewalAt) < Self.renewalInterval {
            return false
        }
        lastRenewalAt = now
        guard let executable = ClaudeCodeIntegration.executableURL else {
            logger.notice("Claude Code sign-in renewal skipped: no Claude Code executable found")
            return false
        }

        // A fixed, app-owned working directory keeps Claude Code from reading any
        // project's settings or CLAUDE.md.
        let workingDirectory = ClaudeCodeIntegration.applicationSupportURL
        try? FileManager.default.createDirectory(
            at: workingDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let process = Process()
        process.executableURL = executable
        process.arguments = [
            "-p", "/usage",
            "--output-format", "json",
            "--no-session-persistence",
            "--strict-mcp-config",
            "--settings", #"{"disableAllHooks":true,"autoMemoryEnabled":false}"#,
        ]
        process.currentDirectoryURL = workingDirectory
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", environment["PATH"]]
            .compactMap { $0 }
            .joined(separator: ":")
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            logger.error("Claude Code sign-in renewal could not start: \(error.localizedDescription, privacy: .public)")
            return false
        }
        let watchdog = DispatchWorkItem { [weak process] in
            if process?.isRunning == true { process?.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.renewalTimeout, execute: watchdog)
        process.waitUntilExit()
        watchdog.cancel()

        let succeeded = process.terminationReason == .exit && process.terminationStatus == 0
        logger.notice("Claude Code sign-in renewal finished: \(succeeded ? "ok" : "failed", privacy: .public) (status \(process.terminationStatus))")
        return succeeded
    }

    private static func retryAfter(_ response: HTTPURLResponse, now: Date) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = TimeInterval(value.trimmingCharacters(in: .whitespaces)) {
            return max(0, seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value).map { max(0, $0.timeIntervalSince(now)) }
    }

    /// Reads the item exactly the way Claude Code does, through `/usr/bin/security`.
    /// Claude Code creates the item with that tool, so its access list already
    /// trusts it and no keychain prompt appears. The token is re-read on every poll
    /// because Claude Code replaces it whenever it renews the login.
    private static func readCredentials() -> ClaudeOAuthCredentials? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-a", NSUserName(), "-w", "-s", keychainService]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }

        // A locked keychain could otherwise leave the poll waiting indefinitely.
        let watchdog = DispatchWorkItem { [weak process] in
            if process?.isRunning == true { process?.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + keychainTimeout, execute: watchdog)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        guard process.terminationStatus == 0 else { return nil }
        return ClaudeOAuthCredentials.decode(keychainOutput: data)
    }
}
