<p align="center">
  <img src="docs/images/icon-256.png" width="96" alt="ClipBar 图标" />
</p>

<h1 align="center">ClipBar</h1>

<p align="center">
  <strong>本地优先的 macOS 剪贴板管理器</strong><br />
  键盘流 · 高性能 · 简约 · 默认隐私
</p>

<p align="center">
  <a href="README.md">English</a>
  ·
  <a href="https://github.com/BaaKoo9/ClipBar/releases">下载</a>
  ·
  <a href="https://github.com/BaaKoo9/ClipBar/releases/latest">最新 Release</a>
</p>

---

快捷键呼出 → 方向键选择 → 回车粘贴，全程不必碰鼠标。

<p align="center">
  <img src="docs/images/panel.jpg?v=20260812" width="860" alt="ClipBar 快照条" />
</p>

## 亮点

- **快照条** — 底部横向卡片，支持类型筛选与自定义标签
- **顺序粘贴** — 入队复制、出队粘贴，侧边队列常驻
- **即时搜索** — 关键词高亮；`#标签` 快速筛选
- **本地优先** — 历史仅存本机（SQLite + 图片/RTF 缓存）
- **零第三方依赖** — 纯 Swift + SwiftUI + AppKit

<p align="center">
  <img src="docs/images/queue.jpg?v=20260812" width="720" alt="ClipBar 粘贴队列" />
</p>

## 系统要求

| | |
|---|---|
| 系统 | **macOS 14 Sonoma** 及以上（含 15 Sequoia） |
| 芯片 | Apple Silicon 与 Intel |
| 权限 | **辅助功能** + **输入监控**（全局快捷键与自动粘贴） |

## 安装

从 [Releases](https://github.com/BaaKoo9/ClipBar/releases) 下载最新包：

| 产物 | 适用场景 |
|---|---|
| **`ClipBar-x.y.z.pkg`** | 双击按系统安装器装到「应用程序」（推荐） |
| **`ClipBar-x.y.z.dmg`** | 打开后把 `ClipBar.app` 拖到 **Applications** |

### 首次打开（未公证）

当前为自签名构建，**尚未 Apple 公证**。若首次被拦截：

1. **推荐**：Finder 中 **Control-单击** ClipBar →「打开」→ 再次确认「打开」
2. 或 **系统设置 → 隐私与安全性** →「仍要打开」

随后为 ClipBar 开启：

- 辅助功能  
- 输入监控  

## 快速上手

| 操作 | 默认快捷键 |
|---|---|
| 呼出 / 收起面板 | `⌥⌘V` |
| 入队（复制选中并入队） | `⌥⌘E` |
| 出队粘贴 | `⌥⌘D` |
| 面板内选择 | `←` `→` |
| 粘贴选中项 | 回车 或 单击 |
| 面板内入队 | `⌘`+点击 或 悬停 `⊕` |

所有快捷键可在设置中自定义。

<p align="center">
  <img src="docs/images/settings.jpg?v=20260812" width="720" alt="ClipBar 设置" />
</p>

## 功能一览

- 菜单栏常驻；自动记录文本、链接、图片、文件与 RTF
- 置顶 / 收藏（不受容量清理影响）；可选「粘贴后刷新排序」
- 去重：相同内容刷新时间戳，不重复堆叠
- 标签：面板内新建、拖拽排序、编辑/删除；设置中集中管理
- 历史上限 + 可选按天保留（1–90 天，仅未置顶）
- 忽略应用、开机自启、应用内检查更新（带下载进度）
- 关于窗口：版本与项目链接

> **剪贴板内容**不会离开本机。检查更新时才会访问 GitHub Releases（含镜像下载线路）。

## 从源码构建

需 macOS 14+ 与 Xcode Command Line Tools（不必装完整 Xcode）：

```bash
./scripts/build-app.sh          # 生成 dist/ClipBar.app
./scripts/make-pkg.sh           # 生成 dist/ClipBar-x.y.z.pkg
./scripts/make-dmg.sh           # 生成 dist/ClipBar-x.y.z.dmg
./scripts/run-tests.sh          # 核心单元测试
```

## 测试

```bash
swift run CoreTests
```

覆盖：插入/读取、去重、搜索、置顶保护、清空、文本/图片/文件/RTF 回填、热键注册、旧库迁移、1 万条性能（读取 &lt;10ms、搜索 &lt;5ms）。

## 技术栈

- Swift + SwiftUI + AppKit — 无第三方 SPM 依赖
- SQLite（系统库）：串行写入，TTL + 条数上限清理
- Carbon 全局热键 + CGEventTap
- PNG 存储 + JPEG 缩略图；富文本保留 RTF

## 路线图

- [x] 剪贴板监听与本地存储
- [x] 快照条、搜索、回填
- [x] 可自定义快捷键（呼出 / 入队 / 出队）
- [x] 顺序粘贴、置顶、忽略 App、开机自启
- [x] App 图标、pkg + dmg、关于窗口
- [x] 队列侧边窗、自定义标签、检查更新
- [ ] iCloud 私有同步；更多类型识别（颜色、代码块）

## 许可

源代码可供个人使用。保留所有权利。
