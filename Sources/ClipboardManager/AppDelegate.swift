import AppKit
import ClipboardManagerCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem?
    private var panelController: BottomPanelController?
    private var settingsWindow: PanelWindow?

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
        ClipboardMonitor.shared.start()
        requestPermissionsIfNeeded()

        // 面板预构建（SwiftUI + 毛玻璃）较慢，挪到下一轮 runloop，不占用启动关键路径。
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.setupPanel()
            self.panelViewModel.loadHistory()
            DebugLog.write("启动：面板预构建完成，耗时 \(LaunchClock.elapsedMilliseconds)ms")
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
        ) { _ in
            HotKeyService.shared.rebuildMonitor()
            if HotKeyService.isAccessibilityAvailable, !HotKeyService.isListeningAvailable {
                HotKeyService.requestListeningAccess()
            }
        }

        // 休眠唤醒后系统常会让事件 tap 失效，这里主动重建。
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            DebugLog.write("系统唤醒，重建快捷键通道")
            HotKeyService.shared.reinitialize()
        }
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

        DebugLog.write("快捷键注册完成：呼出 \(KeyCodeMapper.displayString(keyCode: settings.hotKeyCode, modifiers: settings.hotKeyModifiers)) / 入队 \(KeyCodeMapper.displayString(keyCode: settings.enqueueHotKeyCode, modifiers: settings.enqueueHotKeyModifiers)) / 出队 \(KeyCodeMapper.displayString(keyCode: settings.dequeueHotKeyCode, modifiers: settings.dequeueHotKeyModifiers))")
    }

    // MARK: - Status item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "rectangle.stack",
                accessibilityDescription: "剪贴板"
            )
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(handleStatusItemClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
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

        let showItem = NSMenuItem(title: "显示剪贴板面板", action: #selector(togglePanelAction(_:)), keyEquivalent: "")
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

        let aboutItem = NSMenuItem(title: "关于 Clipboard Manager…", action: #selector(openAbout(_:)), keyEquivalent: "")
        aboutItem.target = self

        menu.addItem(showItem)
        menu.addItem(.separator())
        menu.addItem(statusItem)
        menu.addItem(reinitItem)
        menu.addItem(.separator())
        menu.addItem(settingsItem)
        menu.addItem(aboutItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 Clipboard Manager", action: #selector(quitApp(_:)), keyEquivalent: "q"))

        NSMenu.popUpContextMenu(menu, with: NSApp.currentEvent ?? NSEvent(), for: view)
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
        if aboutWindow == nil {
            let hosting = NSHostingController(rootView: AboutView())
            let window = PanelWindow(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 480),
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
            window.center()
            aboutWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        aboutWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: - 设置窗口（屏幕居中，无边框圆角玻璃）

    private func showSettingsWindow() {
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView())
            let window = PanelWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 620),
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
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
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
