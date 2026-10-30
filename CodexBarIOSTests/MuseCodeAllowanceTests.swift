import XCTest
@testable import CodexBarIOS

/// Schema-1 `muse usage --json` fixtures. `measured` is the producer's real reading without identity
/// (hs-pi-dashboard 588be88 internal/usage/testdata/muse); every other payload is synthetic. Wire shapes for
/// expired sign-in, entitlement denial, PAYG, rate limits and transport failures are unknown, so those states
/// are constructed directly rather than parsed (MUSE-CODE.md).
final class MuseCodeAllowanceTests: XCTestCase {
    private static let asOf = Date(timeIntervalSince1970: 1_793_037_245.064)
    private static let now = asOf.addingTimeInterval(30)
    private static let windowReset = Date(timeIntervalSince1970: 1_793_053_104)
    private static let weeklyReset = Date(timeIntervalSince1970: 1_793_577_600)
    private static let configuration = ProviderAccountConfiguration(
        id: "muse-fixture", providerID: .museCode, accountLabel: "Muse Code", authMethod: .browserSession
    )

    private static let measured = #"{"schemaVersion":1,"allowance":{"asOfMs":1793037245064,"source":"mint","tier":"Muse Code Power Usage","#
        + #""weekly":{"resetsAtMs":1793577600000,"usedPercent":5},"window":{"resetsAtMs":1793053104000,"#
        + #""usedPercent":15}}}"#
    private static let zero = #"{"schemaVersion":1,"allowance":{"asOfMs":1793037245064,"source":"mint","tier":"Muse Code Power Usage","#
        + #""weekly":{"resetsAtMs":1793577600000,"usedPercent":0},"window":{"resetsAtMs":1793053104000,"#
        + #""usedPercent":0}}}"#
    private static let exhausted = #"{"schemaVersion":1,"allowance":{"asOfMs":1793037245064,"source":"mint","tier":"Muse Code Power Usage","#
        + #""weekly":{"resetsAtMs":1793577600000,"usedPercent":100},"window":{"resetsAtMs":1793053104000,"#
        + #""usedPercent":130}}}"#
    private static let partial = #"{"schemaVersion":1,"allowance":{"asOfMs":1793037245064,"source":"mint","#
        + #""weekly":{"resetsAtMs":1793577600000,"usedPercent":5},"window":{"resetsAtMs":1793053104000}}}"#
    private static let malformedValues = #"{"schemaVersion":1,"allowance":{"asOfMs":1793037245064,"source":"mint","#
        + #""weekly":{"resetsAtMs":1793577600000,"usedPercent":"5%"},"window":{"resetsAtMs":"soon","#
        + #""usedPercent":15}}}"#
    private static let resetBeyondWindow = #"{"schemaVersion":1,"allowance":{"asOfMs":1793037245064,"source":"mint","#
        + #""window":{"resetsAtMs":1793053104000,"usedPercent":15},"weekly":{"resetsAtMs":1794182400000,"#
        + #""usedPercent":5}}}"#
    private static let unsupportedSchema = #"{"schemaVersion":2,"allowance":{"asOfMs":1793037245064,"weekly":{"resetsAtMs":1793577600000,"#
        + #""usedPercent":5}}}"#
    private static let truncated = #"{"schemaVersion":1,"allowance":"#
    private static let nullAllowance = #"{"schemaVersion":1,"allowance":null,"reason":"synthetic reason for fixture.user@example.com","#
        + #""hint":"synthetic hint: run muse login as Fixture User"}"#
    private static let payAsYouGo = #"{"schemaVersion":1,"allowance":null,"reason":"META_API_KEY sk-fixture-secret is pay-as-you-go","#
        + #""hint":"unset the key"}"#
    private static let extraWindow = #"{"schemaVersion":1,"allowance":{"asOfMs":1793037245064,"source":"mint","#
        + #""tier":"Muse Code Power Usage <script>","weekly":{"resetsAtMs":1793577600000,"usedPercent":5},"#
        + #""wonder-full-weekly":{"resetsAtMs":1793577600000,"usedPercent":40},"totalTokens":123456,"#
        + #""billing":{"mode":"subscription"}}}"#
    private static let tokensOnly = #"{"schemaVersion":1,"allowance":{"asOfMs":1793037245064,"totalTokens":987654,"#
        + #""models":{"muse-wonder-full-1.0":{"inputTokens":800000,"outputTokens":187654}}}}"#

