import Foundation
@testable import CodexBarWatch

extension WatchComplicationSnapshotStore {
    init(testDefaults: UserDefaults) {
        self.init(
            defaults: testDefaults,
            accessClock: WatchAccessClockStore(directory: WatchAccessTestStorage.directory(for: testDefaults)),
            clockSample: { date in
                ProEntitlementClockSample(wallDate: date, continuousSeconds: 0, continuityID: "watch-test-boot")
            }
        )
    }
}

// Fixture namespace lookup is synchronized; production never stores temporary paths in preferences.
private enum WatchAccessTestStorage {
    static let lock = NSLock()

    static func directory(for defaults: UserDefaults) -> URL {
        lock.lock()
        defer { lock.unlock() }
        let key = "fixture.watch-access-directory"
        if let path = defaults.string(forKey: key) { return URL(fileURLWithPath: path) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("watch-access-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaults.set(directory.path, forKey: key)
        return directory
    }
}
