import SwiftUI
import WebKit

struct AntigravitySignInResult {
    let marker: AntigravityWebSessionMarker
    let capture: AntigravityPageCapture
    let readAt: Date
}

/// One Google sign-in for one Antigravity account, in a website data store no other account or feature uses.
/// Nothing loads from Google until the customer accepts the notice, and the sign-in counts only once Google's
/// page has reported usage that CodexBar can read.
@MainActor
final class AntigravitySignInSession: NSObject, ObservableObject, Identifiable, WKNavigationDelegate, WKUIDelegate {
    enum Stage: Equatable {
        case notice
        case browser
    }

    let id = UUID()
    let storeID = UUID()
    let isSynthetic: Bool
    @Published private(set) var stage = Stage.notice
    @Published private(set) var host = AntigravityPagePolicy.pageHost
    @Published private(set) var canGoBack = false
    @Published private(set) var message: String?
    private(set) var webView: WKWebView?
    private let receiver = AntigravityCaptureReceiver()
    private var completion: ((Result<AntigravitySignInResult, AntigravitySignInError>) -> Void)?
    private var progress = AntigravityCaptureProgress()
    private var navigation = AntigravitySignInNavigation()
    private var finishTask: Task<Void, Never>?

    init(isSynthetic: Bool = false, completion: @escaping (Result<AntigravitySignInResult, AntigravitySignInError>) -> Void) {
        self.isSynthetic = isSynthetic
        self.completion = completion
        super.init()
        AntigravityPendingSignIns.begin(storeID)
    }

    func acceptNotice() {
        guard stage == .notice, completion != nil else { return }
        stage = .browser
        guard !isSynthetic else { return }
        let webView = WKWebView(
            frame: .zero, configuration: AntigravityCaptureReceiver.configuration(storeID: storeID, receiver: receiver)
        )
        webView.navigationDelegate = self
        webView.uiDelegate = self
        receiver.onResponse = { [weak self] response, path in self?.receive(response, path: path) }
        self.webView = webView
        AntigravityGateDiagnostics.record("signin.begin")
        loadUsagePage()
    }

    /// The customer's "Models & Usage" button.
    func openUsagePage() {
        message = nil
        navigation.customerReopenedUsagePage()
        loadUsagePage()
    }

    private func loadUsagePage() {
        guard let url = AntigravityPagePolicy.pageURLs(pagePath: nil).first else { return }
        webView?.load(URLRequest(url: url))
    }

    func goBack() {
        webView?.goBack()
    }

    func cancel() {
        finish(.failure(.canceled))
    }

    /// Simulator fixtures only: stands in for Google's page reporting usage.
    func completeSynthetic(with capture: AntigravityPageCapture) {
        guard isSynthetic, stage == .browser else { return }
        if let profile = capture.profileBody {
            progress.receive(.profile(profile), pagePath: nil, requiresReadableQuota: true)
        }
        progress.receive(.quota(capture.quotaBody), pagePath: capture.pagePath, requiresReadableQuota: true)
        succeed()
    }

    func failSynthetic() {
        guard isSynthetic else { return }
        finish(.failure(.browserFailed))
    }

    /// One response Google's page received. Internal so tests can stand in for the page.
    func receive(_ response: AntigravityPagePolicy.CapturedResponse, path: String?) {
        guard completion != nil else { return }
        let event = progress.receive(response, pagePath: path, requiresReadableQuota: true)
        AntigravityGateDiagnostics.record("signin.response \(event) path=\(path ?? "?")")
        if case let .quota(body) = response { AntigravityGateDiagnostics.recordQuotaResponse(body) }
        if event == .unreadableQuota { message = AntigravityReadError.unreadableResponse.localizedDescription }
        if event == .quota { finishAfterProfileGrace() }
        if event == .signedOut, case let .signInLink(link) = response { followSignInLink(link) }
    }

    /// Opens Google's own Sign in link, as tapping it on the page would.
    private func followSignInLink(_ link: URL) {
        guard let url = navigation.signInLinkShown(link) else { return }
        webView?.load(URLRequest(url: url))
    }

    /// Google's page asks for the plan in a separate request; give it a moment to arrive.
    private func finishAfterProfileGrace() {
        guard finishTask == nil else { return }
        finishTask = Task { [weak self] in
            let deadline = ContinuousClock.now + .milliseconds(1500)
            while self?.progress.profileBody == nil, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            self?.succeed()
        }
    }

