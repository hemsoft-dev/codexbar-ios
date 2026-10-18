import Foundation
import XCTest
@testable import CodexBarIOS

final class SubscriptionBillingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private let owner = "11111111-1111-4111-8111-111111111111"
    private let organization = "22222222-2222-4222-8222-222222222222"
    private let cookie = SubscriptionBillingSession.Cookie(name: "sessionKey", value: "synthetic", expiresAt: nil)

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
