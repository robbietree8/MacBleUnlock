import CoreBluetooth
import Foundation
import Observation

/// 一个被监听的 BLE 设备及其最近一次样本。
struct DeviceSample: Equatable, Sendable {
    var uuid: UUID
    var name: String?
    var rssi: Int
    var seenAt: TimeInterval
}

/// 扫描 BLE 广播并维护设备列表。
///
/// 设备身份用 `CBPeripheral.identifier`（本机稳定的 UUID）加广播名 —— 不做 MAC 解析
/// （macOS 27 上 `/Library/Preferences/com.apple.Bluetooth.plist` 已无缓存表，
/// `/Library/Bluetooth/*.db` 为 640 root:wheel）。
///
/// **两条发现路径，缺一不可**（plan 只写了第一条）：
///
///   1. `scanForPeripherals` —— 发现正在广播的设备。
///   2. `retrieveConnectedPeripherals` —— 发现**已经连到本机**的设备。
///
/// 第 2 条是主用例的关键：iPhone 一旦与 Mac 建立 BLE 连接（Handoff / 连续互通 /
/// 已配对），就不再发送可被扫描到的广播包，`scanForPeripherals` 永远看不到它。
/// 实测本机 `system_profiler SPBluetoothDataType` 显示 iPhone 处于 Connected、
/// RSSI -48，而扫描结果里完全没有它。所以必须把系统已连接的设备也纳入，
/// 并主动 `readRSSI()` 轮询来获得实时距离。
@MainActor
@Observable
final class BLEScanner: NSObject {
    /// 对外可见的设备列表（最近 15s 内有样本的设备）。
    private(set) var devices: [UUID: DeviceSample] = [:]
    private(set) var bluetoothAvailable = false
    private(set) var bluetoothStateText = "未知"
    /// 用户在系统设置里拒绝了蓝牙权限。
    private(set) var authorizationDenied = false

    /// 每个有效样本（已过滤哨兵值）。
    @ObservationIgnored var onSample: ((UUID, String?, Int) -> Void)?
    /// 设备列表发生变化（新增 / 过期移除）。
    @ObservationIgnored var onDevicesChanged: (() -> Void)?

    /// 无样本多久后从菜单列表移除。仅影响展示，不参与靠近判定。
    private let expiryInterval: TimeInterval = 15
    /// `readRSSI()` 轮询间隔。每次调用是一次 BLE 往返，1s 足够且不扰民。
    private let rssiPollInterval: TimeInterval = 1
    /// 每隔多少次 tick 重新枚举系统已连接设备。
    /// 每秒跑一次接管扫描。实测断连到重新接管有 3–4s 空档，其中大部分是
    /// 系统级连接自己在重连，但把轮询降到 1s 仍能削掉属于我们那一部分。
    private let adoptEveryNTicks = 1

    /// 用于 `retrieveConnectedPeripherals` 的服务 UUID。
    ///
    /// **空数组不会返回任何东西**（实测），必须给出具体服务。
    /// 这组覆盖了 iPhone/iPad 在连接状态下对外暴露的服务，实测在本机
    /// 能用 180A 把已连接的 iPhone 取出来：
    ///   180A Device Information、180F Battery、1805 Current Time、
    ///   9FA480E0-… Apple Continuity。
    private static let connectedProbeServices: [CBUUID] = [
        CBUUID(string: "180A"),
        CBUUID(string: "180F"),
        CBUUID(string: "1805"),
        CBUUID(string: "9FA480E0-4967-4542-9390-D343DC5D04AE"),
    ]

    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var connectedPeripherals: [UUID: CBPeripheral] = [:]
    /// 每秒递增，不参与观察 —— 否则菜单每秒都会被无意义地重建。
    @ObservationIgnored private var tickCount = 0
    @ObservationIgnored private var lastReconnectAttemptAt: TimeInterval = 0

