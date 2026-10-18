import Combine
import CryptoKit
import Foundation
import OSLog

#if os(iOS)
import WatchConnectivity

private let phoneWatchConnectivityLogger = Logger(
    subsystem: "com.hemsoft.CodexBarIOS",
    category: "WatchConnectivity.Phone"
)

private struct PhoneWatchReplyHandler: @unchecked Sendable {
    let send: ([String: Any]) -> Void

    init(_ send: @escaping ([String: Any]) -> Void) {
        self.send = send
    }
}
#endif

private extension WatchMetricSeverity {
    init(_ severity: UsageSeverity) {
        switch severity {
        case .normal:
            self = .normal
        case .warning:
            self = .warning
        case .critical:
            self = .critical
        }
    }
}

private extension WatchMetricVisualizationStyle {
    init(_ style: MetricVisualizationStyle) {
        self = Self(rawValue: style.rawValue) ?? .automatic
    }
}

@MainActor
protocol WatchSnapshotSending: AnyObject {
    var retainedSnapshot: WatchDashboardSnapshot? { get }
    func activate(onSnapshotNeeded: @escaping @MainActor (_ force: Bool) -> Void)
    @discardableResult
    func publish(_ snapshot: WatchDashboardSnapshot, force: Bool) -> Bool
}

extension WatchSnapshotSending {
    var retainedSnapshot: WatchDashboardSnapshot? { nil }
}

struct WatchSnapshotDeduplicator {
    private(set) var lastSemanticData: Data?

    func shouldSend(_ snapshot: WatchDashboardSnapshot, force: Bool) throws -> Bool {
        let semanticData = try snapshot.semanticData()
        return force || semanticData != lastSemanticData
    }

    mutating func recordSent(_ snapshot: WatchDashboardSnapshot) throws {
        lastSemanticData = try snapshot.semanticData()
    }
}

