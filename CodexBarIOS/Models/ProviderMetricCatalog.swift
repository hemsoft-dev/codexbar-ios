import Foundation

/// Known metric choices are independent of whether the latest fetch returned a value.
public enum ProviderMetricCatalog {
    static let disabledReason = "Disabled"

    public struct Definition: Equatable, Sendable {
        public let sourceProviderID: ProviderID
        public let key: String
        public let label: String
        public let window: String

        public var id: String { "\(sourceProviderID.rawValue).\(key)" }
    }

    public static func definitions(for providerID: ProviderID) -> [Definition] {
        switch providerID {
        case .codex:
            [Definition(sourceProviderID: .codex, key: CodexUsageParser.creditsPoolStableKey, label: "Credits pool", window: "balance")]
        case .museCode:
            MuseCodeAllowance.Window.allCases.map {
                Definition(sourceProviderID: .museCode, key: $0.rawValue, label: $0.label, window: $0 == .window ? "5h" : "weekly")
            }
        default:
            []
        }
    }

    public static func metrics(
        for providerID: ProviderID,
        result: ProviderUsageResult? = nil,
        missingReason: String = "Setup required"
    ) -> [ProviderUsageMetric] {
        if providerID == .cursor {
            return cursorMetrics(result: result, missingReason: missingReason)
        }
        let matchingResult = result?.providerID == providerID ? result : nil
        let observed = matchingResult?.availableMetrics ?? []
        let definitions = definitions(for: providerID)
        let knownIDs = Set(definitions.map(\.id))
        let known = definitions.map { definition in
            let metricID = definition.id
            let unavailableReason = matchingResult?.unavailableUsageMetrics[metricID]
            let kind: ProviderUsageMetricKind
            if unavailableReason == disabledReason {
                kind = .unavailableUsage(disabledReason)
            } else {
                kind = observed.first { $0.id == metricID }?.kind
                    ?? .unavailableUsage(unavailableReason ?? missingReason)
            }
            return ProviderUsageMetric(id: metricID, label: definition.label, kind: kind)
        }
        let additional = observed.filter { !knownIDs.contains($0.id) }
        return providerID == .codex ? additional + known : known + additional
    }

    public static func layoutCopyMetricIDs(for providerID: ProviderID, result: ProviderUsageResult?) -> [String] {
        guard providerID != .codex
            || (result?.hasSuccessfulRefreshHistory == true && result?.usageHistoryBars().isEmpty == false)
        else { return [] }
        return metrics(for: providerID, result: result).map(\.id)
    }

    private static func cursorMetrics(result: ProviderUsageResult?, missingReason: String) -> [ProviderUsageMetric] {
        let matching = result?.providerID == .cursor ? result : nil
        let observed = matching?.availableMetrics ?? []
        let known: [ProviderUsageMetric] = CursorUsageIdentity.spendingChoices.map { choice in
            let id = "cursor.\(choice.key)"
            if let metric = observed.first(where: { $0.id == id }) {
                return metric
            }
            let reason = matching?.unavailableUsageMetrics[id] ?? missingReason
            return ProviderUsageMetric(id: id, label: choice.label, kind: .unavailableUsage(reason))
        }
        let knownIDs = Set(known.map(\.id))
        return known + observed.filter { !knownIDs.contains($0.id) }
    }

}
