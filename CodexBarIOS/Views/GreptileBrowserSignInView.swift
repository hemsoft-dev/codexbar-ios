import SwiftUI
import WebKit

@MainActor
final class GreptileBrowserSignInSession: NSObject, ObservableObject, Identifiable,
    WKNavigationDelegate, WKUIDelegate, WKHTTPCookieStoreObserver {
    let id = UUID()
    let webView: WKWebView
    @Published private(set) var host = "app.greptile.com"
    @Published private(set) var organizations: [GreptileOrganization] = []
    @Published private(set) var message: String?
    @Published private(set) var isVerifying = false
    @Published private(set) var isGoogleSignInUnavailable = false
    private let client: GreptileDashboardClient
    private var identity: GreptileDashboardIdentity?
    private var cookies: [GreptileSessionCookie] = []
    private var completion: ((Result<GreptileSessionCredentials, Error>) -> Void)?
    private var task: Task<Void, Never>?
    private var didStart = false
    private var navigationRevision = UUID()
    private var cookieInspectionPending = false
    private var observedSessionTokens: [String: String]?
    private var latestSessionCookies: [GreptileSessionCookie]?
    private let usesSignInFixture: Bool
    private var fixtureDocumentPending = false
    @Published private(set) var canGoBack = false

    init(
        client: GreptileDashboardClient = GreptileDashboardClient(session: GreptileDashboardClient.isolatedSession()),
        completion: @escaping (Result<GreptileSessionCredentials, Error>) -> Void
    ) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        self.client = client
        #if DEBUG
        usesSignInFixture = UITestFixtures.current != nil
            && ProcessInfo.processInfo.environment["CODEXBAR_UI_TEST_SCENARIO"]?.hasPrefix("greptile-") == true
        #else
        usesSignInFixture = false
        #endif
        self.completion = completion
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        configuration.websiteDataStore.httpCookieStore.add(self)
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        openUsage()
    }

    func openUsage() {
        resetInspection()
        message = nil
        #if DEBUG
        if usesSignInFixture {
            fixtureDocumentPending = true
            webView.loadHTMLString("""
                <html><head><meta name="viewport" content="width=device-width, initial-scale=1"></head>
                <body><p>Isolated Greptile sign-in fixture. No live account is accessed.</p>
                <p><a href="https://accounts.google.com/o/oauth2/v2/auth">Continue with Google</a></p>
                <p><a target="_blank" href="https://accounts.google.com/o/oauth2/v2/auth">Google popup</a></p></body></html>
                """, baseURL: URL(string: "https://app.greptile.com/"))
            return
        }
        #endif
        webView.load(URLRequest(url: URL(string: "https://app.greptile.com/-/settings/usage")!))
    }

    private func resetInspection() {
        navigationRevision = UUID()
        cookieInspectionPending = false
        observedSessionTokens = nil
        latestSessionCookies = nil
        message = nil
        task?.cancel()
        task = nil
        isVerifying = false
        isGoogleSignInUnavailable = false
        organizations = []
        identity = nil
        cookies = []
    }

    func goBack() {
        guard webView.canGoBack, !isVerifying else { return }
        resetInspection()
        webView.goBack()
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        resetInspection()
        canGoBack = webView.canGoBack
    }

    func cancel() { finish(.failure(GreptileSignInError.canceled)) }

    func invalidate() {
        completion = nil
        task?.cancel()
        task = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.configuration.websiteDataStore.httpCookieStore.remove(self)
        client.session.invalidateAndCancel()
        cookies = []
        identity = nil
    }

    private func finish(_ result: Result<GreptileSessionCredentials, Error>) {
        let callback = completion
        invalidate()
        callback?(result)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        canGoBack = webView.canGoBack
        host = webView.url?.host ?? "app.greptile.com"
        inspectSession()
    }

    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        let revision = navigationRevision
        cookieStore.getAllCookies { [weak self] values in
            self?.inspectCookieChange(values, revision: revision)
        }
    }

    private func inspectCookieChange(_ values: [HTTPCookie], revision: UUID) {
        guard completion != nil, navigationRevision == revision else { return }
        let latest = (try? GreptileSessionCredentials.sessionCookies(from: values)) ?? []
        latestSessionCookies = latest
        let tokens = Dictionary(uniqueKeysWithValues: latest.map { ($0.name, $0.value) })
        guard tokens != observedSessionTokens else {
            if !cookies.isEmpty { cookies = latest }
            return
        }
        observedSessionTokens = tokens
        if task != nil { cookieInspectionPending = true; return }
        identity = nil
        cookies = []
        if latest.isEmpty { organizations = [] }
        inspectSession()
    }

    private func finishVerification(revision: UUID) {
        guard navigationRevision == revision else { return }
        task = nil
        isVerifying = false
        guard cookieInspectionPending else { return }
        cookieInspectionPending = false
        identity = nil
        cookies = []
        inspectSession()
    }

    private func inspectSession() {
        guard completion != nil, task == nil, identity == nil, !webView.isLoading,
              webView.url?.scheme == "https", webView.url?.host == "app.greptile.com" else { return }
        let revision = navigationRevision
        let url = webView.url
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] values in
            guard let self, self.completion != nil, self.task == nil, self.navigationRevision == revision,
                  self.webView.url == url, !self.webView.isLoading else { return }
            guard let cookies = try? GreptileSessionCredentials.sessionCookies(from: values), !cookies.isEmpty else {
                self.organizations = []
                return
            }
            self.latestSessionCookies = cookies
            self.observedSessionTokens = Dictionary(uniqueKeysWithValues: cookies.map { ($0.name, $0.value) })
            self.inspect(cookies: cookies, revision: revision)
        }
    }

    private func inspect(cookies: [GreptileSessionCookie], revision: UUID) {
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.finishVerification(revision: revision) }
            self.isVerifying = true
            do {
                let identity = try await self.client.identity(cookies: cookies)
                guard !Task.isCancelled, self.completion != nil, self.navigationRevision == revision,
                      !self.cookieInspectionPending else { return }
                guard !identity.organizations.isEmpty else {
                    self.organizations = []
                    self.message = "Greptile returned no organizations. Finish account setup, then return to Usage."
                    return
                }
                self.cookies = self.latestSessionCookies ?? cookies
                self.identity = identity
                self.organizations = identity.organizations
                self.message = nil
            } catch {
                guard !Task.isCancelled, self.completion != nil, self.navigationRevision == revision,
                      !self.cookieInspectionPending else { return }
                self.organizations = []
                self.message = "Finish signing in, then choose Greptile Usage to retry verification."
            }
        }
    }

    func connect(_ organization: GreptileOrganization) {
        guard completion != nil, task == nil, let identity,
              identity.organizations.contains(organization) else { return }
        let credential = GreptileSessionCredentials(
            version: 1, subject: identity.greptileId, organization: organization, cookies: cookies
        )
        isVerifying = true
        let revision = navigationRevision
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.finishVerification(revision: revision) }
            do {
                try await self.client.verifyConnection(for: credential)
                guard !Task.isCancelled, self.completion != nil, !self.cookieInspectionPending else { return }
                self.finish(.success(GreptileSessionCredentials(
                    version: 1, subject: credential.subject, organization: credential.organization, cookies: self.cookies
                )))
            } catch {
                guard !Task.isCancelled, self.completion != nil else { return }
                self.message = (error as? GreptileSignInError ?? .unavailable).localizedDescription
            }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard organizations.isEmpty else { return .cancel }
        if blockGoogleSignIn(action.request.url) { return .cancel }
        #if DEBUG
        if usesSignInFixture {
            // Allow only the local document created by openUsage, then block external fixture traffic.
            guard fixtureDocumentPending, action.navigationType == .other,
                  ["about:blank", "https://app.greptile.com/"].contains(action.request.url?.absoluteString ?? "") else { return .cancel }
            fixtureDocumentPending = false
            return .allow
        }
        #endif
        guard let url = action.request.url, url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else {
            explainBlockedNavigation(action)
            return .cancel
        }
        return .allow
    }

    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard navigationAction.targetFrame == nil else { return nil }
        if blockGoogleSignIn(navigationAction.request.url) { return nil }
        #if DEBUG
        if usesSignInFixture { return nil }
        #endif
        if let url = navigationAction.request.url, url.scheme == "https", url.user == nil, url.password == nil,
           url.port == nil || url.port == 443 {
            webView.load(navigationAction.request)
        } else {
            explainBlockedNavigation(navigationAction)
        }
        return nil
    }

    private func blockGoogleSignIn(_ url: URL?) -> Bool {
        guard let url, GreptileSignInAvailability.isGoogleSignIn(url) else { return false }
        resetInspection()
        webView.stopLoading()
        isGoogleSignInUnavailable = true
        return true
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationFailed(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { navigationFailed(error) }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        message = "The sign-in page closed. Choose Greptile Usage to try again."
    }

    private func explainBlockedNavigation(_ action: WKNavigationAction) {
        guard action.targetFrame?.isMainFrame != false, action.request.url?.absoluteString != "about:blank" else { return }
        message = "This sign-in link could not be opened securely. Choose Greptile Usage to continue."
    }

    private func navigationFailed(_ error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        message = "Greptile sign-in could not load. Check the connection and try again."
    }
}

