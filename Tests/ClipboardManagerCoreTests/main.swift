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
    for i in 0..<5 {
        store.upsert(NewClipboardItem(kind: .text, text: "条目 \(i)", hash: "h\(i)"))
    }
    waitForStore()

    let semaphore = DispatchSemaphore(value: 0)
    var pinnedID: Int64?
    store.fetchAll { items in
        pinnedID = items.last?.id
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 2)

    store.setPinned(id: pinnedID!, pinned: true) {
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 2)

    store.upsert(NewClipboardItem(kind: .text, text: "新条目", hash: "new"))
    waitForStore()

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

// MARK: - 运行

do {
    try testInsertAndFetch()
    try testDuplicateRefreshesInsteadOfInserting()
    try testSearchMatchesText()
    try testPinnedItemSurvivesLimitCleanup()
    try testClearRemovesEverything()
} catch {
    failed += 1
    print("❌ 测试抛出异常: \(error)")
}

print("\n结果: \(passed) 通过, \(failed) 失败")
exit(failed == 0 ? 0 : 1)
