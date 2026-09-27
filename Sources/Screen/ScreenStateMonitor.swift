import AppKit
import CoreGraphics
import Observation

/// 跟踪锁屏 / 屏保 / 睡眠状态。
///
/// 两个独立来源（plan 的兜底设计）：
///   1. `CGSessionCopyCurrentDictionary()` 的 `CGSSessionScreenIsLocked` —— 初始对账与唤醒后校正；
///   2. 分布式通知 `com.apple.screenIsLocked` / `com.apple.screenIsUnlocked` —— 实时状态。
///
/// 任一来源在某个系统版本上失效时，另一条仍然工作。
@MainActor
@Observable
final class ScreenStateMonitor {
    private(set) var isLocked = false
    private(set) var displayAsleep = false
    private(set) var systemAsleep = false
    private(set) var inScreensaver = false
    /// 进入锁定状态的时刻；用于「必须已锁定足够久才注入回车」的判定。
    private(set) var lockedSince: TimeInterval?

    /// 向 CoreGraphics 问一次显示器的真实电源状态。
    ///
    /// 不能只靠 `NSWorkspace.screensDidWake/Sleep` 通知：那是个**事件流**，进程启动时并不
    /// 知道当下的状态 —— 如果 App 是在显示器已经睡眠时启动的，`displayAsleep` 会一直是
    /// false（实测踩过：自动解锁因此跳过了唤醒步骤，按键全打进黑屏）。
    @discardableResult
    func refreshDisplayPower() -> Bool {
        let asleep = Self.isDisplayAsleep
        if asleep != displayAsleep {
            displayAsleep = asleep
            Log.screen.notice("display.power asleep=\(asleep, privacy: .public) via=poll")
        }
        return asleep
    }

    /// 显示器此刻是否睡着。电源层的事实，不依赖任何通知（`CGDisplayIsAsleep` 返回 `boolean_t`）。
    static var isDisplayAsleep: Bool { CGDisplayIsAsleep(CGMainDisplayID()) != 0 }

    private var observers: [NSObjectProtocol] = []

    func start() {
        reconcileLockState(reason: "start")
        refreshDisplayPower()

        let distributed = DistributedNotificationCenter.default()
        for (name, locked) in [
            ("com.apple.screenIsLocked", true),
            ("com.apple.screenIsUnlocked", false),
        ] {
            observers.append(distributed.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.setLocked(locked, reason: name)
                }
            })
        }

        for (name, started) in [
            ("com.apple.screensaver.didstart", true),
            ("com.apple.screensaver.didstop", false),
        ] {
            observers.append(distributed.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.inScreensaver = started
                    Log.screen.notice("screensaver=\(started, privacy: .public)")
                }
            })
        }

        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.displayAsleep = true
                Log.screen.notice("display.asleep")
            }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.displayAsleep = false
                Log.screen.notice("display.awake")
            }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.systemAsleep = true
                Log.screen.notice("system.willSleep")
            }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.systemAsleep = false
                Log.screen.notice("system.didWake")
                // 唤醒后 1s 重新对账：睡眠期间可能错过了分布式通知。
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    MainActor.assumeIsolated { self?.reconcileLockState(reason: "didWake") }
                }
            }
        })
    }

    func stop() {
        let distributed = DistributedNotificationCenter.default()
        let workspace = NSWorkspace.shared.notificationCenter
        for observer in observers {
            distributed.removeObserver(observer)
            workspace.removeObserver(observer)
        }
        observers.removeAll()
    }

    /// 用 CGSession 的权威值校正本地状态。
    func reconcileLockState(reason: String) {
        setLocked(Self.currentSessionLocked(), reason: "reconcile:\(reason)")
    }

    private func setLocked(_ locked: Bool, reason: String) {
        guard locked != isLocked else { return }
        isLocked = locked
        lockedSince = locked ? Date().timeIntervalSince1970 : nil
        Log.screen.notice("locked=\(locked, privacy: .public) via=\(reason, privacy: .public)")
    }

    static func currentSessionLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        if let locked = session["CGSSessionScreenIsLocked"] as? Bool { return locked }
        if let locked = session["CGSSessionScreenIsLocked"] as? Int { return locked == 1 }
        return false
    }
}
