import Foundation
import ServiceManagement

/// 开机自启（`SMAppService.mainApp`）。
@MainActor
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static var statusText: String {
        switch SMAppService.mainApp.status {
        case .enabled: "已开启"
        case .notRegistered: "未开启"
        case .notFound: "未找到"
        case .requiresApproval: "等待系统设置里批准"
        @unknown default: "未知"
        }
    }

    /// 返回是否成功。调用方负责在失败时回滚菜单勾选状态。
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            Log.app.notice("loginItem.set enabled=\(enabled, privacy: .public) status=\(Self.statusText, privacy: .public)")
            return true
        } catch {
            Log.app.error("loginItem.failed enabled=\(enabled, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