@MainActor
enum WatchSnapshotPublisher {
    static func makeSnapshot(
        results: [ProviderUsageResult],
        configurationStore: ProviderConfigurationStore,
        access: SnapshotProAccess = .locked,
        retainedSnapshot: WatchDashboardSnapshot? = nil,
        now: Date = Date(),
        dateTimeFormatter: UserFacingDateTimeFormatter = .current
    ) -> WatchDashboardSnapshot {
        if !access.isProLocked, results.isEmpty, let retainedSnapshot {
            let eligibleIDs = Set(configurationStore.configurations.filter {
                configurationStore.shouldDisplayOnDashboard($0)
                    && !configurationStore.accountAccess.isPaused(accountID: $0.id)
            }.map { snapshotAccountID(providerID: $0.providerID, configurationID: $0.id) })
            return WatchDashboardSnapshot(
                generatedAt: retainedSnapshot.generatedAt,
                refreshIntervalSeconds: configurationStore.autoRefreshInterval.seconds,
                accounts: retainedSnapshot.accounts.filter { eligibleIDs.contains($0.id) },
                isProLocked: false, proAccessEndsAt: access.proAccessEndsAt,
                proAccessEffectiveAt: access.proAccessEffectiveAt
            )
        }
        let orderedResults = access.isProLocked ? [] : orderedDisplayableResults(
            results: results,
            configurationStore: configurationStore,
            now: now
        )

        return WatchDashboardSnapshot(
            generatedAt: now,
            refreshIntervalSeconds: configurationStore.autoRefreshInterval.seconds,
            accounts: orderedResults.compactMap { result -> WatchAccountSnapshot? in
                guard let configuration = configurationStore.configuration(accountID: result.accountID) else {
                    return nil
                }

                let barMetrics: [WatchMetricSnapshot] = result.enabledBarIndices.map { index in
                    let bar = result.bars[index]
                    let severityThresholds =
                        configurationStore.usageAlertSettings.severityThresholds
                    let metricID = bar.metricIdentifier(providerID: result.providerID, index: index)
                    let hasKnownLimit = bar.limit > 0
                    let fraction = hasKnownLimit ? max(bar.used / bar.limit, 0) : nil
                    let localizedResetText = bar.localizedResetDescription(
                        at: now,
                        dateTimeFormatter: dateTimeFormatter
                    )
                    return WatchMetricSnapshot(
                        id: metricID,
                        label: bar.label,
                        usedFraction: fraction,
                        remainingFraction: fraction.map { 1 - $0 },
                        exactValue: hasKnownLimit
                            ? bar.usageText
                            : (bar.fractionlessUsageText ?? bar.used.formatted()),
                        severity: result.hasFreshBars
                            ? WatchMetricSeverity(
                                bar.effectiveSeverity(
                                    at: now,
                                    thresholds: severityThresholds
                                )
                            )
                            : .normal,
                        resetText: localizedResetText
                            ?? (result.hasFreshBars ? bar.projectionDescriptionOverride : nil),
                        resetsAt: bar.resetsAt,
                        resetDisplayStyle: bar.resetDisplayStyle,
                        fetchedAt: result.barsFetchedAt ?? result.fetchedAt,
                        visualizationStyle: bar.isUnboundedNumeric
                            ? .largeNumeric
                            : WatchMetricVisualizationStyle(
                                configurationStore.visualizationStyle(
                                    accountID: result.accountID,
                                    metricID: metricID
                                )
                            )
                    )
                }

                let monetaryMetrics: [WatchMetricSnapshot] = result.monetaryMetrics.map { metric in
                    let metricID = metric.metricIdentifier(providerID: result.providerID)
                    return WatchMetricSnapshot(
                        id: metricID,
                        label: metric.label,
                        exactValue: metric.formattedAmount(),
                        severity: result.hasReachedSpendLimit ? .critical : .normal,
                        fetchedAt: result.fetchedAt,
                        visualizationStyle: .largeNumeric
                    )
                }

                var availableMetrics = barMetrics + monetaryMetrics
                if let poolStatus = creditsPoolStatusMetric(for: result) {
                    availableMetrics.append(poolStatus)
                }
                let creditsMetricID = "\(result.providerID.rawValue).credits-remaining"
                if let creditsRemaining = result.freshCreditsRemaining {
                    availableMetrics.append(
                        WatchMetricSnapshot(
                            id: creditsMetricID,
                            label: "Credits remaining",
                            exactValue: creditsRemaining.formatted(
                                .number.precision(.fractionLength(0...2))
                            ),
                            fetchedAt: result.fetchedAt,
                            visualizationStyle: .largeNumeric
                        )
                    )
                }
                let savedOrder = configurationStore.metricLayouts[result.accountID]?.orderedMetricIDs ?? []
                let metrics = orderedVisibleMetrics(
                    accountID: result.accountID,
                    availableMetrics: availableMetrics,
                    providerAvailableMetricIDs: result.availableMetrics.map(\.id),
                    savedOrder: savedOrder,
                    configurationStore: configurationStore
                )
                let displayedBarMetricIDs = Set(barMetrics.map(\.id))
                let displayedDataFetchedAt = metrics.contains {
                    displayedBarMetricIDs.contains($0.id)
                }
                    ? (result.barsFetchedAt ?? result.fetchedAt)
                    : result.fetchedAt
                let plan = result.providerID.supportsPlanBadge ? result.plan : nil

                return WatchAccountSnapshot(
                    id: snapshotAccountID(
                        providerID: result.providerID,
                        configurationID: configuration.id
                    ),
                    legacyAccountIDs: configurationStore.linkedGoogleAccountIDs(for: result.accountID).map {
                        snapshotAccountID(providerID: .antigravity, configurationID: $0)
                    },
                    providerName: result.providerID == .openCodeZen
                        ? result.title
                        : configuration.providerID.displayName,
                    accountLabel: watchAccountLabel(
                        configuration: configuration,
                        result: result
                    ),
                    planIdentifier: plan?.identifier,
                    planDisplayLabel: plan?.displayLabel,
                    planAccessibilityLabel: plan?.accessibilityLabel,
                    statusText: statusText(
                        for: result,
                        configurationStore: configurationStore
                    ),
                    fetchedAt: displayedDataFetchedAt,
                    metrics: metrics
                )
            },
            isProLocked: access.isProLocked,
            proAccessEndsAt: access.proAccessEndsAt,
            proAccessEffectiveAt: access.proAccessEffectiveAt
        )
    }

