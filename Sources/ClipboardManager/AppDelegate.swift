import AppKit
import ClipboardManagerCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem?
    private var panelController: BottomPanelController?
    private var settingsWindow: PanelWindow?
    /// 1x1 透明非激活面板：让 LSUIElement 进程挂上 WindowServer，否则热键可能「已注册却不派发」。
    private var keepAlivePanel: NSPanel?
    private var didPrimeHotKeys = false

    private var panelViewModel = PanelViewModel()

    private static let mainHotKeyTag: UInt32 = 1
    private static let enqueueHotKeyTag: UInt32 = 2
    private static let dequeueHotKeyTag: UInt32 = 3

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // 快捷键必须最先就绪：事件 tap 是在首次访问 HotKeyService.shared 时创建的，
        // 若排在面板构建之后，冷启动时 SwiftUI 初始化那一两秒内快捷键完全无响应。
        registerHotKeys()
        DebugLog.write("启动：快捷键就绪，耗时 \(LaunchClock.elapsedMilliseconds)ms")

        setupStatusItem()
        ensureKeepAlivePanel()
        ClipboardMonitor.shared.start()
        requestPermissionsIfNeeded()
        UpdateChecker.schedulePeriodicChecks()
        NotificationCenter.default.addObserver(
            forName: .clipboardUpdateAvailable,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshStatusItemIcon()
            }
        }

        // 面板预构建（SwiftUI + 毛玻璃）较慢，挪到下一轮 runloop，不占用启动关键路径。
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.setupPanel()
            self.panelViewModel.loadHistory()
            DebugLog.write("启动：面板预构建完成，耗时 \(LaunchClock.elapsedMilliseconds)ms")
            // 预热必须在首轮 UI 就绪后做：日志证实「从未 activate 时 tap 显示正常但收不到事件」，
            // 用户右键菜单任意项会 activate，之后热键才恢复——这里自动完成同样的激活打通。
            self.primeHotKeyDelivery()
        }

        NotificationCenter.default.addObserver(
            forName: .clipboardHotKeyChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.registerHotKeys()
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            HotKeyService.shared.rebuildMonitor()
            if HotKeyService.isAccessibilityAvailable, !HotKeyService.isListeningAvailable {
                HotKeyService.requestListeningAccess()
            }
            // 用户手动点菜单也会走到这里；若启动预热尚未完成，借这次激活补一次重建。
            self?.rebuildHotKeysAfterActivationIfNeeded(reason: "didBecomeActive")
        }

        // 休眠唤醒后系统常会让事件 tap 失效，这里主动重建。
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DebugLog.write("系统唤醒，重建快捷键通道")
            self?.didPrimeHotKeys = false
            HotKeyService.shared.reinitialize()
            self?.registerHotKeys()
            self?.primeHotKeyDelivery()
        }
    }

    /// 挂一个永不抢焦点的透明面板，避免 accessory 进程在无窗时被 WindowServer 挂起事件投递。
    private func ensureKeepAlivePanel() {
        guard keepAlivePanel == nil else { return }
        let panel = NSPanel(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 1, height: 1),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.alphaValue = 0
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.orderFrontRegardless()
        keepAlivePanel = panel
        DebugLog.write("保活面板已挂接（nonactivating）")
    }

    /// LSUIElement 冷启动时 CGEventTap/Carbon 可能「已启用却不派发」。
    ///
    /// 关键：accessory 应用若没有可成为 key 的窗口，`NSApp.activate` 是空操作——
    /// 日志里启动预热后看不到 `didBecomeActive` 重建，而用户点「关于」会
    /// `makeKeyAndOrderFront`，于是热键才突然好用。这里用隐形 key 窗口完成同样激活。
    private func primeHotKeyDelivery() {
        let previous = NSWorkspace.shared.frontmostApplication
        let previousPID = previous?.processIdentifier
        let alreadyPrimed = self.didPrimeHotKeys
        DebugLog.write(
            "启动预热开始：前台=\(previous?.localizedName ?? "无") pid=\(previousPID.map(String.init) ?? "-") " +
            "已预热=\(alreadyPrimed) isActive=\(NSApp.isActive)"
        )

        let primer = PanelWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 1, height: 1),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        primer.isOpaque = false
        primer.backgroundColor = .clear
        primer.alphaValue = 0
        primer.hasShadow = false
        primer.ignoresMouseEvents = true
        primer.level = .statusBar
        primer.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .fullScreenAuxiliary]
        primer.isReleasedWhenClosed = false

        NSApp.activate(ignoringOtherApps: true)
        primer.makeKeyAndOrderFront(nil)
        DebugLog.write("启动预热：隐形 key 窗口已前置 isActive=\(NSApp.isActive)")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.rebuildHotKeysAfterActivationIfNeeded(reason: "launchPrime")
            primer.orderOut(nil)

            // 归还焦点：否则启动瞬间会抢走用户正在用的 App
            if let previous,
               previous.processIdentifier != ProcessInfo.processInfo.processIdentifier,
               !previous.isTerminated {
                previous.activate(options: [.activateIgnoringOtherApps])
            }
            // accessory 即使 activate 了前台 App，自身 isActive 仍可能为 true；显式 deactivate 更干净
            NSApp.deactivate()
            DebugLog.write(
                "启动预热结束：isActive=\(NSApp.isActive) " +
                "front=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")"
            )
        }
    }

    private func rebuildHotKeysAfterActivationIfNeeded(reason: String) {
        if didPrimeHotKeys, reason != "launchPrime" {
            return
        }
        HotKeyService.shared.reinitialize()
        registerHotKeys()
        didPrimeHotKeys = true
        let status = HotKeyService.shared.status
        DebugLog.write(
            "快捷键通道重建 reason=\(reason) \(status.description) " +
            "carbon=\(status.carbonCount) tap=\(status.tapActive) 启动后\(LaunchClock.elapsedMilliseconds)ms"
        )
    }

    private func requestPermissionsIfNeeded() {
        let hasAccessibility = HotKeyService.isAccessibilityAvailable
        let hasListening = HotKeyService.isListeningAvailable
        DebugLog.write("权限检查：辅助功能=\(hasAccessibility) 输入监控=\(hasListening)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            if !HotKeyService.isAccessibilityAvailable {
                HotKeyService.requestAccessibilityAccess()
            }
            if !HotKeyService.isListeningAvailable {
                HotKeyService.requestListeningAccess()
            }
        }
    }

    // MARK: - 全局快捷键

    private func registerHotKeys() {
        let settings = AppSettings.shared

        HotKeyService.shared.register(
            tag: Self.mainHotKeyTag,
            keyCode: settings.hotKeyCode,
            modifiers: settings.hotKeyModifiers
        ) { [weak self] in
            self?.togglePanel()
        }

        HotKeyService.shared.register(
            tag: Self.enqueueHotKeyTag,
            keyCode: settings.enqueueHotKeyCode,
            modifiers: settings.enqueueHotKeyModifiers
        ) { [weak self] in
            self?.panelViewModel.enqueueFromClipboard()
        }

        HotKeyService.shared.register(
            tag: Self.dequeueHotKeyTag,
            keyCode: settings.dequeueHotKeyCode,
            modifiers: settings.dequeueHotKeyModifiers
        ) { [weak self] in
            self?.panelViewModel.dequeueAndPaste()
        }

        let status = HotKeyService.shared.status
        DebugLog.write(
            "快捷键注册完成：呼出 \(KeyCodeMapper.displayString(keyCode: settings.hotKeyCode, modifiers: settings.hotKeyModifiers)) / " +
            "入队 \(KeyCodeMapper.displayString(keyCode: settings.enqueueHotKeyCode, modifiers: settings.enqueueHotKeyModifiers)) / " +
            "出队 \(KeyCodeMapper.displayString(keyCode: settings.dequeueHotKeyCode, modifiers: settings.dequeueHotKeyModifiers)) | " +
            "通道=\(status.description) carbon=\(status.carbonCount) tap=\(status.tapActive) listening=\(status.listening)"
        )
    }

    // MARK: - Status item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.target = self
            button.action = #selector(handleStatusItemClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "ClipBar"
        }
        statusItem = item
        refreshStatusItemIcon()
    }

    private func refreshStatusItemIcon() {
        guard let button = statusItem?.button else { return }
        let hasUpdate = AppSettings.shared.shouldSurfaceUpdate
        let name = hasUpdate ? "arrow.down.circle.fill" : "rectangle.stack"
        button.image = NSImage(systemSymbolName: name, accessibilityDescription: "剪贴板")
        button.image?.isTemplate = !hasUpdate
        button.contentTintColor = hasUpdate ? .systemOrange : nil
        button.toolTip = hasUpdate
            ? "ClipBar · 有新版本 \(AppSettings.shared.availableUpdateVersion ?? "")"
            : "ClipBar"
    }

    @objc private func handleStatusItemClick(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        let eventType = NSApp.currentEvent?.type ?? .leftMouseUp
        if eventType == .rightMouseUp {
            showStatusMenu(relativeTo: button)
        } else {
            // 左键：呼出/收起切换
            togglePanel()
        }
    }

    private func showStatusMenu(relativeTo view: NSView) {
        let menu = NSMenu()

        let showItem = NSMenuItem(title: "显示剪贴板面板", action: #selector(showPanelFromMenu(_:)), keyEquivalent: "")
        showItem.target = self

        let status = HotKeyService.shared.status
        let statusItem = NSMenuItem(title: "快捷键状态：\(status.description)", action: nil, keyEquivalent: "")
        statusItem.isEnabled = false

        let reinitItem = NSMenuItem(
            title: "重新初始化快捷键",
            action: #selector(reinitializeHotKeys(_:)),
            keyEquivalent: ""
        )
        reinitItem.target = self

        let settingsItem = NSMenuItem(title: "设置…", action: #selector(openSettings(_:)), keyEquivalent: "")
        settingsItem.target = self

        let updateItem = NSMenuItem(title: "检查更新…", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        updateItem.target = self

        let aboutItem = NSMenuItem(title: "关于 ClipBar…", action: #selector(openAbout(_:)), keyEquivalent: "")
        aboutItem.target = self

        menu.addItem(showItem)
        menu.addItem(.separator())
        menu.addItem(statusItem)
        menu.addItem(reinitItem)
        menu.addItem(.separator())
        menu.addItem(settingsItem)
        menu.addItem(updateItem)
        menu.addItem(aboutItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 ClipBar", action: #selector(quitApp(_:)), keyEquivalent: "q"))

        NSMenu.popUpContextMenu(menu, with: NSApp.currentEvent ?? NSEvent(), for: view)
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        UpdateChecker.checkForUpdates(interactive: true)
    }

    /// 手动重建快捷键通道：权限已授予但系统 TCC 缓存滞后时的兜底入口。
    @objc private func reinitializeHotKeys(_ sender: Any?) {
        HotKeyService.shared.reinitialize()
        registerHotKeys()

        if !HotKeyService.isAccessibilityAvailable {
            HotKeyService.requestAccessibilityAccess()
        }
        if !HotKeyService.isListeningAvailable {
            HotKeyService.requestListeningAccess()
        }

        // 重建是异步的，稍后再读状态才准确。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            let status = HotKeyService.shared.status
            ToastWindowController.shared.show(
                title: status.isWorking ? "快捷键已就绪" : "快捷键仍未生效",
                message: status.isWorking
                    ? "当前状态：\(status.description)"
                    : "请在系统设置中授予辅助功能与输入监控权限",
                systemImage: status.isWorking ? "checkmark.circle" : "exclamationmark.triangle"
            )
        }
    }

    @objc private func showPanelFromMenu(_ sender: Any?) {
        // 右键菜单关闭会触发 didResignActive；等菜单收起后再强制 show
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            DebugLog.write("菜单呼出面板")
            self.setupPanel()
            self.settingsWindow?.orderOut(nil)
            self.panelController?.show(resignGrace: 1.2, fromStatusMenu: true)
        }
    }

    @objc private func togglePanelAction(_ sender: Any?) {
        togglePanel()
    }

    @objc private func openSettings(_ sender: Any?) {
        showSettingsWindow()
    }

    @objc private func quitApp(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    private var aboutWindow: PanelWindow?

    @objc private func openAbout(_ sender: Any?) {
        showAboutWindow()
    }

    private func showAboutWindow() {
        let preferredSize = NSSize(width: 420, height: 480)
        if aboutWindow == nil {
            let hosting = NSHostingController(rootView: AboutView())
            let window = PanelWindow(
                contentRect: NSRect(origin: .zero, size: preferredSize),
                styleMask: [.borderless, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.contentViewController = hosting
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.isMovableByWindowBackground = true
            window.level = .normal
            window.collectionBehavior = [.moveToActiveSpace]
            window.isReleasedWhenClosed = false
            window.delegate = self
            aboutWindow = window
        }
        if let aboutWindow {
            aboutWindow.setContentSize(preferredSize)
            ScreenHelper.centerAfterLayout(aboutWindow, preferredSize: preferredSize, reason: "关于窗居中")
            NSApp.activate(ignoringOtherApps: true)
            aboutWindow.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: - 设置窗口（当前活跃屏居中，无边框圆角玻璃）

    private func showSettingsWindow() {
        let preferredSize = NSSize(width: 720, height: 560)
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView())
            let window = PanelWindow(
                contentRect: NSRect(origin: .zero, size: preferredSize),
                styleMask: [.borderless, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.contentViewController = hosting
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.isMovableByWindowBackground = true
            window.level = .normal
            window.collectionBehavior = [.moveToActiveSpace]
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        if let settingsWindow {
            settingsWindow.setContentSize(preferredSize)
            ScreenHelper.centerAfterLayout(settingsWindow, preferredSize: preferredSize, reason: "设置窗居中")
            NSApp.activate(ignoringOtherApps: true)
            settingsWindow.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: - 底部面板

    private func setupPanel() {
        guard panelController == nil else { return }
        let controller = BottomPanelController(viewModel: panelViewModel)
        controller.prepare()
        panelController = controller

        // 队列提示框 X：关闭提示并清空队列
        ToastWindowController.shared.onQueueClose = { [weak self] in
            self?.panelViewModel.clearQueue()
        }

        // 面板内齿轮 → 独立设置窗口
        panelViewModel.onOpenSettings = { [weak self] in
            self?.panelController?.hide(animated: false)
            self?.showSettingsWindow()
        }
    }

     private func togglePanel() {
        DebugLog.write("面板切换触发")
        // 面板改为异步预构建，极早期按下快捷键时这里补建，避免按了没反应。
        setupPanel()
        // 快捷键呼出只关心剪切板，设置窗口不随之出现
        settingsWindow?.orderOut(nil)
        panelController?.toggle()
    }
}
