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
    private let deleteKey: CGKeyCode = 51  // kVK_Delete（退格）

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
        // 读钥匙串可能弹授权框（旧签名身份的条目），**不能**放在主线程上等。
        let stored = await KeychainPassword.load()
        guard case .password(let password) = stored, !password.isEmpty else {
            if case .unavailable(let status) = stored {
                Log.screen.error("unlock.skip password unreadable status=\(status, privacy: .public)")
            } else {
                Log.screen.notice("unlock.skip no stored password")
            }
            return
        }

        // 屏保前台时先按 Escape 退出屏保，否则按键到不了锁屏认证界面。
        if app.screen.inScreensaver {
            postKey(escapeKey)
            try? await Task.sleep(for: .milliseconds(500))
        }

        // 5 次而不是 3 次：系统睡眠唤醒后，登录界面要好几秒才收键
        // （实测唤醒后的前两次尝试都落空，第三次才成功），重试窗口拉长到 ~16s。
        for attemptIndex in 1...5 {
            guard app.presence, !app.manualLock else { return }

            // 锁屏界面的键盘事件有个前提：显示器得醒着、界面得刚刚被「用户活动」叫醒。
            // 实测锁屏超过 ~5s（登录窗口的 idle 计时器到期）后认证窗口会被关掉
            // （`LWDefaultScreenLockUI handleTimeOutTimer: idletime hit … canceling`），
            // 这时按键全部落空；唤醒与轻推必须在**每次**尝试前做，而不是只在开头做一次。
            if !app.wakeDisplayEnabled {
                if ScreenStateMonitor.isDisplayAsleep {
                    Log.screen.notice("unlock.skip display asleep, wake disabled")
                    return
                }
            } else {
                await ensureDisplayAwake()
                nudgeLockScreen()
            }

            let evidence = lockEvidence()
            guard evidence.locked else {
                Log.screen.error("unlock.abort votes=\(evidence.votes, privacy: .public) \(evidence.detail, privacy: .public)")
                return
            }

            Log.screen.notice("unlock.trigger attempt=\(attemptIndex, privacy: .public) \(evidence.detail, privacy: .public)")
            // 先把可能残留的半截密码清掉（空框里退格是空操作），顺便让锁屏把密码框拉出来。
            clearPasswordField()
            // 4 个退格的第一下就是「把密码框叫出来」（`LWDefaultScreenLockUI keyPressed:`
            // → `showPasswordFieldMakingFirstResponder:`），等它把密码框真正拿到第一响应者。
            try? await Task.sleep(for: .milliseconds(400))
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

        Log.screen.error("unlock.failed after 5 attempts")
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
    private func typePassword(_ password: String) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        let map = KeyboardLayoutMap()
        var mapped = 0
        var fallback = 0

        for character in password {
            if let entry = map.entry(for: character) {
                mapped += 1
                postKeyCode(entry.keyCode, flags: entry.flags, source: source)
            } else {
                // 当前布局打不出这个字符：退回 unicode 注入（多数界面能用，锁屏未必）。
                fallback += 1
                postUnicode(character, source: source)
            }
        }
        // 只记数量，绝不记密码本身。
        Log.screen.notice("unlock.type chars=\(password.count, privacy: .public) mapped=\(mapped, privacy: .public) unicodeFallback=\(fallback, privacy: .public) mapSize=\(map.count, privacy: .public)")
    }

    private func postKey(_ key: CGKeyCode) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        postKeyCode(key, flags: [], source: source)
    }

    /// 真实按键事件：锁屏的安全输入框只认这个。
    private func postKeyCode(_ key: CGKeyCode, flags: CGEventFlags, source: CGEventSource) {
            for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: isDown) else { continue }
            event.flags = flags
                event.post(tap: .cghidEventTap)
        }
    }

    private func postUnicode(_ character: Character, source: CGEventSource) {
        for unit in String(character).utf16 {
            var value = unit
            for isDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: isDown) else { continue }
                event.keyboardSetUnicodeString(stringLength: 1, unicodeString: &value)
                event.post(tap: .cghidEventTap)
            }
        }
    }

    /// 退格几下：清掉上一次尝试可能留在框里的字符，空框里是空操作。
    private func clearPasswordField() {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        for _ in 0..<3 {
            postKeyCode(deleteKey, flags: [], source: source)
        }
    }

    /// 确保显示器醒着，并在唤醒后给登录界面 1s 稳定时间。
    ///
    /// 判据用 `CGDisplayIsAsleep()`（电源层的事实），不用 `AppState.screen.displayAsleep`
    /// —— 后者是通知流，App 在显示器睡着时启动的话它一直是 false。
    /// 唤醒后系统会**清空密码框**（`loginwindow: Clearing password field for
    /// NSWorkspaceScreensDidWakeNotification`），紧接着打字会被丢掉。
    private func ensureDisplayAwake() async {
        let started = Date()
        // 刚从系统睡眠里醒来的话，多给登录界面 1.5s：实测这一段里注入的按键会被吞掉。
        if let wakeAt = AppState.shared.screen.lastSystemWakeAt,
           Date().timeIntervalSince1970 - wakeAt < 20 {
            try? await Task.sleep(for: .milliseconds(1500))
        }
        for _ in 1...3 {
            if ScreenStateMonitor.isDisplayAsleep {
                AppState.shared.display.wakeDisplay()
                var waited = 0
                while ScreenStateMonitor.isDisplayAsleep, waited < 2000 {
                    try? await Task.sleep(for: .milliseconds(100))
                    waited += 100
                }
            }
            try? await Task.sleep(for: .milliseconds(1000))
            if !ScreenStateMonitor.isDisplayAsleep {
                Log.screen.notice("unlock.wake settledMs=\(Int(Date().timeIntervalSince(started) * 1000), privacy: .public)")
                return
            }
        }
        Log.screen.error("unlock.wake display still asleep")
    }

    /// 鼠标微移两像素：这是 HID 层的「用户活动」，锁屏靠它把密码框重新拉出来。
    /// 锁屏上不显示光标，也不会有副作用；绝不用点击（误点可能点到别的控件）。
    private func nudgeLockScreen() {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        let current = CGEvent(source: nil)?.location ?? CGPoint(x: 400, y: 400)
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                mouseCursorPosition: CGPoint(x: current.x + 2, y: current.y + 2),
                mouseButton: .left)?.post(tap: .cghidEventTap)
    }
}
