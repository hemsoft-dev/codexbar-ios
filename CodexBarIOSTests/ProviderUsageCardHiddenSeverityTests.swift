import SwiftUI
import XCTest
@testable import CodexBarIOS

final class ProviderUsageCardHiddenSeverityTests: XCTestCase {
    func testHiddenMetricExplainsCardSeverityAndVoiceOver() throws {
        let result = ProviderUsageResult(
            accountID: "cursor.personal",
            providerID: .cursor,
            title: "Cursor",
            subtitle: "Usage",
            bars: [
                UsageBar(
                    stableKey: CursorUsageIdentity.cursorModelsStableKey,
                    label: "Cursor Models",
                    used: 38,
                    limit: 100
                ),
                UsageBar(
                    stableKey: CursorUsageIdentity.otherModelsStableKey,
                    label: "Other Models",
                    used: 100,
                    limit: 100
                ),
            ],
            fetchedAt: Date()
        )
        let hiddenMetricID = CursorUsageIdentity.otherModelsMetricID
        let alert = try XCTUnwrap(
            ProviderUsageCard.hiddenSeverityAlert(
                for: result,
                cardSeverity: .critical,
                isMetricVisible: { $0 != hiddenMetricID }
            )
        )

        XCTAssertEqual(alert.title, "Critical status from hidden metric")
        XCTAssertEqual(alert.message, "Hidden metric Other Models is currently at 100%.")
        XCTAssertNil(
            ProviderUsageCard.hiddenSeverityAlert(
                for: result,
                cardSeverity: .critical,
                isMetricVisible: { _ in true }
            )
        )
        XCTAssertEqual(
            ProviderUsageCard.disclosureAccessibilityLabel(
                for: result,
                statusText: "Current",
                isRefreshing: false,
                isPerformingRecovery: false,
                severity: .critical,
                severitySource: alert.message
            ),
            "Cursor, Plan unavailable, Current, Critical status, Hidden metric Other Models is currently at 100%."
        )
    }

    func testHiddenMetricExplainsProjectedSeverity() throws {
        let now = Date(timeIntervalSince1970: 1_783_667_520)
        let result = ProviderUsageResult(
            accountID: "cursor.personal",
            providerID: .cursor,
            title: "Cursor",
            subtitle: "Usage",
            bars: [
                UsageBar(
                    stableKey: CursorUsageIdentity.otherModelsStableKey,
                    label: "Other Models",
                    used: 40,
                    limit: 100,
                    projectionCurrent: 40,
                    projectionLimit: 100,
                    projectionPeriodStart: now.addingTimeInterval(-4 * 24 * 60 * 60),
                    projectionPeriodEnd: now.addingTimeInterval(6 * 24 * 60 * 60)
                ),
            ],
            fetchedAt: now
        )
        let alert = try XCTUnwrap(
            ProviderUsageCard.hiddenSeverityAlert(
                for: result,
                cardSeverity: .critical,
                now: now,
                isMetricVisible: { _ in false }
            )
        )

        XCTAssertEqual(
            alert.message,
            "Hidden metric Other Models is currently at 40% and projected to reach 100%."
        )

        let cachedResult = ProviderUsageResult(
            accountID: result.accountID,
            providerID: result.providerID,
            title: result.title,
            subtitle: "Refresh failed. Showing last known data.",
            bars: result.bars,
            barsFetchedAt: now,
            failureMessage: "Refresh failed",
            fetchedAt: now
        )
        let cachedAlert = try XCTUnwrap(
            ProviderUsageCard.hiddenSeverityAlert(
                for: cachedResult,
                cardSeverity: .critical,
                now: now,
                isMetricVisible: { _ in false }
            )
        )

        XCTAssertEqual(
            cachedAlert.message,
            "Hidden metric Other Models was last known at 40% and was projected to reach 100%."
        )
    }

