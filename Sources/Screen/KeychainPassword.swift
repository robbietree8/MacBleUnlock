import Foundation
import Security

/// 登录密码的 Keychain 存取。
///
/// 只有在用户主动在菜单里设置之后才存在。用 `kSecAttrAccessibleAfterFirstUnlock`：
/// 开机首次解锁后即可读 —— **屏幕锁定不等于钥匙串上锁**，自动解锁正是在锁屏状态下读取。
enum KeychainPassword {
    static let service = "com.robbietree.MacBleUnlock"
    static let account = "loginPassword"

    struct Failure: Error, CustomStringConvertible {
        let status: OSStatus
        var description: String {
            (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
        }
    }

    static func save(_ password: String) throws {
        delete()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(password.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        return text
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    static var isSet: Bool {
        guard let value = load() else { return false }
        return !value.isEmpty
    }
}
