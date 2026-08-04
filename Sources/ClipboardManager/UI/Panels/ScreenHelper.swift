import AppKit

enum ScreenHelper {
    /// 当前活跃屏幕：鼠标所在屏优先，回退主屏。
    static var activeScreen: NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }
}