    private func succeed() {
        guard let capture = progress.capture else { return }
        finish(.success(AntigravitySignInResult(
            marker: AntigravityWebSessionMarker(websiteDataStoreID: storeID, pagePath: capture.pagePath), capture: capture,
            readAt: Date()
        )))
    }

    /// Ends the session exactly once. A sign-in that didn't succeed leaves no website data behind.
    func finish(_ result: Result<AntigravitySignInResult, AntigravitySignInError>) {
        guard let callback = completion else { return }
        completion = nil
        finishTask?.cancel()
        finishTask = nil
        receiver.onResponse = nil
        if let webView {
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
            webView.configuration.userContentController.removeAllScriptMessageHandlers()
        }
        webView = nil
        if case let .failure(error) = result {
            AntigravityGateDiagnostics.record("signin.ended \(error)")
            Self.discard(storeID: storeID)
        } else {
            AntigravityGateDiagnostics.record("signin.succeeded")
        }
        callback(result)
    }

    /// Releases a sign-in that was never saved and deletes the Google website data it created.
    static func discard(storeID: UUID) {
        AntigravityPendingSignIns.end(storeID)
        Task {
            // WebKit removes a store only after its web view is gone, so wait for the released view to unload.
            // The launch sweep removes anything this leaves behind.
            for delay in [1, 5] {
                try? await Task.sleep(for: .seconds(delay))
                await WebKitAntigravityWebsiteData().removeStore(id: storeID)
            }
        }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        host = webView.url?.host ?? AntigravityPagePolicy.pageHost
        canGoBack = webView.canGoBack
        AntigravityGateDiagnostics.record("signin.page \(AntigravityGateDiagnostics.describe(webView.url))")
        if navigation.shouldReopenUsagePage(afterFinishing: webView.url, hasReading: progress.capture != nil) { loadUsagePage() }
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard AntigravityPagePolicy.allowsNavigation(to: navigationAction.request.url) else {
            explainBlockedNavigation(navigationAction)
            return .cancel
        }
        return .allow
    }

    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard navigationAction.targetFrame == nil else { return nil }
        guard AntigravityPagePolicy.allowsNavigation(to: navigationAction.request.url) else {
            explainBlockedNavigation(navigationAction)
            return nil
        }
        webView.load(navigationAction.request)
        return nil
    }

    private func explainBlockedNavigation(_ action: WKNavigationAction) {
        guard action.targetFrame?.isMainFrame != false, action.request.url?.absoluteString != "about:blank" else { return }
        AntigravityGateDiagnostics.record("signin.blocked \(action.request.url?.host ?? "?")")
        message = "This sign-in window only opens secure Google pages. Go back, or choose Models & Usage to try again."
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleNavigationFailure(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleNavigationFailure(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(.failure(.browserFailed))
    }

    private func handleNavigationFailure(_ error: Error) {
        let code = (error as NSError).code
        // A canceled load is a redirect or a blocked page, and a frame interruption is a download; neither ends sign-in.
        guard code != NSURLErrorCancelled, code != 102 else { return }
        // WebKit's error text and failing URL are never shown; either can carry account details.
        AntigravityGateDiagnostics.record("signin.load-failed code=\(code)")
        finish(.failure(.browserFailed))
    }
}

struct AntigravitySignInView: View {
    @ObservedObject var session: AntigravitySignInSession

    var body: some View {
        NavigationStack {
            Group {
                switch session.stage {
                case .notice:
                    AntigravityNoticeView(accept: { session.acceptNotice() })
                case .browser:
                    browser
                }
            }
            .navigationTitle(session.stage == .notice ? "Antigravity" : session.host)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { session.cancel() }
                        .accessibilityIdentifier("antigravity-sign-in-cancel")
                }
            }
        }
        .interactiveDismissDisabled()
    }

    @ViewBuilder
    private var browser: some View {
        if session.isSynthetic {
            AntigravitySyntheticSignInView(session: session)
        } else {
            VStack(spacing: 0) {
                Text(
                    "Sign in on Google's website. CodexBar returns here once Google's page shows your usage. "
                        + "If it doesn't, open Settings on the page, then Models & Usage."
                )
                .font(.footnote)
                .padding()
                if let message = session.message {
                    Text(message).font(.footnote).foregroundStyle(.red).padding(.horizontal)
                }
                if let webView = session.webView {
                    AntigravityWebViewContainer(webView: webView)
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("Back", systemImage: "chevron.left") { session.goBack() }
                        .disabled(!session.canGoBack)
                    Spacer()
                    Button("Models & Usage") { session.openUsagePage() }
                }
            }
        }
    }
}

