import SwiftUI
import WebKit

@MainActor
final class SubscriptionBillingSignInSession: NSObject, ObservableObject, Identifiable, WKNavigationDelegate, WKUIDelegate, WKHTTPCookieStoreObserver {
    let id = UUID()
    let webView: WKWebView
    let providerName: String
    let isSynthetic: Bool
    @Published private(set) var message: String?
    @Published private(set) var routeNotice: String?
    @Published private(set) var isVerifying = false
    @Published private(set) var host: String
    private let configuration: ProviderAccountConfiguration
    private let usageSecret: String
    private let client: SubscriptionBillingClient
    private var completion: ((Result<SubscriptionBillingSession, Error>) -> Void)?
    private var task: Task<Void, Never>?
    private var revision = UUID()
    private var started = false
    private var isResetting = false
    private var inspectionPending = false
    private var manualInspectionRequested = false
    private var discoveryTask: Task<Void, Never>?
    private var discoveryDeadline: ContinuousClock.Instant?
    private var nextAutomaticRead: ContinuousClock.Instant?
    private(set) var automaticCookieReadCount = 0
    private var attemptedCredentials = [[String: String]]()
    private var inFlightCredential: [String: String]?
    private var verificationID = UUID()

    init(configuration: ProviderAccountConfiguration, usageSecret: String, client: SubscriptionBillingClient? = nil,
         completion: @escaping (Result<SubscriptionBillingSession, Error>) -> Void) {
        self.configuration = configuration
        self.usageSecret = usageSecret
        #if DEBUG
        isSynthetic = UITestFixtures.current != nil
        self.client = client ?? (isSynthetic ? SubscriptionBillingClient(session: UITestSubscriptionBillingProtocol.session()) : SubscriptionBillingClient())
        #else
        isSynthetic = false
        self.client = client ?? SubscriptionBillingClient()
        #endif
        self.completion = completion
        providerName = configuration.providerID == .claude ? "Claude" : "Grok"
        host = SubscriptionBillingSession.host(configuration.providerID) ?? ""
        let webConfiguration = WKWebViewConfiguration()
        webConfiguration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: webConfiguration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.configuration.websiteDataStore.httpCookieStore.add(self)
    }

    func start() {
        guard !started else { return }
        started = true
        if isSynthetic {
            webView.loadHTMLString("""
            <html><meta name="viewport" content="width=device-width, initial-scale=1"><body>
            <p>Simulator billing fixture. No live account is accessed.</p>
            <a href="https://accounts.google.com/o/oauth2/auth" target="_blank">Continue with Google (synthetic)</a>
            </body></html>
            """,
                                   baseURL: URL(string: "https://\(host)/")!)
            return
        }
        let path = configuration.providerID == .claude ? "/settings/billing" : "/"
        let providerHost = SubscriptionBillingSession.host(configuration.providerID)!
        webView.load(URLRequest(url: URL(string: "https://\(providerHost)\(path)")!))
    }

