# HANDOFF — Clipboard Manager

交接文档，供新会话/新 agent 接手。

## 项目概览

macOS 剪贴板管理器：本地优先、零网络权限、键盘流。Swift + SwiftUI + AppKit，零第三方依赖。

- 仓库：https://github.com/BaaKoo9/clipboard-manager（private，gh 已登录 BaaKoo9）
- 当前版本：v1.0.3（**已构建安装到 /Applications，尚未打 tag / 发 Release，等用户测评**）
- 工作区：`/Users/huxiaolong/Documents/project/llm/clipboard-manager`
- 安装版：`/Applications/Clipboard Manager.app`（自签名证书签名，重装不丢系统权限）
- 用户语言：中文（正常模式，v1.0.3 起不再是 caveman 模式）

## v1.0.3 变更（本轮）

### 快捷键重启后失效（两个独立根因）

**根因 A（主因，用户实际遇到的）：启动顺序。** `HotKeyService.shared` 是懒加载单例，
事件 tap 在首次访问它时才创建，而 `registerHotKeys()` 原先排在 `setupPanel()` 之后——
后者要构建近全屏宽、带 `.ultraThinMaterial` 的 SwiftUI `NSHostingController`，冷启动时
连同 SwiftUI 框架加载要一两秒。**这段时间快捷键完全无响应**，用户启动后立刻按 ⌥⌘V 就没反应；
等去试入队/出队时已经热好了，所以那两个"正常"，看起来像是呼出键单独坏了。

修复：`registerHotKeys()` 提到 `applicationDidFinishLaunching` 最前面，面板预构建改为
`DispatchQueue.main.async` 延后；`togglePanel()` 里补 `setupPanel()` 兜底极早期按键。
新增 `LaunchClock` 埋点，日志会打印：

```
启动：快捷键就绪，耗时 85ms
启动：面板预构建完成，耗时 303ms
```

热启动实测 85ms vs 303ms；冷启动差距更大。**排查同类问题先看这两个数字。**

**根因 B：TCC 缓存滞后。** `AXIsProcessTrusted()` 返回 true 时 `CGEvent.tapCreate` 仍会失败
（历史日志里 `CGEventTap 创建失败` 29 次，含"权限已 true 但创建失败"）。旧代码失败后无重试，
且只在权限**变化**时才重装，于是该进程终身没有主通道。

修复（`HotKeyService`）：
- tap 移到独立 `EventTapThread` 的 runloop（主线程卡顿不再导致系统判定超时而禁用 tap）
- 回调处理 `tapDisabledByTimeout` / `tapDisabledByUserInput`，就地 `tapEnable` 恢复
- 创建失败 → 退避重试（0.4s 步进，上限 3s），直到成功
- 看护定时器 2s 一次 `ensureTapHealthy()`：tap 缺失或被禁用则重建；健康时不写日志
- 新增 `reinitialize()` + `status`；状态栏右键菜单有「快捷键状态：…」和「重新初始化快捷键」
- 监听 `NSWorkspace.didWakeNotification`，休眠唤醒后自动重建

**诊断埋点**：热键日志现在带来源和启动耗时，例如
`热键命中 tag=1 来源=tap 启动后2310ms`。`来源` 是 `tap`（主通道）还是 `monitor`（辅助通道）。
若用户报"呼不出来"，先分清是**热键没触发**（日志无记录）还是**面板没显示**
（有 `热键命中` 但随后是 `面板首显失败，强制置前重试`）。

**面板显隐竞争**：`BottomPanelController` 加了 `visibilityToken`。此前淡出动画未结束时再次呼出，
旧的 `completionHandler` 会把刚显示的面板 `orderOut` 掉，表现为随机"呼不出来"。

### 性能

| 项 | 改动 |
|---|---|
| `DebugLog` | 主线程同步 open/seek/write/close → 后台串行队列 + 常驻 FileHandle + `@autoclosure` 延迟插值 + 2MB 自动截断 |
| 面板粘贴 | 固定 `0.2s + 0.12s = 320ms` → `PasteService.activateAndPaste`，8ms 轮询目标 App `isActive` + 30ms 焦点沉淀，实测约 40–70ms |
| 出队粘贴 | 固定 `0.12s + 0.12s = 240ms` → 同上；并在 `deactivate` 前先取 targetPID |
| 入队复制 | 剪贴板变更轮询 50ms → 6ms |
| 面板呼出 | 去掉近全屏宽毛玻璃窗口的位移动画（逐帧重排视图树），只留透明度过渡，0.15s → 0.09s |
| 历史查询 | `fetchAll` 全表 → `kind` / `LIMIT 300` 下推 SQL；新增 `idx_items_kind_updated`；开 WAL |
| 去重判断 | `exists(hash:)` 从取全列改为 `SELECT 1` |
| 搜索 | 每次按键触发全表 LIKE → 90ms 防抖 |
| 图片捕获 | NSImage 解码 + PNG 重编码 + SHA256 从主线程移到后台队列 |
| 其他 | 去掉 `@Published` 之外多余的 `objectWillChange.send()`、`panelDidOpen` 的重复 refresh |

### 图标

`Tools/GenerateIcon.swift` 重写：深墨→暗青渐变底 + 青色辉光 + **三张错位堆叠卡片**（薄荷→青渐变前卡 + 内容行）。
刻意避开"剪贴板 + 夹子"造型（Paste / Maccy / CleanClip / Pastebot 都在用），改以本应用差异化功能"粘贴队列"为主体。
各尺寸独立渲染而非缩放大图，16px 下仍可辨认。状态栏图标同步换成 `rectangle.stack`。