    func testHiddenBalanceExplainsAlertSeverity() throws {
        let result = ProviderUsageResult(
            accountID: "openRouter.personal",
            providerID: .openRouter,
            title: "OpenRouter",
            subtitle: "Credit balance",
            bars: [],
            creditsRemaining: 4.50,
            fetchedAt: Date()
        )
        let balanceAlert = UsageAlertDetail(
            id: "balance.openRouter.personal",
            accountID: result.accountID,
            kind: .balance,
            title: "Balance below $5.00",
            message: "$4.50 remaining for OpenRouter.",
            severity: .warning
        )
        let alert = try XCTUnwrap(
            ProviderUsageCard.hiddenSeverityAlert(
                for: result,
                cardSeverity: .warning,
                alerts: [balanceAlert],
                isMetricVisible: { _ in false }
            )
        )

        XCTAssertEqual(alert.title, "Balance below $5.00 from hidden metric")
        XCTAssertEqual(alert.message, "Hidden metric Credit balance is currently at $4.50.")
    }

    func testFreshHiddenBalanceIsExplainedWhenBarsAreStale() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_785_000_200)
        let result = ProviderUsageResult(
            accountID: "openCodeZen.personal",
            providerID: .openCodeZen,
            title: "OpenCode Go + Zen",
            subtitle: "Go refresh failed",
            bars: [UsageBar(stableKey: "weekly", label: "Weekly", used: 20, limit: 100)],
            barsFetchedAt: fetchedAt.addingTimeInterval(-60),
            creditsRemaining: 4.50,
            creditsFetchedAt: fetchedAt,
            failureMessage: "Go refresh failed",
            preserveCachedBarsOnFailure: true,
            fetchedAt: fetchedAt
        )
        let balanceAlert = UsageAlertDetail(
            id: "balance.openCodeZen.personal",
            accountID: result.accountID,
            kind: .balance,
            title: "Balance below $5.00",
            message: "$4.50 remaining for OpenCode Go + Zen.",
            severity: .warning
        )
        let alert = try XCTUnwrap(
            ProviderUsageCard.hiddenSeverityAlert(
                for: result,
                cardSeverity: .warning,
                alerts: [balanceAlert],
                isMetricVisible: { _ in false }
            )
        )

        XCTAssertFalse(result.hasFreshBars)
        XCTAssertTrue(result.hasCurrentCredits)
        XCTAssertEqual(alert.message, "Hidden metric Zen credit balance is currently at $4.50.")
    }

    func testCachedHiddenUsageIsLabeledLastKnown() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_785_000_300)
        let result = ProviderUsageResult(
            accountID: "cursor.personal",
            providerID: .cursor,
            title: "Cursor",
            subtitle: "Refresh failed. Showing last known data.",
            bars: [
                UsageBar(
                    stableKey: CursorUsageIdentity.otherModelsStableKey,
                    label: "Other Models",
                    used: 100,
                    limit: 100
                ),
            ],
            barsFetchedAt: fetchedAt,
            failureMessage: "Refresh failed",
            fetchedAt: fetchedAt
        )
        let alert = try XCTUnwrap(
            ProviderUsageCard.hiddenSeverityAlert(
                for: result,
                cardSeverity: .critical,
                isMetricVisible: { _ in false }
            )
        )

        XCTAssertTrue(result.hasFreshBars)
        XCTAssertFalse(result.hasCurrentBars)
        XCTAssertEqual(alert.message, "Hidden metric Other Models was last known at 100%.")
    }

    func testHiddenSpendExplainsReachedLimitSeverity() throws {
        let result = ProviderUsageResult(
            accountID: "claude.personal",
            providerID: .claude,
            title: "Claude",
            subtitle: "Usage credits",
            bars: [],
            monetaryMetrics: [
                ProviderMonetaryMetric(
                    kind: .spent,
                    label: "Monthly spend",
                    minorUnits: 5_000,
                    currencyCode: "USD",
                    decimalPlaces: 2
                ),
                ProviderMonetaryMetric(
                    kind: .spendLimit,
                    label: "Monthly spend limit",
                    minorUnits: 5_000,
                    currencyCode: "USD",
                    decimalPlaces: 2
                ),
            ],
            fetchedAt: Date()
        )
        let spentMetricID = "claude.monetary.spent.usd"
        let alert = try XCTUnwrap(
            ProviderUsageCard.hiddenSeverityAlert(
                for: result,
                cardSeverity: .critical,
                isMetricVisible: { $0 != spentMetricID }
            )
        )

        XCTAssertEqual(alert.title, "Critical status from hidden metric")
        XCTAssertEqual(
            alert.message,
            "Hidden metric Monthly spend is currently at $50.00 and has reached the $50.00 limit."
        )

        let cachedResult = ProviderUsageResult(
            accountID: result.accountID,
            providerID: result.providerID,
            title: result.title,
            subtitle: "Refresh failed. Showing last known data.",
            bars: [],
            monetaryMetrics: result.monetaryMetrics,
            failureMessage: "Refresh failed",
            fetchedAt: result.fetchedAt
        )
        let cachedAlert = try XCTUnwrap(
            ProviderUsageCard.hiddenSeverityAlert(
                for: cachedResult,
                cardSeverity: .critical,
                isMetricVisible: { $0 != spentMetricID }
            )
        )

        XCTAssertEqual(
            cachedAlert.message,
            "Hidden metric Monthly spend was last known at $50.00 "
                + "and was last known to have reached the $50.00 limit."
        )
    }

    @MainActor
    func testRenderedHeaderAnnouncesStatusHiddenSeverityAndCollapsedState() throws {
        let result = Self.cursorResultWithFullOtherModels()
        let hiddenMetricID = CursorUsageIdentity.otherModelsMetricID
        let probe = try HostedViewProbe(ProviderUsageCard(
            result: result,
            statusText: "Updated just now",
            history: UsageHistorySeries(accountID: result.accountID, points: [], isBalance: false),
            isExpanded: false,
            isMetricVisible: { $0 != hiddenMetricID }
        ))
        defer { probe.close() }
        let hiddenMessage = "Hidden metric Other Models is currently at 100%."
        let disclosure = try XCTUnwrap(probe.element(labelPrefix: "Cursor, "), "\(probe.labels)")

        XCTAssertEqual(
            disclosure.accessibilityLabel,
            ProviderUsageCard.disclosureAccessibilityLabel(
                for: result,
                statusText: "Updated just now",
                isRefreshing: false,
                isPerformingRecovery: false,
                severity: .critical,
                severitySource: hiddenMessage
            )
        )
        XCTAssertEqual(disclosure.accessibilityValue, "Collapsed")
        XCTAssertEqual(disclosure.accessibilityHint, ProviderUsageCard.disclosureAccessibilityHint(isExpanded: false, title: "Cursor"))
        XCTAssertNotNil(probe.element(label: "More options for Cursor"), "\(probe.labels)")
        XCTAssertFalse(probe.labels.contains { $0.contains("Refreshing") || $0.contains("Signing in") })
    }

    @MainActor
    func testRenderedHeaderReportsRefreshAndRecoveryProgressWithoutHiddenSeverity() throws {
        let result = Self.cursorResultWithFullOtherModels()
        for (isRefreshing, isPerformingRecovery, progressText) in [(true, false, "Refreshing"), (true, true, "Signing in")] {
            let probe = try HostedViewProbe(ProviderUsageCard(
                result: result,
                statusText: "",
                history: UsageHistorySeries(accountID: result.accountID, points: [], isBalance: false),
                isRefreshing: isRefreshing,
                isExpanded: true,
                isPerformingRecovery: isPerformingRecovery
            ))
            defer { probe.close() }
            let disclosure = try XCTUnwrap(probe.element(labelPrefix: "Cursor, "), "\(probe.labels)")

            XCTAssertEqual(
                disclosure.accessibilityLabel,
                ProviderUsageCard.disclosureAccessibilityLabel(
                    for: result,
                    statusText: "",
                    isRefreshing: isRefreshing,
                    isPerformingRecovery: isPerformingRecovery,
                    severity: .critical
                )
            )
            XCTAssertTrue(disclosure.accessibilityLabel?.contains(progressText) == true)
            XCTAssertEqual(disclosure.accessibilityValue, "Expanded")
            XCTAssertFalse(probe.labels.contains { $0.hasPrefix("Hidden metric") }, "\(probe.labels)")
        }
    }

    @MainActor
    func testRenderedHeaderMenuOffersAccountAndCardActions() throws {
        let result = Self.cursorResultWithFullOtherModels()
        let probe = try HostedViewProbe(ProviderUsageCard(
            result: result,
            statusText: "Updated just now",
            history: UsageHistorySeries(accountID: result.accountID, points: [], isBalance: false),
            isExpanded: false
        ))
        defer { probe.close() }
        let expectedActions = ProviderUsageCard.menuActions(for: result)

        XCTAssertTrue(expectedActions.contains(.configureAccount))
        XCTAssertTrue(expectedActions.contains(.customizeMetrics))
        XCTAssertTrue(probe.activate(label: "More options for Cursor"), "\(probe.labels)")
        XCTAssertTrue(probe.waitUntil { probe.element(label: "Configure account Cursor") != nil }, "\(probe.labels)")
        XCTAssertNotNil(probe.element(label: "Customize Card…"), "\(probe.labels)")
        XCTAssertEqual(
            probe.element(label: "More information for Cursor") != nil,
            expectedActions.contains(.moreInformation),
            "\(probe.labels)"
        )
    }

    @MainActor
    func testResetInventoryRowsExplainEachGrantState() throws {
        let now = Date()
        let selected = Self.resetGrant(id: "selected", remainingCount: 2, now: now)
        let paused = Self.resetGrant(id: "paused", title: "Paused grant", isPaused: true, now: now)
        let expired = Self.resetGrant(id: "expired", title: "Expired grant", expiresIn: -60, now: now)
        let limited = Self.resetGrant(id: "limited", title: "Limited grant", requiresLimit: true, now: now)
        let disabled = Self.resetGrant(id: "disabled", title: "Disabled grant", requiresLimit: false, now: now)
        let inventory = ClaudeUsageResetInventory(
            isEligible: true, grants: [selected, paused, expired, limited, disabled],
            selectedGrantID: selected.id, cooldownUntil: nil, credentialBinding: "binding"
        )
        let probe = try HostedViewProbe(ClaudeUsageResetInventoryView(
            inventory: inventory, accountName: "Work Claude", canRedeem: true,
            onUseReset: { _, _ in ClaudeUsageResetFeedback(message: "Unused", isSuccess: true) }
        ))
        defer { probe.close() }
        let labels = probe.labels

        XCTAssertEqual(probe.element(identifier: "claude-reset-summary")?.accessibilityLabel, "4 resets available", "\(labels)")
        XCTAssertTrue(labels.contains("2 saved resets"), "\(labels)")
        XCTAssertTrue(labels.contains("1 saved reset"), "\(labels)")
        XCTAssertTrue(labels.contains("Resets five-hour usage and weekly usage."), "\(labels)")
        XCTAssertTrue(labels.contains("Paused by Claude"), "\(labels)")
        XCTAssertTrue(labels.contains("Not currently available"), "\(labels)")
        XCTAssertTrue(
            labels.contains("Claude may require a usage limit to be reached before this reset can be used."), "\(labels)"
        )
        XCTAssertTrue(labels.contains("Claude has not enabled this reset for use now."), "\(labels)")
        XCTAssertEqual(probe.elements(identifier: "claude-use-reset").map(\.accessibilityLabel), ["Use one reset"])
        XCTAssertNil(probe.element(identifier: "claude-reset-cooldown"))
    }

    @MainActor
    func testResetInventoryHidesActionDuringCooldownOrWhenRedemptionIsUnavailable() throws {
        let now = Date()
        let grant = Self.resetGrant(id: "selected", remainingCount: 1, expiresIn: nil, now: now)
        let cooldown = ClaudeUsageResetInventory(
            isEligible: true, grants: [grant], selectedGrantID: grant.id,
            cooldownUntil: now.addingTimeInterval(3_600), credentialBinding: "binding"
        )
        let cooldownProbe = try HostedViewProbe(ClaudeUsageResetInventoryView(
            inventory: cooldown, accountName: "Work Claude", canRedeem: true,
            onUseReset: { _, _ in ClaudeUsageResetFeedback(message: "Unused", isSuccess: true) }
        ))
        let cooldownLabel = cooldownProbe.element(identifier: "claude-reset-cooldown")?.accessibilityLabel
        let cooldownLabels = cooldownProbe.labels
        let cooldownActions = cooldownProbe.elements(identifier: "claude-use-reset")
        cooldownProbe.close()

        XCTAssertTrue(cooldownLabel?.hasPrefix("Claude reset cooldown ends ") == true, "\(cooldownLabels)")
        XCTAssertTrue(cooldownLabels.contains("Expiration not provided by Claude."), "\(cooldownLabels)")
        XCTAssertTrue(cooldownActions.isEmpty)

        let available = ClaudeUsageResetInventory(
            isEligible: true, grants: [grant], selectedGrantID: grant.id, cooldownUntil: nil, credentialBinding: "binding"
        )
        let lockedProbe = try HostedViewProbe(ClaudeUsageResetInventoryView(
            inventory: available, accountName: "Work Claude", canRedeem: false,
            onUseReset: { _, _ in ClaudeUsageResetFeedback(message: "Unused", isSuccess: true) }
        ))
        defer { lockedProbe.close() }

        XCTAssertTrue(lockedProbe.labels.contains("Refresh Claude usage before using a reset."), "\(lockedProbe.labels)")
        XCTAssertTrue(lockedProbe.elements(identifier: "claude-use-reset").isEmpty, "\(lockedProbe.labels)")
        XCTAssertNil(lockedProbe.element(identifier: "claude-reset-cooldown"))
    }

    @MainActor
    func testProgressLabelMatchAcceptsOnlyTheLabelOrItsInProgressForm() {
        XCTAssertTrue(HostedViewProbe.isProgressLabel("Using reset…", "Using reset…"))
        XCTAssertTrue(HostedViewProbe.isProgressLabel("In progress, Using reset…", "Using reset…"))
        for label in [nil, "", "In progress", "Use one reset", "Using reset", "In progress, Use one reset", "Using reset…, In progress"] {
            XCTAssertFalse(HostedViewProbe.isProgressLabel(label, "Using reset…"), "\(String(describing: label))")
        }
    }

    @MainActor
    func testResetInventoryShowsProgressThenFeedbackWhileUsingConfirmedReset() throws {
        let now = Date()
        let grant = Self.resetGrant(id: "selected", remainingCount: 1, now: now)
        let inventory = ClaudeUsageResetInventory(
            isEligible: true, grants: [grant], selectedGrantID: grant.id, cooldownUntil: nil, credentialBinding: "binding"
        )
        let gate = ResetRedemptionGate()
        let probe = try HostedViewProbe(ClaudeUsageResetInventoryView(
            inventory: inventory, accountName: "Work Claude", canRedeem: true,
            onUseReset: { redeemed, binding in
                await gate.wait(grantID: redeemed.id, binding: binding)
            }
        ))
        defer {
            gate.release()
            probe.close()
        }

        XCTAssertTrue(probe.activate(identifier: "claude-use-reset"), "\(probe.labels)")
        XCTAssertTrue(probe.waitUntil { probe.element(label: "Use reset") != nil }, "\(probe.labels)")
        XCTAssertTrue(probe.chooseAlertAction("Use reset"), "\(probe.labels)")
        XCTAssertTrue(probe.waitUntil { gate.request != nil }, "\(probe.labels)")
        XCTAssertTrue(
            probe.waitUntil { probe.labels.contains { HostedViewProbe.isProgressLabel($0, "Using reset…") } }, "\(probe.labels)"
        )
        XCTAssertEqual(gate.request?.grantID, grant.id)
        XCTAssertEqual(gate.request?.binding, "binding")

        gate.release()

        XCTAssertTrue(probe.waitUntil { probe.element(identifier: "claude-reset-feedback") != nil }, "\(probe.labels)")
        XCTAssertEqual(probe.element(identifier: "claude-reset-feedback")?.accessibilityLabel, "Claude reset used.")
        XCTAssertEqual(probe.elements(identifier: "claude-use-reset").map(\.accessibilityLabel), ["Use one reset"])
    }

    @MainActor
    func testProbeRestoresAnimationsOnlyAfterEveryOverlappingWindowCloses() throws {
        let original = UIView.areAnimationsEnabled
        defer { UIView.setAnimationsEnabled(original) }
        UIView.setAnimationsEnabled(true)
        let first = try HostedViewProbe(Text("First probe"))
        defer { first.close() }
        let second = try HostedViewProbe(Text("Second probe"))
        defer { second.close() }

        XCTAssertFalse(UIView.areAnimationsEnabled)
        first.close()
        XCTAssertFalse(UIView.areAnimationsEnabled, "A remaining probe still owns a live window.")
        first.close()
        XCTAssertFalse(UIView.areAnimationsEnabled, "Repeated close must not release another window's lease.")
        second.close()
        XCTAssertTrue(UIView.areAnimationsEnabled)
    }

    @MainActor
    func testProbePreservesPreviouslyDisabledAnimations() throws {
        let original = UIView.areAnimationsEnabled
        defer { UIView.setAnimationsEnabled(original) }
        UIView.setAnimationsEnabled(false)
        let probe = try HostedViewProbe(Text("Existing animation policy"))
        defer { probe.close() }
        probe.close()
        XCTAssertFalse(UIView.areAnimationsEnabled)
    }

    private static func cursorResultWithFullOtherModels() -> ProviderUsageResult {
        ProviderUsageResult(
            accountID: "cursor.personal",
            providerID: .cursor,
            title: "Cursor",
            subtitle: "Usage",
            bars: [
                UsageBar(stableKey: CursorUsageIdentity.cursorModelsStableKey, label: "Cursor Models", used: 38, limit: 100),
                UsageBar(stableKey: CursorUsageIdentity.otherModelsStableKey, label: "Other Models", used: 100, limit: 100),
            ],
            fetchedAt: Date()
        )
    }

    private static func resetGrant(
        id: String,
        title: String = "Saved reset",
        remainingCount: Int = 1,
        expiresIn: TimeInterval? = 86_400,
        isPaused: Bool = false,
        requiresLimit: Bool = true,
        now: Date
    ) -> ClaudeUsageResetGrant {
        ClaudeUsageResetGrant(
            id: id, title: title, remainingCount: remainingCount, startsAt: now.addingTimeInterval(-3_600),
            expiresAt: expiresIn.map { now.addingTimeInterval($0) }, clears: ["seven_day", "five_hour"],
            isPaused: isPaused, isUsableNow: true, requiresLimit: requiresLimit
        )
    }
}

