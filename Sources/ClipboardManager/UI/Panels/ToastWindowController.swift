import AppKit
import ClipboardManagerCore
import SwiftUI

/// 屏幕侧边的提示浮窗：单条 Toast + 常驻队列列表窗口。
@MainActor
final class ToastWindowController {
    static let shared = ToastWindowController()

    /// 队列窗口 X 按钮触发的额外动作（清空队列由外部注入）。
    var onQueueClose: (() -> Void)?

    private var window: NSPanel?
    private var hideTask: DispatchWorkItem?

    private var queueWindow: NSPanel?
    private var queueHosting: NSHostingController<QueueListView>?
    private var queueHideTask: DispatchWorkItem?

    private init() {}

    // MARK: - 单条 Toast

    func show(title: String, message: String, systemImage: String) {
        show(title: title, lines: [message], systemImage: systemImage)
    }

    private func show(title: String, lines: [String], systemImage: String) {
        hideTask?.cancel()
        if let oldWindow = window {
            oldWindow.orderOut(nil)
            oldWindow.alphaValue = 0
        }

        let content = ToastView(title: title, lines: lines, systemImage: systemImage)
        let hosting = NSHostingController(rootView: content)

        let height = 64 + max(lines.count, 1) * 18
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false

        let screen = ScreenHelper.activeScreen
        let visible = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: visible.maxX - 300 - 20, y: visible.midY - CGFloat(height) / 2))

        window = panel
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.125
            panel.animator().alphaValue = 1
        }

        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.125
                self.window?.animator().alphaValue = 0
            }) {
                self.window?.orderOut(nil)
                self.window = nil
            }
        }
        hideTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: task)
    }

    // MARK: - 队列常驻窗口

    func showQueue(items: [ClipboardItem]) {
        DebugLog.write("队列窗口：显示/更新 \(items.count) 条")
        queueHideTask?.cancel()

        if let queueWindow, let queueHosting {
            // 窗口已存在：只更新内容，不重建、不关闭，避免闪烁
            queueHosting.rootView = QueueListView(items: items, onClose: { [weak self] in
                self?.hideQueue()
                self?.onQueueClose?()
            })
            if !queueWindow.isVisible {
                queueWindow.alphaValue = 0
                queueWindow.orderFrontRegardless()
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.15
                    queueWindow.animator().alphaValue = 1
                }
            }
            return
        }

        let hosting = NSHostingController(rootView: QueueListView(items: items, onClose: { [weak self] in
            self?.hideQueue()
            self?.onQueueClose?()
        }))
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 360),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false

        let screen = ScreenHelper.activeScreen
        let visible = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: visible.maxX - 340 - 20, y: visible.maxY - 380))

        queueWindow = panel
        queueHosting = hosting
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }

    func hideQueue() {
        DebugLog.write("队列窗口：隐藏")
        queueHideTask?.cancel()
        guard let queueWindow, queueWindow.isVisible else {
            queueWindow?.orderOut(nil)
            self.queueWindow = nil
            self.queueHosting = nil
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            queueWindow.animator().alphaValue = 0
        }) { [weak self] in
            queueWindow.orderOut(nil)
            self?.queueWindow = nil
            self?.queueHosting = nil
        }
    }
}

// MARK: - 单条 Toast 视图

private struct ToastView: View {
    let title: String
    let lines: [String]
    let systemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    Text("\(index + 1). \(line)")
                        .font(.system(size: 11))
                        .foregroundStyle(.primary.opacity(0.85))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 300)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.12), radius: 20, y: 8)
    }
}

// MARK: - 队列列表视图

private struct QueueListView: View {
    let items: [ClipboardItem]
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "list.number")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("待粘贴队列（\(items.count)）")
                    .font(.system(size: 13.5, weight: .semibold))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .background(Color.primary.opacity(0.06), in: Circle())
                }
                .buttonStyle(.plain)
                .help("关闭提示并清空队列")
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(index + 1)")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 24, alignment: .trailing)
                            Text(truncated(item.previewLine))
                                .font(.system(size: 12.5))
                                .foregroundStyle(.primary.opacity(0.85))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 5)
                        if index < items.count - 1 {
                            Divider()
                        }
                    }
                }
            }
            .frame(maxHeight: 260)
        }
        .padding(14)
        .frame(width: 340, height: 360, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.12), radius: 20, y: 8)
    }

    private func truncated(_ text: String) -> String {
        text.count <= 40 ? text : String(text.prefix(40)) + "…"
    }
}
