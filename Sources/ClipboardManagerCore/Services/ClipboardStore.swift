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
        "id, kind, text, rtf_path, image_path, original_image_path, file_paths, hash, pinned, created_at, updated_at, source_app_bundle_id"

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
        AppPaths.supportDirectory().appendingPathComponent("clipboard.sqlite")
    }

    public static func defaultImagesDirectory() -> URL {
        AppPaths.imagesDirectory()
    }

    public static func defaultRTFDirectory() -> URL {
        AppPaths.rtfDirectory()
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
                updated_at REAL NOT NULL,
                source_app_bundle_id TEXT
            )
            """
        )
        execute("CREATE INDEX IF NOT EXISTS idx_items_updated ON items(updated_at DESC)")
        execute("CREATE INDEX IF NOT EXISTS idx_items_kind_updated ON items(kind, updated_at DESC)")
        execute("CREATE INDEX IF NOT EXISTS idx_items_pinned_updated ON items(pinned, updated_at)")
        execute(
            """
            CREATE TABLE IF NOT EXISTS labels (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL UNIQUE,
                color TEXT NOT NULL DEFAULT 'blue',
                sort_order INTEGER NOT NULL DEFAULT 0,
                created_at REAL NOT NULL
            )
            """
        )
        execute(
            """
            CREATE TABLE IF NOT EXISTS item_labels (
                item_id INTEGER NOT NULL,
                label_id INTEGER NOT NULL,
                PRIMARY KEY (item_id, label_id),
                FOREIGN KEY (item_id) REFERENCES items(id) ON DELETE CASCADE,
                FOREIGN KEY (label_id) REFERENCES labels(id) ON DELETE CASCADE
            )
            """
        )
        execute("CREATE INDEX IF NOT EXISTS idx_item_labels_label ON item_labels(label_id)")
        execute("PRAGMA journal_mode = WAL")
        execute("PRAGMA synchronous = NORMAL")
        migrateIfNeeded()
    }

    /// 旧版本数据库增量迁移（rtf_path / source_app_bundle_id）。
    private func migrateIfNeeded() {
        guard let db else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(items)", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        var columns = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let name = sqlite3_column_text(stmt, 1) {
                columns.insert(String(cString: name))
            }
        }
        if !columns.contains("rtf_path") {
            execute("ALTER TABLE items ADD COLUMN rtf_path TEXT")
        }
        if !columns.contains("source_app_bundle_id") {
            execute("ALTER TABLE items ADD COLUMN source_app_bundle_id TEXT")
        }
        rewriteLegacyMediaPaths()
    }

    /// 改名后 DB 里仍是旧绝对路径时，批量改写到 ClipBar，并尽量找回文件。
    private func rewriteLegacyMediaPaths() {
        guard let db else { return }
        var stmt: OpaquePointer?
        let sql = """
            SELECT id, image_path, original_image_path, rtf_path FROM items
            WHERE image_path LIKE '%ClipboardManager%'
               OR original_image_path LIKE '%ClipboardManager%'
               OR rtf_path LIKE '%ClipboardManager%'
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        var updates: [(Int64, String?, String?, String?)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let image = columnStringOrNil(stmt, 1).map(AppPaths.remapLegacySupportPath)
            let original = columnStringOrNil(stmt, 2).map(AppPaths.remapLegacySupportPath)
            let rtf = columnStringOrNil(stmt, 3).map(AppPaths.remapLegacySupportPath)
            updates.append((id, image, original, rtf))
        }
        for (id, image, original, rtf) in updates {
            execute(
                "UPDATE items SET image_path = ?, original_image_path = ?, rtf_path = ? WHERE id = ?",
                [image, original, rtf, id]
            )
        }
        if !updates.isEmpty {
            DebugLog.write("路径迁移：改写 \(updates.count) 条旧 ClipboardManager 媒体路径")
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
            case let d as Double:
                sqlite3_bind_double(stmt, position, d)
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
            let sourceAppBundleID = columnStringOrNil(stmt, 11)

            let filePaths = filePathsRaw.flatMap { raw -> [String] in
                (try? JSONDecoder().decode([String].self, from: Data(raw.utf8))) ?? []
            } ?? []

            items.append(ClipboardItem(
                id: id,
                kind: ClipboardItem.Kind(rawValue: kindRaw) ?? .text,
                text: text,
                rtfPath: AppPaths.resolveExistingPath(rtfPath) ?? rtfPath,
                imagePath: AppPaths.resolveExistingPath(imagePath) ?? imagePath,
                originalImagePath: AppPaths.resolveExistingPath(originalImagePath) ?? originalImagePath,
                filePaths: filePaths,
                hash: hash,
                pinned: pinned,
                sourceAppBundleID: sourceAppBundleID,
                labelIDs: [],
                createdAt: createdAt,
                updatedAt: updatedAt
            ))
        }
        return attachLabelIDs(items)
    }

    private func attachLabelIDs(_ items: [ClipboardItem]) -> [ClipboardItem] {
        guard !items.isEmpty, let db else { return items }
        let ids = items.map(\.id)
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        var stmt: OpaquePointer?
        let sql = "SELECT item_id, label_id FROM item_labels WHERE item_id IN (\(placeholders))"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return items }
        defer { sqlite3_finalize(stmt) }
        for (index, id) in ids.enumerated() {
            sqlite3_bind_int64(stmt, Int32(index + 1), id)
        }
        var map: [Int64: [Int64]] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let itemID = sqlite3_column_int64(stmt, 0)
            let labelID = sqlite3_column_int64(stmt, 1)
            map[itemID, default: []].append(labelID)
        }
        return items.map { item in
            ClipboardItem(
                id: item.id,
                kind: item.kind,
                text: item.text,
                rtfPath: item.rtfPath,
                imagePath: item.imagePath,
                originalImagePath: item.originalImagePath,
                filePaths: item.filePaths,
                hash: item.hash,
                pinned: item.pinned,
                sourceAppBundleID: item.sourceAppBundleID,
                labelIDs: map[item.id] ?? [],
                createdAt: item.createdAt,
                updatedAt: item.updatedAt
            )
        }
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
                        file_paths = ?, source_app_bundle_id = COALESCE(?, source_app_bundle_id), updated_at = ?
                    WHERE hash = ?
                    """,
                    [item.kind.rawValue, item.text ?? "", item.rtfPath ?? "", item.imagePath ?? "",
                     item.originalImagePath ?? "", item.filePaths.isEmpty ? nil : self.encodeFilePaths(item.filePaths),
                     item.sourceAppBundleID, now, item.hash]
                )
            } else {
                self.execute(
                    """
                    INSERT INTO items (kind, text, rtf_path, image_path, original_image_path, file_paths, hash, pinned, created_at, updated_at, source_app_bundle_id)
                    VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?)
                    """,
                    [item.kind.rawValue, item.text ?? "", item.rtfPath ?? "", item.imagePath ?? "",
                     item.originalImagePath ?? "", item.filePaths.isEmpty ? nil : self.encodeFilePaths(item.filePaths),
                     item.hash, now, now, item.sourceAppBundleID]
                )
                self.insertCount += 1
            }
            self.enforceRetention()
            self.enforceLimit()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .clipboardHistoryDidChange, object: nil)
            }
        }
    }

    /// 删除最近若干秒内误记的「图片类文件」条目（微信等先写 file-url 再写位图）。
    public func deleteRecentUnpinnedImageFiles(withinSeconds: TimeInterval) {
        queue.async { [weak self] in
            guard let self else { return }
            let cutoff = Date().addingTimeInterval(-withinSeconds).timeIntervalSince1970
            let candidates = self.query(
                """
                SELECT \(Self.itemColumns) FROM items
                WHERE pinned = 0 AND kind = 'file' AND updated_at >= ?
                """,
                [cutoff]
            )
            let imageExts: Set<String> = [
                "png", "jpg", "jpeg", "gif", "webp", "tif", "tiff", "bmp", "heic", "heif"
            ]
            var removed = 0
            for item in candidates {
                let allImage = !item.filePaths.isEmpty && item.filePaths.allSatisfy { path in
                    imageExts.contains((path as NSString).pathExtension.lowercased())
                }
                guard allImage else { continue }
                self.removeContentFiles(for: item)
                self.execute("DELETE FROM items WHERE id = ?", [item.id])
                removed += 1
            }
            guard removed > 0 else { return }
            DebugLog.write("清理附属图片文件条目 \(removed) 条")
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .clipboardHistoryDidChange, object: nil)
            }
        }
    }

    /// 只取 id，避免为了判断存在而把整条文本/路径读出来。
    private func exists(hash: String) -> Bool {
        guard let db else { return false }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM items WHERE hash = ? LIMIT 1", -1, &stmt, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, hash, -1, SQLITE_TRANSIENT)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private func encodeFilePaths(_ paths: [String]) -> String {
        (try? String(data: JSONEncoder().encode(paths), encoding: .utf8)) ?? paths.joined(separator: "\n")
    }

    /// 删除超过保留天数且未置顶的条目（按 updated_at）。返回删除条数。
    @discardableResult
    private func enforceRetention() -> Int {
        guard AppSettings.shared.retentionEnabled else { return 0 }
        let days = AppSettings.shared.retentionDays
        let cutoff = Date().addingTimeInterval(-TimeInterval(days) * 24 * 60 * 60).timeIntervalSince1970
        let doomed = query(
            """
            SELECT \(Self.itemColumns) FROM items
            WHERE pinned = 0 AND updated_at < ?
            """,
            [cutoff]
        )
        guard !doomed.isEmpty else { return 0 }
        for item in doomed {
            removeContentFiles(for: item)
        }
        execute("DELETE FROM items WHERE pinned = 0 AND updated_at < ?", [cutoff])
        DebugLog.write("TTL 清理：删除 \(doomed.count) 条（>\(days) 天）")
        return doomed.count
    }

    @discardableResult
    private func enforceLimit() -> Int {
        let limit = max(AppSettings.shared.historyLimit, 1)
        let total = scalarCount("SELECT COUNT(*) FROM items WHERE pinned = 0")
        guard total > limit else { return 0 }

        let doomed = query(
            """
            SELECT \(Self.itemColumns) FROM items
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
        for item in doomed {
            removeContentFiles(for: item)
        }
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
        return doomed.count
    }

    /// 按 TTL + 条数上限立即清理；completion 参数为是否删除了条目。
    public func enforceHistoryLimit(completion: ((Bool) -> Void)? = nil) {
        queue.async { [weak self] in
            let started = CFAbsoluteTimeGetCurrent()
            let removed = (self?.enforceRetention() ?? 0) + (self?.enforceLimit() ?? 0)
            let ms = Int((CFAbsoluteTimeGetCurrent() - started) * 1000)
            if ms > 5 || removed > 0 {
                DebugLog.write("历史清理耗时 \(ms)ms removed=\(removed)")
            }
            if let completion {
                DispatchQueue.main.async { completion(removed > 0) }
            }
        }
    }

    /// 粘贴后刷新使用时间，使条目按「最近使用」提前。
    public func touch(id: Int64, completion: (() -> Void)? = nil) {
        queue.async { [weak self] in
            let now = Date().timeIntervalSince1970
            self?.execute("UPDATE items SET updated_at = ? WHERE id = ?", [now, id])
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .clipboardHistoryDidChange, object: nil)
            }
            completion?()
        }
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

    /// 分类与条数都下推到 SQL：面板只展示有限条目，取回全表既慢又浪费内存。
    public func fetchAll(
        kind: String? = nil,
        labelID: Int64? = nil,
        limit: Int? = nil,
        completion: @escaping ([ClipboardItem]) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else {
                completion([])
                return
            }
            var sql = "SELECT \(Self.itemColumns) FROM items"
            var bindings: [Any?] = []
            var clauses: [String] = []
            if let kind {
                clauses.append("kind = ?")
                bindings.append(kind)
            }
            if let labelID {
                clauses.append("id IN (SELECT item_id FROM item_labels WHERE label_id = ?)")
                bindings.append(labelID)
            }
            if !clauses.isEmpty {
                sql += " WHERE " + clauses.joined(separator: " AND ")
            }
            sql += " ORDER BY pinned DESC, updated_at DESC, id DESC"
            if let limit {
                sql += " LIMIT ?"
                bindings.append(limit)
            }
            completion(self.query(sql, bindings))
        }
    }

    public func search(
        _ queryText: String,
        kind: String? = nil,
        labelID: Int64? = nil,
        limit: Int? = nil,
        completion: @escaping ([ClipboardItem]) -> Void
    ) {
        let trimmed = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        // `#tag`：按标签名筛选；可与剩余文本组合
        var tagName: String?
        var textQuery = trimmed
        if trimmed.hasPrefix("#") {
            let rest = String(trimmed.dropFirst())
            let parts = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            tagName = parts.first.map(String.init)
            textQuery = parts.count > 1 ? String(parts[1]) : ""
        }

        if textQuery.isEmpty, tagName == nil {
            fetchAll(kind: kind, labelID: labelID, limit: limit, completion: completion)
            return
        }

        queue.async { [weak self] in
            guard let self else {
                completion([])
                return
            }
            var sql = "SELECT \(Self.itemColumns) FROM items WHERE 1=1"
            var bindings: [Any?] = []
            if let kind {
                sql += " AND kind = ?"
                bindings.append(kind)
            }
            if let labelID {
                sql += " AND id IN (SELECT item_id FROM item_labels WHERE label_id = ?)"
                bindings.append(labelID)
            }
            if let tagName {
                if tagName.isEmpty {
                    sql += " AND id IN (SELECT item_id FROM item_labels)"
                } else {
                    sql += """
                     AND id IN (
                        SELECT il.item_id FROM item_labels il
                        JOIN labels l ON l.id = il.label_id
                        WHERE l.name LIKE ?
                     )
                    """
                    bindings.append(tagName)
                }
            }
            if !textQuery.isEmpty {
                let pattern = "%\(textQuery)%"
                sql += " AND (text LIKE ? OR file_paths LIKE ?)"
                bindings.append(pattern)
                bindings.append(pattern)
            }
            sql += " ORDER BY pinned DESC, updated_at DESC, id DESC"
            if let limit {
                sql += " LIMIT ?"
                bindings.append(limit)
            }
            completion(self.query(sql, bindings))
        }
    }

    // MARK: - 标签

    public func fetchLabels(completion: @escaping ([ClipboardLabel]) -> Void) {
        queue.async { [weak self] in
            completion(self?.queryLabels() ?? [])
        }
    }

    public func createLabel(name: String, color: String, completion: ((ClipboardLabel?) -> Void)? = nil) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion?(nil)
            return
        }
        queue.async { [weak self] in
            guard let self else {
                completion?(nil)
                return
            }
            let now = Date().timeIntervalSince1970
            let order = self.scalarCount("SELECT COUNT(*) FROM labels")
            let colorName = ClipboardLabel.presetColors.contains(color) ? color : "blue"
            self.execute(
                "INSERT INTO labels (name, color, sort_order, created_at) VALUES (?, ?, ?, ?)",
                [trimmed, colorName, order, now]
            )
            let labels = self.queryLabels()
            let created = labels.first { $0.name == trimmed }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .clipboardLabelsDidChange, object: nil)
            }
            completion?(created)
        }
    }

    public func updateLabel(id: Int64, name: String?, color: String?, completion: (() -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            if let name {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    self.execute("UPDATE labels SET name = ? WHERE id = ?", [trimmed, id])
                }
            }
            if let color, ClipboardLabel.presetColors.contains(color) {
                self.execute("UPDATE labels SET color = ? WHERE id = ?", [color, id])
            }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .clipboardLabelsDidChange, object: nil)
            }
            completion?()
        }
    }

    public func deleteLabel(id: Int64, completion: (() -> Void)? = nil) {
        queue.async { [weak self] in
            self?.execute("DELETE FROM item_labels WHERE label_id = ?", [id])
            self?.execute("DELETE FROM labels WHERE id = ?", [id])
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .clipboardLabelsDidChange, object: nil)
                NotificationCenter.default.post(name: .clipboardHistoryDidChange, object: nil)
            }
            completion?()
        }
    }

    public func setItemLabels(itemID: Int64, labelIDs: [Int64], completion: (() -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            self.execute("DELETE FROM item_labels WHERE item_id = ?", [itemID])
            for labelID in Set(labelIDs) {
                self.execute(
                    "INSERT OR IGNORE INTO item_labels (item_id, label_id) VALUES (?, ?)",
                    [itemID, labelID]
                )
            }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .clipboardHistoryDidChange, object: nil)
            }
            completion?()
        }
    }

    public func toggleItemLabel(itemID: Int64, labelID: Int64, completion: (() -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            let exists = self.scalarCount(
                "SELECT COUNT(*) FROM item_labels WHERE item_id = ? AND label_id = ?",
                [itemID, labelID]
            ) > 0
            if exists {
                self.execute("DELETE FROM item_labels WHERE item_id = ? AND label_id = ?", [itemID, labelID])
            } else {
                self.execute(
                    "INSERT OR IGNORE INTO item_labels (item_id, label_id) VALUES (?, ?)",
                    [itemID, labelID]
                )
            }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .clipboardHistoryDidChange, object: nil)
            }
            completion?()
        }
    }

    public func reorderLabels(orderedIDs: [Int64], completion: (() -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            for (index, id) in orderedIDs.enumerated() {
                self.execute("UPDATE labels SET sort_order = ? WHERE id = ?", [index, id])
            }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .clipboardLabelsDidChange, object: nil)
            }
            completion?()
        }
    }

    private func queryLabels() -> [ClipboardLabel] {
        guard let db else { return [] }
        var stmt: OpaquePointer?
        let sql = "SELECT id, name, color, sort_order, created_at FROM labels ORDER BY sort_order ASC, id ASC"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var result: [ClipboardLabel] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            result.append(ClipboardLabel(
                id: sqlite3_column_int64(stmt, 0),
                name: columnString(stmt, 1),
                color: columnString(stmt, 2),
                sortOrder: Int(sqlite3_column_int(stmt, 3)),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
            ))
        }
        return result
    }

    private func scalarCount(_ sql: String, _ bindings: [Any?] = []) -> Int {
        guard let db else { return 0 }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
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
            default:
                break
            }
        }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
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
            self.execute("DELETE FROM item_labels WHERE item_id = ?", [id])
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
            self.execute("DELETE FROM item_labels")
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

public extension Notification.Name {
    /// 历史有写入/删除后广播，供面板在后台保持列表预热。
    static let clipboardHistoryDidChange = Notification.Name("clipboardHistoryDidChange")
    /// 标签增删改后广播。
    static let clipboardLabelsDidChange = Notification.Name("clipboardLabelsDidChange")
    /// 发现可用更新（低打扰提示）。
    static let clipboardUpdateAvailable = Notification.Name("clipboardUpdateAvailable")
}
