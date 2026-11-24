import Foundation
import WebKit
#if canImport(UIKit)
import UIKit
#endif

/// Opens Google's Models & Usage page for one account and returns what the page fetched.
public protocol AntigravityPageReading: Sendable {
    func read(marker: AntigravityWebSessionMarker) async throws -> AntigravityPageCapture
}

/// Owns the per-account website data stores that hold each Google sign-in.
public protocol AntigravityWebsiteDataManaging: Sendable {
    func removeStore(id: UUID) async
    func storeIDs() async -> [UUID]
}

public struct WebKitAntigravityWebsiteData: AntigravityWebsiteDataManaging {
    public init() {}

    // WebKit's identified-store calls crash off the main thread, and before WebKit has started in this process.
    // Asking for the default store starts it.
    @MainActor
    public func removeStore(id: UUID) async {
        _ = WKWebsiteDataStore.default()
        // WebKit refuses while a web view still uses the store; the launch sweep removes it later.
        try? await WKWebsiteDataStore.remove(forIdentifier: id)
    }

    @MainActor
    public func storeIDs() async -> [UUID] {
        _ = WKWebsiteDataStore.default()
        return await WKWebsiteDataStore.allDataStoreIdentifiers
    }
}

public enum AntigravityWebsiteDataCleanup {
    /// Removes stores no saved account names: a canceled sign-in, a replaced sign-in or a removed account.
    /// Antigravity is the only feature that creates identified stores, so every unnamed one is its leftover.
    /// `keptStoreIDs` is asked again before each removal, so a sign-in saved meanwhile keeps its store; nil stops.
    /// WebKit refuses to remove a store whose web view closed a moment ago, so a store that survives the first
    /// pass gets one more try after `retryDelay`.
    public static func removeOrphanedStores(
        keeping keptStoreIDs: @Sendable () async -> Set<UUID>?,
        data: AntigravityWebsiteDataManaging = WebKitAntigravityWebsiteData(),
        retryDelay: Duration = .seconds(2)
    ) async {
        guard await removeOrphans(keeping: keptStoreIDs, data: data) else { return }
        try? await Task.sleep(for: retryDelay)
        _ = await removeOrphans(keeping: keptStoreIDs, data: data)
    }

    /// One pass. Returns true when a store that should be gone is still there.
    private static func removeOrphans(
        keeping keptStoreIDs: @Sendable () async -> Set<UUID>?, data: AntigravityWebsiteDataManaging
    ) async -> Bool {
        for id in await data.storeIDs() {
            guard let kept = await keptStoreIDs() else { return false }
            if !kept.contains(id) { await data.removeStore(id: id) }
        }
        guard let kept = await keptStoreIDs() else { return false }
        return await !Set(data.storeIDs()).isSubset(of: kept)
    }
}

/// Website data stores of sign-ins that are open but not saved yet. The cleanup never removes these.
@MainActor
public enum AntigravityPendingSignIns {
    public private(set) static var storeIDs: Set<UUID> = []

    public static func begin(_ storeID: UUID) {
        storeIDs.insert(storeID)
    }

    public static func end(_ storeID: UUID) {
        storeIDs.remove(storeID)
    }
}

/// Receives what the capture script forwards and hands on only what the page policy accepts.
@MainActor
final class AntigravityCaptureReceiver: NSObject, WKScriptMessageHandler {
    var onResponse: ((AntigravityPagePolicy.CapturedResponse, String?) -> Void)?

