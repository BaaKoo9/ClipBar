import AppKit
import Foundation
@testable import ClipboardManagerCore

// 轻量测试框架（CommandLineTools 无 XCTest 模块时的替代）
private var passed = 0
private var failed = 0

private func expect(_ condition: Bool, _ name: String) {
    if condition {
        passed += 1
        print("✅ \(name)")
    } else {
        failed += 1
        print("❌ \(name)")
    }
}

private func expectEqual<T: Equatable>(_ a: T, _ b: T, _ name: String) {
    if a == b {
        passed += 1
        print("✅ \(name)")
    } else {
        failed += 1
        print("❌ \(name): \(a) != \(b)")
    }
}

private func waitForStore(_ timeout: TimeInterval = 2) {
    let semaphore = DispatchSemaphore(value: 0)
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + timeout)
}

// MARK: - 存储测试

private func testInsertAndFetch() throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("CoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let store = ClipboardStore(dbURL: tempDir.appendingPathComponent("test.sqlite"))
    store.upsert(NewClipboardItem(kind: .text, text: "你好，世界", hash: "abc123"))
    waitForStore()

    let semaphore = DispatchSemaphore(value: 0)
    var result: [ClipboardItem] = []
    store.fetchAll { items in
        result = items
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 2)

    expectEqual(result.count, 1, "插入后应有一条记录")
    expectEqual(result.first?.text, "你好，世界", "文本内容正确")
    expectEqual(result.first?.kind, .text, "类型为文本")
}

private func testDuplicateRefreshesInsteadOfInserting() throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("CoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let store = ClipboardStore(dbURL: tempDir.appendingPathComponent("test.sqlite"))
    store.upsert(NewClipboardItem(kind: .text, text: "相同内容", hash: "dup"))
    waitForStore()
    Thread.sleep(forTimeInterval: 0.02)
    store.upsert(NewClipboardItem(kind: .text, text: "相同内容", hash: "dup"))
    waitForStore()

    let semaphore = DispatchSemaphore(value: 0)
    var result: [ClipboardItem] = []
    store.fetchAll { items in
        result = items
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 2)

    expectEqual(result.count, 1, "相同 hash 应去重而不是新增")
}

private func testSearchMatchesText() throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("CoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let store = ClipboardStore(dbURL: tempDir.appendingPathComponent("test.sqlite"))
    store.upsert(NewClipboardItem(kind: .text, text: "SwiftUI 开发笔记", hash: "a"))
    store.upsert(NewClipboardItem(kind: .text, text: "购物清单：牛奶 面包", hash: "b"))
    waitForStore()

    let semaphore = DispatchSemaphore(value: 0)
    var result: [ClipboardItem] = []
    store.search("SwiftUI") { items in
        result = items
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 2)

    expectEqual(result.count, 1, "搜索只命中一条")
    expectEqual(result.first?.text, "SwiftUI 开发笔记", "命中内容正确")
}


private func testPinnedItemSurvivesLimitCleanup() throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("CoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    AppSettings.shared.historyLimit = 3
    defer { AppSettings.shared.historyLimit = 5000 }

    let store = ClipboardStore(dbURL: tempDir.appendingPathComponent("test.sqlite"))

    for i in 0..<60 {
        store.upsert(NewClipboardItem(kind: .text, text: "条目 \(i)", hash: "h\(i)"))
    }
    let semaphore = DispatchSemaphore(value: 0)
    var pinnedID: Int64?
    store.fetchAll { items in
        pinnedID = items.first?.id
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 2)


    store.setPinned(id: pinnedID!, pinned: true) {
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 2)

    // 再插入 40 条：第 100 次插入触发清理，应保留置顶 1 条 + 未置顶 3 条
    for i in 60..<100 {
        store.upsert(NewClipboardItem(kind: .text, text: "条目 \(i)", hash: "h\(i)"))
    }
    var all: [ClipboardItem] = []
    store.fetchAll { items in
        all = items
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 2)

    expectEqual(all.count, 4, "容量清理后应保留 3 + 1 条置顶")
    expect(all.contains { $0.id == pinnedID }, "置顶条目应保留")
}
private func testClearRemovesEverything() throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("CoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let store = ClipboardStore(dbURL: tempDir.appendingPathComponent("test.sqlite"))
    store.upsert(NewClipboardItem(kind: .text, text: "内容", hash: "x"))
    waitForStore()

    let semaphore = DispatchSemaphore(value: 0)
    store.clear {
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 2)

    var result: [ClipboardItem] = []
    store.fetchAll { items in
        result = items
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 2)

    expect(result.isEmpty, "清空后无记录")
}

// MARK: - 回填测试（写回系统剪贴板）

private func testPasteText() {
    let item = ClipboardItem(
        id: 1,
        kind: .text,
        text: "回填测试文本",
        imagePath: nil,
        originalImagePath: nil,
        filePaths: [],
        hash: "t1",
        pinned: false,
        createdAt: Date(),
        updatedAt: Date()
    )

    let hash = PasteService.shared.writeToPasteboard(item)
    let pasteboard = NSPasteboard.general

    expect(hash == Hashing.sha256Hex("回填测试文本"), "文本回填返回正确 hash")
    expect(pasteboard.string(forType: .string) == "回填测试文本", "文本已写入系统剪贴板")
}

