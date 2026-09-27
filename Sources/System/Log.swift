import os

/// 统一日志入口。查看：`log stream --predicate 'subsystem == "com.robbietree.MacBleUnlock"' --level debug`
enum Log {
    static let subsystem = "com.robbietree.MacBleUnlock"
    static let app = Logger(subsystem: subsystem, category: "app")
    static let ble = Logger(subsystem: subsystem, category: "ble")
    static let proximity = Logger(subsystem: subsystem, category: "proximity")
    static let screen = Logger(subsystem: subsystem, category: "screen")
}
