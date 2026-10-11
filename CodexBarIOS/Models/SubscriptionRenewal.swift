import Foundation

/// A billing observation, never a usage-window reset. Dates remain bound to one account.
public struct SubscriptionRenewal: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case renewing
        case nonRenewing
        case notApplicable
    }

    public let accountID: String
    public let providerID: ProviderID
    public let state: State
    public let date: Date?
    public let isDateOnly: Bool
    public let observedAt: Date

    public init(accountID: String, providerID: ProviderID, state: State, date: Date?,
                isDateOnly: Bool = false, observedAt: Date) {
        self.accountID = accountID
        self.providerID = providerID
        self.state = state
        self.date = date
        self.isDateOnly = isDateOnly
        self.observedAt = observedAt
    }

    public func isFresh(at now: Date) -> Bool {
        let age = now.timeIntervalSince(observedAt)
        return age >= -60 && age <= 86_400
    }

    /// Date-only values represent a civil date, without inventing a midnight charge time.
    private func localDate(in calendar: Calendar) -> Date? {
        guard let date else { return nil }
        guard isDateOnly else { return date }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        var local = Calendar(identifier: .gregorian)
        local.timeZone = calendar.timeZone
        return local.date(from: utc.dateComponents([.year, .month, .day], from: date))
    }

    private func countdown(at now: Date, calendar: Calendar) -> (amount: Int, unit: String)? {
        guard state == .renewing, isFresh(at: now), let date = localDate(in: calendar) else { return nil }
        if isDateOnly {
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: date).day ?? -1
            return days >= 0 ? (days, "day") : nil
        }
        let interval = date.timeIntervalSince(now)
        guard interval > 0 else { return nil }
        if interval >= 86_400 { return (Int(interval / 86_400), "day") }
        if interval >= 3_600 { return (Int(interval / 3_600), "hour") }
        return (max(1, Int(interval / 60)), "minute")
    }

    public func compactLabel(at now: Date, calendar: Calendar = .autoupdatingCurrent) -> String? {
        guard let value = countdown(at: now, calendar: calendar) else { return nil }
        if value.amount == 0 { return "Renews today" }
        let suffix = value.unit == "day" ? "d" : value.unit == "hour" ? "h" : "m"
        return "Renews in \(value.amount)\(suffix)"
    }

    public func accessibilityText(at now: Date, calendar: Calendar = .autoupdatingCurrent) -> String? {
        guard let value = countdown(at: now, calendar: calendar) else { return nil }
        let countdown = value.amount == 0 ? "Renews today"
            : "Renews in \(value.amount) \(value.unit)\(value.amount == 1 ? "" : "s")"
        return "\(countdown), \(dateText(calendar: calendar) ?? "")"
    }

    public func dateText(calendar: Calendar = .autoupdatingCurrent) -> String? {
        guard let date = localDate(in: calendar) else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .long
        formatter.timeStyle = isDateOnly ? .none : .short
        let text = formatter.string(from: date)
        return isDateOnly ? "\(text) (time not provided)" : "\(text) \(calendar.timeZone.abbreviation(for: date) ?? "")"
    }

    public func information(at now: Date) -> ProviderCardInformationSection? {
        guard state != .notApplicable else { return nil }
        let label: String
        let detail: String
        if !isFresh(at: now) {
            label = "Last known billing date"
            detail = "\(dateText() ?? "Unavailable"). Refresh to verify the current subscription."
        } else if state == .nonRenewing {
            label = "Does not renew"
            detail = dateText().map { "Subscription access ends \($0)." } ?? "The provider reports that this subscription will not renew."
        } else if date == nil {
            label = "Renewal date unavailable"
            detail = "The provider did not supply a billing date."
        } else if compactLabel(at: now) == nil {
            label = "Billing date passed"
            detail = "\(dateText() ?? "Unavailable"). Refresh for the next billing date."
        } else {
            label = "Next subscription renewal"
            detail = dateText() ?? "Unavailable"
        }
        return ProviderCardInformationSection(id: "subscription-renewal", title: "Subscription billing", items: [
            ProviderCardInformationItem(id: "subscription-renewal.date", label: label, detail: detail)
        ])
    }
}

