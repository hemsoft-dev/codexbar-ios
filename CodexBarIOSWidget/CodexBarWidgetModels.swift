import Foundation

struct CodexBarWidgetTile: Identifiable {
    let id: String
    let accountID: String?
    let providerID: String
    let providerTitle: String
    let title: String
    let subtitle: String
    let bar: CodexBarWidgetUsageBarSnapshot?
    let creditsRemaining: Double?
    let monetaryMetric: CodexBarWidgetMonetaryMetricSnapshot?
    let barFetchedAt: Date?
    let monetaryValueFetchedAt: Date?
    let fetchedAt: Date?
    let severity: CodexBarWidgetSeverity

    /// Saved Builder slots and App Intent choices share the same available-tile fallback.
    static func resolvingSavedID(
        _ tileID: String,
        in tiles: [CodexBarWidgetTile],
        legacyMatch: () -> CodexBarWidgetTile? = { nil }
    ) -> CodexBarWidgetTile {
        if let exact = tiles.first(where: { $0.id == tileID }) { return exact }
        if let legacy = legacyMatch() { return legacy }
        if let fallback = tiles.first { return fallback }
        return .unavailable(choice: CodexBarWidgetTileChoice(
            id: tileID, title: "Saved Tile", subtitle: "Open CodexBar to refresh"
        ))
    }

    var choiceTitle: String {
        if bar != nil || monetaryMetric != nil {
            "\(providerTitle) - \(title)"
        } else {
            title
        }
    }

    var choiceSubtitle: String {
        if let bar {
            return "\(bar.usageText) used"
        }

        if let creditsRemaining {
            return CodexBarCurrencyText.format(creditsRemaining)
        }

        if let monetaryMetric {
            return monetaryMetric.formattedAmount
        }

        return subtitle
    }

    static func unavailable(choice: CodexBarWidgetTileChoice) -> CodexBarWidgetTile {
        CodexBarWidgetTile(
            id: "unavailable.\(choice.id)",
            accountID: nil,
            providerID: "unavailable",
            providerTitle: choice.title,
            title: choice.title,
            subtitle: "Open CodexBar to refresh this tile.",
            bar: nil,
            creditsRemaining: nil,
            monetaryMetric: nil,
            barFetchedAt: nil,
            monetaryValueFetchedAt: nil,
            fetchedAt: nil,
            severity: .warning
        )
    }

    var deepLinkURL: URL? {
        accountID.flatMap(CodexBarDeepLink.providerURL(accountID:))
    }

    var monetaryValueText: String? {
        if let monetaryMetric {
            return monetaryMetric.formattedAmount
        }
        return creditsRemaining.map { CodexBarCurrencyText.format($0) }
    }

    var summaryText: String {
        if let monetaryValueText {
            return monetaryValueText
        }

        return bar.map(metricText(for:)) ?? "No data"
    }

    var allowsUsageGauge: Bool {
        bar?.allowsGauge != false
    }

    func metricText(for bar: CodexBarWidgetUsageBarSnapshot) -> String {
        bar.usageText
    }

    func urgentStatusDetail(for bar: CodexBarWidgetUsageBarSnapshot) -> String {
        if let projectionDescription = bar.localizedProjectionDescription() {
            return "\(bar.usageText) used - \(projectionDescription)"
        }

        return [bar.usageText, bar.localizedResetDescription()]
            .compactMap { $0 }
            .joined(separator: " - ")
    }
}

struct CodexBarWidgetRenderedTile: Identifiable {
    let tile: CodexBarWidgetTile
    let displayMode: CodexBarWidgetTileDisplayMode

    var id: String {
        "\(tile.id).\(displayMode.rawValue)"
    }

    var fetchedAt: Date? {
        switch displayMode {
        case .automatic:
            tile.fetchedAt
        case .compactPercent, .fullBar, .urgentStatus:
            tile.bar == nil
                ? (tile.monetaryValueFetchedAt ?? tile.fetchedAt)
                : (tile.barFetchedAt ?? tile.fetchedAt)
        case .balanceOnly:
            tile.monetaryValueFetchedAt
        }
    }

    var allowsUsageGauge: Bool {
        tile.allowsUsageGauge
    }
}

extension Collection where Element == CodexBarWidgetRenderedTile {
    func freshnessDate(fallback: Date) -> Date {
        compactMap(\.fetchedAt).min() ?? fallback
    }
}

extension CodexBarWidgetSnapshot {
    func selectableTiles(
        group: CodexBarWidgetGroupChoice? = nil,
        focus: CodexBarWidgetFocus = .dashboardOrder
    ) -> [CodexBarWidgetTile] {
        scopedProviders(group: group, focus: focus).flatMap { provider in
            [provider.summaryTile]
                + provider.bars.map { provider.barTile($0) }
                + provider.standaloneMonetaryMetrics.map { provider.monetaryTile($0) }
        }
    }

