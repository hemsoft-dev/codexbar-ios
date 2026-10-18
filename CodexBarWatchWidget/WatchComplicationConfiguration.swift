import AppIntents
import Foundation
#if CODEXBAR_PHONE_WATCH_TESTS
@testable import CodexBarIOS
#endif
import WidgetKit
#if CODEXBAR_WATCH_TESTS
@testable import CodexBarWatch
#endif

struct WatchComplicationEntry: TimelineEntry {
    let date: Date
    private let projectedSample: WatchComplicationSample
    let configuration: WatchComplicationConfigurationIntent
    private let accessEpoch: UUID?
    private let loadAccess: (() -> WatchAccessDecision?)?

    init(
        date: Date, sample: WatchComplicationSample, configuration: WatchComplicationConfigurationIntent,
        accessEpoch: UUID? = nil, loadAccess: (() -> WatchAccessDecision?)? = nil
    ) {
        self.date = date
        projectedSample = sample
        self.configuration = configuration
        self.accessEpoch = accessEpoch
        self.loadAccess = loadAccess
    }

    var sample: WatchComplicationSample {
        // Future locked entries and explicit gallery previews never observe a synthetic future date.
        guard projectedSample.availability != .locked, let loadAccess else { return projectedSample }
        guard let decision = loadAccess(), decision.epoch == accessEpoch, !decision.isLocked else { return .locked }
        return projectedSample
    }
}

struct WatchComplicationTimelineLoader {
    private let resolver: WatchComplicationResolver
    private let now: () -> Date
    private let loadAccess: () -> WatchAccessDecision?
    private let checksRetainedAccess: Bool

    init(
        resolver: WatchComplicationResolver = WatchComplicationResolver(),
        now: @escaping () -> Date = { Date() },
        loadSnapshot: (() -> WatchDashboardSnapshot?)? = nil,
        loadAccess: (() -> WatchAccessDecision?)? = nil
    ) {
        self.resolver = resolver
        self.now = now
        if let loadAccess {
            self.loadAccess = loadAccess
            checksRetainedAccess = true
        } else if let loadSnapshot {
            // Explicit fixture loaders retain their pure resolver behavior.
            self.loadAccess = {
                loadSnapshot().map { WatchAccessDecision(source: $0, effectiveDate: now(), epoch: nil, hasExpired: false) }
            }
            checksRetainedAccess = false
        } else {
            self.loadAccess = { WatchComplicationSnapshotStore().loadAccess() }
            checksRetainedAccess = true
        }
    }

    func entry(
        configuration: WatchComplicationConfigurationIntent,
        date: Date? = nil
    ) -> WatchComplicationEntry {
        let wallNow = now()
        let entryDate = date ?? wallNow
        let decision = loadAccess()
        let effective = decision?.effectiveDate ?? wallNow
        return makeEntry(
            configuration: configuration, decision: decision, date: entryDate,
            effectiveDate: effective.addingTimeInterval(max(0, entryDate.timeIntervalSince(wallNow)))
        )
    }

    func timeline(configuration: WatchComplicationConfigurationIntent) -> Timeline<WatchComplicationEntry> {
        let wallNow = now()
        let decision = loadAccess()
        let snapshot = decision?.snapshot
        let effective = decision?.effectiveDate ?? wallNow
        let selection = configuration.selection(in: snapshot)
        let entries = resolver.timelineEntryDates(snapshot: snapshot, selection: selection, now: effective).map { effectiveEntry in
            makeEntry(
                configuration: configuration, decision: decision,
                date: wallNow.addingTimeInterval(effectiveEntry.timeIntervalSince(effective)), effectiveDate: effectiveEntry
            )
        }
        let effectiveReload = resolver.nextReloadDate(snapshot: snapshot, selection: selection, now: effective)
        let nextReload = wallNow.addingTimeInterval(effectiveReload.timeIntervalSince(effective))
        return Timeline(entries: entries, policy: .after(nextReload))
    }

    private func makeEntry(
        configuration: WatchComplicationConfigurationIntent, decision: WatchAccessDecision?, date: Date, effectiveDate: Date
    ) -> WatchComplicationEntry {
        let snapshot = decision?.snapshot
        return WatchComplicationEntry(
            date: date,
            sample: resolver.resolve(snapshot: snapshot, selection: configuration.selection(in: snapshot), at: effectiveDate),
            configuration: configuration, accessEpoch: decision?.epoch,
            loadAccess: checksRetainedAccess ? loadAccess : nil
        )
    }
}

struct WatchComplicationTimelineProvider: AppIntentTimelineProvider {
    private let loader = WatchComplicationTimelineLoader()

    func recommendations() -> [AppIntentRecommendation<WatchComplicationConfigurationIntent>] {
        []
    }

    func placeholder(in context: Context) -> WatchComplicationEntry {
        WatchComplicationEntry(
            date: Date(),
            sample: .preview,
            configuration: WatchComplicationConfigurationIntent()
        )
    }

