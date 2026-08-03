import AppKit
import ClipboardManagerCore
import SwiftUI

struct HistoryPanelView: View {
    @ObservedObject var viewModel: PanelViewModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        if viewModel.showsSettings {
            SettingsView(viewModel: viewModel)
        } else {
            historyContent
        }
    }

    private var historyContent: some View {
        VStack(spacing: 0) {
            searchField
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

            Divider()

            if viewModel.items.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                itemList
            }

            if !viewModel.pasteQueue.isEmpty {
                queueBar
            }

            Divider()
            footer
        }
        .frame(width: 380, height: 440)
        .background(Color.clear)
        .onAppear {
            searchFocused = true
        }
        .onChange(of: viewModel.searchText) { _, _ in
            viewModel.searchDidChange()
        }
    }

    // MARK: - 搜索框

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索历史…", text: $viewModel.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFocused)
                .onKeyPress(.upArrow) {
                    viewModel.moveSelection(offset: -1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    viewModel.moveSelection(offset: 1)
                    return .handled
                }
                .onKeyPress(.escape) {
                    viewModel.onRequestClose?()
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
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.05), in: Capsule())
    }

    // MARK: - 列表

    private var itemList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(viewModel.items) { item in
                        HistoryRow(
                            item: item,
                            isSelected: item.id == viewModel.selectedID,
                            highlight: viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            viewModel.selectedID = item.id
                        }
                        .onTapGesture(count: 2) {
                            viewModel.selectedID = item.id
                            viewModel.pasteSelected()
                        }
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
                            Button("删除", role: .destructive) {
                                viewModel.deleteItem(item)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: viewModel.selectedID) { _, newID in
                if let newID {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(newID, anchor: .center)
                    }
                }
            }
        }
    }

    // MARK: - 队列条

    private var queueBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "list.number")
                .font(.system(size: 11))
                .foregroundStyle(Color.accentColor)
            Text("待粘贴 \(viewModel.pasteQueue.count) 项")
                .font(.system(size: 11, weight: .medium))
            Text("关闭面板后依次粘贴")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer()
            Button {
                viewModel.clearQueue()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("清空队列")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.08))
    }

    // MARK: - 空状态 / 底部

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text(viewModel.searchText.isEmpty ? "复制内容会显示在这里" : "没有匹配的结果")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Text("↑↓ 选择")
            Text("回车 粘贴")
            Text("⌘↵ 入队")
            Spacer()
            Button {
                viewModel.openSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("设置")
        }
        .font(.system(size: 10))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

// MARK: - 行

private struct HistoryRow: View {
    let item: ClipboardItem
    let isSelected: Bool
    let highlight: String
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            if item.kind == .image {
                ThumbnailView(path: item.imagePath)
            } else {
                Image(systemName: iconName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? .white : Color.secondary)
                    .frame(width: 18)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(highlightedPreview)
                    .lineLimit(2)
                    .foregroundStyle(isSelected ? .white : .primary)
                Text("\(typeLabel) · \(Self.relativeTime(item.updatedAt))")
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
            }

            Spacer(minLength: 6)

            if item.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(isSelected ? .white : .orange)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(rowBackground)
        .onHover { hovering in
            isHovering = hovering
        }
        .overlay(alignment: .bottom) {
            if !isSelected {
                Divider()
            }
        }
    }

    private var rowBackground: Color {
        if isSelected { return Color.accentColor }
        if isHovering { return Color.primary.opacity(0.045) }
        return Color.clear
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
                attributed[attrRange].font = .system(size: 13, weight: .bold)
                if isSelected {
                    attributed[attrRange].foregroundColor = .white
                } else {
                    attributed[attrRange].foregroundColor = .accentColor
                }
            }
            if range.upperBound == searchStart {
                break
            }
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

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private static func relativeTime(_ date: Date) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - 缩略图

private struct ThumbnailView: View {
    let path: String?
    @State private var image: NSImage?

    private static let cache = NSCache<NSString, NSImage>()

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(0.05))
                    .overlay {
                        Image(systemName: "photo")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
            }
        }
        .frame(width: 40, height: 40)
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
