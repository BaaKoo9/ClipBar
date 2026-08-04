import AppKit
import ClipboardManagerCore
import Foundation

/// 面板的共享状态：历史数据、选中项、搜索、粘贴队列与 Toast。
@MainActor
final class PanelViewModel: ObservableObject {
    @Published var searchText = ""
    @Published var items: [ClipboardItem] = []
    @Published var selectedID: Int64?
    @Published var pasteQueue: [ClipboardItem] = []
    @Published var filterKind: ClipboardItem.Kind?
    @Published var scrollRequestID: Int64?

    /// AppDelegate 注入：请求关闭面板（Esc、粘贴完成后等）。
    var onRequestClose: (() -> Void)?
    /// AppDelegate 注入：请求打开独立设置窗口。
    var onOpenSettings: (() -> Void)?

    /// 面板显示前调用：记住当前前台 App（呼出前一刻），粘贴时定向注入到它。
    func panelWillOpen(from pid: pid_t?) {
        targetPID = pid
    }

    private var loaded = false
    private var targetPID: pid_t?
    private let enqueueQueue = DispatchQueue(label: "com.huxiaolong.clipboard.enqueue")

    // MARK: - 生命周期

    func loadHistory() {
        guard !loaded else { return }
        loaded = true
        refresh()
    }

    func panelDidOpen() {
        loadHistory()
        refresh()
        if selectedID == nil {
            selectedID = items.first?.id
        }
    }

    func panelDidClose() {
        if !searchText.isEmpty {
            searchText = ""
        }
    }

    // MARK: - 搜索与筛选

    func searchDidChange() {
        refresh()
    }

    func setFilter(_ kind: ClipboardItem.Kind?) {
        filterKind = kind
        refresh()
    }

