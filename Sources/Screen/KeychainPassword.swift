import Foundation
import Security

/// 登录密码的 Keychain 存取。
///
/// 只有在用户主动在菜单里设置之后才存在。用 `kSecAttrAccessibleAfterFirstUnlock`：
/// 开机首次解锁后即可读 —— **屏幕锁定不等于钥匙串上锁**，自动解锁正是在锁屏状态下读取。
///
/// **所有调用都必须是 async 的**，因为钥匙串调用可能弹出系统授权框并**阻塞调用线程**：
/// 换过签名证书（比如自签名换成 Developer ID）之后，旧条目属于旧身份，
/// 读它就会弹框等人点。以前这些调用都在主线程上，结果是「App 启动即卡死」——
/// 实测主线程栈停在 `KeychainPassword.load → SecItemCopyMatching`，BLE 和菜单都不会起来。
///
/// 不用「数据保护钥匙串」（`kSecUseDataProtectionKeychain`）：Developer ID 签名、
/// 无 provisioning profile 的 App 会拿到 `errSecMissingEntitlement (-34018)`（实测）。
///
/// 好消息是旧式钥匙串的访问控制绑的是**指定要求**（team + bundle id），不是 cdhash：
/// 同证书重新构建不会弹框（实测：两个 cdhash 不同的二进制互相读得到对方的条目）。
/// 所以换证书后只要重设一次密码，之后重建都不会再弹。
enum KeychainPassword {
    static let service = "com.robbietree.MacBleUnlock"
    static let account = "loginPassword"

    /// 读取结果。必须区分「没有条目」与「有条目但读不出来」——后者是旧签名身份留下的，
    /// 光看 nil 会把它当成「用户没设过密码」，排查时完全看不出真相。
    enum LoadResult: Equatable, Sendable {
        case password(String)
        case missing
        /// 条目存在但取不出来（旧签名身份 / 用户在授权框上点了拒绝 / 钥匙串锁定）。
        case unavailable(OSStatus)
    }

    /// 钥匙串调用可能等人点授权框，所以放在自己的串行队列上，绝不占用主线程。
    private static let queue = DispatchQueue(
        label: "com.robbietree.MacBleUnlock.keychain",
        qos: .userInitiated
    )

    // MARK: - 异步接口（唯一对外入口）

    static func load() async -> LoadResult {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: loadNow()) }
        }
    }

    static func save(_ password: String) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try saveNow(password)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    @discardableResult
    static func delete() async -> OSStatus {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: deleteNow()) }
        }
    }

    // MARK: - 同步实现（只在 queue 上使用）

    private static func query(_ extra: [String: Any] = [:]) -> CFDictionary {
        var dict: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        dict.merge(extra) { _, new in new }
        return dict as CFDictionary
    }

    private static func loadNow() -> LoadResult {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query([
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]), &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let text = String(data: data, encoding: .utf8) else {
                return .missing
            }
            return .password(text)
        case errSecItemNotFound:
            return .missing
        default:
            return .unavailable(status)
        }
    }

    private static func saveNow(_ password: String) throws {
        // 先删再写：旧条目可能属于别的签名身份，删不掉就让这次保存失败，
        // 免得留下两条同名条目、之后读哪条都说不清。
        let deleteStatus = deleteNow()
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            throw Failure(status: deleteStatus)
        }

        let status = SecItemAdd(query([
            kSecValueData as String: Data(password.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]), nil)
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    private static func deleteNow() -> OSStatus {
        SecItemDelete(query())
    }

    struct Failure: Error, CustomStringConvertible {
        let status: OSStatus
        var description: String {
            (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
        }
    }
}
