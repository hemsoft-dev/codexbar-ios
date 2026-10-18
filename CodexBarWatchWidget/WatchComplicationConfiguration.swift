import AppIntents
import Foundation
import WidgetKit
#if CODEXBAR_WATCH_TESTS
@testable import CodexBarWatch
#endif

struct WatchComplicationEntry: TimelineEntry {
    let date: Date
    let sample: WatchComplicationSample
    let configuration: WatchComplicationConfigurationIntent
}

struct WatchComplicationTimelineLoader {
    private let resolver: WatchComplicationResolver
    private let now: () -> Date
    private let loadSnapshot: () -> WatchDashboardSnapshot?

    init(
        resolver: WatchComplicationResolver = WatchComplicationResolver(),
        now: @escaping () -> Date = { Date() },
        loadSnapshot: @escaping () -> WatchDashboardSnapshot? = {
            WatchComplicationSnapshotStore().load()
        }
    ) {
        self.resolver = resolver
        self.now = now
        self.loadSnapshot = loadSnapshot
    }

    func entry(
        configuration: WatchComplicationConfigurationIntent,
        date: Date? = nil
    ) -> WatchComplicationEntry {
        let entryDate = date ?? now()
        let snapshot = loadSnapshot()
        return WatchComplicationEntry(
            date: entryDate,
            sample: resolver.resolve(
                snapshot: snapshot,
                selection: configuration.selection(in: snapshot),
                at: entryDate
            ),
            configuration: configuration
        )
    }

    func timeline(
        configuration: WatchComplicationConfigurationIntent
    ) -> Timeline<WatchComplicationEntry> {
        let date = now()
        let snapshot = loadSnapshot()
        let selection = configuration.selection(in: snapshot)
        let entries = resolver.timelineEntryDates(
            snapshot: snapshot,
            selection: selection,
            now: date
        ).map { entryDate in
            WatchComplicationEntry(
                date: entryDate,
                sample: resolver.resolve(
                    snapshot: snapshot,
                    selection: selection,
                    at: entryDate
                ),
                configuration: configuration
            )
        }
        let nextReload = resolver.nextReloadDate(
            snapshot: snapshot,
            selection: selection,
            now: date
        )
        return Timeline(entries: entries, policy: .after(nextReload))
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

    init() {
        loadSnapshot = { WatchComplicationSnapshotStore().load() }
    }

    init(loadSnapshot: @escaping @Sendable () -> WatchDashboardSnapshot?) {
        self.loadSnapshot = loadSnapshot
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
        WatchComplicationChoiceCatalog(snapshot: loadSnapshot())
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

    init() {
        loadSnapshot = { WatchComplicationSnapshotStore().load() }
    }

    init(loadSnapshot: @escaping @Sendable () -> WatchDashboardSnapshot?) {
        self.loadSnapshot = loadSnapshot
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
        WatchComplicationChoiceCatalog(snapshot: loadSnapshot())
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
