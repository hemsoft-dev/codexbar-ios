import XCTest
@testable import CodexBarIOS

final class GeminiUsageProviderTests: XCTestCase {
    func testCredentialParserKeepsOnlyRequiredSessionCookies() throws {
        let stored = try GeminiSessionCredentialsParser.storedCredential(
            from: "Cookie: SID=discard; __Secure-1PSID=primary-value; "
                + "__Secure-1PSIDTS=rotating-value; OTHER=discard"
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(stored.utf8)) as? [String: String]
        )
        XCTAssertEqual(
            object,
            [
                "__Secure-1PSID": "primary-value",
                "__Secure-1PSIDTS": "rotating-value",
            ]
        )
        XCTAssertFalse(stored.contains("discard"))
    }

    func testCredentialParserRejectsMissingPrimaryCookie() {
        XCTAssertThrowsError(
            try GeminiSessionCredentialsParser.storedCredential(
                from: "Cookie: __Secure-1PSIDTS=rotating-value"
            )
        )
    }

    func testCredentialParserAcceptsJSONAndKeepsOnlySupportedValues() throws {
        let stored = try GeminiSessionCredentialsParser.storedCredential(
            from: #"{"__Secure-1PSID":"primary-value","__Secure-1PSIDTS":"rotating-value","SID":"discard"}"#
        )

        XCTAssertEqual(
            try GeminiSessionCredentialsParser.parse(stored),
            GeminiSessionCredentials(
                securePSID: "primary-value",
                securePSIDTS: "rotating-value"
            )
        )
        XCTAssertFalse(stored.contains("discard"))
    }

    func testProviderFetchesFiveHourAndWeeklyUsage() async throws {
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration(
            id: "gemini.personal",
            providerID: .gemini,
            accountLabel: "Personal Gemini",
            authMethod: .apiKey
        )
        try secretStore.saveSecret(
            GeminiSessionCredentialsParser.storedCredential(
                from: "__Secure-1PSID=primary-value; __Secure-1PSIDTS=rotating-value; SID=discard"
            ),
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )

        let sessionFixture = IsolatedTestURLSession { request in
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Cookie"),
                "__Secure-1PSID=primary-value; __Secure-1PSIDTS=rotating-value"
            )
            XCTAssertFalse(request.value(forHTTPHeaderField: "Cookie")?.contains("SID=discard") == true)

            if request.url?.path == "/usage" {
                XCTAssertEqual(request.httpMethod, "GET")
                let html = #"<script>window.WIZ_global_data={"SNlM0e":"at-token","cfb2h":"build-token","FdrFJe":"session-token"};</script><div>Google AI Pro</div>"#
                return (
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!,
                    Data(html.utf8)
                )
            }

            XCTAssertEqual(request.url?.path, "/_/BardChatUi/data/batchexecute")
            XCTAssertEqual(request.httpMethod, "POST")
            let queryItems = URLComponents(
                url: try XCTUnwrap(request.url),
                resolvingAgainstBaseURL: false
            )?.queryItems
            XCTAssertEqual(queryItems?.first { $0.name == "rpcids" }?.value, "jSf9Qc")
            XCTAssertEqual(queryItems?.first { $0.name == "source-path" }?.value, "/usage")
            XCTAssertEqual(queryItems?.first { $0.name == "bl" }?.value, "build-token")
            XCTAssertEqual(queryItems?.first { $0.name == "f.sid" }?.value, "session-token")
            let requestData = try XCTUnwrap(requestBodyData(from: request))
            let body = try XCTUnwrap(String(bytes: requestData, encoding: .utf8))
            XCTAssertTrue(body.contains("at=at-token"))
            XCTAssertTrue(body.contains("jSf9Qc"))

            let payload: [Any] = [
                2,
                [
                    [48_106, 0.005_726_25, 2, [[1_781_646_433, 197_701_000]]],
                    [2_400, 0.25, 1, [[1_781_135_233, 197_509_000]]],
                ],
                false,
            ]
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                try makeGeminiBatchResponse(payload)
            )
        }
        defer { sessionFixture.invalidate() }

        let result = try await GeminiUsageProvider(
            secretStore: secretStore,
            session: sessionFixture.session
        ).fetchUsage(for: configuration)

        XCTAssertNil(result.failureMessage)
        XCTAssertEqual(result.providerID, .gemini)
        XCTAssertEqual(result.accountID, configuration.id)
        XCTAssertEqual(result.title, "Personal Gemini")
        XCTAssertNil(result.plan)
        XCTAssertEqual(result.bars.map(\.stableKey), ["five-hour", "weekly"])
        let fiveHour = try XCTUnwrap(result.bars.first)
        let weekly = try XCTUnwrap(result.bars.dropFirst().first)
        XCTAssertEqual(fiveHour.used, 25, accuracy: 0.000_001)
        XCTAssertEqual(fiveHour.resetsAt, Date(timeIntervalSince1970: 1_781_135_233))
        XCTAssertEqual(weekly.used, 0.572_625, accuracy: 0.000_001)
        XCTAssertEqual(weekly.resetsAt, Date(timeIntervalSince1970: 1_781_646_433))
    }

    func testUsageParserIgnoresUnknownSiblingBucket() throws {
        let payload: [Any] = [
            2,
            [
                [48_106, 0.5, 2, [[1_781_646_433, 0]]],
                [2_400, 0.25, 1, [[1_781_135_233, 0]]],
                [10, 0, 4, NSNull(), NSNull(), [[1_781_732_833, 0], 4]],
            ],
            false,
        ]

        let parsed = try XCTUnwrap(GeminiUsageProvider.parseUsageResponse(makeGeminiBatchResponse(payload)))
        XCTAssertEqual(parsed.fiveHour?.fractionUsed, 0.25)
        XCTAssertEqual(parsed.weekly?.fractionUsed, 0.5)
    }

    func testUsageParserRejectsFractionalAndOutOfRangePeriods() throws {
        let payload: [Any] = [
            2,
            [
                [2_400, 0.75, 1.5, [[1_781_135_233, 0]]],
                [2_400, 0.5, 1e300, [[1_781_135_233, 0]]],
                [48_106, 0.25, 2, [[1_781_646_433, 0]]],
            ],
            false,
        ]

        let parsed = try XCTUnwrap(GeminiUsageProvider.parseUsageResponse(makeGeminiBatchResponse(payload)))
        XCTAssertNil(parsed.fiveHour)
        XCTAssertEqual(parsed.weekly?.fractionUsed, 0.25)
    }

    func testProviderPropagatesCancelledRequests() async throws {
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration(
            id: "gemini.cancelled",
            providerID: .gemini,
            authMethod: .apiKey
        )
        try secretStore.saveSecret(
            GeminiSessionCredentialsParser.storedCredential(from: "__Secure-1PSID=session-value"),
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )

        let sessionFixture = IsolatedTestURLSession { _ in
            throw URLError(.cancelled)
        }
        defer { sessionFixture.invalidate() }

        do {
            _ = try await GeminiUsageProvider(
                secretStore: secretStore,
                session: sessionFixture.session
            ).fetchUsage(for: configuration)
            XCTFail("Expected cancellation to propagate")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testProviderTreatsSignInRedirectAsExpiredCredentials() async throws {
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration(
            id: "gemini.expired",
            providerID: .gemini,
            authMethod: .apiKey
        )
        try secretStore.saveSecret(
            GeminiSessionCredentialsParser.storedCredential(from: "__Secure-1PSID=expired-value"),
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )

        let sessionFixture = IsolatedTestURLSession { request in
            (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 302,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data()
            )
        }
        defer { sessionFixture.invalidate() }

        let result = try await GeminiUsageProvider(
            secretStore: secretStore,
            session: sessionFixture.session
        ).fetchUsage(for: configuration)

        XCTAssertEqual(result.recoveryAction, .reauthenticate)
        XCTAssertTrue(result.failureMessage?.contains("sign in") == true)
        XCTAssertTrue(result.preserveCachedBarsOnFailure)
    }

    func testProviderTreatsUsageRPCPermissionDeniedAsExpiredCredentials() async throws {
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .gemini)
        let (provider, sessionFixture) = try makeGeminiFixtureProvider(
            responseData: geminiPermissionDeniedFixture,
            configuration: configuration
        )
        defer { sessionFixture.invalidate() }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.recoveryAction, .reauthenticate)
        XCTAssertEqual(
            result.failureMessage,
            "Gemini rejected these session credentials. Sign in again with Google."
        )
        XCTAssertEqual(result.subtitle, result.failureMessage)
        XCTAssertTrue(result.bars.isEmpty)
        XCTAssertTrue(result.preserveCachedBarsOnFailure)
        for marker in ["fixture-account", "fixture-cookie", "fixture-token", "fixture-trace", "__Secure-1PSID"] {
            XCTAssertFalse(result.failureMessage?.contains(marker) == true)
        }
    }

    @MainActor
    func testUsageRPCPermissionDeniedPreservesStaleCachedBars() async throws {
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .gemini)
        let (provider, sessionFixture) = try makeGeminiFixtureProvider(
            responseData: geminiPermissionDeniedFixture,
            configuration: configuration
        )
        defer { sessionFixture.invalidate() }
        let cachedResult = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .gemini,
            title: configuration.displayName,
            subtitle: "Gemini Apps usage",
            bars: [
                UsageBar(stableKey: "five-hour", label: "5-hour usage limit", used: 25, limit: 100),
                UsageBar(stableKey: "weekly", label: "Weekly usage limit", used: 50, limit: 100),
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_781_000_000)
        )
        let service = UsageRefreshService(providers: [provider], initialResults: [cachedResult])

        _ = await service.refresh(configuration: configuration)

        let preserved = try XCTUnwrap(service.results.first)
        XCTAssertEqual(preserved.bars, cachedResult.bars)
        XCTAssertEqual(preserved.barsFetchedAt, cachedResult.barsFetchedAt)
        XCTAssertFalse(preserved.hasFreshBars)
        XCTAssertEqual(preserved.recoveryAction, .reauthenticate)
        XCTAssertNotNil(preserved.failureMessage)
    }

    func testUnknownAndMalformedRPCEnvelopesFailClosedWithoutReauthentication() async throws {
        let responses = [
            #"[["wrb.fr","otherRPC",null,null,null,[7],"generic"]]"#,
            #"[["wrb.fr","jSf9Qc",null,null,null,[6],"generic"]]"#,
            #"[["wrb.fr","jSf9Qc",null,null,null,[7.5],"generic"]]"#,
            #"[["wrb.fr","jSf9Qc",null,null,null,["7"],"generic"]]"#,
            #"[["wrb.fr","jSf9Qc",null,null,null,[true],"generic"]]"#,
            #"[["wrb.fr","jSf9Qc",null,null,null,7,"generic"]]"#,
            #"[["wrb.fr","jSf9Qc",null,null,null,[],"generic"]]"#,
            #"[["wrb.fr","jSf9Qc",null,null,null,null,"generic"]]"#,
            #"[["wrb.fr","jSf9Qc",null]]"#,
            #"[["wrb.fr","jSf9Qc"]]"#,
            #"[["wrb.fr","jSf9Qc",null],["unknown","jSf9Qc",null,null,null,[7]]]"#,
            #"[["wrb.fr","jSf9Qc",null,null,null,[7],"generic"]"#,
            #"[["wrb.fr","jSf9Qc","{}",null,null,null,"generic"]]"#,
            "[]",
        ]
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .gemini)
        for response in responses {
            let (provider, sessionFixture) = try makeGeminiFixtureProvider(
                responseData: Data(response.utf8),
                configuration: configuration
            )
            defer { sessionFixture.invalidate() }

            let result = try await provider.fetchUsage(for: configuration)

            XCTAssertEqual(result.recoveryAction, .retryRefresh, response)
            XCTAssertEqual(
                result.failureMessage,
                "Gemini's usage response format changed. No limit values were saved.",
                response
            )
            XCTAssertTrue(result.bars.isEmpty, response)
            XCTAssertTrue(result.preserveCachedBarsOnFailure, response)
        }
    }

    func testUnrelatedRPCRejectionDoesNotDiscardValidUsage() async throws {
        let payload: [Any] = [
            2,
            [[2_400, 0.25, 1, [[1_781_135_233, 0]]], [48_106, 0.5, 2, [[1_781_646_433, 0]]]],
            false,
        ]
        let unrelatedRejection = #"[["wrb.fr","otherRPC",null,null,null,[7],"generic"]]"#
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .gemini)
        let (provider, sessionFixture) = try makeGeminiFixtureProvider(
            responseData: Data(unrelatedRejection.utf8) + makeGeminiBatchResponse(payload),
            configuration: configuration
        )
        defer { sessionFixture.invalidate() }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertNil(result.failureMessage)
        XCTAssertEqual(result.bars.map(\.stableKey), ["five-hour", "weekly"])
        XCTAssertEqual(result.bars.map(\.used), [25, 50])
    }

    func testUsageRPCPermissionDeniedTakesPrecedenceOverValidUsage() async throws {
        let payload: [Any] = [2, [[2_400, 0.25, 1, [[1_781_135_233, 0]]]], false]
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .gemini)
        let (provider, sessionFixture) = try makeGeminiFixtureProvider(
            responseData: makeGeminiBatchResponse(payload) + geminiPermissionDeniedFixture,
            configuration: configuration
        )
        defer { sessionFixture.invalidate() }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.recoveryAction, .reauthenticate)
        XCTAssertNotNil(result.failureMessage)
        XCTAssertTrue(result.bars.isEmpty)
        XCTAssertTrue(result.preserveCachedBarsOnFailure)
    }
}

