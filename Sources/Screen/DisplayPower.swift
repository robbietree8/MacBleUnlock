import Foundation
import IOKit.pwr_mgt

/// 屏幕电源与「保持唤醒」断言。
///
/// 断言名固定为 `MacBleUnlock`，因此 `pmset -g assertions` 里可以直接 grep 到。
@MainActor
final class DisplayPower {
    private var keepAwakeAssertion: IOPMAssertionID = 0
    private var userActivityAssertion: IOPMAssertionID = 0

    /// 设备在附近时持有 `PreventUserIdleDisplaySleep`。重复调用幂等。
    func holdKeepAwake() {
        guard keepAwakeAssertion == 0 else { return }
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "MacBleUnlock" as CFString,
            &id
        )
        guard result == kIOReturnSuccess else {
            Log.screen.error("keepAwake create failed: \(result, privacy: .public)")
            return
        }
        keepAwakeAssertion = id
        Log.screen.notice("keepAwake.on id=\(id, privacy: .public)")
    }

    func releaseKeepAwake() {
        guard keepAwakeAssertion != 0 else { return }
        let id = keepAwakeAssertion
        keepAwakeAssertion = 0
        IOPMAssertionRelease(id)
        Log.screen.notice("keepAwake.off id=\(id, privacy: .public)")
    }

    /// 点亮屏幕（但不解锁）。锁屏状态下由 loginwindow 决定是否显示密码框。
    func wakeDisplay() {
        // **复用**同一个断言 id：`IOPMAssertionDeclareUserActivity` 每次传 0 都会新建一条
        // UserIsActive 断言，而它有几分钟的超时 —— 旧代码每次解锁尝试都新建一条，
        // `pmset -g assertions` 里会堆出一串同名断言（实测 2 条同时存活）。
        let result = IOPMAssertionDeclareUserActivity(
            "MacBleUnlock" as CFString,
            kIOPMUserActiveLocal,
            &userActivityAssertion
        )
        if result == kIOReturnSuccess {
            Log.screen.notice("wakeDisplay ok")
        } else {
            Log.screen.error("wakeDisplay failed: \(result, privacy: .public)")
        }
    }

    var isHoldingKeepAwake: Bool { keepAwakeAssertion != 0 }
}
