import XCTest
@testable import CodexBarIOS

final class ProviderParsingTests: XCTestCase {
    func testGreptileProviderUsesReadOnlyMCPPaginationAndCountsReviewStatuses() async throws {
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration(
            id: "greptile.team-a",
            providerID: .greptile,
            accountLabel: "Team A reviews",
            authMethod: .apiKey
        )
        try secretStore.saveSecret(
            "Authorization: Bearer greptile-test-key",
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )

        let sessionFixture = IsolatedTestURLSession { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.greptile.com/mcp")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer greptile-test-key")
            let body = try XCTUnwrap(requestBodyData(from: request))
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(root["jsonrpc"] as? String, "2.0")
            XCTAssertEqual(root["method"] as? String, "tools/call")
            let params = try XCTUnwrap(root["params"] as? [String: Any])
            XCTAssertEqual(params["name"] as? String, "list_code_reviews")
            let arguments = try XCTUnwrap(params["arguments"] as? [String: Any])
            XCTAssertEqual(arguments["limit"] as? Int, 3)
            let offset = try XCTUnwrap(arguments["offset"] as? Int)

            let payload: String
            switch offset {
            case 0:
                payload = #"{"jsonrpc":"2.0","id":"one","result":{"content":[{"type":"text","text":"{\"codeReviews\":[{\"id\":\"r1\",\"status\":\"COMPLETED\",\"mergeRequest\":{\"prNumber\":45}},{\"id\":\"r2\",\"status\":\"COMPLETED\",\"mergeRequest\":{\"prNumber\":45}},{\"id\":\"r3\",\"status\":\"PENDING\"}],\"total\":8}"}]}}"#
            case 3:
                payload = #"{"jsonrpc":"2.0","id":"two","result":{"structuredContent":{"codeReviews":[{"id":"r4","status":"REVIEWING_FILES"},{"id":"r5","status":"GENERATING_SUMMARY"},{"id":"r6","status":"FAILED","futureField":{"ignored":true}}],"total":8}}}"#
            case 6:
                payload = #"{"jsonrpc":"2.0","id":"three","result":{"codeReviews":[{"id":"r7","status":"SKIPPED"},{"id":"r8","status":"FUTURE_STATUS"}],"total":8}}"#
            default:
                XCTFail("Unexpected Greptile pagination offset \(offset)")
                payload = #"{"result":{"codeReviews":[],"total":8}}"#
            }

            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(payload.utf8)
            )
        }
        defer { sessionFixture.invalidate() }

        let provider = GreptileUsageProvider(
            secretStore: secretStore,
            session: sessionFixture.session,
            pageSize: 3
        )
        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.providerID, .greptile)
        XCTAssertEqual(result.accountID, configuration.id)
        XCTAssertEqual(result.title, "Team A reviews")
        XCTAssertEqual(result.subtitle, "")
        let completed = try XCTUnwrap(result.bars.first)
        XCTAssertEqual(completed.stableKey, GreptileUsageIdentity.completedReviewsStableKey)
        XCTAssertEqual(completed.label, "Completed reviews")
        XCTAssertEqual(completed.used, 2)
        XCTAssertEqual(completed.limit, 0)
        XCTAssertEqual(completed.usageText, "2")
        XCTAssertEqual(completed.severity, .normal)
        XCTAssertEqual(result.availableMetrics.first?.id, GreptileUsageIdentity.completedReviewsMetricID)
        XCTAssertTrue(result.usageMessages.isEmpty)

        let statusItems = try XCTUnwrap(result.cardInformationSections.first).items
        let counts = Dictionary(uniqueKeysWithValues: statusItems.map { ($0.label, $0.detail) })
        XCTAssertEqual(counts["Completed"], "2")
        XCTAssertEqual(counts["Pending"], "1")
        XCTAssertEqual(counts["In progress"], "2")
        XCTAssertEqual(counts["Failed"], "1")
        XCTAssertEqual(counts["Skipped"], "1")
        XCTAssertEqual(counts["Other statuses"], "1")
    }

    func testGreptileProviderUsesReturnedBillingPeriodReviewQuota() async throws {
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration(providerID: .greptile, authMethod: .apiKey)
        try secretStore.saveSecret(
            "greptile-test-key",
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
        let sessionFixture = IsolatedTestURLSession { request in
            (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(
                    #"{"result":{"codeReviews":[{"id":"r1","status":"COMPLETED"}],"total":1,"billingUsage":{"reviewsUsed":50,"includedReviews":50,"billingPeriodStart":"2026-08-01T00:00:00Z","billingPeriodEnd":"2026-09-01T00:00:00Z","plan":"Starter"}}}"#.utf8
                )
            )
        }
        defer { sessionFixture.invalidate() }

        let provider = GreptileUsageProvider(
            secretStore: secretStore,
            session: sessionFixture.session
        )
        let result = try await provider.fetchUsage(for: configuration)

        let bar = try XCTUnwrap(result.bars.first)
        XCTAssertEqual(result.subtitle, "")
        XCTAssertEqual(result.plan?.accessibilityLabel, "Starter")
        XCTAssertEqual(bar.stableKey, GreptileUsageIdentity.reviewQuotaStableKey)
        XCTAssertEqual(result.availableMetrics.first?.id, GreptileUsageIdentity.reviewQuotaMetricID)
        XCTAssertEqual(bar.label, "Reviews used")
        XCTAssertEqual(bar.used, 50)
        XCTAssertEqual(bar.limit, 50)
        XCTAssertEqual(bar.resetsAt, ISO8601DateFormatter().date(from: "2026-09-01T00:00:00Z"))
        XCTAssertEqual(
            bar.projectionPeriodStart,
            ISO8601DateFormatter().date(from: "2026-08-01T00:00:00Z")
        )
        XCTAssertTrue(result.usageMessages.isEmpty)
    }

    func testGreptileProviderParsesNumericBillingPeriodTimestamps() async throws {
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration(providerID: .greptile, authMethod: .apiKey)
        try secretStore.saveSecret(
            "greptile-test-key",
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
        let sessionFixture = IsolatedTestURLSession { request in
            (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(
                    #"{"result":{"codeReviews":[],"total":0,"billingUsage":{"reviewsUsed":1,"includedReviews":50,"periodStart":1785542400,"resetsAt":1788220800000}}}"#.utf8
                )
            )
        }
        defer { sessionFixture.invalidate() }

        let provider = GreptileUsageProvider(
            secretStore: secretStore,
            session: sessionFixture.session
        )
        let result = try await provider.fetchUsage(for: configuration)
        let bar = try XCTUnwrap(result.bars.first)

        XCTAssertEqual(bar.projectionPeriodStart, Date(timeIntervalSince1970: 1_785_542_400))
        XCTAssertEqual(bar.resetsAt, Date(timeIntervalSince1970: 1_788_220_800))
    }

    func testGreptileProviderRejectsNonPositiveNumericBillingPeriodTimestamps() async throws {
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration(providerID: .greptile, authMethod: .apiKey)
        try secretStore.saveSecret(
            "greptile-test-key",
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
        let sessionFixture = IsolatedTestURLSession { request in
            (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(
                    #"{"result":{"codeReviews":[],"total":0,"billingUsage":{"reviewsUsed":1,"includedReviews":50,"periodStart":0,"resetsAt":-1788220800000,"123":"ignored","---":"ignored"}}}"#.utf8
                )
            )
        }
        defer { sessionFixture.invalidate() }

        let provider = GreptileUsageProvider(
            secretStore: secretStore,
            session: sessionFixture.session
        )
        let result = try await provider.fetchUsage(for: configuration)
        let bar = try XCTUnwrap(result.bars.first)

        XCTAssertNil(bar.projectionPeriodStart)
        XCTAssertNil(bar.resetsAt)
    }

    func testGreptileProviderRejectsBooleanAndNonFiniteReviewQuotaValues() async throws {
        for billingUsage in [
            #"{"reviewsUsed":true,"includedReviews":50}"#,
            #"{"reviewsUsed":1,"includedReviews":false}"#,
            #"{"reviewsUsed":"nan","includedReviews":50}"#,
            #"{"reviewsUsed":1,"includedReviews":"infinity"}"#,
        ] {
            let secretStore = MemorySecretStore()
            let configuration = ProviderAccountConfiguration(providerID: .greptile, authMethod: .apiKey)
            try secretStore.saveSecret(
                "greptile-test-key",
                account: ProviderConfigurationStore.keychainAccount(for: configuration)
            )
            let sessionFixture = IsolatedTestURLSession { request in
                (
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!,
                    Data(
                        """
                        {"result":{"codeReviews":[{"id":"r1","status":"COMPLETED"}],"total":1,"billingUsage":\(billingUsage)}}
                        """.utf8
                    )
                )
            }

            let provider = GreptileUsageProvider(
                secretStore: secretStore,
                session: sessionFixture.session
            )
            let result = try await provider.fetchUsage(for: configuration)
            sessionFixture.invalidate()

            XCTAssertEqual(result.subtitle, "")
            XCTAssertEqual(result.bars.first?.stableKey, GreptileUsageIdentity.completedReviewsStableKey)
            XCTAssertTrue(result.usageMessages.isEmpty)
        }
    }

    func testGreptileProviderDoesNotPresentMissingReviewDataAsZero() async throws {
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration(providerID: .greptile, authMethod: .apiKey)
        try secretStore.saveSecret(
            "greptile-test-key",
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
        let sessionFixture = IsolatedTestURLSession { request in
            (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(#"{"result":{"codeReviews":[],"total":0}}"#.utf8)
            )
        }
        defer { sessionFixture.invalidate() }

        let provider = GreptileUsageProvider(
            secretStore: secretStore,
            session: sessionFixture.session
        )
        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertTrue(result.bars.isEmpty)
        XCTAssertNil(result.failureMessage)
        XCTAssertTrue(result.usageMessages.isEmpty)
    }

    func testGreptileProviderRejectsIncompleteOrMalformedPagination() async throws {
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration(providerID: .greptile, authMethod: .apiKey)
        try secretStore.saveSecret(
            "greptile-test-key",
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
        let sessionFixture = IsolatedTestURLSession { request in
            (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(#"{"jsonrpc":"2.0","result":{"content":[{"type":"text","text":"not json"}]}}"#.utf8)
            )
        }
        defer { sessionFixture.invalidate() }

        let provider = GreptileUsageProvider(secretStore: secretStore, session: sessionFixture.session)
        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.failureMessage, "Could not parse Greptile review activity.")
        XCTAssertFalse(result.preserveCachedBarsOnFailure)
        XCTAssertTrue(result.bars.isEmpty)
    }

    func testGreptileProviderDecodesSSEJSONRPCResponses() async throws {
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration(providerID: .greptile, authMethod: .apiKey)
        try secretStore.saveSecret(
            "greptile-test-key",
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
        let sessionFixture = IsolatedTestURLSession { request in
            let payload = """
            event: message
            data: {"jsonrpc":"2.0","id":"sse","result":{"codeReviews":[{"id":"r1","status":"COMPLETED"}],"total":1,"truncated":false}}

            """
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "text/event-stream"]
                )!,
                Data(payload.utf8)
            )
        }
        defer { sessionFixture.invalidate() }

        let provider = GreptileUsageProvider(
            secretStore: secretStore,
            session: sessionFixture.session
        )
        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.bars.first?.used, 1)
        XCTAssertNil(result.failureMessage)
    }

    func testGreptileProviderRejectsEveryTruncatedPageShapeWithoutAdvancing() async throws {
        let scenarios: [(name: String, reviewCount: Int, total: Int?)] = [
            ("empty without total", 0, nil),
            ("empty with total", 0, 0),
            ("short without total", 1, nil),
            ("short with total", 1, 1),
            ("full without total", 2, nil),
            ("full with total", 2, 2),
        ]

        for scenario in scenarios {
            let secretStore = MemorySecretStore()
            let configuration = ProviderAccountConfiguration(providerID: .greptile, authMethod: .apiKey)
            try secretStore.saveSecret(
                "greptile-test-key",
                account: ProviderConfigurationStore.keychainAccount(for: configuration)
            )
            let requestLock = NSLock()
            var requestedOffsets: [Int] = []
            let sessionFixture = IsolatedTestURLSession { request in
                let body = try XCTUnwrap(requestBodyData(from: request))
                let root = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                let params = try XCTUnwrap(root["params"] as? [String: Any])
                let arguments = try XCTUnwrap(params["arguments"] as? [String: Any])
                let offset = try XCTUnwrap(arguments["offset"] as? Int)
                requestLock.withLock {
                    requestedOffsets.append(offset)
                }

                let reviews = (0..<scenario.reviewCount).map { index in
                    ["id": "review-\(index)", "status": "COMPLETED"]
                }
                var payload: [String: Any] = [
                    "codeReviews": reviews,
                    "truncated": true,
                ]
                if let total = scenario.total {
                    payload["total"] = total
                }
                return (
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!,
                    try JSONSerialization.data(withJSONObject: ["result": payload])
                )
            }

            let provider = GreptileUsageProvider(
                secretStore: secretStore,
                session: sessionFixture.session,
                pageSize: 2
            )
            let result = try await provider.fetchUsage(for: configuration)
            sessionFixture.invalidate()

            XCTAssertEqual(
                result.failureMessage,
                "Greptile returned incomplete paginated review activity. Try again later.",
                scenario.name
            )
            XCTAssertTrue(result.bars.isEmpty, scenario.name)
            XCTAssertNotEqual(result.subtitle, "All available review history", scenario.name)
            XCTAssertEqual(requestLock.withLock { requestedOffsets }, [0], scenario.name)
        }
    }

    func testGreptileProviderRejectsMalformedTruncatedFlag() async throws {
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration(providerID: .greptile, authMethod: .apiKey)
        try secretStore.saveSecret(
            "greptile-test-key",
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
        let sessionFixture = IsolatedTestURLSession { request in
            (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(
                    #"{"result":{"codeReviews":[],"total":0,"truncated":"true"}}"#.utf8
                )
            )
        }
        defer { sessionFixture.invalidate() }

        let provider = GreptileUsageProvider(
            secretStore: secretStore,
            session: sessionFixture.session
        )
        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.failureMessage, "Could not parse Greptile review activity.")
        XCTAssertTrue(result.bars.isEmpty)
    }

    func testGreptileProviderEnforcesConfiguredPaginationLimit() async throws {
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration(providerID: .greptile, authMethod: .apiKey)
        try secretStore.saveSecret(
            "greptile-test-key",
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
        let sessionFixture = IsolatedTestURLSession { request in
            let body = try XCTUnwrap(requestBodyData(from: request))
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let params = try XCTUnwrap(root["params"] as? [String: Any])
            let arguments = try XCTUnwrap(params["arguments"] as? [String: Any])
            let offset = try XCTUnwrap(arguments["offset"] as? Int)
            guard (0...1).contains(offset) else {
                XCTFail("Unexpected Greptile pagination offset \(offset)")
                throw URLError(.badServerResponse)
            }
            let payload = #"{"result":{"codeReviews":[{"id":"r\#(offset)","status":"COMPLETED"}],"total":3}}"#
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(payload.utf8)
            )
        }
        defer { sessionFixture.invalidate() }

        let provider = GreptileUsageProvider(
            secretStore: secretStore,
            session: sessionFixture.session,
            pageSize: 1,
            maximumPageCount: 2
        )
        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(
            result.failureMessage,
            "Greptile returned incomplete paginated review activity. Try again later."
        )
        XCTAssertTrue(result.bars.isEmpty)
    }

    func testGreptileProviderNeverRequestsOffsetAbovePublishedMaximum() async throws {
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration(providerID: .greptile, authMethod: .apiKey)
        try secretStore.saveSecret(
            "greptile-test-key",
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
        let requestLock = NSLock()
        var requestedOffsets: [Int] = []
        let sessionFixture = IsolatedTestURLSession { request in
            let body = try XCTUnwrap(requestBodyData(from: request))
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let params = try XCTUnwrap(root["params"] as? [String: Any])
            let arguments = try XCTUnwrap(params["arguments"] as? [String: Any])
            let offset = try XCTUnwrap(arguments["offset"] as? Int)
            requestLock.withLock {
                requestedOffsets.append(offset)
            }

            let reviews = (0..<100).map { index in
                ["id": "review-\(offset + index)", "status": "COMPLETED"]
            }
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                try JSONSerialization.data(withJSONObject: [
                    "result": [
                        "codeReviews": reviews,
                        "total": 1_200,
                    ],
                ])
            )
        }
        defer { sessionFixture.invalidate() }

        let provider = GreptileUsageProvider(
            secretStore: secretStore,
            session: sessionFixture.session
        )
        let result = try await provider.fetchUsage(for: configuration)
        let offsets = requestLock.withLock { requestedOffsets }

        XCTAssertEqual(
            result.failureMessage,
            "Greptile returned incomplete paginated review activity. Try again later."
        )
        XCTAssertEqual(offsets, Array(stride(from: 0, through: 1_000, by: 100)))
        XCTAssertEqual(offsets.max(), 1_000)
    }

    func testGreptileProviderRejectsOverlappingPagesThatMissReportedReviews() async throws {
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration(providerID: .greptile, authMethod: .apiKey)
        try secretStore.saveSecret(
            "greptile-test-key",
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
        let sessionFixture = IsolatedTestURLSession { request in
            let body = try XCTUnwrap(requestBodyData(from: request))
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let params = try XCTUnwrap(root["params"] as? [String: Any])
            let arguments = try XCTUnwrap(params["arguments"] as? [String: Any])
            let offset = try XCTUnwrap(arguments["offset"] as? Int)
            let reviews = offset == 0
                ? #"[{"id":"r1","status":"COMPLETED"},{"id":"r2","status":"COMPLETED"}]"#
                : #"[{"id":"r2","status":"COMPLETED"},{"id":"r3","status":"COMPLETED"}]"#
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(#"{"result":{"codeReviews":\#(reviews),"total":4}}"#.utf8)
            )
        }
        defer { sessionFixture.invalidate() }

        let provider = GreptileUsageProvider(
            secretStore: secretStore,
            session: sessionFixture.session,
            pageSize: 2
        )
        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(
            result.failureMessage,
            "Greptile returned incomplete paginated review activity. Try again later."
        )
        XCTAssertTrue(result.bars.isEmpty)
    }

    func testGreptileProviderRejectsIdlessReviewsBeforePaginationDeduplication() async throws {
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration(providerID: .greptile, authMethod: .apiKey)
        try secretStore.saveSecret(
            "greptile-test-key",
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
        let sessionFixture = IsolatedTestURLSession { request in
            (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(
                    #"{"result":{"codeReviews":[{"status":"COMPLETED"},{"id":"","status":"PENDING"}],"total":2}}"#.utf8
                )
            )
        }
        defer { sessionFixture.invalidate() }

        let provider = GreptileUsageProvider(
            secretStore: secretStore,
            session: sessionFixture.session,
            pageSize: 2
        )
        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.failureMessage, "Could not parse Greptile review activity.")
        XCTAssertTrue(result.bars.isEmpty)
    }

    func testGreptileProviderDistinguishesHTTPAndJSONRPCFailures() async throws {
        let cases: [(Int, [String: String]?, Data, String)] = [
            (401, nil, Data(), "Greptile rejected this organization API key."),
            (403, nil, Data(), "lacks permission"),
            (429, ["Retry-After": "45"], Data(), "about 45 seconds"),
            (503, nil, Data(), "temporarily unavailable (HTTP 503)"),
            (
                200,
                nil,
                Data(#"{"jsonrpc":"2.0","error":{"code":-32603,"message":"Authentication failed"}}"#.utf8),
                "Greptile rejected this organization API key."
            ),
        ]

        for (statusCode, headers, data, messageFragment) in cases {
            let secretStore = MemorySecretStore()
            let configuration = ProviderAccountConfiguration(providerID: .greptile, authMethod: .apiKey)
            try secretStore.saveSecret(
                "greptile-test-key",
                account: ProviderConfigurationStore.keychainAccount(for: configuration)
            )
            let sessionFixture = IsolatedTestURLSession { request in
                (
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: statusCode,
                        httpVersion: nil,
                        headerFields: headers
                    )!,
                    data
                )
            }
            let provider = GreptileUsageProvider(
                secretStore: secretStore,
                session: sessionFixture.session
            )

            let result = try await provider.fetchUsage(for: configuration)
            sessionFixture.invalidate()

            XCTAssertTrue(
                try XCTUnwrap(result.failureMessage).contains(messageFragment),
                "Expected \(messageFragment) for HTTP \(statusCode)"
            )
            XCTAssertFalse(try XCTUnwrap(result.failureMessage).contains("greptile-test-key"))
        }
    }

    @MainActor
    func testGreptileTransientFailurePreservesStaleSameAccountSnapshot() async throws {
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration(
            id: "greptile.stale-team",
            providerID: .greptile,
            authMethod: .apiKey
        )
        try secretStore.saveSecret(
            "greptile-test-key",
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
        let successFixture = IsolatedTestURLSession { request in
            (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(#"{"result":{"codeReviews":[{"id":"r1","status":"COMPLETED"}],"total":1}}"#.utf8)
            )
        }
        let successfulProvider = GreptileUsageProvider(
            secretStore: secretStore,
            session: successFixture.session
        )
        let successfulResult = try await successfulProvider.fetchUsage(for: configuration)
        successFixture.invalidate()

        let failureFixture = IsolatedTestURLSession { request in
            (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 503,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data()
            )
        }
        defer { failureFixture.invalidate() }
        let service = UsageRefreshService(
            providers: [
                GreptileUsageProvider(secretStore: secretStore, session: failureFixture.session),
            ],
            initialResults: [successfulResult]
        )

        _ = await service.refresh(configuration: configuration)

        let preserved = try XCTUnwrap(service.results.first)
        XCTAssertEqual(preserved.accountID, configuration.id)
        XCTAssertEqual(preserved.bars.first?.used, 1)
        XCTAssertNotNil(preserved.failureMessage)
        XCTAssertFalse(preserved.hasCurrentBars)
        XCTAssertTrue(preserved.subtitle.contains("last known data"))
    }

    @MainActor
    func testGreptileTruncatedPagePreservesStaleSameAccountSnapshot() async throws {
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration(
            id: "greptile.truncated-team",
            providerID: .greptile,
            authMethod: .apiKey
        )
        try secretStore.saveSecret(
            "greptile-test-key",
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
        let successFixture = IsolatedTestURLSession { request in
            (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(#"{"result":{"codeReviews":[{"id":"r1","status":"COMPLETED"}],"total":1}}"#.utf8)
            )
        }
        let successfulResult = try await GreptileUsageProvider(
            secretStore: secretStore,
            session: successFixture.session
        ).fetchUsage(for: configuration)
        successFixture.invalidate()

        let truncatedFixture = IsolatedTestURLSession { request in
            (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(
                    #"{"result":{"codeReviews":[{"id":"partial","status":"COMPLETED"}],"truncated":true}}"#.utf8
                )
            )
        }
        defer { truncatedFixture.invalidate() }
        let service = UsageRefreshService(
            providers: [
                GreptileUsageProvider(secretStore: secretStore, session: truncatedFixture.session),
            ],
            initialResults: [successfulResult]
        )

        _ = await service.refresh(configuration: configuration)

        let preserved = try XCTUnwrap(service.results.first)
        XCTAssertEqual(preserved.accountID, configuration.id)
        XCTAssertEqual(preserved.bars.first?.used, 1)
        XCTAssertNotNil(preserved.failureMessage)
        XCTAssertFalse(preserved.hasCurrentBars)
        XCTAssertTrue(preserved.subtitle.contains("last known data"))
    }

    @MainActor
    func testGreptileAccountsUseIsolatedCredentialsAndResults() async throws {
        let secretStore = MemorySecretStore()
        let first = ProviderAccountConfiguration(
            id: "greptile.first",
            providerID: .greptile,
            authMethod: .apiKey
        )
        let second = ProviderAccountConfiguration(
            id: "greptile.second",
            providerID: .greptile,
            authMethod: .apiKey
        )
        try secretStore.saveSecret(
            "first-key",
            account: ProviderConfigurationStore.keychainAccount(for: first)
        )
        try secretStore.saveSecret(
            "second-key",
            account: ProviderConfigurationStore.keychainAccount(for: second)
        )
        XCTAssertNotEqual(
            ProviderConfigurationStore.keychainAccount(for: first),
            ProviderConfigurationStore.keychainAccount(for: second)
        )

        let sessionFixture = IsolatedTestURLSession { request in
            let authorization = try XCTUnwrap(request.value(forHTTPHeaderField: "Authorization"))
            let completedCount = authorization == "Bearer first-key" ? 1 : 2
            let reviews = (0..<completedCount).map { index in
                #"{"id":"\#(authorization)-\#(index)","status":"COMPLETED"}"#
            }.joined(separator: ",")
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(#"{"result":{"codeReviews":[\#(reviews)],"total":\#(completedCount)}}"#.utf8)
            )
        }
        defer { sessionFixture.invalidate() }
        let service = UsageRefreshService(providers: [
            GreptileUsageProvider(secretStore: secretStore, session: sessionFixture.session),
        ])

        await service.refresh(configurations: [first, second])

        let results = Dictionary(uniqueKeysWithValues: service.results.map { ($0.accountID, $0) })
        XCTAssertEqual(results[first.id]?.bars.first?.used, 1)
        XCTAssertEqual(results[second.id]?.bars.first?.used, 2)
    }

    func testGreptileProviderWithoutCredentialIsNotConfigured() async throws {
        let provider = GreptileUsageProvider(secretStore: EmptySecretStore())
        let configuration = ProviderAccountConfiguration(providerID: .greptile, authMethod: .apiKey)

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.failureMessage, "Not configured - enter a Greptile organization API key.")
        XCTAssertTrue(result.bars.isEmpty)
    }

    func testGreptileNormalizesPastedAuthorizationHeader() {
        XCTAssertEqual(
            GreptileUsageProvider.normalizedAPIKey(from: "Authorization: Bearer greptile-key"),
            "greptile-key"
        )
        XCTAssertEqual(
            GreptileUsageProvider.normalizedAPIKey(from: "\"quoted-key\""),
            "quoted-key"
        )
    }

    func testOpenRouterCreditsParserCalculatesBalance() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_783_667_520)
        let configuration = ProviderAccountConfiguration(
            providerID: .openRouter,
            accountLabel: "OpenRouter API",
            authMethod: .apiKey
        )
        let payload = """
        {
          "data": {
            "total_credits": 25.5,
            "total_usage": 7.25
          }
        }
        """

        let result = try XCTUnwrap(OpenRouterUsageProvider.parseCredits(
            Data(payload.utf8),
            configuration: configuration,
            fetchedAt: fetchedAt
        ))

        XCTAssertEqual(result.providerID, .openRouter)
        XCTAssertEqual(result.title, "OpenRouter API")
        XCTAssertEqual(result.subtitle, "Credit balance")
        XCTAssertEqual(result.creditsRemaining, 18.25)
        XCTAssertTrue(result.bars.isEmpty)
    }

    func testOpenRouterCreditsParserRejectsMissingCreditFields() throws {
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openRouter)
        let payload = """
        {
          "data": {
            "usage": 7.25
          }
        }
        """

        let result = OpenRouterUsageProvider.parseCredits(
            Data(payload.utf8),
            configuration: configuration
        )

        XCTAssertNil(result)
    }

    func testOpenRouterProviderFetchesKeyBalance() async throws {
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openRouter)
        try secretStore.saveSecret("Bearer sk-or-test", account: ProviderConfigurationStore.keychainAccount(for: configuration))

        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [ProviderParsingMockURLProtocol.self]
        let session = URLSession(configuration: urlSessionConfiguration)
        let provider = OpenRouterUsageProvider(secretStore: secretStore, session: session)

        ProviderParsingMockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/credits")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-or-test")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Title"), "CodexBar")
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(#"{"data":{"total_credits":100,"total_usage":12.34}}"#.utf8)
            )
        }
        defer {
            ProviderParsingMockURLProtocol.handler = nil
        }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.providerID, .openRouter)
        XCTAssertEqual(try XCTUnwrap(result.creditsRemaining), 87.66, accuracy: 0.0001)
        XCTAssertTrue(result.bars.isEmpty)
    }

    func testOpenRouterNormalizesPastedAuthorizationHeader() {
        XCTAssertEqual(
            OpenRouterUsageProvider.normalizedAPIKey(from: "Authorization: Bearer sk-or-test"),
            "sk-or-test"
        )
        XCTAssertEqual(
            OpenRouterUsageProvider.normalizedAPIKey(from: "\"sk-or-quoted\""),
            "sk-or-quoted"
        )
    }

    func testOpenRouterProviderWithoutCredentialIsNotDemoData() async throws {
        let provider = OpenRouterUsageProvider(secretStore: EmptySecretStore())
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openRouter)

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.providerID, .openRouter)
        XCTAssertEqual(result.accountID, configuration.id)
        XCTAssertEqual(result.subtitle, "Not configured - enter OpenRouter Management API Key.")
        XCTAssertNil(result.creditsRemaining)
        XCTAssertTrue(result.bars.isEmpty)
    }

    func testOpenRouterProviderDistinguishesInvalidKeysFromMissingCreditsPermission() async throws {
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openRouter)
        try secretStore.saveSecret(
            "sk-or-management-test",
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )

        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [ProviderParsingMockURLProtocol.self]
        let session = URLSession(configuration: urlSessionConfiguration)
        let provider = OpenRouterUsageProvider(secretStore: secretStore, session: session)
        defer {
            ProviderParsingMockURLProtocol.handler = nil
        }

        let cases = [
            (401, "OpenRouter Management API Key is invalid or expired."),
            (
                403,
                "This key lacks permission to read account credits. Enter an OpenRouter Management API Key."
            ),
        ]

        for (statusCode, expectedMessage) in cases {
            ProviderParsingMockURLProtocol.handler = { request in
                (
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: statusCode,
                        httpVersion: nil,
                        headerFields: nil
                    )!,
                    Data()
                )
            }

            let result = try await provider.fetchUsage(for: configuration)

            XCTAssertEqual(result.subtitle, expectedMessage)
            XCTAssertEqual(result.failureMessage, expectedMessage)
            XCTAssertNil(result.creditsRemaining)
        }
    }

    func testMoonshotBalanceParserReadsAvailableBalance() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_783_667_520)
        let configuration = ProviderAccountConfiguration(
            providerID: .moonshot,
            accountLabel: "Moonshot API",
            authMethod: .apiKey
        )
        let payload = """
        {
          "code": 0,
          "data": {
            "available_balance": 49.58894,
            "voucher_balance": 46.58893,
            "cash_balance": 3.00001
          },
          "scode": "0x0",
          "status": true
        }
        """

        let result = try XCTUnwrap(MoonshotUsageProvider.parseBalance(
            Data(payload.utf8),
            configuration: configuration,
            fetchedAt: fetchedAt
        ))

        XCTAssertEqual(result.providerID, .moonshot)
        XCTAssertEqual(result.title, "Moonshot API")
        XCTAssertEqual(result.subtitle, "Credit balance")
        XCTAssertEqual(try XCTUnwrap(result.creditsRemaining), 49.58894, accuracy: 0.0001)
        XCTAssertTrue(result.bars.isEmpty)
        XCTAssertEqual(result.fetchedAt, fetchedAt)
    }

    func testMoonshotBalanceParserRejectsMissingBalance() throws {
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .moonshot)
        let payload = """
        {
          "code": 0,
          "data": {
            "voucher_balance": 46.58893
          },
          "status": true
        }
        """

        let result = MoonshotUsageProvider.parseBalance(
            Data(payload.utf8),
            configuration: configuration
        )

        XCTAssertNil(result)
    }

    func testMoonshotProviderFetchesBalance() async throws {
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .moonshot)
        try secretStore.saveSecret("Bearer sk-moonshot-test", account: ProviderConfigurationStore.keychainAccount(for: configuration))

        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [ProviderParsingMockURLProtocol.self]
        let session = URLSession(configuration: urlSessionConfiguration)
        let provider = MoonshotUsageProvider(secretStore: secretStore, session: session)

        ProviderParsingMockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.moonshot.ai/v1/users/me/balance")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-moonshot-test")
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(#"{"code":0,"data":{"available_balance":37.5,"voucher_balance":30,"cash_balance":7.5},"scode":"0x0","status":true}"#.utf8)
            )
        }
        defer {
            ProviderParsingMockURLProtocol.handler = nil
        }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.providerID, .moonshot)
        XCTAssertEqual(try XCTUnwrap(result.creditsRemaining), 37.5, accuracy: 0.0001)
        XCTAssertTrue(result.bars.isEmpty)
    }

    func testMoonshotProviderRejectsInvalidKey() async throws {
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .moonshot)
        try secretStore.saveSecret("sk-moonshot-bad", account: ProviderConfigurationStore.keychainAccount(for: configuration))

        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [ProviderParsingMockURLProtocol.self]
        let session = URLSession(configuration: urlSessionConfiguration)
        let provider = MoonshotUsageProvider(secretStore: secretStore, session: session)

        ProviderParsingMockURLProtocol.handler = { request in
            (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 401,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(#"{"error":{"message":"Invalid API key"}}"#.utf8)
            )
        }
        defer {
            ProviderParsingMockURLProtocol.handler = nil
        }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.providerID, .moonshot)
        XCTAssertEqual(result.failureMessage, "Moonshot rejected this API key.")
        XCTAssertNil(result.creditsRemaining)
    }

    func testMoonshotNormalizesPastedAuthorizationHeader() {
        XCTAssertEqual(
            MoonshotUsageProvider.normalizedAPIKey(from: "Authorization: Bearer sk-moonshot-test"),
            "sk-moonshot-test"
        )
        XCTAssertEqual(
            MoonshotUsageProvider.normalizedAPIKey(from: "\"sk-moonshot-quoted\""),
            "sk-moonshot-quoted"
        )
    }

    func testMoonshotProviderWithoutCredentialIsNotConfigured() async throws {
        let provider = MoonshotUsageProvider(secretStore: EmptySecretStore())
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .moonshot)

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.providerID, .moonshot)
        XCTAssertEqual(result.accountID, configuration.id)
        XCTAssertEqual(result.subtitle, "Not configured - enter API key.")
        XCTAssertNil(result.creditsRemaining)
        XCTAssertTrue(result.bars.isEmpty)
    }

    func testOpenCodeZenBalanceParserReadsJSONBalance() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_783_667_520)
        var configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        configuration.accountLabel = "OpenCode ZEN API"
        let payload = """
        {
          "data": {
            "balance": 42.5,
            "currency": "USD"
          }
        }
        """

        let result = try XCTUnwrap(OpenCodeZenUsageProvider.parseBalance(
            Data(payload.utf8),
            configuration: configuration,
            fetchedAt: fetchedAt
        ))

        XCTAssertEqual(result.providerID, .openCodeZen)
        XCTAssertEqual(result.title, "OpenCode ZEN API")
        XCTAssertEqual(result.subtitle, "Credit balance")
        XCTAssertEqual(result.creditsRemaining, 42.5)
        XCTAssertTrue(result.bars.isEmpty)
    }

    func testOpenCodeZenBalanceParserReadsDashboardNanodollarBalance() throws {
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        let payload = #"initial:{balance:1250000000,credits:[]}"#

        let result = try XCTUnwrap(OpenCodeZenUsageProvider.parseBalance(
            Data(payload.utf8),
            configuration: configuration
        ))

        XCTAssertEqual(result.providerID, .openCodeZen)
        XCTAssertEqual(result.title, "OpenCode Zen")
        XCTAssertEqual(try XCTUnwrap(result.creditsRemaining), 12.5, accuracy: 0.0001)
        XCTAssertTrue(result.bars.isEmpty)
    }

    func testOpenCodeZenBalanceParserReadsQuotedDashboardBalance() throws {
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        let payload = #"<script>data={"balance":875000000,"reloadAmount":20}</script>"#

        let result = try XCTUnwrap(OpenCodeZenUsageProvider.parseBalance(
            Data(payload.utf8),
            configuration: configuration
        ))

        XCTAssertEqual(result.providerID, .openCodeZen)
        XCTAssertEqual(result.title, "OpenCode Zen")
        XCTAssertEqual(try XCTUnwrap(result.creditsRemaining), 8.75, accuracy: 0.0001)
        XCTAssertTrue(result.bars.isEmpty)
    }

    func testOpenCodeGoParserReadsHydrationWindowsInStableOrder() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_783_667_520)
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        let payload = """
        <script>
        window.data = {
          "monthlyUsage": {"resetInSec": 2592000, "usagePercent": 7.25},
          "rollingUsage": {"resetInSec": 5400, "usagePercent": 12.5},
          "weeklyUsage": {"usagePercent": 43.75, "resetInSec": 172800}
        };
        </script>
        """

        let result = try XCTUnwrap(OpenCodeZenUsageProvider.parseGoUsage(
            Data(payload.utf8),
            configuration: configuration,
            fetchedAt: fetchedAt
        ))

        XCTAssertEqual(result.title, "OpenCode Go")
        XCTAssertEqual(result.bars.map(\.stableKey), [
            "go.rolling-5-hour",
            "go.weekly",
            "go.monthly",
        ])
        XCTAssertEqual(result.bars.map(\.label), [
            "5-hour usage limit",
            "Weekly usage limit",
            "Monthly usage limit",
        ])
        XCTAssertEqual(result.bars.map(\.used), [12.5, 43.75, 7.25])
        XCTAssertEqual(result.bars[0].resetsAt, fetchedAt.addingTimeInterval(5_400))
        XCTAssertEqual(result.bars[1].resetsAt, fetchedAt.addingTimeInterval(172_800))
        XCTAssertEqual(result.bars[2].resetsAt, fetchedAt.addingTimeInterval(2_592_000))
        XCTAssertEqual(result.bars.map(\.resetDisplayStyle), [
            .relativeWithLocalTime,
            .relativeWithLocalTime,
            .relativeWithLocalTime,
        ])
    }

    func testOpenCodeGoParserProjectsExactRollingWeeklyAndMonthlyBoundaries() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_784_980_800) // 2026-07-25 12:00 UTC
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        let payload = """
        {
          "rollingUsage": {"usagePercent": 80, "resetInSec": 3600},
          "weeklyUsage": {"usagePercent": 40, "resetInSec": 129600},
          "monthlyUsage": {"usagePercent": 20, "resetInSec": 1814400}
        }
        """

        let result = try XCTUnwrap(OpenCodeZenUsageProvider.parseGoUsage(
            Data(payload.utf8),
            configuration: configuration,
            fetchedAt: fetchedAt
        ))

        XCTAssertEqual(result.bars.map(\.projectionCurrent), [0.8, 0.4, 0.2])
        XCTAssertEqual(result.bars.map(\.projectionLimit), [1, 1, 1])
        XCTAssertEqual(result.bars.map(\.showProjectionOnCurrentBar), [true, true, true])
        XCTAssertEqual(
            result.bars.map(\.projectionPeriodStart),
            [
                Date(timeIntervalSince1970: 1_784_966_400),
                Date(timeIntervalSince1970: 1_784_505_600),
                Date(timeIntervalSince1970: 1_784_116_800),
            ]
        )
        XCTAssertEqual(
            result.bars.map(\.projectionPeriodEnd),
            [
                Date(timeIntervalSince1970: 1_784_984_400),
                Date(timeIntervalSince1970: 1_785_110_400),
                Date(timeIntervalSince1970: 1_786_795_200),
            ]
        )
        XCTAssertEqual(
            try XCTUnwrap(result.bars[0].projectedFraction(at: fetchedAt)),
            1,
            accuracy: 0.000_001
        )
        XCTAssertTrue(
            try XCTUnwrap(result.bars[0].projectionDescription(at: fetchedAt))
                .hasPrefix("Projected 100% at current pace")
        )
        XCTAssertEqual(
            result.bars[1].projectionDescription(at: fetchedAt),
            "Projected to stay under limit"
        )
    }

    func testOpenCodeGoParserKeepsZeroUsageAndSelectivelySuppressesAmbiguousMonth() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_789_934_400) // 2026-09-20 20:00 UTC
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        let payload = """
        {
          "rollingUsage": {"usagePercent": 0, "resetInSec": 18000},
          "weeklyUsage": {"usagePercent": 25, "resetInSec": 14400},
          "monthlyUsage": {"usagePercent": 50, "resetInSec": 864000}
        }
        """

        let result = try XCTUnwrap(OpenCodeZenUsageProvider.parseGoUsage(
            Data(payload.utf8),
            configuration: configuration,
            fetchedAt: fetchedAt
        ))

        XCTAssertEqual(result.bars.map(\.used), [0, 25, 50])
        XCTAssertEqual(result.bars.map(\.showProjectionOnCurrentBar), [true, true, false])
        XCTAssertEqual(result.bars[0].projectionCurrent, 0)
        XCTAssertNil(result.bars[0].projectedFraction(at: fetchedAt))
        XCTAssertNotNil(result.bars[1].projectionPeriodStart)
        XCTAssertNil(result.bars[2].projectionCurrent)
        XCTAssertNil(result.bars[2].projectionLimit)
        XCTAssertNil(result.bars[2].projectionPeriodStart)
        XCTAssertNil(result.bars[2].projectionPeriodEnd)
        XCTAssertEqual(
            result.bars[2].resetsAt,
            fetchedAt.addingTimeInterval(864_000)
        )
    }

    func testOpenCodeGoWeeklyProjectionAllowsRequestTransitBeforeMondayBoundary() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_789_934_400) // 2026-09-20 20:00 UTC
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        let payload = """
        {
          "rollingUsage": {"usagePercent": 10, "resetInSec": 3600},
          "weeklyUsage": {"usagePercent": 25, "resetInSec": 14398},
          "monthlyUsage": {"usagePercent": 50, "resetInSec": 2116800}
        }
        """

        let result = try XCTUnwrap(OpenCodeZenUsageProvider.parseGoUsage(
            Data(payload.utf8),
            configuration: configuration,
            fetchedAt: fetchedAt
        ))

        XCTAssertTrue(result.bars[1].showProjectionOnCurrentBar)
        XCTAssertEqual(
            result.bars[1].projectionPeriodEnd,
            Date(timeIntervalSince1970: 1_789_948_798)
        )
        XCTAssertEqual(
            result.bars[1].projectionPeriodStart,
            Date(timeIntervalSince1970: 1_789_343_998)
        )
    }

    func testOpenCodeGoParserSuppressesInvalidOrExpiredProjectionPeriods() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_784_980_800)
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        let payload = """
        {
          "rollingUsage": {"usagePercent": 30, "resetInSec": 18001},
          "weeklyUsage": {"usagePercent": 40, "resetInSec": 0},
          "monthlyUsage": {"usagePercent": 50, "resetInSec": 1814400}
        }
        """

        let result = try XCTUnwrap(OpenCodeZenUsageProvider.parseGoUsage(
            Data(payload.utf8),
            configuration: configuration,
            fetchedAt: fetchedAt
        ))

        XCTAssertEqual(result.bars.map(\.used), [30, 40, 50])
        XCTAssertEqual(result.bars.map(\.showProjectionOnCurrentBar), [false, false, true])
        XCTAssertEqual(
            result.bars[0].resetsAt,
            fetchedAt.addingTimeInterval(18_001)
        )
        XCTAssertEqual(result.bars[1].resetsAt, fetchedAt)
        XCTAssertNil(result.bars[0].projectionPeriodStart)
        XCTAssertNil(result.bars[1].projectionPeriodStart)
        XCTAssertNotNil(result.bars[2].projectionPeriodStart)
    }

    func testOpenCodeGoParserFallsBackToRenderedUsageItems() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_783_667_520)
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        let payload = """
        <div data-slot="usage-item">
          <span data-slot="usage-label">Monthly Usage</span>
          <span data-slot="usage-value">6.5%</span>
          <span data-slot="reset-time">Resets in 29 days 4 hours</span>
        </div>
        <div data-slot="usage-item">
          <span data-slot="usage-label">Rolling Usage</span>
          <span data-slot="usage-value">10.25%</span>
          <span data-slot="reset-time">Resets in 1 hour 30 minutes</span>
        </div>
        <div data-slot="usage-item">
          <span data-slot="usage-label">Weekly Usage</span>
          <span data-slot="usage-value">20%</span>
          <span data-slot="reset-time">Resets in 2 days 3 hours</span>
        </div>
        """

        let result = try XCTUnwrap(OpenCodeZenUsageProvider.parseGoUsage(
            Data(payload.utf8),
            configuration: configuration,
            fetchedAt: fetchedAt
        ))

        XCTAssertEqual(result.bars.map(\.used), [10.25, 20, 6.5])
        XCTAssertEqual(result.bars[0].resetsAt, fetchedAt.addingTimeInterval(5_400))
        XCTAssertEqual(result.bars[1].resetsAt, fetchedAt.addingTimeInterval(183_600))
        XCTAssertEqual(result.bars[2].resetsAt, fetchedAt.addingTimeInterval(2_520_000))
        XCTAssertEqual(result.bars.map(\.showProjectionOnCurrentBar), [false, false, false])
        XCTAssertTrue(result.bars.allSatisfy { $0.projectionCurrent == nil })
    }

    func testOpenCodeGoRenderedParserAcceptsRecognizedZeroResetDurations() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_783_667_520)
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        let payload = """
        <div data-slot="usage-item">
          <span data-slot="usage-label">Rolling Usage</span>
          <span data-slot="usage-value">10%</span>
          <span data-slot="reset-time">Resets in less than a minute</span>
        </div>
        <div data-slot="usage-item">
          <span data-slot="usage-label">Weekly Usage</span>
          <span data-slot="usage-value">20%</span>
          <span data-slot="reset-time">Resets in 0 minutes</span>
        </div>
        <div data-slot="usage-item">
          <span data-slot="usage-label">Monthly Usage</span>
          <span data-slot="usage-value">30%</span>
          <span data-slot="reset-time">Resets in a few seconds</span>
        </div>
        """

        let result = try XCTUnwrap(OpenCodeZenUsageProvider.parseGoUsage(
            Data(payload.utf8),
            configuration: configuration,
            fetchedAt: fetchedAt
        ))

        XCTAssertEqual(result.bars[0].resetsAt, fetchedAt)
        XCTAssertEqual(result.bars[1].resetsAt, fetchedAt)
        XCTAssertEqual(result.bars[2].resetsAt, fetchedAt.addingTimeInterval(5))
    }

    func testOpenCodeGoParserRejectsPartialAndMalformedPages() {
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        let partial = """
        {"rollingUsage":{"usagePercent":12,"resetInSec":300},
         "weeklyUsage":{"usagePercent":20,"resetInSec":600}}
        """

        XCTAssertNil(OpenCodeZenUsageProvider.parseGoUsage(
            Data(partial.utf8),
            configuration: configuration
        ))
        XCTAssertNil(OpenCodeZenUsageProvider.parseGoUsage(
            Data("<html>unexpected dashboard</html>".utf8),
            configuration: configuration
        ))
    }

    func testOpenCodeProductTitlesTreatLegacyDefaultAsDerivedAndPreserveCustomLabels() {
        var configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)

        XCTAssertEqual(configuration.displayName, "OpenCode Go + Zen")
        XCTAssertEqual(
            configuration.openCodeDisplayName(hasGoUsage: true, hasZenBalance: true),
            "OpenCode Go + Zen"
        )
        XCTAssertEqual(
            configuration.openCodeDisplayName(hasGoUsage: true, hasZenBalance: false),
            "OpenCode Go"
        )
        XCTAssertEqual(
            configuration.openCodeDisplayName(hasGoUsage: false, hasZenBalance: true),
            "OpenCode Zen"
        )

        configuration.accountLabel = "OpenCode ZEN"
        XCTAssertFalse(configuration.hasCustomAccountLabel)
        XCTAssertEqual(
            configuration.openCodeDisplayName(hasGoUsage: true, hasZenBalance: true),
            "OpenCode Go + Zen"
        )

        configuration.accountLabel = "OpenCode ZEN 1"
        XCTAssertFalse(configuration.hasCustomAccountLabel)
        XCTAssertEqual(configuration.displayName, "OpenCode Go + Zen 1")
        XCTAssertEqual(
            configuration.openCodeDisplayName(hasGoUsage: true, hasZenBalance: false),
            "OpenCode Go"
        )

        configuration.accountLabel = "OpenCode Go + Zen 2"
        XCTAssertFalse(configuration.hasCustomAccountLabel)
        XCTAssertEqual(configuration.displayName, "OpenCode Go + Zen 2")
        XCTAssertEqual(
            configuration.openCodeDisplayName(hasGoUsage: false, hasZenBalance: true),
            "OpenCode Zen"
        )

        configuration.accountLabel = "Team ZEN"
        XCTAssertTrue(configuration.hasCustomAccountLabel)
        XCTAssertEqual(
            configuration.openCodeDisplayName(hasGoUsage: true, hasZenBalance: true),
            "Team ZEN"
        )
        XCTAssertEqual(
            configuration.openCodeDisplayName(hasGoUsage: false, hasZenBalance: true),
            "Team ZEN"
        )

        for customLabel in [
            "OpenCode ZEN Team 1",
            "OpenCode Go + Zen Production",
            "OpenCode ZEN 01",
        ] {
            configuration.accountLabel = customLabel
            XCTAssertTrue(configuration.hasCustomAccountLabel)
            XCTAssertEqual(
                configuration.openCodeDisplayName(
                    hasGoUsage: true,
                    hasZenBalance: true
                ),
                customLabel
            )
        }
    }

    func testOpenCodeProviderPreservesBalanceWhenGoPageIsMalformed() async throws {
        let secretStore = MemorySecretStore()
        var configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        configuration.openCodeWorkspaceId = "wrk_test"
        try secretStore.saveSecret(
            "opencode-dashboard-token",
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )

        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [ProviderParsingMockURLProtocol.self]
        let session = URLSession(configuration: urlSessionConfiguration)
        let provider = OpenCodeZenUsageProvider(secretStore: secretStore, session: session)

        ProviderParsingMockURLProtocol.handler = { request in
            let data = request.url?.path.hasSuffix("/go") == true
                ? Data("<html>malformed Go page</html>".utf8)
                : Data("<html>balance:1225000000</html>".utf8)
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                data
            )
        }
        defer {
            ProviderParsingMockURLProtocol.handler = nil
        }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(try XCTUnwrap(result.creditsRemaining), 12.25, accuracy: 0.0001)
        XCTAssertTrue(result.bars.isEmpty)
        XCTAssertEqual(
            result.failureMessage,
            "Go usage unavailable: Could not parse all OpenCode Go usage windows."
        )
        XCTAssertTrue(result.preserveCachedBarsOnFailure)
        XCTAssertEqual(result.usageMessages, [
            "Go usage unavailable: Could not parse all OpenCode Go usage windows.",
        ])
    }

    func testOpenCodeProviderPreservesGoUsageWhenBalanceIsMalformed() async throws {
        let secretStore = MemorySecretStore()
        var configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        configuration.openCodeWorkspaceId = "wrk_test"
        try secretStore.saveSecret(
            "opencode-dashboard-token",
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )

        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [ProviderParsingMockURLProtocol.self]
        let session = URLSession(configuration: urlSessionConfiguration)
        let provider = OpenCodeZenUsageProvider(secretStore: secretStore, session: session)
        let goPayload = """
        {"rollingUsage":{"usagePercent":12.5,"resetInSec":300},
         "weeklyUsage":{"resetInSec":600,"usagePercent":20},
         "monthlyUsage":{"usagePercent":30.75,"resetInSec":900}}
        """

        ProviderParsingMockURLProtocol.handler = { request in
            let data = request.url?.path.hasSuffix("/go") == true
                ? Data(goPayload.utf8)
                : Data("<html>malformed balance page</html>".utf8)
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                data
            )
        }
        defer {
            ProviderParsingMockURLProtocol.handler = nil
        }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertNil(result.creditsRemaining)
        XCTAssertEqual(result.bars.map(\.used), [12.5, 20, 30.75])
        XCTAssertEqual(
            result.failureMessage,
            "Zen balance unavailable: Could not parse OpenCode Zen balance."
        )
        XCTAssertTrue(result.preserveCachedCreditsOnFailure)
        XCTAssertEqual(result.usageMessages, [
            "Zen balance unavailable: Could not parse OpenCode Zen balance.",
        ])
    }

    @MainActor
    func testOpenCodePartialRefreshPreservesEachFailedCachedComponent() async throws {
        let secretStore = MemorySecretStore()
        var configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        configuration.openCodeWorkspaceId = "wrk_test"
        try secretStore.saveSecret(
            "opencode-dashboard-token",
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )

        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [ProviderParsingMockURLProtocol.self]
        let session = URLSession(configuration: urlSessionConfiguration)
        let service = UsageRefreshService(providers: [
            OpenCodeZenUsageProvider(secretStore: secretStore, session: session),
        ])
        var phase = 0

        ProviderParsingMockURLProtocol.handler = { request in
            let isGo = request.url?.path.hasSuffix("/go") == true
            let data: Data
            switch (phase, isGo) {
            case (0, false):
                data = Data("<html>balance:1000000000</html>".utf8)
            case (0, true):
                data = Data("""
                {"rollingUsage":{"usagePercent":10,"resetInSec":300},
                 "weeklyUsage":{"usagePercent":20,"resetInSec":600},
                 "monthlyUsage":{"usagePercent":30,"resetInSec":900}}
                """.utf8)
            case (1, false):
                data = Data("<html>balance:2000000000</html>".utf8)
            case (1, true):
                data = Data("<html>malformed Go page</html>".utf8)
            case (2, false):
                data = Data("<html>malformed balance page</html>".utf8)
            case (2, true):
                data = Data("""
                {"rollingUsage":{"usagePercent":40,"resetInSec":300},
                 "weeklyUsage":{"usagePercent":50,"resetInSec":600},
                 "monthlyUsage":{"usagePercent":60,"resetInSec":900}}
                """.utf8)
            default:
                XCTFail("Unexpected OpenCode request phase")
                data = Data()
            }
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                data
            )
        }
        defer {
            ProviderParsingMockURLProtocol.handler = nil
        }

        _ = await service.refresh(configuration: configuration)
        let full = try XCTUnwrap(service.results.first)
        XCTAssertEqual(full.title, "OpenCode Go + Zen")
        XCTAssertEqual(full.bars.map(\.used), [10, 20, 30])
        XCTAssertEqual(try XCTUnwrap(full.creditsRemaining), 10, accuracy: 0.0001)

        phase = 1
        _ = await service.refresh(configuration: configuration)
        let goFailure = try XCTUnwrap(service.results.first)
        XCTAssertEqual(goFailure.title, "OpenCode Go + Zen")
        XCTAssertEqual(goFailure.bars, full.bars)
        XCTAssertEqual(goFailure.barsFetchedAt, full.barsFetchedAt)
        XCTAssertEqual(try XCTUnwrap(goFailure.creditsRemaining), 20, accuracy: 0.0001)
        XCTAssertFalse(goFailure.hasFreshBars)
        XCTAssertTrue(goFailure.hasFreshCredits)
        XCTAssertNotNil(goFailure.failureMessage)
        XCTAssertEqual(service.successfulRefreshResults, [goFailure])

        phase = 2
        _ = await service.refresh(configuration: configuration)
        let balanceFailure = try XCTUnwrap(service.results.first)
        XCTAssertEqual(balanceFailure.title, "OpenCode Go + Zen")
        XCTAssertEqual(balanceFailure.bars.map(\.used), [40, 50, 60])
        XCTAssertEqual(try XCTUnwrap(balanceFailure.creditsRemaining), 20, accuracy: 0.0001)
        XCTAssertTrue(balanceFailure.hasFreshBars)
        XCTAssertFalse(balanceFailure.hasFreshCredits)
        XCTAssertNotNil(balanceFailure.failureMessage)
        XCTAssertEqual(service.successfulRefreshResults, [balanceFailure])
    }

    @MainActor
    func testOpenCodePartialRefreshDoesNotReuseCacheAfterWorkspaceOrCredentialChanges() async throws {
        let secretStore = MemorySecretStore()
        var configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        configuration.openCodeWorkspaceId = "wrk_old"
        let keychainAccount = ProviderConfigurationStore.keychainAccount(for: configuration)
        try secretStore.saveSecret("old-token", account: keychainAccount)

        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [ProviderParsingMockURLProtocol.self]
        let session = URLSession(configuration: urlSessionConfiguration)
        let service = UsageRefreshService(providers: [
            OpenCodeZenUsageProvider(secretStore: secretStore, session: session),
        ])
        var phase = 0

        ProviderParsingMockURLProtocol.handler = { request in
            let isGo = request.url?.path.hasSuffix("/go") == true
            let data: Data
            switch (phase, isGo) {
            case (0, false):
                data = Data("<html>balance:1000000000</html>".utf8)
            case (0, true):
                data = Data("""
                {"rollingUsage":{"usagePercent":10,"resetInSec":300},
                 "weeklyUsage":{"usagePercent":20,"resetInSec":600},
                 "monthlyUsage":{"usagePercent":30,"resetInSec":900}}
                """.utf8)
            case (1, false):
                data = Data("<html>balance:2000000000</html>".utf8)
            case (1, true):
                data = Data("<html>malformed Go page</html>".utf8)
            case (2, false):
                data = Data("<html>malformed balance page</html>".utf8)
            case (2, true):
                data = Data("""
                {"rollingUsage":{"usagePercent":40,"resetInSec":300},
                 "weeklyUsage":{"usagePercent":50,"resetInSec":600},
                 "monthlyUsage":{"usagePercent":60,"resetInSec":900}}
                """.utf8)
            default:
                XCTFail("Unexpected OpenCode request phase")
                data = Data()
            }
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
        defer {
            ProviderParsingMockURLProtocol.handler = nil
        }

        _ = await service.refresh(configuration: configuration)
        let original = try XCTUnwrap(service.results.first)
        XCTAssertEqual(original.bars.map(\.used), [10, 20, 30])
        XCTAssertEqual(try XCTUnwrap(original.creditsRemaining), 10, accuracy: 0.0001)

        phase = 1
        configuration.openCodeWorkspaceId = "wrk_new"
        _ = await service.refresh(configuration: configuration)
        let changedWorkspace = try XCTUnwrap(service.results.first)
        XCTAssertTrue(changedWorkspace.bars.isEmpty)
        XCTAssertNil(changedWorkspace.barsFetchedAt)
        XCTAssertEqual(try XCTUnwrap(changedWorkspace.creditsRemaining), 20, accuracy: 0.0001)

        phase = 2
        try secretStore.saveSecret("new-token", account: keychainAccount)
        _ = await service.refresh(configuration: configuration)
        let changedCredential = try XCTUnwrap(service.results.first)
        XCTAssertEqual(changedCredential.bars.map(\.used), [40, 50, 60])
        XCTAssertNil(changedCredential.creditsRemaining)
        XCTAssertNil(changedCredential.creditsFetchedAt)
    }

    @MainActor
    func testOpenCodeRefreshPreservesCacheWhenCredentialReadFails() async throws {
        var configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        configuration.openCodeWorkspaceId = "wrk_test"
        let fetchedAt = Date(timeIntervalSince1970: 2_000_000_000)
        let cachedResult = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .openCodeZen,
            title: configuration.displayName,
            subtitle: "Go usage and Zen credit balance",
            bars: [UsageBar(label: "Rolling", used: 25, limit: 100)],
            creditsRemaining: 12.5,
            cacheIdentity: "known-account-identity",
            cacheScope: "wrk_test",
            fetchedAt: fetchedAt
        )
        let service = UsageRefreshService(
            providers: [
                OpenCodeZenUsageProvider(secretStore: FailingReadSecretStore()),
            ],
            initialResults: [cachedResult]
        )

        _ = await service.refresh(configuration: configuration)

        let preserved = try XCTUnwrap(service.results.first)
        XCTAssertEqual(preserved.bars, cachedResult.bars)
        XCTAssertEqual(preserved.barsFetchedAt, cachedResult.barsFetchedAt)
        XCTAssertEqual(preserved.creditsRemaining, cachedResult.creditsRemaining)
        XCTAssertEqual(preserved.creditsFetchedAt, cachedResult.creditsFetchedAt)
        XCTAssertTrue(preserved.subtitle.contains("Showing last known data."))
        XCTAssertEqual(
            service.refreshErrorsByAccountID[configuration.id],
            "Keychain unavailable"
        )
    }

    @MainActor
    func testOpenCodeCredentialReadFailureDoesNotReuseAnotherWorkspaceCache() async throws {
        var configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        configuration.openCodeWorkspaceId = "wrk_new"
        let cachedResult = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .openCodeZen,
            title: configuration.displayName,
            subtitle: "Old workspace data",
            bars: [UsageBar(label: "Rolling", used: 25, limit: 100)],
            creditsRemaining: 12.5,
            cacheIdentity: "old-account-identity",
            cacheScope: "wrk_old",
            fetchedAt: Date(timeIntervalSince1970: 2_000_000_000)
        )
        let service = UsageRefreshService(
            providers: [
                OpenCodeZenUsageProvider(secretStore: FailingReadSecretStore()),
            ],
            initialResults: [cachedResult]
        )

        _ = await service.refresh(configuration: configuration)

        let failure = try XCTUnwrap(service.results.first)
        XCTAssertTrue(failure.bars.isEmpty)
        XCTAssertNil(failure.creditsRemaining)
        XCTAssertEqual(failure.subtitle, "Keychain unavailable")
        XCTAssertEqual(failure.cacheScope, "wrk_new")
    }

    func testOpenCodeProviderDoesNotTreatDashboard404AsNotSubscribed() async throws {
        let secretStore = MemorySecretStore()
        var configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        configuration.openCodeWorkspaceId = "wrk_missing"
        try secretStore.saveSecret(
            "opencode-dashboard-token",
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )

        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [ProviderParsingMockURLProtocol.self]
        let session = URLSession(configuration: urlSessionConfiguration)
        let provider = OpenCodeZenUsageProvider(secretStore: secretStore, session: session)

        ProviderParsingMockURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 404, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }
        defer {
            ProviderParsingMockURLProtocol.handler = nil
        }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertNotNil(result.failureMessage)
        XCTAssertFalse(result.subtitle.localizedCaseInsensitiveContains("not subscribed"))
        XCTAssertTrue(result.bars.isEmpty)
        XCTAssertNil(result.creditsRemaining)
    }

    func testOpenCodeProviderReportsSubscriptionOwnedByAnotherWorkspaceMember() async throws {
        let secretStore = MemorySecretStore()
        var configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        configuration.openCodeWorkspaceId = "wrk_test"
        try secretStore.saveSecret(
            "opencode-dashboard-token",
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )

        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [ProviderParsingMockURLProtocol.self]
        let session = URLSession(configuration: urlSessionConfiguration)
        let provider = OpenCodeZenUsageProvider(secretStore: secretStore, session: session)

        ProviderParsingMockURLProtocol.handler = { request in
            let data = request.url?.path.hasSuffix("/go") == true
                ? Data(#"<div data-slot="other-message">OpenCode Go is owned by another member.</div>"#.utf8)
                : Data("<html>balance:1225000000</html>".utf8)
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                data
            )
        }
        defer {
            ProviderParsingMockURLProtocol.handler = nil
        }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.title, "OpenCode Zen")
        XCTAssertEqual(result.subtitle, "Zen credit balance - Go owned by another member")
        XCTAssertEqual(result.usageMessages, [
            "Another workspace member owns the OpenCode Go subscription.",
        ])
        XCTAssertEqual(try XCTUnwrap(result.creditsRemaining), 12.25, accuracy: 0.0001)
        XCTAssertTrue(result.bars.isEmpty)
    }

    func testOpenCodeProviderReturnsGoUsageAndZenBalanceTogether() async throws {
        let secretStore = MemorySecretStore()
        var configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        configuration.openCodeWorkspaceId = "wrk_test"
        try secretStore.saveSecret(
            "opencode-dashboard-token",
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )

        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [ProviderParsingMockURLProtocol.self]
        let session = URLSession(configuration: urlSessionConfiguration)
        let provider = OpenCodeZenUsageProvider(secretStore: secretStore, session: session)
        let goPayload = #"""
        <script>data="{\"weeklyUsage\":{\"resetInSec\":600,\"usagePercent\":22.5},
        \"rollingUsage\":{\"usagePercent\":11.25,\"resetInSec\":300},
        \"monthlyUsage\":{\"resetInSec\":900,\"usagePercent\":33.75}}"</script>
        """#

        ProviderParsingMockURLProtocol.handler = { request in
            let data = request.url?.path.hasSuffix("/go") == true
                ? Data(goPayload.utf8)
                : Data("<html>balance:1875000000</html>".utf8)
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                data
            )
        }
        defer {
            ProviderParsingMockURLProtocol.handler = nil
        }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(try XCTUnwrap(result.creditsRemaining), 18.75, accuracy: 0.0001)
        XCTAssertEqual(result.bars.map(\.used), [11.25, 22.5, 33.75])
        XCTAssertEqual(result.title, "OpenCode Go + Zen")
        XCTAssertEqual(result.subtitle, "Go usage and Zen credit balance")
        XCTAssertTrue(result.usageMessages.isEmpty)
        XCTAssertNil(result.failureMessage)
    }

    func testOpenCodeZenProviderFetchesDashboardBillingBalance() async throws {
        let secretStore = MemorySecretStore()
        var configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        configuration.openCodeWorkspaceId = "wrk_test"
        try secretStore.saveSecret(
            "opencode-dashboard-token",
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )

        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [ProviderParsingMockURLProtocol.self]
        let session = URLSession(configuration: urlSessionConfiguration)
        let provider = OpenCodeZenUsageProvider(secretStore: secretStore, session: session)
        let requestCountLock = NSLock()
        var requestCount = 0

        ProviderParsingMockURLProtocol.handler = { request in
            requestCountLock.withLock {
                requestCount += 1
            }
            XCTAssertEqual(request.url?.scheme, "https")
            XCTAssertEqual(request.url?.host, "opencode.ai")
            XCTAssertTrue(["/workspace/wrk_test/billing", "/workspace/wrk_test/go"].contains(request.url?.path))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "auth=opencode-dashboard-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/html")
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "text/html"]
                )!,
                request.url?.path.hasSuffix("/go") == true
                    ? Data(#"<html><div data-slot="promo-description">Subscribe to Go</div></html>"#.utf8)
                    : Data(#"<html>data balance:2575000000 more</html>"#.utf8)
            )
        }
        defer {
            ProviderParsingMockURLProtocol.handler = nil
        }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.providerID, .openCodeZen)
        XCTAssertEqual(try XCTUnwrap(result.creditsRemaining), 25.75, accuracy: 0.0001)
        XCTAssertTrue(result.bars.isEmpty)
        XCTAssertEqual(result.title, "OpenCode Zen")
        XCTAssertEqual(result.subtitle, "Zen credit balance - Go not subscribed")
        XCTAssertEqual(result.usageMessages, [
            "This workspace is not subscribed to OpenCode Go.",
        ])
        XCTAssertEqual(requestCountLock.withLock { requestCount }, 2)
    }

    func testOpenCodeZenProviderExplainsModelAPIKeyCannotFetchBalanceAfterDashboardRejectsIt() async throws {
        let secretStore = MemorySecretStore()
        var configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        configuration.openCodeWorkspaceId = "wrk_test"
        try secretStore.saveSecret(
            "sk-opencode-model-key",
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )

        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [ProviderParsingMockURLProtocol.self]
        let session = URLSession(configuration: urlSessionConfiguration)
        let provider = OpenCodeZenUsageProvider(secretStore: secretStore, session: session)

        ProviderParsingMockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "auth=sk-opencode-model-key")
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"<html><title>OpenAuth</title></html>"#.utf8)
            )
        }
        defer {
            ProviderParsingMockURLProtocol.handler = nil
        }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.providerID, .openCodeZen)
        XCTAssertEqual(
            result.subtitle,
            "This is an OpenCode Zen model API key, not an OpenCode dashboard auth value. Reconnect in account settings."
        )
        XCTAssertNil(result.creditsRemaining)
        XCTAssertTrue(result.bars.isEmpty)
    }

    func testOpenCodeZenProviderReadsWindowsSettingsJSONCredentialAndWorkspace() async throws {
        let secretStore = MemorySecretStore()
        var configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        configuration.openCodeWorkspaceId = ""
        let windowsSettings = """
        {
          "openCodeGoWorkspaceId": "wrk_from_windows",
          "providers": {
            "OpenCodeGo": {
              "enabled": true,
              "apiKey": "go-dashboard-token"
            },
            "OpenCodeZen": {
              "enabled": true,
              "apiKey": "sk-zen-model-token"
            }
          }
        }
        """
        try secretStore.saveSecret(
            windowsSettings,
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )

        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [ProviderParsingMockURLProtocol.self]
        let session = URLSession(configuration: urlSessionConfiguration)
        let provider = OpenCodeZenUsageProvider(secretStore: secretStore, session: session)

        ProviderParsingMockURLProtocol.handler = { request in
            XCTAssertTrue([
                "/workspace/wrk_from_windows/billing",
                "/workspace/wrk_from_windows/go",
            ].contains(request.url?.path))
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Cookie"),
                request.url?.path.hasSuffix("/go") == true
                    ? "auth=go-dashboard-token"
                    : "auth=sk-zen-model-token"
            )
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                request.url?.path.hasSuffix("/go") == true
                    ? Data(#"<html><div data-slot="promo-description">Subscribe to Go</div></html>"#.utf8)
                    : Data(#"<html>balance:625000000</html>"#.utf8)
            )
        }
        defer {
            ProviderParsingMockURLProtocol.handler = nil
        }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.providerID, .openCodeZen)
        XCTAssertEqual(try XCTUnwrap(result.creditsRemaining), 6.25, accuracy: 0.0001)
        XCTAssertTrue(result.bars.isEmpty)
    }

    @MainActor
    func testOpenCodeZenBootstrapImporterStoresWindowsSettingsJSON() throws {
        let suiteName = "OpenCodeZenBootstrapImporter-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let secretStore = MemorySecretStore()
        let configurationStore = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secretStore)
        let payload = """
        {
          "openCodeGoWorkspaceId": "wrk_from_windows",
          "providers": {
            "OpenCodeGo": {
              "apiKey": "go-dashboard-token"
            },
            "OpenCodeZen": {
              "apiKey": "sk-zen-model-token"
            }
          }
        }
        """

        XCTAssertTrue(OpenCodeZenBootstrapImporter.importPayload(payload, configurationStore: configurationStore))

        let configuration = try XCTUnwrap(configurationStore.configurations(for: .openCodeZen).first)
        XCTAssertEqual(configuration.openCodeWorkspaceId, "wrk_from_windows")
        XCTAssertEqual(configuration.accountLabel, "")
        XCTAssertEqual(configuration.displayName, "OpenCode Go + Zen")
        let savedCredential = try XCTUnwrap(
            secretStore.readSecret(
                account: ProviderConfigurationStore.keychainAccount(for: configuration)
            )
        )
        XCTAssertEqual(
            OpenCodeZenUsageProvider.normalizedBalanceCredential(from: savedCredential),
            "sk-zen-model-token"
        )
        XCTAssertEqual(
            OpenCodeZenUsageProvider.normalizedGoCredential(from: savedCredential),
            "go-dashboard-token"
        )
    }

    @MainActor
    func testOpenCodeZenBootstrapImporterAppliesCompleteFileProtection() throws {
        let fileManager = RecordingFileProtectionManager()
        let importURL = URL(fileURLWithPath: "/tmp/\(OpenCodeZenBootstrapImporter.importFileName)")

        XCTAssertTrue(
            OpenCodeZenBootstrapImporter.protectImportFile(at: importURL, fileManager: fileManager)
        )
        XCTAssertEqual(fileManager.recordedPath, importURL.path)
        XCTAssertEqual(
            fileManager.recordedAttributes?[.protectionKey] as? FileProtectionType,
            .complete
        )
    }

    @MainActor
    func testOpenCodeZenBootstrapImporterProtectsImportsAndRemovesStagingFile() throws {
        let suiteName = "OpenCodeZenBootstrapProtectedImport-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let fileManager = FileManager.default
        let importDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("OpenCodeZenBootstrapImport-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: importDirectory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: importDirectory)
        }

        let importURL = importDirectory.appendingPathComponent(OpenCodeZenBootstrapImporter.importFileName)
        let payload = """
        {
          "openCodeGoWorkspaceId": "wrk_protected",
          "providers": {
            "OpenCodeGo": {
              "apiKey": "protected-dashboard-token"
            }
          }
        }
        """
        try Data(payload.utf8).write(to: importURL)

        let secretStore = MemorySecretStore()
        let configurationStore = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secretStore)
        OpenCodeZenBootstrapImporter.importIfNeeded(
            configurationStore: configurationStore,
            fileManager: fileManager,
            importDirectory: importDirectory
        )

        XCTAssertFalse(fileManager.fileExists(atPath: importURL.path))
        let configuration = try XCTUnwrap(configurationStore.configurations(for: .openCodeZen).first)
        XCTAssertEqual(configuration.openCodeWorkspaceId, "wrk_protected")
        XCTAssertEqual(
            try secretStore.readSecret(account: ProviderConfigurationStore.keychainAccount(for: configuration)),
            "protected-dashboard-token"
        )
    }

    @MainActor
    func testOpenCodeZenBootstrapImporterWaitsForAndResumesAfterConfigurationRecovery() throws {
        let suiteName = "OpenCodeZenBootstrapRecovery-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let malformedData = Data("not-json".utf8)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set(malformedData, forKey: "providerConfigurations")

        let fileManager = FileManager.default
        let importDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("OpenCodeZenBootstrapRecovery-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: importDirectory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: importDirectory)
        }

        let importURL = importDirectory.appendingPathComponent(OpenCodeZenBootstrapImporter.importFileName)
        let payload = """
        {
          "openCodeGoWorkspaceId": "wrk_after_recovery",
          "providers": {
            "OpenCodeGo": {
              "apiKey": "recovered-dashboard-token"
            }
          }
        }
        """
        try Data(payload.utf8).write(to: importURL)

        let secretStore = MemorySecretStore()
        let configurationStore = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secretStore)
        OpenCodeZenBootstrapImporter.importIfNeeded(
            configurationStore: configurationStore,
            fileManager: fileManager,
            importDirectory: importDirectory
        )

        XCTAssertTrue(fileManager.fileExists(atPath: importURL.path))
        XCTAssertTrue(configurationStore.configurations.isEmpty)
        XCTAssertEqual(defaults.data(forKey: "providerConfigurations"), malformedData)

        XCTAssertTrue(OpenCodeZenBootstrapImporter.replaceCorruptedConfigurationsAndImportIfNeeded(
            configurationStore: configurationStore,
            fileManager: fileManager,
            importDirectory: importDirectory
        ))

        XCTAssertFalse(fileManager.fileExists(atPath: importURL.path))
        let configuration = try XCTUnwrap(configurationStore.configurations(for: .openCodeZen).first)
        XCTAssertEqual(configuration.openCodeWorkspaceId, "wrk_after_recovery")
        XCTAssertEqual(
            try secretStore.readSecret(account: ProviderConfigurationStore.keychainAccount(for: configuration)),
            "recovered-dashboard-token"
        )
    }

    @MainActor
    func testOpenCodeZenBootstrapImporterResumesAfterGroupRecovery() throws {
        let suiteName = "OpenCodeZenBootstrapGroupRecovery-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let malformedConfigurationData = Data("bad-configurations".utf8)
        let malformedGroupData = Data("bad-groups".utf8)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set(malformedConfigurationData, forKey: "providerConfigurations")
        defaults.set(malformedGroupData, forKey: "providerAccountGroups")

        let fileManager = FileManager.default
        let importDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("OpenCodeZenBootstrapGroupRecovery-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: importDirectory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: importDirectory)
        }

        let importURL = importDirectory.appendingPathComponent(OpenCodeZenBootstrapImporter.importFileName)
        let payload = """
        {
          "openCodeGoWorkspaceId": "wrk_after_group_recovery",
          "providers": {
            "OpenCodeGo": {
              "apiKey": "group-recovered-dashboard-token"
            }
          }
        }
        """
        try Data(payload.utf8).write(to: importURL)

        let secretStore = MemorySecretStore()
        let configurationStore = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secretStore)
        OpenCodeZenBootstrapImporter.importIfNeeded(
            configurationStore: configurationStore,
            fileManager: fileManager,
            importDirectory: importDirectory
        )

        XCTAssertTrue(fileManager.fileExists(atPath: importURL.path))
        XCTAssertTrue(configurationStore.isConfigurationRecoveryRequired)
        XCTAssertTrue(configurationStore.isGroupRecoveryRequired)
        XCTAssertEqual(defaults.data(forKey: "providerConfigurations"), malformedConfigurationData)
        XCTAssertEqual(defaults.data(forKey: "providerAccountGroups"), malformedGroupData)

        XCTAssertTrue(OpenCodeZenBootstrapImporter.replaceCorruptedConfigurationsAndImportIfNeeded(
            configurationStore: configurationStore,
            fileManager: fileManager,
            importDirectory: importDirectory
        ))
        XCTAssertTrue(fileManager.fileExists(atPath: importURL.path))
        XCTAssertFalse(configurationStore.isConfigurationRecoveryRequired)
        XCTAssertTrue(configurationStore.isGroupRecoveryRequired)

        XCTAssertTrue(OpenCodeZenBootstrapImporter.replaceCorruptedGroupsAndImportIfNeeded(
            configurationStore: configurationStore,
            fileManager: fileManager,
            importDirectory: importDirectory
        ))

        XCTAssertFalse(fileManager.fileExists(atPath: importURL.path))
        XCTAssertFalse(configurationStore.isPersistenceRecoveryRequired)
        let configuration = try XCTUnwrap(configurationStore.configurations(for: .openCodeZen).first)
        XCTAssertEqual(configuration.openCodeWorkspaceId, "wrk_after_group_recovery")
        XCTAssertEqual(
            try secretStore.readSecret(account: ProviderConfigurationStore.keychainAccount(for: configuration)),
            "group-recovered-dashboard-token"
        )
    }

    @MainActor
    func testOpenCodeZenBootstrapImporterDeletesFileWithoutReadingWhenProtectionFails() throws {
        let suiteName = "OpenCodeZenBootstrapProtectionFailure-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let fileManager = RecordingFileProtectionManager()
        fileManager.shouldFail = true
        let importDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("OpenCodeZenBootstrapFailure-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: importDirectory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: importDirectory)
        }

        let importURL = importDirectory.appendingPathComponent(OpenCodeZenBootstrapImporter.importFileName)
        try Data(#"{"openCodeGoWorkspaceId":"wrk_secret","providers":{"OpenCodeGo":{"apiKey":"secret-token"}}}"#.utf8)
            .write(to: importURL)

        let configurationStore = ProviderConfigurationStore(
            initialPlanAccess: .unrestricted,
            defaults: defaults,
            secretStore: MemorySecretStore()
        )
        OpenCodeZenBootstrapImporter.importIfNeeded(
            configurationStore: configurationStore,
            fileManager: fileManager,
            importDirectory: importDirectory
        )

        XCTAssertFalse(fileManager.fileExists(atPath: importURL.path))
        XCTAssertTrue(configurationStore.configurations(for: .openCodeZen).isEmpty)
    }

    func testOpenCodeZenProviderNormalizesAuthHeaderBeforeDashboardRequest() async throws {
        let secretStore = MemorySecretStore()
        var configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        configuration.openCodeWorkspaceId = "wrk_test"
        try secretStore.saveSecret(
            "Authorization: Bearer opencode-dashboard-token",
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )

        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [ProviderParsingMockURLProtocol.self]
        let session = URLSession(configuration: urlSessionConfiguration)
        let provider = OpenCodeZenUsageProvider(secretStore: secretStore, session: session)
        let requestCountLock = NSLock()
        var requestCount = 0

        ProviderParsingMockURLProtocol.handler = { request in
            requestCountLock.withLock {
                requestCount += 1
            }
            XCTAssertTrue([
                "https://opencode.ai/workspace/wrk_test/billing",
                "https://opencode.ai/workspace/wrk_test/go",
            ].contains(request.url?.absoluteString))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "auth=opencode-dashboard-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/html")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "User-Agent"),
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Gecko/20100101 Firefox/148.0"
            )
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                request.url?.path.hasSuffix("/go") == true
                    ? Data(#"<html><div data-slot="promo-description">Subscribe to Go</div></html>"#.utf8)
                    : Data(#"<html>data balance:2575000000 more</html>"#.utf8)
            )
        }
        defer {
            ProviderParsingMockURLProtocol.handler = nil
        }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.providerID, .openCodeZen)
        XCTAssertEqual(try XCTUnwrap(result.creditsRemaining), 25.75, accuracy: 0.0001)
        XCTAssertTrue(result.bars.isEmpty)
        XCTAssertEqual(requestCountLock.withLock { requestCount }, 2)
    }

    func testOpenCodeZenProviderReportsRejectedCredential() async throws {
        let secretStore = MemorySecretStore()
        var configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        configuration.openCodeWorkspaceId = "wrk_test"
        try secretStore.saveSecret("bad-balance-credential", account: ProviderConfigurationStore.keychainAccount(for: configuration))

        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [ProviderParsingMockURLProtocol.self]
        let session = URLSession(configuration: urlSessionConfiguration)
        let provider = OpenCodeZenUsageProvider(secretStore: secretStore, session: session)

        ProviderParsingMockURLProtocol.handler = { request in
            (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 403,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data()
            )
        }
        defer {
            ProviderParsingMockURLProtocol.handler = nil
        }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.providerID, .openCodeZen)
        XCTAssertEqual(result.subtitle, "OpenCode rejected the saved dashboard auth value.")
        XCTAssertNil(result.creditsRemaining)
        XCTAssertTrue(result.bars.isEmpty)
    }

    func testOpenCodeZenProviderExplainsOpenCodeSignInPage() async throws {
        let secretStore = MemorySecretStore()
        var configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        configuration.openCodeWorkspaceId = "wrk_test"
        try secretStore.saveSecret("auth=opencode-dashboard-token", account: ProviderConfigurationStore.keychainAccount(for: configuration))

        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [ProviderParsingMockURLProtocol.self]
        let session = URLSession(configuration: urlSessionConfiguration)
        let provider = OpenCodeZenUsageProvider(secretStore: secretStore, session: session)

        ProviderParsingMockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "auth=opencode-dashboard-token")
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(#"<html><title>OpenAuth</title></html>"#.utf8)
            )
        }
        defer {
            ProviderParsingMockURLProtocol.handler = nil
        }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.providerID, .openCodeZen)
        XCTAssertEqual(result.subtitle, "OpenCode returned the sign-in page. Reconnect in account settings.")
        XCTAssertNil(result.creditsRemaining)
        XCTAssertTrue(result.bars.isEmpty)
    }

    func testOpenCodeZenNormalizesPastedBalanceCredential() {
        XCTAssertEqual(
            OpenCodeZenUsageProvider.normalizedBalanceCredential(from: "Authorization: Bearer oczen-test-key"),
            "oczen-test-key"
        )
        XCTAssertEqual(
            OpenCodeZenUsageProvider.normalizedBalanceCredential(from: "\"quoted-key\""),
            "quoted-key"
        )
        XCTAssertEqual(
            OpenCodeZenUsageProvider.normalizedBalanceCredential(from: "auth=oczen-legacy-shaped-key; other=value"),
            "oczen-legacy-shaped-key"
        )
        XCTAssertEqual(
            OpenCodeZenUsageProvider.normalizedBalanceCredential(from: "Cookie: other=value; auth=oczen-cookie"),
            "oczen-cookie"
        )
        XCTAssertEqual(
            OpenCodeZenUsageProvider.normalizedBalanceCredential(from: "Set-Cookie: auth=oczen-cookie; Path=/; HttpOnly"),
            "oczen-cookie"
        )
        XCTAssertEqual(
            OpenCodeZenUsageProvider.normalizedWorkspaceId(from: "https://opencode.ai/workspace/wrk_test/billing"),
            "wrk_test"
        )
        XCTAssertEqual(
            OpenCodeZenUsageProvider.normalizedWorkspaceId(from: "https://opencode.ai/workspace/wrk_test/go"),
            "wrk_test"
        )
        XCTAssertEqual(
            OpenCodeZenUsageProvider.normalizedBalanceCredential(from: #"OPENCODE_GO_AUTH_COOKIE="go-dashboard-token""#),
            "go-dashboard-token"
        )
        XCTAssertEqual(
            OpenCodeZenUsageProvider.normalizedWorkspaceId(from: "OPENCODE_GO_WORKSPACE_ID=wrk_env"),
            "wrk_env"
        )
    }

    func testOpenCodeZenProviderWithoutWorkspaceIsNotConfigured() async throws {
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        try secretStore.saveSecret("oczen-test-key", account: ProviderConfigurationStore.keychainAccount(for: configuration))

        let provider = OpenCodeZenUsageProvider(secretStore: secretStore)

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.providerID, .openCodeZen)
        XCTAssertEqual(result.subtitle, "Not configured - sign in with OpenCode to choose a workspace.")
        XCTAssertNil(result.creditsRemaining)
        XCTAssertTrue(result.bars.isEmpty)
    }

    func testOpenCodeZenProviderWithoutCredentialIsNotDemoData() async throws {
        let provider = OpenCodeZenUsageProvider(secretStore: EmptySecretStore())
        var configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        configuration.openCodeWorkspaceId = "wrk_test"

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.providerID, .openCodeZen)
        XCTAssertEqual(result.accountID, configuration.id)
        XCTAssertEqual(result.subtitle, "Disconnected - sign in with OpenCode.")
        XCTAssertNil(result.creditsRemaining)
        XCTAssertTrue(result.bars.isEmpty)
    }

    func testCursorNormalizesPastedAuthJSONAndBearerHeader() {
        XCTAssertEqual(
            CursorUsageProvider.normalizedAccessToken(from: #"{"accessToken":"cursor-token","refreshToken":"refresh"}"#),
            "cursor-token"
        )
        XCTAssertEqual(
            CursorUsageProvider.normalizedAccessToken(from: "Authorization: Bearer cursor-token"),
            "cursor-token"
        )
        XCTAssertEqual(
            CursorUsageProvider.normalizedAccessToken(from: "\"cursor-quoted\""),
            "cursor-quoted"
        )
    }

    func testCursorUsageParserReadsDashboardUsage() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_783_667_520)
        var configuration = ProviderAccountConfiguration.defaultConfiguration(for: .cursor)
        configuration.accountLabel = "Cursor Pro"
        let payload = """
        {
          "billingCycleStart": "1783036800000",
          "billingCycleEnd": "1784332800000",
          "planUsage": {
            "autoPercentUsed": 42.4,
            "apiPercentUsed": 18.2,
            "totalPercentUsed": 62.6
          },
          "spendLimitUsage": {
            "individualLimit": 2000,
            "individualRemaining": 800
          }
        }
        """

        let result = try XCTUnwrap(CursorUsageProvider.parseUsage(
            Data(payload.utf8),
            configuration: configuration,
            fetchedAt: fetchedAt
        ))

        XCTAssertEqual(result.providerID, .cursor)
        XCTAssertEqual(result.title, "Cursor Pro")
        XCTAssertEqual(result.subtitle, "Cursor plan usage")
        XCTAssertEqual(
            result.cardInformationSections,
            [
                ProviderCardInformationSection(
                    id: "cursor.included-usage",
                    title: "Included usage",
                    items: [
                        ProviderCardInformationItem(
                            id: "cursor.included-usage.cursor-models",
                            label: "Cursor Models",
                            detail: "42%"
                        ),
                        ProviderCardInformationItem(
                            id: "cursor.included-usage.other-models",
                            label: "Other Models",
                            detail: "18%"
                        ),
                    ]
                ),
            ]
        )
        XCTAssertEqual(result.bars.map(\.label), [
            "Cursor Models",
            "Other Models",
            "On-demand $12.00 / $20.00",
        ])
        XCTAssertEqual(
            result.bars.enumerated().map {
                $0.element.metricIdentifier(providerID: .cursor, index: $0.offset)
            },
            ["cursor.cursor-models", "cursor.other-models", "cursor.on-demand"]
        )
        XCTAssertEqual(result.bars.map(\.usageText), ["42%", "18%", "60%"])
        XCTAssertTrue(result.bars.allSatisfy(\.showProjectionOnCurrentBar))
        XCTAssertEqual(
            result.bars.compactMap(\.projectionPeriodStart),
            Array(repeating: Date(timeIntervalSince1970: 1_783_036_800), count: 3)
        )
        XCTAssertEqual(
            result.bars.compactMap(\.projectionPeriodEnd),
            Array(repeating: Date(timeIntervalSince1970: 1_784_332_800), count: 3)
        )
        XCTAssertEqual(try XCTUnwrap(result.bars[0].projectionCurrent), 0.424, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(result.bars[1].projectionCurrent), 0.182, accuracy: 0.000_001)
        XCTAssertEqual(result.bars[2].projectionCurrent, 1_200)
        XCTAssertEqual(result.bars.compactMap(\.projectionLimit), [1, 1, 2_000])
        XCTAssertEqual(result.bars[0].projectionDescription(at: fetchedAt), "Projected to stay under limit")
        XCTAssertEqual(result.bars[1].projectionDescription(at: fetchedAt), "Projected to stay under limit")
        XCTAssertNil(result.bars[0].dashboardProjectionDescription(at: fetchedAt))
        XCTAssertNil(result.bars[1].dashboardProjectionDescription(at: fetchedAt))
        XCTAssertTrue(try XCTUnwrap(result.bars[2].projectionDescription(at: fetchedAt)).hasPrefix(
            "Projected 100% at current pace - Limit hit "
        ))
    }

    func testCursorUsageParserPreservesOverLimitModelBuckets() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_783_667_520)
        let payload = """
        {
          "billingCycleStart": "1783036800000",
          "billingCycleEnd": "1784332800000",
          "planUsage": {
            "autoPercentUsed": 137.4,
            "apiPercentUsed": 118
          }
        }
        """

        let result = try XCTUnwrap(CursorUsageProvider.parseUsage(
            Data(payload.utf8),
            configuration: .defaultConfiguration(for: .cursor),
            fetchedAt: fetchedAt
        ))

        XCTAssertEqual(result.bars.map(\.used), [137.4, 118])
        XCTAssertEqual(result.bars.map(\.usageText), ["137%", "118%"])
        XCTAssertEqual(result.bars.map(\.fractionUsed), [1, 1])
        let projectionCurrent = result.bars.compactMap(\.projectionCurrent)
        XCTAssertEqual(projectionCurrent.count, 2)
        XCTAssertEqual(projectionCurrent[0], 1.374, accuracy: 0.000_001)
        XCTAssertEqual(projectionCurrent[1], 1.18, accuracy: 0.000_001)
        XCTAssertEqual(
            result.cardInformationSections.first?.items.map(\.detail),
            ["137%", "118%"]
        )

        let historySnapshot = UsageHistorySnapshot(result: result)
        XCTAssertEqual(historySnapshot.bars.map(\.used), [137.4, 118])
        XCTAssertEqual(
            try XCTUnwrap(historySnapshot.primaryValue),
            1.374,
            accuracy: 0.000_001
        )
    }

    func testCursorUsageParserHandlesMissingBoundaryAndMalformedCategoryValues() throws {
        let fixtures: [(payload: String, labels: [String], usage: [String])] = [
            (
                #"{"planUsage":{"autoPercentUsed":0,"apiPercentUsed":100}}"#,
                ["Cursor Models", "Other Models"],
                ["0%", "100%"]
            ),
            (
                #"{"planUsage":{"apiPercentUsed":37.4}}"#,
                ["Other Models"],
                ["37%"]
            ),
            (
                #"{"planUsage":{"autoPercentUsed":"invalid","apiPercentUsed":24}}"#,
                ["Other Models"],
                ["24%"]
            ),
            (
                #"{"planUsage":{"autoPercentUsed":-5,"apiPercentUsed":1e100}}"#,
                ["Cursor Models"],
                ["0%"]
            ),
        ]

        for fixture in fixtures {
            let result = try XCTUnwrap(CursorUsageProvider.parseUsage(
                Data(fixture.payload.utf8),
                configuration: .defaultConfiguration(for: .cursor)
            ))
            XCTAssertEqual(result.bars.map(\.label), fixture.labels)
            XCTAssertEqual(result.bars.map(\.usageText), fixture.usage)
        }

        XCTAssertNil(CursorUsageProvider.parseUsage(
            Data(#"{"planUsage":{"totalPercentUsed":99}}"#.utf8),
            configuration: .defaultConfiguration(for: .cursor)
        ))
    }

    func testCursorUsageParserReadsGrokBotWeeklyUsage() throws {
        let fetchedAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-22T12:00:00Z"))
        let usagePayload = #"{"planUsage":{"autoPercentUsed":25}}"#
        let grokBotPayload = """
        {
          "currentPeriodStart": "2026-08-19T21:37:33.239Z",
          "nextResetTimestampUtc": "2026-08-26T21:37:33.239Z",
          "usagePercent": 38.059383,
          "usesPooledEnterpriseAllowance": false
        }
        """

        let result = try XCTUnwrap(CursorUsageProvider.parseUsage(
            Data(usagePayload.utf8),
            grokBotUsageData: Data(grokBotPayload.utf8),
            configuration: .defaultConfiguration(for: .cursor),
            fetchedAt: fetchedAt
        ))
        let grokBot = try XCTUnwrap(result.bars.last)

        XCTAssertEqual(result.bars.map(\.label), ["Cursor Models", "Grok Bot weekly"])
        XCTAssertEqual(grokBot.stableKey, "grok-bot-weekly")
        XCTAssertEqual(grokBot.usageText, "38%")
        XCTAssertEqual(
            try XCTUnwrap(grokBot.resetsAt).timeIntervalSince1970,
            1_787_780_253.239,
            accuracy: 0.001
        )
        XCTAssertTrue(grokBot.showProjectionOnCurrentBar)
        XCTAssertEqual(grokBot.metricIdentifier(providerID: .cursor, index: 1), "cursor.grok-bot-weekly")
    }

    func testCursorUsageParserOmitsUnavailableGrokBotUsage() throws {
        let usagePayload = #"{"planUsage":{"autoPercentUsed":25}}"#
        let pooledGrokBotPayload = #"{"usage_percent":38,"uses_pooled_enterprise_allowance":true}"#

        let result = try XCTUnwrap(CursorUsageProvider.parseUsage(
            Data(usagePayload.utf8),
            grokBotUsageData: Data(pooledGrokBotPayload.utf8),
            configuration: .defaultConfiguration(for: .cursor)
        ))

        XCTAssertEqual(result.bars.map(\.label), ["Cursor Models"])
    }

    func testCursorUsageParserOmitsGrokBotUsageWithoutIncludedAllowance() throws {
        let usagePayload = #"{"planUsage":{"autoPercentUsed":25}}"#
        let unavailablePayloads = [
            #"{"usagePercent":0,"hasNonZeroIncludedLimit":false}"#,
            #"{"usage_percent":0,"has_non_zero_included_limit":false}"#,
            #"{"usage_percent":0,"included_limit_zero":true}"#,
        ]

        for grokBotPayload in unavailablePayloads {
            let result = try XCTUnwrap(CursorUsageProvider.parseUsage(
                Data(usagePayload.utf8),
                grokBotUsageData: Data(grokBotPayload.utf8),
                configuration: .defaultConfiguration(for: .cursor)
            ))

            XCTAssertEqual(result.bars.map(\.label), ["Cursor Models"])
            XCTAssertEqual(
                result.bars.map { $0.metricIdentifier(providerID: .cursor, index: 0) },
                ["cursor.cursor-models"]
            )
        }
    }

    func testCursorUsageParserKeepsEntitledZeroPercentGrokBotUsage() throws {
        let usagePayload = #"{"planUsage":{"autoPercentUsed":25}}"#
        let grokBotPayload = """
        {
          "usagePercent": 0,
          "hasNonZeroIncludedLimit": true,
          "includedLimitZero": false,
          "usesPooledEnterpriseAllowance": false
        }
        """

        let result = try XCTUnwrap(CursorUsageProvider.parseUsage(
            Data(usagePayload.utf8),
            grokBotUsageData: Data(grokBotPayload.utf8),
            configuration: .defaultConfiguration(for: .cursor)
        ))

        XCTAssertEqual(result.bars.map(\.label), ["Cursor Models", "Grok Bot weekly"])
        XCTAssertEqual(result.bars.last?.usageText, "0%")
    }

    func testCursorUsageParserSuppressesPredictionsWithoutValidCurrentBillingPeriod() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_783_667_520)
        let invalidPeriods = [
            #""billingCycleEnd": "1784332800000","#,
            #""billingCycleStart": "invalid", "billingCycleEnd": "1784332800000","#,
            #""billingCycleStart": "1784332800000", "billingCycleEnd": "1781740800000","#,
            #""billingCycleStart": "1784332800000", "billingCycleEnd": "1786924800000","#,
        ]

        for periodFields in invalidPeriods {
            let payload = """
            {
              \(periodFields)
              "planUsage": {
                "autoPercentUsed": 10,
                "apiPercentUsed": 5,
                "totalPercentUsed": 25
              },
              "spendLimitUsage": {
                "individualLimit": 2000,
                "individualRemaining": 1500
              }
            }
            """

            let result = try XCTUnwrap(CursorUsageProvider.parseUsage(
                Data(payload.utf8),
                configuration: .defaultConfiguration(for: .cursor),
                fetchedAt: fetchedAt
            ))

            XCTAssertEqual(result.bars.count, 3)
            XCTAssertTrue(result.bars.allSatisfy { !$0.showProjectionOnCurrentBar })
            XCTAssertTrue(result.bars.allSatisfy { $0.projectionDescription(at: fetchedAt) == nil })
        }
    }

    func testCursorProviderFetchesDashboardUsage() async throws {
        let secretStore = MemorySecretStore()
        var configuration = ProviderAccountConfiguration.defaultConfiguration(for: .cursor)
        configuration.accountLabel = "Cursor"
        try secretStore.saveSecret(
            #"{"accessToken":"cursor-token"}"#,
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )

        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [ProviderParsingMockURLProtocol.self]
        let session = URLSession(configuration: urlSessionConfiguration)
        let provider = CursorUsageProvider(secretStore: secretStore, session: session)
        let currentUsageRequest = expectation(description: "Current Cursor usage requested")
        let grokBotUsageRequest = expectation(description: "Grok Bot usage requested")

        ProviderParsingMockURLProtocol.handler = { request in
            if request.url?.lastPathComponent == "full_stripe_profile" {
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer cursor-token")
                return (HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200,
                                        httpVersion: nil, headerFields: nil)!, Data(#"{"membershipType":"pro_plus"}"#.utf8))
            }
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer cursor-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Connect-Protocol-Version"), "1")
            XCTAssertEqual(requestBodyData(from: request), Data("{}".utf8))
            let responseData: Data
            switch request.url?.lastPathComponent {
            case "GetCurrentPeriodUsage":
                currentUsageRequest.fulfill()
                responseData = Data(
                    #"{"planUsage":{"totalPercentUsed":25,"autoPercentUsed":10,"apiPercentUsed":5}}"#.utf8
                )
            case "GetSandUsageStatus":
                grokBotUsageRequest.fulfill()
                responseData = Data(#"{"usagePercent":12.4}"#.utf8)
            default:
                XCTFail("Unexpected Cursor usage URL: \(request.url?.absoluteString ?? "nil")")
                responseData = Data()
            }
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                responseData
            )
        }
        defer {
            ProviderParsingMockURLProtocol.handler = nil
        }

        let result = try await provider.fetchUsage(for: configuration)
        await fulfillment(of: [currentUsageRequest, grokBotUsageRequest], timeout: 1)

        XCTAssertEqual(result.providerID, .cursor)
        XCTAssertEqual(result.title, "Cursor")
        XCTAssertEqual(
            result.bars.map(\.label),
            ["Cursor Models", "Other Models", "Grok Bot weekly"]
        )
        XCTAssertEqual(result.bars.first?.usageText, "10%")
    }

    func testCursorProviderDoesNotWaitForStalledOptionalGrokBotUsage() async throws {
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .cursor)
        try secretStore.saveSecret(
            "cursor-token",
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )

        let events = StalledCursorRequestEvents()
        let host = UUID().uuidString.lowercased() + ".test"
        StalledCursorGrokBotURLProtocol.register(events, for: host)
        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [StalledCursorGrokBotURLProtocol.self]
        let session = URLSession(configuration: urlSessionConfiguration)
        defer {
            session.invalidateAndCancel()
            StalledCursorGrokBotURLProtocol.unregister(host: host)
        }
        let provider = CursorUsageProvider(
            secretStore: secretStore,
            session: session,
            usageEndpoint: try XCTUnwrap(URL(string: "https://\(host)/GetCurrentPeriodUsage")),
            grokBotUsageEndpoint: try XCTUnwrap(URL(string: "https://\(host)/GetSandUsageStatus")),
            grokBotRequestTimeout: .seconds(2),
            waitForGrokBotTimeout: { duration in
                XCTAssertEqual(duration, .seconds(2))
                events.record(.timeoutStarted)
                await events.primaryCompleted.wait()
                await events.optionalStarted.wait()
                try Task.checkCancellation()
                events.record(.timeoutFired)
            }
        )

        // This guard only breaks a deadlock. Request events drive the timeout and assertions.
        let result = try await withTestWatchdog(
            timeout: .seconds(30),
            failureMessage: "Cursor usage waited for the stalled optional Grok Bot request.",
            onTimeout: { session.invalidateAndCancel() },
            operation: {
                let result = try await provider.fetchUsage(for: configuration)
                events.record(.fetchReturned)
                // URLSession may dispatch stopLoading after resuming data(for:).
                await events.optionalCancelled.wait()
                return result
            }
        )

        XCTAssertEqual(result.bars.map(\.label), ["Cursor Models", "Other Models"])
        XCTAssertEqual(result.bars.first?.usageText, "25%")
        let recorded = events.recorded
        XCTAssertEqual(recorded.count, 6)
        let timeoutIndex = try XCTUnwrap(recorded.firstIndex(of: .timeoutFired))
        for event in [StalledCursorRequestEvents.Event.primaryCompleted, .optionalStarted, .timeoutStarted] {
            XCTAssertLessThan(try XCTUnwrap(recorded.firstIndex(of: event)), timeoutIndex)
        }
        for event in [StalledCursorRequestEvents.Event.optionalCancelled, .fetchReturned] {
            XCTAssertGreaterThan(try XCTUnwrap(recorded.firstIndex(of: event)), timeoutIndex)
        }
    }

    func testCursorProviderDefaultTimeoutCancelsStalledOptionalGrokBotUsage() async throws {
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .cursor)
        try secretStore.saveSecret("cursor-token", account: ProviderConfigurationStore.keychainAccount(for: configuration))

        let events = StalledCursorRequestEvents()
        let host = UUID().uuidString.lowercased() + ".test"
        StalledCursorGrokBotURLProtocol.register(events, for: host)
        let observer = StalledCursorTaskObserver()
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [StalledCursorGrokBotURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration, delegate: observer, delegateQueue: nil)
        defer {
            session.invalidateAndCancel()
            StalledCursorGrokBotURLProtocol.unregister(host: host)
        }
        let provider = CursorUsageProvider(
            secretStore: secretStore,
            session: session,
            usageEndpoint: try XCTUnwrap(URL(string: "https://\(host)/GetCurrentPeriodUsage")),
            grokBotUsageEndpoint: try XCTUnwrap(URL(string: "https://\(host)/GetSandUsageStatus")),
            grokBotRequestTimeout: .milliseconds(25)
        )

        let result = try await withTestWatchdog(
            timeout: .seconds(30),
            failureMessage: "Cursor's default timeout did not cancel the optional Grok Bot task.",
            onTimeout: { session.invalidateAndCancel() },
            operation: {
                let result = try await provider.fetchUsage(for: configuration)
                await events.primaryCompleted.wait()
                return result
            }
        )

        XCTAssertEqual(result.bars.map(\.label), ["Cursor Models", "Other Models"])
        XCTAssertEqual(result.bars.first?.usageText, "25%")
        XCTAssertTrue(events.recorded.contains(.primaryCompleted))
        // The real timeout may cancel the child before URLSession creates a task.
        // When one was created, fetchUsage waits for that child to finish too.
        if let optionalTask = observer.optionalTask {
            XCTAssertEqual(optionalTask.state, .completed)
            XCTAssertEqual((optionalTask.error as? URLError)?.code, .cancelled)
        }
    }

    func testCursorProviderWithoutCredentialIsNotDemoData() async throws {
        let provider = CursorUsageProvider(secretStore: EmptySecretStore())
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .cursor)

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.providerID, .cursor)
        XCTAssertEqual(result.accountID, configuration.id)
        XCTAssertEqual(result.subtitle, "Not configured - sign in with Cursor.")
        XCTAssertTrue(result.bars.isEmpty)
    }

    func testCodexUsageParserReadsPlusUsageWindows() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_893_369_600)
        let formatter = UserFacingDateTimeFormatter(
            timeZone: try XCTUnwrap(TimeZone(identifier: "Europe/Berlin")),
            locale: Locale(identifier: "en_US")
        )
        let payload = """
        {
          "plan_type": "plus",
          "credits": {"has_credits": true, "unlimited": false, "balance": "62500"},
          "rate_limit": {
            "primary_window": {
              "used_percent": 42,
              "reset_at": 1893456000,
              "limit_window_seconds": 18000
            },
            "secondary_window": {
              "used_percent": 81,
              "reset_at": 1894060800,
              "limit_window_seconds": 604800
            }
          }
        }
        """

        let result = try XCTUnwrap(CodexUsageParser.parse(
            Data(payload.utf8),
            fetchedAt: fetchedAt,
            dateTimeFormatter: formatter,
            locale: Locale(identifier: "en_US")
        ))

        XCTAssertEqual(result.title, "ChatGPT / Codex")
        XCTAssertEqual(
            result.plan,
            ProviderPlanDescriptor(
                identifier: "codex.plus",
                displayLabel: "ChatGPT 20",
                accessibilityLabel: "ChatGPT 20"
            )
        )
        XCTAssertEqual(result.bars.map(\.label), ["5 hour usage limit", "Weekly usage limit", "Credits pool"])
        XCTAssertEqual(result.bars.map(\.used), [42, 81, 62500])
        XCTAssertEqual(result.bars.map(\.usageText), ["42%", "81%", "62,500 credits"])
        XCTAssertTrue(try XCTUnwrap(result.bars.last).isUnboundedNumeric)
        XCTAssertEqual(result.configurableMetrics.last?.id, "codex.credits-pool")
        XCTAssertTrue(result.usageMessages.isEmpty)
        let resetDescription = try XCTUnwrap(result.bars.first?.resetDescription)
        XCTAssertTrue(resetDescription.hasPrefix("Resets 1d 0h (Tue 1:00"))
        XCTAssertTrue(resetDescription.hasSuffix("GMT+1)"))
        let newYorkFormatter = UserFacingDateTimeFormatter(
            timeZone: try XCTUnwrap(TimeZone(identifier: "America/New_York")),
            locale: Locale(identifier: "en_US")
        )
        let reformattedReset = try XCTUnwrap(result.bars.first?.localizedResetDescription(
            at: fetchedAt,
            dateTimeFormatter: newYorkFormatter
        ))
        XCTAssertTrue(reformattedReset.hasSuffix("EST)"))
        XCTAssertFalse(reformattedReset.contains("GMT+1"))
        XCTAssertEqual(result.bars.first?.projectionCurrent, 0.42)
        XCTAssertEqual(result.bars.first?.projectionLimit, 1)
        XCTAssertEqual(result.bars.first?.projectionPeriodStart, Date(timeIntervalSince1970: 1_893_438_000))
        XCTAssertEqual(result.bars.first?.projectionPeriodEnd, Date(timeIntervalSince1970: 1_893_456_000))
    }

    func testCodexUsageParserReadsEveryReturnedRateLimitBucketDeterministically() throws {
        let payload = """
        {
          "plan_type": "pro",
          "rate_limit": {
            "primary_window": {
              "used_percent": 30,
              "reset_at": 1894060800,
              "limit_window_seconds": 604800
            },
            "secondary_window": null
          },
          "code_review_rate_limit": {
            "primary_window": {
              "used_percent": 12,
              "reset_at": 1893456000,
              "limit_window_seconds": 18000
            }
          },
          "additional_rate_limits": [
            null,
            {
              "metered_feature": "codex_future",
              "limit_name": "Future model",
              "rate_limit": {
                "primary_window": {
                  "used_percent": 7,
                  "reset_at": 1893456000,
                  "limit_window_seconds": 7200
                }
              }
            },
            {"metered_feature": "malformed", "rate_limit": "unexpected"},
            {
              "metered_feature": "codex_bengalfox",
              "limit_name": "GPT-5.3-Codex-Spark",
              "rate_limit": {
                "secondary_window": {
                  "used_percent": 66,
                  "reset_at": 1894060800,
                  "limit_window_seconds": 604800
                },
                "primary_window": {
                  "used_percent": 44,
                  "reset_at": 1893456000,
                  "limit_window_seconds": 18000
                }
              }
            },
            {
              "metered_feature": "codex_quiet",
              "primary_window": {
                "used_percent": 9,
                "reset_at": 1893456000,
                "limit_window_seconds": 9000
              }
            }
          ]
        }
        """

        let result = try XCTUnwrap(CodexUsageParser.parse(Data(payload.utf8)))

        XCTAssertEqual(
            result.bars.map(\.stableKey),
            [
                "window-604800",
                "bucket-code_5Freview.window-18000",
                "bucket-codex_5Fbengalfox.window-18000",
                "bucket-codex_5Fbengalfox.window-604800",
                "bucket-codex_5Ffuture.window-7200",
                "bucket-codex_5Fquiet.window-9000",
            ]
        )
        XCTAssertEqual(
            result.bars.map(\.label),
            [
                "Weekly usage limit",
                "Code review · 5 hour usage limit",
                "GPT-5.3-Codex-Spark · 5 hour usage limit",
                "GPT-5.3-Codex-Spark · Weekly usage limit",
                "Future model · 2 hour usage limit",
                "Additional Codex usage · 150 minute usage limit",
            ]
        )
        XCTAssertEqual(result.bars.map(\.used), [30, 12, 44, 66, 7, 9])

        var reorderedRoot = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
        )
        let additionalRateLimits = try XCTUnwrap(
            reorderedRoot["additional_rate_limits"] as? [Any]
        )
        reorderedRoot["additional_rate_limits"] = Array(additionalRateLimits.reversed())
        let reorderedData = try JSONSerialization.data(withJSONObject: reorderedRoot)
        let reordered = try XCTUnwrap(CodexUsageParser.parse(reorderedData))

        XCTAssertEqual(reordered.bars.map(\.stableKey), result.bars.map(\.stableKey))
        XCTAssertEqual(reordered.bars.map(\.label), result.bars.map(\.label))
    }

    func testCodexUsageParserDoesNotDropCollidingOrAnonymousBuckets() throws {
        let payload = """
        {
          "additional_rate_limits": [
            {
              "metered_feature": "foo_bar",
              "rate_limit": {
                "primary_window": {
                  "used_percent": 1,
                  "reset_at": 1893456000,
                  "limit_window_seconds": 3600
                }
              }
            },
            {
              "metered_feature": "foo-bar",
              "rate_limit": {
                "primary_window": {
                  "used_percent": 2,
                  "reset_at": 1893456000,
                  "limit_window_seconds": 3600
                }
              }
            },
            {
              "primary_window": {
                "used_percent": 3,
                "reset_at": 1893456000,
                "limit_window_seconds": 3600
              }
            },
            {
              "primary_window": {
                "used_percent": 4,
                "reset_at": 1893456000,
                "limit_window_seconds": 3600
              }
            },
            {
              "metered_feature": "foo_bar",
              "rate_limit": {
                "primary_window": {
                  "used_percent": 5,
                  "reset_at": 1893456000,
                  "limit_window_seconds": 3600
                }
              }
            }
          ]
        }
        """

        let result = try XCTUnwrap(CodexUsageParser.parse(Data(payload.utf8)))

        XCTAssertEqual(result.bars.count, 5)
        XCTAssertEqual(Set(result.bars.compactMap(\.stableKey)).count, 5)
        XCTAssertEqual(
            Set(result.bars.compactMap(\.stableKey)),
            [
                "bucket-additional.window-3600",
                "bucket-additional.window-3600.duplicate-2",
                "bucket-foo_2Dbar.window-3600",
                "bucket-foo_5Fbar.window-3600",
                "bucket-foo_5Fbar.window-3600.duplicate-2",
            ]
        )

        var reorderedRoot = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
        )
        let collidingBuckets = try XCTUnwrap(
            reorderedRoot["additional_rate_limits"] as? [Any]
        )
        reorderedRoot["additional_rate_limits"] = Array(collidingBuckets.reversed())
        let reorderedData = try JSONSerialization.data(withJSONObject: reorderedRoot)
        let reordered = try XCTUnwrap(CodexUsageParser.parse(reorderedData))
        let keyedUsage = Dictionary(uniqueKeysWithValues: result.bars.compactMap { bar in
            bar.stableKey.map { ($0, bar.used) }
        })
        let reorderedKeyedUsage = Dictionary(uniqueKeysWithValues: reordered.bars.compactMap { bar in
            bar.stableKey.map { ($0, bar.used) }
        })

        XCTAssertEqual(reorderedKeyedUsage, keyedUsage)
    }

    func testCodexUsageParserKeepsSharedFeaturesBoundToImmutableLimitIDs() throws {
        func bucket(limitID: String, usedPercent: Double) -> [String: Any] {
            [
                "metered_feature": "shared",
                "limit_id": limitID,
                "rate_limit": [
                    "primary_window": [
                        "used_percent": usedPercent,
                        "reset_at": 1_893_456_000,
                        "limit_window_seconds": 3_600,
                    ],
                ],
            ]
        }

        func parse(_ buckets: [[String: Any]]) throws -> ProviderUsageResult {
            let data = try JSONSerialization.data(withJSONObject: [
                "additional_rate_limits": buckets,
            ])
            return try XCTUnwrap(CodexUsageParser.parse(data))
        }

        func keyedUsage(_ result: ProviderUsageResult) -> [String: Double] {
            Dictionary(uniqueKeysWithValues: result.bars.compactMap { bar in
                bar.stableKey.map { ($0, bar.used) }
            })
        }

        let initial = try parse([
            bucket(limitID: "alpha", usedPercent: 10),
            bucket(limitID: "beta", usedPercent: 20),
        ])
        XCTAssertEqual(keyedUsage(initial), [
            "bucket-shared.limit-alpha.window-3600": 10,
            "bucket-shared.limit-beta.window-3600": 20,
        ])

        let refreshed = try parse([
            bucket(limitID: "beta", usedPercent: 35),
            bucket(limitID: "alpha", usedPercent: 25),
        ])
        XCTAssertEqual(keyedUsage(refreshed), [
            "bucket-shared.limit-alpha.window-3600": 25,
            "bucket-shared.limit-beta.window-3600": 35,
        ])

        let surviving = try parse([
            bucket(limitID: "beta", usedPercent: 45),
        ])
        XCTAssertEqual(keyedUsage(surviving), [
            "bucket-shared.limit-beta.window-3600": 45,
        ])
    }

    func testCodexUsageParserIgnoresUnsafeWindowDurations() throws {
        let payload = """
        {
          "additional_rate_limits": [
            {
              "metered_feature": "zero",
              "primary_window": {
                "used_percent": 1,
                "reset_at": 1893456000,
                "limit_window_seconds": 0
              }
            },
            {
              "metered_feature": "negative",
              "primary_window": {
                "used_percent": 2,
                "reset_at": 1893456000,
                "limit_window_seconds": -1
              }
            },
            {
              "metered_feature": "extreme",
              "primary_window": {
                "used_percent": 3,
                "reset_at": 1893456000,
                "limit_window_seconds": 1e100
              }
            },
            {
              "metered_feature": "implausibly_long",
              "primary_window": {
                "used_percent": 4,
                "reset_at": 1893456000,
                "limit_window_seconds": 315360001
              }
            },
            {
              "metered_feature": "valid",
              "primary_window": {
                "used_percent": 5,
                "reset_at": 1893456000,
                "limit_window_seconds": 3600
              }
            },
            {
              "metered_feature": "nonfinite_usage",
              "primary_window": {
                "used_percent": "nan",
                "reset_at": 1893456000,
                "limit_window_seconds": 3600
              }
            }
          ]
        }
        """

        let result = try XCTUnwrap(CodexUsageParser.parse(Data(payload.utf8)))

        XCTAssertEqual(result.bars.map(\.stableKey), ["bucket-valid.window-3600"])
        XCTAssertEqual(result.bars.map(\.used), [5])
    }

    func testCodexUsageParserNormalizesOnlyVerifiedPlanValues() throws {
        let mappings: [(rawValue: String, identifier: String, label: String)] = [
            ("free", "codex.free", "ChatGPT Free"),
            ("go", "codex.go", "ChatGPT Go"),
            ("plus", "codex.plus", "ChatGPT 20"),
            ("pro", "codex.pro", "ChatGPT Pro 200"),
            ("prolite", "codex.prolite", "ChatGPT Pro 100"),
            ("promax", "codex.promax", "ChatGPT Pro 500"),
            ("business", "codex.business", "ChatGPT Business"),
            ("team", "codex.business", "ChatGPT Business"),
            ("enterprise", "codex.enterprise", "ChatGPT Enterprise"),
            ("edu", "codex.edu", "ChatGPT Edu"),
            ("health", "codex.health", "ChatGPT Health"),
            ("gov", "codex.gov", "ChatGPT Gov"),
        ]

        for mapping in mappings {
            let payload = """
            {
              "plan_type": "\(mapping.rawValue)",
              "rate_limit": {
                "primary_window": {
                  "used_percent": 1,
                  "reset_at": 1893456000,
                  "limit_window_seconds": 18000
                }
              }
            }
            """
            let result = try XCTUnwrap(CodexUsageParser.parse(Data(payload.utf8)))
            XCTAssertEqual(result.plan?.identifier, mapping.identifier, mapping.rawValue)
            XCTAssertEqual(result.plan?.displayLabel, mapping.label, mapping.rawValue)
        }

        for rawJSON in ["null", #""""#, #""unknown_value""#, "42"] {
            let payload = """
            {
              "plan_type": \(rawJSON),
              "rate_limit": {
                "primary_window": {
                  "used_percent": 1,
                  "reset_at": 1893456000,
                  "limit_window_seconds": 18000
                }
              }
            }
            """
            XCTAssertNil(
                try XCTUnwrap(CodexUsageParser.parse(Data(payload.utf8))).plan,
                rawJSON
            )
        }
    }

    func testCodexUsageParserReadsBankedResetCountsDefensively() throws {
        func parse(_ resetCreditsJSON: String?) -> CodexBankedRateLimitResets? {
            let resetCredits = resetCreditsJSON.map { ",\"rate_limit_reset_credits\":\($0)" } ?? ""
            let payload = """
            {
              "rate_limit": {
                "primary_window": {
                  "used_percent": 25,
                  "reset_at": 1893456000,
                  "limit_window_seconds": 18000
                }
              }
              \(resetCredits)
            }
            """
            return CodexUsageParser.parse(Data(payload.utf8))?.codexBankedRateLimitResets
        }

        XCTAssertNil(parse(nil))
        XCTAssertNil(parse("null"))
        XCTAssertNil(parse(#"{"available_count":0}"#))
        XCTAssertNil(parse(#"{"available_count":-1}"#))
        XCTAssertNil(parse(#"{"available_count":1.5}"#))
        XCTAssertNil(parse(#"{"available_count":"2"}"#))
        XCTAssertEqual(parse(#"{"available_count":1}"#)?.availableCount, 1)
        XCTAssertEqual(parse(#"{"available_count":3}"#)?.availableCount, 3)
        XCTAssertFalse(try XCTUnwrap(parse(#"{"available_count":1}"#)).canConsume)
    }

    func testCodexUsageParserReadsDetailedAndCountOnlyResetCredits() throws {
        let detailed = try XCTUnwrap(CodexUsageParser.parseResetCredits(
            Data("""
            {
              "available_count":2,
              "credits":[
                {
                  "id":"credit-1",
                  "status":"available",
                  "title":"Full reset (Weekly + 5 hr)",
                  "description":"Ready to redeem",
                  "expires_at":"2030-01-02T03:04:05Z"
                },
                {"id":"credit-used","status":"redeemed","title":"Do not show"}
              ]
            }
            """.utf8),
            canConsume: true
        ))

        XCTAssertEqual(detailed.availableCount, 2)
        XCTAssertTrue(detailed.canConsume)
        XCTAssertEqual(detailed.credits?.map(\.id), ["credit-1"])
        XCTAssertEqual(detailed.preferredCredit?.title, "Full reset (Weekly + 5 hr)")
        XCTAssertEqual(
            detailed.preferredCredit?.expiresAt,
            ISO8601DateFormatter().date(from: "2030-01-02T03:04:05Z")
        )

        let countOnly = try XCTUnwrap(CodexUsageParser.parseResetCredits(
            Data(#"{"available_count":4}"#.utf8),
            canConsume: true
        ))
        XCTAssertEqual(countOnly.availableCount, 4)
        XCTAssertNil(countOnly.credits)
        XCTAssertTrue(countOnly.canConsume)
    }

    func testCodexUsageParserAcceptsWeeklyOnlyProAndDurationDrift() throws {
        let weeklyOnlyPayload = #"{"plan_type":"prolite","rate_limit":{"primary_window":{"used_percent":30,"reset_at":1894060800,"limit_window_seconds":604800},"secondary_window":null}}"#
        let weeklyOnly = try XCTUnwrap(CodexUsageParser.parse(Data(weeklyOnlyPayload.utf8)))

        XCTAssertEqual(weeklyOnly.bars.map(\.label), ["Weekly usage limit"])
        XCTAssertTrue(weeklyOnly.usageMessages.isEmpty)

        let driftedPayload = #"{"rate_limit":{"primary_window":{"used_percent":20,"reset_at":1894060800,"limit_window_seconds":604800},"secondary_window":{"used_percent":10,"reset_at":1893456000,"limit_window_seconds":17999}}}"#
        let drifted = try XCTUnwrap(CodexUsageParser.parse(Data(driftedPayload.utf8)))

        XCTAssertEqual(drifted.bars.map(\.label), ["5 hour usage limit", "Weekly usage limit"])
        XCTAssertEqual(
            drifted.bars.enumerated().map {
                $0.element.metricIdentifier(providerID: .codex, index: $0.offset)
            },
            ["codex.window-18000", "codex.window-604800"]
        )
        XCTAssertTrue(drifted.usageMessages.isEmpty)

        let outsideTolerancePayload = #"{"rate_limit":{"primary_window":{"used_percent":10,"reset_at":1893456000,"limit_window_seconds":18901}}}"#
        let outsideTolerance = try XCTUnwrap(CodexUsageParser.parse(Data(outsideTolerancePayload.utf8)))

        XCTAssertEqual(outsideTolerance.bars.map(\.label), ["315 minute usage limit"])
        XCTAssertEqual(
            outsideTolerance.bars.first?.metricIdentifier(providerID: .codex, index: 0),
            "codex.window-18901"
        )
        XCTAssertTrue(outsideTolerance.usageMessages.isEmpty)
    }

    func testClaudeUsageParserReadsOAuthUsageWindows() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_893_369_600)
        let formatter = UserFacingDateTimeFormatter(
            timeZone: try XCTUnwrap(TimeZone(identifier: "Europe/Berlin")),
            locale: Locale(identifier: "de_DE")
        )
        let payload = """
        {
          "five_hour": {
            "utilization": 0.42,
            "resets_at": "2030-01-01T00:00:00Z"
          },
          "seven_day": {
            "utilization": 0.81,
            "resets_at": "2030-01-08T00:00:00Z"
          }
        }
        """

        let result = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(payload.utf8),
            subscriptionType: "pro",
            fetchedAt: fetchedAt,
            dateTimeFormatter: formatter
        ))

        XCTAssertEqual(result.providerID, .claude)
        XCTAssertEqual(result.title, "Claude")
        XCTAssertEqual(
            result.plan,
            ProviderPlanDescriptor(
                identifier: "claude.pro",
                displayLabel: "PRO",
                accessibilityLabel: "Pro"
            )
        )
        XCTAssertEqual(result.bars.map(\.label), ["5-hour", "Weekly"])
        XCTAssertEqual(result.bars.map(\.used), [42, 81])
        XCTAssertEqual(result.bars.map(\.usageText), ["42%", "81%"])
        let resetDescription = try XCTUnwrap(result.bars.first?.resetDescription)
        XCTAssertTrue(resetDescription.contains("Di. 01:00"))
        XCTAssertTrue(resetDescription.hasSuffix("GMT+1)"))
        XCTAssertEqual(result.bars.first?.projectionCurrent, 0.42)
        XCTAssertEqual(result.bars.first?.projectionLimit, 1)
        XCTAssertEqual(result.bars.first?.projectionPeriodStart, Date(timeIntervalSince1970: 1_893_438_000))
        XCTAssertEqual(result.bars.first?.projectionPeriodEnd, Date(timeIntervalSince1970: 1_893_456_000))

        let percentagePayload = #"{"five_hour":{"utilization":15},"seven_day":{"utilization":36}}"#
        let percentageResult = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(percentagePayload.utf8),
            subscriptionType: "pro"
        ))
        XCTAssertEqual(percentageResult.bars.map(\.used), [15, 36])

        let onePercentResult = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"five_hour":{"utilization":1}}"#.utf8),
            subscriptionType: "pro"
        ))
        XCTAssertEqual(onePercentResult.bars.first?.used, 1)
    }

    func testClaudeUsageParserRepresentsIdleAndActiveCurrentSessions() throws {
        let idle = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"limits":[{"kind":"session","percent":0,"resets_at":null,"is_active":false}]}"#.utf8),
            subscriptionType: "pro"
        ))
        XCTAssertEqual(idle.bars.first?.label, "5-hour")
        XCTAssertEqual(idle.bars.first?.used, 0)
        XCTAssertNil(idle.bars.first?.resetsAt)
        XCTAssertEqual(
            idle.bars.first?.projectionDescriptionOverride,
            "Starts when a message is sent"
        )

        let active = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"five_hour":{"utilization":13,"resets_at":"2030-01-01T02:00:00Z"}}"#.utf8),
            subscriptionType: "pro"
        ))
        XCTAssertEqual(active.bars.first?.label, "5-hour")
        XCTAssertEqual(active.bars.first?.used, 13)
        XCTAssertNotNil(active.bars.first?.resetsAt)
        XCTAssertNil(active.bars.first?.projectionDescriptionOverride)
    }

    func testClaudeUsageParserPrefersProviderSpendAndKeepsBalanceDistinctFromHeadroom() throws {
        let payload = """
        {
          "limits": [
            {"kind":"session","percent":0,"resets_at":null,"is_active":false},
            {"kind":"weekly_all","group":"weekly","percent":13,"resets_at":"2026-07-27T09:59:00Z","is_active":true}
          ],
          "extra_usage": {
            "is_enabled": true,
            "used_credits": 9999,
            "monthly_limit": 9999,
            "currency": "USD",
            "decimal_places": 2
          },
          "spend": {
            "used": {"amount_minor":0,"currency":"USD","exponent":2},
            "limit": {"amount_minor":4000,"currency":"USD","exponent":2},
            "percent": 0,
            "enabled": true,
            "balance": {"amount_minor":10000,"currency":"USD","exponent":2},
            "auto_reload": null
          }
        }
        """

        let result = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(payload.utf8),
            subscriptionType: "pro"
        ))

        XCTAssertEqual(result.bars.map(\.label), ["5-hour", "Weekly"])
        XCTAssertEqual(result.bars.map(\.used), [0, 13])
        XCTAssertEqual(
            result.monetaryMetrics.map(\.kind),
            [.spent, .spendLimit, .balance, .remainingHeadroom]
        )
        XCTAssertEqual(
            result.monetaryMetrics.map(\.amount),
            [Decimal(0), Decimal(40), Decimal(100), Decimal(40)]
        )
        XCTAssertEqual(
            result.monetaryMetrics.map(\.label),
            [
                "Usage credits spent",
                "Monthly spend limit",
                "Current balance",
                "Remaining spend headroom",
            ]
        )
        XCTAssertEqual(result.monetaryMetrics[0].detail, "0% used")
        XCTAssertEqual(
            result.monetaryMetrics[2].detail,
            "Provider-reported prepaid balance"
        )
        XCTAssertEqual(
            result.monetaryMetrics[3].detail,
            "Derived from spend limit; not a prepaid balance"
        )
        XCTAssertEqual(
            result.usageMessages,
            ["Usage credits are enabled.", "Auto-reload is off."]
        )
        XCTAssertTrue(result.dashboardUsageMessages.isEmpty)
        XCTAssertEqual(
            result.cardInformationSections,
            [
                ProviderCardInformationSection(
                    id: "claude.account-details",
                    title: "Account details",
                    items: [
                        ProviderCardInformationItem(
                            id: "claude.usage-credits",
                            label: "Usage credits",
                            detail: "Enabled"
                        ),
                        ProviderCardInformationItem(
                            id: "claude.auto-reload",
                            label: "Auto-reload",
                            detail: "Off"
                        ),
                    ]
                ),
            ]
        )
    }

    func testClaudeUsageParserOmitsUnreportedSpendFieldsAndPreservesAutoReloadObjectState() throws {
        let partial = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"spend":{"enabled":true,"used":{"amount_minor":250,"currency":"GBP","exponent":2},"auto_reload":{"enabled":true}}}"#.utf8),
            subscriptionType: "pro"
        ))
        XCTAssertEqual(partial.monetaryMetrics.map(\.kind), [.spent])
        XCTAssertEqual(partial.monetaryMetrics.first?.amount, Decimal(string: "2.5"))
        XCTAssertEqual(
            partial.usageMessages,
            ["Usage credits are enabled.", "Auto-reload is on."]
        )
        XCTAssertTrue(partial.dashboardUsageMessages.isEmpty)

        let missingOptionalFields = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"spend":{"enabled":true,"used":{"amount_minor":0,"currency":"USD","exponent":2}}}"#.utf8),
            subscriptionType: "pro"
        ))
        XCTAssertEqual(missingOptionalFields.monetaryMetrics.map(\.kind), [.spent])
        XCTAssertEqual(
            missingOptionalFields.usageMessages,
            ["Usage credits are enabled."]
        )
        XCTAssertTrue(missingOptionalFields.dashboardUsageMessages.isEmpty)
    }

    func testClaudeUsageParserLossilyOmitsMalformedSpendFields() throws {
        let result = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"five_hour":{"utilization":13,"resets_at":"2030-01-01T02:00:00Z"},"spend":{"enabled":true,"percent":"unknown","used":{"amount_minor":250,"currency":"USD"},"limit":{"amount_minor":4000,"currency":"USD","exponent":2},"balance":[],"auto_reload":[]}}"#.utf8),
            subscriptionType: "pro"
        ))

        XCTAssertEqual(result.bars.map(\.label), ["5-hour"])
        XCTAssertEqual(result.bars.map(\.used), [13])
        XCTAssertEqual(result.monetaryMetrics.map(\.kind), [.spendLimit])
        XCTAssertEqual(result.monetaryMetrics.first?.amount, Decimal(40))
        XCTAssertEqual(
            result.usageMessages,
            ["Usage credits are enabled."]
        )
    }

    func testClaudeUsageParserLossilyOmitsMalformedSpendContainer() throws {
        let result = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"five_hour":{"utilization":13,"resets_at":"2030-01-01T02:00:00Z"},"spend":[]}"#.utf8),
            subscriptionType: "pro"
        ))

        XCTAssertEqual(result.bars.map(\.label), ["5-hour"])
        XCTAssertEqual(result.bars.map(\.used), [13])
        XCTAssertTrue(result.monetaryMetrics.isEmpty)
    }

    func testClaudeUsageParserLossilyOmitsMalformedLimitsContainer() throws {
        let result = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"limits":[{"kind":"session","percent":13,"resets_at":"2030-01-01T02:00:00Z"},{"kind":"weekly_all","percent":"unknown"},"unexpected",{"kind":"weekly_all","percent":36,"resets_at":"2030-01-08T02:00:00Z"}],"spend":{"enabled":true,"balance":{"amount_minor":1000,"currency":"USD","exponent":2}}}"#.utf8),
            subscriptionType: "pro"
        ))

        XCTAssertEqual(result.bars.map(\.label), ["5-hour", "Weekly"])
        XCTAssertEqual(result.bars.map(\.used), [13, 36])
        XCTAssertEqual(result.monetaryMetrics.map(\.kind), [.balance])
        XCTAssertEqual(result.monetaryMetrics.map(\.amount), [Decimal(10)])
        XCTAssertEqual(result.usageMessages, ["Usage credits are enabled."])
    }

    func testClaudeUsageParserLossilyOmitsMalformedWindowFields() throws {
        let result = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"five_hour":{"utilization":13,"resets_at":[]},"seven_day":{"utilization":36,"resets_at":{}}}"#.utf8),
            subscriptionType: "pro"
        ))

        XCTAssertEqual(result.bars.map(\.label), ["5-hour", "Weekly"])
        XCTAssertEqual(result.bars.map(\.used), [13, 36])
        XCTAssertEqual(result.bars.map(\.resetsAt), [nil, nil])
    }

    func testClaudeUsageParserLossilyOmitsMalformedLegacyExtraUsage() throws {
        let preferredSpend = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"five_hour":{"utilization":13,"resets_at":"2030-01-01T02:00:00Z"},"spend":{"enabled":true,"used":{"amount_minor":500,"currency":"USD","exponent":2},"limit":{"amount_minor":4000,"currency":"USD","exponent":2},"balance":{"amount_minor":1000,"currency":"USD","exponent":2}},"extra_usage":{"is_enabled":true,"used_credits":"unknown"}}"#.utf8),
            subscriptionType: "pro"
        ))

        XCTAssertEqual(preferredSpend.bars.map(\.label), ["5-hour"])
        XCTAssertEqual(preferredSpend.bars.map(\.used), [13])
        XCTAssertEqual(
            preferredSpend.monetaryMetrics.map(\.kind),
            [.spent, .spendLimit, .balance, .remainingHeadroom]
        )
        XCTAssertEqual(preferredSpend.usageMessages, ["Usage credits are enabled."])

        let legacySpend = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"extra_usage":{"is_enabled":true,"used_credits":500,"monthly_limit":"unknown","currency":"USD","decimal_places":2}}"#.utf8),
            subscriptionType: "pro"
        ))

        XCTAssertEqual(legacySpend.monetaryMetrics.map(\.kind), [.spent])
        XCTAssertEqual(legacySpend.monetaryMetrics.map(\.amount), [Decimal(5)])
        XCTAssertEqual(
            legacySpend.usageMessages,
            ["Usage credits are enabled with no monthly spend limit reported."]
        )
    }

    func testClaudeUsageParserFillsPartialSpendFromLegacyExtraUsage() throws {
        let result = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"spend":{"enabled":true,"used":{"amount_minor":500,"currency":"USD","exponent":2},"balance":{"amount_minor":1000,"currency":"USD","exponent":2}},"extra_usage":{"is_enabled":true,"used_credits":250,"monthly_limit":4000,"currency":"USD","decimal_places":2}}"#.utf8),
            subscriptionType: "pro"
        ))

        XCTAssertEqual(
            result.monetaryMetrics.map(\.kind),
            [.spent, .spendLimit, .balance, .remainingHeadroom]
        )
        XCTAssertEqual(
            result.monetaryMetrics.map(\.amount),
            [Decimal(5), Decimal(40), Decimal(10), Decimal(35)]
        )
        XCTAssertEqual(result.usageMessages, ["Usage credits are enabled."])
    }

    func testClaudeUsageParserHonorsFallbackDisabledSpendState() throws {
        let result = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"spend":{"used":{"amount_minor":500,"currency":"USD","exponent":2}},"extra_usage":{"is_enabled":false,"disabled_reason":"Not funded"}}"#.utf8),
            subscriptionType: "pro"
        ))

        XCTAssertTrue(result.monetaryMetrics.isEmpty)
        XCTAssertEqual(result.usageMessages, ["Usage credits are disabled: Not funded."])
    }

    func testClaudeUsageParserHonorsFallbackEnabledSpendState() throws {
        let result = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"spend":{"used":{"amount_minor":500,"currency":"USD","exponent":2},"limit":{"amount_minor":4000,"currency":"USD","exponent":2}},"extra_usage":{"is_enabled":true,"used_credits":500,"monthly_limit":4000,"currency":"USD","decimal_places":2}}"#.utf8),
            subscriptionType: "pro"
        ))

        XCTAssertEqual(
            result.monetaryMetrics.map(\.kind),
            [.spent, .spendLimit, .remainingHeadroom]
        )
        XCTAssertEqual(result.usageMessages, ["Usage credits are enabled."])
    }

    func testClaudeUsageParserValidatesAndClampsProviderMoney() throws {
        let invalidExponent = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"spend":{"enabled":true,"used":{"amount_minor":500,"currency":"USD","exponent":20},"limit":{"amount_minor":4000,"currency":"USD","exponent":20}}}"#.utf8),
            subscriptionType: "pro"
        ))
        XCTAssertTrue(invalidExponent.monetaryMetrics.isEmpty)

        let negativeAmounts = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"spend":{"enabled":true,"used":{"amount_minor":-500,"currency":"USD","exponent":2},"limit":{"amount_minor":-4000,"currency":"USD","exponent":2},"balance":{"amount_minor":-1000,"currency":"USD","exponent":2}}}"#.utf8),
            subscriptionType: "pro"
        ))
        XCTAssertEqual(
            negativeAmounts.monetaryMetrics.map(\.kind),
            [.spent, .spendLimit, .balance, .remainingHeadroom]
        )
        XCTAssertEqual(
            negativeAmounts.monetaryMetrics.map(\.amount),
            [Decimal(0), Decimal(0), Decimal(0), Decimal(0)]
        )

        let hugePercent = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"spend":{"enabled":true,"percent":1e20,"used":{"amount_minor":500,"currency":"USD","exponent":2}}}"#.utf8),
            subscriptionType: "pro"
        ))
        XCTAssertEqual(hugePercent.monetaryMetrics.first?.detail, "Month to date")
    }

    func testClaudeUsageParserUsesOnlyExplicitVerifiedPlanCombinations() throws {
        let payload = Data(#"{"five_hour":{"utilization":0.1,"resets_at":"2030-01-01T00:00:00Z"}}"#.utf8)
        let mappings: [
            (
                subscription: String?,
                rateLimitTier: String?,
                identifier: String?,
                displayLabel: String?
            )
        ] = [
            ("free", nil, "claude.free", "FREE"),
            ("pro", "standard", "claude.pro", "PRO"),
            ("max", "max_20x", "claude.max20", "MAX 20×"),
            ("max_20x", nil, "claude.max20", "MAX 20×"),
            ("team", nil, "claude.team", "TEAM"),
            ("team_premium", nil, "claude.team-premium", "TEAM PREMIUM"),
            ("enterprise", nil, "claude.enterprise", "ENTERPRISE"),
            ("max", nil, "claude.max", "MAX"),
            ("subscription", nil, nil, nil),
            ("unknown_value", "unknown_tier", nil, nil),
            ("", "", nil, nil),
        ]

        for mapping in mappings {
            let result = try XCTUnwrap(ClaudeUsageParser.parse(
                payload,
                subscriptionType: mapping.subscription,
                rateLimitTier: mapping.rateLimitTier
            ))
            XCTAssertEqual(result.plan?.identifier, mapping.identifier, mapping.subscription ?? "nil")
            XCTAssertEqual(result.plan?.displayLabel, mapping.displayLabel, mapping.subscription ?? "nil")
        }
    }

    func testClaudeUsageParserPreservesScopedFiveHourLimits() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_893_369_600)
        let payload = """
        {
          "five_hour": {"utilization": 0.99, "resets_at": "2030-01-01T06:00:00Z"},
          "limits": [
            {"kind":"session","percent":27,"resets_at":"2030-01-01T02:00:00Z","is_active":true},
            {"kind":"session","percent":64,"resets_at":"2030-01-01T04:00:00Z","scope":{"model":{"display_name":"Fable"}},"is_active":true},
            {"kind":"session","percent":91,"scope":{"model":{"display_name":"Fable"}},"is_active":true}
          ]
        }
        """

        let result = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(payload.utf8),
            subscriptionType: "max",
            fetchedAt: fetchedAt
        ))

        XCTAssertEqual(result.bars.map(\.label), [
            "Other models 5-hour",
            "Fable current session",
        ])
        XCTAssertEqual(result.bars.map(\.used), [27, 64])
        XCTAssertEqual(
            result.bars.map(\.resetsAt),
            [
                ISO8601DateFormatter().date(from: "2030-01-01T02:00:00Z"),
                ISO8601DateFormatter().date(from: "2030-01-01T04:00:00Z"),
            ]
        )
        XCTAssertEqual(
            result.bars.map(\.projectionPeriodStart),
            [
                ISO8601DateFormatter().date(from: "2029-12-31T21:00:00Z"),
                ISO8601DateFormatter().date(from: "2029-12-31T23:00:00Z"),
            ]
        )

        let legacyAndScopedPayload = """
        {
          "five_hour": {"utilization": 0.31, "resets_at": "2030-01-01T06:00:00Z"},
          "limits": [
            {"kind":"session","percent":44,"resets_at":"2030-01-01T04:00:00Z","scope":{"model":{"display_name":"Fable"}},"is_active":true}
          ]
        }
        """
        let legacyAndScoped = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(legacyAndScopedPayload.utf8),
            subscriptionType: "max",
            fetchedAt: fetchedAt
        ))

        XCTAssertEqual(legacyAndScoped.bars.map(\.label), [
            "Fable current session",
            "5-hour",
        ])
        XCTAssertEqual(legacyAndScoped.bars.map(\.used), [44, 31])
        XCTAssertEqual(
            legacyAndScoped.bars.map(\.resetsAt),
            [
                ISO8601DateFormatter().date(from: "2030-01-01T04:00:00Z"),
                ISO8601DateFormatter().date(from: "2030-01-01T06:00:00Z"),
            ]
        )

        let inactiveScopedPayload = """
        {
          "five_hour": {"utilization": 0.25},
          "limits": [
            {"kind":"session","percent":80,"scope":{"model":{"display_name":"Fable"}},"is_active":false}
          ]
        }
        """
        let inactiveScoped = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(inactiveScopedPayload.utf8),
            subscriptionType: "max",
            fetchedAt: fetchedAt
        ))
        XCTAssertEqual(inactiveScoped.bars.map(\.label), ["5-hour"])
        XCTAssertEqual(inactiveScoped.bars.map(\.used), [25])
    }

    func testClaudeUsageParserShowsObservedInactiveFableWeeklyLimit() throws {
        let payload = """
        {
          "five_hour": {"utilization":11,"resets_at":"2030-01-01T02:00:00Z"},
          "seven_day": {"utilization":9,"resets_at":"2030-01-08T04:00:00Z"},
          "limits": [
            {"kind":"session","group":"session","percent":11,"resets_at":"2030-01-01T02:00:00Z","scope":null,"is_active":true},
            {"kind":"weekly_all","group":"weekly","percent":9,"resets_at":"2030-01-08T04:00:00Z","scope":null,"is_active":false},
            {"kind":"weekly_scoped","group":"weekly","percent":5,"resets_at":"2030-01-08T04:00:00Z","scope":{"model":{"id":null,"display_name":"Fable"}},"is_active":false}
          ]
        }
        """

        let result = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(payload.utf8),
            subscriptionType: "max"
        ))

        XCTAssertEqual(result.bars.map(\.label), [
            "5-hour",
            "Weekly",
            "Fable weekly usage limit",
        ])
        XCTAssertEqual(result.bars.map(\.used), [11, 9, 5])
        XCTAssertEqual(result.bars.map(\.stableKey), [
            "session",
            "weekly-all",
            "weekly-scoped-fable",
        ])
        XCTAssertEqual(
            result.bars.map(\.resetsAt),
            [
                ISO8601DateFormatter().date(from: "2030-01-01T02:00:00Z"),
                ISO8601DateFormatter().date(from: "2030-01-08T04:00:00Z"),
                ISO8601DateFormatter().date(from: "2030-01-08T04:00:00Z"),
            ]
        )
    }

    func testClaudeUsageParserPrefersActiveDuplicateWeeklyLimit() throws {
        let payload = """
        {
          "limits": [
            {"kind":"weekly_all","group":"monthly","percent":99,"is_active":true},
            {"kind":"weekly_all","group":"weekly","percent":9,"is_active":false},
            {"kind":"weekly_all","group":"weekly","percent":14,"is_active":true}
          ]
        }
        """

        let result = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(payload.utf8),
            subscriptionType: "max"
        ))

        XCTAssertEqual(result.bars.map(\.label), ["Weekly"])
        XCTAssertEqual(result.bars.map(\.used), [14])
        XCTAssertEqual(result.bars.map(\.stableKey), ["weekly-all"])
    }

    @MainActor
    func testClaudeStructuredScopedWeeklyLimitsPreserveLegacyIdentities() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let payload = """
        {
          "seven_day_sonnet": {"utilization":44},
          "seven_day_opus": {"utilization":32},
          "limits": [
            {"kind":"weekly_scoped","group":"weekly","percent":5,"scope":{"model":{"display_name":"Fable"}},"is_active":false},
            {"kind":"weekly_scoped","group":"weekly","percent":45,"scope":{"model":{"display_name":"Claude Sonnet 4.5"}},"is_active":false},
            {"kind":"weekly_scoped","group":"weekly","percent":33,"scope":{"model":{"display_name":"Claude Opus 4.1"}},"is_active":false}
          ]
        }
        """

        let result = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(payload.utf8),
            subscriptionType: "max"
        ))

        XCTAssertEqual(result.bars.map(\.label), [
            "Fable weekly usage limit",
            "Claude Sonnet 4.5 weekly usage limit",
            "Claude Opus 4.1 weekly usage limit",
        ])
        XCTAssertEqual(result.bars.map(\.used), [5, 45, 33])
        XCTAssertEqual(result.bars.map(\.stableKey), [
            "weekly-scoped-fable",
            "sonnet-weekly-limit",
            "opus-weekly-limit",
        ])

        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: MemorySecretStore())
        let configuration = try XCTUnwrap(store.addAccount(for: .claude))
        store.saveSecret("claude-token", for: configuration)
        let accountResult = ProviderUsageResult(
            accountID: configuration.id,
            providerID: result.providerID,
            title: result.title,
            subtitle: result.subtitle,
            bars: result.bars,
            fetchedAt: result.fetchedAt
        )
        let evaluation = UsageAlertEvaluator.evaluate(
            results: [accountResult],
            settings: UsageAlertSettings(
                isEnabled: true,
                warningThreshold: 0.20,
                criticalThreshold: 0.99
            ),
            activeAlertIDs: []
        )
        XCTAssertEqual(evaluation.notifications.count, 1)
        XCTAssertEqual(
            evaluation.activeAlertIDs,
            ["severity.warning.\(configuration.id)"]
        )

        WidgetSnapshotPublisher.publish(
            results: [accountResult],
            configurationStore: store, access: SnapshotProAccess(isProLocked: false, proAccessEndsAt: nil),
            snapshotDefaults: defaults
        )
        let snapshot = WidgetSnapshotStore.loadSnapshot(defaults: defaults)
        let widgetProvider = try XCTUnwrap(snapshot.results.first)
        XCTAssertEqual(widgetProvider.bars.map(\.id), [
            "\(configuration.id).0.fable-weekly-usage-limit",
            "\(configuration.id).sonnet-weekly-limit",
            "\(configuration.id).opus-weekly-limit",
        ])
        XCTAssertEqual(
            snapshot.builderTile(
                resolvingSavedID: "bar.\(configuration.id).0.sonnet-weekly-limit"
            )?.title,
            "Claude Sonnet 4.5 weekly usage limit"
        )
        XCTAssertEqual(
            snapshot.builderTile(
                resolvingSavedID: "bar.\(configuration.id).1.opus-weekly-limit"
            )?.title,
            "Claude Opus 4.1 weekly usage limit"
        )
        XCTAssertEqual(
            snapshot.builderTile(
                resolvingSavedID: "bar.\(configuration.id).2.fable-weekly-limit"
            )?.title,
            "Fable weekly usage limit"
        )
    }

    @MainActor
    func testClaudeStructuredScopedWeeklyLimitsKeepModelVersionsDistinct() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let payload = """
        {
          "seven_day_sonnet": {"utilization":55},
          "limits": [
            {"kind":"weekly_scoped","group":"weekly","percent":42,"scope":{"model":{"display_name":"Claude Sonnet 4"}},"is_active":true},
            {"kind":"weekly_scoped","group":"weekly","percent":68,"scope":{"model":{"display_name":"Claude Sonnet 4.5"}},"is_active":true}
          ]
        }
        """
        let parsed = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(payload.utf8),
            subscriptionType: "max"
        ))
        XCTAssertEqual(parsed.bars.map(\.stableKey), [
            "weekly-scoped-claudesonnet4",
            "weekly-scoped-claudesonnet45",
        ])
        XCTAssertEqual(parsed.bars.map(\.used), [42, 68])

        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: MemorySecretStore())
        let configuration = try XCTUnwrap(store.addAccount(for: .claude))
        store.saveSecret("claude-token", for: configuration)
        let result = ProviderUsageResult(
            accountID: configuration.id,
            providerID: parsed.providerID,
            title: parsed.title,
            subtitle: parsed.subtitle,
            bars: parsed.bars,
            fetchedAt: parsed.fetchedAt
        )
        let evaluation = UsageAlertEvaluator.evaluate(
            results: [result],
            settings: UsageAlertSettings(
                isEnabled: true,
                warningThreshold: 0.20,
                criticalThreshold: 0.99
            ),
            activeAlertIDs: []
        )
        XCTAssertEqual(
            evaluation.activeAlertIDs,
            ["severity.warning.\(configuration.id)"]
        )

        WidgetSnapshotPublisher.publish(
            results: [result],
            configurationStore: store, access: SnapshotProAccess(isProLocked: false, proAccessEndsAt: nil),
            snapshotDefaults: defaults
        )
        let widgetBars = try XCTUnwrap(
            WidgetSnapshotStore.loadSnapshot(defaults: defaults).results.first
        ).bars
        XCTAssertEqual(Set(widgetBars.map(\.id)).count, 2)
    }

    @MainActor
    func testClaudeWeeklyMetricsRemainDistinctWithoutDuplicateAlerts() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let secretStore = MemorySecretStore()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let fetchedAt = Date(timeIntervalSince1970: 1_893_369_600)
        let payload = """
        {
          "limits": [
            {"kind":"session","group":"session","percent":27,"resets_at":"2030-01-01T02:00:00Z","is_active":true},
            {"kind":"weekly_all","group":"weekly","percent":64,"resets_at":"2030-01-08T04:00:00Z","is_active":false},
            {"kind":"weekly_scoped","group":"weekly","percent":71,"resets_at":"2030-01-08T06:00:00Z","scope":{"model":{"display_name":"Fable"}},"is_active":false}
          ]
        }
        """
        let parsed = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(payload.utf8),
            subscriptionType: "max",
            fetchedAt: fetchedAt
        ))
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secretStore)
        let configuration = try XCTUnwrap(store.addAccount(for: .claude))
        store.saveSecret("claude-token", for: configuration)
        let result = ProviderUsageResult(
            accountID: configuration.id,
            providerID: parsed.providerID,
            title: parsed.title,
            subtitle: parsed.subtitle,
            bars: parsed.bars,
            fetchedAt: parsed.fetchedAt
        )

        let historySnapshot = UsageHistorySnapshot(result: result)
        XCTAssertEqual(historySnapshot.bars.map(\.label), result.bars.map(\.label))
        XCTAssertEqual(Set(historySnapshot.bars.map(\.label)).count, 3)

        let evaluation = UsageAlertEvaluator.evaluate(
            results: [result],
            settings: UsageAlertSettings(
                isEnabled: true,
                warningThreshold: 0.20,
                criticalThreshold: 0.99
            ),
            activeAlertIDs: []
        )
        XCTAssertEqual(evaluation.notifications.count, 1)
        XCTAssertEqual(
            evaluation.activeAlertIDs,
            ["severity.warning.\(configuration.id)"]
        )

        WidgetSnapshotPublisher.publish(
            results: [result],
            configurationStore: store, access: SnapshotProAccess(isProLocked: false, proAccessEndsAt: nil),
            snapshotDefaults: defaults,
            now: fetchedAt
        )
        let widgetProvider = try XCTUnwrap(
            WidgetSnapshotStore.loadSnapshot(defaults: defaults).results.first
        )
        XCTAssertEqual(widgetProvider.bars.map(\.label), result.bars.map(\.label))
        XCTAssertEqual(Set(widgetProvider.bars.map(\.id)).count, 3)
        XCTAssertEqual(widgetProvider.bars.map(\.id), [
            "\(configuration.id).0.5-hour-usage-limit",
            "\(configuration.id).weekly-usage-limit",
            "\(configuration.id).2.fable-weekly-usage-limit",
        ])
    }

    @MainActor
    func testClaudeScopedSessionWidgetIDsPreserveLegacyLabels() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let parsed = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"limits":[{"kind":"session","percent":27,"is_active":true},{"kind":"session","percent":64,"scope":{"model":{"display_name":"Fable"}},"is_active":true}]}"#.utf8),
            subscriptionType: "max"
        ))
        let secretStore = MemorySecretStore()
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secretStore)
        let configuration = try XCTUnwrap(store.addAccount(for: .claude))
        store.saveSecret("claude-token", for: configuration)
        let result = ProviderUsageResult(
            accountID: configuration.id,
            providerID: parsed.providerID,
            title: parsed.title,
            subtitle: parsed.subtitle,
            bars: parsed.bars,
            fetchedAt: parsed.fetchedAt
        )

        WidgetSnapshotPublisher.publish(
            results: [result],
            configurationStore: store, access: SnapshotProAccess(isProLocked: false, proAccessEndsAt: nil),
            snapshotDefaults: defaults
        )
        let snapshot = WidgetSnapshotStore.loadSnapshot(defaults: defaults)
        let widgetProvider = try XCTUnwrap(snapshot.results.first)

        XCTAssertEqual(widgetProvider.bars.map(\.id), [
            "\(configuration.id).0.other-models-5-hour-usage-limit",
            "\(configuration.id).1.fable-5-hour-usage-limit",
        ])
        XCTAssertNotNil(snapshot.builderTile(
            resolvingSavedID: "bar.\(configuration.id).0.other-models-5-hour-usage-limit"
        ))
        XCTAssertNotNil(snapshot.builderTile(
            resolvingSavedID: "bar.\(configuration.id).1.fable-5-hour-usage-limit"
        ))
    }

    func testClaudeScopedMetricsProduceSingleSeverityAlert() throws {
        let payload = """
        {
          "limits": [
            {"kind":"session","percent":42,"scope":{"model":{"display_name":"Claude Sonnet 4"}},"is_active":true},
            {"kind":"session","percent":68,"scope":{"model":{"display_name":"Claude Sonnet 4.5"}},"is_active":true}
          ]
        }
        """
        let result = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(payload.utf8),
            subscriptionType: "max"
        ))

        XCTAssertEqual(result.bars.map(\.stableKey), [
            "session-scoped-claudesonnet4",
            "session-scoped-claudesonnet45",
        ])
        let evaluation = UsageAlertEvaluator.evaluate(
            results: [result],
            settings: UsageAlertSettings(
                isEnabled: true,
                warningThreshold: 0.20,
                criticalThreshold: 0.99
            ),
            activeAlertIDs: []
        )
        XCTAssertEqual(evaluation.notifications.count, 1)
        XCTAssertEqual(evaluation.activeAlertIDs, ["severity.warning.claude"])
    }

    func testClaudeUnscopedIdentitySurvivesScopedLabelChange() throws {
        let unscopedPayload = """
        {"limits":[{"kind":"session","percent":42,"is_active":true}]}
        """
        let scopedPayload = """
        {
          "limits": [
            {"kind":"session","percent":42,"is_active":true},
            {"kind":"session","percent":68,"scope":{"model":{"display_name":"Fable"}},"is_active":true}
          ]
        }
        """
        let legacyPayload = """
        {"five_hour":{"utilization":0.42,"resets_at":"2030-01-01T02:00:00Z"}}
        """
        let unscopedResult = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(unscopedPayload.utf8),
            subscriptionType: "max"
        ))
        let scopedResult = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(scopedPayload.utf8),
            subscriptionType: "max"
        ))
        let legacyResult = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(legacyPayload.utf8),
            subscriptionType: "max"
        ))
        let headerResult = try XCTUnwrap(ClaudeUsageParser.parseRateLimitHeaders(
            [
                "anthropic-ratelimit-unified-5h-utilization": "0.42",
                "anthropic-ratelimit-unified-5h-reset": "1893456000",
            ],
            subscriptionType: "max"
        ))

        XCTAssertEqual(unscopedResult.bars.first?.label, "5-hour")
        XCTAssertEqual(scopedResult.bars.first?.label, "Other models 5-hour")
        XCTAssertEqual(unscopedResult.bars.first?.stableKey, "session")
        XCTAssertEqual(scopedResult.bars.first?.stableKey, "session")
        XCTAssertEqual(legacyResult.bars.first?.stableKey, "session")
        XCTAssertEqual(headerResult.bars.first?.stableKey, "session")

        for result in [unscopedResult, legacyResult, headerResult] {
            let evaluation = UsageAlertEvaluator.evaluate(
                results: [result],
                settings: UsageAlertSettings(
                    isEnabled: true,
                    warningThreshold: 0.20,
                    criticalThreshold: 0.99
                ),
                activeAlertIDs: []
            )
            XCTAssertEqual(evaluation.activeAlertIDs, ["severity.warning.claude"])
        }
    }

    func testClaudeUsageParserReadsStructuredAndScopedLimitsWithoutDuplicates() throws {
        let payload = """
        {
          "five_hour": {"utilization": 0.99, "resets_at": "2030-01-01T00:00:00Z"},
          "seven_day": {"utilization": 0.88, "resets_at": "2030-01-08T00:00:00Z"},
          "seven_day_sonnet": {"utilization": 0.44, "resets_at": "2030-01-08T00:00:00Z"},
          "limits": [
            {"kind":"session","percent":15,"is_active":true},
            {"kind":"weekly_all","percent":36,"resets_at":"2030-01-08T00:00:00Z","is_active":true},
            {"kind":"weekly_scoped","percent":71,"resets_at":"2030-01-08T00:00:00.838164+00:00","scope":{"model":{"display_name":"Fable"}},"is_active":true},
            {"kind":"weekly_scoped","percent":112,"scope":{"model":{"display_name":"Future Model"}},"is_active":true},
            {"kind":"weekly_scoped","percent":49,"scope":{"model":{"display_name":"Claude Sonnet 4.5"}},"is_active":true},
            {"kind":"internal_codename","percent":100,"scope":{"model":{"display_name":"Do Not Show"}},"is_active":true},
            {"kind":"weekly_scoped","percent":90,"scope":{"model":{"id":"internal-only"}},"is_active":true}
          ]
        }
        """

        let result = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(payload.utf8),
            subscriptionType: "max_20x"
        ))

        XCTAssertEqual(result.bars.map(\.label), [
            "5-hour",
            "Weekly",
            "Fable weekly usage limit",
            "Future Model weekly usage limit",
            "Claude Sonnet 4.5 weekly usage limit",
        ])
        XCTAssertEqual(result.bars.map(\.used), [15, 36, 71, 112, 49])
        XCTAssertEqual(result.bars[3].usageText, "112%")
        XCTAssertEqual(result.bars[0].resetsAt, ISO8601DateFormatter().date(from: "2030-01-01T00:00:00Z"))
        XCTAssertNil(result.bars[3].resetsAt)
        XCTAssertNotNil(result.bars[2].resetsAt)
        XCTAssertTrue(result.usageMessages.contains {
            $0 == "Fable usage is capped within the all-model weekly allowance."
        })
        XCTAssertFalse(result.dashboardUsageMessages.contains {
            $0 == "Fable usage is capped within the all-model weekly allowance."
        })
        XCTAssertEqual(
            result.cardInformationSections.first,
            ProviderCardInformationSection(
                id: "claude.limit-details",
                title: "Limit details",
                items: [
                    ProviderCardInformationItem(
                        id: "claude.limit.weekly-scoped-fable",
                        label: "Fable weekly limit",
                        detail: "Counts toward the all-model weekly allowance"
                    ),
                    ProviderCardInformationItem(
                        id: "claude.limit.weekly-scoped-futuremodel",
                        label: "Future Model weekly limit",
                        detail: "Counts toward the all-model weekly allowance"
                    ),
                    ProviderCardInformationItem(
                        id: "claude.limit.weekly-scoped-claudesonnet45",
                        label: "Claude Sonnet 4.5 weekly limit",
                        detail: "Counts toward the all-model weekly allowance"
                    ),
                ]
            )
        )
        XCTAssertFalse(result.bars.contains { $0.label.contains("Do Not Show") })

        let incompleteStructured = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"five_hour":{"utilization":0.42},"limits":[{"kind":"session","percent":null}]}"#.utf8),
            subscriptionType: nil
        ))
        XCTAssertEqual(incompleteStructured.bars.first?.used, 42)
    }

    func testClaudeUsageParserReadsCurrencyAwareUsageCredits() throws {
        let payload = """
        {
          "limits": [{"kind":"weekly_all","percent":24,"is_active":true}],
          "extra_usage": {
            "is_enabled": true,
            "monthly_limit": 5000,
            "used_credits": 1250,
            "currency": "EUR",
            "decimal_places": 2
          }
        }
        """

        let result = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(payload.utf8),
            subscriptionType: "pro"
        ))

        XCTAssertEqual(result.bars.first?.used, 24)
        XCTAssertEqual(result.monetaryMetrics.map(\.kind), [.spent, .spendLimit, .remainingHeadroom])
        XCTAssertEqual(result.monetaryMetrics.map(\.minorUnits), [Decimal(1250), Decimal(5000), Decimal(3750)])
        XCTAssertEqual(result.monetaryMetrics.map(\.amount), [Decimal(string: "12.5")!, Decimal(50), Decimal(string: "37.5")!])
        XCTAssertEqual(result.monetaryMetrics.map(\.currencyCode), ["EUR", "EUR", "EUR"])
        XCTAssertEqual(result.monetaryMetrics.last?.detail, "Not a prepaid balance")
        XCTAssertNil(result.creditsRemaining)
    }

    func testClaudeUsageParserRepresentsDisabledUnlimitedAndMalformedExtraUsage() throws {
        let disabled = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"extra_usage":{"is_enabled":false,"disabled_reason":"Not funded"}}"#.utf8),
            subscriptionType: nil
        ))
        XCTAssertEqual(disabled.usageMessages, ["Usage credits are disabled: Not funded."])
        XCTAssertEqual(disabled.dashboardUsageMessages, disabled.usageMessages)
        XCTAssertTrue(disabled.monetaryMetrics.isEmpty)

        let unlimited = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"extra_usage":{"is_enabled":true,"used_credits":250,"currency":"GBP","decimal_places":2}}"#.utf8),
            subscriptionType: nil
        ))
        XCTAssertEqual(unlimited.monetaryMetrics.map(\.kind), [.spent])
        XCTAssertEqual(unlimited.usageMessages, ["Usage credits are enabled with no monthly spend limit reported."])

        let malformed = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"limits":[{"kind":"unknown","percent":50}],"extra_usage":{"is_enabled":true,"used_credits":10,"currency":"US"}}"#.utf8),
            subscriptionType: nil
        ))
        XCTAssertTrue(malformed.monetaryMetrics.isEmpty)
        XCTAssertEqual(
            malformed.usageMessages,
            ["Usage credits are enabled, but monetary details are temporarily unavailable."]
        )
        XCTAssertEqual(malformed.dashboardUsageMessages, malformed.usageMessages)

        let missingCurrency = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"extra_usage":{"is_enabled":true,"used_credits":1250,"monthly_limit":5000,"decimal_places":2}}"#.utf8),
            subscriptionType: nil
        ))
        XCTAssertEqual(missingCurrency.monetaryMetrics.map(\.currencyCode), ["USD", "USD", "USD"])
        XCTAssertEqual(missingCurrency.monetaryMetrics.map(\.amount), [12.5, 50, 37.5])

        let unknownState = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"extra_usage":{"currency":"USD","decimal_places":2}}"#.utf8),
            subscriptionType: nil
        ))
        XCTAssertEqual(
            unknownState.usageMessages,
            ["Usage credits are enabled, but monetary details are temporarily unavailable."]
        )

        let missingSpend = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"extra_usage":{"is_enabled":true,"monthly_limit":5000,"currency":"USD","decimal_places":2}}"#.utf8),
            subscriptionType: nil
        ))
        XCTAssertTrue(missingSpend.monetaryMetrics.isEmpty)
        XCTAssertEqual(
            missingSpend.usageMessages,
            ["Usage credits are enabled, but monetary details are temporarily unavailable."]
        )

        let inferredPrecision = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"extra_usage":{"is_enabled":true,"used_credits":1250,"monthly_limit":5000,"currency":"USD"}}"#.utf8),
            subscriptionType: nil
        ))
        XCTAssertEqual(inferredPrecision.monetaryMetrics.map(\.decimalPlaces), [2, 2, 2])
        XCTAssertEqual(inferredPrecision.monetaryMetrics.map(\.amount), [12.5, 50, 37.5])

        let unreportedEnabledState = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"extra_usage":{"used_credits":1250,"monthly_limit":5000,"currency":"USD","decimal_places":2}}"#.utf8),
            subscriptionType: nil
        ))
        XCTAssertEqual(unreportedEnabledState.monetaryMetrics.map(\.kind), [.spent, .spendLimit, .remainingHeadroom])
        XCTAssertEqual(
            unreportedEnabledState.usageMessages,
            ["Usage-credit enabled status was not reported."]
        )
        XCTAssertEqual(
            unreportedEnabledState.dashboardUsageMessages,
            unreportedEnabledState.usageMessages
        )
    }

    func testClaudeUsageParserReadsRateLimitHeaders() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_893_369_600)
        let result = try XCTUnwrap(ClaudeUsageParser.parseRateLimitHeaders(
            [
                "anthropic-ratelimit-unified-5h-utilization": "0.25",
                "anthropic-ratelimit-unified-5h-reset": "1893456000",
            ],
            subscriptionType: "max",
            fetchedAt: fetchedAt
        ))

        XCTAssertEqual(result.title, "Claude")
        XCTAssertEqual(result.plan?.displayLabel, "MAX")
        XCTAssertEqual(result.bars.map(\.label), ["5-hour"])
        XCTAssertEqual(result.bars.first?.stableKey, "session")
        XCTAssertEqual(result.bars.first?.used, 25)
        XCTAssertEqual(result.bars.first?.projectionCurrent, 0.25)

        let overQuota = try XCTUnwrap(ClaudeUsageParser.parseRateLimitHeaders(
            [
                "anthropic-ratelimit-unified-5h-utilization": "1.2",
                "anthropic-ratelimit-unified-5h-reset": "1893456000",
            ],
            subscriptionType: "max",
            fetchedAt: fetchedAt
        ))
        XCTAssertEqual(overQuota.bars.first?.used, 100)
    }

    func testUsageBarFormatsPercentAndProjection() throws {
        let start = Date(timeIntervalSince1970: 1_767_225_600)
        let now = start.addingTimeInterval(60 * 60)
        let end = start.addingTimeInterval(5 * 60 * 60)
        let bar = UsageBar(
            label: "5 hour usage limit",
            used: 25,
            limit: 100,
            projectionCurrent: 0.25,
            projectionLimit: 1,
            projectionPeriodStart: start,
            projectionPeriodEnd: end,
            showProjectionOnCurrentBar: true
        )

        XCTAssertEqual(bar.usageText, "25%")
        XCTAssertEqual(bar.projectedFraction(at: now), 1)
        XCTAssertEqual(bar.projectedSeverity(at: now), .critical)
        XCTAssertEqual(bar.effectiveSeverity(at: now), .critical)
        let projection = try XCTUnwrap(bar.projectionDescription(at: now))
        XCTAssertTrue(projection.hasPrefix("Projected 100% at current pace - Limit hit "))
        XCTAssertTrue(projection.hasSuffix(" - 1h early"))
    }

    func testUserFacingDateTimeFormatterUsesTimezoneAtDisplayedInstant() throws {
        let winter = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-01-15T12:00:00Z"))
        let summer = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-15T12:00:00Z"))
        let marchMismatch = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-03-20T12:00:00Z"))
        let octoberMismatch = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-29T12:00:00Z"))
        let locale = Locale(identifier: "en_US")
        let cases: [(String, String, String)] = [
            ("Europe/Berlin", "GMT+1", "GMT+2"),
            ("America/New_York", "EST", "EDT"),
            ("Asia/Kathmandu", "GMT+5:45", "GMT+5:45"),
        ]

        for (identifier, winterZone, summerZone) in cases {
            let formatter = UserFacingDateTimeFormatter(
                timeZone: try XCTUnwrap(TimeZone(identifier: identifier)),
                locale: locale
            )

            XCTAssertTrue(formatter.timeWithZone(winter, includesWeekday: false).hasSuffix(winterZone))
            XCTAssertTrue(formatter.timeWithZone(summer, includesWeekday: false).hasSuffix(summerZone))
        }

        let berlin = UserFacingDateTimeFormatter(
            timeZone: try XCTUnwrap(TimeZone(identifier: "Europe/Berlin")),
            locale: locale
        )
        let newYork = UserFacingDateTimeFormatter(
            timeZone: try XCTUnwrap(TimeZone(identifier: "America/New_York")),
            locale: locale
        )
        XCTAssertTrue(berlin.timeWithZone(marchMismatch, includesWeekday: false).hasSuffix("GMT+1"))
        XCTAssertTrue(newYork.timeWithZone(marchMismatch, includesWeekday: false).hasSuffix("EDT"))
        XCTAssertTrue(berlin.timeWithZone(octoberMismatch, includesWeekday: false).hasSuffix("GMT+1"))
        XCTAssertTrue(newYork.timeWithZone(octoberMismatch, includesWeekday: false).hasSuffix("EDT"))
    }

    func testUserFacingDateTimeFormatterHonorsLocaleAndLocalWeekday() throws {
        let instant = try XCTUnwrap(ISO8601DateFormatter().date(from: "2030-01-01T00:00:00Z"))
        let newYork = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let berlin = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))
        let usFormatter = UserFacingDateTimeFormatter(
            timeZone: newYork,
            locale: Locale(identifier: "en_US")
        )
        let germanFormatter = UserFacingDateTimeFormatter(
            timeZone: berlin,
            locale: Locale(identifier: "de_DE")
        )

        let newYorkValue = usFormatter.timeWithZone(instant, includesWeekday: true)
        let berlinValue = germanFormatter.timeWithZone(instant, includesWeekday: true)
        XCTAssertTrue(newYorkValue.contains("Mon"))
        XCTAssertTrue(newYorkValue.contains("PM"))
        XCTAssertTrue(berlinValue.contains("Di."))
        XCTAssertTrue(berlinValue.contains("01:00"))
        XCTAssertFalse(berlinValue.contains("AM"))
        XCTAssertFalse(berlinValue.contains("PM"))
    }

    func testUserFacingDateTimeFormatterReevaluatesTimezoneProvider() throws {
        let instant = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-01-15T12:00:00Z"))
        var timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let formatter = UserFacingDateTimeFormatter(
            timeZoneProvider: { timeZone },
            localeProvider: { Locale(identifier: "en_US") }
        )

        XCTAssertTrue(formatter.timeWithZone(instant, includesWeekday: false).hasSuffix("EST"))
        timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))
        let updatedValue = formatter.timeWithZone(instant, includesWeekday: false)
        XCTAssertTrue(updatedValue.hasSuffix("GMT+1"))
        XCTAssertFalse(updatedValue.contains("EST"))
    }

    func testCodexResetDescriptionsCoverRelativeAndExpiredRanges() throws {
        let resetAt = Date(timeIntervalSince1970: 1_893_456_000)
        let formatter = UserFacingDateTimeFormatter(
            timeZone: try XCTUnwrap(TimeZone(identifier: "Europe/Berlin")),
            locale: Locale(identifier: "en_US")
        )
        let payload = """
        {
          "rate_limit": {
            "primary_window": {
              "used_percent": 42,
              "reset_at": 1893456000,
              "limit_window_seconds": 18000
            }
          }
        }
        """
        let cases: [(Date, String)] = [
            (resetAt.addingTimeInterval(60), "Resets now"),
            (resetAt.addingTimeInterval(-30 * 60), "Resets 30m"),
            (resetAt.addingTimeInterval(-2 * 60 * 60), "Resets 2h 0m"),
            (resetAt.addingTimeInterval(-(2 * 24 + 4) * 60 * 60), "Resets 2d 4h"),
        ]

        for (fetchedAt, expectedPrefix) in cases {
            let result = try XCTUnwrap(CodexUsageParser.parse(
                Data(payload.utf8),
                fetchedAt: fetchedAt,
                dateTimeFormatter: formatter
            ))
            XCTAssertTrue(try XCTUnwrap(result.bars.first?.resetDescription).hasPrefix(expectedPrefix))
        }
    }

    func testUsageBarFormatsProjectedLimitInInjectedTimezone() throws {
        let start = Date(timeIntervalSince1970: 1_767_225_600)
        let now = start.addingTimeInterval(60 * 60)
        let end = start.addingTimeInterval(5 * 60 * 60)
        let formatter = UserFacingDateTimeFormatter(
            timeZone: try XCTUnwrap(TimeZone(identifier: "Asia/Kathmandu")),
            locale: Locale(identifier: "en_US")
        )

        let description = UsageBar.formatLimitHit(
            current: 0.25,
            limit: 1,
            periodStart: start,
            periodEnd: end,
            now: now,
            dateTimeFormatter: formatter
        )

        XCTAssertTrue(description.contains("Thu 9:45"))
        XCTAssertTrue(description.contains("GMT+5:45"))
        XCTAssertTrue(description.hasSuffix(" - 1h early"))
    }

    @MainActor
    func testWidgetSnapshotReformatsResetAndProjectionForChangedTimezone() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let secretStore = MemorySecretStore()
        let store = ProviderConfigurationStore(initialPlanAccess: .unrestricted, defaults: defaults, secretStore: secretStore)
        let configuration = try XCTUnwrap(store.addAccount(for: .codex))
        store.saveSecret("test-token", for: configuration)
        let start = Date(timeIntervalSince1970: 1_767_225_600)
        let now = start.addingTimeInterval(60 * 60)
        let resetAt = start.addingTimeInterval(3 * 60 * 60)
        let result = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .codex,
            title: "ChatGPT / Codex",
            subtitle: "Live ChatGPT usage",
            bars: [
                UsageBar(
                    label: "5 hour usage limit",
                    used: 25,
                    limit: 100,
                    resetDescription: "Resets 2h (10:00 PM EST)",
                    resetsAt: resetAt,
                    resetDisplayStyle: .relativeWithLocalTime,
                    projectionCurrent: 0.25,
                    projectionLimit: 1,
                    projectionPeriodStart: start,
                    projectionPeriodEnd: start.addingTimeInterval(5 * 60 * 60),
                    showProjectionOnCurrentBar: true
                ),
            ],
            fetchedAt: now
        )
        let newYork = UserFacingDateTimeFormatter(
            timeZone: try XCTUnwrap(TimeZone(identifier: "America/New_York")),
            locale: Locale(identifier: "en_US")
        )
        let berlin = UserFacingDateTimeFormatter(
            timeZone: try XCTUnwrap(TimeZone(identifier: "Europe/Berlin")),
            locale: Locale(identifier: "en_US")
        )

        WidgetSnapshotPublisher.publish(
            results: [result],
            configurationStore: store, access: SnapshotProAccess(isProLocked: false, proAccessEndsAt: nil),
            snapshotDefaults: defaults,
            now: now,
            dateTimeFormatter: newYork
        )
        let storedBar = try XCTUnwrap(
            WidgetSnapshotStore.loadSnapshot(defaults: defaults).results.first?.bars.first
        )
        let easternProjection = try XCTUnwrap(storedBar.localizedProjectionDescription(
            dateTimeFormatter: newYork
        ))
        let easternReset = try XCTUnwrap(storedBar.localizedResetDescription(
            at: now,
            dateTimeFormatter: newYork
        ))
        XCTAssertTrue(easternProjection.contains("EST"))
        XCTAssertTrue(easternReset.contains("EST"))

        let localProjection = try XCTUnwrap(storedBar.localizedProjectionDescription(
            dateTimeFormatter: berlin
        ))
        let localReset = try XCTUnwrap(storedBar.localizedResetDescription(
            at: now,
            dateTimeFormatter: berlin
        ))
        XCTAssertTrue(localProjection.contains("GMT+1"))
        XCTAssertFalse(localProjection.contains("EST"))
        XCTAssertTrue(localReset.contains("GMT+1"))
        XCTAssertFalse(localReset.contains("EST"))
    }

    func testUsageBarShowsSafeProjectionWhenPaceStaysBelowLimit() {
        let start = Date(timeIntervalSince1970: 1_767_225_600)
        let now = start.addingTimeInterval(60 * 60)
        let end = start.addingTimeInterval(5 * 60 * 60)
        let bar = UsageBar(
            label: "5 hour usage limit",
            used: 8,
            limit: 100,
            projectionCurrent: 0.08,
            projectionLimit: 1,
            projectionPeriodStart: start,
            projectionPeriodEnd: end,
            showProjectionOnCurrentBar: true
        )

        XCTAssertEqual(bar.projectedFraction(at: now), 0.4)
        XCTAssertEqual(bar.projectedSeverity(at: now), .normal)
        XCTAssertEqual(bar.effectiveSeverity(at: now), .normal)
        XCTAssertEqual(bar.projectionDescription(at: now), "Projected to stay under limit")
        XCTAssertNil(bar.dashboardProjectionDescription(at: now))
    }

    func testUsageBarKeepsOverLimitPercentVisible() {
        let bar = UsageBar(label: "Weekly usage limit", used: 112, limit: 100)

        XCTAssertEqual(bar.usageText, "112%")
        XCTAssertEqual(bar.fractionUsed, 1)
    }

}