// Synthetic account, credential, and trace markers exercise response privacy.
private let geminiPermissionDeniedFixture = Data(
    """
    )]}'

    [["wrb.fr","jSf9Qc",null,null,null,[7,null,["fixture-account@example.invalid","__Secure-1PSID=fixture-cookie","fixture-token","fixture-trace"]],"generic"],["di",199]]
    """.utf8
)

private func makeGeminiFixtureProvider(
    responseData: Data,
    configuration: ProviderAccountConfiguration
) throws -> (GeminiUsageProvider, IsolatedTestURLSession) {
    let secretStore = MemorySecretStore()
    try secretStore.saveSecret(
        GeminiSessionCredentialsParser.storedCredential(from: "__Secure-1PSID=fixture-cookie"),
        account: ProviderConfigurationStore.keychainAccount(for: configuration)
    )
    try secretStore.saveSecret(
        #"{"access_token":"coding-token"}"#,
        account: ProviderConfigurationStore.geminiCodingKeychainAccount(accountID: configuration.id)
    )
    let sessionFixture = IsolatedTestURLSession { request in
        if request.url == AntigravityUsageProvider.quotaURL {
            return (try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: 503, httpVersion: nil, headerFields: nil)), Data())
        }
        let data = request.url?.path == "/usage"
            ? Data(#"<script>window.WIZ_global_data={"SNlM0e":"fixture-token"};</script>"#.utf8)
            : responseData
        return (
            HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!,
            data
        )
    }
    return (
        GeminiUsageProvider(secretStore: secretStore, session: sessionFixture.session),
        sessionFixture
    )
}

