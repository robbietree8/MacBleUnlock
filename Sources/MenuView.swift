import AppKit
import SwiftUI

struct MenuView: View {
    @Bindable var app: AppState

    var body: some View {
        Text(app.menuStatusText)

        Divider()

        deviceMenu

        Picker("靠近时解锁", selection: $app.unlockRSSI) {
            Text("关闭").tag(-1000)
            Text("-50 dBm（很近）").tag(-50)
            Text("-60 dBm").tag(-60)
            Text("-70 dBm").tag(-70)
            Text("-80 dBm（宽松）").tag(-80)
        }

        Picker("远离时锁定", selection: $app.lockRSSI) {
            Text("关闭").tag(-1000)
            Text("-70 dBm").tag(-70)
            Text("-80 dBm").tag(-80)
            Text("-90 dBm").tag(-90)
        }

        Picker("离开判定延迟", selection: $app.lockDelay) {
            Text("3 秒").tag(TimeInterval(3))
            Text("5 秒").tag(TimeInterval(5))
            Text("10 秒").tag(TimeInterval(10))
            Text("30 秒").tag(TimeInterval(30))
        }

        Picker("无信号超时", selection: $app.noSignalTimeout) {
            Text("15 秒").tag(TimeInterval(15))
            Text("30 秒").tag(TimeInterval(30))
            Text("60 秒").tag(TimeInterval(60))
            Text("120 秒").tag(TimeInterval(120))
        }

        Divider()

        Toggle("靠近时保持屏幕不休眠", isOn: $app.keepAwakeEnabled)
        Toggle("靠近时唤醒屏幕", isOn: $app.wakeDisplayEnabled)
        Toggle("开机自启", isOn: $app.launchAtLoginEnabled)

        Divider()

        Button(accessibilityTitle) {
            app.requestAccessibility()
        }

        Button(passwordButtonTitle) {
            app.promptForLoginPassword()
        }

        if app.hasStoredPassword {
            Button("清除登录密码") { app.clearLoginPassword() }
        }
        if app.passwordUnreadable {
            Button("删除旧钥匙串条目") { app.clearLoginPassword() }
        }

        Divider()

        Button("立即锁定") { app.lockNow() }

        if app.lockFailed {
            Text("锁定失败：见日志")
        }

        Button("打开日志") { app.openLog() }

        Button(updateItemTitle) { app.performUpdateAction() }
            .disabled(app.updateState.isBusy)

        if app.updateState.knownRelease != nil {
            Button("打开发布页") { app.openReleasePage() }
        }

        Divider()

        Text("设备在附近时，App 会自动替你输入登录密码解锁。")

        Text(versionText)

        Button("退出 MacBleUnlock") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var accessibilityTitle: String {
        app.accessibilityTrusted ? "辅助功能权限：已授予" : "辅助功能权限：未授予（点击申请）"
    }

    /// 检查更新那一项的标题 —— 状态与动作都要写在标题里，菜单里没有别的提示位置：
    /// `.menu` 样式只能给 Button 一个标题，disable 一项就少一个可点击入口，
    /// 所以主按钮的事（检查 / 下载 / 显示）由 `AppState.performUpdateAction()` 按状态分派。
    private var updateItemTitle: String {
        switch app.updateState {
        case .idle:
            "检查更新"
        case .checking:
            "正在检查更新…"
        case .upToDate(let version):
            "已是最新版本 \(version)（点击重新检查）"
        case .available(let release):
            release.downloadURL == nil
                ? "发现新版本 \(release.version)（无安装包，打开发布页）"
                : "下载 MacBleUnlock \(release.version) 安装包"
        case .downloading(let release):
            "正在下载 \(release.version)…"
        case .downloaded(_, let url):
            "已下载 \(url.lastPathComponent)（点击在 Finder 中显示）"
        case .failed(let reason):
            "检查更新失败：\(reason)（点击重试）"
        }
    }

    /// 菜单底部显示的版本号。
    ///
    /// 直接读 `Bundle.main`，不缓存：`.menu` 样式的菜单内容每次打开都重建，
    /// 所以从 Finder 里替换 `.app` 后不用重启菜单就能看到新版本。
    /// 版本号来自 `project.yml` 的 `CFBundleShortVersionString` / `CFBundleVersion`。
    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "版本 \(short) (\(build))"
    }

    /// 换过签名证书后，钥匙串里属于旧身份的条目会读不出来（历史上它还会把 App 卡在启动阶段）。
    /// 菜单必须把这两种情况分开说，否则用户只会看到「设置登录密码」而不知道旧条目还在。
    private var passwordButtonTitle: String {
        if app.hasStoredPassword { return "更新登录密码…" }
        if app.passwordUnreadable { return "设置登录密码…（旧条目不可读）" }
        return "设置登录密码…"
    }

    /// 菜单里**只能**读低频率的状态：快照（menuXxx）、设置项、以及很少变的状态。
    /// 直接读 `scanner.xxx` / `smoothedRSSI` 会让菜单每秒重建几十次，子菜单就会一直闪。
    private var deviceMenu: some View {
        Menu("设备") {
            if app.menuDeviceGroups.isEmpty {
                Text(app.menuBluetoothAvailable ? "未发现设备" : "蓝牙不可用")
            } else {
                ForEach(app.menuDeviceGroups, id: \.id) { group in
                    Toggle(label(for: group), isOn: Binding(
                        get: { app.isMonitored(group) },
                        set: { isOn in if isOn { app.selectDevice(group.representative) } }
                    ))
                }
            }
        }
    }

    private func label(for group: DeviceGroup) -> String {
        let name = group.name.isEmpty ? group.representative.uuid.uuidString.prefix(8).description : group.name
        return "\(name)  \(group.representative.rssi) dBm"
    }
}
