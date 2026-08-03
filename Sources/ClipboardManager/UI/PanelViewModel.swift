import AppKit
import ClipboardManagerCore
import Foundation

/// 面板的共享状态：历史数据、选中项、搜索与回填。
@MainActor
final class PanelViewModel: ObservableObject {
    @Published var searchText = ""
    @Published var items: [ClipboardItem] = []
    @Published var selectedID: Int64?

    /// AppDelegate 注入：请求关闭面板（Esc、粘贴完成后等）。
    var onRequestClose: (() -> Void)?

    private var loaded = false

    // MARK: - 生命周期

    func loadHistory() {
        guard !loaded else { return }
        loaded = true
        refresh()
    }

    func panelDidOpen() {
        loadHistory()
        if selectedID == nil {
            selectedID = items.first?.id
        }
    }

    func panelDidClose() {
        if !searchText.isEmpty {
            searchText = ""
        }
    }

    // MARK: - 搜索

    func searchDidChange() {
        refresh()
    }

    private func refresh() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            ClipboardStore.shared.fetchAll { [weak self] items in
                DispatchQueue.main.async { self?.apply(items) }
            }
        } else {
            ClipboardStore.shared.search(query) { [weak self] items in
                DispatchQueue.main.async { self?.apply(items) }
            }
        }
    }

    private func apply(_ newItems: [ClipboardItem]) {
        items = newItems
        if let selectedID, items.contains(where: { $0.id == selectedID }) {
            return
        }
        selectedID = items.first?.id
    }

    // MARK: - 键盘导航

    var selectedItem: ClipboardItem? {
        items.first { $0.id == selectedID }
    }

    func moveSelection(offset: Int) {
        guard !items.isEmpty else { return }
        let currentIndex = items.firstIndex { $0.id == selectedID } ?? -1
        let newIndex = min(max(currentIndex + offset, 0), items.count - 1)
        selectedID = items[newIndex].id
    }

    // MARK: - 操作

    func pasteSelected() {
        guard let item = selectedItem else { return }
        if let hash = PasteService.shared.writeToPasteboard(item) {
            ClipboardMonitor.shared.ignore(hash: hash)
        }
        if AppSettings.shared.autoPasteEnabled, PasteService.hasAccessibilityPermission {
            PasteService.injectCommandV()
        }
        onRequestClose?()
    }

    func togglePin(_ item: ClipboardItem) {
        ClipboardStore.shared.setPinned(id: item.id, pinned: !item.pinned) { [weak self] in
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    func deleteItem(_ item: ClipboardItem) {
        ClipboardStore.shared.delete(id: item.id) { [weak self] in
            DispatchQueue.main.async { self?.refresh() }
        }
    }
}
