import Foundation

enum WatchComplicationConstants {
    static let appGroupIdentifier = "group.com.hemsoft.CodexBarIOS"
    static let widgetKind = "CodexBarWatchUsageComplication"
    static let snapshotDefaultsKey = "watch.complication.last-good-snapshot"
}

struct WatchComplicationSelection: Equatable, Sendable {
    let accountID: String?
    let metricID: String?

    static let automatic = WatchComplicationSelection(accountID: nil, metricID: nil)

    static func resolving(
        accountID: String?,
        metricAccountID: String?,
        metricID: String?,
        snapshot: WatchDashboardSnapshot? = nil
    ) -> WatchComplicationSelection {
        let resolvedAccountID = accountID ?? metricAccountID
        let account = snapshot?.accounts.first {
            $0.id == resolvedAccountID || ($0.legacyAccountIDs ?? []).contains(resolvedAccountID ?? "")
        }
        let linkedIDs = [account?.id].compactMap { $0 } + (account?.legacyAccountIDs ?? [])
        let resolvedMetricID = metricAccountID == nil || metricAccountID == resolvedAccountID
            || linkedIDs.contains(metricAccountID ?? "")
            ? metricID
            : nil
        return WatchComplicationSelection(
            accountID: resolvedAccountID,
            metricID: resolvedMetricID
        )
    }
}

struct WatchComplicationAccountChoice: Equatable, Sendable {
    let id: String
    let providerName: String
    let accountLabel: String
}

struct WatchComplicationMetricChoice: Equatable, Sendable {
    let id: String
    let accountID: String
    let metricID: String
    let providerName: String
    let accountLabel: String
    let metricLabel: String

    var subtitle: String {
        [providerName, accountLabel]
            .filter { !$0.isEmpty }
            .joined(separator: " • ")
    }
}

struct WatchComplicationChoiceCatalog {
    private let snapshot: WatchDashboardSnapshot?

    init(snapshot: WatchDashboardSnapshot?, now: Date = Date()) {
        self.snapshot = snapshot?.isLocked(at: now) == false ? snapshot : nil
    }

    var accounts: [WatchComplicationAccountChoice] {
        (snapshot?.accounts ?? [])
            .filter { !$0.metrics.isEmpty }
            .map {
                WatchComplicationAccountChoice(
                    id: $0.id,
                    providerName: $0.providerName,
                    accountLabel: $0.accountLabel
                )
            }
    }

    var metrics: [WatchComplicationMetricChoice] {
        (snapshot?.accounts ?? []).flatMap { account in
            account.metrics.map { metric in
                WatchComplicationMetricChoice(
                    id: Self.metricChoiceID(accountID: account.id, metricID: metric.id),
                    accountID: account.id,
                    metricID: metric.id,
                    providerName: account.providerName,
                    accountLabel: account.accountLabel,
                    metricLabel: metric.label
                )
            }
        }
    }

    func accounts(for identifiers: [String]) -> [WatchComplicationAccountChoice] {
        let choicesByID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        return identifiers.map { identifier in
            let alias = snapshot?.accounts.first { ($0.legacyAccountIDs ?? []).contains(identifier) }
            return choicesByID[identifier] ?? WatchComplicationAccountChoice(
                id: identifier,
                providerName: alias?.providerName ?? "Saved Account",
                accountLabel: alias?.accountLabel ?? "Open CodexBar to refresh"
            )
        }
    }

    func metrics(for identifiers: [String]) -> [WatchComplicationMetricChoice] {
        let choicesByID = Dictionary(uniqueKeysWithValues: metrics.map { ($0.id, $0) })
        return identifiers.map { identifier in
            if let exact = choicesByID[identifier] { return exact }
            let saved = Self.savedMetricChoice(identifier: identifier)
            let replacementID = ClaudeFableUsageIdentity.replacementMetricID(for: saved.metricID)
            guard let account = snapshot?.accounts.first(where: {
                ($0.legacyAccountIDs ?? []).contains(saved.accountID)
                    || (replacementID != nil && $0.id == saved.accountID)
            }), let metric = account.metrics.first(where: { $0.id == (replacementID ?? saved.metricID) }) else { return saved }
            return WatchComplicationMetricChoice(
                id: identifier, accountID: saved.accountID, metricID: metric.id,
                providerName: account.providerName, accountLabel: account.accountLabel, metricLabel: metric.label
            )
        }
    }

