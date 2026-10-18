import Foundation

/// The phone's committed access decision, copied without extending its deadline.
struct SnapshotProAccess: Equatable {
    let isProLocked: Bool
    let proAccessEndsAt: Date?

    static let locked = Self(isProLocked: true, proAccessEndsAt: nil)

    init(isProLocked: Bool, proAccessEndsAt: Date?) {
        self.isProLocked = isProLocked
        self.proAccessEndsAt = proAccessEndsAt
    }

    @MainActor
    init(entitlement: ProEntitlement?) {
        isProLocked = !(entitlement?.hasAccess ?? false)
        proAccessEndsAt = entitlement?.value.proAccessEndsAt
    }
}
