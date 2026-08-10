import Foundation

/// 文件日志，用于排查快捷键等运行问题。
///
/// 写入全部下沉到后台串行队列，并复用常驻 FileHandle；消息用 @autoclosure 延迟求值，
/// 让字符串插值也不占用调用方线程。日志因此不会出现在热键、粘贴等交互路径的耗时里。
public enum DebugLog {
    private static let queue = DispatchQueue(label: "com.huxiaolong.clipboard.log", qos: .utility)
    private static var handle: FileHandle?
    private static var handleReady = false

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    public static func write(_ message: @autoclosure @escaping () -> String) {
        let timestamp = Date()
        queue.async {
            guard let handle = currentHandle() else { return }
            let line = "\(formatter.string(from: timestamp)) \(message())\n"
            guard let data = line.data(using: .utf8) else { return }
            try? handle.write(contentsOf: data)
        }
    }

    /// 仅在专用队列上调用。
    private static func currentHandle() -> FileHandle? {
        if handleReady { return handle }
        handleReady = true

        let url = AppPaths.supportDirectory().appendingPathComponent("debug.log")

        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        // 日志超过 2MB 时截断，避免无限增长拖慢写入。
        if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
           size > 2 * 1024 * 1024 {
            try? Data().write(to: url)
        }

        handle = try? FileHandle(forWritingTo: url)
        try? handle?.seekToEnd()
        return handle
    }
}
