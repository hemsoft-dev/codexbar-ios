import Darwin
import Foundation

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

/// Watch-local elapsed evidence shared by the app, complications and intent queries.
/// Phone timestamps/revisions identify delivery only; they never replace an existing anchor.
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

        init(_ snapshot: WatchDashboardSnapshot) {
            sequence = snapshot.publicationSequence
            generatedAt = snapshot.generatedAt
            locked = snapshot.isProLocked
            deadline = snapshot.proAccessEndsAt
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
    func accept(_ snapshot: WatchDashboardSnapshot, sample: ProEntitlementClockSample) -> Bool {
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
                    if let continuityID = sample.continuityID {
                        let anchor = ProEntitlementClockAnchor(
                            anchorDate: sample.wallDate, continuousSeconds: sample.continuousSeconds,
                            continuityID: continuityID, latestSignedAt: sample.wallDate
                        )
                        if anchor.isValid {
                            record.deadlines[key] = Observation(anchor: anchor, expired: false)
                            record.history.deadlines.insert(key)
                        }
                    }
                }
                _ = observe(&record, deadline: deadline, sample: sample)
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

    private func observe(_ record: inout Record, deadline: Date, sample: ProEntitlementClockSample) -> Date? {
        let key = deadlineKey(deadline)
        guard sample.continuousSeconds.isFinite, sample.continuousSeconds >= 0,
              var observation = record.deadlines[key], let effective = observation.anchor.effectiveDate(at: sample) else { return nil }
        observation.anchor = observation.anchor.checkpoint(at: sample)
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
