import AppKit
import ClipboardManagerCore
import SwiftUI

/// 屏幕底部的快照条：分类筛选 + 横向卡片列表 + 搜索 + 键盘导航。
struct SnapshotBarView: View {
    @ObservedObject var viewModel: PanelViewModel
    @FocusState private var searchFocused: Bool

    /// 所有类型统一卡片尺寸（竞品常见做法：固定宽高 + 横向滚动，不随屏幕摊扁）。
    private static let cardWidth: CGFloat = 168
    private static let cardHeight: CGFloat = 118
    private static let cardSpacing: CGFloat = 10

    var body: some View {
        snapshotContent
    }

    private var snapshotContent: some View {
        VStack(spacing: 0) {
            topBar
            filterBar
            Divider()

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

            Divider()
            hintBar
        }
        // 入队提示改由侧边队列窗承担，面板内不再插入 queueBar，避免顶起卡片行
        .frame(minWidth: 560, maxWidth: .infinity, minHeight: 268, maxHeight: 268)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 40, y: 14)
        .onAppear {
            searchFocused = true
        }
        .onChange(of: viewModel.searchText) { _, _ in
            viewModel.searchDidChange()
        }
    }

    // MARK: - 顶栏

    private var topBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            TextField("搜索历史…", text: $viewModel.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
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

            Button {
                viewModel.openSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("设置")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - 分类筛选

    private var filterBar: some View {
        HStack(spacing: 6) {
            FilterChip(title: "全部", isSelected: viewModel.filterKind == nil) {
                viewModel.setFilter(nil)
            }
            FilterChip(title: "文本", isSelected: viewModel.filterKind == .text) {
                viewModel.setFilter(.text)
            }
            FilterChip(title: "链接", isSelected: viewModel.filterKind == .link) {
                viewModel.setFilter(.link)
            }
            FilterChip(title: "图片", isSelected: viewModel.filterKind == .image) {
                viewModel.setFilter(.image)
            }
            FilterChip(title: "文件", isSelected: viewModel.filterKind == .file) {
                viewModel.setFilter(.file)
            }

            Spacer()

            Text("\(viewModel.items.count) 条")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    // MARK: - 快照卡片

    private var snapshotScroller: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .center, spacing: Self.cardSpacing) {
                    ForEach(viewModel.items) { item in
                        SnapshotCard(
                            item: item,
                            isSelected: item.id == viewModel.selectedID,
                            highlight: viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines),
                            onSelect: {
                                viewModel.selectedID = item.id
                                viewModel.pasteSelected()
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
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
            .onChange(of: viewModel.scrollRequestID) { _, newID in
                if let newID {
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
                    .foregroundStyle(Color.primary.opacity(0.78))
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
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? .white : .secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(isSelected ? Color.accentColor : Color.primary.opacity(0.05), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 快照卡片

private struct SnapshotCard: View {
    let item: ClipboardItem
    let isSelected: Bool
    let highlight: String
    var onSelect: () -> Void
    var onEnqueue: () -> Void
    var onDelete: () -> Void
    var onTogglePin: () -> Void
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            headerRow
            contentBody
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            isSelected
                ? Color.accentColor
                : (isHovering ? Color.primary.opacity(0.08) : Color.primary.opacity(0.04))
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    isSelected ? Color.accentColor : Color.primary.opacity(isHovering ? 0.16 : 0.08),
                    lineWidth: isSelected ? 2 : 1
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture {
            let isCommand = NSEvent.modifierFlags.contains(.command)
                || (NSApp.currentEvent?.modifierFlags.contains(.command) == true)
            if isCommand {
                onEnqueue()
            } else {
                onSelect()
            }
        }
        .onHover { hovering in
            isHovering = hovering
        }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .animation(.easeOut(duration: 0.12), value: isSelected)
    }

    private var headerRow: some View {
        HStack(spacing: 4) {
            Image(systemName: iconName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isSelected ? Color.white.opacity(0.9) : Color.secondary)
            Text(typeLabel)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)

            if item.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(isSelected ? .white : .orange)
            }

            Spacer(minLength: 0)

            if isHovering {
                HStack(spacing: 4) {
                    CardIconButton(
                        systemName: item.pinned ? "pin.slash" : "pin",
                        help: item.pinned ? "取消置顶" : "置顶",
                        isSelected: isSelected,
                        action: onTogglePin
                    )
                    CardIconButton(
                        systemName: "xmark",
                        help: "删除",
                        isSelected: isSelected,
                        action: onDelete
                    )
                }
            }
        }
        .frame(height: 20)
    }

    @ViewBuilder
    private var contentBody: some View {
        if item.kind == .image {
            SnapshotThumbnail(path: item.imagePath)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text(highlightedPreview)
                .font(.system(size: 12))
                .lineLimit(4)
                .lineSpacing(1)
                .multilineTextAlignment(.leading)
                .foregroundStyle(isSelected ? .white : .primary)
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
                attributed[attrRange].foregroundColor = isSelected ? .white : .accentColor
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

    private var typeLabel: String {
        switch item.kind {
        case .text: "文本"
        case .link: "链接"
        case .image: "图片"
        case .file: "文件"
        }
    }
}

private struct CardIconButton: View {
    let systemName: String
    let help: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary.opacity(0.75))
                .frame(width: 20, height: 20)
                .background(
                    (isSelected ? Color.white : Color.primary.opacity(0.08)),
                    in: Circle()
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct SnapshotThumbnail: View {
    let path: String?
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
        .task(id: path) {
            guard let path else { return }
            if let cached = Self.cache.object(forKey: path as NSString) {
                image = cached
                return
            }
            let loaded = await Task.detached(priority: .utility) { () -> NSImage? in
                NSImage(contentsOfFile: path)
            }.value
            if let loaded {
                Self.cache.setObject(loaded, forKey: path as NSString)
                image = loaded
            }
        }
    }
}
