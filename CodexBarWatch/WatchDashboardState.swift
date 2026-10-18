import Foundation

struct WatchUsageSample: Equatable, Identifiable, Sendable {
    let id: String
    let providerName: String
    let accountLabel: String
    let showsAccountContext: Bool
    let metricLabel: String
    let exactValue: String
    let usedFraction: Double?
    let severity: WatchMetricSeverity
    let resetText: String?
    let visualizationStyle: WatchMetricVisualizationStyle
    let freshnessText: String

    init(
        id: String,
        providerName: String,
        accountLabel: String,
        showsAccountContext: Bool = true,
        metricLabel: String,
        exactValue: String,
        usedFraction: Double?,
        severity: WatchMetricSeverity,
        resetText: String?,
        visualizationStyle: WatchMetricVisualizationStyle,
        freshnessText: String
    ) {
        self.id = id
        self.providerName = providerName
        self.accountLabel = accountLabel
        self.showsAccountContext = showsAccountContext
        self.metricLabel = metricLabel
        self.exactValue = exactValue
        self.usedFraction = usedFraction
        self.severity = severity
        self.resetText = resetText
        self.visualizationStyle = visualizationStyle
        self.freshnessText = freshnessText
    }

    var clampedUsedFraction: Double {
        min(max(usedFraction ?? 0, 0), 1)
    }

    var percentageText: String {
        usedFraction.map { "\(Int((max($0, 0) * 100).rounded()))%" } ?? exactValue
    }

    var severityText: String? {
        switch severity {
        case .normal:
            nil
        case .warning:
            "Warning"
        case .critical:
            "Critical"
        }
    }

    var accessibilitySummary: String {
        [
            providerName,
            accountLabel,
            metricLabel,
            exactValue,
            severityText,
            resetText,
            freshnessText,
        ]
        .compactMap { $0 }
        .filter { !$0.isEmpty }
        .joined(separator: ", ")
    }
}

struct WatchDashboardState: Equatable, Sendable {
    let title: String
    let statusText: String
    let samples: [WatchUsageSample]
    let isProLocked: Bool

    static let lockedMessage = "Unlock the watch app with CodexBar Pro on iPhone"

    static let empty = WatchDashboardState(
        title: "CodexBar",
        statusText: "Open CodexBar on iPhone",
        samples: []
    )

    init(
        snapshot: WatchDashboardSnapshot?,
        now: Date,
        isPhoneReachable: Bool,
        decodingError: String?
    ) {
        title = "CodexBar"
        isProLocked = snapshot?.isLocked(at: now) == true
        guard !isProLocked else {
            statusText = Self.lockedMessage
            samples = []
            return
        }
        guard let snapshot else {
            statusText = decodingError ?? "Open CodexBar on iPhone"
            samples = []
            return
        }

        let displayedAccounts = snapshot.accounts.filter { !$0.metrics.isEmpty }
        let oldestDisplayedFetch = displayedAccounts.map(\.fetchedAt).min() ?? snapshot.generatedAt
        let freshnessText = Self.lastUpdatedText(oldestDisplayedFetch, now: now)
        if let decodingError {
            statusText = "\(decodingError). Showing \(freshnessText.lowercased())"
        } else if displayedAccounts.isEmpty {
            statusText = Self.emptyStatusText(for: snapshot.accounts)
        } else if snapshot.isStale(dataDate: oldestDisplayedFetch, at: now) {
            statusText = "\(freshnessText) • Stale"
        } else if !isPhoneReachable {
            statusText = "\(freshnessText) • iPhone unavailable"
        } else {
            statusText = freshnessText
        }

        samples = snapshot.accounts.flatMap { account in
            let accountFreshnessText = Self.lastUpdatedText(account.fetchedAt, now: now)
            return account.metrics.enumerated().map { index, metric in
                WatchUsageSample(
                    id: "\(account.id).\(metric.id)",
                    providerName: account.providerName,
                    accountLabel: account.accountLabel,
                    showsAccountContext: index == 0,
                    metricLabel: metric.label,
                    exactValue: metric.exactValue,
                    usedFraction: metric.usedFraction,
                    severity: metric.severity,
                    resetText: metric.resetText,
                    visualizationStyle: metric.visualizationStyle,
                    freshnessText: accountFreshnessText
                )
            }
        }
    }

    init(title: String, statusText: String, samples: [WatchUsageSample], isProLocked: Bool = false) {
        self.title = title
        self.statusText = statusText
        self.samples = samples
        self.isProLocked = isProLocked
    }

