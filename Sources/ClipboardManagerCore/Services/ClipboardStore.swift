import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// 基于 SQLite 的本地历史存储。
/// 所有读写都在专用串行队列执行，UI 通过回调拿到结果。
public final class ClipboardStore {
    public static let shared = ClipboardStore()

    private var db: OpaquePointer?
    private var insertCount = 0
    private let queue = DispatchQueue(label: "com.huxiaolong.clipboard.store", qos: .userInitiated)

    private let dbURL: URL
    private let imagesDirectory: URL

    private static let itemColumns =
        "id, kind, text, rtf_path, image_path, original_image_path, file_paths, hash, pinned, created_at, updated_at"

    public init(dbURL: URL? = nil, imagesDirectory: URL? = nil) {
        let url = dbURL ?? Self.defaultDBURL()
        self.dbURL = url
        self.imagesDirectory = imagesDirectory ?? Self.defaultImagesDirectory()
        openDatabase()
        createSchema()
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: - 路径

    public static func defaultDBURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("ClipboardManager", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("clipboard.sqlite")
    }

    public static func defaultImagesDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("ClipboardManager/Images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static func defaultRTFDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("ClipboardManager/RTF", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - 基础

    private func openDatabase() {
        try? FileManager.default.createDirectory(
            at: dbURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
    }

    private func createSchema() {
        execute(
            """
            CREATE TABLE IF NOT EXISTS items (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                kind TEXT NOT NULL,
                text TEXT,
                rtf_path TEXT,
                image_path TEXT,
                original_image_path TEXT,
                file_paths TEXT,
                hash TEXT NOT NULL UNIQUE,
                pinned INTEGER NOT NULL DEFAULT 0,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            )
            """
        )
        execute("CREATE INDEX IF NOT EXISTS idx_items_updated ON items(updated_at DESC)")
        migrateIfNeeded()
    }

    /// 旧版本数据库没有 rtf_path 列，这里做增量迁移。
    private func migrateIfNeeded() {
        guard let db else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(items)", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        var hasRTFColumn = false
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let name = sqlite3_column_text(stmt, 1) {
                let column = String(cString: name)
                if column == "rtf_path" {
                    hasRTFColumn = true
                }
            }
        }
        if !hasRTFColumn {
            execute("ALTER TABLE items ADD COLUMN rtf_path TEXT")
        }
    }

    @discardableResult
    private func execute(_ sql: String, _ bindings: [Any?] = []) -> Bool {
        guard let db else { return false }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            print("SQLite prepare failed: \(String(cString: sqlite3_errmsg(db)))")
            return false
        }
        defer { sqlite3_finalize(stmt) }

        for (index, value) in bindings.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case let i as Int:
                sqlite3_bind_int64(stmt, position, Int64(i))
            case let i as Int64:
                sqlite3_bind_int64(stmt, position, i)
            case let d as Double:
                sqlite3_bind_double(stmt, position, d)
            case let s as String:
                sqlite3_bind_text(stmt, position, s, -1, SQLITE_TRANSIENT)
            case let data as Data:
                sqlite3_bind_blob(stmt, position, (data as NSData).bytes, Int32(data.count), SQLITE_TRANSIENT)
            case let bool as Bool:
                sqlite3_bind_int(stmt, position, bool ? 1 : 0)
            case .none:
                sqlite3_bind_null(stmt, position)
            default:
                sqlite3_bind_null(stmt, position)
            }
        }

