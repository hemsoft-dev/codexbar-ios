import Foundation

public enum CodexBarDeepLink {
    public static let scheme = "codexbar"

    public static var proURL: URL? { URL(string: "codexbar://pro") }

    public static func isProURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return components.scheme?.lowercased() == scheme && components.host?.lowercased() == "pro"
            && (components.path.isEmpty || components.path == "/") && components.query == nil
    }

    private static let providerHost = "provider"
    private static let accountQueryName = "account"

    public static func providerURL(accountID: String) -> URL? {
        guard !accountID.isEmpty else {
            return nil
        }

        var components = URLComponents()
        components.scheme = scheme
        components.host = providerHost
        components.queryItems = [URLQueryItem(name: accountQueryName, value: accountID)]
        return components.url
    }

    public static func providerAccountID(from url: URL) -> String? {
        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.scheme?.lowercased() == scheme,
            components.host?.lowercased() == providerHost,
            components.path.isEmpty || components.path == "/"
        else {
            return nil
        }

        let accountItems = components.queryItems?.filter { $0.name == accountQueryName } ?? []
        guard accountItems.count == 1, let accountID = accountItems[0].value, !accountID.isEmpty else {
            return nil
        }

        return accountID
    }
}
