import AppKit
import SwiftUI

@main
struct MacBleUnlockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppState.shared

    /// 菜单栏场景的显示开关。读 `AppState.menuBarIconVisible`，写走统一切换方法 ——
    /// 菜单开关与 reopen 恢复必须落到同一个状态，不能各改各的。
    private var menuBarIconVisible: Binding<Bool> {
        Binding(
            get: { app.menuBarIconVisible },
            set: { app.setMenuBarIconVisible($0) }
        )
    }

    var body: some Scene {
        MenuBarExtra("MacBleUnlock", systemImage: "lock.rotation", isInserted: menuBarIconVisible) {
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

    /// 冷启动是否已跑完，以及启动时刻。两者用来把「用户真正的再次打开」与
    /// 「LaunchServices 在冷启动时顺带投递的首次打开」区分开：后者同样会走 reopen 回调，
    /// 若不过滤，存了隐藏偏好的冷启动会被误判成用户想恢复图标。
    private var hasFinishedLaunching = false
    private var launchUptime: TimeInterval = 0
    /// 启动后 1 秒内一律忽略 reopen：紧随冷启动而来的首次打开事件通常落在这一段。
    /// 更迟的误判在进程内无法区分，属于已知风险（见 README）。
    private static let reopenIgnoreWindow: TimeInterval = 1

    func applicationDidFinishLaunching(_ notification: Notification) {
        launchUptime = ProcessInfo.processInfo.systemUptime
        Log.app.notice("app.launch policy=\(NSApp.activationPolicy().rawValue, privacy: .public)")
        guard !Self.isRunningTests else {
            Log.app.notice("app.launch test host, background machinery not started")
            return
        }
        // 启动就把辅助功能授权与自己的签名指纹记下来：授权与签名身份绑定，
        // 「系统设置里开着但 App 说未授予」几乎都是换过证书，日志里能直接对上。
        Permissions.logAccessibilityState("launch")
        AppState.shared.start()
        // 放在 start() 之后：启动期间收到的 reopen 必须被挡在门外，
        // 否则隐藏偏好会在启动过程中被这个回调自己改成显示。
        hasFinishedLaunching = true
    }

    /// 唯一恢复入口：用户在 Finder/Launchpad/Spotlight 再次打开已运行的 App，或跑 `open -a`。
    /// 隐藏态没有别的 UI，所以这里必须自己把图标恢复出来；返回 false 表示已接管，不再走系统默认处理。
    /// 已显示时也激活 App，让用户看到反馈。不重复调用 `start()`，后台任务不会被重启。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // 纯观测插桩，不改判别：无论事件是否会被忽略都先留痕，才能量出冷启动首次 open 的到达时差。
        let delta = ProcessInfo.processInfo.systemUptime - launchUptime
        let finished = hasFinishedLaunching
        let hidden = !AppState.shared.menuBarIconVisible
        let restoring = finished && delta >= Self.reopenIgnoreWindow && !hidden
        Log.app.notice("app.reopen delta=\(String(format: "%.3f", delta), privacy: .public) finished=\(finished, privacy: .public) hidden=\(hidden, privacy: .public) restoring=\(restoring, privacy: .public) isRunningTests=\(Self.isRunningTests, privacy: .public)")
        guard !Self.isRunningTests,
              hasFinishedLaunching,
              ProcessInfo.processInfo.systemUptime - launchUptime >= Self.reopenIgnoreWindow else {
            return false
        }
        if !AppState.shared.menuBarIconVisible {
            AppState.shared.setMenuBarIconVisible(true)
        }
        NSApp.activate(ignoringOtherApps: true)
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !Self.isRunningTests else { return }
        AppState.shared.stop()
    }
}