    private func refresh() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            ClipboardStore.shared.fetchAll { [weak self] items in
                DispatchQueue.main.async { self?.apply(items) }
            }
        } else {
            ClipboardStore.shared.search(query) { [weak self] items in
                DispatchQueue.main.async { self?.apply(items) }
            }
        }
    }

    private func apply(_ rawItems: [ClipboardItem]) {
        let newItems = filterKind.flatMap { kind in rawItems.filter { $0.kind == kind } } ?? rawItems
        items = newItems
        if let selectedID, items.contains(where: { $0.id == selectedID }) {
            return
        }
        selectedID = items.first?.id
    }

    // MARK: - 键盘导航

    var selectedItem: ClipboardItem? {
        items.first { $0.id == selectedID }
    }

    func moveSelection(offset: Int) {
        guard !items.isEmpty else { return }
        let currentIndex = items.firstIndex { $0.id == selectedID } ?? -1
        let newIndex = min(max(currentIndex + offset, 0), items.count - 1)
        selectedID = items[newIndex].id
        scrollRequestID = selectedID
    }

    // MARK: - 粘贴

    func pasteSelected() {
        guard let item = selectedItem else { return }
        DebugLog.write("回车粘贴: \(item.kind.rawValue) \(item.previewLine.prefix(20))")
        if let hash = PasteService.shared.writeToPasteboard(item) {
            ClipboardMonitor.shared.ignore(hash: hash)
        }
        onRequestClose?()
        if AppSettings.shared.autoPasteEnabled, PasteService.hasAccessibilityPermission {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                if NSApp.isActive {
                    NSApp.deactivate()
                }
                self.injectPaste(to: self.targetPID)
            }
        }
    }

    /// 激活前台目标并注入 ⌘V：先激活目标 App，稍等其获得焦点，再用系统级事件注入（对 Electron 类 App 更兼容）。
    /// 注入 ⌘V 到指定 App：先激活，稍等焦点，再用系统级事件注入（对 Electron 类 App 更兼容）。
    private func injectPaste(to pid: pid_t?) {
        guard let pid else {
            DebugLog.write("注入 ⌘V：无目标 App，系统级注入")
            PasteService.injectCommandV()
            return
        }
        let appName = PasteService.activateApp(pid: pid)
        DebugLog.write("注入 ⌘V：pid=\(pid) app=\(appName ?? "未知")")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            PasteService.injectCommandV()
        }
    }

    // MARK: - 基础操作

    func togglePin(_ item: ClipboardItem) {
        ClipboardStore.shared.setPinned(id: item.id, pinned: !item.pinned) { [weak self] in
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    func deleteItem(_ item: ClipboardItem) {
        ClipboardStore.shared.delete(id: item.id) { [weak self] in
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    func clearAllHistory() {
        ClipboardStore.shared.clear { [weak self] in
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    func openSettings() {
        onOpenSettings?()
    }

    // MARK: - 粘贴队列

    /// 面板内 ⌘+点击/⌘+回车：把当前选中项加入队列。
    func enqueueSelected() {
        guard let item = selectedItem else { return }
        DebugLog.write("面板入队: \(item.kind.rawValue) \(item.previewLine.prefix(20)) count=\(pasteQueue.count + 1)")
        pasteQueue.append(item)
        objectWillChange.send()
        showEnqueueToast(item)
    }

    func clearQueue() {
        DebugLog.write("清空队列")
        pasteQueue = []
        objectWillChange.send()
        ToastWindowController.shared.hideQueue()
    }

    /// 全局快捷键：模拟普通复制（⌘C）后再把新剪贴板内容加入队列。
    func enqueueFromClipboard() {
        guard PasteService.hasAccessibilityPermission else {
            enqueueQueue.async { [weak self] in
                self?.performEnqueueFromClipboard()
            }
            return
        }
        let before = NSPasteboard.general.changeCount
        if let pid = PasteService.frontmostPID() {
            PasteService.activateApp(pid: pid)
            PasteService.injectCommandC(to: pid)
        } else {
            PasteService.injectCommandC()
        }
        waitForPasteboardChange(before: before, retries: 10)
    }

    private func waitForPasteboardChange(before: Int, retries: Int) {
        guard retries > 0 else {
            enqueueQueue.async { [weak self] in
                self?.performEnqueueFromClipboard()
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            if NSPasteboard.general.changeCount != before {
                self.enqueueQueue.async { self.performEnqueueFromClipboard() }
            } else {
                self.waitForPasteboardChange(before: before, retries: retries - 1)
            }
        }
    }

    private func performEnqueueFromClipboard() {
        let pasteboard = NSPasteboard.general

        // 图片优先（截图工具可能同时提供图片数据和文件引用）
        if let imageData = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            let hash = Hashing.sha256Hex(imageData)
            if let existing = ClipboardStore.shared.itemSync(hash: hash) {
                enqueueAppend(existing)
                return
            }
            if let (original, thumb) = saveImageSync(data: imageData, hash: hash) {
                let item = ClipboardItem(
                    id: -1,
                    kind: .image,
                    text: nil,
                    rtfPath: nil,
                    imagePath: thumb,
                    originalImagePath: original,
                    filePaths: [],
                    hash: hash,
                    pinned: false,
                    createdAt: Date(),
                    updatedAt: Date()
                )
                enqueueAppend(item)
            }
            return
        }

        // 文本
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            let item = ClipboardItem(
                id: -1,
                kind: text.hasPrefix("http://") || text.hasPrefix("https://") ? .link : .text,
                text: text,
                rtfPath: nil,
                imagePath: nil,
                originalImagePath: nil,
                filePaths: [],
                hash: Hashing.sha256Hex(text),
                pinned: false,
                createdAt: Date(),
                updatedAt: Date()
            )
            enqueueAppend(item)
            return
        }

        // 文件
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            let paths = urls.map(\.path)
            let item = ClipboardItem(
                id: -1,
                kind: .file,
                text: paths.joined(separator: "\n"),
                rtfPath: nil,
                imagePath: nil,
                originalImagePath: nil,
                filePaths: paths,
                hash: Hashing.sha256Hex(filePaths: paths),
                pinned: false,
                createdAt: Date(),
                updatedAt: Date()
            )
            enqueueAppend(item)
            return
        }

        DispatchQueue.main.async {
            ToastWindowController.shared.show(
                title: "无法入队",
                message: "剪贴板为空或不支持的类型",
                systemImage: "exclamationmark.triangle"
            )
        }
    }

    private func enqueueAppend(_ item: ClipboardItem) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pasteQueue.append(item)
            DebugLog.write("入队[速]: \(item.kind.rawValue) \(item.previewLine.prefix(20)) count=\(self.pasteQueue.count)")
            self.objectWillChange.send()
            self.showEnqueueToast(item)
        }
    }

    private func showEnqueueToast(_ item: ClipboardItem) {
        ToastWindowController.shared.showQueue(items: pasteQueue)
    }

    /// 全局快捷键：从队列取出下一个写回剪贴板并粘贴。
    func dequeueAndPaste() {
        guard !pasteQueue.isEmpty else {
            ToastWindowController.shared.show(
                title: "队列为空",
                message: "先用入队复制（⌥⌘E）收集内容",
                systemImage: "list.number"
            )
            return
        }
        let item = pasteQueue.removeFirst()
        DebugLog.write("出队: \(item.kind.rawValue) \(item.previewLine.prefix(20)) 剩余=\(pasteQueue.count)")
        if let hash = PasteService.shared.writeToPasteboard(item) {
            ClipboardMonitor.shared.ignore(hash: hash)
        }
        if AppSettings.shared.autoPasteEnabled, PasteService.hasAccessibilityPermission {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                if NSApp.isActive {
                    NSApp.deactivate()
                }
                self.injectPaste(to: PasteService.frontmostPID())
            }
        }
        if pasteQueue.isEmpty {
            ToastWindowController.shared.hideQueue()
        } else {
            ToastWindowController.shared.showQueue(items: pasteQueue)
        }
    }


    // MARK: - 图片落盘

    private func saveImageSync(data: Data, hash: String) -> (String, String)? {
        let directory = ClipboardStore.defaultImagesDirectory()
        let originalURL = directory.appendingPathComponent("\(hash).data")
        let thumbURL = directory.appendingPathComponent("\(hash)_thumb.jpg")
        do {
            try data.write(to: originalURL)
            let thumbData = Self.makeThumbnail(from: data, maxDimension: 512)
            try thumbData?.write(to: thumbURL)
            return (originalURL.path, thumbURL.path)
        } catch {
            print("保存入队图片失败: \(error)")
            return nil
        }
    }

    private static nonisolated func makeThumbnail(from data: Data, maxDimension: CGFloat) -> Data? {
        guard let image = NSImage(data: data) else { return nil }
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, maxDimension / max(size.width, size.height))
        let target = NSSize(width: size.width * scale, height: size.height * scale)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(target.width),
            pixelsHigh: Int(target.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = target
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: target))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }
}