private func makeGeminiBatchResponse(_ payload: [Any]) throws -> Data {
    let payloadData = try JSONSerialization.data(withJSONObject: payload)
    let payloadString = try XCTUnwrap(String(bytes: payloadData, encoding: .utf8))
    let rows: [Any] = [
        ["wrb.fr", "jSf9Qc", payloadString, NSNull(), NSNull(), NSNull(), "generic"],
        ["di", 199],
    ]
    let rowsData = try JSONSerialization.data(withJSONObject: rows)
    let rowsString = try XCTUnwrap(String(bytes: rowsData, encoding: .utf8))
    return Data(")]}'\n\n\(rowsString)\n".utf8)
}

final class UnifiedGeminiUsageProviderTests: XCTestCase {
    private static let configuration = ProviderAccountConfiguration(
        id: "gemini.unified", providerID: .gemini, authMethod: .browserSession
    )
    private static let metricIDs = [
        "gemini.five-hour", "gemini.weekly", "antigravity.gemini-5h",
        "antigravity.gemini-weekly", "antigravity.3p-5h", "antigravity.3p-weekly",
    ]

    func testSingleGeminiCatalogKeepsSixSourceIdentitiesBeforeConnection() {
        let metrics = GoogleUsageMetricCatalog.metrics(for: .gemini)
        XCTAssertEqual(metrics.map(\.id), Self.metricIDs)
        XCTAssertTrue(metrics.allSatisfy { $0.kind == .unavailableUsage("Setup required") })
        XCTAssertTrue(GoogleUsageMetricCatalog.missingSourceConfigurations(in: [Self.configuration]).isEmpty)
        XCTAssertNil(GoogleUsageMetricCatalog.setupDescription(for: .antigravity))
        XCTAssertEqual(
            UsageBar(stableKey: "gemini-5h", label: "Renamed", used: 31, limit: 100)
                .metricIdentifier(providerID: .gemini, index: 5),
            "antigravity.gemini-5h"
        )
    }

    func testUnifiedFetchRenewsOnlyCodingCredentialAndKeepsAllSixMetrics() async throws {
        let secrets = try Self.secrets(coding: #"{"access_token":"old","refresh_token":"refresh","client_id":"client","client_secret":"client-secret","expiry":"2020-01-01T00:00:00Z"}"#)
        let fixture = IsolatedTestURLSession { request in
            if request.url == AntigravityUsageProvider.tokenURL {
                XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
                return (try Self.http(request), Data(#"{"access_token":"renewed","expires_in":3600}"#.utf8))
            }
            return try Self.response(request, codingToken: "renewed")
        }
        defer { fixture.invalidate() }
        let result = try await GeminiUsageProvider(secretStore: secrets, session: fixture.session)
            .fetchUsage(for: Self.configuration)

        XCTAssertEqual(result.providerID, .gemini)
        XCTAssertEqual(result.accountID, Self.configuration.id)
        XCTAssertEqual(result.availableMetrics.map(\.id), Self.metricIDs)
        XCTAssertEqual(result.configurableMetrics.map(\.id), Self.metricIDs)
        XCTAssertEqual(result.bars.map(\.usageText), ["12%", "45%", "100%", "31%", "20%", "60%"])
        XCTAssertEqual(result.bars[2].resetsAt, AntigravityQuotaParser.date("2030-09-11T16:22:20Z"))
        XCTAssertTrue(result.hasCurrentBars)
        XCTAssertNil(result.failureMessage)
        XCTAssertTrue(result.unavailableUsageMetrics.isEmpty)
        XCTAssertEqual(
            try secrets.readSecret(account: ProviderConfigurationStore.keychainAccount(for: Self.configuration)),
            "__Secure-1PSID=apps-cookie"
        )
        let storedCoding = try XCTUnwrap(secrets.readSecret(
            account: ProviderConfigurationStore.geminiCodingKeychainAccount(accountID: Self.configuration.id)
        ))
        XCTAssertEqual(try AntigravityCredentials.parse(storedCoding).accessToken, "renewed")
    }

    func testMissingCodingCredentialDoesNotReuseAppsCookieOrAnotherAccountsToken() async throws {
        let secrets = try Self.secrets(coding: nil)
        try secrets.saveSecret(
            #"{"access_token":"other-account"}"#,
            account: ProviderConfigurationStore.geminiCodingKeychainAccount(accountID: "gemini.other")
        )
        let fixture = IsolatedTestURLSession { request in
            XCTAssertEqual(request.url?.host, "gemini.google.com")
            return try Self.response(request)
        }
        defer { fixture.invalidate() }
        let result = try await GeminiUsageProvider(secretStore: secrets, session: fixture.session)
            .fetchUsage(for: Self.configuration)

        XCTAssertEqual(result.bars.map(\.stableKey), ["five-hour", "weekly"])
        XCTAssertEqual(result.configurableMetrics.count, 6)
        XCTAssertTrue(result.hasCurrentBars)
        XCTAssertNil(result.failureMessage)
        for metricID in Self.metricIDs.suffix(4) {
            XCTAssertTrue(result.unavailableUsageMetrics[metricID]?.contains("Coding connection required") == true)
        }
        XCTAssertFalse(result.usageMessages.joined().contains("Antigravity"))
    }

    func testAppsReauthenticationLeavesCodingMetricsCurrent() async throws {
        let secrets = try Self.secrets()
        let fixture = IsolatedTestURLSession { try Self.response($0, appsStatus: 403) }
        defer { fixture.invalidate() }
        let result = try await GeminiUsageProvider(secretStore: secrets, session: fixture.session)
            .fetchUsage(for: Self.configuration)

        XCTAssertEqual(result.availableMetrics.map(\.id), Array(Self.metricIDs.suffix(4)))
        XCTAssertTrue(result.hasCurrentBars)
        XCTAssertNil(result.failureMessage)
        XCTAssertEqual(result.recoveryAction, .reauthenticate)
        for metricID in Self.metricIDs.prefix(2) {
            XCTAssertTrue(result.unavailableUsageMetrics[metricID]?.contains("Sign in again") == true)
        }
    }

    func testBothSourceFailuresPrioritizeCredentialRecoveryAndKeepItsMessage() async throws {
        for (appsStatus, codingStatus, action, message) in [
            (503, 401, ProviderUsageRecoveryAction.reauthenticate, "Coding connection required"),
            (403, 503, .reauthenticate, "Sign in again"),
            (503, 503, .retryRefresh, "Try again later"),
            (0, 503, .signIn, "sign in with Google"),
        ] {
            let secrets = try Self.secrets()
            if appsStatus == 0 {
                try secrets.deleteSecret(account: ProviderConfigurationStore.keychainAccount(for: Self.configuration))
            }
            let fixture = IsolatedTestURLSession { request in
                let status = request.url?.host == "gemini.google.com" ? appsStatus : codingStatus
                return (try Self.http(request, status: status), Data())
            }
            defer { fixture.invalidate() }
            let result = try await GeminiUsageProvider(secretStore: secrets, session: fixture.session)
                .fetchUsage(for: Self.configuration)
            XCTAssertEqual(result.recoveryAction, action)
            XCTAssertTrue(result.failureMessage?.contains(message) == true, result.failureMessage ?? "Missing failure")
            XCTAssertTrue(result.bars.isEmpty)
            XCTAssertEqual(result.unavailableUsageMetrics.count, 6)
            XCTAssertEqual(DashboardRecoveryRoute.resolve(action: result.recoveryAction, providerID: .gemini),
                           action == .retryRefresh ? .retryRefresh : .accountSettings)
        }
    }

    @MainActor
    func testPartialCodingResponseReplacesOldSourceValuesWithoutRecordingUnavailableMetrics() async throws {
        let suite = "UnifiedGeminiPartial.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = MemorySecretStore()
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secrets)
        let account = try XCTUnwrap(store.addAccount(for: .gemini))
        XCTAssertTrue(store.saveSecret("__Secure-1PSID=apps-cookie", for: account))
        XCTAssertTrue(store.saveGeminiCodingSecret(
            #"{"access_token":"coding-token"}"#,
            for: account,
            confirmedSameAccount: true
        ))
        let fixture = IsolatedTestURLSession { try Self.response($0, partialCoding: true) }
        defer { fixture.invalidate() }
        let cached = ProviderUsageResult(
            accountID: account.id, providerID: .gemini, title: account.displayName, subtitle: "Old usage",
            bars: [UsageBar(stableKey: "gemini-weekly", label: "Old weekly", used: 99, limit: 100)],
            fetchedAt: Date(timeIntervalSince1970: 1_000)
        )
        let service = UsageRefreshService(
            providers: [GeminiUsageProvider(secretStore: secrets, session: fixture.session)], initialResults: [cached]
        )
        _ = await service.refresh(configuration: account)
        let result = try XCTUnwrap(service.results.first)
        let currentIDs = ["gemini.five-hour", "gemini.weekly", "antigravity.gemini-5h", "antigravity.3p-weekly"]
        XCTAssertEqual(result.availableMetrics.map(\.id), currentIDs)
        XCTAssertTrue(result.hasCurrentBars)
        XCTAssertEqual(result.configurableMetrics[3].kind, .unavailableUsage("Unavailable"))
        XCTAssertEqual(result.configurableMetrics[4].kind, .unavailableUsage("Disabled"))

        WidgetSnapshotPublisher.publish(results: [result], configurationStore: store, access: SnapshotProAccess(isProLocked: false, proAccessEndsAt: nil), snapshotDefaults: defaults)
        let widgetBars = WidgetSnapshotStore.loadSnapshot(defaults: defaults).results.first?.bars
        XCTAssertEqual(widgetBars?.count, currentIDs.count)
        XCTAssertEqual(widgetBars?.compactMap(\.metricID), currentIDs)
        let watch = WatchSnapshotPublisher.makeSnapshot(results: [result], configurationStore: store, access: SnapshotProAccess(isProLocked: false, proAccessEndsAt: nil))
        XCTAssertEqual(watch.accounts.first?.providerName, ProviderID.gemini.displayName)
        XCTAssertEqual(watch.accounts.first?.metrics.map(\.id), currentIDs)
        let history = UsageHistoryStore(defaults: defaults)
        history.record(results: [result])
        let snapshot = try XCTUnwrap(history.snapshots(for: account.id).first)
        XCTAssertEqual(snapshot.bars.map(\.stableKey), result.bars.map(\.stableKey))
        XCTAssertFalse(snapshot.bars.contains { $0.stableKey == "gemini-weekly" })
    }

    private static func secrets(coding: String? = #"{"access_token":"coding-token"}"#) throws -> MemorySecretStore {
        let secrets = MemorySecretStore()
        try secrets.saveSecret("__Secure-1PSID=apps-cookie", account: ProviderConfigurationStore.keychainAccount(for: configuration))
        if let coding {
            try secrets.saveSecret(coding, account: ProviderConfigurationStore.geminiCodingKeychainAccount(accountID: configuration.id))
        }
        return secrets
    }

    private static func http(_ request: URLRequest, status: Int = 200) throws -> HTTPURLResponse {
        try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: status, httpVersion: nil, headerFields: nil))
    }

