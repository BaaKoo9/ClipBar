import Foundation

/// 应用支持目录等路径；含旧版 `ClipboardManager` 目录迁移。
public enum AppPaths {
    public static let supportFolderName = "ClipBar"
    private static let legacySupportFolderName = "ClipboardManager"

    public static func supportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent(supportFolderName, isDirectory: true)
        let legacy = base.appendingPathComponent(legacySupportFolderName, isDirectory: true)
        migrateIfNeeded(from: legacy, to: dir)
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

    private static func migrateIfNeeded(from legacy: URL, to dir: URL) {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: dir.path), fm.fileExists(atPath: legacy.path) else { return }
        try? fm.moveItem(at: legacy, to: dir)
    }
}
