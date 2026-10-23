import CryptoKit
import Foundation
import XCTest
@testable import CodexBarIOS

final class GrokTransportTests: XCTestCase, @unchecked Sendable {
    func testDeviceApprovalVerifiesIdentityWithoutSendingCookiesOrKeys() async throws {
        let service = makeService([
            (200, #"{"device_code":"synthetic","verification_uri_complete":"https://accounts.x.ai/oauth2/device?user_code=TEST","expires_in":1800,"interval":5}"#),
            (400, #"{"error":"authorization_pending"}"#),
            (400, #"{"error":"slow_down"}"#),
            (429, "{}"),
            (503, "{}"),
            (200, "{not-json"),
            (400, "{not-json"),
            (0, ""),
            (200, #"{"access_token":"access-one","refresh_token":"refresh-one","token_type":"Bearer","expires_in":3600}"#),
            (0, ""),
            (429, "{}"),
            (503, "{}"),
            (200, "{not-json"),
            (200, #"{"sub":"subject-one","email":"fixture@example.invalid"}"#),
        ])
        defer { service.session.invalidateAndCancel() }
        let challenge = try await service.begin()
        let delays = GrokDelayRecorder()
        let credential = try await service.authorize(challenge, sleep: { await delays.record($0) })
        XCTAssertEqual(credential.subject, "subject-one")
        XCTAssertEqual(credential.email, "fixture@example.invalid")
        let recordedDelays = await delays.values
        XCTAssertEqual(recordedDelays, [5, 5, 10, 15, 20, 25, 30, 35, 5, 10, 15, 20])
        let requests = GrokTestProtocol.state.requests
        XCTAssertEqual(requests.map { $0.url?.path }, [
            "/oauth2/device/code", "/oauth2/token", "/oauth2/token", "/oauth2/token",
            "/oauth2/token", "/oauth2/token", "/oauth2/token", "/oauth2/token",
            "/oauth2/token", "/oauth2/userinfo", "/oauth2/userinfo",
            "/oauth2/userinfo", "/oauth2/userinfo", "/oauth2/userinfo",
        ])
        XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer access-one")
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == nil })
        XCTAssertTrue(requests.allSatisfy { $0.url?.host == "auth.x.ai" })
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        XCTAssertTrue(GrokDeviceAuthService.scope.contains("api:access"))
    }

    func testRefusalStopsWithoutIdentityOrBilling() async throws {
        let service = makeService([(400, #"{"error":"access_denied"}"#)])
        defer { service.session.invalidateAndCancel() }
        let challenge = GrokDeviceChallenge(
            code: "synthetic", approvalURL: URL(string: "https://accounts.x.ai/oauth2/device")!,
            expiresAt: Date().addingTimeInterval(1800), interval: 5
        )
        do {
            _ = try await service.authorize(challenge, sleep: { _ in })
            XCTFail("A refusal must stop authorization")
        } catch GrokAuthError.denied {
            XCTAssertEqual(GrokTestProtocol.state.requests.count, 1)
        }
    }

    func testCandidateRequiresMatchingVerifiedSubjectBeforeReadingBilling() async throws {
        let credential = GrokCredential(
            kind: "grok-oauth-v1", accessToken: "access-one", refreshToken: "refresh-one",
            expiresAt: Date().addingTimeInterval(3600), subject: "subject-one", email: nil
        )
        let session = makeSession([(200, #"{"sub":"subject-two"}"#)])
        defer { session.invalidateAndCancel() }
        let provider = GrokUsageProvider(session: session)
        do {
            _ = try await provider.fetchCandidate(credential, for: .defaultConfiguration(for: .grok))
            XCTFail("A changed identity must not fetch another account's usage")
        } catch GrokAuthError.unauthorized {
            XCTAssertEqual(GrokTestProtocol.state.requests.count, 1)
        }
    }

    func testCandidateVerificationRetriesTransientIdentityAndBillingFailuresWithoutRepeatingApproval() async throws {
        let credential = GrokCredential(
            kind: "grok-oauth-v1", accessToken: "issued-token", refreshToken: "issued-refresh",
            expiresAt: Date().addingTimeInterval(3600), subject: "subject-one", email: nil
        )
        let session = makeSession([
            (503, "{}"),
            (200, #"{"sub":"subject-one"}"#), (0, ""),
            (200, #"{"sub":"subject-one"}"#), (200, "{not-json"),
            (200, #"{"sub":"subject-one"}"#), (200, #"{"config":{}}"#),
        ])
        defer { session.invalidateAndCancel() }
        let delays = GrokDelayRecorder()
        let result = try await GrokUsageProvider(session: session).verifyCandidate(
            credential, for: .defaultConfiguration(for: .grok), retryUntil: Date().addingTimeInterval(120),
            sleep: { await delays.record($0) }
        )
        XCTAssertNil(result.failureMessage)
        let recordedDelays = await delays.values
        XCTAssertEqual(recordedDelays, [5, 10, 15])
        XCTAssertEqual(GrokTestProtocol.state.requests.map { $0.url?.host }, [
            "auth.x.ai", "auth.x.ai", "cli-chat-proxy.grok.com", "auth.x.ai",
            "cli-chat-proxy.grok.com", "auth.x.ai", "cli-chat-proxy.grok.com",
            "cli-chat-proxy.grok.com",
        ])
    }

    func testSettingsTierComesFromVerifiedAccountNotBillingPayload() async throws {
        let credential = GrokCredential(
            kind: "grok-oauth-v1", accessToken: "access", refreshToken: "refresh",
            expiresAt: Date().addingTimeInterval(3600), subject: "subject-one", email: nil
        )
        let formatter = ISO8601DateFormatter()
        let start = formatter.string(from: Date().addingTimeInterval(-86_400))
        let end = formatter.string(from: Date().addingTimeInterval(86_400))
        let session = makeSession([
            (200, #"{"sub":"subject-one"}"#),
            (200, """
                {"config":{"isUnifiedBillingUser":true,"subscriptionTier":"SuperGrok Heavy",
                "currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"\(start)","end":"\(end)"},
                "prepaidBalance":{"val":500}}}
                """),
            (200, #"{"subscription_tier_display":"  ","subscription_tier":"SuperGrok Lite"}"#),
        ])
        defer { session.invalidateAndCancel() }
        let result = try await GrokUsageProvider(session: session).fetchCandidate(
            credential, for: .defaultConfiguration(for: .grok)
        )
        XCTAssertEqual(result.verifiedGrokPlanName, "SuperGrok Lite")
        XCTAssertTrue(result.bars.isEmpty)
        XCTAssertEqual(result.monetaryMetrics.map(\.minorUnits), [500])
        XCTAssertEqual(GrokTestProtocol.state.requests.map { $0.url?.path }, [
            "/oauth2/userinfo", "/v1/billing", "/v1/settings",
        ])
        XCTAssertTrue(GrokTestProtocol.state.requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Cookie") == nil
        })
    }

    @MainActor
    func testXSubscriptionReadsTheSameVerifiedEndpointsWithoutBillingSignIn() async throws {
        let suite = "GrokAuthTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = GrokTestSecrets()
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secrets, widgetSnapshotDefaults: defaults)
        let account = try XCTUnwrap(store.addAccount(for: .xSubscription))
        let credential = GrokCredential(
            kind: "grok-oauth-v1", accessToken: "access", refreshToken: "refresh",
            expiresAt: Date().addingTimeInterval(3600), subject: "subject-one", email: nil
        )
        XCTAssertTrue(store.replaceCredential(try credential.encoded(), for: account))
        let formatter = ISO8601DateFormatter()
        let start = formatter.string(from: Date().addingTimeInterval(-86_400))
        let end = formatter.string(from: Date().addingTimeInterval(86_400))
        let billing = """
            {"config":{"creditUsagePercent":38,"prepaidBalance":{"val":1250},
            "currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"\(start)","end":"\(end)"},
            "productUsage":[{"product":"PRODUCT_CURSOR","usagePercent":21}]}}
            """
        for (settings, plan, hasPool) in [
            (#"{"subscription_tier_display":"Premium"}"#, "Premium", true),
            (#"{"subscription_tier_display":"X Premium+"}"#, nil, true),
            // A unified account may still report a legacy tier; it never hides the pool.
            (#"{"subscription_tier":"SuperGrok"}"#, nil, true),
        ] as [(String, String?, Bool)] {
            let session = makeSession([(200, #"{"sub":"subject-one"}"#), (200, billing), (200, settings)])
            defer { session.invalidateAndCancel() }
            let provider = GrokUsageProvider(providerID: .xSubscription, secretStore: secrets, session: session)
            XCTAssertEqual(provider.providerID, .xSubscription)
            let result = try await provider.fetchUsage(for: account)
            XCTAssertNil(result.failureMessage, settings)
            XCTAssertEqual(result.providerID, .xSubscription)
            XCTAssertEqual(result.verifiedGrokPlanName, plan, settings)
            XCTAssertEqual(result.bars.first?.used, hasPool ? 38 : nil, settings)
            XCTAssertEqual(result.bars.first?.resetsAt, hasPool ? formatter.date(from: end) : nil, settings)
            XCTAssertNil(result.subscriptionRenewal)
            XCTAssertEqual(GrokTestProtocol.state.requests.map { $0.url?.path }, [
                "/oauth2/userinfo", "/v1/billing", "/v1/settings",
            ])
        }
        let missing = try XCTUnwrap(store.addAccount(for: .xSubscription))
        let signIn = try await GrokUsageProvider(providerID: .xSubscription, secretStore: secrets).fetchUsage(for: missing)
        XCTAssertEqual(signIn.failureMessage, "Sign in with xAI to see X Subscription usage.")
        XCTAssertEqual(signIn.providerID, .xSubscription)
    }

    func testCandidateVerificationDoesNotRetryAChangedIdentity() async throws {
        let credential = GrokCredential(
            kind: "grok-oauth-v1", accessToken: "issued-token", refreshToken: "issued-refresh",
            expiresAt: Date().addingTimeInterval(3600), subject: "subject-one", email: nil
        )
        let session = makeSession([(200, #"{"sub":"subject-two"}"#)])
        defer { session.invalidateAndCancel() }
        let delays = GrokDelayRecorder()
        do {
            _ = try await GrokUsageProvider(session: session).verifyCandidate(
                credential, for: .defaultConfiguration(for: .grok), retryUntil: Date().addingTimeInterval(120),
                sleep: { await delays.record($0) }
            )
            XCTFail("A different identity must not be retried or accepted")
        } catch GrokAuthError.unauthorized {
            XCTAssertEqual(GrokTestProtocol.state.requests.count, 1)
            let recordedDelays = await delays.values
            XCTAssertEqual(recordedDelays, [])
        }
        let expired = makeSession([(503, "{}")])
        defer { expired.invalidateAndCancel() }
        do {
            _ = try await GrokUsageProvider(session: expired).verifyCandidate(
                credential, for: .defaultConfiguration(for: .grok), retryUntil: .distantPast,
                sleep: { _ in XCTFail("Retry must stop at its deadline") }
            )
            XCTFail("A provider outage must not be mistaken for verified usage")
        } catch GrokAuthError.temporarilyUnavailable {
            XCTAssertEqual(GrokTestProtocol.state.requests.count, 1)
        }
    }

    func testCandidateReportsTemporaryProviderOutageWithoutSavingAConnection() async throws {
        let credential = GrokCredential(
            kind: "grok-oauth-v1", accessToken: "access", refreshToken: "refresh",
            expiresAt: Date().addingTimeInterval(3600), subject: "subject", email: nil
        )
        let session = makeSession([(200, #"{"sub":"subject"}"#), (503, "{}")])
        defer { session.invalidateAndCancel() }
        let provider = GrokUsageProvider(session: session)
        do {
            _ = try await provider.fetchCandidate(credential, for: .defaultConfiguration(for: .grok))
            XCTFail("A provider outage is not an unsupported account")
        } catch GrokAuthError.temporarilyUnavailable {
            XCTAssertEqual(GrokTestProtocol.state.requests.count, 2)
        }
        let identityOutage = makeSession([(503, "{}")])
        defer { identityOutage.invalidateAndCancel() }
        do {
            _ = try await GrokUsageProvider(session: identityOutage)
                .fetchCandidate(credential, for: .defaultConfiguration(for: .grok))
            XCTFail("A userinfo outage is not rejected authorization")
        } catch GrokAuthError.temporarilyUnavailable {
            XCTAssertEqual(GrokTestProtocol.state.requests.count, 1)
        }
    }

    @MainActor
    func testOptionalTierFailuresRetainOnlyTheSameVerifiedSubjectsPlan() async throws {
        let account = ProviderAccountConfiguration.defaultConfiguration(for: .grok)
        let secrets = GrokTestSecrets()
        let credential = GrokCredential(
            kind: "grok-oauth-v1", accessToken: "synthetic", refreshToken: "synthetic-refresh",
            expiresAt: Date().addingTimeInterval(3600), subject: "subject-one", email: nil
        )
        try secrets.saveSecret(credential.encoded(), account: ProviderConfigurationStore.keychainAccount(for: account))
        let formatter = ISO8601DateFormatter()
        let start = formatter.string(from: Date().addingTimeInterval(-86_400))
        let end = formatter.string(from: Date().addingTimeInterval(86_400))
        let billing = """
            {"config":{"isUnifiedBillingUser":true,"creditUsagePercent":31,
            "currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"\(start)","end":"\(end)"}}}
            """
        for singleAccount in [false, true] {
            for sameSubject in [false, true] {
                let cached = try GrokUsageProvider.parseCredits(
                    Data(billing.replacingOccurrences(of: ":31", with: ":11").utf8), configuration: account,
                    subject: sameSubject ? "subject-one" : "another-subject", now: Date(), verifiedPlanName: "SuperGrok Lite"
                )
                for firstStatus in [400, 401, 402, 408, 425, 503] {
                    let retainsTier = sameSubject && ![401, 402].contains(firstStatus)
                    let chainedSession = makeSession([
                        (200, #"{"sub":"subject-one"}"#), (firstStatus, "{}"),
                        (200, #"{"sub":"subject-one"}"#), (200, billing), (503, "{}"),
                    ])
                    let chained = UsageRefreshService(
                        providers: [GrokUsageProvider(secretStore: secrets, session: chainedSession)], initialResults: [cached]
                    )
                    if singleAccount { _ = await chained.refresh(configuration: account) } else { await chained.refresh(configurations: [account]) }
                    let stale = try XCTUnwrap(chained.results.first)
                    XCTAssertEqual(stale.cardPlan.displayLabel, retainsTier ? "SuperGrok Lite" : "Plan unavailable")
                    XCTAssertEqual(stale.bars.map(\.used), retainsTier ? [11] : [])
                    XCTAssertEqual(stale.cacheIdentity, [401, 402].contains(firstStatus) ? nil
                        : Data(SHA256.hash(data: Data("subject-one".utf8))).base64EncodedString())
                    if singleAccount { _ = await chained.refresh(configuration: account) } else { await chained.refresh(configurations: [account]) }
                    let restored = try XCTUnwrap(chained.results.first)
                    XCTAssertEqual(restored.cardPlan.displayLabel, retainsTier ? "SuperGrok Lite" : "Plan unavailable")
                    XCTAssertEqual(restored.bars.first?.used, 31)
                    XCTAssertNil(restored.failureMessage)
                    XCTAssertEqual(GrokTestProtocol.state.requests.count, 5)
                    chainedSession.invalidateAndCancel()
                }
                for (status, settings, unavailable, freshTier) in [
                    (0, "", true, "Plan unavailable"),
                    (503, "{}", true, "Plan unavailable"),
                    (403, "{}", true, "Plan unavailable"),
                    (200, "not-json", true, "Plan unavailable"),
                    (200, #"{"subscription_tier":123}"#, true, "Plan unavailable"),
                    (200, "{}", false, "Plan unavailable"),
                    (200, #"{"subscription_tier":"Unknown future tier"}"#, false, "Plan unavailable"),
                    (200, #"{"subscription_tier_display":"SuperGrok Heavy"}"#, false, "SuperGrok Heavy"),
                    (200, #"{"subscription_tier_display":"","subscription_tier":"SuperGrok Lite"}"#, false, "SuperGrok Lite"),
                    (200, #"{"subscription_tier_display":"  ","subscription_tier":"SuperGrok Plus"}"#, false, "SuperGrok Plus"),
                    (200, #"{"subscription_tier_display":"Unknown","subscription_tier":"SuperGrok"}"#, false, "SuperGrok"),
                    (200, #"{"subscription_tier_display":"SuperGrok Heavy","subscription_tier":"SuperGrok Lite"}"#, false, "SuperGrok Heavy"),
                ] {
                    let session = makeSession([(200, #"{"sub":"subject-one"}"#), (200, billing), (status, settings)])
                    let service = UsageRefreshService(
                        providers: [GrokUsageProvider(secretStore: secrets, session: session)], initialResults: [cached]
                    )
                    if singleAccount {
                        _ = await service.refresh(configuration: account)
                    } else {
                        await service.refresh(configurations: [account])
                    }
                    let result = try XCTUnwrap(service.results.first)
                    XCTAssertEqual(result.cardPlan.displayLabel, unavailable && sameSubject ? "SuperGrok Lite" : freshTier)
                    XCTAssertEqual(result.grokPlanLookupFailed, unavailable)
                    XCTAssertEqual(result.bars.first?.used, 31, "New billing must not be replaced by cached quota")
                    XCTAssertNil(result.failureMessage)
                    XCTAssertEqual(GrokTestProtocol.state.requests.count, 3)
                    session.invalidateAndCancel()
                }
            }
        }
        try await assertRetainedTierUsesOnlyFreshOmittedUsageEvidence(account: account, secrets: secrets, start: start, end: end)
    }

    @MainActor
    private func assertRetainedTierUsesOnlyFreshOmittedUsageEvidence(
        account: ProviderAccountConfiguration, secrets: GrokTestSecrets, start: String, end: String
    ) async throws {
        let cases: [((String, String), Bool, String?, String, [Double])] = [
            (("", "true"), true, "SuperGrok Lite", "subject-one", []),
            ((",\"creditUsagePercent\":31", "true"), true, "SuperGrok Lite", "subject-one", [31]),
            ((",\"creditUsagePercent\":null", "true"), true, "SuperGrok Lite", "subject-one", []),
            ((",\"productUsage\":[]", "true"), true, "SuperGrok Lite", "subject-one", []),
            (("", "false"), true, "SuperGrok Lite", "subject-one", []),
            (("", "true"), false, "SuperGrok Lite", "subject-one", []),
            (("", "true"), true, nil, "subject-one", []),
            (("", "true"), true, "SuperGrok Lite", "other-subject", []),
        ]
        for singleAccount in [false, true] {
            for ((usage, unified), unavailable, plan, subject, expected) in cases {
                let billing = """
                    {"config":{"isUnifiedBillingUser":\(unified)\(usage),"prepaidBalance":{"val":700},
                    "currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"\(start)","end":"\(end)"}}}
                    """
                let cached = ProviderUsageResult(
                    accountID: account.id, providerID: .grok, title: "Grok", verifiedGrokPlanName: plan,
                    subtitle: "Old usage", bars: [UsageBar(label: "Old weekly", used: 77, limit: 100, resetsAt: .distantPast)],
                    cacheIdentity: Data(SHA256.hash(data: Data(subject.utf8))).base64EncodedString(), fetchedAt: .distantPast
                )
                let session = makeSession([
                    (200, #"{"sub":"subject-one"}"#), (200, billing),
                    (unavailable ? 503 : 200, unavailable ? "{}" : #"{"subscription_tier":"Unknown"}"#),
                ])
                defer { session.invalidateAndCancel() }
                let service = UsageRefreshService(
                    providers: [GrokUsageProvider(secretStore: secrets, session: session)], initialResults: [cached]
                )
                if singleAccount { _ = await service.refresh(configuration: account) } else { await service.refresh(configurations: [account]) }
                let result = try XCTUnwrap(service.results.first)
                XCTAssertEqual(result.bars.map(\.used), expected, "Only fresh reported usage is visible")
                XCTAssertEqual(result.monetaryMetrics.map(\.minorUnits), unified == "true" ? [700] : [],
                               "Fresh extra credits must survive tier retention only for a verified unified account")
                XCTAssertNil(result.failureMessage)
                XCTAssertTrue(result.hasFreshBars)
                if expected == [0] {
                    XCTAssertEqual(result.bars.first?.resetsAt, ISO8601DateFormatter().date(from: end))
                    XCTAssertEqual(result.bars.first?.stableKey, "included-usage")
                    XCTAssertEqual(result.bars.first?.projectionPeriodStart, ISO8601DateFormatter().date(from: start))
                    XCTAssertTrue(result.usageMessages.contains { $0.contains("Inferred zero") })
                    XCTAssertTrue(result.subtitle.contains("No included usage reported"))
                }
                XCTAssertEqual(GrokTestProtocol.state.requests.count, 3)
            }
        }
    }

    @MainActor
    func testUnsupportedBillingDiscardsCachedPlanWhileOutagesKeepIt() async throws {
        let account = ProviderAccountConfiguration.defaultConfiguration(for: .grok)
        let secrets = GrokTestSecrets()
        let credential = GrokCredential(
            kind: "grok-oauth-v1", accessToken: "synthetic", refreshToken: "synthetic-refresh",
            expiresAt: Date().addingTimeInterval(3600), subject: "subject-one", email: nil
        )
        try secrets.saveSecret(credential.encoded(), account: ProviderConfigurationStore.keychainAccount(for: account))
        let cached = ProviderUsageResult(
            accountID: account.id, providerID: .grok, title: "Grok", verifiedGrokPlanName: "SuperGrok Lite",
            subtitle: "Synthetic", bars: [UsageBar(label: "Weekly", used: 31, limit: 100)],
            cacheIdentity: Data(SHA256.hash(data: Data("subject-one".utf8))).base64EncodedString(), fetchedAt: Date()
        )
        for status in [302, 400, 401, 402, 403, 404, 408, 409, 410, 422, 425, 429, 500, 503, 599] {
            let session = makeSession([(200, #"{"sub":"subject-one"}"#), (status, "{}")])
            let provider = GrokUsageProvider(secretStore: secrets, session: session)
            let service = UsageRefreshService(providers: [provider], initialResults: [cached])
            await service.refresh(configurations: [account])
            let result = try XCTUnwrap(service.results.first)
            let temporary = ![401, 402, 403, 404, 410].contains(status)
            XCTAssertEqual(result.cardPlan.displayLabel, temporary ? "SuperGrok Lite" : "Plan unavailable", "HTTP \(status)")
            XCTAssertEqual(result.bars.isEmpty, !temporary, "HTTP \(status)")
            XCTAssertNotNil(result.failureMessage)
            XCTAssertEqual(result.recoveryAction, [401, 403].contains(status) ? .reauthenticate : .retryRefresh)
            XCTAssertEqual(GrokTestProtocol.state.requests.count, 2)
            session.invalidateAndCancel()
        }
    }

    @MainActor
    func testTransientFailuresOfferRetryButRejectedTokensOfferReconnect() async throws {
        let suite = "GrokAuthTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = GrokTestSecrets()
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secrets, widgetSnapshotDefaults: defaults)
        let account = try XCTUnwrap(store.addAccount(for: .grok))
        let key = ProviderConfigurationStore.keychainAccount(for: account)
        let credential = GrokCredential(
            kind: "grok-oauth-v1", accessToken: "access", refreshToken: "refresh",
            expiresAt: Date().addingTimeInterval(3600), subject: "subject", email: nil
        )
        try secrets.saveSecret(credential.encoded(), account: key)
        let unavailable = makeSession([(429, "{}")])
        let retryUserInfo = try await GrokUsageProvider(secretStore: secrets, session: unavailable).fetchUsage(for: account)
        XCTAssertEqual(retryUserInfo.recoveryAction, .retryRefresh)
        unavailable.invalidateAndCancel()

        let billingOutage = makeSession([(200, #"{"sub":"subject"}"#), (503, "{}")])
        let retryBilling = try await GrokUsageProvider(secretStore: secrets, session: billingOutage).fetchUsage(for: account)
        XCTAssertEqual(retryBilling.recoveryAction, .retryRefresh)
        billingOutage.invalidateAndCancel()

        let rejected = makeSession([(401, "{}")])
        let reconnect = try await GrokUsageProvider(secretStore: secrets, session: rejected).fetchUsage(for: account)
        XCTAssertEqual(reconnect.recoveryAction, .reauthenticate)
        rejected.invalidateAndCancel()

        let nearExpiry = GrokCredential(
            kind: credential.kind, accessToken: credential.accessToken, refreshToken: credential.refreshToken,
            expiresAt: Date().addingTimeInterval(5), subject: credential.subject, email: nil
        )
        try secrets.saveSecret(nearExpiry.encoded(), account: key)
        let nearExpiryOutage = makeSession([(503, "{}"), (401, "{}")])
        let retryNearExpiry = try await GrokUsageProvider(secretStore: secrets, session: nearExpiryOutage)
            .fetchUsage(for: account)
        XCTAssertEqual(retryNearExpiry.recoveryAction, .retryRefresh)
        XCTAssertEqual(GrokTestProtocol.state.requests.count, 1)
        // Compare decoded credentials; JSONEncoder key order is not stable between calls.
        XCTAssertEqual(GrokCredential.parse(try secrets.readSecret(account: key)), nearExpiry)
        nearExpiryOutage.invalidateAndCancel()

        let expired = GrokCredential(
            kind: credential.kind, accessToken: credential.accessToken, refreshToken: credential.refreshToken,
            expiresAt: Date().addingTimeInterval(-10), subject: credential.subject, email: nil
        )
        try secrets.saveSecret(expired.encoded(), account: key)
        let renewalOutage = makeSession([(503, "{}")])
        let retryRenewal = try await GrokUsageProvider(secretStore: secrets, session: renewalOutage).fetchUsage(for: account)
        XCTAssertEqual(retryRenewal.recoveryAction, .retryRefresh)
        renewalOutage.invalidateAndCancel()

        for body in ["{not-json", #"{"error":"temporarily_unavailable"}"#, #"{"error":"invalid_client"}"#] {
            let response = makeSession([(400, body)])
            let retry = try await GrokUsageProvider(secretStore: secrets, session: response).fetchUsage(for: account)
            XCTAssertEqual(retry.recoveryAction, .retryRefresh)
            response.invalidateAndCancel()
        }
        let invalidGrant = makeSession([(400, #"{"error":"invalid_grant"}"#)])
        let reconnectGrant = try await GrokUsageProvider(secretStore: secrets, session: invalidGrant).fetchUsage(for: account)
        XCTAssertEqual(reconnectGrant.recoveryAction, .reauthenticate)
        invalidGrant.invalidateAndCancel()

        let malformedRenewal = makeSession([(200, "{not-json")])
        let retryMalformed = try await GrokUsageProvider(secretStore: secrets, session: malformedRenewal).fetchUsage(for: account)
        XCTAssertEqual(retryMalformed.recoveryAction, .retryRefresh)
        malformedRenewal.invalidateAndCancel()

        let rejectedRenewal = makeSession([
            (200, #"{"access_token":"renewed","token_type":"Bearer","expires_in":3600}"#),
            (401, "{}"),
        ])
        let reconnectRenewal = try await GrokUsageProvider(secretStore: secrets, session: rejectedRenewal).fetchUsage(for: account)
        XCTAssertEqual(reconnectRenewal.recoveryAction, .reauthenticate)
        rejectedRenewal.invalidateAndCancel()
    }

    @MainActor
    func testRenewalWithoutRotatedRefreshTokenKeepsSameAccountAndZeroUsage() async throws {
        let suite = "GrokAuthTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = GrokTestSecrets()
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secrets, widgetSnapshotDefaults: defaults)
        let account = try XCTUnwrap(store.addAccount(for: .grok))
        let key = ProviderConfigurationStore.keychainAccount(for: account)
        let old = GrokCredential(
            kind: "grok-oauth-v1", accessToken: "old-access", refreshToken: "old-refresh",
            expiresAt: Date().addingTimeInterval(-10), subject: "subject-one", email: nil
        )
        let start = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-86_400))
        let end = ISO8601DateFormatter().string(from: Date().addingTimeInterval(86_400))
        let billing = """
            {"config":{"isUnifiedBillingUser":true,"creditUsagePercent":0,
            "currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"\(start)","end":"\(end)"}}}
            """
        for renewal in [
            #"{"access_token":"new-access","token_type":"Bearer","expires_in":3600}"#,
            #"{"access_token":"new-access","token_type":"Bearer","expires_in":3600,"refresh_token":""}"#,
        ] {
            try secrets.saveSecret(old.encoded(), account: key)
            let session = makeSession([
                (200, renewal), (200, #"{"sub":"subject-one"}"#),
                (200, #"{"sub":"subject-one"}"#), (200, billing),
            ])
            defer { session.invalidateAndCancel() }
            let result = try await GrokUsageProvider(secretStore: secrets, session: session).fetchUsage(for: account)
            XCTAssertNil(result.failureMessage)
            XCTAssertEqual(result.bars.first?.used, 0)
            let saved = try XCTUnwrap(GrokCredential.parse(try secrets.readSecret(account: key)))
            XCTAssertEqual(saved.refreshToken, old.refreshToken)
            XCTAssertEqual(saved.subject, old.subject)
            XCTAssertEqual(saved.accessToken, "new-access")
            XCTAssertEqual(GrokTestProtocol.state.requests.last?.url?.host, "cli-chat-proxy.grok.com")
        }
    }

    @MainActor
    func testRotatedRefreshTokenSurvivesTransientIdentityFailure() async throws {
        let suite = "GrokAuthTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = GrokTestSecrets()
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secrets, widgetSnapshotDefaults: defaults)
        let account = try XCTUnwrap(store.addAccount(for: .grok))
        let key = ProviderConfigurationStore.keychainAccount(for: account)
        let old = GrokCredential(
            kind: "grok-oauth-v1", accessToken: "old-access", refreshToken: "old-refresh",
            expiresAt: Date().addingTimeInterval(-10), subject: "subject-one", email: nil
        )
        try secrets.saveSecret(old.encoded(), account: key)
        let session = makeSession([
            (200, #"{"access_token":"new-access","refresh_token":"new-refresh","token_type":"Bearer","expires_in":3600}"#),
            (503, "{}"), (200, #"{"sub":"subject-one"}"#),
            (200, #"{"sub":"subject-one"}"#), (200, #"{"config":{}}"#),
        ])
        defer { session.invalidateAndCancel() }
        let result = try await GrokUsageProvider(secretStore: secrets, session: session).fetchUsage(for: account)
        XCTAssertNil(result.failureMessage)
        let saved = try XCTUnwrap(GrokCredential.parse(try secrets.readSecret(account: key)))
        XCTAssertEqual(saved.accessToken, "new-access")
        XCTAssertEqual(saved.refreshToken, "new-refresh")
        XCTAssertEqual(saved.subject, old.subject)
        XCTAssertEqual(GrokTestProtocol.state.requests.map { $0.url?.path }, [
            "/oauth2/token", "/oauth2/userinfo", "/oauth2/userinfo", "/oauth2/userinfo", "/v1/billing",
            "/v1/settings",
        ])
    }

    @MainActor
    func testRemovalDuringBillingCannotPublishAnOldAccountResult() async throws {
        let suite = "GrokAuthTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = GrokTestSecrets()
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secrets, widgetSnapshotDefaults: defaults)
        let account = try XCTUnwrap(store.addAccount(for: .grok))
        let stored = GrokCredential(
            kind: "grok-oauth-v1", accessToken: "old-access", refreshToken: "old-refresh",
            expiresAt: Date().addingTimeInterval(3600), subject: "subject-one", email: nil
        )
        let key = ProviderConfigurationStore.keychainAccount(for: account)
        try secrets.saveSecret(stored.encoded(), account: key)
        let billingStarted = expectation(description: "billing request started")
        let allowBilling = DispatchSemaphore(value: 0)
        let session = makeSession([])
        GrokTestProtocol.state.reset(handler: { request in
            if request.url?.path == "/v1/billing" {
                billingStarted.fulfill()
                _ = allowBilling.wait(timeout: .now() + 5)
                return (200, #"{"config":{"creditUsagePercent":31}}"#)
            }
            return (200, #"{"sub":"subject-one"}"#)
        })
        defer { session.invalidateAndCancel() }
        let provider = GrokUsageProvider(secretStore: secrets, session: session)
        let task = Task { try await provider.fetchUsage(for: account) }
        await fulfillment(of: [billingStarted], timeout: 5)
        XCTAssertTrue(store.removeAccount(account))
        allowBilling.signal()
        let result = try await task.value
        XCTAssertNotNil(result.failureMessage)
        XCTAssertTrue(result.bars.isEmpty)
        XCTAssertNil(try secrets.readSecret(account: key))
    }

    @MainActor
    func testRemovalDuringRenewalCannotRestoreAnOldCredential() async throws {
        try await assertCredentialStaysRemovedDuringRenewal(resetAll: false)
    }

    @MainActor
    func testResetDuringRenewalCannotRestoreAnOldCredential() async throws {
        try await assertCredentialStaysRemovedDuringRenewal(resetAll: true)
    }

    @MainActor
    private func assertCredentialStaysRemovedDuringRenewal(resetAll: Bool) async throws {
        let suite = "GrokAuthTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = GrokTestSecrets()
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secrets, widgetSnapshotDefaults: defaults)
        let account = try XCTUnwrap(store.addAccount(for: .grok))
        var clearedHistory: [String] = []
        let subscription = store.grokHistoryInvalidations.sink { clearedHistory.append($0) }
        defer { subscription.cancel() }
        let stored = GrokCredential(
            kind: "grok-oauth-v1", accessToken: "old-access", refreshToken: "old-refresh",
            expiresAt: Date().addingTimeInterval(-10), subject: "subject-one", email: nil
        )
        let key = ProviderConfigurationStore.keychainAccount(for: account)
        try secrets.saveSecret(stored.encoded(), account: key)
        let refreshStarted = expectation(description: "renewal request started")
        let allowRefresh = DispatchSemaphore(value: 0)
        let session = makeSession([])
        GrokTestProtocol.state.reset(handler: { request in
            if request.url?.path == "/oauth2/token" {
                refreshStarted.fulfill()
                _ = allowRefresh.wait(timeout: .now() + 5)
                return (200, #"{"access_token":"new-access","refresh_token":"new-refresh","token_type":"Bearer","expires_in":3600}"#)
            }
            return (200, #"{"sub":"subject-one"}"#)
        })
        defer { session.invalidateAndCancel() }
        let provider = GrokUsageProvider(secretStore: secrets, session: session)
        let task = Task { try await provider.fetchUsage(for: account) }
        await fulfillment(of: [refreshStarted], timeout: 5)
        if resetAll {
            XCTAssertTrue(store.resetAccounts())
        } else {
            XCTAssertTrue(store.removeAccount(account))
        }
        allowRefresh.signal()
        let result = try await task.value
        XCTAssertNotNil(result.failureMessage)
        XCTAssertNil(try secrets.readSecret(account: key))
        XCTAssertEqual(clearedHistory, [account.id])
    }

    private func makeService(_ replies: [(Int, String)]) -> GrokDeviceAuthService {
        GrokDeviceAuthService(session: makeSession(replies))
    }

    private func makeSession(_ replies: [(Int, String)]) -> URLSession {
        GrokTestProtocol.state.reset(replies)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GrokTestProtocol.self]
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }
}

private actor GrokDelayRecorder {
    private var recorded: [TimeInterval] = []
    var values: [TimeInterval] { recorded }
    func record(_ value: TimeInterval) { recorded.append(value) }
}

private final class GrokTestProtocol: URLProtocol, @unchecked Sendable {
    static let state = GrokProtocolState()
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        guard let reply = Self.state.next(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        if reply.0 == 0 {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.0, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.1.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class GrokProtocolState: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [(Int, String)] = []
    private var recorded: [URLRequest] = []
    private var handler: (@Sendable (URLRequest) -> (Int, String)?)?
    var requests: [URLRequest] { lock.withLock { recorded } }
    func reset(_ replies: [(Int, String)]) {
        lock.withLock { self.replies = replies; recorded = []; handler = nil }
    }
    func reset(handler: @escaping @Sendable (URLRequest) -> (Int, String)?) {
        lock.withLock { replies = []; recorded = []; self.handler = handler }
    }
    func next(_ request: URLRequest) -> (Int, String)? {
        lock.withLock {
            recorded.append(request)
            if let handler { return handler(request) }
            return replies.isEmpty ? nil : replies.removeFirst()
        }
    }
}
