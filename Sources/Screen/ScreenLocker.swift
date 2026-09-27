import CoreGraphics
import Foundation

/// 锁屏。
///
/// macOS 没有公开的锁屏 API，这里用两条路径：
///   1. `login.framework` 的 `SACLockScreenImmediate`（私有，但本机 27.0 上存在）；
///   2. 退回到合成 Ctrl-Cmd-Q —— 系统自带的「锁定屏幕」快捷键。
enum ScreenLocker {
    private typealias LockFunction = @convention(c) () -> Void

    private static let immediateLock: LockFunction? = {
        let path = "/System/Library/PrivateFrameworks/login.framework/Versions/A/login"
        guard let handle = dlopen(path, RTLD_LAZY) else {
            Log.screen.error("dlopen login.framework failed")
            return nil
        }
        guard let symbol = dlsym(handle, "SACLockScreenImmediate") else {
            Log.screen.error("dlsym SACLockScreenImmediate failed")
            return nil
        }
        Log.screen.notice("SACLockScreenImmediate resolved")
        return unsafeBitCast(symbol, to: LockFunction.self)
    }()

    @discardableResult
    static func lock() -> Bool {
        if let immediateLock {
            immediateLock()
            Log.screen.notice("lock via SACLockScreenImmediate")
            return true
        }
        if lockViaKeyEvent() {
            Log.screen.notice("lock via Ctrl-Cmd-Q")
            return true
        }
        Log.screen.error("lock failed: no mechanism available")
        return false
    }

    /// 合成 Ctrl-Cmd-Q 到 HID 事件流。
    private static func lockViaKeyEvent() -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return false }
        let qKey: CGKeyCode = 12  // kVK_ANSI_Q
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: qKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: qKey, keyDown: false)
        else { return false }

        down.flags = [.maskCommand, .maskControl]
        up.flags = [.maskCommand, .maskControl]
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
