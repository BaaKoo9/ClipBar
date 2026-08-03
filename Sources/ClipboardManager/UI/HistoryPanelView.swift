import ClipboardManagerCore
import SwiftUI

struct HistoryPanelView: View {
    @ObservedObject var viewModel: PanelViewModel
    @FocusState private var searchFocused: Bool

    var body: some View {
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
                        HistoryRow(item: item, isSelected: item.id == viewModel.selectedID)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                viewModel.selectedID = item.id
                            }
                            .onTapGesture(count: 2) {
                                viewModel.selectedID = item.id
                                viewModel.pasteSelected()
                            }
                            .contextMenu {
                                Button(item.pinned ? "取消置顶" : "置顶") {
                                    viewModel.togglePin(item)
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
            Text("⌥⌘V 呼出")
        }
        .font(.system(size: 10))
        .foregroundStyle(.tertiary)
        .padding(.vertical, 6)
    }
}

// MARK: - 行

private struct HistoryRow: View {
    let item: ClipboardItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isSelected ? .white : Color.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.previewLine.isEmpty ? "（空内容）" : item.previewLine)
                    .font(.system(size: 13))
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
        .background(isSelected ? Color.accentColor : Color.clear)
        .overlay(alignment: .bottom) {
            if !isSelected {
                Divider()
            }
        }
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
