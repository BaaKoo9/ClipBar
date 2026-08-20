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
    /// 面板可见期间提升交互调度优先级，避免应用闲置后从 App Nap 恢复时连续掉帧。
    private var interactionActivity: NSObjectProtocol?

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
        beginInteractionActivity()
        let pipelineStarted = CFAbsoluteTimeGetCurrent()

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
        let height = SnapshotBarView.panelHeight
        let finalRect = NSRect(x: visible.midX - width / 2, y: visible.minY + 16, width: width, height: height)

        visibilityToken &+= 1
        resignGraceSeconds = resignGrace
        lastShowTime = CFAbsoluteTimeGetCurrent()
        let showStarted = lastShowTime

        panel.setFrame(finalRect, display: true)
        let frameFinished = CFAbsoluteTimeGetCurrent()

        // 直接上屏：淡入会与后台列表对齐叠成「一帧卡顿」体感
        let forceFront = secure || fromStatusMenu
        panel.alphaValue = 1
        if forceFront {
            panel.level = .statusBar
            panel.orderFrontRegardless()
            panel.makeKeyAndOrderFront(nil)
            panel.orderFrontRegardless()
        } else {
            panel.level = .floating
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            panel.orderFrontRegardless()
        }
        let frontFinished = CFAbsoluteTimeGetCurrent()

        viewModel.panelDidOpen()
        let modelFinished = CFAbsoluteTimeGetCurrent()
        DebugLog.write(
            "show 首帧 \(Int((modelFinished - showStarted) * 1000))ms forceFront=\(forceFront) " +
            "分段 pre=\(Int((showStarted - pipelineStarted) * 1000)) " +
            "frame=\(Int((frameFinished - showStarted) * 1000)) " +
            "front=\(Int((frontFinished - frameFinished) * 1000)) " +
            "model=\(Int((modelFinished - frontFinished) * 1000))"
        )

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
        guard let panel, panel.isVisible else { return }
        DebugLog.write("hide 面板 reason=\(reason) animated=\(animated)")
        visibilityToken &+= 1
        let token = visibilityToken
        let finish = { [weak self] in
            guard let self, token == self.visibilityToken else { return }
            panel.orderOut(nil)
            panel.alphaValue = 1
            panel.level = .floating
            self.viewModel.panelDidClose()
            self.endInteractionActivity()
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

    private func beginInteractionActivity() {
        guard interactionActivity == nil else { return }
        interactionActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "ClipBar panel interaction"
        )
    }

    private func endInteractionActivity() {
        guard let interactionActivity else { return }
        ProcessInfo.processInfo.endActivity(interactionActivity)
        self.interactionActivity = nil
    }

    private func buildPanel() {
        let hosting = NSHostingController(rootView: SnapshotBarView(viewModel: viewModel))
        let p = PanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: SnapshotBarView.panelHeight),
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
