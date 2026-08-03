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
            button.action = #selector(togglePanel(_:))
        }
        statusItem = item
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

    @objc private func togglePanel(_ sender: Any?) {
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
