import AppKit
import CodexLimitCore
import OSLog

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private static let monitoringDefaultsKey = "monitoringEnabled"
    private static let minimumContentWidth: CGFloat = 420
    private static let recentActivityInterval: TimeInterval = 15 * 60

    private let statusItem = NSStatusBar.system.statusItem(withLength: 90)
    private let client = CodexAppServerClient()
    private let dashboardView = LimitsDashboardView(frame: NSRect(x: 0, y: 0, width: 420, height: 235))
    private let logger = Logger(subsystem: "com.vitashka2001.AILimitBar", category: "limits")
    private let monitoringItem = NSMenuItem(title: L10n.string("menu.monitoring"), action: nil, keyEquivalent: "")
    private let switchAccountItem = NSMenuItem(title: L10n.string("menu.switchAccount"), action: nil, keyEquivalent: "")
    private let switchClaudeAccountItem = NSMenuItem(title: L10n.string("menu.switchClaudeAccount"), action: nil, keyEquivalent: "")
    private let launchAtLoginItem = NSMenuItem(title: L10n.string("menu.launchAtLogin"), action: nil, keyEquivalent: "")
    private let languageItem = NSMenuItem(title: L10n.string("menu.language"), action: nil, keyEquivalent: "")
    private let refreshItem = NSMenuItem(title: L10n.string("menu.refresh"), action: nil, keyEquivalent: "r")

    private var refreshTimer: Timer?
    private var codexSnapshot: RateLimitSnapshot?
    private var claudeResult: ClaudeUsageReadResult = .noData
    private var account: CodexAccount?
    private var monitoringEnabled = true
    private var clientConnected = false
    private var loginInProgress = false
    private var codexUsageSignature: [String: Double] = [:]
    private var codexLastUsageChangeAt: Date?
    private var frontmostProvider: AIProvider?

    override init() {
        super.init()
        frontmostProvider = provider(for: NSWorkspace.shared.frontmostApplication)
        configureStatusItem()
        configureClient()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeApplicationChanged),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        LaunchAtLoginManager.migrateIfNeeded()
        let storedValue = UserDefaults.standard.object(forKey: Self.monitoringDefaultsKey) as? Bool
        setMonitoringEnabled(storedValue ?? true, persist: false)
        refreshLaunchAtLoginState()
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        client.stop()
    }

    private func configureStatusItem() {
        let menu = NSMenu()
        menu.delegate = self

        let dashboardItem = NSMenuItem()
        dashboardItem.view = dashboardView
        menu.addItem(dashboardItem)
        menu.addItem(.separator())

        configureMenuItem(monitoringItem, action: #selector(toggleMonitoring), symbol: "chart.bar.fill")
        configureMenuItem(switchAccountItem, action: #selector(switchAccount), symbol: "person.crop.circle")
        configureProviderMenuItem(switchClaudeAccountItem, action: #selector(switchClaudeAccount), provider: .claude)
        configureMenuItem(launchAtLoginItem, action: #selector(toggleLaunchAtLogin), symbol: "power")
        menu.addItem(monitoringItem)
        menu.addItem(switchAccountItem)
        menu.addItem(switchClaudeAccountItem)
        menu.addItem(launchAtLoginItem)

        configureLanguageMenu()
        menu.addItem(languageItem)
        menu.addItem(.separator())

        configureMenuItem(refreshItem, action: #selector(refreshNow), symbol: "arrow.clockwise")
        menu.addItem(refreshItem)

        let quitItem = NSMenuItem(title: L10n.string("menu.quit"), action: #selector(quit), keyEquivalent: "q")
        configureMenuItem(quitItem, action: #selector(quit), symbol: "xmark.circle")
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.imagePosition = .imageOnly
        render()
    }

    private func configureMenuItem(_ item: NSMenuItem, action: Selector, symbol: String) {
        item.target = self
        item.action = action
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: item.title) {
            image.isTemplate = true
            item.image = image
        }
    }

    private func configureProviderMenuItem(_ item: NSMenuItem, action: Selector, provider: AIProvider) {
        item.target = self
        item.action = action
        item.image = ProviderIcon.menuImage(for: provider)
    }

    private func configureLanguageMenu() {
        if let image = NSImage(systemSymbolName: "globe", accessibilityDescription: languageItem.title) {
            image.isTemplate = true
            languageItem.image = image
        }
        let submenu = NSMenu()
        for language in AppLanguage.allCases {
            let item = NSMenuItem(title: language.nativeName, action: #selector(changeLanguage), keyEquivalent: "")
            item.target = self
            item.representedObject = language.rawValue
            item.state = language == L10n.language ? .on : .off
            submenu.addItem(item)
        }
        languageItem.submenu = submenu
    }

    private func configureClient() {
        client.onSnapshot = { [weak self] snapshot in
            Task { @MainActor in self?.apply(snapshot) }
        }
        client.onAccount = { [weak self] account in
            Task { @MainActor in
                self?.account = account
                self?.render()
            }
        }
        client.onStateChange = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .connecting:
                    self.clientConnected = false
                case .connected:
                    self.clientConnected = true
                case .failed(let message):
                    self.clientConnected = false
                    self.logger.error("Codex connection failed: \(message, privacy: .public)")
                }
                self.render()
                self.updateActionAvailability()
            }
        }
        client.onLoginStarted = { [weak self] authURL in
            Task { @MainActor in
                guard let self else { return }
                self.loginInProgress = true
                self.switchAccountItem.title = L10n.string("menu.cancelSwitch")
                self.updateActionAvailability()
                guard NSWorkspace.shared.open(authURL) else {
                    self.client.cancelLogin()
                    self.showAlert(
                        title: L10n.string("alert.browser.title"),
                        message: L10n.string("alert.browser.message")
                    )
                    return
                }
            }
        }
        client.onLoginFinished = { [weak self] success, error in
            Task { @MainActor in
                guard let self else { return }
                let wasInProgress = self.loginInProgress
                self.loginInProgress = false
                self.switchAccountItem.title = L10n.string("menu.switchAccount")
                self.updateActionAvailability()
                if success {
                    self.showAlert(
                        title: L10n.string("alert.accountSwitched.title"),
                        message: L10n.string("alert.accountSwitched.message")
                    )
                } else if wasInProgress, let error, !error.isEmpty {
                    self.showAlert(title: L10n.string("alert.loginIncomplete.title"), message: error)
                }
            }
        }
    }

    private func apply(_ snapshot: RateLimitSnapshot) {
        let signature = Dictionary(uniqueKeysWithValues: snapshot.windows.enumerated().map { index, window in
            (window.identifier ?? "\(window.windowDurationMinutes)-\(index)", window.usedPercent)
        })
        if !codexUsageSignature.isEmpty, signature != codexUsageSignature {
            codexLastUsageChangeAt = Date()
        }
        codexUsageSignature = signature
        codexSnapshot = snapshot
        render()
    }

    private func refreshClaude() {
        claudeResult = ClaudeUsageReader.read()
        render()
        updateActionAvailability()
    }

    private func render() {
        guard monitoringEnabled else {
            dashboardView.update(
                active: nil,
                providers: AIProvider.allCases.map {
                    ProviderDashboardState(provider: $0, status: L10n.string("dashboard.monitoringStopped"), windows: [])
                }
            )
            renderStatus(limit: nil, stateText: L10n.string("status.off"), tooltip: L10n.string("status.monitoringStopped.tooltip"))
            return
        }

        let selected = selectDisplayedLimit()
        dashboardView.update(active: selected, providers: [codexDashboardState(), claudeDashboardState()])
        if let selected {
            let title = L10n.format(
                "limits.providerTooltip",
                selected.provider.displayName,
                windowLabel(selected.window),
                Int(selected.window.remainingPercent.rounded())
            )
            renderStatus(limit: selected, stateText: nil, tooltip: title)
        } else {
            renderStatus(limit: nil, stateText: "--", tooltip: L10n.string("limits.noFreshData"))
        }
    }

    private func codexDashboardState() -> ProviderDashboardState {
        let status: String
        if let account {
            status = accountDescription(account)
        } else if clientConnected {
            status = L10n.string("account.connected")
        } else {
            status = L10n.string("account.connecting")
        }
        return ProviderDashboardState(provider: .codex, status: status, windows: codexSnapshot?.windows ?? [])
    }

    private func claudeDashboardState() -> ProviderDashboardState {
        switch claudeResult {
        case .available(let snapshot):
            let key = snapshot.isFresh() ? "claude.updated" : "claude.stale"
            return ProviderDashboardState(
                provider: .claude,
                status: L10n.format(key, Self.dateFormatter.string(from: snapshot.limits.fetchedAt)),
                windows: snapshot.limits.windows,
                isStale: !snapshot.isFresh()
            )
        case .notInstalled:
            return ProviderDashboardState(provider: .claude, status: L10n.string("claude.notInstalled"), windows: [])
        case .noData:
            return ProviderDashboardState(provider: .claude, status: L10n.string("claude.noData"), windows: [])
        case .failed:
            return ProviderDashboardState(provider: .claude, status: L10n.string("claude.failed"), windows: [])
        }
    }

    private func selectDisplayedLimit(now: Date = Date()) -> DisplayedLimit? {
        var candidates: [(limit: DisplayedLimit, activity: Date?)] = []
        if clientConnected, let window = codexSnapshot?.mostConstrainedWindow {
            candidates.append((DisplayedLimit(provider: .codex, window: window), codexLastUsageChangeAt))
        }
        if case .available(let claude) = claudeResult,
           claude.isFresh(at: now),
           let window = claude.limits.mostConstrainedWindow {
            candidates.append((DisplayedLimit(provider: .claude, window: window), claude.lastUsageChangeAt))
        }
        guard !candidates.isEmpty else { return nil }

        let critical = candidates.filter { $0.limit.window.remainingPercent < 20 }
        if let lowest = critical.min(by: { $0.limit.window.remainingPercent < $1.limit.window.remainingPercent }) {
            return lowest.limit
        }

        let recentlyUsed = candidates.filter {
            guard let activity = $0.activity else { return false }
            return now.timeIntervalSince(activity) <= Self.recentActivityInterval
        }
        if let latest = recentlyUsed.max(by: { ($0.activity ?? .distantPast) < ($1.activity ?? .distantPast) }) {
            return latest.limit
        }

        if let frontmostProvider,
           let frontmost = candidates.first(where: { $0.limit.provider == frontmostProvider }) {
            return frontmost.limit
        }
        return candidates.min(by: { $0.limit.window.remainingPercent < $1.limit.window.remainingPercent })?.limit
    }

    private func accountDescription(_ account: CodexAccount) -> String {
        let plan = account.planType.map(displayPlan)
        switch account.kind {
        case .chatgpt:
            let identity = account.email ?? "ChatGPT"
            return plan.map { L10n.format("account.namedPlan", identity, $0) }
                ?? L10n.format("account.named", identity)
        case .apiKey: return L10n.string("account.apiKey")
        case .amazonBedrock: return L10n.string("account.amazonBedrock")
        case .unknown: return L10n.string("account.unknown")
        }
    }

    private func renderStatus(limit: DisplayedLimit?, stateText: String?, tooltip: String) {
        statusItem.button?.image = LimitStatusImage.make(limit: limit, stateText: stateText)
        statusItem.button?.toolTip = tooltip
        statusItem.button?.setAccessibilityLabel(tooltip)
    }

    private func startRefreshTimer() {
        guard refreshTimer == nil else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.client.refresh()
                self?.refreshClaude()
            }
        }
    }

    private func setMonitoringEnabled(_ enabled: Bool, persist: Bool) {
        monitoringEnabled = enabled
        monitoringItem.state = enabled ? .on : .off
        if persist { UserDefaults.standard.set(enabled, forKey: Self.monitoringDefaultsKey) }

        if enabled {
            client.start()
            refreshClaude()
            startRefreshTimer()
        } else {
            refreshTimer?.invalidate()
            refreshTimer = nil
            client.stop()
            clientConnected = false
            loginInProgress = false
        }
        render()
        updateActionAvailability()
    }

    private func updateActionAvailability() {
        refreshItem.isEnabled = monitoringEnabled
        switchAccountItem.isEnabled = monitoringEnabled && (clientConnected || loginInProgress)
        switchClaudeAccountItem.isEnabled = monitoringEnabled && claudeDesktopIsInstalled
    }

    private var claudeDesktopIsInstalled: Bool {
        if case .notInstalled = claudeResult { return false }
        return true
    }

    @objc private func refreshNow() {
        guard monitoringEnabled else { return }
        client.refresh()
        refreshClaude()
    }

    @objc private func toggleMonitoring() {
        setMonitoringEnabled(!monitoringEnabled, persist: true)
    }

    @objc private func switchAccount() {
        if loginInProgress {
            client.cancelLogin()
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.string("alert.switchAccount.title")
        alert.informativeText = L10n.string("alert.switchAccount.message")
        alert.addButton(withTitle: L10n.string("alert.switchAccount.continue"))
        alert.addButton(withTitle: L10n.string("alert.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        loginInProgress = true
        switchAccountItem.title = L10n.string("menu.startingLogin")
        updateActionAvailability()
        client.startChatGPTLogin()
    }

    @objc private func switchClaudeAccount() {
        guard let url = URL(string: "claude://claude.ai/settings/profile"),
              NSWorkspace.shared.open(url) else {
            showAlert(
                title: L10n.string("alert.claudeOpen.title"),
                message: L10n.string("alert.claudeOpen.message")
            )
            return
        }
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            try LaunchAtLoginManager.setEnabled(!LaunchAtLoginManager.isEnabled)
        } catch {
            showAlert(title: L10n.string("alert.launchAtLogin.title"), message: error.localizedDescription)
        }
        refreshLaunchAtLoginState()
    }

    private func refreshLaunchAtLoginState() {
        launchAtLoginItem.state = LaunchAtLoginManager.isEnabled ? .on : .off
        launchAtLoginItem.title = L10n.string("menu.launchAtLogin")
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: L10n.string("alert.ok"))
        alert.runModal()
    }

    @objc private func changeLanguage(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let language = AppLanguage(rawValue: rawValue),
              language != L10n.language else { return }
        AppLanguage.select(language)
        restartApplication()
    }

    private func restartApplication() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", Bundle.main.bundlePath]
        do {
            try process.run()
            NSApplication.shared.terminate(nil)
        } catch {
            showAlert(title: L10n.string("alert.restart.title"), message: error.localizedDescription)
        }
    }

    @objc private func activeApplicationChanged(_ notification: Notification) {
        let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        frontmostProvider = provider(for: application)
        render()
    }

    private func provider(for application: NSRunningApplication?) -> AIProvider? {
        guard let application else { return nil }
        return AIProvider.allCases.first { $0.matches(application) }
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshLaunchAtLoginState()
        if monitoringEnabled {
            client.refresh()
            refreshClaude()
        }
        menu.update()
        let width = max(Self.minimumContentWidth, menu.size.width)
        dashboardView.setFrameSize(NSSize(width: width, height: dashboardView.desiredHeight))
        dashboardView.needsDisplay = true
    }

    private func windowLabel(_ window: RateLimitWindow) -> String {
        LimitsDashboardView.windowLabel(window)
    }

    private func displayPlan(_ plan: String) -> String {
        switch plan.lowercased() {
        case "plus": return "Plus"
        case "pro": return "Pro"
        case "team": return "Team"
        case "business", "self_serve_business_usage_based": return "Business"
        case "enterprise", "enterprise_cbp_usage_based": return "Enterprise"
        case "free": return "Free"
        default: return plan.capitalized
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = L10n.language.locale
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}

private struct ProviderDashboardState {
    let provider: AIProvider
    let status: String
    let windows: [RateLimitWindow]
    var isStale = false
}

private final class LimitsDashboardView: NSView {
    private var active: DisplayedLimit?
    private var providers: [ProviderDashboardState] = []

    override var isFlipped: Bool { true }

    var desiredHeight: CGFloat {
        providers.reduce(CGFloat.zero) { result, provider in
            result + 50 + CGFloat(provider.windows.count) * 35
        }
    }

    func update(active: DisplayedLimit?, providers: [ProviderDashboardState]) {
        self.active = active
        self.providers = providers.sorted { left, right in
            if left.provider == active?.provider { return true }
            if right.provider == active?.provider { return false }
            return AIProvider.allCases.firstIndex(of: left.provider) ?? 0
                < AIProvider.allCases.firstIndex(of: right.provider) ?? 0
        }
        setFrameSize(NSSize(width: frame.width, height: desiredHeight))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        var y: CGFloat = 0
        for provider in providers {
            y = drawProvider(provider, at: y)
        }
    }

    private func drawProvider(_ state: ProviderDashboardState, at originY: CGFloat) -> CGFloat {
        let isActive = active?.provider == state.provider
        let sectionHeight = 50 + CGFloat(state.windows.count) * 35
        if isActive, let remaining = active?.window.remainingPercent {
            LimitPalette.color(for: remaining).withAlphaComponent(0.07).setFill()
            NSRect(x: 0, y: originY, width: bounds.width, height: sectionHeight - 1).fill()
            LimitPalette.color(for: remaining).withAlphaComponent(0.9).setFill()
            NSRect(x: 0, y: originY + 5, width: 3, height: sectionHeight - 11).fill()
        }

        let iconColor: NSColor = state.isStale ? .secondaryLabelColor : ProviderIcon.brandColor(for: state.provider)
        ProviderIcon.draw(state.provider, in: NSRect(x: 17, y: originY + 9, width: 18, height: 18), color: iconColor)
        drawText(state.provider.displayName, rect: NSRect(x: 45, y: originY + 5, width: 115, height: 18), font: .systemFont(ofSize: 13, weight: .semibold), color: .labelColor)
        drawText(state.status, rect: NSRect(x: 45, y: originY + 24, width: bounds.width - 61, height: 17), font: .systemFont(ofSize: 10.5), color: .secondaryLabelColor)

        var y = originY + 48
        for window in state.windows {
            let remaining = window.remainingPercent
            let selectedWindow = isActive && window == active?.window
            drawText(Self.windowLabel(window), rect: NSRect(x: 45, y: y, width: bounds.width - 127, height: 16), font: .systemFont(ofSize: 11.5, weight: selectedWindow ? .semibold : .medium), color: state.isStale ? .secondaryLabelColor : .labelColor)
            drawText("\(Int(remaining.rounded()))%", rect: NSRect(x: bounds.width - 72, y: y - 1, width: 56, height: 17), font: .monospacedDigitSystemFont(ofSize: 12, weight: .semibold), color: state.isStale ? .secondaryLabelColor : LimitPalette.color(for: remaining), alignment: .right)
            drawProgress(remaining, rect: NSRect(x: 45, y: y + 22, width: bounds.width - 61, height: selectedWindow ? 5 : 4), muted: state.isStale)
            y += 35
        }
        drawDivider(y: y - 1)
        return y + 2
    }

    static func windowLabel(_ window: RateLimitWindow) -> String {
        switch window.identifier {
        case "seven_day": return L10n.string("window.weekAllModels")
        case "seven_day_opus": return L10n.string("window.weekOpus")
        case "seven_day_oauth_apps": return L10n.string("window.weekOAuthApps")
        case "seven_day_cowork": return L10n.string("window.weekCowork")
        case "seven_day_model": return L10n.string("window.weekModel")
        case "promotional": return L10n.string("window.promotional")
        case "seven_day_sonnet": return L10n.string("window.weekSonnet")
        default:
            if window.windowDurationMinutes == 300 { return L10n.string("window.fiveHours") }
            if window.windowDurationMinutes == 10_080 { return L10n.string("window.week") }
            return L10n.string("window.limit")
        }
    }

    private func drawProgress(_ percent: Double?, rect: NSRect, muted: Bool = false) {
        NSColor.tertiaryLabelColor.withAlphaComponent(0.28).setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
        guard let percent, percent > 0 else { return }
        let fill = NSRect(x: rect.minX, y: rect.minY, width: max(rect.height, rect.width * min(100, percent) / 100), height: rect.height)
        (muted ? NSColor.secondaryLabelColor : LimitPalette.color(for: percent)).setFill()
        NSBezierPath(roundedRect: fill, xRadius: fill.height / 2, yRadius: fill.height / 2).fill()
    }

    private func drawDivider(y: CGFloat) {
        NSColor.separatorColor.withAlphaComponent(0.65).setFill()
        NSRect(x: 14, y: y, width: bounds.width - 28, height: 1).fill()
    }

    private func drawText(_ text: String, rect: NSRect, font: NSFont, color: NSColor, alignment: NSTextAlignment = .left) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingMiddle
        text.draw(in: rect, withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
    }
}

@MainActor
private enum LimitStatusImage {
    static func make(limit: DisplayedLimit?, stateText: String?) -> NSImage {
        let size = NSSize(width: 88, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            let value = limit.map { "\(Int($0.window.remainingPercent.rounded()))%" } ?? (stateText ?? "--")
            let window = limit.map { shortLabel($0.window) } ?? ""
            let windowAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let valueAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
            ]
            let valueWidth = value.size(withAttributes: valueAttributes).width
            let windowWidth = window.size(withAttributes: windowAttributes).width
            if let limit {
                let contentWidth = 13 + 4 + windowWidth + 5 + valueWidth
                let contentX = (size.width - contentWidth) / 2
                ProviderIcon.draw(limit.provider, in: NSRect(x: contentX, y: 3, width: 13, height: 13), color: .labelColor)
                window.draw(at: NSPoint(x: contentX + 17, y: 5.5), withAttributes: windowAttributes)
                value.draw(at: NSPoint(x: contentX + 17 + windowWidth + 5, y: 4), withAttributes: valueAttributes)
            } else {
                value.draw(at: NSPoint(x: (size.width - valueWidth) / 2, y: 4), withAttributes: valueAttributes)
            }

            let track = NSRect(x: 2, y: 0, width: size.width - 4, height: 2)
            NSColor.tertiaryLabelColor.withAlphaComponent(0.28).setFill()
            NSBezierPath(roundedRect: track, xRadius: 1, yRadius: 1).fill()
            if let limit, limit.window.remainingPercent > 0 {
                let fill = NSRect(x: track.minX, y: track.minY, width: max(3, track.width * limit.window.remainingPercent / 100), height: track.height)
                LimitPalette.color(for: limit.window.remainingPercent).setFill()
                NSBezierPath(roundedRect: fill, xRadius: 1, yRadius: 1).fill()
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func shortLabel(_ window: RateLimitWindow) -> String {
        if window.windowDurationMinutes == 300 { return L10n.string("window.short.five") }
        if window.windowDurationMinutes == 10_080 { return L10n.string("window.short.week") }
        return L10n.string("window.short.limit")
    }
}

@MainActor
private enum ProviderIcon {
    static func menuImage(for provider: AIProvider) -> NSImage? {
        guard let image = sourceImage(for: provider) else {
            return NSImage(systemSymbolName: provider.fallbackSymbolName, accessibilityDescription: provider.displayName)
        }
        let result = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            draw(image, in: rect, color: .labelColor)
            return true
        }
        result.isTemplate = false
        return result
    }

    static func draw(_ provider: AIProvider, in rect: NSRect, color: NSColor) {
        if let image = sourceImage(for: provider) {
            draw(image, in: rect, color: color)
            return
        }
        let configuration = NSImage.SymbolConfiguration(pointSize: rect.height, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        NSImage(systemSymbolName: provider.fallbackSymbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)?
            .draw(in: rect)
    }

    static func brandColor(for provider: AIProvider) -> NSColor {
        switch provider {
        case .codex: return .labelColor
        case .claude: return NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)
        }
    }

    private static func sourceImage(for provider: AIProvider) -> NSImage? {
        guard let url = Bundle.main.url(
            forResource: provider.iconAssetName,
            withExtension: "svg",
            subdirectory: "ProviderIcons"
        ) else { return nil }
        let image = NSImage(contentsOf: url)
        image?.isTemplate = true
        return image
    }

    private static func draw(_ image: NSImage, in rect: NSRect, color: NSColor) {
        NSGraphicsContext.saveGraphicsState()
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        color.setFill()
        rect.fill(using: .sourceIn)
        NSGraphicsContext.restoreGraphicsState()
    }
}

private enum LimitPalette {
    static func color(for remainingPercent: Double) -> NSColor {
        switch RateLimitIndicatorLevel(remainingPercent: remainingPercent) {
        case .green: return .systemGreen
        case .yellow: return .systemYellow
        case .red: return .systemRed
        }
    }
}