    func scopedProviders(
        group: CodexBarWidgetGroupChoice? = nil,
        focus: CodexBarWidgetFocus = .dashboardOrder
    ) -> [CodexBarWidgetProviderSnapshot] {
        let groupFiltered: [CodexBarWidgetProviderSnapshot]
        if let selectedGroupID = group?.id {
            groupFiltered = results.filter { provider in
                (provider.groupID ?? CodexBarWidgetGroupChoice.ungroupedID) == selectedGroupID
            }
        } else {
            groupFiltered = results
        }

        return focus.providerID.map { providerID in
            groupFiltered.filter {
                $0.providerID == providerID
            }
        } ?? groupFiltered
    }

    var groupChoices: [CodexBarWidgetGroupChoice] {
        var choices: [CodexBarWidgetGroupChoice] = []
        var seenIDs = Set<String>()

        for provider in results {
            let id = provider.groupID ?? CodexBarWidgetGroupChoice.ungroupedID
            guard seenIDs.insert(id).inserted else {
                continue
            }

            choices.append(
                CodexBarWidgetGroupChoice(
                    id: id,
                    title: widgetGroupTitle(for: provider)
                )
            )
        }

        return choices.sorted {
            if $0.id == CodexBarWidgetGroupChoice.ungroupedID {
                return false
            }

            if $1.id == CodexBarWidgetGroupChoice.ungroupedID {
                return true
            }

            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    private func widgetGroupTitle(for provider: CodexBarWidgetProviderSnapshot) -> String {
        let title = provider.groupName ?? "Ungrouped"
        if provider.groupID != nil,
           title.localizedCaseInsensitiveCompare("Ungrouped") == .orderedSame {
            return "Ungrouped (group)"
        }

        return title
    }
}

extension CodexBarWidgetProviderSnapshot {
    var summaryTile: CodexBarWidgetTile {
        let summaryMetric = summaryMonetaryMetric
        return CodexBarWidgetTile(
            id: "provider.\(accountID)",
            accountID: accountID,
            providerID: providerID,
            providerTitle: title,
            title: summaryMetric?.label ?? (creditsRemaining == nil ? title : "\(title) Balance"),
            subtitle: summaryMetric?.detail ?? subtitle,
            bar: representativeBar,
            creditsRemaining: creditsRemaining,
            monetaryMetric: summaryMetric,
            barFetchedAt: representativeBar == nil ? nil : (barsFetchedAt ?? fetchedAt),
            monetaryValueFetchedAt: summaryMonetaryFetchedAt,
            fetchedAt: summaryFetchedAt,
            severity: severity
        )
    }

    private var summaryMonetaryFetchedAt: Date? {
        if summaryMonetaryMetric != nil {
            return monetaryMetricsFetchedAt ?? fetchedAt
        }
        if creditsRemaining != nil {
            return creditsFetchedAt ?? fetchedAt
        }
        return nil
    }

    private var summaryFetchedAt: Date {
        if let summaryMonetaryFetchedAt {
            return summaryMonetaryFetchedAt
        }
        if representativeBar != nil {
            return barsFetchedAt ?? fetchedAt
        }
        return fetchedAt
    }

    private var representativeBar: CodexBarWidgetUsageBarSnapshot? {
        bars.max { lhs, rhs in
            if lhs.effectiveSeverity == rhs.effectiveSeverity {
                return lhs.effectiveFractionUsed < rhs.effectiveFractionUsed
            }

            return lhs.effectiveSeverity < rhs.effectiveSeverity
        }
    }

    func barTile(_ bar: CodexBarWidgetUsageBarSnapshot) -> CodexBarWidgetTile {
        CodexBarWidgetTile(
            id: "bar.\(bar.id)",
            accountID: accountID,
            providerID: providerID,
            providerTitle: title,
            title: bar.label,
            subtitle: subtitle,
            bar: bar,
            creditsRemaining: nil,
            monetaryMetric: nil,
            barFetchedAt: barsFetchedAt ?? fetchedAt,
            monetaryValueFetchedAt: nil,
            fetchedAt: barsFetchedAt ?? fetchedAt,
            severity: bar.effectiveSeverity
        )
    }

    func monetaryTile(_ metric: CodexBarWidgetMonetaryMetricSnapshot) -> CodexBarWidgetTile {
        CodexBarWidgetTile(
            id: "money.\(accountID).\(metric.id)",
            accountID: accountID,
            providerID: providerID,
            providerTitle: title,
            title: metric.label,
            subtitle: metric.detail ?? subtitle,
            bar: nil,
            creditsRemaining: nil,
            monetaryMetric: metric,
            barFetchedAt: nil,
            monetaryValueFetchedAt: monetaryMetricsFetchedAt ?? fetchedAt,
            fetchedAt: monetaryMetricsFetchedAt ?? fetchedAt,
            severity: severity
        )
    }
}
