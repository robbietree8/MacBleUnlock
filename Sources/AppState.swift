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
        static let menuBarIconVisible = "menuBarIconVisible"
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
    /// 钥匙串里有条目、但属于别的签名身份读不出来。菜单据此给出「先删掉旧条目」的出口。
    private(set) var passwordUnreadable = false

    /// 菜单「立即锁定」置位；必须等设备先离开再靠近才恢复自动解锁。
    private(set) var manualLock = false

    // MARK: - 检查更新

    /// 一次检查/下载的可见状态。只在用户点菜单时变，所以菜单可以直接观察它。
    enum UpdateState: Equatable {
        case idle
        case checking
        case upToDate(String)
        case available(UpdateChecker.Release)
        case downloading(UpdateChecker.Release)
        /// 已落到下载文件夹的安装包：release + 落地路径。
        case downloaded(UpdateChecker.Release, URL)
        /// 失败原因（一句话，直接进菜单）。
        case failed(String)

        /// 请求进行中：菜单项置灰，避免连点攒出一堆请求。
        var isBusy: Bool {
            switch self {
            case .checking, .downloading: true
            default: false
            }
        }

        /// 已经知道的新版本（有安装包或已经下载完），「打开发布页」据此显示。
        var knownRelease: UpdateChecker.Release? {
            switch self {
            case .available(let release), .downloading(let release), .downloaded(let release, _): release
            default: nil
            }
        }
    }

    private(set) var updateState: UpdateState = .idle
    @ObservationIgnored private var updateTask: Task<Void, Never>?

    // MARK: - 设置

    var unlockRSSI: Int = -60 { didSet { persist(unlockRSSI, Key.unlockRSSI); applyConfig() } }
    var lockRSSI: Int = -80 { didSet { persist(lockRSSI, Key.lockRSSI); applyConfig() } }
    var lockDelay: TimeInterval = 5 { didSet { persist(lockDelay, Key.lockDelay); applyConfig() } }
    var noSignalTimeout: TimeInterval = 30 { didSet { persist(noSignalTimeout, Key.noSignalTimeout); applyConfig() } }
    var keepAwakeEnabled = true { didSet { persist(keepAwakeEnabled, Key.keepAwake); syncKeepAwake() } }
    var wakeDisplayEnabled = true { didSet { persist(wakeDisplayEnabled, Key.wakeDisplay) } }
    var autoUnlockEnabled = true { didSet { persist(autoUnlockEnabled, Key.autoUnlock) } }
    var autoLockEnabled = true { didSet { persist(autoLockEnabled, Key.autoLock) } }

    /// 菜单栏图标是否显示。隐藏态没有任何前台 UI（无 Dock 图标、窗口、通知），
    /// 进程、BLE 扫描与自动锁定/解锁照常运行；只有重新打开已运行的 App 才会恢复。
    var menuBarIconVisible = true { didSet { persist(menuBarIconVisible, Key.menuBarIconVisible) } }

    /// 开机自启：不缓存，直接反映 `SMAppService` 的真实状态。
    /// 写入失败时 `LoginItem.setEnabled` 返回 false，这里就不改任何本地状态 —— 菜单勾选自然回滚。
    /// `.menu` 样式的内容在每次打开菜单时重建，所以不需要额外的变更通知。
    var launchAtLoginEnabled: Bool {
        get { LoginItem.isEnabled }
        set { LoginItem.setEnabled(newValue) }
    }


    @ObservationIgnored private let defaults: UserDefaults
    private var tickTask: Task<Void, Never>?
    private var isApplyingStoredConfig = false

    /// 可注入 `UserDefaults`，单测据此用独立 suite 构造互不影响的状态实例；
    /// `AppState.shared` 仍走 `.standard`，生产行为不变。
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // 构造时就加载：SwiftUI Scene 第一次构建 `MenuBarExtra(isInserted:)` 必须已经拿到
        // 存储值，否则存了隐藏偏好的冷启动会先插进图标、再被 `start()` 覆盖而闪一下。
        loadStoredSettings()
    }

    /// 菜单开关与 reopen 恢复共用这一个入口：只改偏好并持久化，绝不触碰正在运行的后台任务。
    /// `MenuBarExtra` 没有「插入成功与否」的返回值，检测不到失败；若将来出现可检测的失败信号，
    /// 回退策略是把偏好恢复为 true 并持久化，避免留下用户无法自救的隐藏状态。
    func setMenuBarIconVisible(_ visible: Bool) {
        guard menuBarIconVisible != visible else { return }
        menuBarIconVisible = visible
        Log.app.notice("menubar.icon visible=\(visible, privacy: .public)")
    }

    // MARK: - 生命周期

    func start() {
        guard !started else { return }
        started = true

        loadStoredSettings()
        monitoredUUID = DeviceIdentity.storedUUID(in: defaults)
        monitoredName = DeviceIdentity.storedName(in: defaults)
        applyConfig()

        screen.start()
        // 唤醒窗口里到达的「靠近」事件：`UnlockTrigger` 那次会先等系统醒来（`unlock.wait`），
        // 但设备本来就在附近时连 `arrived` 都不会有（睡眠期间扫描停摆，醒来后 presence 仍为 true），
        // 所以 `didWake` 时再主动补一次。
        screen.onSystemWake = { [weak self] in self?.retryUnlockAfterWake() }
        refreshPasswordStatus()
        refreshAccessibilityTrust(logAlways: true)
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
        screen.onSystemWake = nil
        updateTask?.cancel()
        updateTask = nil
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
        // 钥匙串调用可能弹授权框并阻塞线程 —— 必须离开主线程。
        Task { [weak self] in
            let result = await KeychainPassword.load()
            self?.applyPasswordStatus(result)
        }
    }

    private func applyPasswordStatus(_ result: KeychainPassword.LoadResult) {
        switch result {
        case .password(let value) where !value.isEmpty:
            hasStoredPassword = true
            passwordUnreadable = false
        case .password, .missing:
            hasStoredPassword = false
            passwordUnreadable = false
        case .unavailable(let status):
            // 旧签名身份留下的条目：系统设置里看得出它存在，我们却读不出来。
            hasStoredPassword = false
            passwordUnreadable = true
            Log.app.error("password.unreadable status=\(status, privacy: .public)（换过签名证书后旧条目属于旧身份，重设一次登录密码即可）")
        }
        Log.app.notice("password.status stored=\(self.hasStoredPassword, privacy: .public) unreadable=\(self.passwordUnreadable, privacy: .public)")
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
        saveLoginPassword(password)
    }

    /// 写钥匙串同样可能弹授权框（覆盖旧签名身份的条目时），所以也放后台线程：
    /// 用户看到的授权框由系统弹出，这里只是不让主线程陪着一起等。
    private func saveLoginPassword(_ password: String) {
        Task { [weak self] in
            do {
                try await KeychainPassword.save(password)
                Log.app.notice("password.saved")
                self?.refreshPasswordStatus()
            } catch {
                Log.app.error("password.save failed: \(String(describing: error), privacy: .public)")
                self?.presentError("无法保存密码", detail: String(describing: error))
            }
        }
    }

    func clearLoginPassword() {
        Task { [weak self] in
            let status = await KeychainPassword.delete()
            Log.app.notice("password.cleared status=\(status, privacy: .public)")
            self?.refreshPasswordStatus()
        }
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

    // MARK: - 检查更新

    /// 菜单主按钮：点下去干什么由当前状态决定（检查 / 下载 / 在 Finder 里显示已下载的包）。
    func performUpdateAction() {
        switch updateState {
        case .idle, .upToDate, .failed: checkForUpdates()
        case .available(let release):
            // 没带安装包的 release（只有源码包）就只能去发布页。
            if release.downloadURL == nil { openReleasePage() } else { downloadUpdate() }
        case .downloaded(_, let url): NSWorkspace.shared.activateFileViewerSelecting([url])
        case .checking, .downloading: break  // 请求进行中，菜单项已置灰
        }
    }

    /// 查 GitHub Releases 的最新 tag 并与当前版本比对。
    /// 不做自动轮询、不缓存结果：一次点击一次请求（未认证限额 60 次/小时/IP）。
    func checkForUpdates() {
        updateTask?.cancel()
        updateState = .checking
        let current = UpdateChecker.currentVersion
        Log.update.notice("update.check current=\(current, privacy: .public)")
        updateTask = Task { [weak self] in
            let result = await UpdateChecker.check(current: current)
            guard let self, !Task.isCancelled else { return }
            switch result {
            case .upToDate(let version):
                self.updateState = .upToDate(version)
                Log.update.notice("update.result upToDate version=\(version, privacy: .public)")
            case .available(let version, let release):
                self.updateState = .available(release)
                Log.update.notice("update.result available current=\(version, privacy: .public) latest=\(release.version, privacy: .public) asset=\(release.downloadName ?? "-", privacy: .public)")
            case .failed(let reason):
                self.updateState = .failed(reason)
                Log.update.error("update.result failed reason=\(reason, privacy: .public)")
            }
        }
    }

    /// 把安装包下到 `~/Downloads` 并在 Finder 里选中。
    func downloadUpdate() {
        guard let release = updateState.knownRelease, release.downloadURL != nil else { return }
        updateTask?.cancel()
        updateState = .downloading(release)
        Log.update.notice("update.download start version=\(release.version, privacy: .public) name=\(release.downloadName ?? "-", privacy: .public)")
        updateTask = Task { [weak self] in
            do {
                let url = try await UpdateChecker.download(release)
                guard let self, !Task.isCancelled else { return }
                self.updateState = .downloaded(release, url)
                Log.update.notice("update.downloaded path=\(url.path, privacy: .public)")
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                guard let self, !Task.isCancelled else { return }
                let reason = (error as? LocalizedError)?.errorDescription ?? "下载失败"
                self.updateState = .failed(reason)
                Log.update.error("update.download failed reason=\(String(describing: error), privacy: .public)")
            }
        }
    }

    /// 用浏览器打开发布页 —— 想看 release notes 或自己挑包（zip）时用。
    func openReleasePage() {
        guard let release = updateState.knownRelease else { return }
        Log.update.notice("update.page opened version=\(release.version, privacy: .public)")
        NSWorkspace.shared.open(release.pageURL)
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
    /// 同一台设备可能有多个 uuid（identity 地址 + 私有地址），菜单里它们合成一行，
    /// 所以勾选状态按**名字**判定：代表样本的 uuid 会随着两个地址的强弱来回变，按 uuid 判会闪。
    func isMonitored(_ group: DeviceGroup) -> Bool {
        if !group.name.isEmpty, monitoredName == group.name { return true }
        return monitoredUUID == group.representative.uuid
    }

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
    private(set) var menuDeviceGroups: [DeviceGroup] = []
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
        refreshAccessibilityTrust()
        // 显示器电源状态每秒对齐一次：通知流在「启动时已经睡着」的情况下是错的。
        screen.refreshDisplayPower()
        refreshMenuSnapshot()
    }

    // MARK: - 辅助功能授权

    /// 辅助功能授权的快照。菜单读这个值，**不能**直接在视图里问 TCC：
    /// `Permissions.isAccessibilityTrusted` 不是被观察的属性，授权状态变了菜单也不会
    /// 重建，标题就永远停在旧值上（系统设置里明明已开启、菜单仍显示「未授予」）。
    private(set) var accessibilityTrusted = false

    /// 菜单里点「辅助功能权限」时走这里。
    func requestAccessibility() {
        if Permissions.isAccessibilityTrusted {
            Permissions.openAccessibilitySettings()
        } else {
            Permissions.promptAccessibility()
            Permissions.openAccessibilitySettings()
        }
        Permissions.logAccessibilityState("menu")
        refreshAccessibilityTrust()
    }

    private func refreshAccessibilityTrust(logAlways: Bool = false) {
        let trusted = Permissions.isAccessibilityTrusted
        if logAlways || trusted != accessibilityTrusted {
            Permissions.logAccessibilityState(trusted ? "granted" : "revoked")
        }
        accessibilityTrusted = trusted
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

        let groups = scanner.deviceGroups
        if groups != menuDeviceGroups { menuDeviceGroups = groups }

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

    /// 系统从睡眠中醒来后补一次解锁尝试。
    ///
    /// 两个入口都需要它：唤醒窗口里到达的 `arrived`（`UnlockTrigger` 会等系统醒来，但多一次总无妨），
    /// 以及「设备一直在附近、睡眠期间扫描停摆」那种连 `arrived` 都不会有的唤醒 ——
    /// 实测 2026-09-30 08:37 就是前者：`arrived` 到 `system.didWake` 的 8.7s 里什么都做不了。
    private func retryUnlockAfterWake() {
        guard presence, screen.isLocked, autoUnlockEnabled, !manualLock else { return }
        Log.screen.notice("unlock.retry after system wake")
        if wakeDisplayEnabled { display.wakeDisplay() }
        UnlockTrigger.shared.attempt()
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
        // 只在键存在时读取：`bool(forKey:)` 对缺失键返回 false，会把默认的「显示」覆盖成隐藏。
        if defaults.object(forKey: Key.menuBarIconVisible) != nil { menuBarIconVisible = defaults.bool(forKey: Key.menuBarIconVisible) }
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
