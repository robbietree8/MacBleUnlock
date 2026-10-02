# 菜单栏图标可选显示

## 目标与非目标

- 目标：用户可随时关闭菜单栏图标，并在隐藏状态下继续使用自动锁定/解锁；重新打开已运行的 App 可恢复图标。选择跨重启保留。
- 非目标：退出或暂停后台扫描、改变开机自启状态、增加 Dock 图标、窗口、通知或全局快捷键、重做现有菜单。

## 已确定的交互与设计

- 默认 `显示菜单栏图标 = true`，新安装和升级后无已存储键时仍显示现有图标。菜单现有设置区增加 `Toggle("显示菜单栏图标", …)`，放在「开机自启」之后。隐藏时该菜单立即消失。
- macOS 14+ 使用 SwiftUI `MenuBarExtra("MacBleUnlock", systemImage: "lock.rotation", isInserted: Binding<Bool>) { MenuView(app: app) }`，保留 `.menuBarExtraStyle(.menu)`；绑定读取 `AppState.menuBarIconVisible`，写入调用显式切换方法，不直接退出 App 或停止后台任务。
- 隐藏态完全没有 App UI：`isInserted = false` 移除菜单栏图标；`LSUIElement = true` 保持 agent 身份，既不调用 `NSApp.setActivationPolicy(.regular)`，也不产生 Dock 图标、窗口、通知或快捷键。进程、BLE 扫描、自动锁定/解锁及 keepAwake 断言照旧。
- 唯一恢复入口是**重新打开已在运行的 App**：在 Finder/Launchpad/Spotlight 双击 App，或运行 `open -a MacBleUnlock`。LaunchServices 把再次打开请求交给现有实例，由 `applicationShouldHandleReopen(_:hasVisibleWindows:) -> Bool` 把偏好置 true、重新插入图标，并调用 `NSApp.activate(ignoringOtherApps: true)`；图标是可见反馈。回调已由 App 自行处理，返回 false。隐藏态要退出，可先重新打开并从菜单选择「退出 MacBleUnlock」，或用 Activity Monitor / `pkill MacBleUnlock` 结束进程。
- 冷启动严格遵从已存偏好：false 时纯后台运行且不主动恢复图标。AppDelegate 在 `applicationDidFinishLaunching(_:)` 开始时记录 `ProcessInfo.processInfo.systemUptime`，在 `AppState.shared.start()` 完成后设置 `hasFinishedLaunching = true`；reopen 回调只有 `hasFinishedLaunching` 且距启动时间至少 1 秒时才恢复，其余回调直接返回 false。依据是 LaunchServices 可能将首次打开也转发到同一个 reopen 回调；启动就绪标志过滤启动阶段，1 秒消抖过滤紧随其后的首次打开事件。用户若刚启动就想恢复，在 1 秒后再次打开；验收时检验冷启动和真实再次打开。
- UserDefaults 键：`AppState.Key.menuBarIconVisible = "menuBarIconVisible"`。`AppState` 属性默认 `true`，`didSet` 调用现有 `persist(_:_:)`；`loadStoredSettings()` 只在 `object(forKey:) != nil` 时读取 `bool(forKey:)`，明确保存的 false 不会被默认值覆盖。初始化单例时先加载设置，确保 SwiftUI Scene 第一次构建就使用正确的 `isInserted` 值；`start()` 仍负责启动后台系统。
- 切换顺序：菜单开关通过统一方法设置 `menuBarIconVisible = false` 并持久化，SwiftUI 移除图标；后台生命周期不受影响。reopen 通过同一方法恢复 true 并持久化，随后激活 App。启动时只读取存储值，绝不调用恢复方法；测试宿主仍短路后台启动及 reopen 处理。没有激活策略或窗口操作的失败分支；若检测到状态切换失败，回退为图标可见并持久化 true，不留下已知不可恢复状态。`MenuBarExtra` 没有返回插入成功与否的 API，须用真机验收覆盖这一路径。

## 受影响文件

