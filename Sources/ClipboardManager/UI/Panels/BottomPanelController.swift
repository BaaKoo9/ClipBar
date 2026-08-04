import AppKit
import ClipboardManagerCore
import SwiftUI

/// 屏幕底部的快照面板控制器。
@MainActor
final class BottomPanelController: NSObject {
    private var panel: NSPanel?
    private let viewModel: PanelViewModel
    /// 每次显示/隐藏自增，用来作废上一次操作挂起的动画收尾。
    private var visibilityToken: UInt = 0

    init(viewModel: PanelViewModel) {
        self.viewModel = viewModel
        super.init()
        viewModel.onRequestClose = { [weak self] animated in
            self?.hide(animated: animated)
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
        let finalRect = NSRect(x: visible.midX - width / 2, y: visible.minY + 16, width: width, height: height)

        // 作废挂起的隐藏收尾：淡出动画未结束时再次呼出，
        // 否则旧的 completionHandler 会把刚显示的面板 orderOut 掉。
        visibilityToken &+= 1

        // 直接落到最终位置：对接近全屏宽的毛玻璃窗口做位移动画会逐帧重排整个视图树，
        // 是呼出卡顿的主要来源。只做透明度过渡，观感依旧平滑但没有布局开销。
        panel.setFrame(finalRect, display: false)
        panel.alphaValue = 0
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.09
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }

        viewModel.panelDidOpen()

        // 冷启动或多屏切换时首显偶发失败，复查一次并记录真实结果。
        let token = visibilityToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, let panel = self.panel, token == self.visibilityToken else { return }
            if panel.isVisible {
                DebugLog.write("面板已显示 visible=true alpha=\(panel.alphaValue)")
            } else {
                DebugLog.write("面板首显失败，强制置前重试")
                panel.alphaValue = 1
                panel.orderFrontRegardless()
                panel.makeKeyAndOrderFront(nil)
            }
        }
    }

    func hide(animated: Bool = true) {
        guard let panel, panel.isVisible else {
            viewModel.panelDidClose()
            return
        }
        visibilityToken &+= 1
        let token = visibilityToken
        let finish = { [weak self] in
            guard let self, token == self.visibilityToken else { return }
            panel.orderOut(nil)
            panel.alphaValue = 1
            self.viewModel.panelDidClose()
        }
        if animated {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.09
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
