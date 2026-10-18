import Darwin
import Foundation
#if CODEXBAR_PHONE_WATCH_TESTS
@testable import CodexBarIOS
#endif

struct WatchAccessDecision {
    let source: WatchDashboardSnapshot
    let effectiveDate: Date?
    let epoch: UUID?
    let hasExpired: Bool

    var isLocked: Bool { source.isProLocked || effectiveDate == nil || hasExpired }
    var snapshot: WatchDashboardSnapshot { isLocked ? source.lockingAccess() : source }
    var remaining: TimeInterval? {
        guard !isLocked, let deadline = source.proAccessEndsAt, let effectiveDate else { return nil }
        return max(0, deadline.timeIntervalSince(effectiveDate))
    }
}

/// A coherent Watch-local observation retained while its first durable write is pending.
/// A newer phone floor is applied at its own receipt, after elapsed Watch time is counted.
struct WatchAccessPublication {
    let deadline: Date?
    let anchor: ProEntitlementClockAnchor?

    init(_ snapshot: WatchDashboardSnapshot, sample: ProEntitlementClockSample, previous: Self? = nil) {
        deadline = snapshot.proAccessEndsAt
        if previous?.deadline == deadline, let old = previous?.anchor {
            anchor = Self.checkpoint(old, floor: snapshot.proAccessEffectiveAt, sample: sample) ?? old
        } else if deadline?.timeIntervalSinceReferenceDate.isFinite == true,
                  let floor = snapshot.proAccessEffectiveAt, floor.timeIntervalSinceReferenceDate.isFinite,
                  sample.wallDate.timeIntervalSinceReferenceDate.isFinite, let continuityID = sample.continuityID {
            let date = max(sample.wallDate, floor)
            let initial = ProEntitlementClockAnchor(
                anchorDate: date, continuousSeconds: sample.continuousSeconds,
                continuityID: continuityID, latestSignedAt: date
            )
            anchor = initial.isValid ? initial : nil
        } else { anchor = nil }
    }

    static func checkpoint(
        _ anchor: ProEntitlementClockAnchor, floor: Date?, sample: ProEntitlementClockSample
    ) -> ProEntitlementClockAnchor? {
        guard floor.map({ $0.timeIntervalSinceReferenceDate.isFinite }) != false,
              sample.continuousSeconds.isFinite, sample.continuousSeconds >= 0,
              let effective = anchor.effectiveDate(at: sample) else { return nil }
        guard let floor, floor > effective else { return anchor.checkpoint(at: sample) }
        guard let continuityID = sample.continuityID, !continuityID.isEmpty else { return nil }
        return ProEntitlementClockAnchor(
            anchorDate: floor, continuousSeconds: sample.continuousSeconds,
            continuityID: continuityID, latestSignedAt: anchor.latestSignedAt
        )
    }
}

/// Watch-local elapsed evidence shared by the app, complications and intent queries.
/// Usage timestamps and revisions only order delivery. A phone-effective floor can
/// advance local time, but never replace elapsed evidence or extend the fixed deadline.
struct WatchAccessClockStore: Sendable {
    let directory: URL?
    private let write: @Sendable (Data, URL) throws -> Void

