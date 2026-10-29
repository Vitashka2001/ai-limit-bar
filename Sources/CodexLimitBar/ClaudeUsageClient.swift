import Foundation
import CodexLimitCore

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
        /// The token lapsed or was rejected; Claude Code renews it on next use.
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

    private let queue = DispatchQueue(label: "com.vitashka2001.AILimitBar.claude-usage")
    private let session: URLSession
    private var inFlight = false
    private var lastAttemptAt: Date?
    private var blockedUntil: Date?
    private var backoff = initialBackoff

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

        guard let credentials = Self.readCredentials() else {
            emitState(.signedOut)
            return
        }
        guard credentials.isUsable(at: now) else {
            emitState(.tokenExpired)
            return
        }

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
            emitState(.tokenExpired)
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
