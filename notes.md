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

### 发布：Developer ID + 公证（scripts/release.sh）

Release 配置里的身份是 `Developer ID Application` + `DEVELOPMENT_TEAM`，Debug 仍然是
自签名 `MacBleUnlock Dev` —— 单测宿主必须用能加载 `MacBleUnlock.debug.dylib` 的身份。

用自签名身份跑 `release.sh --skip-notarize` 验证签名配置时，必须把 team 置空：
`MBU_TEAM_ID= bash scripts/release.sh --skip-notarize`。否则 `xcodebuild` 会带着
`DEVELOPMENT_TEAM=55L6785UNH` 去找证书，而自签名证书不属于任何 team，签名直接失败。

两个断言对「交给用户的那个文件」是真检查（实测未公证的自签名产物）：

```
$ xcrun stapler validate /tmp/x/MacBleUnlock.app
MacBleUnlock.app does not have a ticket stapled to it.   # 退出码 65
$ spctl -a -t exec -vv /tmp/x/MacBleUnlock.app
/tmp/x/MacBleUnlock.app: rejected
```

所以 `release.sh` 把 zip 解压、把 dmg 挂载之后逐个再跑一遍这两个命令，而不是只信
构建目录里的那个 `.app`。注意 `stapler validate` 会去 Apple 取 `DeveloperIDTicket`
记录（`-v` 里能看到下载动作），不是纯离线检查。

### Xcode 不会自动加 --timestamp

实测：Release 用 Developer ID 签名、但没设 `OTHER_CODE_SIGN_FLAGS: "--timestamp"` 时，
产物的签名里**没有**安全时间戳：

```
$ codesign -dvvv MacBleUnlock.app | grep -E "Authority|Timestamp|Signed Time"
Authority=Developer ID Application: Zhonggao Wang (55L6785UNH)
Timestamp=Sep 27, 2026 at 17:42:54        # 加上 --timestamp 之后才有
Signed Time=Sep 27, 2026 at 17:42:36      # 没加的时候只有这一行
```

公证强制要求安全时间戳，所以它写在 Release 配置里（签名时联网向 Apple 的时间戳服务取，
离线签发会失败）。`release.sh` 把它当作签名的硬断言，缺了就中止，不会白等一次公证。

签名正确但不公证，Gatekeeper 的判词和自签名不一样 —— 能看出差在哪一步：

```
$ spctl -a -t exec -vv MacBleUnlock.app
MacBleUnlock.app: rejected
source=Unnotarized Developer ID
origin=Developer ID Application: Zhonggao Wang (55L6785UNH)   # 退出码 3
```

### notarytool 要显式给 --keychain

本机实测：`store-credentials` 报「Success. Credentials validated.」，紧接着
`notarytool history --keychain-profile mbu-notary` 却说找不到那条条目；
带上 `--keychain ~/Library/Keychains/login.keychain-db` 立刻正常。

所以 `release.sh` 总是显式传 `--keychain`（默认取 `security default-keychain -d user`，
可用 `MBU_NOTARY_KEYCHAIN` 覆盖），history / submit / log / 提示文案四个地方都一致。

### /bin/bash 3.2 会把全角字符吃进变量名

`$VAR` 后面紧跟全角字符（`）`、`，`、`」` …）时，macOS 自带 bash 3.2 会把那个字符的
字节当成变量名的一部分，`set -u` 下就报（变量名尾部会多出一个不可打印字节）：

```
scripts/release.sh: line 138: SUBMISSION<替换字符>: unbound variable
```

同一段代码在 bash 5 下不会报。中文输出紧挨变量时一律加花括号：`${SUBMISSION}）。`

### dlopen 的目标在磁盘上不存在

`/System/Library/PrivateFrameworks/login.framework/Versions/A/` 下只有
`Frameworks/ Resources/ XPCServices/ _CodeSignature/`，没有 `login` 文件 ——
二进制在 dyld 共享缓存里，`dlopen` 照常解析（见上面的探针）。所以
`codesign -dvvv` 那个路径会失败（No such file），别拿它判断私有 API 还在不在。

## 图标

`Resources/AppIcon.icns` 是生成物，由 `scripts/make-icon.swift` 用 CoreGraphics 矢量重画
（仓库里不存设计稿）：深蓝渐变圆角方块 + 白色挂锁 + 两侧信号弧。改设计就改脚本重生成。

```bash
swift scripts/make-icon.swift Resources/AppIcon.icns                          # 重新生成
MBU_ICONSET_DIR=/tmp/icon swift scripts/make-icon.swift /tmp/icon/AppIcon.icns # 留下 iconset 逐个尺寸看
```

两条实测约束：

- `iconutil` 要**完整 10 个文件**，缺一个只报 `Failed to generate ICNS.`，不说是缺哪个 ——
  `icon_16x16@2x.png` 与 `icon_32x32.png` 像素相同但必须各写一份。
- 每个尺寸都按矢量重画，而不是缩 1024 那张：16pt 下信号弧自然糊进背景，只剩挂锁轮廓读得出来。

