import Foundation

/// The phone's committed access decision, copied without extending its deadline.
struct SnapshotProAccess: Equatable {
    let isProLocked: Bool
    let proAccessEndsAt: Date?
    let clockAnchor: ProEntitlementClockAnchor?
    let verificationGeneration: UUID?
    let environment: ProStoreEnvironment

    static let locked = Self(isProLocked: true, proAccessEndsAt: nil)

    init(
        isProLocked: Bool, proAccessEndsAt: Date?,
        clockAnchor: ProEntitlementClockAnchor? = nil, verificationGeneration: UUID? = nil,
        environment: ProStoreEnvironment = .production
    ) {
        self.isProLocked = isProLocked
        self.proAccessEndsAt = proAccessEndsAt
        self.clockAnchor = clockAnchor
        self.verificationGeneration = verificationGeneration
        self.environment = environment
    }

    @MainActor
    init(entitlement: ProEntitlement?) {
        isProLocked = !(entitlement?.hasAccess ?? false)
        proAccessEndsAt = entitlement?.value.proAccessEndsAt
        clockAnchor = entitlement?.value.clockAnchor
        verificationGeneration = entitlement?.widgetVerificationGeneration
        environment = entitlement?.value.environment ?? .production
    }
}