    func start() {
        guard central == nil else { return }
        bluetoothStateText = "启动中"
        central = CBCentralManager(delegate: self, queue: .main)
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.tick()
            }
        }
    }

    func stop() {
        tickTask?.cancel()
        tickTask = nil
        if let central {
            for peripheral in connectedPeripherals.values {
                central.cancelPeripheralConnection(peripheral)
            }
        }
        connectedPeripherals.removeAll()
        central?.stopScan()
        central = nil
        devices.removeAll()
        bluetoothAvailable = false
        bluetoothStateText = "已停止"
        onDevicesChanged?()
    }

    func sample(for uuid: UUID) -> DeviceSample? { devices[uuid] }

    var sortedDevices: [DeviceSample] {
        devices.values.sorted {
            if $0.rssi != $1.rssi { return $0.rssi > $1.rssi }
            return ($0.name ?? "") < ($1.name ?? "")
        }
    }

    // MARK: - 定时任务

    private func tick() {
        tickCount += 1
        if tickCount % adoptEveryNTicks == 0 {
            adoptConnectedPeripherals()
        }
        pollConnectedRSSI()
        expireStaleDevices()
    }

    private func expireStaleDevices() {
        let now = Date().timeIntervalSince1970
        let stale = devices.filter { now - $0.value.seenAt > expiryInterval }.map(\.key)
        guard !stale.isEmpty else { return }
        for key in stale { devices.removeValue(forKey: key) }
        onDevicesChanged?()
    }

    /// 把系统已连接的 BLE 设备纳入监听，并建立我们自己的连接以便读 RSSI。
    private func adoptConnectedPeripherals() {
        guard let central, bluetoothAvailable else { return }
        var seen = Set<UUID>()
        for service in Self.connectedProbeServices {
            for peripheral in central.retrieveConnectedPeripherals(withServices: [service]) {
                guard seen.insert(peripheral.identifier).inserted else { continue }
                guard connectedPeripherals[peripheral.identifier] == nil else { continue }
                connectedPeripherals[peripheral.identifier] = peripheral
                peripheral.delegate = self
                central.connect(peripheral, options: nil)
                Log.ble.notice("device.adopt uuid=\(peripheral.identifier.uuidString, privacy: .public) name=\(peripheral.name ?? "-", privacy: .public)")
            }
        }
    }

    private func pollConnectedRSSI() {
        for peripheral in connectedPeripherals.values where peripheral.state == .connected {
            peripheral.readRSSI()
        }
    }

    // MARK: - 状态与发现

    private func handleState(_ state: CBManagerState) {
        switch state {
        case .poweredOn:
            bluetoothAvailable = true
            authorizationDenied = false
            bluetoothStateText = "已开启"
            central?.scanForPeripherals(
                withServices: nil,
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
            )
            adoptConnectedPeripherals()
        case .poweredOff:
            bluetoothAvailable = false
            bluetoothStateText = "蓝牙已关闭"
            devices.removeAll()
            connectedPeripherals.removeAll()
            onDevicesChanged?()
        case .unauthorized:
            bluetoothAvailable = false
            authorizationDenied = true
            bluetoothStateText = "无蓝牙权限"
        case .unsupported:
            bluetoothAvailable = false
            bluetoothStateText = "此机器不支持蓝牙"
        case .resetting:
            bluetoothAvailable = false
            bluetoothStateText = "蓝牙正在重置"
        case .unknown:
            bluetoothAvailable = false
            bluetoothStateText = "未知"
        @unknown default:
            bluetoothAvailable = false
            bluetoothStateText = "未知"
        }
        Log.ble.notice("state=\(self.bluetoothStateText, privacy: .public) available=\(self.bluetoothAvailable, privacy: .public)")
    }

    private func handleDiscovery(uuid: UUID, name: String?, rssi: Int) {
        // CoreBluetooth 的「RSSI 不可用」哨兵与物理上不可能的值都不是有效测距。
        guard ProximityEngine.isValidRSSI(rssi) else { return }

        let now = Date().timeIntervalSince1970
        let isNew = devices[uuid] == nil
        devices[uuid] = DeviceSample(uuid: uuid, name: name ?? devices[uuid]?.name, rssi: rssi, seenAt: now)
        if isNew {
            Log.ble.debug("device.discovered uuid=\(uuid.uuidString, privacy: .public) name=\(name ?? "-", privacy: .public) rssi=\(rssi, privacy: .public)")
            onDevicesChanged?()
        }
        onSample?(uuid, name ?? devices[uuid]?.name, rssi)
    }
}

extension BLEScanner: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        handleState(central.state)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
        handleDiscovery(uuid: peripheral.identifier, name: name, rssi: RSSI.intValue)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Log.ble.notice("device.didConnect uuid=\(peripheral.identifier.uuidString, privacy: .public) name=\(peripheral.name ?? "-", privacy: .public)")
        peripheral.readRSSI()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Log.ble.error("device.connectFailed uuid=\(peripheral.identifier.uuidString, privacy: .public) error=\(error?.localizedDescription ?? "-", privacy: .public)")
        connectedPeripherals.removeValue(forKey: peripheral.identifier)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        // 记录系统级连接是否还在：在 → 空档是我们轮询太慢；不在 → 是 iPhone 侧真的断了，
        // 我们只能等系统重连。用于区分这两种情况。
        let stillSystemConnected = Self.connectedProbeServices.contains { service in
            central.retrieveConnectedPeripherals(withServices: [service])
                .contains { $0.identifier == peripheral.identifier }
        }
        Log.ble.notice("device.disconnected uuid=\(peripheral.identifier.uuidString, privacy: .public) systemConnected=\(stillSystemConnected, privacy: .public)")
        connectedPeripherals.removeValue(forKey: peripheral.identifier)

        // 系统级连接通常还在（iPhone 对本机是 Connected），只是我们这一侧被回收了。
        // 立刻重新接管，避免 RSSI 出现空档 —— 空档超过 noSignalTimeout 会误判「离开」并锁屏。
        // 节流 2s，防止「连上就被踢」时打转。
        let now = Date().timeIntervalSince1970
        if now - lastReconnectAttemptAt >= 2 {
            lastReconnectAttemptAt = now
            adoptConnectedPeripherals()
        }
    }
}

extension BLEScanner: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard error == nil else { return }
        handleDiscovery(uuid: peripheral.identifier, name: peripheral.name, rssi: RSSI.intValue)
    }
}
