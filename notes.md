# 开发笔记

面向要改这个仓库的人。README 只讲怎么用；这里记录**为什么**这么做，以及每条结论背后的实测证据。
结论都是在本机（macOS 27.0 / Xcode 27 / Swift 6.4）上跑出来的，换系统版本要重新验证。

## 代码结构

```
Sources/
  MacBleUnlockApp.swift      菜单栏场景 + 启动/退出
  AppState.swift             根状态：设置、事件接线、菜单动作、菜单快照
  MenuView.swift             菜单
  Proximity/
    BLEScanner.swift         两条路径的 BLE 发现
    ProximityEngine.swift    纯逻辑状态机（中值滤波 / 滞回 / 延迟 / 超时）
    DeviceIdentity.swift     UUID 记忆与唯一同名重绑
  Screen/
    ScreenStateMonitor.swift 锁屏 / 屏保 / 睡眠状态
    ScreenLocker.swift       锁屏（SACLockScreenImmediate，回退 Ctrl-Cmd-Q）
    DisplayPower.swift       PreventUserIdleDisplaySleep 断言与唤醒
    UnlockTrigger.swift      密码注入
    LockEvidence.swift       锁屏判定的三方投票（纯函数，可单测）
    KeychainPassword.swift   密码的钥匙串存取
  System/
    Log.swift  LoginItem.swift  Permissions.swift
```

## RSSI 是负数，负号不能丢

原设计里的样本过滤条件写的是 `rssi <= 0` 就丢弃。**这条会把所有真实样本全部丢掉** ——
CoreBluetooth 报的 RSSI 是负的 dBm，实测值 `-96 / -86 / -93 / -53 / -50 / -44`。
真按那个条件写，App 会永久停在「未检测到」。

现在的判据是 `ProximityEngine.isValidRSSI`：`rssi < 0 && rssi >= -127`。
排除了 `0` 和正值（不是有效测距）、`127`（CoreBluetooth 的「RSSI 不可用」哨兵）和
低于 -127（物理上不可能）。

## 为什么不用 PAM：SIP 调查

原计划装一个 `auth sufficient` 的 PAM 模块到 `/etc/pam.d/screensaver`：
锁屏认证时模块向 App 查询「设备是否在附近」，在附近就放行 —— **不需要存储密码**。
这条路在本机走不通，因为 `/etc/pam.d` 被 SIP 保护。

以 uid=0 实测：

```
/etc/hosts                     RDWR-OK
/etc/pam.d/screensaver         RDWR-BLOCKED
/etc/pam.d/sudo_local          RDWR-BLOCKED
/etc/pam.d/login               RDWR-BLOCKED
touch /etc/pam.d/mbu_probe     Operation not permitted
csrutil status                 System Integrity Protection status: enabled.
csrutil authenticated-root     Authenticated Root status: enabled
```

整个目录都在 SIP 的静态路径表里：不能创建新文件，也不能修改已有文件。
文件本身没有 `restricted` 标志、没有 ACL、没有 xattr —— 权限位看着是 644，实际写不了。
容易被误导的地方正是这里：`ls -l` 显示 `-rw-r--r-- root wheel`，看起来 root 随便写。

机制判断本身没错：`loginwindow` 确实引用 `/etc/pam.d/screensaver`
（`strings` 可见 `Doing scan of /etc/pam.d/screensaver`），**只是可写性假设不成立**。

PAM 模块当时已经写完并编译通过（universal，含对端代码签名校验、任何一步失败返回
`PAM_IGNORE` 保证密码通道永远可用），也装进了 `/usr/local`；唯独差 pam.d 那一步写不进去，
于是整条路线作废，改成注入密码。要复活它需要不关 SIP 的替代通道：

- **SecurityAgent 授权插件**：`/var/db/auth.db` 可写（root），
  `system.login.screensaver` 是 `k-of-n=1` 规则，且已指向一个第三方插件
  已经指向一个第三方授权插件。往规则里加一个自己的机制即可；
  机制返回非 Allow 时自动落回密码 UI，fail-safe 性质与 `PAM_IGNORE` 等价。
  不需要存密码，但得新写一个 ObjC bundle 并改 authdb。
- **关闭 SIP**（`csrutil disable`，需进 Recovery 重启）：之后原 PAM 方案可用，
  代价是全系统级的安全降级。

## 没有解锁 API

`login.framework`（dyld 共享缓存内，`nm` 读不到，用 `dyld_info -exports`）共 274 个导出符号，
名字含 `unlock` 的 **0 个**：

```
_SACLockScreenImmediate                 ← 我们在用
_SACLockScreenWhenBroughtOnConsole
_SACAssertScreenLockViaTouchIDBlocked   ← 只能「阻止」指纹解锁，没有反向的
ALL exports containing 'unlock'  →  >>> NONE <<<
```

