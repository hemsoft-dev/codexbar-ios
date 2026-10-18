import Darwin
import Foundation

public struct WidgetFiniteGrant: Codable, Equatable, Sendable {
    public let deadline: Date
    public let signedAt: Date
    public let environment: ProStoreEnvironment

    public init(deadline: Date, signedAt: Date, environment: ProStoreEnvironment = .production) {
        self.deadline = deadline
        self.signedAt = signedAt
        self.environment = environment
    }
}

/// Publication identity fences retained entries; grant identity survives ordinary refreshes.
public struct WidgetAccessPublication: Codable, Equatable, Sendable {
    public let id: UUID
    public let finiteGrant: WidgetFiniteGrant?
    public let environment: ProStoreEnvironment
    public let verificationGeneration: UUID?
    public let acceptedVerifications: [String: UUID]
    public let observedPartitions: Set<String>

    public init(
        id: UUID = UUID(), finiteGrant: WidgetFiniteGrant?, verificationGeneration: UUID?,
        acceptedVerifications: [String: UUID]? = nil, observedPartitions: Set<String>? = nil,
        environment: ProStoreEnvironment? = nil
    ) {
        self.id = id
        self.finiteGrant = finiteGrant
        self.environment = environment ?? finiteGrant?.environment ?? .production
        self.verificationGeneration = verificationGeneration
        self.observedPartitions = observedPartitions ?? Set(finiteGrant.map { [$0.environment.rawValue] } ?? [])
        self.acceptedVerifications = acceptedVerifications ?? finiteGrant.flatMap { grant in
            verificationGeneration.map { [grant.environment.rawValue: $0] }
        } ?? [:]
    }
}

struct WidgetAccessObservation: Codable, Equatable {
    var publication: WidgetAccessPublication
    var phoneLocked: Bool
    var finiteByEnvironment: [String: Finite]

    struct Finite: Codable, Equatable {
        let grant: WidgetFiniteGrant
        var anchor: ProEntitlementClockAnchor
        var expired: Bool
    }
}

/// Survives observation invalidation and loss of the separate usage snapshot.
private struct WidgetAccessHistory: Codable {
    var observedPartitions: Set<String> = []
    var consumedVerifications: [String: Set<UUID>] = [:]
    var latestSignedAt: [String: Date] = [:]

    mutating func consume(_ publication: WidgetAccessPublication) {
        guard let grant = publication.finiteGrant else { return }
        let partition = grant.environment.rawValue
        observedPartitions.insert(partition)
        latestSignedAt[partition] = max(latestSignedAt[partition] ?? grant.signedAt, grant.signedAt)
        if let generation = publication.verificationGeneration {
            consumedVerifications[partition, default: []].insert(generation)
        }
    }
}

/// A separate file leaves usage and saved configuration untouched. Every read/merge/write
/// holds the same nonblocking interprocess lock, including phone grant replacement.
struct WidgetAccessGuard: Sendable {
    let directory: URL?
    let write: @Sendable (Data, URL) throws -> Void
    let invalidate: @Sendable (URL) throws -> Void

