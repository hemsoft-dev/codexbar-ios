#if DEBUG
import Foundation

/// Simulator-only Antigravity states for UI tests and evidence. Every value is synthetic: the responses are built
/// from the field layout in Google's public page code and no Google account or page is ever opened.
@MainActor
enum UITestAntigravityFixture {
    static let statesScenario = "antigravity-states"
    static let addScenario = "antigravity-add"

    private enum State: String, CaseIterable {
        case measured
        case weeklyLimit = "weekly-limit"
        case partial
        case extraPool = "extra-pool"
        case stale
        case needsComputer = "needs-computer"
        case signInExpired = "sign-in-expired"

        var label: String {
            switch self {
            case .measured: "Fixture: four meters"
            case .weeklyLimit: "Fixture: weekly limit hit"
            case .partial: "Fixture: pools missing"
            case .extraPool: "Fixture: extra pool"
            case .stale: "Fixture: page didn't load"
            case .needsComputer: "Fixture: needs a computer"
            case .signInExpired: "Fixture: sign in again"
            }
        }

        var accountID: String {
            "ui-antigravity-\(rawValue)"
        }
    }

    static func isScenario(_ scenario: String?) -> Bool {
        scenario == statesScenario || scenario == addScenario
    }

    static func seed(in store: ProviderConfigurationStore, scenario: String?) {
        guard scenario == statesScenario, store.configurations.isEmpty else { return }
        for state in State.allCases {
            let account = ProviderAccountConfiguration(
                id: state.accountID, providerID: .antigravityWeb, accountLabel: state.label, authMethod: .browserSession
            )
            precondition(store.update(account))
            _ = store.saveSecret(AntigravityWebSessionMarker(websiteDataStoreID: storeID(for: state)).storedValue, for: account)
        }
    }

    static func results(in store: ProviderConfigurationStore, scenario: String?, now: Date = Date()) -> [ProviderUsageResult]? {
        if scenario == addScenario {
            // After a relaunch, the account the synthetic sign-in added shows the reading that sign-in reported.
            return store.configurations.filter { $0.providerID == .antigravityWeb && store.isConfigured($0) }.compactMap {
                try? AntigravityQuotaParser.result(from: signInCapture, configuration: $0, fetchedAt: now)
            }
        }
        guard scenario == statesScenario else { return nil }
        return State.allCases.compactMap { state in
            store.configuration(accountID: state.accountID).map { result(for: state, configuration: $0, now: now) }
        }
    }

    static func presentFailures(of results: [ProviderUsageResult], in service: UsageRefreshService, scenario: String?) {
        guard scenario == statesScenario else { return }
        service.recordFixtureFailures(from: results)
    }

    /// The real provider with a reader that never opens a page.
    static func providers(overriding providers: [any UsageProvider], scenario: String?, secretStore: SecretStore) -> [any UsageProvider] {
        guard isScenario(scenario) else { return providers }
        return [AntigravityUsageProvider(secretStore: secretStore, reader: FixtureReader())]
    }

    /// What the synthetic sign-in reports: the four meters and plan from the owner's screenshot of November 23, 2026.
    nonisolated static var signInCapture: AntigravityPageCapture {
        AntigravityPageCapture(quotaBody: quotaBody(for: .measured, now: Date()), profileBody: profileBody, pagePath: "/remote/settings")
    }

    // MARK: Synthetic responses

    nonisolated private static let profileBody = #"["",["g1-ultra-tier","Google AI Ultra"]]"#

    nonisolated private static func storeID(for state: State) -> UUID {
        let index = State.allCases.firstIndex(of: state) ?? 0
        return UUID(uuidString: "00000000-0000-4000-8000-00000000060\(index)") ?? UUID()
    }

    nonisolated private static func bucket(
        _ id: String, _ name: String, window: String, remaining: Double?, resetIn: TimeInterval? = nil, disabled: Bool = false,
        now: Date
    ) -> [Any] {
        let reset: Any = resetIn.map { [String(Int(now.addingTimeInterval($0).timeIntervalSince1970)), 0] as [Any] } ?? NSNull()
        return [id, name, window, remaining.map { $0 as Any } ?? NSNull(), NSNull(), reset, NSNull(), disabled]
    }

