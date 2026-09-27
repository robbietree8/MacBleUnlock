import AppKit
import ApplicationServices

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
}