    static func metricChoiceID(accountID: String, metricID: String) -> String {
        "\(accountID)::\(metricID)"
    }

    private static func savedMetricChoice(identifier: String) -> WatchComplicationMetricChoice {
        let accountID: String
        let metricID: String
        if let separator = identifier.range(of: "::") {
            accountID = String(identifier[..<separator.lowerBound])
            metricID = String(identifier[separator.upperBound...])
        } else {
            accountID = identifier
            metricID = "__saved-metric"
        }
        return WatchComplicationMetricChoice(
            id: identifier,
            accountID: accountID,
            metricID: metricID,
            providerName: "Saved Account",
            accountLabel: "Open CodexBar to refresh",
            metricLabel: "Saved Metric"
        )
    }
}

enum WatchComplicationAvailability: Equatable, Sendable {
    case locked
    case empty
    case unavailable
    case value
}

struct WatchComplicationSample: Equatable, Sendable {
    let availability: WatchComplicationAvailability
    let providerName: String
    let accountLabel: String
    let metricLabel: String
    let exactValue: String
    let usedFraction: Double?
    let severity: WatchMetricSeverity
    let resetText: String?
    let freshnessText: String
    let isStale: Bool

    static let lockedMessage = "Unlock the watch app with CodexBar Pro on iPhone"

    static let locked = WatchComplicationSample(
        availability: .locked,
        providerName: "CodexBar",
        accountLabel: "",
        metricLabel: "Unlock with Pro",
        exactValue: "",
        usedFraction: nil,
        severity: .normal,
        resetText: nil,
        freshnessText: "On iPhone",
        isStale: false
    )

    static let empty = WatchComplicationSample(
        availability: .empty,
        providerName: "CodexBar",
        accountLabel: "",
        metricLabel: "Open iPhone app",
        exactValue: "--",
        usedFraction: nil,
        severity: .normal,
        resetText: nil,
        freshnessText: "No usage yet",
        isStale: false
    )

    static let unavailable = WatchComplicationSample(
        availability: .unavailable,
        providerName: "CodexBar",
        accountLabel: "",
        metricLabel: "Selection unavailable",
        exactValue: "--",
        usedFraction: nil,
        severity: .normal,
        resetText: nil,
        freshnessText: "Open iPhone app",
        isStale: false
    )

    var clampedUsedFraction: Double {
        min(max(usedFraction ?? 0, 0), 1)
    }

    var supportsGauge: Bool {
        availability == .value && usedFraction != nil
    }

    var cornerContextLabel: String {
        switch availability {
        case .locked:
            return "Unlock with CodexBar Pro"
        case .empty:
            return "CodexBar"
        case .unavailable:
            return "Selection unavailable"
        case .value:
            return isStale ? "Stale • \(metricLabel)" : metricLabel
        }
    }

    var accountContextLabel: String {
        [providerName, accountLabel]
            .filter { !$0.isEmpty }
            .joined(separator: " • ")
    }

    var stateLabel: String? {
        let freshnessState = isStale ? "Stale" : nil
        let severityState: String?
        switch severity {
        case .normal:
            severityState = nil
        case .warning:
            severityState = "Warning"
        case .critical:
            severityState = "Critical"
        }
        let labels = [freshnessState, severityState].compactMap { $0 }
        return labels.isEmpty ? nil : labels.joined(separator: " • ")
    }

    var accessibilityLabel: String {
        if availability == .locked { return Self.lockedMessage }
        return [
            providerName,
            accountLabel,
            metricLabel,
            exactValue,
            stateLabel,
            resetText,
            freshnessText,
        ]
        .compactMap { $0 }
        .filter { !$0.isEmpty }
        .joined(separator: ", ")
    }
}