struct GreptileBrowserSignInView: View {
    @ObservedObject var session: GreptileBrowserSignInSession

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if session.isGoogleSignInUnavailable {
                    ContentUnavailableView {
                        Label("Google sign-in unavailable", systemImage: "person.crop.circle.badge.exclamationmark")
                    } description: {
                        Text(GreptileSignInAvailability.googleRecovery)
                    } actions: {
                        Button("Return to sign-in") { session.openUsage() }
                            .accessibilityIdentifier("greptile-return-to-sign-in")
                    }
                } else {
                    Text(GreptileSignInAvailability.googleNotice)
                        .font(.footnote).padding(.horizontal)
                    Text("Use an existing sign-in method for your Greptile account, then choose your organization.")
                        .font(.footnote).padding(.horizontal)
                }
                if let message = session.message {
                    Text(message).font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
                }
                if session.isVerifying { ProgressView("Verifying Greptile access…") }
                if session.isGoogleSignInUnavailable {
                    EmptyView()
                } else if session.organizations.isEmpty {
                    GreptileSignInWebView(session: session)
                } else {
                    List(session.organizations) { organization in
                        Button("Connect \(organization.name)") { session.connect(organization) }
                            .disabled(session.isVerifying)
                    }
                    Text("Connect to save your verified organization session securely for this account.")
                        .font(.footnote).padding()
                }
            }
            .navigationTitle(session.organizations.isEmpty ? session.host : "Choose Organization")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { session.cancel() } }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("Back", systemImage: "chevron.left") { session.goBack() }
                        .disabled(!session.canGoBack || session.isVerifying)
                    Spacer()
                    Button("Greptile Usage") { session.openUsage() }.disabled(session.isVerifying)
                }
            }
        }
        .interactiveDismissDisabled()
    }
}

private struct GreptileSignInWebView: UIViewRepresentable {
    let session: GreptileBrowserSignInSession
    func makeUIView(context: Context) -> WKWebView { session.start(); return session.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
