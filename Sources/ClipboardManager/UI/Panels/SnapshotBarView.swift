import AppKit
import ClipboardManagerCore
import SwiftUI

/// 屏幕底部的快照条：分类筛选 + 横向卡片列表 + 搜索 + 键盘导航。
struct SnapshotBarView: View {
    @ObservedObject var viewModel: PanelViewModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        snapshotContent
    }

    private var snapshotContent: some View {
        VStack(spacing: 0) {
            topBar

            filterBar

            Divider()

            if viewModel.items.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                snapshotScroller
            }

            if viewModel.pasteQueue.count > 0 {
                queueBar
            }

            Divider()
            hintBar
        }
        .frame(minWidth: 560, maxWidth: .infinity, minHeight: 260, maxHeight: 280)
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

            if let count = viewModel.items.count as Int? {
                Text("\(count) 条")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    // MARK: - 快照卡片

    private var snapshotScroller: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 10) {
                        ForEach(viewModel.items) { item in
                            SnapshotCard(
                                item: item,
                                isSelected: item.id == viewModel.selectedID,
                                highlight: viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines),
                                onEnqueue: {
                                    viewModel.selectedID = item.id
                                    viewModel.enqueueSelected()
                                }
                            )
                            .frame(width: Self.cardWidth(for: geo.size.width, count: viewModel.items.count), height: 108)
                            .contentShape(Rectangle())
                            .gesture(
                                SpatialTapGesture()
                                    .onEnded { _ in
                                        let isCommand = (NSApp.currentEvent?.modifierFlags.contains(.command) == true)
                                            || NSEvent.modifierFlags.contains(.command)
                                        if isCommand {
                                            viewModel.selectedID = item.id
                                            viewModel.enqueueSelected()
                                        } else {
                                            // 单击直接粘贴（CleanClip 风格）
                                            viewModel.selectedID = item.id
                                            viewModel.pasteSelected()
                                        }
                                    }
                            )
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
                    .padding(.vertical, 4)
                }
                .onChange(of: viewModel.scrollRequestID) { _, newID in
                    if let newID {
                        proxy.scrollTo(newID, anchor: .center)
                    }
                }
            }
        }
    }

    /// 卡片宽度：条目少时摊宽铺满，条目多时收敛到最小宽度横向滚动。
    private static func cardWidth(for total: CGFloat, count: Int) -> CGFloat {
        let safeCount = max(count, 1)
        let gaps = CGFloat(safeCount - 1) * 10
        let natural = (total - 28 - gaps) / CGFloat(safeCount)
        return min(max(natural, 140), 260)
    }

    // MARK: - 队列条

    private var queueBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "list.number")
                .font(.system(size: 11))
                .foregroundStyle(Color.accentColor)
            Text("待粘贴队列 \(viewModel.pasteQueue.count) 项")
                .font(.system(size: 11, weight: .medium))
            Text("按出队快捷键逐个粘贴")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer()
            Button {
                viewModel.clearQueue()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("清空队列")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(Color.accentColor.opacity(0.08))
    }

    // MARK: - 空状态 / 提示

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)
            Text(viewModel.searchText.isEmpty ? "复制内容会显示在这里" : "没有匹配的结果")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }

    private var hintBar: some View {
        HStack(spacing: 16) {
            Text("←→ 选择")
            Text("回车 粘贴")
            Text("⌘+点击/⌘↵ 入队")
            Text("Esc 关闭")
            Spacer()
            Text("⌥⌘E 入队复制 · ⌥⌘D 出队粘贴")
                .foregroundStyle(.tertiary)
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
    var onEnqueue: () -> Void
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 顶部行：类型标记 + 置顶 + 入队按钮
            HStack(spacing: 5) {
                if item.kind != .image {
                    Image(systemName: iconName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(isSelected ? .white : Color.secondary)
                    Text(typeLabel)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                }
                Spacer(minLength: 0)
                if item.pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(isSelected ? .white : .orange)
                }
                if isHovering && !isSelected {
                    Button(action: onEnqueue) {
                        Image(systemName: "list.badge.plus")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 20, height: 20)
                            .background(Color.white.opacity(0.9), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("加入粘贴队列")
                }
            }

            if item.kind == .image {
                // 图片：主体铺满缩略图，不再重复显示“图片”文字
                Spacer(minLength: 0)
                SnapshotThumbnail(path: item.imagePath, size: 96)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Spacer(minLength: 0)
            } else {
                Text(highlightedPreview)
                    .font(.system(size: 12))
                    .lineLimit(4)
                    .foregroundStyle(isSelected ? .white : .primary)
                Spacer(minLength: 0)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            isSelected ? Color.accentColor : (isHovering ? Color.white.opacity(0.7) : Color.white.opacity(0.5))
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isSelected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: isSelected ? 2 : 1)
        )
        .scaleEffect(isHovering && !isSelected ? 1.02 : 1)
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
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

private struct SnapshotThumbnail: View {
    let path: String?
    let size: CGFloat
    @State private var image: NSImage?

    private static let cache = NSCache<NSString, NSImage>()

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.primary.opacity(0.08))
                    .overlay {
                        Image(systemName: "photo")
                            .font(.system(size: 14))
                            .foregroundStyle(.tertiary)
                    }
            }
        }
        .frame(minWidth: size, idealWidth: 96, maxWidth: .infinity, minHeight: size, idealHeight: 96, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 8))
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
