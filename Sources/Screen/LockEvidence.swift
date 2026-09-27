import Foundation

/// 「现在确实在锁屏界面」的判定 —— 决定要不要注入密码的**唯一**闸门。
///
/// 为什么是三方投票而不是信任单一来源：三个信号各自都可能失效。
///   - 分布式通知 `com.apple.screenIsLocked/Unlocked` 可能漏收；
///   - `CGSessionCopyCurrentDictionary` 的 `CGSSessionScreenIsLocked` 在个别系统版本上可能失效；
///   - 前台进程判断依赖 bundle id，系统版本变化时可能对不上。
///
/// 因此要求至少两票同意。方向是不对称的：**漏判只是不解锁（安全），
/// 误判会把登录密码打进前台应用（不可接受）**。
enum LockEvidence {
    /// 锁屏界面可能的宿主进程。锁屏时前台是它们，解锁后是用户的普通应用。
    static let lockUIBundleIDs: Set<String> = [
        "com.apple.loginwindow",
        "com.apple.SecurityAgent",
        "com.apple.ScreenSaver.Engine",
        "com.apple.screensaver",
    ]

    struct Verdict: Equatable {
        var locked: Bool
        var votes: Int
        var detail: String
    }

    static func evaluate(
        stateLocked: Bool,
        sessionLocked: Bool,
        frontmostBundleID: String?
    ) -> Verdict {
        let atLockUI = frontmostBundleID.map(lockUIBundleIDs.contains) ?? false
        let votes = (stateLocked ? 1 : 0) + (sessionLocked ? 1 : 0) + (atLockUI ? 1 : 0)
        let detail = "state=\(stateLocked) session=\(sessionLocked) frontmost=\(frontmostBundleID ?? "-")"
        return Verdict(locked: votes >= 2, votes: votes, detail: detail)
    }
}
