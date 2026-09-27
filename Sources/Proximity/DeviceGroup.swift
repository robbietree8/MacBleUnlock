import Foundation

/// 菜单里的一行设备。**同名设备合成一行** —— 只影响展示。
struct DeviceGroup: Equatable, Sendable {
    /// 分组键：有名字用名字，没名字用 uuid 字符串。
    var id: String
    /// 展示用名字（没名字时为空，由菜单回退成 uuid 前缀）。
    var name: String
    /// 组里 RSSI 最强的那个样本。选中这一行时监听的就是它。
    var representative: DeviceSample
    /// 组里有多少个 uuid。
    var memberCount: Int
}

/// 把扫描到的 uuid 列表归成菜单的一行行设备。
///
/// 同一台设备经常以**两个 identifier** 出现：identity 地址 + 可解析私有地址，
/// 或者同一台设备的两条广播集。实测本机日志（`device.list`）：
///
/// ```
/// [7C761E5C… AVATRKEYTK505028 -88dBm]  [764651F9… AVATRKEYTK505028 -89dBm]
/// [58105F18… mobike -91dBm]            [EC09F3E2… mobike -92dBm]
/// ```
///
/// 名字相同、RSSI 只差 1dBm、同时存在 —— 一台车钥匙 / 一辆共享单车各占了两行。
/// 菜单按 uuid 渲染，于是用户看到的就是「重复设备」。
///
/// **只合并展示**：监听与设备重绑仍然用原始 uuid 列表（`DeviceIdentity.resolve`），
/// 否则「两台同名设备」会被当成一台，人走了却不锁屏 —— 那个方向是不安全的。
enum DeviceGrouping {
    static func groups(from samples: [DeviceSample]) -> [DeviceGroup] {
        var byKey: [String: [DeviceSample]] = [:]
        for sample in samples {
            let name = sample.name ?? ""
            byKey[name.isEmpty ? sample.uuid.uuidString : name, default: []].append(sample)
        }

        return byKey.map { key, members in
            let sorted = members.sorted {
                if $0.rssi != $1.rssi { return $0.rssi > $1.rssi }
                return $0.uuid.uuidString < $1.uuid.uuidString
            }
            return DeviceGroup(
                id: key,
                name: sorted[0].name ?? "",
                representative: sorted[0],
                memberCount: members.count
            )
        }
        .sorted {
            if $0.representative.rssi != $1.representative.rssi {
                return $0.representative.rssi > $1.representative.rssi
            }
            return $0.id < $1.id
        }
    }
}