struct AntigravityNoticeView: View {
    let accept: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label("Experimental", systemImage: "flask")
                    .font(.headline)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("antigravity-notice-experimental")
                ForEach(AntigravityPagePolicy.noticeParagraphs, id: \.self) { paragraph in
                    Text(paragraph)
                }
                Text("CodexBar shows Gemini Models and Claude and GPT Models, each with a weekly and a five-hour limit.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Accept and Sign in with Google") { accept() }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("antigravity-notice-accept")
            }
            .padding()
        }
        .accessibilityIdentifier("antigravity-notice")
    }
}

private struct AntigravitySyntheticSignInView: View {
    let session: AntigravitySignInSession

    var body: some View {
        Form {
            Section {
                Text("Choose what Google's page reports for the sample account.")
                #if DEBUG
                Button("Page shows usage") { session.completeSynthetic(with: UITestAntigravityFixture.signInCapture) }
                    .accessibilityIdentifier("antigravity-synthetic-approve")
                #endif
                Button("Page fails to load") { session.failSynthetic() }
                    .accessibilityIdentifier("antigravity-synthetic-fail")
            } footer: {
                Text("Simulator fixture. No live Google account is accessed.")
            }
        }
    }
}

private struct AntigravityWebViewContainer: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView {
        webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

/// Saves a finished sign-in for an account, or throws it away.
@MainActor
enum AntigravityAccountConnector {
    static func makeSession(
        completion: @escaping (Result<AntigravitySignInResult, AntigravitySignInError>) -> Void
    ) -> AntigravitySignInSession {
        var isSynthetic = false
        #if DEBUG
        isSynthetic = UITestFixtures.current != nil
        #endif
        return AntigravitySignInSession(isSynthetic: isSynthetic, completion: completion)
    }

    /// Adds the account a finished sign-in belongs to. Returns the new account, or a message and no account.
    static func addAccount(
        for signIn: AntigravitySignInResult, flowState: inout AddAccountFlowState, in store: ProviderConfigurationStore
    ) async -> Result<ProviderAccountConfiguration, AntigravityAccountError> {
        guard let accountID = flowState.select(.antigravityWeb, configurationStore: store),
              let configuration = store.configuration(accountID: accountID) else {
            AntigravitySignInSession.discard(storeID: signIn.marker.websiteDataStoreID)
            return .failure(AntigravityAccountError(store.lastError))
        }
        if await save(signIn, for: configuration, in: store) { return .success(configuration) }
        let message = store.lastError
        store.removeAccount(configuration)
        flowState = AddAccountFlowState()
        return .failure(AntigravityAccountError(message))
    }

    /// Replaces an account's saved sign-in. On failure the saved one is left as it was.
    static func reconnect(
        _ outcome: Result<AntigravitySignInResult, AntigravitySignInError>, configuration: ProviderAccountConfiguration,
        in store: ProviderConfigurationStore
    ) async -> AntigravityAccountError? {
        switch outcome {
        case let .failure(error):
            return AntigravityAccountError(error.localizedDescription)
        case let .success(signIn):
            return await save(signIn, for: configuration, in: store) ? nil : AntigravityAccountError(store.lastError)
        }
    }

    /// The first refresh reuses the reading sign-in just watched instead of loading Google's page again.
    static func save(
        _ result: AntigravitySignInResult, for configuration: ProviderAccountConfiguration, in store: ProviderConfigurationStore
    ) async -> Bool {
        let storeID = result.marker.websiteDataStoreID
        await AntigravityReadCache.shared.prime(storeID: storeID, capture: result.capture, at: result.readAt)
        guard store.saveSecret(result.marker.storedValue, for: configuration) else {
            await AntigravityReadCache.shared.forget(storeID: storeID)
            AntigravitySignInSession.discard(storeID: storeID)
            return false
        }
        AntigravityPendingSignIns.end(storeID)
        return true
    }
}

struct AntigravityAccountError: Error, Equatable {
    let message: String

    init(_ message: String?) {
        self.message = message ?? AntigravitySignInError.storageFailed.localizedDescription
    }
}

extension Result where Failure == AntigravitySignInError {
    /// The customer-facing text for a sign-in that didn't finish, or nil when it did.
    var failureMessage: String? {
        if case let .failure(error) = self { return error.localizedDescription }
        return nil
    }
}