    func snapshot(
        for configuration: WatchComplicationConfigurationIntent,
        in context: Context
    ) async -> WatchComplicationEntry {
        if context.isPreview {
            return WatchComplicationEntry(
                date: Date(),
                sample: .preview,
                configuration: configuration
            )
        }
        return loader.entry(configuration: configuration)
    }

    func timeline(
        for configuration: WatchComplicationConfigurationIntent,
        in context: Context
    ) async -> Timeline<WatchComplicationEntry> {
        loader.timeline(configuration: configuration)
    }
}

struct WatchComplicationConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "CodexBar Usage"
    static let description = IntentDescription(
        "Choose the provider account and usage metric shown by this complication."
    )

    @Parameter(title: "Provider Account")
    var account: WatchComplicationAccountEntity?

    @Parameter(title: "Metric")
    var metric: WatchComplicationMetricEntity?

    func selection(in snapshot: WatchDashboardSnapshot?) -> WatchComplicationSelection {
        WatchComplicationSelection.resolving(
            accountID: account?.id,
            metricAccountID: metric?.accountID,
            metricID: metric?.metricID,
            snapshot: snapshot
        )
    }
}

struct WatchComplicationAccountEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Provider Account")
    static let defaultQuery = WatchComplicationAccountQuery()

    let id: String
    let providerName: String
    let accountLabel: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(providerName)",
            subtitle: "\(accountLabel)"
        )
    }
}

struct WatchComplicationAccountQuery: EntityQuery {
    private let loadSnapshot: @Sendable () -> WatchDashboardSnapshot?
    private let now: @Sendable () -> Date

    init() {
        loadSnapshot = { WatchComplicationSnapshotStore().loadForAccess() }
        now = { Date() }
    }

    init(
        loadSnapshot: @escaping @Sendable () -> WatchDashboardSnapshot?,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.loadSnapshot = loadSnapshot
        self.now = now
    }

    func entities(for identifiers: [String]) async throws -> [WatchComplicationAccountEntity] {
        accountCatalog()
            .accounts(for: identifiers)
            .map(WatchComplicationAccountEntity.init)
    }

    func suggestedEntities() async throws -> [WatchComplicationAccountEntity] {
        accountEntities()
    }

    private func accountEntities() -> [WatchComplicationAccountEntity] {
        accountCatalog().accounts.map(WatchComplicationAccountEntity.init)
    }

    private func accountCatalog() -> WatchComplicationChoiceCatalog {
        WatchComplicationChoiceCatalog(snapshot: loadSnapshot(), now: now())
    }
}

private extension WatchComplicationAccountEntity {
    init(_ choice: WatchComplicationAccountChoice) {
        self.init(
            id: choice.id,
            providerName: choice.providerName,
            accountLabel: choice.accountLabel
        )
    }
}

struct WatchComplicationMetricEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Usage Metric")
    static let defaultQuery = WatchComplicationMetricQuery()

    let id: String
    let accountID: String
    let metricID: String
    let metricLabel: String
    let accountContext: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(metricLabel)",
            subtitle: "\(accountContext)"
        )
    }
}

struct WatchComplicationMetricQuery: EntityQuery {
    private let loadSnapshot: @Sendable () -> WatchDashboardSnapshot?
    private let now: @Sendable () -> Date

    init() {
        loadSnapshot = { WatchComplicationSnapshotStore().loadForAccess() }
        now = { Date() }
    }

    init(
        loadSnapshot: @escaping @Sendable () -> WatchDashboardSnapshot?,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.loadSnapshot = loadSnapshot
        self.now = now
    }

    func entities(for identifiers: [String]) async throws -> [WatchComplicationMetricEntity] {
        metricCatalog()
            .metrics(for: identifiers)
            .map(WatchComplicationMetricEntity.init)
    }

    func suggestedEntities() async throws -> [WatchComplicationMetricEntity] {
        metricEntities()
    }

    private func metricEntities() -> [WatchComplicationMetricEntity] {
        metricCatalog().metrics.map(WatchComplicationMetricEntity.init)
    }

    private func metricCatalog() -> WatchComplicationChoiceCatalog {
        WatchComplicationChoiceCatalog(snapshot: loadSnapshot(), now: now())
    }
}

private extension WatchComplicationMetricEntity {
    init(_ choice: WatchComplicationMetricChoice) {
        self.init(
            id: choice.id,
            accountID: choice.accountID,
            metricID: choice.metricID,
            metricLabel: choice.metricLabel,
            accountContext: choice.subtitle
        )
    }
}

private extension WatchComplicationSample {
    static let preview = WatchComplicationSample(
        availability: .value,
        providerName: "Codex",
        accountLabel: "Primary",
        metricLabel: "5-hour limit",
        exactValue: "72%",
        usedFraction: 0.72,
        severity: .warning,
        resetText: "Resets in 2h",
        freshnessText: "Updated now",
        isStale: false
    )
}
