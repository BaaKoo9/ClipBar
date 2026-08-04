import AppKit
import ClipboardManagerCore

enum ScreenHelper {
    /// 当前活跃屏幕：鼠标所在屏优先，其次前台 App 主窗口所在屏，最后主屏。
    static var activeScreen: NSScreen {
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) {
            DebugLog.write("屏幕选择：鼠标屏 \(NSStringFromRect(screen.frame))")
            return screen
        }
        if let screen = frontmostAppScreen() {
            DebugLog.write("屏幕选择：前台 App 窗口屏 \(NSStringFromRect(screen.frame))")
            return screen
        }
        let main = NSScreen.main ?? NSScreen.screens[0]
        DebugLog.write("屏幕选择：鼠标 \(mouse) 未命中，回退主屏 \(NSStringFromRect(main.frame))")
        return main
    }

    /// 前台 App 最大窗口所在的屏幕。
    private static func frontmostAppScreen() -> NSScreen? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let pidNumber = NSNumber(value: pid)
        var best: (CGRect, CGFloat)?
        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? NSNumber) == pidNumber,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let cgRect = CGRect(
                x: bounds["X"] ?? 0,
                y: bounds["Y"] ?? 0,
                width: bounds["Width"] ?? 0,
                height: bounds["Height"] ?? 0
            )
            let area = cgRect.width * cgRect.height
            if let best, best.1 > area { continue }
            best = (cgRect, area)
        }
        guard let (cgRect, _) = best else { return nil }
        // CG 坐标（原点左上）转 AppKit 坐标（原点左下）
        let topY = NSScreen.screens.map { $0.frame.maxY }.max() ?? 0
        let cocoaRect = CGRect(x: cgRect.minX, y: topY - cgRect.maxY, width: cgRect.width, height: cgRect.height)
        return NSScreen.screens.first { $0.frame.intersects(cocoaRect) }
    }
}
