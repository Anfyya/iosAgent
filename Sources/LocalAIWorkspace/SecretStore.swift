import Foundation

#if canImport(Security)
import Security
#endif

public protocol SecretStore: Sendable {
    func save(service: String, account: String, value: String) throws
    func read(service: String, account: String) throws -> String?
    func delete(service: String, account: String) throws
    func exists(service: String, account: String) throws -> Bool
}

public enum SecretStoreError: Error, LocalizedError {
    case unsupportedPlatform
    case invalidData
    case unexpectedStatus(Int32)

    public var errorDescription: String? {
        switch self {
        case .unsupportedPlatform:
            return "Keychain is unavailable on this platform."
        case .invalidData:
            return "The stored secret data is invalid."
        case let .unexpectedStatus(status):
            return "Secret store failed with status \(status)."
        }
    }
}

public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    public init() {}

    public func save(service: String, account: String, value: String) throws {
        lock.lock()
        defer { lock.unlock() }
        values[key(service: service, account: account)] = value
    }

    public func read(service: String, account: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[key(service: service, account: account)]
    }

    public func delete(service: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        values.removeValue(forKey: key(service: service, account: account))
    }

    public func exists(service: String, account: String) throws -> Bool {
        try read(service: service, account: account) != nil
    }

    private func key(service: String, account: String) -> String {
        "\(service)|\(account)"
    }
}

#if canImport(Security)
public struct KeychainSecretStore: SecretStore {
    public init() {}

    public func save(service: String, account: String, value: String) throws {
        let encoded = Data(value.utf8)
        let query = baseQuery(service: service, account: account)
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = encoded
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SecretStoreError.unexpectedStatus(status)
        }
    }

    public func read(service: String, account: String) throws -> String? {
        var query = baseQuery(service: service, account: account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw SecretStoreError.unexpectedStatus(status)
        }
        guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            throw SecretStoreError.invalidData
        }
        return value
    }

    public func delete(service: String, account: String) throws {
        let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretStoreError.unexpectedStatus(status)
        }
    }

    public func exists(service: String, account: String) throws -> Bool {
        try read(service: service, account: account) != nil
    }

    private func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
#else
public struct KeychainSecretStore: SecretStore {
    public init() {}

    public func save(service: String, account: String, value: String) throws {
        throw SecretStoreError.unsupportedPlatform
    }

    public func read(service: String, account: String) throws -> String? {
        throw SecretStoreError.unsupportedPlatform
    }

    public func delete(service: String, account: String) throws {
        throw SecretStoreError.unsupportedPlatform
    }

    public func exists(service: String, account: String) throws -> Bool {
        throw SecretStoreError.unsupportedPlatform
    }
}
#endif
