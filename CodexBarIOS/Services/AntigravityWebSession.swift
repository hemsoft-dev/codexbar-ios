import Foundation

/// What CodexBar saves for an Antigravity account. It names the account's private website data store and holds no
/// Google cookie, token or key: the Google sign-in itself stays inside that store.
public struct AntigravityWebSessionMarker: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var websiteDataStoreID: UUID
    /// Page path that reported quota during sign-in, so later reads open the same screen.
    public var pagePath: String?

    public init(websiteDataStoreID: UUID, pagePath: String? = nil) {
        self.version = Self.currentVersion
        self.websiteDataStoreID = websiteDataStoreID
        self.pagePath = pagePath.flatMap(AntigravityPagePolicy.sanitizedPagePath)
    }

    public var storedValue: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    public static func parse(_ stored: String?) -> AntigravityWebSessionMarker? {
        guard let data = stored?.data(using: .utf8),
              var marker = try? JSONDecoder().decode(AntigravityWebSessionMarker.self, from: data),
              marker.version == currentVersion else { return nil }
        marker.pagePath = marker.pagePath.flatMap(AntigravityPagePolicy.sanitizedPagePath)
        return marker
    }
}

public enum AntigravityReadError: LocalizedError, Equatable, Sendable {
    case notConfigured
    case signInRequired
    case noUsageReported
    case pageFailed
    case unreadableResponse

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Not configured - sign in with Google"
        case .signInRequired:
            "Google asked you to sign in again. Sign in to read Antigravity usage."
        case .noUsageReported:
            "Google's page didn't report usage for this account. An Antigravity account that only works through a "
                + "connected computer can't be read by CodexBar."
        case .pageFailed:
            "Google's Antigravity page didn't load. Check your connection and try again."
        case .unreadableResponse:
            "Google's Antigravity page reported usage in a form CodexBar doesn't recognize. An app update may be needed."
        }
    }
}

public enum AntigravitySignInError: LocalizedError, Equatable {
    case canceled
    case browserFailed
    case storageFailed

    public var errorDescription: String? {
        switch self {
        case .canceled:
            "Google sign-in canceled. No account was changed."
        case .browserFailed:
            "Google sign-in could not load. Check your connection and try again. No account was changed."
        case .storageFailed:
            "CodexBar could not save this sign-in. No account was changed."
        }
    }
}

/// Which pages the in-app browser may open, and which of the page's own responses CodexBar may read.
public enum AntigravityPagePolicy {
    public static let pageHost = "antigravity.google.com"
    static let defaultPagePath = "/remote/settings"
    static let modelsScreenQuery = "settingsScreen=Models"
    static let quotaMethodSuffix = "/google.gca.aicode.v1alpha.JetskiRemoteAgentProxyService/GetUserQuotaSummary"
    static let profileMethodSuffix = "/google.gca.aicode.v1alpha.JetskiRemoteAgentProxyService/GetUserProfile"
    static let responseHosts: Set<String> = ["aicode.clients6.google.com", "aicode.googleapis.com"]
    public static let messageHandlerName = "codexbarAntigravity"
    static let maximumBodyLength = 256 * 1024

    /// The notice a customer accepts before signing in. Also quoted in PRIVACY.md and ANTIGRAVITY-USAGE.md.
    public static let noticeParagraphs = [
        "Antigravity support is experimental. Google doesn't officially support third-party tools reading this page.",
        "Google's terms allow it to suspend an account that uses third-party software with Antigravity. "
            + "CodexBar only reads the usage that Google's own page shows you.",
        "CodexBar keeps a Google web sign-in on this device for this account and sends it nowhere. "
            + "Removing the account deletes it.",
    ]

    /// Pages opened to read usage, most likely first. `pagePath` is the one sign-in observed.
    public static func pageURLs(pagePath: String?) -> [URL] {
        var urls: [URL] = []
        for path in [pagePath.flatMap(sanitizedPagePath), defaultPagePath, "/"].compactMap({ $0 }) {
            var components = URLComponents()
            components.scheme = "https"
            components.host = pageHost
            components.path = path
            if path.hasSuffix("/settings") {
                components.percentEncodedQuery = modelsScreenQuery
            } else if path == "/" {
                components.percentEncodedQuery = "settingsOpen=true&" + modelsScreenQuery
            }
            if let url = components.url, !urls.contains(url) { urls.append(url) }
        }
        return urls
    }

    static func sanitizedPagePath(_ path: String) -> String? {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/-_")
        guard path.hasPrefix("/"), path.count <= 64, path.allSatisfy(allowed.contains), !path.contains("//") else { return nil }
        // Only the usage screen or the app's entry are worth reopening; a conversation path is never saved.
        let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        guard trimmed.hasSuffix("/settings") || trimmed == "/remote" || trimmed == "/" else { return nil }
        return trimmed
    }

    public static func allowsNavigation(to url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        return host == "google.com" || host.hasSuffix(".google.com") || host == "accounts.youtube.com"
    }

