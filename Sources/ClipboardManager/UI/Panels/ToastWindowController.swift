import AppKit
import ClipboardManagerCore
import SwiftUI

/// 屏幕侧边的提示浮窗：单条 Toast + 常驻队列列表窗口。
@MainActor
final class ToastWindowController {
    static let shared = ToastWindowController()

    private var window: NSPanel?
    private var hideTask: DispatchWorkItem?

    private var queueWindow: NSPanel?
    private var queueHosting: NSHostingController<QueueListView>?
    private var queueHideTask: DispatchWorkItem?
    private var queueWindowDragStart: (mouseLocation: NSPoint, windowOrigin: NSPoint)?

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

        let panelID = ObjectIdentifier(panel)
        let task = DispatchWorkItem { [weak self] in
            guard let self,
                  self.window.map(ObjectIdentifier.init) == panelID else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.125
                self.window?.animator().alphaValue = 0
            }) { [weak self] in
                Task { @MainActor in
                    guard self?.window.map(ObjectIdentifier.init) == panelID else { return }
                    self?.window?.orderOut(nil)
                    self?.window = nil
                }
            }
        }
        hideTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: task)
    }

    // MARK: - 队列常驻窗口

    private static let queueWidth: CGFloat = 360
    private static let queueHeaderHeight: CGFloat = 48
    private static let queueRowHeight: CGFloat = 36
    private static let queueRowSpacing: CGFloat = 6
    private static let queueMaxVisibleRows = 10
    private static let queuePadding: CGFloat = 28

    private static func queueHeight(forCount count: Int) -> CGFloat {
        let rows = max(min(count, queueMaxVisibleRows), 1)
        let gaps = max(rows - 1, 0)
        return queueHeaderHeight
            + CGFloat(rows) * queueRowHeight
            + CGFloat(gaps) * queueRowSpacing
            + queuePadding
    }

    func showQueue(viewModel: PanelViewModel) {
        let items = viewModel.pasteQueue
        DebugLog.write("队列窗口：显示/更新 \(items.count) 条")
        queueHideTask?.cancel()

        let height = Self.queueHeight(forCount: items.count)
        let screen = queueWindow?.screen ?? ScreenHelper.activeScreen
        let visible = screen.visibleFrame
        let defaultFrame = NSRect(
            x: visible.maxX - Self.queueWidth - 20,
            y: visible.maxY - height - 20,
            width: Self.queueWidth,
            height: height
        )
        let listView = QueueListView(viewModel: viewModel) { [weak self] ended in
            self?.moveQueueWindow(ended: ended)
        }

        if let queueWindow, let queueHosting {
            let preservedFrame = NSRect(
                x: min(max(queueWindow.frame.minX, visible.minX), visible.maxX - Self.queueWidth),
                y: min(max(queueWindow.frame.maxY - height, visible.minY), visible.maxY - height),
                width: Self.queueWidth,
                height: height
            )
            let shouldAnimateResize = queueWindow.isVisible
                && abs(queueWindow.frame.height - preservedFrame.height) > 0.5
            queueWindow.setFrame(preservedFrame, display: true, animate: shouldAnimateResize)
            queueHosting.view.needsLayout = true
            queueHosting.view.layoutSubtreeIfNeeded()
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

        let hosting = NSHostingController(rootView: listView)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.queueWidth, height: height),
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
        panel.setFrame(defaultFrame, display: true)
        // 首帧强制布局：避免 Lazy/Hosting 在 alpha=0 时未测量导致「空壳」
        hosting.view.setFrameSize(defaultFrame.size)
        hosting.view.needsLayout = true
        hosting.view.layoutSubtreeIfNeeded()

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
            queueWindowDragStart = nil
            return
        }
        let windowID = ObjectIdentifier(queueWindow)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            queueWindow.animator().alphaValue = 0
        }) { [weak self] in
            Task { @MainActor in
                guard self?.queueWindow.map(ObjectIdentifier.init) == windowID else { return }
                self?.queueWindow?.orderOut(nil)
                self?.queueWindow = nil
                self?.queueHosting = nil
                self?.queueWindowDragStart = nil
            }
        }
    }

    private func moveQueueWindow(ended: Bool) {
        guard let queueWindow else { return }
        let mouseLocation = NSEvent.mouseLocation
        if queueWindowDragStart == nil {
            queueWindowDragStart = (
                mouseLocation: mouseLocation,
                windowOrigin: queueWindow.frame.origin
            )
        }
        guard let dragStart = queueWindowDragStart else { return }

        let visible = queueWindow.screen?.visibleFrame ?? ScreenHelper.activeScreen.visibleFrame
        let proposed = NSPoint(
            x: dragStart.windowOrigin.x + mouseLocation.x - dragStart.mouseLocation.x,
            y: dragStart.windowOrigin.y + mouseLocation.y - dragStart.mouseLocation.y
        )
        let constrained = NSPoint(
            x: min(max(proposed.x, visible.minX), visible.maxX - queueWindow.frame.width),
            y: min(max(proposed.y, visible.minY), visible.maxY - queueWindow.frame.height)
        )
        queueWindow.setFrameOrigin(constrained)
        if ended {
            queueWindowDragStart = nil
            DebugLog.write("队列窗口：移动到 \(NSStringFromPoint(constrained))")
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
                .foregroundStyle(BrandTheme.accent)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    Text("\(index + 1). \(line)")
                        .font(.system(size: 11))
                        .foregroundStyle(.primary.opacity(0.85))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 300, alignment: .leading)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.regularMaterial)
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(BrandTheme.panelWash)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(BrandTheme.panelStroke, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 20, y: 8)
    }
}

