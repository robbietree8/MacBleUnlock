import Foundation

/// 靠近判定的可调参数。默认值与 plan 的验收口径一致。
struct ProximityConfig: Equatable, Sendable {
    /// 平滑 RSSI ≥ 该值 → 判定「靠近」。
    var unlockRSSI: Int = -60
    /// 平滑 RSSI < 该值 → 开始计时「远离」。
    var lockRSSI: Int = -80
    /// 平滑 RSSI 持续低于 lockRSSI 多久后判定离开。
    var lockDelay: TimeInterval = 5
    /// 完全没有广播多久后判定离开。
    var noSignalTimeout: TimeInterval = 30
    /// 中值滤波窗口长度（奇数最优）。
    var medianWindow: Int = 5
}

enum ProximityEvent: Equatable, Sendable {
    /// 设备进入 unlockRSSI 范围。
    case arrived
    /// 设备远离并已超过 lockDelay。
    case departed
    /// 设备停止广播并已超过 noSignalTimeout。
    case lost
}

/// 纯逻辑的靠近判定引擎：不持有任何系统资源，全部时间由调用方注入，便于确定性单测。
///
/// 状态机（presence 为唯一权威状态）：
///   - presence == false：平滑 RSSI ≥ unlockRSSI → 转为 true 并发出 `.arrived`，
///     同时清空滤波窗口，避免旧的远端样本把中值拖低。
///   - presence == true：平滑 RSSI < lockRSSI → 记录 awaySince 并开始计时；
///     计时未满前平滑 RSSI 回到 ≥ lockRSSI 则取消；计时满 → 转为 false 并发出 `.departed`。
///   - presence == true 且距最后一次有效样本超过 noSignalTimeout → 转为 false 并发出 `.lost`。
struct ProximityEngine {
    /// CoreBluetooth 报告的 RSSI 是**负数** dBm（典型 -30…-100）。
    ///
    /// 注意：plan 里写的判据是 `rssi <= 0`，那会把所有真实样本全部丢掉 ——
    /// 真实 RSSI 永远 ≤ 0。这里按同一个意图（丢弃哨兵与物理上不可能的值）收紧为：
    /// 必须严格小于 0（排除 0 和正值），且不低于 -127 dBm。
    /// 127 是 CoreBluetooth 的「RSSI 不可用」哨兵，已被 `rssi < 0` 排除。
    static func isValidRSSI(_ rssi: Int) -> Bool {
        rssi < 0 && rssi >= -127
    }

    private(set) var config: ProximityConfig
    private(set) var presence = false
    private(set) var smoothedRSSI: Int?
    private(set) var lastSampleAt: TimeInterval?

    /// 平滑 RSSI 首次跌破 lockRSSI 的时刻；回到阈值内会被清空。
    private(set) var awaySince: TimeInterval?

    private var window: [Int] = []

    init(config: ProximityConfig = ProximityConfig()) {
        self.config = config
    }

    /// 运行期修改阈值（用户在菜单里改设置）。不重置 presence，避免改一下设置就误锁。
    mutating func update(config newConfig: ProximityConfig) {
        config = newConfig
        trimWindow()
        smoothedRSSI = window.isEmpty ? nil : median(window)
    }

    /// 换绑设备：丢弃全部历史。
    mutating func reset() {
        presence = false
        smoothedRSSI = nil
        lastSampleAt = nil
        window.removeAll()
        awaySince = nil
    }

    /// 一个 RSSI 样本。非法样本（0、负数、CoreBluetooth 的 127 哨兵）直接丢弃。
    @discardableResult
    mutating func sample(rssi: Int, at t: TimeInterval) -> [ProximityEvent] {
        guard Self.isValidRSSI(rssi) else { return [] }

        lastSampleAt = t
        window.append(rssi)
        trimWindow()
        smoothedRSSI = median(window)

        guard presence else {
            guard let smoothed = smoothedRSSI, smoothed >= config.unlockRSSI else { return [] }
            presence = true
            awaySince = nil
            // 清空窗口，让新一次「靠近」从中性状态重新开始。
            window = [rssi]
            smoothedRSSI = rssi
            return [.arrived]
        }

        guard let smoothed = smoothedRSSI, smoothed < config.lockRSSI else {
            // 回到阈值内：取消离开计时（滞回）。
            awaySince = nil
            return []
        }

        if awaySince == nil { awaySince = t }
        guard let since = awaySince, t - since >= config.lockDelay else { return [] }

        presence = false
        awaySince = nil
        window.removeAll()
        return [.departed]
    }

    /// 时间推进。处理两条纯时间规则：离开计时到期、无信号超时。
    /// 离开计时也要在这里检查 —— 设备可能刚好在跌破 lockRSSI 后就不再广播，
    /// 那种情况下应当按 lockDelay 锁屏，而不是干等 noSignalTimeout。
    @discardableResult
    mutating func tick(at t: TimeInterval) -> [ProximityEvent] {
        guard presence else { return [] }

        if let since = awaySince, t - since >= config.lockDelay {
            presence = false
            awaySince = nil
            window.removeAll()
            return [.departed]
        }

        if let last = lastSampleAt, t - last > config.noSignalTimeout {
            presence = false
            awaySince = nil
            window.removeAll()
            smoothedRSSI = nil
            return [.lost]
        }

        return []
    }

    private mutating func trimWindow() {
        let limit = max(1, config.medianWindow)
        if window.count > limit { window.removeFirst(window.count - limit) }
    }

    /// 上中位数：窗口为奇数时取正中，偶数时取偏大的一侧。
    private func median(_ values: [Int]) -> Int {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
