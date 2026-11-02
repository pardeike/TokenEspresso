import Foundation
import TokenEspresso
import Security

public struct KeychainCodexCredentialStore: CodexCredentialStore, @unchecked Sendable {
    private let service: String
    private let account: String

    public init(
        service: String,
        account: String = "default"
    ) {
        self.service = service
        self.account = account
    }

    public func load() async throws -> CodexCredentials? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainCodexCredentialStoreError.keychain(status)
        }
        guard let data = result as? Data else {
            throw KeychainCodexCredentialStoreError.invalidData
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CodexCredentials.self, from: data)
    }

    public func save(_ tokens: CodexCredentials) async throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(tokens)
        var query = baseQuery()

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus != errSecItemNotFound {
            throw KeychainCodexCredentialStoreError.keychain(updateStatus)
        }

        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainCodexCredentialStoreError.keychain(addStatus)
        }
    }

    public func delete() async throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainCodexCredentialStoreError.keychain(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

public enum KeychainCodexCredentialStoreError: Error, LocalizedError {
    case keychain(OSStatus)
    case invalidData

    public var errorDescription: String? {
        switch self {
        case let .keychain(status):
            if let message = SecCopyErrorMessageString(status, nil) as String? {
                "Keychain error \(status): \(message)"
            } else {
                "Keychain error \(status)"
            }
        case .invalidData:
            "Codex token data in Keychain is invalid."
        }
    }
}