    static func snapshotAccountID(
        providerID: ProviderID,
        configurationID: String
    ) -> String {
        let digest = SHA256.hash(data: Data(configurationID.utf8))
        let opaqueID = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return "\(providerID.rawValue).\(opaqueID)"
    }

    @discardableResult
    static func publish(
        results: [ProviderUsageResult],
        configurationStore: ProviderConfigurationStore,
        access: SnapshotProAccess = .locked,
        sender: (any WatchSnapshotSending)? = nil,
        now: Date = Date(),
        force: Bool = false
    ) -> Bool {
        let resolvedSender = sender ?? PhoneWatchConnectivityCoordinator.shared
        return resolvedSender.publish(
            makeSnapshot(
                results: results,
                configurationStore: configurationStore,
                access: access,
                retainedSnapshot: resolvedSender.retainedSnapshot,
                now: now
            ),
            force: force
        )
    }

    private static func orderedDisplayableResults(
        results: [ProviderUsageResult],
        configurationStore: ProviderConfigurationStore,
        now: Date
    ) -> [ProviderUsageResult] {
        let resultsByAccountID = Dictionary(
            uniqueKeysWithValues: results.map { ($0.accountID, $0) }
        )
        let displayable: [ProviderUsageResult] = configurationStore.configurations.compactMap { configuration in
            guard configurationStore.shouldDisplayOnDashboard(configuration),
                  !configurationStore.accountAccess.isPaused(accountID: configuration.id) else {
                return nil
            }
            return resultsByAccountID[configuration.id]
        }
        return DashboardUsageSorter.orderedResults(
            displayable,
            mode: configurationStore.dashboardOrderingMode,
            manualOrder: configurationStore.dashboardCardOrder,
            now: now,
            severityThresholds: configurationStore.usageAlertSettings.severityThresholds
        )
    }

    private static func creditsPoolStatusMetric(for result: ProviderUsageResult) -> WatchMetricSnapshot? {
        guard result.providerID == .codex,
              let status = result.unavailableUsageMetrics[CodexUsageParser.creditsPoolMetricID] else { return nil }
        return WatchMetricSnapshot(
            id: CodexUsageParser.creditsPoolMetricID, label: "Credits pool", exactValue: status,
            fetchedAt: result.fetchedAt, visualizationStyle: .statusText
        )
    }

    private static func orderedVisibleMetrics(
        accountID: String,
        availableMetrics: [WatchMetricSnapshot],
        providerAvailableMetricIDs: [String],
        savedOrder: [String],
        configurationStore: ProviderConfigurationStore
    ) -> [WatchMetricSnapshot] {
        let snapshotsByID = Dictionary(
            availableMetrics.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var seenMetricIDs = Set<String>()
        var orderedMetricIDs: [String] = []

        func appendAvailableMetricIDs<S: Sequence>(_ metricIDs: S) where S.Element == String {
            for metricID in metricIDs
            where snapshotsByID[metricID] != nil && seenMetricIDs.insert(metricID).inserted {
                orderedMetricIDs.append(metricID)
            }
        }

        appendAvailableMetricIDs(savedOrder)
        appendAvailableMetricIDs(providerAvailableMetricIDs)
        appendAvailableMetricIDs(availableMetrics.map(\.id))

        return orderedMetricIDs.compactMap { metricID in
            guard configurationStore.isMetricVisibleOnWatch(
                accountID: accountID,
                metricID: metricID
            ) else {
                return nil
            }
            return snapshotsByID[metricID]
        }
    }

    private static func watchAccountLabel(
        configuration: ProviderAccountConfiguration,
        result: ProviderUsageResult
    ) -> String {
        if result.providerID == .openCodeZen {
            let subtitle = result.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
            return subtitle.isEmpty ? result.title : subtitle
        }
        let configuredLabel = configuration.accountLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configuredLabel.isEmpty {
            return configuredLabel
        }
        let subtitle = result.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return subtitle.isEmpty ? configuration.providerID.displayName : subtitle
    }

    private static func statusText(
        for result: ProviderUsageResult,
        configurationStore: ProviderConfigurationStore
    ) -> String {
        guard let configuration = configurationStore.configuration(accountID: result.accountID) else {
            return result.subtitle
        }
        if configurationStore.isConfigured(configuration),
           !result.subtitle.localizedCaseInsensitiveContains("not configured") {
            return result.subtitle
        }
        return configurationStore.statusText(for: configuration)
    }
}

@MainActor
final class WatchSnapshotCoordinator {
    typealias SnapshotPublisher = @MainActor (
        [ProviderUsageResult],
        ProviderConfigurationStore,
        Bool
    ) -> Void