`LSUIElement: true` 所以没有 Dock 图标，这个图标出现在访达 / 聚焦 / 权限弹框里。

## 测试

### 单测宿主不启动后台机制

单测宿主就是这个 App，`applicationDidFinishLaunching` 会被调用。所以 `AppDelegate`
里用 `XCTestConfigurationFilePath` 判断是否在跑测试，是就直接 return ——
否则一次 `xcodebuild test` 会启动 BLE 扫描，设备一「离开」就可能把用户的屏幕锁上。
日志里会看到 `app.launch test host, background machinery not started`。

（注意：单测跑在 App 进程里，日志写的是同一个 subsystem —— 用 `log show` 排查真机问题时
会看到测试制造的行，比如 `DeviceIdentityTests` 的 `device.remap.ambiguous`。）

### 设备列表按名字合并（只合并展示）

同一台设备经常以两个 `CBPeripheral.identifier` 出现：identity 地址 + 可解析私有地址。
实测日志（`device.list`）里同时存在、RSSI 只差 1dBm：

```
[7C761E5C… AVATRKEYTK505028 -88dBm]  [764651F9… AVATRKEYTK505028 -89dBm]
[58105F18… mobike -91dBm]            [EC09F3E2… mobike -92dBm]
```

菜单按 uuid 渲染，于是同一台设备占两行。`DeviceGrouping` 按**名字**合成一行（没名字的
不合并），代表样本取组内 RSSI 最强的那条，选中它就把监听绑到它的 uuid 上。

合并只作用于展示：监听的样本过滤和设备重绑仍然用原始 uuid 列表。否则「两台同名设备」
会被当成一台，人走了却不锁屏 —— 那个方向是不安全的（`DeviceIdentity.resolve` 的同名歧义
拒绝重绑也是同一个道理）。

### 钥匙串调用绝不能上主线程

实测卡死现场（`sample` 进程）：主线程停在
`AppState.refreshPasswordStatus → KeychainPassword.load → SecItemCopyMatching`，
`AppState.start()` 没跑完 —— BLE 不启动、菜单不动，看起来就是 App 卡死。
触发条件是换签名证书：旧条目属于旧身份，读它就弹系统授权框，而框没人点。

所以 `KeychainPassword` 只对外提供 async 接口，内部跑在自家串行队列上。

两个实测结论（各用一次性探针验过）：

- 旧式钥匙串的访问控制绑的是**指定要求**（team + bundle id），不是 cdhash：
  两个 cdhash 不同、证书与 bundle id 相同的二进制能互读对方创建的条目，不弹框。
  所以换证书后重设一次密码，以后重建都不再弹。
- 「数据保护钥匙串」（`kSecUseDataProtectionKeychain`）走不通：Developer ID 签名、
  无 provisioning profile 的 App 拿到 `errSecMissingEntitlement (-34018)`。

### 辅助功能授权与签名身份

TCC 行绑定代码签名身份。换证书后系统设置里那一行还在、还开着，但属于旧身份，
新二进制判定未授予。日志里带上 cdhash / team / 路径，这种情况一眼能认：

```
auth.accessibility trusted=false cdhash=… team=55L6785UNH context=launch path=/Applications/MacBleUnlock.app
```

菜单标题读的是 `AppState.accessibilityTrusted`（每秒刷新一次），**不是**直接在视图里调
`AXIsProcessTrusted()`：后者不进观察图，授权状态变了菜单也不会重建，标题会停在旧值上。
清除旧记录用 `tccutil reset Accessibility com.robbietree.MacBleUnlock`，重新授权只能手动点。

### 锁屏投票的三方规则

`LockEvidence.evaluate` 是决定要不要注入密码的**唯一**闸门，要求三个信号里至少两票同意：
分布式通知维护的锁屏状态、`CGSessionCopyCurrentDictionary` 的 `CGSSessionScreenIsLocked`、
前台进程是否属于 `loginwindow` / `SecurityAgent` / `ScreenSaver.Engine` / `screensaver`。

方向是不对称的：**漏判只是不解锁（安全），误判会把密码打进前台应用（不可接受）**。
`Tests/LockEvidenceTests.swift` 把 8 种组合都钉住了，包括「只有前台是锁屏 UI」不算通过。

### 锁屏注入：真实键码 + 先把登录界面叫醒

注入链的每一步都有日志：`unlock.wake settledMs=…` → `unlock.trigger attempt=…` →
`unlock.type chars=… mapped=… unicodeFallback=…` → `unlock.success` / `unlock.failed`。

**一、用真实键码，不用 unicode 字符串。**
按当前键盘布局现场建「字符 → 键码 + 修饰键」表（`KeyboardLayoutMap`：`UCKeyTranslate`
扫 0…127 键码 × 无 / shift / option / shift+option），逐个发真实 keyDown/keyUp；
布局打不出来的字符才退回 unicode 注入。实测 `unlock.type chars=14 mapped=14
unicodeFallback=0 mapSize=200`。

