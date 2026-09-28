# MacBleUnlock

用 iPhone 当「在场信标」的 macOS 菜单栏应用：**iPhone 远离自动锁屏，靠近自动解锁。**

## 系统要求

- macOS 14.0 或更高（实测环境：macOS 27.0 / Xcode 27 / Swift 6.4）
- 一台已与本机蓝牙配对的 iPhone
- 从源码构建还需要 Xcode 和 `xcodegen`

## 行为

| 场景 | 结果 |
| --- | --- |
| 平滑 RSSI < 远离阈值（默认 -80）持续 5s | 锁屏 |
| 5s 内回到阈值内 | 不锁 |
| 完全失去广播 30s | 判定离开并锁屏 |
| 锁屏后 平滑 RSSI ≥ 靠近阈值（默认 -60） | 3s 内自动解锁 |
| 菜单「立即锁定」 | 锁屏；必须等设备**先离开再靠近**才会自动解锁 |
| 设备在附近 | 持有 `PreventUserIdleDisplaySleep`，屏幕不会因空闲熄灭（连带系统也不会空闲睡眠）|
| 设备不在附近 / App 未运行 / 未设置密码 | 锁屏仍能用密码正常解锁 |

## 安装

```bash
bash scripts/make-signing-cert.sh          # 只需跑一次
xcodegen generate
xcodebuild -project MacBleUnlock.xcodeproj -scheme MacBleUnlock -configuration Release build
ditto ~/Library/Developer/Xcode/DerivedData/MacBleUnlock-*/Build/Products/Release/MacBleUnlock.app \
      /Applications/MacBleUnlock.app
open -a /Applications/MacBleUnlock.app
```

签名身份必须固定 —— TCC 授权（蓝牙、辅助功能）绑定在代码签名身份上，换身份就要重新授权。
`scripts/make-signing-cert.sh` 是幂等的，已存在就直接退出。

单测：`xcodebuild -project MacBleUnlock.xcodeproj -scheme MacBleUnlock test`

## 首次使用

1. 点菜单栏图标 → **设备** → 选中你的 iPhone
2. 系统弹出蓝牙授权 → 允许
3. 菜单 → **辅助功能权限** → 在系统设置里打开 MacBleUnlock 的开关
4. 菜单 → **设置登录密码…** 输入登录密码

第 3 步不做，自动解锁不会生效（其余功能正常）。第 4 步不做，只是不自动解锁，其余功能同样正常。

## 菜单

| 菜单项 | 说明 |
| --- | --- |
| 状态行 | `iPhone · -53 dBm · 附近` / `· 已离开` / `· 未检测到` |
| **设备** | 发现到的 BLE 设备及其实时 RSSI，选中一项即开始监听。同名设备合成一行（同一台设备常有两个 BLE 地址）|
| 靠近时解锁 | 解锁阈值：关闭 / -50 / -60 / -70 / -80 |
| 远离时锁定 | 锁屏阈值：关闭 / -70 / -80 / -90 |
| 离开判定延迟 | 3 / 5 / 10 / 30 秒 |
| 无信号超时 | 15 / 30 / 60 / 120 秒 |
| 靠近时保持屏幕不休眠 | 设备在附近时抑制屏幕空闲熄灭 |
| 靠近时唤醒屏幕 | 解锁前先点亮屏幕 |
| 开机自启 | 登录项 |
| 辅助功能权限 | 显示状态；未授予时点击去申请 |
| 设置 / 更新 / 清除登录密码 | 密码只存本机钥匙串 |
| 立即锁定 | 手动锁屏；之后必须「先离开再靠近」才会自动解锁 |
| 打开日志 | 把日志过滤条件复制到剪贴板并打开控制台 |

## 自动解锁是怎么工作的

macOS 没有解锁 API，所以 App 的做法是**替你输入一次登录密码**：

1. 设备靠近且屏幕处于锁定状态时触发；
2. 先用三个独立信号投票确认「现在确实在锁屏界面」—— 锁屏通知状态、
   `CGSessionScreenIsLocked`、前台进程是否为 `loginwindow` / `SecurityAgent` / 屏保。
   至少两票同意才继续；
3. 用 `CGEvent` 注入密码和回车，随后 3s 内轮询锁屏状态，仍锁定则最多重试 3 次。

### 为什么必须设置登录密码

因为 macOS **只会锁屏，不会解锁**。`login.framework` 共 274 个导出符号，
名字里含 `unlock` 的 **0 个**，只有 `SACLockScreenImmediate` 这类锁屏函数；公开 API 同样没有。
锁屏的密码框只认登录密码，没有别的钥匙。

本来有一条不需要密码的路：装一个 PAM 模块到 `/etc/pam.d/screensaver`，
设备靠近时直接放行认证。但 `/etc/pam.d` 被 SIP 保护，root 也写不了，装不上（详见 notes.md）。

所以密码是必需的，但用途被限制得很窄：**只在投票确认处于锁屏界面之后**，
注入到锁屏的密码框里。它存在钥匙串（`kSecClassGenericPassword`），不落盘、不进日志，
菜单里可随时清除；未设置时直接跳过，不会用空密码去试探。

