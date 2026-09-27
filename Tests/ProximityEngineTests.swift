import XCTest
@testable import MacBleUnlock

final class ProximityEngineTests: XCTestCase {

    // MARK: - 中值滤波

    func testMedianFilterSuppressesSingleOutlier() {
        var engine = makeEngine(medianWindow: 5)
        var t: TimeInterval = 0

        for _ in 0..<3 { _ = engine.sample(rssi: -50, at: t); t += 1 }
        XCTAssertTrue(engine.presence)

        // 稳定在 -70：处在 unlockRSSI(-60) 与 lockRSSI(-80) 之间的滞回带，不该有任何事件。
        for _ in 0..<5 {
            XCTAssertEqual(engine.sample(rssi: -70, at: t), [])
            t += 1
        }
        XCTAssertEqual(engine.smoothedRSSI, -70)

        // 单个离群点被中值滤掉。
        XCTAssertEqual(engine.sample(rssi: -95, at: t), [])
        t += 1
        XCTAssertEqual(engine.smoothedRSSI, -70, "单个离群点不应改变中值")

        // 第二个离群点仍在窗口 5 的容忍范围内。
        XCTAssertEqual(engine.sample(rssi: -95, at: t), [])
        t += 1
        XCTAssertEqual(engine.smoothedRSSI, -70, "两个离群点仍不应改变中值")

        // 第三个才翻转中值 —— 并且此时只是开始计时，还没到 lockDelay。
        XCTAssertEqual(engine.sample(rssi: -95, at: t), [])
        XCTAssertEqual(engine.smoothedRSSI, -95)
        XCTAssertEqual(engine.awaySince, t, "跌破 lockRSSI 的样本即为计时起点")
        XCTAssertTrue(engine.presence, "刚到 lockDelay 起点，不应立即判定离开")
    }

    // MARK: - 滞回

    func testHysteresisBandProducesNoEvents() {
        var engine = makeEngine()
        var t: TimeInterval = 0

        // 一直待在 (-80, -60) 区间内：永远不判定「靠近」。
        for rssi in [-70, -75, -79, -72, -78, -70] {
            XCTAssertEqual(engine.sample(rssi: rssi, at: t), [])
            t += 1
        }
        XCTAssertFalse(engine.presence)

        // 需要足够多的样本把中值推过 -60。
        XCTAssertEqual(engine.sample(rssi: -55, at: t), []); t += 1
        XCTAssertEqual(engine.sample(rssi: -55, at: t), []); t += 1
        XCTAssertEqual(engine.sample(rssi: -55, at: t), [.arrived]); t += 1
        XCTAssertTrue(engine.presence)

        // 回到滞回带内：不判定离开。
        for _ in 0..<10 {
            XCTAssertEqual(engine.sample(rssi: -70, at: t), [])
            t += 1
        }
        XCTAssertTrue(engine.presence, "滞回带内抖动不应判定离开")
    }

    // MARK: - 离开延迟

    func testLockDelayCancelledWhenSignalReturns() {
        var engine = makeEngine(lockDelay: 5)
        var t: TimeInterval = 0

        _ = engine.sample(rssi: -55, at: t); t += 1
        XCTAssertTrue(engine.presence)

        // 掉到 lockRSSI 以下，开始计时。
        let since = feedUntilAway(&engine, rssi: -95, t: &t)

        // lockDelay 内回到阈值内 → 取消计时。
        XCTAssertEqual(engine.sample(rssi: -55, at: since + 2), [])
        XCTAssertNil(engine.awaySince, "回到阈值内应取消离开计时")
        XCTAssertTrue(engine.presence, "lockDelay 内回来不应判定离开")

        // 取消之后继续待在附近，也不该再触发。
        t = since + 3
        for _ in 0..<10 {
            XCTAssertEqual(engine.sample(rssi: -55, at: t), [])
            t += 1
        }
        XCTAssertTrue(engine.presence, "持续待在附近不应触发任何事件")
    }