    static func configuration(storeID: UUID, receiver: AntigravityCaptureReceiver) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: storeID)
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(
            source: AntigravityPagePolicy.captureScript, injectionTime: .atDocumentStart, forMainFrameOnly: true
        ))
        controller.add(WeakReceiver(receiver), name: AntigravityPagePolicy.messageHandlerName)
        configuration.userContentController = controller
        return configuration
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let origin = message.frameInfo.securityOrigin
        let forwarded = AntigravityPagePolicy.ForwardedMessage(
            name: message.name, isMainFrame: message.frameInfo.isMainFrame, originScheme: origin.protocol,
            originHost: origin.host, body: message.body
        )
        guard let accepted = AntigravityPagePolicy.capturedResponse(from: forwarded) else { return }
        onResponse?(accepted.response, accepted.pagePath)
    }

    /// The content controller holds its handler strongly; this keeps the receiver's owner in charge of its lifetime.
    private final class WeakReceiver: NSObject, WKScriptMessageHandler {
        weak var receiver: AntigravityCaptureReceiver?

        init(_ receiver: AntigravityCaptureReceiver) {
            self.receiver = receiver
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            receiver?.userContentController(userContentController, didReceive: message)
        }
    }
}

/// Reads usage without showing the page. One read runs at a time.
public final class WebKitAntigravityPageReader: AntigravityPageReading {
    private let firstAttemptTimeout: Duration
    private let laterAttemptTimeout: Duration
    private let profileGrace: Duration

    /// Google's app takes several seconds to start in a new web view before it asks for quota. On the owner's
    /// phone the visible browser received quota 8 to 9 seconds after an already loaded page was reopened, and a
    /// 15-second limit from a cold start was never enough.
    public init(
        firstAttemptTimeout: Duration = .seconds(45), laterAttemptTimeout: Duration = .seconds(20),
        profileGrace: Duration = .milliseconds(1500)
    ) {
        self.firstAttemptTimeout = firstAttemptTimeout
        self.laterAttemptTimeout = laterAttemptTimeout
        self.profileGrace = profileGrace
    }

    public func read(marker: AntigravityWebSessionMarker) async throws -> AntigravityPageCapture {
        try await AntigravityReadQueue.shared.run { [firstAttemptTimeout, laterAttemptTimeout, profileGrace] in
            guard AntigravityHiddenPageLoad.isAppOnScreen else {
                AntigravityGateDiagnostics.record("read.skipped app-not-active")
                throw AntigravityReadError.appNotActive
            }
            let load = AntigravityHiddenPageLoad(storeID: marker.websiteDataStoreID)
            defer { load.finish() }
            return try await load.read(
                urls: AntigravityPagePolicy.pageURLs(pagePath: marker.pagePath),
                timeouts: (first: firstAttemptTimeout, later: laterAttemptTimeout), profileGrace: profileGrace
            )
        }
    }
}

@MainActor
private final class AntigravityReadQueue {
    static let shared = AntigravityReadQueue()
    private var tail: Task<Void, Never>?

    func run<Value: Sendable>(_ work: @escaping @MainActor () async throws -> Value) async throws -> Value {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            return try await work()
        }
        tail = Task { _ = await task.result }
        return try await task.value
    }
}

