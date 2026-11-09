import XCTest
@testable import CodexBarIOS

final class AntigravityUsageProviderTests: XCTestCase {
    @MainActor
    func testCodingReconnectPreservesSavedSessionWhenCandidateUsageFails() async throws {
        for status in [401, 403, 500, 200] {
            let suite = "CodingValidation.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let secrets = MemorySecretStore()
            let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secrets)
            let account = try XCTUnwrap(store.addAccount(for: .gemini))
            let original = #"{"access_token":"working"}"#
            XCTAssertTrue(store.saveGeminiCodingSecret(original, for: account, confirmedSameAccount: true))
            let fixture = IsolatedTestURLSession { request in
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer candidate")
                return (try Self.response(request, status: status), try Self.payload([]))
            }
            defer { fixture.invalidate() }
            var refreshCount = 0
            let model = ProviderSettingsViewModel(
                configurationStore: store, accountID: account.id,
                onCredentialRefresh: { _ in refreshCount += 1; return nil }
            )
            model.googleCodingUsageProvider = AntigravityUsageProvider(
                secretStore: secrets, sessionConfiguration: fixture.session.configuration
            )
            do {
                try await model.saveValidatedGoogleCodingCredential(
                    AntigravityCredentials.parse(#"{"access_token":"candidate"}"#)
                )
                XCTFail("An unusable coding grant must be rejected")
            } catch { }
            XCTAssertEqual(try secrets.readSecret(
                account: ProviderConfigurationStore.geminiCodingKeychainAccount(accountID: account.id)
            ), original)
            XCTAssertEqual(refreshCount, 0)
        }
    }

    @MainActor
    func testCodingReconnectValidatesBeforeSavingAndRefreshesOnce() async throws {
        try await verifyCodingReconnect(hasAppsSession: true)
        try await verifyCodingReconnect(hasAppsSession: false)
    }

    @MainActor
    private func verifyCodingReconnect(hasAppsSession: Bool) async throws {
        let suite = "CodingValidation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = MemorySecretStore()
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secrets)
        let account = try XCTUnwrap(store.addAccount(for: .gemini))
        if hasAppsSession {
            XCTAssertTrue(store.saveSecret("__Secure-1PSID=apps", for: account))
        }
        let key = ProviderConfigurationStore.geminiCodingKeychainAccount(accountID: account.id)
        let original = #"{"access_token":"working"}"#
        XCTAssertTrue(store.saveGeminiCodingSecret(original, for: account, confirmedSameAccount: true))
        let fixture = IsolatedTestURLSession { request in
            XCTAssertEqual(try secrets.readSecret(account: key), original)
            return (try Self.response(request, status: 200), try Self.payload())
        }
        defer { fixture.invalidate() }
        var refreshCount = 0
        let refreshed = expectation(description: "One credential refresh")
        refreshed.assertForOverFulfill = true
        let model = ProviderSettingsViewModel(
            configurationStore: store, accountID: account.id,
            onCredentialRefresh: { _ in
                refreshCount += 1
                await Task.yield()
                refreshed.fulfill()
                return nil
            }
        )
        model.googleCodingUsageProvider = AntigravityUsageProvider(
            secretStore: secrets, sessionConfiguration: fixture.session.configuration
        )
        let candidate = try AntigravityCredentials.parse(#"{"access_token":"candidate"}"#)
        try await model.receiveGoogleCodingCredential(candidate)
        XCTAssertTrue(model.needsGoogleCodingAccountConfirmation)
        XCTAssertEqual(try secrets.readSecret(account: key), original)
        model.cancelGoogleCodingSignIn()
        model.confirmGoogleCodingAccount()
        XCTAssertEqual(try secrets.readSecret(account: key), original)
        try await model.receiveGoogleCodingCredential(candidate)
        model.confirmGoogleCodingAccount()
        await fulfillment(of: [refreshed], timeout: 3)
        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(model.geminiCodingMessage, "Coding account connected.")
        let saved = try XCTUnwrap(secrets.readSecret(account: key))
        XCTAssertEqual(try AntigravityCredentials.parse(saved).accessToken, "candidate")
    }

