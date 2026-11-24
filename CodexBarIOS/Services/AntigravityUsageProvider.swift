import Foundation

/// Experimental Antigravity usage, read from Google's own Models & Usage page (ANTIGRAVITY-USAGE.md).
/// This provider sends no request of its own: Google's page loads in the account's private browser profile and
/// CodexBar reads the quota response that page fetched.
public final class AntigravityUsageProvider: UsageProvider {
    public let providerID = ProviderID.antigravityWeb

    private let secretStore: SecretStore
    private let reader: AntigravityPageReading
    private let cache: AntigravityReadCache
    private let now: @Sendable () -> Date

    public init(
        secretStore: SecretStore = KeychainService(),
        reader: AntigravityPageReading = WebKitAntigravityPageReader(),
        cache: AntigravityReadCache = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.secretStore = secretStore
        self.reader = reader
        self.cache = cache
        self.now = now
    }

    public func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        let stored = try secretStore.readSecret(account: ProviderConfigurationStore.keychainAccount(for: configuration))
        guard let marker = AntigravityWebSessionMarker.parse(stored) else {
            return Self.failure(.notConfigured, configuration: configuration, storeID: nil, at: now())
        }
        let reading = await cache.reading(for: marker, now: now(), reader: reader)
        switch reading.outcome {
        case let .failure(error):
            return Self.failure(error, configuration: configuration, storeID: marker.websiteDataStoreID, at: now())
        case let .success(capture):
            do {
                var result = try AntigravityQuotaParser.result(from: capture, configuration: configuration, fetchedAt: reading.readAt)
                result.cacheIdentity = Self.cacheIdentity(marker.websiteDataStoreID)
                if result.failureMessage != nil {
                    return Self.failure(.noUsageReported, configuration: configuration, storeID: marker.websiteDataStoreID, at: now())
                }
                return result
            } catch {
                return Self.failure(.unreadableResponse, configuration: configuration, storeID: marker.websiteDataStoreID, at: now())
            }
        }
    }

    static func cacheIdentity(_ storeID: UUID) -> String {
        "antigravity-web:\(storeID.uuidString.lowercased())"
    }

    /// A page that didn't load, or loaded without reporting usage, keeps the last reading, marked stale. A page that
    /// asked for sign-in shows no values: its identity never matches a cached reading.
    static func failure(
        _ error: AntigravityReadError, configuration: ProviderAccountConfiguration, storeID: UUID?, at date: Date
    ) -> ProviderUsageResult {
        let keepsLastReading = error.keepsLastReading
        let message = error.localizedDescription
        let recovery: ProviderUsageRecoveryAction = switch error {
        case .notConfigured: .signIn
        case .signInRequired: .reauthenticate
        case .noUsageReported, .pageFailed, .unreadableResponse, .appNotActive: .retryRefresh
        }
        return ProviderUsageResult(
            accountID: configuration.id,
            providerID: .antigravityWeb,
            title: configuration.displayName,
            subtitle: message,
            bars: [],
            failureMessage: message,
            recoveryAction: recovery,
            preserveCachedBarsOnFailure: keepsLastReading,
            cacheIdentity: keepsLastReading ? storeID.map(cacheIdentity) : "antigravity-web:no-reading",
            fetchedAt: date
        )
    }
}

/// Limits each account to one page load every five minutes and lets sign-in hand over the reading it already has.
public actor AntigravityReadCache {
    public static let shared = AntigravityReadCache()
    public static let minimumReadInterval: TimeInterval = 5 * 60
    static let failedLoadRetryInterval: TimeInterval = 60

    public struct Reading: Sendable {
        public let readAt: Date
        public let outcome: Result<AntigravityPageCapture, AntigravityReadError>
    }

    /// Off screen there is nothing new to say, so widgets and the watch keep the last reading with its own time.
    /// Only an account with no reading at all reports that it refreshes while the app is open.
    private static func offScreenResult(_ reading: Reading, earlier: Reading?) -> Reading {
        guard reading.outcome == .failure(.appNotActive), let earlier, (try? earlier.outcome.get()) != nil else { return reading }
        return earlier
    }

    private var readings: [UUID: Reading] = [:]
    private var inFlight: [UUID: Task<Reading, Never>] = [:]

    public init() {}

    /// Sign-in already watched Google's page report usage; the first refresh uses that instead of loading it again.
    public func prime(storeID: UUID, capture: AntigravityPageCapture, at date: Date) {
        readings[storeID] = Reading(readAt: date, outcome: .success(capture))
    }

    public func forget(storeID: UUID) {
        readings[storeID] = nil
        inFlight[storeID] = nil
    }

    func reading(for marker: AntigravityWebSessionMarker, now: Date, reader: AntigravityPageReading) async -> Reading {
        let storeID = marker.websiteDataStoreID
        if let cached = readings[storeID] {
            let interval = cached.outcome == .failure(.pageFailed) ? Self.failedLoadRetryInterval : Self.minimumReadInterval
            let age = now.timeIntervalSince(cached.readAt)
            if age >= 0 && age < interval { return cached }
        }
        if let running = inFlight[storeID] { return await running.value }
        let task = Task { () -> Reading in
            do {
                return Reading(readAt: now, outcome: .success(try await reader.read(marker: marker)))
            } catch let error as AntigravityReadError {
                return Reading(readAt: now, outcome: .failure(error))
            } catch {
                return Reading(readAt: now, outcome: .failure(.pageFailed))
            }
        }
        inFlight[storeID] = task
        let reading = await task.value
        if inFlight[storeID] == task {
            inFlight[storeID] = nil
            // A read that didn't run because the app wasn't on screen loaded nothing, so it doesn't count
            // against the five-minute limit and never replaces an earlier reading.
            if reading.outcome != .failure(.appNotActive) { readings[storeID] = reading }
        }
        return Self.offScreenResult(reading, earlier: readings[storeID])
    }
}