/// Holds one reset redemption open so the rendered in-progress state stays observable.
@MainActor
private final class ResetRedemptionGate {
    private(set) var request: (grantID: String, binding: String)?
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReleased = false

    func wait(grantID: String, binding: String) async -> ClaudeUsageResetFeedback {
        request = (grantID, binding)
        if !isReleased {
            await withCheckedContinuation { continuation = $0 }
        }
        return ClaudeUsageResetFeedback(message: "Claude reset used.", isSuccess: true)
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}

/// Hosts SwiftUI content in a real window and reads the accessibility tree that
/// SwiftUI publishes only while accessibility automation is enabled.
@MainActor
final class HostedViewProbe {
    enum ProbeError: Error {
        case accessibilityAutomationUnavailable
    }

    private typealias AutomationGetter = @convention(c) () -> Bool
    private typealias AutomationSetter = @convention(c) (Bool) -> Void

    private let window: UIWindow
    private let setAutomation: AutomationSetter
    private static var activeWindows = 0
    private static var originalAutomationEnabled = false
    private static var originalAnimationsEnabled = true
    private var isClosed = false

    init<Content: View>(_ content: Content, size: CGSize = CGSize(width: 390, height: 2_000), settles: Bool = true) throws {
        guard let library = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW),
              let getter = dlsym(library, "_AXSAutomationEnabled"),
              let setter = dlsym(library, "_AXSSetAutomationEnabled") else {
            throw ProbeError.accessibilityAutomationUnavailable
        }
        setAutomation = unsafeBitCast(setter, to: AutomationSetter.self)
        Self.acquireWindowPolicy(
            automationEnabled: unsafeBitCast(getter, to: AutomationGetter.self)(),
            setter: unsafeBitCast(setter, to: AutomationSetter.self)
        )
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = UIHostingController(rootView: content.transaction {
            $0.animation = nil
            $0.disablesAnimations = true
        })
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        if settles { settle() }
    }

