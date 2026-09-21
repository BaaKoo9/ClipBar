import AppKit
import SQLite3
import Foundation
@testable import ClipboardManagerCore

// 轻量测试框架（CommandLineTools 无 XCTest 模块时的替代）
private var passed = 0
private var failed = 0
private let shouldRunSystemIntegrationTests =
    ProcessInfo.processInfo.environment["CLIPBAR_SKIP_SYSTEM_TESTS"] != "1"

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

private func testUpdatePackageVerifier() throws {
    let digest = "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD"
    let checksum = Data("\(digest)  ClipBar-1.0.9.pkg\n".utf8)
    expectEqual(
        UpdatePackageVerifier.parseSHA256(from: checksum),
        digest.lowercased(),
        "更新校验文件应解析并标准化 SHA-256"
    )
    expect(
        UpdatePackageVerifier.parseSHA256(from: Data("not-a-digest".utf8)) == nil,
        "更新校验文件应拒绝非法摘要"
    )
    expect(
        UpdatePackageVerifier.parseSHA256(
            from: Data(repeating: 0x61, count: UpdatePackageVerifier.maximumChecksumFileSize + 1)
        ) == nil,
        "更新校验文件应拒绝超长内容"
    )

    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("UpdateVerifierTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let file = tempDir.appendingPathComponent("package.bin")
    try Data("abc".utf8).write(to: file, options: .atomic)
    expectEqual(
        try UpdatePackageVerifier.sha256Hex(ofFile: file),
        digest.lowercased(),
        "更新包文件应计算正确 SHA-256"
    )
}

private func testUpdatePolicy() {
    expect(
        UpdatePolicy.shouldSurfaceUpdate(
            availableVersion: "1.0.11",
            dismissedVersion: nil,
            currentVersion: "1.0.10"
        ),
        "仅远程版本较新时应显示更新提示"
    )
    expect(
        !UpdatePolicy.shouldSurfaceUpdate(
            availableVersion: "1.0.10",
            dismissedVersion: nil,
            currentVersion: "1.0.10"
        ),
        "安装完成后同版本更新提示应自动失效"
    )
    expect(
        !UpdatePolicy.shouldSurfaceUpdate(
            availableVersion: "1.0.9",
            dismissedVersion: nil,
            currentVersion: "1.0.10"
        ),
        "旧版本更新提示不应残留"
    )
    expect(
        !UpdatePolicy.shouldSurfaceUpdate(
            availableVersion: "1.0.11",
            dismissedVersion: "1.0.11",
            currentVersion: "1.0.10"
        ),
        "已稍后处理的版本不应显示更新提示"
    )

    let assets = [
        "ClipBar-1.0.11.pkg",
        "ClipBar-1.0.11.pkg.sha256",
        "ClipBar-1.0.11.dmg",
        "ClipBar-1.0.11.dmg.sha256",
    ]
    expectEqual(
        UpdatePolicy.preferredArtifactName(from: assets, version: "1.0.11", architecture: .arm64),
        "ClipBar-1.0.11.dmg",
        "自动更新应优先选择带校验文件的 DMG"
    )
    expectEqual(
        UpdatePolicy.preferredArtifactName(
            from: assets.filter { !$0.hasSuffix(".dmg.sha256") },
            version: "1.0.11", architecture: .arm64
        ),
        "ClipBar-1.0.11.pkg",
        "DMG 缺少校验文件时应安全回退到 pkg"
    )
}

private func testArchitectureSpecificUpdates() throws {
    func assets(_ names: [String]) -> [String] {
        names.flatMap { [$0, "\($0).sha256"] }
    }
    let legacy = "ClipBar-1.0.12.dmg"
    let all = assets([
        legacy, "ClipBar-1.0.12-x86_64.pkg", "ClipBar-1.0.12-arm64.pkg",
        "ClipBar-1.0.12-x86_64.dmg", "ClipBar-1.0.12-arm64.dmg",
    ])
    for architecture in UpdateArchitecture.allCases {
        let own = "ClipBar-1.0.12-\(architecture.rawValue)"
        let other = architecture == .arm64 ? "x86_64" : "arm64"
        for ordering in [all, Array(all.reversed())] {
            expectEqual(
                UpdatePolicy.preferredArtifactName(from: ordering, version: "v1.0.12", architecture: architecture),
                "\(own).dmg", "\(architecture) 不受附件顺序影响且优先自身 DMG"
            )
        }
        expectEqual(
            UpdatePolicy.preferredArtifactName(
                from: all.filter { $0 != "\(own).dmg.sha256" }, version: "1.0.12", architecture: architecture
            ), "\(own).pkg", "\(architecture) DMG 无校验时仅回退同架构 PKG"
        )
        for invalid in [
            assets(["ClipBar-1.0.12-\(other).dmg"]),
            assets(["ClipBar-1.0.13-\(architecture.rawValue).dmg"]),
            assets(["Unrelated-1.0.12-\(architecture.rawValue).dmg"]),
            ["\(own).dmg"], ["\(own).dmg.sha256"], [],
        ] {
            expect(
                UpdatePolicy.preferredArtifactName(from: invalid, version: "1.0.12", architecture: architecture) == nil,
                "\(architecture) 拒绝错误架构/版本/名称和缺失制品或校验"
            )
        }
    }
    expectEqual(
        UpdatePolicy.preferredArtifactName(from: assets([legacy]), version: "1.0.12", architecture: .arm64),
        legacy, "ARM 可兼容历史无架构文件名"
    )
    expect(
        UpdatePolicy.preferredArtifactName(from: assets([legacy]), version: "1.0.12", architecture: .x86_64) == nil,
        "Intel 绝不回退到历史 ARM 包"
    )

    let executable = FileManager.default.temporaryDirectory.appendingPathComponent("MachOTest-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: executable) }
    for architecture in UpdateArchitecture.allCases {
        var header = [UInt8](repeating: 0, count: 32)
        header.replaceSubrange(0..<8, with: [0xcf, 0xfa, 0xed, 0xfe, architecture == .arm64 ? 12 : 7, 0, 0, 1])
        header[12] = 2
        try Data(header).write(to: executable)
        expect(architecture.matchesExecutable(at: executable), "识别 \(architecture) 可执行头部")
        let other: UpdateArchitecture = architecture == .arm64 ? .x86_64 : .arm64
        expect(!other.matchesExecutable(at: executable), "拒绝实际二进制架构与下载名不符")
        header[12] = 6
        try Data(header).write(to: executable)
        expect(!architecture.matchesExecutable(at: executable), "拒绝用动态库冒充更新程序")
    }
    for data in [Data(), Data([0xcf, 0xfa, 0xed, 0xfe]), Data(repeating: 0, count: 32)] {
        try data.write(to: executable)
        expect(!UpdateArchitecture.arm64.matchesExecutable(at: executable), "拒绝截断或无效 Mach-O")
    }
}

private func testPaginationAndHistoryCounts() throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("PaginationTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let previousLimit = AppSettings.shared.historyLimit
    AppSettings.shared.historyLimit = 5_000
    defer { AppSettings.shared.historyLimit = previousLimit }

    let store = ClipboardStore(dbURL: tempDir.appendingPathComponent("test.sqlite"))
    for index in 0..<95 {
        let prefix = index.isMultiple(of: 3) ? "分页命中" : "普通条目"
        store.upsert(NewClipboardItem(
            kind: index.isMultiple(of: 5) ? .link : .text,
            text: "\(prefix) \(index)",
            hash: "pagination-\(index)"
        ))
    }

    let semaphore = DispatchSemaphore(value: 0)
    var firstPage = ClipboardHistoryPage(items: [], totalCount: 0, matchCount: 0)
    var secondPage = firstPage
    var thirdPage = firstPage

    store.fetchHistoryPage(limit: 40) { page in
        firstPage = page
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 5)
    store.fetchHistoryPage(limit: 40, offset: 40) { page in
        secondPage = page
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 5)
    store.fetchHistoryPage(limit: 40, offset: 80) { page in
        thirdPage = page
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 5)

    expectEqual(firstPage.totalCount, 95, "分页快照应返回库总量")
    expectEqual(firstPage.matchCount, 95, "无筛选时匹配量应等于库总量")
    expectEqual(firstPage.items.count, 40, "分页首屏应返回 40 条")
    expectEqual(secondPage.items.count, 40, "分页第二页应返回 40 条")
    expectEqual(thirdPage.items.count, 15, "分页末页应返回剩余 15 条")

    let allIDs = (firstPage.items + secondPage.items + thirdPage.items).map(\.id)
    expectEqual(Set(allIDs).count, 95, "连续分页不应出现重复条目")

    var searchPage = firstPage
    store.fetchHistoryPage(query: "分页命中", limit: 10, offset: 30) { page in
        searchPage = page
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 5)

    expectEqual(searchPage.totalCount, 95, "搜索分页仍应返回库总量")
    expectEqual(searchPage.matchCount, 32, "搜索分页应返回完整匹配量")
    expectEqual(searchPage.items.count, 2, "搜索末页应返回剩余匹配项")
    expect(searchPage.items.allSatisfy { $0.text?.contains("分页命中") == true }, "搜索分页内容应全部命中")

    var linkPage = firstPage
    store.fetchHistoryPage(kind: ClipboardItem.Kind.link.rawValue, limit: 40) { page in
        linkPage = page
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 5)
    expectEqual(linkPage.matchCount, 19, "类型筛选应返回完整匹配量")
    expect(linkPage.items.allSatisfy { $0.kind == .link }, "类型筛选内容应保持一致")
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

    // 再插入 40 条：每次写入都会按上限清理，应保留置顶 1 条 + 未置顶 3 条
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

private func testPinnedItemsSortFirst() throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("CoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let store = ClipboardStore(dbURL: tempDir.appendingPathComponent("test.sqlite"))
    store.upsert(NewClipboardItem(kind: .text, text: "旧条目", hash: "old"))
    store.upsert(NewClipboardItem(kind: .text, text: "新条目", hash: "new"))
    waitForStore()

    let semaphore = DispatchSemaphore(value: 0)
    var before: [ClipboardItem] = []
    store.fetchAll { items in
        before = items
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 2)

    let olderID = before.first(where: { $0.hash == "old" })!.id
    store.setPinned(id: olderID, pinned: true) {
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 2)

    var after: [ClipboardItem] = []
    store.fetchAll { items in
        after = items
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 2)

    expectEqual(after.first?.id, olderID, "置顶后应排在列表最前")
    expect(after.first?.pinned == true, "首条应为置顶状态")
}

private func testHistoryLimitEnforcedStrictly() throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("CoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    AppSettings.shared.historyLimit = 100
    defer { AppSettings.shared.historyLimit = 5000 }

    let store = ClipboardStore(dbURL: tempDir.appendingPathComponent("test.sqlite"))
    for i in 0..<130 {
        store.upsert(NewClipboardItem(kind: .text, text: "条目 \(i)", hash: "limit-\(i)"))
    }

    let semaphore = DispatchSemaphore(value: 0)
    var all: [ClipboardItem] = []
    store.fetchAll { items in
        all = items
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 3)

    expectEqual(all.count, 100, "超过上限时应立即裁到 100 条")

    // 调低上限后应能主动裁剪
    AppSettings.shared.historyLimit = 50
    store.enforceHistoryLimit { _ in
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 2)
    store.fetchAll { items in
        all = items
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 2)
    expectEqual(all.count, 50, "下调历史上限后应立即裁到新上限")
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
        rtfPath: nil,
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
        rtfPath: nil,
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

private func testFilePasteCompatibility() throws {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let service = PasteService(pasteboard: pasteboard)
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("FilePasteCompatibility-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let paths = ["中文 空格 #%.txt", "second.pdf"].map {
        directory.appendingPathComponent($0).path
    }
    for path in paths {
        try Data("fixture".utf8).write(to: URL(fileURLWithPath: path))
    }
    for selectedPaths in [Array(paths.prefix(1)), paths] {
        let item = ClipboardItem(
            id: 99, kind: .file, text: nil, rtfPath: nil, imagePath: nil,
            originalImagePath: nil, filePaths: selectedPaths, hash: "fixture",
            pinned: false, createdAt: Date(), updatedAt: Date()
        )
        let hash = service.writeToPasteboard(item)
        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]
        expectEqual(urls?.map(\.path), selectedPaths, "文件回填保留现代 URL 格式、顺序及特殊字符")
        expectEqual(
            pasteboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String],
            selectedPaths,
            "文件回填同时提供传统文件列表供聊天应用读取"
        )
        expectEqual(hash, Hashing.sha256Hex(filePaths: selectedPaths), "文件回填 hash 与监听器一致")
    }
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
        rtfPath: nil,
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
    let ok = HotKeyService.shared.register(tag: 1, keyCode: 9, modifiers: 2304) {}
    expect(ok, "⌥⌘V 全局快捷键注册成功")
    HotKeyService.unregisterAll()
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

private func testRTFPastePreservesFormat() throws {
    // 构造一段带格式的 RTF
    let rtfData = Data(#"""
    {\rtf1\ansi\b 加粗内容\b0 普通内容}
    """#.utf8)
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("RTFTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let rtfURL = tempDir.appendingPathComponent("item.rtf")
    try rtfData.write(to: rtfURL)

    let item = ClipboardItem(
        id: 1,
        kind: .text,
        text: "加粗内容 普通内容",
        rtfPath: rtfURL.path,
        imagePath: nil,
        originalImagePath: nil,
        filePaths: [],
        hash: "rtf1",
        pinned: false,
        createdAt: Date(),
        updatedAt: Date()
    )

    _ = PasteService.shared.writeToPasteboard(item)
    let written = NSPasteboard.general.data(forType: .rtf)

    expect(written == rtfData, "RTF 格式在回填后完整保留")
    expect(NSPasteboard.general.string(forType: .string) == "加粗内容 普通内容", "纯文本内容同时保留")
}

private func testLegacyDatabaseMigration() throws {
    // 用旧版 schema（无 rtf_path 列）建库，验证打开后自动迁移
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("MigrateTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let dbURL = tempDir.appendingPathComponent("legacy.sqlite")
    var db: OpaquePointer?
    _ = dbURL.path.withCString { path in
        sqlite3_open(path, &db)
    }
    let legacySchema = """
    CREATE TABLE items (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        kind TEXT NOT NULL,
        text TEXT,
        image_path TEXT,
        original_image_path TEXT,
        file_paths TEXT,
        hash TEXT NOT NULL UNIQUE,
        pinned INTEGER NOT NULL DEFAULT 0,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL
    )
    """
    let schema = legacySchema as NSString
    typealias ExecCallback = @convention(c) (UnsafeMutableRawPointer?, Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32
    sqlite3_exec(db, schema.utf8String, Optional<ExecCallback>.none, nil, nil)
    sqlite3_close(db)
    let store = ClipboardStore(dbURL: dbURL, imagesDirectory: tempDir)
    store.upsert(NewClipboardItem(
        kind: .text,
        text: "迁移后的内容",
        rtfPath: "/tmp/fake.rtf",
        hash: "migrate1"
    ))
    waitForStore()

    let semaphore = DispatchSemaphore(value: 0)
    var items: [ClipboardItem] = []
    store.fetchAll { result in
        items = result
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 2)

    expectEqual(items.count, 1, "旧库迁移后仍可读写")
    expectEqual(items.first?.rtfPath, "/tmp/fake.rtf", "迁移后 rtf_path 列可正常存取")
}

private func testRetentionDeletesOldUnpinned() throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("RetentionTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let previousRetention = AppSettings.shared.retentionEnabled
    let previousDays = AppSettings.shared.retentionDays
    let previousLimit = AppSettings.shared.historyLimit
    AppSettings.shared.retentionEnabled = true
    AppSettings.shared.retentionDays = 7
    AppSettings.shared.historyLimit = 5000
    defer {
        AppSettings.shared.retentionEnabled = previousRetention
        AppSettings.shared.retentionDays = previousDays
        AppSettings.shared.historyLimit = previousLimit
    }

    let dbURL = tempDir.appendingPathComponent("test.sqlite")
    let store = ClipboardStore(dbURL: dbURL, imagesDirectory: tempDir)
    store.upsert(NewClipboardItem(kind: .text, text: "新鲜", hash: "fresh"))
    store.upsert(NewClipboardItem(kind: .text, text: "过期", hash: "stale"))
    store.upsert(NewClipboardItem(kind: .text, text: "置顶过期", hash: "pinned-stale"))
    waitForStore()

    let semaphore = DispatchSemaphore(value: 0)
    var pinnedID: Int64?
    store.fetchAll { items in
        pinnedID = items.first(where: { $0.hash == "pinned-stale" })?.id
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 2)
    store.setPinned(id: pinnedID!, pinned: true) {
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 2)

    // 把过期条目的 updated_at 拨到 8 天前（保留天数 7）
    let staleTS = Date().addingTimeInterval(-8 * 24 * 60 * 60).timeIntervalSince1970
    var db: OpaquePointer?
    _ = dbURL.path.withCString { path in
        sqlite3_open(path, &db)
    }
    let sql = "UPDATE items SET updated_at = \(staleTS) WHERE hash IN ('stale','pinned-stale')" as NSString
    typealias ExecCallback = @convention(c) (UnsafeMutableRawPointer?, Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32
    sqlite3_exec(db, sql.utf8String, Optional<ExecCallback>.none, nil, nil)
    sqlite3_close(db)

    store.enforceHistoryLimit { _ in
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 2)

    var after: [ClipboardItem] = []
    store.fetchAll { items in
        after = items
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 2)

    expect(after.contains { $0.hash == "fresh" }, "TTL 应保留未过期条目")
    expect(!after.contains { $0.hash == "stale" }, "TTL 应删除过期未置顶")
    expect(after.contains { $0.hash == "pinned-stale" }, "TTL 应保留过期置顶")
}

private func testDeleteRecentImageFilesAfterImageUpsert() throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ImageFileDedup-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let store = ClipboardStore(dbURL: tempDir.appendingPathComponent("test.sqlite"), imagesDirectory: tempDir)
    let imagePath = tempDir.appendingPathComponent("wechat-shot.png").path
    store.upsert(NewClipboardItem(
        kind: .file,
        text: imagePath,
        filePaths: [imagePath],
        hash: "file-img-1"
    ))
    waitForStore()
    store.upsert(NewClipboardItem(
        kind: .image,
        imagePath: tempDir.appendingPathComponent("thumb.jpg").path,
        originalImagePath: tempDir.appendingPathComponent("orig.data").path,
        hash: "bitmap-1"
    ))
    let semaphore = DispatchSemaphore(value: 0)
    store.deleteRecentUnpinnedImageFiles(withinSeconds: 3)
    // deleteRecent 是异步的，稍等
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { semaphore.signal() }
    _ = semaphore.wait(timeout: .now() + 2)

    var items: [ClipboardItem] = []
    store.fetchAll { result in
        items = result
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 2)

    expect(!items.contains { $0.hash == "file-img-1" }, "图片入库后应清理近期图片文件条目")
    expect(items.contains { $0.hash == "bitmap-1" }, "图片条目应保留")
}

private func testLabelsAssignAndFilter() throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("LabelTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let store = ClipboardStore(dbURL: tempDir.appendingPathComponent("test.sqlite"), imagesDirectory: tempDir)
    store.upsert(NewClipboardItem(kind: .text, text: "工作备注", hash: "work1"))
    store.upsert(NewClipboardItem(kind: .text, text: "生活备注", hash: "life1"))
    waitForStore()

    let semaphore = DispatchSemaphore(value: 0)
    var labelID: Int64?
    store.createLabel(name: "工作", color: "blue") { label in
        labelID = label?.id
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 2)
    expect(labelID != nil, "应能创建标签")
    guard let labelID else { return }

    var items: [ClipboardItem] = []
    store.fetchAll { result in
        items = result
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 2)
    guard let workItem = items.first(where: { $0.hash == "work1" }) else {
        expect(false, "应能找到 work1 条目")
        return
    }
    store.setItemLabels(itemID: workItem.id, labelIDs: [labelID]) {
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 2)

    store.fetchAll(labelID: labelID) { result in
        items = result
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 2)
    expectEqual(items.count, 1, "按标签筛选应只命中一条")
    expectEqual(items.first?.hash, "work1", "标签筛选命中正确条目")

    store.touch(id: workItem.id) {
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 2)
    store.fetchAll { result in
        items = result
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 2)
    expectEqual(items.first?.hash, "work1", "touch 后应排到最前")
}

private func testPanelInteractionPolicy() {
    expectEqual(
        PanelInteractionPolicy.focusTarget(for: .panelOpened),
        .panel,
        "呼出面板时不应自动激活搜索框与输入法"
    )
    expectEqual(
        PanelInteractionPolicy.focusTarget(for: .searchRequested),
        .searchField,
        "明确请求搜索时应聚焦搜索框"
    )
    expectEqual(
        PanelInteractionPolicy.selectionIndex(currentIndex: nil, itemCount: 8, offset: 1),
        0,
        "没有当前选中项时应从首项开始"
    )
    expectEqual(
        PanelInteractionPolicy.selectionIndex(currentIndex: 3, itemCount: 8, offset: 1),
        4,
        "向右应选择下一项"
    )
    expectEqual(
        PanelInteractionPolicy.selectionIndex(currentIndex: 0, itemCount: 8, offset: -1),
        0,
        "向左不应越过首项"
    )
    expectEqual(
        PanelInteractionPolicy.selectionIndex(currentIndex: 7, itemCount: 8, offset: 1),
        7,
        "向右不应越过末项"
    )
    expect(
        !PanelInteractionPolicy.shouldScroll(targetID: 102, visibleIDs: [101, 102, 103]),
        "目标卡片已可见时不应触发滚动"
    )
    expect(
        PanelInteractionPolicy.shouldScroll(targetID: 104, visibleIDs: [101, 102, 103]),
        "目标卡片不可见时才应触发滚动"
    )
    expectEqual(
        PanelInteractionPolicy.moving([1, 2, 3, 4], from: 1, over: 3),
        [1, 3, 4, 2],
        "队列向下拖拽应越过目标项"
    )
    expectEqual(
        PanelInteractionPolicy.moving([1, 2, 3, 4], from: 3, over: 1),
        [1, 4, 2, 3],
        "队列向上拖拽应插入目标项之前"
    )
    expectEqual(
        PanelInteractionPolicy.moving([1, 2, 3], from: 1, over: 1),
        [1, 2, 3],
        "队列拖到原位置不应改变顺序"
    )

    var deferredReorder = DeferredReorderState<Int>()
    deferredReorder.begin(dragging: 1)
    deferredReorder.hover(over: 2)
    expectEqual(deferredReorder.draggedID, 1, "拖拽过程中只记录源项")
    expectEqual(deferredReorder.targetID, 2, "拖拽过程中只记录目标项")
    let proposal = deferredReorder.finish()
    expectEqual(proposal?.sourceID, 1, "松手时生成一次源项提案")
    expectEqual(proposal?.targetID, 2, "松手时生成一次目标项提案")
    expect(deferredReorder.finish() == nil, "同一拖拽只能提交一次排序")
    expectEqual(
        PanelInteractionPolicy.dragTargetIndex(
            sourceIndex: 0,
            itemCount: 3,
            translation: 22,
            itemStride: 42
        ),
        1,
        "队列拖过半行后应切换到下一项"
    )
    expectEqual(
        PanelInteractionPolicy.dragTargetIndex(
            sourceIndex: 1,
            itemCount: 3,
            translation: -42,
            itemStride: 42
        ),
        0,
        "队列向上拖一行应命中上一项"
    )
}

private func testQueueSessionPolicy() {
    expectEqual(
        QueueSessionPolicy.toggleAction(isSessionActive: false),
        .startSession,
        "关闭时再按开关应开会话"
    )
    expectEqual(
        QueueSessionPolicy.toggleAction(isSessionActive: true),
        .endSession,
        "会话中再按开关应结束并清空"
    )
    expectEqual(
        QueueSessionPolicy.openSeedAction(didClipboardChange: true, isIgnoredApp: false),
        .enqueueCurrentClipboard,
        "注入复制后剪贴板变化应入队"
    )
    expectEqual(
        QueueSessionPolicy.openSeedAction(didClipboardChange: false, isIgnoredApp: false),
        .showEmptyQueue,
        "没有选区时应唤出空队列"
    )
    expectEqual(
        QueueSessionPolicy.openSeedAction(didClipboardChange: true, isIgnoredApp: true),
        .showEmptyQueue,
        "忽略名单 App 的复制不应入队"
    )
    expectEqual(
        QueueSessionPolicy.openSeedAction(
            didClipboardChange: false, isIgnoredApp: false, hasSelectedText: true
        ),
        .enqueueSelectedText,
        "剪贴板没变但有选区时应入队选区"
    )
    expectEqual(
        QueueSessionPolicy.pasteAction(
            isSessionActive: false, queueCount: 2, isSecureInput: false, bypassPanelPaste: false
        ),
        .ignore,
        "会话未开时普通粘贴应放行"
    )
    expectEqual(
        QueueSessionPolicy.pasteAction(
            isSessionActive: true, queueCount: 0, isSecureInput: false, bypassPanelPaste: false
        ),
        .swallowAndEnd,
        "空队列粘贴应吞掉并结束会话"
    )
    expectEqual(
        QueueSessionPolicy.pasteAction(
            isSessionActive: true, queueCount: 3, isSecureInput: false, bypassPanelPaste: false
        ),
        .dequeueAndPass,
        "队列有多项时应出队并放行粘贴"
    )
    expectEqual(
        QueueSessionPolicy.pasteAction(
            isSessionActive: true, queueCount: 1, isSecureInput: false, bypassPanelPaste: false
        ),
        .dequeueAndEnd,
        "最后一项出队后应结束会话"
    )
    expectEqual(
        QueueSessionPolicy.pasteAction(
            isSessionActive: true, queueCount: 2, isSecureInput: true, bypassPanelPaste: false
        ),
        .ignore,
        "安全输入里不应拦截粘贴"
    )
    expectEqual(
        QueueSessionPolicy.pasteAction(
            isSessionActive: true, queueCount: 2, isSecureInput: false, bypassPanelPaste: true
        ),
        .ignore,
        "快照条粘贴应绕过队列"
    )
    expect(
        QueueSessionPolicy.shouldEnqueueClipboardChange(
            isSessionActive: true, isSelfWrite: false, isIgnoredApp: false, alreadyConsumed: false
        ),
        "会话中的普通复制应入队"
    )
    expect(
        !QueueSessionPolicy.shouldEnqueueClipboardChange(
            isSessionActive: true, isSelfWrite: true, isIgnoredApp: false, alreadyConsumed: false
        ),
        "自己写回剪贴板不应再入队"
    )
    expect(
        !QueueSessionPolicy.shouldEnqueueClipboardChange(
            isSessionActive: true, isSelfWrite: false, isIgnoredApp: true, alreadyConsumed: false
        ),
        "忽略名单 App 的剪贴板变化不应入队"
    )
    expect(
        QueueSessionPolicy.shouldKeepSessionAfterClearingItems(),
        "清空内容后应保持空窗会话"
    )
    expect(
        QueueSessionPolicy.isPasteChord(keyCode: 9, carbonModifiers: 256),
        "⌘V 应识别为出队粘贴"
    )
    expect(
        QueueSessionPolicy.isPasteChord(keyCode: 9, carbonModifiers: 256 | 512),
        "⇧⌘V 应识别为出队粘贴"
    )
    expect(
        !QueueSessionPolicy.isPasteChord(keyCode: 9, carbonModifiers: 256 | 2048),
        "⌥⌘V 不应当成队列出队"
    )
    expectEqual(
        QueueSessionPolicy.pasteAction(
            isSessionActive: true, queueCount: 2, isSecureInput: false, bypassPanelPaste: true
        ),
        .ignore,
        "面板注入的粘贴不应出队"
    )
    expect(
        !QueueSessionPolicy.isPasteChord(keyCode: 14, carbonModifiers: 256),
        "⌘E 不应当成队列出队"
    )
}

private func testPasteHandoffPolicy() {
    expectEqual(
        PasteHandoffPolicy.settleDelay(hasCapturedFocus: true, didRestoreFocus: true),
        0.012,
        "已恢复原焦点时应使用最短稳定期"
    )
    expectEqual(
        PasteHandoffPolicy.settleDelay(hasCapturedFocus: true, didRestoreFocus: false),
        0.020,
        "已捕获输入框但设焦失败时不应误走缺焦点慢路径"
    )
    expectEqual(
        PasteHandoffPolicy.settleDelay(hasCapturedFocus: false, didRestoreFocus: false),
        0.045,
        "完全未捕获输入框时才保留焦点恢复兜底"
    )
}

private func testLegacyPanelKeyboardPolicy() {
    func action(_ key: UInt16, command: Bool = false, modified: Bool = false,
                searching: Bool = false, composing: Bool = false, editing: Bool = false) -> PanelInteractionPolicy.KeyAction? {
        PanelInteractionPolicy.keyAction(keyCode: key, command: command, modified: modified,
                                         searching: searching, composing: composing, editingOtherText: editing)
    }
    expectEqual(action(123), .left, "macOS 13 左键选择上一项")
    expectEqual(action(124), .right, "macOS 13 右键选择下一项")
    expectEqual(action(53), .close, "macOS 13 Esc 关闭面板")
    expectEqual(action(36), .paste, "macOS 13 回车粘贴")
    expectEqual(action(76), .paste, "macOS 13 数字键盘回车粘贴")
    expectEqual(action(36, command: true), .enqueue, "macOS 13 Command-Return 入队")
    expectEqual(action(3, command: true), .search, "macOS 13 Command-F 聚焦搜索")
    expectEqual(action(123, searching: true), .left, "搜索中方向键仍选择卡片")
    expectEqual(action(36, command: true, searching: true), .enqueue, "搜索中 Command-Return 入队")
    expect(action(36, searching: true) == nil, "搜索回车交给 onSubmit，避免双粘贴")
    expect(action(3) == nil, "普通文字不触发快捷键")
    expect(action(123, modified: true, searching: true) == nil, "保留 Option/Control 编辑快捷键")
    for key: UInt16 in [123, 124, 53, 36, 76, 3] {
        expect(action(key, command: true, composing: true) == nil, "输入法组合期间不拦截按键")
        expect(action(key, command: true, editing: true) == nil, "标签等其他编辑器不拦截按键")
    }
}

/// 完整集成测试只暂时占用系统剪贴板；结束时恢复进入测试前的数据。
private func withPreservedSystemPasteboard(_ body: () throws -> Void) rethrows {
    let pasteboard = NSPasteboard.general
    let saved = (pasteboard.pasteboardItems ?? []).map { item in
        item.types.compactMap { type -> (NSPasteboard.PasteboardType, Data)? in
            item.data(forType: type).map { (type, $0) }
        }
    }
    defer {
        pasteboard.clearContents()
        let restored = saved.map { values in
            let item = NSPasteboardItem()
            for (type, data) in values { item.setData(data, forType: type) }
            return item
        }
        if !restored.isEmpty { pasteboard.writeObjects(restored) }
    }
    try body()
}

// MARK: - 运行

do {
    try testInsertAndFetch()
    try testDuplicateRefreshesInsteadOfInserting()
    try testSearchMatchesText()
    try testUpdatePackageVerifier()
    testUpdatePolicy()
    try testArchitectureSpecificUpdates()
    try testPaginationAndHistoryCounts()
    try testPinnedItemSurvivesLimitCleanup()
    try testPinnedItemsSortFirst()
    try testHistoryLimitEnforcedStrictly()
    try testImageFilesCleanedOnClear()
    try testClearRemovesEverything()
    try testPerformanceWith10kItems()
    try testLegacyDatabaseMigration()
    try testRetentionDeletesOldUnpinned()
    try testDeleteRecentImageFilesAfterImageUpsert()
    try testLabelsAssignAndFilter()
    testPanelInteractionPolicy()
    testQueueSessionPolicy()
    testPasteHandoffPolicy()
    testLegacyPanelKeyboardPolicy()
    try testFilePasteCompatibility()
    if shouldRunSystemIntegrationTests {
        try withPreservedSystemPasteboard {
            testPasteText()
            try testPasteFile()
            try testPasteImage()
            testHotKeyRegistration()
            try testRTFPastePreservesFormat()
        }
    } else {
        print("⏭️ 已跳过依赖系统剪贴板与全局热键权限的集成测试")
    }
} catch {
    failed += 1
    print("❌ 测试抛出异常: \(error)")
}

print("\n结果: \(passed) 通过, \(failed) 失败")
exit(failed == 0 ? 0 : 1)
