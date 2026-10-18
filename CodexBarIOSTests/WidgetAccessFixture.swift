import Foundation
import XCTest
@testable import CodexBarIOS

final class WidgetAccessFixture: @unchecked Sendable {
    let directory: URL
    let suiteName = "WidgetAccessFixture.\(UUID().uuidString)"
    let defaults: UserDefaults
    private let lock = NSLock()
    private var clock = ProEntitlementClockSample(wallDate: Date(timeIntervalSince1970: 1_000), continuousSeconds: 500, continuityID: "boot-A")

    init() throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    var store: WidgetAccessGuard { WidgetAccessGuard(directory: directory) }
    var snapshot: CodexBarWidgetSnapshot { WidgetSnapshotStore.loadSnapshot(defaults: defaults) }
    var sample: ProEntitlementClockSample {
        lock.lock()
        defer { lock.unlock() }
        return clock
    }
    var context: WidgetAccessContext {
        WidgetAccessContext(
            guardStore: store, sample: { self.sample }, currentPublication: { self.snapshot.accessPublication }
        )
    }
    var loader: CodexBarWidgetTimelineLoader {
        CodexBarWidgetTimelineLoader(
            now: { self.sample.wallDate }, loadSnapshot: { $0 ? .preview : self.snapshot },
            loadRefreshInterval: { .fifteenMinutes }, accessContext: context
        )
    }
    var anchor: ProEntitlementClockAnchor {
        .init(anchorDate: Date(timeIntervalSince1970: 1_000), continuousSeconds: 500, continuityID: "boot-A", latestSignedAt: Date(timeIntervalSince1970: 900))
    }

    func advance(wall: TimeInterval, continuous: TimeInterval, boot: String? = "boot-A") {
        lock.lock()
        defer { lock.unlock() }
        clock = .init(wallDate: Date(timeIntervalSince1970: wall), continuousSeconds: continuous, continuityID: boot)
    }

    @discardableResult
    func publish(
        deadline: TimeInterval? = 1_100,
        anchor: ProEntitlementClockAnchor? = nil,
        generation: UUID? = UUID(),
        locked: Bool = false,
        environment: ProStoreEnvironment = .production
    ) -> CodexBarWidgetSnapshot {
        let anchor = anchor ?? self.anchor
        let publication = WidgetAccessPublication(
            finiteGrant: deadline.map { .init(deadline: Date(timeIntervalSince1970: $0), signedAt: anchor.latestSignedAt, environment: environment) },
            verificationGeneration: generation
        )
        store.publish(publication, locked: locked, anchor: anchor, replacing: snapshot.accessPublication, sample: sample)
        let snapshot = CodexBarWidgetSnapshot(
            generatedAt: sample.wallDate, results: Self.results,
            isProLocked: locked, proAccessEndsAt: deadline.map(Date.init(timeIntervalSince1970:)), accessPublication: publication
        )
        WidgetSnapshotStore.saveSnapshot(snapshot, defaults: defaults)
        return snapshot
    }

    func recoveredAnchor(signedAt: TimeInterval = 1_040) -> ProEntitlementClockAnchor {
        .init(
            anchorDate: sample.wallDate, continuousSeconds: sample.continuousSeconds,
            continuityID: sample.continuityID ?? "unavailable", latestSignedAt: Date(timeIntervalSince1970: signedAt)
        )
    }

    private static let results = [CodexBarWidgetProviderSnapshot(
        accountID: "codex.work", providerID: "codex", legacyAccountIDs: ["codex.saved"], title: "Codex", subtitle: "Work account",
        groupID: "work", groupName: "Work",
        bars: [CodexBarWidgetUsageBarSnapshot(
            id: "codex.work.weekly", label: "Weekly usage", fractionUsed: 0.37, usageText: "37%", resetDescription: "Resets Friday", severity: .normal
        ),
        ], creditsRemaining: 12.34, fetchedAt: Date(timeIntervalSince1970: 990), severity: .normal
    ),
    ]
}