struct WatchComplicationResolver {
    func resolve(
        snapshot: WatchDashboardSnapshot?,
        selection: WatchComplicationSelection,
        at date: Date
    ) -> WatchComplicationSample {
        guard let snapshot else {
            return .empty
        }
        guard !snapshot.isLocked(at: date) else { return .locked }

        let accounts = snapshot.accounts.filter { !$0.metrics.isEmpty }
        guard !accounts.isEmpty else {
            return selection.accountID == nil && selection.metricID == nil
                ? .empty
                : .unavailable
        }

        guard let displayed = displayedMetric(in: accounts, selection: selection) else {
            return .unavailable
        }
        let account = displayed.account
        let metric = displayed.metric
        let fetchedAt = metric.fetchedAt ?? account.fetchedAt
        let isStale = Self.isStale(
            snapshot: snapshot,
            metric: metric,
            fetchedAt: fetchedAt,
            at: date
        )

        return WatchComplicationSample(
            availability: .value,
            providerName: account.providerName,
            accountLabel: account.accountLabel,
            metricLabel: metric.label,
            exactValue: metric.exactValue,
            usedFraction: metric.usedFraction,
            severity: metric.severity,
            resetText: UserFacingDateTimeFormatter.current.resetDescription(
                resetAt: metric.resetsAt,
                now: date,
                style: metric.resetDisplayStyle ?? .verbatim,
                fallback: metric.resetText,
                includesMinutesBeyondFinalHour: false
            ),
            freshnessText: Self.freshnessText(fetchedAt, now: date),
            isStale: isStale
        )
    }

    func nextReloadDate(
        snapshot: WatchDashboardSnapshot?,
        selection: WatchComplicationSelection,
        now: Date
    ) -> Date {
        let usageDate = usageReloadDate(snapshot: snapshot, selection: selection, now: now)
        guard let snapshot, !snapshot.isLocked(at: now),
              let deadline = snapshot.proAccessEndsAt else { return usageDate }
        return min(usageDate, deadline)
    }

    private func usageReloadDate(
        snapshot: WatchDashboardSnapshot?,
        selection: WatchComplicationSelection,
        now: Date
    ) -> Date {
        guard let snapshot else {
            return now.addingTimeInterval(30 * 60)
        }

        let accounts = snapshot.accounts.filter { !$0.metrics.isEmpty }
        guard let displayed = displayedMetric(in: accounts, selection: selection) else {
            return now.addingTimeInterval(30 * 60)
        }
        let fetchedAt = displayed.metric.fetchedAt ?? displayed.account.fetchedAt

        let staleWindow = snapshot.refreshIntervalSeconds.map {
            max($0 * 2, 15 * 60)
        } ?? 60 * 60
        let staleDate = fetchedAt.addingTimeInterval(staleWindow + 1)
        let retryInterval = max(snapshot.refreshIntervalSeconds ?? 60 * 60, 15 * 60)
        if let resetsAt = displayed.metric.resetsAt {
            if resetsAt <= now {
                return now.addingTimeInterval(retryInterval)
            }
            if resetsAt < staleDate {
                return resetsAt
            }
        }
        if staleDate > now {
            return max(staleDate, now.addingTimeInterval(60))
        }

        return now.addingTimeInterval(retryInterval)
    }

    func timelineEntryDates(
        snapshot: WatchDashboardSnapshot?,
        selection: WatchComplicationSelection,
        now: Date
    ) -> [Date] {
        guard let snapshot else { return [now] }
        guard !snapshot.isLocked(at: now) else { return [now] }
        let usageDates = usageTimelineEntryDates(snapshot: snapshot, selection: selection, now: now)
        guard let deadline = snapshot.proAccessEndsAt else { return usageDates }
        return Array(Set(usageDates.filter { $0 < deadline } + [deadline])).sorted()
    }