    private static func response(
        _ request: URLRequest,
        codingToken: String = "coding-token",
        appsStatus: Int = 200,
        partialCoding: Bool = false
    ) throws -> (HTTPURLResponse, Data) {
        if request.url?.host == "gemini.google.com" {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "__Secure-1PSID=apps-cookie")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            let data = request.url?.path == "/usage"
                ? Data(#"<script>window.WIZ_global_data={"SNlM0e":"csrf-token"};</script>"#.utf8)
                : try makeGeminiBatchResponse([2, [[2_400, 0.12, 1, [[1_900_000_000, 0]]], [48_106, 0.45, 2, [[1_900_600_000, 0]]]], false])
            return (try http(request, status: appsStatus), data)
        }
        if request.url == AntigravityUsageProvider.planURL { return (try http(request, status: 200), Data("{}".utf8)) }
        XCTAssertEqual(request.url, AntigravityUsageProvider.quotaURL)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(codingToken)")
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        var buckets: [[String: Any]] = zip(GoogleUsageMetricCatalog.codingDefinitions, [0.0, 0.69, 0.8, 0.4]).map { metric, remaining in
            ["bucketId": metric.key, "window": metric.window, "remainingFraction": remaining, "resetTime": "2030-09-11T16:22:20Z"]
        }
        if partialCoding {
            buckets[1].removeValue(forKey: "remainingFraction")
            buckets[2]["disabled"] = true
        }
        return (try http(request), try JSONSerialization.data(withJSONObject: ["groups": [["buckets": buckets]]]))
    }
}

