import AppKit
import ClipboardManagerCore
import SwiftUI

/// 屏幕底部的快照条：分类筛选 + 横向卡片列表 + 搜索 + 键盘导航。
struct SnapshotBarView: View {
    @ObservedObject var viewModel: PanelViewModel
    @FocusState private var searchFocused: Bool
    @State private var showAddLabel = false
    @State private var newLabelName = ""
    @State private var newLabelColor = "blue"
    @State private var draggingLabelID: Int64?
    @State private var editingLabel: ClipboardLabel?
    @State private var editLabelName = ""
    @State private var editLabelColor = "blue"
    @State private var labelPendingDelete: ClipboardLabel?

    /// 所有类型统一卡片尺寸（略回正，避免偏瘦高）。
    private static let cardWidth: CGFloat = 152
    private static let cardHeight: CGFloat = 140
    private static let cardSpacing: CGFloat = 10
    /// 与 BottomPanelController 保持一致。
    static let panelHeight: CGFloat = 318

    var body: some View {
        snapshotContent
    }

    private var snapshotContent: some View {
        VStack(spacing: 0) {
            chromeBar
            Divider().opacity(0.55)

            // 固定内容区高度：空状态与有卡片时同高，避免切筛选时上下跳动
            Group {
                if viewModel.items.isEmpty {
                    emptyState
                } else {
                    snapshotScroller
                }
            }
            .frame(height: Self.cardHeight + 16)
            .frame(maxWidth: .infinity)

            Divider().opacity(0.55)
            hintBar
        }
        // 入队提示改由侧边队列窗承担，面板内不再插入 queueBar，避免顶起卡片行
        .frame(minWidth: 560, maxWidth: .infinity, minHeight: Self.panelHeight, maxHeight: Self.panelHeight)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.regularMaterial)
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(BrandTheme.panelWash)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(BrandTheme.panelStroke, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.28), radius: 36, y: 12)
        .onAppear {
            searchFocused = true
        }
        .onChange(of: viewModel.searchText) { _, _ in
            viewModel.searchDidChange()
        }
        .popover(isPresented: Binding(
            get: { editingLabel != nil },
            set: { if !$0 { editingLabel = nil } }
        ), arrowEdge: .bottom) {
            editLabelPopover
        }
        .alert(
            "删除标签",
            isPresented: Binding(
                get: { labelPendingDelete != nil },
                set: { if !$0 { labelPendingDelete = nil } }
            ),
            presenting: labelPendingDelete
        ) { label in
            Button("取消", role: .cancel) { labelPendingDelete = nil }
            Button("删除", role: .destructive) {
                viewModel.deleteLabel(id: label.id)
                labelPendingDelete = nil
            }
        } message: { label in
            Text("确定删除「\(label.name)」？已打在条目上的该标签也会移除。")
        }
    }

    // MARK: - 顶栏（品牌 + 筛选 + 搜索）

    private var chromeBar: some View {
        HStack(spacing: 10) {
            brandMark

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    FilterChip(
                        title: "全部",
                        systemImage: "square.grid.2x2",
                        isSelected: viewModel.filterKind == nil && viewModel.filterLabelID == nil
                    ) {
                        viewModel.setFilter(nil)
                        viewModel.setLabelFilter(nil)
                    }
                    FilterChip(title: "文本", systemImage: "text.alignleft", isSelected: viewModel.filterKind == .text) {
                        viewModel.setLabelFilter(nil)
                        viewModel.setFilter(.text)
                    }
                    FilterChip(title: "链接", systemImage: "link", isSelected: viewModel.filterKind == .link) {
                        viewModel.setLabelFilter(nil)
                        viewModel.setFilter(.link)
                    }
                    FilterChip(title: "图片", systemImage: "photo", isSelected: viewModel.filterKind == .image) {
                        viewModel.setLabelFilter(nil)
                        viewModel.setFilter(.image)
                    }
                    FilterChip(title: "文件", systemImage: "doc", isSelected: viewModel.filterKind == .file) {
                        viewModel.setLabelFilter(nil)
                        viewModel.setFilter(.file)
                    }

                    ForEach(viewModel.labels) { label in
                        FilterChip(
                            title: label.name,
                            isSelected: viewModel.filterLabelID == label.id,
                            tint: LabelColor.color(for: label.color),
                            style: .labelDot
                        ) {
                            if viewModel.filterLabelID == label.id {
                                viewModel.setLabelFilter(nil)
                            } else {
                                viewModel.setFilter(nil)
                                viewModel.setLabelFilter(label.id)
                            }
                        }
                        .opacity(draggingLabelID == label.id ? 0.4 : 1)
                        .onDrag {
                            draggingLabelID = label.id
                            return NSItemProvider(object: NSString(string: "label:\(label.id)"))
                        }
                        .onDrop(
                            of: [.text],
                            delegate: LabelReorderDropDelegate(
                                targetID: label.id,
                                draggingID: $draggingLabelID,
                                onHover: { dragging, target in
                                    withAnimation(.interactiveSpring(response: 0.22, dampingFraction: 0.86)) {
                                        viewModel.moveLabel(draggingID: dragging, before: target)
                                    }
                                },
                                onDrop: {
                                    viewModel.commitLabelOrder()
                                    draggingLabelID = nil
                                }
                            )
                        )
                        .contextMenu {
                            Button("编辑…") {
                                editingLabel = label
                                editLabelName = label.name
                                editLabelColor = label.color
                            }
                            Button("删除…", role: .destructive) {
                                labelPendingDelete = label
                            }
                        }
                    }

                    Button {
                        newLabelName = ""
                        newLabelColor = "blue"
                        showAddLabel = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                            .background(Color.primary.opacity(0.10), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("新建标签")
                    .popover(isPresented: $showAddLabel, arrowEdge: .bottom) {
                        addLabelPopover
                    }
                    .onDrop(
                        of: [.text],
                        delegate: LabelReorderDropDelegate(
                            targetID: nil,
                            draggingID: $draggingLabelID,
                            onHover: { dragging, target in
                                withAnimation(.interactiveSpring(response: 0.22, dampingFraction: 0.86)) {
                                    viewModel.moveLabel(draggingID: dragging, before: target)
                                }
                            },
                            onDrop: {
                                viewModel.commitLabelOrder()
                                draggingLabelID = nil
                            }
                        )
                    )
                }
            }

            Text("\(viewModel.items.count)")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.tertiary)

            searchField
            settingsButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var brandMark: some View {
        HStack(spacing: 6) {
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
                    Image(systemName: "rectangle.stack.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(BrandTheme.inkTop)
                )
            Text("ClipBar")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.92))
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("搜索", text: $viewModel.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
                .onKeyPress(.leftArrow) {
                    viewModel.moveSelection(offset: -1)
                    return .handled
                }
                .onKeyPress(.rightArrow) {
                    viewModel.moveSelection(offset: 1)
                    return .handled
                }
                .onKeyPress(.escape) {
                    viewModel.requestClose()
                    return .handled
                }
                .onKeyPress { press in
                    if press.modifiers.contains(.command), press.key == .return {
                        viewModel.enqueueSelected()
                        return .handled
                    }
                    return .ignored
                }
                .onSubmit {
                    viewModel.pasteSelected()
                }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(width: 148)
        .background(Color.primary.opacity(0.08), in: Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private var settingsButton: some View {
        Button {
            viewModel.openSettings()
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(Color.primary.opacity(0.08), in: Circle())
        }
        .buttonStyle(.plain)
        .help("设置")
    }

    private var addLabelPopover: some View {
        labelEditorPopover(
            title: "新建标签",
            name: $newLabelName,
            color: $newLabelColor,
            confirmTitle: "添加",
            onCancel: { showAddLabel = false },
            onConfirm: {
                let name = newLabelName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                viewModel.createLabel(name: name, color: newLabelColor)
                showAddLabel = false
            }
        )
    }

    private var editLabelPopover: some View {
        labelEditorPopover(
            title: "编辑标签",
            name: $editLabelName,
            color: $editLabelColor,
            confirmTitle: "保存",
            onCancel: { editingLabel = nil },
            onConfirm: {
                guard let label = editingLabel else { return }
                let name = editLabelName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                viewModel.updateLabel(id: label.id, name: name, color: editLabelColor)
                editingLabel = nil
            }
        )
    }

    private func labelEditorPopover(
        title: String,
        name: Binding<String>,
        color: Binding<String>,
        confirmTitle: String,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
            TextField("名称", text: name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
            HStack(spacing: 8) {
                ForEach(ClipboardLabel.presetColors, id: \.self) { preset in
                    Button {
                        color.wrappedValue = preset
                    } label: {
                        Circle()
                            .fill(LabelColor.color(for: preset))
                            .frame(width: 18, height: 18)
                            .overlay(
                                Circle().stroke(
                                    Color.primary.opacity(color.wrappedValue == preset ? 0.55 : 0.12),
                                    lineWidth: color.wrappedValue == preset ? 2 : 1
                                )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Spacer()
                Button("取消", action: onCancel)
                    .buttonStyle(.plain)
                Button(confirmTitle, action: onConfirm)
                    .disabled(name.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
    }

    // MARK: - 快照卡片

    private var snapshotScroller: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .center, spacing: Self.cardSpacing) {
                    // 左侧占位：scrollTo(leading) 时仍保留与顶栏一致的边距
                    Color.clear
                        .frame(width: 14)
                        .id("list-leading-inset")

                    ForEach(Array(viewModel.items.enumerated()), id: \.element.id) { index, item in
                        SnapshotCard(
                            index: index + 1,
                            item: item,
                            labels: viewModel.labels,
                            isSelected: item.id == viewModel.selectedID,
                            highlight: viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines),
                            suppressAnimation: viewModel.suppressListAnimation,
                            onSelect: {
                                viewModel.pasteItem(item)
                            },
                            onEnqueue: {
                                viewModel.selectedID = item.id
                                viewModel.enqueueSelected()
                            },
                            onDelete: {
                                viewModel.deleteItem(item)
                            },
                            onTogglePin: {
                                viewModel.togglePin(item)
                            }
                        )
                        .frame(width: Self.cardWidth, height: Self.cardHeight)
                        .id(item.id)
                        .contextMenu {
                            if item.kind == .link, let text = item.text, let url = URL(string: text) {
                                Button("打开链接") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            if item.kind == .file, let first = item.filePaths.first {
                                Button("在 Finder 中显示") {
                                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: first)])
                                }
                            }
                            Button(item.pinned ? "取消置顶" : "置顶") {
                                viewModel.togglePin(item)
                            }
                            if !viewModel.labels.isEmpty {
                                Menu("标签") {
                                    ForEach(viewModel.labels) { label in
                                        Button {
                                            viewModel.toggleLabel(label.id, for: item)
                                        } label: {
                                            HStack {
                                                Text(label.name)
                                                if item.labelIDs.contains(label.id) {
                                                    Image(systemName: "checkmark")
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                            Button("加入粘贴队列") {
                                viewModel.selectedID = item.id
                                viewModel.enqueueSelected()
                            }
                            Button("粘贴") {
                                viewModel.selectedID = item.id
                                viewModel.pasteSelected()
                            }
                            Button("删除", role: .destructive) {
                                viewModel.deleteItem(item)
                            }
                        }
                    }

                    Color.clear.frame(width: 14)
                }
                .padding(.vertical, 8)
            }
            .onChange(of: viewModel.scrollGeneration) { _, _ in
                guard let newID = viewModel.scrollRequestID else { return }
                let scrollToStart = viewModel.suppressListAnimation || !viewModel.scrollAnimated
                if scrollToStart {
                    // 滚到左侧占位，避免首卡贴齐面板边缘
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        proxy.scrollTo("list-leading-inset", anchor: .leading)
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(newID, anchor: .center)
                    }
                }
            }
        }
    }

    // MARK: - 空状态 / 提示

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "rectangle.stack")
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)
            Text(emptyStateMessage)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateMessage: String {
        if !viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "没有匹配的结果"
        }
        switch viewModel.filterKind {
        case .text: return "暂无文本记录"
        case .link: return "暂无链接记录"
        case .image: return "暂无图片记录"
        case .file: return "暂无文件记录"
        case nil: return "复制内容会显示在这里"
        }
    }

    private var hintBar: some View {
        HStack(spacing: 16) {
            Text("←→ 选择")
            Text("回车 粘贴")
            Text("⌘+点击/⌘↵ 入队")
            Text("Esc 关闭")
            Spacer()
            if viewModel.pasteQueue.count > 0 {
                Text("队列 \(viewModel.pasteQueue.count) 项 · 侧边窗可查看")
                    .foregroundStyle(BrandTheme.accent.opacity(0.9))
                    .fontWeight(.medium)
            } else {
                Text("\(viewModel.enqueueHotKeyLabel) 入队 · \(viewModel.dequeueHotKeyLabel) 出队")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
    }
}

// MARK: - 分类筛选 Chip

private struct FilterChip: View {
    enum Style {
        case brandFill
        case labelDot
    }

    let title: String
    var systemImage: String? = nil
    let isSelected: Bool
    var tint: Color = BrandTheme.accent
    var style: Style = .brandFill
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if style == .labelDot {
                    Circle()
                        .fill(tint)
                        .frame(width: isSelected ? 7 : 6, height: isSelected ? 7 : 6)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 9, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(fill)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(stroke, lineWidth: isSelected && style == .labelDot ? 1.25 : 0)
            )
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: isSelected)
    }

    private var foreground: Color {
        switch style {
        case .brandFill:
            return isSelected ? BrandTheme.inkTop : .secondary
        case .labelDot:
            return isSelected ? .primary.opacity(0.92) : .secondary
        }
    }

    private var fill: Color {
        switch style {
        case .brandFill:
            return isSelected ? BrandTheme.accent.opacity(0.92) : Color.primary.opacity(0.10)
        case .labelDot:
            return isSelected ? Color.primary.opacity(0.12) : Color.primary.opacity(0.08)
        }
    }

    private var stroke: Color {
        style == .labelDot && isSelected ? BrandTheme.selectedStroke : .clear
    }
}

// MARK: - 快照卡片

private struct SnapshotCard: View {
    let index: Int
    let item: ClipboardItem
    let labels: [ClipboardLabel]
    let isSelected: Bool
    let highlight: String
    var suppressAnimation: Bool = false
    var onSelect: () -> Void
    var onEnqueue: () -> Void
    var onDelete: () -> Void
    var onTogglePin: () -> Void
    @State private var isHovering = false

    private var itemLabels: [ClipboardLabel] {
        labels.filter { item.labelIDs.contains($0.id) }
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button {
                let isCommand = NSEvent.modifierFlags.contains(.command)
                    || (NSApp.currentEvent?.modifierFlags.contains(.command) == true)
                if isCommand {
                    onEnqueue()
                } else {
                    onSelect()
                }
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    headerRow
                    contentBody
                    footerRow
                }
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(isSelected ? BrandTheme.cardFillSelected : (isHovering ? BrandTheme.cardFillHover : BrandTheme.cardFill))
                        .shadow(
                            color: isSelected
                                ? BrandTheme.selectedStroke.opacity(0.35)
                                : Color.black.opacity(isHovering ? 0.14 : 0.08),
                            radius: isSelected ? 10 : 5,
                            y: isSelected ? 3 : 2
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(
                            isSelected
                                ? BrandTheme.selectedStroke
                                : Color.primary.opacity(isHovering ? 0.16 : 0.08),
                            lineWidth: isSelected ? 2 : 1
                        )
                )
                .scaleEffect(isSelected ? 1.02 : 1.0)
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)

            if isHovering {
                HStack(spacing: 4) {
                    CardIconButton(
                        systemName: item.pinned ? "pin.slash" : "pin",
                        help: item.pinned ? "取消置顶" : "置顶",
                        action: onTogglePin
                    )
                    CardIconButton(
                        systemName: "xmark",
                        help: "删除",
                        action: onDelete
                    )
                }
                .padding(.top, 8)
                .padding(.trailing, 8)
            }
        }
        .onHover { hovering in
            isHovering = hovering
        }
        .animation(suppressAnimation ? nil : .spring(response: 0.28, dampingFraction: 0.86), value: isSelected)
        .animation(suppressAnimation ? nil : .easeOut(duration: 0.12), value: isHovering)
    }

    private var headerRow: some View {
        HStack(spacing: 5) {
            Text("\(index)")
                .font(.system(size: 12, weight: .bold).monospacedDigit())
                .foregroundStyle(Color.secondary.opacity(0.9))
                .frame(width: 16, alignment: .leading)

            Image(systemName: iconName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isSelected ? BrandTheme.selectedStroke : Color.primary.opacity(0.55))

            Spacer(minLength: 0)

            Text(RelativeTime.string(from: item.updatedAt))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Color.secondary.opacity(0.9))
            // 悬停操作按钮叠在卡片外层，避免嵌套 Button
            Color.clear.frame(width: isHovering ? 44 : 0, height: 1)
        }
        .frame(height: 18)
    }

    private var footerRow: some View {
        HStack(spacing: 5) {
            labelDots
            sourceIcon
            Spacer(minLength: 0)
            if item.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(BrandTheme.selectedStroke)
            }
        }
    }

    @ViewBuilder
    private var sourceIcon: some View {
        if let icon = Self.appIcon(for: item.sourceAppBundleID) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 15, height: 15)
                .clipShape(RoundedRectangle(cornerRadius: 3.5, style: .continuous))
                .opacity(0.95)
        }
    }

    @ViewBuilder
    private var labelDots: some View {
        let shown = Array(itemLabels.prefix(3))
        if !shown.isEmpty {
            HStack(spacing: -2) {
                ForEach(shown) { label in
                    Circle()
                        .fill(LabelColor.color(for: label.color))
                        .frame(width: 7, height: 7)
                        .overlay(Circle().stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
                }
                if itemLabels.count > 3 {
                    Text("+\(itemLabels.count - 3)")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                }
            }
        }
    }

    @ViewBuilder
    private var contentBody: some View {
        if item.kind == .image {
            SnapshotThumbnail(path: item.imagePath, fallbackPath: item.originalImagePath)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text(highlightedPreview)
                .font(.system(size: 12))
                .lineLimit(3)
                .lineSpacing(1)
                .multilineTextAlignment(.leading)
                .foregroundStyle(.primary.opacity(0.92))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var highlightedPreview: AttributedString {
        let text = item.previewLine.isEmpty ? "（空内容）" : item.previewLine
        var attributed = AttributedString(text)
        guard !highlight.isEmpty else { return attributed }

        let lowerText = text.lowercased()
        let lowerQuery = highlight.lowercased()
        var searchStart = lowerText.startIndex
        while let range = lowerText.range(of: lowerQuery, range: searchStart..<lowerText.endIndex) {
            if let attrRange = Range(range, in: attributed) {
                attributed[attrRange].font = .system(size: 12, weight: .bold)
                attributed[attrRange].foregroundColor = Color(red: 0.12, green: 0.10, blue: 0.06)
                attributed[attrRange].backgroundColor = BrandTheme.searchHit.opacity(0.92)
            }
            if range.upperBound == searchStart { break }
            searchStart = range.upperBound
        }
        return attributed
    }

    private var iconName: String {
        switch item.kind {
        case .text: "text.alignleft"
        case .link: "link"
        case .image: "photo"
        case .file: "doc"
        }
    }

    private static let iconCache = NSCache<NSString, NSImage>()

    private static func appIcon(for bundleID: String?) -> NSImage? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        if let cached = iconCache.object(forKey: bundleID as NSString) {
            return cached
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 28, height: 28)
        iconCache.setObject(icon, forKey: bundleID as NSString)
        return icon
    }
}

private enum RelativeTime {
    static func string(from date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "刚刚" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) 分钟前" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) 小时前" }
        let days = hours / 24
        if days < 30 { return "\(days) 天前" }
        return "更早"
    }
}