// MARK: - 队列列表视图

private struct QueueListView: View {
    @ObservedObject var viewModel: PanelViewModel
    let onWindowDrag: (Bool) -> Void
    @State private var reorderState = DeferredReorderState<UUID>()
    @State private var queueDragOffset = CGSize.zero

    private static let maxVisibleRows = 10
    private static let rowHeight: CGFloat = 36
    private static let rowStride: CGFloat = 42
    private static let dropAnimationDuration = 0.04

    private var items: [PasteQueueEntry] {
        viewModel.pasteQueue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            queueHeader

            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: items.count > Self.maxVisibleRows) {
                    // 队列最多展示约 10 行：用 VStack 避免 LazyVStack 首条入队时不绘制
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, entry in
                            QueueEntryRow(
                                entry: entry,
                                index: index,
                                count: items.count,
                                isDragging: reorderState.draggedID == entry.id,
                                isDropTarget: reorderState.targetID == entry.id
                                    && reorderState.draggedID != entry.id,
                                onDelete: {
                                    viewModel.removeQueueEntry(id: entry.id)
                                },
                                onMoveUp: {
                                    viewModel.moveQueueEntry(id: entry.id, offset: -1)
                                },
                                onMoveDown: {
                                    viewModel.moveQueueEntry(id: entry.id, offset: 1)
                                }
                            )
                            .offset(
                                y: reorderState.draggedID == entry.id
                                    ? queueDragOffset.height
                                    : 0
                            )
                            .scaleEffect(reorderState.draggedID == entry.id ? 1.018 : 1)
                            .shadow(
                                color: Color.black.opacity(reorderState.draggedID == entry.id ? 0.18 : 0),
                                radius: 9,
                                y: 4
                            )
                            .zIndex(reorderState.draggedID == entry.id ? 10 : 0)
                            .highPriorityGesture(queueDragGesture(for: entry, index: index))
                            .id(queueRowID(entry.id))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .onAppear {
                    scrollToLatest(proxy)
                }
                .onChange(of: items.count) { _, _ in
                    scrollToLatest(proxy)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.regularMaterial)
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(BrandTheme.panelWash)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(BrandTheme.panelStroke, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 20, y: 8)
    }