    public static func isAntigravityPage(_ url: URL?) -> Bool {
        allowsNavigation(to: url) && url?.host?.lowercased() == pageHost
    }

    /// A Google page that is asking for credentials, as opposed to a silent redirect through the account service.
    public static func isSignInPage(_ url: URL?) -> Bool {
        guard allowsNavigation(to: url), let url, url.host?.lowercased() == "accounts.google.com" else { return false }
        let path = url.path.lowercased()
        return ["/signin", "/v3/signin", "/servicelogin", "/interactivelogin", "/accountchooser", "/v2/identifier"]
            .contains { path.hasPrefix($0) }
    }

    public enum CapturedResponse: Equatable, Sendable {
        case quota(String)
        case profile(String)
        /// Google's page is showing its own Sign in link, so nobody is signed in.
        case signInLink(URL)
    }

    /// The Sign in link Google's account bar shows to a signed-out visitor.
    static let signInLinkPrefix = "https://accounts.google.com/ServiceLogin"

    static func signInLink(_ text: String) -> URL? {
        guard text.hasPrefix(signInLinkPrefix), text.utf8.count <= 2048, let url = URL(string: text),
              allowsNavigation(to: url), url.host?.lowercased() == "accounts.google.com", url.path == "/ServiceLogin"
        else { return nil }
        return url
    }

    /// Accepts only a successful response from Google's own service for the two methods CodexBar reads.
    public static func capturedResponse(urlString: String, status: Int, body: String) -> CapturedResponse? {
        guard (200..<300).contains(status), !body.isEmpty, body.utf8.count <= maximumBodyLength,
              let url = URL(string: urlString), url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), responseHosts.contains(host) else { return nil }
        if url.path.hasSuffix(quotaMethodSuffix) { return .quota(body) }
        if url.path.hasSuffix(profileMethodSuffix) { return .profile(body) }
        return nil
    }

    /// What the capture script posted, checked against where it came from. Anything but the main frame of
    /// Google's own page is dropped.
    public struct ForwardedMessage {
        public var name: String
        public var isMainFrame: Bool
        public var originScheme: String
        public var originHost: String
        public var body: Any

        public init(name: String, isMainFrame: Bool, originScheme: String, originHost: String, body: Any) {
            self.name = name
            self.isMainFrame = isMainFrame
            self.originScheme = originScheme
            self.originHost = originHost
            self.body = body
        }
    }

    public static func capturedResponse(from message: ForwardedMessage) -> (response: CapturedResponse, pagePath: String?)? {
        guard message.name == messageHandlerName, message.isMainFrame, message.originScheme == "https",
              message.originHost == pageHost, let body = message.body as? [String: Any] else { return nil }
        if let link = (body["signInURL"] as? String).flatMap(signInLink) { return (.signInLink(link), nil) }
        guard let url = body["url"] as? String, let text = body["body"] as? String,
              let status = (body["status"] as? NSNumber)?.intValue,
              let response = capturedResponse(urlString: url, status: status, body: text) else { return nil }
        return (response, body["path"] as? String)
    }

    /// Runs inside Google's page. It forwards the text of two responses the page itself requested, and the address of
    /// the Sign in link Google shows a signed-out visitor. Nothing else: no cookies, headers, request bodies or
    /// other responses. It sends no request of its own.
    public static let captureScript = """
    (function () {
      if (window.__codexbarAntigravityCapture) { return; }
      window.__codexbarAntigravityCapture = true;
      var suffixes = ['\(quotaMethodSuffix)', '\(profileMethodSuffix)'];
      var limit = \(maximumBodyLength);
      function matches(url) {
        var text = String(url || '').split('?')[0];
        for (var i = 0; i < suffixes.length; i++) {
          if (text.slice(-suffixes[i].length) === suffixes[i]) { return true; }
        }
        return false;
      }
      function post(url, status, body) {
        try {
          if (typeof body !== 'string' || body.length > limit) { return; }
          window.webkit.messageHandlers.\(messageHandlerName).postMessage({
            url: String(url), status: Number(status) || 0, body: body, path: String(window.location.pathname || '')
          });
        } catch (error) {}
      }
      function reportSignInLink() {
        try {
          var link = document.querySelector('a[href^="\(signInLinkPrefix)"]');
          if (link) { window.webkit.messageHandlers.\(messageHandlerName).postMessage({ signInURL: String(link.href) }); }
        } catch (error) {}
      }
      if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', reportSignInLink);
      } else {
        reportSignInLink();
      }
      window.addEventListener('load', reportSignInLink);
      var open = XMLHttpRequest.prototype.open;
      var send = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function (method, url) {
        try { this.__codexbarURL = new URL(String(url), window.location.href).href; } catch (error) { this.__codexbarURL = ''; }
        return open.apply(this, arguments);
      };
      XMLHttpRequest.prototype.send = function () {
        var request = this;
        if (matches(request.__codexbarURL)) {
          request.addEventListener('load', function () {
            try {
              if (request.responseType === '' || request.responseType === 'text') {
                post(request.__codexbarURL, request.status, request.responseText);
              }
            } catch (error) {}
          });
        }
        return send.apply(this, arguments);
      };
      var originalFetch = window.fetch;
      if (typeof originalFetch === 'function') {
        window.fetch = function (input) {
          var result = originalFetch.apply(this, arguments);
          try {
            var url = new URL(String(typeof input === 'string' ? input : (input && input.url) || ''), window.location.href).href;
            if (matches(url)) {
              result.then(function (response) {
                response.clone().text().then(function (text) { post(url, response.status, text); }).catch(function () {});
              }).catch(function () {});
            }
          } catch (error) {}
          return result;
        };
      }
    })();
    """
}

