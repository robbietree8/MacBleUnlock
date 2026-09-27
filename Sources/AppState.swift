import AppKit
import Foundation
import Observation

/// 根应用状态。菜单栏场景持有的单例。
@MainActor
@Observable
final class AppState {
    static let shared = AppState()

    // MARK: - UserDefaults 键（集中定义）

    enum Key {
        static let unlockRSSI = "unlockRSSI"
        static let lockRSSI = "lockRSSI"
        static let lockDelay = "lockDelay"
        static let noSignalTimeout = "noSignalTimeout"
        static let keepAwake = "keepAwake"
        static let wakeDisplay = "wakeDisplay"
        static let autoUnlock = "autoUnlock"
        static let autoLock = "autoLock"
        static let launchAtLogin = "launchAtLogin"
    }

    // MARK: - 子系统

    let scanner = BLEScanner()
    let screen = ScreenStateMonitor()
    let display = DisplayPower()

    private(set) var started = false

    // MARK: - 靠近状态

    private var engine = ProximityEngine()
    private(set) var monitoredUUID: UUID?
    private(set) var monitoredName: String?
    private(set) var presence = false
    private(set) var smoothedRSSI: Int?
    private(set) var lastEventText = "—"
    private(set) var lockFailed = false
    private(set) var hasStoredPassword = false

    /// 菜单「立即锁定」置位；必须等设备先离开再靠近才恢复自动解锁。
    private(set) var manualLock = false

    // MARK: - 设置

    var unlockRSSI: Int = -60 { didSet { persist(unlockRSSI, Key.unlockRSSI); applyConfig() } }
    var lockRSSI: Int = -80 { didSet { persist(lockRSSI, Key.lockRSSI); applyConfig() } }
    var lockDelay: TimeInterval = 5 { didSet { persist(lockDelay, Key.lockDelay); applyConfig() } }
    var noSignalTimeout: TimeInterval = 30 { didSet { persist(noSignalTimeout, Key.noSignalTimeout); applyConfig() } }
    var keepAwakeEnabled = true { didSet { persist(keepAwakeEnabled, Key.keepAwake); syncKeepAwake() } }
    var wakeDisplayEnabled = true { didSet { persist(wakeDisplayEnabled, Key.wakeDisplay) } }
    var autoUnlockEnabled = true { didSet { persist(autoUnlockEnabled, Key.autoUnlock) } }
    var autoLockEnabled = true { didSet { persist(autoLockEnabled, Key.autoLock) } }

    /// 开机自启：不缓存，直接反映 `SMAppService` 的真实状态。
    /// 写入失败时 `LoginItem.setEnabled` 返回 false，这里就不改任何本地状态 —— 菜单勾选自然回滚。
    /// `.menu` 样式的内容在每次打开菜单时重建，所以不需要额外的变更通知。
    var launchAtLoginEnabled: Bool {
        get { LoginItem.isEnabled }
        set { LoginItem.setEnabled(newValue) }
    }


    private var defaults: UserDefaults { .standard }
    private var tickTask: Task<Void, Never>?
    private var isApplyingStoredConfig = false

    private init() {}

    // MARK: - 生命周期

