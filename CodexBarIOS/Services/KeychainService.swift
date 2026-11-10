import Foundation
import Security

public protocol SecretStore: Sendable {
    func accountNames() throws -> [String]
    func readSecret(account: String) throws -> String?
    func saveSecret(_ secret: String, account: String) throws
    func deleteSecret(account: String) throws
}

public extension SecretStore {
    func accountNames() throws -> [String] { [] }
}

actor CredentialRefreshCoordinator<Result: Sendable> {
    private var inFlightTasks: [String: Task<Result, Never>] = [:]

    func run(
        for account: String,
        onJoinExistingTask: (@Sendable () -> Void)? = nil,
        operation: @escaping @Sendable () async -> Result
    ) async -> Result {
        if let task = inFlightTasks[account] {
            onJoinExistingTask?()
            return await task.value
        }

        let task = Task { await operation() }
        inFlightTasks[account] = task
        let result = await task.value
        inFlightTasks[account] = nil
        return result
    }
}

public struct KeychainService: SecretStore {
    private let service: String

    public init(service: String = "com.hemsoft.CodexBarIOS") {
        self.service = service
    }

    public func accountNames() throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw KeychainError.unhandledStatus(status) }
        return (result as? [[String: Any]] ?? []).compactMap { $0[kSecAttrAccount as String] as? String }
    }

    public func readSecret(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            throw KeychainError.unhandledStatus(status)
        }

        guard let data = result as? Data else {
            throw KeychainError.invalidSecretData
        }

        return try Self.decodeSecret(data)
    }

    public func saveSecret(_ secret: String, account: String) throws {
        let encodedSecret = Data(secret.utf8)
        var query = baseQuery(account: account)

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            let attributes = [kSecValueData as String: encodedSecret]
            let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainError.unhandledStatus(updateStatus)
            }
            return
        }

        guard status == errSecItemNotFound else {
            throw KeychainError.unhandledStatus(status)
        }

        query[kSecValueData as String] = encodedSecret
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.unhandledStatus(addStatus)
        }
    }

    public func deleteSecret(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandledStatus(status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func decodeSecret(_ data: Data) throws -> String {
        guard let secret = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidSecretData
        }

        return secret
    }
}

public enum KeychainError: Error, Equatable, LocalizedError {
    case unhandledStatus(OSStatus)
    case invalidSecretData

    public var errorDescription: String? {
        switch self {
        case let .unhandledStatus(status):
            "Keychain operation failed with status \(status)."
        case .invalidSecretData:
            "The saved credential contains invalid data."
        }
    }
}

extension RetiredGoogleProviderMigration {
    /// Runs before configuration decoding. Pending account names survive both partial cleanup and relaunch.
    static func run(defaults: UserDefaults, secretStore: SecretStore, configurationKey: String) -> String? {
        var pending = Set(defaults.stringArray(forKey: "retiredGoogleCredentialCleanup") ?? [])
        if let data = defaults.data(forKey: configurationKey),
           let records = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for record in records {
                guard let provider = record["providerID"] as? String, ["gemini", "antigravity"].contains(provider) else { continue }
                let id = record["id"] as? String ?? provider
                pending.insert(id == provider ? "provider.\(provider).credential" : "providerAccount.\(id).credential")
                pending.insert("provider.gemini.\(id).coding")
            }
        }
        for key in ["confirmedGoogleAccountLinks", "pendingGoogleAccountLinks"] {
            let links = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
            for id in Set(links.keys).union(links.values) {
                pending.insert("providerAccount.\(id).credential")
                pending.insert("provider.gemini.\(id).coding")
            }
        }
        let records = defaults.data(forKey: configurationKey)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
        let protectedAccounts = Set(records.compactMap { record -> String? in
            guard let provider = record["providerID"] as? String,
                  !["gemini", "antigravity"].contains(provider) else { return nil }
            let id = record["id"] as? String ?? provider
            return id == provider ? "provider.\(provider).credential" : "providerAccount.\(id).credential"
        })
        var cleanupFailed = false
        do {
            pending.formUnion(try secretStore.accountNames().filter { account in
                account.hasPrefix("provider.gemini.") || account.hasPrefix("provider.antigravity.")
                    || (account.hasPrefix("providerAccount.") && isRetiredIdentifier(account))
            })
        } catch { cleanupFailed = true }
        pending.subtract(protectedAccounts)
        defaults.set(pending.sorted(), forKey: "retiredGoogleCredentialCleanup")
        for account in pending {
            do {
                try secretStore.deleteSecret(account: account)
                pending.remove(account)
            } catch { cleanupFailed = true }
        }
        defaults.set(pending.sorted(), forKey: "retiredGoogleCredentialCleanup")
        for key in [configurationKey, "usageHistorySnapshots", "usageHistoryDailySnapshots"] {
            guard let data = defaults.data(forKey: key) else { continue }
            do {
                let migrated = try removingRetiredRecords(from: data)
                if migrated != data { defaults.set(migrated, forKey: key) }
            } catch { continue } // Existing recovery handles corrupt data without overwriting it.
        }
        defaults.removeObject(forKey: "confirmedGoogleAccountLinks")
        defaults.removeObject(forKey: "pendingGoogleAccountLinks")
        return cleanupFailed ? "Saved Google credentials could not all be removed. Cleanup will retry when CodexBar opens again." : nil
    }
}
