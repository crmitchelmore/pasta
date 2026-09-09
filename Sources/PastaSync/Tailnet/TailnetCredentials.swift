#if os(macOS)
import Foundation
import Security

protocol TailnetCredentials: Sendable {
    func read(_ id: UUID) throws -> String?
    func save(_ token: String, id: UUID) throws
    func remove(_ id: UUID) throws
}
struct TailnetKeychain: TailnetCredentials {
    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.pasta.tailnet.pairing",
         kSecAttrAccount as String: id.uuidString]
    }
    func read(_ id: UUID) throws -> String? {
        var q = query(id); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else { throw TailnetError.unavailable("Unlock the login keychain to resume paired sync.") }
        return value
    }
    func save(_ token: String, id: UUID) throws {
        var q = query(id)
        q[kSecValueData as String] = Data(token.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        if status == errSecDuplicateItem {
            guard SecItemUpdate(query(id) as CFDictionary, [kSecValueData as String: Data(token.utf8)] as CFDictionary) == errSecSuccess else { throw TailnetError.unavailable("Could not save pairing in Keychain.") }
        } else if status != errSecSuccess { throw TailnetError.unavailable("Could not save pairing in Keychain.") }
    }
    func remove(_ id: UUID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw TailnetError.unavailable("Could not remove pairing from Keychain.") }
    }
    static func token() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw TailnetError.unavailable("Could not generate a pairing secret.") }
        return Data(bytes).base64EncodedString()
    }
    static func matches(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b, a.utf8.count == 44, b.utf8.count == 44 else { return false }
        return zip(a.utf8, b.utf8).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
#endif
