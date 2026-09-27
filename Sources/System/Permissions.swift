import AppKit
import ApplicationServices
import Security

/// 系统权限状态与跳转。
enum Permissions {
    /// 合成键盘事件（解锁用的回车）需要辅助功能权限。
    static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    /// 首次调用会弹出系统授权对话框。
    @discardableResult
    static func promptAccessibility() -> Bool {
        // 不用 kAXTrustedCheckOptionPrompt：它是 SDK 里的全局 var，在 Swift 6 下不是并发安全的。
        // 这里直接用它的字面值（该常量自 10.9 起从未变过）。
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    /// 当前二进制的签名指纹。
    ///
    /// TCC 授权（蓝牙、辅助功能）是与**代码签名身份**绑定的：换证书（比如从自签名换成
    /// Developer ID）之后，系统设置里那行开关还在、还是开着的，但它记的是旧身份，
    /// 新二进制判定为「未授予」。日志里带上 cdhash 与 team，这种情况一眼就能认出来。
    static var selfIdentity: (cdhash: String, team: String) {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return ("-", "-") }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return ("-", "-") }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any]
        else { return ("-", "-") }

        let unique = dictionary[kSecCodeInfoUnique as String] as? Data
        let cdhash = unique.map { $0.map { String(format: "%02x", $0) }.joined() } ?? "-"
        let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String ?? "-"
        return (cdhash, team)
    }

    /// 把「权限判定」和「是谁在被判定」一起写进日志。
    static func logAccessibilityState(_ context: String) {
        let (cdhash, team) = selfIdentity
        Log.screen.notice("auth.accessibility trusted=\(isAccessibilityTrusted, privacy: .public) cdhash=\(cdhash, privacy: .public) team=\(team, privacy: .public) context=\(context, privacy: .public) path=\(Bundle.main.bundlePath, privacy: .public)")
    }
}