/// What one page load has reported so far. Shared by sign-in and by the hidden read.
public struct AntigravityCaptureProgress: Equatable, Sendable {
    public enum Event: Equatable, Sendable {
        case ignored
        case profile
        case quota
        /// The page reported usage in a form CodexBar can't read; the earlier state is kept.
        case unreadableQuota
        /// The page showed Google's Sign in link. Meaningful only while no usage has been reported.
        case signedOut
    }

    public private(set) var quotaBody: String?
    public private(set) var profileBody: String?
    public private(set) var pagePath: String?

    public init() {}

    public var capture: AntigravityPageCapture? {
        quotaBody.map { AntigravityPageCapture(quotaBody: $0, profileBody: profileBody, pagePath: pagePath) }
    }

    /// `requiresReadableQuota` is set during sign-in, where an unreadable response must not create an account.
    @discardableResult
    public mutating func receive(
        _ response: AntigravityPagePolicy.CapturedResponse, pagePath path: String?, requiresReadableQuota: Bool
    ) -> Event {
        switch response {
        case .signInLink:
            return quotaBody == nil ? .signedOut : .ignored
        case let .profile(body):
            profileBody = body
            return .profile
        case let .quota(body):
            if requiresReadableQuota && !Self.isReadable(body) { return .unreadableQuota }
            quotaBody = body
            pagePath = path
            return .quota
        }
    }

    static func isReadable(_ quotaBody: String) -> Bool {
        let placeholder = ProviderAccountConfiguration.defaultConfiguration(for: .antigravityWeb)
        let result = try? AntigravityQuotaParser.result(from: AntigravityPageCapture(quotaBody: quotaBody), configuration: placeholder)
        return result?.failureMessage == nil && result != nil
    }
}

/// How one hidden page load ended, decided from what the web view observed.
public struct AntigravityReadAttempt: Equatable, Sendable {
    public var progress = AntigravityCaptureProgress()
    public var needsSignIn = false
    public var navigationFailed = false

    public init() {}

    /// Nothing more to wait for on this page.
    public var isSettled: Bool {
        progress.quotaBody != nil || needsSignIn || navigationFailed
    }

    public mutating func pageFinished(at url: URL?) {
        if AntigravityPagePolicy.isSignInPage(url) { needsSignIn = true }
    }

    /// A refresh takes any response the page received; a Sign in link means the saved sign-in has ended.
    public mutating func receive(_ response: AntigravityPagePolicy.CapturedResponse, pagePath: String?) {
        if progress.receive(response, pagePath: pagePath, requiresReadableQuota: false) == .signedOut { needsSignIn = true }
    }

    public mutating func navigationFailed(code: Int) {
        if code != NSURLErrorCancelled { navigationFailed = true }
    }

    /// Whether this load got as far as Google's Antigravity app, as opposed to failing on the way.
    public func reachedAntigravity(at url: URL?) -> Bool {
        !navigationFailed && AntigravityPagePolicy.isAntigravityPage(url)
    }

    /// The error for a read whose pages reported no usage.
    public static func failure(reachedAntigravity: Bool) -> AntigravityReadError {
        reachedAntigravity ? .noUsageReported : .pageFailed
    }
}

/// Where the sign-in browser goes next. Google's page shows a signed-out visitor a Sign in link; the browser
/// follows it once, and reopens the usage screen when Google sends the customer back signed in.
public struct AntigravitySignInNavigation: Equatable, Sendable {
    private var followedSignInLink = false
    private var awaitsReturnFromGoogle = false

    public init() {}

    /// The link to open, or nil when it was already followed once and the next step is the customer's.
    public mutating func signInLinkShown(_ link: URL) -> URL? {
        guard !followedSignInLink else { return nil }
        followedSignInLink = true
        awaitsReturnFromGoogle = true
        return link
    }

    /// True when the customer has just come back from Google's sign-in and the usage screen should be reopened.
    public mutating func shouldReopenUsagePage(afterFinishing url: URL?, hasReading: Bool) -> Bool {
        guard awaitsReturnFromGoogle, AntigravityPagePolicy.isAntigravityPage(url) else { return false }
        awaitsReturnFromGoogle = false
        return !hasReading
    }

    /// The customer asked for the usage screen again, so Google's Sign in link may be followed once more.
    public mutating func customerReopenedUsagePage() {
        followedSignInLink = false
        awaitsReturnFromGoogle = false
    }
}
