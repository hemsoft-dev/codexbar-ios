import XCTest
@testable import CodexBarIOS

final class SubscriptionRenewalTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func renewal(offset: Double, state: SubscriptionRenewal.State = .renewing,
                         observedOffset: Double = 0, accountID: String = "personal") -> SubscriptionRenewal {
        SubscriptionRenewal(accountID: accountID, providerID: .codex, state: state,
                            date: now.addingTimeInterval(offset), observedAt: now.addingTimeInterval(observedOffset))
    }

    func testClaudeDiagnosticsRespectOrganizationAndAccountBinding() {
        for tier in ["team", "enterprise", "max"] {
            var result = ProviderUsageResult(accountID: "personal", providerID: .claude, title: "Claude",
                                             plan: .make(providerPrefix: "claude", identifier: tier, label: tier),
                                             subtitle: "", bars: [], fetchedAt: now)
            result.subscriptionBillingProblem = SubscriptionBillingProblem(accountID: "personal", reason: .notConnected)
            let detail = result.subscriptionBillingInformation(at: now)?.items.first?.detail ?? ""
            XCTAssertEqual(result.canOpenClaudeBillingSettings, tier == "max")
            XCTAssertEqual(detail.contains("organization billing is unsupported"), tier != "max")
            result.subscriptionBillingProblem = SubscriptionBillingProblem(accountID: "other", reason: .expiredSession)
            XCTAssertFalse(result.subscriptionBillingInformation(at: now)?.items.first?.detail.contains("expired") == true)
        }
    }

    func testCountdownBoundariesAndElapsedTime() {
        for (seconds, label) in [(172_800.0, "Renews in 2d"), (86_399, "Renews in 23h"),
                                 (3_600, "Renews in 1h"), (3_599, "Renews in 59m"), (1, "Renews in 1m"),
        ] {
            XCTAssertEqual(renewal(offset: seconds).compactLabel(at: now), label)
        }
        XCTAssertNil(renewal(offset: 0).compactLabel(at: now))
        XCTAssertNil(renewal(offset: -1).compactLabel(at: now))
        let value = renewal(offset: 172_800)
        XCTAssertEqual(value.compactLabel(at: now.addingTimeInterval(3_600)), "Renews in 1d")
        XCTAssertTrue(value.accessibilityText(at: now)?.contains("2 days") == true)
    }

    func testStaleCanceledAndFreeNeverLookLikeUpcomingCharges() {
        XCTAssertNil(renewal(offset: 172_800, observedOffset: -86_401).compactLabel(at: now))
        XCTAssertNil(renewal(offset: 172_800, observedOffset: 61).compactLabel(at: now))
        XCTAssertNil(renewal(offset: 172_800, state: .nonRenewing).compactLabel(at: now))
        XCTAssertEqual(renewal(offset: 172_800, state: .nonRenewing).information(at: now)?.items.first?.label, "Does not renew")
        XCTAssertNil(renewal(offset: 172_800, state: .notApplicable).information(at: now))
        XCTAssertEqual(renewal(offset: -1).information(at: now)?.items.first?.label, "Billing date passed")
    }

    func testDateOnlyKeepsCivilDayAcrossTimezonesAndDST() throws {
        let formatter = ISO8601DateFormatter()
        let date = try XCTUnwrap(formatter.date(from: "2026-11-01T00:00:00Z"))
        for zone in ["America/New_York", "Pacific/Honolulu", "Asia/Tokyo"] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try XCTUnwrap(TimeZone(identifier: zone))
            let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 18)))
            let value = SubscriptionRenewal(accountID: "personal", providerID: .codex, state: .renewing,
                                            date: date, isDateOnly: true, observedAt: today)
            XCTAssertEqual(value.compactLabel(at: today, calendar: calendar), "Renews in 1d")
            let nextMorning = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 6)))
            XCTAssertEqual(value.compactLabel(at: nextMorning, calendar: calendar), "Renews today")
            XCTAssertTrue(value.dateText(calendar: calendar)?.contains("time not provided") == true)
        }
    }

    func testAccountBindingAndFailureRejectRetainedDates() {
        var result = makeHistoryResult(accountID: "personal", fetchedAt: now)
        result.subscriptionRenewal = renewal(offset: 172_800, accountID: "work")
        XCTAssertNil(result.boundSubscriptionRenewal)
        result.subscriptionRenewal = renewal(offset: 172_800)
        XCTAssertNotNil(result.boundSubscriptionRenewal)
        let failed = ProviderUsageResult(accountID: "personal", providerID: .codex, title: "Personal", subtitle: "",
                                         bars: [], subscriptionRenewal: result.subscriptionRenewal,
                                         failureMessage: "Failed", fetchedAt: now)
        XCTAssertNil(failed.subscriptionRenewal)
        XCTAssertNil(failed.boundSubscriptionRenewal)
        var otherProvider = makeHistoryResult(accountID: "personal", providerID: .claude, fetchedAt: now)
        otherProvider.subscriptionRenewal = renewal(offset: 172_800)
        XCTAssertNil(otherProvider.boundSubscriptionRenewal)
    }

    func testFreeAndPrepaidProductsRejectConflictingBillingEvidence() throws {
        let googleFree = try XCTUnwrap(GoogleAIPlanParser.namedPlan("Google AI Free"))
        for (provider, identifier) in [(ProviderID.codex, "codex.free"), (.cursor, "cursor.free"),
                                       (.gemini, googleFree.identifier), (.openRouter, "openrouter.api-credits"), (.moonshot, "moonshot.api-credits"),
        ] {
            var result = ProviderUsageResult(accountID: "personal", providerID: provider, title: "Fixture",
                                              plan: provider == .gemini ? googleFree
                                                  : .make(providerPrefix: provider.rawValue, identifier: identifier, label: "Free"),
                                              subtitle: "", bars: [], fetchedAt: now)
            result.subscriptionRenewal = SubscriptionRenewal(accountID: "personal", providerID: provider, state: .renewing,
                                                              date: now.addingTimeInterval(172_800), observedAt: now)
            XCTAssertNil(result.boundSubscriptionRenewal)
            XCTAssertNil(result.subscriptionBillingInformation(at: now))
        }
    }

    func testHeaderSettingAndExactDateDetailsAreIndependent() {
        var result = makeHistoryResult(accountID: "personal", fetchedAt: now)
        result.subscriptionRenewal = renewal(offset: 172_800)
        let visible = ProviderUsageCard.disclosureAccessibilityLabel(for: result, statusText: "", isRefreshing: false,
                                                                     isPerformingRecovery: false, severity: .normal, now: now)
        XCTAssertTrue(visible.contains("Renews in 2 days"))
        let hidden = ProviderUsageCard.disclosureAccessibilityLabel(for: result, statusText: "", isRefreshing: false,
                                                                    isPerformingRecovery: false, severity: .normal,
                                                                    showsSubscriptionRenewals: false, now: now)
        XCTAssertFalse(hidden.contains("Renews"))
        XCTAssertEqual(ProviderUsageCard.informationSections(for: result, now: now).last?.items.first?.detail,
                       result.subscriptionRenewal?.dateText())
    }

    @MainActor
    func testSettingDefaultsOnAndPersistsExplicitFalseAcrossUpgradeAndReload() throws {
        let suite = "subscription-renewal-tests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("dark", forKey: "appAppearance")
        let store = ProviderConfigurationStore(defaults: defaults, secretStore: EmptySecretStore(), widgetSnapshotDefaults: defaults)
        XCTAssertTrue(store.showsSubscriptionRenewals)
        store.updateShowsSubscriptionRenewals(false)
        XCTAssertFalse(store.showsSubscriptionRenewals)
        let reload = ProviderConfigurationStore(defaults: defaults, secretStore: EmptySecretStore(), widgetSnapshotDefaults: defaults)
        XCTAssertFalse(reload.showsSubscriptionRenewals)
        reload.updateShowsSubscriptionRenewals(true)
        XCTAssertTrue(defaults.bool(forKey: "showsSubscriptionRenewals"))
    }

    func testKnownSubscriptionContractRejectsGuessesAndMismatchedOwners() throws {
        let parse: (String) -> SubscriptionRenewal? = { body in
            CodexSubscriptionClient.parse(Data(body.utf8), accountID: "personal", providerAccountID: "provider-personal", observedAt: self.now)
        }
        XCTAssertEqual(parse(#"{"active_until":"2027-01-15T13:00:00.000Z","will_renew":true}"#)?.state, .renewing)
        XCTAssertEqual(parse(#"{"active_until":"2027-01-15T13:00:00Z","will_renew":false}"#)?.state, .nonRenewing)
        XCTAssertEqual(parse(#"{"active_until":null,"will_renew":false}"#)?.state, .notApplicable)
        for body in [#"{"active_until":"2027-01-15T13:00:00Z","will_renew":1}"#,
                     #"{"active_until":"2027-01-15","will_renew":true}"#,
                     #"{"active_until":null,"will_renew":true}"#, #"{"will_renew":true}"#,
                     #"{"reset_at":"2027-01-15T13:00:00Z","will_renew":true}"#,
                     #"{"account_id":"provider-work","active_until":"2027-01-15T13:00:00Z","will_renew":true}"#,
        ] {
            XCTAssertNil(parse(body), body)
        }
    }

    func testBillingClientUsesBoundGrantAndNeverBrowserCookies() async throws {
        let fixture = IsolatedTestURLSession { request in
            XCTAssertEqual(request.url?.path, "/backend-api/subscriptions")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer personal-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "provider-personal")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(query?.filter { $0.name == "account_id" }.map(\.value), ["provider-personal"])
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "OpenAI-Beta"), "codex-1")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Originator"), "Codex Desktop")
            XCTAssertTrue(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("codex_cli_rs/") == true)
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"active_until":"2027-01-15T13:00:00Z","will_renew":true}"#.utf8))
        }
        defer { fixture.invalidate() }
        let credentials = CodexCredentials(accessToken: "personal-token", accountID: "provider-personal")
        let result = try await CodexSubscriptionClient(session: fixture.session).fetch(credentials: credentials, accountID: "personal", observedAt: now)
        XCTAssertEqual(result?.accountID, "personal")
        XCTAssertEqual(result?.state, .renewing)
    }

    func testProviderAcquiresOnlyItsCurrentAccountsBillingAndPreservesUsageOnFailure() async throws {
        for changesOwner in [false, true] {
            let store = MemorySecretStore()
            let account = ProviderAccountConfiguration(id: "personal", providerID: .codex, authMethod: .browserSession)
            let key = ProviderConfigurationStore.keychainAccount(for: account)
            let secret = CodexCredentialsParser.storedCredential(from: CodexCredentials(accessToken: "token", accountID: "provider-personal"))
            try store.saveSecret(secret, account: key)
            let fixture = IsolatedTestURLSession { request in
                let billing = request.url?.path == "/backend-api/subscriptions"
                if billing && changesOwner {
                    try store.saveSecret(CodexCredentialsParser.storedCredential(from: CodexCredentials(
                        accessToken: "replacement", accountID: "provider-work"
                    )), account: key)
                }
                let body = billing ? #"{"active_until":"2027-01-15T13:00:00Z","will_renew":true}"#
                    : request.url?.path == "/usage" ? #"{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":25,"reset_at":2000007200,"limit_window_seconds":18000}}}"# : "{}"
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
            }
            defer { fixture.invalidate() }
            let provider = CodexUsageProvider(secretStore: store, session: fixture.session,
                                              usageEndpoint: URL(string: "https://example.test/usage")!,
                                              resetCreditsEndpoint: URL(string: "https://example.test/resets")!)
            do {
                let result = try await provider.fetchUsage(for: account)
                XCTAssertFalse(changesOwner, "An old grant must not finish after account replacement")
                XCTAssertEqual(result.boundSubscriptionRenewal?.accountID, account.id)
                XCTAssertNil(result.failureMessage)
                XCTAssertEqual(result.plan?.identifier, "codex.pro")
            } catch is CancellationError {
                XCTAssertTrue(changesOwner)
            }
        }
    }

    func testPersonalBillingIsNeverAttachedToFreeOrWorkspaceUsage() async throws {
        for plan in ["free", "business", "enterprise", "future"] {
            let store = MemorySecretStore()
            let account = ProviderAccountConfiguration(id: "work", providerID: .codex, authMethod: .browserSession)
            try store.saveSecret(CodexCredentialsParser.storedCredential(from: CodexCredentials(
                accessToken: "work-token", accountID: "work-account"
            )), account: ProviderConfigurationStore.keychainAccount(for: account))
            let fixture = IsolatedTestURLSession { request in
                XCTAssertNotEqual(request.url?.path, "/backend-api/subscriptions", "Personal billing has no verified workspace semantics")
                let body = request.url?.path == "/usage"
                    ? "{\"plan_type\":\"\(plan)\",\"rate_limit\":{\"primary_window\":{\"used_percent\":25,\"reset_at\":2000007200,\"limit_window_seconds\":18000}}}"
                    : "{}"
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
            }
            defer { fixture.invalidate() }
            let result = try await CodexUsageProvider(secretStore: store, session: fixture.session,
                                                      usageEndpoint: URL(string: "https://example.test/usage")!,
                                                      resetCreditsEndpoint: URL(string: "https://example.test/resets")!).fetchUsage(for: account)
            XCTAssertNil(result.subscriptionRenewal)
            XCTAssertNil(result.failureMessage)
            XCTAssertEqual(result.bars.first?.used, 25)
        }
    }

    @MainActor
    func testCachedUsageAndReconnectNeverRestoreBillingDates() async {
        let account = ProviderAccountConfiguration(id: "personal", providerID: .codex, authMethod: .browserSession)
        var cached = makeHistoryResult(accountID: account.id, fetchedAt: now, used: 25)
        cached.subscriptionRenewal = renewal(offset: 172_800)
        let service = UsageRefreshService(providers: [ReturningFailureUsageProvider(providerID: .codex)], initialResults: [cached])
        service.updateCurrentConfigurations([account])
        service.invalidateCredentials(accountID: account.id, preserveCachedResult: true)
        XCTAssertEqual(service.results.first?.bars.first?.used, 25)
        XCTAssertNil(service.results.first?.boundSubscriptionRenewal)
        _ = await service.refresh(configuration: account)
        XCTAssertNil(service.results.first?.boundSubscriptionRenewal)
        service.invalidateCredentials(accountID: account.id)
        XCTAssertTrue(service.results.isEmpty)
    }

    func testOptionalBillingRejectionsStayUnavailable() async throws {
        for status in [401, 403, 429, 500] {
            let fixture = IsolatedTestURLSession { request in
                (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data())
            }
            defer { fixture.invalidate() }
            let result = try await CodexSubscriptionClient(session: fixture.session).fetch(
                credentials: CodexCredentials(accessToken: "token", accountID: "account"), accountID: "personal", observedAt: now)
            XCTAssertNil(result)
        }
    }
}