    private static func lastUpdatedText(_ generatedAt: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(generatedAt)))
        if seconds < 60 {
            return "Updated just now"
        }
        if seconds < 3_600 {
            return "Updated \(seconds / 60)m ago"
        }
        if seconds < 86_400 {
            return "Updated \(seconds / 3_600)h ago"
        }
        return "Updated \(seconds / 86_400)d ago"
    }

    private static func emptyStatusText(for accounts: [WatchAccountSnapshot]) -> String {
        let accountStatuses = accounts.compactMap { account -> String? in
            guard let status = account.statusText?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !status.isEmpty else {
                return nil
            }
            return "\(account.providerName): \(status)"
        }
        return accountStatuses.isEmpty
            ? "No dashboard metrics on iPhone"
            : accountStatuses.joined(separator: " • ")
    }

    static let sample = WatchDashboardState(
        title: "CodexBar",
        statusText: "Sample data",
        samples: [
            WatchUsageSample(
                id: "codex-primary",
                providerName: "Codex",
                accountLabel: "Primary",
                metricLabel: "5-hour limit",
                exactValue: "72%",
                usedFraction: 0.72,
                severity: .warning,
                resetText: "Resets in 2h",
                visualizationStyle: .circularRing,
                freshnessText: "Updated just now"
            ),
            WatchUsageSample(
                id: "copilot-work",
                providerName: "Copilot",
                accountLabel: "Work",
                metricLabel: "Premium requests",
                exactValue: "38%",
                usedFraction: 0.38,
                severity: .normal,
                resetText: nil,
                visualizationStyle: .segmentedBar,
                freshnessText: "Updated just now"
            ),
        ]
    )
}

enum WatchAppStoreScreenshotScene: String, CaseIterable, Sendable {
    case overview
    case balances

    static let readyFileName = "app-store-watch-screenshot-ready"

    static var settleDelay: TimeInterval {
        settleDelay(
            arguments: ProcessInfo.processInfo.arguments,
            environment: ProcessInfo.processInfo.environment
        )
    }

    static func current(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> WatchAppStoreScreenshotScene? {
        guard arguments.contains("--app-store-screenshots") else { return nil }
        guard let sceneFlag = arguments.firstIndex(of: "--app-store-watch-scene"),
              arguments.indices.contains(sceneFlag + 1)
        else {
            return .overview
        }
        return WatchAppStoreScreenshotScene(rawValue: arguments[sceneFlag + 1])
    }

    static func settleDelay(
        arguments: [String],
        environment: [String: String] = [:]
    ) -> TimeInterval {
        let argumentValue = value(after: "--app-store-settle-seconds", in: arguments)
        let delay = argumentValue.flatMap(TimeInterval.init)
            ?? environment["CODEXBAR_APP_STORE_SETTLE_SECONDS"].flatMap(TimeInterval.init)
            ?? 3
        guard delay.isFinite else { return 3 }
        return min(max(delay, 0), 30)
    }

    func markReady(cachesDirectory: URL? = nil) {
        let resolvedCachesDirectory = cachesDirectory ?? FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first
        guard let resolvedCachesDirectory else { return }

        let readyFile = resolvedCachesDirectory.appendingPathComponent(Self.readyFileName)
        try? Data(rawValue.utf8).write(to: readyFile, options: .atomic)
    }

    private static func value(after argument: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: argument),
              arguments.indices.contains(index + 1)
        else {
            return nil
        }
        return arguments[index + 1]
    }

    var state: WatchDashboardState {
        switch self {
        case .overview:
            WatchDashboardState(
                title: "CodexBar",
                statusText: "Updated just now",
                samples: [
                    WatchUsageSample(
                        id: "screenshot-codex-studio",
                        providerName: "Codex",
                        accountLabel: "Demo Studio",
                        metricLabel: "5-hour limit",
                        exactValue: "72%",
                        usedFraction: 0.72,
                        severity: .warning,
                        resetText: "Resets in 2h",
                        visualizationStyle: .segmentedBar,
                        freshnessText: "Updated just now"
                    ),
                ]
            )
        case .balances:
            WatchDashboardState(
                title: "CodexBar",
                statusText: "Updated just now",
                samples: [
                    WatchUsageSample(
                        id: "screenshot-opencode-demo",
                        providerName: "OpenCode Zen",
                        accountLabel: "Demo Workspace",
                        metricLabel: "API balance",
                        exactValue: "$24.80",
                        usedFraction: nil,
                        severity: .normal,
                        resetText: nil,
                        visualizationStyle: .largeNumeric,
                        freshnessText: "Updated just now"
                    ),
                ]
            )
        }
    }
}
