import Charts
import SwiftUI
import UIKit

struct CodexBankedResetInventoryPresentation: Identifiable, Equatable {
    let id = UUID()
    let resets: CodexBankedRateLimitResets
    let canRedeem: Bool
}

enum ProviderUsageCardMenuAction: Hashable {
    case moreInformation
    case configureAccount
    case customizeMetrics
}

private struct ProviderProblemReportDisclosure: View {
    let title: String
    let message: String
    let onReport: (() -> Void)?

    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(title, isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let onReport {
                    Button {
                        onReport()
                    } label: {
                        Label("Report This Problem", systemImage: "ladybug")
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                    .accessibilityHint(
                        "Previews the privacy-safe diagnostic before opening GitHub"
                    )
                }
            }
        }
        .font(.caption)
    }
}

private struct ProviderMetricTileDetailPresentation: Identifiable {
    let metricID: String

    var id: String { metricID }
}

struct ProviderUsageCard: View {
    private static let headerControlSpacing: CGFloat = 8
    private static let menuControlSize: CGFloat = 44
    private static let severityDotSize: CGFloat = 10
    private static let chevronSlotSize: CGFloat = 13
    private static var menuTrailingOffset: CGFloat {
        severityDotSize + chevronSlotSize + (headerControlSpacing * 2)
    }

    let result: ProviderUsageResult
    let showsSubscriptionRenewals: Bool
    let statusText: String
    let history: UsageHistorySeries
    let historyAccessPolicy: HistoryAccessPolicy
    let alerts: [UsageAlertDetail]
    let isHistoryEnabled: Bool
    let isRefreshing: Bool
    let isPausedByPlan: Bool
    let onMakeActive: () -> Void
    let isExpanded: Bool
    let refreshErrorMessage: String?
    let recoveryAction: ProviderUsageRecoveryAction
    let isPerformingRecovery: Bool
    let recoveryStatusMessage: String?
    let recoveryErrorMessage: String?
    let onReportProblem: (() -> Void)?
    let onShowHistory: () -> Void
    let onToggleExpansion: () -> Void
    let onConfigureAccount: () -> Void
    let onRetry: () -> Void
    let onUseCodexReset: ((String?) async -> CodexBankedResetRedemptionFeedback)?
    let onUseClaudeReset: ((ClaudeUsageResetGrant, String) async -> ClaudeUsageResetFeedback)?
    let isMetricVisible: (String) -> Bool
    let onUpdateMetricVisibility: (String, Bool) -> Void
    let watchVisibilityForMetric: (String) -> WatchMetricVisibilityPolicy
    let onUpdateWatchVisibility: (String, WatchMetricVisibilityPolicy) -> Void
    let visualizationStyleForMetric: (String) -> MetricVisualizationStyle
    let onUpdateVisualizationStyle: (String, MetricVisualizationStyle) -> Void
    let onApplyVisualizationStyleToAll: (MetricVisualizationStyle, [String]) -> Void
    let onResetVisualizationStyles: ([String]) -> Void
    let metricOrder: [String]
    let metricWidthForMetric: (String) -> MetricTileWidthPreference
    let onUpdateMetricWidth: (String, MetricTileWidthPreference) -> Void
    let metricLayoutProvider: () -> AccountMetricLayout
    let isMetricNewlyDiscovered: (String) -> Bool
    let onUpdateMetricOrder: ([String]) -> Void
    let onReplaceMetricLayout: (AccountMetricLayout) -> Void
    let onResetMetricLayout: ([String]) -> Void
    let copyLayoutDestinationsProvider: () -> [MetricLayoutCopyDestination]
    let onCopyMetricLayout: (MetricLayoutCopyDestination) -> Void
    let onMarkMetricsSeen: ([String]) -> Void
    let historySeriesOptionsProvider: () -> [UsageHistorySeriesOption]
    let onMetricsDiscovered: ([String]) -> Void

    @State private var resetInventoryPresentation: CodexBankedResetInventoryPresentation?
    @State private var isShowingClaudeResets = false
    @State private var claudeResetFeedback: ClaudeUsageResetFeedback?
    @State private var isUsingClaudeReset = false
    @State private var resetFeedback: CodexBankedResetRedemptionFeedback?
    @State private var isResetActionUnavailable = false
    @State private var isCustomizingMetrics = false
    @State private var isShowingMoreInformation = false
    @State private var reconnectAfterInformation = false

