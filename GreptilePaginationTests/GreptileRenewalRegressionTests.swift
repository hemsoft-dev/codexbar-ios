import Combine
import Foundation
import XCTest
@testable import CodexBarIOS

final class GreptileRenewalRegressionTests: XCTestCase, @unchecked Sendable {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func credential(subject: String = "fixture-user", organization: String = "fixture-org") -> GreptileSessionCredentials {
        GreptileSessionCredentials(
            version: 1, subject: subject,
            organization: GreptileOrganization(tenantExternalId: organization, name: "Synthetic organization"),
            cookies: [GreptileSessionCookie(name: "__Secure-authjs.session-token", value: "synthetic-cookie", expiresAt: nil)]
        )
    }

    private func identity(
        subject: String = "fixture-user", organization: String = "fixture-org", token: String = "synthetic-user-token"
    ) throws -> GreptileHTTPFixture.Reply {
        .payload(try JSONSerialization.data(withJSONObject: [
            "user": [
                "greptileId": subject, "greptileToken": token,
                "organizations": [["tenantExternalId": organization, "name": "Synthetic organization"]],
            ],
        ]))
    }

    private func billing(_ state: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [["result": ["data": ["json": state]]]])
    }

    private func provider(_ fixture: GreptileHTTPFixture, credential: GreptileSessionCredentials) throws -> GreptileUsageProvider {
        let account = browserAccount()
        return GreptileUsageProvider(
            secretStore: GreptileFixtureSecrets(values: [
                ProviderConfigurationStore.keychainAccount(for: account): try credential.encoded(),
            ]),
            session: fixture.session, endpoint: fixture.endpoint, dashboardBaseURL: fixture.endpoint
        )
    }

    private func browserAccount() -> ProviderAccountConfiguration {
        ProviderAccountConfiguration(id: "synthetic-browser-account", providerID: .greptile, authMethod: .browserSession)
    }

    func testBillingDateDoesNotRequireCreditsOrReviewHistory() async throws {
        let date = "2030-02-15T12:03:41.000Z"
        let fixture = GreptileHTTPFixture([
            try identity(),
            .payload(try billing(["kind": "free", "currentPeriod": ["end": date]])),
            try GreptileHTTPFixture.page([], total: 0),
        ])
        defer { fixture.invalidate() }
        let result = try await provider(fixture, credential: credential()).fetchUsage(for: browserAccount())
        XCTAssertNil(result.failureMessage)
        XCTAssertEqual(result.greptileAllowanceRenewal?.renewsAt, ISO8601DateFormatter().date(from: "2030-02-15T12:03:41Z"))
        XCTAssertTrue(result.bars.isEmpty)
        XCTAssertNil(result.creditsRemaining)
        XCTAssertEqual(result.cacheIdentity, "fixture-user:fixture-org")
        let requests = fixture.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests[0].url?.path, fixture.endpoint.path + "/api/auth/session")
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(requests[1].httpMethod, "GET")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Cookie"), "__Secure-authjs.session-token=synthetic-cookie")
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(requests[1].url), resolvingAgainstBaseURL: false))
        let input = try XCTUnwrap(components.queryItems?.first { $0.name == "input" }?.value)
        XCTAssertTrue(input.contains("fixture-org"))
        XCTAssertNil(requests[2].value(forHTTPHeaderField: "Cookie"))
        XCTAssertEqual(requests[2].value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-user-token")
        let body = try GreptileHTTPFixture.requestBody(requests[2])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let params = try XCTUnwrap(object["params"] as? [String: Any])
        let arguments = try XCTUnwrap(params["arguments"] as? [String: Any])
        XCTAssertEqual(arguments["organization"] as? String, "fixture-org")
    }

    @MainActor
    func testActualCreditAllowanceStaysSeparateFromReviewActivity() async throws {
        let fixture = GreptileHTTPFixture([
            try identity(),
            .payload(try billing(["kind": "free", "used": 12, "includedCreditsPerPeriod": 17,
                                  "currentPeriod": ["start": "2026-01-01T00:00:00Z", "end": "2030-02-15T12:03:41Z"],
            ])),
            try GreptileHTTPFixture.page(["one", "two"], total: 2),
        ])
        defer { fixture.invalidate() }
        let result = try await provider(fixture, credential: credential()).fetchUsage(for: browserAccount())
        XCTAssertNil(result.failureMessage)
        let credits = try XCTUnwrap(result.bars.first { $0.stableKey == GreptileUsageIdentity.creditAllowanceStableKey })
        XCTAssertEqual(credits.used, 12)
        XCTAssertEqual(credits.limit, 17)
        XCTAssertEqual(credits.resetsAt, result.greptileAllowanceRenewal?.renewsAt)
        XCTAssertEqual(credits.resetDescription, "12 of 17 credits used. 5 remaining.")
        XCTAssertEqual(result.bars.last?.stableKey, GreptileUsageIdentity.completedReviewsStableKey)
        XCTAssertEqual(result.bars.last?.used, 2)
        XCTAssertNil(result.creditsRemaining, "Credit counts must not enter the generic dollar balance presentation.")
        XCTAssertEqual(result.cardInformationSections.first?.items.map(\.detail), ["12", "17", "5"])
        XCTAssertEqual(result.cacheIdentity, "fixture-user:fixture-org")
        let suite = "GreptileCreditHistory.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = UsageHistoryStore(defaults: defaults)
        history.record(results: [result])
        let options = history.historySeriesOptions(for: result)
        XCTAssertEqual(options.first { $0.id == "usage.credit-allowance" }?.series.points.last?.value, 12)
        XCTAssertEqual(options.first { $0.id == GreptileUsageIdentity.completedReviewsHistorySeriesID }?.series.points.last?.value, 2)

    }

    @MainActor
    func testPartialRefreshRecordsFreshCreditsWithoutReplacingCachedReviews() async throws {
        let fixture = GreptileHTTPFixture([
            try identity(), .payload(try billing(["kind": "free", "used": 12, "includedCreditsPerPeriod": 50,
                                                   "currentPeriod": ["end": "2030-02-15T12:03:41Z"],
            ])),
            try GreptileHTTPFixture.page(["one", "two"], total: 2),
            try identity(), .payload(try billing(["kind": "free", "used": 15, "includedCreditsPerPeriod": 50,
                                                   "currentPeriod": ["end": "2030-02-15T12:03:41Z"],
            ])),
            .payload(Data(), status: 503),
        ])
        defer { fixture.invalidate() }
        let service = UsageRefreshService(providers: [try provider(fixture, credential: credential())])
        let suite = "GreptilePartialRefreshHistory.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = UsageHistoryStore(defaults: defaults)
        await service.refresh(configurations: [browserAccount()])
        history.record(results: service.successfulRefreshResults)
        await service.refresh(configurations: [browserAccount()])
        history.record(results: service.successfulRefreshResults)
        let result = try XCTUnwrap(service.results.first)
        XCTAssertNotNil(result.failureMessage)
        XCTAssertTrue(result.hasCurrentBars)
        XCTAssertEqual(result.bars.first { $0.stableKey == GreptileUsageIdentity.completedReviewsStableKey }?.used, 2)
        XCTAssertEqual(result.usageHistoryBars().map(\.used), [15])
        XCTAssertEqual(result.freshBars.map(\.used), [15])
        XCTAssertEqual(result.availableMetrics.count, 2)
        let review = try XCTUnwrap(result.availableMetrics.first { $0.id == GreptileUsageIdentity.completedReviewsMetricID })
        XCTAssertEqual(review.kind, .unavailableUsage("Review activity unavailable. Last known: 2."))
        XCTAssertEqual(service.successfulRefreshResults.count, 1)
        let options = history.historySeriesOptions(for: result)
        XCTAssertEqual(options.first { $0.id == "usage.credit-allowance" }?.series.points.map(\.value), [12, 15])
        XCTAssertEqual(options.first { $0.id == GreptileUsageIdentity.completedReviewsHistorySeriesID }?.series.points.map(\.value), [2])
    }

    @MainActor
    func testFailedBillingAndReviewsExposeOneUnavailableCreditChoice() async throws {
        let fixture = GreptileHTTPFixture([
            try identity(), .payload(try billing(["kind": "free", "used": 12, "includedCreditsPerPeriod": 50,
                                                   "currentPeriod": ["end": "2030-02-15T12:03:41Z"],
            ])),
            try GreptileHTTPFixture.page(["one"], total: 1),
            try identity(), .payload(Data(), status: 503), .payload(Data(), status: 503),
        ])
        defer { fixture.invalidate() }
        let service = UsageRefreshService(providers: [try provider(fixture, credential: credential())])
        await service.refresh(configurations: [browserAccount()])
        await service.refresh(configurations: [browserAccount()])
        let result = try XCTUnwrap(service.results.first)
        let credits = result.availableMetrics.filter { $0.id == GreptileUsageIdentity.creditAllowanceMetricID }
        XCTAssertEqual(credits.count, 1)
        XCTAssertEqual(credits.first?.kind, .unavailableUsage("Credit usage unavailable"))
        XCTAssertFalse(result.hasCurrentBars)
        XCTAssertTrue(service.successfulRefreshResults.isEmpty)
        XCTAssertFalse(result.cardInformationSections.contains { $0.id == "greptile.credit-allowance" })
    }

    @MainActor
    func testKnownPaidAccountDoesNotGainFreeCreditChoiceOnBillingFailure() async throws {
        let fixture = GreptileHTTPFixture([
            try identity(), .payload(try billing(["kind": "paid"])), try GreptileHTTPFixture.page(["one"], total: 1),
            try identity(), .payload(Data(), status: 503), try GreptileHTTPFixture.page(["two"], total: 1),
        ])
        defer { fixture.invalidate() }
        let service = UsageRefreshService(providers: [try provider(fixture, credential: credential())])
        await service.refresh(configurations: [browserAccount()])
        await service.refresh(configurations: [browserAccount()])
        let result = try XCTUnwrap(service.results.first)
        XCTAssertEqual(result.greptileAllowanceRenewal?.isApplicable, false)
        XCTAssertFalse(result.availableMetrics.contains { $0.id == GreptileUsageIdentity.creditAllowanceMetricID })
        XCTAssertEqual(result.availableMetrics.count, 1)
    }

    @MainActor
    func testCreditOnlyAccountUsesCountHistoryAndCreditDetailIdentity() async throws {
        let fixture = GreptileHTTPFixture([
            try identity(), .payload(try billing(["kind": "free", "used": 12, "includedCreditsPerPeriod": 50,
                                                   "currentPeriod": ["end": "2030-02-15T12:03:41Z"],
            ])),
            try GreptileHTTPFixture.page([], total: 0),
        ])
        defer { fixture.invalidate() }
        let result = try await provider(fixture, credential: credential()).fetchUsage(for: browserAccount())
        let suite = "GreptileCreditOnlyHistory.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = UsageHistoryStore(defaults: defaults)
        history.record(results: [result])
        XCTAssertEqual(history.historySeries(for: result).points.last?.value, 12)
        XCTAssertTrue(history.historySeries(for: result).isCount)
        let id = GreptileUsageIdentity.historySeriesID(forStableKey: GreptileUsageIdentity.creditAllowanceStableKey)
        XCTAssertEqual(id, "usage.credit-allowance")
        XCTAssertEqual(history.historySeriesOptions(for: result).first { $0.id == id }?.series.points.last?.value, 12)
    }

    func testCreditExhaustionOverageAndZeroUsageRemainTruthful() throws {
        for (used, remaining, percent) in [(0.0, 50.0, "0%"), (50.0, 0.0, "100%"), (52.0, 0.0, "104%")] {
            let state = try GreptileDashboardClient.parseBillingState(billing([
                "kind": "free", "used": used, "includedCreditsPerPeriod": 50,
                "currentPeriod": ["end": "2030-02-15T12:03:41Z"],
            ]))
            let allowance = try XCTUnwrap(state.creditAllowance)
            XCTAssertEqual(allowance.used, used)
            XCTAssertEqual(allowance.remaining, remaining)
            XCTAssertEqual(allowance.usageBar(at: now)?.usageText, percent)
        }
    }

    func testInvalidCreditCountsDoNotEraseValidRenewal() throws {
        for counts: [String: Any] in [
            [:], ["used": 3], ["includedCreditsPerPeriod": 50],
            ["used": -1, "includedCreditsPerPeriod": 50], ["used": 3, "includedCreditsPerPeriod": 0],
            ["used": 3, "includedCreditsPerPeriod": -50], ["used": true, "includedCreditsPerPeriod": 50],
            ["used": 3, "includedCreditsPerPeriod": true], ["used": "3", "includedCreditsPerPeriod": 50],
            ["used": "NaN", "includedCreditsPerPeriod": 50], ["used": NSNull(), "includedCreditsPerPeriod": 50],
            ["used": 1e100, "includedCreditsPerPeriod": 1e-100],
        ] {
            var payload = counts
            payload["kind"] = "free"
            payload["currentPeriod"] = ["end": "2030-02-15T12:03:41Z"]
            let state = try GreptileDashboardClient.parseBillingState(billing(payload))
            XCTAssertNotNil(state.renewalDate)
            XCTAssertNil(state.creditAllowance)
        }
        XCTAssertThrowsError(try GreptileDashboardClient.parseBillingState(Data(
            #"[{"result":{"data":{"json":{"kind":"free","used":1e309,"includedCreditsPerPeriod":50}}}}]"#.utf8
        )))
    }

    func testCreditPeriodsAndPaidStatesNeverInventCurrentAllowance() throws {
        for period in [
            ["end": "invalid"],
            ["end": "2020-01-01T00:00:00Z"],
            ["start": "2030-01-01T00:00:00Z", "end": "2030-02-01T00:00:00Z"],
            ["start": "2030-03-01T00:00:00Z", "end": "2030-02-01T00:00:00Z"],
        ] {
            let state = try GreptileDashboardClient.parseBillingState(billing([
                "kind": "free", "used": 3, "includedCreditsPerPeriod": 50, "currentPeriod": period,
            ]))
            XCTAssertNil(state.creditAllowance?.usageBar(at: now))
        }
        let paid = try GreptileDashboardClient.parseBillingState(billing([
            "kind": "paid", "used": 3, "includedCreditsPerPeriod": 50,
            "currentPeriod": ["end": "2030-02-01T00:00:00Z"],
        ]))
        XCTAssertNil(paid.creditAllowance)
    }

    func testFailedBillingKeepsReviewActivityAndUnavailableCreditChoice() async throws {
        let fixture = GreptileHTTPFixture([
            try identity(), .payload(Data("{}".utf8), status: 401), try GreptileHTTPFixture.page(["one"], total: 1),
        ])
        defer { fixture.invalidate() }
        let result = try await provider(fixture, credential: credential()).fetchUsage(for: browserAccount())
        XCTAssertNil(result.failureMessage)
        XCTAssertEqual(result.bars.map(\.stableKey), [GreptileUsageIdentity.completedReviewsStableKey])
        XCTAssertEqual(result.configurableMetrics.first { $0.id == GreptileUsageIdentity.creditAllowanceMetricID }?.kind,
                       .unavailableUsage("Credit usage unavailable"))
        XCTAssertTrue(result.greptileAllowanceRenewal?.requiresAuthentication == true)
    }

    @MainActor
    func testCreditMetricDoesNotTakeOverSavedReviewChoices() throws {
        let suite = "GreptileCredits.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: GreptileFixtureSecrets(values: [:]))
        let account = browserAccount()
        _ = store.update(account)
        store.updateMetricVisibility(false, accountID: account.id, metricID: GreptileUsageIdentity.completedReviewsMetricID)
        _ = store.reconcileMetricLayout(accountID: account.id, availableMetricIDs: [
            GreptileUsageIdentity.creditAllowanceMetricID, GreptileUsageIdentity.completedReviewsMetricID,
        ])
        XCTAssertFalse(store.isMetricVisible(accountID: account.id, metricID: GreptileUsageIdentity.completedReviewsMetricID))
        XCTAssertTrue(store.isMetricVisible(accountID: account.id, metricID: GreptileUsageIdentity.creditAllowanceMetricID))
    }

    func testVerifiedConnectionSurvivesNonAuthenticationBillingFailures() async throws {
        for reply in [
            GreptileHTTPFixture.Reply.failure(URLError(.timedOut)),
            .payload(Data("{}".utf8), status: 503),
            .payload(Data("malformed".utf8)),
        ] {
            let fixture = GreptileHTTPFixture([try identity(), reply])
            defer { fixture.invalidate() }
            let client = GreptileDashboardClient(session: fixture.session, baseURL: fixture.endpoint)
            try await client.verifyConnection(for: credential())
            XCTAssertEqual(fixture.requests.count, 2)
            XCTAssertEqual(fixture.requests.last?.timeoutInterval, 5)
        }
    }

    func testConnectionStillRejectsExpiredWrongAndCanceledSessions() async throws {
        for replies in [
            [try identity(), .payload(Data("{}".utf8), status: 401)],
            [try identity(), .payload(Data("{}".utf8), status: 403)],
            [try identity(subject: "another-user")],
            [try identity(), .failure(URLError(.cancelled))],
        ] {
            let fixture = GreptileHTTPFixture(replies)
            defer { fixture.invalidate() }
            let client = GreptileDashboardClient(session: fixture.session, baseURL: fixture.endpoint)
            do {
                try await client.verifyConnection(for: credential())
                XCTFail("Rejected or canceled sessions must not complete setup.")
            } catch {
                XCTAssertTrue((error as? GreptileSignInError)?.requiresAuthentication == true || error is URLError)
            }
        }
    }

    func testBillingDenialStaysUnavailableAndOffersRecovery() async throws {
        let fixture = GreptileHTTPFixture([
            try identity(), .payload(Data("{}".utf8), status: 403),
            try GreptileHTTPFixture.page(["one"], total: 1),
        ])
        defer { fixture.invalidate() }
        let result = try await provider(fixture, credential: credential()).fetchUsage(for: browserAccount())
        XCTAssertNil(result.greptileAllowanceRenewal?.renewsAt)
        XCTAssertNil(result.greptileAllowanceRenewal?.isApplicable)
        XCTAssertEqual(result.greptileAllowanceRenewal?.requiresAuthentication, true)
        XCTAssertEqual(result.greptileAllowanceRenewal?.unavailableReason, GreptileSignInError.accessDenied.localizedDescription)
        XCTAssertEqual(result.bars.map(\.stableKey), [GreptileUsageIdentity.completedReviewsStableKey])
    }

    func testGoogleAuthorizationIsRecognizedWithoutBlockingGreptileOrOtherProviders() throws {
        for address in [
            "https://accounts.google.com/o/oauth2/v2/auth", "https://ACCOUNTS.GOOGLE.COM/signin",
            "https://oauth.accounts.google.com/",
        ] {
            XCTAssertTrue(GreptileSignInAvailability.isGoogleSignIn(try XCTUnwrap(URL(string: address))))
        }
        for address in [
            "https://app.greptile.com/-/settings/usage", "https://auth.greptile.com/oauth2/auth",
            "https://github.com/login/oauth/authorize", "https://accounts.google.com.example.org/",
            "https://example.org/?next=https://accounts.google.com", "about:blank",
        ] {
            XCTAssertFalse(GreptileSignInAvailability.isGoogleSignIn(try XCTUnwrap(URL(string: address))))
        }
    }

    func testMissingMalformedAndUnrelatedPeriodsNeverInventADate() throws {
        for state: [String: Any] in [
            ["kind": "free"],
            ["kind": "free", "currentPeriod": ["end": "invalid"]],
            ["kind": "free", "currentPeriod": ["end": NSNull()]],
            ["kind": "free", "currentPeriod": ["start": "2030-03-01T00:00:00Z", "end": "2030-02-01T00:00:00Z"]],
            ["kind": "paid", "currentPeriod": ["end": "2030-02-01T00:00:00Z"]],
            ["kind": "free", "apiSubscription": ["currentPeriodEnd": "2030-02-01T00:00:00Z"]],
        ] {
            XCTAssertNil(try GreptileDashboardClient.parseBillingState(billing(state)).renewalDate)
        }
        XCTAssertThrowsError(try GreptileDashboardClient.parseBillingState(Data("[]".utf8)))
        XCTAssertThrowsError(try GreptileDashboardClient.parseBillingState(Data("not-json".utf8)))
        XCTAssertThrowsError(try GreptileDashboardClient.parseBillingState(billing(["kind": "unknown"])))
    }

    func testWrongSubjectOrOrganizationStopsBeforeBillingAndReviewRequests() async throws {
        for reply in [try identity(subject: "another-user"), try identity(organization: "another-org")] {
            let fixture = GreptileHTTPFixture([reply])
            defer { fixture.invalidate() }
            let result = try await provider(fixture, credential: credential()).fetchUsage(for: browserAccount())
            XCTAssertEqual(result.recoveryAction, .reauthenticate)
            XCTAssertEqual(result.cacheIdentity, "unverified-greptile-session")
            XCTAssertTrue(result.bars.isEmpty)
            XCTAssertNil(result.greptileAllowanceRenewal?.renewsAt)
            XCTAssertEqual(fixture.requests.count, 1)
        }
    }

    func testCookiesRejectExpiredIncompleteAndInjectedCredentials() throws {
        for cookies in [
            [GreptileSessionCookie(name: "__Secure-authjs.session-token", value: "a", expiresAt: now)],
            [GreptileSessionCookie(name: "__Secure-authjs.session-token", value: "a; other=b", expiresAt: nil)],
            [GreptileSessionCookie(name: "__Secure-authjs.session-token.1", value: "a", expiresAt: nil)],
            [GreptileSessionCookie(name: "unrelated", value: "a", expiresAt: nil)],
        ] {
            let invalid = GreptileSessionCredentials(version: 1, subject: "user", organization: credential().organization, cookies: cookies)
            XCTAssertThrowsError(try invalid.cookieHeader(now: now))
        }
        let chunks = GreptileSessionCredentials(
            version: 1, subject: "user", organization: credential().organization,
            cookies: [
                GreptileSessionCookie(name: "__Secure-authjs.session-token.0", value: "a", expiresAt: nil),
                GreptileSessionCookie(name: "__Secure-authjs.session-token.1", value: "b", expiresAt: nil),
            ]
        )
        XCTAssertEqual(try chunks.cookieHeader(), "__Secure-authjs.session-token.0=a; __Secure-authjs.session-token.1=b")
        XCTAssertEqual(GreptileSessionCredentials.parse(try chunks.encoded()), chunks)
        XCTAssertNotEqual(credential().cacheIdentity, credential(organization: "another-org").cacheIdentity)
    }

    func testCountdownPassedAndStaleDatesAreHonest() {
        let renewal = GreptileAllowanceRenewal(renewsAt: now.addingTimeInterval(90_000), observedAt: now)
        XCTAssertEqual(renewal.status(at: now), "Renews in 1d 1h")
        XCTAssertNotNil(renewal.localDateText)
        XCTAssertEqual(renewal.status(at: now.addingTimeInterval(90_000)), "Last known renewal date")
        let passed = GreptileAllowanceRenewal(renewsAt: now, observedAt: now)
        XCTAssertEqual(passed.status(at: now), "Period ended. Refresh for the next renewal.")
        let stale = GreptileAllowanceRenewal(renewsAt: now.addingTimeInterval(600), observedAt: now, isStale: true)
        XCTAssertEqual(stale.status(at: now), "Last known renewal date")
        XCTAssertEqual(GreptileAllowanceRenewal(renewsAt: nil, observedAt: now).status(at: now), "Renewal date unavailable")
    }

    @MainActor
    func testReconnectCannotReplaceAnotherOrganization() throws {
        let account = browserAccount()
        let saved = try credential().encoded()
        let secrets = GreptileFixtureSecrets(values: [ProviderConfigurationStore.keychainAccount(for: account): saved])
        let suite = "GreptileRenewalRegressionTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secrets)
        XCTAssertTrue(store.canReconnectGreptile(credential(), for: account))
        XCTAssertFalse(store.canReconnectGreptile(credential(organization: "another-org"), for: account))
        XCTAssertFalse(store.canReconnectGreptile(credential(subject: "another-user"), for: account))
        XCTAssertEqual(try secrets.readSecret(account: ProviderConfigurationStore.keychainAccount(for: account)), saved)
    }

    @MainActor
    func testUnverifiedSessionCannotReuseAnotherAccountsRenewal() async throws {
        let fixture = GreptileHTTPFixture([try identity(subject: "another-user")])
        defer { fixture.invalidate() }
        let account = browserAccount()
        let previous = ProviderUsageResult(
            accountID: account.id, providerID: .greptile, title: account.displayName, subtitle: "Previous account", bars: [],
            greptileAllowanceRenewal: GreptileAllowanceRenewal(renewsAt: now.addingTimeInterval(600), observedAt: now),
            cacheIdentity: credential().cacheIdentity, fetchedAt: now
        )
        let service = UsageRefreshService(providers: [try provider(fixture, credential: credential())], initialResults: [previous])
        await service.refresh(configurations: [account])
        XCTAssertNil(service.results.first?.greptileAllowanceRenewal?.renewsAt)
        XCTAssertNotNil(service.results.first?.failureMessage)
    }

    @MainActor
    func testFreshRenewalDoesNotMakeFailedReviewHistoryCurrent() async throws {
        let fixture = GreptileHTTPFixture([
            try identity(), .payload(try billing(["kind": "free", "currentPeriod": ["end": "2030-02-01T00:00:00Z"]])),
            try GreptileHTTPFixture.page(["first"], total: 1),
            try identity(), .payload(try billing(["kind": "free", "currentPeriod": ["end": "2030-03-01T00:00:00Z"]])),
            .payload(Data("{}".utf8), status: 503),
        ])
        defer { fixture.invalidate() }
        let service = UsageRefreshService(providers: [try provider(fixture, credential: credential())])
        let account = browserAccount()
        await service.refresh(configurations: [account])
        let original = try XCTUnwrap(service.results.first?.greptileAllowanceRenewal?.renewsAt)
        await service.refresh(configurations: [account])
        let result = try XCTUnwrap(service.results.first)
        XCTAssertEqual(result.bars.first?.used, 1)
        XCTAssertFalse(result.hasCurrentBars)
        XCTAssertTrue(result.subtitle.contains("last known data"))
        XCTAssertNotEqual(result.greptileAllowanceRenewal?.renewsAt, original)
        XCTAssertEqual(result.greptileAllowanceRenewal?.isStale, false)
    }

    @MainActor
    func testRefreshFailurePreservesStaleDateAndNextSuccessReplacesIt() async throws {
        let first = try billing(["kind": "free", "currentPeriod": ["end": "2030-02-01T00:00:00Z"]])
        let next = try billing(["kind": "free", "currentPeriod": ["end": "2030-03-01T00:00:00Z"]])
        let fixture = GreptileHTTPFixture([
            try identity(), .payload(first), try GreptileHTTPFixture.page(["first"], total: 1),
            .failure(URLError(.notConnectedToInternet)),
            try identity(), .payload(next), try GreptileHTTPFixture.page(["first"], total: 1),
        ])
        defer { fixture.invalidate() }
        let service = UsageRefreshService(providers: [try provider(fixture, credential: credential())])
        let account = browserAccount()
        await service.refresh(configurations: [account])
        let original = try XCTUnwrap(service.results.first?.greptileAllowanceRenewal)
        await service.refresh(configurations: [account])
        XCTAssertEqual(service.results.first?.greptileAllowanceRenewal?.renewsAt, original.renewsAt)
        XCTAssertEqual(service.results.first?.greptileAllowanceRenewal?.isStale, true)
        XCTAssertEqual(service.results.first?.recoveryAction, .retryRefresh)
        await service.refresh(configurations: [account])
        XCTAssertNotEqual(service.results.first?.greptileAllowanceRenewal?.renewsAt, original.renewsAt)
        XCTAssertEqual(service.results.first?.greptileAllowanceRenewal?.isStale, false)
        XCTAssertNil(service.results.first?.failureMessage)
    }

    @MainActor
    func testLegacyAndUnreadableSavedSecretsCannotBeReplaced() throws {
        for method in [ProviderAuthMethod.apiKey, .browserSession] {
            var account = browserAccount()
            account.authMethod = method
            let secrets = GreptileFixtureSecrets(values: [ProviderConfigurationStore.keychainAccount(for: account): "synthetic-legacy-key"])
            let suite = "GreptileRenewalRegressionTests.\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secrets)
            XCTAssertFalse(store.canReconnectGreptile(credential(), for: account))
            XCTAssertTrue(store.lastError?.contains(method == .apiKey ? "separate" : "could not be read") == true)
            XCTAssertEqual(try secrets.readSecret(account: ProviderConfigurationStore.keychainAccount(for: account)), "synthetic-legacy-key")
        }
    }

    @MainActor
    func testBillingFailureKeepsLastKnownDateWithFreshReviewHistory() async throws {
        let fixture = GreptileHTTPFixture([
            try identity(), .payload(try billing(["kind": "free", "currentPeriod": ["end": "2030-02-01T00:00:00Z"]])),
            try GreptileHTTPFixture.page(["first"], total: 1),
            try identity(), .failure(URLError(.notConnectedToInternet)),
            try GreptileHTTPFixture.page(["first", "second"], total: 2),
            try identity(), .payload(Data("not-json".utf8)),
            try GreptileHTTPFixture.page(["first", "second"], total: 2),
            try identity(), .payload(try billing(["kind": "free", "currentPeriod": ["end": "2030-02-01T00:00:00Z"]])),
            try GreptileHTTPFixture.page(["first", "second"], total: 2),
            try identity(), .payload(try billing(["kind": "free"])),
            try GreptileHTTPFixture.page(["first", "second"], total: 2),
        ])
        defer { fixture.invalidate() }
        let service = UsageRefreshService(providers: [try provider(fixture, credential: credential())])
        let account = browserAccount()
        await service.refresh(configurations: [account])
        let original = try XCTUnwrap(service.results.first?.greptileAllowanceRenewal?.renewsAt)
        let refreshed = await service.refresh(configuration: account)
        XCTAssertEqual(refreshed?.greptileAllowanceRenewal?.renewsAt, original)
        XCTAssertEqual(refreshed?.greptileAllowanceRenewal?.isStale, true)
        XCTAssertEqual(refreshed?.bars.first?.used, 2)
        XCTAssertNil(refreshed?.failureMessage)
        await service.refresh(configurations: [account])
        XCTAssertNil(service.results.first?.greptileAllowanceRenewal?.renewsAt)
        XCTAssertEqual(service.results.first?.greptileAllowanceRenewal?.requiresAuthentication, false)
        await service.refresh(configurations: [account])
        XCTAssertEqual(service.results.first?.greptileAllowanceRenewal?.renewsAt, original)
        await service.refresh(configurations: [account])
        XCTAssertNil(service.results.first?.greptileAllowanceRenewal?.renewsAt)
        XCTAssertEqual(service.results.first?.greptileAllowanceRenewal?.requiresAuthentication, false)
    }

    func testBrowserRequestCancellationPropagatesFromEveryEndpoint() async throws {
        let prefixes: [[GreptileHTTPFixture.Reply]] = [
            [], [try identity()],
            [try identity(), .payload(try billing(["kind": "free"]))],
        ]
        for prefix in prefixes {
            let fixture = GreptileHTTPFixture(prefix + [.failure(URLError(.cancelled))])
            defer { fixture.invalidate() }
            do {
                _ = try await provider(fixture, credential: credential()).fetchUsage(for: browserAccount())
                XCTFail("Cancellation must propagate")
            } catch is CancellationError {
                XCTAssertEqual(fixture.requests.count, prefix.count + 1)
            }
        }
    }

    @MainActor
    func testCanceledRefreshDoesNotReplaceDashboardData() async throws {
        let fixture = GreptileHTTPFixture([
            try identity(), .payload(try billing(["kind": "free", "currentPeriod": ["end": "2030-02-01T00:00:00Z"]])),
            try GreptileHTTPFixture.page(["first"], total: 1),
            .failure(URLError(.cancelled)), .failure(URLError(.cancelled)),
        ])
        defer { fixture.invalidate() }
        let service = UsageRefreshService(providers: [try provider(fixture, credential: credential())])
        let account = browserAccount()
        await service.refresh(configurations: [account])
        let original = service.results.first?.greptileAllowanceRenewal
        let canceled = await service.refresh(configuration: account)
        XCTAssertNil(canceled)
        await service.refresh(configurations: [account])
        XCTAssertEqual(service.results.first?.greptileAllowanceRenewal, original)
        XCTAssertNil(service.results.first?.failureMessage)
        XCTAssertTrue(service.refreshErrorsByAccountID.isEmpty)
        XCTAssertFalse(service.isRefreshing)
    }

    @MainActor
    func testExpiredSessionsRetainDateAndRequireReconnect() async throws {
        let expiry = GreptileHTTPFixture.Reply.payload(Data("{}".utf8), status: 401)
        let replies: [[GreptileHTTPFixture.Reply]] = [
            [expiry], [try identity(), expiry, try GreptileHTTPFixture.page(["current"], total: 1)],
        ]
        let scenarios = replies.flatMap { response in [true, false].map { (response, $0) } }
        for (response, isFree) in scenarios {
            let fixture = GreptileHTTPFixture(response)
            defer { fixture.invalidate() }
            let account = browserAccount()
            let original = GreptileAllowanceRenewal(
                renewsAt: isFree ? now.addingTimeInterval(600) : nil, observedAt: now, isApplicable: isFree
            )
            let previous = ProviderUsageResult(
                accountID: account.id, providerID: .greptile, title: account.displayName, subtitle: "Verified", bars: [],
                greptileAllowanceRenewal: original, cacheIdentity: credential().cacheIdentity, fetchedAt: now
            )
            let service = UsageRefreshService(providers: [try provider(fixture, credential: credential())], initialResults: [previous])
            await service.refresh(configurations: [account])
            let result = try XCTUnwrap(service.results.first?.greptileAllowanceRenewal)
            XCTAssertEqual(result.renewsAt, original.renewsAt)
            XCTAssertTrue(result.isStale)
            XCTAssertTrue(result.requiresAuthentication)
            XCTAssertEqual(result.isApplicable, isFree)
        }
    }

    @MainActor
    func testCancellationRetainsPreviousRefreshFailure() async throws {
        let fixture = GreptileHTTPFixture([
            .failure(URLError(.notConnectedToInternet)), .failure(URLError(.cancelled)), .failure(URLError(.cancelled)),
        ])
        defer { fixture.invalidate() }
        let service = UsageRefreshService(providers: [try provider(fixture, credential: credential())])
        let account = browserAccount()
        await service.refresh(configurations: [account])
        let original = try XCTUnwrap(service.refreshErrorsByAccountID[account.id])
        _ = await service.refresh(configuration: account)
        XCTAssertEqual(service.refreshErrorsByAccountID[account.id], original)
        await service.refresh(configurations: [account])
        XCTAssertEqual(service.refreshErrorsByAccountID[account.id], original)
        XCTAssertEqual(service.lastRefreshError, original)
        XCTAssertTrue(service.successfulRefreshResults.isEmpty)
    }

    func testMalformedIdentityDoesNotRequestReauthentication() async throws {
        for payload in ["not-json", "{}", #"{"user":{"greptileId":"fixture-user"}}"#] {
            let fixture = GreptileHTTPFixture([.payload(Data(payload.utf8))])
            defer { fixture.invalidate() }
            let result = try await provider(fixture, credential: credential()).fetchUsage(for: browserAccount())
            XCTAssertEqual(result.recoveryAction, .retryRefresh)
            XCTAssertEqual(result.greptileAllowanceRenewal?.requiresAuthentication, false)
            XCTAssertEqual(fixture.requests.count, 1)
        }
        let fixture = GreptileHTTPFixture([.payload(Data(#"{"user":null}"#.utf8))])
        defer { fixture.invalidate() }
        let result = try await provider(fixture, credential: credential()).fetchUsage(for: browserAccount())
        XCTAssertEqual(result.recoveryAction, .reauthenticate)
    }

    @MainActor
    func testUnknownBillingDoesNotAssumeFreeOrReplaceCachedPaidClassification() async throws {
        for reply in [GreptileHTTPFixture.Reply.failure(URLError(.timedOut)), .payload(Data("malformed".utf8))] {
            let fixture = GreptileHTTPFixture([try identity(), reply, try GreptileHTTPFixture.page([], total: 0)])
            defer { fixture.invalidate() }
            let account = browserAccount()
            let provider = try provider(fixture, credential: credential())
            let previous = ProviderUsageResult(
                accountID: account.id, providerID: .greptile, title: account.displayName, subtitle: "Verified paid", bars: [],
                greptileAllowanceRenewal: GreptileAllowanceRenewal(renewsAt: nil, observedAt: now, isApplicable: false),
                cacheIdentity: credential().cacheIdentity, fetchedAt: now
            )
            let service = UsageRefreshService(providers: [provider], initialResults: [previous])
            await service.refresh(configurations: [account])
            XCTAssertEqual(service.results.first?.greptileAllowanceRenewal?.isApplicable, false)
            XCTAssertNil(service.results.first?.greptileAllowanceRenewal?.renewsAt)
            let firstLookup = GreptileHTTPFixture([try identity(), reply, try GreptileHTTPFixture.page([], total: 0)])
            defer { firstLookup.invalidate() }
            let result = try await self.provider(firstLookup, credential: credential()).fetchUsage(for: account)
            XCTAssertNil(result.greptileAllowanceRenewal?.isApplicable)
        }
    }

    func testEmptyOrganizationIdentifiersRejectIdentityBeforeConnection() async throws {
        for organization in ["", "   "] {
            let fixture = GreptileHTTPFixture([try identity(organization: organization)])
            defer { fixture.invalidate() }
            let client = GreptileDashboardClient(session: fixture.session, baseURL: fixture.endpoint)
            do {
                _ = try await client.identity(cookies: credential().cookies)
                XCTFail("An unusable organization must not be offered for connection.")
            } catch {
                XCTAssertEqual(error as? GreptileSignInError, .invalidIdentityResponse)
            }
            XCTAssertEqual(fixture.requests.count, 1)
        }
    }

    func testIdentityCredentialsRejectBlankFieldsAndNormalizeSurroundingWhitespace() async throws {
        for blank in ["", "   ", "\n\t"] {
            for (reply, subject) in [(try identity(subject: blank), blank), (try identity(token: blank), "fixture-user")] {
                let fixture = GreptileHTTPFixture([reply])
                defer { fixture.invalidate() }
                let client = GreptileDashboardClient(session: fixture.session, baseURL: fixture.endpoint)
                do {
                    try await client.verifyConnection(for: credential(subject: subject))
                    XCTFail("Blank identity credentials must be rejected before billing or connection.")
                } catch {
                    XCTAssertEqual(error as? GreptileSignInError, .invalidIdentityResponse)
                }
                XCTAssertEqual(fixture.requests.count, 1)
            }
        }
        let fixture = GreptileHTTPFixture([try identity(subject: " fixture-user\n", token: "\t synthetic-user-token ")])
        defer { fixture.invalidate() }
        let client = GreptileDashboardClient(session: fixture.session, baseURL: fixture.endpoint)
        let normalized = try await client.verifiedIdentity(for: credential())
        XCTAssertEqual(normalized.greptileId, "fixture-user")
        XCTAssertEqual(normalized.greptileToken, "synthetic-user-token")
    }

    func testPaidBillingDoesNotExposeAFreeRenewal() async throws {
        let fixture = GreptileHTTPFixture([
            try identity(), .payload(try billing(["kind": "paid", "currentPeriod": ["end": "2030-02-01T00:00:00Z"]])),
            try GreptileHTTPFixture.page(["current"], total: 1),
        ])
        defer { fixture.invalidate() }
        let result = try await provider(fixture, credential: credential()).fetchUsage(for: browserAccount())
        XCTAssertEqual(result.greptileAllowanceRenewal?.isApplicable, false)
        XCTAssertNil(result.greptileAllowanceRenewal?.renewsAt)
        XCTAssertEqual(result.bars.first?.used, 1)
    }

    @MainActor
    func testCredentialPublicationIdentifiesDisconnectAndAccountReplacement() throws {
        let secrets = GreptileWritableFixtureSecrets()
        let suite = "GreptileRenewalRegressionTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secrets)
        let account = try XCTUnwrap(store.addAccount(for: .greptile))
        var updates: [Bool] = []
        let observer = store.greptileCredentialUpdates.sink { update in
            XCTAssertEqual(update.accountID, account.id)
            updates.append(update.identityChanged)
        }
        defer { observer.cancel() }
        XCTAssertTrue(store.replaceCredential(try credential().encoded(), for: account))
        XCTAssertTrue(store.replaceCredential(try credential().encoded(), for: account))
        secrets.rejectNextSave()
        XCTAssertFalse(store.replaceCredential(try credential(organization: "another-org").encoded(), for: account))
        XCTAssertEqual(updates, [true, false])
        XCTAssertEqual(try secrets.readSecret(account: ProviderConfigurationStore.keychainAccount(for: account)), try credential().encoded())
        try secrets.deleteSecret(account: ProviderConfigurationStore.keychainAccount(for: account))
        XCTAssertTrue(store.canReconnectGreptile(credential(organization: "another-org"), for: account))
        XCTAssertTrue(store.replaceCredential(try credential(organization: "another-org").encoded(), for: account))
        XCTAssertEqual(updates, [true, false, true])
    }
}

private final class GreptileWritableFixtureSecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var rejectsSave = false
    func rejectNextSave() { lock.withLock { rejectsSave = true } }
    func readSecret(account: String) throws -> String? { lock.withLock { values[account] } }
    func saveSecret(_ secret: String, account: String) throws {
        try lock.withLock {
            if rejectsSave { rejectsSave = false; throw URLError(.cannotWriteToFile) }
            values[account] = secret
        }
    }
    func deleteSecret(account: String) throws { _ = lock.withLock { values.removeValue(forKey: account) } }
}