    func chooseSyntheticAccount(matching: Bool) {
        guard isSynthetic, completion != nil, !isResetting else { return }
        let cookie = HTTPCookie(properties: [
            .name: configuration.providerID == .claude ? "sessionKey" : "billing-fixture",
            .value: matching ? "matching" : "wrong",
            .domain: SubscriptionBillingSession.host(configuration.providerID)!, .path: "/", .secure: "TRUE",
        ])!
        webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) { [weak self] in self?.verify() }
    }

    func invalidate() {
        completion = nil
        resetWork(clearCredentialHistory: true)
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.configuration.websiteDataStore.httpCookieStore.remove(self)
    }

    func cancel() {
        let callback = completion
        invalidate()
        callback?(.failure(SubscriptionBillingError.canceled))
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        // A provisional destination has not replaced the committed provider document.
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard webView === self.webView, completion != nil, !isResetting else { return }
        host = Self.canonicalHost(webView.url) ?? host
        routeNotice = nil
        beginDiscovery()
        inspectCookies(manual: false)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        beginDiscovery()
        inspectCookies(manual: false)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard completion != nil, !isResetting else { return }
        let failure = error as NSError
        guard !(failure.domain == NSURLErrorDomain && failure.code == NSURLErrorCancelled),
              !([WKError.errorDomain, "WebKitErrorDomain"].contains(failure.domain) && failure.code == 102) else { return }
        message = "The sign-in page could not load. Reload Sign-In when you have a connection."
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.webView(webView, didFail: navigation, withError: error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView, completion != nil, !isResetting else { return }
        resetWork()
        routeNotice = nil
        message = "The sign-in page closed unexpectedly. Reload Sign-In to continue; your private sign-in session is retained."
    }

    /// Reload is non-wiping. Only the explicit Start Over action deletes this sheet's private data.
    func reloadSignIn() {
        guard completion != nil, !isResetting else { return }
        resetWork()
        message = nil
        routeNotice = nil
        webView.stopLoading()
        started = false
        start()
    }

    func retrySignIn() {
        guard completion != nil, !isResetting else { return }
        resetWork(clearCredentialHistory: true)
        let attempt = revision
        isResetting = true
        isVerifying = true
        message = nil
        routeNotice = nil
        webView.stopLoading()
        let dataStore = webView.configuration.websiteDataStore
        dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { [weak self] in
            guard let self, self.completion != nil, self.revision == attempt else { return }
            self.isResetting = false
            self.isVerifying = false
            self.started = false
            self.start()
        }
    }

    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        inspectCookies(manual: false)
    }

    func verify() {
        inspectCookies(manual: true)
    }

    private var isOnProviderPage: Bool {
        Self.isSecure(webView.url) && Self.canonicalHost(webView.url) == SubscriptionBillingSession.host(configuration.providerID)
    }

    private func beginDiscovery() {
        guard completion != nil, !isResetting, isOnProviderPage, discoveryDeadline == nil else { return }
        discoveryDeadline = ContinuousClock.now.advanced(by: .seconds(15))
        discoveryTask = Task { [weak self] in
            for _ in 1...5 {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                guard !Task.isCancelled else { return }
                self?.inspectCookies(manual: false)
            }
        }
    }

    private func inspectCookies(manual: Bool) {
        guard completion != nil, !isResetting else { return }
        guard !webView.isLoading, isOnProviderPage else {
            if manual { message = "Finish signing in on the \(providerName) page, then Check Billing." }
            return
        }
        if inspectionPending {
            manualInspectionRequested = manualInspectionRequested || manual
            return
        }
        if !manual {
            guard let deadline = discoveryDeadline, ContinuousClock.now <= deadline,
                  automaticCookieReadCount < 6,
                  nextAutomaticRead.map({ ContinuousClock.now >= $0 }) ?? true else { return }
            automaticCookieReadCount += 1
            nextAutomaticRead = ContinuousClock.now.advanced(by: .seconds(2.5))
        }
        inspectionPending = true
        let attempt = revision
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] values in
            guard let self, self.completion != nil, self.revision == attempt else { return }
            self.inspectionPending = false
            let cookies = SubscriptionBillingSession.capture(values, provider: self.configuration.providerID)
            self.consider(cookies, manual: manual)
            if self.manualInspectionRequested {
                self.manualInspectionRequested = false
                self.inspectCookies(manual: true)
            }
        }
    }

    private func credential(_ cookies: [SubscriptionBillingSession.Cookie]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: cookies.map { ($0.name, $0.value) })
    }

    private func consider(_ cookies: [SubscriptionBillingSession.Cookie], manual: Bool) {
        let captured = credential(cookies)
        if captured.isEmpty {
            if inFlightCredential != nil { cancelVerification() }
            if manual { message = "No billing sign-in was found yet. Finish signing in with an existing method for this same \(providerName) account, then Check Billing." }
            return
        }
        guard captured != inFlightCredential else { return }
        guard manual || !attemptedCredentials.contains(captured) else { return }
        cancelVerification()
        if !attemptedCredentials.contains(captured) { attemptedCredentials.append(captured) }
        inFlightCredential = captured
        isVerifying = true
        message = nil
        let attempt = revision
        let verification = verificationID
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let billing = try await client.connect(configuration: configuration, usageSecret: usageSecret, cookies: cookies)
                guard !Task.isCancelled, revision == attempt, verificationID == verification, completion != nil else { return }
                // Cookie observer delivery is not guaranteed. Never save an unobserved removed/replaced credential.
                let current = await withCheckedContinuation { continuation in
                    webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
                }
                guard !Task.isCancelled, revision == attempt, verificationID == verification, completion != nil else { return }
                let latest = SubscriptionBillingSession.capture(current, provider: configuration.providerID)
                guard isOnProviderPage, credential(latest) == captured else {
                    cancelVerification()
                    message = "Billing sign-in changed during verification. Check Billing again for the current account."
                    return
                }
                let callback = completion
                routeNotice = nil
                invalidate()
                callback?(.success(billing))
            } catch {
                guard !Task.isCancelled, revision == attempt, verificationID == verification, completion != nil else { return }
                message = (error as? SubscriptionBillingError ?? .unavailable).localizedDescription
                cancelVerification()
            }
        }
    }

    private func cancelVerification() {
        verificationID = UUID()
        task?.cancel()
        task = nil
        inFlightCredential = nil
        isVerifying = false
    }

    private func resetWork(clearCredentialHistory: Bool = false) {
        revision = UUID()
        cancelVerification()
        discoveryTask?.cancel()
        discoveryTask = nil
        discoveryDeadline = nil
        nextAutomaticRead = nil
        automaticCookieReadCount = 0
        inspectionPending = false
        manualInspectionRequested = false
        if clearCredentialHistory { attemptedCredentials.removeAll() }
    }

    static func canonicalHost(_ url: URL?) -> String? {
        guard var host = url?.host?.lowercased() else { return nil }
        while host.hasSuffix(".") { host.removeLast() }
        return host
    }

    static func isSecure(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme?.lowercased() == "https" && url.user == nil && url.password == nil
            && (url.port == nil || url.port == 443) && canonicalHost(url)?.isEmpty == false
            && canonicalHost(url)?.hasPrefix(".") == false
    }

    private func deniesGoogle(_ url: URL?, visible: Bool) -> Bool {
        guard let host = Self.canonicalHost(url), host == "accounts.google.com" || host.hasSuffix(".accounts.google.com") else { return false }
        if visible {
            routeNotice = "Google sign-in cannot run in this embedded \(providerName) billing page. "
                + "Use another sign-in method only if you already use it for this same \(providerName) account. "
                + "Otherwise, this billing connection is unavailable. Your usage connection is unchanged."
        }
        return true
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        if deniesGoogle(navigationAction.request.url, visible: navigationAction.targetFrame?.isMainFrame != false) { return .cancel }
        guard Self.isSecure(navigationAction.request.url) else { return .cancel }
        return .allow
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard completion != nil, navigationAction.targetFrame == nil else { return nil }
        if deniesGoogle(navigationAction.request.url, visible: true) { return nil }
        if Self.isSecure(navigationAction.request.url) { webView.load(navigationAction.request) }
        return nil
    }
}

