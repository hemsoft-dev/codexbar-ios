import Foundation
import XCTest
@testable import CodexBarIOS

/// Synthetic payloads in the shape public implementations report for `iguana_necktie`. No live account.
final class ClaudePromotionalCreditTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_534_400) // 2026-11-01T12:00:00Z
    private let formatter = UserFacingDateTimeFormatter(
        timeZone: TimeZone(identifier: "UTC")!, locale: Locale(identifier: "en_US")
    )
    private let expiry = Date(timeIntervalSince1970: 1_793_865_540) // 2026-11-05T07:59:00Z
    private let untouched = #"{"utilization":0.0,"resets_at":"2026-11-05T07:59:00+00:00","limit_dollars":100,"#
        + #""used_dollars":0.0,"remaining_dollars":100.0,"locked_reason":null}"#

    func testReportedCreditShowsBalanceAndExpiryApartFromPrepaidBalance() throws {
        let result = try XCTUnwrap(parse(credit: untouched))
        XCTAssertEqual(item(in: result)?.label, "Promotional credit")
        XCTAssertEqual(item(in: result)?.detail, "$100.00 of $100.00 remaining, expires \(formatter.dateAndTime(expiry))")
        XCTAssertTrue(formatter.dateAndTime(expiry).hasPrefix("Nov 5, 2026"), formatter.dateAndTime(expiry))
        // The prepaid balance and spend metrics are exactly what they are without the credit.
        let plain = try XCTUnwrap(parse(credit: nil))
        XCTAssertEqual(result.monetaryMetrics, plain.monetaryMetrics)
        XCTAssertEqual(result.monetaryMetrics.first { $0.kind == .balance }?.minorUnits, 2_500)
        XCTAssertEqual(otherContent(of: result), otherContent(of: plain))
        let section = try XCTUnwrap(result.cardInformationSections.first { $0.id == "claude.account-details" })
        XCTAssertEqual(section.items.map(\.id), ["claude.usage-credits", "claude.promotional-credit"])
    }

    func testPartialAmountsUseTheReportedRemainderOrDeriveItFromUse() throws {
        let cases = [
            (#"{"limit_dollars":100,"used_dollars":25,"remaining_dollars":75}"#, "$75.00 of $100.00 remaining"),
            (#"{"limit_dollars":200,"remaining_dollars":150.5}"#, "$150.50 of $200.00 remaining"),
            (#"{"limit_dollars":250,"used_dollars":250}"#, "$0.00 of $250.00 remaining"),
            (#"{"limit_dollars":100,"used_dollars":10,"remaining_dollars":80,"resets_at":null}"#, "$80.00 of $100.00 remaining"),
        ]
        for (credit, expected) in cases {
            XCTAssertEqual(item(in: try XCTUnwrap(parse(credit: credit)))?.detail, expected, credit)
        }
    }

    func testExpiredOrLockedCreditShowsNoUsableAmount() throws {
        let expired = untouched.replacingOccurrences(of: "2026-11-05T07:59:00+00:00", with: "2026-10-31T07:59:00.500Z")
        let expiredAt = Date(timeIntervalSince1970: 1_793_433_540.5) // 2026-10-31T07:59:00.5Z
        XCTAssertEqual(item(in: try XCTUnwrap(parse(credit: expired)))?.detail, "Expired \(formatter.dateAndTime(expiredAt))")
        let locked = untouched.replacingOccurrences(of: #""locked_reason":null"#, with: #""locked_reason":"plan_ineligible""#)
        XCTAssertEqual(item(in: try XCTUnwrap(parse(credit: locked)))?.detail, "Not available to use now")
        let blankReason = untouched.replacingOccurrences(of: #""locked_reason":null"#, with: #""locked_reason":"  ""#)
        XCTAssertEqual(item(in: try XCTUnwrap(parse(credit: blankReason)))?.detail,
                       "$100.00 of $100.00 remaining, expires \(formatter.dateAndTime(expiry))")
    }

    func testAbsentNullOrMalformedCreditLeavesTheResultUnchanged() throws {
        let plain = try XCTUnwrap(parse(credit: nil))
        XCTAssertNil(item(in: plain))
        let omitted = [
            "null", "[]", #""$100""#, "{}",
            #"{"utilization":0.0,"resets_at":null,"limit_dollars":null,"used_dollars":null,"remaining_dollars":null}"#,
            #"{"limit_dollars":0,"remaining_dollars":0}"#,
            #"{"limit_dollars":-5,"remaining_dollars":1}"#,
            #"{"limit_dollars":100}"#,
            #"{"limit_dollars":100,"utilization":10.0}"#,
            #"{"limit_dollars":"100","remaining_dollars":"100"}"#,
            #"{"limit_dollars":100,"remaining_dollars":101}"#,
            #"{"limit_dollars":100,"used_dollars":-1}"#,
            #"{"limit_dollars":100,"used_dollars":101}"#,
            #"{"limit_dollars":100,"remaining_dollars":true}"#,
            #"{"limit_dollars":100,"remaining_dollars":50,"resets_at":"soon"}"#,
            #"{"limit_dollars":100,"remaining_dollars":50,"resets_at":1793534400}"#,
            #"{"limit_dollars":100,"remaining_dollars":50,"locked_reason":7}"#,
            #"{"limit_dollars":5000000,"remaining_dollars":50}"#,
        ]
        for credit in omitted {
            let result = try XCTUnwrap(parse(credit: credit))
            XCTAssertEqual(otherContent(of: result), otherContent(of: plain), credit)
            XCTAssertEqual(result.cardInformationSections, plain.cardInformationSections, credit)
        }
    }

    func testCreditAloneStillProducesItsRowAndNothingElse() throws {
        let data = Data(#"{"iguana_necktie":\#(untouched)}"#.utf8)
        let result = try XCTUnwrap(ClaudeUsageParser.parse(data, subscriptionType: nil, fetchedAt: now, dateTimeFormatter: formatter))
        XCTAssertTrue(result.bars.isEmpty)
        XCTAssertTrue(result.monetaryMetrics.isEmpty)
        XCTAssertEqual(result.cardInformationSections.flatMap(\.items).map(\.id), ["claude.promotional-credit"])
        XCTAssertNil(ClaudeUsageParser.parse(Data(#"{"iguana_necktie":null}"#.utf8), subscriptionType: nil, fetchedAt: now))
    }

    func testCreditFollowsEachAccountResponseAndClearsWithAReplacedCredential() async throws {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [PromotionalCreditProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }
        let secrets = PromotionalCreditSecrets()
        let clock = now
        let provider = ClaudeUsageProvider(secretStore: secrets, session: session, now: { clock })
        let first = ProviderAccountConfiguration(id: "claude-promo-first", providerID: .claude, authMethod: .cliToken)
        let second = ProviderAccountConfiguration(id: "claude-promo-second", providerID: .claude, authMethod: .cliToken)

        PromotionalCreditProtocol.configure(status: 200, credit: untouched)
        let reported = try await provider.fetchUsage(for: first)
        XCTAssertNotNil(item(in: reported))
        // Another account's response without the block shows nothing from the first account.
        PromotionalCreditProtocol.configure(status: 200, credit: nil)
        let other = try await provider.fetchUsage(for: second)
        XCTAssertNil(item(in: other))
        // The same account drops the row as soon as Claude stops reporting it.
        let withdrawn = try await provider.fetchUsage(for: first)
        XCTAssertNil(item(in: withdrawn))
        // A replaced credential never inherits the earlier credential's retained details.
        PromotionalCreditProtocol.configure(status: 200, credit: untouched)
        let restored = try await provider.fetchUsage(for: first)
        XCTAssertNotNil(item(in: restored))
        secrets.replace(with: "replacement-token")
        PromotionalCreditProtocol.configure(status: 503, credit: nil)
        let replaced = try await provider.fetchUsage(for: first)
        XCTAssertNotNil(replaced.failureMessage)
        XCTAssertNil(item(in: replaced))
    }

    /// Everything the card shows other than its information sections. Bar identifiers are random per parse.
    private func otherContent(of result: ProviderUsageResult) -> [String] {
        result.bars.map { "\($0.stableKey ?? "")|\($0.label)|\($0.used)" }
            + result.monetaryMetrics.map { "\($0.id)|\($0.minorUnits)|\($0.detail ?? "")" }
            + result.usageMessages + ["--"] + result.dashboardUsageMessages
    }

    private func item(in result: ProviderUsageResult) -> ProviderCardInformationItem? {
        result.cardInformationSections.flatMap(\.items).first { $0.id == "claude.promotional-credit" }
    }

    private func parse(credit: String?) -> ProviderUsageResult? {
        let block = credit.map { #","iguana_necktie":\#($0)"# } ?? ""
        let payload = #"""
        {"limits":[{"kind":"session","percent":12,"resets_at":"2026-11-01T15:00:00Z","is_active":true}],
         "spend":{"used":{"amount_minor":500,"currency":"USD","exponent":2},
                  "limit":{"amount_minor":4000,"currency":"USD","exponent":2},
                  "enabled":true,"balance":{"amount_minor":2500,"currency":"USD","exponent":2}}
        """# + block + "}"
        return ClaudeUsageParser.parse(Data(payload.utf8), subscriptionType: "max", fetchedAt: now, dateTimeFormatter: formatter)
    }
}

private final class PromotionalCreditSecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var token = "fixture-token"
    func replace(with value: String) { lock.withLock { token = value } }
    func readSecret(account: String) throws -> String? { lock.withLock { token } }
    func saveSecret(_ secret: String, account: String) throws { replace(with: secret) }
    func deleteSecret(account: String) throws { replace(with: "") }
}

private class PromotionalCreditProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var status = 200
    nonisolated(unsafe) private static var credit: String?
    static func configure(status: Int, credit: String?) {
        lock.withLock { self.status = status; self.credit = credit }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let state = Self.lock.withLock { (Self.status, Self.credit) }
        let block = state.1.map { #","iguana_necktie":\#($0)"# } ?? ""
        let body = #"{"five_hour":{"utilization":42}"# + block + "}"
        let response = HTTPURLResponse(url: request.url!, statusCode: state.0, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