        let result = sqlite3_step(stmt)
        return result == SQLITE_DONE || result == SQLITE_ROW
    }

    private func query(_ sql: String, _ bindings: [Any?] = []) -> [ClipboardItem] {
        guard let db else { return [] }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            print("SQLite prepare failed: \(String(cString: sqlite3_errmsg(db)))")
            return []
        }
        defer { sqlite3_finalize(stmt) }

        for (index, value) in bindings.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case let i as Int:
                sqlite3_bind_int64(stmt, position, Int64(i))
            case let i as Int64:
                sqlite3_bind_int64(stmt, position, i)
            case let s as String:
                sqlite3_bind_text(stmt, position, s, -1, SQLITE_TRANSIENT)
            case .none:
                sqlite3_bind_null(stmt, position)
            default:
                break
            }
        }

        var items: [ClipboardItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let kindRaw = columnString(stmt, 1)
            let text = columnStringOrNil(stmt, 2)
            let rtfPath = columnStringOrNil(stmt, 3)
            let imagePath = columnStringOrNil(stmt, 4)
            let originalImagePath = columnStringOrNil(stmt, 5)
            let filePathsRaw = columnStringOrNil(stmt, 6)
            let hash = columnString(stmt, 7)
            let pinned = sqlite3_column_int(stmt, 8) == 1
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 9))
            let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 10))

            let filePaths = filePathsRaw.flatMap { raw -> [String] in
                (try? JSONDecoder().decode([String].self, from: Data(raw.utf8))) ?? []
            } ?? []

            items.append(ClipboardItem(
                id: id,
                kind: ClipboardItem.Kind(rawValue: kindRaw) ?? .text,
                text: text,
                rtfPath: rtfPath,
                imagePath: imagePath,
                originalImagePath: originalImagePath,
                filePaths: filePaths,
                hash: hash,
                pinned: pinned,
                createdAt: createdAt,
                updatedAt: updatedAt
            ))
        }
        return items
    }

    private func scalarCount(_ sql: String) -> Int {
        guard let db else { return 0 }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private func columnString(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        columnStringOrNil(stmt, index) ?? ""
    }

    private func columnStringOrNil(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let cString = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cString)
    }

    // MARK: - 写入

    /// 新增或刷新一条记录（按 hash 去重，刷新后移到顶部）。
    public func upsert(_ item: NewClipboardItem) {
        queue.async { [weak self] in
            guard let self else { return }
            let now = Date().timeIntervalSince1970
            if self.exists(hash: item.hash) {
                self.execute(
                    """
                    UPDATE items SET kind = ?, text = ?, rtf_path = ?, image_path = ?, original_image_path = ?,
                        file_paths = ?, updated_at = ?
                    WHERE hash = ?
                    """,
                    [item.kind.rawValue, item.text ?? "", item.rtfPath ?? "", item.imagePath ?? "",
                     item.originalImagePath ?? "", item.filePaths.isEmpty ? nil : self.encodeFilePaths(item.filePaths),
                     now, item.hash]
                )
            } else {
                self.execute(
                    """
                    INSERT INTO items (kind, text, rtf_path, image_path, original_image_path, file_paths, hash, pinned, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?, ?)
                    """,
                    [item.kind.rawValue, item.text ?? "", item.rtfPath ?? "", item.imagePath ?? "",
                     item.originalImagePath ?? "", item.filePaths.isEmpty ? nil : self.encodeFilePaths(item.filePaths),
                     item.hash, now, now]
                )
                self.insertCount += 1
                if self.insertCount % 25 == 0 {
                    self.enforceLimit()
                }
            }
        }
    }

    private func exists(hash: String) -> Bool {
        !query("SELECT \(Self.itemColumns) FROM items WHERE hash = ? LIMIT 1", [hash]).isEmpty
    }

    private func encodeFilePaths(_ paths: [String]) -> String {
        (try? String(data: JSONEncoder().encode(paths), encoding: .utf8)) ?? paths.joined(separator: "\n")
    }

    private func enforceLimit() {
        let total = scalarCount("SELECT COUNT(*) FROM items WHERE pinned = 0")
        let limit = AppSettings.shared.historyLimit
        guard total > limit + 25 else { return }
        execute(
            """
            DELETE FROM items
            WHERE pinned = 0
              AND id NOT IN (
                  SELECT id FROM items
                  WHERE pinned = 0
                  ORDER BY updated_at DESC, id DESC
                  LIMIT ?
              )
            """,
            [limit]
        )
    }

    // MARK: - 读取

    /// 按内容 hash 精确查找（用于入队复制时复用历史缓存）。
    /// 同步版精确查找（在专用串行队列中调用，不阻塞主线程）。
    public func itemSync(hash: String) -> ClipboardItem? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: ClipboardItem?
        item(hash: hash) { item in
            result = item
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 3)
        return result
    }

    public func item(hash: String, completion: @escaping (ClipboardItem?) -> Void) {
        queue.async { [weak self] in
            let items = self?.query("SELECT \(Self.itemColumns) FROM items WHERE hash = ? LIMIT 1", [hash]) ?? []
            completion(items.first)
        }
    }

    public func fetchAll(completion: @escaping ([ClipboardItem]) -> Void) {
        queue.async { [weak self] in
            let items = self?.query("SELECT \(Self.itemColumns) FROM items ORDER BY updated_at DESC, id DESC") ?? []
            completion(items)
        }
    }

    public func search(_ queryText: String, completion: @escaping ([ClipboardItem]) -> Void) {
        let trimmed = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            fetchAll(completion: completion)
            return
        }
        let pattern = "%\(trimmed)%"
        queue.async { [weak self] in
            let items = self?.query(
                """
                SELECT \(Self.itemColumns)
                FROM items
                WHERE text LIKE ? OR file_paths LIKE ?
                ORDER BY updated_at DESC, id DESC
                """,
                [pattern, pattern]
            ) ?? []
            completion(items)
        }
    }

    // MARK: - 管理

    public func setPinned(id: Int64, pinned: Bool, completion: (() -> Void)? = nil) {
        queue.async { [weak self] in
            self?.execute("UPDATE items SET pinned = ? WHERE id = ?", [pinned ? 1 : 0, id])
            completion?()
        }
    }

    public func delete(id: Int64, completion: (() -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            let items = self.query("SELECT \(Self.itemColumns) FROM items WHERE id = ?", [id])
            if let item = items.first {
                self.removeContentFiles(for: item)
            }
            self.execute("DELETE FROM items WHERE id = ?", [id])
            completion?()
        }
    }

    public func clear(completion: (() -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            let items = self.query("SELECT \(Self.itemColumns) FROM items")
            for item in items {
                self.removeContentFiles(for: item)
            }
            self.execute("DELETE FROM items")
            completion?()
        }
    }

    /// 删除与条目关联的缓存文件（图片、RTF），只清理自家目录。
    private func removeContentFiles(for item: ClipboardItem) {
        let imageBase = imagesDirectory.standardizedFileURL.path
        let rtfBase = Self.defaultRTFDirectory().standardizedFileURL.path
        var paths = [item.imagePath, item.originalImagePath, item.rtfPath].compactMap { $0 }
        for path in paths {
            let std = (path as NSString).standardizingPath
            let isSafe = std.hasPrefix(imageBase) || std.hasPrefix(rtfBase)
            guard isSafe else { continue }
            try? FileManager.default.removeItem(atPath: std)
        }
    }
}