### 已知风险

只要 iPhone 在附近，任何人敲一下键盘就能解锁（其实 App 会自动完成）。
这是所有基于靠近的解锁方案的固有性质。

## 设置项

存在 `UserDefaults`（domain `com.robbietree.MacBleUnlock`）：

`monitoredDeviceUUID`、`monitoredDeviceName`、`unlockRSSI`、`lockRSSI`、`lockDelay`、
`noSignalTimeout`、`keepAwake`、`wakeDisplay`、`autoUnlock`、`autoLock`。

日志：

```bash
log stream --predicate 'subsystem == "com.robbietree.MacBleUnlock"' --level debug
```

## 故障排查

**状态栏或菜单显示「蓝牙不可用」/ 停在旧值。**
先看日志里的权威状态：

```bash
log show --predicate 'subsystem == "com.robbietree.MacBleUnlock"' --last 10m | grep 'state='
```

正常只会看到 `state=已开启 available=true`。若日志正常而菜单不对，属于界面刷新问题，见 notes.md。

启动时还会打一行 `config unlock=… lock=… delay=…`，记录实际生效的配置 ——
菜单设置和实际行为不一致时看它。

**蓝牙被关了 / 权限被拒。** 状态栏会写明「蓝牙：蓝牙已关闭」或「蓝牙：无蓝牙权限」。
后者去「系统设置 › 隐私与安全性 › 蓝牙」重新打开；
`tccutil reset Bluetooth com.robbietree.MacBleUnlock` 可以清掉拒绝记录，下次启动重新弹框。

**RSSI 停住不动。** 观察接管循环：

```bash
log stream --predicate 'subsystem == "com.robbietree.MacBleUnlock"' --level debug 2>&1 \
  | grep -E 'device.disconnected|device.adopt|sample rssi'
```

正常是 `device.disconnected` 后几秒内出现 `device.adopt`。若一直只有 disconnected，
说明系统级连接也没了 —— 检查 `system_profiler SPBluetoothDataType` 里 iPhone 是否还是 Connected。

**自动解锁没反应。** 依次确认辅助功能权限是否授予、是否设置了登录密码。
日志会写明原因：`unlock.skip no accessibility permission`、`unlock.skip no stored password`、
或 `unlock.abort votes=… `（投票未通过时会附带三个信号的实际取值）。

日志还会给出注入结果：`unlock.type chars=14 mapped=14 unicodeFallback=0`。
`unicodeFallback` 不为 0 说明有字符在当前键盘布局（输入法）里敲不出来，那部分只能退回
unicode 注入 —— 这条退路在锁屏上**未经验证**，别指望它能解锁。换个能打出这些字符的
输入法（比如英文键盘）即可。

解锁过程分三步，日志里各对应一行：`unlock.wake`（显示器醒 + 界面稳定）→
`unlock.trigger`（三方投票通过）→ `unlock.type`（注入）。缺哪一行就是哪一步没过。

**辅助功能权限：系统设置里明明开着，菜单却写「未授予」。**

TCC 的授权是绑在**代码签名身份**上的。换过证书（比如从自签名换成 Developer ID）之后，
系统设置里那一行还在、还开着，但它记的是旧身份，新二进制判定为未授权。日志里能直接看出来：

```bash
log show --predicate 'subsystem == "com.robbietree.MacBleUnlock"' --last 10m | grep auth.accessibility
# auth.accessibility trusted=false cdhash=… team=… path=/Applications/MacBleUnlock.app
```

修法：清掉旧记录，再重新授权（这一步只能人来点，TCC 没有命令行授予）：

```bash
tccutil reset Accessibility com.robbietree.MacBleUnlock
```

然后点菜单里的「辅助功能权限：未授予（点击申请）」→ 在系统设置里打开 MacBleUnlock 的开关。
授权后菜单 1 秒内变成「已授予」，不用重启 App（日志会打出 `trusted=true`）。

**设备列表里同一台设备出现两行。**

同一台设备常常有两个 BLE 地址（identity 地址 + 可解析私有地址），菜单以前会显示两行。
现在菜单按名字合成一行，看原始 uuid 列表和合并结果：

```bash
log show --predicate 'subsystem == "com.robbietree.MacBleUnlock"' --last 5m | grep device.list
# device.list reason=add count=26 groups=25 [uuid 名字 -49dBm] [uuid 名字 -51dBm] …
```

**登录密码读不出来 / App 卡在启动阶段。**

钥匙串条目同样按签名身份授权，换证书后旧条目属于旧身份。钥匙串调用现在全部在后台线程
（历史上它曾把主线程卡死在系统授权框上：BLE 不启动、菜单不动），读不出来时菜单会写
「设置登录密码…（旧条目不可读）」并多出「删除旧钥匙串条目」。重设一次密码即可 ——
同证书重新构建不会再弹框（访问控制绑的是指定要求，不是 cdhash）。

**Mac 睡下去了，回来时解锁不了。**

