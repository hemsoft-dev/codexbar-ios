import Foundation
import SwiftUI
import UIKit
import WebKit
import XCTest
@testable import CodexBarIOS

final class SubscriptionBillingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private let owner = "11111111-1111-4111-8111-111111111111"
    private let organization = "22222222-2222-4222-8222-222222222222"
    private let cookie = SubscriptionBillingSession.Cookie(name: "sessionKey", value: "synthetic", expiresAt: nil)

    @MainActor
    func testUltraCaptureUsesRealFixtureStoreAndConsistentProfile() async throws {
        let suite = "com.hemsoft.CodexBarIOS.ui-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = UITestSecretStore(suite: suite)
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults,
                                               secretStore: secrets, widgetSnapshotDefaults: defaults)
        let scenario = "claude-renewal-ultra"
        UITestFixtures.seedClaudeAccount(in: store, scenario: scenario)
        let account = try XCTUnwrap(store.configuration(accountID: "ui-claude"))
        XCTAssertTrue(store.hasSubscriptionBillingSession(for: account))
        let saved = try secrets.readSecret(account: SubscriptionBillingSession.keychainAccount(account))
        XCTAssertEqual(SubscriptionBillingSession.parse(saved)?.cookies.first?.value, "matching")

        // Keep the restrictive fixture-store contract. The old seed was rejected here.
        let invalid = SubscriptionBillingSession(providerID: .claude, ownerID: UITestSubscriptionBillingProtocol.claudeOwner,
                                                organizationID: UITestSubscriptionBillingProtocol.claudeOrganization, cookies: [cookie])
        XCTAssertThrowsError(try secrets.saveSecret(invalid.encoded(), account: SubscriptionBillingSession.keychainAccount(account)))
        let providers = UITestFixtures.claudeProviders(scenario: scenario, suiteName: suite)
        let result = try await XCTUnwrap(providers.first).fetchUsage(for: account)
        XCTAssertEqual(result.plan?.accessibilityLabel, "Ultra")
        XCTAssertNil(result.failureMessage)
        XCTAssertFalse(result.bars.isEmpty)
        let renewal = try XCTUnwrap(result.boundSubscriptionRenewal)
        XCTAssertNotNil(renewal.compactLabel(at: Date()))
        XCTAssertEqual(result.subscriptionBillingInformation(at: Date())?.items.first?.label, "Next subscription renewal")
        XCTAssertNotNil(renewal.dateText())
    }

    func testClaudeChargeCancellationAndCivilDates() throws {
        let account = ProviderAccountConfiguration(id: "claude-personal", providerID: .claude, authMethod: .browserSession)
        let renewal = try XCTUnwrap(SubscriptionBillingParser.claude(claudeBilling(), configuration: account, at: now))
        XCTAssertEqual(renewal.state, .renewing)
        XCTAssertEqual(renewal.accountID, account.id)
        XCTAssertFalse(renewal.isDateOnly)
        let canceled = try XCTUnwrap(SubscriptionBillingParser.claude(claudeBilling(ending: "2033-05-20"), configuration: account, at: now))
        XCTAssertEqual(canceled.state, .nonRenewing, "Cancellation overrides a residual next charge")
        XCTAssertTrue(canceled.isDateOnly)
        XCTAssertNil(canceled.compactLabel(at: now))
        for body in [#"{"status":"active","next_charge_at":null,"next_charge_date":"2033-02-30","plan_ending_at":null,"plan_ending_before":null}"#,
                     #"{"status":"expired","next_charge_at":null,"next_charge_date":null,"plan_ending_at":null,"plan_ending_before":null}"#,
        ] { XCTAssertNil(SubscriptionBillingParser.claude(Data(body.utf8), configuration: account, at: now)) }
        let empty = Data(#"{"status":"canceled","next_charge_at":null,"next_charge_date":null,"plan_ending_at":null,"plan_ending_before":null}"#.utf8)
        XCTAssertEqual(SubscriptionBillingParser.claude(empty, configuration: account, at: now)?.state, .nonRenewing)
    }

    func testClaudeAlternativeFieldsAndPaymentPause() throws {
        let account = ProviderAccountConfiguration(id: "claude-personal", providerID: .claude, authMethod: .browserSession)
        for status in ["active", "trialing"] {
            for key in ["next_charge_at", "next_charge_date"] {
                let value = key.hasSuffix("_at") ? "2033-05-20T00:00:00Z" : "2033-05-20"
                let data = Data("{\"status\":\"\(status)\",\"billing_interval\":\"year\",\"\(key)\":\"\(value)\"}".utf8)
                let parsed = try XCTUnwrap(SubscriptionBillingParser.claude(data, configuration: account, at: now))
                XCTAssertEqual(parsed.state, .renewing)
                XCTAssertEqual(parsed.isDateOnly, key.hasSuffix("_date"))
            }
        }
        for key in ["plan_ending_at", "plan_ending_before"] {
            let data = Data("{\"status\":\"active\",\"next_charge_at\":\"2033-05-20T00:00:00Z\",\"\(key)\":\"2033-05-19\"}".utf8)
            XCTAssertEqual(SubscriptionBillingParser.claude(data, configuration: account, at: now)?.state, .nonRenewing)
        }
        for body in [#"{"status":"active"}"#, #"{"status":"active","next_charge_at":null}"#, #"{"status":"trialing","next_charge_date":null}"#,
                     #"{"status":"active","next_charge_at":"2033-05-20T00:00:00Z","plan_ending_at":false}"#,
                     #"{"status":"active","next_charge_at":"2033-05-20T00:00:00Z","payment_paused_until":"2033-06-01"}"#,
        ] { XCTAssertNil(SubscriptionBillingParser.claude(Data(body.utf8), configuration: account, at: now)) }
    }

    func testClaudeBillingDiagnosticsAndUsagePreservation() async throws {
        let cases: [(String, SubscriptionBillingProblem.Reason?)] = [
            ("missing", .notConnected), ("expired", .expiredSession), ("401", .expiredSession), ("403", .accessDenied),
            ("500", .transportFailure), ("network", .transportFailure), ("shape", .rejectedResponse),
            ("mismatch", .accountMismatch), ("apple", .unsupportedSubscription), ("null-status", .unsupportedSubscription), ("success", nil),
        ]
        for (scenario, reason) in cases {
            let account = ProviderAccountConfiguration(id: "claude-personal", providerID: .claude, authMethod: .browserSession)
            let secrets = MemorySecretStore()
            try secrets.saveSecret("usage-token", account: ProviderConfigurationStore.keychainAccount(for: account))
            if scenario != "missing" {
                let savedCookie = scenario == "expired"
                    ? SubscriptionBillingSession.Cookie(name: "sessionKey", value: "old", expiresAt: .distantPast) : cookie
                let billing = SubscriptionBillingSession(providerID: .claude, ownerID: owner, organizationID: organization, cookies: [savedCookie])
                try secrets.saveSecret(billing.encoded(), account: SubscriptionBillingSession.keychainAccount(account))
            }
            let fixture = IsolatedTestURLSession { [self] request in
                var status = 200
                let data: Data
                switch request.url?.path {
                case "/api/oauth/usage": data = Data(#"{"five_hour":{"utilization":12,"resets_at":"2033-05-19T00:00:00Z"}}"#.utf8)
                case "/api/oauth/profile": data = profile()
                case "/api/account":
                    if scenario == "network" { throw URLError(.notConnectedToInternet) }
                    status = Int(scenario) ?? 200
                    var root = try XCTUnwrap(SubscriptionBillingParser.object(webAccount(owner: scenario == "mismatch" ? "other" : nil)))
                    if scenario == "apple" {
                        root["memberships"] = [["organization": ["uuid": organization, "billing_type": "apple_subscription"]]]
                    }
                    data = try JSONSerialization.data(withJSONObject: root)
                default:
                    if request.url!.path.contains("subscription_details") {
                        data = scenario == "shape" ? Data("{}".utf8) : scenario == "null-status" ? Data(#"{"status":null}"#.utf8)
                            : Data(#"{"status":"active","next_charge_at":"2033-05-20T00:00:00Z"}"#.utf8)
                    } else { status = 404; data = Data("{}".utf8) }
                }
                return (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, data)
            }
            defer { fixture.invalidate() }
            let result = try await ClaudeUsageProvider(secretStore: secrets, session: fixture.session, now: { self.now }).fetchUsage(for: account)
            XCTAssertNil(result.failureMessage, scenario)
            XCTAssertFalse(result.bars.isEmpty, scenario)
            XCTAssertEqual(result.subscriptionBillingProblem?.reason, reason, scenario)
            XCTAssertEqual(result.subscriptionBillingProblem?.accountID, reason == nil ? nil : account.id, scenario)
            XCTAssertEqual(result.boundSubscriptionRenewal != nil, reason == nil, scenario)
            XCTAssertEqual(try secrets.readSecret(account: ProviderConfigurationStore.keychainAccount(for: account)), "usage-token")
        }
    }

    func testClaudeCallerBillingCredentialReadFailurePreservesUsageAndExplainsRetry() async throws {
        let account = ProviderAccountConfiguration(id: "claude-personal", providerID: .claude, authMethod: .browserSession)
        // The initial read, two plan-owner checks, accepted-usage check and final owner check succeed.
        // Only the caller's subsequent optional billing-credential read fails, then recovers.
        let secrets = TransientBillingReadSecretStore(account: ProviderConfigurationStore.keychainAccount(for: account), failureNumber: 6)
        try secrets.saveSecret("usage-token", account: ProviderConfigurationStore.keychainAccount(for: account))
        let fixture = IsolatedTestURLSession { [self] request in
            XCTAssertFalse(request.url!.path.contains("subscription_details"))
            let data = request.url?.path == "/api/oauth/profile" ? profile()
                : Data(#"{"five_hour":{"utilization":12,"resets_at":"2033-05-19T00:00:00Z"}}"#.utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }
        defer { fixture.invalidate() }
        let result = try await ClaudeUsageProvider(secretStore: secrets, session: fixture.session, now: { self.now }).fetchUsage(for: account)
        XCTAssertNil(result.failureMessage)
        XCTAssertFalse(result.bars.isEmpty)
        XCTAssertNil(result.boundSubscriptionRenewal)
        XCTAssertEqual(result.subscriptionBillingProblem?.reason, .credentialsUnavailable)
        XCTAssertTrue(result.subscriptionBillingInformation(at: now)?.items.first?.detail.contains("Retry refresh") == true)
        XCTAssertEqual(try secrets.readSecret(account: ProviderConfigurationStore.keychainAccount(for: account)), "usage-token")
    }

    func testClaudeKeychainReadFailureDoesNotClaimMissingOrMismatchedCredentials() async throws {
        for phase in ["usage", "billing", "final"] {
            let account = ProviderAccountConfiguration(id: "claude-personal", providerID: .claude, authMethod: .browserSession)
            let secrets = BillingMutationSecretStore()
            let usageKey = ProviderConfigurationStore.keychainAccount(for: account)
            let billingKey = SubscriptionBillingSession.keychainAccount(account)
            try secrets.saveSecret("usage-token", account: usageKey)
            let billing = SubscriptionBillingSession(providerID: .claude, ownerID: owner, organizationID: organization, cookies: [cookie])
            let original = try billing.encoded()
            try secrets.saveSecret(original, account: billingKey)
            if phase != "final" { secrets.failingReadAccount = phase == "usage" ? usageKey : billingKey }
            let fixture = IsolatedTestURLSession { [self] request in
                let data: Data
                switch request.url?.path {
                case "/api/oauth/profile": data = profile()
                case "/api/account": data = webAccount()
                default: secrets.failingReadAccount = billingKey; data = claudeBilling()
                }
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
            }
            defer { fixture.invalidate() }
            let result = try await SubscriptionBillingClient(session: fixture.session).fetchClaudeObservation(
                configuration: account, usageSecret: "usage-token", secretStore: secrets, at: now)
            XCTAssertNil(result.renewal)
            XCTAssertEqual(result.problem?.reason, .credentialsUnavailable, phase)
            secrets.failingReadAccount = nil
            XCTAssertEqual(try secrets.readSecret(account: usageKey), "usage-token")
            XCTAssertEqual(try secrets.readSecret(account: billingKey), original)
        }
    }

    func testClaudeCredentialChangeDiscardsBillingAndCallerCancellationPropagates() async throws {
        for mutation in ["usage", "billing", "cancel"] {
            let account = ProviderAccountConfiguration(id: "claude-personal", providerID: .claude, authMethod: .browserSession)
            let secrets = MemorySecretStore()
            let usageKey = ProviderConfigurationStore.keychainAccount(for: account)
            let billingKey = SubscriptionBillingSession.keychainAccount(account)
            try secrets.saveSecret("usage-token", account: usageKey)
            let billing = SubscriptionBillingSession(providerID: .claude, ownerID: owner, organizationID: organization, cookies: [cookie])
            try secrets.saveSecret(billing.encoded(), account: billingKey)
            let fixture = IsolatedTestURLSession { [self] request in
                let data: Data
                switch request.url?.path {
                case "/api/oauth/profile": data = profile()
                case "/api/account": data = webAccount()
                default:
                    try secrets.saveSecret("changed", account: mutation == "usage" ? usageKey : billingKey)
                    data = claudeBilling()
                }
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
            }
            defer { fixture.invalidate() }
            let task = Task {
                try await SubscriptionBillingClient(session: fixture.session).fetchClaudeObservation(
                    configuration: account, usageSecret: "usage-token", secretStore: secrets, at: now)
            }
            if mutation == "cancel" { task.cancel() }
            do {
                let result = try await task.value
                XCTAssertNotEqual(mutation, "cancel")
                XCTAssertNil(result.renewal)
                XCTAssertEqual(result.problem?.reason, .accountMismatch)
            } catch { XCTAssertEqual(mutation, "cancel"); XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
        }
    }

    func testGrokRequiresOwnedPersonalBillingAndExplicitRenewalState() throws {
        let account = ProviderAccountConfiguration(id: "grok-personal", providerID: .grok, authMethod: .browserSession)
        let parser = { (data: Data) in SubscriptionBillingParser.grok(data, configuration: account, owner: self.owner, at: self.now) }
        XCTAssertEqual(parser(grokBilling())?.state, .renewing)
        XCTAssertEqual(parser(grokBilling(cancel: true))?.state, .nonRenewing)
        XCTAssertNil(parser(grokBilling(owner: "other-account")))
        XCTAssertNil(parser(grokBilling(cancelJSON: "1")))
        XCTAssertNil(parser(grokBilling(extra: #", "x":{}"#)))
        XCTAssertNil(parser(grokBilling(extra: #", "lapsedPaymentInfo":{"onHold":{}}"#)))
        XCTAssertNil(parser(grokBilling(extra: #", "cancelAtPeriodEnd":true"#)))
        XCTAssertNil(parser(grokBilling(extra: #", "cancelAtPeriodEnd":"false""#)))
        let root = try XCTUnwrap(SubscriptionBillingParser.object(grokBilling()))
        let rows = try XCTUnwrap(root["subscriptions"] as? [[String: Any]])
        XCTAssertNil(parser(try JSONSerialization.data(withJSONObject: ["subscriptions": rows + rows])))
        XCTAssertNil(parser(Data(#"{"config":{"currentPeriod":{"end":"2033-05-20T00:00:00Z"}}}"#.utf8)), "Weekly usage is never a charge")
        for source in [#""google":{"expiryTime":"2033-05-20T00:00:00Z","autoRenewEnabled":true}"#,
                       #""apple":{"autoRenewOn":true},"billingPeriodEnd":"2033-05-20T00:00:00Z""#,
        ] {
            let data = Data("{\"subscriptions\":[{\"xaiUserId\":\"\(owner)\",\"tier\":\"SUBSCRIPTION_TIER_GROK_PRO\",\"status\":\"SUBSCRIPTION_STATUS_ACTIVE\",\(source)}]}".utf8)
            XCTAssertEqual(parser(data)?.state, .renewing)
        }
    }

    func testClaudeAcquisitionChecksOAuthAndWebOwnerBeforeAndAfterBilling() async throws {
        let account = ProviderAccountConfiguration(id: "claude-personal", providerID: .claude, authMethod: .browserSession)
        let fixture = IsolatedTestURLSession { [self] request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.timeoutInterval, 3)
            let body: Data
            switch request.url?.path {
            case "/api/oauth/profile":
                XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer usage-token")
                body = profile()
            case "/api/account":
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "sessionKey=synthetic")
                body = webAccount()
            default:
                XCTAssertEqual(request.url?.path, "/api/organizations/\(organization)/subscription_details")
                body = claudeBilling()
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        defer { fixture.invalidate() }
        let client = SubscriptionBillingClient(session: fixture.session)
        let secret = "usage-token"
        let billing = try await client.connect(configuration: account, usageSecret: secret, cookies: [cookie])
        XCTAssertEqual(billing.ownerID, owner)
        XCTAssertEqual(billing.organizationID, organization)
        let store = MemorySecretStore()
        try store.saveSecret(secret, account: ProviderConfigurationStore.keychainAccount(for: account))
        try store.saveSecret(billing.encoded(), account: SubscriptionBillingSession.keychainAccount(account))
        let result = try await client.fetch(configuration: account, usageSecret: secret, secretStore: store, at: now)
        XCTAssertEqual(result?.providerID, .claude)
        XCTAssertEqual(result?.state, .renewing)
    }

    func testForeignClaudeWebSessionIsRejectedBeforeReadingBilling() async throws {
        let account = ProviderAccountConfiguration(id: "claude-personal", providerID: .claude, authMethod: .browserSession)
        let fixture = IsolatedTestURLSession { [self] request in
            XCTAssertFalse(request.url!.path.contains("subscription_details"))
            let body = request.url?.path == "/api/oauth/profile" ? profile() : webAccount(owner: "other")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        defer { fixture.invalidate() }
        do {
            _ = try await SubscriptionBillingClient(session: fixture.session).connect(configuration: account, usageSecret: "usage-token", cookies: [cookie])
            XCTFail("Foreign web account must not connect")
        } catch { XCTAssertEqual(error as? SubscriptionBillingError, .accountMismatch) }
    }

    func testGrokAcquisitionDisconnectAndRejectedReadsNeverRestoreDates() async throws {
        for status in [200, 401, 403, 429, 500] {
            for disconnect in [false, true] {
                let account = ProviderAccountConfiguration(id: "grok-personal", providerID: .grok, authMethod: .browserSession)
                let store = MemorySecretStore()
                let credential = GrokCredential(kind: "grok-oauth-v1", accessToken: "usage-token", refreshToken: "refresh",
                                                expiresAt: Date().addingTimeInterval(3600), subject: owner, email: nil)
                let secret = try credential.encoded()
                try store.saveSecret(secret, account: ProviderConfigurationStore.keychainAccount(for: account))
                let billing = SubscriptionBillingSession(providerID: .grok, ownerID: owner, organizationID: nil, cookies: [cookie])
                try store.saveSecret(billing.encoded(), account: SubscriptionBillingSession.keychainAccount(account))
                let fixture = IsolatedTestURLSession { [self] request in
                    XCTAssertEqual(request.url?.absoluteString, "https://grok.com/rest/subscriptions")
                    XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                    if disconnect { try store.deleteSecret(account: SubscriptionBillingSession.keychainAccount(account)) }
                    return (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, grokBilling())
                }
                defer { fixture.invalidate() }
                let result = try await SubscriptionBillingClient(session: fixture.session).fetch(
                    configuration: account, usageSecret: secret, secretStore: store, at: now)
                XCTAssertEqual(result != nil, status == 200 && !disconnect)
            }
        }
    }

    func testUnsupportedGrokSubscriptionCannotConnect() async throws {
        let account = ProviderAccountConfiguration(id: "grok-personal", providerID: .grok, authMethod: .browserSession)
        let credential = GrokCredential(kind: "grok-oauth-v1", accessToken: "usage-token", refreshToken: "refresh",
                                        expiresAt: Date().addingTimeInterval(3600), subject: owner, email: nil)
        for data in [grokBilling(extra: #", "x":{}"#), Data("{\"subscriptions\":[{\"xaiUserId\":\"\(owner)\"}]}".utf8)] {
            let fixture = IsolatedTestURLSession { request in
                (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
            }
            defer { fixture.invalidate() }
            do {
                _ = try await SubscriptionBillingClient(session: fixture.session).connect(
                    configuration: account, usageSecret: credential.encoded(), cookies: [cookie])
                XCTFail("An owned but unsupported subscription must not be reported connected")
            } catch {
                XCTAssertEqual(error as? SubscriptionBillingError, .unsupportedSubscription)
            }
        }
    }

    func testExpiredAncillaryCookieDoesNotInvalidateLiveAuthentication() throws {
        let expired = SubscriptionBillingSession.Cookie(name: "ancillary", value: "old", expiresAt: .distantPast)
        let live = SubscriptionBillingSession.Cookie(name: "auth", value: "current", expiresAt: .distantFuture)
        XCTAssertEqual(SubscriptionBillingSession.header([expired, live], at: now), "auth=current")
        XCTAssertNil(SubscriptionBillingSession.header([expired], at: now))
        let session = SubscriptionBillingSession(providerID: .grok, ownerID: owner, organizationID: nil, cookies: [expired, live])
        XCTAssertEqual(SubscriptionBillingSession.parse(try session.encoded()), session)
    }

    func testClaudeOrganizationSwitchAfterBillingRejectsObservation() async throws {
        let account = ProviderAccountConfiguration(id: "claude-personal", providerID: .claude, authMethod: .browserSession)
        let secrets = MemorySecretStore()
        let secret = "usage-token"
        let billing = SubscriptionBillingSession(providerID: .claude, ownerID: owner, organizationID: organization, cookies: [cookie])
        try secrets.saveSecret(secret, account: ProviderConfigurationStore.keychainAccount(for: account))
        try secrets.saveSecret(billing.encoded(), account: SubscriptionBillingSession.keychainAccount(account))
        let fixture = IsolatedTestURLSession { [self] request in
            let body: Data
            switch request.url?.path {
            case "/api/oauth/profile": body = profile()
            case "/api/account":
                body = try secrets.readSecret(account: "changed") == nil ? webAccount()
                    : Data("{\"uuid\":\"\(owner)\",\"memberships\":[{\"organization\":{\"uuid\":\"different-organization\"}}]}".utf8)
            default:
                try secrets.saveSecret("yes", account: "changed")
                body = claudeBilling()
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        defer { fixture.invalidate() }
        let result = try await SubscriptionBillingClient(session: fixture.session).fetch(
            configuration: account, usageSecret: secret, secretStore: secrets, at: now)
        XCTAssertNil(result)
    }

    @MainActor
    func testExplicitReconnectRemovalAndResetClearBillingSecrets() throws {
        let suite = "SubscriptionBillingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = MemorySecretStore()
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secrets, widgetSnapshotDefaults: defaults)
        let account = ProviderAccountConfiguration(id: "claude-personal", providerID: .claude, authMethod: .browserSession)
        XCTAssertTrue(store.update(account))
        XCTAssertTrue(store.saveSecret("usage-token", for: account))
        let billing = SubscriptionBillingSession(providerID: .claude, ownerID: owner, organizationID: organization, cookies: [cookie])
        XCTAssertFalse(store.saveSubscriptionBillingSession(billing, for: account, expectedUsageSecret: "old-token"))
        XCTAssertTrue(store.saveSubscriptionBillingSession(billing, for: account, expectedUsageSecret: "usage-token"))
        XCTAssertTrue(store.hasSubscriptionBillingSession(for: account))
        XCTAssertTrue(store.saveSecret("replacement-token", for: account))
        XCTAssertFalse(store.hasSubscriptionBillingSession(for: account))
        XCTAssertTrue(store.saveSubscriptionBillingSession(billing, for: account, expectedUsageSecret: "replacement-token"))
        XCTAssertTrue(store.removeAccount(account))
        XCTAssertNil(try secrets.readSecret(account: SubscriptionBillingSession.keychainAccount(account)))
        XCTAssertTrue(store.update(account))
        XCTAssertTrue(store.saveSecret("usage-token", for: account))
        XCTAssertTrue(store.saveSubscriptionBillingSession(billing, for: account, expectedUsageSecret: "usage-token"))
        XCTAssertTrue(store.resetAccounts())
        XCTAssertNil(try secrets.readSecret(account: SubscriptionBillingSession.keychainAccount(account)))
    }

    @MainActor
    func testFailedCredentialReplacementPreservesBillingAndOriginalCredential() throws {
        for failure in ["primary-save", "primary-delete", "billing-delete"] {
            let suite = "SubscriptionBillingTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let secrets = BillingMutationSecretStore()
            let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secrets, widgetSnapshotDefaults: defaults)
            let account = ProviderAccountConfiguration(id: "claude-personal", providerID: .claude, authMethod: .browserSession)
            XCTAssertTrue(store.update(account))
            XCTAssertTrue(store.saveSecret("usage-token", for: account))
            let billing = SubscriptionBillingSession(providerID: .claude, ownerID: owner, organizationID: organization, cookies: [cookie])
            XCTAssertTrue(store.saveSubscriptionBillingSession(billing, for: account, expectedUsageSecret: "usage-token"))
            let primary = ProviderConfigurationStore.keychainAccount(for: account)
            secrets.failingSaveAccount = failure == "primary-save" ? primary : nil
            secrets.failingDeleteAccount = failure == "primary-delete" ? primary
                : failure == "billing-delete" ? SubscriptionBillingSession.keychainAccount(account) : nil
            if failure == "primary-delete" {
                XCTAssertFalse(store.removeAccount(account))
                XCTAssertNotNil(store.configuration(accountID: account.id))
            } else {
                XCTAssertFalse(store.saveSecret("replacement-token", for: account))
            }
            XCTAssertEqual(try secrets.readSecret(account: primary), "usage-token", failure)
            XCTAssertEqual(SubscriptionBillingSession.parse(try secrets.readSecret(account: SubscriptionBillingSession.keychainAccount(account))), billing, failure)
        }
    }

    @MainActor
    func testResetRetainsBillingOwnerUntilFailedDeletionCanBeRetried() throws {
        for provider in [ProviderID.claude, .grok] {
            let suite = "SubscriptionBillingTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let secrets = BillingMutationSecretStore()
            let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secrets, widgetSnapshotDefaults: defaults)
            let account = ProviderAccountConfiguration(id: "personal-\(provider.rawValue)", providerID: provider, authMethod: .browserSession)
            XCTAssertTrue(store.update(account))
            let primary = ProviderConfigurationStore.keychainAccount(for: account)
            let billingKey = SubscriptionBillingSession.keychainAccount(account)
            try secrets.saveSecret("usage-token", account: primary)
            try secrets.saveSecret("billing-token", account: billingKey)
            secrets.failingDeleteAccount = billingKey
            XCTAssertFalse(store.resetAccounts())
            XCTAssertNil(try secrets.readSecret(account: primary))
            XCTAssertEqual(try secrets.readSecret(account: billingKey), "billing-token")
            XCTAssertNotNil(store.configuration(accountID: account.id))
            let reloaded = ProviderConfigurationStore(
                initialPlanAccess: .unrestricted,
                defaults: defaults, secretStore: secrets, widgetSnapshotDefaults: defaults)
            XCTAssertNotNil(reloaded.configuration(accountID: account.id))
            secrets.failingDeleteAccount = nil
            XCTAssertTrue(reloaded.resetAccounts())
            XCTAssertNil(try secrets.readSecret(account: billingKey))
            XCTAssertNil(reloaded.configuration(accountID: account.id))
        }
    }

    @MainActor
    func testPartialResetInvalidatesDeletedBillingWhenUsageCredentialRemains() throws {
        for provider in [ProviderID.claude, .grok] {
            let suite = "SubscriptionBillingTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let secrets = BillingMutationSecretStore()
            let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secrets, widgetSnapshotDefaults: defaults)
            let account = ProviderAccountConfiguration(id: "personal-\(provider.rawValue)", providerID: provider, authMethod: .browserSession)
            XCTAssertTrue(store.update(account))
            let primary = ProviderConfigurationStore.keychainAccount(for: account)
            let billingKey = SubscriptionBillingSession.keychainAccount(account)
            try secrets.saveSecret("usage-token", account: primary)
            try secrets.saveSecret("billing-token", account: billingKey)
            secrets.failingDeleteAccount = primary
            var invalidated = [String]()
            let subscription = store.credentialChanges.sink { invalidated.append($0) }
            defer { subscription.cancel() }
            XCTAssertFalse(store.resetAccounts())
            XCTAssertEqual(try secrets.readSecret(account: primary), "usage-token")
            XCTAssertNil(try secrets.readSecret(account: billingKey))
            XCTAssertNotNil(store.configuration(accountID: account.id))
            XCTAssertTrue(invalidated.contains(account.id), "Deleted billing must invalidate cached renewal dates")
        }
    }

    func testCookieCaptureRejectsForeignInsecureExpiredAndHeaderInjection() throws {
        let make = { (domain: String, secure: Bool, value: String, expiry: Date?) -> HTTPCookie in
            var properties: [HTTPCookiePropertyKey: Any] = [.name: "sessionKey", .value: value, .domain: domain, .path: "/"]
            if secure { properties[.secure] = "TRUE" }
            if let expiry { properties[.expires] = expiry }
            return HTTPCookie(properties: properties)!
        }
        XCTAssertEqual(SubscriptionBillingSession.capture([make(".claude.ai", true, "synthetic", nil)], provider: .claude).count, 1)
        for cookie in [make("evilclaude.ai", true, "synthetic", nil), make("claude.ai", false, "synthetic", nil),
                       make("claude.ai", true, "synthetic", Date(timeIntervalSince1970: 1)),
        ] { XCTAssertTrue(SubscriptionBillingSession.capture([cookie], provider: .claude).isEmpty) }
        XCTAssertNil(SubscriptionBillingSession.header([.init(name: "sessionKey", value: "value; another=secret", expiresAt: nil)], at: now))
        XCTAssertNil(SubscriptionBillingSession.header([cookie, cookie], at: now))
    }

    func testCursorObservationRenewsOnlyForOneUnambiguousMatchingPlan() throws {
        let account = ProviderAccountConfiguration(id: "cursor-personal", providerID: .cursor, authMethod: .browserSession)
        let observe = { (data: Data, profile: CursorSubscriptionBilling.Profile) in
            CursorSubscriptionBilling.observation(data, profile: profile, configuration: account, at: self.now)
        }
        let profile = try cursorProfile()
        let end = Date(timeIntervalSince1970: 2_100_000_000)
        XCTAssertEqual(observe(try cursorSubscriptions(), profile),
                       SubscriptionRenewal(accountID: account.id, providerID: .cursor, state: .renewing, date: end, observedAt: now))
        let unrelated: [[String: Any]] = [["status": "active"], ["items": [["price_details": ["product": ["name": "Stripe Climate"]]]]]]
        XCTAssertEqual(observe(try cursorSubscriptions(others: unrelated), profile)?.state, .renewing, "Non-Cursor subscriptions are ignored")
        let yearly = try cursorProfile(["isYearlyPlan": true])
        XCTAssertNil(observe(try cursorSubscriptions(), yearly), "A monthly price never confirms a yearly profile")
        XCTAssertEqual(observe(try cursorSubscriptions(interval: "year"), yearly)?.date, end)
        XCTAssertEqual(observe(try cursorSubscriptions(product: "Cursor Pro Plus"), try cursorProfile(["membershipType": "pro_plus"]))?.state, .renewing)
        XCTAssertNil(observe(try cursorSubscriptions(product: "Cursor Ultra"), profile), "The product must match the membership")

        let claude = ProviderAccountConfiguration(id: "claude-personal", providerID: .claude, authMethod: .browserSession)
        XCTAssertNil(CursorSubscriptionBilling.observation(try cursorSubscriptions(), profile: profile, configuration: claude, at: now))
        let second = try XCTUnwrap((SubscriptionBillingParser.object(try cursorSubscriptions())?["data"] as? [[String: Any]])?.first)
        let rejected: [(String, Data)] = [
            ("not a list", try cursorSubscriptions(list: ["object": "subscription"])),
            ("more pages", try cursorSubscriptions(list: ["has_more": true])),
            ("unknown paging", try cursorSubscriptions(list: ["has_more": NSNull()])),
            ("missing rows", try cursorSubscriptions(list: ["data": "none"])),
            ("ambiguous plans", try cursorSubscriptions(others: [second])),
            ("no Cursor plan", try cursorSubscriptions(product: "Stripe Climate")),
            ("period end outside range", try cursorSubscriptions(["current_period_end": 100])),
            ("unknown cancellation", try cursorSubscriptions(["cancel_at_period_end": NSNull()])),
            ("ended subscription", try cursorSubscriptions(["ended_at": 2_000_000_000])),
            ("unsupported status", try cursorSubscriptions(["status": "past_due"])),
            ("malformed JSON", Data("not json".utf8)),
        ]
        for (reason, data) in rejected { XCTAssertNil(observe(data, profile), reason) }
    }

    func testCursorObservationReportsScheduledStopsAsNonRenewing() throws {
        let account = ProviderAccountConfiguration(id: "cursor-personal", providerID: .cursor, authMethod: .browserSession)
        let profile = try cursorProfile()
        let end = Date(timeIntervalSince1970: 2_100_000_000)
        let observe = { (overrides: [String: Any]) in
            CursorSubscriptionBilling.observation(try self.cursorSubscriptions(overrides), profile: profile, configuration: account, at: self.now)
        }
        XCTAssertEqual(try observe(["cancel_at_period_end": true]),
                       SubscriptionRenewal(accountID: account.id, providerID: .cursor, state: .nonRenewing, date: end, observedAt: now))
        let earlyStop = Date(timeIntervalSince1970: 2_050_000_000)
        let early = try observe(["cancel_at": 2_050_000_000])
        XCTAssertEqual(early?.state, .nonRenewing)
        XCTAssertEqual(early?.date, earlyStop, "Access ends at the scheduled stop before the period end")
        XCTAssertEqual(try observe(["cancel_at": 2_100_000_000, "cancel_at_period_end": true])?.date, end)
        XCTAssertEqual(try observe(["status": "canceled", "cancel_at_period_end": true])?.state, .nonRenewing)
        let canceledProfile = try cursorProfile(["subscriptionStatus": "canceled", "pendingCancellationDate": "2036-07-18"])
        XCTAssertEqual(CursorSubscriptionBilling.observation(try cursorSubscriptions(["cancel_at_period_end": true]), profile: canceledProfile,
                                                             configuration: account, at: now)?.state, .nonRenewing)
        XCTAssertNil(try observe(["cancel_at": 2_150_000_000]), "A stop after another charge does not establish the access end")
        XCTAssertNil(try observe(["cancel_at": "2036-07-18"]), "A malformed stop date is never ignored")
        XCTAssertNil(try observe(["cancel_at": true]))
    }

    func testCursorObservationWithholdsRenewalWhileAnyChangeIsPending() throws {
        let account = ProviderAccountConfiguration(id: "cursor-personal", providerID: .cursor, authMethod: .browserSession)
        let profiles: [(String, [String: Any])] = [
            ("canceled profile", ["subscriptionStatus": "canceled"]),
            ("pending cancellation", ["pendingCancellationDate": "2036-07-18"]),
            ("failed payment", ["lastPaymentFailed": true]),
            ("payment recovery", ["paymentRecoveryAction": ["type": "update_payment_method"]]),
        ]
        for (reason, overrides) in profiles {
            let profile = try cursorProfile(overrides)
            XCTAssertNil(CursorSubscriptionBilling.observation(try cursorSubscriptions(), profile: profile, configuration: account, at: now), reason)
        }
        let subscriptions: [(String, [String: Any])] = [
            ("canceled subscription", ["status": "canceled"]),
            ("paused collection", ["pause_collection": ["behavior": "void"]]),
            ("pending update", ["pending_update": ["expires_at": 2_050_000_000]]),
            ("trial", ["trial_end": 2_050_000_000]),
            ("scheduled update", ["has_update_scheduled": true]),
            ("unknown scheduled update", ["has_update_scheduled": NSNull()]),
            ("mixed interval", ["is_mixed_interval": true]),
        ]
        let profile = try cursorProfile()
        for (reason, overrides) in subscriptions {
            XCTAssertNil(CursorSubscriptionBilling.observation(try cursorSubscriptions(overrides), profile: profile, configuration: account, at: now), reason)
        }
    }

    @MainActor
    func testBillingSignInVerifiesOnlyOnTheProviderPageAndCompletesOnce() async throws {
        let account = ProviderAccountConfiguration(id: "claude-personal", providerID: .claude, authMethod: .browserSession)
        let fixture = billingSignInFixture()
        defer { fixture.invalidate() }
        var results = [Result<SubscriptionBillingSession, Error>]()
        let session = SubscriptionBillingSignInSession(configuration: account, usageSecret: "usage-token",
                                                       client: SubscriptionBillingClient(session: fixture.session)) { results.append($0) }
        defer { session.invalidate() }
        let cookies = session.webView.configuration.websiteDataStore.httpCookieStore
        await cookies.setCookie(try signInCookie("matching"))
        session.verify()
        XCTAssertFalse(session.isVerifying, "Nothing is submitted before a page has loaded")

        session.webView.loadHTMLString("<html><body>Elsewhere</body></html>", baseURL: URL(string: "https://example.com/"))
        let foreignLoaded = await waitUntil { !session.webView.isLoading && session.webView.url?.host == "example.com" }
        XCTAssertTrue(foreignLoaded)
        session.verify()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(session.host, "example.com")
        XCTAssertFalse(session.isVerifying, "Provider cookies are never submitted from another site")
        XCTAssertTrue(results.isEmpty)

        session.webView.loadHTMLString("<html><body>Billing</body></html>", baseURL: URL(string: "https://claude.ai/"))
        let completed = await waitUntil { !results.isEmpty }
        XCTAssertTrue(completed)
        XCTAssertEqual(session.host, "claude.ai")
        XCTAssertNil(session.message)
        let billing = try XCTUnwrap(results.first).get()
        XCTAssertEqual(billing.providerID, .claude)
        XCTAssertEqual(billing.ownerID, owner)
        XCTAssertEqual(billing.organizationID, organization)
        XCTAssertEqual(billing.cookies.map(\.name), ["sessionKey"])
        XCTAssertEqual(billing.cookies.map(\.value), ["matching"])

        session.verify()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(results.count, 1, "A completed attempt never verifies or reports again")
    }

    @MainActor
    func testBillingSignInExplainsWrongAccountAndRecoversWithMatchingAccount() async throws {
        let account = ProviderAccountConfiguration(id: "claude-personal", providerID: .claude, authMethod: .browserSession)
        let fixture = billingSignInFixture()
        defer { fixture.invalidate() }
        var results = [Result<SubscriptionBillingSession, Error>]()
        let session = SubscriptionBillingSignInSession(configuration: account, usageSecret: "usage-token",
                                                       client: SubscriptionBillingClient(session: fixture.session)) { results.append($0) }
        defer { session.invalidate() }
        session.webView.loadHTMLString("<html><body>Sign in</body></html>", baseURL: URL(string: "https://claude.ai/"))
        let loaded = await waitUntil { !session.webView.isLoading && session.webView.url?.host == "claude.ai" }
        XCTAssertTrue(loaded)
        session.verify()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(session.isVerifying, "A signed-out page has no billing cookie to verify")
        XCTAssertTrue(session.message?.contains("No billing sign-in") == true)

        let cookies = session.webView.configuration.websiteDataStore.httpCookieStore
        await cookies.setCookie(try signInCookie("wrong"))
        session.verify()
        let explained = await waitUntil { session.message == SubscriptionBillingError.accountMismatch.localizedDescription && !session.isVerifying }
        XCTAssertTrue(explained)
        XCTAssertEqual(session.message, SubscriptionBillingError.accountMismatch.localizedDescription)
        XCTAssertTrue(results.isEmpty, "A wrong account keeps the sign-in open")

        await cookies.setCookie(try signInCookie("matching"))
        session.verify()
        let completed = await waitUntil { !results.isEmpty }
        XCTAssertTrue(completed)
        XCTAssertEqual(try XCTUnwrap(results.first).get().cookies.map(\.value), ["matching"])
        session.cancel()
        XCTAssertEqual(results.count, 1, "Canceling after completion reports nothing")
    }

    @MainActor
    func testStartingBillingSignInRequiresPersonalClaudeOrGrokUsageConnection() throws {
        let suite = "SubscriptionBillingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = MemorySecretStore()
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secrets, widgetSnapshotDefaults: defaults)
        let claude = ProviderAccountConfiguration(id: "claude-personal", providerID: .claude, authMethod: .browserSession)
        let grok = ProviderAccountConfiguration(id: "grok-personal", providerID: .grok, authMethod: .browserSession)
        let cursor = ProviderAccountConfiguration(id: "cursor-personal", providerID: .cursor, authMethod: .browserSession)
        for account in [claude, grok, cursor] { XCTAssertTrue(store.update(account)) }

        let unconnected = ProviderSettingsViewModel(configurationStore: store, accountID: claude.id)
        unconnected.startSubscriptionBillingSignIn()
        XCTAssertNil(unconnected.subscriptionBillingSession, "Billing requires the saved usage connection first")

        for account in [claude, grok, cursor] { XCTAssertTrue(store.saveSecret("usage-token", for: account)) }
        let unsupported = ProviderSettingsViewModel(configurationStore: store, accountID: cursor.id)
        unsupported.startSubscriptionBillingSignIn()
        XCTAssertNil(unsupported.subscriptionBillingSession, "Cursor billing is read through its own session")

        let team = ProviderUsageResult(
            accountID: claude.id, providerID: .claude, title: "Claude",
            plan: ProviderPlanDescriptor(identifier: "claude.team", displayLabel: "TEAM", accessibilityLabel: "Team"),
            subtitle: "Team usage", bars: [], fetchedAt: now
        )
        let organization = ProviderSettingsViewModel(configurationStore: store, accountID: claude.id, initialUsageResult: team)
        XCTAssertTrue(organization.isClaudeOrganizationBilling)
        organization.startSubscriptionBillingSignIn()
        XCTAssertNil(organization.subscriptionBillingSession, "Organization billing is not personal billing")

        for (account, name, host) in [(claude, "Claude", "claude.ai"), (grok, "Grok", "grok.com")] {
            let viewModel = ProviderSettingsViewModel(configurationStore: store, accountID: account.id)
            viewModel.startSubscriptionBillingSignIn()
            let session = try XCTUnwrap(viewModel.subscriptionBillingSession, name)
            XCTAssertEqual(session.providerName, name)
            XCTAssertEqual(session.host, host)
            XCTAssertNil(session.message)
            XCTAssertFalse(session.webView.configuration.websiteDataStore.isPersistent, "Billing sign-in never shares browser data")
        }
    }

    @MainActor
    func testRestartingBillingSignInReplacesTheAttemptAndCanceledAttemptsStayQuiet() throws {
        let suite = "SubscriptionBillingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = MemorySecretStore()
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secrets, widgetSnapshotDefaults: defaults)
        let account = ProviderAccountConfiguration(id: "claude-personal", providerID: .claude, authMethod: .browserSession)
        XCTAssertTrue(store.update(account))
        XCTAssertTrue(store.saveSecret("usage-token", for: account))
        var credentialChanges = 0
        let viewModel = ProviderSettingsViewModel(configurationStore: store, accountID: account.id, onCredentialsChanged: { credentialChanges += 1 })

        viewModel.disconnectSubscriptionBilling()
        XCTAssertEqual(viewModel.subscriptionBillingMessage, "Billing disconnected. Your usage connection is unchanged.")
        XCTAssertEqual(credentialChanges, 1)
        viewModel.startSubscriptionBillingSignIn()
        let first = try XCTUnwrap(viewModel.subscriptionBillingSession)
        XCTAssertNil(viewModel.subscriptionBillingMessage, "A new attempt clears the previous outcome")

        viewModel.startSubscriptionBillingSignIn()
        let second = try XCTUnwrap(viewModel.subscriptionBillingSession)
        XCTAssertFalse(first === second)
        first.cancel()
        XCTAssertTrue(viewModel.subscriptionBillingSession === second, "A replaced attempt can no longer complete")

        second.cancel()
        XCTAssertNil(viewModel.subscriptionBillingSession)
        XCTAssertNil(viewModel.subscriptionBillingMessage, "Canceling is not reported as a failure")
        XCTAssertEqual(credentialChanges, 1)

        viewModel.startSubscriptionBillingSignIn()
        let third = try XCTUnwrap(viewModel.subscriptionBillingSession)
        try secrets.deleteSecret(account: ProviderConfigurationStore.keychainAccount(for: account))
        viewModel.startSubscriptionBillingSignIn()
        XCTAssertNil(viewModel.subscriptionBillingSession, "Losing the usage connection ends the open attempt")
        third.cancel()
        XCTAssertNil(viewModel.subscriptionBillingMessage)
    }

    @MainActor
    func testBillingSignInCompletionSavesOnlyForTheUnchangedUsageConnection() async throws {
        let suite = "SubscriptionBillingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted, defaults: defaults, secretStore: MemorySecretStore(), widgetSnapshotDefaults: defaults)
        let account = ProviderAccountConfiguration(id: "claude-personal", providerID: .claude, authMethod: .browserSession)
        XCTAssertTrue(store.update(account))
        XCTAssertTrue(store.saveSecret("usage-token", for: account))
        var credentialChanges = 0
        let viewModel = ProviderSettingsViewModel(configurationStore: store, accountID: account.id, onCredentialsChanged: { credentialChanges += 1 })
        defer { viewModel.cancelSubscriptionBillingSignIn() }

        viewModel.startSubscriptionBillingSignIn()
        let session = try XCTUnwrap(viewModel.subscriptionBillingSession)
        // The view model owns its live billing client; only the explicit simulator fixture host can complete offline.
        try XCTSkipUnless(session.isSynthetic, "Requires the isolated fixture host configured by the CodexBarIOS test scheme")
        session.start()
        session.chooseSyntheticAccount(matching: true)
        let saved = await waitUntil { viewModel.subscriptionBillingSession == nil }
        XCTAssertTrue(saved)
        XCTAssertEqual(viewModel.subscriptionBillingMessage, "Billing connected. Updating the current renewal date.")
        XCTAssertTrue(store.hasSubscriptionBillingSession(for: account))
        XCTAssertEqual(credentialChanges, 1)

        viewModel.startSubscriptionBillingSignIn()
        let replacement = try XCTUnwrap(viewModel.subscriptionBillingSession)
        XCTAssertTrue(store.saveSecret("replacement-token", for: account))
        replacement.start()
        replacement.chooseSyntheticAccount(matching: true)
        let rejected = await waitUntil { viewModel.subscriptionBillingSession == nil }
        XCTAssertTrue(rejected)
        XCTAssertEqual(viewModel.subscriptionBillingMessage, "Account changed or billing could not be saved. Connect billing again.")
        XCTAssertFalse(store.hasSubscriptionBillingSession(for: account), "Billing is never bound to a replaced usage connection")
        XCTAssertEqual(credentialChanges, 1)
    }

    private func cursorProfile(_ overrides: [String: Any] = [:]) throws -> CursorSubscriptionBilling.Profile {
        var root: [String: Any] = [
            "membershipType": "pro", "paymentId": "cus_synthetic", "subscriptionStatus": "active", "isYearlyPlan": false,
            "isTeamMember": false, "lastPaymentFailed": false, "pendingCancellationDate": "", "paymentRecoveryAction": NSNull(),
        ]
        root.merge(overrides) { $1 }
        return try XCTUnwrap(CursorSubscriptionBilling.Profile(try JSONSerialization.data(withJSONObject: root)))
    }

    private func cursorSubscriptions(_ overrides: [String: Any] = [:], product: String = "Cursor Pro", interval: String = "month",
                                     others: [[String: Any]] = [], list: [String: Any] = [:]) throws -> Data {
        let end = 2_100_000_000
        let price: [String: Any] = ["type": "recurring", "product": ["name": product], "recurring": ["interval": interval, "interval_count": 1]]
        var subscription: [String: Any] = [
            "id": "sub_synthetic", "object": "subscription", "status": "active", "current_period_end": end,
            "cancel_at_period_end": false, "cancel_at": NSNull(), "ended_at": NSNull(), "pause_collection": NSNull(),
            "pending_update": NSNull(), "trial_end": NSNull(), "has_update_scheduled": false, "is_mixed_interval": false,
            "items": [["current_period_end": end, "price_details": price]],
        ]
        subscription.merge(overrides) { $1 }
        var root: [String: Any] = ["object": "list", "has_more": false, "data": [subscription] + others]
        root.merge(list) { $1 }
        return try JSONSerialization.data(withJSONObject: root)
    }

    private func billingSignInFixture() -> IsolatedTestURLSession {
        IsolatedTestURLSession { [self] request in
            let wrong = request.value(forHTTPHeaderField: "Cookie")?.contains("=wrong") == true
            let body: Data
            switch request.url?.path {
            case "/api/oauth/profile": body = profile()
            case "/api/account": body = webAccount(owner: wrong ? "other" : nil)
            default: body = claudeBilling()
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
    }

    private func signInCookie(_ value: String) throws -> HTTPCookie {
        try XCTUnwrap(HTTPCookie(properties: [.name: "sessionKey", .value: value, .domain: "claude.ai", .path: "/", .secure: "TRUE"]))
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func claudeBilling(ending: String? = nil) -> Data {
        Data("{\"status\":\"active\",\"next_charge_at\":\"2033-05-20T00:00:00Z\",\"next_charge_date\":null,\"plan_ending_at\":null,\"plan_ending_before\":\(ending.map { "\"\($0)\"" } ?? "null")}".utf8)
    }

    private func grokBilling(owner: String? = nil, cancel: Bool = false, cancelJSON: String? = nil, extra: String = "") -> Data {
        Data("{\"subscriptions\":[{\"xaiUserId\":\"\(owner ?? self.owner)\",\"tier\":\"SUBSCRIPTION_TIER_GROK_PRO\",\"status\":\"SUBSCRIPTION_STATUS_ACTIVE\",\"stripe\":{\"currentPeriodEnd\":\"2033-05-20T00:00:00Z\",\"cancelAtPeriodEnd\":\(cancelJSON ?? (cancel ? "true" : "false"))}\(extra)}]}".utf8)
    }

    private func profile() -> Data {
        Data("{\"account\":{\"uuid\":\"\(owner)\"},\"organization\":{\"uuid\":\"\(organization)\",\"organization_type\":\"claude_max\"}}".utf8)
    }

    private func webAccount(owner: String? = nil) -> Data {
        Data("{\"uuid\":\"\(owner ?? self.owner)\",\"memberships\":[{\"organization\":{\"uuid\":\"\(organization)\"}}]}".utf8)
    }
}

// Records the production decision, then prevents any external fixture document from loading.
@MainActor
private final class BillingPolicyRecorder: NSObject, WKNavigationDelegate {
    let session: SubscriptionBillingSignInSession
    var googleAllowed = false
    var blockProviderLoad = false
    var decisions = [String: WKNavigationActionPolicy]()
    var googleDecisions = 0
    init(_ session: SubscriptionBillingSignInSession) { self.session = session }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        let policy = await session.webView(webView, decidePolicyFor: action)
        if let url = action.request.url { decisions[url.absoluteString] = policy }
        if SubscriptionBillingSignInSession.canonicalHost(action.request.url)?.contains("accounts.google.com") == true {
            googleDecisions += 1
            googleAllowed = googleAllowed || policy == .allow
            return .cancel
        }
        if blockProviderLoad, action.request.url?.host == "claude.ai" { return .cancel }
        return policy
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        (session as WKNavigationDelegate).webView?(webView, didCommit: navigation)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { session.webView(webView, didFinish: navigation) }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        session.webView(webView, didStartProvisionalNavigation: navigation)
    }
}

extension SubscriptionBillingTests {
    /// Supplemental rendering through the native app test host, never an XCUITest or live-account claim.
    @MainActor
    func testBillingRecoveryProductionViewHostEvidence() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        XCTAssertTrue([UIUserInterfaceIdiom.phone, .pad].contains(scene.traitCollection.userInterfaceIdiom))
        for dark in [false, true] {
            let appearance = dark ? "dark-accessibility2" : "light-default"
            let suite = "com.hemsoft.CodexBarIOS.ui-tests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let secrets = UITestSecretStore(suite: suite)
            let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults,
                                                   secretStore: secrets, widgetSnapshotDefaults: defaults)
            UITestFixtures.seedClaudeAccount(in: store, scenario: "claude-renewal-ultra")
            let account = try XCTUnwrap(store.configuration(accountID: "ui-claude"))
            XCTAssertTrue(store.removeSubscriptionBillingSession(for: account))
            let provider = try XCTUnwrap(UITestFixtures.claudeProviders(scenario: "claude-renewal-ultra", suiteName: suite).first)
            let disconnected = try await provider.fetchUsage(for: account)
            XCTAssertNil(disconnected.boundSubscriptionRenewal)
            let model = ProviderSettingsViewModel(configurationStore: store, accountID: account.id, initialUsageResult: disconnected)
            model.startSubscriptionBillingSignIn()
            let session = try XCTUnwrap(model.subscriptionBillingSession)
            defer { session.invalidate() }
            let controller = UIHostingController(rootView: AnyView(EmptyView()))
            let window = UIWindow(windowScene: scene)
            window.frame = scene.coordinateSpace.bounds
            window.overrideUserInterfaceStyle = dark ? .dark : .light
            window.rootViewController = controller
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            func show<Content: View>(_ content: Content) {
                controller.rootView = AnyView(content.environment(\.dynamicTypeSize, dark ? .accessibility2 : .large)
                    .environment(\.colorScheme, dark ? .dark : .light))
            }
            show(SubscriptionBillingSignInView(session: session))
            let loaded = await waitUntil { !session.webView.isLoading && session.webView.url?.host == "claude.ai" }
            XCTAssertTrue(loaded)
            _ = try await session.webView.evaluateJavaScript("window.open('https://accounts.google.com/o/oauth2/auth','auth'); void(0)")
            let denied = await waitUntil { session.routeNotice != nil }
            XCTAssertTrue(denied)
            XCTAssertEqual(session.host, "claude.ai")
            try await captureProductionHost(window, name: "billing-native-host-\(appearance)-google-denied")
            if dark {
                let guidance = try XCTUnwrap(billingScrollViews(in: controller.view).first {
                    $0 !== session.webView.scrollView && $0.bounds.height > window.bounds.height * 0.25
                        && $0.bounds.height < window.bounds.height * 0.6
                }, "Long accessibility guidance needs a scroll container instead of truncation")
                let originalOffset = guidance.contentOffset
                let geometry = XCTAttachment(string: "Guidance scroll frame \(guidance.convert(guidance.bounds, to: window)); "
                    + "content \(guidance.contentSize); offset \(originalOffset); insets \(guidance.adjustedContentInset); "
                    + "window \(window.bounds); identifier \(guidance.accessibilityIdentifier ?? "none")")
                geometry.name = "billing-guidance-scroll-geometry"
                geometry.lifetime = .keepAlways
                add(geometry)
                if guidance.contentSize.height > guidance.bounds.height + 1 {
                    guidance.setContentOffset(CGPoint(x: 0, y: guidance.contentSize.height - guidance.bounds.height), animated: false)
                    XCTAssertGreaterThan(guidance.contentOffset.y, 0)
                    try await captureProductionHost(window, name: "billing-native-host-\(appearance)-guidance-scrolled")
                    guidance.setContentOffset(originalOffset, animated: false)
                }
            }
            session.webViewWebContentProcessDidTerminate(session.webView)
            XCTAssertNil(session.routeNotice, "A terminated page clears the previous route notice")
            XCTAssertTrue(session.message?.contains("closed unexpectedly") == true)
            try await captureProductionHost(window, name: "billing-native-host-\(appearance)-interrupted")
            session.reloadSignIn()
            let reloaded = await waitUntil { !session.webView.isLoading && session.routeNotice == nil }
            XCTAssertTrue(reloaded)
            session.chooseSyntheticAccount(matching: false)
            let wrong = await waitUntil { session.message == SubscriptionBillingError.accountMismatch.localizedDescription }
            XCTAssertTrue(wrong)
            XCTAssertFalse(store.hasSubscriptionBillingSession(for: account))
            session.retrySignIn()
            let reset = await waitUntil { !session.isVerifying && !session.webView.isLoading }
            XCTAssertTrue(reset)
            session.chooseSyntheticAccount(matching: true)
            let connected = await waitUntil { model.subscriptionBillingSession == nil && store.hasSubscriptionBillingSession(for: account) }
            XCTAssertTrue(connected)
            let acquired = try await provider.fetchUsage(for: account)
            XCTAssertNil(acquired.failureMessage)
            XCTAssertEqual(acquired.plan?.accessibilityLabel, "Ultra")
            let renewal = try XCTUnwrap(acquired.boundSubscriptionRenewal)
            XCTAssertNotNil(renewal.compactLabel(at: Date()))
            let header = ProviderUsageCard.disclosureAccessibilityLabel(for: acquired, statusText: "", isRefreshing: false,
                                                                       isPerformingRecovery: false, severity: .normal)
            XCTAssertTrue(header.contains("Renews in"))
            let card = ProviderUsageCard(result: acquired, statusText: "Synthetic provider transport",
                                         showsSubscriptionRenewals: store.showsSubscriptionRenewals,
                                         history: UsageHistorySeries(accountID: account.id, points: [], isBalance: false), isHistoryEnabled: false)
            show(ScrollView { card.padding(20) })
            try await captureProductionHost(window, name: "billing-native-host-\(appearance)-verified-header")
            let sections = ProviderUsageCard.informationSections(for: acquired)
            let billing = try XCTUnwrap(sections.first { $0.id == "subscription-renewal" })
            XCTAssertEqual(billing.items.first?.label, "Next subscription renewal")
            XCTAssertEqual(billing.items.first?.detail, renewal.dateText())
            show(ProviderCardInformationView(sections: sections, greptileRenewal: nil))
            try await captureProductionHost(window, name: "billing-native-host-\(appearance)-verified-date")
        }
        let grok = SubscriptionBillingSignInSession(
            configuration: ProviderAccountConfiguration(id: "synthetic-grok", providerID: .grok, authMethod: .browserSession),
            usageSecret: "synthetic-unused"
        ) { _ in }
        defer { grok.invalidate() }
        let grokWindow = UIWindow(windowScene: scene)
        grokWindow.frame = scene.coordinateSpace.bounds
        grokWindow.overrideUserInterfaceStyle = .light
        grokWindow.rootViewController = UIHostingController(rootView: SubscriptionBillingSignInView(session: grok)
            .environment(\.dynamicTypeSize, .large).environment(\.colorScheme, .light))
        grokWindow.makeKeyAndVisible()
        defer { grokWindow.isHidden = true }
        let loadedGrok = await waitUntil { !grok.webView.isLoading && grok.webView.url?.host == "grok.com" }
        XCTAssertTrue(loadedGrok)
        _ = try await grok.webView.evaluateJavaScript("window.open('https://accounts.google.com/o/oauth2/auth','auth'); void(0)")
        let deniedGrok = await waitUntil { grok.routeNotice?.contains("Grok") == true }
        XCTAssertTrue(deniedGrok)
        try await captureProductionHost(grokWindow, name: "billing-native-host-grok-google-denied")
        grok.cancel()
    }

    @MainActor
    private func billingScrollViews(in view: UIView) -> [UIScrollView] {
        let current = (view as? UIScrollView).map { [$0] } ?? []
        return current + view.subviews.flatMap { billingScrollViews(in: $0) }
    }

    @MainActor
    private func captureProductionHost(_ window: UIWindow, name: String) async throws {
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(400))
        let scene = try XCTUnwrap(window.windowScene)
        XCTAssertEqual(window.bounds.size, scene.coordinateSpace.bounds.size)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scene.screen.scale
        var rendered = false
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            rendered = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        XCTAssertTrue(rendered, "Capture the mounted UIKit/SwiftUI hierarchy, never a recreated image")
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func recoverySession(fixture: IsolatedTestURLSession, completion: @escaping (Result<SubscriptionBillingSession, Error>) -> Void)
        -> SubscriptionBillingSignInSession {
        SubscriptionBillingSignInSession(
            configuration: ProviderAccountConfiguration(id: "claude-personal", providerID: .claude, authMethod: .browserSession),
            usageSecret: "usage-token", client: SubscriptionBillingClient(session: fixture.session), completion: completion
        )
    }

    @MainActor
    private func loadRecoveryPage(_ session: SubscriptionBillingSignInSession) async {
        session.webView.loadHTMLString("<html><body>Provider sign-in</body></html>", baseURL: URL(string: "https://claude.ai/"))
        let loaded = await waitUntil { !session.webView.isLoading && session.webView.url?.host == "claude.ai" }
        XCTAssertTrue(loaded)
    }

    @MainActor
    func testGooglePopupIsDeniedWithoutReplacingProviderAndTerminationExplained() async throws {
        let fixture = billingSignInFixture()
        defer { fixture.invalidate() }
        let account = ProviderAccountConfiguration(id: "claude-personal", providerID: .claude, authMethod: .browserSession)
        let session = SubscriptionBillingSignInSession(configuration: account, usageSecret: "usage-token",
                                                       client: SubscriptionBillingClient(session: fixture.session)) { _ in }
        defer { session.invalidate() }
        let recorder = BillingPolicyRecorder(session)
        session.webView.navigationDelegate = recorder
        session.webView.loadHTMLString("<html><body>Provider sign-in</body></html>", baseURL: URL(string: "https://claude.ai/"))
        let loaded = await waitUntil { !session.webView.isLoading && session.webView.url?.host == "claude.ai" }
        XCTAssertTrue(loaded)
        _ = try await session.webView.evaluateJavaScript("window.open('https://accounts.google.com/o/oauth2/auth','auth'); void(0)")
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(recorder.googleAllowed, "Production must deny Google authorization before its document loads")
        XCTAssertEqual(session.host, "claude.ai", "Keep the provider page and its committed host")
        (session as WKNavigationDelegate).webViewWebContentProcessDidTerminate?(session.webView)
        XCTAssertNotNil(session.message, "A terminated page must explain non-wiping recovery")
    }

    @MainActor
    func testGoogleMainRedirectSubframeAndMalformedPoliciesUseProductionCallbacks() async throws {
        let fixture = billingSignInFixture()
        defer { fixture.invalidate() }
        for provider in [ProviderID.claude, .grok] {
            let account = ProviderAccountConfiguration(id: "personal", providerID: provider, authMethod: .browserSession)
            let session = SubscriptionBillingSignInSession(configuration: account, usageSecret: "usage-token",
                                                           client: SubscriptionBillingClient(session: fixture.session)) { _ in }
            defer { session.invalidate() }
            let recorder = BillingPolicyRecorder(session)
            session.webView.navigationDelegate = recorder
            let providerHost = try XCTUnwrap(SubscriptionBillingSession.host(provider))
            session.webView.loadHTMLString("<html><body>Provider</body></html>", baseURL: URL(string: "https://\(providerHost)/"))
            let loaded = await waitUntil { !session.webView.isLoading && session.webView.url?.host == providerHost }
            XCTAssertTrue(loaded)
            _ = try await session.webView.evaluateJavaScript("var f=document.createElement('iframe'); f.src='https://accounts.google.com/gsi/iframe'; document.body.appendChild(f); void(0)")
            let subframe = await waitUntil { recorder.decisions["https://accounts.google.com/gsi/iframe"] != nil }
            XCTAssertTrue(subframe)
            XCTAssertEqual(recorder.decisions["https://accounts.google.com/gsi/iframe"], .cancel)
            XCTAssertNil(session.routeNotice, "Subframes must be silent and leave the provider page usable")
            for target in ["https://accounts.google.com/o/oauth2/auth", "https://ACCOUNTS.GOOGLE.COM./o/oauth2/auth",
                           "https://sub.accounts.google.com/auth", ] {
                let before = recorder.googleDecisions
                _ = try await session.webView.evaluateJavaScript("window.location.replace('\(target)'); void(0)")
                let denied = await waitUntil { recorder.googleDecisions > before }
                XCTAssertTrue(denied)
                XCTAssertFalse(recorder.googleAllowed)
                XCTAssertTrue(session.routeNotice?.contains(session.providerName) == true)
                XCTAssertEqual(session.host, providerHost)
            }
            for target in ["http://claude.ai/", "https://user:pass@claude.ai/", "https://claude.ai:444/", "about:blank",
                           "blob:https://claude.ai/id", "javascript:void(0)", "data:text/html,test", ] {
                XCTAssertFalse(SubscriptionBillingSignInSession.isSecure(URL(string: target)))
            }
            XCTAssertTrue(SubscriptionBillingSignInSession.isSecure(URL(string: "https://claude.ai:443/")))
            session.webView(session.webView, didFailProvisionalNavigation: nil, withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
            session.webView(session.webView, didFail: nil, withError: NSError(domain: "WebKitErrorDomain", code: 102))
            XCTAssertNil(session.message)
            session.webView(session.webView, didFail: nil, withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut))
            XCTAssertNotNil(session.message, "Actual network failures remain visible")
            session.webView(session.webView, didCommit: nil)
            XCTAssertNil(session.routeNotice)
        }
    }
    @MainActor
    func testLateCookieDiscoveryWithoutObserverOrNavigationCompletesOnce() async throws {
        let fixture = billingSignInFixture()
        defer { fixture.invalidate() }
        var results = [Result<SubscriptionBillingSession, Error>]()
        let session = recoverySession(fixture: fixture) { results.append($0) }
        defer { session.invalidate() }
        let store = session.webView.configuration.websiteDataStore.httpCookieStore
        store.remove(session)
        await loadRecoveryPage(session)
        try await Task.sleep(for: .milliseconds(300))
        await store.setCookie(try signInCookie("matching"))
        let completed = await waitUntil { results.count == 1 }
        XCTAssertTrue(completed, "The finite local discovery finds a cookie without observer/didFinish")
        XCTAssertEqual(try XCTUnwrap(results.first).get().cookies.map(\.value), ["matching"])
        session.verify()
        XCTAssertEqual(results.count, 1)
    }

    @MainActor
    func testSlowConnectSurvivesUnrelatedChurnAndDiscoveryTicks() async throws {
        let requests = BillingRequestCount()
        let fixture = IsolatedTestURLSession { [self] request in
            requests.increment()
            Thread.sleep(forTimeInterval: 0.65)
            let body = request.url?.path == "/api/oauth/profile" ? profile()
                : request.url?.path == "/api/account" ? webAccount() : claudeBilling()
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        defer { fixture.invalidate() }
        var results = [Result<SubscriptionBillingSession, Error>]()
        let session = recoverySession(fixture: fixture) { results.append($0) }
        defer { session.invalidate() }
        await loadRecoveryPage(session)
        let store = session.webView.configuration.websiteDataStore.httpCookieStore
        await store.setCookie(try signInCookie("matching"))
        session.verify()
        let began = await waitUntil { session.isVerifying }
        XCTAssertTrue(began)
        for _ in 0..<8 {
            await store.setCookie(try XCTUnwrap(HTTPCookie(properties: [.name: "unrelated", .value: UUID().uuidString,
                                                                      .domain: "claude.ai", .path: "/", .secure: "TRUE", ])))
            session.cookiesDidChange(in: store)
            session.verify() // Same credential in flight must be a no-op, even for manual intent.
            try await Task.sleep(for: .milliseconds(450))
        }
        let completed = await waitUntil { results.count == 1 }
        XCTAssertTrue(completed)
        XCTAssertEqual(requests.value, 6, "One real connect makes six identity/billing requests; polling never restarts it")
    }

    @MainActor
    func testFailedCredentialHasFiniteAutomaticBudgetAndManualRetry() async throws {
        let requests = BillingRequestCount()
        let fixture = IsolatedTestURLSession { [self] request in
            requests.increment()
            let body = request.url?.path == "/api/oauth/profile" ? profile() : webAccount(owner: "other")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        defer { fixture.invalidate() }
        let session = recoverySession(fixture: fixture) { _ in XCTFail("Wrong account must stay open") }
        defer { session.invalidate() }
        await loadRecoveryPage(session)
        let store = session.webView.configuration.websiteDataStore.httpCookieStore
        await store.setCookie(try signInCookie("wrong"))
        session.verify()
        let failed = await waitUntil { session.message == SubscriptionBillingError.accountMismatch.localizedDescription }
        XCTAssertTrue(failed)
        await store.setCookie(try signInCookie("wrong-again"))
        session.verify()
        let secondFailed = await waitUntil { requests.value == 6 && !session.isVerifying }
        XCTAssertTrue(secondFailed)
        await store.setCookie(try signInCookie("wrong"))
        let count = requests.value
        for _ in 0..<32 {
            session.cookiesDidChange(in: store)
            session.webView(session.webView, didFinish: nil)
            try await Task.sleep(for: .milliseconds(500))
        }
        XCTAssertEqual(requests.value, count, "Identical failed credentials never automatically retry")
        XCTAssertLessThanOrEqual(session.automaticCookieReadCount, 6)
        let reads = session.automaticCookieReadCount
        session.webView(session.webView, didCommit: nil)
        session.cookiesDidChange(in: store)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(session.automaticCookieReadCount, reads, "Events cannot renew an exhausted generation budget")
        session.verify()
        let retried = await waitUntil { requests.value == count + 3 && !session.isVerifying }
        XCTAssertTrue(retried, "Explicit manual intent can retry the same credential")
    }

    @MainActor
    func testUnobservedRemovalBeforeConnectReturnsCannotComplete() async throws {
        let requests = BillingRequestCount()
        let gate = TestRequestGate()
        defer { gate.release() }
        let fixture = IsolatedTestURLSession { [self] request in
            requests.increment()
            if requests.value == 6 { gate.blockUntilReleased() }
            let body = request.url?.path == "/api/oauth/profile" ? profile()
                : request.url?.path == "/api/account" ? webAccount() : claudeBilling()
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        defer { fixture.invalidate() }
        var results = [Result<SubscriptionBillingSession, Error>]()
        let session = recoverySession(fixture: fixture) { results.append($0) }
        defer { session.invalidate() }
        let store = session.webView.configuration.websiteDataStore.httpCookieStore
        store.remove(session)
        await loadRecoveryPage(session)
        let cookie = try signInCookie("matching")
        await store.setCookie(cookie)
        session.verify()
        let blocked = await waitUntil { requests.value == 6 }
        XCTAssertTrue(blocked)
        await store.deleteCookie(cookie)
        gate.release()
        let rejected = await waitUntil { !session.isVerifying && session.message?.contains("changed during verification") == true }
        XCTAssertTrue(rejected)
        XCTAssertTrue(results.isEmpty, "No stale success even when no observer fired")
    }

    @MainActor
    func testNewCredentialSupersedesSlowAttemptAndCancelIsExactlyOnce() async throws {
        for cancel in [false, true] {
            let requests = BillingRequestCount()
            let gate = TestRequestGate()
            defer { gate.release() }
            let fixture = IsolatedTestURLSession { [self] request in
                requests.increment()
                if requests.value == 1 { gate.blockUntilReleased() }
                let wrong = request.value(forHTTPHeaderField: "Cookie")?.contains("=wrong") == true
                let body = request.url?.path == "/api/oauth/profile" ? profile()
                    : request.url?.path == "/api/account" ? webAccount(owner: wrong ? "other" : nil) : claudeBilling()
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
            }
            defer { fixture.invalidate() }
            var results = [Result<SubscriptionBillingSession, Error>]()
            let session = recoverySession(fixture: fixture) { results.append($0) }
            defer { session.invalidate() }
            await loadRecoveryPage(session)
            let store = session.webView.configuration.websiteDataStore.httpCookieStore
            await store.setCookie(try signInCookie("wrong"))
            session.verify()
            let blocked = await waitUntil { requests.value == 1 }
            XCTAssertTrue(blocked)
            await store.setCookie(try signInCookie("matching"))
            session.verify()
            if cancel { session.cancel() }
            gate.release()
            let completed = await waitUntil { results.count == 1 }
            XCTAssertTrue(completed)
            if cancel {
                XCTAssertThrowsError(try results.first?.get())
            } else {
                XCTAssertEqual(try XCTUnwrap(results.first).get().cookies.map(\.value), ["matching"])
            }
            session.cancel()
            session.cookiesDidChange(in: store)
            try await Task.sleep(for: .milliseconds(250))
            XCTAssertEqual(results.count, 1, "Canceled/superseded callbacks cannot report a second outcome")
        }
    }

    @MainActor
    func testStartOverInvalidatesSlowSuccessWithoutReportingOrSaving() async throws {
        let requests = BillingRequestCount()
        let gate = TestRequestGate()
        defer { gate.release() }
        let fixture = IsolatedTestURLSession { [self] request in
            requests.increment()
            if requests.value == 6 { gate.blockUntilReleased() }
            let body = request.url?.path == "/api/oauth/profile" ? profile()
                : request.url?.path == "/api/account" ? webAccount() : claudeBilling()
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        defer { fixture.invalidate() }
        var results = [Result<SubscriptionBillingSession, Error>]()
        let session = recoverySession(fixture: fixture) { results.append($0) }
        defer { session.invalidate() }
        await loadRecoveryPage(session)
        let store = session.webView.configuration.websiteDataStore.httpCookieStore
        await store.setCookie(try signInCookie("matching"))
        session.verify()
        let blocked = await waitUntil { requests.value == 6 }
        XCTAssertTrue(blocked)
        session.retrySignIn()
        gate.release()
        let reset = await waitUntil { !session.isVerifying && !session.webView.isLoading }
        XCTAssertTrue(reset)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(results.isEmpty, "Generation change prevents the old successful connect from completing")
    }

    @MainActor
    func testTerminationReloadPreservesCookiesAndExplicitStartOverWipesThem() async throws {
        let fixture = billingSignInFixture()
        defer { fixture.invalidate() }
        let session = recoverySession(fixture: fixture) { _ in XCTFail("Recovery must not save an unverified session") }
        defer { session.invalidate() }
        let recorder = BillingPolicyRecorder(session)
        session.webView.navigationDelegate = recorder
        let store = session.webView.configuration.websiteDataStore.httpCookieStore
        store.remove(session)
        await loadRecoveryPage(session)
        await store.setCookie(try signInCookie("wrong"))
        recorder.blockProviderLoad = true // Recovery request goes through production policy but never reaches a provider.
        session.webViewWebContentProcessDidTerminate(session.webView)
        XCTAssertNotNil(session.message)
        session.reloadSignIn()
        var cookies = await withCheckedContinuation { continuation in store.getAllCookies { continuation.resume(returning: $0) } }
        XCTAssertEqual(SubscriptionBillingSession.capture(cookies, provider: .claude).map(\.value), ["wrong"])
        XCTAssertNil(session.message)
        session.retrySignIn()
        let reset = await waitUntil { !session.isVerifying }
        XCTAssertTrue(reset)
        cookies = await withCheckedContinuation { continuation in store.getAllCookies { continuation.resume(returning: $0) } }
        XCTAssertTrue(SubscriptionBillingSession.capture(cookies, provider: .claude).isEmpty)
        XCTAssertEqual(session.automaticCookieReadCount, 0)
    }

    @MainActor
    func testGrokUsesItsCapturedCookieSetRatherThanClaudeSessionKey() async throws {
        let account = ProviderAccountConfiguration(id: "grok-personal", providerID: .grok, authMethod: .browserSession)
        let usage = try GrokCredential(kind: "grok-oauth-v1", accessToken: "usage-token", refreshToken: "refresh",
                                       expiresAt: Date().addingTimeInterval(3600), subject: owner, email: nil).encoded()
        let requests = BillingRequestCount()
        let fixture = IsolatedTestURLSession { [self] request in
            requests.increment()
            Thread.sleep(forTimeInterval: 1.7)
            XCTAssertEqual(Set((request.value(forHTTPHeaderField: "Cookie") ?? "").components(separatedBy: "; ")),
                           ["billing-fixture=matching", "commerce=second"])
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, grokBilling())
        }
        defer { fixture.invalidate() }
        var results = [Result<SubscriptionBillingSession, Error>]()
        let session = SubscriptionBillingSignInSession(configuration: account, usageSecret: usage,
                                                       client: SubscriptionBillingClient(session: fixture.session)) { results.append($0) }
        defer { session.invalidate() }
        let store = session.webView.configuration.websiteDataStore.httpCookieStore
        store.remove(session)
        session.webView.loadHTMLString("<html><body>Grok billing fixture</body></html>", baseURL: URL(string: "https://grok.com/"))
        let loaded = await waitUntil { !session.webView.isLoading && session.webView.url?.host == "grok.com" }
        XCTAssertTrue(loaded)
        for (name, value) in [("billing-fixture", "matching"), ("commerce", "second")] {
            await store.setCookie(try XCTUnwrap(HTTPCookie(properties: [.name: name, .value: value, .domain: "grok.com", .path: "/", .secure: "TRUE"])))
        }
        session.verify()
        for _ in 0..<7 {
            session.cookiesDidChange(in: store)
            session.webView(session.webView, didFinish: nil)
            try await Task.sleep(for: .milliseconds(450))
        }
        let completed = await waitUntil { results.count == 1 }
        XCTAssertTrue(completed)
        XCTAssertEqual(Set(try XCTUnwrap(results.first).get().cookies.map(\.name)), ["billing-fixture", "commerce"])
        XCTAssertEqual(requests.value, 2)
    }
}

private final class BillingRequestCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private final class BillingMutationSecretStore: SecretStore, @unchecked Sendable {
    private let storage = MemorySecretStore()
    var failingSaveAccount: String?
    var failingReadAccount: String?
    var failingDeleteAccount: String?

    func readSecret(account: String) throws -> String? {
        if account == failingReadAccount { throw KeychainError.unhandledStatus(-25308) }
        return try storage.readSecret(account: account)
    }

    func saveSecret(_ secret: String, account: String) throws {
        if account == failingSaveAccount { throw KeychainError.unhandledStatus(-25308) }
        try storage.saveSecret(secret, account: account)
    }

    func deleteSecret(account: String) throws {
        if account == failingDeleteAccount { throw KeychainError.unhandledStatus(-25308) }
        try storage.deleteSecret(account: account)
    }
}

private final class TransientBillingReadSecretStore: SecretStore, @unchecked Sendable {
    private let storage = MemorySecretStore()
    private let lock = NSLock()
    private let account: String
    private let failureNumber: Int
    private var reads = 0

    init(account: String, failureNumber: Int) { self.account = account; self.failureNumber = failureNumber }

    func readSecret(account: String) throws -> String? {
        let fails = lock.withLock {
            guard account == self.account else { return false }
            reads += 1
            return reads == failureNumber
        }
        if fails { throw KeychainError.unhandledStatus(-25308) }
        return try storage.readSecret(account: account)
    }

    func saveSecret(_ secret: String, account: String) throws { try storage.saveSecret(secret, account: account) }
    func deleteSecret(account: String) throws { try storage.deleteSecret(account: account) }
}
