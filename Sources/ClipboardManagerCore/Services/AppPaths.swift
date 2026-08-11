import Foundation

/// 应用支持目录等路径；含旧版 `ClipboardManager` 目录迁移。
public enum AppPaths {
    public static let supportFolderName = "ClipBar"
    private static let legacySupportFolderName = "ClipboardManager"

    public static func supportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent(supportFolderName, isDirectory: true)
        let legacy = base.appendingPathComponent(legacySupportFolderName, isDirectory: true)
        migrateSupportDirectory(from: legacy, to: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static func imagesDirectory() -> URL {
        let dir = supportDirectory().appendingPathComponent("Images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static func rtfDirectory() -> URL {
        let dir = supportDirectory().appendingPathComponent("RTF", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static func updatesDirectory() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("ClipBarUpdates", isDirectory: true)
        let legacy = base.appendingPathComponent("ClipboardManagerUpdates", isDirectory: true)
        migrateIfNeeded(from: legacy, to: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 解析媒体文件真实路径：兼容改名后 DB 里残留的旧绝对路径。
    public static func resolveExistingPath(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let fm = FileManager.default
        if fm.fileExists(atPath: path) { return path }

        let remapped = remapLegacySupportPath(path)
        if remapped != path, fm.fileExists(atPath: remapped) {
            return remapped
        }

        let name = (path as NSString).lastPathComponent
        guard !name.isEmpty else { return nil }
        let inImages = imagesDirectory().appendingPathComponent(name).path
        if fm.fileExists(atPath: inImages) { return inImages }
        let inRTF = rtfDirectory().appendingPathComponent(name).path
        if fm.fileExists(atPath: inRTF) { return inRTF }
        return nil
    }

    public static func remapLegacySupportPath(_ path: String) -> String {
        path
            .replacingOccurrences(
                of: "/Application Support/\(legacySupportFolderName)/",
                with: "/Application Support/\(supportFolderName)/"
            )
            .replacingOccurrences(
                of: "/Application Support/\(legacySupportFolderName)",
                with: "/Application Support/\(supportFolderName)"
            )
    }

    private static func migrateSupportDirectory(from legacy: URL, to dir: URL) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path), fm.fileExists(atPath: legacy.path) {
            try? fm.moveItem(at: legacy, to: dir)
            return
        }
        // 两边都存在时：把旧目录残留的 Images/RTF 文件合并过来，避免图片「显示异常」
        guard fm.fileExists(atPath: dir.path), fm.fileExists(atPath: legacy.path) else { return }
        mergeDirectory(
            from: legacy.appendingPathComponent("Images", isDirectory: true),
            to: dir.appendingPathComponent("Images", isDirectory: true)
        )
        mergeDirectory(
            from: legacy.appendingPathComponent("RTF", isDirectory: true),
            to: dir.appendingPathComponent("RTF", isDirectory: true)
        )
    }

    private static func mergeDirectory(from legacy: URL, to dir: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacy.path) else { return }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let items = try? fm.contentsOfDirectory(atPath: legacy.path) else { return }
        for name in items {
            let src = legacy.appendingPathComponent(name)
            let dst = dir.appendingPathComponent(name)
            guard !fm.fileExists(atPath: dst.path) else { continue }
            try? fm.copyItem(at: src, to: dst)
        }
    }

    private static func migrateIfNeeded(from legacy: URL, to dir: URL) {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: dir.path), fm.fileExists(atPath: legacy.path) else { return }
        try? fm.moveItem(at: legacy, to: dir)
    }
}
