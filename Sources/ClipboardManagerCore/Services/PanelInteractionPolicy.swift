/// 面板选择与滚动策略。保持为纯函数，便于回归测试交互边界。
public enum PanelInteractionPolicy {
    public enum FocusIntent {
        case panelOpened
        case searchRequested
    }

    public enum FocusTarget: Equatable {
        case panel
        case searchField
    }

    /// 呼出时先保证选择/悬停流畅；只有用户明确搜索时才激活输入法。
    public static func focusTarget(for intent: FocusIntent) -> FocusTarget {
        switch intent {
        case .panelOpened: .panel
        case .searchRequested: .searchField
        }
    }

    public static func selectionIndex(
        currentIndex: Int?,
        itemCount: Int,
        offset: Int
    ) -> Int? {
        guard itemCount > 0 else { return nil }
        let index = (currentIndex ?? -1) + offset
        return min(max(index, 0), itemCount - 1)
    }

    /// 目标卡片已在可视区时，不再触发 ScrollView 的布局与动画。
    public static func shouldScroll(targetID: Int64, visibleIDs: Set<Int64>) -> Bool {
        !visibleIDs.contains(targetID)
    }
}
