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
        ClipboardMonitor.shared.start()
        setupStatusItem()
        setupPanel()
        panelViewModel.loadHistory()
        registerHotKeys()
        requestPermissionsIfNeeded()

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
                systemSymbolName: "doc.on.clipboard",
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
            // 左键始终呼出并聚焦面板（避免 toggle 状态错乱）
            panelController?.show()
        }
    }

    private func showStatusMenu(relativeTo view: NSView) {
        let menu = NSMenu()

        let showItem = NSMenuItem(title: "显示剪贴板面板", action: #selector(togglePanelAction(_:)), keyEquivalent: "")
        showItem.target = self

        let settingsItem = NSMenuItem(title: "设置…", action: #selector(openSettings(_:)), keyEquivalent: "")
        settingsItem.target = self

        menu.addItem(showItem)
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 Clipboard Manager", action: #selector(quitApp(_:)), keyEquivalent: "q"))

        NSMenu.popUpContextMenu(menu, with: NSApp.currentEvent ?? NSEvent(), for: view)
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
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: - 底部面板

    private func setupPanel() {
        let controller = BottomPanelController(viewModel: panelViewModel)
        panelController = controller

        // 面板内齿轮 → 独立设置窗口
        panelViewModel.onOpenSettings = { [weak self] in
            self?.panelController?.hide(animated: false)
            self?.showSettingsWindow()
        }
    }

    @objc private func togglePanel() {
        DebugLog.write("面板切换触发")
        panelController?.toggle()
    }
}
