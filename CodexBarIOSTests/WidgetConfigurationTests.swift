import WidgetKit
import XCTest
@testable import CodexBarIOS

final class WidgetConfigurationTests: XCTestCase {
    func testProDeepLinkHasSeparateUserInitiatedDestination() throws {
        let url = try XCTUnwrap(CodexBarDeepLink.proURL)
        XCTAssertEqual(url.absoluteString, "codexbar://pro")
        XCTAssertTrue(CodexBarDeepLink.isProURL(url))
        XCTAssertNil(CodexBarDeepLink.providerAccountID(from: url))
        XCTAssertFalse(CodexBarDeepLink.isProURL(URL(string: "https://pro")!))
        XCTAssertFalse(CodexBarDeepLink.isProURL(URL(string: "codexbar://pro/details")!))
        XCTAssertFalse(CodexBarDeepLink.isProURL(URL(string: "codexbar://pro?account=saved")!))
    }

    func testEveryWidgetFocusMapsToItsProvider() {
        let mappings: [(CodexBarWidgetFocus, String?)] = [
            (.dashboardOrder, nil),
            (.codex, "codex"),
            (.copilot, "copilot"),
            (.claude, "claude"),
            (.grok, "grok"),
            (.xSubscription, "xSubscription"),
            (.cursor, "cursor"),
            (.moonshot, "moonshot"),
            (.openCodeZen, "openCodeZen"),
            (.openRouter, "openRouter"),
            (.greptile, "greptile"),
            (.gemini, "gemini"),
            (.antigravity, "antigravity"),
        ]

        for (focus, providerID) in mappings {
            XCTAssertEqual(focus.providerID, providerID)
        }
        XCTAssertEqual(
            Set(CodexBarWidgetFocus.allCases),
            Set(CodexBarWidgetFocus.caseDisplayRepresentations.keys).subtracting([.antigravity])
        )
        XCTAssertEqual(Set(CodexBarWidgetFocus.allCases), Set(mappings.map(\.0)).subtracting([.antigravity]))
    }

