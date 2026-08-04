import Foundation

/// 记录进程启动时刻，用于量化"启动后多久快捷键才真正可用"。
public enum LaunchClock {
    private static var start: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()

    public static func markProcessStart() {
        start = CFAbsoluteTimeGetCurrent()
    }

    /// 距进程启动的毫秒数。
    public static var elapsedMilliseconds: Int {
        Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
    }
}