    func start() {
        guard !started else { return }
        started = true

        loadStoredSettings()
        monitoredUUID = DeviceIdentity.storedUUID(in: defaults)
        monitoredName = DeviceIdentity.storedName(in: defaults)
        applyConfig()

        screen.start()
        refreshPasswordStatus()
        startMenuTrackingObservation()
        refreshMenuSnapshot(force: true)

        scanner.onSample = { [weak self] uuid, name, rssi in
            self?.handleSample(uuid: uuid, name: name, rssi: rssi)
        }
        scanner.onDevicesChanged = { [weak self] in
            self?.resolveMonitoredDevice()
        }
        scanner.start()

        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.tick()
            }
        }

        Log.app.notice("app.started monitored=\(self.monitoredUUID?.uuidString ?? "-", privacy: .public)")
    }

    func stop() {
        guard started else { return }
        started = false
        tickTask?.cancel()
        tickTask = nil
        scanner.stop()
        screen.stop()
        for observer in menuTrackingObservers { NotificationCenter.default.removeObserver(observer) }
        menuTrackingObservers.removeAll()
        display.releaseKeepAwake()
        Log.app.notice("app.stopped")
    }

    // MARK: - 菜单动作

    /// 菜单「立即锁定」：锁定并置 manualLock，之后必须「先离开再靠近」才会自动解锁。
    func lockNow() {
        manualLock = true
        let ok = ScreenLocker.lock()
        lockFailed = !ok
        Log.screen.notice("manual lock ok=\(ok, privacy: .public)")
    }

    func refreshPasswordStatus() {
        hasStoredPassword = KeychainPassword.isSet
    }

    /// 菜单「设置登录密码…」。密码只写进钥匙串，不落盘、不记日志。
    func promptForLoginPassword() {
        let alert = NSAlert()
        alert.messageText = hasStoredPassword ? "更新登录密码" : "设置登录密码"
        alert.informativeText = "密码只保存在本机钥匙串中，仅用于设备靠近时自动解锁。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "登录密码"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let password = field.stringValue
        guard !password.isEmpty else {
            Log.app.notice("password.prompt empty, ignored")
            return
        }
        do {
            try KeychainPassword.save(password)
            refreshPasswordStatus()
            Log.app.notice("password.saved")
        } catch {
            Log.app.error("password.save failed: \(String(describing: error), privacy: .public)")
            presentError("无法保存密码", detail: String(describing: error))
        }
    }

    func clearLoginPassword() {
        KeychainPassword.delete()
        refreshPasswordStatus()
        Log.app.notice("password.cleared")
    }

    private func presentError(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// 把日志过滤谓词拷到剪贴板再打开控制台。
    func openLog() {
        let predicate = "subsystem == \"\(Log.subsystem)\""
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(predicate, forType: .string)
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Console.app"))
    }


    func selectDevice(_ device: DeviceSample) {
        monitoredUUID = device.uuid
        monitoredName = device.name
        DeviceIdentity.store(MonitoredDevice(uuid: device.uuid, name: device.name), in: defaults)
        engine.reset()
        syncEngineState()
        lastEventText = "已选择 \(device.name ?? device.uuid.uuidString)"
        Log.proximity.notice("device.selected uuid=\(device.uuid.uuidString, privacy: .public) name=\(device.name ?? "-", privacy: .public)")
    }

    /// 菜单里「设备」子菜单的绑定。
    var deviceSelection: UUID? {
        get { monitoredUUID }
        set {
            guard let newValue, let device = scanner.devices[newValue] else { return }
            selectDevice(device)
        }
    }

    // MARK: - 菜单快照
    //
    // 菜单**绝不能**直接读实时值。RSSI 每个样本都在变、每个设备每次广播都在变，
    // 直接观察它们会让 SwiftUI 每秒重建几十次 NSMenu —— 表现就是悬停子菜单时一直闪
    // （重建会把用户正悬停的子菜单一起拆掉）。
    // 所以菜单只读这份快照：内容真的变了才赋值，最多 1 秒一更，且菜单显示期间完全冻结。

    private(set) var menuStatusText = "启动中"
    private(set) var menuDevices: [DeviceSample] = []
    private(set) var menuBluetoothAvailable = false

    @ObservationIgnored private var lastMenuRefresh: TimeInterval = 0
    /// 正在显示中的 NSMenu 数量。子菜单会再发一对 begin/end，所以用计数而不是布尔。
    @ObservationIgnored private var menuTrackingDepth = 0
    @ObservationIgnored private var menuTrackingSince: TimeInterval = 0
    @ObservationIgnored private var menuTrackingObservers: [NSObjectProtocol] = []

    // MARK: - 状态文案

    /// 实时状态文案。**仅供内部生成快照使用**，不要放进视图里 —— 它每次采样都会变。
    private var liveStatusText: String {
        guard scanner.bluetoothAvailable else {
            return "蓝牙：\(scanner.bluetoothStateText)"
        }
        guard monitoredUUID != nil else { return "未选择设备" }
        let name = monitoredName ?? "已选设备"
        guard let rssi = smoothedRSSI else { return "\(name) · 未检测到" }
        return "\(name) · \(rssi) dBm · \(presence ? "附近" : "已离开")"
    }

    // MARK: - 事件处理

    private func handleSample(uuid: UUID, name: String?, rssi: Int) {
        guard let monitored = monitoredUUID, uuid == monitored else { return }

        let now = Date().timeIntervalSince1970
        let events = engine.sample(rssi: rssi, at: now)
        syncEngineState()
        Log.proximity.debug("sample rssi=\(rssi, privacy: .public) smoothed=\(self.smoothedRSSI ?? 0, privacy: .public) presence=\(self.presence, privacy: .public)")
        handle(events: events)
    }

    private func tick() {
        let events = engine.tick(at: Date().timeIntervalSince1970)
        syncEngineState()
        handle(events: events)
        refreshMenuSnapshot()
    }

    // MARK: - 菜单快照的生成

    private func startMenuTrackingObservation() {
        let center = NotificationCenter.default
        let begin = NSMenu.didBeginTrackingNotification
        let end = NSMenu.didEndTrackingNotification
        menuTrackingObservers.append(center.addObserver(forName: begin, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.menuTrackingDepth == 0 { self.menuTrackingSince = Date().timeIntervalSince1970 }
                self.menuTrackingDepth += 1
                Log.app.debug("menu.tracking depth=\(self.menuTrackingDepth, privacy: .public) frozen=true")
            }
        })
        menuTrackingObservers.append(center.addObserver(forName: end, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.menuTrackingDepth = max(0, self.menuTrackingDepth - 1)
                Log.app.debug("menu.tracking depth=\(self.menuTrackingDepth, privacy: .public) frozen=\(self.menuTrackingDepth > 0, privacy: .public)")
                // 菜单刚关上：把快照刷到最新，下次打开就是新值。
                if self.menuTrackingDepth == 0 { self.refreshMenuSnapshot(force: true) }
            }
        })
    }

    private func refreshMenuSnapshot(force: Bool = false) {
        let now = Date().timeIntervalSince1970

        if menuTrackingDepth > 0 {
            // 兜底：万一漏收了 didEndTracking，2 分钟后自动解冻，避免菜单永久停在旧值。
            guard now - menuTrackingSince > 120 else { return }
            menuTrackingDepth = 0
        }
        if !force, now - lastMenuRefresh < 1 { return }
        lastMenuRefresh = now

        // 逐项比较后再赋值：@Observable 每次赋值都会通知，写同样的值等于白白重建一次菜单。
        let text = liveStatusText
        if text != menuStatusText { menuStatusText = text }

        let devices = scanner.sortedDevices
        if devices != menuDevices { menuDevices = devices }

        if scanner.bluetoothAvailable != menuBluetoothAvailable {
            menuBluetoothAvailable = scanner.bluetoothAvailable
        }
    }

    private func syncEngineState() {
        presence = engine.presence
        smoothedRSSI = engine.smoothedRSSI
        // 断言的唯一收敛点：严格镜像 (keepAwakeEnabled && presence)。
        // 放在这里而不是散落在各个事件分支里，否则换设备 / 重绑这类
        // 「presence 直接归零」的路径会漏掉 release，断言就永久泄漏。
        syncKeepAwake()
    }

    private func handle(events: [ProximityEvent]) {
        for event in events {
            Log.proximity.notice("event=\(String(describing: event), privacy: .public)")
            lastEventText = Self.describe(event)

            switch event {
            case .departed, .lost:
                manualLock = false
                if autoLockEnabled, !screen.isLocked {
                    lockFailed = !ScreenLocker.lock()
                }
            case .arrived:
                if manualLock { break }
                if screen.isLocked, autoUnlockEnabled {
                    if wakeDisplayEnabled { display.wakeDisplay() }
                    UnlockTrigger.shared.attempt()
                }
            }
        }
    }

    private static func describe(_ event: ProximityEvent) -> String {
        switch event {
        case .arrived: "设备靠近"
        case .departed: "设备远离"
        case .lost: "信号丢失"
        }
    }

    /// 设备在附近且开启「保持屏幕不休眠」时持有断言。
    private func syncKeepAwake() {
        if keepAwakeEnabled, presence {
            display.holdKeepAwake()
        } else {
            display.releaseKeepAwake()
        }
    }

    private func resolveMonitoredDevice() {
        let candidates = scanner.devices.values.map { MonitoredDevice(uuid: $0.uuid, name: $0.name) }
        guard !candidates.isEmpty else { return }
        guard let resolved = DeviceIdentity.resolve(candidates: candidates, in: defaults) else { return }
        guard resolved != monitoredUUID else {
            monitoredName = DeviceIdentity.storedName(in: defaults)
            return
        }
        monitoredUUID = resolved
        monitoredName = DeviceIdentity.storedName(in: defaults)
        engine.reset()
        syncEngineState()
        Log.proximity.notice("device.rebound uuid=\(resolved.uuidString, privacy: .public)")
    }

    // MARK: - 设置持久化

    private func loadStoredSettings() {
        isApplyingStoredConfig = true
        defer { isApplyingStoredConfig = false }

        if defaults.object(forKey: Key.unlockRSSI) != nil { unlockRSSI = defaults.integer(forKey: Key.unlockRSSI) }
        if defaults.object(forKey: Key.lockRSSI) != nil { lockRSSI = defaults.integer(forKey: Key.lockRSSI) }
        if defaults.object(forKey: Key.lockDelay) != nil { lockDelay = defaults.double(forKey: Key.lockDelay) }
        if defaults.object(forKey: Key.noSignalTimeout) != nil { noSignalTimeout = defaults.double(forKey: Key.noSignalTimeout) }
        if defaults.object(forKey: Key.keepAwake) != nil { keepAwakeEnabled = defaults.bool(forKey: Key.keepAwake) }
        if defaults.object(forKey: Key.wakeDisplay) != nil { wakeDisplayEnabled = defaults.bool(forKey: Key.wakeDisplay) }
        if defaults.object(forKey: Key.autoUnlock) != nil { autoUnlockEnabled = defaults.bool(forKey: Key.autoUnlock) }
        if defaults.object(forKey: Key.autoLock) != nil { autoLockEnabled = defaults.bool(forKey: Key.autoLock) }
    }

    private func persist(_ value: Any, _ key: String) {
        guard !isApplyingStoredConfig else { return }
        defaults.set(value, forKey: key)
    }

    private func applyConfig() {
        engine.update(config: ProximityConfig(
            unlockRSSI: unlockRSSI,
            lockRSSI: lockRSSI,
            lockDelay: lockDelay,
            noSignalTimeout: noSignalTimeout,
            medianWindow: 5
        ))
        // 把生效的配置记下来：默认值 / 存储值 / 菜单值三者不一致时，这是唯一能看出真相的地方。
        Log.app.notice("config unlock=\(self.unlockRSSI, privacy: .public) lock=\(self.lockRSSI, privacy: .public) delay=\(self.lockDelay, privacy: .public) timeout=\(self.noSignalTimeout, privacy: .public) keepAwake=\(self.keepAwakeEnabled, privacy: .public) autoLock=\(self.autoLockEnabled, privacy: .public)")
        syncEngineState()
    }
}
