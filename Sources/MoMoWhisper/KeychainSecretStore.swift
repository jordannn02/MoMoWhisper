import Foundation
import Security

enum KeychainSecretStore {
    static func readPassword(service: String, account: String = NSUserName()) -> String? {
        var query = baseQuery(service: service, account: account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status == errSecSuccess,
              let data = item as? Data,
              let password = String(data: data, encoding: .utf8) else {
            return nil
        }

        let trimmed = password.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func readPassword(services: [String], account: String = NSUserName()) -> String? {
        for service in services {
            if let password = readPassword(service: service, account: account) {
                return password
            }
        }
        return nil
    }

    static func writePassword(_ password: String, service: String, account: String = NSUserName()) throws {
        let trimmed = password.trimmingCharacters(in: .whitespacesAndNewlines)
        var query = baseQuery(service: service, account: account)
        SecItemDelete(query as CFDictionary)

        guard !trimmed.isEmpty else {
            return
        }

        query[kSecValueData as String] = Data(trimmed.utf8)

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainSecretError.writeFailed(status)
        }
    }

    static func hasPassword(service: String, account: String = NSUserName()) -> Bool {
        readPassword(service: service, account: account) != nil
    }

    static func hasPassword(services: [String], account: String = NSUserName()) -> Bool {
        readPassword(services: services, account: account) != nil
    }

    private static func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

enum KeychainSecretError: LocalizedError {
    case writeFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .writeFailed(let status):
            return "API key 儲存到 Keychain 失敗：\(status)"
        }
    }
}