/// Safe diagnostic text bound to the same account as the optional billing read.
public struct SubscriptionBillingProblem: Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        case notConnected, expiredSession, accountMismatch, accessDenied, unsupportedSubscription, transportFailure, rejectedResponse
        case credentialsUnavailable

        public var message: String {
            switch self {
            case .credentialsUnavailable:
                "Saved billing credentials could not be read. Retry refresh. Your usage connection is unchanged."
            case .notConnected: "Connect Billing in this Claude account's settings to verify its renewal date. Usage resets are separate."
            case .expiredSession: "Billing sign-in expired. Reconnect billing with the same Claude account. Your usage connection is unchanged."
            case .accountMismatch: "Billing does not match this Claude account. Reconnect billing with the account used for usage."
            case .accessDenied: "Claude denied billing access. Reconnect billing or check Claude Billing for your subscription date."
            case .unsupportedSubscription:
                "This Claude purchase does not expose supported personal web billing. Check the store where you subscribed or your administrator."
            case .transportFailure: "Claude Billing could not be reached. Refresh when your connection is available. Your usage connection is unchanged."
            case .rejectedResponse: "Claude returned billing details that CodexBar could not verify. Check Claude Billing for the date."
            }
        }
    }

    public let accountID: String
    public let reason: Reason
}

extension ProviderUsageResult {
    /// Also validates mutations: a copied observation must not appear on another account.
    public var boundSubscriptionRenewal: SubscriptionRenewal? {
        // OpenCode verifies Go billing separately from the optional Zen balance read.
        guard !subscriptionBillingIsNotApplicable, failureMessage == nil || providerID == .openCodeZen,
              let renewal = subscriptionRenewal,
              renewal.accountID == accountID, renewal.providerID == providerID else { return nil }
        return renewal
    }

    public func subscriptionBillingInformation(at now: Date) -> ProviderCardInformationSection? {
        if let renewal = boundSubscriptionRenewal { return renewal.information(at: now) }
        guard let reason = subscriptionBillingUnavailableReason else { return nil }
        return ProviderCardInformationSection(id: "subscription-renewal", title: "Subscription billing", items: [
            ProviderCardInformationItem(id: "subscription-renewal.unavailable", label: "Renewal date unavailable", detail: reason)
        ])
    }

    public var canOpenClaudeBillingSettings: Bool {
        providerID == .claude && !isClaudeOrganizationSubscription && !subscriptionBillingIsNotApplicable
            && failureMessage == nil && boundSubscriptionRenewal == nil
    }

    private var isClaudeOrganizationSubscription: Bool {
        guard providerID == .claude, let identifier = plan?.identifier.lowercased() else { return false }
        return identifier.contains("team") || identifier.contains("enterprise")
    }

    private var subscriptionBillingIsNotApplicable: Bool {
        if [.openRouter, .moonshot, .githubBilling, .antigravity].contains(providerID) { return true }
        let identifier = plan?.identifier.lowercased() ?? ""
        if providerID == .gemini && identifier == "google-ai.google ai free" { return true }
        if identifier.hasSuffix(".free") || identifier.hasSuffix(".hobby") || identifier.contains(".api-credits") { return true }
        return providerID == .greptile && greptileAllowanceRenewal?.isApplicable == true
    }

    private var subscriptionBillingUnavailableReason: String? {
        guard !subscriptionBillingIsNotApplicable else { return nil }
        switch providerID {
        case .codex:
            return "The current ChatGPT connection did not provide a verified subscription billing date. Usage resets are separate."
        case .claude:
            if isClaudeOrganizationSubscription {
                return "Claude Team and Enterprise organization billing is unsupported. Check billing with your organization's administrator. "
                    + "Usage resets are separate."
            }
            if failureMessage == nil, let problem = subscriptionBillingProblem, problem.accountID == accountID { return problem.reason.message }
            return "Connect Billing in this Claude account's settings to verify its renewal date. If already connected, reconnect "
                + "billing and refresh. Usage resets are separate."
        case .grok:
            return "Connect Billing in this Grok account's settings to verify its subscription date. If already connected, reconnect "
                + "billing and refresh. X and API billing remain separate."
        case .cursor:
            return "Cursor reports usage cycles and membership, but not a verified next charge with cancellation status. Check Manage "
                + "Subscription in Cursor Billing."
        case .gemini:
            return "Google AI billing is managed by Google One, Google payments or the store where you subscribed. The current "
                + "connection does not expose a verified next charge and renewal status."
        case .copilot:
            return "Copilot allowance resets are separate from subscription billing. The current connection does not provide a next "
                + "charge and cancellation status. Check GitHub Billing & licensing."
        case .openCodeZen:
            return "The current OpenCode connection did not verify a Go subscription billing date. Refresh or reconnect to check. Zen "
                + "prepaid credit balances do not renew."
        case .greptile:
            return "Paid Greptile billing needs a verified next charge and renewal status for the selected organization. Free-credit "
                + "allowance renewals remain separate."
        default:
            return nil
        }
    }
}