    /// Simulator-only fixture hook: the More Information sheet opens directly when
    /// a journey relaunches with CODEXBAR_UI_TEST_MORE_INFORMATION=1. Production
    /// builds keep the menu-only entry point.
    private static func presentsFixtureInformationSheetOnLaunch(for accountID: String) -> Bool {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        guard environment["CODEXBAR_UI_TESTS"] == "1",
              environment["CODEXBAR_UI_TEST_MORE_INFORMATION"] == "1" else { return false }
        return environment["CODEXBAR_UI_TEST_MORE_INFORMATION_ACCOUNT"].map { $0 == accountID } ?? true
        #else
        return false
        #endif
    }
    @State private var metricDetailPresentation: ProviderMetricTileDetailPresentation?
    @StateObject private var resetRedemptionController: CodexBankedResetRedemptionController
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.usageSeverityThresholds) private var severityThresholds

    init(
        result: ProviderUsageResult,
        statusText: String,
        showsSubscriptionRenewals: Bool = true,
        history: UsageHistorySeries,
        historyAccessPolicy: HistoryAccessPolicy = .pro,
        alerts: [UsageAlertDetail] = [],
        isHistoryEnabled: Bool = true,
        isRefreshing: Bool = false,
        isPausedByPlan: Bool = false,
        onMakeActive: @escaping () -> Void = {},
        isExpanded: Bool = true,
        refreshErrorMessage: String? = nil,
        recoveryAction: ProviderUsageRecoveryAction = .retryRefresh,
        isPerformingRecovery: Bool = false,
        recoveryStatusMessage: String? = nil,
        recoveryErrorMessage: String? = nil,
        onReportProblem: (() -> Void)? = nil,
        onShowHistory: @escaping () -> Void = {},
        onToggleExpansion: @escaping () -> Void = {},
        onConfigureAccount: @escaping () -> Void = {},
        onRetry: @escaping () -> Void = {},
        retainedCodexResetAttempt: CodexRetainedResetAttempt? = nil,
        onUseClaudeReset: ((ClaudeUsageResetGrant, String) async -> ClaudeUsageResetFeedback)? = nil,
        onUseCodexReset: ((String?) async -> CodexBankedResetRedemptionFeedback)? = nil,
        isMetricVisible: @escaping (String) -> Bool = { _ in true },
        onUpdateMetricVisibility: @escaping (String, Bool) -> Void = { _, _ in },
        watchVisibilityForMetric: @escaping (String) -> WatchMetricVisibilityPolicy = { _ in .inherit },
        onUpdateWatchVisibility: @escaping (String, WatchMetricVisibilityPolicy) -> Void = { _, _ in },
        visualizationStyleForMetric: @escaping (String) -> MetricVisualizationStyle = { _ in .linearBar },
        onUpdateVisualizationStyle: @escaping (String, MetricVisualizationStyle) -> Void = { _, _ in },
        onApplyVisualizationStyleToAll: @escaping (MetricVisualizationStyle, [String]) -> Void = { _, _ in },
        onResetVisualizationStyles: @escaping ([String]) -> Void = { _ in },
        metricOrder: [String] = [],
        metricWidthForMetric: @escaping (String) -> MetricTileWidthPreference = { _ in .automatic },
        onUpdateMetricWidth: @escaping (String, MetricTileWidthPreference) -> Void = { _, _ in },
        metricLayout: @escaping () -> AccountMetricLayout = { AccountMetricLayout() },
        isMetricNewlyDiscovered: @escaping (String) -> Bool = { _ in false },
        onUpdateMetricOrder: @escaping ([String]) -> Void = { _ in },
        onReplaceMetricLayout: @escaping (AccountMetricLayout) -> Void = { _ in },
        onResetMetricLayout: @escaping ([String]) -> Void = { _ in },
        copyLayoutDestinations: @escaping () -> [MetricLayoutCopyDestination] = { [] },
        onCopyMetricLayout: @escaping (MetricLayoutCopyDestination) -> Void = { _ in },
        onMarkMetricsSeen: @escaping ([String]) -> Void = { _ in },
        historySeriesOptions: @escaping () -> [UsageHistorySeriesOption] = { [] },
        onMetricsDiscovered: @escaping ([String]) -> Void = { _ in }
    ) {
        self.result = result
        self.showsSubscriptionRenewals = showsSubscriptionRenewals
        self.statusText = statusText
        self.history = history
        self.historyAccessPolicy = historyAccessPolicy
        self.alerts = alerts
        self.isHistoryEnabled = isHistoryEnabled
        self.isRefreshing = isRefreshing
        self.isPausedByPlan = isPausedByPlan
        self.onMakeActive = onMakeActive
        self.isExpanded = isExpanded
        self.refreshErrorMessage = refreshErrorMessage
        self.recoveryAction = recoveryAction
        self.isPerformingRecovery = isPerformingRecovery
        self.recoveryStatusMessage = recoveryStatusMessage
        self.recoveryErrorMessage = recoveryErrorMessage
        self.onReportProblem = onReportProblem
        self.onShowHistory = onShowHistory
        self.onToggleExpansion = onToggleExpansion
        self.onConfigureAccount = onConfigureAccount
        self.onRetry = onRetry
        self.onUseCodexReset = onUseCodexReset
        self.onUseClaudeReset = onUseClaudeReset
        self.isMetricVisible = isMetricVisible
        self.onUpdateMetricVisibility = onUpdateMetricVisibility
        self.watchVisibilityForMetric = watchVisibilityForMetric
        self.onUpdateWatchVisibility = onUpdateWatchVisibility
        self.visualizationStyleForMetric = visualizationStyleForMetric
        self.onUpdateVisualizationStyle = onUpdateVisualizationStyle
        self.onApplyVisualizationStyleToAll = onApplyVisualizationStyleToAll
        self.onResetVisualizationStyles = onResetVisualizationStyles
        self.metricOrder = metricOrder
        self.metricWidthForMetric = metricWidthForMetric
        self.onUpdateMetricWidth = onUpdateMetricWidth
        self.metricLayoutProvider = metricLayout
        self.isMetricNewlyDiscovered = isMetricNewlyDiscovered
        self.onUpdateMetricOrder = onUpdateMetricOrder
        self.onReplaceMetricLayout = onReplaceMetricLayout
        self.onResetMetricLayout = onResetMetricLayout
        self.copyLayoutDestinationsProvider = copyLayoutDestinations
        self.onCopyMetricLayout = onCopyMetricLayout
        self.onMarkMetricsSeen = onMarkMetricsSeen
        self.historySeriesOptionsProvider = {
            let options = historySeriesOptions()
            return options.isEmpty
                ? [UsageHistorySeriesOption(id: "primary", label: "Usage", series: history)]
                : options
        }
        self.onMetricsDiscovered = onMetricsDiscovered
        _isShowingMoreInformation = State(
            initialValue: Self.presentsFixtureInformationSheetOnLaunch(for: result.accountID)
        )
        _resetRedemptionController = StateObject(
            wrappedValue: CodexBankedResetRedemptionController(
                retainedAttempt: retainedCodexResetAttempt,
                resets: result.codexBankedRateLimitResets
            )
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            cardHeader
                .opacity(isPausedByPlan ? 0.6 : 1)

            SubscriptionUtilizationEmptyState(result: result)
            if isPausedByPlan {
                PausedAccountNotice(accountID: result.accountID, onMakeActive: onMakeActive)
            }
            if isExpanded {
                cardBody
                    .opacity(isPausedByPlan ? 0.6 : 1)
                    .transition(
                        accessibilityReduceMotion
                            ? .identity
                            : .opacity.combined(with: .move(edge: .top))
                    )
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
        .sheet(isPresented: $isShowingClaudeResets) {
            if let inventory = result.claudeUsageResetInventory {
                ClaudeUsageResetInventoryView(inventory: inventory, accountName: result.title,
                                              canRedeem: canUseClaudeReset, onUseReset: useClaudeReset)
            } else {
                NavigationStack {
                    VStack(spacing: 16) {
                        if isUsingClaudeReset { ProgressView("Checking Claude usage…") }
                        Text("Claude resets unavailable")
                        Text(claudeResetFeedback?.message ?? "Refresh Claude usage to check saved resets.")
                    }
                    .padding()
                    .navigationTitle("Claude resets")
                    .toolbar { Button("Done") { isShowingClaudeResets = false }.disabled(isUsingClaudeReset) }
                    .interactiveDismissDisabled(isUsingClaudeReset)
                }
            }
        }
        .sheet(item: $resetInventoryPresentation) { presentation in
            CodexBankedResetInventoryView(
                resets: presentation.resets,
                canRedeem: presentation.canRedeem,
                onUseReset: onUseCodexReset,
                onFeedback: { feedback in
                    resetFeedback = feedback
                    isResetActionUnavailable = feedback.hidesAction
                },
                redemptionController: resetRedemptionController
            )
        }
        .sheet(isPresented: $isCustomizingMetrics) {
            MetricVisualizationCustomizationView(
                accountTitle: result.title,
                result: result,
                showsSeverity: result.hasCurrentBars,
                isMetricVisible: isMetricVisible,
                onUpdateMetricVisibility: onUpdateMetricVisibility,
                watchVisibilityForMetric: watchVisibilityForMetric,
                onUpdateWatchVisibility: onUpdateWatchVisibility,
                visualizationStyleForMetric: visualizationStyleForMetric,
                onUpdateVisualizationStyle: onUpdateVisualizationStyle,
                onApplyVisualizationStyleToAll: onApplyVisualizationStyleToAll,
                onResetVisualizationStyles: onResetVisualizationStyles,
                metricWidthForMetric: metricWidthForMetric,
                onUpdateMetricWidth: onUpdateMetricWidth,
                metricLayoutProvider: metricLayoutProvider,
                isMetricNewlyDiscovered: isMetricNewlyDiscovered,
                onUpdateMetricOrder: onUpdateMetricOrder,
                onReplaceMetricLayout: onReplaceMetricLayout,
                onResetMetricLayout: onResetMetricLayout,
                copyLayoutDestinationsProvider: copyLayoutDestinationsProvider,
                onCopyMetricLayout: onCopyMetricLayout,
                onMarkMetricsSeen: onMarkMetricsSeen
            )
        }
        .sheet(isPresented: $isShowingMoreInformation, onDismiss: reconnectFromInformation, content: {
            ProviderCardInformationView(
                sections: informationSections,
                greptileRenewal: greptileRenewal,
                onConnect: {
                    reconnectAfterInformation = true
                    isShowingMoreInformation = false
                },
                showsBillingSettings: result.canOpenClaudeBillingSettings
            )
        })
        .sheet(item: $metricDetailPresentation) { presentation in
            if let metric = Self.metric(withID: presentation.metricID, in: result) {
                ProviderMetricTileDetailView(
                    result: result,
                    statusText: statusText,
                    metric: metric,
                    history: metricDetailHistorySeries(for: metric),
                    visualizationStyle: resolvedVisualizationStyle(for: metric)
                )
            }
        }
        .task(id: result.configurableMetrics.map(\.id)) {
            onMetricsDiscovered(result.configurableMetrics.map(\.id))
        }
        .onChange(of: result.accountID) {
            isShowingClaudeResets = false
            claudeResetFeedback = nil
        }
        .onChange(of: result.fetchedAt) {
            resetInventoryPresentation = Self.reconciledResetInventoryPresentation(
                current: resetInventoryPresentation,
                requestedResets: bankedResets,
                canRedeem: showsCodexResetRedemptionActions,
                requestsPresentation: false
            )
            isResetActionUnavailable = false
            resetFeedback = nil
        }
        .onChange(of: result.configurableMetrics.map(\.id)) {
            guard let metricID = metricDetailPresentation?.metricID else {
                return
            }
            if Self.metric(withID: metricID, in: result) == nil {
                metricDetailPresentation = nil
            }
        }
        .onChange(of: informationSections) {
            guard result.providerID != .greptile else { return }
            isShowingMoreInformation = Self.reconciledMoreInformationPresentation(
                currentlyPresented: isShowingMoreInformation,
                sections: informationSections
            )
        }
    }

    private var cardHeader: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            cardHeader(at: context.date)
        }
    }

    private func cardHeader(at now: Date) -> some View {
        ZStack(alignment: Alignment(horizontal: .trailing, vertical: .firstTextBaseline)) {
            Button(action: toggleExpansion) {
                HStack(alignment: .firstTextBaseline, spacing: Self.headerControlSpacing) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .top, spacing: 8) {
                            ProviderLogoTile(providerID: result.providerID)

                            ViewThatFits(in: .horizontal) {
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text(result.title)
                                        .font(.headline)
                                        .fixedSize(horizontal: true, vertical: false)

                                    headerBadges(at: now)
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(result.title)
                                        .font(.headline)
                                        .fixedSize(horizontal: false, vertical: true)

                                    headerBadges(at: now)
                                }
                            }
                        }

                        if !statusText.isEmpty {
                            Text(statusText)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        if let hiddenSeverityAlert {
                            Label(
                                hiddenSeverityAlert.message,
                                systemImage: hiddenSeverityAlert.kind.systemImageName
                            )
                            .font(.caption)
                            .foregroundStyle(hiddenSeverityAlert.severity.tint)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Spacer()

                    ZStack {
                        if isRefreshing || isPerformingRecovery {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                    .frame(width: 16, height: 16)

                    Color.clear
                        .frame(width: Self.menuControlSize, height: Self.menuControlSize)
                        // A non-text view defaults its text baseline to its bottom edge.
                        // Reserve the full hit area without pushing the heading below it.
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] }

                    Circle()
                        .fill(cardSeverity.tint)
                        .frame(width: Self.severityDotSize, height: Self.severityDotSize)

                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: Self.chevronSlotSize)
                        .rotationEffect(.degrees(disclosureChevronRotation))
                        .animation(
                            accessibilityReduceMotion ? nil : .easeInOut(duration: 0.2),
                            value: isExpanded
                        )
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(disclosureAccessibilityLabel(at: now))
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(disclosureAccessibilityHint)

            // This topmost sibling owns the menu hit area, so menu taps never
            // reach the disclosure button underneath it.
            Menu {
                ForEach(
                    Self.menuActions(
                        for: result,
                        alerts: displayedAlerts,
                        isMetricVisible: isMetricVisible
                    ),
                    id: \.self
                ) { action in
                    switch action {
                    case .moreInformation:
                        Button {
                            isShowingMoreInformation = true
                        } label: {
                            Label("More Information…", systemImage: "info.circle")
                        }
                        .accessibilityLabel("More information for \(result.title)")
                    case .configureAccount:
                        Button(action: onConfigureAccount) {
                            Label("Configure Account…", systemImage: "gearshape")
                        }
                        .accessibilityLabel("Configure account \(result.title)")
                    case .customizeMetrics:
                        Button {
                            isCustomizingMetrics = true
                        } label: {
                            Label("Customize Card…", systemImage: "gauge.with.dots.needle.50percent")
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.body)
                    .frame(width: Self.menuControlSize, height: Self.menuControlSize)
                    .background(Color(.secondarySystemGroupedBackground))
            }
            .padding(.trailing, Self.menuTrailingOffset)
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] }
            .accessibilityLabel("More options for \(result.title)")
        }
    }

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !inlineAlerts.isEmpty {
                UsageAlertSummaryView(alerts: inlineAlerts)
            }

            if showsRecoveryAction {
                Button(action: onRetry) {
                    Label(recoveryActionTitle, systemImage: recoveryActionSystemImage)
                        .frame(minHeight: result.providerID == .cursor ? 44 : nil)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityHint(recoveryAccessibilityHint)
            }

            CursorStaleUsageNotice(result: result)

            if let recoveryStatusMessage {
                Text(recoveryStatusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let recoveryErrorMessage {
                Text(recoveryErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let refreshErrorMessage {
                ProviderProblemReportDisclosure(
                    title: "Refresh problem details",
                    message: refreshErrorMessage,
                    onReport: onReportProblem
                )
            }

            if let greptileRenewal {
                GreptileRenewalView(renewal: greptileRenewal, onConnect: onConfigureAccount)
            }

            if !metricGridRows.isEmpty {
                Grid(alignment: .topLeading, horizontalSpacing: 10, verticalSpacing: 10) {
                    ForEach(metricGridRows) { row in
                        GridRow(alignment: .top) {
                            metricTile(row.leading)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                .gridCellColumns(row.leading.width == .full ? 2 : 1)

                            if let trailing = row.trailing {
                                metricTile(trailing)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            } else if row.leading.width == .half {
                                Color.clear
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                }
            }

            if result.providerID == .claude {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Label(claudeResetAvailabilityText(at: context.date), systemImage: "arrow.counterclockwise.circle")
                                .font(.caption)
                                .accessibilityIdentifier("claude-reset-availability-\(result.accountID)")
                            if let expiration = claudeResetExpirationText(at: context.date) {
                                Text(expiration).font(.caption2)
                                    .accessibilityIdentifier("claude-reset-expiration-\(result.accountID)")
                            }
                        }
                        .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        if result.claudeUsageResetInventory != nil {
                            Button("View Resets") { isShowingClaudeResets = true }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .accessibilityIdentifier("claude-view-resets-\(result.accountID)")
                        }
                    }
                }
                if let feedback = claudeResetFeedback {
                    Label(feedback.message, systemImage: feedback.isSuccess ? "checkmark.circle" : "info.circle")
                        .font(.caption2)
                        .accessibilityIdentifier("claude-reset-card-feedback-\(result.accountID)")
                }
            }

            if bankedResets != nil {
                HStack(spacing: 8) {
                    Label(bankedResetAvailabilityText, systemImage: "arrow.counterclockwise.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(bankedResetAvailabilityText)

                    Spacer(minLength: 8)

                    if showsCodexResetInventoryAction {
                        Button {
                            resetInventoryPresentation = Self.reconciledResetInventoryPresentation(
                                current: resetInventoryPresentation,
                                requestedResets: bankedResets,
                                canRedeem: showsCodexResetRedemptionActions,
                                requestsPresentation: true
                            )
                        } label: {
                            Text(resetInventoryActionTitle)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityHint("Shows each available banked reset and its expiration")
                    }
                }

            }

            if let resetFeedback = resetPresentationFeedback {
                Label(
                    resetFeedback.message,
                    systemImage: resetFeedback.isSuccess ? "checkmark.circle" : "info.circle"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(resetFeedback.message)
            }

            ForEach(result.dashboardUsageMessages, id: \.self) { message in
                Label(message, systemImage: "info.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(message)
            }

            if showsHistory {
                UsageHistoryCompactView(
                    series: history,
                    onShowHistory: onShowHistory
                )
            }
        }
    }

    private func disclosureAccessibilityLabel(at now: Date) -> String {
        Self.disclosureAccessibilityLabel(
            for: result,
            statusText: statusText,
            isRefreshing: isRefreshing,
            isPerformingRecovery: isPerformingRecovery,
            severity: cardSeverity,
            severitySource: hiddenSeverityAlert?.message,
            showsSubscriptionRenewals: showsSubscriptionRenewals,
            now: now
        )
    }

    private var disclosureAccessibilityHint: String {
        Self.disclosureAccessibilityHint(isExpanded: isExpanded, title: result.title)
    }

    private var disclosureChevronRotation: Double {
        guard !isExpanded else {
            return 0
        }
        return layoutDirection == .rightToLeft ? 90 : -90
    }

    private func toggleExpansion() {
        withAnimation(accessibilityReduceMotion ? nil : .easeInOut(duration: 0.2)) {
            onToggleExpansion()
        }
    }

    static func disclosureAccessibilityHint(isExpanded: Bool, title: String) -> String {
        isExpanded ? "Collapse \(title)" : "Expand \(title)"
    }

    static func disclosureAccessibilityLabel(
        for result: ProviderUsageResult,
        statusText: String,
        isRefreshing: Bool,
        isPerformingRecovery: Bool,
        severity: UsageSeverity,
        severitySource: String? = nil,
        showsSubscriptionRenewals: Bool = true,
        now: Date = Date()
    ) -> String {
        var components = [headerAccessibilityLabel(for: result), statusText]
        if showsSubscriptionRenewals, let text = result.boundSubscriptionRenewal?.accessibilityText(at: now) {
            components.append(text)
        }
        if isPerformingRecovery {
            components.append("Signing in")
        } else if isRefreshing {
            components.append("Refreshing")
        }
        switch severity {
        case .normal:
            components.append("Normal status")
        case .warning:
            components.append("Warning status")
        case .critical:
            components.append("Critical status")
        }
        if let severitySource {
            components.append(severitySource)
        }
        return components.joined(separator: ", ")
    }

    private var cardSeverity: UsageSeverity {
        max(
            result.highestSeverity(thresholds: severityThresholds),
            alerts.map(\.severity).max() ?? .normal
        )
    }

    private var hiddenSeverityAlert: UsageAlertDetail? {
        Self.hiddenSeverityAlert(
            for: result,
            cardSeverity: cardSeverity,
            alerts: alerts,
            thresholds: severityThresholds,
            isMetricVisible: isMetricVisible
        )
    }

    static func hiddenSeverityAlert(
        for result: ProviderUsageResult,
        cardSeverity: UsageSeverity,
        alerts: [UsageAlertDetail] = [],
        thresholds: UsageSeverityThresholds = .default,
        now: Date = Date(),
        isMetricVisible: (String) -> Bool
    ) -> UsageAlertDetail? {
        let bars = result.hasFreshBars
            ? result.bars.enumerated().map { index, bar in
                (
                    bar: bar,
                    metricID: bar.metricIdentifier(providerID: result.providerID, index: index),
                    severity: bar.effectiveSeverity(at: now, thresholds: thresholds)
                )
            }
            : []
        let strongestVisibleSeverity = bars
            .filter { isMetricVisible($0.metricID) }
            .map(\.severity)
            .max() ?? .normal
        let strongestHiddenSeverity = bars
            .filter { !isMetricVisible($0.metricID) }
            .map(\.severity)
            .max() ?? .normal

        if
            strongestHiddenSeverity >= .warning,
            strongestHiddenSeverity > strongestVisibleSeverity,
            strongestHiddenSeverity == cardSeverity,
            let hiddenMetric = bars.first(where: {
                !isMetricVisible($0.metricID) && $0.severity == strongestHiddenSeverity
            }) {
            return hiddenUsageAlert(
                for: hiddenMetric,
                result: result,
                severity: strongestHiddenSeverity,
                thresholds: thresholds,
                now: now
            )
        }

        if
            cardSeverity == .critical,
            strongestVisibleSeverity < .critical,
            result.hasReachedSpendLimit,
            let spentMetric = result.configurableMetrics.first(where: { metric in
                guard case let .monetary(index) = metric.kind else {
                    return false
                }
                return result.monetaryMetrics.indices.contains(index)
                    && result.monetaryMetrics[index].kind == .spent
                    && !isMetricVisible(metric.id)
            }),
            case let .monetary(spentIndex) = spentMetric.kind {
            let spent = result.monetaryMetrics[spentIndex]
            let limit = result.monetaryMetrics.first(where: { $0.kind == .spendLimit })
            let limitDescription = limit.map { limit in
                if result.failureMessage == nil {
                    return " and has reached the \(limit.formattedAmount()) limit"
                }
                return " and was last known to have reached the \(limit.formattedAmount()) limit"
            } ?? ""
            let valueStatus = result.failureMessage == nil ? "is currently at" : "was last known at"
            return UsageAlertDetail(
                id: "hidden-severity.\(spentMetric.id)",
                accountID: result.accountID,
                kind: .severity,
                title: "Critical status from hidden metric",
                message: "Hidden metric \(spent.label) \(valueStatus) \(spent.formattedAmount())"
                    + "\(limitDescription).",
                severity: .critical
            )
        }

        if
            strongestVisibleSeverity < cardSeverity,
            let balanceAlert = alerts.first(where: {
                $0.kind == .balance && $0.severity == cardSeverity
            }),
            let creditMetric = result.configurableMetrics.first(where: { metric in
                guard case .creditsRemaining = metric.kind else {
                    return false
                }
                return !isMetricVisible(metric.id)
            }),
            let creditsRemaining = result.creditsRemaining {
            let valueStatus = result.hasCurrentCredits ? "is currently at" : "was last known at"
            return UsageAlertDetail(
                id: "hidden-severity.\(creditMetric.id)",
                accountID: result.accountID,
                kind: .balance,
                title: "\(balanceAlert.title) from hidden metric",
                message: "Hidden metric \(creditMetric.label) \(valueStatus) "
                    + "\(CodexBarCurrencyText.format(creditsRemaining)).",
                severity: balanceAlert.severity
            )
        }

        return nil
    }

    private static func hiddenUsageAlert(
        for hiddenMetric: (bar: UsageBar, metricID: String, severity: UsageSeverity),
        result: ProviderUsageResult,
        severity: UsageSeverity,
        thresholds: UsageSeverityThresholds,
        now: Date
    ) -> UsageAlertDetail {
        let valueStatus = result.hasCurrentBars ? "is currently at" : "was last known at"
        let message: String
        if hiddenMetric.bar.severity(using: thresholds) < severity,
           let projectedFraction = hiddenMetric.bar.projectedFraction(at: now) {
            let projectedPercent = Int((projectedFraction * 100).rounded())
            let projectionStatus = result.hasCurrentBars ? "and projected" : "and was projected"
            message = "Hidden metric \(hiddenMetric.bar.label) \(valueStatus) "
                + "\(hiddenMetric.bar.usageText) "
                + "\(projectionStatus) to reach \(projectedPercent)%."
        } else {
            message = "Hidden metric \(hiddenMetric.bar.label) \(valueStatus) "
                + "\(hiddenMetric.bar.usageText)."
        }
        let severityName = severity == .critical ? "Critical" : "Warning"

        return UsageAlertDetail(
            id: "hidden-severity.\(hiddenMetric.metricID)",
            accountID: result.accountID,
            kind: .severity,
            title: "\(severityName) status from hidden metric",
            message: message,
            severity: severity
        )
    }

    @ViewBuilder
    private func headerBadges(at now: Date) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if result.showsCardPlan { planBadge }
                renewalBadge(at: now)
            }
            .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 4) {
                if result.showsCardPlan { planBadge }
                renewalBadge(at: now)
            }
        }
    }

    @ViewBuilder
    private func renewalBadge(at now: Date) -> some View {
        if showsSubscriptionRenewals, let text = result.boundSubscriptionRenewal?.compactLabel(at: now) {
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.secondary.opacity(0.10), in: Capsule())
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHidden(true)
        }
    }

    private var planBadge: some View {
        Text(result.cardPlan.displayLabel)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background {
                Capsule()
                    .fill(Color.secondary.opacity(0.14))
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityHidden(true)
    }

    static func headerAccessibilityLabel(for result: ProviderUsageResult) -> String {
        result.showsCardPlan ? "\(result.title), \(result.cardPlan.accessibilityLabel)" : result.title
    }

    static func menuActions(
        for result: ProviderUsageResult,
        alerts: [UsageAlertDetail] = [],
        isMetricVisible: (String) -> Bool = { _ in true }
    ) -> [ProviderUsageCardMenuAction] {
        var actions: [ProviderUsageCardMenuAction] = []
        if result.providerID == .greptile || !informationSections(for: result, alerts: alerts).isEmpty {
            actions.append(.moreInformation)
        }
        if result.configurableMetrics.isEmpty {
            actions.append(.configureAccount)
            return actions
        }
        actions.append(contentsOf: [.configureAccount, .customizeMetrics])
        return actions
    }

    static func informationSections(
        for result: ProviderUsageResult,
        alerts: [UsageAlertDetail] = [],
        now: Date = Date()
    ) -> [ProviderCardInformationSection] {
        var sections = result.cardInformationSections
        if let billing = result.subscriptionBillingInformation(at: now) { sections.append(billing) }
        if result.providerID == .cursor, !alerts.isEmpty {
            sections.append(ProviderCardInformationSection(
                id: "cursor.active-alerts",
                title: "Active alerts",
                items: alerts.map {
                    ProviderCardInformationItem(
                        id: "cursor.alert.\($0.id)",
                        label: $0.title,
                        detail: $0.message
                    )
                }
            ))
        }
        return sections.filter { !$0.items.isEmpty }
    }

    static func reconciledMoreInformationPresentation(
        currentlyPresented: Bool,
        sections: [ProviderCardInformationSection]
    ) -> Bool {
        currentlyPresented && !sections.isEmpty
    }

    static func showsMetricVisibilityControls(
        for result: ProviderUsageResult,
        isMetricVisible: (String) -> Bool
    ) -> Bool {
        result.configurableMetrics.count > 1
            || result.configurableMetrics.contains { !isMetricVisible($0.id) }
    }

    static func metricVisibilityAccessibilityValue(isVisible: Bool) -> String {
        isVisible ? "Shown" : "Hidden"
    }

    var displayedAlerts: [UsageAlertDetail] {
        guard result.providerID == .codex else {
            return alerts
        }
        return alerts.filter { $0.kind != .usage }
    }

    var inlineAlerts: [UsageAlertDetail] {
        result.providerID == .cursor ? [] : displayedAlerts
    }

    private func reconnectFromInformation() {
        guard reconnectAfterInformation else { return }
        reconnectAfterInformation = false
        // Let SwiftUI finish removing this sheet before the dashboard presents settings.
        DispatchQueue.main.async {
            onConfigureAccount()
        }
    }

    private var greptileRenewal: GreptileAllowanceRenewal? {
        guard result.providerID == .greptile else { return nil }
        if let renewal = result.greptileAllowanceRenewal, renewal.isApplicable == false && !renewal.requiresAuthentication { return nil }
        return result.greptileAllowanceRenewal ?? GreptileAllowanceRenewal(
            renewsAt: nil, observedAt: result.fetchedAt,
            unavailableReason: "Connect Greptile to read the allowance renewal date.", requiresAuthentication: true, isApplicable: nil
        )
    }

    var informationSections: [ProviderCardInformationSection] {
        Self.informationSections(for: result, alerts: displayedAlerts)
    }

    var showsHistory: Bool {
        isHistoryEnabled && (result.creditsRemaining != nil
            || !result.usageHistoryBars().isEmpty
            || !result.monetaryMetrics.isEmpty
            || !history.points.isEmpty)
    }

    var showsRecoveryAction: Bool {
        !isPausedByPlan && refreshErrorMessage != nil && !isRefreshing && !isPerformingRecovery
    }

    var showsRetryAction: Bool {
        showsRecoveryAction && recoveryAction == .retryRefresh
    }

    var recoveryActionTitle: String {
        switch recoveryAction {
        case .retryRefresh:
            "Retry"
        case .signIn:
            result.providerID == .cursor ? "Sign in with Cursor"
                : result.providerID == .claude ? "Sign in with Claude" : "Open account settings"
        case .reauthenticate:
            result.providerID == .cursor ? "Reconnect Cursor"
                : result.providerID == .claude ? "Sign in again" : "Update credentials"
        }
    }

    var recoveryActionSystemImage: String {
        switch recoveryAction {
        case .retryRefresh:
            "arrow.clockwise"
        case .signIn, .reauthenticate:
            "person.badge.key"
        }
    }

    var recoveryAccessibilityHint: String {
        switch recoveryAction {
        case .retryRefresh:
            "Retries refreshing usage for \(result.title)"
        case .signIn:
            ProviderSignInAccessibility.hint(providerID: result.providerID, title: result.title, reconnecting: false)
        case .reauthenticate:
            ProviderSignInAccessibility.hint(providerID: result.providerID, title: result.title, reconnecting: true)
        }
    }

    private func claudeResetAvailabilityText(at date: Date) -> String {
        guard let inventory = result.claudeUsageResetInventory else { return "Saved resets unavailable" }
        let count = inventory.availableCount(at: date)
        return count == 1 ? "1 saved reset available" : "\(count) saved resets available"
    }

    private func claudeResetExpirationText(at date: Date) -> String? {
        guard let inventory = result.claudeUsageResetInventory, inventory.isEligible else { return nil }
        let expiry = inventory.grants.filter { $0.isCurrent(at: date) }.compactMap(\.expiresAt).min()
        return expiry.map { "Next reset expires \($0.formatted(date: .abbreviated, time: .shortened))" }
    }

    private var canUseClaudeReset: Bool {
        !isPausedByPlan && result.providerID == .claude && result.failureMessage == nil && refreshErrorMessage == nil
            && !isRefreshing && !isPerformingRecovery && !isUsingClaudeReset && onUseClaudeReset != nil
            && result.claudeUsageResetInventory?.credentialBinding != nil
    }

    private func useClaudeReset(grant: ClaudeUsageResetGrant, binding: String) async -> ClaudeUsageResetFeedback {
        guard canUseClaudeReset, let onUseClaudeReset else {
            return ClaudeUsageResetFeedback(message: "Refresh Claude usage before using a reset.", isSuccess: false)
        }
        isUsingClaudeReset = true
        defer { isUsingClaudeReset = false }
        let feedback = await onUseClaudeReset(grant, binding)
        claudeResetFeedback = feedback
        return feedback
    }

    var bankedResets: CodexBankedRateLimitResets? {
        guard
            result.providerID == .codex,
            let resets = result.codexBankedRateLimitResets,
            resets.availableCount > 0
        else {
            return nil
        }
        return resets
    }

    var bankedResetAvailabilityText: String {
        guard let count = bankedResets?.availableCount else {
            return ""
        }
        return count == 1 ? "1 reset available" : "\(count) resets available"
    }

    var showsCodexResetInventoryAction: Bool {
        bankedResets != nil
    }

    var resetInventoryActionTitle: String {
        "View Resets"
    }

    var showsCodexResetRedemptionActions: Bool {
        !isPausedByPlan && bankedResets?.canConsume == true
            && onUseCodexReset != nil
            && !isResetActionUnavailable
    }

    var resetPresentationFeedback: CodexBankedResetRedemptionFeedback? {
        Self.resetPresentationFeedback(resetFeedback, availableResets: bankedResets)
    }

    static func resetPresentationFeedback(
        _ feedback: CodexBankedResetRedemptionFeedback?,
        availableResets _: CodexBankedRateLimitResets?
    ) -> CodexBankedResetRedemptionFeedback? {
        feedback
    }

    static func reconciledResetInventoryPresentation(
        current: CodexBankedResetInventoryPresentation?,
        requestedResets: CodexBankedRateLimitResets?,
        canRedeem: Bool,
        requestsPresentation: Bool
    ) -> CodexBankedResetInventoryPresentation? {
        if let current {
            return current
        }
        guard requestsPresentation, let requestedResets else {
            return nil
        }
        return CodexBankedResetInventoryPresentation(
            resets: requestedResets,
            canRedeem: canRedeem
        )
    }

    private var metricGridRows: [ProviderMetricTileGridRow] {
        ProviderMetricTileGridResolver.rows(
            metrics: result.configurableMetrics.filter { isMetricVisible($0.id) },
            orderedMetricIDs: metricOrder,
            widthForMetric: metricWidthForMetric,
            visualizationStyleForMetric: { metricID in
                guard let metric = Self.metric(withID: metricID, in: result) else {
                    return visualizationStyleForMetric(metricID)
                }
                return resolvedVisualizationStyle(for: metric)
            },
            usesRegularHorizontalSizeClass: horizontalSizeClass == .regular,
            collapsesToSingleColumn: dynamicTypeSize.isAccessibilitySize
        )
    }

    private func metricTile(_ item: ProviderMetricTileGridItem) -> some View {
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            Button {
                metricDetailPresentation = ProviderMetricTileDetailPresentation(metricID: item.metric.id)
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    metricTileContent(item)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(12)
                .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(.separator).opacity(0.22), lineWidth: 0.5)
                }
                .contentShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("dashboard-metric-\(item.metric.id)")
            .accessibilityLabel(metricAccessibilityLabel(item.metric))
            .accessibilityHint(Self.metricDetailAccessibilityHint)
            .accessibilityAddTraits(.isButton)
        }
    }

    @ViewBuilder
    private func metricTileContent(_ item: ProviderMetricTileGridItem) -> some View {
        switch ProviderMetricTileContent.resolve(metric: item.metric, result: result, isFullWidth: item.width == .full) {
        case let .usageBar(bar):
            usageTileContent(item, bar: bar)
        case let .unavailableUsage(reason):
            unavailableTileContent(label: item.metric.label, reason: reason)
            if item.metric.id.contains("weekly") { SubscriptionUtilizationBadge(score: nil) }
        case let .creditsRemaining(value, detail):
            creditsTileContent(label: item.metric.label, value: value, detail: detail)
        case let .monetary(metric, detail):
            monetaryTileContent(metric: metric, detail: detail)
        case .empty:
            EmptyView()
        }
    }

    @ViewBuilder
    private func unavailableTileContent(label: String, reason: String) -> some View {
        Text(label)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.primary)
        Text(reason)
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func creditsTileContent(label: String, value: Double, detail: String?) -> some View {
        Text(label)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.primary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)

        Text(CodexBarCurrencyText.format(value))
            .font(.system(.title3, design: .rounded, weight: .semibold))
            .foregroundStyle(.primary)
            .monospacedDigit()
            .minimumScaleFactor(0.7)
            .lineLimit(1)

        if let detail {
            supportingText(detail)
        }
    }

    @ViewBuilder
    private func monetaryTileContent(metric: ProviderMonetaryMetric, detail: String?) -> some View {
        Text(metric.label)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.primary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)

        Text(metric.formattedAmount())
            .font(.system(.title3, design: .rounded, weight: .semibold))
            .foregroundStyle(.primary)
            .monospacedDigit()
            .minimumScaleFactor(0.65)
            .lineLimit(1)

        if let detail {
            supportingText(detail)
        }
    }

    private func usageTileContent(_ item: ProviderMetricTileGridItem, bar: UsageBar) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.metric.label)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            let visualizationStyle = resolvedVisualizationStyle(for: item.metric)
            if visualizationStyle.showsStandaloneMetricTileValue && !bar.isUnboundedNumeric {
                Text(bar.usageText)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
            }
            MetricVisualizationView(bar: bar, style: visualizationStyle, showsSeverity: result.hasCurrentBars)
            SubscriptionUtilizationMetricView(bar: bar, isCurrent: result.hasCurrentBars)
            let githubAllowanceSummary = result.providerID == .githubBilling
                ? Self.githubAllowanceSummary(bar)
                : nil
            if let githubAllowanceSummary {
                allowanceSupportingText(githubAllowanceSummary)
            }
            if result.providerID == .gemini || result.providerID == .antigravity {
                supportingText(result.hasCurrentBars ? "Percent used · Current" : "Percent used · Last known value")
            }
            usageTileResetDetails(item: item, bar: bar, showsAllowanceSummary: githubAllowanceSummary != nil)
        }
    }

    @ViewBuilder
    private func usageTileResetDetails(
        item: ProviderMetricTileGridItem,
        bar: UsageBar,
        showsAllowanceSummary: Bool
    ) -> some View {
        if item.width == .full || showsAllowanceSummary {
            if let resetDescription = bar.localizedResetDescription() {
                supportingText(resetDescription)
            }
            if result.hasCurrentBars, let projectionDescription = bar.dashboardProjectionDescription() {
                supportingText(projectionDescription)
            }
        }
    }

    private func resolvedVisualizationStyle(
        for metric: ProviderUsageMetric
    ) -> MetricVisualizationStyle {
        let preferredStyle = visualizationStyleForMetric(metric.id)
        guard case let .usageBar(index) = metric.kind, result.bars.indices.contains(index) else {
            return preferredStyle
        }
        return result.bars[index].resolvedVisualizationStyle(preferredStyle)
    }

    private func allowanceSupportingText(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func supportingText(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    func metricDetailHistorySeries(for metric: ProviderUsageMetric) -> UsageHistorySeries? {
        unfilteredMetricDetailHistorySeries(for: metric)?
            .filtered(to: .threeMonths, accessPolicy: historyAccessPolicy)
    }

    private func unfilteredMetricDetailHistorySeries(for metric: ProviderUsageMetric) -> UsageHistorySeries? {
        guard isHistoryEnabled else {
            return nil
        }

        let preferredOptionID: String?
        switch metric.kind {
        case let .usageBar(index):
            if result.providerID == .greptile,
               result.bars.indices.contains(index),
               let stableKey = result.bars[index].stableKey,
               let seriesID = GreptileUsageIdentity.historySeriesID(forStableKey: stableKey) {
                return historySeriesOptionsProvider()
                    .first(where: {
                        $0.id == seriesID
                    })?
                    .series
            }
            guard
                result.providerID == .cursor,
                result.bars.indices.contains(index),
                let stableKey = result.bars[index].stableKey
            else {
                // Other providers still expose a card-wide aggregate usage series,
                // which is not accurate for one selected bar.
                return nil
            }
            return historySeriesOptionsProvider()
                .first(where: { $0.id == "usage.\(stableKey)" })?
                .series
        case .unavailableUsage:
            return nil
        case .creditsRemaining:
            preferredOptionID = "balance"
        case let .monetary(index):
            preferredOptionID = result.monetaryMetrics.indices.contains(index)
                ? "money.\(result.monetaryMetrics[index].id)"
                : nil
        }
        let options = historySeriesOptionsProvider()
        return options.first(where: { $0.id == preferredOptionID })?.series
            ?? (options.count == 1 ? options.first?.series : nil)
    }

    static func metric(
        withID metricID: String,
        in result: ProviderUsageResult
    ) -> ProviderUsageMetric? {
        result.configurableMetrics.first { $0.id == metricID }
    }

    private func metricAccessibilityLabel(_ metric: ProviderUsageMetric) -> String {
        switch metric.kind {
        case let .usageBar(index) where result.bars.indices.contains(index):
            return Self.usageMetricAccessibilityLabel(
                result.bars[index],
                in: result,
                thresholds: severityThresholds
            )
        case let .unavailableUsage(reason):
            return "\(metric.label), \(reason)" + (metric.id.contains("weekly") ? ", SUS unavailable" : "")
        case .creditsRemaining:
            return [
                metric.label,
                result.creditsRemaining.map { CodexBarCurrencyText.format($0) },
                result.hasCurrentCredits ? "fresh" : "stale",
            ]
            .compactMap { $0 }
            .joined(separator: ", ")
        case let .monetary(index) where result.monetaryMetrics.indices.contains(index):
            let monetaryMetric = result.monetaryMetrics[index]
            return [
                monetaryMetric.label,
                monetaryMetric.formattedAmount(),
                Self.isCritical(monetaryMetric, in: result) ? "critical" : "normal",
                monetaryFreshnessDescription.lowercased(),
                monetaryMetric.detail,
            ]
            .compactMap { $0 }
            .joined(separator: ", ")
        default:
            return metric.label
        }
    }

    static func usageMetricAccessibilityLabel(
        _ bar: UsageBar,
        in result: ProviderUsageResult,
        thresholds: UsageSeverityThresholds = .default
    ) -> String {
        if bar.isUnboundedNumeric {
            return [
                bar.label,
                bar.usageText,
                result.hasCurrentBars ? "fresh" : "stale",
            ]
            .joined(separator: ", ")
        }

        let usageDescription = result.providerID == .githubBilling
            ? Self.githubAllowanceSummary(bar)
            : nil
        return [
            bar.label,
            bar.usageText,
            usageDescription
                ?? "\(Self.formattedUsageAmount(bar.used)) of \(Self.formattedUsageAmount(bar.limit)) used",
            result.hasCurrentBars
                ? bar.effectiveSeverity(thresholds: thresholds).accessibilityName
                : "status unavailable",
            result.hasCurrentBars ? "fresh" : "stale",
            bar.localizedResetDescription(),
            result.hasCurrentBars ? bar.dashboardProjectionDescription() : nil,
            SubscriptionUtilizationScore.applies(to: bar)
                ? (result.hasCurrentBars ? SubscriptionUtilizationScore(bar: bar)?.accessibilityText : nil) ?? "SUS unavailable" : nil,
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }

    static func githubAllowanceSummary(_ bar: UsageBar) -> String? {
        guard let stableKey = bar.stableKey, let unit = githubAllowanceUnits[stableKey] else { return nil }
        let used = formattedAllowanceAmount(bar.used)
        let included = formattedAllowanceAmount(bar.limit)
        let difference = bar.limit - bar.used
        if difference >= 0 {
            return "\(used) \(unit) used · \(included) included · "
                + "\(formattedAllowanceAmount(difference)) remaining"
        }
        return "\(used) \(unit) used · \(included) included · "
            + "\(formattedAllowanceAmount(-difference)) over"
    }

    private static func formattedAllowanceAmount(_ value: Double) -> String {
        value > 0 && value < 0.01 ? "<0.01" : formattedUsageAmount(value)
    }

    static func formattedUsageAmount(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)))
    }

    private static let githubAllowanceUnits = [
        "actions-allowance-minutes": "minutes",
        "actions-storage": "GB",
        "packages-storage": "GB",
        "lfs-storage": "GB-hours",
        "codespaces-storage": "GB-hours",
        "packages-data-transfer": "GB",
        "lfs-bandwidth": "GB",
        "codespaces-core-hours": "core hours",
    ]

    static let metricDetailAccessibilityHint = "Shows complete metric details."

    static func isCritical(
        _ monetaryMetric: ProviderMonetaryMetric,
        in result: ProviderUsageResult
    ) -> Bool {
        monetaryMetric.kind == .spent && result.hasReachedSpendLimit
    }

    var monetaryFreshnessDescription: String {
        result.failureMessage == nil ? "Current" : "Last known value"
    }
}