- `Sources/MacBleUnlockApp.swift`：`MenuBarExtra(isInserted:)` 绑定、AppDelegate 冷启动遵从偏好与启动完成防误判、reopen 恢复图标；测试宿主保护保持生效。
- `Sources/AppState.swift`：新偏好键、默认值、加载/持久化、可注入 `UserDefaults` 的内部初始化入口，以及统一切换方法；保持扫描和锁屏生命周期独立。
- `Sources/MenuView.swift`：中文开关及其写入绑定。
- **新增** `Tests/MenuBarVisibilityTests.swift`：偏好默认值、false/true 持久化及新实例恢复的纯状态测试；不启动 BLE，也不对 Scene 或 LaunchServices 做 UI 单测。
- `README.md`：隐藏、再次打开已运行 App 恢复图标、纯后台退出方式与冷启动区别。
- `project.yml`、`Resources/Info.plist`：均保持 `LSUIElement: true`，本方案**不修改**。如实施中确需调整该键，必须同步两份并重跑 XcodeGen；预计无需调整。`Sources` 和 `Tests` 由 project.yml 目录收集，新文件无需逐一登记。

## 分步实现任务

### 1. 持久化偏好并保证 Scene 初始值正确

- **文件/区域：** `Sources/AppState.swift`、`Tests/MenuBarVisibilityTests.swift`。
- **行为：** 添加键和 `menuBarIconVisible: Bool = true` 属性，沿用 `didSet { persist(menuBarIconVisible, Key.menuBarIconVisible) }`；在初始化阶段调用 `loadStoredSettings()`，使已存 false 在 SwiftUI 首次构建前生效。将 `private init()` 改为内部 `init(defaults: UserDefaults = .standard)`、保存注入的 defaults，供测试创建互不影响的状态实例；`AppState.shared` 不变。现有 `start()` 的重复加载可保留，或在确认初始化加载覆盖全部原设置后移除，但只允许一次后台启动。测试直接赋值该属性验证持久化；UI 在任务 2 中统一通过协调方法切换。
- **约束：** 仅 `object(forKey:) != nil` 时读取 Bool；不把 `@State` 或 `MenuBarExtra` 内容视图 `.task` 当作后台启动入口；测试实例不调用 `start()`。
- **验收证据：** XCTest 用独立 `UserDefaults(suiteName:)` 检查无键默认 true、保存 false 后重新构造仍为 false、再保存 true 可恢复；现有设置加载结果不变。
- **依赖：** 无。
- **工作区：** 顺序。

### 2. 图标显示和重新打开恢复入口

- **文件/区域：** `Sources/MacBleUnlockApp.swift`、`Sources/MenuView.swift`；在 `Sources/AppState.swift` 增加统一切换方法。
- **行为：** 以 `isInserted` Binding 连接菜单栏场景和 AppState；菜单开关用 `Binding(get:set:)` 的 setter 调用 `AppState.setMenuBarIconVisible(_ visible: Bool)`，该方法仅改变属性及持久化，不更改运行中的后台任务。AppDelegate 在 `applicationDidFinishLaunching(_:)` 记录 `ProcessInfo.processInfo.systemUptime`，完成 `AppState.shared.start()` 后标记已启动；不因存储 false 而恢复图标。实现 `applicationShouldHandleReopen(_:hasVisibleWindows:) -> Bool`：测试宿主、尚未完成启动、或启动后不足 1 秒时直接返回 false；其余请求在偏好为 false 时调用统一方法恢复 true，然后调用 `NSApp.activate(ignoringOtherApps: true)`，返回 false。偏好已为 true 的 reopen 保持 true 并激活；不重复启动 scanner。
- **约束：** AppState 的初始值必须在 Scene 构建前加载；隐藏模式无任何前台 UI。冷启动收到 reopen 不能误判成用户再次打开；超过消抖时段的首次打开延迟回调属于真机验收风险。已检测到插拔异常时把属性回退至 true 并持久化；不得把菜单消失解释为退出 App。测试宿主继续跳过后台启动和 reopen 操作。
- **验收证据：** 手动关闭图标、冷启动保存的隐藏模式保持纯后台、等待超过 1 秒后二次打开 App 使菜单图标恢复；锁定/解锁任务仍在进程中运行。
- **依赖：** 任务 1。
- **工作区：** 顺序。

### 3. 说明和端到端验证

- **文件/区域：** `README.md`；检查 `project.yml` 与 `Resources/Info.plist` 的一致性。
- **行为：** 更新菜单操作说明：隐藏后 App 仍运行；重新打开已运行的 App 恢复图标；结束进程可用 Activity Monitor / `pkill MacBleUnlock`，或先恢复图标再点击菜单「退出 MacBleUnlock」。明确冷启动会保留隐藏偏好，需等待超过 1 秒再次打开才能恢复。检查构建产物的 `LSUIElement` 仍为 true。
- **约束：** 如果生成的工程发生变更，按既有仓库流程管理；不要单独编辑生成的 `.xcodeproj` 作为唯一来源。
- **验收证据：** 运行下列命令并逐条完成手动检查。
- **依赖：** 任务 2。
- **工作区：** 顺序。

