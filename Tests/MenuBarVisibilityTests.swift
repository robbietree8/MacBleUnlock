import XCTest
@testable import MacBleUnlock

/// `AppState` 的菜单栏图标偏好：默认值、持久化、以及用独立 `UserDefaults` 重建实例后的恢复。
///
/// 只测纯状态，不调用 `start()`、不启动 BLE、不触碰 Scene / LaunchServices —— 测试宿主
/// 本身就是要保护的对象（一次测试运行绝不该真的去扫设备或锁屏）。
@MainActor
final class MenuBarVisibilityTests: XCTestCase {

    /// 每个用例一个独立 suite，避免并发用例互相看到对方写入的偏好。
    private func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "MacBleUnlockTests.menuBarIcon.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("无法创建测试用 UserDefaults suite: \(suiteName)")
        }
        return defaults
    }

    func testDefaultsToVisibleWhenNoStoredKey() {
        // 新装或升级后没有这个键：必须保持旧的「显示图标」行为，不能被 `bool(forKey:)` 的 false 吞掉。
        let state = AppState(defaults: makeIsolatedDefaults())
        XCTAssertTrue(state.menuBarIconVisible)
    }

    func testStoredFalseSurvivesReinstantiation() {
        let defaults = makeIsolatedDefaults()
        let state = AppState(defaults: defaults)
        state.setMenuBarIconVisible(false)
        XCTAssertFalse(state.menuBarIconVisible)

        // 重建实例模拟重启：显式存储的 false 必须被读回，而不是回到默认 true。
        let reloaded = AppState(defaults: defaults)
        XCTAssertFalse(reloaded.menuBarIconVisible)
    }

    func testStoredTrueRestoresAfterFalse() {
        let defaults = makeIsolatedDefaults()
        let state = AppState(defaults: defaults)
        state.setMenuBarIconVisible(false)
        state.setMenuBarIconVisible(true)
        XCTAssertTrue(state.menuBarIconVisible)

        let reloaded = AppState(defaults: defaults)
        XCTAssertTrue(reloaded.menuBarIconVisible)
    }
}
