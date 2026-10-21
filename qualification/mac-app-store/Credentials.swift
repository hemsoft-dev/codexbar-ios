import Foundation
import LocalAuthentication
import Security

/// Dedicated namespace. Never reads the iOS app's credentials or accepts real tokens.
struct FixtureCredentials {
    let service: String

    init(service: String? = nil) {
        let namespace = Bundle.main.url(forResource: "FixtureNamespace", withExtension: "txt")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            .flatMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            ?? UUID()
        self.service = service ?? "com.hemsoft.qualification.mac476.fixtures.\(namespace.uuidString)"
    }

    private func query(_ account: String) -> [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseAuthenticationContext as String: context,
        ]
    }

    func save(_ account: String, token: Data) throws {
        var attributes = query(account)
        attributes[kSecValueData as String] = token
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let result = SecItemAdd(attributes as CFDictionary, nil)
        if result == errSecDuplicateItem {
            let update = [kSecValueData as String: token]
            try check(SecItemUpdate(query(account) as CFDictionary, update as CFDictionary))
        } else {
            try check(result)
        }
    }

    func read(_ account: String) throws -> Data? {
        var attributes = query(account)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        return result as? Data
    }

    func remove(_ account: String) throws {
        let result = SecItemDelete(query(account) as CFDictionary)
        if result != errSecItemNotFound { try check(result) }
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}
