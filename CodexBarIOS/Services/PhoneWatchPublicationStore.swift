import Foundation

/// Orders phone publications across restarts without trusting the wall clock.
@MainActor
final class PhoneWatchPublicationStore {
    private static let snapshotKey = "watch.lastOrderedSnapshot"
    private static let sequenceKey = "watch.publicationSequence"
    private let defaults: UserDefaults
    private(set) var snapshot: WatchDashboardSnapshot?
    private var requestedSequenceFloor: UInt64?

    init(defaults: UserDefaults, initialApplicationContext: [String: Any]? = nil) {
        self.defaults = defaults
        snapshot = defaults.data(forKey: Self.snapshotKey).flatMap { try? WatchDashboardSnapshot.decode($0) }
        if snapshot == nil, let initialApplicationContext {
            snapshot = try? WatchDashboardSnapshot.decodeApplicationContext(initialApplicationContext)
        }
    }

    func observeReceiverSequence(_ sequence: UInt64) {
        guard sequence < UInt64.max - 1 else { return }
        requestedSequenceFloor = max(requestedSequenceFloor ?? 0, sequence)
    }

    private var savedSequence: UInt64 {
        let saved = (defaults.object(forKey: Self.sequenceKey) as? NSNumber)?.uint64Value ?? 0
        // Invalid local counters recover through the retained context and watch watermark.
        return saved < UInt64.max - 1 ? saved : 0
    }

    func record(_ candidate: WatchDashboardSnapshot) throws -> WatchDashboardSnapshot {
        defer { requestedSequenceFloor = nil }
        let previousSequence = max(
            savedSequence,
            snapshot?.publicationSequence ?? 0,
            requestedSequenceFloor ?? 0
        )
        let unchanged = try snapshot?.semanticData() == candidate.semanticData()
        let incremented = previousSequence.addingReportingOverflow(1)
        guard !incremented.overflow, incremented.partialValue < UInt64.max - 1 else {
            throw WatchDashboardPayloadError.invalidPublicationSequence
        }
        let satisfiesReceiver = requestedSequenceFloor.map { previousSequence > $0 } ?? true
        let sequence = unchanged && snapshot?.publicationSequence == previousSequence && satisfiesReceiver
            ? previousSequence : incremented.partialValue
        let ordered = WatchDashboardSnapshot(
            schemaVersion: candidate.schemaVersion, generatedAt: candidate.generatedAt,
            refreshIntervalSeconds: candidate.refreshIntervalSeconds, accounts: candidate.accounts,
            isProLocked: candidate.isProLocked, proAccessEndsAt: candidate.proAccessEndsAt,
            proAccessEffectiveAt: candidate.proAccessEffectiveAt,
            publicationSequence: sequence
        )
        let data = try ordered.encoded()
        defaults.set(NSNumber(value: sequence), forKey: Self.sequenceKey)
        defaults.set(data, forKey: Self.snapshotKey)
        snapshot = ordered
        return ordered
    }
}