final class UsageRefreshCredentialInvalidationTests: XCTestCase {
    @MainActor
    func testCredentialInvalidationRejectsSuspendedSingleAndBatchRefreshCompletions() async {
        for isBatch in [false, true] {
            for fails in [false, true] {
                let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .gemini)
                let gate = UsageProviderGate()
                let cached = makeHistoryResult(accountID: configuration.id, providerID: .gemini, fetchedAt: Date(), used: 15)
                let service = UsageRefreshService(
                    providers: [StaleCompletionTestUsageProvider(providerID: .gemini, gate: gate, fails: fails)],
                    initialResults: [cached]
                )
                service.updateCurrentConfigurations([configuration])
                let refresh = Task {
                    if isBatch {
                        await service.refresh(configurations: [configuration])
                    } else {
                        _ = await service.refresh(configuration: configuration)
                    }
                }
                await gate.waitUntilBlocked()
                service.invalidateCredentials(accountID: configuration.id)
                XCTAssertTrue(service.results.isEmpty)
                XCTAssertEqual(service.refreshingAccountIDs, [configuration.id])

                await gate.release()
                await refresh.value
                XCTAssertTrue(service.results.isEmpty, "Batch: \(isBatch), failed response: \(fails)")
                XCTAssertTrue(service.refreshErrorsByAccountID.isEmpty)
                XCTAssertNil(service.lastRefreshError)
                XCTAssertTrue(service.refreshingAccountIDs.isEmpty)
                XCTAssertEqual(service.trackedRefreshGenerationCount, 1)
                if !fails {
                    let replacement = await service.refresh(configuration: configuration)
                    XCTAssertEqual(replacement?.bars.first?.used, 95)
                    XCTAssertEqual(service.results.first?.bars.first?.used, 95)
                }
            }
        }
    }

    @MainActor
    func testCredentialInvalidationClearsOnlyTargetAccountAndDoesNotTrackUnknownAccounts() async {
        let target = ProviderAccountConfiguration(id: "gemini.target", providerID: .gemini, authMethod: .browserSession)
        let other = ProviderAccountConfiguration(id: "gemini.other", providerID: .gemini, authMethod: .browserSession)
        let service = UsageRefreshService(providers: [
            SelectivelyFailingUsageProvider(providerID: .gemini, failedAccountID: target.id),
        ])
        await service.refresh(configurations: [target, other])
        let otherResult = service.results.first { $0.accountID == other.id }
        XCTAssertNotNil(service.refreshErrorsByAccountID[target.id])
        XCTAssertNotNil(service.lastRefreshError)

        service.invalidateCredentials(accountID: target.id)

        XCTAssertEqual(service.results, otherResult.map { [$0] } ?? [])
        XCTAssertTrue(service.refreshErrorsByAccountID.isEmpty)
        XCTAssertNil(service.lastRefreshError)
        for index in 0..<100 {
            service.invalidateCredentials(accountID: "absent.\(index)")
        }
        XCTAssertEqual(service.trackedRefreshGenerationCount, 2)
    }

    @MainActor
    func testConfigurationSnapshotExcludesArchivedCodingAccounts() async {
        let gemini = ProviderAccountConfiguration.defaultConfiguration(for: .gemini)
        let legacy = ProviderAccountConfiguration.defaultConfiguration(for: .antigravity)
        let legacyResult = makeHistoryResult(accountID: legacy.id, providerID: .antigravity, fetchedAt: Date(), used: 15)
        let service = UsageRefreshService(providers: [], initialResults: [legacyResult])

        service.updateCurrentConfigurations([gemini, legacy])

        XCTAssertEqual(service.trackedRefreshGenerationCount, 1)
        XCTAssertTrue(service.results.isEmpty)
        let legacyRefresh = await service.refresh(configuration: legacy)
        XCTAssertNil(legacyRefresh)
    }
}

final class GeminiSessionLifetimeTests: XCTestCase {
    func testReleasingFiftyProvidersReleasesOwnedSessionsAndDelegates() async throws {
        let references = try (0..<50).map { _ in
            try autoreleasepool {
                try GeminiLifetimeReferences(GeminiUsageProvider(secretStore: EmptySecretStore()))
            }
        }

        try await assertReleased(references)
    }

    func testOwnedSessionIsReleasedAfterSuccessfulFetch() async throws {
        try await assertReleased([fetchAndReleaseProvider(outcome: "success")])
    }

    func testOwnedSessionIsReleasedAfterFailedFetch() async throws {
        try await assertReleased([fetchAndReleaseProvider(outcome: "failure")])
    }

    func testOwnedSessionIsReleasedAfterCancelledFetch() async throws {
        try await assertReleased([fetchAndReleaseProvider(outcome: "cancel")])
    }

    func testInjectedSessionRemainsUsableAfterProviderIsReleased() async throws {
        let fixture = IsolatedTestURLSession { request in
            (HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("owner request".utf8))
        }
        defer { fixture.invalidate() }
        weak var provider: GeminiUsageProvider?
        autoreleasepool {
            let value = GeminiUsageProvider(secretStore: EmptySecretStore(), session: fixture.session)
            provider = value
        }
        XCTAssertNil(provider)

        let (data, response) = try await fixture.session.data(from: XCTUnwrap(URL(string: "https://example.invalid/owner")))

        XCTAssertEqual(data, Data("owner request".utf8))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }

    func testOwnedSessionDisablesCookieStorageAndAutomaticCookies() throws {
        let provider = GeminiUsageProvider(secretStore: EmptySecretStore())
        let session = try ownedSession(of: provider)
        let configuration = session.configuration
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        let request = provider.makeBootstrapRequest(credentials: GeminiSessionCredentials(securePSID: "fixture-cookie", securePSIDTS: nil))
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "__Secure-1PSID=fixture-cookie")
    }

    func testOwnedSessionRedirectDelegateOnlyAllowsGeminiHTTPSOrigin() throws {
        let provider = GeminiUsageProvider(secretStore: EmptySecretStore())
        let session = try ownedSession(of: provider)
        let delegate = try XCTUnwrap(session.delegate as? URLSessionTaskDelegate)
        let origin = try XCTUnwrap(URL(string: "https://gemini.google.com/usage"))
        let task = session.dataTask(with: origin)
        defer { task.cancel() }
        let response = try XCTUnwrap(HTTPURLResponse(url: origin, statusCode: 302, httpVersion: nil, headerFields: nil))
        let destinations = [
            ("https://gemini.google.com/usage?pli=1", true),
            ("https://gemini.google.com:443/usage", true),
            ("http://gemini.google.com/usage", false),
            ("https://accounts.google.com/signin", false),
            ("https://gemini.google.com.attacker.invalid/usage", false),
            ("https://gemini.google.com:444/usage", false),
        ]
        for (destination, allowed) in destinations {
            let request = URLRequest(url: try XCTUnwrap(URL(string: destination)))
            let completion = expectation(description: "Redirect decision for \(destination)")
            delegate.urlSession?(session, task: task, willPerformHTTPRedirection: response, newRequest: request) {
                XCTAssertEqual($0?.url, allowed ? request.url : nil, destination)
                completion.fulfill()
            }
            wait(for: [completion], timeout: 3)
        }
    }

    private func fetchAndReleaseProvider(outcome: String) async throws -> GeminiLifetimeReferences {
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .gemini)
        let store = MemorySecretStore()
        try store.saveSecret("__Secure-1PSID=fixture-cookie", account: ProviderConfigurationStore.keychainAccount(for: configuration))
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [GeminiLifetimeURLProtocol.self]
        let provider = GeminiUsageProvider(
            secretStore: store,
            sessionConfiguration: sessionConfiguration,
            usageURL: try XCTUnwrap(URL(string: "https://\(outcome).gemini-lifetime.invalid/usage"))
        )
        let references = try GeminiLifetimeReferences(provider)
        do {
            let result = try await provider.fetchUsage(for: configuration)
            XCTAssertNotEqual(outcome, "cancel", "Cancellation must propagate")
            if outcome == "success" {
                XCTAssertNil(result.failureMessage)
                XCTAssertEqual(result.bars.map(\.used), [25])
            } else {
                XCTAssertNotNil(result.failureMessage)
            }
        } catch is CancellationError {
            XCTAssertEqual(outcome, "cancel")
        }
        return references
    }

    private func assertReleased(_ references: [GeminiLifetimeReferences]) async throws {
        // Also clean up sessions when the regression fails against the old implementation.
        defer { references.forEach { $0.session?.invalidateAndCancel() } }
        // URL-loading cleanup runs asynchronously; allow scheduling headroom on CI.
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while references.contains(where: { !$0.isReleased }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(references.filter { $0.provider != nil }.count, 0, "Providers must be released")
        XCTAssertEqual(references.filter { $0.session != nil }.count, 0, "Owned sessions must be released")
        XCTAssertEqual(references.filter { $0.delegate != nil }.count, 0, "Owned delegates must be released")
    }
}