struct CodexBankedResetInventoryItem: Identifiable, Equatable, Sendable {
    let id: String
    let creditID: String?
    let title: String
    let detail: String
    let expiration: String

    init(
        credit: CodexBankedRateLimitReset,
        dateTimeFormatter: UserFacingDateTimeFormatter = .current
    ) {
        id = credit.id
        creditID = credit.id
        title = Self.nonempty(credit.title) ?? "Banked reset"
        detail = Self.nonempty(credit.description) ?? "No description provided."
        expiration = credit.expiresAt.map {
            "Expires \(dateTimeFormatter.dateAndTime($0))"
        } ?? "Expiration unavailable"
    }

    static func generic() -> CodexBankedResetInventoryItem {
        CodexBankedResetInventoryItem(
            id: "generic-banked-reset",
            creditID: nil,
            title: "Use one banked reset",
            detail: "Individual reset details are unavailable for this account.",
            expiration: "Expiration unavailable"
        )
    }

    private init(
        id: String,
        creditID: String?,
        title: String,
        detail: String,
        expiration: String
    ) {
        self.id = id
        self.creditID = creditID
        self.title = title
        self.detail = detail
        self.expiration = expiration
    }

    var confirmationMessage: String {
        if creditID == nil {
            return "This will use one banked reset for the current ChatGPT account. Individual reset details and expiration are unavailable."
        }
        return "This will use the selected banked reset for the current ChatGPT account. \(detail) \(expiration)."
    }

