#if DEBUG
import Foundation

/// Simulator-only Muse Code states for UI evidence. Every value is synthetic and the shipping app cannot
/// reach these cards: Muse Code can't be added on iPhone (MUSE-CODE.md).
@MainActor
enum UITestMuseCodeFixture {
    static let scenario = "muse-code-states"

    private enum State: String, CaseIterable {
        case measured
        case partial
        case exhausted
        case stale
        case notReported = "not-reported"
        case signInExpired = "sign-in-expired"
        case notOnIPhone = "not-on-iphone"

        var label: String {
            switch self {
            case .measured: "Fixture: measured"
            case .partial: "Fixture: partial"
            case .exhausted: "Fixture: exhausted"
            case .stale: "Fixture: stale"
            case .notReported: "Fixture: allowance null"
            case .signInExpired: "Fixture: sign-in expired"
            case .notOnIPhone: "Fixture: not on iPhone"
            }
        }

        var accountID: String {
            "ui-muse-code-\(rawValue)"
        }
    }

    static func seed(in store: ProviderConfigurationStore, scenario: String?) {
        guard scenario == Self.scenario else { return }
        let accounts = State.allCases.map {
            ProviderAccountConfiguration(id: $0.accountID, providerID: .museCode, accountLabel: $0.label, authMethod: .browserSession)
        }
        store.insertUnavailableProviderFixtureAccounts(accounts)
        for account in accounts {
            _ = store.saveSecret("ui-test-credential", for: account)
        }
    }

    static func results(in store: ProviderConfigurationStore, scenario: String?, now: Date = Date()) -> [ProviderUsageResult]? {
        guard scenario == Self.scenario else { return nil }
        return State.allCases.compactMap { state in
            store.configuration(accountID: state.accountID).map { result(for: state, configuration: $0, now: now) }
        }
    }

    /// Shows unavailable states with the same error presentation a failed refresh would produce.
    static func presentFailures(of results: [ProviderUsageResult], in service: UsageRefreshService, scenario: String?) {
        guard scenario == Self.scenario else { return }
        service.recordFixtureFailures(from: results)
    }

    private static func result(for state: State, configuration: ProviderAccountConfiguration, now: Date) -> ProviderUsageResult {
        let outcome: MuseCodeAllowance.Outcome
        switch state {
        case .measured:
            outcome = parse(observedAgo: 60, window: #""usedPercent":15"#, weekly: #""usedPercent":5"#, now: now)
        case .partial:
            outcome = parse(observedAgo: 60, window: nil, weekly: #""usedPercent":5"#, now: now)
        case .exhausted:
            outcome = parse(observedAgo: 60, window: #""usedPercent":104"#, weekly: #""usedPercent":62"#, now: now)
        case .stale:
            outcome = parse(observedAgo: 40 * 60, window: #""usedPercent":15"#, weekly: #""usedPercent":5"#, now: now)
        case .notReported:
            let payload = #"{"schemaVersion":1,"allowance":null,"reason":"synthetic reason for fixture.user@example.com","hint":"x"}"#
            outcome = MuseCodeAllowance.parse(Data(payload.utf8), now: now)
        case .signInExpired:
            outcome = .unavailable(.authorizationExpired)
        case .notOnIPhone:
            outcome = .unavailable(.phoneAcquisitionUnsupported)
        }
        return MuseCodeAllowance.result(for: outcome, configuration: configuration, fetchedAt: now)
    }

    /// `window: nil` keeps the five-hour key but drops its percentage, the partial reading in the producer fixtures.
    private static func parse(observedAgo: TimeInterval, window: String?, weekly: String, now: Date) -> MuseCodeAllowance.Outcome {
        let asOf = now.addingTimeInterval(-observedAgo)
        func milliseconds(_ date: Date) -> Int { Int(date.timeIntervalSince1970 * 1000) }
        let windowReset = milliseconds(asOf.addingTimeInterval(3 * 60 * 60))
        let weeklyReset = milliseconds(asOf.addingTimeInterval(4 * 24 * 60 * 60))
        let windowFields = window.map { "\($0)," } ?? ""
        let payload = """
        {"schemaVersion":1,"allowance":{"asOfMs":\(milliseconds(asOf)),"source":"mint","tier":"Muse Code Power Usage",\
        "window":{\(windowFields)"resetsAtMs":\(windowReset)},"weekly":{\(weekly),"resetsAtMs":\(weeklyReset)}}}
        """
        return MuseCodeAllowance.parse(Data(payload.utf8), now: now)
    }
}
#endif
