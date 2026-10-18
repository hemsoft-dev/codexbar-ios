import Foundation

public enum ProPresentationOrigin: Equatable, Sendable {
    case limit
    case settings
}

/// A committed account-access decision. Pausing never changes the saved configuration.
public struct AccountPlanAccess: Equatable, Sendable {
    public static let unresolved = AccountPlanAccess(hasProAccess: false, isResolved: false)
    public static let unrestricted = AccountPlanAccess(hasProAccess: true, isResolved: true)
    public static let free = AccountPlanAccess(hasProAccess: false, isResolved: true)

    public let hasProAccess: Bool
    public let isResolved: Bool
    public let activeAccountID: String?
    public let pausedAccountIDs: Set<String>
    public let needsActiveAccountChoice: Bool

    public init(
        hasProAccess: Bool,
        isResolved: Bool = true,
        activeAccountID: String? = nil,
        pausedAccountIDs: Set<String> = [],
        needsActiveAccountChoice: Bool = false
    ) {
        self.hasProAccess = hasProAccess
        self.isResolved = isResolved
        self.activeAccountID = activeAccountID
        self.pausedAccountIDs = pausedAccountIDs
        self.needsActiveAccountChoice = needsActiveAccountChoice
    }

    public func isPaused(accountID: String) -> Bool {
        pausedAccountIDs.contains(accountID)
    }

    public func permitsRefresh(_ configuration: ProviderAccountConfiguration) -> Bool {
        guard configuration.isEnabled, configuration.providerID != .antigravity else { return false }
        return hasProAccess || (isResolved && activeAccountID == configuration.id)
    }

    public func permitsInsertion(
        for providerID: ProviderID,
        configurations: [ProviderAccountConfiguration]
    ) -> Bool {
        providerID == .antigravity || hasProAccess
            || !configurations.contains { $0.isEnabled && $0.providerID != .antigravity }
    }
}