    var accessibilityLabel: String {
        "\(title), \(detail), \(expiration), available"
    }

    private static func nonempty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

@MainActor
final class CodexBankedResetRedemptionController: ObservableObject {
    @Published private(set) var selectedItem: CodexBankedResetInventoryItem?
    @Published private(set) var pendingItem: CodexBankedResetInventoryItem?
    @Published private(set) var retryItem: CodexBankedResetInventoryItem?

    var pendingItemID: String? {
        pendingItem?.id
    }

    var retryItemID: String? {
        retryItem?.id
    }

    var isConfirmationPresented: Bool {
        selectedItem != nil
    }

    init(
        retainedAttempt: CodexRetainedResetAttempt? = nil,
        resets: CodexBankedRateLimitResets? = nil
    ) {
        guard let retainedAttempt else {
            return
        }
        if
            let creditID = retainedAttempt.creditID,
            let credit = resets?.credits?.first(where: { $0.id == creditID }) {
            retryItem = CodexBankedResetInventoryItem(credit: credit)
        } else if let creditID = retainedAttempt.creditID {
            retryItem = CodexBankedResetInventoryItem(
                credit: CodexBankedRateLimitReset(id: creditID)
            )
        } else {
            retryItem = .generic()
        }
    }

    func requestConfirmation(for item: CodexBankedResetInventoryItem) {
        guard canRequestConfirmation(for: item) else {
            return
        }
        selectedItem = item
    }

    func cancelConfirmation() {
        selectedItem = nil
    }

    func beginRedemption() -> CodexBankedResetInventoryItem? {
        guard let selectedItem else {
            return nil
        }
        return beginRedemption(for: selectedItem)
    }

    func beginRedemption(
        for item: CodexBankedResetInventoryItem
    ) -> CodexBankedResetInventoryItem? {
        guard canRequestConfirmation(for: item) else {
            return nil
        }
        pendingItem = item
        retryItem = nil
        self.selectedItem = nil
        return item
    }

    func finishRedemption(
        for item: CodexBankedResetInventoryItem,
        requiresSameResetForRetry: Bool = false
    ) {
        guard pendingItemID == item.id else {
            return
        }
        pendingItem = nil
        retryItem = requiresSameResetForRetry ? item : nil
    }

    func canRequestConfirmation(for item: CodexBankedResetInventoryItem) -> Bool {
        pendingItemID == nil && (retryItemID == nil || retryItemID == item.id)
    }
}

struct CodexBankedResetInventoryView: View {
    let resets: CodexBankedRateLimitResets
    let canRedeem: Bool
    let onUseReset: ((String?) async -> CodexBankedResetRedemptionFeedback)?
    let onFeedback: (CodexBankedResetRedemptionFeedback) -> Void
    @ObservedObject var redemptionController: CodexBankedResetRedemptionController

    @Environment(\.dismiss) private var dismiss
    @State private var feedback: CodexBankedResetRedemptionFeedback?

