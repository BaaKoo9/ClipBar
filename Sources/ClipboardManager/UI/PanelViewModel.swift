import AppKit
import ClipboardManagerCore
import Foundation

/// 面板的共享状态：历史数据、搜索、后续的置顶与粘贴队列。
@MainActor
final class PanelViewModel: ObservableObject {
    @Published var searchText = ""
    @Published var items: [ClipboardItem] = []

    private var loaded = false

    func loadHistory() {
        guard !loaded else { return }
        loaded = true
        refresh()
    }

    func panelDidOpen() {
        loadHistory()
    }

    func panelDidClose() {}

    /// 搜索框内容变化时调用。
    func searchDidChange() {
        refresh()
    }

    private func refresh() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            ClipboardStore.shared.fetchAll { [weak self] items in
                DispatchQueue.main.async { self?.items = items }
            }
        } else {
            ClipboardStore.shared.search(query) { [weak self] items in
                DispatchQueue.main.async { self?.items = items }
            }
        }
    }
}