    private var queueHeader: some View {
        HStack(alignment: .center, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [BrandTheme.mint, BrandTheme.cyan],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 18, height: 18)
                    .overlay(
                        Image(systemName: "list.number")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(BrandTheme.inkTop)
                    )

                VStack(alignment: .leading, spacing: 1) {
                    Text("QUEUE")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .tracking(0.8)
                    Text("\(items.count) 项")
                        .font(.system(size: 13.5, weight: .semibold))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { _ in onWindowDrag(false) }
                    .onEnded { _ in onWindowDrag(true) }
            )
            .help("拖动队列窗口")

            QueueHeaderButton(title: "倒序", systemImage: "arrow.up.arrow.down") {
                withAnimation(.snappy(duration: 0.18, extraBounce: 0)) {
                    viewModel.reverseQueue()
                }
            }
            .disabled(items.count < 2)

            QueueHeaderButton(title: "清空", systemImage: "trash", isDestructive: true) {
                viewModel.clearQueue()
            }
        }
    }

    private func scrollToLatest(_ proxy: ScrollViewProxy) {
        guard let latest = items.last else { return }
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo(queueRowID(latest.id), anchor: .bottom)
            }
        }
    }

    private func queueRowID(_ id: UUID) -> String {
        "queue-row-\(id.uuidString)"
    }

    private func queueDragGesture(for entry: PasteQueueEntry, index: Int) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { drag in
                if reorderState.draggedID == nil {
                    reorderState.begin(dragging: entry.id)
                    queueDragOffset = .zero
                }
                queueDragOffset = drag.translation
                updateQueueDropTarget(sourceIndex: index, verticalTranslation: drag.translation.height)
            }
            .onEnded { _ in
                guard let proposal = reorderState.finish(),
                      let targetID = proposal.targetID else {
                    reorderState.reset()
                    queueDragOffset = .zero
                    return
                }

                withAnimation(.easeOut(duration: Self.dropAnimationDuration)) {
                    queueDragOffset = .zero
                    viewModel.moveQueueEntry(id: proposal.sourceID, over: targetID)
                }
            }
    }

    private func updateQueueDropTarget(sourceIndex: Int, verticalTranslation: CGFloat) {
        guard let targetIndex = PanelInteractionPolicy.dragTargetIndex(
            sourceIndex: sourceIndex,
            itemCount: items.count,
            translation: Double(verticalTranslation),
            itemStride: Double(Self.rowStride)
        ) else { return }
        reorderState.hover(over: items[targetIndex].id)
    }
}

private struct QueueHeaderButton: View {
    let title: String
    let systemImage: String
    var isDestructive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isDestructive ? Color.red.opacity(0.82) : Color.secondary)
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(Color.primary.opacity(0.08), in: Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .opacity(isDestructive ? 0.92 : 1)
        .accessibilityLabel(title)
    }
}

private struct QueueEntryRow: View {
    let entry: PasteQueueEntry
    let index: Int
    let count: Int
    let isDragging: Bool
    let isDropTarget: Bool
    let onDelete: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 7) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isDragging ? BrandTheme.selectedStroke : Color.secondary.opacity(0.65))
                .frame(width: 12)
                .help("拖拽调整顺序")

            Text("\(index + 1)")
                .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(.primary.opacity(0.88))
                .frame(width: 18, alignment: .leading)

            Text(truncated(entry.item.previewLine))
                .font(.system(size: 12.5))
                .foregroundStyle(.primary.opacity(0.9))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onDelete) {
                Image(systemName: "xmark")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(isHovering ? Color.red.opacity(0.9) : Color.secondary.opacity(0.78))
                    .frame(width: 24, height: 24)
                    .background(
                        Color.primary.opacity(isHovering ? 0.09 : 0.055),
                        in: Circle()
                    )
            }
            .buttonStyle(.plain)
            .help("从队列删除")
            .accessibilityLabel("删除第 \(index + 1) 项")
        }
        .padding(.horizontal, 9)
        .frame(height: 36)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(rowFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    isDropTarget ? BrandTheme.selectedStroke.opacity(0.8) : Color.clear,
                    lineWidth: 1
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .opacity(isDragging ? 0.96 : 1)
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .animation(.easeOut(duration: 0.1), value: isHovering)
        .animation(.easeOut(duration: 0.1), value: isDragging)
        .animation(.easeOut(duration: 0.1), value: isDropTarget)
        .contextMenu {
            Button("上移", systemImage: "arrow.up", action: onMoveUp)
                .disabled(index == 0)
            Button("下移", systemImage: "arrow.down", action: onMoveDown)
                .disabled(index >= count - 1)
            Divider()
            Button("从队列删除", systemImage: "trash", role: .destructive, action: onDelete)
        }
        .accessibilityAction(named: "上移", onMoveUp)
        .accessibilityAction(named: "下移", onMoveDown)
        .accessibilityAction(named: "删除", onDelete)
    }

    private var rowFill: Color {
        if isDropTarget {
            return BrandTheme.selectedStroke.opacity(0.14)
        }
        return Color.primary.opacity(isHovering ? 0.105 : 0.075)
    }

    private func truncated(_ text: String) -> String {
        text.count <= 48 ? text : String(text.prefix(48)) + "…"
    }
}
