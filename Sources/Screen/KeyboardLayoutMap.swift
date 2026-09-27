import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// 把密码字符映射成「虚拟键码 + 修饰键」，按当前键盘布局现场建表。
///
/// 为什么不能只靠 `keyboardSetUnicodeString`：锁屏界面的密码框（`SecurityAgent` / `loginwindow`
/// 里的安全输入框）不吃 unicode 字符串注入。实测在真实锁屏下注入三次密码，`authd` /
/// `SecurityAgent` 里**连一条认证尝试都没有**：
///
/// ```
/// 06:57:23 unlock.trigger attempt=1 state=true session=true frontmost=com.apple.loginwindow
/// 06:57:33 unlock.failed after 3 attempts
/// $ log show --start … --predicate 'process == "authd" OR eventMessage CONTAINS "Authentication"'
/// （只有无关的 mdmclient 授权记录）
/// ```
///
/// 所以：能查到键码的字符发真实按键事件（每个键一个 keyDown + keyUp，带修饰键），
/// 查不到的（当前布局打不出来的字符）再退回 unicode 注入。
struct KeyboardLayoutMap {
    struct Entry: Equatable {
        var keyCode: CGKeyCode
        var flags: CGEventFlags
        /// Carbon 约定的修饰键状态（建表时用的那一份，测试要拿它反查）。
        var carbonModifiers: UInt32
    }

    private var table: [Character: Entry] = [:]

    init() {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return }

        let layoutData = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        // 覆盖到 shift+option 组合，够用于密码里常见的符号；顺序保证无修饰键优先。
        let modifierStates: [(CGEventFlags, UInt32)] = [
            ([], 0),
            (.maskShift, UInt32(shiftKey)),
            (.maskAlternate, UInt32(optionKey)),
            ([.maskShift, .maskAlternate], UInt32(shiftKey | optionKey)),
        ]

        layoutData.withUnsafeBytes { buffer in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return }
            for keyCode in 0..<128 {
                for (flags, carbonModifiers) in modifierStates {
                    guard let character = Self.translate(layout, keyCode: keyCode, carbonModifiers: carbonModifiers),
                          table[character] == nil
                    else { continue }
                    table[character] = Entry(
                        keyCode: CGKeyCode(keyCode),
                        flags: flags,
                        carbonModifiers: carbonModifiers
                    )
                }
            }
        }
    }

    func entry(for character: Character) -> Entry? { table[character] }

    var count: Int { table.count }

    /// 建表结果全量可见（测试用：逐条反查，验证「键码 + 修饰键 → 字符」自洽）。
    var entries: [Character: Entry] { table }

    /// 用建表时的同一套参数再翻一次。测试拿它做往返校验。
    func character(for entry: Entry) -> Character? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        return layoutData.withUnsafeBytes { buffer in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }
            return Self.translate(layout, keyCode: Int(entry.keyCode), carbonModifiers: entry.carbonModifiers)
        }
    }

    private static func translate(
        _ layout: UnsafePointer<UCKeyboardLayout>,
        keyCode: Int,
        carbonModifiers: UInt32
    ) -> Character? {
        var deadKeys: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = UCKeyTranslate(
            layout,
            UInt16(keyCode),
            UInt16(kUCKeyActionDown),
            // Carbon 约定：修饰键状态在高字节。
            carbonModifiers >> 8,
            UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysBit),
            &deadKeys,
            characters.count,
            &length,
            &characters
        )
        guard status == noErr, length == 1, let scalar = UnicodeScalar(characters[0]) else { return nil }
        return Character(scalar)
    }
}