    private func usageTimelineEntryDates(
        snapshot: WatchDashboardSnapshot?,
        selection: WatchComplicationSelection,
        now: Date
    ) -> [Date] {
        guard let snapshot else {
            return [now]
        }

        let accounts = snapshot.accounts.filter { !$0.metrics.isEmpty }
        guard let displayed = displayedMetric(in: accounts, selection: selection) else {
            return [now]
        }
        let fetchedAt = displayed.metric.fetchedAt ?? displayed.account.fetchedAt

        let staleDate = usageReloadDate(snapshot: snapshot, selection: selection, now: now)
        guard !Self.isStale(
            snapshot: snapshot,
            metric: displayed.metric,
            fetchedAt: fetchedAt,
            at: now
        ), staleDate > now else {
            return [now]
        }

        var dates = [now]
        let elapsedMinutes = floor(max(0, now.timeIntervalSince(fetchedAt)) / 60)
        var transition = fetchedAt.addingTimeInterval((elapsedMinutes + 1) * 60)
        let firstHourEnd = fetchedAt.addingTimeInterval(60 * 60)

        while transition < staleDate, transition <= firstHourEnd {
            dates.append(transition)
            transition = transition.addingTimeInterval(60)
        }

        if transition < staleDate {
            let elapsedHours = floor(max(1, now.timeIntervalSince(fetchedAt) / (60 * 60)))
            transition = fetchedAt.addingTimeInterval((elapsedHours + 1) * 60 * 60)
            while transition < staleDate {
                dates.append(transition)
                transition = transition.addingTimeInterval(60 * 60)
            }
        }

        if displayed.metric.resetDisplayStyle == .relativeWithLocalTime,
           let resetsAt = displayed.metric.resetsAt,
           resetsAt > now {
            let countdownEnd = min(resetsAt, staleDate)
            let wholeHoursRemaining = Int(
                floor(resetsAt.timeIntervalSince(now) / (60 * 60))
            )
            if wholeHoursRemaining > 0 {
                var countdownDate = resetsAt.addingTimeInterval(
                    -TimeInterval(wholeHoursRemaining * 60 * 60)
                )
                while countdownDate < countdownEnd {
                    if countdownDate > now {
                        dates.append(countdownDate)
                    }
                    countdownDate = countdownDate.addingTimeInterval(60 * 60)
                }
            }

            for minutesBeforeReset in stride(from: 60, through: 0, by: -1) {
                let countdownDate = resetsAt.addingTimeInterval(
                    -TimeInterval(minutesBeforeReset * 60)
                )
                if countdownDate > now, countdownDate < countdownEnd {
                    dates.append(countdownDate)
                }
            }
        }

        dates.append(staleDate)
        return Array(Set(dates)).sorted()
    }

    private func displayedMetric(
        in accounts: [WatchAccountSnapshot],
        selection: WatchComplicationSelection
    ) -> (account: WatchAccountSnapshot, metric: WatchMetricSnapshot)? {
        let account: WatchAccountSnapshot?
        if let accountID = selection.accountID {
            account = accounts.first { $0.id == accountID || ($0.legacyAccountIDs ?? []).contains(accountID) }
        } else {
            account = accounts.first
        }
        guard let account else {
            return nil
        }

        if let metricID = selection.metricID {
            let metric = account.metrics.first(where: { $0.id == metricID })
                ?? replacementMetric(in: account, for: metricID)
            guard let metric else {
                return nil
            }
            return (account, metric)
        }
        if let selectedID = selection.accountID, (account.legacyAccountIDs ?? []).contains(selectedID) {
            guard let coding = account.metrics.first(where: { $0.id.hasPrefix("antigravity.") }) else { return nil }
            return (account, coding)
        }
        return (account, account.metrics[0])
    }

