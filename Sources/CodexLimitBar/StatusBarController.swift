import AppKit
import CodexLimitCore
import OSLog

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private static let monitoringDefaultsKey = "monitoringEnabled"
    private static let claudeAutomaticRefreshDefaultsKey = "claudeAutomaticRefreshEnabled"
    private static let codexVisibleDefaultsKey = "codexProviderVisible"
    private static let claudeVisibleDefaultsKey = "claudeProviderVisible"
    private static let claudeSetupPromptShownDefaultsKey = "claudeSetupPromptShown"
    private static let codexUsageSignatureDefaultsKey = "codexUsageSignature"
    private static let codexLastUsageChangeDefaultsKey = "codexLastUsageChangeAt"
    private static let minimumContentWidth: CGFloat = 420
    private static let recentActivityInterval: TimeInterval = 15 * 60
    private static let dualActivityInterval: TimeInterval = 30 * 60
    private static let claudeLaunchRetryInterval: TimeInterval = 10 * 60

    private let statusItem = NSStatusBar.system.statusItem(withLength: 90)
    private let client = CodexAppServerClient()
    private let dashboardView = LimitsDashboardView(frame: NSRect(x: 0, y: 0, width: 420, height: 235))
    private let logger = Logger(subsystem: "com.vitashka2001.AILimitBar", category: "limits")
    private let monitoringItem = NSMenuItem(title: L10n.string("menu.monitoring"), action: nil, keyEquivalent: "")
    private let displayedProvidersItem = NSMenuItem(title: L10n.string("menu.displayedProviders"), action: nil, keyEquivalent: "")
    private let showCodexItem = NSMenuItem(title: "Codex", action: nil, keyEquivalent: "")
    private let showClaudeItem = NSMenuItem(title: "Claude", action: nil, keyEquivalent: "")
    private let claudeAutomaticRefreshItem = NSMenuItem(title: L10n.string("menu.claudeAutomaticRefresh"), action: nil, keyEquivalent: "")
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
    private var claudeAutomaticRefreshEnabled = true
    private var codexProviderVisible = true
    private var claudeProviderVisible = true
    private var claudeLastLaunchAttemptAt: Date?
    private var claudeDesktopRefreshPID: pid_t?
    private var claudeDesktopLaunchID: UUID?
    private var claudePreviousApplicationPID: pid_t?
    private var claudeRefreshChecksRemaining = 0
    private var clientConnected = false
    private var loginInProgress = false
    private var codexUsageSignature: [String: Double] = [:]
    private var codexLastUsageChangeAt: Date?
    private var frontmostProvider: AIProvider?

    override init() {
        super.init()
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.codexVisibleDefaultsKey) != nil {
            codexProviderVisible = defaults.bool(forKey: Self.codexVisibleDefaultsKey)
        }
        if defaults.object(forKey: Self.claudeVisibleDefaultsKey) != nil {
            claudeProviderVisible = defaults.bool(forKey: Self.claudeVisibleDefaultsKey)
        }
        if !codexProviderVisible && !claudeProviderVisible {
            codexProviderVisible = true
        }
        frontmostProvider = provider(for: NSWorkspace.shared.frontmostApplication)
        configureStatusItem()
        configureClient()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeApplicationChanged),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(claudeCodeUsageUpdated),
            name: ClaudeCodeIntegration.usageUpdatedNotification,
            object: nil
        )
        LaunchAtLoginManager.migrateIfNeeded()
        let storedClaudeRefresh = UserDefaults.standard.object(
            forKey: Self.claudeAutomaticRefreshDefaultsKey
        ) as? Bool
        claudeAutomaticRefreshEnabled = storedClaudeRefresh ?? true
        refreshClaudeAutomaticRefreshState()
        let storedValue = UserDefaults.standard.object(forKey: Self.monitoringDefaultsKey) as? Bool
        setMonitoringEnabled(storedValue ?? true, persist: false)
        refreshLaunchAtLoginState()
        scheduleInitialClaudeSetupRecommendation()
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
        stopOwnedClaudeDesktop()
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
        configureDisplayedProvidersMenu()
        configureMenuItem(
            claudeAutomaticRefreshItem,
            action: #selector(toggleClaudeAutomaticRefresh),
            symbol: "bolt.horizontal.circle"
        )
        configureProviderMenuItem(switchAccountItem, action: #selector(switchAccount), provider: .codex)
        configureProviderMenuItem(switchClaudeAccountItem, action: #selector(switchClaudeAccount), provider: .claude)
        configureMenuItem(launchAtLoginItem, action: #selector(toggleLaunchAtLogin), symbol: "power")
        menu.addItem(monitoringItem)
        menu.addItem(displayedProvidersItem)
        menu.addItem(claudeAutomaticRefreshItem)
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

    private func configureDisplayedProvidersMenu() {
        if let image = NSImage(systemSymbolName: "eye", accessibilityDescription: displayedProvidersItem.title) {
            image.isTemplate = true
            displayedProvidersItem.image = image
        }
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for (item, provider) in [(showCodexItem, AIProvider.codex), (showClaudeItem, AIProvider.claude)] {
            configureProviderMenuItem(item, action: #selector(toggleProviderVisibility), provider: provider)
            item.representedObject = provider.rawValue
            submenu.addItem(item)
        }
        displayedProvidersItem.submenu = submenu
        refreshProviderVisibilityState()
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
        if codexUsageSignature.isEmpty {
            let defaults = UserDefaults.standard
            let storedSignature = defaults.dictionary(forKey: Self.codexUsageSignatureDefaultsKey)?
                .compactMapValues { ($0 as? NSNumber)?.doubleValue }
            if storedSignature == signature {
                codexLastUsageChangeAt = defaults.object(
                    forKey: Self.codexLastUsageChangeDefaultsKey
                ) as? Date
            } else {
                recordCodexActivity(signature: signature)
            }
        } else if signature != codexUsageSignature {
            recordCodexActivity(signature: signature)
        }
        codexUsageSignature = signature
        codexSnapshot = snapshot
        render()
    }

    private func recordCodexActivity(signature: [String: Double], at date: Date = Date()) {
        codexLastUsageChangeAt = date
        UserDefaults.standard.set(signature, forKey: Self.codexUsageSignatureDefaultsKey)
        UserDefaults.standard.set(date, forKey: Self.codexLastUsageChangeDefaultsKey)
    }

    private func refreshClaude(forceDesktopRefresh: Bool = false) {
        claudeResult = ClaudeUsageReader.read()
        render()
        updateActionAvailability()
        refreshClaudeViaDesktopIfNeeded(force: forceDesktopRefresh)
    }

    private func render() {
        guard monitoringEnabled else {
            dashboardView.update(
                active: nil,
                providers: visibleProviders.map {
                    ProviderDashboardState(provider: $0, status: L10n.string("dashboard.monitoringStopped"), windows: [])
                }
            )
            renderStatus(limits: [], stateText: L10n.string("status.off"), tooltip: L10n.string("status.monitoringStopped.tooltip"))
            return
        }

        let selected = selectDisplayedLimits()
        let providers = visibleProviders.map { provider in
            switch provider {
            case .codex: return codexDashboardState()
            case .claude: return claudeDashboardState()
            }
        }
        dashboardView.update(active: selected.first, providers: providers)
        if !selected.isEmpty {
            let title = selected.map {
                L10n.format(
                    "limits.providerTooltip",
                    $0.provider.displayName,
                    windowLabel($0.window),
                    Int($0.window.remainingPercent.rounded())
                )
            }.joined(separator: "\n")
            renderStatus(limits: selected, stateText: nil, tooltip: title)
        } else {
            renderStatus(limits: [], stateText: "--", tooltip: L10n.string("limits.noFreshData"))
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
        if claudeRefreshChecksRemaining > 0 {
            let windows: [RateLimitWindow]
            if case .available(let snapshot) = claudeResult {
                windows = snapshot.limits.windows
            } else {
                windows = []
            }
            return ProviderDashboardState(
                provider: .claude,
                status: L10n.string("claude.refreshingViaDesktop"),
                windows: windows,
                isStale: true
            )
        }

        switch claudeResult {
        case .available(let snapshot):
            let key: String
            switch (snapshot.source, snapshot.isFresh()) {
            case (.claudeCode, true): key = "claude.codeUpdated"
            case (.claudeCode, false): key = "claude.codeStale"
            case (.desktop, true): key = "claude.desktopUpdated"
            case (.desktop, false):
                key = claudeDesktopIsInstalled ? "claude.desktopStale" : "claude.desktopUnavailable"
            }
            return ProviderDashboardState(
                provider: .claude,
                status: L10n.format(key, Self.dateFormatter.string(from: snapshot.limits.fetchedAt)),
                windows: snapshot.limits.windows,
                isStale: !snapshot.isFresh()
            )
        case .notInstalled:
            let key = ClaudeCodeIntegration.isAvailable && ClaudeCodeIntegration.isInstalled
                ? "claude.waitingForCode"
                : "claude.noLiveSource"
            return ProviderDashboardState(provider: .claude, status: L10n.string(key), windows: [])
        case .noData:
            let key = ClaudeCodeIntegration.isAvailable && ClaudeCodeIntegration.isInstalled
                ? "claude.waitingForCode"
                : "claude.noData"
            return ProviderDashboardState(provider: .claude, status: L10n.string(key), windows: [])
        case .failed:
            return ProviderDashboardState(provider: .claude, status: L10n.string("claude.failed"), windows: [])
        }
    }

    private func selectDisplayedLimits(now: Date = Date()) -> [DisplayedLimit] {
        var candidates: [(limit: DisplayedLimit, activity: Date?)] = []
        if codexProviderVisible, clientConnected, let window = codexSnapshot?.mostConstrainedWindow {
            candidates.append((DisplayedLimit(provider: .codex, window: window), codexLastUsageChangeAt))
        }
        if claudeProviderVisible,
           case .available(let claude) = claudeResult,
           claude.isFresh(at: now),
           let window = claude.limits.mostConstrainedWindow {
            candidates.append((DisplayedLimit(provider: .claude, window: window), claude.lastUsageChangeAt))
        }
        guard !candidates.isEmpty else { return [] }

        let dualSession = candidates.filter {
            guard let activity = $0.activity else { return false }
            return now.timeIntervalSince(activity) <= Self.dualActivityInterval
        }
        if dualSession.count > 1 {
            return dualSession
                .sorted { left, right in
                    let leftIndex = AIProvider.allCases.firstIndex(of: left.limit.provider) ?? 0
                    let rightIndex = AIProvider.allCases.firstIndex(of: right.limit.provider) ?? 0
                    return leftIndex < rightIndex
                }
                .map(\.limit)
        }

        let recentlyUsed = candidates.filter {
            guard let activity = $0.activity else { return false }
            return now.timeIntervalSince(activity) <= Self.recentActivityInterval
        }

        let critical = candidates.filter { $0.limit.window.remainingPercent < 20 }
        if let lowest = critical.min(by: { $0.limit.window.remainingPercent < $1.limit.window.remainingPercent }) {
            return [lowest.limit]
        }

        if let latest = recentlyUsed.max(by: { ($0.activity ?? .distantPast) < ($1.activity ?? .distantPast) }) {
            return [latest.limit]
        }

        if let frontmostProvider,
           let frontmost = candidates.first(where: { $0.limit.provider == frontmostProvider }) {
            return [frontmost.limit]
        }
        return candidates
            .min(by: { $0.limit.window.remainingPercent < $1.limit.window.remainingPercent })
            .map { [$0.limit] } ?? []
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

    private func renderStatus(limits: [DisplayedLimit], stateText: String?, tooltip: String) {
        statusItem.length = LimitStatusImage.width(for: limits.count)
        statusItem.button?.image = LimitStatusImage.make(limits: limits, stateText: stateText)
        statusItem.button?.toolTip = tooltip
        statusItem.button?.setAccessibilityLabel(tooltip)
    }

    private func startRefreshTimer() {
        guard refreshTimer == nil else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.codexProviderVisible { self.client.refresh() }
                if self.claudeProviderVisible { self.refreshClaude() }
            }
        }
    }

    private func setMonitoringEnabled(_ enabled: Bool, persist: Bool) {
        monitoringEnabled = enabled
        monitoringItem.state = enabled ? .on : .off
        if persist { UserDefaults.standard.set(enabled, forKey: Self.monitoringDefaultsKey) }

        if enabled {
            if codexProviderVisible { client.start() }
            if claudeProviderVisible { refreshClaude() }
            startRefreshTimer()
        } else {
            refreshTimer?.invalidate()
            refreshTimer = nil
            stopOwnedClaudeDesktop()
            client.stop()
            clientConnected = false
            loginInProgress = false
        }
        render()
        updateActionAvailability()
    }

    private func updateActionAvailability() {
        refreshItem.isEnabled = monitoringEnabled
        switchAccountItem.isHidden = !codexProviderVisible
        switchClaudeAccountItem.isHidden = !claudeProviderVisible
        claudeAutomaticRefreshItem.isHidden = !claudeProviderVisible
        switchAccountItem.isEnabled = monitoringEnabled && codexProviderVisible && (clientConnected || loginInProgress)
        switchClaudeAccountItem.isEnabled = monitoringEnabled && claudeProviderVisible
        switchClaudeAccountItem.title = L10n.string(
            claudeDesktopIsInstalled ? "menu.switchClaudeAccount" : "menu.setupClaude"
        )
        claudeAutomaticRefreshItem.isEnabled = monitoringEnabled && claudeProviderVisible
        refreshProviderVisibilityState()
    }

    private var claudeDesktopIsInstalled: Bool {
        ClaudeUsageReader.desktopIsInstalled()
    }

    @objc private func refreshNow() {
        guard monitoringEnabled else { return }
        if codexProviderVisible { client.refresh() }
        if claudeProviderVisible { refreshClaude(forceDesktopRefresh: true) }
    }

    @objc private func toggleMonitoring() {
        setMonitoringEnabled(!monitoringEnabled, persist: true)
    }

    @objc private func toggleClaudeAutomaticRefresh() {
        let enabling = !claudeAutomaticRefreshEnabled
        if enabling, ClaudeCodeIntegration.isAvailable, !ClaudeCodeIntegration.isInstalled {
            guard let executableURL = Bundle.main.executableURL else { return }
            switch ClaudeCodeIntegration.install(executableURL: executableURL) {
            case .installed:
                break
            case .conflict:
                showAlert(
                    title: L10n.string("alert.claudeIntegrationConflict.title"),
                    message: L10n.string("alert.claudeIntegrationConflict.message")
                )
                return
            case .failed:
                showAlert(
                    title: L10n.string("alert.claudeIntegrationFailed.title"),
                    message: L10n.string("alert.claudeIntegrationFailed.message")
                )
                return
            }
        } else if !enabling, ClaudeCodeIntegration.isInstalled {
            guard ClaudeCodeIntegration.uninstall() else {
                showAlert(
                    title: L10n.string("alert.claudeIntegrationFailed.title"),
                    message: L10n.string("alert.claudeIntegrationFailed.message")
                )
                return
            }
        }

        claudeAutomaticRefreshEnabled = enabling
        UserDefaults.standard.set(enabling, forKey: Self.claudeAutomaticRefreshDefaultsKey)
        if !enabling { stopOwnedClaudeDesktop() }
        refreshClaudeAutomaticRefreshState()
        refreshClaude()
    }

    private func refreshClaudeAutomaticRefreshState() {
        claudeAutomaticRefreshItem.state = claudeAutomaticRefreshEnabled ? .on : .off
    }

    private func refreshClaudeViaDesktopIfNeeded(now: Date = Date(), force: Bool = false) {
        guard monitoringEnabled,
              claudeProviderVisible,
              claudeAutomaticRefreshEnabled,
              let applicationURL = ClaudeUsageReader.desktopApplicationURL() else { return }
        guard claudeRefreshChecksRemaining == 0 else { return }

        let needsRefresh: Bool
        switch claudeResult {
        case .available(let snapshot): needsRefresh = !snapshot.isFresh(at: now)
        case .noData, .failed: needsRefresh = true
        case .notInstalled: needsRefresh = false
        }
        guard needsRefresh else { return }
        guard NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.anthropic.claudefordesktop"
        ).isEmpty else { return }
        if !force, let lastAttempt = claudeLastLaunchAttemptAt,
           now.timeIntervalSince(lastAttempt) < Self.claudeLaunchRetryInterval {
            return
        }

        claudeLastLaunchAttemptAt = now
        claudePreviousApplicationPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        claudeDesktopRefreshPID = nil
        claudeRefreshChecksRemaining = 6
        let launchID = UUID()
        claudeDesktopLaunchID = launchID
        render()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-gj", applicationURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            scheduleClaudeDesktopConcealmentCheck(launchID: launchID)
            scheduleClaudeDesktopRefreshCheck()
        } catch {
            logger.error("Could not launch Claude Desktop fallback: \(error.localizedDescription, privacy: .public)")
            resetClaudeDesktopRefreshState()
            render()
        }
    }

    private func scheduleClaudeDesktopConcealmentCheck(launchID: UUID, attemptsRemaining: Int = 80) {
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self,
                      self.claudeDesktopLaunchID == launchID,
                      self.claudeRefreshChecksRemaining > 0 else { return }
                if let application = NSRunningApplication.runningApplications(
                    withBundleIdentifier: "com.anthropic.claudefordesktop"
                ).first {
                    self.concealOwnedClaudeDesktop(application)
                }
                if attemptsRemaining > 1 {
                    self.scheduleClaudeDesktopConcealmentCheck(
                        launchID: launchID,
                        attemptsRemaining: attemptsRemaining - 1
                    )
                }
            }
        }
    }

    private func scheduleClaudeDesktopRefreshCheck() {
        Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.completeClaudeDesktopRefresh() }
        }
    }

    private func completeClaudeDesktopRefresh() {
        guard claudeRefreshChecksRemaining > 0 else { return }
        let applications = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.anthropic.claudefordesktop"
        )
        if claudeDesktopRefreshPID == nil {
            claudeDesktopRefreshPID = applications.first?.processIdentifier
        }
        if let application = applications.first(where: {
            $0.processIdentifier == claudeDesktopRefreshPID
        }) {
            concealOwnedClaudeDesktop(application)
        }

        claudeResult = ClaudeUsageReader.read()
        let receivedFreshData: Bool
        if case .available(let snapshot) = claudeResult {
            receivedFreshData = snapshot.isFresh()
        } else {
            receivedFreshData = false
        }

        claudeRefreshChecksRemaining -= 1
        if !receivedFreshData, claudeRefreshChecksRemaining > 0 {
            render()
            updateActionAvailability()
            scheduleClaudeDesktopRefreshCheck()
            return
        }
        stopOwnedClaudeDesktop()
        render()
        updateActionAvailability()
    }

    private func stopOwnedClaudeDesktop() {
        if claudeDesktopRefreshPID == nil, claudeRefreshChecksRemaining > 0 {
            claudeDesktopRefreshPID = NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.anthropic.claudefordesktop"
            ).first?.processIdentifier
        }
        let ownedPID = claudeDesktopRefreshPID
        resetClaudeDesktopRefreshState()
        guard let ownedPID,
              let application = NSRunningApplication(processIdentifier: ownedPID) else { return }

        application.terminate()
        Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { _ in
            guard let running = NSRunningApplication(processIdentifier: ownedPID),
                  !running.isTerminated else { return }
            running.forceTerminate()
        }
    }

    private func resetClaudeDesktopRefreshState() {
        claudeDesktopLaunchID = nil
        claudeDesktopRefreshPID = nil
        claudePreviousApplicationPID = nil
        claudeRefreshChecksRemaining = 0
    }

    private func concealOwnedClaudeDesktop(_ application: NSRunningApplication) {
        guard claudeRefreshChecksRemaining > 0,
              application.bundleIdentifier == "com.anthropic.claudefordesktop",
              claudeDesktopRefreshPID == nil || claudeDesktopRefreshPID == application.processIdentifier else {
            return
        }
        claudeDesktopRefreshPID = application.processIdentifier
        application.hide()

        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier,
              let previousPID = claudePreviousApplicationPID,
              let previousApplication = NSRunningApplication(processIdentifier: previousPID),
              !previousApplication.isTerminated else { return }
        previousApplication.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    }

    @objc private func claudeCodeUsageUpdated(_ notification: Notification) {
        guard monitoringEnabled, claudeProviderVisible else { return }
        refreshClaude()
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
        guard claudeDesktopIsInstalled else {
            showClaudeSetupRecommendation()
            return
        }
        guard let url = URL(string: "claude://claude.ai/settings/profile"),
              NSWorkspace.shared.open(url) else {
            showAlert(
                title: L10n.string("alert.claudeOpen.title"),
                message: L10n.string("alert.claudeOpen.message")
            )
            return
        }
    }

    private var hasConfiguredClaudeSource: Bool {
        claudeDesktopIsInstalled
            || (ClaudeCodeIntegration.isAvailable && ClaudeCodeIntegration.isInstalled)
    }

    private var visibleProviders: [AIProvider] {
        AIProvider.allCases.filter { provider in
            switch provider {
            case .codex: return codexProviderVisible
            case .claude: return claudeProviderVisible
            }
        }
    }

    private func scheduleInitialClaudeSetupRecommendation() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.claudeSetupPromptShownDefaultsKey) else { return }
        defaults.set(true, forKey: Self.claudeSetupPromptShownDefaultsKey)
        guard monitoringEnabled, claudeProviderVisible, !hasConfiguredClaudeSource else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.claudeProviderVisible, !self.hasConfiguredClaudeSource else { return }
            self.showClaudeSetupRecommendation()
        }
    }

    @objc private func toggleProviderVisibility(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let provider = AIProvider(rawValue: rawValue) else { return }
        switch provider {
        case .codex:
            guard !codexProviderVisible || claudeProviderVisible else { return }
            codexProviderVisible.toggle()
            UserDefaults.standard.set(codexProviderVisible, forKey: Self.codexVisibleDefaultsKey)
            if monitoringEnabled {
                if codexProviderVisible {
                    client.start()
                } else {
                    if loginInProgress { client.cancelLogin() }
                    client.stop()
                    clientConnected = false
                    loginInProgress = false
                }
            }
        case .claude:
            guard !claudeProviderVisible || codexProviderVisible else { return }
            claudeProviderVisible.toggle()
            UserDefaults.standard.set(claudeProviderVisible, forKey: Self.claudeVisibleDefaultsKey)
            if claudeProviderVisible, monitoringEnabled {
                refreshClaude()
            } else {
                stopOwnedClaudeDesktop()
            }
        }
        render()
        updateActionAvailability()
    }

    private func refreshProviderVisibilityState() {
        showCodexItem.state = codexProviderVisible ? .on : .off
        showClaudeItem.state = claudeProviderVisible ? .on : .off
        showCodexItem.isEnabled = !codexProviderVisible || claudeProviderVisible
        showClaudeItem.isEnabled = !claudeProviderVisible || codexProviderVisible
    }

    private func showClaudeSetupRecommendation() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.string("alert.claudeSetup.title")
        alert.informativeText = L10n.string("alert.claudeSetup.message")
        alert.addButton(withTitle: L10n.string("alert.claudeSetup.codeButton"))
        alert.addButton(withTitle: L10n.string("alert.claudeSetup.desktopButton"))
        alert.addButton(withTitle: L10n.string("alert.cancel"))

        let urlString: String?
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            urlString = "https://code.claude.com/docs/en/quickstart"
        case .alertSecondButtonReturn:
            urlString = "https://claude.com/download"
        default:
            urlString = nil
        }
        guard let urlString, let url = URL(string: urlString) else { return }
        guard NSWorkspace.shared.open(url) else {
            showAlert(
                title: L10n.string("alert.browser.title"),
                message: L10n.string("alert.browser.message")
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
        if let application,
           claudeRefreshChecksRemaining > 0,
           application.bundleIdentifier == "com.anthropic.claudefordesktop" {
            concealOwnedClaudeDesktop(application)
            return
        }
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
            if codexProviderVisible { client.refresh() }
            if claudeProviderVisible { refreshClaude() }
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
    private static let providerHeaderHeight: CGFloat = 50
    private static let compactWindowHeight: CGFloat = 35
    private static let resetDetailsOffset: CGFloat = 18
    private static let resetWindowHeight = compactWindowHeight + resetDetailsOffset

    private var active: DisplayedLimit?
    private var providers: [ProviderDashboardState] = []

    override var isFlipped: Bool { true }

    var desiredHeight: CGFloat {
        providers.reduce(CGFloat.zero) { result, provider in
            result + Self.providerHeaderHeight
                + provider.windows.reduce(CGFloat.zero) { $0 + Self.windowHeight(for: $1) }
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
        let sectionHeight = Self.providerHeaderHeight
            + state.windows.reduce(CGFloat.zero) { $0 + Self.windowHeight(for: $1) }
        if isActive, let remaining = active?.window.remainingPercent {
            LimitPalette.color(for: remaining).withAlphaComponent(0.07).setFill()
            NSRect(x: 0, y: originY, width: bounds.width, height: sectionHeight - 1).fill()
            LimitPalette.color(for: remaining).withAlphaComponent(0.9).setFill()
            NSRect(x: 0, y: originY + 5, width: 3, height: sectionHeight - 11).fill()
        }

        let iconColor: NSColor = state.isStale ? .secondaryLabelColor : ProviderIcon.brandColor(for: state.provider)
        ProviderIcon.draw(state.provider, in: NSRect(x: 16, y: originY + 7, width: 20, height: 20), color: iconColor)
        drawText(state.provider.displayName, rect: NSRect(x: 45, y: originY + 5, width: 115, height: 18), font: .systemFont(ofSize: 13, weight: .semibold), color: .labelColor)
        drawText(state.status, rect: NSRect(x: 45, y: originY + 24, width: bounds.width - 61, height: 17), font: .systemFont(ofSize: 10.5), color: .secondaryLabelColor)

        var y = originY + 48
        for window in state.windows {
            let remaining = window.remainingPercent
            let selectedWindow = isActive && window == active?.window
            let detailsOffset = window.resetsAt == nil ? CGFloat.zero : Self.resetDetailsOffset
            drawText(Self.windowLabel(window), rect: NSRect(x: 45, y: y, width: bounds.width - 127, height: 16), font: .systemFont(ofSize: 11.5, weight: selectedWindow ? .semibold : .medium), color: state.isStale ? .secondaryLabelColor : .labelColor)
            drawText("\(Int(remaining.rounded()))%", rect: NSRect(x: bounds.width - 72, y: y - 1 + detailsOffset, width: 56, height: 17), font: .monospacedDigitSystemFont(ofSize: 12, weight: .semibold), color: state.isStale ? .secondaryLabelColor : LimitPalette.color(for: remaining), alignment: .right)
            if let resetsAt = window.resetsAt {
                let resetText = L10n.format("window.resetAt", Self.resetDateFormatter.string(from: resetsAt))
                drawText(resetText, rect: NSRect(x: 45, y: y + 17, width: bounds.width - 127, height: 14), font: .systemFont(ofSize: 10, weight: .regular), color: .secondaryLabelColor)
            }
            let progressY = y + 22 + detailsOffset
            drawProgress(remaining, rect: NSRect(x: 45, y: progressY, width: bounds.width - 61, height: selectedWindow ? 5 : 4), muted: state.isStale)
            y += Self.windowHeight(for: window)
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

    private static func windowHeight(for window: RateLimitWindow) -> CGFloat {
        window.resetsAt == nil ? compactWindowHeight : resetWindowHeight
    }

    private static let resetDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = L10n.language.locale
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

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
    private static let singleWidth: CGFloat = 88
    private static let dualWidth: CGFloat = 158
    private static let segmentGap: CGFloat = 8

    static func width(for limitCount: Int) -> CGFloat {
        limitCount > 1 ? dualWidth + 2 : singleWidth + 2
    }

    static func make(limits: [DisplayedLimit], stateText: String?) -> NSImage {
        let size = NSSize(width: limits.count > 1 ? dualWidth : singleWidth, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            if limits.count > 1 {
                let segmentWidth = (size.width - segmentGap) / 2
                draw(limits[0], in: NSRect(x: 0, y: 0, width: segmentWidth, height: size.height))
                draw(limits[1], in: NSRect(x: segmentWidth + segmentGap, y: 0, width: segmentWidth, height: size.height))
                NSColor.separatorColor.withAlphaComponent(0.8).setFill()
                NSRect(x: size.width / 2 - 2.5, y: 4, width: 1, height: 12).fill()
            } else if let limit = limits.first {
                draw(limit, in: NSRect(origin: .zero, size: size))
            } else {
                let value = stateText ?? "--"
                let valueAttributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold),
                    .foregroundColor: NSColor.labelColor,
                ]
                let valueWidth = value.size(withAttributes: valueAttributes).width
                value.draw(at: NSPoint(x: (size.width - valueWidth) / 2, y: 4), withAttributes: valueAttributes)
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func draw(_ limit: DisplayedLimit, in rect: NSRect) {
        let value = "\(Int(limit.window.remainingPercent.rounded()))%"
        let window = shortLabel(limit.window)
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
        let contentWidth = 14 + 3 + windowWidth + 4 + valueWidth
        let contentX = rect.minX + (rect.width - contentWidth) / 2
        ProviderIcon.draw(limit.provider, in: NSRect(x: contentX, y: 4, width: 14, height: 14), color: .labelColor)
        window.draw(at: NSPoint(x: contentX + 17, y: 5.5), withAttributes: windowAttributes)
        value.draw(at: NSPoint(x: contentX + 17 + windowWidth + 4, y: 4), withAttributes: valueAttributes)

        let track = NSRect(x: rect.minX + 2, y: 0, width: rect.width - 4, height: 2)
        NSColor.tertiaryLabelColor.withAlphaComponent(0.28).setFill()
        NSBezierPath(roundedRect: track, xRadius: 1, yRadius: 1).fill()
        guard limit.window.remainingPercent > 0 else { return }
        let fill = NSRect(
            x: track.minX,
            y: track.minY,
            width: max(3, track.width * limit.window.remainingPercent / 100),
            height: track.height
        )
        LimitPalette.color(for: limit.window.remainingPercent).setFill()
        NSBezierPath(roundedRect: fill, xRadius: 1, yRadius: 1).fill()
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
        guard sourceImage(for: provider) != nil else {
            return NSImage(systemSymbolName: provider.fallbackSymbolName, accessibilityDescription: provider.displayName)
        }
        let result = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            draw(provider, in: rect, color: .labelColor)
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
            withExtension: provider.iconAssetExtension,
            subdirectory: "ProviderIcons"
        ) else { return nil }
        let image = NSImage(contentsOf: url)
        image?.isTemplate = true
        return image
    }

    private static func draw(_ image: NSImage, in rect: NSRect, color: NSColor) {
        NSGraphicsContext.saveGraphicsState()
        image.draw(
            in: rect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )
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