    @MainActor
    func testDevelopmentHandoffRequiresOptInAndDeletesStagingFile() throws {
        let suite = "CodingHandoff.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = SelectiveReadFailureSecretStore()
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secrets)
        let account = try XCTUnwrap(store.addAccount(for: .gemini))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(DeveloperGoogleSessionInstaller.fileName)
        let credential = #"{"access_token":"sample","refresh_token":"renew","client_id":"client","client_secret":"secret"}"#
        func stage(accountID: String) throws {
            let data = try JSONSerialization.data(withJSONObject: [
                "accountID": accountID, "credential": credential, "confirmedSameAccount": true
            ])
            try data.write(to: file)
        }
        try stage(accountID: account.id)
        XCTAssertFalse(DeveloperGoogleSessionInstaller.installIfRequested(
            configurationStore: store, arguments: [], directory: directory
        ))
        XCTAssertFalse(store.hasGeminiCodingSecret(for: account))
        try stage(accountID: "unknown")
        XCTAssertFalse(DeveloperGoogleSessionInstaller.installIfRequested(
            configurationStore: store, arguments: [DeveloperGoogleSessionInstaller.launchArgument], directory: directory
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let key = ProviderConfigurationStore.geminiCodingKeychainAccount(accountID: account.id)
        try secrets.saveSecret("existing-session", account: key)
        secrets.failingAccount = key
        try stage(accountID: account.id)
        XCTAssertFalse(DeveloperGoogleSessionInstaller.installIfRequested(
            configurationStore: store, arguments: [DeveloperGoogleSessionInstaller.launchArgument], directory: directory
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        secrets.failingAccount = nil
        XCTAssertEqual(try secrets.readSecret(account: key), "existing-session")
        try secrets.deleteSecret(account: key)
        try stage(accountID: account.id)
        XCTAssertTrue(DeveloperGoogleSessionInstaller.installIfRequested(
            configurationStore: store, arguments: [DeveloperGoogleSessionInstaller.launchArgument], directory: directory
        ))
        XCTAssertTrue(store.hasGeminiCodingSecret(for: account))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        try stage(accountID: account.id)
        XCTAssertFalse(DeveloperGoogleSessionInstaller.installIfRequested(
            configurationStore: store, arguments: [DeveloperGoogleSessionInstaller.launchArgument], directory: directory
        ))
    }

    @MainActor
    func testCodingCallbackRejectsUnexpectedStateHostAndDuplicateCodes() throws {
        let config = try GoogleCodingSignIn.Configuration(clientID: "123-example.apps.googleusercontent.com")
        let base = config.redirectURI
        XCTAssertEqual(try GoogleCodingSignIn.authorizationCode(
            URL(string: base + "?state=expected&code=valid")!, configuration: config, state: "expected"
        ), "valid")
        for suffix in ["?state=wrong&code=valid", "?state=expected&code=a&code=b", "?state=expected&error=access_denied"] {
            XCTAssertThrowsError(try GoogleCodingSignIn.authorizationCode(
                URL(string: base + suffix)!, configuration: config, state: "expected"
            ))
        }
        XCTAssertThrowsError(try GoogleCodingSignIn.authorizationCode(
            URL(string: config.callbackScheme + "://attacker/oauthredirect?state=expected&code=a")!,
            configuration: config, state: "expected"
        ))
    }

    @MainActor
    func testCodingClientConfigurationFailsClosedAndRequestsOfflinePKCE() throws {
        for invalid in ["", "$(GOOGLE_CODING_CLIENT_ID)", "invalid", "bad/path.apps.googleusercontent.com"] {
            XCTAssertThrowsError(try GoogleCodingSignIn.Configuration(clientID: invalid))
        }
        let config = try GoogleCodingSignIn.Configuration(clientID: "123-example.apps.googleusercontent.com")
        let url = GoogleCodingSignIn.authorizationURL(configuration: config, state: "state", challenge: "challenge")
        let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(parts.host, "accounts.google.com")
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(items["code_challenge"], "challenge")
        XCTAssertEqual(items["access_type"], "offline")
        XCTAssertEqual(items["redirect_uri"], config.redirectURI)
    }

    @MainActor
    func testCodingTokenExchangeUsesPKCEAndNoEmbeddedSecret() throws {
        let config = try GoogleCodingSignIn.Configuration(clientID: "123-example.apps.googleusercontent.com")
        let request = GoogleCodingSignIn.tokenRequest(code: "a+b", verifier: "verifier", configuration: config)
        let body = try XCTUnwrap(String(data: try XCTUnwrap(request.httpBody), encoding: .utf8))
        XCTAssertTrue(body.contains("code=a%2Bb"))
        XCTAssertTrue(body.contains("code_verifier=verifier"))
        XCTAssertFalse(body.contains("client_secret"))
        XCTAssertEqual(request.url?.host, "oauth2.googleapis.com")
        XCTAssertFalse(request.httpShouldHandleCookies)
    }

    @MainActor
    func testNativeCodingCredentialsRejectMissingRenewalToken() {
        for payload in [
            #"{"access_token":"sample","token_type":"Bearer","expires_in":3600}"#,
            #"{"access_token":"sample","refresh_token":"","token_type":"Bearer","expires_in":3600}"#,
            #"{"access_token":"sample","refresh_token":"  ","token_type":"Bearer","expires_in":3600}"#,
        ] {
            XCTAssertThrowsError(try GoogleCodingSignIn.credentials(
                Data(payload.utf8), clientID: "example", now: Self.now
            ))
        }
    }

    @MainActor
    func testNativeCodingCredentialsPreservePublicClientRenewal() throws {
        let payload = Data(#"{"access_token":"sample","refresh_token":"renew","token_type":"Bearer","expires_in":3600}"#.utf8)
        let credential = try GoogleCodingSignIn.credentials(payload, clientID: "123-example.apps.googleusercontent.com", now: Self.now)
        XCTAssertTrue(credential.canRefresh)
        XCTAssertEqual(credential.expiry, Self.now.addingTimeInterval(3600))
        let restored = try AntigravityCredentials.parse(credential.encoded())
        XCTAssertTrue(restored.canRefresh)
        XCTAssertNil(restored.clientSecret)
        for invalid in [#"{"access_token":"sample","refresh_token":"renew","token_type":"Basic","expires_in":3600}"#,
                        #"{"access_token":"","refresh_token":"renew","token_type":"Bearer","expires_in":3600}"#,
                        #"{"access_token":"sample","refresh_token":"renew","token_type":"Bearer","expires_in":-1}"#,
        ] {
            XCTAssertThrowsError(try GoogleCodingSignIn.credentials(Data(invalid.utf8), clientID: "example"))
        }
    }

    private static let configuration = ProviderAccountConfiguration(
        id: "antigravity-test", providerID: .antigravity, authMethod: .cliToken
    )
    private static let now = Date(timeIntervalSince1970: 1_788_640_000)

    func testFiveIndependentBucketsConvertRemainingExactlyOnce() throws {
        let result = try Self.result(Self.payload())
        XCTAssertEqual(result.providerID, .antigravity)
        XCTAssertEqual(result.bars.map(\.stableKey), ["gemini-5h", "gemini-weekly", "gemini-argon-wtu-weekly", "3p-5h", "3p-weekly"])
        XCTAssertEqual(result.bars.map(\.usageText), ["100%", "31%", "50%", "20%", "60%"])
        XCTAssertEqual(result.bars[1].used, 31, accuracy: 0.000_001)
        XCTAssertEqual(result.bars[0].severity, .critical)
        XCTAssertEqual(result.bars[1].resetsAt, AntigravityQuotaParser.date("2030-09-11T16:22:20Z"))
        XCTAssertNil(result.failureMessage)
    }

    func testArgonIsIndependentAndOmittedPoolsNeverBecomeZero() throws {
        var buckets = Self.buckets()
        buckets.removeAll { ["gemini-weekly", "gemini-argon-wtu-weekly"].contains($0["bucketId"] as? String ?? "") }
        let absent = try Self.result(Self.payload(buckets))
        for key in ["gemini-weekly", "gemini-argon-wtu-weekly"] {
            XCTAssertFalse(absent.bars.contains { $0.stableKey == key })
            XCTAssertEqual(absent.unavailableUsageMetrics["antigravity.\(key)"], "Unavailable")
        }
        let now = Self.now
        buckets.append(["bucketId": "gemini-argon-wtu-weekly", "window": "weekly", "remainingFraction": 0.6,
                        "resetTime": ISO8601DateFormatter().string(from: now.addingTimeInterval(84 * 3_600)),
        ])
        let present = try Self.result(Self.payload(buckets))
        let argon = try XCTUnwrap(present.bars.first { $0.stableKey == "gemini-argon-wtu-weekly" })
        XCTAssertEqual(argon.used, 40, accuracy: 0.000_001)
        XCTAssertEqual(present.unavailableUsageMetrics["antigravity.gemini-weekly"], "Unavailable")
    }

    func testMissingDisabledDuplicateAndInvalidBucketsStayUnavailable() throws {
        let invalid: [Any] = [NSNull(), -0.1, 1.1]
        for fraction in invalid {
            var buckets = Self.buckets()
            buckets[0]["remainingFraction"] = fraction
            let result = try Self.result(Self.payload(buckets))
            XCTAssertEqual(result.bars.count, 4)
            XCTAssertFalse(result.bars.contains { $0.stableKey == "gemini-5h" })
            XCTAssertEqual(result.usageMessages, ["Unavailable: Gemini Models five-hour."])
        }
        for mutation in ["disabled", "window", "resetTime", "duplicate", "missing"] {
            var buckets = Self.buckets()
            switch mutation {
            case "disabled": buckets[0]["disabled"] = true
            case "window": buckets[0]["window"] = "weekly"
            case "resetTime": buckets[0]["resetTime"] = "2020-01-01T00:00:00Z"
            case "duplicate": buckets.append(buckets[0])
            default: buckets.removeFirst()
            }
            XCTAssertEqual(try Self.result(Self.payload(buckets)).bars.count, 4)
        }
    }

    func testEmptyWrongShapeAndNonNumericFractionsCannotBecomeZeroUsage() throws {
        let empty = try Self.result(Self.payload([]))
        XCTAssertNotNil(empty.failureMessage)
        XCTAssertTrue(empty.bars.isEmpty)
        for data in [Data("{}".utf8), Data("not JSON".utf8)] {
            XCTAssertThrowsError(try Self.result(data))
        }
        let wrongTypes: [(String, Any)] = [
            ("remainingFraction", true), ("remainingFraction", "0.69"), ("disabled", "false"),
            ("window", 5), ("resetTime", 1_788_640_000),
        ]
        for (field, invalid) in wrongTypes {
            var buckets = Self.buckets()
            buckets[0][field] = invalid
            let result = try Self.result(Self.payload(buckets))
            XCTAssertEqual(result.bars.map(\.stableKey), ["gemini-weekly", "gemini-argon-wtu-weekly", "3p-5h", "3p-weekly"], field)
            XCTAssertEqual(result.unavailableUsageMetrics["antigravity.gemini-5h"], "Unavailable", field)
        }
    }

    /// Quota groups can carry entries CodexBar doesn't use. Before #553, one of these voided the whole
    /// summary, so the other backend answered without Gemini Models or Argon.
    func testUnrelatedOrMalformedPrimaryEntriesDoNotHideGeminiPools() async throws {
        let secrets = MemorySecretStore()
        try secrets.saveSecret(#"{"access_token":"test"}"#, account: ProviderConfigurationStore.keychainAccount(for: Self.configuration))
        let hosts = LockedHosts()
        var malformedOther = Self.buckets()
        malformedOther[3]["remainingFraction"] = "0.8"
        let groups: [[String: Any]] = [
            ["displayName": "Gemini Models", "buckets": Array(malformedOther.prefix(2))],
            ["displayName": "Gemini 4 Argon", "buckets": [malformedOther[2]]],
            ["displayName": "Claude and GPT models", "buckets": Array(malformedOther.suffix(2))],
            ["displayName": "Image models"],
            ["buckets": [["displayName": "Session", "window": "5h", "remainingFraction": 0.2], 42, NSNull()]],
        ]
        let primary = try JSONSerialization.data(withJSONObject: ["groups": groups])
        let fixture = IsolatedTestURLSession { request in
            hosts.append(request.url)
            let otherModelsOnly = Self.buckets().filter { ($0["bucketId"] as? String)?.hasPrefix("3p-") == true }
            let isFallback = request.url == AntigravityUsageProvider.fallbackQuotaURL
            return (try Self.response(request, status: 200), isFallback ? try Self.payload(otherModelsOnly) : primary)
        }
        defer { fixture.invalidate() }
        let provider = AntigravityUsageProvider(secretStore: secrets, sessionConfiguration: fixture.session.configuration)
        let result = try await provider.fetchUsage(for: Self.configuration)
        XCTAssertEqual(hosts.values, ["daily-cloudcode-pa.googleapis.com"])
        XCTAssertEqual(result.bars.map(\.stableKey), ["gemini-5h", "gemini-weekly", "gemini-argon-wtu-weekly", "3p-weekly"])
        XCTAssertEqual(result.unavailableUsageMetrics, ["antigravity.3p-5h": "Unavailable"])
        XCTAssertEqual(result.usageMessages, ["Unavailable: Other models five-hour."])
    }

    func testFallbackAnswerSaysWhyThePrimaryBackendWasNotUsed() async throws {
        let full = Self.buckets().map { bucket -> [String: Any] in
            var copy = bucket
            copy["remainingFraction"] = 1
            return copy
        }
        let unrelated = try Self.payload([["bucketId": "unrelated", "window": "weekly", "remainingFraction": 0.5]])
        let cases: [(String, Int?, Data, String)] = [
            ("503", 503, Data(), "returned HTTP 503"),
            ("404", 404, Data(), "returned HTTP 404"),
            ("transport", nil, Data(), "couldn't be reached"),
            ("unreadable", 200, Data("not json".utf8), "sent a response CodexBar couldn't read"),
            ("no pool", 200, unrelated, "reported no current pool"),
            ("placeholder", 200, try Self.payload(full), "reported every pool full, which CodexBar ignores"),
        ]
        for (label, status, body, reason) in cases {
            for (fallbackHasGemini, named) in [(false, false), (false, true), (true, false), (true, true)] {
                let secrets = MemorySecretStore()
                try secrets.saveSecret(
                    #"{"access_token":"test"}"#, account: ProviderConfigurationStore.keychainAccount(for: Self.configuration)
                )
                let fixture = IsolatedTestURLSession { request in
                    if request.url == AntigravityUsageProvider.planURL {
                        return named
                            ? (try Self.response(request, status: 200), Self.codeAssist)
                            : (try Self.response(request, status: 503), Data())
                    }
                    XCTAssertEqual(Self.requestedProject(request), named ? "fake-project-123" : nil, label)
                    if request.url == AntigravityUsageProvider.fallbackQuotaURL {
                        let fallback = Self.buckets().filter {
                            fallbackHasGemini || ($0["bucketId"] as? String)?.hasPrefix("3p-") == true
                        }
                        return (try Self.response(request, status: 200), try Self.payload(fallback))
                    }
                    guard let status else { throw URLError(.notConnectedToInternet) }
                    return (try Self.response(request, status: status), body)
                }
                defer { fixture.invalidate() }
                let provider = AntigravityUsageProvider(secretStore: secrets, sessionConfiguration: fixture.session.configuration)
                let result = try await provider.fetchUsage(for: Self.configuration)
                let scope = named ? "When asked for this account's project" : "When asked without a project"
                let note = "\(scope), the quota service Antigravity reads \(reason). These quotas come from Google's "
                    + "other quota service, which can differ from Antigravity or leave pools out."
                // The fallback's numbers can differ from Antigravity's, so the note shows even when all pools arrive.
                if fallbackHasGemini {
                    XCTAssertEqual(result.bars.count, 5, label)
                    XCTAssertEqual(result.usageMessages, [note], label)
                } else {
                    XCTAssertEqual(result.bars.map(\.stableKey), ["3p-5h", "3p-weekly"], label)
                    XCTAssertEqual(result.usageMessages.last, note, label)
                }
                XCTAssertFalse(result.usageMessages.joined().contains("not json"), label)
                XCTAssertFalse(result.usageMessages.joined().contains("fake-project-123"), label)
            }
        }
    }

    /// #519, November 9, 2026, measured live with the Antigravity CLI's own sign-in: Google returns quota pools by
    /// client. A bare `antigravity` User-Agent (CodexBar before this fix) got only the two other-models pools, all
    /// full, on both backends, which is the phone's "Unavailable" card. The CLI's `antigravity/cli/<version>` got all
    /// five. With it, the daily backend matched the CLI's `/usage` exactly, while production read Gemini weekly 0.8238
    /// and Argon 1.0. Hosts are literal here so the same test fails on 3f72ccd.
    func testGooglesClientGatedPoolsReachTheCardAndMatchTheCLI() async throws {
        let secrets = MemorySecretStore()
        try secrets.saveSecret(#"{"access_token":"test"}"#, account: ProviderConfigurationStore.keychainAccount(for: Self.configuration))
        let hosts = LockedHosts()
        let agents = LockedURLs()
        func pools(_ fractions: [String: Double]) throws -> Data {
            try Self.payload(AntigravityQuotaParser.metrics.compactMap { metric in
                fractions[metric.key].map { fraction -> [String: Any] in
                    [
                        "bucketId": metric.key, "window": metric.window, "remainingFraction": fraction,
                        "resetTime": "2030-09-11T16:22:20Z",
                    ]
                }
            })
        }
        let fixture = IsolatedTestURLSession { request in
            hosts.append(request.url)
            let agent = request.value(forHTTPHeaderField: "User-Agent") ?? ""
            agents.append(URL(string: "ua:" + (agent.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")))
            if request.url?.path.hasSuffix(":loadCodeAssist") == true {
                return (try Self.response(request, status: 200), Self.codeAssist)
            }
            guard agent.hasPrefix("antigravity/cli/") else {
                return (try Self.response(request, status: 200), try pools(["3p-5h": 1, "3p-weekly": 1]))
            }
            let daily = request.url?.host == "daily-cloudcode-pa.googleapis.com"
            return (try Self.response(request, status: 200), try pools([
                "gemini-5h": 1, "gemini-weekly": daily ? 0.7615368 : 0.82383215,
                "gemini-argon-wtu-weekly": daily ? 0.9806056 : 1, "3p-5h": 1, "3p-weekly": 1,
            ]))
        }
        defer { fixture.invalidate() }
        let provider = AntigravityUsageProvider(secretStore: secrets, sessionConfiguration: fixture.session.configuration)
        let result = try await provider.fetchUsage(for: Self.configuration)
        XCTAssertEqual(hosts.values, ["daily-cloudcode-pa.googleapis.com"])
        XCTAssertEqual(Set(agents.values.map { $0?.absoluteString }), ["ua:antigravity%2Fcli%2F1%2E5%2E3"])
        XCTAssertEqual(result.bars.map(\.stableKey), ["gemini-5h", "gemini-weekly", "gemini-argon-wtu-weekly", "3p-5h", "3p-weekly"])
        let used = Dictionary(uniqueKeysWithValues: result.bars.map { ($0.stableKey, $0.used) })
        XCTAssertEqual(used["gemini-weekly"] ?? -1, 23.84632, accuracy: 0.000_01)
        XCTAssertEqual(used["gemini-argon-wtu-weekly"] ?? -1, 1.93944, accuracy: 0.000_01)
        XCTAssertTrue(result.unavailableUsageMetrics.isEmpty)
        XCTAssertTrue(result.usageMessages.isEmpty)
    }

    func testResetMayBeAbsentButMalformedResetMakesBucketUnavailable() throws {
        var buckets = Self.buckets()
        buckets[0].removeValue(forKey: "resetTime")
        XCTAssertNil(try Self.result(Self.payload(buckets)).bars.first?.resetsAt)
        buckets[0]["resetTime"] = "not a date"
        XCTAssertEqual(try Self.result(Self.payload(buckets)).bars.count, 4)
        XCTAssertNotNil(AntigravityQuotaParser.date("2030-09-11T16:22:20.123Z"))
    }

    func testCredentialImportNormalizesFlatAndCLIProfiles() throws {
        let flat = try AntigravityCredentials.parse(#"{"access_token":"token","refresh_token":"refresh","client_id":"client","client_secret":"secret","expiry_date":1900000000000,"email":"discard"}"#)
        XCTAssertTrue(flat.canRefresh)
        XCTAssertEqual(try AntigravityCredentials.parse(flat.encoded()), flat)
        XCTAssertFalse(try flat.encoded().contains("discard"))
        let nested = try AntigravityCredentials.parse(#"{"token":{"access_token":"token","expiry":"2030-01-01T00:00:00Z"},"auth_method":"discard"}"#)
        XCTAssertEqual(nested.accessToken, "token")
        XCTAssertFalse(nested.canRefresh)
        XCTAssertNotNil(nested.expiry)
    }

    func testInvalidCredentialFieldsAreRejected() {
        for json in [
            "[]", "{}", #"{"access_token":true}"#, #"{"access_token":""}"#,
            #"{"access_token":"a\nb"}"#, #"{"access_token":"token","expiry":"bad"}"#,
            #"{"access_token":"token","expiry_date":true}"#,
            #"{"access_token":"token","expiry_date":-1}"#,
            #"{"access_token":"token","client_id":12}"#,
        ] {
            XCTAssertThrowsError(try AntigravityCredentials.parse(json))
        }
        XCTAssertNil(try? AntigravityCredentials.parse("not JSON"))
    }

    func testNullExpiryFallsBackToMillisecondsOrRemainsAbsent() throws {
        let fallback = try AntigravityCredentials.parse(#"{"access_token":"token","expiry":null,"expiry_date":1900000000000}"#)
        XCTAssertEqual(fallback.expiry, Date(timeIntervalSince1970: 1_900_000_000))
        let missing = try AntigravityCredentials.parse(#"{"access_token":"token","expiry":null,"expiry_date":null}"#)
        XCTAssertNil(missing.expiry)
    }

    func testRejectedTokenWithoutExpiryRenewsOnce() async throws {
        let secrets = MemorySecretStore()
        let account = ProviderConfigurationStore.keychainAccount(for: Self.configuration)
        var imported = try AntigravityCredentials.parse(Self.expiredCredential)
        imported.expiry = nil
        let original = try imported.encoded()
        try secrets.saveSecret(original, account: account)
        let rejected = LockedFlag()
        let fixture = IsolatedTestURLSession { request in
            if request.url == AntigravityUsageProvider.tokenURL {
                XCTAssertTrue(rejected.currentValue())
                return (try Self.response(request, status: 200), Data(#"{"access_token":"renewed","expires_in":3600}"#.utf8))
            }
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer old" {
                rejected.set()
                return (try Self.response(request, status: 401), Data())
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer renewed")
            return (try Self.response(request, status: 200), try Self.payload())
        }
        defer { fixture.invalidate() }
        let provider = AntigravityUsageProvider(secretStore: secrets, sessionConfiguration: fixture.session.configuration)
        let result = try await provider.fetchUsage(for: Self.configuration)
        XCTAssertNil(result.failureMessage)
        XCTAssertTrue(rejected.currentValue())
    }

    func testRequestUsesVerifiedBackendAndOnlyThisAccountsToken() async throws {
        let secrets = MemorySecretStore()
        try secrets.saveSecret(#"{"access_token":"account-one"}"#, account: ProviderConfigurationStore.keychainAccount(for: Self.configuration))
        let fixture = IsolatedTestURLSession { request in
            XCTAssertEqual(request.url?.host, "daily-cloudcode-pa.googleapis.com")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer account-one")
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertEqual(request.httpMethod, "POST")
            if request.url == AntigravityUsageProvider.planURL {
                return (try Self.response(request, status: 200), Data("{}".utf8))
            }
            XCTAssertEqual(request.url, AntigravityUsageProvider.quotaURL)
            XCTAssertEqual(requestBodyData(from: request), Data("{}".utf8))
            return (try Self.response(request, status: 200), try Self.payload())
        }
        defer { fixture.invalidate() }
        let provider = AntigravityUsageProvider(secretStore: secrets, sessionConfiguration: fixture.session.configuration)
        let result = try await provider.fetchUsage(for: Self.configuration)
        XCTAssertEqual(result.bars.count, 5)
        XCTAssertEqual(result.accountID, Self.configuration.id)
        let other = ProviderAccountConfiguration(id: "other", providerID: .antigravity, authMethod: .cliToken)
        let missing = try await provider.fetchUsage(for: other)
        XCTAssertNotNil(missing.failureMessage)
        XCTAssertTrue(missing.bars.isEmpty)
    }

    /// #519, November 9: production answered every pool full for the app's project-less `{}` request while the
    /// CLI read Gemini weekly 76% left. OpenUsage asks for the project `loadCodeAssist` names; so does CodexBar.
    func testQuotaRequestNamesTheAccountsProjectFromCodeAssist() async throws {
        let secrets = MemorySecretStore()
        try secrets.saveSecret(#"{"access_token":"account-one"}"#, account: ProviderConfigurationStore.keychainAccount(for: Self.configuration))
        let urls = LockedURLs()
        let fixture = IsolatedTestURLSession { request in
            urls.append(request.url)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer account-one")
            if request.url == AntigravityUsageProvider.planURL {
                XCTAssertEqual(request.timeoutInterval, 8)
                let body = try XCTUnwrap(requestBodyData(from: request))
                let root = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                XCTAssertEqual((root["metadata"] as? [String: String])?["ideType"], "IDE_UNSPECIFIED")
                return (try Self.response(request, status: 200), Self.codeAssist)
            }
            let body = try XCTUnwrap(requestBodyData(from: request))
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
            XCTAssertEqual(root, ["project": "fake-project-123"])
            // The primary backend answers only for the account's project, as OpenUsage's fixture does.
            guard root["project"] == "fake-project-123" else {
                return (try Self.response(request, status: 200), try Self.septemberFifthPlaceholder())
            }
            return (try Self.response(request, status: 200), try Self.payload())
        }
        defer { fixture.invalidate() }
        let provider = AntigravityUsageProvider(secretStore: secrets, sessionConfiguration: fixture.session.configuration)
        let result = try await provider.fetchUsage(for: Self.configuration)
        XCTAssertEqual(urls.values, [AntigravityUsageProvider.planURL, AntigravityUsageProvider.quotaURL])
        XCTAssertEqual(result.bars.map(\.stableKey), ["gemini-5h", "gemini-weekly", "gemini-argon-wtu-weekly", "3p-5h", "3p-weekly"])
        XCTAssertTrue(result.usageMessages.isEmpty)
    }

    /// SFL round 1 on #554: a project Google refuses must not turn a card that worked with `{}` into a reconnect.
    func testRejectedProjectRetriesThePrimaryBackendOnceWithTheEmptyRequest() async throws {
        let outcomes: [(Int, String)] = [(400, "usable"), (403, "usable"), (403, "placeholder"), (403, "rejected"), (401, "unused")]
        for (status, emptyAnswer) in outcomes {
            let label = "\(status) then \(emptyAnswer)"
            let secrets = MemorySecretStore()
            try secrets.saveSecret(#"{"access_token":"test"}"#, account: ProviderConfigurationStore.keychainAccount(for: Self.configuration))
            let urls = LockedURLs()
            let bodies = LockedURLs()
            let fixture = IsolatedTestURLSession { request in
                if request.url == AntigravityUsageProvider.planURL {
                    return (try Self.response(request, status: 200), Self.codeAssist)
                }
                urls.append(request.url)
                let project = Self.requestedProject(request)
                bodies.append(URL(string: "body:" + (project ?? "none")))
                if request.url == AntigravityUsageProvider.fallbackQuotaURL {
                    let otherModelsOnly = Self.buckets().filter { ($0["bucketId"] as? String)?.hasPrefix("3p-") == true }
                    return (try Self.response(request, status: 200), try Self.payload(otherModelsOnly))
                }
                if project != nil { return (try Self.response(request, status: status), Data()) }
                switch emptyAnswer {
                case "usable": return (try Self.response(request, status: 200), try Self.payload())
                case "placeholder": return (try Self.response(request, status: 200), try Self.septemberFifthPlaceholder())
                default: return (try Self.response(request, status: 403), Data())
                }
            }
            defer { fixture.invalidate() }
            let provider = AntigravityUsageProvider(secretStore: secrets, sessionConfiguration: fixture.session.configuration)
            let result = try await provider.fetchUsage(for: Self.configuration)
            let primary = AntigravityUsageProvider.quotaURL, fallback = AntigravityUsageProvider.fallbackQuotaURL
            switch emptyAnswer {
            case "usable":
                XCTAssertEqual(urls.values, [primary, primary], label)
                XCTAssertEqual(bodies.values.map { $0?.absoluteString }, ["body:fake-project-123", "body:none"], label)
                XCTAssertEqual(result.bars.count, 5, label)
                XCTAssertNil(result.failureMessage, label)
            case "placeholder":
                XCTAssertEqual(urls.values, [primary, primary, fallback], label)
                XCTAssertEqual(bodies.values.map { $0?.absoluteString }, ["body:fake-project-123", "body:none", "body:none"], label)
                XCTAssertEqual(result.bars.map(\.stableKey), ["3p-5h", "3p-weekly"], label)
                XCTAssertTrue(result.usageMessages.last?.hasPrefix("When asked without a project,") == true, label)
            case "rejected":
                XCTAssertEqual(urls.values, [primary, primary], label)
                XCTAssertTrue(result.bars.isEmpty, label)
                XCTAssertEqual(result.recoveryAction, .reauthenticate, label)
            default:
                // 401 is a sign-in rejection, not a project refusal: no `{}` retry and no fallback.
                XCTAssertEqual(urls.values, [primary], label)
                XCTAssertEqual(result.recoveryAction, .reauthenticate, label)
            }
        }
    }

    func testMissingOrUnreadableProjectKeepsTheEmptyQuotaRequest() async throws {
        let lookups: [(String, Int?, Data)] = [
            ("503", 503, Data()),
            ("401", 401, Data()),
            ("transport", nil, Data()),
            ("no project", 200, Data(#"{"paidTier":{"name":"Google AI Pro"}}"#.utf8)),
            ("empty", 200, Data(#"{"cloudaicompanionProject":""}"#.utf8)),
            ("whitespace", 200, Data(#"{"cloudaicompanionProject":"fake project"}"#.utf8)),
            ("number", 200, Data(#"{"cloudaicompanionProject":123}"#.utf8)),
            ("object without id", 200, Data(#"{"cloudaicompanionProject":{"name":"fake"}}"#.utf8)),
            ("malformed", 200, Data("not json".utf8)),
        ]
        for (label, status, body) in lookups {
            let secrets = MemorySecretStore()
            try secrets.saveSecret(#"{"access_token":"test"}"#, account: ProviderConfigurationStore.keychainAccount(for: Self.configuration))
            let hosts = LockedHosts()
            let fixture = IsolatedTestURLSession { request in
                hosts.append(request.url)
                if request.url == AntigravityUsageProvider.planURL {
                    guard let status else { throw URLError(.cannotConnectToHost) }
                    return (try Self.response(request, status: status), body)
                }
                XCTAssertEqual(requestBodyData(from: request), Data("{}".utf8), label)
                return (try Self.response(request, status: 200), try Self.payload())
            }
            defer { fixture.invalidate() }
            let provider = AntigravityUsageProvider(secretStore: secrets, sessionConfiguration: fixture.session.configuration)
            let result = try await provider.fetchUsage(for: Self.configuration)
            XCTAssertEqual(hosts.values, ["daily-cloudcode-pa.googleapis.com"], label)
            XCTAssertEqual(result.bars.count, 5, label)
            XCTAssertNil(result.failureMessage, label)
        }
    }

    func testCompanionProjectAcceptsOnlyAnIdentifier() {
        func project(_ json: String) -> String? { AntigravityUsageProvider.companionProject(from: Data(json.utf8)) }
        XCTAssertEqual(project(#"{"cloudaicompanionProject":"fake-project-123"}"#), "fake-project-123")
        XCTAssertEqual(project(#"{"cloudaicompanionProject":{"id":"fake-project-456","name":"fake"}}"#), "fake-project-456")
        XCTAssertNil(project(#"{"cloudaicompanionProject":null}"#))
        XCTAssertNil(project(#"{"cloudaicompanionProject":"line\nbreak"}"#))
        XCTAssertNil(project("{\"cloudaicompanionProject\":\"\(String(repeating: "a", count: 257))\"}"))
        XCTAssertNil(project(#"["fake-project-123"]"#))
    }

    func testProjectRequestBodyIsJSONEncoded() throws {
        let provider = AntigravityUsageProvider(secretStore: MemorySecretStore(), sessionConfiguration: .ephemeral)
        let named = provider.quotaRequest(token: "t", project: #"fake"project"#)
        let root = try JSONSerialization.jsonObject(with: try XCTUnwrap(named.httpBody)) as? [String: String]
        XCTAssertEqual(root, ["project": #"fake"project"#])
        XCTAssertEqual(provider.quotaRequest(token: "t").httpBody, Data("{}".utf8))
    }

    func testPrimaryGeminiPoolsAreUsedWithoutAskingFallbackBackend() async throws {
        let secrets = MemorySecretStore()
        try secrets.saveSecret(#"{"access_token":"test"}"#, account: ProviderConfigurationStore.keychainAccount(for: Self.configuration))
        let hosts = LockedHosts()
        let fixture = IsolatedTestURLSession { request in
            hosts.append(request.url)
            let otherModelsOnly = Self.buckets().filter { ($0["bucketId"] as? String)?.hasPrefix("3p-") == true }
            let isFallback = request.url == AntigravityUsageProvider.fallbackQuotaURL
            return (try Self.response(request, status: 200), try Self.payload(isFallback ? otherModelsOnly : Self.buckets()))
        }
        defer { fixture.invalidate() }
        let provider = AntigravityUsageProvider(secretStore: secrets, sessionConfiguration: fixture.session.configuration)
        let result = try await provider.fetchUsage(for: Self.configuration)
        XCTAssertEqual(hosts.values, ["daily-cloudcode-pa.googleapis.com"])
        XCTAssertEqual(result.bars.map(\.stableKey), ["gemini-5h", "gemini-weekly", "gemini-argon-wtu-weekly", "3p-5h", "3p-weekly"])
        XCTAssertTrue(result.unavailableUsageMetrics.isEmpty)
    }

    func testPartialPrimaryResponseIsNotFilledFromFallbackBackend() async throws {
        let secrets = MemorySecretStore()
        try secrets.saveSecret(#"{"access_token":"test"}"#, account: ProviderConfigurationStore.keychainAccount(for: Self.configuration))
        let hosts = LockedHosts()
        let fixture = IsolatedTestURLSession { request in
            hosts.append(request.url)
            let otherModelsOnly = Self.buckets().filter { ($0["bucketId"] as? String)?.hasPrefix("3p-") == true }
            let isFallback = request.url == AntigravityUsageProvider.fallbackQuotaURL
            return (try Self.response(request, status: 200), try Self.payload(isFallback ? Self.buckets() : otherModelsOnly))
        }
        defer { fixture.invalidate() }
        let provider = AntigravityUsageProvider(secretStore: secrets, sessionConfiguration: fixture.session.configuration)
        let result = try await provider.fetchUsage(for: Self.configuration)
        XCTAssertEqual(hosts.values, ["daily-cloudcode-pa.googleapis.com"])
        XCTAssertEqual(result.bars.map(\.stableKey), ["3p-5h", "3p-weekly"])
        for key in ["gemini-5h", "gemini-weekly", "gemini-argon-wtu-weekly"] {
            XCTAssertEqual(result.unavailableUsageMetrics["antigravity.\(key)"], "Unavailable")
        }
    }

    /// Shape of the September 5, 2026 production response: HTTP 200, the same four pools, every fraction 1,
    /// and supplied resets, while the daily backend and the CLI reported Gemini weekly 0.7202861 remaining.
    private static func septemberFifthPlaceholder() throws -> Data {
        let resets = [
            "gemini-weekly": "2030-09-12T22:26:05Z", "gemini-5h": "2030-09-06T03:26:05Z",
            "3p-weekly": "2030-09-12T22:26:05Z", "3p-5h": "2030-09-06T03:26:05Z",
        ]
        let windows = ["gemini-weekly": "weekly", "gemini-5h": "5h", "3p-weekly": "weekly", "3p-5h": "5h"]
        return try payload(resets.keys.sorted().map { key in
            ["bucketId": key, "window": windows[key] ?? "", "remainingFraction": 1, "resetTime": resets[key] ?? ""]
        })
    }

    func testAllFullPrimaryPlaceholderUsesFallbackBackend() async throws {
        let secrets = MemorySecretStore()
        try secrets.saveSecret(#"{"access_token":"test"}"#, account: ProviderConfigurationStore.keychainAccount(for: Self.configuration))
        let hosts = LockedHosts()
        let fixture = IsolatedTestURLSession { request in
            hosts.append(request.url)
            guard request.url == AntigravityUsageProvider.fallbackQuotaURL else {
                return (try Self.response(request, status: 200), try Self.septemberFifthPlaceholder())
            }
            let fallback: [String: Any] = [
                "bucketId": "gemini-weekly", "window": "weekly", "remainingFraction": 0.7202861,
                "resetTime": "2030-09-11T16:22:20Z",
            ]
            return (try Self.response(request, status: 200), try Self.payload([fallback]))
        }
        defer { fixture.invalidate() }
        let provider = AntigravityUsageProvider(secretStore: secrets, sessionConfiguration: fixture.session.configuration)
        let result = try await provider.fetchUsage(for: Self.configuration)
        XCTAssertEqual(hosts.values, ["daily-cloudcode-pa.googleapis.com", "cloudcode-pa.googleapis.com"])
        XCTAssertEqual(result.bars.map(\.stableKey), ["gemini-weekly"])
        XCTAssertEqual(try XCTUnwrap(result.bars.first).used, 27.97139, accuracy: 0.000_001)
        XCTAssertEqual(result.unavailableUsageMetrics["antigravity.gemini-5h"], "Unavailable")
    }

    func testAllFullPrimaryPlaceholderNeverShowsFullBarsWhenFallbackFails() async throws {
        for fallbackStatus in [500, 401] {
            let secrets = MemorySecretStore()
            try secrets.saveSecret(#"{"access_token":"test"}"#, account: ProviderConfigurationStore.keychainAccount(for: Self.configuration))
            let fixture = IsolatedTestURLSession { request in
                if request.url == AntigravityUsageProvider.fallbackQuotaURL {
                    return (try Self.response(request, status: fallbackStatus), Data())
                }
                return (try Self.response(request, status: 200), try Self.septemberFifthPlaceholder())
            }
            defer { fixture.invalidate() }
            let provider = AntigravityUsageProvider(secretStore: secrets, sessionConfiguration: fixture.session.configuration)
            let result = try await provider.fetchUsage(for: Self.configuration)
            XCTAssertTrue(result.bars.isEmpty, "fallback \(fallbackStatus)")
            XCTAssertNotNil(result.failureMessage, "fallback \(fallbackStatus)")
        }
    }

    func testUnusablePrimarySuccessUsesFallbackBackend() async throws {
        let expired = Self.buckets().map { bucket -> [String: Any] in
            var stale = bucket
            stale["resetTime"] = "2020-01-01T00:00:00Z"
            return stale
        }
        let bodies: [(String, Data)] = [
            ("malformed", Data("not json".utf8)),
            ("empty groups", Data(#"{"groups":[]}"#.utf8)),
            ("unrelated pools", try Self.payload([["bucketId": "unrelated", "window": "weekly", "remainingFraction": 0.5]])),
            ("expired resets", try Self.payload(expired)),
        ]
        for (label, body) in bodies {
            let secrets = MemorySecretStore()
            try secrets.saveSecret(#"{"access_token":"test"}"#, account: ProviderConfigurationStore.keychainAccount(for: Self.configuration))
            let hosts = LockedHosts()
            let fixture = IsolatedTestURLSession { request in
                hosts.append(request.url)
                let isFallback = request.url == AntigravityUsageProvider.fallbackQuotaURL
                return (try Self.response(request, status: 200), isFallback ? try Self.payload() : body)
            }
            defer { fixture.invalidate() }
            let provider = AntigravityUsageProvider(secretStore: secrets, sessionConfiguration: fixture.session.configuration)
            let result = try await provider.fetchUsage(for: Self.configuration)
            XCTAssertEqual(hosts.values, ["daily-cloudcode-pa.googleapis.com", "cloudcode-pa.googleapis.com"], label)
            XCTAssertEqual(result.bars.count, 5, label)
            XCTAssertNil(result.failureMessage, label)
        }
    }

    func testPlaceholderDetectionRequiresEverySuppliedPoolFull() throws {
        XCTAssertTrue(AntigravityQuotaParser.isAllFullPlaceholder(try Self.septemberFifthPlaceholder()))
        var oneUsed = Self.buckets().map { bucket -> [String: Any] in
            var full = bucket
            full["remainingFraction"] = 1
            return full
        }
        XCTAssertTrue(AntigravityQuotaParser.isAllFullPlaceholder(try Self.payload(oneUsed)))
        oneUsed[1]["remainingFraction"] = 0.99
        XCTAssertFalse(AntigravityQuotaParser.isAllFullPlaceholder(try Self.payload(oneUsed)))
        XCTAssertFalse(AntigravityQuotaParser.isAllFullPlaceholder(try Self.payload([])))
        XCTAssertFalse(AntigravityQuotaParser.isAllFullPlaceholder(try Self.payload([
            ["bucketId": "unrelated", "window": "weekly", "remainingFraction": 1],
        ])))
        XCTAssertFalse(AntigravityQuotaParser.isAllFullPlaceholder(Data("not json".utf8)))
    }

    func testFallbackBackendIsUsedOnlyForPrimaryOutages() async throws {
        let outages: [(Int?, Bool)] = [
            (500, true), (503, true), (429, true), (302, true), (nil, true),
            (400, false), (401, false), (403, false),
        ]
        for (status, expectsFallback) in outages {
            let secrets = MemorySecretStore()
            try secrets.saveSecret(#"{"access_token":"test"}"#, account: ProviderConfigurationStore.keychainAccount(for: Self.configuration))
            let hosts = LockedHosts()
            let fixture = IsolatedTestURLSession { request in
                hosts.append(request.url)
                if request.url == AntigravityUsageProvider.fallbackQuotaURL {
                    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test")
                    XCTAssertEqual(requestBodyData(from: request), Data("{}".utf8))
                    return (try Self.response(request, status: 200), try Self.payload())
                }
                guard let status else { throw URLError(.cannotConnectToHost) }
                return (try Self.response(request, status: status), Data("secret-response-body".utf8))
            }
            defer { fixture.invalidate() }
            let provider = AntigravityUsageProvider(secretStore: secrets, sessionConfiguration: fixture.session.configuration)
            let result = try await provider.fetchUsage(for: Self.configuration)
            let label = String(describing: status)
            if expectsFallback {
                XCTAssertEqual(hosts.values, ["daily-cloudcode-pa.googleapis.com", "cloudcode-pa.googleapis.com"], label)
                XCTAssertNil(result.failureMessage, label)
                XCTAssertEqual(result.bars.count, 5, label)
            } else {
                XCTAssertEqual(hosts.values, ["daily-cloudcode-pa.googleapis.com"], label)
                XCTAssertTrue(result.bars.isEmpty, label)
                XCTAssertEqual(result.recoveryAction, .reauthenticate, label)
            }
        }
    }

    func testExpiredCredentialRenewsAndPersistsOnlyItsOwnAccount() async throws {
        let secrets = MemorySecretStore()
        let account = ProviderConfigurationStore.keychainAccount(for: Self.configuration)
        try secrets.saveSecret(Self.expiredCredential, account: account)
        let fixture = IsolatedTestURLSession { request in
            if request.url == AntigravityUsageProvider.tokenURL {
                let body = String(bytes: requestBodyData(from: request) ?? Data(), encoding: .utf8) ?? ""
                XCTAssertTrue(body.contains("grant_type=refresh_token"))
                XCTAssertTrue(body.contains("client_secret=secret%2Bvalue"))
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                return (try Self.response(request, status: 200), Data(#"{"access_token":"renewed","refresh_token":"rotated","expires_in":3600}"#.utf8))
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer renewed")
            return (try Self.response(request, status: 200), try Self.payload())
        }
        defer { fixture.invalidate() }
        let provider = AntigravityUsageProvider(secretStore: secrets, sessionConfiguration: fixture.session.configuration)
        let result = try await provider.fetchUsage(for: Self.configuration)
        XCTAssertNil(result.failureMessage)
        let saved = try AntigravityCredentials.parse(XCTUnwrap(secrets.readSecret(account: account)))
        XCTAssertEqual(saved.accessToken, "renewed")
        XCTAssertEqual(saved.refreshToken, "rotated")
        XCTAssertGreaterThan(try XCTUnwrap(saved.expiry), Date())
    }

    func testRenewalCannotRestoreDisconnectedCredential() async throws {
        let secrets = MemorySecretStore()
        let account = ProviderConfigurationStore.keychainAccount(for: Self.configuration)
        try secrets.saveSecret(Self.expiredCredential, account: account)
        let fixture = IsolatedTestURLSession { request in
            XCTAssertEqual(request.url, AntigravityUsageProvider.tokenURL)
            try secrets.deleteSecret(account: account)
            return (try Self.response(request, status: 200), Data(#"{"access_token":"late","expires_in":3600}"#.utf8))
        }
        defer { fixture.invalidate() }
        let provider = AntigravityUsageProvider(secretStore: secrets, sessionConfiguration: fixture.session.configuration)
        let result = try await provider.fetchUsage(for: Self.configuration)
        XCTAssertNotNil(result.failureMessage)
        XCTAssertNil(try secrets.readSecret(account: account))
    }

    func testHTTPAndMalformedFailuresNeverInventUsageOrLeakResponse() async throws {
        for status in [302, 400, 401, 403, 429, 500, 200] {
            let secrets = MemorySecretStore()
            try secrets.saveSecret(#"{"access_token":"test"}"#, account: ProviderConfigurationStore.keychainAccount(for: Self.configuration))
            let fixture = IsolatedTestURLSession { request in
                (try Self.response(request, status: status), Data("secret-response-body".utf8))
            }
            defer { fixture.invalidate() }
            let provider = AntigravityUsageProvider(secretStore: secrets, sessionConfiguration: fixture.session.configuration)
            let result = try await provider.fetchUsage(for: Self.configuration)
            XCTAssertTrue(result.bars.isEmpty)
            XCTAssertNotNil(result.failureMessage)
            XCTAssertFalse(result.failureMessage?.contains("secret-response-body") == true)
        }
    }

    func testCancellationPropagates() async throws {
        let secrets = MemorySecretStore()
        try secrets.saveSecret(#"{"access_token":"test"}"#, account: ProviderConfigurationStore.keychainAccount(for: Self.configuration))
        let fixture = IsolatedTestURLSession { _ in throw URLError(.cancelled) }
        defer { fixture.invalidate() }
        let provider = AntigravityUsageProvider(secretStore: secrets, sessionConfiguration: fixture.session.configuration)
        do {
            _ = try await provider.fetchUsage(for: Self.configuration)
            XCTFail("Expected cancellation")
        } catch is CancellationError { }
    }

    @MainActor
    func testAllSevenMetricChoicesExistOnOneAccountBeforeCredentials() throws {
        let suite = "GoogleChoices.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: MemorySecretStore())
        let account = try XCTUnwrap(store.addAccount(for: .gemini))
        let legacy = try XCTUnwrap(store.addAccount(for: .antigravity))
        let model = ProviderSettingsViewModel(configurationStore: store, accountID: account.id)
        XCTAssertEqual(model.availableMetrics.map(\.id), Self.googleIDs)
        XCTAssertTrue(model.availableMetrics.allSatisfy { $0.kind == .unavailableUsage("Setup required") })
        XCTAssertEqual(store.visibleConfigurations, [account])
        XCTAssertEqual(store.unlinkedGeminiCodingAccounts, [legacy])
        XCTAssertFalse(store.shouldDisplayOnDashboard(legacy))
        XCTAssertFalse(AddAccountFlowState.providerOptions.contains(.antigravity))
        let service = UsageRefreshService(providers: [])
        let dashboard = googleDashboard(store: store, service: service, defaults: defaults)
        XCTAssertEqual(dashboard.dashboardCardItems.map(\.id), [account.id])
        XCTAssertEqual(dashboard.dashboardCardItems.first?.result?.configurableMetrics.map(\.id), Self.googleIDs)
        XCTAssertTrue(GoogleUsageMetricCatalog.missingSourceConfigurations(in: store.configurations).isEmpty)
    }

    @MainActor
    func testAllSevenPreferencesSurviveMissingResultsRefreshAndRelaunch() async throws {
        let suite = "GoogleLayout.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = MemorySecretStore()
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secrets)
        let account = try XCTUnwrap(store.addAccount(for: .gemini))
        XCTAssertTrue(store.saveSecret("apps-session", for: account))
        let result = try Self.unifiedResult(account)
        let model = ProviderSettingsViewModel(configurationStore: store, accountID: account.id)
        store.reconcileMetricLayout(accountID: account.id, availableMetricIDs: Self.googleIDs)
        for (index, id) in Self.googleIDs.enumerated() {
            store.updateMetricVisibility(index.isMultiple(of: 2), accountID: account.id, metricID: id)
            store.updateMetricWidth(index.isMultiple(of: 2) ? .half : .full, accountID: account.id, metricID: id)
            store.updateVisualizationStyle(index.isMultiple(of: 2) ? .circularRing : .largeNumeric, accountID: account.id, metricID: id)
        }
        store.updateMetricOrder(Array(Self.googleIDs.reversed()), accountID: account.id)
        let layout = store.metricLayouts[account.id]
        model.synchronizeUsageResult(result)
        model.synchronizeUsageResult(nil)
        let service = UsageRefreshService(providers: [ReturningFailureUsageProvider(providerID: .gemini)], initialResults: [result])
        await service.refresh(configurations: [account])
        XCTAssertFalse(try XCTUnwrap(service.results.first).hasCurrentBars)
        XCTAssertEqual(store.metricLayouts[account.id], layout)
        let restored = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secrets)
        XCTAssertEqual(restored.metricLayouts[account.id], layout)
        XCTAssertEqual(model.availableMetrics.map(\.id), Self.googleIDs)
    }

    @MainActor
    func testConfirmedLegacyLinkPreservesHistoryCredentialsAndOverridesSeededCodingLayout() throws {
        let suite = "GoogleMigration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = MemorySecretStore()
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secrets, widgetSnapshotDefaults: defaults)
        let apps = try XCTUnwrap(store.addAccount(for: .gemini))
        let coding = try XCTUnwrap(store.addAccount(for: .antigravity))
        let unrelated = try XCTUnwrap(store.addAccount(for: .gemini))
        XCTAssertTrue(store.saveSecret("apps-secret", for: apps))
        XCTAssertTrue(store.saveSecret(#"{"access_token":"coding-token"}"#, for: coding))
        store.reconcileMetricLayout(accountID: apps.id, availableMetricIDs: Self.googleIDs)
        store.updateMetricVisibility(false, accountID: apps.id, metricID: "gemini.weekly")
        let codingIDs = Array(Self.googleIDs.dropFirst(2))
        store.reconcileMetricLayout(accountID: coding.id, availableMetricIDs: codingIDs)
        store.updateMetricVisibility(false, accountID: coding.id, metricID: codingIDs[1])
        store.updateMetricWidth(.half, accountID: coding.id, metricID: codingIDs[1])
        store.updateVisualizationStyle(.circularRing, accountID: coding.id, metricID: codingIDs[1])
        store.updateWatchMetricVisibility(.hide, accountID: coding.id, metricID: codingIDs[1])
        store.updateMetricOrder(Array(codingIDs.reversed()), accountID: coding.id)
        let history = UsageHistoryStore(defaults: defaults)
        let legacyResult = try AntigravityQuotaParser.result(from: Self.payload(), configuration: coding, fetchedAt: Self.now)
        let appsResult = ProviderUsageResult(
            accountID: apps.id, providerID: .gemini, title: apps.displayName, subtitle: "Apps",
            bars: [UsageBar(stableKey: "weekly", label: "Gemini Apps weekly", used: 25, limit: 100)], fetchedAt: Self.now
        )
        history.record(results: [appsResult, legacyResult], now: Self.now)
        let originalIDs = Set(history.snapshots.map(\.id))
        XCTAssertFalse(store.linkGeminiCodingAccount(coding, to: apps, confirmedSameAccount: false))
        XCTAssertEqual(history.snapshots.count, 2)
        XCTAssertFalse(store.hasGeminiCodingSecret(for: apps))
        XCTAssertTrue(store.linkGeminiCodingAccount(coding, to: apps, confirmedSameAccount: true))
        history.migrateGoogleAccounts(links: store.confirmedGoogleAccountLinks, configurations: store.visibleConfigurations)
        XCTAssertEqual(history.snapshots(for: apps.id).count, 2)
        XCTAssertEqual(Set(history.snapshots.map(\.id)), originalIDs)
        XCTAssertTrue(history.snapshots.allSatisfy { $0.providerID == .gemini })
        XCTAssertEqual(history.snapshots(for: apps.id).flatMap(\.bars).count, 6)
        XCTAssertFalse(store.isMetricVisible(accountID: apps.id, metricID: codingIDs[1]))
        XCTAssertFalse(store.isMetricVisible(accountID: apps.id, metricID: "gemini.weekly"))
        XCTAssertFalse(store.isMetricVisibleOnWatch(accountID: apps.id, metricID: codingIDs[1]))
        XCTAssertEqual(store.metricWidth(accountID: apps.id, metricID: codingIDs[1]), .half)
        XCTAssertEqual(store.visualizationStyle(accountID: apps.id, metricID: codingIDs[1]), .circularRing)
        XCTAssertEqual(Array(try XCTUnwrap(store.metricLayouts[apps.id]).orderedMetricIDs.suffix(5)), Array(codingIDs.reversed()))
        XCTAssertTrue(store.isMetricVisible(accountID: unrelated.id, metricID: codingIDs[1]))
        XCTAssertEqual(try secrets.readSecret(account: ProviderConfigurationStore.keychainAccount(for: apps)), "apps-secret")
        XCTAssertNotNil(try secrets.readSecret(account: ProviderConfigurationStore.keychainAccount(for: coding)))
        XCTAssertFalse(store.hasGeminiCodingSecret(for: unrelated))
        let restored = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secrets)
        let restoredHistory = UsageHistoryStore(defaults: defaults)
        restoredHistory.migrateGoogleAccounts(links: restored.confirmedGoogleAccountLinks, configurations: restored.visibleConfigurations)
        restoredHistory.record(results: [try Self.unifiedResult(apps)], now: Self.now)
        XCTAssertEqual(Set(restoredHistory.snapshots.map(\.id)).count, restoredHistory.snapshots.count)
        XCTAssertTrue(restored.unlinkedGeminiCodingAccounts.isEmpty)
        XCTAssertEqual(restored.metricLayouts[apps.id], store.metricLayouts[apps.id])
    }

    @MainActor
    func testUnlinkedAccountsRemainIsolatedAndVerifiedDifferentIdentitiesCannotLink() throws {
        let suite = "GoogleAssociation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = MemorySecretStore()
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secrets)
        var apps = try XCTUnwrap(store.addAccount(for: .gemini))
        var coding = try XCTUnwrap(store.addAccount(for: .antigravity))
        let other = try XCTUnwrap(store.addAccount(for: .antigravity))
        XCTAssertTrue(store.saveSecret(#"{"access_token":"token"}"#, for: coding))
        XCTAssertFalse(store.linkGeminiCodingAccount(coding, to: apps, confirmedSameAccount: false))
        apps.verifiedGoogleSubject = "google-a"
        coding.verifiedGoogleSubject = "google-b"
        XCTAssertTrue(store.update(apps))
        XCTAssertTrue(store.update(coding))
        XCTAssertFalse(store.linkGeminiCodingAccount(coding, to: apps, confirmedSameAccount: true))
        XCTAssertFalse(store.hasGeminiCodingSecret(for: apps))
        XCTAssertEqual(Set(store.unlinkedGeminiCodingAccounts.map(\.id)), [coding.id, other.id])
        coding.verifiedGoogleSubject = "google-a"
        XCTAssertTrue(store.update(coding))
        XCTAssertTrue(store.linkGeminiCodingAccount(coding, to: apps, confirmedSameAccount: false))
        XCTAssertEqual(store.unlinkedGeminiCodingAccounts, [other])
        XCTAssertFalse(store.linkGeminiCodingAccount(other, to: apps, confirmedSameAccount: true))
        XCTAssertNotNil(ProviderConfigurationStore(
            initialPlanAccess: .unrestricted,
            defaults: defaults, secretStore: secrets).configuration(accountID: other.id))
    }

    @MainActor
    func testConfirmedArchiveNameCanBeReusedWithoutLosingUnlinkedNameReservations() throws {
        let suite = "GoogleArchiveNames.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = MemorySecretStore()
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secrets)
        var apps = try XCTUnwrap(store.addAccount(for: .gemini))
        var coding = try XCTUnwrap(store.addAccount(for: .antigravity))
        var other = try XCTUnwrap(store.addAccount(for: .gemini))
        coding.accountLabel = "Google Gemini 3"
        XCTAssertTrue(store.update(coding))
        let token = #"{"access_token":"coding-token"}"#
        XCTAssertTrue(store.saveSecret(token, for: coding))
        apps.accountLabel = "GOOGLE GEMINI 3"
        XCTAssertFalse(store.update(apps), "Unlinked legacy sessions still reserve their names for association.")
        XCTAssertEqual(store.unlinkedGeminiCodingAccounts, [coding])
        XCTAssertTrue(store.linkGeminiCodingAccount(coding, to: apps, confirmedSameAccount: true))
        XCTAssertTrue(store.update(apps), "A confirmed archival record must not block the visible account name.")
        other.accountLabel = "google gemini 3"
        XCTAssertFalse(store.update(other), "Visible names remain case-insensitively unique.")
        XCTAssertEqual(store.configuration(accountID: coding.id), coding)
        XCTAssertEqual(try secrets.readSecret(account: ProviderConfigurationStore.keychainAccount(for: coding)), token)
        let restored = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secrets)
        XCTAssertEqual(restored.configuration(accountID: apps.id)?.displayName, "GOOGLE GEMINI 3")
        XCTAssertEqual(restored.configuration(accountID: coding.id), coding)
        XCTAssertEqual(restored.confirmedGoogleAccountLinks, [coding.id: apps.id])
        XCTAssertTrue(restored.unlinkedGeminiCodingAccounts.isEmpty)
        XCTAssertFalse(restored.update(other))
        apps.accountLabel = "Personal Google"
        XCTAssertTrue(restored.update(apps))
        XCTAssertEqual(try XCTUnwrap(restored.addAccount(for: .gemini)).accountLabel, "Google Gemini 3")
    }

    @MainActor
    func testLegacyRecordWithoutCredentialLinksHistoryAndLayoutWithoutClaimingConnection() throws {
        let suite = "GoogleDataOnlyLink.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = MemorySecretStore()
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secrets)
        let apps = try XCTUnwrap(store.addAccount(for: .gemini))
        let legacy = try XCTUnwrap(store.addAccount(for: .antigravity))
        let metricID = "antigravity.gemini-weekly"
        store.updateMetricVisibility(false, accountID: legacy.id, metricID: metricID)
        store.updateMetricWidth(.half, accountID: legacy.id, metricID: metricID)
        let history = UsageHistoryStore(defaults: defaults)
        let priorResult = try AntigravityQuotaParser.result(
            from: Self.payload(), configuration: legacy, fetchedAt: Self.now
        )
        history.record(results: [priorResult], now: Self.now)
        let originalIDs = history.snapshots.map(\.id)
        XCTAssertTrue(store.linkGeminiCodingAccount(legacy, to: apps, confirmedSameAccount: true))
        history.migrateGoogleAccounts(links: store.confirmedGoogleAccountLinks, configurations: store.visibleConfigurations)
        XCTAssertEqual(history.snapshots.map(\.id), originalIDs)
        XCTAssertEqual(history.snapshots(for: apps.id).count, 1)
        XCTAssertFalse(store.isMetricVisible(accountID: apps.id, metricID: metricID))
        XCTAssertEqual(store.metricWidth(accountID: apps.id, metricID: metricID), .half)
        XCTAssertFalse(store.hasGeminiCodingSecret(for: apps))
        XCTAssertFalse(store.isConfigured(apps))
        XCTAssertNil(try secrets.readSecret(account: ProviderConfigurationStore.geminiCodingKeychainAccount(accountID: apps.id)))
        XCTAssertEqual(store.configuration(accountID: legacy.id), legacy)
        XCTAssertEqual(store.confirmedGoogleAccountLinks, [legacy.id: apps.id])
    }

    @MainActor
    func testPendingConfirmedLinkResumesAfterCredentialCopyWithoutGuessing() throws {
        let suite = "GoogleLinkRecovery.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = MemorySecretStore()
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secrets)
        let apps = try XCTUnwrap(store.addAccount(for: .gemini))
        let coding = try XCTUnwrap(store.addAccount(for: .antigravity))
        let token = try AntigravityCredentials.parse(#"{"access_token":"token"}"#).encoded()
        XCTAssertTrue(store.saveSecret(token, for: coding))
        try secrets.saveSecret(token, account: ProviderConfigurationStore.geminiCodingKeychainAccount(accountID: apps.id))
        defaults.set([coding.id: apps.id], forKey: "pendingGoogleAccountLinks")
        let restored = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secrets)
        XCTAssertEqual(restored.confirmedGoogleAccountLinks, [coding.id: apps.id])
        XCTAssertTrue(restored.unlinkedGeminiCodingAccounts.isEmpty)
        XCTAssertTrue(restored.hasGeminiCodingSecret(for: apps))
        XCTAssertEqual(defaults.dictionary(forKey: "pendingGoogleAccountLinks")?.count, 0)
    }

    @MainActor
    func testSyntheticSetupLayoutMovesToGeminiWithoutCreatingCodingAccount() throws {
        let suite = "GoogleSetupLayout.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = MemorySecretStore()
        let old = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secrets)
        let metricID = "antigravity.gemini-weekly"
        old.updateMetricVisibility(false, accountID: "dashboard.setup.antigravity", metricID: metricID)
        old.updateMetricWidth(.half, accountID: "dashboard.setup.antigravity", metricID: metricID)
        let apps = try XCTUnwrap(old.addAccount(for: .gemini))
        let restored = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secrets)
        XCTAssertEqual(restored.visibleConfigurations, [apps])
        XCTAssertFalse(restored.isMetricVisible(accountID: apps.id, metricID: metricID))
        XCTAssertEqual(restored.metricWidth(accountID: apps.id, metricID: metricID), .half)
        XCTAssertTrue(GoogleUsageMetricCatalog.missingSourceConfigurations(in: restored.configurations).isEmpty)
    }

    @MainActor
    func testLegacyWidgetAndWatchSelectionsResolveOnlyConfirmedCodingIdentity() throws {
        let suite = "GoogleSelections.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: MemorySecretStore())
        let apps = try XCTUnwrap(store.addAccount(for: .gemini))
        let legacy = try XCTUnwrap(store.addAccount(for: .antigravity))
        XCTAssertTrue(store.saveSecret(#"{"access_token":"token"}"#, for: legacy))
        XCTAssertTrue(store.linkGeminiCodingAccount(legacy, to: apps, confirmedSameAccount: true))
        let result = try Self.unifiedResult(apps)
        WidgetSnapshotPublisher.publish(results: [result], configurationStore: store, access: SnapshotProAccess(isProLocked: false, proAccessEndsAt: nil),
        snapshotDefaults: defaults, accessGuard: WidgetAccessGuard(directory: nil), now: Self.now)
        let widget = WidgetSnapshotStore.loadSnapshot(defaults: defaults)
        XCTAssertEqual(widget.results.count, 1)
        XCTAssertEqual(widget.results.first?.bars.count, Self.googleIDs.count)
        XCTAssertEqual(widget.results.first?.bars.compactMap(\.metricID), Self.googleIDs)
        XCTAssertEqual(widget.builderTile(resolvingSavedID: "provider.\(legacy.id)")?.id, "provider.\(apps.id)")
        let savedID = "bar.\(legacy.id).antigravity.gemini-5h"
        XCTAssertEqual(widget.builderTile(resolvingSavedID: savedID)?.id, "bar.\(apps.id).antigravity.gemini-5h")
        XCTAssertEqual(
            widget.builderTile(resolvingSavedID: "bar.\(legacy.id).2.antigravity.3p-5h")?.id,
            "bar.\(apps.id).antigravity.3p-5h"
        )
        XCTAssertNil(widget.builderTile(resolvingSavedID: "bar.\(legacy.id).2.Unknown renamed metric"))
        XCTAssertNil(widget.builderTile(resolvingSavedID: "bar.unlinked.antigravity.gemini-5h"))
        let watch = WatchSnapshotPublisher.makeSnapshot(results: [result], configurationStore: store, access: SnapshotProAccess(isProLocked: false, proAccessEndsAt: nil), now: Self.now)
        XCTAssertEqual(watch.accounts.count, 1)
        XCTAssertEqual(watch.accounts.first?.metrics.map(\.id), Self.googleIDs)
        XCTAssertEqual(watch.accounts.first?.legacyAccountIDs, [WatchSnapshotPublisher.snapshotAccountID(providerID: .antigravity, configurationID: legacy.id)])
        let partial = ProviderUsageResult(
            accountID: apps.id, providerID: .gemini, title: apps.displayName, subtitle: "Coding unavailable",
            bars: Array(result.bars.prefix(2)), fetchedAt: Self.now
        )
        WidgetSnapshotPublisher.publish(results: [partial], configurationStore: store, access: SnapshotProAccess(isProLocked: false, proAccessEndsAt: nil),
        snapshotDefaults: defaults, accessGuard: WidgetAccessGuard(directory: nil), now: Self.now)
        let missing = WidgetSnapshotStore.loadSnapshot(defaults: defaults)
        XCTAssertNil(missing.builderTile(resolvingSavedID: savedID))
        XCTAssertNil(missing.builderTile(resolvingSavedID: "bar.\(legacy.id).0.Gemini-Apps-five-hour"))
    }

    @MainActor
    func testCodingCredentialReplacementAndDisconnectStaySourceAndAccountScoped() throws {
        let suite = "GoogleCredentials.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = MemorySecretStore()
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secrets)
        let apps = try XCTUnwrap(store.addAccount(for: .gemini))
        let other = try XCTUnwrap(store.addAccount(for: .gemini))
        XCTAssertTrue(store.saveSecret("apps-cookie", for: apps))
        XCTAssertFalse(store.saveGeminiCodingSecret(#"{"access_token":"token"}"#, for: apps, confirmedSameAccount: false))
        XCTAssertFalse(store.saveGeminiCodingSecret("apps-cookie", for: apps, confirmedSameAccount: true))
        XCTAssertTrue(store.saveGeminiCodingSecret(#"{"access_token":"token"}"#, for: apps, confirmedSameAccount: true))
        XCTAssertTrue(store.saveGeminiCodingSecret(#"{"access_token":"replacement"}"#, for: apps, confirmedSameAccount: true))
        XCTAssertFalse(store.hasGeminiCodingSecret(for: other))
        XCTAssertTrue(store.disconnectGeminiCoding(for: apps))
        XCTAssertFalse(store.hasGeminiCodingSecret(for: apps))
        XCTAssertEqual(try secrets.readSecret(account: ProviderConfigurationStore.keychainAccount(for: apps)), "apps-cookie")
    }

    @MainActor
    func testCodingDisconnectDeletesLinkedAuthorizationAndCannotReplayAfterRelaunch() throws {
        let suite = "GoogleDisconnect.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = MemorySecretStore()
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secrets)
        let apps = try XCTUnwrap(store.addAccount(for: .gemini))
        let legacy = try XCTUnwrap(store.addAccount(for: .antigravity))
        XCTAssertTrue(store.saveSecret(#"{"access_token":"token"}"#, for: legacy))
        XCTAssertTrue(store.linkGeminiCodingAccount(legacy, to: apps, confirmedSameAccount: true))
        XCTAssertTrue(store.disconnectGeminiCoding(for: apps))
        XCTAssertNil(try secrets.readSecret(account: ProviderConfigurationStore.keychainAccount(for: legacy)))
        let restored = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secrets)
        XCTAssertFalse(restored.hasGeminiCodingSecret(for: apps))
        XCTAssertEqual(restored.confirmedGoogleAccountLinks, [legacy.id: apps.id])
        XCTAssertTrue(restored.unlinkedGeminiCodingAccounts.isEmpty)
    }

    @MainActor
    func testCodingKeyDeletionFailureKeepsResetAccountAvailableForRetry() throws {
        let suite = "GoogleResetRetry.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = RetriableDeleteSecretStore()
        secrets.shouldFailDelete = false
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secrets)
        let apps = try XCTUnwrap(store.addAccount(for: .gemini))
        XCTAssertTrue(store.saveGeminiCodingSecret(#"{"access_token":"token"}"#, for: apps, confirmedSameAccount: true))
        secrets.failingAccount = ProviderConfigurationStore.geminiCodingKeychainAccount(accountID: apps.id)
        XCTAssertFalse(store.resetAccounts())
        XCTAssertNotNil(store.configuration(accountID: apps.id))
        XCTAssertTrue(store.hasGeminiCodingSecret(for: apps))
        secrets.failingAccount = nil
        XCTAssertTrue(store.resetAccounts())
        XCTAssertTrue(store.configurations.isEmpty)
        XCTAssertNil(try secrets.readSecret(account: ProviderConfigurationStore.geminiCodingKeychainAccount(accountID: apps.id)))
    }

    @MainActor
    func testPartialAccountRemovalInvalidatesDeletedCodingSourceAndRetainsLinkedRecords() throws {
        let suite = "GoogleRemovalRetry.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = RetriableDeleteSecretStore()
        secrets.shouldFailDelete = false
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secrets)
        let apps = try XCTUnwrap(store.addAccount(for: .gemini))
        let legacy = try XCTUnwrap(store.addAccount(for: .antigravity))
        XCTAssertTrue(store.saveSecret(#"{"access_token":"token"}"#, for: legacy))
        XCTAssertTrue(store.saveSecret("apps-cookie", for: apps))
        XCTAssertTrue(store.linkGeminiCodingAccount(legacy, to: apps, confirmedSameAccount: true))
        let service = UsageRefreshService(providers: [], initialResults: [try Self.unifiedResult(apps)])
        let dashboard = googleDashboard(store: store, service: service, defaults: defaults)
        secrets.failingAccount = ProviderConfigurationStore.keychainAccount(for: apps)
        XCTAssertFalse(store.removeAccount(apps))
        XCTAssertTrue(service.results.isEmpty)
        XCTAssertEqual(store.confirmedGoogleAccountLinks, [legacy.id: apps.id])
        XCTAssertNotNil(store.configuration(accountID: legacy.id))
        XCTAssertEqual(dashboard.dashboardCardItems.count, 1)
        secrets.failingAccount = nil
        XCTAssertTrue(store.removeAccount(apps))
        XCTAssertTrue(store.configurations.isEmpty)
        XCTAssertTrue(store.confirmedGoogleAccountLinks.isEmpty)
    }

    @MainActor
    func testStoreCodingDisconnectInvalidatesSuspendedDashboardRefresh() async throws {
        let suite = "GoogleRefreshIdentity.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: MemorySecretStore())
        let apps = try XCTUnwrap(store.addAccount(for: .gemini))
        XCTAssertTrue(store.saveGeminiCodingSecret(#"{"access_token":"token"}"#, for: apps, confirmedSameAccount: true))
        let gate = UsageProviderGate()
        let provider = StaleCompletionTestUsageProvider(providerID: .gemini, gate: gate, fails: false)
        let service = UsageRefreshService(providers: [provider], initialResults: [try Self.unifiedResult(apps)])
        let dashboard = googleDashboard(store: store, service: service, defaults: defaults)
        let refresh = Task { await dashboard.refreshNow() }
        try await withTestWatchdog(
            timeout: .seconds(5),
            failureMessage: "Gemini dashboard refresh did not reach the suspended provider within five seconds.",
            onTimeout: {
                refresh.cancel()
                Task { await gate.release() }
            },
            operation: { await gate.waitUntilBlocked() }
        )
        XCTAssertTrue(store.disconnectGeminiCoding(for: apps))
        XCTAssertTrue(service.results.isEmpty)
        await gate.release()
        _ = await refresh.value
        XCTAssertTrue(service.results.isEmpty)
        XCTAssertTrue(UsageHistoryStore(defaults: defaults).snapshots.isEmpty)
    }

    @MainActor
    func testOneUnreadableSourceDoesNotHideTheOtherGeminiCredential() throws {
        let suite = "GoogleAvailability.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = SelectiveReadFailureSecretStore()
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secrets)
        let apps = try XCTUnwrap(store.addAccount(for: .gemini))
        XCTAssertTrue(store.saveSecret("apps-cookie", for: apps))
        XCTAssertTrue(store.saveGeminiCodingSecret(#"{"access_token":"token"}"#, for: apps, confirmedSameAccount: true))
        secrets.failingAccount = ProviderConfigurationStore.keychainAccount(for: apps)
        store.refreshSecretAvailability()
        XCTAssertFalse(store.hasSecret(for: apps))
        XCTAssertTrue(store.hasGeminiCodingSecret(for: apps))
        XCTAssertTrue(store.shouldDisplayOnDashboard(apps))
        secrets.failingAccount = ProviderConfigurationStore.geminiCodingKeychainAccount(accountID: apps.id)
        store.refreshSecretAvailability()
        XCTAssertTrue(store.hasSecret(for: apps))
        XCTAssertFalse(store.hasGeminiCodingSecret(for: apps))
        XCTAssertTrue(store.shouldDisplayOnDashboard(apps))
    }

    @MainActor
    func testScreenshotFixtureContainsOneGeminiAccountAndSevenChoices() {
        let store = ProviderConfigurationStore.appStoreScreenshotDemo()
        let results = AppStoreScreenshotFixtures.results(for: store)
        XCTAssertFalse(results.contains { $0.providerID == .antigravity })
        XCTAssertEqual(results.first { $0.providerID == .gemini }?.configurableMetrics.map(\.id), Self.googleIDs)
    }

    private static let googleIDs = [
        "gemini.five-hour", "gemini.weekly", "antigravity.gemini-5h",
        "antigravity.gemini-weekly", "antigravity.gemini-argon-wtu-weekly", "antigravity.3p-5h", "antigravity.3p-weekly",
    ]

    private static func unifiedResult(_ account: ProviderAccountConfiguration) throws -> ProviderUsageResult {
        let coding = try result(payload())
        return ProviderUsageResult(
            accountID: account.id, providerID: .gemini, title: account.displayName, subtitle: "Google usage",
            bars: [
                UsageBar(stableKey: "five-hour", label: "Gemini Apps five-hour", used: 12, limit: 100),
                UsageBar(stableKey: "weekly", label: "Gemini Apps weekly", used: 45, limit: 100),
            ] + coding.bars,
            fetchedAt: now
        )
    }

    @MainActor
    private func googleDashboard(
        store: ProviderConfigurationStore,
        service: UsageRefreshService,
        defaults: UserDefaults
    ) -> DashboardOrchestrator {
        DashboardOrchestrator(
            refreshService: service, configurationStore: store,
            historyStore: UsageHistoryStore(defaults: defaults),
            usageAlertNotifier: StubUsageAlertNotifier(), appReviewPromptPolicy: AppReviewPromptPolicy(defaults: defaults),
            widgetSnapshotCoordinator: WidgetSnapshotCoordinator(
                refreshService: service, configurationStore: store, publishSnapshot: { _, _ in }, publishSettings: { _ in }
            ),
            watchSnapshotCoordinator: WatchSnapshotCoordinator(
                refreshService: service, configurationStore: store, publishSnapshot: { _, _, _ in }
            )
        )
    }

    private static let expiredCredential = #"{"access_token":"old","refresh_token":"refresh","client_id":"client","client_secret":"secret+value","expiry":"2020-01-01T00:00:00Z"}"#

    /// `loadCodeAssist` shape from OpenUsage's fixture (robinebers/openusage 61333460); values are fake.
    private static let codeAssist = Data(#"""
    {"allowedTiers":[{"id":"free-tier","isDefault":true,"name":"Antigravity Starter Quota"}],
     "cloudaicompanionProject":"fake-project-123","currentTier":{"id":"free-tier","name":"Antigravity Starter Quota"}}
    """#.utf8)

    private static func requestedProject(_ request: URLRequest) -> String? {
        guard let body = requestBodyData(from: request),
              let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        return root["project"] as? String
    }

    private static func response(_ request: URLRequest, status: Int) throws -> HTTPURLResponse {
        try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: status, httpVersion: nil, headerFields: nil))
    }

    private static func buckets() -> [[String: Any]] {
        zip(AntigravityQuotaParser.metrics, [0.0, 0.69, 0.5, 0.8, 0.4]).map { metric, remaining in
            ["bucketId": metric.key, "window": metric.window, "remainingFraction": remaining, "resetTime": "2030-09-11T16:22:20Z"]
        }
    }

    private static func payload(_ buckets: [[String: Any]] = buckets()) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["groups": [["buckets": Array(buckets.prefix(2))], ["buckets": Array(buckets.dropFirst(2))]]])
    }

    private static func result(_ data: Data) throws -> ProviderUsageResult {
        try AntigravityQuotaParser.result(from: data, configuration: configuration, fetchedAt: now)
    }
}

private final class LockedURLs: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL?] = []

    func append(_ url: URL?) {
        lock.withLock { urls.append(url) }
    }

    var values: [URL?] {
        lock.withLock { urls }
    }
}

/// Hosts of quota requests only; the `loadCodeAssist` project lookup has its own assertions.
private final class LockedHosts: @unchecked Sendable {
    private let lock = NSLock()
    private var hosts: [String] = []

    func append(_ url: URL?) {
        guard url != AntigravityUsageProvider.planURL else { return }
        lock.withLock { hosts.append(url?.host ?? "") }
    }

    var values: [String] {
        lock.withLock { hosts }
    }
}