    /// Every element or identified container currently reachable from the window, including presentations.
    var elements: [NSObject] {
        var visited = Set<ObjectIdentifier>()
        var found: [NSObject] = []
        func visit(_ object: NSObject) {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return }
            if let view = object as? UIView, view.isHidden || view.alpha == 0 { return }
            if object.isAccessibilityElement || Self.identifier(of: object) != nil { found.append(object) }
            if let children = object.accessibilityElements as? [NSObject] {
                children.forEach(visit)
            } else {
                let count = object.accessibilityElementCount()
                if count != NSNotFound, count > 0 {
                    (0..<count).compactMap { object.accessibilityElement(at: $0) as? NSObject }.forEach(visit)
                }
            }
            (object as? UIView)?.subviews.forEach(visit)
        }
        visit(window)
        return found
    }

    var labels: [String] { elements.compactMap(\.accessibilityLabel) }

    func element(label: String) -> NSObject? { elements.first { $0.accessibilityLabel == label } }

    func element(labelPrefix: String) -> NSObject? {
        elements.first { $0.accessibilityLabel?.hasPrefix(labelPrefix) == true }
    }

    /// SwiftUI reports a labelled ProgressView as "In progress, <label>" while the device has
    /// application accessibility enabled, and as "<label>" otherwise.
    static func isProgressLabel(_ label: String?, _ text: String) -> Bool {
        label == text || label == "In progress, \(text)"
    }

    func element(identifier: String) -> NSObject? { elements(identifier: identifier).first }

    func elements(identifier: String) -> [NSObject] { elements.filter { Self.identifier(of: $0) == identifier } }

    @discardableResult
    func activate(label: String) -> Bool { activate(elements.filter { $0.accessibilityLabel == label }) }

    @discardableResult
    func activate(identifier: String) -> Bool { activate(elements(identifier: identifier)) }

    /// Spins the main run loop so SwiftUI tasks, transactions and presentations can finish.
    func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return false }
            settle(0.05)
        }
        return true
    }

    /// UIKit alert actions ignore accessibility activation outside VoiceOver, so run the
    /// chosen action's handler and dismissal the way a tap would.
    func chooseAlertAction(_ title: String) -> Bool {
        typealias Handler = @convention(block) (UIAlertAction) -> Void
        guard let alert = window.rootViewController?.presentedViewController as? UIAlertController,
              let action = alert.actions.first(where: { $0.title == title }),
              let handler = action.value(forKey: "handler") else { return false }
        alert.dismiss(animated: false)
        unsafeBitCast(handler as AnyObject, to: Handler.self)(action)
        settle()
        return true
    }

    func settle(_ interval: TimeInterval = 0.2) {
        RunLoop.main.run(until: Date().addingTimeInterval(interval))
        window.layoutIfNeeded()
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        window.rootViewController?.presentedViewController?.dismiss(animated: false)
        window.isHidden = true
        window.rootViewController = nil
        Self.activeWindows -= 1
        if Self.activeWindows == 0 {
            setAutomation(Self.originalAutomationEnabled)
            UIView.setAnimationsEnabled(Self.originalAnimationsEnabled)
        }
    }

    /// These probes assert rendered accessibility and actions, not animation timing.
    /// UIKit menu morphs must finish synchronously before their temporary window disappears.
    private static func acquireWindowPolicy(automationEnabled: Bool, setter: AutomationSetter) {
        if activeWindows == 0 {
            originalAutomationEnabled = automationEnabled
            originalAnimationsEnabled = UIView.areAnimationsEnabled
            setter(true)
            UIView.setAnimationsEnabled(false)
        }
        activeWindows += 1
    }

    /// UIKit can publish a label on both a control and its text; the first element that accepts activation wins.
    private func activate(_ candidates: [NSObject]) -> Bool {
        guard candidates.contains(where: { $0.accessibilityActivate() }) else { return false }
        settle()
        return true
    }

    private static func identifier(of object: NSObject) -> String? {
        guard object.responds(to: NSSelectorFromString("accessibilityIdentifier")),
              let identifier = object.value(forKey: "accessibilityIdentifier") as? String,
              !identifier.isEmpty else { return nil }
        return identifier
    }
}
