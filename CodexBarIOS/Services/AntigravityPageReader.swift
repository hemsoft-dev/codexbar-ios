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
    private let attemptTimeout: Duration
    private let profileGrace: Duration

    public init(attemptTimeout: Duration = .seconds(15), profileGrace: Duration = .milliseconds(1500)) {
        self.attemptTimeout = attemptTimeout
        self.profileGrace = profileGrace
    }

    public func read(marker: AntigravityWebSessionMarker) async throws -> AntigravityPageCapture {
        try await AntigravityReadQueue.shared.run { [attemptTimeout, profileGrace] in
            let load = AntigravityHiddenPageLoad(storeID: marker.websiteDataStoreID)
            defer { load.finish() }
            return try await load.read(
                urls: AntigravityPagePolicy.pageURLs(pagePath: marker.pagePath),
                attemptTimeout: attemptTimeout, profileGrace: profileGrace
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

    init(storeID: UUID) {
        webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 844),
            configuration: AntigravityCaptureReceiver.configuration(storeID: storeID, receiver: receiver)
        )
        super.init()
        webView.navigationDelegate = self
        receiver.onResponse = { [weak self] response, path in
            self?.attempt.receive(response, pagePath: path)
        }
        attachBehindApp()
    }

    /// A page outside any window may never run its scripts, so the web view sits invisibly behind the app.
    private func attachBehindApp() {
        #if canImport(UIKit)
        webView.alpha = 0
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

    func read(urls: [URL], attemptTimeout: Duration, profileGrace: Duration) async throws -> AntigravityPageCapture {
        var reachedAntigravity = false
        for url in urls {
            if let capture = try await open(url, attemptTimeout: attemptTimeout, profileGrace: profileGrace) { return capture }
            reachedAntigravity = reachedAntigravity || attempt.reachedAntigravity(at: webView.url)
        }
        throw AntigravityReadAttempt.failure(reachedAntigravity: reachedAntigravity)
    }

    /// Loads one page and returns what it reported, or nil when it reported no usage in time.
    private func open(_ url: URL, attemptTimeout: Duration, profileGrace: Duration) async throws -> AntigravityPageCapture? {
        attempt = AntigravityReadAttempt()
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
            AntigravityGateDiagnostics.record("read.no-quota failed=\(attempt.navigationFailed) at=\(place)")
            return nil
        }
        // Google's page asks for the plan in a separate request; give it a moment to arrive.
        try await wait(until: profileGrace) { $0.progress.profileBody != nil }
        let capture = attempt.progress.capture
        AntigravityGateDiagnostics.record("read.quota path=\(capture?.pagePath ?? "?") profile=\(capture?.profileBody != nil)")
        AntigravityGateDiagnostics.recordQuotaResponse(capture?.quotaBody ?? "")
        return capture
    }

    private func wait(until limit: Duration, for condition: (AntigravityReadAttempt) -> Bool) async throws {
        let deadline = ContinuousClock.now + limit
        while !condition(attempt), ContinuousClock.now < deadline {
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
