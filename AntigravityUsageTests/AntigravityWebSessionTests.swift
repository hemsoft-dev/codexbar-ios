import Foundation
import XCTest
@testable import CodexBarIOS

final class AntigravityWebSessionTests: XCTestCase, @unchecked Sendable {
    // MARK: Saved marker

    func testSavedMarkerNamesAWebsiteDataStoreAndHoldsNoGoogleSecret() throws {
        let storeID = UUID()
        let marker = AntigravityWebSessionMarker(websiteDataStoreID: storeID, pagePath: "/u/2/remote/settings")
        let stored = marker.storedValue
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(stored.utf8)) as? [String: Any])

        XCTAssertEqual(Set(object.keys), ["pagePath", "version", "websiteDataStoreID"])
        XCTAssertEqual(AntigravityWebSessionMarker.parse(stored), marker)
        XCTAssertEqual(AntigravityWebSessionMarker.parse(stored)?.websiteDataStoreID, storeID)
        for text in [nil, "", "not json", #"{"version":2,"websiteDataStoreID":"\#(storeID.uuidString)"}"#, #"{"version":1}"#] {
            XCTAssertNil(AntigravityWebSessionMarker.parse(text))
        }
    }

    @MainActor
    func testCancelingAReadStopsItsPageLoadAndFreesTheQueue() async throws {
        let queue = AntigravityReadQueue()
        let started = expectation(description: "the load started")
        let abandoned = Task { @MainActor in
            try await queue.run {
                started.fulfill()
                try await Task.sleep(for: .seconds(60))
                return "finished"
            }
        }
        await fulfillment(of: [started], timeout: 5)
        let clock = ContinuousClock()
        let begin = clock.now
        abandoned.cancel()
        let outcome = await abandoned.result
        XCTAssertThrowsError(try outcome.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }

        // The next read doesn't wait for the abandoned one, and a read canceled before its turn never starts.
        let next = try await queue.run { "next" }
        XCTAssertEqual(next, "next")
        XCTAssertLessThan(clock.now - begin, .seconds(5))
        let neverStarted = Task { @MainActor in try await queue.run { XCTFail("a canceled read must not load a page") } }
        neverStarted.cancel()
        _ = await neverStarted.result
    }

    func testHiddenPageIsWideEnoughForGooglesDesktopLayout() {
        // Google's app uses its phone layout at 768 points or less. There Settings is a list, and the usage screen
        // that asks for quota never opens from its address. On the owner's phone a 390-point page got no quota.
        XCTAssertGreaterThan(AntigravityPagePolicy.hiddenPageSize.width, 1024)
        XCTAssertGreaterThan(AntigravityPagePolicy.hiddenPageSize.height, 600)
    }

    func testOnlyTheUsageScreenOrTheAppEntryIsRememberedAsAPagePath() {
        XCTAssertEqual(AntigravityPagePolicy.sanitizedPagePath("/remote/settings"), "/remote/settings")
        XCTAssertEqual(AntigravityPagePolicy.sanitizedPagePath("/u/1/remote/settings/"), "/u/1/remote/settings")
        XCTAssertEqual(AntigravityPagePolicy.sanitizedPagePath("/remote"), "/remote")
        XCTAssertEqual(AntigravityPagePolicy.sanitizedPagePath("/u/1/remote"), "/u/1/remote")
        XCTAssertNil(AntigravityPagePolicy.sanitizedPagePath("/remote/agents/new"))
        for path in [
            "/remote/c/3f2a-conversation", "remote/settings", "/remote/settings?x=1", "//evil.example/settings",
            "/remote/../settings", String(repeating: "/a", count: 40) + "/settings",
        ] {
            XCTAssertNil(AntigravityPagePolicy.sanitizedPagePath(path), path)
        }
        XCTAssertNil(AntigravityWebSessionMarker(websiteDataStoreID: UUID(), pagePath: "/remote/c/private-conversation").pagePath)
    }

    func testPagesOpenedForAReadAreGooglesAntigravityAppOnly() {
        let urls = AntigravityPagePolicy.pageURLs(pagePath: "/u/1/remote/settings").map(\.absoluteString)
        XCTAssertEqual(urls, [
            "https://antigravity.google.com/u/1/remote/settings?settingsScreen=Models",
            "https://antigravity.google.com/remote/settings?settingsScreen=Models",
            "https://antigravity.google.com/?settingsOpen=true&settingsScreen=Models",
        ])
        // On the owner's phone Google's app reported its address as the entry, `/remote`, while showing usage.
        XCTAssertEqual(AntigravityPagePolicy.pageURLs(pagePath: "/remote").map(\.absoluteString), [
            "https://antigravity.google.com/remote/settings?settingsScreen=Models",
            "https://antigravity.google.com/?settingsOpen=true&settingsScreen=Models",
        ])
        XCTAssertEqual(
            AntigravityPagePolicy.pageURLs(pagePath: "/u/1/remote").first?.absoluteString,
            "https://antigravity.google.com/u/1/remote/settings?settingsScreen=Models"
        )
        XCTAssertEqual(AntigravityPagePolicy.pageURLs(pagePath: nil).count, 2)
        XCTAssertEqual(AntigravityPagePolicy.pageURLs(pagePath: "https://evil.example/settings").count, 2)
        for url in AntigravityPagePolicy.pageURLs(pagePath: "/remote") {
            XCTAssertTrue(AntigravityPagePolicy.isAntigravityPage(url))
        }
    }

    // MARK: In-app browser policy

    func testBrowserOpensOnlySecureGooglePages() {
        for text in [
            "https://antigravity.google.com/remote", "https://accounts.google.com/v3/signin/identifier",
            "https://google.com/", "https://accounts.youtube.com/accounts/SetSID",
        ] {
            XCTAssertTrue(AntigravityPagePolicy.allowsNavigation(to: URL(string: text)), text)
        }
        for text in [
            "http://antigravity.google.com/", "https://antigravity.google.com.evil.example/",
                     "https://user:pass@accounts.google.com/", "https://accounts.google.com:8443/", "https://evilgoogle.com/",
            "https://www.youtube.com/", "javascript:alert(1)", "about:blank",
        ] {
            XCTAssertFalse(AntigravityPagePolicy.allowsNavigation(to: URL(string: text)), text)
        }
        XCTAssertFalse(AntigravityPagePolicy.allowsNavigation(to: nil))
    }

    func testSignInPagesAreToldApartFromSilentAccountRedirects() {
        for text in [
            "https://accounts.google.com/v3/signin/identifier?continue=x", "https://accounts.google.com/ServiceLogin",
            "https://accounts.google.com/signin/v2/challenge/pwd", "https://accounts.google.com/AccountChooser",
        ] {
            XCTAssertTrue(AntigravityPagePolicy.isSignInPage(URL(string: text)), text)
        }
        for text in [
            "https://accounts.google.com/CheckCookie?continue=x", "https://antigravity.google.com/signin",
            "https://accounts.google.com.evil.example/signin",
        ] {
            XCTAssertFalse(AntigravityPagePolicy.isSignInPage(URL(string: text)), text)
        }
    }

    func testOnlyTheTwoResponsesFromGooglesServiceAreAccepted() {
        let quota = "https://aicode.clients6.google.com/$rpc/google.gca.aicode.v1alpha.JetskiRemoteAgentProxyService/GetUserQuotaSummary"
        let profile = "https://aicode.googleapis.com/$rpc/google.gca.aicode.v1alpha.JetskiRemoteAgentProxyService/GetUserProfile"
        XCTAssertEqual(AntigravityPagePolicy.capturedResponse(urlString: quota, status: 200, body: "[1]"), .quota("[1]"))
        XCTAssertEqual(AntigravityPagePolicy.capturedResponse(urlString: profile + "?alt=x", status: 200, body: "[2]"), .profile("[2]"))

        let other = "https://aicode.clients6.google.com/$rpc/google.gca.aicode.v1alpha.JetskiRemoteAgentProxyService/ListConversations"
        let wrongHost = quota.replacingOccurrences(of: "aicode.clients6.google.com", with: "aicode.clients6.google.com.evil.example")
        let insecure = quota.replacingOccurrences(of: "https://", with: "http://")
        XCTAssertNil(AntigravityPagePolicy.capturedResponse(urlString: other, status: 200, body: "[1]"))
        XCTAssertNil(AntigravityPagePolicy.capturedResponse(urlString: wrongHost, status: 200, body: "[1]"))
        XCTAssertNil(AntigravityPagePolicy.capturedResponse(urlString: insecure, status: 200, body: "[1]"))
        XCTAssertNil(AntigravityPagePolicy.capturedResponse(urlString: quota, status: 401, body: "[1]"))
        XCTAssertNil(AntigravityPagePolicy.capturedResponse(urlString: quota, status: 200, body: ""))
        XCTAssertNil(AntigravityPagePolicy.capturedResponse(
            urlString: quota, status: 200, body: String(repeating: "x", count: 256 * 1024 + 1)
        ))
    }

    func testForwardedMessagesAreAcceptedOnlyFromTheMainFrameOfGooglesPage() {
        let quota = "https://aicode.clients6.google.com/$rpc/google.gca.aicode.v1alpha.JetskiRemoteAgentProxyService/GetUserQuotaSummary"
        let body: [String: Any] = ["url": quota, "status": 200, "body": "[1]", "path": "/remote/settings"]
        func message(
            name: String = "codexbarAntigravity", mainFrame: Bool = true, scheme: String = "https",
            host: String = "antigravity.google.com", body: Any = body
        ) -> AntigravityPagePolicy.ForwardedMessage {
            AntigravityPagePolicy.ForwardedMessage(name: name, isMainFrame: mainFrame, originScheme: scheme, originHost: host, body: body)
        }
        let accepted = AntigravityPagePolicy.capturedResponse(from: message())
        XCTAssertEqual(accepted?.response, .quota("[1]"))
        XCTAssertEqual(accepted?.pagePath, "/remote/settings")

        XCTAssertNil(AntigravityPagePolicy.capturedResponse(from: message(name: "other")))
        XCTAssertNil(AntigravityPagePolicy.capturedResponse(from: message(mainFrame: false)), "an embedded frame can't report usage")
        XCTAssertNil(AntigravityPagePolicy.capturedResponse(from: message(scheme: "http")))
        XCTAssertNil(AntigravityPagePolicy.capturedResponse(from: message(host: "accounts.google.com")))
        XCTAssertNil(AntigravityPagePolicy.capturedResponse(from: message(host: "antigravity.google.com.evil.example")))
        XCTAssertNil(AntigravityPagePolicy.capturedResponse(from: message(body: "text")))
        XCTAssertNil(AntigravityPagePolicy.capturedResponse(from: message(body: ["url": quota, "body": "[1]"])))
        XCTAssertNil(AntigravityPagePolicy.capturedResponse(from: message(body: ["url": quota, "status": 500, "body": "[1]"])))
        XCTAssertNil(AntigravityPagePolicy.capturedResponse(from: message(body: ["url": quota, "status": 200, "body": 7])))
    }

    func testGooglesSignInLinkMeansSignedOutAndIsTheOnlyLinkEverFollowed() throws {
        let link = "https://accounts.google.com/ServiceLogin?passive=1209600&continue=https://antigravity.google.com/remote"
        func message(_ body: [String: Any], host: String = "antigravity.google.com") -> AntigravityPagePolicy.ForwardedMessage {
            AntigravityPagePolicy.ForwardedMessage(
                name: "codexbarAntigravity", isMainFrame: true, originScheme: "https", originHost: host, body: body
            )
        }
        XCTAssertEqual(
            AntigravityPagePolicy.capturedResponse(from: message(["signInURL": link]))?.response,
            .signInLink(try XCTUnwrap(URL(string: link)))
        )
        for other in [
            "https://accounts.google.com/SignOutOptions", "https://accounts.google.com.evil.example/ServiceLogin",
            "http://accounts.google.com/ServiceLogin", "https://accounts.google.com/ServiceLoginAuth",
            "https://evil.example/?https://accounts.google.com/ServiceLogin", "javascript:alert(1)",
        ] {
            XCTAssertNil(AntigravityPagePolicy.capturedResponse(from: message(["signInURL": other])), other)
        }
        XCTAssertNil(AntigravityPagePolicy.capturedResponse(from: message(["signInURL": link], host: "evil.example")))
        XCTAssertTrue(AntigravityPagePolicy.captureScript.contains("a[href^=\"https://accounts.google.com/ServiceLogin\"]"))

        // A refresh that sees the link stops at once and asks for sign-in.
        let url = try XCTUnwrap(URL(string: link))
        var attempt = AntigravityReadAttempt()
        attempt.receive(.signInLink(url), pagePath: nil)
        XCTAssertTrue(attempt.needsSignIn)
        XCTAssertTrue(attempt.isSettled)
        // Once usage has been reported, a stray link changes nothing.
        var reading = AntigravityReadAttempt()
        reading.receive(.quota("[1]"), pagePath: "/remote/settings")
        reading.receive(.signInLink(url), pagePath: nil)
        XCTAssertFalse(reading.needsSignIn)
    }

    func testSignInBrowserFollowsGooglesLinkOnceAndReopensUsageAfterTheCustomerReturns() throws {
        let link = try XCTUnwrap(URL(string: "https://accounts.google.com/ServiceLogin?continue=https://antigravity.google.com/remote"))
        let signInForm = URL(string: "https://accounts.google.com/v3/signin/identifier")
        let app = URL(string: "https://antigravity.google.com/remote")
        var navigation = AntigravitySignInNavigation()

        XCTAssertFalse(navigation.shouldReopenUsagePage(afterFinishing: app, hasReading: false), "nothing to return from yet")
        XCTAssertEqual(navigation.signInLinkShown(link), link)
        XCTAssertNil(navigation.signInLinkShown(link), "the link is followed once; after that the next step is the customer's")
        XCTAssertFalse(navigation.shouldReopenUsagePage(afterFinishing: signInForm, hasReading: false))
        XCTAssertTrue(navigation.shouldReopenUsagePage(afterFinishing: app, hasReading: false))
        XCTAssertFalse(navigation.shouldReopenUsagePage(afterFinishing: app, hasReading: false), "the usage screen is reopened once")

        navigation.customerReopenedUsagePage()
        XCTAssertEqual(navigation.signInLinkShown(link), link)
        XCTAssertFalse(navigation.shouldReopenUsagePage(afterFinishing: app, hasReading: true), "usage already arrived")
    }

    func testSignInCountsOnlyAResponseCodexBarCanRead() {
        var progress = AntigravityCaptureProgress()
        XCTAssertNil(progress.capture)
        XCTAssertEqual(progress.receive(.profile(AntigravityFixtures.profileBody), pagePath: "/x", requiresReadableQuota: true), .profile)
        XCTAssertNil(progress.capture, "a plan alone is not a reading")
        XCTAssertEqual(progress.receive(.quota("<html></html>"), pagePath: "/remote/settings", requiresReadableQuota: true), .unreadableQuota)
        XCTAssertNil(progress.capture, "an unreadable response must not add an account")
        let empty = AntigravityFixtures.quotaBody(groups: [AntigravityFixtures.group("Gemini Models", [])])
        XCTAssertEqual(progress.receive(.quota(empty), pagePath: "/remote/settings", requiresReadableQuota: true), .unreadableQuota)

        let quota = AntigravityFixtures.screenshotQuotaBody
        XCTAssertEqual(progress.receive(.quota(quota), pagePath: "/remote/settings", requiresReadableQuota: true), .quota)
        XCTAssertEqual(progress.capture, AntigravityPageCapture(
            quotaBody: quota, profileBody: AntigravityFixtures.profileBody, pagePath: "/remote/settings"
        ))
        // A later unreadable response keeps the reading that was accepted.
        XCTAssertEqual(progress.receive(.quota("nope"), pagePath: "/elsewhere", requiresReadableQuota: true), .unreadableQuota)
        XCTAssertEqual(progress.capture?.quotaBody, quota)
        XCTAssertEqual(progress.capture?.pagePath, "/remote/settings")

        // A refresh hands every response to the parser, which reports an unreadable one as a failure.
        var refresh = AntigravityCaptureProgress()
        XCTAssertEqual(refresh.receive(.quota("nope"), pagePath: nil, requiresReadableQuota: false), .quota)
        XCTAssertEqual(refresh.capture?.quotaBody, "nope")
    }

    func testHiddenReadDecidesBetweenSignInNoUsageAndAFailedPage() {
        let page = URL(string: "https://antigravity.google.com/remote/settings")
        let signIn = URL(string: "https://accounts.google.com/v3/signin/identifier")

        var attempt = AntigravityReadAttempt()
        XCTAssertFalse(attempt.isSettled)
        attempt.pageFinished(at: page)
        XCTAssertFalse(attempt.isSettled, "the page loaded, but usage hasn't been reported yet")
        XCTAssertTrue(attempt.reachedAntigravity(at: page))
        attempt.progress.receive(.quota("[1]"), pagePath: "/remote/settings", requiresReadableQuota: false)
        XCTAssertTrue(attempt.isSettled)

        var expired = AntigravityReadAttempt()
        expired.pageFinished(at: signIn)
        XCTAssertTrue(expired.needsSignIn)
        XCTAssertTrue(expired.isSettled)
        XCTAssertFalse(expired.reachedAntigravity(at: signIn))

        var failed = AntigravityReadAttempt()
        failed.navigationFailed(code: NSURLErrorCancelled)
        XCTAssertFalse(failed.isSettled, "a redirect cancels the load it replaces")
        failed.navigationFailed(code: NSURLErrorNotConnectedToInternet)
        XCTAssertTrue(failed.navigationFailed)
        XCTAssertTrue(failed.isSettled)
        XCTAssertFalse(failed.reachedAntigravity(at: page))

        XCTAssertEqual(AntigravityReadAttempt.failure(reachedAntigravity: true), .noUsageReported)
        XCTAssertEqual(AntigravityReadAttempt.failure(reachedAntigravity: false), .pageFailed)
    }

    func testCaptureScriptForwardsTwoResponsesAndTouchesNoCredentials() throws {
        let script = AntigravityPagePolicy.captureScript
        XCTAssertTrue(script.contains("/GetUserQuotaSummary"))
        XCTAssertTrue(script.contains("/GetUserProfile"))
        XCTAssertTrue(script.contains("messageHandlers.codexbarAntigravity"))
        // The first thing it does is leave every page that isn't Google's Antigravity app, sign-in pages included.
        let guardLine = "if (window.location.hostname !== 'antigravity.google.com') { return; }"
        let guardIndex = try XCTUnwrap(script.range(of: guardLine)).lowerBound
        for hook in ["XMLHttpRequest.prototype.open =", "window.fetch =", "addEventListener", "postMessage"] {
            XCTAssertLessThan(guardIndex, try XCTUnwrap(script.range(of: hook)).lowerBound, hook)
        }
        // It reads responses the page requested. It never reads cookies or headers and never starts a request.
        for forbidden in [
            "document.cookie", "getResponseHeader", "setRequestHeader", "Authorization", "SAPISID",
            "new XMLHttpRequest", "localStorage", "sessionStorage", "indexedDB",
        ] {
            XCTAssertFalse(script.contains(forbidden), forbidden)
        }
        XCTAssertEqual(script.components(separatedBy: "originalFetch.apply(this, arguments)").count, 2)
    }

    func testNoticeSaysWhatTheCustomerAccepts() {
        let notice = AntigravityPagePolicy.noticeParagraphs.joined(separator: " ")
        XCTAssertTrue(notice.contains("experimental"))
        XCTAssertTrue(notice.contains("Google doesn't officially support third-party tools reading this page"))
        XCTAssertTrue(notice.contains("suspend an account"))
        XCTAssertTrue(notice.contains("keeps a Google web sign-in on this device"))
        XCTAssertTrue(notice.contains("sends it nowhere"))
        XCTAssertTrue(ProviderID.antigravityWeb.isExperimental)
        XCTAssertEqual(ProviderID.allCases.filter(\.isExperimental), [.antigravityWeb])
    }

    // MARK: Coexistence with the retired Google providers

    @MainActor
    func testNewIdentifiersNeverLookLikeTheRetiredProviders() {
        let account = AntigravityFixtures.configuration(id: UUID().uuidString)
        let firstAccount = ProviderAccountConfiguration.defaultConfiguration(for: .antigravityWeb)
        XCTAssertEqual(ProviderID.antigravityWeb.rawValue, "antigravityWeb")
        XCTAssertEqual(ProviderID.antigravityWeb.displayName, "Antigravity")
        XCTAssertFalse(RetiredProviderMigration.retiredProviderIDs.contains(ProviderID.antigravityWeb.rawValue))
        var identifiers = [
            ProviderID.antigravityWeb.rawValue,
            ProviderConfigurationStore.keychainAccount(for: account),
            ProviderConfigurationStore.keychainAccount(for: firstAccount),
            WatchSnapshotPublisher.snapshotAccountID(providerID: .antigravityWeb, configurationID: account.id),
        ]
        identifiers += ProviderMetricCatalog.definitions(for: .antigravityWeb).map(\.id)
        for identifier in identifiers {
            XCTAssertFalse(RetiredProviderMigration.isRetiredIdentifier(identifier), identifier)
            XCTAssertFalse(identifier.hasPrefix("provider.antigravity."), identifier)
        }
        XCTAssertEqual(ProviderMetricCatalog.definitions(for: .antigravityWeb).map(\.id), [
            "antigravityWeb.gemini-weekly", "antigravityWeb.gemini-5h", "antigravityWeb.3p-weekly", "antigravityWeb.3p-5h",
        ])
        XCTAssertNil(AntigravityQuotaParser.extraPoolKey("gemini"), "an extra pool can never become a retired dotted part")
    }

    func testLaunchCleanupRemovesRetiredGoogleAccountsAndKeepsTheNewProvider() throws {
        let suite = "antigravity-migration-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let marker = AntigravityWebSessionMarker(websiteDataStoreID: UUID())
        let records: [[String: Any]] = [
            ["id": "old-gemini", "providerID": "gemini", "authMethod": "browserSession"],
            ["id": "antigravity", "providerID": "antigravity", "authMethod": "cliToken"],
            ["id": "new-account", "providerID": "antigravityWeb", "authMethod": "browserSession", "accountLabel": "Work Google"],
            ["id": "antigravityWeb", "providerID": "antigravityWeb", "authMethod": "browserSession"],
        ]
        defaults.set(try JSONSerialization.data(withJSONObject: records), forKey: "providerConfigurations")
        let history: [[String: Any]] = [
            ["id": "1", "accountID": "old-gemini", "providerID": "gemini"],
            ["id": "2", "accountID": "new-account", "providerID": "antigravityWeb"],
        ]
        defaults.set(try JSONSerialization.data(withJSONObject: history), forKey: "usageHistorySnapshots")
        let secrets = AntigravityFixtureSecretStore([
            "providerAccount.old-gemini.credential": "old google session",
            "provider.gemini.old-gemini.coding": "old coding token",
            "provider.antigravity.credential": "old antigravity token",
            "providerAccount.new-account.credential": marker.storedValue,
            "provider.antigravityWeb.credential": marker.storedValue,
        ])

        for _ in 0..<3 {
            XCTAssertNil(RetiredProviderMigration.run(defaults: defaults, secretStore: secrets, configurationKey: "providerConfigurations"))
        }

        XCTAssertEqual(Set(try secrets.accountNames()), ["providerAccount.new-account.credential", "provider.antigravityWeb.credential"])
        let kept = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(defaults.data(forKey: "providerConfigurations"))) as? [[String: Any]]
        )
        XCTAssertEqual(kept.compactMap { $0["id"] as? String }.sorted(), ["antigravityWeb", "new-account"])
        let keptHistory = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(defaults.data(forKey: "usageHistorySnapshots"))) as? [[String: Any]]
        )
        XCTAssertEqual(keptHistory.compactMap { $0["accountID"] as? String }, ["new-account"])
    }

    @MainActor
    func testWatchSnapshotKeepsTheNewAntigravityAccountAndDropsTheRetiredOne() throws {
        let current = WatchAccountSnapshot(
            id: WatchSnapshotPublisher.snapshotAccountID(providerID: .antigravityWeb, configurationID: "new-account"),
            providerName: "Antigravity", accountLabel: "Work Google", fetchedAt: AntigravityFixtures.now, metrics: []
        )
        let retired = WatchAccountSnapshot(
            id: "antigravity.0123456789abcdef", providerName: "Antigravity", accountLabel: "Old", fetchedAt: AntigravityFixtures.now,
            metrics: []
        )
        let gemini = WatchAccountSnapshot(
            id: "gemini.0123456789abcdef", providerName: "Google Gemini", accountLabel: "Old", fetchedAt: AntigravityFixtures.now,
            metrics: []
        )
        let snapshot = WatchDashboardSnapshot(
            generatedAt: AntigravityFixtures.now, refreshIntervalSeconds: 900, accounts: [current, retired, gemini]
        )
        let decoded = try JSONDecoder().decode(WatchDashboardSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(decoded.accounts.map(\.id), [current.id])
    }

    // MARK: Website data

    func testWebsiteDataNoSavedAccountNamesIsRemoved() async {
        let kept = UUID()
        let orphans: Set<UUID> = [UUID(), UUID()]
        let data = AntigravityFixtureWebsiteData(stores: orphans.union([kept]))
        await AntigravityWebsiteDataCleanup.removeOrphanedStores(keeping: { [kept] }, data: data)
        let remaining = await data.stores
        let removed = await data.removed
        XCTAssertEqual(remaining, [kept])
        XCTAssertEqual(Set(removed), orphans)
    }

    func testStoreWhoseWebViewJustClosedIsRemovedOnTheSecondTry() async {
        let kept = UUID()
        let justClosed = UUID()
        let stuck = UUID()
        let data = AntigravityFixtureWebsiteData(stores: [kept, justClosed, stuck], busy: [justClosed: 1, stuck: 5])
        await AntigravityWebsiteDataCleanup.removeOrphanedStores(keeping: { [kept] }, data: data, retryDelay: .milliseconds(10))
        let remaining = await data.stores
        XCTAssertEqual(remaining, [kept, stuck], "one retry, then the launch sweep takes over")
    }

    func testCleanupStopsWhenItCanNoLongerTellWhichStoresAreSaved() async {
        let data = AntigravityFixtureWebsiteData(stores: [UUID(), UUID()])
        await AntigravityWebsiteDataCleanup.removeOrphanedStores(keeping: { nil }, data: data)
        let removed = await data.removed
        XCTAssertTrue(removed.isEmpty)
    }

    @MainActor
    func testCleanupRemovesNothingWhileASavedSignInCannotBeReadOrUnderstood() async throws {
        let suite = "antigravity-unreadable-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = AntigravityFixtureSecretStore()
        let signedIn = UUID()
        let orphan = UUID()
        let data = AntigravityFixtureWebsiteData(stores: [signedIn])
        let store = ProviderConfigurationStore(
            initialPlanAccess: AccountPlanAccess(hasProAccess: true, isResolved: true), defaults: defaults, secretStore: secrets,
            widgetSnapshotDefaults: nil, antigravityWebsiteData: data
        )
        let account = try XCTUnwrap(store.addAccount(for: .antigravityWeb))
        let signedOut = try XCTUnwrap(store.addAccount(for: .antigravityWeb))
        XCTAssertTrue(store.saveSecret(AntigravityWebSessionMarker(websiteDataStoreID: signedIn).storedValue, for: account))
        await store.antigravityWebsiteDataSweep?.value
        XCTAssertEqual(store.antigravityRetainedStoreIDs(), [signedIn], "an account without a saved sign-in keeps nothing")
        await data.add(orphan)

        // The Keychain can't be read: the signed-in account's store must not be mistaken for a leftover.
        secrets.failReads(true)
        XCTAssertNil(store.antigravityRetainedStoreIDs())
        store.removeUnusedAntigravityWebsiteData()
        await store.antigravityWebsiteDataSweep?.value
        var stores = await data.stores
        XCTAssertEqual(stores, [signedIn, orphan], "nothing is removed on a guess")

        // A saved value this version can't interpret is treated the same way.
        secrets.failReads(false)
        try secrets.saveSecret(#"{"version":99,"websiteDataStoreID":"\#(UUID().uuidString)"}"#,
                               account: ProviderConfigurationStore.keychainAccount(for: signedOut))
        XCTAssertNil(store.antigravityRetainedStoreIDs())
        store.removeUnusedAntigravityWebsiteData()
        await store.antigravityWebsiteDataSweep?.value
        stores = await data.stores
        XCTAssertEqual(stores, [signedIn, orphan])

        // Once every saved sign-in is readable again, the leftover goes and the signed-in store stays.
        try secrets.deleteSecret(account: ProviderConfigurationStore.keychainAccount(for: signedOut))
        store.removeUnusedAntigravityWebsiteData()
        await store.antigravityWebsiteDataSweep?.value
        stores = await data.stores
        XCTAssertEqual(stores, [signedIn])
    }

    @MainActor
    func testRemovingAnAccountDeletesItsWebsiteDataAndLeavesTheOtherAccountSignedIn() async throws {
        let suite = "antigravity-store-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = AntigravityFixtureSecretStore()
        let firstStore = UUID()
        let secondStore = UUID()
        let data = AntigravityFixtureWebsiteData(stores: [firstStore])
        let store = ProviderConfigurationStore(
            initialPlanAccess: AccountPlanAccess(hasProAccess: true, isResolved: true), defaults: defaults, secretStore: secrets,
            widgetSnapshotDefaults: nil, antigravityWebsiteData: data
        )
        let first = try XCTUnwrap(store.addAccount(for: .antigravityWeb))
        let second = try XCTUnwrap(store.addAccount(for: .antigravityWeb))
        XCTAssertFalse(store.isConfigured(first), "an account is configured only after a reading saved its sign-in")
        XCTAssertEqual(store.statusText(for: first), "Not configured - sign in with Google")
        // The second account's sign-in is open in the browser while the first one is saved.
        AntigravityPendingSignIns.begin(secondStore)
        await data.add(secondStore)
        XCTAssertTrue(store.saveSecret(AntigravityWebSessionMarker(websiteDataStoreID: firstStore).storedValue, for: first))
        await store.antigravityWebsiteDataSweep?.value
        var stores = await data.stores
        XCTAssertEqual(stores, [firstStore, secondStore], "an open sign-in keeps its website data")
        XCTAssertTrue(store.saveSecret(AntigravityWebSessionMarker(websiteDataStoreID: secondStore).storedValue, for: second))
        AntigravityPendingSignIns.end(secondStore)
        XCTAssertTrue(store.isConfigured(first))
        await store.antigravityWebsiteDataSweep?.value
        stores = await data.stores
        XCTAssertEqual(stores, [firstStore, secondStore])

        XCTAssertTrue(store.removeAccount(first))
        await store.antigravityWebsiteDataSweep?.value
        stores = await data.stores
        XCTAssertEqual(stores, [secondStore])
        XCTAssertEqual(store.antigravityWebSessionMarkers().map(\.websiteDataStoreID), [secondStore])

        // A new sign-in replaces the saved one, and the replaced website data goes with it.
        let replacement = UUID()
        await data.add(replacement)
        XCTAssertTrue(store.saveSecret(AntigravityWebSessionMarker(websiteDataStoreID: replacement).storedValue, for: second))
        await store.antigravityWebsiteDataSweep?.value
        stores = await data.stores
        XCTAssertEqual(stores, [replacement])
    }
}