    static var live: Self {
        Self(directory: FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: CodexBarWidgetConstants.appGroupIdentifier
        ))
    }

    init(
        directory: URL?,
        write: @escaping @Sendable (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) },
        invalidate: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    ) {
        self.directory = directory
        self.write = write
        self.invalidate = invalidate
    }

    @discardableResult
    func publish(
        _ publication: WidgetAccessPublication,
        locked: Bool,
        anchor: ProEntitlementClockAnchor?,
        replacing previous: WidgetAccessPublication?,
        sample: ProEntitlementClockSample
    ) -> Bool {
        coordinated { url in
            let old = read(url)
            var history = readHistory(at: url, old: old, previous: previous)
            var record = WidgetAccessObservation(
                publication: publication, phoneLocked: locked, finiteByEnvironment: old?.finiteByEnvironment ?? [:]
            )
            if let grant = publication.finiteGrant {
                let partition = grant.environment.rawValue
                guard var finiteHistory = history,
                      grant.signedAt >= (finiteHistory.latestSignedAt[partition] ?? grant.signedAt) else { return false }
                if let finite = old?.finiteByEnvironment[partition], finite.grant == grant {
                    // A new UUID, refreshed anchor or environment toggle cannot undo this partition's expiry.
                    record.finiteByEnvironment[partition] = finite
                } else {
                    guard canEstablish(publication, anchor: anchor, history: finiteHistory),
                          let anchor else { return false }
                    record.finiteByEnvironment[partition] = .init(grant: grant, anchor: anchor, expired: false)
                }
                _ = observe(&record, sample: sample)
                // Committing a denied observation still consumes its migration/verification authority.
                finiteHistory.consume(publication)
                history = finiteHistory
            }
            guard persistHistory(history, at: url) else { return false }
            return persist(record, at: url)
        } ?? false
    }

    /// Returns effective current time only after its evidence was durably merged.
    /// Neither a cached entry nor a configuration query can initialize this store.
    func effectiveDate(for publication: WidgetAccessPublication, sample: ProEntitlementClockSample) -> Date? {
        coordinated { url -> Date? in
            guard var record = read(url), record.publication.id == publication.id,
                  record.publication.environment == publication.environment,
                  record.publication.finiteGrant == publication.finiteGrant, !record.phoneLocked else { return nil }
            guard publication.finiteGrant != nil else { return sample.wallDate }
            let date = observe(&record, sample: sample)
            guard persist(record, at: url) else { return nil }
            return date
        } ?? nil
    }

    private func canEstablish(
        _ publication: WidgetAccessPublication, anchor: ProEntitlementClockAnchor?,
        history: WidgetAccessHistory
    ) -> Bool {
        guard let grant = publication.finiteGrant, let anchor, anchor.isValid,
              anchor.latestSignedAt == grant.signedAt, grant.deadline.timeIntervalSinceReferenceDate.isFinite else { return false }
        let partition = grant.environment.rawValue
        if let generation = publication.verificationGeneration,
           !history.consumedVerifications[partition, default: []].contains(generation) { return true }
        // One-time upgrade/cache migration: a healthy canonical anchor may establish
        // a never-observed partition. Missing/corrupt state after stamping cannot.
        return !history.observedPartitions.contains(partition)
    }

    private func observe(_ record: inout WidgetAccessObservation, sample: ProEntitlementClockSample) -> Date? {
        guard sample.continuousSeconds.isFinite, sample.continuousSeconds >= 0,
              let grant = record.publication.finiteGrant,
              var finite = record.finiteByEnvironment[grant.environment.rawValue], finite.grant == grant,
              finite.grant.deadline.timeIntervalSinceReferenceDate.isFinite,
              let date = finite.anchor.effectiveDate(at: sample) else { return nil }
        finite.anchor = finite.anchor.checkpoint(at: sample)
        finite.expired = finite.expired || date >= finite.grant.deadline
        record.finiteByEnvironment[grant.environment.rawValue] = finite
        return finite.expired ? nil : date
    }

    func allowsLegacyPermanent() -> Bool {
        coordinated { isMissing($0) && isMissing(markerURL(for: $0)) } ?? false
    }

    private func markerURL(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent("widget-pro-access.was-published")
    }

    private func isMissing(_ url: URL) -> Bool {
        var metadata = stat()
        return lstat(url.path, &metadata) != 0 && errno == ENOENT
    }

    private func readHistory(
        at url: URL, old: WidgetAccessObservation?, previous: WidgetAccessPublication?
    ) -> WidgetAccessHistory? {
        let marker = markerURL(for: url)
        if let data = try? Data(contentsOf: marker) {
            return try? JSONDecoder().decode(WidgetAccessHistory.self, from: data)
        }
        guard isMissing(marker), old == nil,
              previous?.observedPartitions.isEmpty != false,
              previous?.acceptedVerifications.isEmpty != false else { return nil }
        return WidgetAccessHistory()
    }

    private func persistHistory(_ history: WidgetAccessHistory?, at url: URL) -> Bool {
        let marker = markerURL(for: url)
        // A permanent grant or explicit lock may replace the current publication,
        // but cannot erase unreadable finite-grant history to authorize a replay.
        if history == nil, !isMissing(marker) { return true }
        do {
            let data = try history.map { try JSONEncoder().encode($0) } ?? Data([1])
            try data.write(to: marker, options: .atomic)
            return true
        } catch {
            try? invalidate(url)
            return false
        }
    }

    private func read(_ url: URL) -> WidgetAccessObservation? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetAccessObservation.self, from: data)
    }

    private func persist(_ record: WidgetAccessObservation, at url: URL) -> Bool {
        do {
            try write(JSONEncoder().encode(record), url)
            return true
        } catch {
            // Missing state denies readers. The next ordinary cached phone publication
            // cannot reinstall it; a new accepted verification generation is required.
            try? invalidate(url)
            return false
        }
    }

    private func coordinated<T>(_ action: (URL) -> T) -> T? {
        guard let directory else { return nil }
        let descriptor = open(directory.appendingPathComponent("widget-pro-access.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return nil }
        defer { flock(descriptor, LOCK_UN) }
        return action(directory.appendingPathComponent("widget-pro-access.json"))
    }
}

struct WidgetAccessContext: Sendable {
    let guardStore: WidgetAccessGuard
    let sample: @Sendable () -> ProEntitlementClockSample
    let currentPublication: @Sendable () -> WidgetAccessPublication?

    init(
        guardStore: WidgetAccessGuard = .live,
        sample: @escaping @Sendable () -> ProEntitlementClockSample = { ProEntitlementSystemClock.sample() },
        currentPublication: @escaping @Sendable () -> WidgetAccessPublication? = { WidgetSnapshotStore.loadSnapshot().accessPublication }
    ) {
        self.guardStore = guardStore
        self.sample = sample
        self.currentPublication = currentPublication
    }

    func effectiveDate(for snapshot: CodexBarWidgetSnapshot) -> Date? {
        guard !snapshot.isProLocked else { return nil }
        let current = sample()
        let currentID = currentPublication()?.id
        guard let publication = snapshot.accessPublication else {
            // Older permanent snapshots have no boundary to extend. Finite ones require clock evidence.
            return snapshot.proAccessEndsAt == nil && currentID == nil && guardStore.allowsLegacyPermanent() ? current.wallDate : nil
        }
        guard publication.id == currentID, publication.finiteGrant?.deadline == snapshot.proAccessEndsAt else { return nil }
        return guardStore.effectiveDate(for: publication, sample: current)
    }

    func readable(_ snapshot: CodexBarWidgetSnapshot) -> CodexBarWidgetSnapshot {
        effectiveDate(for: snapshot) == nil ? .empty : snapshot
    }
}
