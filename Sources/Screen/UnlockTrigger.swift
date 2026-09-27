import AppKit
import CoreGraphics
import Foundation

/// 设备靠近且屏幕已锁定时，自动完成一次解锁。
///
/// macOS 没有公开的解锁 API，而 PAM 钩子这条路被 SIP 封死（`/etc/pam.d` 连 root 都写不了）。
/// 因此这里走 plan 的回退方案：把登录密码存进钥匙串，靠近时**注入密码 + 回车**。
///
/// 安全边界（这是本文件最需要小心的部分）：
///   1. 只有在「三方投票确认当前确实在锁屏界面」时才发按键 —— 见 `lockEvidence()`。
///      宁可漏判（不解锁），也绝不能误判（把密码打进前台应用）。
///   2. 每次尝试前都重新投票，不用缓存状态。
///   3. 只注入密码字符串本身和回车，不注入任何其他按键。
///   4. 用户没有设置密码时直接跳过，绝不猜测、绝不用空密码试探。
@MainActor
final class UnlockTrigger {
    static let shared = UnlockTrigger()

    private let returnKey: CGKeyCode = 36  // kVK_Return
    private let escapeKey: CGKeyCode = 53  // kVK_Escape

    private var inFlight = false

    private init() {}

    func attempt() {
        guard !inFlight else { return }
        inFlight = true
        Task { @MainActor in
            defer { inFlight = false }
            await run()
        }
    }

    private func run() async {
        let app = AppState.shared

        guard app.presence, app.autoUnlockEnabled, !app.manualLock else { return }
        guard !app.screen.systemAsleep else { return }
        guard Permissions.isAccessibilityTrusted else {
            Log.screen.notice("unlock.skip no accessibility permission")
            return
        }
        guard let password = KeychainPassword.load(), !password.isEmpty else {
            Log.screen.notice("unlock.skip no stored password")
            return
        }

        // 屏保前台时先按 Escape 退出屏保，否则按键到不了锁屏认证界面。
        if app.screen.inScreensaver {
            postKey(escapeKey)
            try? await Task.sleep(for: .milliseconds(500))
        }

        if app.wakeDisplayEnabled {
            app.display.wakeDisplay()
            try? await Task.sleep(for: .milliseconds(300))
        }

        for attemptIndex in 1...3 {
            guard app.presence, !app.manualLock else { return }

            let evidence = lockEvidence()
            guard evidence.locked else {
                Log.screen.error("unlock.abort votes=\(evidence.votes, privacy: .public) \(evidence.detail, privacy: .public)")
                return
            }

            Log.screen.notice("unlock.trigger attempt=\(attemptIndex, privacy: .public) \(evidence.detail, privacy: .public)")
            typePassword(password)
            postKey(returnKey)

            for _ in 0..<6 {  // 0.5s × 6 = 3s
                try? await Task.sleep(for: .milliseconds(500))
                if !lockEvidence().locked {
                    app.screen.reconcileLockState(reason: "unlock")
                    Log.screen.notice("unlock.success")
                    return
                }
            }
        }

        Log.screen.error("unlock.failed after 3 attempts")
    }

    /// 采集三个信号交给 `LockEvidence` 投票。判定规则与理由见 `LockEvidence`。
    private func lockEvidence() -> LockEvidence.Verdict {
        LockEvidence.evaluate(
            stateLocked: AppState.shared.screen.isLocked,
            sessionLocked: ScreenStateMonitor.currentSessionLocked(),
            frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        )
    }

    /// 只发一个密码字符串和回车，不注入任何其他按键。
    /// 用 `keyboardSetUnicodeString` 而不是逐个映射虚拟键码，避免键盘布局差异。
    private func typePassword(_ password: String) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        for unit in Array(password.utf16) {
            var value = unit
            for isDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: isDown) else { continue }
                event.keyboardSetUnicodeString(stringLength: 1, unicodeString: &value)
                event.post(tap: .cghidEventTap)
            }
        }
    }

    private func postKey(_ key: CGKeyCode) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)?.post(tap: .cghidEventTap)
    }
}