private func testPasteFile() throws {
    let temp = FileManager.default.temporaryDirectory
        .appendingPathComponent("PasteTest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    let fileURL = temp.appendingPathComponent("测试文件.txt")
    try "文件内容".write(to: fileURL, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: temp) }

    let item = ClipboardItem(
        id: 2,
        kind: .file,
        text: fileURL.path,
        imagePath: nil,
        originalImagePath: nil,
        filePaths: [fileURL.path],
        hash: "f1",
        pinned: false,
        createdAt: Date(),
        updatedAt: Date()
    )

    _ = PasteService.shared.writeToPasteboard(item)
    let urls = NSPasteboard.general.readObjects(
        forClasses: [NSURL.self],
        options: [.urlReadingFileURLsOnly: true]
    ) as? [URL]

    expect(urls?.map(\.path) == [fileURL.path], "文件引用已写入系统剪贴板")
}

private func testPasteImage() throws {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: 64,
        pixelsHigh: 64,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .calibratedRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let png = rep.representation(using: .png, properties: [:]) else {
        failed += 1
        print("❌ 无法创建测试图片")
        return
    }

    let temp = FileManager.default.temporaryDirectory
        .appendingPathComponent("PasteImageTest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    let originalURL = temp.appendingPathComponent("image.data")
    try png.write(to: originalURL)
    defer { try? FileManager.default.removeItem(at: temp) }

    let item = ClipboardItem(
        id: 3,
        kind: .image,
        text: nil,
        imagePath: nil,
        originalImagePath: originalURL.path,
        filePaths: [],
        hash: "img1",
        pinned: false,
        createdAt: Date(),
        updatedAt: Date()
    )

    let hash = PasteService.shared.writeToPasteboard(item)
    let written = NSPasteboard.general.data(forType: .png)

    expect(written != nil && Hashing.sha256Hex(written!) == hash && !written!.isEmpty, "图片已按 PNG 写回剪贴板")
}

private func testHotKeyRegistration() {
    let ok = HotKeyService.shared.register(keyCode: 9, modifiers: 2304) {}
    expect(ok, "⌥⌘V 全局快捷键注册成功")
    HotKeyService.unregister()
}


private func testPerformanceWith10kItems() throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("PerfTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    AppSettings.shared.historyLimit = 20000
    defer { AppSettings.shared.historyLimit = 5000 }

    let store = ClipboardStore(dbURL: tempDir.appendingPathComponent("perf.sqlite"))

    let insertStart = Date()
    for i in 0..<10000 {
        store.upsert(NewClipboardItem(
            kind: .text,
            text: "性能测试条目 \(i) 的内容，用于验证大数据量下的流畅度",
            hash: "perf\(i)"
        ))
    }
    let semaphore = DispatchSemaphore(value: 0)
    store.fetchAll { _ in semaphore.signal() }
    _ = semaphore.wait(timeout: .now() + 20)
    let insertTime = Date().timeIntervalSince(insertStart)

    let fetchStart = Date()
    var count = 0
    store.fetchAll { items in
        count = items.count
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 5)
    let fetchTime = Date().timeIntervalSince(fetchStart)

    let searchStart = Date()
    var hits = 0
    store.search("性能测试条目 9999") { items in
        hits = items.count
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 5)
    let searchTime = Date().timeIntervalSince(searchStart)

    expectEqual(count, 10000, "10000 条全部可读取")
    expect(hits >= 1, "搜索能命中目标")
    print(String(format: "📊 性能: 插入 10000 条 %.2fs / 全量读取 %.3fs / 搜索 %.3fs", insertTime, fetchTime, searchTime))
    expect(fetchTime < 1.0, "全量读取 10000 条 < 1s")
    expect(searchTime < 1.0, "搜索 < 1s")
}

private func testImageFilesCleanedOnClear() throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("CleanupTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let imagesDir = tempDir.appendingPathComponent("Images", isDirectory: true)
    try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)

    let originalURL = imagesDir.appendingPathComponent("abc.data")
    let thumbURL = imagesDir.appendingPathComponent("abc_thumb.jpg")
    try Data("original".utf8).write(to: originalURL)
    try Data("thumb".utf8).write(to: thumbURL)

    // 目录外的文件不应被误删
    let outsideURL = tempDir.appendingPathComponent("outside.txt")
    try Data("outside".utf8).write(to: outsideURL)

    let store = ClipboardStore(
        dbURL: tempDir.appendingPathComponent("test.sqlite"),
        imagesDirectory: imagesDir
    )
    store.upsert(NewClipboardItem(
        kind: .image,
        imagePath: thumbURL.path,
        originalImagePath: originalURL.path,
        hash: "img-cleanup"
    ))
    waitForStore()

    let semaphore = DispatchSemaphore(value: 0)
    store.clear {
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 2)

    expect(!FileManager.default.fileExists(atPath: originalURL.path), "清空后删除原图文件")
    expect(!FileManager.default.fileExists(atPath: thumbURL.path), "清空后删除缩略图文件")
    expect(FileManager.default.fileExists(atPath: outsideURL.path), "不误删目录外文件")
}
// MARK: - 运行

do {
    try testInsertAndFetch()
    try testDuplicateRefreshesInsteadOfInserting()
    try testSearchMatchesText()
    try testPinnedItemSurvivesLimitCleanup()
    try testImageFilesCleanedOnClear()
    try testClearRemovesEverything()
    testPasteText()
    try testPasteFile()
    try testPasteImage()
    try testPerformanceWith10kItems()
    testHotKeyRegistration()
} catch {
    failed += 1
    print("❌ 测试抛出异常: \(error)")
}

print("\n结果: \(passed) 通过, \(failed) 失败")
exit(failed == 0 ? 0 : 1)