struct SubscriptionBillingSignInView: View {
    @ObservedObject var session: SubscriptionBillingSignInSession

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                VStack(spacing: 8) {
                    Text(session.host).font(.caption).foregroundStyle(.secondary)
                    ScrollView {
                        VStack(spacing: 12) {
                            if let notice = session.routeNotice {
                                Text(notice).font(.footnote).fixedSize(horizontal: false, vertical: true)
                                    .accessibilityIdentifier("subscription-billing-route-notice")
                            } else {
                                Text("Sign in with the same \(session.providerName) account you connected for usage. CodexBar checks briefly for sign-in, then returns after verifying billing. If it stays open, choose Check Billing.")
                                    .font(.footnote).fixedSize(horizontal: false, vertical: true)
                            }
                            if let message = session.message {
                                Text(message).font(.footnote).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if session.isSynthetic { syntheticActions }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal)
                    }
                    .accessibilityIdentifier("subscription-billing-information")
                    .frame(maxHeight: geometry.size.height * 0.5)
                    if session.isVerifying { ProgressView("Verifying billing account…") }
                    ViewThatFits(in: .horizontal) {
                        HStack { recoveryActions }
                        VStack { recoveryActions }
                    }
                    Text("Start Over clears only this private billing sign-in.").font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    BillingWebView(webView: session.webView).frame(minHeight: 120)
                }
            }
            .navigationTitle("\(session.providerName) billing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { session.cancel() } }
            }
            .task { session.start() }
            .onDisappear { session.invalidate() }
        }
        .interactiveDismissDisabled()
    }

    @ViewBuilder
    private var syntheticActions: some View {
        Button("Use another sample account") { session.chooseSyntheticAccount(matching: false) }
            .accessibilityIdentifier("subscription-billing-synthetic-wrong")
        Button("Use matching sample account") { session.chooseSyntheticAccount(matching: true) }
            .accessibilityIdentifier("subscription-billing-synthetic-match")
        Button("Simulate page interruption") { session.webViewWebContentProcessDidTerminate(session.webView) }
            .accessibilityIdentifier("subscription-billing-synthetic-termination")
    }

    @ViewBuilder
    private var recoveryActions: some View {
        Button("Check Billing") { session.verify() }
            .accessibilityIdentifier("subscription-billing-verify")
            .disabled(session.isVerifying)
        Button("Reload Sign-In") { session.reloadSignIn() }
        Button("Start Over") { session.retrySignIn() }
            .accessibilityHint("Clears only this private billing sign-in to choose the correct account")
    }
}

private struct BillingWebView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