    nonisolated private static func quotaBody(for state: State, now: Date) -> String {
        let day: TimeInterval = 24 * 60 * 60
        var gemini = [
            bucket("gemini-weekly", "Weekly Limit Remaining", window: "weekly", remaining: 0.9725, resetIn: 6 * day + 21 * 3600, now: now),
            bucket("gemini-5h", "Five Hour Limit Remaining", window: "5h", remaining: 0.91, resetIn: 2 * 3600 + 15 * 60, now: now),
        ]
        var other = [
            bucket("3p-weekly", "Weekly Limit Remaining", window: "weekly", remaining: 1, now: now),
            bucket("3p-5h", "Five Hour Limit Remaining", window: "5h", remaining: 1, now: now),
        ]
        switch state {
        case .weeklyLimit:
            gemini = [
                bucket("gemini-weekly", "Weekly Limit Remaining", window: "weekly", remaining: 0, resetIn: 2 * day + 4 * 3600, now: now),
                bucket("gemini-5h", "Five Hour Limit Remaining", window: "5h", remaining: nil, disabled: true, now: now),
            ]
        case .partial:
            gemini.removeLast()
            other = [bucket("3p-weekly", "Weekly Limit Remaining", window: "weekly", remaining: 0.62, resetIn: 3 * day, now: now)]
        case .extraPool:
            gemini.append(bucket(
                "gemini-argon-wtu-weekly", "Argon Weekly Limit Remaining", window: "weekly", remaining: 0.4, resetIn: 5 * day, now: now
            ))
        case .measured, .stale, .needsComputer, .signInExpired:
            break
        }
        let response: [Any] = [[[[], [[gemini, "Gemini Models"], [other, "Claude and GPT models"]]] as [Any]] as [Any]]
        let data = (try? JSONSerialization.data(withJSONObject: response)) ?? Data()
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    private static func result(for state: State, configuration: ProviderAccountConfiguration, now: Date) -> ProviderUsageResult {
        let storeID = storeID(for: state)
        func reading(at date: Date) -> ProviderUsageResult {
            let capture = AntigravityPageCapture(quotaBody: quotaBody(for: state, now: date), profileBody: profileBody)
            var result = (try? AntigravityQuotaParser.result(from: capture, configuration: configuration, fetchedAt: date))
                ?? AntigravityUsageProvider.failure(.unreadableResponse, configuration: configuration, storeID: storeID, at: date)
            result.cacheIdentity = AntigravityUsageProvider.cacheIdentity(storeID)
            return result
        }
        switch state {
        case .measured, .weeklyLimit, .partial, .extraPool:
            return reading(at: now)
        case .needsComputer:
            return AntigravityUsageProvider.failure(.noUsageReported, configuration: configuration, storeID: storeID, at: now)
        case .signInExpired:
            return AntigravityUsageProvider.failure(.signInRequired, configuration: configuration, storeID: storeID, at: now)
        case .stale:
            // The shape the refresh service produces when the page fails after an earlier reading.
            let earlier = reading(at: now.addingTimeInterval(-47 * 60))
            let failure = AntigravityUsageProvider.failure(.pageFailed, configuration: configuration, storeID: storeID, at: now)
            return ProviderUsageResult(
                accountID: configuration.id, providerID: .antigravityWeb, title: configuration.displayName, plan: earlier.plan,
                subtitle: "\(failure.subtitle) Showing last known data.", bars: earlier.bars, barsFetchedAt: earlier.barsFetchedAt,
                unavailableUsageMetrics: earlier.unavailableUsageMetrics, failureMessage: failure.failureMessage,
                recoveryAction: failure.recoveryAction, preserveCachedBarsOnFailure: true, cacheIdentity: failure.cacheIdentity,
                hasSuccessfulRefreshHistory: true, fetchedAt: now
            )
        }
    }

    private struct FixtureReader: AntigravityPageReading {
        func read(marker: AntigravityWebSessionMarker) async throws -> AntigravityPageCapture {
            let states = State.allCases
            guard let state = states.first(where: { UITestAntigravityFixture.storeID(for: $0) == marker.websiteDataStoreID }) else {
                return UITestAntigravityFixture.signInCapture
            }
            switch state {
            case .needsComputer: throw AntigravityReadError.noUsageReported
            case .signInExpired: throw AntigravityReadError.signInRequired
            case .stale: throw AntigravityReadError.pageFailed
            case .measured, .weeklyLimit, .partial, .extraPool:
                return AntigravityPageCapture(
                    quotaBody: UITestAntigravityFixture.quotaBody(for: state, now: Date()),
                    profileBody: UITestAntigravityFixture.profileBody
                )
            }
        }
    }
}
#endif
