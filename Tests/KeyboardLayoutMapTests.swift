import XCTest
@testable import MacBleUnlock

/// `KeyboardLayoutMap` 负责把密码字符翻成「虚拟键码 + 修饰键」。
///
/// 这是锁屏解锁能否成功的**关键路径**：以前用 `keyboardSetUnicodeString` 注入，
/// 锁屏的安全输入框直接不吃 —— 实测三次注入，`authd` 里连一条认证尝试都没有。
final class KeyboardLayoutMapTests: XCTestCase {
    func testBuildsATableForTheCurrentLayout() {
        let map = KeyboardLayoutMap()
        XCTAssertGreaterThan(map.count, 80, "一个真实键盘布局至少能打出 80+ 个字符")
    }

    /// 全量往返：每个条目用同一套参数反查，必须还原成它对应的字符。
    /// 任何参数错位（修饰键没左移 8 位、charset 长度写错）都会在这里现形。
    func testEveryEntryRoundTrips() {
        let map = KeyboardLayoutMap()
        var checked = 0
        for (character, entry) in map.entries {
            XCTAssertEqual(map.character(for: entry), character, "键码 \(entry.keyCode) 反查不符")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 80)
    }

    func testMapsDigits() {
        let map = KeyboardLayoutMap()
        for digit in "0123456789" {
            XCTAssertNotNil(map.entry(for: digit), "数字 \(digit) 在任何常见布局里都该能直接或按 Shift 敲出来")
        }
    }

    func testShiftProducesUpperCase() {
        let map = KeyboardLayoutMap()
        // 同一个物理键上的大小写必须落在同一个键码、只有修饰键不同。
        guard let lower = map.entry(for: "a"), let upper = map.entry(for: "A") else {
            return XCTFail("当前布局应能打出 a 和 A")
        }
        XCTAssertEqual(lower.keyCode, upper.keyCode)
        XCTAssertEqual(lower.flags, [])
        XCTAssertEqual(upper.flags, .maskShift)
    }

    func testUnknownCharacterHasNoEntry() {
        let map = KeyboardLayoutMap()
        // 布局里打不出来的字符必须返回 nil —— 调用方据此退回 unicode 注入。
        XCTAssertNil(map.entry(for: "\u{1F600}"))
    }
}