先说物理限制：**用户态 App 无法把 Mac 从系统睡眠里唤醒** —— 唤醒源只有真实硬件输入
（敲键盘 / 动鼠标 / 开盖 / 按电源键）和计划唤醒（`pmset schedule`，需 root）。
`IOPMAssertionDeclareUserActivity` 只能阻止空闲睡眠、点亮屏幕，对已经睡下去的系统无效。

但「靠近时保持屏幕不休眠」开着时，**设备在附近期间系统不会空闲睡眠**：我们的断言让显示器不灭，
而 powerd 在显示器亮着时会自己持有 `Prevent sleep while display is on`（`pmset -g assertions`
里能看到）。真正的睡眠只剩三种：带着手机离开（断言释放）→ 系统空闲睡眠；手动点睡眠；合盖 ——
后两种任何 App 都拦不住。

如果你是自己手动唤醒的（开盖 / 按键），App 会在唤醒后重试：登录界面要好几秒才收键，
所以现在最多试 5 次（约 16s），日志看 `unlock.trigger attempt=N` 与 `unlock.failed after 5 attempts`。

## 分发

### 自签名构建只能自己用

直接把本机自签名（身份 `MacBleUnlock Dev`）的 `.app` 发给别人，对方打不开：

```
$ spctl -a -t exec -vv /Applications/MacBleUnlock.app
/Applications/MacBleUnlock.app: rejected
origin=MacBleUnlock Dev
```

自签名证书、`TeamIdentifier not set`、无公证，Gatekeeper 直接拦。对方只能手动放行：
右键 → 打开，或 系统设置 → 隐私与安全性 → 「仍要打开」，或 `xattr -d com.apple.quarantine`。
而且签名身份只存在于你自己机器的钥匙串里 —— **不要把自己的签名私钥给别人**。

零成本做法：**让对方自己从源码构建**（命令同「安装」）。这样 TCC 授权和钥匙串条目
干净地属于他自己，也不用改任何签名配置。需要 Xcode + Swift 6 工具链。

### 要「下载即用」：Developer ID + 公证

需要付费的 Apple Developer Program（99 USD/年）。下面两件事各做一次：

```bash
# 1. 签一张 Developer ID Application 证书
#    Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application
#    只有 Account Holder（个人）或 Account Holder / Admin（组织）能签；
#    免费 Apple ID 只有 Apple Development，做不了公证。

# 2. 存公证凭据（密码是 appleid.apple.com 上的 App 专用密码）
xcrun notarytool store-credentials mbu-notary \
  --apple-id <Apple ID> --team-id 55L6785UNH --password <App 专用密码>
```

之后每次发布就一条命令：

```bash
bash scripts/release.sh
```

注意：只签名不公证仍然会被拦 —— `spctl` 给的是 `rejected / source=Unnotarized Developer ID`，
所以公证不是可选项。

它会：Release 构建 → 校验签名（身份 / hardened runtime / TeamIdentifier / 无 get-task-allow）
→ `notarytool submit --wait` → `stapler staple` → 打包 `dist/MacBleUnlock-<版本>.zip` 与 `.dmg`
→ **把 zip 解压、把 dmg 挂载，各自再过一遍 `spctl`**，确认用户拿到手的那个文件确实是
`accepted / source=Notarized Developer ID`。产物直接传 GitHub Releases。

`bash scripts/release.sh --skip-notarize` 只构建 + 校验 + 打包（验证签名配置用，产物不能分发）。

换签名的副作用：TCC 授权（蓝牙、辅助功能）和钥匙串里的登录密码条目都绑定签名身份，
从 `MacBleUnlock Dev` 换成 Developer ID 后你自己机器上要重新授权一次；
此后只要 bundle id 和证书不变，用户升级不会掉授权。

### 上不了 Mac App Store

上架强制 App Sandbox，而本 App 靠辅助功能权限 + `CGEvent` 注入密码和私有 API
`SACLockScreenImmediate`，沙盒下做不出来。只能官网 / GitHub Releases 直传。
公证只查签名与恶意软件，不做 App Store 那种私有 API 扫描 —— 但 Apple 随时可能改掉
`SACLockScreenImmediate`，届时自动回落到合成 Ctrl-Cmd-Q。

### 每个人拿到后都必须自己做的事

| 步骤 | 说明 |
| --- | --- |
| 蓝牙授权 | 首次启动弹框，点允许 |
| 辅助功能授权 | 手动在系统设置里勾选。**没有它自动解锁不工作** |
| 菜单 → 设备 | 选中自己的 iPhone |
| 设置登录密码 | 只有要用自动解锁时才需要 |

## 兼容性

- 部署目标 macOS 14.0，但只在 **macOS 27.0 + Xcode 27 + Swift 6.4** 上验证过。
- 用到的私有 API 与系统行为（`SACLockScreenImmediate`、Apple Continuity 服务 UUID、
  `CGSSessionScreenIsLocked`、`NSMenu` 跟踪通知）都没有在其它系统版本上验证。
- 需要 iPhone 已与本机蓝牙配对。

## 许可

[MIT](LICENSE)。

一个提醒：本 App 会替你输入登录密码，而自签名构建本来就无法预编译分发
（Gatekeeper 会拦）。所以**请按上面的步骤自己从源码编译**，
不要接受来路不明的预编译包。
