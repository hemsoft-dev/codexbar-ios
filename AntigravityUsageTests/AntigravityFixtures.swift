import Foundation
@testable import CodexBarIOS

/// Responses in the shape Google's page receives (`application/json+protobuf`: a message is an array indexed by
/// field number). Built from the field numbers in the page's public code, not captured from a live account; a
/// sanitized live capture replaces these once the owner's sign-in check produces one (#601).
enum AntigravityFixtures {
    static let now = Date(timeIntervalSince1970: 1_795_000_000)
    static let weeklyReset = now.addingTimeInterval(6 * 24 * 60 * 60 + 21 * 60 * 60)
    static let fiveHourReset = now.addingTimeInterval(2 * 60 * 60 + 15 * 60)

    static func bucket(
        _ id: String, name: String, window: String, remaining: Any? = nil, reset: Date? = nil,
        description: String? = nil, disabled: Any? = nil
    ) -> [Any] {
        var fields: [Any] = [id, name, window, remaining ?? NSNull(), NSNull()]
        fields.append(reset.map { [String(Int($0.timeIntervalSince1970)), 0] as [Any] } ?? NSNull())
        // Google describes a pool once it has been used; an untouched pool has no description.
        let used = (remaining as? Double).map { $0 < 1 } ?? false
        fields.append(description ?? (used ? "You have used some of this limit." : NSNull()) as Any)
        if let disabled { fields.append(disabled) }
        return fields
    }

    static func group(_ name: String, _ buckets: [[Any]]) -> [Any] {
        [buckets, name, "\(name) share one quota."]
    }

    static func quotaBody(groups: [[Any]], looseBuckets: [[Any]] = []) -> String {
        let response: [Any] = [[[looseBuckets, groups, "Model quota"] as [Any]] as [Any]]
        let data = (try? JSONSerialization.data(withJSONObject: response)) ?? Data()
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    /// The four pools on the owner's screenshot of November 23, 2026: 97% and 91% remaining for Gemini Models,
    /// 100% and 100% for Claude and GPT models with no refresh time.
    static var screenshotQuotaBody: String {
        quotaBody(groups: [
            group("Gemini Models", [
                bucket("gemini-weekly", name: "Weekly Limit Remaining", window: "weekly", remaining: 0.9725, reset: weeklyReset),
                bucket("gemini-5h", name: "Five Hour Limit Remaining", window: "5h", remaining: 0.91, reset: fiveHourReset),
            ]),
            group("Claude and GPT models", [
                bucket("3p-weekly", name: "Weekly Limit Remaining", window: "weekly", remaining: 1),
                bucket("3p-5h", name: "Five Hour Limit Remaining", window: "5h", remaining: 1),
            ]),
        ])
    }

    /// The response Google's page received on the owner's iPhone on November 24, 2026 at 19:26 UTC, as the debug
    /// build recorded it. It holds quota pools and Google's own descriptions, and nothing that identifies an account.
    static let liveCaptureDate = Date(timeIntervalSince1970: 1_795_548_397)
    static let liveQuotaBody = [
        #"[[[null,[[[["gemini-weekly","Weekly Limit Remaining","weekly",0.92771715,null,["1796073749"],"You have used so"#,
        #"me of your weekly limit, it will fully refresh in 6 days, 1 hour."],["gemini-5h","Five Hour Limit Remaining",""#,
        #"5h",1,null,["1795566397"]]],"Gemini Models","Models within this group: Gemini 4 Neon, Gemini 4 Carbon, Gemini "#,
        #"4 Argon, Gemini 4 Hydrogen, Gemini 3.8 Flash"],[[["3p-weekly","Weekly Limit Remaining","weekly",1,null,["17961"#,
        #"53197"]],["3p-5h","Five Hour Limit Remaining","5h",1,null,["1795566397"]]],"Claude and GPT models","Models wit"#,
        #"hin this group: Claude Opus 5.5, Claude Sonnet 5.5, GPT-OSS 120B"]],"Within each group, models share a weekly "#,
        #"limit and a 5-hour limit. Quota is consumed proportionally to the cost of the tokens. Thus, limits will last l"#,
        #"onger with shorter tasks or using more cost-effective models. The 5-hour limit smooths out aggregate demand to"#,
        #" fairly distribute global capacity across all users, while your weekly limit is tied directly to your individu"#,
        #"al tier."]]]"#,
    ].joined()

    static let profileBody = #"["person@example.com",["g1-ultra-tier","Google AI Ultra","You can upgrade.","https://one.google.com/ai","Upgrade"]]"#
    static let profileWithoutPlanBody = #"["person@example.com"]"#

    static func configuration(id: String = "antigravity-test-account") -> ProviderAccountConfiguration {
        ProviderAccountConfiguration(id: id, providerID: .antigravityWeb, accountLabel: "Work Google", authMethod: .browserSession)
    }
}

final class AntigravityFixtureSecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]
    private var readsFail = false

    /// Stands in for a Keychain that is locked or briefly unavailable.
    func failReads(_ fail: Bool) {
        lock.withLock { readsFail = fail }
    }

    init(_ values: [String: String] = [:]) {
        self.values = values
    }

    func accountNames() throws -> [String] {
        lock.withLock { Array(values.keys) }
    }

    func readSecret(account: String) throws -> String? {
        try lock.withLock {
            if readsFail { throw KeychainError.unhandledStatus(-25308) }
            return values[account]
        }
    }

    func saveSecret(_ secret: String, account: String) throws {
        lock.withLock { values[account] = secret }
    }

    func deleteSecret(account: String) throws {
        lock.withLock { values[account] = nil }
    }
}

actor AntigravityFixtureReader: AntigravityPageReading {
    private(set) var markers: [AntigravityWebSessionMarker] = []
    private var outcomes: [Result<AntigravityPageCapture, AntigravityReadError>]

    init(_ outcomes: [Result<AntigravityPageCapture, AntigravityReadError>]) {
        self.outcomes = outcomes
    }

    func read(marker: AntigravityWebSessionMarker) async throws -> AntigravityPageCapture {
        markers.append(marker)
        let outcome = outcomes.count > 1 ? outcomes.removeFirst() : outcomes[0]
        return try outcome.get()
    }
}

actor AntigravityFixtureWebsiteData: AntigravityWebsiteDataManaging {
    private(set) var stores: Set<UUID>
    private(set) var removed: [UUID] = []
    /// Stores WebKit would still refuse to remove, with how many attempts each one refuses.
    private var busy: [UUID: Int]

    init(stores: Set<UUID>, busy: [UUID: Int] = [:]) {
        self.stores = stores
        self.busy = busy
    }

    func add(_ id: UUID) {
        stores.insert(id)
    }

    func removeStore(id: UUID) async {
        if let refusals = busy[id], refusals > 0 {
            busy[id] = refusals - 1
            return
        }
        stores.remove(id)
        removed.append(id)
    }

    func storeIDs() async -> [UUID] {
        Array(stores)
    }
}