    @MainActor
    func testGreptileWidgetSnapshotPublishesCountWithoutGaugeSemantics() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted,
            defaults: defaults,
            secretStore: MemorySecretStore()
        )
        let configuration = try XCTUnwrap(store.addAccount(for: .greptile))
        XCTAssertTrue(store.saveSecret("greptile-widget-key", for: configuration))
        let result = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .greptile,
            title: "Greptile",
            subtitle: "All available review history",
            bars: [
                UsageBar(
                    stableKey: GreptileUsageIdentity.completedReviewsStableKey,
                    label: "Completed reviews",
                    used: 27,
                    limit: 0,
                    fractionlessUsageText: "27"
                ),
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_788_475_200)
        )

        WidgetSnapshotPublisher.publish(
            results: [result],
            configurationStore: store, access: SnapshotProAccess(isProLocked: false, proAccessEndsAt: nil),
            snapshotDefaults: defaults, accessGuard: WidgetAccessGuard(directory: nil)
        )

        let bar = try XCTUnwrap(
            WidgetSnapshotStore.loadSnapshot(defaults: defaults).results.first?.bars.first
        )
        XCTAssertEqual(bar.metricID, GreptileUsageIdentity.completedReviewsMetricID)
        XCTAssertEqual(bar.usageText, "27")
        XCTAssertEqual(bar.fractionUsed, 0)
        XCTAssertEqual(bar.allowsGauge, false)
        XCTAssertFalse(bar.allowsAutomaticVisualization)
        XCTAssertEqual(bar.severity, .normal)
        let usageBar = try XCTUnwrap(result.bars.first)
        XCTAssertEqual(usageBar.supportedVisualizationStyles, [.automatic, .largeNumeric])
        XCTAssertEqual(usageBar.resolvedVisualizationStyle(.circularRing), .largeNumeric)

        let providerSnapshot = try XCTUnwrap(
            WidgetSnapshotStore.loadSnapshot(defaults: defaults).results.first
        )
        let tile = providerSnapshot.barTile(bar)
        XCTAssertFalse(tile.allowsUsageGauge)
        XCTAssertFalse(
            CodexBarWidgetRenderedTile(tile: tile, displayMode: .compactPercent).allowsUsageGauge
        )
        XCTAssertFalse(
            CodexBarWidgetRenderedTile(tile: tile, displayMode: .fullBar).allowsUsageGauge
        )

        store.updateVisualizationStyle(
            .circularRing,
            accountID: configuration.id,
            metricID: GreptileUsageIdentity.completedReviewsMetricID
        )
        let watchMetric = try XCTUnwrap(
            WatchSnapshotPublisher.makeSnapshot(
                results: [result],
                configurationStore: store, access: SnapshotProAccess(isProLocked: false, proAccessEndsAt: nil)
            ).accounts.first?.metrics.first
        )
        XCTAssertNil(watchMetric.usedFraction)
        XCTAssertEqual(watchMetric.exactValue, "27")
        XCTAssertEqual(watchMetric.visualizationStyle, .largeNumeric)
    }

    @MainActor
    func testWatchSnapshotPreservesRawOverageAndCapsRemainingFraction() throws {
        let defaults = UserDefaults(suiteName: #function)!
        defer { defaults.removePersistentDomain(forName: #function) }
        let store = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted,
            defaults: defaults,
            secretStore: MemorySecretStore()
        )
        let configuration = try XCTUnwrap(store.addAccount(for: .cursor))
        XCTAssertTrue(store.saveSecret("cursor-watch-key", for: configuration))
        let result = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .cursor,
            title: "Cursor",
            subtitle: "Cursor plan usage",
            bars: [UsageBar(label: "Cursor Models", used: 137.4, limit: 100)],
            fetchedAt: Date(timeIntervalSince1970: 2_000_000_000)
        )

        let metric = try XCTUnwrap(
            WatchSnapshotPublisher.makeSnapshot(
                results: [result],
                configurationStore: store, access: SnapshotProAccess(isProLocked: false, proAccessEndsAt: nil)
            ).accounts.first?.metrics.first
        )

        XCTAssertEqual(try XCTUnwrap(metric.usedFraction), 1.374, accuracy: 0.000_001)
        XCTAssertEqual(metric.remainingFraction, 0)
        XCTAssertEqual(metric.exactValue, "137%")
    }

    @MainActor
    func testSavedGreptileWidgetTileSurvivesQuotaModeChanges() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted,
            defaults: defaults,
            secretStore: MemorySecretStore()
        )
        let configuration = try XCTUnwrap(store.addAccount(for: .greptile))
        XCTAssertTrue(store.saveSecret("greptile-widget-key", for: configuration))
        let completedResult = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .greptile,
            title: "Greptile",
            subtitle: "All available review history",
            bars: [
                UsageBar(
                    stableKey: GreptileUsageIdentity.completedReviewsStableKey,
                    label: "Completed reviews",
                    used: 27,
                    limit: 0,
                    fractionlessUsageText: "27"
                ),
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_788_475_200)
        )
        WidgetSnapshotPublisher.publish(
            results: [completedResult],
            configurationStore: store, access: SnapshotProAccess(isProLocked: false, proAccessEndsAt: nil),
            snapshotDefaults: defaults, accessGuard: WidgetAccessGuard(directory: nil)
        )
        let completedSnapshot = WidgetSnapshotStore.loadSnapshot(defaults: defaults)
        let savedCompletedTileID = try XCTUnwrap(
            completedSnapshot.builderTiles.first { $0.id.hasPrefix("bar.") }?.id
        )
        let quotaResult = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .greptile,
            title: "Greptile",
            subtitle: "Current billing period",
            bars: [
                UsageBar(
                    stableKey: GreptileUsageIdentity.reviewQuotaStableKey,
                    label: "Reviews used",
                    used: 12,
                    limit: 50
                ),
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_788_561_600)
        )
        WidgetSnapshotPublisher.publish(
            results: [quotaResult],
            configurationStore: store, access: SnapshotProAccess(isProLocked: false, proAccessEndsAt: nil),
            snapshotDefaults: defaults, accessGuard: WidgetAccessGuard(directory: nil)
        )
        let quotaSnapshot = WidgetSnapshotStore.loadSnapshot(defaults: defaults)
        let quotaTile = try XCTUnwrap(quotaSnapshot.builderTiles.first { $0.id.hasPrefix("bar.") })
        XCTAssertEqual(
            quotaSnapshot.builderTile(resolvingSavedID: savedCompletedTileID)?.id,
            quotaTile.id
        )

        WidgetSnapshotPublisher.publish(
            results: [completedResult],
            configurationStore: store, access: SnapshotProAccess(isProLocked: false, proAccessEndsAt: nil),
            snapshotDefaults: defaults, accessGuard: WidgetAccessGuard(directory: nil)
        )
        let restoredCompletedSnapshot = WidgetSnapshotStore.loadSnapshot(defaults: defaults)
        XCTAssertEqual(
            restoredCompletedSnapshot.builderTile(resolvingSavedID: quotaTile.id)?.id,
            savedCompletedTileID
        )
    }

    @MainActor
    func testSavedCursorWidgetTilesSurviveSemanticIdentityUpgrade() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted,
            defaults: defaults,
            secretStore: MemorySecretStore()
        )
        let configuration = try XCTUnwrap(store.addAccount(for: .cursor))
        XCTAssertTrue(store.saveSecret("cursor-widget-key", for: configuration))
        let result = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .cursor,
            title: "Cursor",
            subtitle: "Cursor plan usage",
            bars: [
                UsageBar(
                    stableKey: CursorUsageIdentity.cursorModelsStableKey,
                    label: "Cursor Models",
                    used: 25,
                    limit: 100
                ),
                UsageBar(
                    stableKey: CursorUsageIdentity.otherModelsStableKey,
                    label: "Other Models",
                    used: 50,
                    limit: 100
                ),
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_788_475_200)
        )
        WidgetSnapshotPublisher.publish(
            results: [result],
            configurationStore: store, access: SnapshotProAccess(isProLocked: false, proAccessEndsAt: nil),
            snapshotDefaults: defaults, accessGuard: WidgetAccessGuard(directory: nil)
        )
        let snapshot = WidgetSnapshotStore.loadSnapshot(defaults: defaults)

        XCTAssertEqual(
            snapshot.builderTile(
                resolvingSavedID: "bar.\(configuration.id).cursor.auto"
            )?.id,
            "bar.\(configuration.id).cursor.cursor-models"
        )
        XCTAssertEqual(
            snapshot.builderTile(
                resolvingSavedID: "bar.\(configuration.id).cursor.api"
            )?.id,
            "bar.\(configuration.id).cursor.other-models"
        )
        XCTAssertEqual(
            snapshot.builderTile(
                resolvingSavedID: "bar.\(configuration.id).1.auto"
            )?.id,
            "bar.\(configuration.id).cursor.cursor-models"
        )
        XCTAssertEqual(
            snapshot.builderTile(
                resolvingSavedID: "bar.\(configuration.id).2.api"
            )?.id,
            "bar.\(configuration.id).cursor.other-models"
        )
    }

    @MainActor
    func testWidgetSnapshotPublisherKeepsMetricTileIDAcrossLabelChanges() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted,
            defaults: defaults,
            secretStore: MemorySecretStore()
        )
        let configuration = try XCTUnwrap(store.addAccount(for: .codex))
        XCTAssertTrue(store.saveSecret("codex-widget-key", for: configuration))

        func publish(label: String) throws -> CodexBarWidgetSnapshot {
            let result = ProviderUsageResult(
                accountID: configuration.id,
                providerID: .codex,
                title: "Codex",
                subtitle: "Live usage",
                bars: [
                    UsageBar(
                        stableKey: "bucket-spark.window-18000",
                        label: label,
                        used: 25,
                        limit: 100
                    ),
                ],
                fetchedAt: Date(timeIntervalSince1970: 1_788_475_200)
            )
            WidgetSnapshotPublisher.publish(
                results: [result],
                configurationStore: store, access: SnapshotProAccess(isProLocked: false, proAccessEndsAt: nil),
                snapshotDefaults: defaults, accessGuard: WidgetAccessGuard(directory: nil)
            )
            return WidgetSnapshotStore.loadSnapshot(defaults: defaults)
        }

        let original = try publish(label: "Original Codex limit")
        let originalBarID = try XCTUnwrap(original.results.first?.bars.first?.id)
        let savedTileID = "bar.\(originalBarID)"
        let legacyTileID = "bar.\(configuration.id).0.original-codex-limit"
        XCTAssertEqual(
            original.builderTile(resolvingSavedID: legacyTileID)?.title,
            "Original Codex limit"
        )

        let renamed = try publish(label: "Renamed Codex limit")
        let renamedBarID = try XCTUnwrap(renamed.results.first?.bars.first?.id)

        XCTAssertEqual(
            originalBarID,
            "\(configuration.id).codex.bucket-spark.window-18000"
        )
        XCTAssertEqual(renamedBarID, originalBarID)
        XCTAssertEqual(renamed.builderTile(resolvingSavedID: savedTileID)?.title, "Renamed Codex limit")
        XCTAssertEqual(
            renamed.builderTile(resolvingSavedID: legacyTileID)?.title,
            "Renamed Codex limit"
        )

        let reorderedUniqueLabels = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .codex,
            title: "Codex",
            subtitle: "Live usage",
            bars: [
                UsageBar(stableKey: "bucket-first.window-18000", label: "First", used: 10, limit: 100),
                UsageBar(stableKey: "bucket-inserted.window-18000", label: "Inserted", used: 15, limit: 100),
                UsageBar(stableKey: "bucket-target.window-18000", label: "Target", used: 20, limit: 100),
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_788_475_200)
        )
        WidgetSnapshotPublisher.publish(
            results: [reorderedUniqueLabels],
            configurationStore: store, access: SnapshotProAccess(isProLocked: false, proAccessEndsAt: nil),
            snapshotDefaults: defaults, accessGuard: WidgetAccessGuard(directory: nil)
        )
        let reorderedUniqueSnapshot = WidgetSnapshotStore.loadSnapshot(defaults: defaults)
        XCTAssertEqual(
            reorderedUniqueSnapshot.builderTile(
                resolvingSavedID: "bar.\(configuration.id).1.target"
            )?.id,
            "bar.\(configuration.id).codex.bucket-target.window-18000"
        )

        let duplicateLabels = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .codex,
            title: "Codex",
            subtitle: "Live usage",
            bars: [
                UsageBar(
                    stableKey: "bucket-first.window-18000",
                    label: "Shared label",
                    used: 10,
                    limit: 100
                ),
                UsageBar(
                    stableKey: "bucket-second.window-18000",
                    label: "Shared label",
                    used: 20,
                    limit: 100
                ),
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_788_475_200)
        )
        WidgetSnapshotPublisher.publish(
            results: [duplicateLabels],
            configurationStore: store, access: SnapshotProAccess(isProLocked: false, proAccessEndsAt: nil),
            snapshotDefaults: defaults, accessGuard: WidgetAccessGuard(directory: nil)
        )
        let duplicateLabelSnapshot = WidgetSnapshotStore.loadSnapshot(defaults: defaults)
        XCTAssertEqual(
            duplicateLabelSnapshot.builderTile(
                resolvingSavedID: "bar.\(configuration.id).1.shared-label"
            )?.id,
            "bar.\(configuration.id).codex.bucket-second.window-18000"
        )
    }

    func testEveryRefreshPolicySelectsItsOverrideOrFallback() {
        let fallback = WidgetRefreshInterval.threeHours

        XCTAssertEqual(CodexBarWidgetRefreshPolicy.appDefault.interval(fallback: fallback), fallback)
        XCTAssertEqual(
            CodexBarWidgetRefreshPolicy.fifteenMinutes.interval(fallback: fallback),
            .fifteenMinutes
        )
        XCTAssertEqual(
            CodexBarWidgetRefreshPolicy.thirtyMinutes.interval(fallback: fallback),
            .thirtyMinutes
        )
        XCTAssertEqual(CodexBarWidgetRefreshPolicy.oneHour.interval(fallback: fallback), .oneHour)
        XCTAssertEqual(
            CodexBarWidgetRefreshPolicy.threeHours.interval(fallback: .fifteenMinutes),
            .threeHours
        )
    }

    func testSnapshotScopesProvidersByGroupAndFocus() {
        let snapshot = Self.fixtureSnapshot
        let work = CodexBarWidgetGroupChoice(id: "work", title: "Work")
        let ungrouped = CodexBarWidgetGroupChoice(
            id: CodexBarWidgetGroupChoice.ungroupedID,
            title: "Ungrouped"
        )

        XCTAssertEqual(
            snapshot.scopedProviders(group: work).map(\.accountID),
            ["codex.work", "claude.work"]
        )
        XCTAssertEqual(
            snapshot.scopedProviders(group: work, focus: .claude).map(\.accountID),
            ["claude.work"]
        )
        XCTAssertEqual(
            snapshot.scopedProviders(group: ungrouped).map(\.accountID),
            ["openrouter.personal"]
        )
        XCTAssertTrue(snapshot.scopedProviders(group: work, focus: .moonshot).isEmpty)
    }

    func testGroupChoicesHandleUngroupedNamesAndIdentifierFallbacks() async throws {
        let snapshot = Self.fixtureSnapshot
        let accessFixture = try WidgetAccessFixture()
        let query = CodexBarWidgetGroupChoiceQuery(loadSnapshot: { snapshot }, accessContext: accessFixture.context)
        let choices = try await query.suggestedEntities()
        let titlesByID = Dictionary(uniqueKeysWithValues: choices.map { ($0.id, $0.title) })

        XCTAssertEqual(titlesByID["work"], "Work")
        XCTAssertEqual(titlesByID["named-ungrouped"], "Ungrouped (group)")
        XCTAssertEqual(titlesByID[CodexBarWidgetGroupChoice.ungroupedID], "Ungrouped")
        XCTAssertEqual(choices.last?.id, CodexBarWidgetGroupChoice.ungroupedID)

        let matches = try await query.entities(matching: "wOr")
        XCTAssertEqual(matches.map(\.id), ["work"])

        let resolved = try await query.entities(for: ["work", "missing-group"])
        XCTAssertEqual(resolved.map(\.title), ["Work", "Saved Group"])
        XCTAssertEqual(resolved.map(\.id), ["work", "missing-group"])
    }

    func testTileQueryFiltersAndMatchesCaseInsensitivelyWithInjectedSnapshot() async throws {
        let snapshot = Self.fixtureSnapshot
        let accessFixture = try WidgetAccessFixture()
        let query = CodexBarWidgetTileChoiceQuery(
            loadSnapshot: { snapshot }, accessContext: accessFixture.context,
            group: CodexBarWidgetGroupChoice(id: "work", title: "Work"),
            focus: .codex
        )

        let choices = try await query.suggestedEntities()
        XCTAssertFalse(choices.isEmpty)
        XCTAssertTrue(choices.allSatisfy { $0.id.contains("codex.work") })

        let matches = try await query.entities(matching: "5-HOUR")
        XCTAssertEqual(matches.map(\.id), ["bar.codex.work.five-hour"])

        let subtitleMatches = try await query.entities(matching: "81% USED")
        XCTAssertEqual(subtitleMatches.map(\.id), ["bar.codex.work.five-hour"])

        let resolved = try await query.entities(for: [
            "bar.codex.work.five-hour",
            "bar.codex.work.0.5-hour-usage",
            "missing-tile",
        ])
        XCTAssertEqual(resolved[0].title, "ChatGPT / Codex - 5-hour usage")
        XCTAssertEqual(resolved[1].id, "bar.codex.work.five-hour")
        XCTAssertEqual(resolved[1].title, "ChatGPT / Codex - 5-hour usage")
        XCTAssertEqual(resolved[2].id, "missing-tile")
        XCTAssertEqual(resolved[2].title, "Saved Tile")
    }

    func testProviderTilesSelectRepresentativeBarAndBuildEveryTileKind() throws {
        let codex = try XCTUnwrap(
            Self.fixtureSnapshot.results.first { $0.accountID == "codex.work" }
        )
        let summary = codex.summaryTile

        XCTAssertEqual(summary.id, "provider.codex.work")
        XCTAssertEqual(summary.bar?.id, "codex.work.weekly")
        XCTAssertEqual(summary.severity, .warning)

        let barTile = codex.barTile(try XCTUnwrap(codex.bars.first))
        XCTAssertEqual(barTile.id, "bar.codex.work.five-hour")
        XCTAssertEqual(barTile.accountID, "codex.work")
        XCTAssertEqual(barTile.bar?.usageText, "81%")

        let monetaryMetric = try XCTUnwrap(codex.monetaryMetrics?.first)
        let monetaryTile = codex.monetaryTile(monetaryMetric)
        XCTAssertEqual(monetaryTile.id, "money.codex.work.\(monetaryMetric.id)")
        XCTAssertEqual(monetaryTile.monetaryMetric, monetaryMetric)

        let monetaryOnly = try XCTUnwrap(
            Self.fixtureSnapshot.results.first { $0.accountID == "moonshot.team" }
        )
        XCTAssertEqual(monetaryOnly.summaryTile.title, "Balance")
        XCTAssertEqual(monetaryOnly.summaryTile.monetaryMetric, monetaryOnly.monetaryMetrics?.first)
    }

    func testUsageTileHeadlineAlwaysUsesCurrentUsageAcrossProjectionStates() {
        let criticalProjection = CodexBarWidgetUsageBarSnapshot(
            id: "critical-projection",
            label: "Weekly usage",
            fractionUsed: 0.27,
            usageText: "27%",
            resetDescription: "Resets Friday",
            severity: .normal,
            projectedFraction: 1,
            projectionDescription: "Projected 100% at current pace",
            projectedSeverity: .critical
        )
        let underLimitProjection = CodexBarWidgetUsageBarSnapshot(
            id: "under-limit-projection",
            label: "Weekly usage",
            fractionUsed: 0.27,
            usageText: "27%",
            resetDescription: "Resets Friday",
            severity: .normal,
            projectedFraction: 0.6,
            projectionDescription: "Projected to stay under limit",
            projectedSeverity: .normal
        )
        let noProjection = CodexBarWidgetUsageBarSnapshot(
            id: "no-projection",
            label: "Weekly usage",
            fractionUsed: 0.27,
            usageText: "27%",
            resetDescription: "Resets Friday",
            severity: .normal
        )
        let staleProjection = CodexBarWidgetUsageBarSnapshot(
            id: "stale-projection",
            label: "Weekly usage",
            fractionUsed: 0.27,
            usageText: "27%",
            resetDescription: "Resets Friday",
            severity: .normal,
            projectedFraction: nil,
            projectionDescription: nil,
            projectedSeverity: nil
        )
        let tile = CodexBarWidgetTile(
            id: "bar.codex.weekly",
            accountID: "codex",
            providerID: "codex",
            providerTitle: "ChatGPT / Codex",
            title: "Weekly usage",
            subtitle: "Pro",
            bar: criticalProjection,
            creditsRemaining: nil,
            monetaryMetric: nil,
            barFetchedAt: Date(timeIntervalSince1970: 1_000_000),
            monetaryValueFetchedAt: nil,
            fetchedAt: Date(timeIntervalSince1970: 1_000_000),
            severity: .critical
        )

        for bar in [criticalProjection, underLimitProjection, noProjection, staleProjection] {
            XCTAssertEqual(tile.metricText(for: bar), "27%")
        }
        XCTAssertEqual(tile.summaryText, "27%")
        XCTAssertEqual(
            tile.urgentStatusDetail(for: criticalProjection),
            "27% used - Projected 100% at current pace"
        )
        XCTAssertEqual(
            tile.urgentStatusDetail(for: noProjection),
            "27% - Resets Friday"
        )
    }

    func testUnavailableTilesDisplayModesAndAccountDeepLinks() throws {
        let unavailable = CodexBarWidgetTile.unavailable(
            choice: CodexBarWidgetTileChoice(
                id: "saved.removed",
                title: "Removed tile",
                subtitle: "Previously saved"
            )
        )
        XCTAssertEqual(unavailable.id, "unavailable.saved.removed")
        XCTAssertEqual(unavailable.providerID, "unavailable")
        XCTAssertEqual(unavailable.severity, .warning)

        XCTAssertEqual(
            CodexBarWidgetTileDisplayMode.mode(at: 1, in: [.fullBar, .balanceOnly]),
            .balanceOnly
        )
        XCTAssertEqual(
            CodexBarWidgetTileDisplayMode.mode(at: 4, in: [.fullBar]),
            .automatic
        )
        XCTAssertEqual(
            CodexBarWidgetTileDisplayMode(builderDisplayMode: .urgentStatus),
            .urgentStatus
        )

        let codex = try XCTUnwrap(
            Self.fixtureSnapshot.results.first { $0.accountID == "codex.work" }
        )
        let deepLink = try XCTUnwrap(codex.summaryTile.deepLinkURL)
        XCTAssertEqual(CodexBarDeepLink.providerAccountID(from: deepLink), "codex.work")
        XCTAssertNil(unavailable.deepLinkURL)
    }

    func testWidgetTilesUseComponentFreshnessAndOldestVisibleDate() throws {
        let publicationDate = Date(timeIntervalSince1970: 1_000_000)
        let barsDate = publicationDate.addingTimeInterval(-180)
        let creditsDate = publicationDate.addingTimeInterval(-60)
        let monetaryDate = publicationDate.addingTimeInterval(-30)
        let bar = CodexBarWidgetUsageBarSnapshot(
            id: "codex.work.weekly",
            label: "Weekly",
            fractionUsed: 0.5,
            usageText: "50%",
            resetDescription: nil,
            severity: .normal
        )
        let monetaryMetric = CodexBarWidgetMonetaryMetricSnapshot(
            kind: "spent",
            label: "Spend",
            minorUnits: 500,
            currencyCode: "USD",
            decimalPlaces: 2,
            detail: nil
        )
        let usageProvider = CodexBarWidgetProviderSnapshot(
            accountID: "codex.work",
            providerID: "codex",
            title: "Codex",
            subtitle: "Work",
            bars: [bar],
            creditsRemaining: nil,
            monetaryMetrics: [monetaryMetric],
            barsFetchedAt: barsDate,
            monetaryMetricsFetchedAt: monetaryDate,
            fetchedAt: publicationDate,
            severity: .normal
        )
        let balanceProvider = CodexBarWidgetProviderSnapshot(
            accountID: "openrouter.work",
            providerID: "openRouter",
            title: "OpenRouter",
            subtitle: "Work",
            bars: [],
            creditsRemaining: 10,
            creditsFetchedAt: creditsDate,
            fetchedAt: publicationDate,
            severity: .normal
        )
        let mixedProvider = CodexBarWidgetProviderSnapshot(
            accountID: "opencode.work",
            providerID: "openCodeZen",
            title: "OpenCode",
            subtitle: "Work",
            bars: [bar],
            creditsRemaining: 10,
            barsFetchedAt: barsDate,
            creditsFetchedAt: creditsDate,
            fetchedAt: publicationDate,
            severity: .normal
        )
        let renderedTiles = [
            CodexBarWidgetRenderedTile(
                tile: usageProvider.barTile(bar),
                displayMode: .automatic
            ),
            CodexBarWidgetRenderedTile(
                tile: usageProvider.monetaryTile(monetaryMetric),
                displayMode: .automatic
            ),
            CodexBarWidgetRenderedTile(
                tile: balanceProvider.summaryTile,
                displayMode: .automatic
            ),
        ]

        XCTAssertEqual(usageProvider.summaryTile.fetchedAt, barsDate)
        XCTAssertEqual(renderedTiles[0].tile.fetchedAt, barsDate)
        XCTAssertEqual(renderedTiles[1].tile.fetchedAt, monetaryDate)
        XCTAssertEqual(renderedTiles[2].tile.fetchedAt, creditsDate)
        XCTAssertEqual(renderedTiles.freshnessDate(fallback: publicationDate), barsDate)
        XCTAssertEqual(
            CodexBarWidgetRenderedTile(
                tile: mixedProvider.summaryTile,
                displayMode: .automatic
            ).fetchedAt,
            creditsDate
        )
        XCTAssertEqual(
            CodexBarWidgetRenderedTile(
                tile: mixedProvider.summaryTile,
                displayMode: .balanceOnly
            ).fetchedAt,
            creditsDate
        )
        for mode in [
            CodexBarWidgetTileDisplayMode.compactPercent,
            .fullBar,
            .urgentStatus,
        ] {
            XCTAssertEqual(
                CodexBarWidgetRenderedTile(
                    tile: mixedProvider.summaryTile,
                    displayMode: mode
                ).fetchedAt,
                barsDate
            )
        }
        XCTAssertEqual(
            [CodexBarWidgetRenderedTile]().freshnessDate(fallback: publicationDate),
            publicationDate
        )
    }

    func testLegacyWidgetSnapshotFallsBackToProviderFreshness() throws {
        let json = """
        {
          "generatedAt": 1000000,
          "results": [
            {
              "accountID": "codex.work",
              "providerID": "codex",
              "title": "Codex",
              "subtitle": "Work",
              "bars": [
                {
                  "id": "codex.work.weekly",
                  "label": "Weekly",
                  "fractionUsed": 0.5,
                  "usageText": "50%",
                  "resetDescription": null,
                  "severity": "normal"
                }
              ],
              "creditsRemaining": null,
              "fetchedAt": 999900,
              "severity": "normal"
            }
          ]
        }
        """
        let snapshot = try JSONDecoder().decode(
            CodexBarWidgetSnapshot.self,
            from: Data(json.utf8)
        )
        let provider = try XCTUnwrap(snapshot.results.first)
        let bar = try XCTUnwrap(provider.bars.first)

        XCTAssertNil(provider.barsFetchedAt)
        XCTAssertEqual(provider.barTile(bar).fetchedAt, provider.fetchedAt)
        XCTAssertEqual(provider.summaryTile.fetchedAt, provider.fetchedAt)
    }

    func testTimelineLoaderUsesInjectedClockSnapshotsAndRefreshInterval() {
        let now = Date(timeIntervalSince1970: 1_234_567)
        let liveSnapshot = Self.fixtureSnapshot
        let previewSnapshot = CodexBarWidgetSnapshot(
            generatedAt: now.addingTimeInterval(-1),
            results: []
        )
        let loader = CodexBarWidgetTimelineLoader(
            now: { now },
            loadSnapshot: { isPreview in
                isPreview ? previewSnapshot : liveSnapshot
            },
            loadRefreshInterval: { .threeHours }
        )
        let configuration = CodexBarWidgetConfigurationIntent()
        configuration.refreshPolicy = .thirtyMinutes

        let preview = loader.snapshot(configuration: configuration, isPreview: true)
        let live = loader.snapshot(configuration: configuration, isPreview: false)
        XCTAssertEqual(preview.date, now)
        XCTAssertEqual(preview.snapshot, previewSnapshot)
        XCTAssertTrue(preview.isPreview)
        XCTAssertEqual(live.snapshot, liveSnapshot)
        XCTAssertFalse(live.isPreview)

        let placeholder = loader.placeholder(configuration: configuration)
        XCTAssertEqual(placeholder.snapshot, .preview)
        XCTAssertTrue(placeholder.isPreview)

        let plan = loader.timelinePlan(configuration: configuration)
        let timeline = plan.timeline
        XCTAssertEqual(timeline.entries.count, 1)
        XCTAssertEqual(timeline.entries.first?.date, now)
        XCTAssertEqual(timeline.entries.first?.snapshot, liveSnapshot)
        XCTAssertEqual(plan.nextRefreshDate, now.addingTimeInterval(30 * 60))

        configuration.refreshPolicy = .appDefault
        let fallbackPlan = loader.timelinePlan(configuration: configuration)
        XCTAssertEqual(fallbackPlan.nextRefreshDate, now.addingTimeInterval(3 * 60 * 60))
    }

    func testWatchSnapshotOrderingPrefersPublicationSequenceOverPhoneClock() {
        let earlier = Date(timeIntervalSince1970: 2_000_000_000)
        let later = earlier.addingTimeInterval(60)
        let higher = watchSnapshot(generatedAt: earlier, sequence: 8)
        let lower = watchSnapshot(generatedAt: later, sequence: 7)
        XCTAssertTrue(higher.isNewer(than: lower), "A higher sequence wins even when the phone clock moved backward")
        XCTAssertFalse(lower.isNewer(than: higher))

        let sequenced = watchSnapshot(generatedAt: earlier, sequence: 1)
        let legacy = watchSnapshot(generatedAt: later, sequence: nil)
        XCTAssertTrue(sequenced.isNewer(than: legacy), "Any sequenced publication supersedes a legacy one")
        XCTAssertFalse(legacy.isNewer(than: sequenced))

        let legacyLater = watchSnapshot(generatedAt: later, sequence: nil)
        let legacyEarlierLocked = watchSnapshot(generatedAt: earlier, sequence: nil, isProLocked: true)
        XCTAssertTrue(legacyLater.isNewer(than: legacyEarlierLocked), "Unsequenced snapshots order by generation time first")
        XCTAssertFalse(legacyEarlierLocked.isNewer(than: legacyLater))

        let sameRevision = watchSnapshot(generatedAt: later, sequence: 8)
        XCTAssertFalse(higher.isNewer(than: sameRevision), "An older generation of the same revision never supersedes")
        XCTAssertFalse(higher.isNewer(than: higher))
    }

    func testWatchSnapshotOrderingAtEqualRevisionOnlyAcceptsStricterAccess() {
        let generatedAt = Date(timeIntervalSince1970: 2_000_000_000)
        let soon = generatedAt.addingTimeInterval(3_600)
        let later = generatedAt.addingTimeInterval(7_200)
        let unlocked = watchSnapshot(generatedAt: generatedAt, sequence: 4)
        let locked = watchSnapshot(generatedAt: generatedAt, sequence: 4, isProLocked: true)
        XCTAssertTrue(locked.isNewer(than: unlocked))
        XCTAssertFalse(unlocked.isNewer(than: locked))

        let unbounded = watchSnapshot(generatedAt: generatedAt, sequence: 4)
        let endsSoon = watchSnapshot(generatedAt: generatedAt, sequence: 4, endsAt: soon)
        let endsLater = watchSnapshot(generatedAt: generatedAt, sequence: 4, endsAt: later)
        XCTAssertTrue(endsSoon.isNewer(than: unbounded), "A new access deadline is stricter than none")
        XCTAssertFalse(unbounded.isNewer(than: endsSoon), "Dropping a deadline at the same revision is ignored")
        XCTAssertTrue(endsSoon.isNewer(than: endsLater))
        XCTAssertFalse(endsLater.isNewer(than: endsSoon))

        let earlyFloor = watchSnapshot(generatedAt: generatedAt, sequence: 4, endsAt: soon, effectiveAt: generatedAt)
        let lateFloor = watchSnapshot(generatedAt: generatedAt, sequence: 4, endsAt: soon, effectiveAt: generatedAt.addingTimeInterval(60))
        let infiniteFloor = watchSnapshot(
            generatedAt: generatedAt, sequence: 4, endsAt: soon, effectiveAt: Date(timeIntervalSinceReferenceDate: .infinity)
        )
        XCTAssertTrue(lateFloor.isNewer(than: earlyFloor), "A later effective time leaves less remaining access")
        XCTAssertFalse(earlyFloor.isNewer(than: lateFloor))
        XCTAssertTrue(earlyFloor.isNewer(than: endsSoon), "An effective time is stricter than an unknown one")
        XCTAssertFalse(endsSoon.isNewer(than: earlyFloor))
        XCTAssertFalse(infiniteFloor.isNewer(than: earlyFloor), "A non-finite effective time is never trusted")

        let floorWithoutDeadline = watchSnapshot(generatedAt: generatedAt, sequence: 4, effectiveAt: generatedAt)
        XCTAssertFalse(floorWithoutDeadline.isNewer(than: unbounded), "An effective time without a deadline grants nothing")
    }

    func testWatchSnapshotOrderingAtEqualAccessRequiresIdenticalContentAndLaterGeneration() {
        let generatedAt = Date(timeIntervalSince1970: 2_000_000_000)
        let regenerated = generatedAt.addingTimeInterval(30)
        let account = WatchAccountSnapshot(
            id: "codex.personal", providerName: "Codex", accountLabel: "Personal", fetchedAt: generatedAt,
            metrics: [WatchMetricSnapshot(id: "weekly", label: "Weekly", exactValue: "12%")]
        )
        let current = watchSnapshot(generatedAt: generatedAt, sequence: nil, accounts: [account])
        XCTAssertTrue(watchSnapshot(generatedAt: regenerated, sequence: nil, accounts: [account]).isNewer(than: current))

        let deadline = generatedAt.addingTimeInterval(3_600)
        let floored = watchSnapshot(generatedAt: generatedAt, sequence: 9, endsAt: deadline, effectiveAt: generatedAt, accounts: [account])
        let sameAccess = watchSnapshot(generatedAt: regenerated, sequence: 9, endsAt: deadline, effectiveAt: generatedAt, accounts: [account])
        XCTAssertTrue(sameAccess.isNewer(than: floored), "Equal access with identical content accepts the newer generation")
        XCTAssertFalse(floored.isNewer(than: sameAccess))
        XCTAssertFalse(
            watchSnapshot(generatedAt: regenerated, sequence: 9, endsAt: deadline, effectiveAt: generatedAt).isNewer(than: floored),
            "Changed accounts at the same revision are not accepted"
        )
        XCTAssertFalse(
            watchSnapshot(
                generatedAt: regenerated, sequence: 9, refreshIntervalSeconds: 600, endsAt: deadline,
                effectiveAt: generatedAt, accounts: [account]
            ).isNewer(than: floored),
            "A changed refresh interval at the same revision is not accepted"
        )
        XCTAssertFalse(
            watchSnapshot(
                schemaVersion: WatchDashboardSnapshot.currentSchemaVersion + 1, generatedAt: regenerated, sequence: 9,
                endsAt: deadline, effectiveAt: generatedAt, accounts: [account]
            ).isNewer(than: floored),
            "A different schema at the same revision is not accepted"
        )
    }

    private func watchSnapshot(
        schemaVersion: Int = WatchDashboardSnapshot.currentSchemaVersion,
        generatedAt: Date,
        sequence: UInt64?,
        refreshIntervalSeconds: TimeInterval? = 900,
        isProLocked: Bool = false,
        endsAt: Date? = nil,
        effectiveAt: Date? = nil,
        accounts: [WatchAccountSnapshot] = []
    ) -> WatchDashboardSnapshot {
        WatchDashboardSnapshot(
            schemaVersion: schemaVersion,
            generatedAt: generatedAt,
            refreshIntervalSeconds: refreshIntervalSeconds,
            accounts: accounts,
            isProLocked: isProLocked,
            proAccessEndsAt: endsAt,
            proAccessEffectiveAt: effectiveAt,
            publicationSequence: sequence
        )
    }

    private static let fixtureSnapshot = CodexBarWidgetSnapshot(
        generatedAt: Date(timeIntervalSince1970: 1_000_000),
        results: [
            CodexBarWidgetProviderSnapshot(
                accountID: "codex.work",
                providerID: "codex",
                title: "ChatGPT / Codex",
                subtitle: "Work account",
                groupID: "work",
                groupName: "Work",
                bars: [
                    CodexBarWidgetUsageBarSnapshot(
                        id: "codex.work.five-hour",
                        label: "5-hour usage",
                        fractionUsed: 0.81,
                        usageText: "81%",
                        resetDescription: "Soon",
                        severity: .warning
                    ),
                    CodexBarWidgetUsageBarSnapshot(
                        id: "codex.work.weekly",
                        label: "Weekly usage",
                        fractionUsed: 0.55,
                        usageText: "55%",
                        resetDescription: "Friday",
                        severity: .normal,
                        projectedFraction: 0.96,
                        projectedSeverity: .critical
                    ),
                ],
                creditsRemaining: nil,
                monetaryMetrics: [
                    CodexBarWidgetMonetaryMetricSnapshot(
                        kind: "spend",
                        label: "Spend",
                        minorUnits: 1234,
                        currencyCode: "USD",
                        decimalPlaces: 2,
                        detail: "This month"
                    ),
                ],
                fetchedAt: Date(timeIntervalSince1970: 999_900),
                severity: .warning
            ),
            CodexBarWidgetProviderSnapshot(
                accountID: "claude.work",
                providerID: "claude",
                title: "Claude",
                subtitle: "Work account",
                groupID: "work",
                groupName: "Work",
                bars: [],
                creditsRemaining: 10,
                fetchedAt: Date(timeIntervalSince1970: 999_900),
                severity: .normal
            ),
            CodexBarWidgetProviderSnapshot(
                accountID: "moonshot.team",
                providerID: "moonshot",
                title: "Moonshot",
                subtitle: "Team",
                groupID: "named-ungrouped",
                groupName: "ungrouped",
                bars: [],
                creditsRemaining: nil,
                monetaryMetrics: [
                    CodexBarWidgetMonetaryMetricSnapshot(
                        kind: "balance",
                        label: "Balance",
                        minorUnits: 2500,
                        currencyCode: "USD",
                        decimalPlaces: 2,
                        detail: "Available"
                    ),
                    CodexBarWidgetMonetaryMetricSnapshot(
                        kind: "spend",
                        label: "Spend",
                        minorUnits: 500,
                        currencyCode: "USD",
                        decimalPlaces: 2,
                        detail: "This month"
                    ),
                ],
                fetchedAt: Date(timeIntervalSince1970: 999_900),
                severity: .normal
            ),
            CodexBarWidgetProviderSnapshot(
                accountID: "openrouter.personal",
                providerID: "openRouter",
                title: "OpenRouter",
                subtitle: "Personal",
                bars: [],
                creditsRemaining: 12.34,
                fetchedAt: Date(timeIntervalSince1970: 999_900),
                severity: .normal
            ),
        ]
    )
}