    private let refreshService: UsageRefreshService
    private let configurationStore: ProviderConfigurationStore
    private let sender: any WatchSnapshotSending
    private let publishSnapshot: SnapshotPublisher
    typealias AccessPublisher = @MainActor (
        [ProviderUsageResult], ProviderConfigurationStore, SnapshotProAccess, Bool
    ) -> Void

    private let entitlement: ProEntitlement?
    private let accessPublisher: AccessPublisher?
    private let coalescingDelay: Duration
    private var cancellables: Set<AnyCancellable> = []
    private var snapshotPublishTask: Task<Void, Never>?
    private var hasStarted = false

    init(
        refreshService: UsageRefreshService,
        configurationStore: ProviderConfigurationStore,
        entitlement: ProEntitlement? = nil,
        sender: (any WatchSnapshotSending)? = nil,
        coalescingDelay: Duration = .milliseconds(250),
        publishSnapshot: SnapshotPublisher? = nil,
        accessPublisher: AccessPublisher? = nil
    ) {
        let resolvedSender = sender ?? PhoneWatchConnectivityCoordinator.shared
        self.refreshService = refreshService
        self.configurationStore = configurationStore
        self.sender = resolvedSender
        self.entitlement = entitlement
        self.accessPublisher = accessPublisher
        self.coalescingDelay = coalescingDelay
        self.publishSnapshot = publishSnapshot ?? { results, store, force in
            WatchSnapshotPublisher.publish(
                results: results,
                configurationStore: store,
                access: SnapshotProAccess(entitlement: entitlement),
                sender: resolvedSender,
                force: force
            )
        }

        refreshService.$results.dropFirst().sink { [weak self] _ in
            self?.scheduleSnapshotPublish()
        }.store(in: &cancellables)
        configurationStore.$accountAccess.dropFirst().sink { [weak self] _ in
            self?.scheduleSnapshotPublish()
        }.store(in: &cancellables)
        configurationStore.$configurations.dropFirst().sink { [weak self] _ in
            self?.scheduleSnapshotPublish()
        }.store(in: &cancellables)
        configurationStore.$dashboardCardOrder.dropFirst().sink { [weak self] _ in
            self?.scheduleSnapshotPublish()
        }.store(in: &cancellables)
        configurationStore.$dashboardOrderingMode.dropFirst().sink { [weak self] _ in
            self?.scheduleSnapshotPublish()
        }.store(in: &cancellables)
        configurationStore.$metricLayouts.dropFirst().sink { [weak self] _ in
            self?.scheduleSnapshotPublish()
        }.store(in: &cancellables)
        configurationStore.$autoRefreshInterval.dropFirst().sink { [weak self] _ in
            self?.scheduleSnapshotPublish()
        }.store(in: &cancellables)
        configurationStore.$usageAlertSettings.dropFirst().sink { [weak self] _ in
            self?.scheduleSnapshotPublish()
        }.store(in: &cancellables)

        entitlement?.accessChanges.sink { [weak self] _ in
            self?.scheduleSnapshotPublish(delay: .zero)
        }.store(in: &cancellables)
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        if entitlement != nil { publishCurrentSnapshot(force: true) }
        sender.activate { [weak self] force in
            self?.publishCurrentSnapshot(force: force)
        }
    }

