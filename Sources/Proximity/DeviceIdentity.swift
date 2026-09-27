import Foundation

/// 被监听的设备（UUID + 广播名）。
struct MonitoredDevice: Equatable, Sendable {
    var uuid: UUID
    var name: String?
}

/// 设备身份的记忆与重匹配。
///
/// iPhone 的 `CBPeripheral.identifier` 在本机通常稳定，但重装系统 / 重置蓝牙后可能轮换。
/// 轮换后按「广播名唯一匹配」自动重绑；名字不唯一时绝不猜 —— 宁可要求用户手动重选，
/// 也不要误绑到同名设备（那会导致人走了却不锁屏）。
enum DeviceIdentity {
    static let uuidKey = "monitoredDeviceUUID"
    static let nameKey = "monitoredDeviceName"

    static func storedUUID(in defaults: UserDefaults) -> UUID? {
        guard let raw = defaults.string(forKey: uuidKey) else { return nil }
        return UUID(uuidString: raw)
    }

    static func storedName(in defaults: UserDefaults) -> String? {
        defaults.string(forKey: nameKey)
    }

    static func store(_ device: MonitoredDevice, in defaults: UserDefaults) {
        defaults.set(device.uuid.uuidString, forKey: uuidKey)
        if let name = device.name, !name.isEmpty {
            defaults.set(name, forKey: nameKey)
        } else {
            defaults.removeObject(forKey: nameKey)
        }
    }

    /// 解析出当前应当监听的设备 UUID。
    /// - 先按记录的 UUID 精确匹配。
    /// - 否则若**恰好一个**候选的广播名与记录名相同，则重映射并把新 UUID 写回。
    /// - 其余情况返回 nil，等待用户在菜单里手动选择。
    static func resolve(candidates: [MonitoredDevice], in defaults: UserDefaults) -> UUID? {
        guard let storedUUID = storedUUID(in: defaults) else { return nil }

        if candidates.contains(where: { $0.uuid == storedUUID }) { return storedUUID }

        guard let storedName = storedName(in: defaults), !storedName.isEmpty else { return nil }
        let matches = candidates.filter { $0.name == storedName }
        guard matches.count == 1, let match = matches.first else {
            if matches.count > 1 {
                Log.proximity.notice("device.remap.ambiguous name=\(storedName, privacy: .public) count=\(matches.count, privacy: .public)")
            }
            return nil
        }

        Log.proximity.notice("device.remap old=\(storedUUID.uuidString, privacy: .public) new=\(match.uuid.uuidString, privacy: .public)")
        store(match, in: defaults)
        return match.uuid
    }
}