    var inventoryItems: [CodexBankedResetInventoryItem] {
        let currentItems: [CodexBankedResetInventoryItem]
        if !resets.orderedCredits.isEmpty {
            let detailedItems = resets.orderedCredits.map {
                CodexBankedResetInventoryItem(credit: $0)
            }
            currentItems = if canRedeem, resets.availableCount > detailedItems.count {
                detailedItems + [.generic()]
            } else {
                detailedItems
            }
        } else {
            currentItems = canRedeem ? [.generic()] : []
        }

        guard
            let retainedItem = redemptionController.pendingItem ?? redemptionController.retryItem,
            !currentItems.contains(where: { $0.id == retainedItem.id })
        else {
            return currentItems
        }
        return [retainedItem] + currentItems
    }

    var unavailableDetailCount: Int {
        max(resets.availableCount - resets.orderedCredits.count, 0)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if inventoryItems.isEmpty {
                        Text("Individual reset details are unavailable. Redemption is not available from CodexBar right now.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        ForEach(inventoryItems) { item in
                            if canRedeem {
                                Button {
                                    redemptionController.requestConfirmation(for: item)
                                } label: {
                                    resetRow(item)
                                }
                                .buttonStyle(.plain)
                                .disabled(!redemptionController.canRequestConfirmation(for: item))
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(item.accessibilityLabel)
                                .accessibilityHint(
                                    redemptionController.retryItemID == item.id
                                        ? "Retries the original redemption attempt for this reset"
                                        : "Asks for confirmation before using this reset"
                                )
                            } else {
                                resetRow(item)
                                    .accessibilityElement(children: .ignore)
                                    .accessibilityLabel(item.accessibilityLabel)
                            }
                        }
                    }
                } header: {
                    Text(resets.availableCount == 1 ? "1 reset available" : "\(resets.availableCount) resets available")
                } footer: {
                    if unavailableDetailCount > 0, !resets.orderedCredits.isEmpty {
                        Text(unavailableDetailCount == 1
                            ? "Details are unavailable for 1 additional reset."
                            : "Details are unavailable for \(unavailableDetailCount) additional resets.")
                    } else if !canRedeem, !inventoryItems.isEmpty {
                        Text("This inventory is read-only because redemption is not available from CodexBar right now.")
                    }
                }

