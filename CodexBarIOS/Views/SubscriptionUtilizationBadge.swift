import SwiftUI

struct SubscriptionUtilizationBadge: View {
    let score: SubscriptionUtilizationScore?
    var title = "SUS"

    private var color: Color {
        switch score?.band {
        case .green: .green
        case .yellow: .yellow
        case .red: .red
        case nil: .secondary
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: score == nil ? "minus.circle" : "circle.fill")
                .font(.caption2)
                .foregroundStyle(color)
            Text("\(title) \(score.map { String($0.value) } ?? "n/a")")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title == "SUS" ? score?.accessibilityText ?? "SUS unavailable" : "\(title), \(score?.accessibilityText ?? "unavailable")")
    }
}

#if DEBUG
/// Synthetic, isolated UI evidence. No provider request or real account is used.
struct UITestSUSProvider: UsageProvider {
    let providerID = ProviderID.claude

    static func overriding(_ providers: [any UsageProvider], scenario: String?) -> [any UsageProvider] {
        scenario == "sus-evidence" ? [Self()] : providers
    }

    @MainActor static func seed(in store: ProviderConfigurationStore, scenario: String?) {
        guard scenario == "sus-evidence" else { return }
        guard store.configurations.isEmpty else { return }
        let account = ProviderAccountConfiguration(id: "ui-sus", providerID: .claude,
                                                   accountLabel: "SUS fixture", authMethod: .browserSession)
        precondition(store.update(account))
        _ = store.saveSecret("ui-test-credential", for: account)
    }

    static func result(for account: ProviderAccountConfiguration) -> ProviderUsageResult {
        let now = Date()
        let values: [(String, Double, Double)] = [("On track", 47.5, 84), ("Underused", 40, 84),
                                                 ("Early lockout", 100, 84), ("Fresh window", 1, 4),
        ]
        let bars = values.enumerated().map { index, value in
            UsageBar(stableKey: "weekly-\(index)", label: "Weekly · \(value.0)", used: value.1, limit: 100,
                     resetsAt: now.addingTimeInterval((168 - value.2) * 3_600), resetDisplayStyle: .relativeWithLocalTime,
                     projectionCurrent: value.1, projectionLimit: 100,
                     projectionPeriodStart: now.addingTimeInterval(-value.2 * 3_600),
                     projectionPeriodEnd: now.addingTimeInterval((168 - value.2) * 3_600), showProjectionOnCurrentBar: true)
        }
        return ProviderUsageResult(accountID: account.id, providerID: .claude, title: account.displayName,
                                   subtitle: "Synthetic weekly quota evidence", bars: bars, fetchedAt: now)
    }

    func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        Self.result(for: configuration)
    }
}
#endif

struct SubscriptionUtilizationMetricView: View {
    let bar: UsageBar
    let isCurrent: Bool
    var showsExplanation = false

    var body: some View {
        if SubscriptionUtilizationScore.applies(to: bar) {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                SubscriptionUtilizationBadge(score: isCurrent ? SubscriptionUtilizationScore(bar: bar, at: context.date) : nil)
            }
            if showsExplanation {
                Text("Sub Utilization Score: 100 means full use at reset. Weekly windows need 12 hours of history.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct SubscriptionUtilizationEmptyState: View {
    let result: ProviderUsageResult
    var body: some View {
        if result.providerID.usesXAIConsumerAuth && result.bars.isEmpty {
            SubscriptionUtilizationBadge(score: nil)
        }
    }
}
