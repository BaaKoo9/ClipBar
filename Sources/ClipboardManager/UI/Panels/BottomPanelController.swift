import AppKit
import ClipboardManagerCore
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

    /// 启动时预构建并隐藏面板，呼出时零布局延迟。
    func prepare() {
        guard panel == nil else { return }
        buildPanel()
        panel?.orderOut(nil)
    }

    func toggle() {
        isShown ? hide() : show()
    }

    func show() {
        if panel == nil {
            buildPanel()
        }
        guard let panel else { return }

        // 在激活自己之前记住当前前台 App，粘贴时定向注入到它
        let sourcePID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        viewModel.panelWillOpen(from: sourcePID)

        let screen = ScreenHelper.activeScreen
        let visible = screen.visibleFrame
        DebugLog.write("show 面板 screen=\(NSStringFromRect(screen.frame)) visible=\(NSStringFromRect(visible))")
        let width = visible.width - 32
        let height: CGFloat = 280
        let x = visible.midX - width / 2
        let finalY = visible.minY + 16
        let startRect = NSRect(x: x, y: finalY - 28, width: width, height: height)
        let finalRect = NSRect(x: x, y: finalY, width: width, height: height)

        // 先定位并隐藏，再显示，避免闪现旧位置造成拖影
        panel.setFrame(startRect, display: false)
        panel.alphaValue = 0
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        // 防御：首次显示偶发失败时强制置前，并延迟复查重试
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, let panel = self.panel, !panel.isVisible else { return }
            DebugLog.write("面板首显失败，重试")
            panel.orderFrontRegardless()
            panel.makeKeyAndOrderFront(nil)
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
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
                context.duration = 0.15
                panel.animator().alphaValue = 0
            }, completionHandler: finish)
        } else {
            finish()
        }
    }

    private func buildPanel() {
        let hosting = NSHostingController(rootView: SnapshotBarView(viewModel: viewModel))
        let p = PanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: (NSScreen.main ?? NSScreen.screens[0]).visibleFrame.width - 32, height: 280),
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
