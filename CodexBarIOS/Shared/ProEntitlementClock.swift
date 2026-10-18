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

    public init(anchorDate: Date, continuousSeconds: TimeInterval, continuityID: String, latestSignedAt: Date) {
        self.anchorDate = anchorDate
        self.continuousSeconds = continuousSeconds
        self.continuityID = continuityID
        self.latestSignedAt = latestSignedAt
    }

    public var isValid: Bool {
        anchorDate.timeIntervalSinceReferenceDate.isFinite
            && latestSignedAt.timeIntervalSinceReferenceDate.isFinite
            && latestSignedAt <= anchorDate
            && continuousSeconds.isFinite && continuousSeconds >= 0
            && !continuityID.isEmpty
    }

    public func effectiveDate(at sample: ProEntitlementClockSample) -> Date? {
        guard isValid, sample.wallDate.timeIntervalSinceReferenceDate.isFinite,
              sample.continuousSeconds.isFinite, sample.continuousSeconds >= continuousSeconds,
              sample.continuityID == continuityID else { return nil }
        let elapsedDate = anchorDate.addingTimeInterval(sample.continuousSeconds - continuousSeconds)
        guard elapsedDate.timeIntervalSinceReferenceDate.isFinite else { return nil }
        return max(sample.wallDate, elapsedDate)
    }
}

public enum ProEntitlementSystemClock {
    public static func sample(at date: Date = Date()) -> ProEntitlementClockSample {
        let group = CodexBarWidgetConstants.appGroupIdentifier
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

    private static func mappedNonce(descriptor: Int32, initializing: Bool) -> String? {
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