> 更正：早先版本的本节曾把「`authd` 里没有认证尝试」当作 unicode 注入无效的证据。
> 那条**站不住**：密码正确解锁时 `authd` 也不落同样的记录。真实失败原因是下面两条；
> unicode 注入在锁屏上的行为**没有单独验证过**，它现在只是布局打不出字符时的退路。

**二、显示器要醒着，判据用电源层的事实。**
`ScreenStateMonitor.displayAsleep` 原只由 `NSWorkspace.screensDidWake/Sleep` 通知维护，
进程启动时不知道当下状态 —— App 在显示器已睡时启动就一直是 false，唤醒步骤被跳过，
按键全打进黑屏（实测：`display.asleep` 通知比那次注入晚 130ms 到）。现在
`CGDisplayIsAsleep(CGMainDisplayID())` 每秒对齐一次，解锁前直接问它。

**三、登录窗口的「认证窗口」会自己关掉。**
锁屏或唤醒后约 5s，登录窗口的 idle 计时器到期就关掉认证窗口：

```
07:24:12.487 -[LWDefaultScreenLockUI handleTimeOutTimer:] | idletime hit making further …
07:24:12.490 -[LWDefaultScreenLockUI closeAuthAndReset:] | entered, resetAuthWindowLevel…
```

这之后注入的按键全部落空（实测那一轮三次尝试全废）。所以每次尝试前都：

1. `IOPMAssertionDeclareUserActivity` 唤醒显示器，轮询 `CGDisplayIsAsleep` 等它真的醒，
   再等 1s 让界面稳定（唤醒时系统会清空密码框：`loginwindow: Clearing password field for
   NSWorkspaceScreensDidWakeNotification`）；
2. 鼠标微移 2px：HID 层的用户活动，把密码框重新叫出来（锁屏不显示光标，也不用点击）；
3. 鼠标轻推之后才投票、清空残留（3 个退格）、注入。

实测三种场景都是第一次尝试成功（锁屏后重启 App 制造一次 `arrived` 迁移）：

| 场景 | 结果 |
| --- | --- |
| 刚锁屏 4s（认证窗口还开着） | `unlock.success`，≈1.4s |
| 锁屏 12s + 显示器已睡 | `unlock.wake settledMs=1065` → 成功 |
| 锁屏 14s + `caffeinate -d` 强制保持显示器唤醒 | 成功（靠鼠标轻推） |

日志只记数量不记内容。

### 系统睡眠：App 唤不醒它，但靠近时也不会睡

- 用户态 App **无法**把 Mac 从系统睡眠里唤醒：唤醒源只有真实硬件输入（键盘 / 鼠标 / 开盖 /
  电源键）与计划唤醒（`pmset schedule`，需 root）。`IOPMAssertionDeclareUserActivity` 只能
  阻止空闲睡眠、点亮屏幕，对已经睡下去的系统无效。
- 但「靠近时保持屏幕不休眠」开着时，系统本来就不会空闲睡眠：
  `pmset -g assertions` 里能看到 powerd 自己持有
  `PreventUserIdleSystemSleep named: "Powerd - Prevent sleep while display is on"`，
  而我们的 `PreventUserIdleDisplaySleep` 让显示器不灭，链条因此成立：
  设备在附近 → 显示器不灭 → powerd 阻止空闲系统睡眠。
  （实测：设备在附近期间 `pmset -g log` 没有新的 `Entering Sleep`。）
- 真正的睡眠只剩三种：带着手机离开（断言释放）、手动睡眠、合盖 —— 后两者任何 App 都拦不住。
- 唤醒之后登录界面要几秒才收键：实测系统唤醒后的前两次注入落空、第三次才成功。所以重试从
  3 次提到 5 次（约 16s），且距 `system.didWake` 20s 内的尝试额外等 1.5s。
- 另外修了一个断言泄漏：`IOPMAssertionDeclareUserActivity` 每次传 `0` 都会新建一条
  UserIsActive 断言（几分钟超时），旧代码每次解锁尝试都新建一条，`pmset -g assertions`
  里堆了两条。现在复用同一个 id。

> `unlock.success` 的判定是「投票说已经不在锁屏了」，它**分不清**是 App 注入成功还是用户自己
> 敲的密码 / 触控 ID。要看注入是否真的有效，得看「尝试次数 + 时间」：例如刚锁屏、无人操作时
> `attempt=1` 就 `success`（约 1s）才能归功于注入。

## 未验证项

- **自动解锁端到端**已验证（2026-09-28）：三种锁屏场景各跑一次都成功（见「锁屏注入」一节），
  解锁仍由 `LockEvidence` 三方投票把守。
  仍未验证：屏保状态下解锁、多显示器、以及 `unicodeFallback > 0` 的情形（当前布局打不出
  密码里的字符时退回 unicode 注入，它在锁屏上是否有效没有单独验证）。
- **菜单点击类交互**（各项设置的持久化、开机自启的勾选与回滚）没有实际点击验证过，
  只有代码级与日志级检查。
- 只在 macOS 27.0 上验证过。上面所有依赖系统行为的结论都需要在其它版本上重新确认。