                if let feedback {
                    Section {
                        Label(
                            feedback.message,
                            systemImage: feedback.isSuccess ? "checkmark.circle" : "info.circle"
                        )
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(feedback.message)
                    }
                }
            }
            .navigationTitle("Saved Codex Resets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .alert(
                redemptionController.selectedItem.map { "Use \($0.title)?" } ?? "Use Reset?",
                isPresented: Binding(
                    get: { redemptionController.isConfirmationPresented },
                    set: { isPresented in
                        if !isPresented {
                            redemptionController.cancelConfirmation()
                        }
                    }
                ),
                presenting: redemptionController.selectedItem
            ) { item in
                Button("Cancel", role: .cancel) {
                    redemptionController.cancelConfirmation()
                }
                Button("Use Reset", role: .destructive) {
                    redeemSelectedReset(item)
                }
            } message: { item in
                Text(item.confirmationMessage)
            }
        }
    }

    @ViewBuilder
    private func resetRow(_ item: CodexBankedResetInventoryItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(item.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(item.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Label(item.expiration, systemImage: "calendar")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if redemptionController.retryItemID == item.id {
                    Label("Retry this reset", systemImage: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            if redemptionController.pendingItemID == item.id {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Using \(item.title)")
            } else if canRedeem {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
    }

    private func redeemSelectedReset(_ presentedItem: CodexBankedResetInventoryItem) {
        guard
            let onUseReset,
            let item = redemptionController.beginRedemption(for: presentedItem)
        else {
            return
        }

        feedback = nil
        Task {
            let result = await onUseReset(item.creditID)
            redemptionController.finishRedemption(
                for: item,
                requiresSameResetForRetry: result.requiresSameResetForRetry
            )
            feedback = result
            onFeedback(result)
            UIAccessibility.post(notification: .announcement, argument: result.message)
            if result.isSuccess || result.hidesAction {
                dismiss()
            }
        }
    }
}

struct ProviderUsagePlaceholderCard: View {
    let configuration: ProviderAccountConfiguration
    let errorMessage: String?
    let recoveryAction: ProviderUsageRecoveryAction
    let isPerformingRecovery: Bool
    let recoveryStatusMessage: String?
    let recoveryErrorMessage: String?
    let onReportProblem: (() -> Void)?
    let onRetry: () -> Void

    init(
        configuration: ProviderAccountConfiguration,
        errorMessage: String?,
        recoveryAction: ProviderUsageRecoveryAction = .retryRefresh,
        isPerformingRecovery: Bool = false,
        recoveryStatusMessage: String? = nil,
        recoveryErrorMessage: String? = nil,
        onReportProblem: (() -> Void)? = nil,
        onRetry: @escaping () -> Void
    ) {
        self.configuration = configuration
        self.errorMessage = errorMessage
        self.recoveryAction = recoveryAction
        self.isPerformingRecovery = isPerformingRecovery
        self.recoveryStatusMessage = recoveryStatusMessage
        self.recoveryErrorMessage = recoveryErrorMessage
        self.onReportProblem = onReportProblem
        self.onRetry = onRetry
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 8) {
                ProviderLogoTile(providerID: configuration.providerID)

                Text(configuration.displayName)
                    .font(.headline)

                Spacer()
            }

            if let errorMessage {
                Label("Could not load usage", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)

                ProviderProblemReportDisclosure(
                    title: "Problem details",
                    message: errorMessage,
                    onReport: onReportProblem
                )

                if isPerformingRecovery {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Signing in to \(configuration.displayName)")
                } else {
                    Button(action: onRetry) {
                        Label(recoveryActionTitle, systemImage: recoveryActionSystemImage)
                            .frame(minHeight: configuration.providerID == .cursor ? 44 : nil)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityHint(recoveryAccessibilityHint)
                }

                if let recoveryStatusMessage {
                    Text(recoveryStatusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let recoveryErrorMessage {
                    Text(recoveryErrorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)

                    Text("Loading current usage")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Loading current usage for \(configuration.displayName)")

                VStack(alignment: .leading, spacing: 10) {
                    loadingRow(labelWidth: 92, valueWidth: 64)
                    loadingRow(labelWidth: 116, valueWidth: 48)
                }
                .accessibilityHidden(true)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(.separator).opacity(0.22), lineWidth: 0.5)
        }
    }

    var recoveryActionTitle: String {
        switch recoveryAction {
        case .retryRefresh:
            "Retry"
        case .signIn:
            configuration.providerID == .cursor ? "Sign in with Cursor"
                : configuration.providerID == .claude ? "Sign in with Claude" : "Open account settings"
        case .reauthenticate:
            configuration.providerID == .cursor ? "Reconnect Cursor"
                : configuration.providerID == .claude ? "Sign in again" : "Update credentials"
        }
    }

    var recoveryActionSystemImage: String {
        recoveryAction == .retryRefresh ? "arrow.clockwise" : "person.badge.key"
    }

    var recoveryAccessibilityHint: String {
        switch recoveryAction {
        case .retryRefresh:
            "Retries refreshing usage for \(configuration.displayName)"
        case .signIn:
            ProviderSignInAccessibility.hint(providerID: configuration.providerID, title: configuration.displayName, reconnecting: false)
        case .reauthenticate:
            ProviderSignInAccessibility.hint(providerID: configuration.providerID, title: configuration.displayName, reconnecting: true)
        }
    }

    private func loadingRow(labelWidth: CGFloat, valueWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                loadingBar(width: labelWidth, height: 11)
                Spacer()
                loadingBar(width: valueWidth, height: 11)
            }

            loadingBar(width: nil, height: 7)
        }
    }

    private func loadingBar(width: CGFloat?, height: CGFloat) -> some View {
        Capsule()
            .fill(Color(.tertiarySystemFill))
            .frame(width: width, height: height)
    }
}

private struct UsageAlertSummaryView: View {
    let alerts: [UsageAlertDetail]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(alerts) { alert in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: alert.kind.systemImageName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(alert.severity.tint)
                        .frame(width: 16)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(alert.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(alert.message)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier("usage-alert-summary")
    }

    private var accessibilityLabel: String {
        alerts
            .map { "\($0.title). \($0.message)" }
            .joined(separator: " ")
    }
}

private struct UsageHistoryCompactView: View {
    let series: UsageHistorySeries
    let onShowHistory: () -> Void

    var body: some View {
        Button(action: onShowHistory) {
            HStack(spacing: 12) {
                UsageTrendSparkline(series: series, tint: series.tint)
                    .frame(width: 88, height: 38)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(series.latestValueDescription)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .monospacedDigit()

                        Text(series.changeDescription)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(series.tint)
                            .lineLimit(1)
                    }

                    Text(series.rangeDescription)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Text(series.sampleWindowDescription)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Usage history. Latest \(series.latestValueDescription). \(series.changeDescription). \(series.rangeDescription)."
        )
        .accessibilityHint("Shows the expanded history graph.")
    }
}

private struct UsageTrendSparkline: View {
    let series: UsageHistorySeries
    let tint: Color

    var body: some View {
        Canvas { context, size in
            guard !series.points.isEmpty else {
                var placeholder = Path()
                placeholder.move(to: CGPoint(x: 0, y: size.height / 2))
                placeholder.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                context.stroke(
                    placeholder,
                    with: .color(tint.opacity(0.35)),
                    style: StrokeStyle(lineWidth: 1.5, dash: [3, 3])
                )
                return
            }

            let firstDate = series.points.first?.capturedAt ?? Date()
            let lastDate = series.points.last?.capturedAt ?? firstDate
            let timeSpan = max(lastDate.timeIntervalSince(firstDate), 1)
            let valueSpan = max(series.chartDomain.upperBound - series.chartDomain.lowerBound, 0.0001)
            var path = Path()
            var lastResolvedPoint = CGPoint(x: size.width / 2, y: size.height / 2)

            for (index, point) in series.points.enumerated() {
                let x = series.points.count == 1
                    ? size.width / 2
                    : CGFloat(point.capturedAt.timeIntervalSince(firstDate) / timeSpan) * size.width
                let normalizedValue = (point.value - series.chartDomain.lowerBound) / valueSpan
                let y = size.height - CGFloat(min(max(normalizedValue, 0), 1)) * size.height
                let resolvedPoint = CGPoint(x: x, y: y)
                lastResolvedPoint = resolvedPoint

                if index == 0 {
                    path.move(to: resolvedPoint)
                } else {
                    path.addLine(to: resolvedPoint)
                }
            }

            if series.points.count >= 2 {
                context.stroke(
                    path,
                    with: .color(tint),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                )
            }

            context.fill(
                Path(ellipseIn: CGRect(
                    x: lastResolvedPoint.x - 3,
                    y: lastResolvedPoint.y - 3,
                    width: 6,
                    height: 6
                )),
                with: .color(tint)
            )
        }
        .accessibilityHidden(true)
    }
}

struct ProviderUsageHistoryDetailView: View {
    @Environment(\.dismiss) private var dismiss

    let result: ProviderUsageResult
    let seriesOptions: [UsageHistorySeriesOption]
    let accessPolicy: HistoryAccessPolicy
    let onRequestPro: () -> Void

    @State private var selectedDate: Date?
    @State private var selectedSeriesID: String
    @State private var selectedRange = UsageHistoryRange.sevenDays

    init(
        result: ProviderUsageResult,
        seriesOptions: [UsageHistorySeriesOption],
        accessPolicy: HistoryAccessPolicy = HistoryAccessPolicy(hasProAccess: true),
        initialRange: UsageHistoryRange = .sevenDays,
        onRequestPro: @escaping () -> Void = {}
    ) {
        self.result = result
        self.seriesOptions = seriesOptions
        self.accessPolicy = accessPolicy
        self.onRequestPro = onRequestPro
        _selectedRange = State(initialValue: accessPolicy.allows(range: initialRange) ? initialRange : .sevenDays)
        _selectedSeriesID = State(initialValue: seriesOptions.first?.id ?? "primary")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    accountHeader

                    if seriesOptions.count > 1 {
                        Picker("History metric", selection: $selectedSeriesID) {
                            ForEach(seriesOptions) { option in
                                Text(option.label).tag(option.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .onChange(of: selectedSeriesID) {
                            selectedDate = nil
                        }
                    }

                    HistoryRangePicker(selection: accessibleRangeSelection, accessPolicy: accessPolicy, onRequestPro: onRequestPro)
                        .onChange(of: selectedRange) { selectedDate = nil }
                        .onChange(of: accessPolicy) { selectedDate = nil }

                    if series.points.isEmpty {
                        ContentUnavailableView(
                            "No History in This Range",
                            systemImage: "chart.xyaxis.line",
                            description: Text(
                                "Choose a longer range or refresh usage to collect another sample."
                            )
                        )
                        .frame(maxWidth: .infinity, minHeight: 320)
                    } else {
                        chartSection
                        statisticsSection
                        recentSamplesSection
                    }
                }
                .frame(maxWidth: 720, alignment: .leading)
                .padding(20)
                .frame(maxWidth: .infinity)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private var accessibleRangeSelection: Binding<UsageHistoryRange> {
        Binding(
            get: { accessPolicy.allows(range: selectedRange) ? selectedRange : .sevenDays },
            set: { selectedRange = $0 }
        )
    }

    private var series: UsageHistorySeries {
        let unfilteredSeries = seriesOptions.first(where: { $0.id == selectedSeriesID })?.series
            ?? seriesOptions.first?.series
            ?? UsageHistorySeries(accountID: result.accountID, points: [], isBalance: false)
        return unfilteredSeries.filtered(to: selectedRange, accessPolicy: accessPolicy)
    }

    private var accountHeader: some View {
        HStack(spacing: 10) {
            ProviderLogoTile(providerID: result.providerID)
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(result.title)
                    .font(.headline)

                Text(series.sampleWindowDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayedPoint.map { series.valueDescription(for: $0.value) } ?? series.latestValueDescription)
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .monospacedDigit()

                    if let displayedPoint {
                        Text(UserFacingDateTimeFormatter.current.dateAndTime(displayedPoint.capturedAt))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Text(series.changeDescription)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(series.tint)
            }

            Chart {
                ForEach(series.points) { point in
                    if series.points.count >= 2 {
                        AreaMark(
                            x: .value("Time", point.capturedAt),
                            yStart: .value("Baseline", series.chartDomain.lowerBound),
                            yEnd: .value("Value", point.value)
                        )
                        .foregroundStyle(series.tint.opacity(0.1))

                        LineMark(
                            x: .value("Time", point.capturedAt),
                            y: .value("Value", point.value)
                        )
                        .foregroundStyle(series.tint)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    }

                    if series.points.count <= 12 {
                        PointMark(
                            x: .value("Time", point.capturedAt),
                            y: .value("Value", point.value)
                        )
                        .foregroundStyle(series.tint.opacity(0.75))
                        .symbolSize(24)
                    }
                }

                if series.showsQuotaLimitRule {
                    RuleMark(y: .value("Limit", 1.0))
                        .foregroundStyle(Color.secondary.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .annotation(position: .top, alignment: .trailing) {
                            Text("100% limit")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                }

                if let displayedPoint {
                    RuleMark(x: .value("Selected time", displayedPoint.capturedAt))
                        .foregroundStyle(Color.secondary.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))

                    PointMark(
                        x: .value("Selected time", displayedPoint.capturedAt),
                        y: .value("Selected value", displayedPoint.value)
                    )
                    .foregroundStyle(series.tint)
                    .symbolSize(52)
                }
            }
            .chartYScale(domain: series.chartDomain)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine()
                        .foregroundStyle(Color.secondary.opacity(0.15))
                    AxisTick()
                    AxisValueLabel(
                        anchor: value.count > 1 && value.index == 0
                            ? .topLeading
                            : value.count > 1 && value.index == value.count - 1 ? .topTrailing : .top,
                        collisionResolution: .greedy(priority: value.index == value.count - 1 ? 1 : 0)
                    ) {
                        if let date = value.as(Date.self) {
                            Text(axisDateText(for: date))
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { value in
                    AxisGridLine()
                        .foregroundStyle(Color.secondary.opacity(0.15))
                    AxisTick()
                    AxisValueLabel {
                        if let numericValue = value.as(Double.self) {
                            Text(series.valueDescription(for: numericValue))
                        }
                    }
                }
            }
            .chartXSelection(value: $selectedDate)
            .frame(height: 260)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(result.title) history chart")
            .accessibilityValue(
                "\(series.sampleWindowDescription). Latest \(series.latestValueDescription). \(series.changeDescription). \(series.rangeDescription)."
            )
            .accessibilityHint("Drag across the chart to inspect historical values.")

            if series.points.count == 1 {
                Text("More samples will appear after future refreshes.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statisticsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Summary")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 14) {
                GridRow {
                    HistoryMetricView(title: "Latest", value: series.latestValueDescription)
                    HistoryMetricView(title: "Change", value: series.changeDescription)
                }

                Divider()
                    .gridCellColumns(2)

                GridRow {
                    HistoryMetricView(title: "Low", value: series.minimumValueDescription)
                    HistoryMetricView(title: "High", value: series.maximumValueDescription)
                }
            }
        }
    }

    private var recentSamplesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recent Samples")
                .font(.headline)
                .padding(.bottom, 8)

            ForEach(Array(series.points.suffix(20).reversed())) { point in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(series.valueDescription(for: point.value))
                            .font(.body.weight(.semibold))
                            .monospacedDigit()

                        Text(UserFacingDateTimeFormatter.current.dateAndTime(point.capturedAt))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Circle()
                        .fill(point.severity.tint)
                        .frame(width: 9, height: 9)
                        .accessibilityHidden(true)
                }
                .padding(.vertical, 10)

                Divider()
            }
        }
    }

    private var displayedPoint: UsageHistoryPoint? {
        guard let selectedDate else {
            return series.points.last
        }

        return series.points.min { lhs, rhs in
            abs(lhs.capturedAt.timeIntervalSince(selectedDate))
                < abs(rhs.capturedAt.timeIntervalSince(selectedDate))
        }
    }

    private func axisDateText(for date: Date) -> String {
        guard
            let first = series.points.first?.capturedAt,
            let last = series.points.last?.capturedAt
        else {
            return ""
        }

        if last.timeIntervalSince(first) < 24 * 60 * 60 {
            return UserFacingDateTimeFormatter.current.time(date)
        }

        return UserFacingDateTimeFormatter.current.shortDate(date)
    }
}

private struct HistoryMetricView: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(value)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension UsageHistorySeries {
    var tint: Color {
        switch direction {
        case .flat:
            .secondary
        case .up where isBalance:
            .green
        case .down where isBalance:
            .orange
        case .up:
            .orange
        case .down:
            .green
        }
    }
}

private extension UsageAlertKind {
    var systemImageName: String {
        switch self {
        case .usage:
            "gauge.with.dots.needle.67percent"
        case .balance:
            "creditcard"
        case .severity:
            "exclamationmark.triangle.fill"
        }
    }
}

private struct ProviderLogoTile: View {
    let providerID: ProviderID

    var body: some View {
        CodexBarProviderLogo(
            providerID: providerID.rawValue,
            size: 24,
            background: Color(.secondarySystemGroupedBackground),
            border: Color(.separator).opacity(0.3),
            imagePadding: 4
        )
    }
}

private struct ProviderMetricTileDetailView: View {
    let result: ProviderUsageResult
    let statusText: String
    let metric: ProviderUsageMetric
    let history: UsageHistorySeries?
    let visualizationStyle: MetricVisualizationStyle

    @Environment(\.dismiss) private var dismiss
    @Environment(\.usageSeverityThresholds) private var severityThresholds

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 10) {
                        ProviderLogoTile(providerID: result.providerID)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(metric.label)
                                .font(.headline)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(result.title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    metricSummary

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Details")
                            .font(.headline)
                        detailRows
                    }
                    .padding(16)
                    .background(
                        Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 12)
                    )

                    historySection
                }
                .frame(maxWidth: 640, alignment: .leading)
                .padding(20)
                .frame(maxWidth: .infinity)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Metric Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private var metricSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(valueText)
                .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .minimumScaleFactor(0.65)
                .lineLimit(1)

            if case let .usageBar(index) = metric.kind,
               result.bars.indices.contains(index),
               !result.bars[index].isUnboundedNumeric {
                MetricVisualizationView(
                    bar: result.bars[index],
                    style: visualizationStyle,
                    showsSeverity: result.hasCurrentBars
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 12)
        )
    }

    @ViewBuilder
    private var detailRows: some View {
        switch metric.kind {
        case let .usageBar(index) where result.bars.indices.contains(index):
            let bar = result.bars[index]
            if bar.isUnboundedNumeric {
                detailRow("Count", bar.usageText)
                if !result.subtitle.isEmpty { detailRow("Scope", result.subtitle) }
            } else {
                detailRow("Used", ProviderUsageCard.formattedUsageAmount(bar.used))
                detailRow("Limit", ProviderUsageCard.formattedUsageAmount(bar.limit))
                detailRow(
                    "Severity",
                    result.hasCurrentBars
                        ? bar.effectiveSeverity(
                            thresholds: severityThresholds
                        ).accessibilityName.capitalized
                        : "Unavailable"
                )
            }
            SubscriptionUtilizationMetricView(bar: bar, isCurrent: result.hasCurrentBars, showsExplanation: true)
            detailRow("Freshness", result.hasCurrentBars ? "Current" : "Last known value")
            if let resetDescription = bar.localizedResetDescription() {
                detailRow("Reset", resetDescription)
            }
            if result.hasCurrentBars, let projectionDescription = bar.projectionDescription() {
                detailRow("Projection", projectionDescription)
            }
            detailRow("Account status", statusText)
        case let .unavailableUsage(reason):
            detailRow("Availability", reason)
            if metric.id.contains("weekly") { SubscriptionUtilizationBadge(score: nil) }
            detailRow("Account status", statusText)
        case .creditsRemaining:
            detailRow("Balance", valueText)
            detailRow("Freshness", result.hasCurrentCredits ? "Current" : "Last known value")
            detailRow("Account status", statusText)
        case let .monetary(index) where result.monetaryMetrics.indices.contains(index):
            let monetaryMetric = result.monetaryMetrics[index]
            detailRow("Amount", monetaryMetric.formattedAmount())
            detailRow("Currency", monetaryMetric.currencyCode)
            detailRow(
                "Freshness",
                result.failureMessage == nil ? "Current" : "Last known value"
            )
            if ProviderUsageCard.isCritical(monetaryMetric, in: result) {
                detailRow("Severity", "Critical")
            }
            if let detail = monetaryMetric.detail {
                detailRow("Context", detail)
            }
            detailRow("Account status", statusText)
        default:
            detailRow("Account status", statusText)
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var historySection: some View {
        if let history {
            VStack(alignment: .leading, spacing: 12) {
                Text("History")
                    .font(.headline)

                if history.points.isEmpty {
                    ContentUnavailableView(
                        "No History Yet",
                        systemImage: "chart.xyaxis.line",
                        description: Text("History will appear after this metric is refreshed again.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 180)
                } else {
                    UsageTrendSparkline(series: history, tint: history.tint)
                        .frame(height: 110)

                    HStack(spacing: 12) {
                        HistoryMetricView(title: "Latest", value: history.latestValueDescription)
                        HistoryMetricView(title: "Change", value: history.changeDescription)
                        HistoryMetricView(title: "Range", value: history.rangeDescription)
                    }

                    Text(history.sampleWindowDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .accessibilityElement(children: .contain)
        }
    }

    private var valueText: String {
        switch metric.kind {
        case let .usageBar(index) where result.bars.indices.contains(index):
            return result.bars[index].usageText
        case let .unavailableUsage(reason):
            return reason
        case .creditsRemaining:
            return result.creditsRemaining.map { CodexBarCurrencyText.format($0) } ?? "Unavailable"
        case let .monetary(index) where result.monetaryMetrics.indices.contains(index):
            return result.monetaryMetrics[index].formattedAmount()
        default:
            return "Unavailable"
        }
    }
}

private struct MetricVisualizationCustomizationView: View {
    let accountTitle: String
    let result: ProviderUsageResult
    let showsSeverity: Bool
    let isMetricVisible: (String) -> Bool
    let onUpdateMetricVisibility: (String, Bool) -> Void
    let watchVisibilityForMetric: (String) -> WatchMetricVisibilityPolicy
    let onUpdateWatchVisibility: (String, WatchMetricVisibilityPolicy) -> Void
    let visualizationStyleForMetric: (String) -> MetricVisualizationStyle
    let onUpdateVisualizationStyle: (String, MetricVisualizationStyle) -> Void
    let onApplyVisualizationStyleToAll: (MetricVisualizationStyle, [String]) -> Void
    let onResetVisualizationStyles: ([String]) -> Void
    let metricWidthForMetric: (String) -> MetricTileWidthPreference
    let onUpdateMetricWidth: (String, MetricTileWidthPreference) -> Void
    let metricLayoutProvider: () -> AccountMetricLayout
    let isMetricNewlyDiscovered: (String) -> Bool
    let onUpdateMetricOrder: ([String]) -> Void
    let onReplaceMetricLayout: (AccountMetricLayout) -> Void
    let onResetMetricLayout: ([String]) -> Void
    let copyLayoutDestinationsProvider: () -> [MetricLayoutCopyDestination]
    let onCopyMetricLayout: (MetricLayoutCopyDestination) -> Void
    let onMarkMetricsSeen: ([String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var undoHistory = MetricLayoutUndoHistory()
    @State private var draggedMetricID: String?
    @State private var dropTargetMetricID: String?
    @State private var dragHasRecordedUndo = false
    @State private var newMetricIDs = Set<String>()
    @State private var didCaptureNewMetricIDs = false
    @State private var pendingCopyDestination: MetricLayoutCopyDestination?
    @State private var copyStatusMessage: String?

    var body: some View {
        let copyDestinations = copyLayoutDestinationsProvider()

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(accountTitle)
                            .font(.subheadline.weight(.semibold))
                        Text("Drag tiles by their handles or use each tile’s menu. Changes apply immediately and autosave.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Live Preview")
                            .font(.headline)

                        if visibleMetrics.isEmpty {
                            ContentUnavailableView(
                                "No Visible Metrics",
                                systemImage: "rectangle.slash",
                                description: Text("Restore a metric from Hidden Metrics below.")
                            )
                            .frame(maxWidth: .infinity)
                        } else {
                            Grid(alignment: .topLeading, horizontalSpacing: 10, verticalSpacing: 10) {
                                ForEach(previewRows) { row in
                                    GridRow(alignment: .top) {
                                        editorTile(row.leading)
                                            .gridCellColumns(row.leading.width == .full ? 2 : 1)

                                        if let trailing = row.trailing {
                                            editorTile(trailing)
                                        } else if row.leading.width == .half {
                                            Color.clear
                                                .accessibilityHidden(true)
                                        }
                                    }
                                }
                            }
                            .animation(.snappy(duration: 0.22), value: visibleMetrics.map(\.id))
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Hidden Metrics")
                            .font(.headline)

                        if hiddenMetrics.isEmpty {
                            Text("No hidden metrics")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(hiddenMetrics) { metric in
                                HStack(spacing: 12) {
                                    Label(metric.label, systemImage: "eye.slash")
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    watchVisibilityControl(for: metric)
                                    Button("Show") {
                                        performChange {
                                            onUpdateMetricVisibility(metric.id, true)
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                    .frame(minWidth: 44, minHeight: 44)
                                    .accessibilityLabel("Show \(metric.label)")
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Reuse Layout")
                            .font(.headline)

                        Menu {
                            ForEach(copyDestinations) { destination in
                                Button(destination.title) {
                                    requestCopy(to: destination)
                                }
                            }
                        } label: {
                            Label("Copy Layout…", systemImage: "rectangle.on.rectangle")
                                .frame(minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                        .disabled(copyDestinations.isEmpty)

                        if copyDestinations.isEmpty {
                            Text("Add another configured account for this provider to reuse its layout.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if let copyStatusMessage {
                            Label(copyStatusMessage, systemImage: "checkmark.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityAddTraits(.isStaticText)
                        }
                    }

                    if !styleMetricIDs.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("All Usage Metrics")
                                .font(.headline)

                            Menu {
                                ForEach(MetricVisualizationStyle.allCases) { style in
                                    Button(style.displayName) {
                                        performChange {
                                            onApplyVisualizationStyleToAll(style, styleMetricIDs)
                                        }
                                    }
                                }
                            } label: {
                                Label("Apply a visualization to all", systemImage: "square.stack.3d.up")
                                    .frame(minHeight: 44)
                            }
                            .buttonStyle(.bordered)

                            Button {
                                performChange {
                                    onResetVisualizationStyles(styleMetricIDs)
                                }
                            } label: {
                                Label("Reset visualizations to linear bars", systemImage: "arrow.counterclockwise")
                                    .frame(minHeight: 44)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
                .padding(16)
            }
            .accessibilityIdentifier("metric-customization-scroll")
            .navigationTitle("Customize Card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button("Undo", systemImage: "arrow.uturn.backward") {
                        undo()
                    }
                    .disabled(!undoHistory.canUndo)

                    Button("Reset", systemImage: "arrow.counterclockwise") {
                        performChange {
                            onResetMetricLayout(availableMetricIDs)
                        }
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onAppear {
            guard !didCaptureNewMetricIDs else {
                return
            }
            newMetricIDs = Set(
                availableMetricIDs.filter(isMetricNewlyDiscovered)
            )
            didCaptureNewMetricIDs = true
        }
        .onDisappear {
            onMarkMetricsSeen(Array(newMetricIDs))
        }
        .alert(
            "Replace \(pendingCopyDestination?.title ?? "destination") layout?",
            isPresented: Binding(
                get: { pendingCopyDestination != nil },
                set: { if !$0 { pendingCopyDestination = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) {
                pendingCopyDestination = nil
            }
            Button("Replace Layout", role: .destructive) {
                guard let destination = pendingCopyDestination else {
                    return
                }
                copyLayout(to: destination)
                pendingCopyDestination = nil
            }
        } message: {
            Text("This account already has a custom layout. Matching metrics will be replaced; destination-only metrics will stay available.")
        }
    }

    private var availableMetricIDs: [String] {
        result.configurableMetrics.map(\.id)
    }

    private var orderedMetrics: [ProviderUsageMetric] {
        let metricsByID = Dictionary(
            result.configurableMetrics.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var seen = Set<String>()
        return metricLayoutProvider().orderedMetricIDs.compactMap { metricID in
            guard seen.insert(metricID).inserted else {
                return nil
            }
            return metricsByID[metricID]
        } + result.configurableMetrics.filter { seen.insert($0.id).inserted }
    }

    private var visibleMetrics: [ProviderUsageMetric] {
        orderedMetrics.filter { isMetricVisible($0.id) }
    }

    private var hiddenMetrics: [ProviderUsageMetric] {
        orderedMetrics.filter { !isMetricVisible($0.id) }
    }

    private var previewRows: [ProviderMetricTileGridRow] {
        ProviderMetricTileGridResolver.rows(
            metrics: visibleMetrics,
            orderedMetricIDs: visibleMetrics.map(\.id),
            widthForMetric: metricWidthForMetric,
            visualizationStyleForMetric: { metricID in
                guard let metric = orderedMetrics.first(where: { $0.id == metricID }) else {
                    return visualizationStyleForMetric(metricID)
                }
                return resolvedVisualizationStyle(for: metric)
            },
            usesRegularHorizontalSizeClass: horizontalSizeClass == .regular,
            collapsesToSingleColumn: dynamicTypeSize.isAccessibilitySize
        )
    }

    private func editorTile(_ item: ProviderMetricTileGridItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 4) {
                Image(systemName: "line.3.horizontal")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .foregroundStyle(.secondary)
                    .onDrag {
                        beginDrag(item.metric.id)
                        return NSItemProvider(object: item.metric.id as NSString)
                    }
                    .accessibilityLabel("Drag \(item.metric.label)")
                    .accessibilityHint("Reorders this metric tile")

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.metric.label)
                        .font(.caption.weight(.semibold))
                        .lineLimit(2)
                    if newMetricIDs.contains(item.metric.id) {
                        Text("New")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.tint)
                            .accessibilityLabel("New metric")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                tileMenu(for: item.metric)
            }

            previewValue(for: item.metric)
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    dropTargetMetricID == item.metric.id ? Color.accentColor : Color.clear,
                    style: StrokeStyle(lineWidth: 2, dash: [6, 4])
                )
                .animation(.easeInOut(duration: 0.16), value: dropTargetMetricID)
        }
        .onDrop(
            of: [.text],
            delegate: MetricEditorDropDelegate(
                targetMetricID: item.metric.id,
                draggedMetricID: $draggedMetricID,
                dropTargetMetricID: $dropTargetMetricID,
                moveMetric: moveMetric
            )
        )
        .accessibilityElement(children: .contain)
    }

    private func tileMenu(for metric: ProviderUsageMetric) -> some View {
        Menu {
            Button("Move Earlier", systemImage: "arrow.left") {
                moveMetric(metric.id, by: -1)
            }
            .disabled(visibleMetrics.first?.id == metric.id)

            Button("Move Later", systemImage: "arrow.right") {
                moveMetric(metric.id, by: 1)
            }
            .disabled(visibleMetrics.last?.id == metric.id)

            Menu("Tile Width") {
                Picker("Tile Width", selection: Binding(
                    get: { metricWidthForMetric(metric.id) },
                    set: { width in
                        performChange(haptic: .rigid) {
                            onUpdateMetricWidth(metric.id, width)
                        }
                    }
                )) {
                    ForEach(MetricTileWidthPreference.allCases, id: \.self) { width in
                        Text(width.displayName).tag(width)
                    }
                }
            }

            let styles = supportedStyles(for: metric)
            if !styles.isEmpty {
                Menu("Visualization") {
                    Picker("Visualization", selection: Binding(
                        get: { visualizationStyleForMetric(metric.id) },
                        set: { style in
                            performChange {
                                onUpdateVisualizationStyle(metric.id, style)
                            }
                        }
                    )) {
                        ForEach(styles) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                }
            }

            watchVisibilityControl(for: metric)

            Divider()

            Button("Hide", systemImage: "eye.slash") {
                performChange {
                    onUpdateMetricVisibility(metric.id, false)
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityIdentifier("customize-metric-\(metric.id)")
        .accessibilityLabel("Actions for \(metric.label)")
        .accessibilityHint("Move, resize, restyle, or hide this metric")
    }

    private func watchVisibilityControl(for metric: ProviderUsageMetric) -> some View {
        let policy = watchVisibilityForMetric(metric.id)
        return Menu {
            ForEach(WatchMetricVisibilityPolicy.allCases, id: \.self) { option in
                Button {
                    performChange {
                        onUpdateWatchVisibility(metric.id, option)
                    }
                } label: {
                    if policy == option {
                        Label(
                            option.displayName(isVisibleOnIPhone: isMetricVisible(metric.id)),
                            systemImage: "checkmark"
                        )
                    } else {
                        Text(option.displayName(isVisibleOnIPhone: isMetricVisible(metric.id)))
                    }
                }
            }
        } label: {
            Label(
                policy.controlLabel(isVisibleOnIPhone: isMetricVisible(metric.id)),
                systemImage: "applewatch"
            )
            .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel("Show \(metric.label) on Watch")
        .accessibilityValue(policy.accessibilityValue(isVisibleOnIPhone: isMetricVisible(metric.id)))
        .accessibilityHint("Choose whether Watch inherits iPhone visibility or always shows or hides this metric")
    }

    @ViewBuilder
    private func previewValue(for metric: ProviderUsageMetric) -> some View {
        switch metric.kind {
        case let .usageBar(index) where result.bars.indices.contains(index):
            usagePreview(for: metric, bar: result.bars[index])
        case .creditsRemaining:
            Text(result.creditsRemaining.map { CodexBarCurrencyText.format($0) } ?? "Unavailable")
                .font(.title3.weight(.semibold))
                .monospacedDigit()
        case let .monetary(index) where result.monetaryMetrics.indices.contains(index):
            Text(result.monetaryMetrics[index].formattedAmount())
                .font(.title3.weight(.semibold))
                .monospacedDigit()
        case let .unavailableUsage(reason):
            Text(reason).font(.subheadline).foregroundStyle(.secondary)
        default:
            Text("Unavailable")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func usagePreview(for metric: ProviderUsageMetric, bar: UsageBar) -> some View {
        let visualizationStyle = resolvedVisualizationStyle(for: metric)
        return VStack(alignment: .leading, spacing: 8) {
            if visualizationStyle.showsStandaloneMetricTileValue && !bar.isUnboundedNumeric {
                Text(bar.usageText)
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
            }
            MetricVisualizationView(bar: bar, style: visualizationStyle, showsSeverity: showsSeverity)
        }
    }

    private func performChange(
        haptic: UIImpactFeedbackGenerator.FeedbackStyle = .light,
        _ change: () -> Void
    ) {
        let previousLayout = metricLayoutProvider()
        withAnimation(.snappy(duration: 0.22)) {
            change()
        }
        guard undoHistory.record(
            previousLayout,
            ifChangedTo: metricLayoutProvider()
        ) else {
            return
        }
        UIImpactFeedbackGenerator(style: haptic).impactOccurred()
    }

    private func undo() {
        guard let previous = undoHistory.undo() else {
            return
        }
        withAnimation(.snappy(duration: 0.22)) {
            onReplaceMetricLayout(previous)
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func beginDrag(_ metricID: String) {
        dragHasRecordedUndo = false
        draggedMetricID = metricID
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func moveMetric(_ draggedID: String, toward targetID: String) {
        guard let order = ProviderMetricTileOrderResolver.moving(
            draggedID,
            toward: targetID,
            in: visibleMetrics.map(\.id)
        ) else {
            return
        }
        if !dragHasRecordedUndo {
            undoHistory.record(metricLayoutProvider())
            dragHasRecordedUndo = true
        }
        onUpdateMetricOrder(order)
    }

    private func moveMetric(_ metricID: String, by offset: Int) {
        var order = visibleMetrics.map(\.id)
        guard let sourceIndex = order.firstIndex(of: metricID) else {
            return
        }
        let destinationIndex = sourceIndex + offset
        guard order.indices.contains(destinationIndex) else {
            return
        }
        performChange {
            order.swapAt(sourceIndex, destinationIndex)
            onUpdateMetricOrder(order)
        }
    }

    private func requestCopy(to destination: MetricLayoutCopyDestination) {
        if destination.hasCustomLayout {
            pendingCopyDestination = destination
        } else {
            copyLayout(to: destination)
        }
    }

    private func copyLayout(to destination: MetricLayoutCopyDestination) {
        onCopyMetricLayout(destination)
        let message = "Layout copied to \(destination.title)."
        copyStatusMessage = message
        UIAccessibility.post(notification: .announcement, argument: message)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private var styleMetricIDs: [String] {
        result.configurableMetrics.compactMap { metric in
            if case .unavailableUsage = metric.kind { return metric.id }
            guard let bar = usageBar(for: metric), !bar.isUnboundedNumeric else {
                return nil
            }
            return metric.id
        }
    }

    private func supportedStyles(for metric: ProviderUsageMetric) -> [MetricVisualizationStyle] {
        if case .unavailableUsage = metric.kind { return MetricVisualizationStyle.allCases }
        return usageBar(for: metric)?.supportedVisualizationStyles ?? []
    }

    private func usageBar(for metric: ProviderUsageMetric) -> UsageBar? {
        guard case let .usageBar(index) = metric.kind, result.bars.indices.contains(index) else {
            return nil
        }
        return result.bars[index]
    }

    private func resolvedVisualizationStyle(
        for metric: ProviderUsageMetric
    ) -> MetricVisualizationStyle {
        let preferredStyle = visualizationStyleForMetric(metric.id)
        return usageBar(for: metric)?.resolvedVisualizationStyle(preferredStyle) ?? preferredStyle
    }

}

private struct MetricEditorDropDelegate: DropDelegate {
    let targetMetricID: String
    @Binding var draggedMetricID: String?
    @Binding var dropTargetMetricID: String?
    let moveMetric: (String, String) -> Void

    func dropEntered(info: DropInfo) {
        guard let draggedMetricID, draggedMetricID != targetMetricID else {
            return
        }
        dropTargetMetricID = targetMetricID
        withAnimation(.snappy(duration: 0.18)) {
            moveMetric(draggedMetricID, targetMetricID)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if dropTargetMetricID == targetMetricID {
            dropTargetMetricID = nil
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedMetricID = nil
        dropTargetMetricID = nil
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        return true
    }
}

private extension MetricTileWidthPreference {
    var displayName: String {
        switch self {
        case .automatic:
            "Automatic"
        case .half:
            "Half"
        case .full:
            "Full"
        }
    }
}

private extension WatchMetricVisibilityPolicy {
    func displayName(isVisibleOnIPhone: Bool) -> String {
        switch self {
        case .inherit:
            "Inherit iPhone (\(isVisibleOnIPhone ? "Shown" : "Hidden"))"
        case .show:
            "Always Show"
        case .hide:
            "Always Hide"
        }
    }

    func controlLabel(isVisibleOnIPhone: Bool) -> String {
        switch self {
        case .inherit:
            "Watch: Inherited \(isVisibleOnIPhone ? "Shown" : "Hidden")"
        case .show:
            "Watch: Shown"
        case .hide:
            "Watch: Hidden"
        }
    }

    func accessibilityValue(isVisibleOnIPhone: Bool) -> String {
        displayName(isVisibleOnIPhone: isVisibleOnIPhone)
    }
}

private struct MetricVisualizationView: View {
    let bar: UsageBar
    let style: MetricVisualizationStyle
    let showsSeverity: Bool

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.usageSeverityThresholds) private var severityThresholds

    var body: some View {
        Group {
            switch resolvedStyle {
            case .automatic:
                EmptyView()
            case .linearBar:
                UsageProgressBar(bar: bar, showsSeverity: showsSeverity)
            case .segmentedBar:
                SegmentedUsageBar(
                    fraction: bar.fractionUsed,
                    tint: tint
                )
            case .circularRing:
                CircularUsageRing(
                    fraction: bar.fractionUsed,
                    valueText: bar.usageText,
                    tint: tint
                )
            case .semicircularDial:
                SemicircularUsageDial(
                    fraction: bar.fractionUsed,
                    valueText: bar.usageText,
                    tint: tint
                )
            case .largeNumeric:
                Text(bar.metricTileValueText)
                    .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                    .foregroundStyle(tint)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
            }
        }
        .accessibilityHidden(true)
    }

    private var resolvedStyle: MetricVisualizationStyle {
        if bar.isUnboundedNumeric {
            return .largeNumeric
        }
        guard style == .automatic else {
            return style
        }
        return horizontalSizeClass == .regular ? .circularRing : .linearBar
    }

    private var tint: Color {
        showsSeverity
            ? bar.effectiveSeverity(thresholds: severityThresholds).tint
            : Color.secondary.opacity(0.7)
    }
}

private struct SegmentedUsageBar: View {
    let fraction: Double
    let tint: Color
    private let segmentCount = 12

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<segmentCount, id: \.self) { index in
                Capsule()
                    .fill(index < filledSegmentCount ? tint : Color(.tertiarySystemFill))
            }
        }
        .frame(height: 9)
    }

    private var filledSegmentCount: Int {
        Int((min(max(fraction, 0), 1) * Double(segmentCount)).rounded(.up))
    }
}

private struct CircularUsageRing: View {
    let fraction: Double
    let valueText: String
    let tint: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color(.tertiarySystemFill), lineWidth: 8)
            Circle()
                .trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(tint, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(valueText)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .minimumScaleFactor(0.65)
        }
        .frame(width: 72, height: 72)
    }
}

struct SemicircularUsageDialLayout: Layout {
    static let contentSize = CGSize(width: 112, height: 58)
    static let valueMaxWidth: CGFloat = 88
    static let valueMinimumScaleFactor = 0.65

    static func contentFrame(contentSize: CGSize, in bounds: CGRect) -> CGRect {
        CGRect(
            x: bounds.midX - (contentSize.width / 2),
            y: bounds.minY,
            width: contentSize.width,
            height: contentSize.height
        )
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache _: inout ()
    ) -> CGSize {
        guard let subview = subviews.first else {
            return .zero
        }
        let contentSize = subview.sizeThatFits(.unspecified)
        return CGSize(
            width: max(proposal.width ?? contentSize.width, contentSize.width),
            height: contentSize.height
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal _: ProposedViewSize,
        subviews: Subviews,
        cache _: inout ()
    ) {
        guard let subview = subviews.first else {
            return
        }
        let contentSize = subview.sizeThatFits(.unspecified)
        let frame = Self.contentFrame(contentSize: contentSize, in: bounds)
        subview.place(
            at: frame.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(contentSize)
        )
    }
}

private struct SemicircularUsageDial: View {
    let fraction: Double
    let valueText: String
    let tint: Color

    var body: some View {
        SemicircularUsageDialLayout {
            ZStack {
                SemicircleShape()
                    .stroke(Color(.tertiarySystemFill), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                SemicircleShape()
                    .trim(from: 0, to: min(max(fraction, 0), 1))
                    .stroke(tint, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                Text(valueText)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(SemicircularUsageDialLayout.valueMinimumScaleFactor)
                    .frame(maxWidth: SemicircularUsageDialLayout.valueMaxWidth)
                    .offset(y: 5)
            }
            .frame(
                width: SemicircularUsageDialLayout.contentSize.width,
                height: SemicircularUsageDialLayout.contentSize.height
            )
        }
    }
}

private struct SemicircleShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let radius = min(rect.width / 2, rect.height)
        path.addArc(
            center: CGPoint(x: rect.midX, y: rect.maxY),
            radius: radius,
            startAngle: .degrees(180),
            endAngle: .degrees(0),
            clockwise: false
        )
        return path
    }
}

private struct UsageProgressBar: View {
    let bar: UsageBar
    let showsSeverity: Bool
    @Environment(\.usageSeverityThresholds) private var severityThresholds

    var body: some View {
        let projectedFraction = showsSeverity ? bar.projectedFraction() : nil
        CodexBarUsageProgressBar(
            fractionUsed: bar.fractionUsed,
            projectedFraction: projectedFraction,
            severity: showsSeverity
                ? bar.severity(using: severityThresholds).widgetSeverity
                : .normal,
            projectedSeverity: projectedFraction.map {
                UsageSeverity(
                    fractionUsed: $0,
                    thresholds: severityThresholds
                ).widgetSeverity
            },
            fillColor: showsSeverity ? nil : Color.secondary.opacity(0.55),
            height: 7,
            trackColor: Color(.tertiarySystemFill),
            accessibilityText: "\(bar.label) \(bar.usageText)"
        )
    }
}

private extension UsageSeverity {
    var accessibilityName: String {
        switch self {
        case .normal:
            "normal status"
        case .warning:
            "warning status"
        case .critical:
            "critical status"
        }
    }

    var widgetSeverity: CodexBarWidgetSeverity {
        switch self {
        case .normal:
            .normal
        case .warning:
            .warning
        case .critical:
            .critical
        }
    }
}

private struct MetricCustomizationPreview: View {
    @State private var layout: AccountMetricLayout

    init() {
        let metricIDs = Self.result.configurableMetrics.map(\.id)
        let preferences = Dictionary(
            uniqueKeysWithValues: metricIDs.enumerated().map { index, metricID in
                (
                    metricID,
                    MetricTilePreference(
                        isVisible: index != metricIDs.count - 1,
                        visualizationStyle: index == 1 ? .circularRing : nil,
                        width: index == 0 ? .full : .half,
                        isNewlyDiscovered: index == 2
                    )
                )
            }
        )
        _layout = State(
            initialValue: AccountMetricLayout(
                orderedMetricIDs: metricIDs,
                preferences: preferences
            )
        )
    }

    var body: some View {
        MetricVisualizationCustomizationView(
            accountTitle: "Personal Codex",
            result: Self.result,
            showsSeverity: true,
            isMetricVisible: { metricID in
                layout.preferences[metricID]?.isVisible ?? true
            },
            onUpdateMetricVisibility: { metricID, isVisible in
                updatePreference(metricID) { $0.isVisible = isVisible }
            },
            watchVisibilityForMetric: { metricID in
                layout.preferences[metricID]?.watchVisibility ?? .inherit
            },
            onUpdateWatchVisibility: { metricID, policy in
                updatePreference(metricID) { $0.watchVisibility = policy }
            },
            visualizationStyleForMetric: { metricID in
                layout.preferences[metricID]?.visualizationStyle ?? .linearBar
            },
            onUpdateVisualizationStyle: { metricID, style in
                updatePreference(metricID) { $0.visualizationStyle = style }
            },
            onApplyVisualizationStyleToAll: { style, metricIDs in
                for metricID in metricIDs {
                    updatePreference(metricID) { $0.visualizationStyle = style }
                }
            },
            onResetVisualizationStyles: { metricIDs in
                for metricID in metricIDs {
                    updatePreference(metricID) { $0.visualizationStyle = nil }
                }
            },
            metricWidthForMetric: { metricID in
                layout.preferences[metricID]?.width ?? .automatic
            },
            onUpdateMetricWidth: { metricID, width in
                updatePreference(metricID) { $0.width = width }
            },
            metricLayoutProvider: { layout },
            isMetricNewlyDiscovered: { metricID in
                layout.preferences[metricID]?.isNewlyDiscovered == true
            },
            onUpdateMetricOrder: { metricIDs in
                layout.orderedMetricIDs = metricIDs
            },
            onReplaceMetricLayout: { layout = $0 },
            onResetMetricLayout: { metricIDs in
                layout = AccountMetricLayout(
                    orderedMetricIDs: metricIDs,
                    preferences: Dictionary(
                        uniqueKeysWithValues: metricIDs.map {
                            ($0, MetricTilePreference(isNewlyDiscovered: false))
                        }
                    )
                )
            },
            copyLayoutDestinationsProvider: {
                [
                    MetricLayoutCopyDestination(
                        id: "codex.work",
                        title: "Work Codex",
                        availableMetricIDs: Self.result.configurableMetrics.map(\.id),
                        hasCustomLayout: true
                    ),
                ]
            },
            onCopyMetricLayout: { _ in },
            onMarkMetricsSeen: { metricIDs in
                for metricID in metricIDs {
                    updatePreference(metricID) { $0.isNewlyDiscovered = false }
                }
            }
        )
    }

    private func updatePreference(
        _ metricID: String,
        change: (inout MetricTilePreference) -> Void
    ) {
        var updatedLayout = layout
        var preference = updatedLayout.preferences[metricID] ?? MetricTilePreference()
        change(&preference)
        updatedLayout.preferences[metricID] = preference
        layout = updatedLayout
    }

    private static let result = ProviderUsageResult(
        accountID: "codex.preview",
        providerID: .codex,
        title: "Codex",
        subtitle: "Preview data",
        bars: [
            UsageBar(stableKey: "session", label: "5 hour usage limit", used: 45, limit: 100),
            UsageBar(stableKey: "weekly", label: "Weekly usage limit", used: 72, limit: 100),
        ],
        creditsRemaining: 18.75,
        monetaryMetrics: [
            ProviderMonetaryMetric(
                kind: .spent,
                label: "On-demand spend",
                minorUnits: 1_240,
                currencyCode: "USD",
                decimalPlaces: 2
            ),
        ],
        fetchedAt: Date()
    )
}

#Preview("Customize Card – iPhone Compact", traits: .fixedLayout(width: 393, height: 852)) {
    MetricCustomizationPreview()
}

#Preview("Customize Card – iPad Accessibility", traits: .fixedLayout(width: 1024, height: 1366)) {
    MetricCustomizationPreview()
        .environment(\.dynamicTypeSize, .accessibility2)
}

#Preview("Provider Card") {
    let fiveHourReset = Date().addingTimeInterval(8_100)
    let weeklyReset = Date().addingTimeInterval(2 * 24 * 60 * 60 + 4 * 60 * 60)
    let formatter = UserFacingDateTimeFormatter.current
    let fiveHourResetDescription = "Resets 2h 15m (\(formatter.timeWithZone(fiveHourReset, includesWeekday: false)))"
    let weeklyResetDescription = "Resets 2d 4h (\(formatter.timeWithZone(weeklyReset, includesWeekday: true)))"
    ProviderUsageCard(
        result: ProviderUsageResult(
            providerID: .codex,
            title: ProviderID.codex.displayName,
            subtitle: "Preview data",
            bars: [
                UsageBar(
                    stableKey: "session",
                    label: "5 hour usage limit",
                    used: 45,
                    limit: 100,
                    resetDescription: fiveHourResetDescription,
                    resetsAt: fiveHourReset,
                    projectionCurrent: 0.45,
                    projectionLimit: 1,
                    projectionPeriodStart: Date().addingTimeInterval(-3_600),
                    projectionPeriodEnd: Date().addingTimeInterval(8_100),
                    showProjectionOnCurrentBar: true
                ),
                UsageBar(
                    stableKey: "weekly",
                    label: "Weekly usage limit",
                    used: 92,
                    limit: 100,
                    resetDescription: weeklyResetDescription
                ),
            ],
            creditsRemaining: 18.75,
            monetaryMetrics: [
                ProviderMonetaryMetric(
                    kind: .spent,
                    label: "On-demand spend",
                    minorUnits: 1_240,
                    currencyCode: "USD",
                    decimalPlaces: 2,
                    detail: "of a $25.00 monthly limit"
                ),
            ],
            fetchedAt: Date()
        ),
        statusText: "Not configured - demo data",
        history: UsageHistorySeries(
            accountID: "codex",
            points: [0.34, 0.46, 0.52, 0.45, 0.62].enumerated().map { index, value in
                UsageHistoryPoint(
                    id: "preview.\(index)",
                    capturedAt: Date().addingTimeInterval(TimeInterval(index - 4) * 24 * 60 * 60),
                    value: value,
                    severity: UsageSeverity(fractionUsed: value)
                )
            },
            isBalance: false
        ),
        alerts: [
            UsageAlertDetail(
                id: "usage.codex.weekly-usage-limit",
                accountID: "codex",
                kind: .usage,
                title: "Weekly usage limit at 92%",
                message: "92 of 100 used. Alert threshold: 80%. Resets 2d 4h.",
                severity: .critical
            ),
        ],
        visualizationStyleForMetric: { metricID in
            metricID.hasSuffix(".weekly") ? .circularRing : .linearBar
        }
    )
    .padding()
    .background(Color(.systemGroupedBackground))
}
