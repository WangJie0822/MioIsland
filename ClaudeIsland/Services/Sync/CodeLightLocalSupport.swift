//
//  CodeLightLocalSupport.swift
//  ClaudeIsland
//
//  Local fallback implementations for the small subset of CodeLight protocol
//  and crypto helpers used by ClaudeIsland.
//

import CryptoKit
import Foundation
import Security

struct AuthRequest: Codable {
    let publicKey: String
    let challenge: String
    let signature: String
}

struct AuthResponse: Codable {
    let token: String?
    let deviceId: String?
}

final class KeyManager {
    private enum KeychainError: Error {
        case unexpectedData
        case unhandledStatus(OSStatus)
    }

    private let serviceName: String
    private let identityAccount = "identity-key"

    init(serviceName: String) {
        self.serviceName = serviceName
    }

    @discardableResult
    func getOrCreateIdentityKey() throws -> P256.Signing.PrivateKey {
        if let existing = try loadIdentityKey() {
            return existing
        }

        let key = P256.Signing.PrivateKey()
        try save(data: key.rawRepresentation, account: identityAccount)
        return key
    }

    func sign(_ data: Data) throws -> Data {
        let key = try getOrCreateIdentityKey()
        return try key.signature(for: data).derRepresentation
    }

    func publicKeyBase64() throws -> String {
        let key = try getOrCreateIdentityKey()
        return key.publicKey.rawRepresentation.base64EncodedString()
    }

    func loadToken(forServer server: String) -> String? {
        guard let data = try? load(account: tokenAccount(for: server)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func storeToken(_ token: String, forServer server: String) throws {
        guard let data = token.data(using: .utf8) else {
            throw KeychainError.unexpectedData
        }
        try save(data: data, account: tokenAccount(for: server))
    }

    private func loadIdentityKey() throws -> P256.Signing.PrivateKey? {
        guard let data = try load(account: identityAccount) else { return nil }
        return try P256.Signing.PrivateKey(rawRepresentation: data)
    }

    private func tokenAccount(for server: String) -> String {
        "token:\(server)"
    }

    private func load(account: String) throws -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: serviceName,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                throw KeychainError.unexpectedData
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unhandledStatus(status)
        }
    }

    private func save(data: Data, account: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: serviceName,
            kSecAttrAccount: account,
        ]

        let attributes: [CFString: Any] = [
            kSecValueData: data,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus != errSecItemNotFound {
            throw KeychainError.unhandledStatus(updateStatus)
        }

        var insertQuery = query
        insertQuery[kSecValueData] = data
        let addStatus = SecItemAdd(insertQuery as CFDictionary, nil)
        if addStatus != errSecSuccess {
            throw KeychainError.unhandledStatus(addStatus)
        }
    }
}
