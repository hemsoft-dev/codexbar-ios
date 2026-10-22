import Foundation

/// Applied only to verified AppTransaction evidence by ProEntitlementResolver.
struct ProOriginalPurchaserPolicy: Sendable {
    // FINAL: 2026-11-01T00:00:00Z, compiled into 2.0.0 build 5 (submitted 2026-10-22, #470, #515).
    // Customer copy names this instant. Never move it in a later update: that changes who qualifies.
    static let cutover = Date(timeIntervalSince1970: 1_793_491_200)

    var qualifies: @Sendable (ProAppPurchase) -> Bool = { Self.recognizes($0) }

    private static func recognizes(_ purchase: ProAppPurchase) -> Bool {
        guard purchase.isProduction, !purchase.revoked else { return false }
        let boughtBeforeCutover = purchase.originalPurchaseDate.timeIntervalSinceReferenceDate.isFinite
            && purchase.originalPurchaseDate < cutover
        return boughtBeforeCutover || isPaidVersion(purchase.originalVersion)
    }

    private static func isPaidVersion(_ version: String) -> Bool {
        // A plain integer is an iOS build, never a marketing major version. In particular,
        // an overflowing build must not fall back to a permissive marketing comparison.
        if isASCIIDigits(version) { return UInt64(version).map { $0 <= 4 } ?? false }

        // Accept only dotted numeric marketing versions (major.minor[.patch...]).
        // Reject suffixes, signs, spaces, empty components, non-ASCII digits and overflow.
        let components = version.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard components.count >= 2, components.allSatisfy(isASCIIDigits) else { return false }
        let numbers = components.compactMap(UInt64.init)
        guard numbers.count == components.count, let major = numbers.first else { return false }
        // All components are nonnegative, so a validated marketing version is below 2.0 iff its major is below 2.
        return major < 2
    }

    private static func isASCIIDigits(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) }
    }
}