## 已完成功能（v1.0.2 起）

- 剪贴板监听：文本/链接/图片/文件/RTF（图片优先识别，兼容 PixPin 等截图工具）
- 快照面板：屏幕底部横向卡片、自适应宽度、分类筛选（全部/文本/链接/图片/文件）、搜索高亮
- 单击卡片 = 粘贴；⌘+点击 = 入队；悬停显示 ⊕ 入队按钮
- 全局快捷键（可录制自定义）：呼出 `⌥⌘V`、入队复制 `⌥⌘E`（模拟 ⌘C + 自动入队）、出队粘贴 `⌥⌘D`
- 队列侧边窗：常驻显示全部队列、可滚动、X 按钮 = 关提示 + 清队列、跟随首次入队屏幕
- 设置窗口：居中玻璃窗（快捷键录制、开机自启、历史上限 100–3000、自动粘贴、忽略 App、清空历史）
- 关于窗口：X 关闭、版本信息、GitHub 链接
- 置顶、去重、SQLite 容量清理、开机自启、多屏跟随（鼠标屏 + 前台 App 窗口屏兜底）
- 固定自签名证书签名：重装不丢失辅助功能/输入监控权限

## 关键实现

- `Sources/ClipboardManagerCore/`：模型、SQLite 存储（手写 SQLite3）、ClipboardMonitor（0.08s 轮询）、HotKeyService（CGEventTap 主通道跑在独立线程 + NSEvent global monitor 辅助，Carbon 已移除）、PasteService（定向注入 + `activateAndPaste` 激活探测）、AppSettings、DebugLog（异步）
- `Sources/ClipboardManager/UI/`：SnapshotBarView（底部面板）、SettingsView、AboutView、ToastWindowController（队列侧边窗）、BottomPanelController、PanelWindow（canBecomeKey 关键）、ScreenHelper、KeyCodeMapper
- 粘贴注入链路：写回剪贴板 → 无动画关闭面板 → deactivate → 目标 pid（面板场景用呼出前记忆的 targetPID）→ activate → 轮询 `isActive` → 30ms 后系统级 ⌘V 注入
- 日志：`~/Library/Application Support/ClipboardManager/debug.log`（权限状态、热键命中/去重、注入 pid/app、入队/出队内容、屏幕选择）

## 测试

`./scripts/run-tests.sh`（即 `swift run CoreTests`）— 25 断言全过：存储/去重/搜索/置顶保护/清空/文本·图片·文件·RTF 回填/热键注册/旧库迁移/10000 条性能。

## 构建与发布

```bash
./scripts/build-app.sh    # 生成 dist/Clipboard Manager.app（证书签名）
./scripts/make-pkg.sh     # 生成 dist/Clipboard-Manager-X.Y.Z.pkg（推荐分发格式）
./scripts/make-dmg.sh     # 生成 dist/Clipboard-Manager.dmg（含 /Applications 软链接）
./scripts/run-tests.sh    # 测试
```

**分发格式**：优先用 `.pkg`——双击后系统安装器自动装到 `/Applications` 并启动，无需拖拽。
`scripts/pkg-scripts/preinstall` 先退出运行中的实例，`postinstall` 去掉 quarantine 属性并以
当前登录用户身份启动 App。没有 Developer ID Installer 证书，包未签名，首次需右键 →「打开」。
包内会有两个 `._` AppleDouble 条目（`com.apple.provenance` 属性无法移除导致），不影响安装。

发布：`git tag -a vX.Y.Z -m "..." && git push --tags && gh release create vX.Y.Z dist/Clipboard-Manager-X.Y.Z.pkg dist/Clipboard-Manager.dmg --title ... --notes ...`

## 注意事项 / 已知边界

- 权限：需要「辅助功能」+「输入监控」两个权限（分步请求）。新用户首次授权后可用；无权限时出队/粘贴只写回剪贴板并 Toast 提示。
- 出队语义 = 粘贴：有辅助功能权限即注入，不依赖"自动粘贴"开关（v1.0.1 修复）。
- 签名：自签名证书 "Clipboard Manager Dev" + 专用钥匙串 `clipboard-dev.keychain-db`（构建脚本自动解锁，免弹框）。**p12 文件在 `/tmp/clipboard-dev.p12`，密码勿写入文档**。
- 代码编辑警告：本会话多次因 perl 替换转义问题弄坏文件（@State 被吃、$0 被吃、中文注释报错、拼接截断）。后续 agent 改 Swift 文件优先用 `apply_patch`，避免大段 perl/head-tail 拼接；若必须用，先备份。
- 队列窗口多屏：创建时锁定屏幕，本次队列会话不跳屏。
- Spotlight 搜索结果：dist 只保留 DMG，避免重复 app。

## 路线图（未做）

- iCloud 私有数据库同步
- 更多类型识别（颜色、代码块）
- 面板超过 300 条时的分页/懒加载（当前直接截断到 300）
- 深色模式细节打磨

## Suggested Skills

- `coding-standards`：Swift 代码规范
- `diagnose`：遇到 bug 先读 debug.log 定位
- `github:github`：仓库 / Release / tag 操作
- `tdd`：新增核心逻辑时先补测试