## 验收标准

- [ ] 新安装或升级且没有新键时，启动后菜单栏图标出现，Dock 不常驻；原菜单功能可用。
- [ ] 菜单中出现中文「显示菜单栏图标」开关，默认勾选；关闭后图标消失，进程保持运行且无 Dock 图标、窗口、通知或快捷键入口。
- [ ] 菜单图标隐藏期间，已配置设备的 BLE 监测、自动锁定/解锁及 keepAwake 断言继续工作。
- [ ] 隐藏后等待超过 1 秒，通过 Finder/Launchpad/Spotlight 再次打开已运行的 App 或执行 `open -a MacBleUnlock`，菜单栏图标重现，偏好保存为 true；重复打开不重复启动后台任务。
- [ ] 隐藏态可用 Activity Monitor 或 `pkill MacBleUnlock` 退出；也可先再次打开恢复图标，再选菜单「退出 MacBleUnlock」；显示态现有菜单退出项仍有效。
- [ ] 隐藏态结束进程后冷启动 App（含开机自启路径）仍为纯后台，启动时可能投递的 reopen 不恢复图标；启动完成且超过 1 秒后二次打开才恢复。显示态冷启动仍显示菜单栏图标。
- [ ] 检测到图标切换异常时回退为图标可见并持久化 true；常规切换后重启保留所选偏好。
- [ ] 单测涵盖 UserDefaults 无键、false、true 的加载与再次实例化；现有单测全部通过；生成工程与最终产物保留 `LSUIElement=true`。

## 测试与验证命令

```sh
xcodegen generate
xcodebuild -project MacBleUnlock.xcodeproj -scheme MacBleUnlock test
plutil -extract LSUIElement raw Resources/Info.plist
# 在所运行的 .app 包路径上再检查打包值：
plutil -extract LSUIElement raw /path/to/MacBleUnlock.app/Contents/Info.plist
```

手动：启动 → 查看菜单栏图标 → 关闭「显示菜单栏图标」→ 确认无 App UI 且自动锁定仍生效 → 等待超过 1 秒并用 Finder/Launchpad/Spotlight 双击或 `open -a MacBleUnlock` 恢复图标 → 再隐藏 → 用 Activity Monitor / `pkill MacBleUnlock` 退出 → 冷启动确认仍为纯后台 → 等待超过 1 秒再打开恢复图标 → 菜单退出。自动解锁应在已有安全测试环境和已授权设备上验证，避免验证过程中意外锁屏。

## 风险与回归点

- `LSUIElement=true` 的 agent App 再次打开时是否稳定收到 `applicationShouldHandleReopen` 要在目标 macOS 版本真机验证；冷启动和 reopen 可能共用回调。已启动标志与 1 秒忽略窗口降低误恢复风险，但特别迟到的首次打开事件仍可能误恢复；过快的真正二次打开可能被忽略，需再打开一次。若 LaunchServices 不转发回调，此唯一恢复路径无法兑现，验收不得通过。
- 隐藏态没有 UI 承载：TCC 辅助功能授权提示在尚未授权时的可见性、可操作性及锁屏操作需实测；已有授权与代码签名身份相关，隐藏菜单不应改变签名。`SMAppService.mainApp` 开机自启保持原状，登录后冷启动必须静默保持已存隐藏模式。
- 隐藏态钥匙串读取可能触发系统授权框，需验证弹窗仍可见、可操作、可取消，且未授权时不会使后台扫描或锁屏死锁；设置/更新密码仍需先恢复菜单图标。
- SwiftUI `MenuBarExtra(isInserted:)` 的插拔没有同步成功返回值；已检测的状态错误回退为可见并持久化 true，仍需在真机验证隐藏、reopen 恢复与进程继续运行。菜单只读低频状态的既有约束继续保持，避免 BLE 每秒更新导致 NSMenu 重建。

## 待决事项

无。实现方案已确定：隐藏时纯后台；已运行进程收到重新打开事件才恢复菜单栏图标；不变更 LSUIElement、开机自启或后台任务策略。
