import XCTest
@testable import MacBleUnlock

/// 回归测试：BLEScanner 必须参与 SwiftUI 的观察系统。
///
/// 症状是菜单永远停在「蓝牙不可用」。根因是 `BLEScanner` 当时是个普通 class，
/// 嵌在 `@Observable` 的 `AppState` 里 —— SwiftUI 只跟踪 `@Observable` 类型的属性，
/// 于是 `AppState.statusText` 开头的 `guard scanner.bluetoothAvailable else { return ... }`
/// 在首次渲染（蓝牙状态尚未就绪）时直接提前返回，**没有读取任何被观察的属性**，
/// 视图再也不会失效，菜单就冻结在那一刻的取值上。
///
/// 这个测试直接钉住「状态变化能被观察到」这一条，而不依赖菜单渲染。
final class BLEScannerObservabilityTests: XCTestCase {

    /// `onChange` 是 @Sendable 闭包，不能直接捕获可变局部变量。
    /// 这个回调实际是同步调用的（`@Observable` 在 withMutation 里同步通知），
    /// 所以用一个普通盒子就够。
    private final class Flag: @unchecked Sendable {
        var value = false
    }

    @MainActor
    func testStateChangesAreObservable() {
        let scanner = BLEScanner()

        let flag = Flag()
        withObservationTracking {
            _ = scanner.bluetoothAvailable
            _ = scanner.bluetoothStateText
        } onChange: {
            flag.value = true
        }

        XCTAssertEqual(scanner.bluetoothStateText, "未知", "新建扫描器的初始状态")
        scanner.stop()  // 把 bluetoothStateText 改为「已停止」

        XCTAssertEqual(scanner.bluetoothStateText, "已停止")
        XCTAssertTrue(flag.value, "扫描器状态变化必须触发 SwiftUI 观察，否则菜单会冻结在旧值")
    }

    @MainActor
    func testDeviceListChangesAreObservable() {
        let scanner = BLEScanner()

        let flag = Flag()
        withObservationTracking {
            _ = scanner.sortedDevices
        } onChange: {
            flag.value = true
        }

        scanner.start()
        scanner.stop()  // devices.removeAll()

        XCTAssertTrue(flag.value, "设备列表变化必须触发 SwiftUI 观察")
    }
}