    init(directory: URL?, write: @escaping @Sendable (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) {
        self.directory = directory
        self.write = write
    }

    private struct Stamp: Codable, Equatable {
        let sequence: UInt64?
        let generatedAt: Date
        let locked: Bool
        let deadline: Date?
        let effectiveAt: Date?

        init(_ snapshot: WatchDashboardSnapshot) {
            sequence = snapshot.publicationSequence
            generatedAt = snapshot.generatedAt
            locked = snapshot.isProLocked
            deadline = snapshot.proAccessEndsAt
            effectiveAt = snapshot.proAccessEffectiveAt
        }

        func hasSameAccess(as other: Self) -> Bool { locked == other.locked && deadline == other.deadline }
    }

    private struct Observation: Codable {
        var anchor: ProEntitlementClockAnchor
        var expired: Bool
    }

    private struct History: Codable, Equatable {
        var deadlines: Set<String> = []
        var unavailable = false

        mutating func merge(_ other: Self?) {
            guard let other else { return }
            deadlines.formUnion(other.deadlines)
            unavailable = unavailable || other.unavailable
        }
    }

    private struct Record: Codable {
        var stamp: Stamp
        var epoch: UUID
        var deadlines: [String: Observation]
        var history: History
    }

    @discardableResult
    func accept(
        _ snapshot: WatchDashboardSnapshot, sample: ProEntitlementClockSample, origin: WatchAccessPublication? = nil
    ) -> Bool {
        coordinated { url in
            let stamp = Stamp(snapshot)
            let previous = read(url)
            let history = previous?.history ?? readHistory(markerURL(url))
                ?? History(unavailable: !(isMissing(url) && isMissing(markerURL(url))))
            var record = previous ?? Record(stamp: stamp, epoch: UUID(), deadlines: [:], history: history)
            record.history.merge(readHistory(markerURL(url)))
            if !record.stamp.hasSameAccess(as: stamp) { record.epoch = UUID() }
            record.stamp = stamp
            if let deadline = snapshot.proAccessEndsAt {
                guard deadline.timeIntervalSinceReferenceDate.isFinite else { return false }
                let key = deadlineKey(deadline)
                if record.deadlines[key] == nil {
                    // Losing evidence cannot turn an old deadline into a newly received allowance.
                    guard !record.history.unavailable, !record.history.deadlines.contains(key) else { return false }
                    let received = origin?.deadline == deadline ? origin : WatchAccessPublication(snapshot, sample: sample)
                    if let anchor = received?.anchor, anchor.isValid {
                        record.deadlines[key] = Observation(anchor: anchor, expired: false)
                        record.history.deadlines.insert(key)
                    }
                }
                let pendingFloor = origin?.deadline == deadline ? origin?.anchor?.effectiveDate(at: sample) : nil
                _ = observe(&record, deadline: deadline, sample: sample, pendingFloor: pendingFloor)
            }
            // Commit the full anchor first. A failed first write has granted no access and can retry.
            guard persist(record, at: url), commitHistory(record.history, at: markerURL(url)) else { return false }
            return snapshot.proAccessEndsAt.map { record.deadlines[deadlineKey($0)] != nil } ?? true
        } ?? false
    }

    func decision(for snapshot: WatchDashboardSnapshot, sample: ProEntitlementClockSample) -> WatchAccessDecision {
        let denied = WatchAccessDecision(source: snapshot, effectiveDate: nil, epoch: nil, hasExpired: false)
        return coordinated { url in
            guard var record = read(url), record.stamp == Stamp(snapshot) else { return denied }
            record.history.merge(readHistory(markerURL(url)))
            guard let deadline = snapshot.proAccessEndsAt else {
                guard commitHistory(record.history, at: markerURL(url)) else { return denied }
                return WatchAccessDecision(source: snapshot, effectiveDate: sample.wallDate, epoch: record.epoch, hasExpired: false)
            }
            let effectiveDate = observe(&record, deadline: deadline, sample: sample)
            let expired = record.deadlines[deadlineKey(deadline)]?.expired == true
            guard persist(record, at: url), commitHistory(record.history, at: markerURL(url)) else {
                // Preserve actual expiry in the independent receipt even if checkpointing fails.
                return WatchAccessDecision(source: snapshot, effectiveDate: nil, epoch: nil, hasExpired: expired)
            }
            return WatchAccessDecision(source: snapshot, effectiveDate: effectiveDate, epoch: record.epoch, hasExpired: expired)
        } ?? denied
    }

    func recordExpiration(_ deadline: Date) {
        _ = coordinated { url in
            guard var record = read(url), var observation = record.deadlines[deadlineKey(deadline)] else { return false }
            observation.expired = true
            record.deadlines[deadlineKey(deadline)] = observation
            return persist(record, at: url)
        }
    }

    private func observe(
        _ record: inout Record, deadline: Date, sample: ProEntitlementClockSample, pendingFloor: Date? = nil
    ) -> Date? {
        let key = deadlineKey(deadline)
        guard record.stamp.effectiveAt.map({ $0.timeIntervalSinceReferenceDate.isFinite }) != false,
              var observation = record.deadlines[key] else { return nil }
        let floor = [record.stamp.effectiveAt, pendingFloor].compactMap { $0 }.max()
        guard let checkpoint = WatchAccessPublication.checkpoint(observation.anchor, floor: floor, sample: sample),
              let effective = checkpoint.effectiveDate(at: sample) else { return nil }
        observation.anchor = checkpoint
        observation.expired = observation.expired || effective >= deadline
        record.deadlines[key] = observation
        return observation.expired ? nil : effective
    }

    private func deadlineKey(_ deadline: Date) -> String { String(deadline.timeIntervalSinceReferenceDate) }
    private func markerURL(_ url: URL) -> URL { url.appendingPathExtension("initialized") }

    private func isMissing(_ url: URL) -> Bool {
        var metadata = stat()
        return lstat(url.path, &metadata) != 0 && errno == ENOENT
    }

    private func read(_ url: URL) -> Record? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    private func readHistory(_ url: URL) -> History? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(History.self, from: data)
    }

    private func commitHistory(_ history: History, at url: URL) -> Bool {
        if readHistory(url) == history { return true }
        do {
            try write(JSONEncoder().encode(history), url)
            return true
        } catch { return false }
    }

    private func persist(_ record: Record, at url: URL) -> Bool {
        do {
            try write(JSONEncoder().encode(record), url)
            return true
        } catch {
            // Keep the last durable anchor. Every retry re-evaluates elapsed time before allowing access.
            return false
        }
    }

    private func coordinated<T>(_ action: (URL) -> T) -> T? {
        guard let directory else { return nil }
        let descriptor = open(directory.appendingPathComponent("watch-access-clock.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return nil }
        defer { flock(descriptor, LOCK_UN) }
        return action(directory.appendingPathComponent("watch-access-clock.json"))
    }
}
