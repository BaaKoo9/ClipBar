import Foundation

/// 面板的共享状态。骨架阶段先占位，后续逐步接入历史、搜索、队列等。
@MainActor
final class PanelViewModel: ObservableObject {
    @Published var searchText = ""

    func panelDidOpen() {}
    func panelDidClose() {}
}
