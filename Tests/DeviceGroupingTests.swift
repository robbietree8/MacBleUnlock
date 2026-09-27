import XCTest
@testable import MacBleUnlock

/// `DeviceGrouping` 把同一台设备的多个 uuid 在菜单里合成一行。
///
/// 症状：设备子菜单里同一台设备出现两行。实测日志（`device.list`）里，
/// 同一台车钥匙 / 共享单车会以两个 uuid、相差 1dBm 的 RSSI 同时存在：
///
/// ```
/// [7C761E5C… AVATRKEYTK505028 -88dBm]  [764651F9… AVATRKEYTK505028 -89dBm]
/// ```
///
/// 这里只钉展示层的合并规则；监听与重绑仍然走原始 uuid 列表（`DeviceIdentityTests` 覆盖）。
final class DeviceGroupingTests: XCTestCase {
    private func sample(_ name: String?, rssi: Int, uuid: UUID = UUID()) -> DeviceSample {
        DeviceSample(uuid: uuid, name: name, rssi: rssi, seenAt: 0)
    }

    func testSameNameBecomesOneRowKeepingStrongestRSSI() {
        let first = UUID()
        let second = UUID()
        let groups = DeviceGrouping.groups(from: [
            sample("AVATRKEYTK505028", rssi: -89, uuid: second),
            sample("AVATRKEYTK505028", rssi: -88, uuid: first),
        ])

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].representative.uuid, first, "代表样本取 RSSI 更强的那条")
        XCTAssertEqual(groups[0].representative.rssi, -88)
        XCTAssertEqual(groups[0].memberCount, 2)
        XCTAssertEqual(groups[0].id, "AVATRKEYTK505028")
    }

    func testDifferentNamesStaySeparate() {
        let groups = DeviceGrouping.groups(from: [
            sample("iPhone R", rssi: -50),
            sample("iPad", rssi: -60),
        ])

        XCTAssertEqual(groups.map(\.id), ["iPhone R", "iPad"], "按 RSSI 从强到弱排")
        XCTAssertEqual(groups.map(\.memberCount), [1, 1])
    }

    func testNamelessSamplesDoNotMergeWithEachOther() {
        // 没有名字的广播包之间无法判断是不是同一台设备，各占一行。
        let a = UUID()
        let b = UUID()
        let groups = DeviceGrouping.groups(from: [
            sample(nil, rssi: -70, uuid: a),
            sample(nil, rssi: -75, uuid: b),
        ])

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].id, a.uuidString)
        XCTAssertEqual(groups[1].id, b.uuidString)
        XCTAssertTrue(groups.allSatisfy { $0.name.isEmpty })
    }

    func testEmptyNameDoesNotMergeWithNamed() {
        let groups = DeviceGrouping.groups(from: [
            sample("", rssi: -70),
            sample("iPhone R", rssi: -50),
        ])

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].id, "iPhone R")
    }

    func testEmptyInput() {
        XCTAssertTrue(DeviceGrouping.groups(from: []).isEmpty)
    }
}