    func publishCurrentSnapshot(force: Bool = false) {
        if force { snapshotPublishTask?.cancel() }
        // Free access must remove previously sent Pro accounts even if the active provider is still loading.
        let hasResolvedFreeAccess = configurationStore.accountAccess.isResolved
            && !configurationStore.accountAccess.hasProAccess
        let awaitsInitialResults = entitlement == nil && !hasResolvedFreeAccess && refreshService.results.isEmpty
            && configurationStore.configurations.contains(
                where: configurationStore.shouldDisplayOnDashboard
            )
        guard !awaitsInitialResults else {
            return
        }
        if let accessPublisher {
            accessPublisher(refreshService.results, configurationStore, SnapshotProAccess(entitlement: entitlement), force)
        } else {
            publishSnapshot(refreshService.results, configurationStore, force)
        }
    }

    private func scheduleSnapshotPublish(delay: Duration? = nil) {
        snapshotPublishTask?.cancel()
        snapshotPublishTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if let delay, delay == .zero {
                    await Task.yield()
                } else {
                    try await Task.sleep(for: delay ?? coalescingDelay)
                }
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            publishCurrentSnapshot()
        }
    }

    deinit {
        snapshotPublishTask?.cancel()
    }
}

#if os(iOS)
@MainActor
final class PhoneWatchConnectivityCoordinator: NSObject, WatchSnapshotSending {
    static let shared = PhoneWatchConnectivityCoordinator()

    private let session: WCSession?
    private var snapshotNeededHandler: (@MainActor (_ force: Bool) -> Void)?
    private var deduplicator = WatchSnapshotDeduplicator()
    private var latestSnapshot: WatchDashboardSnapshot?
    private let publicationStore: PhoneWatchPublicationStore
    private let sendApplicationContext: (([String: Any]) throws -> Void)?

    var retainedSnapshot: WatchDashboardSnapshot? { publicationStore.snapshot }

    init(
        session: WCSession? = WCSession.isSupported() ? .default : nil,
        defaults: UserDefaults = .standard,
        sendApplicationContext: (([String: Any]) throws -> Void)? = nil,
        initialApplicationContext: [String: Any]? = nil
    ) {
        self.session = session
        publicationStore = PhoneWatchPublicationStore(
            defaults: defaults, initialApplicationContext: initialApplicationContext ?? session?.applicationContext
        )
        self.sendApplicationContext = sendApplicationContext
        super.init()
    }

    func activate(onSnapshotNeeded: @escaping @MainActor (_ force: Bool) -> Void) {
        snapshotNeededHandler = onSnapshotNeeded
        requestCurrentSnapshot(force: true)
        guard let session else {
            phoneWatchConnectivityLogger.error("WatchConnectivity is unavailable on this iPhone")
            return
        }
        session.delegate = self
        phoneWatchConnectivityLogger.info(
            "Activating session state=\(session.activationState.rawValue, privacy: .public) paired=\(session.isPaired, privacy: .public) watchAppInstalled=\(session.isWatchAppInstalled, privacy: .public)"
        )
        if session.activationState != .activated { session.activate() }
    }

    @discardableResult
    func handleMessage(
        _ message: [String: Any],
        replyHandler: (([String: Any]) -> Void)? = nil
    ) -> Bool {
        guard WatchDashboardSnapshot.isSnapshotRequest(message) else {
            return false
        }
        handleSnapshotRequest(message)
        if let replyHandler {
            replyHandler(snapshotReply())
        }
        return true
    }

    @discardableResult
    func handleUserInfo(_ userInfo: [String: Any]) -> Bool {
        guard WatchDashboardSnapshot.isSnapshotRequest(userInfo) else {
            return false
        }
        phoneWatchConnectivityLogger.info("Received queued snapshot request from Watch")
        handleSnapshotRequest(userInfo)
        return true
    }

    private func handleSnapshotRequest(_ message: [String: Any] = [:]) {
        if let sequence = message[WatchDashboardSnapshot.snapshotAfterSequenceKey] as? UInt64, sequence < UInt64.max - 1 {
            publicationStore.observeReceiverSequence(sequence)
        }
        phoneWatchConnectivityLogger.info("Handling snapshot request from Watch")
        requestCurrentSnapshot(force: true)
    }

    private func requestCurrentSnapshot(force: Bool) {
        // A callback that cannot publish must never reply with pre-denial data.
        if force { latestSnapshot = nil }
        snapshotNeededHandler?(force)
    }

