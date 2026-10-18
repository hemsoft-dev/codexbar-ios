import Foundation

@MainActor
protocol ProEntitlementCaching {
    func load(environment: ProStoreEnvironment) -> ProEntitlementValue?
    func save(_ value: ProEntitlementValue) throws
}

extension ProEntitlementCaching {
    func load() -> ProEntitlementValue? { load(environment: .production) }
}

@MainActor
struct ProEntitlementCache: ProEntitlementCaching {
    let fileURL: URL?

    static var appGroup: Self {
        let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: CodexBarWidgetConstants.appGroupIdentifier
        )
        return Self(fileURL: container?.appendingPathComponent("pro-entitlement.json"))
    }

    func load(environment: ProStoreEnvironment) -> ProEntitlementValue? {
        guard let fileURL = url(for: environment), let data = try? Data(contentsOf: fileURL),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.version == 1, record.value.environment == environment,
              record.value.isValidCacheValue else { return nil }
        return record.value
    }

    func save(_ value: ProEntitlementValue) throws {
        guard let fileURL = url(for: value.environment), value.isValidCacheValue else { throw CacheError.unavailable }
        let data = try JSONEncoder().encode(Record(version: 1, value: value))
        try data.write(to: fileURL, options: .atomic)
    }

    private func url(for environment: ProStoreEnvironment) -> URL? {
        environment == .production ? fileURL : fileURL?.appendingPathExtension(environment.rawValue)
    }

    private struct Record: Codable {
        let version: Int
        let value: ProEntitlementValue
    }

    private enum CacheError: Error { case unavailable }
}
