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
    /// 最近一次 show 的时刻：激活瞬间可能误触发 didResignActive，需忽略。
    private var lastShowTime: CFAbsoluteTime = 0
    /// 忽略 didResignActive 的宽限时长（右键菜单关闭后会更晚触发 resign）。
    private var resignGraceSeconds: CFAbsoluteTime = 0.35

    init(viewModel: PanelViewModel) {
        self.viewModel = viewModel
        super.init()
        viewModel.onRequestClose = { [weak self] animated in
            self?.hide(animated: animated, reason: "requestClose")
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let grace = self.resignGraceSeconds
                if CFAbsoluteTimeGetCurrent() - self.lastShowTime < grace {
                    DebugLog.write("忽略 didResignActive：距 show 不足 \(Int(grace * 1000))ms")
                    return
                }
                self.hide(animated: true, reason: "didResignActive")
            }
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
        if isShown {
            hide(animated: true, reason: "toggleHide")
        } else {
            show()
        }
    }

    /// - Parameters:
    ///   - resignGrace: 忽略 didResignActive 的时长
    ///   - fromStatusMenu: 右键菜单呼出；菜单关闭后 App 常仍未真正激活，需强制 orderFrontRegardless
    func show(resignGrace: CFAbsoluteTime = 0.35, fromStatusMenu: Bool = false) {
        if panel == nil {
            buildPanel()
        }
        guard let panel else { return }

        // 在激活自己之前记住当前前台 App，粘贴时定向注入到它
        let sourcePID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        viewModel.panelWillOpen(from: sourcePID)

        let screen = ScreenHelper.activeScreen
        let visible = screen.visibleFrame
        let secure = HotKeyService.isSecureEventInputEnabled
        DebugLog.write(
            "show 面板 screen=\(NSStringFromRect(screen.frame)) visible=\(NSStringFromRect(visible)) " +
            "secure=\(secure) fromMenu=\(fromStatusMenu) frontPID=\(sourcePID ?? -1)"
        )
        let width = max(visible.width - 48, 560)
        let height: CGFloat = 268
        let finalRect = NSRect(x: visible.midX - width / 2, y: visible.minY + 16, width: width, height: height)

        visibilityToken &+= 1
        resignGraceSeconds = resignGrace
        lastShowTime = CFAbsoluteTimeGetCurrent()

        panel.setFrame(finalRect, display: true)

        // 安全输入或菜单呼出时：系统往往不允许抢焦点，makeKeyAndOrderFront 会把 isVisible
        // 标成 true 但窗体未真正上屏。必须 orderFrontRegardless，并抬高层级。
        let forceFront = secure || fromStatusMenu
        if forceFront {
            panel.level = .statusBar
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            // 尽量成为 key 以便搜索/方向键；失败也不影响可见性
            panel.makeKeyAndOrderFront(nil)
            panel.orderFrontRegardless()
        } else {
            panel.level = .floating
            panel.alphaValue = 0
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.09
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        }

        viewModel.panelDidOpen()

        let token = visibilityToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, let panel = self.panel, token == self.visibilityToken else { return }
            let occluded = !panel.occlusionState.contains(.visible)
            DebugLog.write(
                "面板状态 visible=\(panel.isVisible) alpha=\(panel.alphaValue) " +
                "isKey=\(panel.isKeyWindow) level=\(panel.level.rawValue) " +
                "occluded=\(occluded) frame=\(NSStringFromRect(panel.frame))"
            )
            if !panel.isVisible || occluded || panel.alphaValue < 0.9 {
                DebugLog.write("面板未真正可见，强制补救")
                panel.alphaValue = 1
                panel.level = .statusBar
                panel.orderFrontRegardless()
            }
        }
    }

    func hide(animated: Bool = true, reason: String = "unknown") {
        guard let panel, panel.isVisible else {
            viewModel.panelDidClose()
            return
        }
        DebugLog.write("hide 面板 reason=\(reason) animated=\(animated)")
        visibilityToken &+= 1
        let token = visibilityToken
        let finish = { [weak self] in
            guard let self, token == self.visibilityToken else { return }
            panel.orderOut(nil)
            panel.alphaValue = 1
            panel.level = .floating
            self.viewModel.panelDidClose()
        }
        if animated {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.09
                panel.animator().alphaValue = 0
            }, completionHandler: {
                Task { @MainActor in
                    finish()
                }
            })
        } else {
            finish()
        }
    }

    private func buildPanel() {
        let hosting = NSHostingController(rootView: SnapshotBarView(viewModel: viewModel))
        let p = PanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 268),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.contentViewController = hosting
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        panel = p
    }
}
