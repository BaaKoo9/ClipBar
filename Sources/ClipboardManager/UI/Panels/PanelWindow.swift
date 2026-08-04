import AppKit

/// 可成为 key window 的无边框面板窗口（底部快照条、设置窗口共用）。
/// 无边框 NSPanel 默认 canBecomeKey == false，会导致搜索框、键盘快捷键全部失效。
final class PanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
