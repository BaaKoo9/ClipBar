import AppKit
import ClipboardManagerCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?

    private var panelViewModel = PanelViewModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        ClipboardMonitor.shared.start()
        setupStatusItem()
        setupPopover()
        panelViewModel.loadHistory()
        registerHotKey()

        NotificationCenter.default.addObserver(
            forName: .clipboardHotKeyChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.registerHotKey()
        }
    }

    // MARK: - 全局快捷键

    private func registerHotKey() {
        let settings = AppSettings.shared
        let ok = HotKeyService.shared.register(
            keyCode: settings.hotKeyCode,
            modifiers: settings.hotKeyModifiers
        ) { [weak self] in
            self?.togglePanel(nil)
        }
        let desc = KeyCodeMapper.displayString(keyCode: settings.hotKeyCode, modifiers: settings.hotKeyModifiers)
        Self.appendLog("全局快捷键 \(desc) 注册\(ok ? "成功" : "失败")")
    }

    private static func appendLog(_ message: String) {
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
            togglePanel(sender)
        }
    }

    private func showStatusMenu(relativeTo view: NSView) {
        let menu = NSMenu()

        let showItem = NSMenuItem(title: "显示剪贴板面板", action: #selector(togglePanel(_:)), keyEquivalent: "")
        showItem.target = self

        let settingsItem = NSMenuItem(title: "设置…", action: #selector(openSettings(_:)), keyEquivalent: "")
        settingsItem.target = self

        menu.addItem(showItem)
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 Clipboard Manager", action: #selector(quitApp(_:)), keyEquivalent: "q"))

        NSMenu.popUpContextMenu(menu, with: NSApp.currentEvent ?? NSEvent(), for: view)
    }

    @objc private func openSettings(_ sender: Any?) {
        guard let popover, let button = statusItem?.button else { return }
        if !popover.isShown {
            showPanel(relativeTo: button)
        }
        panelViewModel.openSettings()
    }

    @objc private func quitApp(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    // MARK: - Popover

    private func setupPopover() {
        let hosting = NSHostingController(rootView: HistoryPanelView(viewModel: panelViewModel))
        let pop = NSPopover()
        pop.contentViewController = hosting
        pop.behavior = .transient
        pop.animates = true
        pop.delegate = self

        panelViewModel.onRequestClose = { [weak self] in
            self?.popover?.performClose(nil)
        }

        popover = pop
    }

     private func togglePanel(_ sender: Any?) {
        Self.appendLog("面板切换触发")
        guard let popover, let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPanel(relativeTo: button)
        }
    }

    private func showPanel(relativeTo view: NSView) {
        guard let popover else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        panelViewModel.panelDidOpen()
    }

    // MARK: - NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        panelViewModel.panelDidClose()
    }
}