    private func snapshotReply() -> [String: Any] {
        guard let latestSnapshot else {
            phoneWatchConnectivityLogger.notice("Snapshot request completed before iPhone data was available")
            return WatchDashboardSnapshot.snapshotUnavailableReply
        }
        do {
            return try latestSnapshot.applicationContext()
        } catch {
            phoneWatchConnectivityLogger.error("Could not encode snapshot reply")
            return WatchDashboardSnapshot.snapshotUnavailableReply
        }
    }

    func watchStateDidChange() {
        guard let session else { return }
        phoneWatchConnectivityLogger.info(
            "Watch state changed paired=\(session.isPaired, privacy: .public) watchAppInstalled=\(session.isWatchAppInstalled, privacy: .public) reachable=\(session.isReachable, privacy: .public)"
        )
        snapshotNeededHandler?(false)
    }

    @discardableResult
    func publish(_ snapshot: WatchDashboardSnapshot, force: Bool) -> Bool {
        do {
            let ordered = try publicationStore.record(snapshot)
            latestSnapshot = ordered
            guard try deduplicator.shouldSend(ordered, force: force) else { return false }
            let context = try ordered.applicationContext()
            if let sendApplicationContext {
                try sendApplicationContext(context)
            } else if let session {
                try session.updateApplicationContext(context)
            } else {
                return false
            }
            try deduplicator.recordSent(ordered)
            return true
        } catch {
            phoneWatchConnectivityLogger.error(
                "Snapshot context publish failed domain=\((error as NSError).domain, privacy: .public) code=\((error as NSError).code, privacy: .public)"
            )
            return false
        }
    }
}

extension PhoneWatchConnectivityCoordinator: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        let errorCode = (error as NSError?)?.code ?? 0
        phoneWatchConnectivityLogger.info(
            "Activation completed state=\(activationState.rawValue, privacy: .public) errorCode=\(errorCode, privacy: .public) paired=\(session.isPaired, privacy: .public) watchAppInstalled=\(session.isWatchAppInstalled, privacy: .public)"
        )
        guard activationState == .activated, error == nil else { return }
        Task { @MainActor [weak self] in
            self?.requestCurrentSnapshot(force: true)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any]
    ) {
        guard WatchDashboardSnapshot.isSnapshotRequest(message) else { return }
        let sequence = message[WatchDashboardSnapshot.snapshotAfterSequenceKey] as? UInt64
        Task { @MainActor [weak self] in
            self?.handleSnapshotRequest(WatchDashboardSnapshot.snapshotRequestMessage(after: sequence))
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        guard WatchDashboardSnapshot.isSnapshotRequest(message) else {
            replyHandler(WatchDashboardSnapshot.snapshotUnavailableReply)
            return
        }
        let reply = PhoneWatchReplyHandler(replyHandler)
        let sequence = message[WatchDashboardSnapshot.snapshotAfterSequenceKey] as? UInt64
        Task { @MainActor [weak self] in
            guard let self else {
                reply.send(WatchDashboardSnapshot.snapshotUnavailableReply)
                return
            }
            self.handleSnapshotRequest(WatchDashboardSnapshot.snapshotRequestMessage(after: sequence))
            reply.send(self.snapshotReply())
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveUserInfo userInfo: [String: Any] = [:]
    ) {
        guard WatchDashboardSnapshot.isSnapshotRequest(userInfo) else { return }
        phoneWatchConnectivityLogger.info("Received queued snapshot request from Watch")
        let sequence = userInfo[WatchDashboardSnapshot.snapshotAfterSequenceKey] as? UInt64
        Task { @MainActor [weak self] in
            self?.handleSnapshotRequest(WatchDashboardSnapshot.snapshotRequestMessage(after: sequence))
        }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in
            self?.watchStateDidChange()
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
}
#else
@MainActor
final class PhoneWatchConnectivityCoordinator: WatchSnapshotSending {
    static let shared = PhoneWatchConnectivityCoordinator()

    func activate(onSnapshotNeeded: @escaping @MainActor (_ force: Bool) -> Void) {}

    func publish(_ snapshot: WatchDashboardSnapshot, force: Bool) -> Bool {
        false
    }
}
#endif