    func testDepartsAfterLockDelay() {
        var engine = makeEngine(lockDelay: 5)
        var t: TimeInterval = 0

        _ = engine.sample(rssi: -55, at: t); t += 1
        XCTAssertTrue(engine.presence)

        let since = feedUntilAway(&engine, rssi: -95, t: &t)

        XCTAssertEqual(engine.sample(rssi: -95, at: since + 4.9), [], "未满 lockDelay 不应判定离开")
        XCTAssertEqual(engine.sample(rssi: -95, at: since + 5), [.departed])
        XCTAssertFalse(engine.presence)
        XCTAssertNil(engine.awaySince)
    }

    // MARK: - 无信号超时

    func testNoSignalTimeoutEmitsLost() {
        var engine = makeEngine(noSignalTimeout: 30)
        var t: TimeInterval = 0

        for _ in 0..<3 { _ = engine.sample(rssi: -55, at: t); t += 1 }
        XCTAssertTrue(engine.presence)
        let lastSample = t - 1

        XCTAssertEqual(engine.tick(at: lastSample + 20), [], "未到超时不应判定离开")
        XCTAssertEqual(engine.tick(at: lastSample + 30), [], "恰好等于超时不判定（必须严格超过）")
        XCTAssertEqual(engine.tick(at: lastSample + 30.5), [.lost])
        XCTAssertFalse(engine.presence)
        XCTAssertNil(engine.smoothedRSSI, "判定离开后不再显示 RSSI")
    }

    /// 设备跌破 lockRSSI 后就停止广播：应当按 lockDelay 锁，而不是干等 noSignalTimeout。
    func testTickExpiresLockDelayWhileSilent() {
        var engine = makeEngine(lockDelay: 5, noSignalTimeout: 30)
        var t: TimeInterval = 0

        _ = engine.sample(rssi: -55, at: t); t += 1
        XCTAssertTrue(engine.presence)

        let since = feedUntilAway(&engine, rssi: -95, t: &t)
        // 此后设备不再广播（不再调用 sample）。

        XCTAssertEqual(engine.tick(at: since + 1), [])
        XCTAssertEqual(engine.tick(at: since + 5), [.departed])
        XCTAssertFalse(engine.presence)
    }

    // MARK: - 非法样本

    func testInvalidSamplesIgnored() {
        var engine = makeEngine()

        XCTAssertEqual(engine.sample(rssi: 0, at: 0), [])
        XCTAssertEqual(engine.sample(rssi: 127, at: 1), [], "127 是 CoreBluetooth 的 RSSI 不可用哨兵")
        XCTAssertEqual(engine.sample(rssi: 5, at: 2), [], "正值不是有效 RSSI")
        XCTAssertEqual(engine.sample(rssi: -200, at: 3), [], "超出物理可能范围")

        XCTAssertNil(engine.lastSampleAt)
        XCTAssertNil(engine.smoothedRSSI)
        XCTAssertFalse(engine.presence)
        XCTAssertEqual(engine.tick(at: 10_000), [], "从未有过有效样本时不应判定离开")
    }

    // MARK: - arrived 清空滤波窗口

    func testArrivedClearsFilterWindow() {
        var engine = makeEngine(medianWindow: 5)

        // -79 贴着 lockRSSI，但低于 unlockRSSI，因此不会触发 arrived。
        _ = engine.sample(rssi: -79, at: 0)
        _ = engine.sample(rssi: -79, at: 1)
        XCTAssertFalse(engine.presence)
        XCTAssertEqual(engine.smoothedRSSI, -79)

        // 第 4 个样本让中值翻到 -59（≥ -60）→ arrived，到达样本本身是 -55。
        _ = engine.sample(rssi: -59, at: 2)
        XCTAssertEqual(engine.sample(rssi: -55, at: 3), [.arrived])

        // 窗口被清空，只剩到达样本。若未清空，此刻中值会是 -59（[-79,-79,-59,-55] 的中值）。
        XCTAssertEqual(engine.smoothedRSSI, -55, "arrived 之后应从中性窗口重新开始")
    }

    // MARK: - 参数热更新