`dlsym` 逐个探测 `SACUnlockScreen` / `SACUnlockImmediate` / `SACSetScreenLocked` 等候选名
也全部 absent。公开 API 同样没有 —— 这就是为什么必须注入密码。

## BLE 设备发现：两条路径缺一不可

`BLEScanner` 同时使用 `scanForPeripherals` 和 `retrieveConnectedPeripherals(withServices:)`。
第二条是主用例的关键：**iPhone 一旦与 Mac 建立 BLE 连接，就不再发送可被扫描到的广播包**。

实测：`system_profiler SPBluetoothDataType` 显示 iPhone 处于 Connected、RSSI -48，
而同一时间 45s 的 `scanForPeripherals` 结果里有 13 个设备、**完全看不到 iPhone**。

两个坑：

- `retrieveConnectedPeripherals(withServices: [])` 传空数组**不会返回任何东西**，
  必须给出具体服务 UUID。实测能取出已连接 iPhone 的是
  `180A`（Device Information）/ `180F` / `1805` / `9FA480E0-…`（Apple Continuity）。
- 连接被回收后，设备往往**仍在广播**（`system_profiler` 会把它列为 Not Connected 但仍报
  RSSI）。这时 `scanForPeripherals` 继续供样本，`presence` 正确地保持 true ——
  不要看到「Not Connected」就以为该判定离开。

设备身份用 `CBPeripheral.identifier` 加广播名（不做 MAC 解析：macOS 27 上
`/Library/Preferences/com.apple.Bluetooth.plist` 已无缓存表、`/Library/Bluetooth/*.db` 为 640）。
UUID 轮换时只有在**恰好一个**候选的广播名与记录名相同时才自动重绑；
同名设备多于一个就要求手动重选 —— 宁可麻烦也不能误绑到同名设备。

### 连接受限与接管循环

iPhone 侧大约每 68s 会把我们这一侧的连接回收一次。`didDisconnectPeripheral` 里立刻尝试
重新接管（节流 2s，防止「连上就被踢」打转），另外每秒跑一次接管扫描兜底。
实测断连到重新接管有数秒空档，远小于 `noSignalTimeout`（30s）和 15s 的设备列表过期时间，
不会误判「离开」而锁屏。

断开时会记一行 `systemConnected=`：

- `true` —— 系统级连接还在，空档是我们重新接管的速度问题；
- `false` —— iPhone 侧真的断了，只能等系统恢复。

## SwiftUI 菜单的两个坑

### 1. 观察链断了 → 菜单永久冻结

`BLEScanner` 必须是 `@Observable`。它曾经是个普通 class 嵌在 `@Observable` 的 `AppState` 里，
而 SwiftUI 只跟踪 `@Observable` 类型的属性。`AppState.statusText` 开头是
`guard scanner.bluetoothAvailable else { return … }` —— 首次渲染时蓝牙状态还没就绪，
直接提前返回，**没有读取任何被观察的属性**，视图再也不会失效，菜单就永久冻结在
「蓝牙不可用」。症状看起来像 BLE 坏了，其实是界面问题。

`Tests/BLEScannerObservabilityTests.swift` 钉住了这条：去掉 `@Observable` 会挂 2 个用例。

### 2. 观察太频繁 → 子菜单闪烁

修完第 1 条，菜单不再冻在旧值上，却换来悬停「设备」子菜单时**一直在闪**。

根因：菜单直接观察实时值。`scanner.devices` 每个设备每次广播都写一次、`smoothedRSSI`
每次采样都会变，实测原始写入率约 **15 次/秒**。每次失效 SwiftUI 都把 NSMenu 重建一遍，
而重建会把用户正悬停的子菜单一起拆掉。

修法是把菜单和实时数据解耦成一份快照：

- `menuStatusText` / `menuDevices` / `menuBluetoothAvailable`；
- **赋值前先比较**：`@Observable` 每次 `set` 都会通知，写同样的值等于白白重建一次菜单；
- 最多 1 秒一更；
- **菜单显示期间完全冻结**：监听 `NSMenu.didBeginTrackingNotification` /
  `didEndTrackingNotification`，深度 > 0 就跳过刷新。用计数而不是布尔，因为 AppKit
  的子菜单可能再发一对；另带 2 分钟安全超时，防止漏收通知后永久冻住。

实测：原始写入 ~15 次/秒 → 快照写入 菜单关闭时 ≤1.4 次/秒、菜单显示时 **0 次/秒**。
（这两个通知在本机实测确实会发：`NSMenu` + `cancelTracking` 的探针打出了
`DID_BEGIN_TRACKING` / `DID_END_TRACKING`。）

**因此 `MenuView` 里只能读快照、设置项和很少变的状态。**
任何时候直接读 `scanner.xxx` 或 `smoothedRSSI` 都会把闪烁带回来。

## 保持唤醒断言的唯一收敛点

