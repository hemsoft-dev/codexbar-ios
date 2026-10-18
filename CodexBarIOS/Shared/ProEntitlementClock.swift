import Darwin
import Foundation
import ProClockSupport

public struct ProEntitlementClockSample: Equatable, Sendable {
    public let wallDate: Date
    public let continuousSeconds: TimeInterval
    public let continuityID: String?

    public init(wallDate: Date, continuousSeconds: TimeInterval, continuityID: String?) {
        self.wallDate = wallDate
        self.continuousSeconds = continuousSeconds
        self.continuityID = continuityID
    }
}

/// Local elapsed-time evidence, without a device, purchase, or account identifier.
public struct ProEntitlementClockAnchor: Codable, Equatable, Sendable {
    public let anchorDate: Date
    public let continuousSeconds: TimeInterval
    public let continuityID: String
    public let latestSignedAt: Date
    public let calendarFloor: Date?

    public init(
        anchorDate: Date, continuousSeconds: TimeInterval, continuityID: String, latestSignedAt: Date, calendarFloor: Date? = nil
    ) {
        self.anchorDate = anchorDate
        self.continuousSeconds = continuousSeconds
        self.continuityID = continuityID
        self.latestSignedAt = latestSignedAt
        self.calendarFloor = calendarFloor
    }

    public var knownDate: Date { max(anchorDate, calendarFloor ?? anchorDate) }

    public var isValid: Bool {
        anchorDate.timeIntervalSinceReferenceDate.isFinite
            && latestSignedAt.timeIntervalSinceReferenceDate.isFinite
            && latestSignedAt <= anchorDate
            && continuousSeconds.isFinite && continuousSeconds >= 0
            && !continuityID.isEmpty
            && calendarFloor.map { $0.timeIntervalSinceReferenceDate.isFinite && $0 >= anchorDate } != false
    }

    public func effectiveDate(at sample: ProEntitlementClockSample) -> Date? {
        guard isValid, sample.wallDate.timeIntervalSinceReferenceDate.isFinite else { return nil }
        // A reboot resets the continuous clock. Keep the fixed calendar deadline
        // available offline, but reject a wall date earlier than the saved time floor.
        guard sample.continuityID == continuityID else {
            return sample.wallDate >= knownDate ? sample.wallDate : nil
        }
        guard sample.continuousSeconds.isFinite, sample.continuousSeconds >= continuousSeconds else { return nil }
        let elapsedDate = anchorDate.addingTimeInterval(sample.continuousSeconds - continuousSeconds)
        guard elapsedDate.timeIntervalSinceReferenceDate.isFinite else { return nil }
        return max(knownDate, max(sample.wallDate, elapsedDate))
    }

    public func checkpoint(at sample: ProEntitlementClockSample) -> Self {
        guard let date = effectiveDate(at: sample) else { return self }
        if let marker = sample.continuityID, !marker.isEmpty,
           sample.continuousSeconds.isFinite, sample.continuousSeconds >= 0 {
            return Self(
                anchorDate: date, continuousSeconds: sample.continuousSeconds,
                continuityID: marker, latestSignedAt: latestSignedAt
            )
        }
        // A missing marker cannot establish which boot owns the counter. Retain
        // its original elapsed-time origin and save only the observed calendar floor.
        return Self(
            anchorDate: anchorDate, continuousSeconds: continuousSeconds,
            continuityID: continuityID, latestSignedAt: latestSignedAt, calendarFloor: max(knownDate, date)
        )
    }
}

public enum ProEntitlementSystemClock {
    public static func sample(at date: Date = Date()) -> ProEntitlementClockSample {
        // The same namespace is local to each device and shared by its app and extensions.
        let group = "group.com.hemsoft.CodexBarIOS"
        let sample = sample(
            at: date,
            sharedMemoryName: group + "/p",
            directory: FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
        )
        // Read the wall clock after the continuous sample: suspension between reads must not add access time.
        return ProEntitlementClockSample(
            wallDate: max(date, Date()), continuousSeconds: sample.continuousSeconds, continuityID: sample.continuityID
        )
    }

