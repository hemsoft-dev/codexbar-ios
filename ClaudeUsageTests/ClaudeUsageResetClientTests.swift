import Foundation
import XCTest
@testable import CodexBarIOS

final class ClaudeUsageResetClientTests: XCTestCase {
    private let account = ProviderAccountConfiguration(id: "claude.fixture", providerID: .claude, authMethod: .cliToken)
    private let now = Date(timeIntervalSince1970: 1_893_456_000)

    private var fixtureConfirmedGrant: ClaudeUsageResetGrant {
        ClaudeUsageResetGrant(id: "fixture_grant", title: "Claude usage reset", remainingCount: 2,
                             startsAt: Date(timeIntervalSince1970: 1_890_777_600),
                             expiresAt: Date(timeIntervalSince1970: 1_894_060_800),
                             clears: ["five_hour", "seven_day"], isPaused: false, isUsableNow: true, requiresLimit: true)
    }

    func testFreshVerifiedGrantProducesOneOrganizationBoundPost() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        ResetClientProtocol.configure(mode: .success)
        let outcome = try await harness.client.consume(for: account, accessToken: "fixture-token", grantID: "fixture_grant",
                                                          credentialBinding: ClaudeUsageResetClient.credentialBinding(for: "fixture-token"),
                                                          confirmedGrant: fixtureConfirmedGrant)
        XCTAssertEqual(outcome, .reset)
        let requests = ResetClientProtocol.requests
        XCTAssertEqual(requests.filter { $0.httpMethod == "POST" }.count, 1)
        let post = try XCTUnwrap(requests.last)
        XCTAssertEqual(post.url?.path, "/api/organizations/00000000-0000-0000-0000-000000000002/reset_rate_limits")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(post.httpBody)) as? [String: String])
        XCTAssertEqual(body["program"], "cedar_ember")
        XCTAssertEqual(body["grant_id"], "fixture_grant")
        XCTAssertNotNil(body["request_id"].flatMap(UUID.init(uuidString:)))
        XCTAssertEqual(post.value(forHTTPHeaderField: "User-Agent"), "CodexBarIOS")
        XCTAssertTrue(requests.contains { $0.url?.query == "cedar_ember=1" })
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: harness.directory.path).isEmpty)
        try await assertConfirmedOutcomesAndRejections()
        try await assertLoopbackRedirectWhenRequested()
        let changedHarness = makeHarness()
        defer { try? FileManager.default.removeItem(at: changedHarness.directory) }
        ResetClientProtocol.configure(mode: .success)
        let confirmed = try await changedHarness.client.inventory(accessToken: "fixture-token")
        let grant = try XCTUnwrap(confirmed.redeemableGrant(at: now))
        ResetClientProtocol.configure(mode: .reconciled)
        let changed = try await changedHarness.client.consume(
            for: account, accessToken: "fixture-token", grantID: grant.id,
            credentialBinding: ClaudeUsageResetClient.credentialBinding(for: "fixture-token"), confirmedGrant: grant
        )
        XCTAssertEqual(changed, .stateChanged)
        XCTAssertEqual(ResetClientProtocol.requests.filter { $0.httpMethod == "POST" }.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: changedHarness.directory.path))
    }

    private func assertLoopbackRedirectWhenRequested() async throws {
        // Explicit local transport qualification; the native suite has no loopback fixture server.
        let portFile = URL(fileURLWithPath: "/tmp/codexbar-reset-redirect-port")
        guard FileManager.default.fileExists(atPath: portFile.path) else { return }
        let port = try XCTUnwrap(Int(String(contentsOf: portFile, encoding: .utf8)))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeRedirect.\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = now
        let client = ClaudeUsageResetClient(session: URLSession(configuration: .ephemeral),
                                           secretStore: ResetClientSecrets(token: "fixture-token"), receiptDirectory: directory,
                                           baseURL: URL(string: "http://127.0.0.1:\(port)")!, now: { clock })
        do {
            _ = try await client.consume(for: account, accessToken: "fixture-token", grantID: "fixture_grant",
                                         credentialBinding: ClaudeUsageResetClient.credentialBinding(for: "fixture-token"),
                                         confirmedGrant: fixtureConfirmedGrant)
            XCTFail("A real HTTP307 must never follow or report a confirmed reset")
        } catch { XCTAssertEqual(error as? ClaudeUsageResetError, .indeterminate) }
        let requests = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf:
            URL(fileURLWithPath: "/tmp/codexbar-reset-redirect-requests.json"))) as? [[String: String]])
        XCTAssertEqual(requests.filter { $0["method"] == "POST" }.count, 1)
        XCTAssertFalse(requests.contains { $0["path"] == "/redirected-reset" })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1)
    }

    private func assertConfirmedOutcomesAndRejections() async throws {
        let confirmed: [(String, ClaudeUsageResetOutcome)] = [
            ("reset", .reset), ("already_redeemed", .alreadyRedeemed), ("already_used", .alreadyRedeemed),
            ("nothing_to_reset", .nothingToReset), ("not_limited", .nothingToReset), ("no_credit", .noCredit),
        ]
        for (response, expected) in confirmed {
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.directory) }
            ResetClientProtocol.configure(mode: .confirmed(response))
            let outcome = try await harness.client.consume(for: account, accessToken: "fixture-token", grantID: "fixture_grant",
                credentialBinding: ClaudeUsageResetClient.credentialBinding(for: "fixture-token"), confirmedGrant: fixtureConfirmedGrant)
            XCTAssertEqual(outcome, expected, response)
            XCTAssertEqual(ResetClientProtocol.requests.filter { $0.httpMethod == "POST" }.count, 1)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: harness.directory.path).isEmpty)
        }
        for status in [400, 401, 403, 404, 409, 429] {
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.directory) }
            ResetClientProtocol.configure(mode: .rejected(status))
            do {
                _ = try await harness.client.consume(for: account, accessToken: "fixture-token", grantID: "fixture_grant",
                    credentialBinding: ClaudeUsageResetClient.credentialBinding(for: "fixture-token"), confirmedGrant: fixtureConfirmedGrant)
                XCTFail("A rejected request cannot report success")
            } catch {
                // Claude accepted this sign-in for the reads just before, so 401 and 403 refuse the reset itself.
                XCTAssertEqual(error as? ClaudeUsageResetError, [401, 403].contains(status) ? .notPermitted(status) : .httpStatus(status))
            }
            XCTAssertEqual(ResetClientProtocol.requests.filter { $0.httpMethod == "POST" }.count, 1)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: harness.directory.path).isEmpty)
        }
    }

    func testExpiredIneligibleOrDifferentGrantNeverSendsPost() async throws {
        for mode in [ResetClientProtocol.Mode.ineligible, .expired, .success] {
            let harness = makeHarness()
            ResetClientProtocol.configure(mode: mode)
            do {
                _ = try await harness.client.consume(for: account, accessToken: "fixture-token",
                                                     grantID: mode == .success ? "different_grant" : "fixture_grant",
                                                     credentialBinding: ClaudeUsageResetClient.credentialBinding(for: "fixture-token"),
                                                     confirmedGrant: fixtureConfirmedGrant
                )
                XCTFail("A grant Claude does not list as usable must not be redeemed")
            } catch {
                XCTAssertEqual(error as? ClaudeUsageResetError, .unavailable)
            }
            XCTAssertFalse(ResetClientProtocol.requests.contains { $0.httpMethod == "POST" })
            try? FileManager.default.removeItem(at: harness.directory)
        }
    }

    private var fixtureFableGrant: ClaudeUsageResetGrant {
        ClaudeUsageResetGrant(id: "fixture_fable", title: "Claude usage reset", remainingCount: 1,
                             startsAt: Date(timeIntervalSince1970: 1_890_777_600),
                             expiresAt: Date(timeIntervalSince1970: 1_894_060_800),
                             clears: ["seven_day_overage_included"], isPaused: false, isUsableNow: true, requiresLimit: true)
    }

    private func consume(_ grant: ClaudeUsageResetGrant, with client: ClaudeUsageResetClient) async throws -> ClaudeUsageResetOutcome {
        try await client.consume(for: account, accessToken: "fixture-token", grantID: grant.id,
                                 credentialBinding: ClaudeUsageResetClient.credentialBinding(for: "fixture-token"),
                                 confirmedGrant: grant)
    }

    func testUsableUnselectedGrantPostsItsOwnIdentifier() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        ResetClientProtocol.configure(mode: .mixedGrants(postBody: #"{"result":"reset"}"#))
        let outcome = try await consume(fixtureFableGrant, with: harness.client)
        XCTAssertEqual(outcome, .reset)
        let posts = ResetClientProtocol.requests.filter { $0.httpMethod == "POST" }
        XCTAssertEqual(posts.count, 1)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(posts.first?.httpBody)) as? [String: String])
        XCTAssertEqual(body["grant_id"], "fixture_fable")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: harness.directory.path).isEmpty)

        // A listed grant Claude has not marked usable never reaches the network.
        ResetClientProtocol.configure(mode: .mixedGrants(postBody: #"{"result":"reset"}"#))
        let locked = ClaudeUsageResetGrant(id: "fixture_locked", title: "Claude usage reset", remainingCount: 1,
                                           startsAt: fixtureFableGrant.startsAt, expiresAt: fixtureFableGrant.expiresAt,
                                           clears: ["seven_day_overage_included"], isPaused: false, isUsableNow: false, requiresLimit: true)
        do {
            _ = try await consume(locked, with: harness.client)
            XCTFail("A grant Claude has not enabled must not be redeemed")
        } catch { XCTAssertEqual(error as? ClaudeUsageResetError, .unavailable) }
        XCTAssertFalse(ResetClientProtocol.requests.contains { $0.httpMethod == "POST" })
    }

    func testClaudeDecliningAnUnselectedGrantIsConfirmedAndLeavesOtherResetsUsable() async throws {
        for declined in [#"{"result":"unavailable","reason":"not_next_grant"}"#, #"{"result":"not_next_grant"}"#] {
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.directory) }
            ResetClientProtocol.configure(mode: .mixedGrants(postBody: declined))
            let outcome = try await consume(fixtureFableGrant, with: harness.client)
            XCTAssertEqual(outcome, .notNextGrant, declined)
            XCTAssertEqual(ResetClientProtocol.requests.filter { $0.httpMethod == "POST" }.count, 1, declined)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: harness.directory.path).isEmpty, declined)

            // The refusal is a confirmed answer: the reset Claude listed as next is not locked out by it.
            ResetClientProtocol.configure(mode: .mixedGrants(postBody: #"{"result":"reset"}"#))
            let next = try await consume(fixtureConfirmedGrant, with: harness.client)
            XCTAssertEqual(next, .reset, declined)
        }
    }

    func testOtherUnavailableAnswersStayUnconfirmed() async throws {
        for unconfirmed in [#"{"result":"unavailable"}"#, #"{"result":"unavailable","reason":"cooldown"}"#,
                            #"{"result":"unavailable","reason":7}"#,
        ] {
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.directory) }
            ResetClientProtocol.configure(mode: .mixedGrants(postBody: unconfirmed))
            do {
                _ = try await consume(fixtureFableGrant, with: harness.client)
                XCTFail("An answer this app cannot interpret must not be reported as confirmed")
            } catch { XCTAssertEqual(error as? ClaudeUsageResetError, .indeterminate, unconfirmed) }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: harness.directory.path).count, 1, unconfirmed)
        }
    }

    func testChangedCredentialAndMissingVerifiedIdentityNeverSendPost() async throws {
        for mode in [ResetClientProtocol.Mode.success, .missingIdentity, .changedIdentity] {
            let harness = makeHarness(token: mode == .success ? "replacement-token" : "fixture-token")
            ResetClientProtocol.configure(mode: mode)
            do {
                _ = try await harness.client.consume(for: account, accessToken: "fixture-token", grantID: "fixture_grant",
                                                          credentialBinding: ClaudeUsageResetClient.credentialBinding(for: "fixture-token"),
                                                          confirmedGrant: fixtureConfirmedGrant)
                XCTFail("Unverified identity or replaced credentials must prevent redemption")
            } catch {
                XCTAssertTrue([ClaudeUsageResetError.credentialChanged, .unavailable].contains(error as? ClaudeUsageResetError ?? .inProgress))
            }
            XCTAssertFalse(ResetClientProtocol.requests.contains { $0.httpMethod == "POST" })
            try? FileManager.default.removeItem(at: harness.directory)
        }
    }

    func testAmbiguousPostSurvivesClientRestartWithoutAutomaticReplay() async throws {
        for mode in [
            ResetClientProtocol.Mode.timeout, .serverError, .malformedSuccess, .rejected(408),
            .confirmed("unexpected"), .oversizedSuccess, .redirectSuccess, .actualRedirect,
        ] {
            let harness = makeHarness()
            ResetClientProtocol.configure(mode: mode)
            do {
                _ = try await harness.client.consume(for: account, accessToken: "fixture-token", grantID: "fixture_grant",
                                                          credentialBinding: ClaudeUsageResetClient.credentialBinding(for: "fixture-token"),
                                                          confirmedGrant: fixtureConfirmedGrant)
                XCTFail("An unconfirmed mutation must remain unknown")
            } catch {
                XCTAssertEqual(error as? ClaudeUsageResetError, .indeterminate)
            }
            XCTAssertEqual(ResetClientProtocol.requests.filter { $0.httpMethod == "POST" }.count, 1)
            let restarted = client(session: harness.session, directory: harness.directory, token: "rotated-token")
            ResetClientProtocol.configure(mode: .success)
            do {
                _ = try await restarted.consume(for: account, accessToken: "rotated-token", grantID: "fixture_grant",
                                                          credentialBinding: ClaudeUsageResetClient.credentialBinding(for: "rotated-token"),
                                                          confirmedGrant: fixtureConfirmedGrant)
                XCTFail("Token rotation cannot erase an ambiguous same-subject request")
            } catch { XCTAssertEqual(error as? ClaudeUsageResetError, .indeterminate) }
            XCTAssertFalse(ResetClientProtocol.requests.contains { $0.httpMethod == "POST" })
            ResetClientProtocol.configure(mode: .reconciled)
            let outcome = try await restarted.consume(for: account, accessToken: "rotated-token", grantID: "fixture_grant",
                                                          credentialBinding: ClaudeUsageResetClient.credentialBinding(for: "rotated-token"),
                                                          confirmedGrant: fixtureConfirmedGrant)
            XCTAssertEqual(outcome, .stateChanged)
            XCTAssertFalse(ResetClientProtocol.requests.contains { $0.httpMethod == "POST" })
            let receipts = try FileManager.default.contentsOfDirectory(atPath: harness.directory.path)
            XCTAssertTrue(receipts.isEmpty)
            try? FileManager.default.removeItem(at: harness.directory)
        }
    }

    func testCorruptReceiptAndMissingGrantNeverDiscardUnconfirmedMutation() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        ResetClientProtocol.configure(mode: .timeout)
        do {
            _ = try await harness.client.consume(for: account, accessToken: "fixture-token", grantID: "fixture_grant",
                credentialBinding: ClaudeUsageResetClient.credentialBinding(for: "fixture-token"), confirmedGrant: fixtureConfirmedGrant)
            XCTFail("Timeout must remain unknown")
        } catch { XCTAssertEqual(error as? ClaudeUsageResetError, .indeterminate) }
        let files = try FileManager.default.contentsOfDirectory(at: harness.directory, includingPropertiesForKeys: nil)
        let receiptURL = try XCTUnwrap(files.first)
        let receipt = try String(contentsOf: receiptURL, encoding: .utf8)
        XCTAssertFalse(receipt.contains("fixture_grant"))
        XCTAssertFalse(receipt.contains("fixture-token"))
        XCTAssertEqual(try harness.directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        for mode in [ResetClientProtocol.Mode.missingGrant, .success] {
            if mode == .success { try Data("corrupt".utf8).write(to: receiptURL, options: .atomic) }
            ResetClientProtocol.configure(mode: mode)
            do {
                _ = try await harness.client.consume(for: account, accessToken: "fixture-token", grantID: "fixture_grant",
                    credentialBinding: ClaudeUsageResetClient.credentialBinding(for: "fixture-token"), confirmedGrant: fixtureConfirmedGrant)
                XCTFail("Missing grant or unreadable receipt must not permit another POST")
            } catch { XCTAssertEqual(error as? ClaudeUsageResetError, .indeterminate) }
            XCTAssertFalse(ResetClientProtocol.requests.contains { $0.httpMethod == "POST" })
            XCTAssertTrue(FileManager.default.fileExists(atPath: receiptURL.path))
        }
    }

    func testConfirmationCredentialBindingIsRequiredBeforeAnyNetworkRequest() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        ResetClientProtocol.configure(mode: .success)
        do {
            _ = try await harness.client.consume(for: account, accessToken: "fixture-token", grantID: "fixture_grant",
                credentialBinding: ClaudeUsageResetClient.credentialBinding(for: "previous-account-token"), confirmedGrant: fixtureConfirmedGrant)
            XCTFail("A previous account's confirmation cannot spend the current account's reset")
        } catch { XCTAssertEqual(error as? ClaudeUsageResetError, .credentialChanged) }
        XCTAssertTrue(ResetClientProtocol.requests.isEmpty)
    }

    func testConcurrentConfirmationCannotSendDuplicatePost() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        ResetClientProtocol.configure(mode: .delayed)
        let account = self.account
        let binding = ClaudeUsageResetClient.credentialBinding(for: "fixture-token")
        let confirmedGrant = fixtureConfirmedGrant
        let first = Task {
            try await harness.client.consume(for: account, accessToken: "fixture-token", grantID: "fixture_grant",
                                             credentialBinding: binding, confirmedGrant: confirmedGrant)
        }
        for _ in 0..<100 where ResetClientProtocol.requests.isEmpty {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertFalse(ResetClientProtocol.requests.isEmpty)
        do {
            _ = try await harness.client.consume(for: account, accessToken: "fixture-token", grantID: "fixture_grant",
                                                credentialBinding: binding, confirmedGrant: fixtureConfirmedGrant)
            XCTFail("A simultaneous confirmation must not start another request")
        } catch { XCTAssertEqual(error as? ClaudeUsageResetError, .inProgress) }
        let outcome = try await first.value
        XCTAssertEqual(outcome, .reset)
        XCTAssertEqual(ResetClientProtocol.requests.filter { $0.httpMethod == "POST" }.count, 1)
    }

    func testUncertainReceiptDoesNotLeakAcrossVerifiedProviderAccounts() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        ResetClientProtocol.configure(mode: .timeout)
        let originalBinding = ClaudeUsageResetClient.credentialBinding(for: "fixture-token")
        do {
            _ = try await harness.client.consume(for: account, accessToken: "fixture-token", grantID: "fixture_grant",
                                                credentialBinding: originalBinding, confirmedGrant: fixtureConfirmedGrant)
            XCTFail("Original account mutation should remain unconfirmed")
        } catch { XCTAssertEqual(error as? ClaudeUsageResetError, .indeterminate) }
        let other = client(session: harness.session, directory: harness.directory, token: "other-token")
        let otherAccount = ProviderAccountConfiguration(id: "claude.other", providerID: .claude, authMethod: .cliToken)
        ResetClientProtocol.configure(mode: .otherIdentity)
        let outcome = try await other.consume(for: otherAccount, accessToken: "other-token", grantID: "fixture_grant",
                                             credentialBinding: ClaudeUsageResetClient.credentialBinding(for: "other-token"),
                                             confirmedGrant: fixtureConfirmedGrant)
        XCTAssertEqual(outcome, .reset)
        let post = try XCTUnwrap(ResetClientProtocol.requests.first { $0.httpMethod == "POST" })
        XCTAssertEqual(post.url?.path, "/api/organizations/00000000-0000-0000-0000-000000000004/reset_rate_limits")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: harness.directory.path).count, 1)
    }

    func testUnwritableReceiptStopsBeforeMutatingRequest() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        try Data("file, not directory".utf8).write(to: harness.directory)
        ResetClientProtocol.configure(mode: .success)
        do {
            _ = try await harness.client.consume(for: account, accessToken: "fixture-token", grantID: "fixture_grant",
                credentialBinding: ClaudeUsageResetClient.credentialBinding(for: "fixture-token"), confirmedGrant: fixtureConfirmedGrant)
            XCTFail("A mutation without a durable safety receipt must not start")
        } catch { XCTAssertEqual(error as? ClaudeUsageResetError, .storageUnavailable) }
        XCTAssertFalse(ResetClientProtocol.requests.contains { $0.httpMethod == "POST" })
    }

    private func makeHarness(token: String = "fixture-token") -> Harness {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeResetClientTests.\(UUID())")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ResetClientProtocol.self]
        let session = URLSession(configuration: configuration)
        return Harness(client: client(session: session, directory: directory, token: token), session: session, directory: directory)
    }

    private func client(session: URLSession, directory: URL, token: String) -> ClaudeUsageResetClient {
        let date = now
        return ClaudeUsageResetClient(session: session, secretStore: ResetClientSecrets(token: token), receiptDirectory: directory,
                                      baseURL: URL(string: "https://fixture.invalid")!, now: { date })
    }

    private struct Harness {
        let client: ClaudeUsageResetClient
        let session: URLSession
        let directory: URL
    }
}