`PreventUserIdleDisplaySleep` 断言严格镜像 `keepAwakeEnabled && presence`，
并且**只在** `AppState.syncEngineState()` 里收敛一次。

不能把它散落在各个事件分支里：`.departed` / `.lost` 只有在 `presence` 从 `true`
跳变到 `false` 时才会触发，而换设备（`selectDevice`）和 UUID 重绑
（`resolveMonitoredDevice`）会直接把 `presence` 归零 —— 这类路径不经过事件分支，
旧写法漏掉 release 后断言就**永久泄漏**，Mac 再也不会自动休眠。
收敛到 `syncEngineState()` 之后，任何改变 presence 的路径都在 1s 内收敛到正确状态。

同理 `lockNow()` 里不要手工 release —— 1s 后会被下一个 tick 重新 hold，属于自相矛盾。

实测两个方向都正常（用倒置阈值逼出一次 arrive→depart 循环，并临时关掉 autoLock 避免锁屏）：

```
keepAwake.off id=36394   ← departed 时释放
event=departed
keepAwake.on  id=36395   ← 再次 arrived 时重新持有
```

## 构建与签名

### 签名身份必须固定

TCC 授权（蓝牙、辅助功能）绑定在代码签名身份上，换身份就要重新授权。
`scripts/make-signing-cert.sh` 幂等，已存在直接退出。

实现上和「用 openssl 生成证书再导入」的常见写法有几处差异，都是实测逼出来的：

- PKCS#12 **必须用非空口令**。空口令会被 Security.framework 拒绝：
  `SecKeychainItemImport: MAC verification failed during PKCS12 import`。
- 不需要 `security set-key-partition-list`：`security import -T /usr/bin/codesign`
  已经足够让 codesign 非交互取用私钥。
- 不要用 `-A`：私钥 ACL 只授予 `/usr/bin/codesign` 与 `/usr/bin/security`，
  这是能通过验证的最小授权。
- 自签名证书必须 `add-trusted-cert -r trustRoot -p codeSign`，否则
  `find-identity -v` 看不到它（会显示 `CSSMERR_TP_NOT_TRUSTED`）。

### hardened runtime 只在 Release 开

公证（notarytool）强制要求 hardened runtime。但 Debug **必须**关掉：
Xcode 16+ 的 Debug 会把代码放进单独的 `MacBleUnlock.debug.dylib`，
而自签名证书没有 Team ID，库校验无法判定「同团队」，dyld 直接拒绝加载它 ——
测试宿主会崩在启动阶段（`Test crashed with signal abrt before establishing connection`）。
Release 是单二进制，没有可校验的外部库，不受影响。

实测 hardened runtime **不会**妨碍 dlopen 苹果自己的框架（库校验只针对非 Apple 签名的库）：

```
$ codesign -dvvv /tmp/hrprobe | grep flags
CodeDirectory v=20500 … flags=0x10000(runtime)
$ /tmp/hrprobe
dlopen OK, SACLockScreenImmediate=0x1991b9b3c
```

### get-task-allow 只在 Debug

Release 用 `CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO`，否则会注入
`com.apple.security.get-task-allow`，允许 `task_for_pid` 附加到发布产物。

## 测试

### 单测宿主不启动后台机制

单测宿主就是这个 App，`applicationDidFinishLaunching` 会被调用。所以 `AppDelegate`
里用 `XCTestConfigurationFilePath` 判断是否在跑测试，是就直接 return ——
否则一次 `xcodebuild test` 会启动 BLE 扫描，设备一「离开」就可能把用户的屏幕锁上。
日志里会看到 `app.launch test host, background machinery not started`。

### 锁屏投票的三方规则

`LockEvidence.evaluate` 是决定要不要注入密码的**唯一**闸门，要求三个信号里至少两票同意：
分布式通知维护的锁屏状态、`CGSessionCopyCurrentDictionary` 的 `CGSSessionScreenIsLocked`、
前台进程是否属于 `loginwindow` / `SecurityAgent` / `ScreenSaver.Engine` / `screensaver`。

方向是不对称的：**漏判只是不解锁（安全），误判会把密码打进前台应用（不可接受）**。
`Tests/LockEvidenceTests.swift` 把 8 种组合都钉住了，包括「只有前台是锁屏 UI」不算通过。

## 未验证项

- **自动解锁端到端**没有在真机上跑通：需要给 App 授予辅助功能权限，并且要有一次真实的锁屏。
  已单独验证的部分：三信号投票规则（单测）、Keychain 往返、`SACLockScreenImmediate`
  可解析、密码注入的 `CGEvent` 序列。
- **菜单点击类交互**（各项设置的持久化、开机自启的勾选与回滚）没有实际点击验证过，
  只有代码级与日志级检查。
- 只在 macOS 27.0 上验证过。上面所有依赖系统行为的结论都需要在其它版本上重新确认。
