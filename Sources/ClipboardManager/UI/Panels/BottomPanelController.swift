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
    private var expectsAppActivation = false
    private var escapeMonitor: Any?
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
                let elapsed = CFAbsoluteTimeGetCurrent() - self.lastShowTime
                if elapsed < grace {
                    let token = self.visibilityToken
                    DispatchQueue.main.asyncAfter(deadline: .now() + grace - elapsed) { [weak self] in
                        guard let self, token == self.visibilityToken, let panel = self.panel else { return }
                        let shouldClose = PanelInteractionPolicy.shouldCloseAfterActivationGrace(
                            isVisible: panel.isVisible,
                            isKeyWindow: panel.isKeyWindow,
                            expectsAppActivation: self.expectsAppActivation,
                            isAppActive: NSApp.isActive
                        )
                        DebugLog.write("宽限期失活复核 close=\(shouldClose) key=\(panel.isKeyWindow) active=\(NSApp.isActive)")
                        if shouldClose {
                            self.hide(animated: true, reason: "deferredResignActive")
                        }
                    }
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
        let pasteTarget = PasteService.captureTarget(pid: sourcePID)
        viewModel.panelWillOpen(from: pasteTarget)

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
        panel.invalidateShadow()
        let frameFinished = CFAbsoluteTimeGetCurrent()

        // 直接上屏：淡入会与后台列表对齐叠成「一帧卡顿」体感
        let forceFront = secure || fromStatusMenu
        expectsAppActivation = !forceFront
        panel.alphaValue = 1
        installEscapeMonitor()
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
            self.removeEscapeMonitor()
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

    private func installEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self, let panel = self.panel,
                  event.window === panel, panel.isVisible, panel.isKeyWindow else { return event }
            if (panel.firstResponder as? NSTextView)?.hasMarkedText() == true { return event }
            self.hide(animated: true, reason: "escape")
            return nil
        }
    }

    private func removeEscapeMonitor() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
    }

    private func buildPanel() {
        let hosting = NSHostingController(rootView: SnapshotBarView(viewModel: viewModel))
        hosting.view.wantsLayer = true
        hosting.view.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.view.layer?.cornerRadius = 20
        hosting.view.layer?.cornerCurve = .continuous
        hosting.view.layer?.masksToBounds = true
        let p = PanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: SnapshotBarView.panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.contentViewController = hosting
        p.contentView?.wantsLayer = true
        p.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        panel = p
    }
}