private struct ResetClientSecrets: SecretStore {
    let token: String
    func readSecret(account _: String) throws -> String? { token }
    func saveSecret(_: String, account _: String) throws {}
    func deleteSecret(account _: String) throws {}
}

private class ResetClientProtocol: URLProtocol, @unchecked Sendable {
    enum Mode: Equatable, Sendable {
        case success, ineligible, expired, missingIdentity, timeout, reconciled
        case serverError, malformedSuccess, missingGrant, changedIdentity, delayed, otherIdentity
        case confirmed(String), rejected(Int), oversizedSuccess, redirectSuccess, actualRedirect
        /// A weekly reset Claude lists as next, a usable Fable reset and a Fable reset Claude has not enabled.
        case mixedGrants(postBody: String)
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var mode = Mode.success
    nonisolated(unsafe) private static var recorded: [URLRequest] = []
    static var requests: [URLRequest] { lock.withLock { recorded } }
    static func configure(mode: Mode) { lock.withLock { self.mode = mode; recorded = [] } }

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var recordedRequest = request
        if recordedRequest.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            recordedRequest.httpBody = data
        }
        let mode = Self.lock.withLock { Self.recorded.append(recordedRequest); return Self.mode }
        if mode == .delayed, request.url?.path == "/api/oauth/profile" {
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(100)) { [self] in respond(mode: mode) }
            return
        }
        respond(mode: mode)
    }

    private func respond(mode: Mode) {
        if mode == .actualRedirect, request.httpMethod == "POST", request.url?.path.hasSuffix("reset_rate_limits") == true {
            var redirected = request
            redirected.url = URL(string: "https://other.invalid/redirected-reset")!
            let response = HTTPURLResponse(url: request.url!, statusCode: 307, httpVersion: nil,
                                           headerFields: ["Location": redirected.url!.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
            return
        }
        if request.httpMethod == "POST", mode == .timeout {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            return
        }
        let body: String
        if request.url?.path == "/api/oauth/profile" {
            let profileCount = Self.requests.filter { $0.url?.path == "/api/oauth/profile" }.count
            let organization: String
            if mode == .otherIdentity {
                organization = "00000000-0000-0000-0000-000000000004"
            } else {
                organization = mode == .changedIdentity && profileCount > 1
                    ? "00000000-0000-0000-0000-000000000003" : "00000000-0000-0000-0000-000000000002"
            }
            let accountID = mode == .otherIdentity
                ? "00000000-0000-0000-0000-000000000003" : "00000000-0000-0000-0000-000000000001"
            body = mode == .missingIdentity ? "{}" : """
            {"account":{"uuid":"\(accountID)"},
             "organization":{"uuid":"\(organization)"}}
            """
        } else if request.httpMethod == "POST" {
            switch mode {
            case .confirmed(let result): body = "{\"result\":\"\(result)\"}"
            case .oversizedSuccess: body = "{\"result\":\"reset\",\"padding\":\"" + String(repeating: "x", count: 1_048_576) + "\"}"
            case .malformedSuccess: body = "{}"
            case .mixedGrants(let postBody): body = postBody
            default: body = #"{"result":"reset","cleared":["five_hour","seven_day"]}"#
            }
        } else if mode == .missingGrant {
            body = #"{"cedar_ember":{"eligible":true,"grants":[]}}"#
        } else if case .mixedGrants = mode {
            let window = #""starts_at":"2029-12-01T00:00:00Z","ends_at":"2030-01-08T00:00:00Z","paused":false"#
            body = """
            {"cedar_ember":{"eligible":true,"next_grant_id":"fixture_grant","grants":[
              {"id":"fixture_grant","resets_left":2,\(window),"clears":["five_hour","seven_day"],"usable_now":true},
              {"id":"fixture_fable","resets_left":1,\(window),"clears":["seven_day_overage_included"],"usable_now":true},
              {"id":"fixture_locked","resets_left":1,\(window),"clears":["seven_day_overage_included"],"usable_now":false}
            ]}}
            """
        } else {
            body = """
            {"cedar_ember":{"eligible":\(mode != .ineligible),"next_grant_id":"fixture_grant","grants":[{
              "id":"fixture_grant","resets_left":\(mode == .reconciled ? 1 : 2),
              "starts_at":"2029-12-01T00:00:00Z","ends_at":"\(mode == .expired ? "2029-12-31" : "2030-01-08")T00:00:00Z",
              "clears":["five_hour","seven_day"],"paused":false,"usable_now":true
            }]}}
            """
        }
        let status: Int
        if request.httpMethod == "POST", case .rejected(let value) = mode {
            status = value
        } else { status = request.httpMethod == "POST" && mode == .serverError ? 503 : 200 }
        let responseURL = request.httpMethod == "POST" && mode == .redirectSuccess
            ? URL(string: "https://other.invalid/reset_rate_limits")! : request.url!
        let response = HTTPURLResponse(url: responseURL, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