enum LabelColor {
    static func color(for name: String) -> Color {
        switch name {
        case "purple": return .purple
        case "pink": return .pink
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        case "gray": return .gray
        default: return .blue
        }
    }
}

private struct CardIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.primary.opacity(0.8))
                .frame(width: 20, height: 20)
                .background(Color.primary.opacity(0.12), in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// 标签横向重排：悬停时即时换位，支持左右双向；松手后落库。
private struct LabelReorderDropDelegate: DropDelegate {
    let targetID: Int64?
    @Binding var draggingID: Int64?
    let onHover: (Int64, Int64?) -> Void
    let onDrop: () -> Void

    func validateDrop(info: DropInfo) -> Bool {
        draggingID != nil
    }

    func dropEntered(info: DropInfo) {
        guard let draggingID, draggingID != targetID else { return }
        onHover(draggingID, targetID)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard draggingID != nil else { return false }
        onDrop()
        return true
    }

    func dropExited(info: DropInfo) {}
}

private struct SnapshotThumbnail: View {
    let path: String?
    var fallbackPath: String? = nil
    @State private var image: NSImage?

    private static let cache = NSCache<NSString, NSImage>()

    var body: some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.06))

                if let image {
                    // 等比缩放入框，不裁切、不拉伸，留白由背景承接
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geo.size.width, height: geo.size.height)
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 16))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: "\(path ?? "")|\(fallbackPath ?? "")") {
            let candidates = [
                AppPaths.resolveExistingPath(path),
                AppPaths.resolveExistingPath(fallbackPath)
            ].compactMap { $0 }
            guard let resolved = candidates.first else {
                image = nil
                return
            }
            if let cached = Self.cache.object(forKey: resolved as NSString) {
                image = cached
                return
            }
            let loaded = await Task.detached(priority: .utility) { () -> NSImage? in
                for candidate in candidates {
                    if let img = NSImage(contentsOfFile: candidate) { return img }
                }
                return nil
            }.value
            if let loaded {
                Self.cache.setObject(loaded, forKey: resolved as NSString)
                image = loaded
            } else {
                image = nil
            }
        }
    }
}
