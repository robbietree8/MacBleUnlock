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
            if Permissions.isAccessibilityTrusted {
                Permissions.openAccessibilitySettings()
            } else {
                Permissions.promptAccessibility()
                Permissions.openAccessibilitySettings()
            }
        }

        Button(app.hasStoredPassword ? "更新登录密码…" : "设置登录密码…") {
            app.promptForLoginPassword()
        }

        if app.hasStoredPassword {
            Button("清除登录密码") { app.clearLoginPassword() }
        }

        Divider()

        Button("立即锁定") { app.lockNow() }

        if app.lockFailed {
            Text("锁定失败：见日志")
        }

        Button("打开日志") { app.openLog() }

        Divider()

        Text("设备在附近时，App 会自动替你输入登录密码解锁。")

        Button("退出 MacBleUnlock") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var accessibilityTitle: String {
        Permissions.isAccessibilityTrusted ? "辅助功能权限：已授予" : "辅助功能权限：未授予（点击申请）"
    }

    /// 菜单里**只能**读低频率的状态：快照（menuXxx）、设置项、以及很少变的状态。
    /// 直接读 `scanner.xxx` / `smoothedRSSI` 会让菜单每秒重建几十次，子菜单就会一直闪。
    private var deviceMenu: some View {
        Menu("设备") {
            if app.menuDevices.isEmpty {
                Text(app.menuBluetoothAvailable ? "未发现设备" : "蓝牙不可用")
            } else {
                ForEach(app.menuDevices, id: \.uuid) { device in
                    Toggle(label(for: device), isOn: Binding(
                        get: { app.monitoredUUID == device.uuid },
                        set: { isOn in if isOn { app.selectDevice(device) } }
                    ))
                }
            }
        }
    }

    private func label(for device: DeviceSample) -> String {
        let name = device.name ?? device.uuid.uuidString.prefix(8).description
        return "\(name)  \(device.rssi) dBm"
    }
}
