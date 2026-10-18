import Combine
import Foundation

/// Acknowledgment is presentation state only. It can never grant or remove Pro access.
@MainActor
final class OriginalPurchaserNotice: ObservableObject {
    static let message = "Thanks for buying CodexBar. You have lifetime Pro: nothing to do."
    private static let acknowledgmentKey = "originalPurchaserThankYou2Acknowledged"

    @Published private(set) var isAcknowledged: Bool
    private let defaults: UserDefaults
    private let now: () -> Date

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
        isAcknowledged = defaults.bool(forKey: Self.acknowledgmentKey)
    }

    func shouldShow(value: ProEntitlementValue, isResolved: Bool) -> Bool {
        isResolved && !isAcknowledged && value.environment == .production
            && value.reason == .originalPurchaser && value.hasAccess(at: now())
    }

    /// Only the visible notice's acknowledgment button calls this, never launch or onAppear.
    func acknowledge() {
        defaults.set(true, forKey: Self.acknowledgmentKey)
        isAcknowledged = true
    }

    func familyMessage(locale: Locale = .autoupdatingCurrent, timeZone: TimeZone = .autoupdatingCurrent) -> String? {
        guard now() < ProOriginalPurchaserPolicy.cutover else { return nil }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEEE MMMM d yyyy jmm z")
        let deadline = formatter.string(from: ProOriginalPurchaserPolicy.cutover)
        return "Family members can get lifetime Pro too: have them install CodexBar from the App Store before \(deadline)."
    }
}
