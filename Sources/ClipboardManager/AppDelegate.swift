import AppKit
import ClipboardManagerCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var panelController: BottomPanelController?

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
        requestListeningAccessIfNeeded()

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
            // 用户从系统设置授权返回后，重新挂载全局监听
            HotKeyService.shared.rebuildMonitor()
        }
    }

    private func requestListeningAccessIfNeeded() {
        guard !HotKeyService.isListeningAvailable else { return }
        // 首次启动弹出系统授权提示
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            HotKeyService.requestListeningAccess()
        }
    }

    // MARK: - 全局快捷键（呼出 / 入队 / 出队）

    private func registerHotKeys() {
        let settings = AppSettings.shared

        let mainOK = HotKeyService.shared.register(
            tag: Self.mainHotKeyTag,
            keyCode: settings.hotKeyCode,
            modifiers: settings.hotKeyModifiers
        ) { [weak self] in
            self?.togglePanel()
        }
        Self.appendLog("呼出 \(KeyCodeMapper.displayString(keyCode: settings.hotKeyCode, modifiers: settings.hotKeyModifiers))：\(mainOK ? "成功" : "失败")")

        let enqueueOK = HotKeyService.shared.register(
            tag: Self.enqueueHotKeyTag,
            keyCode: settings.enqueueHotKeyCode,
            modifiers: settings.enqueueHotKeyModifiers
        ) { [weak self] in
            self?.panelViewModel.enqueueFromClipboard()
        }
        Self.appendLog("入队 \(KeyCodeMapper.displayString(keyCode: settings.enqueueHotKeyCode, modifiers: settings.enqueueHotKeyModifiers))：\(enqueueOK ? "成功" : "失败")")

        let dequeueOK = HotKeyService.shared.register(
            tag: Self.dequeueHotKeyTag,
            keyCode: settings.dequeueHotKeyCode,
            modifiers: settings.dequeueHotKeyModifiers
        ) { [weak self] in
            self?.panelViewModel.dequeueAndPaste()
        }
        Self.appendLog("出队 \(KeyCodeMapper.displayString(keyCode: settings.dequeueHotKeyCode, modifiers: settings.dequeueHotKeyModifiers))：\(dequeueOK ? "成功" : "失败")")
    }

    static func appendLog(_ message: String) {
        let dir = ClipboardStore.defaultDBURL().deletingLastPathComponent()
        let url = dir.appendingPathComponent("debug.log")
        let line = "\(Date()) \(message)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            try? handle.close()
        } else {
            try? line.data(using: .utf8)?.write(to: url)
        }
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
            togglePanel()
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
        panelController?.show()
        panelViewModel.openSettings()
    }

    @objc private func quitApp(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    // MARK: - 底部面板

    private func setupPanel() {
        let controller = BottomPanelController(viewModel: panelViewModel)
        panelController = controller
    }

    @objc private func togglePanel() {
        Self.appendLog("面板切换触发")
        panelController?.toggle()
    }
}