@MainActor
private final class AntigravityHiddenPageLoad: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private let receiver = AntigravityCaptureReceiver()
    private var attempt = AntigravityReadAttempt()
    private var started = SuspendingClock.now

    init(storeID: UUID) {
        webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 844),
            configuration: AntigravityCaptureReceiver.configuration(storeID: storeID, receiver: receiver)
        )
        super.init()
        webView.navigationDelegate = self
        receiver.onResponse = { [weak self] response, path in
            self?.attempt.receive(response, pagePath: path)
            self?.recordResponse(response)
        }
        attachBehindApp()
    }

    private func recordResponse(_ response: AntigravityPagePolicy.CapturedResponse) {
        if case .profile = response { AntigravityGateDiagnostics.record("read.profile t=\(elapsed)") }
        if case .signInLink = response { AntigravityGateDiagnostics.record("read.sign-in-link t=\(elapsed)") }
    }

    /// A page outside any window may never run its scripts, so the web view sits behind the app's own content,
    /// nearly transparent in case anything above it ever is.
    private func attachBehindApp() {
        #if canImport(UIKit)
        webView.alpha = 0.02
        webView.isUserInteractionEnabled = false
        webView.accessibilityElementsHidden = true
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow }
        window?.insertSubview(webView, at: 0)
        #endif
    }

    func finish() {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        receiver.onResponse = nil
        #if canImport(UIKit)
        webView.removeFromSuperview()
        #endif
    }

    /// A hidden page is only read while CodexBar is on screen. In the background iOS suspends the app mid-load.
    /// At launch, and during any brief interruption, the app is inactive but still on screen, and that counts.
    static var isAppOnScreen: Bool {
        #if canImport(UIKit)
        UIApplication.shared.applicationState != .background
        #else
        true
        #endif
    }

    func read(
        urls: [URL], timeouts: (first: Duration, later: Duration), profileGrace: Duration
    ) async throws -> AntigravityPageCapture {
        var reachedAntigravity = false
        for (index, url) in urls.enumerated() {
            let limit = index == 0 ? timeouts.first : timeouts.later
            if let capture = try await open(url, attemptTimeout: limit, profileGrace: profileGrace) { return capture }
            reachedAntigravity = reachedAntigravity || attempt.reachedAntigravity(at: webView.url)
        }
        guard Self.isAppOnScreen else { throw AntigravityReadError.appNotActive }
        throw AntigravityReadAttempt.failure(reachedAntigravity: reachedAntigravity)
    }

    /// Loads one page and returns what it reported, or nil when it reported no usage in time.
    private func open(_ url: URL, attemptTimeout: Duration, profileGrace: Duration) async throws -> AntigravityPageCapture? {
        attempt = AntigravityReadAttempt()
        started = SuspendingClock.now
        AntigravityGateDiagnostics.record("read.open \(AntigravityGateDiagnostics.describe(url))")
        webView.load(URLRequest(url: url))
        try await wait(until: attemptTimeout) { $0.isSettled }
        attempt.pageFinished(at: webView.url)
        if attempt.needsSignIn {
            AntigravityGateDiagnostics.record("read.sign-in-required \(AntigravityGateDiagnostics.describe(webView.url))")
            throw AntigravityReadError.signInRequired
        }
        guard attempt.progress.quotaBody != nil else {
            let place = AntigravityGateDiagnostics.describe(webView.url)
            let profile = attempt.progress.profileBody != nil
            AntigravityGateDiagnostics.record(
                "read.no-quota t=\(elapsed) failed=\(attempt.navigationFailed) profile=\(profile) at=\(place)"
            )
            return nil
        }
        // Google's page asks for the plan in a separate request; give it a moment to arrive.
        try await wait(until: profileGrace) { $0.progress.profileBody != nil }
        let capture = attempt.progress.capture
        AntigravityGateDiagnostics.record("read.quota t=\(elapsed) path=\(capture?.pagePath ?? "?") profile=\(capture?.profileBody != nil)")
        AntigravityGateDiagnostics.recordQuotaResponse(capture?.quotaBody ?? "")
        return capture
    }

    /// Whole seconds since this page was opened, not counting time the app spent suspended.
    private var elapsed: Int {
        Int((SuspendingClock.now - started).components.seconds)
    }

    /// Waits on a clock that stops while iOS has the app suspended, so a suspended load isn't mistaken for a slow one.
    private func wait(until limit: Duration, for condition: (AntigravityReadAttempt) -> Bool) async throws {
        let deadline = SuspendingClock.now + limit
        while !condition(attempt), SuspendingClock.now < deadline {
            try await Task.sleep(for: .milliseconds(150))
        }
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        AntigravityPagePolicy.allowsNavigation(to: navigationAction.request.url) ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        attempt.pageFinished(at: webView.url)
        AntigravityGateDiagnostics.record("read.finished t=\(elapsed) at=\(AntigravityGateDiagnostics.describe(webView.url))")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        attempt.navigationFailed(code: (error as NSError).code)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        attempt.navigationFailed(code: (error as NSError).code)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        attempt.navigationFailed = true
    }
}