private final class GeminiLifetimeReferences {
    weak var provider: GeminiUsageProvider?
    weak var session: URLSession?
    weak var delegate: AnyObject?

    var isReleased: Bool { provider == nil && session == nil && delegate == nil }

    init(_ provider: GeminiUsageProvider) throws {
        self.provider = provider
        let session = try ownedSession(of: provider)
        self.session = session
        self.delegate = try XCTUnwrap(session.delegate)
    }
}

private func ownedSession(of provider: GeminiUsageProvider) throws -> URLSession {
    try XCTUnwrap(Mirror(reflecting: provider).children.first { $0.label == "session" }?.value as? URLSession)
}

// Each owned session installs this protocol without any process-wide registration.
private final class GeminiLifetimeURLProtocol: URLProtocol, @unchecked Sendable {
    // URLProtocol requires overridable class methods.
    // swiftlint:disable:next static_over_final_class
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".gemini-lifetime.invalid") == true
    }

    // swiftlint:disable:next static_over_final_class
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if request.url?.host == "cancel.gemini-lifetime.invalid" {
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
            return
        }
        do {
            let status = request.url?.host == "failure.gemini-lifetime.invalid" ? 503 : 200
            let response = try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: status, httpVersion: nil, headerFields: nil))
            let data = request.url?.path == "/usage"
                ? Data(#"<script>window.WIZ_global_data={"SNlM0e":"fixture-token"};</script>"#.utf8)
                : try makeGeminiBatchResponse([2, [[2_400, 0.25, 1, [[1_781_135_233, 0]]]], false])
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

extension GeminiUsageProviderTests {
    func testAllSixGeminiMetricsProjectOrdinaryPaceAndExhaustion() throws {
        let now = Date(timeIntervalSince1970: 1_788_640_000)
        for fraction in [0.2, 0.6] {
            let bars = try projectionBars(fraction: fraction, now: now)
            XCTAssertEqual(bars.map(\.stableKey), ["five-hour", "weekly", "gemini-5h", "gemini-weekly", "3p-5h", "3p-weekly"])
            for bar in bars {
                XCTAssertEqual(bar.fractionUsed, fraction, accuracy: 0.000_001)
                XCTAssertEqual(try XCTUnwrap(bar.projectedFraction(at: now)), min(fraction * 2, 1), accuracy: 0.000_001)
                XCTAssertTrue(bar.showProjectionOnCurrentBar)
                let parts = try XCTUnwrap(bar.projectionDescriptionParts(at: now))
                if fraction == 0.2 {
                    XCTAssertEqual(parts.leadingText, "Projected to stay under limit")
                    XCTAssertEqual(parts.significance, .benign)
                    XCTAssertNil(bar.dashboardProjectionDescription(at: now))
                } else {
                    let start = try XCTUnwrap(bar.projectionPeriodStart)
                    let hit = start.addingTimeInterval(now.timeIntervalSince(start) / fraction)
                    XCTAssertEqual(try XCTUnwrap(parts.timestamp).timeIntervalSince1970, hit.timeIntervalSince1970, accuracy: 0.001)
                    XCTAssertTrue(parts.trailingText.contains("early"))
                    XCTAssertNotNil(bar.dashboardProjectionDescription(at: now))
                }
            }
        }
    }

    func testAllSixGeminiResetCaptionsMatchCodexEvenWhenProjectionIsBenign() throws {
        let now = Date(timeIntervalSince1970: 1_788_640_000)
        let bars = try projectionBars(fraction: 0.2, now: now)
        XCTAssertEqual(bars.count, 6)
        for zone in ["America/New_York", "Europe/Berlin"] {
            let formatter = UserFacingDateTimeFormatter(
                timeZone: try XCTUnwrap(TimeZone(identifier: zone)), locale: Locale(identifier: "en_US")
            )
            for bar in bars {
                let reset = try XCTUnwrap(bar.resetsAt)
                let start = try XCTUnwrap(bar.projectionPeriodStart)
                let window: [String: Any] = [
                    "used_percent": 20, "reset_at": reset.timeIntervalSince1970,
                    "limit_window_seconds": Int(reset.timeIntervalSince(start)),
                ]
                let data = try JSONSerialization.data(withJSONObject: ["rate_limit": ["primary_window": window]])
                let codex = try XCTUnwrap(CodexUsageParser.parse(data, fetchedAt: now)?.bars.first)
                let caption = try XCTUnwrap(bar.localizedResetDescription(at: now, dateTimeFormatter: formatter))
                XCTAssertEqual(caption, codex.localizedResetDescription(at: now, dateTimeFormatter: formatter))
                XCTAssertTrue(caption.hasPrefix(reset.timeIntervalSince(now) >= 86_400 ? "Resets 3d 12h" : "Resets 2h"))
                XCTAssertTrue(caption.contains(formatter.timeWithZone(reset, includesWeekday: reset.timeIntervalSince(now) >= 86_400)))
                XCTAssertNil(bar.dashboardProjectionDescription(at: now))
            }
        }
    }

    func testCodingResetCaptionsDoNotInventMissingMalformedOrExpiredTimes() throws {
        let now = Date(timeIntervalSince1970: 1_788_640_000)
        for reset: Any in [NSNull(), "bad", "2020-01-01T00:00:00Z", ISO8601DateFormatter().string(from: now)] {
            let buckets: [[String: Any]] = AntigravityQuotaParser.metrics.map { metric in
                ["bucketId": metric.key, "window": metric.window, "remainingFraction": 0.8, "resetTime": reset]
            }
            let result = try codingProjectionResult(buckets: buckets, now: now)
            if reset is NSNull {
                XCTAssertEqual(result.bars.count, 4)
                for bar in result.bars {
                    XCTAssertNil(bar.resetsAt)
                    XCTAssertNil(bar.localizedResetDescription(at: now))
                    XCTAssertNil(bar.projectedFraction(at: now))
                }
            } else {
                XCTAssertTrue(result.bars.isEmpty)
                XCTAssertEqual(result.unavailableUsageMetrics.count, 4)
            }
        }
    }

    func testGeminiProjectionSafeguardsForZeroExpiredAndNotStartedWindows() throws {
        let now = Date(timeIntervalSince1970: 1_788_640_000)
        for bar in try projectionBars(fraction: 0, now: now) {
            XCTAssertNil(bar.projectedFraction(at: now))
            XCTAssertNil(bar.projectionDescription(at: now))
        }
        for bar in try projectionBars(fraction: 0.2, now: now) {
            for time in [try XCTUnwrap(bar.projectionPeriodStart), try XCTUnwrap(bar.projectionPeriodEnd)] {
                XCTAssertEqual(try XCTUnwrap(bar.projectedFraction(at: time)), bar.fractionUsed, accuracy: 0.000_001)
                XCTAssertNil(bar.projectionDescription(at: time))
            }
        }
    }

    func testGeminiParsersDoNotBorrowMissingOrInvalidResetTimes() throws {
        let now = Date(timeIntervalSince1970: 1_788_640_000)
        let validReset = now.addingTimeInterval(9_000).timeIntervalSince1970
        for invalid: Any in [NSNull(), "bad", []] {
            let payload: [Any] = [2, [[2_400, 0.2, 1, [[validReset, 0]]], [48_106, 0.2, 2, invalid]], false]
            let parsed = try XCTUnwrap(GeminiUsageProvider.parseUsageResponse(makeGeminiBatchResponse(payload)))
            XCTAssertEqual(GeminiUsageProvider.bars(from: parsed).map(\.stableKey), ["five-hour"])
        }
        for reset: Any in [NSNull(), "bad", "2020-01-01T00:00:00Z"] {
            let buckets: [[String: Any]] = [
                ["bucketId": "gemini-5h", "window": "5h", "remainingFraction": 0.8, "resetTime": reset],
                ["bucketId": "3p-weekly", "window": "weekly", "remainingFraction": 0.8,
                 "resetTime": ISO8601DateFormatter().string(from: now.addingTimeInterval(302_400)),
                ],
            ]
            let result = try codingProjectionResult(buckets: buckets, now: now)
            let missing = result.bars.first { $0.stableKey == "gemini-5h" }
            if reset is NSNull {
                XCTAssertNotNil(missing)
                XCTAssertNil(missing?.projectedFraction(at: now))
                XCTAssertNil(missing?.projectionDescription(at: now))
            } else {
                XCTAssertNil(missing)
                XCTAssertEqual(result.unavailableUsageMetrics["antigravity.gemini-5h"], "Unavailable")
            }
            let weekly = try XCTUnwrap(result.bars.first { $0.stableKey == "3p-weekly" })
            XCTAssertEqual(try XCTUnwrap(weekly.projectedFraction(at: now)), 0.4, accuracy: 0.000_001)
        }
    }

    @MainActor
    func testSixGeminiProjectionsSurviveWidgetSnapshotSerialization() throws {
        let now = Date(timeIntervalSince1970: 1_788_640_000)
        let suite = "GeminiProjection.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: MemorySecretStore())
        let account = try XCTUnwrap(store.addAccount(for: .gemini))
        XCTAssertTrue(store.saveSecret("__Secure-1PSID=fixture", for: account))
        for fraction in [0.2, 0.6] {
            let bars = try projectionBars(fraction: fraction, now: now)
            let result = ProviderUsageResult(
                accountID: account.id, providerID: .gemini, title: account.displayName, subtitle: "Gemini usage", bars: bars, fetchedAt: now
            )
            WidgetSnapshotPublisher.publish(results: [result], configurationStore: store, access: SnapshotProAccess(isProLocked: false, proAccessEndsAt: nil), snapshotDefaults: defaults, now: now)
            let saved = try XCTUnwrap(WidgetSnapshotStore.loadSnapshot(defaults: defaults).results.first)
            XCTAssertEqual(saved.accountID, account.id)
            XCTAssertEqual(saved.bars.count, 6)
            for bar in saved.bars {
                XCTAssertEqual(bar.fractionUsed, fraction, accuracy: 0.000_001)
                XCTAssertEqual(try XCTUnwrap(bar.projectedFraction), min(fraction * 2, 1), accuracy: 0.000_001)
                let isCoding = GoogleUsageMetricCatalog.codingDefinitions.contains { $0.id == bar.metricID }
                if fraction == 0.2 && isCoding {
                    XCTAssertNil(bar.localizedProjectionDescription())
                    XCTAssertNil(bar.projectionLeadingText)
                    XCTAssertNil(bar.projectionTimestamp)
                    XCTAssertNil(bar.projectionTrailingText)
                    XCTAssertTrue(try XCTUnwrap(bar.localizedResetDescription(at: now)).hasPrefix("Resets"))
                } else if fraction == 0.2 {
                    XCTAssertEqual(bar.localizedProjectionDescription(), "Projected to stay under limit")
                } else {
                    XCTAssertTrue(try XCTUnwrap(bar.localizedProjectionDescription()).contains("early"))
                    XCTAssertNotNil(bar.projectionTimestamp)
                }
            }
        }
    }

    private func projectionBars(fraction: Double, now: Date) throws -> [UsageBar] {
        let payload: [Any] = [2, [
            [2_400, fraction, 1, [[now.addingTimeInterval(9_000).timeIntervalSince1970, 0]]],
            [48_106, fraction, 2, [[now.addingTimeInterval(302_400).timeIntervalSince1970, 0]]],
        ], false,
        ]
        let parsed = try XCTUnwrap(GeminiUsageProvider.parseUsageResponse(makeGeminiBatchResponse(payload)))
        let buckets: [[String: Any]] = AntigravityQuotaParser.metrics.map { metric in
            let reset = now.addingTimeInterval(metric.window == "5h" ? 9_000 : 302_400)
            return ["bucketId": metric.key, "window": metric.window, "remainingFraction": 1 - fraction,
                    "resetTime": ISO8601DateFormatter().string(from: reset),
            ]
        }
        return GeminiUsageProvider.bars(from: parsed) + (try codingProjectionResult(buckets: buckets, now: now)).bars
    }

    private func codingProjectionResult(buckets: [[String: Any]], now: Date) throws -> ProviderUsageResult {
        let data = try JSONSerialization.data(withJSONObject: ["groups": [["buckets": buckets]]])
        let account = ProviderAccountConfiguration(id: "gemini.projection", providerID: .gemini, authMethod: .apiKey)
        return try AntigravityQuotaParser.result(from: data, configuration: account, fetchedAt: now)
    }
}

final class GoogleAIPlanTests: XCTestCase {
    func testNamedSubscriptionMappingAndVariants() throws {
        for name in ["Google AI Free", "Google AI Plus", "Google AI Pro", "Google AI Ultra",
                     "Google AI Pro (5 TB)", "Google AI Pro (10 TB)", "Google AI Plus (400 GB)",
                     "Google AI Plus (2 TB)", "Google AI Ultra 5x", "Google AI Ultra 20x",
                     "Google AI Ultra (5x)", "Google AI Ultra (20x)",
        ] {
            let plan = try XCTUnwrap(GoogleAIPlanParser.namedPlan(name))
            XCTAssertEqual(plan.displayLabel, name)
            XCTAssertEqual(plan.accessibilityLabel, name)
        }
        XCTAssertEqual(GoogleAIPlanParser.namedPlan("Gemini Code Assist in Google One AI Pro")?.displayLabel, "Google AI Pro")
        for name in ["Free", "free-tier", "standard-tier", "Gemini Code Assist Standard", "Workspace",
                     "Google AI Enterprise", "Google AI Pro 20x", "Google AI Ultra 100x", "Upgrade to Google AI Pro",
                     "Google AI Pro\nUpgrade", "Pro", "Google AI Pro (unknown)",
        ] {
            XCTAssertNil(GoogleAIPlanParser.namedPlan(name), name)
        }
    }

    func testOnlyAssignedNamedTiersEstablishPlan() throws {
        let paid = Data(#"{"currentTier":{"id":"free-tier"},"paidTier":{"name":"Google AI Pro (5 TB)"}}"#.utf8)
        XCTAssertEqual(GoogleAIPlanParser.parse(paid)?.displayLabel, "Google AI Pro (5 TB)")
        let free = Data(#"{"currentTier":{"name":"Google AI Free"}}"#.utf8)
        XCTAssertEqual(GoogleAIPlanParser.parse(free)?.displayLabel, "Google AI Free")
        for body in ["{}", "null", "[]", "bad", #"{"currentTier":{"id":"free-tier"}}"#,
                     #"{"allowedTiers":[{"name":"Google AI Ultra"}]}"#,
                     #"{"paidTier":{"name":"Workspace"},"currentTier":{"name":"Google AI Free"}}"#,
                     #"{"paidTier":{"name":123}}"#, #"{"credits":200,"plan":"Google AI Pro"}"#,
        ] {
            XCTAssertNil(GoogleAIPlanParser.parse(Data(body.utf8)), body)
        }
    }

    func testOptionalLookupUsesOnlyAccountCodingGrantAndRejectsReplacement() async throws {
        let secrets = MemorySecretStore()
        let key = ProviderConfigurationStore.geminiCodingKeychainAccount(accountID: "personal")
        try secrets.saveSecret(#"{"access_token":"personal"}"#, account: key)
        try secrets.saveSecret(#"{"access_token":"other"}"#,
                               account: ProviderConfigurationStore.geminiCodingKeychainAccount(accountID: "other"))
        let fixture = IsolatedTestURLSession { request in
            XCTAssertEqual(request.url, AntigravityUsageProvider.planURL)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer personal")
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertEqual(request.timeoutInterval, 8)
            let body = try XCTUnwrap(requestBodyData(from: request))
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let metadata = try XCTUnwrap(root["metadata"] as? [String: String])
            XCTAssertEqual(metadata["ideType"], "IDE_UNSPECIFIED")
            XCTAssertEqual(metadata["ideName"], "CodexBar iOS")
            if try secrets.readSecret(account: "replace") != nil {
                try secrets.saveSecret(#"{"access_token":"replacement"}"#, account: key)
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"paidTier":{"name":"Google AI Pro (5 TB)"}}"#.utf8))
        }
        defer { fixture.invalidate() }
        let provider = AntigravityUsageProvider(secretStore: secrets, sessionConfiguration: fixture.session.configuration)
        let plan = try await provider.googlePlan(keychainAccount: key)
        XCTAssertEqual(plan?.displayLabel, "Google AI Pro (5 TB)")
        try secrets.saveSecret("yes", account: "replace")
        let replaced = try await provider.googlePlan(keychainAccount: key)
        XCTAssertNil(replaced)
        let missing = try await provider.googlePlan(keychainAccount: "not-configured")
        XCTAssertNil(missing)
    }

    func testOptionalLookupFailureDoesNotBecomeFree() async throws {
        for status in [401, 403, 503, 200] {
            let secrets = MemorySecretStore()
            try secrets.saveSecret(#"{"access_token":"personal"}"#, account: "coding")
            let fixture = IsolatedTestURLSession { request in
                (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data("{}".utf8))
            }
            defer { fixture.invalidate() }
            let provider = AntigravityUsageProvider(secretStore: secrets, sessionConfiguration: fixture.session.configuration)
            let plan = try await provider.googlePlan(keychainAccount: "coding")
            XCTAssertNil(plan)
        }
    }

    @MainActor
    func testCombinedPlansStayAccountBoundAndClearAfterFailedLookupOrReconnect() async throws {
        let secrets = MemorySecretStore()
        let personal = ProviderAccountConfiguration(id: "personal", providerID: .gemini, accountLabel: "Google AI Ultra", authMethod: .browserSession)
        let work = ProviderAccountConfiguration(id: "work", providerID: .gemini, accountLabel: "Google AI Free", authMethod: .browserSession)
        for account in [personal, work] {
            try secrets.saveSecret("__Secure-1PSID=\(account.id)", account: ProviderConfigurationStore.keychainAccount(for: account))
            try secrets.saveSecret("{\"access_token\":\"\(account.id)\"}",
                                   account: ProviderConfigurationStore.geminiCodingKeychainAccount(accountID: account.id))
        }
        let fixture = IsolatedTestURLSession { request in
            let mode = try secrets.readSecret(account: "test-mode")
            let failure = mode == "failure"
            let planFailure = request.url == AntigravityUsageProvider.planURL && mode == "plan-failure"
            let status = failure || planFailure ? 503 : 200
            let body: Data
            if request.url == AntigravityUsageProvider.planURL {
                let name = request.value(forHTTPHeaderField: "Authorization") == "Bearer personal" ? "Google AI Pro (5 TB)" : "Google AI Plus"
                body = Data("{\"paidTier\":{\"name\":\"\(name)\"}}".utf8)
            } else if request.url == AntigravityUsageProvider.quotaURL {
                body = Data(#"{"groups":[]}"#.utf8)
            } else if request.url?.path == "/usage" {
                body = Data(#"<script>window.WIZ_global_data={"SNlM0e":"csrf"};</script>"#.utf8)
            } else {
                body = try makeGeminiBatchResponse([2, [[2_400, 0.12, 1, [[1_900_000_000, 0]]]], false])
            }
            return (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, body)
        }
        defer { fixture.invalidate() }
        let provider = GeminiUsageProvider(secretStore: secrets, session: fixture.session)
        async let first = provider.fetchUsage(for: personal)
        async let second = provider.fetchUsage(for: work)
        let results = try await [first, second]
        XCTAssertEqual(results.map { $0.plan?.displayLabel }, ["Google AI Pro (5 TB)", "Google AI Plus"])
        XCTAssertEqual(results.map(\.accountID), [personal.id, work.id])
        let service = UsageRefreshService(providers: [provider])
        await service.refresh(configurations: [personal])
        XCTAssertEqual(service.results.first?.plan?.displayLabel, "Google AI Pro (5 TB)")
        service.invalidateCredentials(accountID: personal.id, preserveCachedResult: true)
        XCTAssertNil(service.results.first?.plan)
        await service.refresh(configurations: [personal])
        XCTAssertNotNil(service.results.first?.plan)
        try secrets.saveSecret("plan-failure", account: "test-mode")
        await service.refresh(configurations: [personal])
        XCTAssertNil(service.results.first?.plan)
        XCTAssertNil(service.results.first?.failureMessage)
        XCTAssertFalse(service.results.first?.bars.isEmpty ?? true)
        try secrets.saveSecret("failure", account: "test-mode")
        await service.refresh(configurations: [personal])
        XCTAssertNil(service.results.first?.plan)
        XCTAssertNotNil(service.results.first?.failureMessage)
        XCTAssertFalse(service.results.first?.bars.isEmpty ?? true)
    }

    func testOpenCodeHeaderOmitsPillEvenWithPlanMetadata() {
        for plan in [nil, GoogleAIPlanParser.namedPlan("Google AI Pro")] {
            let result = ProviderUsageResult(accountID: "go", providerID: .openCodeZen, title: "OpenCode Go + Zen",
                                             plan: plan, subtitle: "Usage", bars: [], fetchedAt: Date())
            XCTAssertFalse(result.showsCardPlan)
            XCTAssertEqual(ProviderUsageCard.headerAccessibilityLabel(for: result), "OpenCode Go + Zen")
        }
        let google = ProviderUsageResult(accountID: "google", providerID: .gemini, title: "Personal",
                                        plan: GoogleAIPlanParser.namedPlan("Google AI Pro"), subtitle: "Usage", bars: [], fetchedAt: Date())
        XCTAssertTrue(google.showsCardPlan)
        XCTAssertEqual(ProviderUsageCard.headerAccessibilityLabel(for: google), "Personal, Google AI Pro")
    }
}
