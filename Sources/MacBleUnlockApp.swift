import AppKit
import SwiftUI

@main
struct MacBleUnlockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppState.shared

    var body: some Scene {
        MenuBarExtra("MacBleUnlock", systemImage: "lock.rotation") {
            MenuView(app: app)
        }
        .menuBarExtraStyle(.menu)
    }
}

/// 启动/退出走 AppDelegate 而不是 `MenuBarExtra` 内容视图上的 `.task`：
/// `.menu` 样式的菜单内容由 NSMenu 惰性构建，`.task` 只在用户第一次点开菜单时
/// 才执行 —— 那样 BLE 扫描要等用户点一下才开始，自动锁定永远不会触发。
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 单测宿主就是本 App。测试期间绝不能启动 BLE 扫描与自动锁定 ——
    /// 否则一次 `xcodebuild test` 就可能因为设备“离开”而把用户的屏幕锁上。
    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.app.notice("app.launch policy=\(NSApp.activationPolicy().rawValue, privacy: .public)")
        guard !Self.isRunningTests else {
            Log.app.notice("app.launch test host, background machinery not started")
            return
        }
        AppState.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !Self.isRunningTests else { return }
        AppState.shared.stop()
    }
}
