# HANDOFF — Clipboard Manager

交接文档，供新会话/新 agent 接手。

## 项目概览

macOS 剪贴板管理器：本地优先、零网络权限、键盘流。Swift + SwiftUI + AppKit，零第三方依赖。

- 仓库：https://github.com/BaaKoo9/clipboard-manager（private，gh 已登录 BaaKoo9）
- 当前版本：v1.0.2（tag + Release 已发布，DMG 已上传）
- 工作区：`/Users/huxiaolong/Documents/project/llm/clipboard-manager`
- 安装版：`/Applications/Clipboard Manager.app`（自签名证书签名，重装不丢系统权限）
- 用户语言：中文。**用户当前处于 caveman 模式**（回复要极简中文，直到用户说"正常模式"）

## 已完成功能（v1.0.2）

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

- `Sources/ClipboardManagerCore/`：模型、SQLite 存储（手写 SQLite3）、ClipboardMonitor（0.08s 轮询）、HotKeyService（CGEventTap 主通道 + NSEvent global monitor 辅助，Carbon 已移除）、PasteService（定向注入）、AppSettings、DebugLog
- `Sources/ClipboardManager/UI/`：SnapshotBarView（底部面板）、SettingsView、AboutView、ToastWindowController（队列侧边窗）、BottomPanelController、PanelWindow（canBecomeKey 关键）、ScreenHelper、KeyCodeMapper
- 粘贴注入链路：写回剪贴板 → 关闭面板 → deactivate → 获取前台 pid（面板场景用呼出前记忆的 targetPID）→ activateApp → 0.12s → 系统级 ⌘V 注入
- 日志：`~/Library/Application Support/ClipboardManager/debug.log`（权限状态、热键命中/去重、注入 pid/app、入队/出队内容、屏幕选择）

## 测试

`./scripts/run-tests.sh`（即 `swift run CoreTests`）— 25 断言全过：存储/去重/搜索/置顶保护/清空/文本·图片·文件·RTF 回填/热键注册/旧库迁移/10000 条性能。

## 构建与发布

```bash
./scripts/build-app.sh    # 生成 dist/Clipboard Manager.app（证书签名）
./scripts/make-dmg.sh     # 生成 dist/Clipboard-Manager.dmg（自动清理 dist 内 .app，只留 DMG）
./scripts/run-tests.sh    # 测试
```

发布：`git tag -a vX.Y.Z -m "..." && git push --tags && gh release create vX.Y.Z dist/Clipboard-Manager.dmg --title ... --notes ...`

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
- 面板数据内存缓存、入队零等待（进一步降延迟）
- 深色模式细节打磨

## Suggested Skills

- `caveman`：用户当前沟通模式，回复必须极简中文
- `coding-standards`：Swift 代码规范
- `diagnose`：遇到 bug 先读 debug.log 定位
- `github:github`：仓库 / Release / tag 操作
- `tdd`：新增核心逻辑时先补测试