    private func replacementMetric(
        in account: WatchAccountSnapshot,
        for metricID: String
    ) -> WatchMetricSnapshot? {
        if let replacementID = ClaudeFableUsageIdentity.replacementMetricID(for: metricID) {
            return account.metrics.first { $0.id == replacementID }
        }
        if let replacementID = CursorUsageIdentity.replacementMetricID(for: metricID) {
            return account.metrics.first { $0.id == replacementID }
        }

        let replacementID: String
        switch metricID {
        case GreptileUsageIdentity.completedReviewsMetricID:
            replacementID = GreptileUsageIdentity.reviewQuotaMetricID
        case GreptileUsageIdentity.reviewQuotaMetricID:
            replacementID = GreptileUsageIdentity.completedReviewsMetricID
        default:
            return nil
        }
        return account.metrics.first { $0.id == replacementID }
    }

    private static func isStale(
        snapshot: WatchDashboardSnapshot,
        metric: WatchMetricSnapshot,
        fetchedAt: Date,
        at date: Date
    ) -> Bool {
        snapshot.isStale(dataDate: fetchedAt, at: date)
            || metric.resetsAt.map { $0 <= date } == true
    }

    private static func freshnessText(_ fetchedAt: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(fetchedAt)))
        if seconds < 60 {
            return "Updated now"
        }
        if seconds < 3_600 {
            return "Updated \(seconds / 60)m ago"
        }
        if seconds < 86_400 {
            return "Updated \(seconds / 3_600)h ago"
        }
        return "Updated \(seconds / 86_400)d ago"
    }
}

struct WatchComplicationSnapshotStore {
    private let defaults: UserDefaults

    init(
        defaults: UserDefaults = UserDefaults(
            suiteName: WatchComplicationConstants.appGroupIdentifier
        ) ?? .standard
    ) {
        self.defaults = defaults
    }

    func load() -> WatchDashboardSnapshot? {
        guard let data = defaults.data(forKey: WatchComplicationConstants.snapshotDefaultsKey) else {
            return nil
        }
        return try? WatchDashboardSnapshot.decode(data)
    }

    func loadForAccess(now: Date = Date()) -> WatchDashboardSnapshot? {
        guard let snapshot = load(), let deadline = snapshot.proAccessEndsAt else { return load() }
        guard deadline.timeIntervalSinceReferenceDate.isFinite, now.timeIntervalSinceReferenceDate.isFinite else {
            return snapshot.lockingAccess()
        }
        // A queued newer usage revision cannot revive an already denied deadline.
        // A renewed deadline or permanent phone grant has independent access.
        if snapshot.isProLocked || now >= deadline {
            recordExpiration(deadline)
            return snapshot.lockingAccess()
        }
        return defaults.object(forKey: expirationKey(deadline)) == nil ? snapshot : snapshot.lockingAccess()
    }

    func recordExpiration(_ deadline: Date) {
        guard deadline.timeIntervalSinceReferenceDate.isFinite else { return }
        // Only set this receipt; concurrent observers never clear or overwrite it.
        defaults.set(true, forKey: expirationKey(deadline))
    }

    private func expirationKey(_ deadline: Date) -> String {
        "watch.complication.expired-deadline.\(deadline.timeIntervalSinceReferenceDate)"
    }

    @discardableResult
    func saveIfChanged(
        _ snapshot: WatchDashboardSnapshot,
        encodedData: Data? = nil
    ) throws -> Bool {
        let data = try encodedData ?? snapshot.encoded()
        guard defaults.data(forKey: WatchComplicationConstants.snapshotDefaultsKey) != data else {
            return false
        }
        defaults.set(data, forKey: WatchComplicationConstants.snapshotDefaultsKey)
        return true
    }
}

enum WatchComplicationFamilyLayout: CaseIterable, Hashable, Sendable {
    case inline
    case circular
    case rectangular
    case corner

    var showsResetContext: Bool {
        self == .rectangular
    }

    var usesGauge: Bool {
        self == .circular || self == .corner
    }

    func usesGauge(for sample: WatchComplicationSample) -> Bool {
        usesGauge && sample.supportsGauge
    }
}
