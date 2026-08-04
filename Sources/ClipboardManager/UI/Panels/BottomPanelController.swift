import AppKit
import SwiftUI

/// 屏幕底部的快照面板控制器。
@MainActor
final class BottomPanelController: NSObject {
    private var panel: NSPanel?
    private let viewModel: PanelViewModel

    init(viewModel: PanelViewModel) {
        self.viewModel = viewModel
        super.init()
        viewModel.onRequestClose = { [weak self] in
            self?.hide()
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.hide()
        }
    }

    var isShown: Bool { panel?.isVisible ?? false }

    func toggle() {
        isShown ? hide() : show()
    }

    func show() {
        if panel == nil {
            buildPanel()
        }
        guard let panel else { return }

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        let screen = NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let width = visible.width - 32
        let height: CGFloat = 214
        let x = visible.midX - width / 2
        let finalY = visible.minY + 16
        let startRect = NSRect(x: x, y: finalY - 36, width: width, height: height)
        let finalRect = NSRect(x: x, y: finalY, width: width, height: height)

        panel.setFrame(startRect, display: false)
        panel.alphaValue = 0

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.32
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(finalRect, display: true)
            panel.animator().alphaValue = 1
        }

        viewModel.panelDidOpen()
    }

    func hide(animated: Bool = true) {
        guard let panel, panel.isVisible else {
            viewModel.panelDidClose()
            return
        }
        let finish = { [weak self] in
            panel.orderOut(nil)
            self?.viewModel.panelDidClose()
        }
        if animated {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.2
                panel.animator().alphaValue = 0
            }, completionHandler: finish)
        } else {
            finish()
        }
    }

    private func buildPanel() {
        let hosting = NSHostingController(rootView: SnapshotBarView(viewModel: viewModel))
        let p = PanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: (NSScreen.main ?? NSScreen.screens[0]).visibleFrame.width - 32, height: 214),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        p.contentViewController = hosting
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        panel = p
    }
}
