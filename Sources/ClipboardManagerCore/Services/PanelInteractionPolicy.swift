/// 面板选择与滚动策略。保持为纯函数，便于回归测试交互边界。
public enum PanelInteractionPolicy {
    public enum KeyAction: Equatable {
        case left, right, close, paste, enqueue, search
    }

    /// macOS 13 键盘桥接策略：输入法组合和其他编辑器优先，搜索回车由 onSubmit 处理。
    public static func keyAction(
        keyCode: UInt16, command: Bool, modified: Bool,
        searching: Bool, composing: Bool, editingOtherText: Bool
    ) -> KeyAction? {
        guard !composing, !editingOtherText, !modified else { return nil }
        switch keyCode {
        case 123: return .left
        case 124: return .right
        case 53: return .close
        case 36, 76: return command ? .enqueue : (searching ? nil : .paste)
        case 3: return command && !searching ? .search : nil
        default: return nil
        }
    }
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

    /// 把源元素移动到目标元素所在方向的另一侧，适配拖拽经过目标行时的即时重排。
    public static func moving<Element>(
        _ elements: [Element],
        from sourceIndex: Int,
        over targetIndex: Int
    ) -> [Element] {
        guard elements.indices.contains(sourceIndex),
              elements.indices.contains(targetIndex),
              sourceIndex != targetIndex else { return elements }

        var reordered = elements
        let moved = reordered.remove(at: sourceIndex)
        reordered.insert(moved, at: targetIndex)
        return reordered
    }

    /// 固定行高列表按拖动距离计算目标位置，越过半行才切换目标。
    public static func dragTargetIndex(
        sourceIndex: Int,
        itemCount: Int,
        translation: Double,
        itemStride: Double
    ) -> Int? {
        guard itemCount > 0,
              (0..<itemCount).contains(sourceIndex),
              itemStride > 0 else { return nil }
        let offset = Int((translation / itemStride).rounded())
        return min(max(sourceIndex + offset, 0), itemCount - 1)
    }
}

/// 拖拽时只追踪目标，松手后才生成一次排序提案，避免悬停阶段反复重排真实列表。
public struct DeferredReorderState<ID: Equatable>: Equatable {
    public struct Proposal: Equatable {
        public let sourceID: ID
        public let targetID: ID?
    }

    public private(set) var draggedID: ID?
    public private(set) var targetID: ID?
    public private(set) var isTargetActive = false

    public init() {}

    public mutating func begin(dragging id: ID) {
        draggedID = id
        targetID = nil
        isTargetActive = false
    }

    public mutating func hover(over id: ID?) {
        guard draggedID != nil else { return }
        targetID = id
        isTargetActive = true
    }

    public mutating func finish() -> Proposal? {
        defer { reset() }
        guard let draggedID, isTargetActive, draggedID != targetID else { return nil }
        return Proposal(sourceID: draggedID, targetID: targetID)
    }

    public mutating func reset() {
        draggedID = nil
        targetID = nil
        isTargetActive = false
    }
}
