import AppKit
import ClipboardManagerCore

enum ScreenHelper {
    /// 当前活跃屏幕：鼠标所在屏优先，回退主屏。
    static var activeScreen: NSScreen {
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) {
            DebugLog.write("屏幕选择：鼠标屏 \(NSStringFromRect(screen.frame))")
            return screen
        }
        let main = NSScreen.main ?? NSScreen.screens[0]
        DebugLog.write("屏幕选择：鼠标 \(mouse) 不在任何屏，回退主屏 \(NSStringFromRect(main.frame))")
        return main
    }
}