    private func parse(_ payload: String, now: Date = now) -> MuseCodeAllowance.Outcome {
        MuseCodeAllowance.parse(Data(payload.utf8), now: now)
    }

    private func result(_ payload: String, now: Date = now) -> ProviderUsageResult {
        MuseCodeAllowance.result(for: parse(payload, now: now), configuration: Self.configuration, fetchedAt: now)
    }

    private func reading(_ payload: String, now: Date = now, file: StaticString = #filePath, line: UInt = #line) throws
        -> MuseCodeAllowance.Reading {
        guard case let .reading(reading) = parse(payload, now: now) else {
            XCTFail("Expected a reading", file: file, line: line)
            throw XCTSkip("not a reading")
        }
        return reading
    }

    // MARK: Parser

    func testMeasuredReadingKeepsWindowsTierSourceAndObservationTime() throws {
        let reading = try reading(Self.measured)
        XCTAssertEqual(reading.observedAt, Self.asOf)
        XCTAssertEqual(reading.tier, "Muse Code Power Usage")
        XCTAssertEqual(reading.source, "mint")
        XCTAssertEqual(reading.windows, [
            .init(window: .window, usedPercent: 15, resetsAt: Self.windowReset),
            .init(window: .weekly, usedPercent: 5, resetsAt: Self.weeklyReset),
        ])
        XCTAssertTrue(reading.invalidWindows.isEmpty)

        let result = result(Self.measured)
        XCTAssertNil(result.failureMessage)
        XCTAssertTrue(result.hasCurrentBars)
        XCTAssertEqual(result.barsFetchedAt, Self.now)
        XCTAssertEqual(result.availableMetrics.map(\.id), ["museCode.window", "museCode.weekly"])
        XCTAssertEqual(result.bars.map(\.label), ["5-hour", "Weekly"])
        XCTAssertEqual(result.bars.map(\.used), [15, 5])
        XCTAssertEqual(result.bars.map(\.limit), [100, 100])
        XCTAssertEqual(result.bars.map(\.resetsAt), [Self.windowReset, Self.weeklyReset])
        XCTAssertEqual(result.bars[0].projectionPeriodStart, Self.windowReset.addingTimeInterval(-5 * 3600))
        XCTAssertEqual(result.bars[1].projectionPeriodStart, Self.weeklyReset.addingTimeInterval(-7 * 86400))
        XCTAssertEqual(result.plan?.displayLabel, "Muse Code Power Usage")
        XCTAssertEqual(result.cardInformationSections.first?.items.map(\.label), ["Measured", "Source"])
        XCTAssertEqual(result.cardInformationSections.first?.items.last?.detail, "mint")
        XCTAssertTrue(result.usageMessages.isEmpty)
    }

    func testGenuineZeroStaysNumericZeroAndNullAllowanceIsUnavailable() throws {
        let zero = result(Self.zero)
        XCTAssertNil(zero.failureMessage)
        XCTAssertEqual(zero.bars.map(\.used), [0, 0])
        XCTAssertTrue(zero.hasCurrentBars)

        XCTAssertEqual(parse(Self.nullAllowance), .unavailable(.allowanceNotReported))
        let unavailable = result(Self.nullAllowance)
        XCTAssertTrue(unavailable.bars.isEmpty)
        XCTAssertEqual(unavailable.failureMessage, MuseCodeAllowance.Unavailable.allowanceNotReported.message)
        XCTAssertTrue(unavailable.preserveCachedBarsOnFailure)
        XCTAssertEqual(unavailable.unavailableUsageMetrics["museCode.window"], "Unavailable")
        XCTAssertEqual(unavailable.unavailableUsageMetrics["museCode.weekly"], "Unavailable")
    }

    func testReasonAndHintNeverSurface() {
        for payload in [Self.nullAllowance, Self.payAsYouGo] {
            let result = result(payload)
            let text = ([result.title, result.subtitle, result.failureMessage ?? ""] + result.usageMessages
                + result.cardInformationSections.flatMap { $0.items.map(\.detail) }).joined(separator: " ")
            for secret in ["fixture.user", "Fixture User", "synthetic", "sk-fixture-secret", "META_API_KEY", "unset the key"] {
                XCTAssertFalse(text.contains(secret), secret)
            }
        }
        // PAYG and a missing subscription share `allowance: null`; the app can't tell them apart.
        XCTAssertEqual(parse(Self.payAsYouGo), .unavailable(.allowanceNotReported))
    }

    func testExhaustedCapsTheBarButKeepsTheRawForecastInput() {
        let result = result(Self.exhausted)
        XCTAssertEqual(result.bars.map(\.used), [100, 100])
        XCTAssertEqual(result.bars.map(\.fractionUsed), [1, 1])
        XCTAssertEqual(result.bars[0].projectionCurrent ?? 0, 1.3, accuracy: 0.000_001)
        XCTAssertEqual(result.bars[0].severity, .critical)
    }

    func testInvalidWindowsAreDroppedIndependentlyAndNamed() throws {
        let partial = result(Self.partial)
        XCTAssertEqual(partial.availableMetrics.map(\.id), ["museCode.weekly"])
        XCTAssertEqual(partial.unavailableUsageMetrics["museCode.window"], "Unavailable")
        XCTAssertEqual(partial.usageMessages, ["5-hour allowance unavailable: Muse Code sent an invalid value."])
        XCTAssertNil(partial.failureMessage)

        let beyond = result(Self.resetBeyondWindow)
        XCTAssertEqual(beyond.availableMetrics.map(\.id), ["museCode.window"])
        XCTAssertEqual(beyond.unavailableUsageMetrics["museCode.weekly"], "Unavailable")

        // Strings are never coerced into percentages or timestamps.
        XCTAssertEqual(parse(Self.malformedValues), .unavailable(.noValidWindows))
        let boolean = Self.measured.replacingOccurrences(of: #""usedPercent":15"#, with: #""usedPercent":true"#)
        XCTAssertEqual(try reading(boolean).invalidWindows, [.window])
        let negative = Self.measured.replacingOccurrences(of: #""usedPercent":15"#, with: #""usedPercent":-1"#)
        XCTAssertEqual(try reading(negative).invalidWindows, [.window])
    }

    func testResetRolloverDropsOnlyTheElapsedWindow() throws {
        let afterShortReset = Self.windowReset.addingTimeInterval(60)
        let reading = try reading(Self.measured, now: afterShortReset)
        XCTAssertEqual(reading.windows.map(\.window), [.weekly])
        XCTAssertEqual(reading.invalidWindows, [.window])
        XCTAssertEqual(parse(Self.measured, now: Self.weeklyReset.addingTimeInterval(1)), .unavailable(.noValidWindows))
    }

    func testUnsupportedMalformedAndObservationFailuresAreDistinct() {
        XCTAssertEqual(parse(Self.unsupportedSchema), .unavailable(.unsupportedSchema))
        XCTAssertEqual(parse(#"{"allowance":null}"#), .unavailable(.unsupportedSchema))
        XCTAssertEqual(parse(#"{"schemaVersion":"1","allowance":null}"#), .unavailable(.unsupportedSchema))
        XCTAssertEqual(parse(Self.truncated), .unavailable(.malformed))
        XCTAssertEqual(parse("[]"), .unavailable(.malformed))
        XCTAssertEqual(parse(#"{"schemaVersion":1,"allowance":[]}"#), .unavailable(.malformed))
        XCTAssertEqual(parse(#"{"schemaVersion":1}"#), .unavailable(.malformed))
        XCTAssertEqual(
            parse(Self.measured.replacingOccurrences(of: #""asOfMs":1793037245064,"#, with: "")),
            .unavailable(.observationMissing)
        )
        XCTAssertEqual(parse(Self.measured, now: Self.asOf.addingTimeInterval(-61)), .unavailable(.observationInFuture))
        XCTAssertNotEqual(parse(Self.measured, now: Self.asOf.addingTimeInterval(-59)), .unavailable(.observationInFuture))
    }

    func testTokensAndUndocumentedWindowsNeverBecomeQuota() throws {
        XCTAssertEqual(parse(Self.tokensOnly), .unavailable(.noValidWindows))

        let reading = try reading(Self.extraWindow)
        XCTAssertNil(reading.tier, "markup in the tier is dropped")
        XCTAssertEqual(reading.undocumentedWindowNames, ["wonder-full-weekly"])
        let result = result(Self.extraWindow)
        XCTAssertEqual(result.availableMetrics.map(\.id), ["museCode.weekly"])
        XCTAssertNil(result.plan)
        XCTAssertFalse(result.bars.contains { $0.used == 40 || $0.label.localizedCaseInsensitiveContains("wonder") })
        XCTAssertEqual(result.usageMessages, [
            "Muse Code reported other allowance windows that CodexBar doesn't track (wonder-full-weekly).",
        ])
    }

    func testStaleObservationIsLastKnownWithoutForecastOrNewAlerts() {
        let later = Self.asOf.addingTimeInterval(40 * 60)
        let stale = result(Self.measured, now: later)
        XCTAssertEqual(stale.bars.count, 2)
        XCTAssertEqual(stale.barsFetchedAt, Self.asOf)
        XCTAssertFalse(stale.hasCurrentBars)
        XCTAssertTrue(stale.freshBars.isEmpty)
        XCTAssertTrue(stale.bars.allSatisfy { $0.projectionCurrent == nil && $0.projectedFraction(at: later) == nil })
        XCTAssertEqual(stale.usageMessages, ["Last known value, measured 40 minutes before this refresh."])

        let settings = UsageAlertSettings(isEnabled: true)
        let exhaustedStale = result(Self.exhausted, now: later)
        XCTAssertTrue(UsageAlertEvaluator.evaluate(results: [exhaustedStale], settings: settings, activeAlertIDs: [], now: later)
            .notifications.isEmpty)
        let exhaustedFresh = result(Self.exhausted)
        XCTAssertFalse(UsageAlertEvaluator.evaluate(results: [exhaustedFresh], settings: settings, activeAlertIDs: [], now: Self.now)
            .notifications.isEmpty)
    }

    func testEveryUnavailableStateIsDistinctAndNeverHealthy() {
        let states = MuseCodeAllowance.Unavailable.allCases
        XCTAssertEqual(Set(states.map(\.message)).count, states.count)
        for state in states {
            let result = MuseCodeAllowance.result(for: .unavailable(state), configuration: Self.configuration, fetchedAt: Self.now)
            XCTAssertTrue(result.bars.isEmpty, state.rawValue)
            XCTAssertNil(result.creditsRemaining, state.rawValue)
            XCTAssertEqual(result.failureMessage, state.message, state.rawValue)
            XCTAssertEqual(result.recoveryAction, state == .authorizationExpired ? .reauthenticate : .retryRefresh, state.rawValue)
            XCTAssertEqual(result.preserveCachedBarsOnFailure, state != .phoneAcquisitionUnsupported, state.rawValue)
        }
        XCTAssertTrue(MuseCodeAllowance.Unavailable.phoneAcquisitionUnsupported.message.contains("isn't available on iPhone"))
    }

    // MARK: Metric choices and surfaces

    func testMetricChoicesKeepUnavailableWindowsSelectable() {
        let partial = result(Self.partial)
        XCTAssertEqual(partial.configurableMetrics.map(\.id), ["museCode.window", "museCode.weekly"])
        XCTAssertEqual(partial.configurableMetrics.first?.kind, .unavailableUsage("Unavailable"))
        XCTAssertEqual(partial.configurableMetrics.last?.kind, .usageBar(index: 0))
    }

    @MainActor
    func testWidgetWatchAndHistoryCarryOnlyVerifiedFixtureWindows() throws {
        let suite = "MuseCodeSurfaces.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = MemorySecretStore()
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secrets)
        store.insertUnavailableProviderFixtureAccounts([Self.configuration])
        XCTAssertTrue(store.saveSecret("fixture-only", for: Self.configuration))
        let access = SnapshotProAccess(isProLocked: false, proAccessEndsAt: nil)

        let measured = result(Self.measured)
        WidgetSnapshotPublisher.publish(results: [measured], configurationStore: store, access: access,
                                        snapshotDefaults: defaults, accessGuard: WidgetAccessGuard(directory: nil), now: Self.now)
        let widget = try XCTUnwrap(WidgetSnapshotStore.loadSnapshot(defaults: defaults).results.first)
        XCTAssertEqual(widget.providerID, "museCode")
        XCTAssertEqual(widget.bars.compactMap(\.metricID), ["museCode.window", "museCode.weekly"])
        XCTAssertEqual(widget.bars.map(\.fractionUsed), [0.15, 0.05])
        XCTAssertEqual(widget.bars.map(\.resetsAt), [Self.windowReset, Self.weeklyReset])
        XCTAssertEqual(widget.planDisplayLabel, "Muse Code Power Usage")
        let encoded = try XCTUnwrap(String(
            bytes: JSONEncoder().encode(WidgetSnapshotStore.loadSnapshot(defaults: defaults)), encoding: .utf8
        ))
        XCTAssertFalse(encoded.contains("fixture-only"), "no credential reaches the widget")

        let watch = WatchSnapshotPublisher.makeSnapshot(results: [measured], configurationStore: store, access: access, now: Self.now)
        let watchAccount = try XCTUnwrap(watch.accounts.first)
        XCTAssertEqual(watchAccount.providerName, "Muse Code")
        XCTAssertEqual(watchAccount.metrics.map(\.id), ["museCode.window", "museCode.weekly"])
        XCTAssertEqual(watchAccount.metrics.compactMap(\.usedFraction), [0.15, 0.05])
        let decoded = try JSONDecoder().decode(WatchDashboardSnapshot.self, from: try JSONEncoder().encode(watch))
        XCTAssertEqual(decoded.accounts.first?.metrics.map(\.id), ["museCode.window", "museCode.weekly"])

        let unavailable = result(Self.nullAllowance)
        WidgetSnapshotPublisher.publish(results: [unavailable], configurationStore: store, access: access,
                                        snapshotDefaults: defaults, accessGuard: WidgetAccessGuard(directory: nil), now: Self.now)
        XCTAssertEqual(WidgetSnapshotStore.loadSnapshot(defaults: defaults).results.first?.bars.count ?? 0, 0)
        let unavailableWatch = WatchSnapshotPublisher.makeSnapshot(results: [unavailable], configurationStore: store, access: access, now: Self.now)
        XCTAssertTrue(unavailableWatch.accounts.first?.metrics.allSatisfy { $0.usedFraction == nil } ?? true)

        let history = UsageHistoryStore(defaults: defaults)
        let later = Self.asOf.addingTimeInterval(40 * 60)
        history.record(results: [measured], now: Self.now)
        history.record(results: [result(Self.measured, now: later)], now: later)
        let recorded = history.snapshots(for: Self.configuration.id, now: later)
        XCTAssertEqual(recorded.count, 1, "a stale observation is not recorded as new history")
        XCTAssertEqual(recorded.first?.bars.map(\.stableKey), ["window", "weekly"])
    }

    // MARK: Account rules

    @MainActor
    func testMuseCodeCannotBecomeAnAccountOnAnyPlan() throws {
        XCTAssertFalse(AddAccountFlowState.providerOptions.contains(.museCode))
        XCTAssertEqual(AddAccountFlowState.unavailableProviders, [.museCode])
        XCTAssertEqual(ProviderID.museCode.displayName, "Muse Code")
        XCTAssertFalse(ProviderID.museCode.isAvailableOnIPhone)
        XCTAssertTrue(ProviderID.allCases.filter { $0 != .museCode }.allSatisfy(\.isAvailableOnIPhone))

        for access in [AccountPlanAccess.unrestricted, .free] {
            let suite = "MuseCodeAccounts.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = ProviderConfigurationStore(initialPlanAccess: access, defaults: defaults, secretStore: MemorySecretStore())
            XCTAssertNil(store.addAccount(for: .museCode))
            XCTAssertEqual(store.lastError, "Muse Code isn't available on iPhone.")
            XCTAssertFalse(store.update(Self.configuration))
            XCTAssertFalse(store.canAddAccount(for: .museCode))
            XCTAssertFalse(store.requestedProPresentation, "no paywall for a provider nobody can add")
            XCTAssertTrue(store.configurations.isEmpty)
            var flow = AddAccountFlowState()
            XCTAssertNil(flow.select(.museCode, configurationStore: store))
        }

        let free = AccountPlanAccess.free
        let muse = ProviderAccountConfiguration(id: "muse", providerID: .museCode, accountLabel: "Muse", authMethod: .browserSession)
        XCTAssertFalse(free.permitsRefresh(muse))
        XCTAssertFalse(AccountPlanAccess.unrestricted.permitsRefresh(muse))
        XCTAssertTrue(free.permitsInsertion(for: .claude, configurations: [muse]), "a Muse record never holds the free slot")
        XCTAssertFalse(AccountPlanAccess.unrestricted.permitsInsertion(for: .museCode, configurations: []))
    }

    @MainActor
    func testRefreshNeverRequestsMuseCode() async {
        let service = UsageRefreshService(providers: [])
        XCTAssertFalse(service.canRefresh(Self.configuration))
        let result = await service.refresh(configuration: Self.configuration)
        XCTAssertNil(result)
        await service.refresh(configurations: [Self.configuration])
        XCTAssertTrue(service.results.isEmpty)
        XCTAssertNil(service.lastRefreshError)
    }

    @MainActor
    func testUIEvidenceFixtureRendersEveryStateThroughTheProductionMapping() throws {
        let suite = "MuseCodeFixture.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: MemorySecretStore())
        UITestMuseCodeFixture.seed(in: store, scenario: "other")
        XCTAssertNil(UITestMuseCodeFixture.results(in: store, scenario: "other"))
        XCTAssertTrue(store.configurations.isEmpty)

        UITestMuseCodeFixture.seed(in: store, scenario: UITestMuseCodeFixture.scenario)
        let results = try XCTUnwrap(UITestMuseCodeFixture.results(in: store, scenario: UITestMuseCodeFixture.scenario, now: Self.now))
        let byID = Dictionary(uniqueKeysWithValues: results.map { ($0.accountID, $0) })
        XCTAssertEqual(results.count, 7)
        XCTAssertTrue(store.configurations.allSatisfy { $0.providerID == .museCode && store.isConfigured($0) })

        XCTAssertEqual(byID["ui-muse-code-measured"]?.bars.map(\.used), [15, 5])
        XCTAssertEqual(byID["ui-muse-code-partial"]?.availableMetrics.map(\.id), ["museCode.weekly"])
        XCTAssertEqual(byID["ui-muse-code-exhausted"]?.bars.first?.used, 100)
        XCTAssertEqual(byID["ui-muse-code-stale"]?.hasCurrentBars, false)
        XCTAssertEqual(byID["ui-muse-code-not-reported"]?.failureMessage, MuseCodeAllowance.Unavailable.allowanceNotReported.message)
        XCTAssertEqual(byID["ui-muse-code-sign-in-expired"]?.recoveryAction, .reauthenticate)
        XCTAssertEqual(
            byID["ui-muse-code-not-on-iphone"]?.failureMessage, MuseCodeAllowance.Unavailable.phoneAcquisitionUnsupported.message
        )

        let service = UsageRefreshService(providers: [], initialResults: results)
        UITestMuseCodeFixture.presentFailures(of: results, in: service, scenario: "other")
        XCTAssertTrue(service.refreshErrorsByAccountID.isEmpty)
        UITestMuseCodeFixture.presentFailures(of: results, in: service, scenario: UITestMuseCodeFixture.scenario)
        XCTAssertEqual(
            Set(service.refreshErrorsByAccountID.keys),
            ["ui-muse-code-not-reported", "ui-muse-code-sign-in-expired", "ui-muse-code-not-on-iphone"]
        )
    }

    func testExistingProviderIdentifiersAreUnchanged() throws {
        XCTAssertEqual(ProviderID.allCases.map(\.rawValue), [
            "codex", "copilot", "githubBilling", "claude", "grok", "xSubscription", "openRouter",
            "openCodeZen", "moonshot", "cursor", "greptile", "gemini", "antigravity", "museCode",
        ])
        let saved = try JSONEncoder().encode(ProviderID.allCases.filter { $0 != .museCode }.map(ProviderAccountConfiguration.defaultConfiguration))
        let decoded = try JSONDecoder().decode([ProviderAccountConfiguration].self, from: saved)
        XCTAssertFalse(decoded.contains { $0.providerID == .museCode })
        XCTAssertEqual(decoded.count, ProviderID.allCases.count - 1)
    }
}