    // The injected namespace keeps tests away from the production continuity marker.
    static func sample(at date: Date, sharedMemoryName: String, directory: URL?) -> ProEntitlementClockSample {
        var timebase = mach_timebase_info_data_t()
        let seconds: TimeInterval
        if mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.numer > 0, timebase.denom > 0 {
            seconds = Double(mach_continuous_time()) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
        } else {
            seconds = .nan
        }
        let nonce = directory.flatMap { continuityID(sharedMemoryName: sharedMemoryName, directory: $0) }
        return ProEntitlementClockSample(wallDate: date, continuousSeconds: seconds, continuityID: nonce)
    }

    private static let markerLength = 40
    private static let markerPrefix = "CBP1"

    static func openSharedMemory(_ name: String, flags: Int32) -> Int32 {
        codexbar_pro_shm_open(name, flags, mode_t(S_IRUSR | S_IWUSR))
    }

    private static func continuityID(sharedMemoryName: String, directory: URL) -> String? {
        guard !sharedMemoryName.isEmpty, sharedMemoryName.utf8.count <= 31 else { return nil }
        let lockPath = directory.appendingPathComponent("pro-entitlement-clock.lock").path
        let lockDescriptor = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard lockDescriptor >= 0 else { return nil }
        defer { close(lockDescriptor) }
        // A suspended initializer must not block an extension's access check.
        guard flock(lockDescriptor, LOCK_SH | LOCK_NB) == 0 else { return nil }
        defer { flock(lockDescriptor, LOCK_UN) }
        let available = openSharedMemory(sharedMemoryName, flags: O_RDONLY)
        if available >= 0 {
            defer { close(available) }
            if let nonce = mappedNonce(descriptor: available, initializing: false) { return nonce }
        } else if errno != ENOENT { return nil }
        guard flock(lockDescriptor, LOCK_UN) == 0 else { return nil }
        guard flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else { return nil }

        let descriptor = openSharedMemory(sharedMemoryName, flags: O_CREAT | O_RDWR)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        // Another initializer may have finished before we acquired the exclusive lock.
        if let nonce = mappedNonce(descriptor: descriptor, initializing: false) { return nonce }
        // Darwin only permits one allocation. EINVAL also means an invalid marker already has storage.
        guard ftruncate(descriptor, off_t(markerLength)) == 0 || errno == EINVAL else { return nil }
        // A crashed initializer may leave an incomplete marker. A fresh nonce invalidates its old anchors.
        return mappedNonce(descriptor: descriptor, initializing: true)
    }

    static func mappedNonce(descriptor: Int32, initializing: Bool) -> String? {
        var metadata = stat()
        // A descriptor can survive an initializer that exited before allocating
        // storage. Never read or write a mapping beyond its reported capacity.
        guard fstat(descriptor, &metadata) == 0, metadata.st_size >= off_t(markerLength) else { return nil }
        let protection = initializing ? PROT_READ | PROT_WRITE : PROT_READ
        guard let memory = mmap(nil, markerLength, protection, MAP_SHARED, descriptor, 0), memory != MAP_FAILED else { return nil }
        defer { munmap(memory, markerLength) }
        if initializing {
            let marker = Array((markerPrefix + UUID().uuidString).utf8)
            marker.withUnsafeBytes { bytes in
                if let baseAddress = bytes.baseAddress { memory.copyMemory(from: baseAddress, byteCount: markerLength) }
            }
        }
        let bytes = UnsafeRawBufferPointer(start: memory, count: markerLength)
        guard let marker = String(bytes: bytes, encoding: .utf8) else { return nil }
        guard marker.hasPrefix(markerPrefix), let nonce = UUID(uuidString: String(marker.dropFirst(markerPrefix.count))) else { return nil }
        return nonce.uuidString
    }
}
