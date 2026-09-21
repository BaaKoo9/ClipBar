/// 粘贴队列会话的纯决策。窗口可见即会话进行中；开关、关闭按钮和空队列粘贴会结束并清空。
public enum QueueSessionPolicy {
    public static let pasteKeyCode = 9
    public static let commandModifier: UInt = 256
    public static let shiftModifier: UInt = 512
    public static let optionModifier: UInt = 2048
    public static let controlModifier: UInt = 4096

    public enum ToggleAction: Equatable {
        case startSession
        case endSession
    }

    public enum OpenSeedAction: Equatable {
        case enqueueCurrentClipboard
        case enqueueSelectedText
        case showEmptyQueue
    }

    public enum PasteAction: Equatable {
        /// 放行系统粘贴，不动会话。
        case ignore
        /// 吞掉这次粘贴并结束会话。
        case swallowAndEnd
        /// 出队头并放行这次粘贴。
        case dequeueAndPass
        /// 出最后一项、结束会话，并放行这次粘贴。
        case dequeueAndEnd
    }

    public static func toggleAction(isSessionActive: Bool) -> ToggleAction {
        isSessionActive ? .endSession : .startSession
    }

    /// 第一次打开：剪贴板因注入 ⌘C 而变化才入队，否则出空队列。
    public static func openSeedAction(
        didClipboardChange: Bool,
        isIgnoredApp: Bool,
        hasSelectedText: Bool = false
    ) -> OpenSeedAction {
        if isIgnoredApp { return .showEmptyQueue }
        if didClipboardChange { return .enqueueCurrentClipboard }
        if hasSelectedText { return .enqueueSelectedText }
        return .showEmptyQueue
    }

    public static func pasteAction(
        isSessionActive: Bool,
        queueCount: Int,
        isSecureInput: Bool,
        bypassPanelPaste: Bool
    ) -> PasteAction {
        guard isSessionActive else { return .ignore }
        if isSecureInput || bypassPanelPaste { return .ignore }
        if queueCount <= 0 { return .swallowAndEnd }
        if queueCount == 1 { return .dequeueAndEnd }
        return .dequeueAndPass
    }

    public static func shouldEnqueueClipboardChange(
        isSessionActive: Bool,
        isSelfWrite: Bool,
        isIgnoredApp: Bool,
        alreadyConsumed: Bool
    ) -> Bool {
        isSessionActive && !isSelfWrite && !isIgnoredApp && !alreadyConsumed
    }

    /// 清空或删光后仍保持空窗会话。
    public static func shouldKeepSessionAfterClearingItems() -> Bool {
        true
    }

    /// ⌘V 与 ⇧⌘V 算出队；⌥⌘V / ⌃⌘V 不算，以免抢走面板热键。
    public static func isPasteChord(keyCode: Int, carbonModifiers: UInt) -> Bool {
        guard keyCode == pasteKeyCode else { return false }
        let hasCommand = carbonModifiers & commandModifier != 0
        let hasOption = carbonModifiers & optionModifier != 0
        let hasControl = carbonModifiers & controlModifier != 0
        return hasCommand && !hasOption && !hasControl
    }
}
