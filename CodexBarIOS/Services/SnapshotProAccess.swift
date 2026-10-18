import Foundation

/// The phone's committed access decision, copied without extending its deadline.
struct SnapshotProAccess: Equatable {
    let isProLocked: Bool
    let proAccessEndsAt: Date?
    let proAccessEffectiveAt: Date?
    let clockAnchor: ProEntitlementClockAnchor?
    let verificationGeneration: UUID?
    let environment: ProStoreEnvironment

    static let locked = Self(isProLocked: true, proAccessEndsAt: nil)

    init(
        isProLocked: Bool, proAccessEndsAt: Date?, proAccessEffectiveAt: Date? = nil,
        clockAnchor: ProEntitlementClockAnchor? = nil, verificationGeneration: UUID? = nil,
        environment: ProStoreEnvironment = .production
    ) {
        self.isProLocked = isProLocked
        self.proAccessEndsAt = proAccessEndsAt
        self.proAccessEffectiveAt = proAccessEffectiveAt
        self.clockAnchor = clockAnchor
        self.verificationGeneration = verificationGeneration
        self.environment = environment
    }

    @MainActor
    init(entitlement: ProEntitlement?) {
        self = entitlement?.snapshotAccess() ?? .locked
    }
}
