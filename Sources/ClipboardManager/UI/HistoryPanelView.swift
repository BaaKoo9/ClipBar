import SwiftUI

struct HistoryPanelView: View {
    @ObservedObject var viewModel: PanelViewModel

    var body: some View {
        VStack(spacing: 0) {
            searchField
                .padding(12)

            Divider()

            emptyState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 32)
        }
        .frame(width: 380, height: 420)
        .background(Color.clear)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索历史…", text: $viewModel.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.05), in: Capsule())
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("复制内容会显示在这里")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }
}
