import Foundation
import Security

public protocol SecretStore: Sendable {
    func read(account: String) throws -> String?
    func write(_ secret: String, account: String) throws
    func delete(account: String) throws
}

public struct KeychainError: Error, Equatable {
    public let status: OSStatus
}

public struct KeychainStore: SecretStore {
    private let service: String

    public init(service: String = "nl.torrisi.pullwatch") {
        self.service = service
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func read(account: String) throws -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw KeychainError(status: status) }
        return String(decoding: data, as: UTF8.self)
    }

    public func write(_ secret: String, account: String) throws {
        let data = Data(secret.utf8)
        let status = SecItemUpdate(
            baseQuery(account) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if status == errSecItemNotFound {
            var query = baseQuery(account)
            query[kSecValueData as String] = data
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
            return
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

public struct KeychainPATSource: TokenSource {
    private let store: any SecretStore
    private let accountId: UUID

    public init(store: any SecretStore, accountId: UUID) {
        self.store = store
        self.accountId = accountId
    }

    public func token() async throws -> String {
        guard let token = try store.read(account: accountId.uuidString), !token.isEmpty else {
            throw ProviderError.missingToken
        }
        return token
    }
}