    func testUpdateConfigKeepsPresence() {
        var engine = makeEngine(unlockRSSI: -60, lockRSSI: -80)
        XCTAssertEqual(engine.sample(rssi: -55, at: 0), [.arrived])

        // 用户把 unlockRSSI 调到 -70：当前状态不该被重置，否则会重复触发 arrived。
        engine.update(config: ProximityConfig(unlockRSSI: -70, lockRSSI: -80, lockDelay: 5, noSignalTimeout: 30, medianWindow: 5))
        XCTAssertTrue(engine.presence)
        XCTAssertEqual(engine.sample(rssi: -55, at: 1), [])
    }

    /// 持续注入 rssi，直到中值滤波结果跌破 lockRSSI，返回离开计时的起点时刻。
    /// 中值需要足够多的样本才会翻转，所以测试里不能硬编码「第几个样本生效」。
    private func feedUntilAway(
        _ engine: inout ProximityEngine,
        rssi: Int,
        t: inout TimeInterval,
        limit: Int = 20
    ) -> TimeInterval {
        for _ in 0..<limit {
            _ = engine.sample(rssi: rssi, at: t)
            t += 1
            if let since = engine.awaySince { return since }
        }
        XCTFail("注入 \(limit) 个 \(rssi) 样本后中值仍未跌破 lockRSSI")
        return t
    }

    private func makeEngine(
        unlockRSSI: Int = -60,
        lockRSSI: Int = -80,
        lockDelay: TimeInterval = 5,
        noSignalTimeout: TimeInterval = 30,
        medianWindow: Int = 5
    ) -> ProximityEngine {
        ProximityEngine(config: ProximityConfig(
            unlockRSSI: unlockRSSI,
            lockRSSI: lockRSSI,
            lockDelay: lockDelay,
            noSignalTimeout: noSignalTimeout,
            medianWindow: medianWindow
        ))
    }
}

final class DeviceIdentityTests: XCTestCase {

    func testResolvesStoredUUIDExactly() {
        let defaults = makeDefaults()
        let stored = UUID()
        DeviceIdentity.store(MonitoredDevice(uuid: stored, name: "iPhone"), in: defaults)

        let other = UUID()
        let resolved = DeviceIdentity.resolve(
            candidates: [MonitoredDevice(uuid: other, name: "别的设备"),
                         MonitoredDevice(uuid: stored, name: "iPhone")],
            in: defaults
        )
        XCTAssertEqual(resolved, stored)
    }

    func testRemapsWhenExactlyOneCandidateMatchesName() {
        let defaults = makeDefaults()
        let old = UUID()
        DeviceIdentity.store(MonitoredDevice(uuid: old, name: "iPhone"), in: defaults)

        let new = UUID()
        let resolved = DeviceIdentity.resolve(
            candidates: [MonitoredDevice(uuid: new, name: "iPhone")],
            in: defaults
        )
        XCTAssertEqual(resolved, new)
        XCTAssertEqual(DeviceIdentity.storedUUID(in: defaults), new, "重映射后应写回新 UUID")
    }

    func testRefusesAmbiguousName() {
        let defaults = makeDefaults()
        let old = UUID()
        DeviceIdentity.store(MonitoredDevice(uuid: old, name: "iPhone"), in: defaults)

        let a = UUID()
        let b = UUID()
        let resolved = DeviceIdentity.resolve(
            candidates: [MonitoredDevice(uuid: a, name: "iPhone"),
                         MonitoredDevice(uuid: b, name: "iPhone")],
            in: defaults
        )
        XCTAssertNil(resolved, "同名设备多于一个时绝不自动重绑")
        XCTAssertEqual(DeviceIdentity.storedUUID(in: defaults), old, "拒绝重绑时不应改写记录")
    }

    func testReturnsNilWhenNothingRecorded() {
        let defaults = makeDefaults()
        let resolved = DeviceIdentity.resolve(
            candidates: [MonitoredDevice(uuid: UUID(), name: "iPhone")],
            in: defaults
        )
        XCTAssertNil(resolved)
    }

    func testReturnsNilWhenNameDiffers() {
        let defaults = makeDefaults()
        DeviceIdentity.store(MonitoredDevice(uuid: UUID(), name: "iPhone"), in: defaults)
        let resolved = DeviceIdentity.resolve(
            candidates: [MonitoredDevice(uuid: UUID(), name: "iPad")],
            in: defaults
        )
        XCTAssertNil(resolved)
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "com.robbietree.MacBleUnlockTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
