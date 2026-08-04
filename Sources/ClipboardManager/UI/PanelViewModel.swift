import AppKit
import ClipboardManagerCore
import Foundation

/// 面板的共享状态：历史数据、选中项、搜索、粘贴队列与 Toast。
@MainActor
final class PanelViewModel: ObservableObject {
    @Published var searchText = ""
    @Published var items: [ClipboardItem] = []
    @Published var selectedID: Int64?
    @Published var showsSettings = false
    @Published var pasteQueue: [ClipboardItem] = []

    /// AppDelegate 注入：请求关闭面板（Esc、粘贴完成后等）。
    var onRequestClose: (() -> Void)?

    private var loaded = false

    // MARK: - 生命周期

    func loadHistory() {
        guard !loaded else { return }
        loaded = true
        refresh()
    }

    func panelDidOpen() {
        loadHistory()
        if selectedID == nil {
            selectedID = items.first?.id
        }
    }

    func panelDidClose() {
        if !searchText.isEmpty {
            searchText = ""
        }
    }

    // MARK: - 搜索

    func searchDidChange() {
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

    private func apply(_ newItems: [ClipboardItem]) {
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
    }

    // MARK: - 基础操作

    func pasteSelected() {
        guard let item = selectedItem else { return }
        if let hash = PasteService.shared.writeToPasteboard(item) {
            ClipboardMonitor.shared.ignore(hash: hash)
        }
        if AppSettings.shared.autoPasteEnabled, PasteService.hasAccessibilityPermission {
            PasteService.injectCommandV()
        }
        onRequestClose?()
    }

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
        showsSettings = true
    }

    // MARK: - 粘贴队列

    /// 面板内 ⌘+回车：把当前选中项加入队列。
    func enqueueSelected() {
        guard let item = selectedItem else { return }
        pasteQueue.append(item)
        ToastWindowController.shared.show(
            title: "已入队（\(pasteQueue.count)）",
            message: item.previewLine,
            systemImage: "list.number"
        )
    }

    func clearQueue() {
        pasteQueue = []
    }

    /// 全局快捷键：把当前系统剪贴板内容加入队列。
    func enqueueFromClipboard() {
        let pasteboard = NSPasteboard.general

        // 文本
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            enqueueFromHistoryOrCreate(
                hash: Hashing.sha256Hex(text),
                kind: text.hasPrefix("http://") || text.hasPrefix("https://") ? .link : .text,
                text: text,
                rtfPath: nil,
                imagePath: nil,
                originalImagePath: nil,
                filePaths: []
            )
            return
        }

        // 图片
        if let imageData = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            let hash = Hashing.sha256Hex(imageData)
            enqueueFromHistoryOrCreate(
                hash: hash,
                kind: .image,
                text: nil,
                rtfPath: nil,
                imagePath: nil,
                originalImagePath: nil,
                filePaths: [],
                pendingImageData: imageData
            )
            return
        }

        // 文件
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            let paths = urls.map(\.path)
            enqueueFromHistoryOrCreate(
                hash: Hashing.sha256Hex(filePaths: paths),
                kind: .file,
                text: paths.joined(separator: "\n"),
                rtfPath: nil,
                imagePath: nil,
                originalImagePath: nil,
                filePaths: paths
            )
            return
        }

        ToastWindowController.shared.show(title: "无法入队", message: "剪贴板为空或不支持的类型", systemImage: "exclamationmark.triangle")
    }

    private func enqueueFromHistoryOrCreate(
        hash: String,
        kind: ClipboardItem.Kind,
        text: String?,
        rtfPath: String?,
        imagePath: String?,
        originalImagePath: String?,
        filePaths: [String],
        pendingImageData: Data? = nil
    ) {
        ClipboardStore.shared.item(hash: hash) { [weak self] existing in
            DispatchQueue.main.async {
                guard let self else { return }
                if let existing {
                    self.pasteQueue.append(existing)
                    self.showEnqueueToast(existing)
                    return
                }
                // 历史中没有：图片需要先落盘才能回填
                if let data = pendingImageData {
                    self.savePendingImage(data: data, hash: hash) { original, thumb in
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
                        self.pasteQueue.append(item)
                        self.showEnqueueToast(item)
                    }
                } else {
                    let item = ClipboardItem(
                        id: -1,
                        kind: kind,
                        text: text,
                        rtfPath: rtfPath,
                        imagePath: imagePath,
                        originalImagePath: originalImagePath,
                        filePaths: filePaths,
                        hash: hash,
                        pinned: false,
                        createdAt: Date(),
                        updatedAt: Date()
                    )
                    self.pasteQueue.append(item)
                    self.showEnqueueToast(item)
                }
            }
        }
    }

    private func savePendingImage(data: Data, hash: String, completion: @escaping (String?, String?) -> Void) {
        let directory = ClipboardStore.defaultImagesDirectory()
        let originalURL = directory.appendingPathComponent("\(hash).data")
        let thumbURL = directory.appendingPathComponent("\(hash)_thumb.jpg")

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try data.write(to: originalURL)
                let thumbData = Self.makeThumbnail(from: data, maxDimension: 512)
                try thumbData?.write(to: thumbURL)
                DispatchQueue.main.async {
                    completion(originalURL.path, thumbURL.path)
                }
            } catch {
                print("保存入队图片失败: \(error)")
                DispatchQueue.main.async {
                    completion(nil, nil)
                }
            }
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

    private func showEnqueueToast(_ item: ClipboardItem) {
        ToastWindowController.shared.show(
            title: "已入队（\(pasteQueue.count)）",
            message: item.previewLine,
            systemImage: "list.number"
        )
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
        if let hash = PasteService.shared.writeToPasteboard(item) {
            ClipboardMonitor.shared.ignore(hash: hash)
        }
        if AppSettings.shared.autoPasteEnabled, PasteService.hasAccessibilityPermission {
            PasteService.injectCommandV()
        }
        ToastWindowController.shared.show(
            title: pasteQueue.isEmpty ? "已全部粘贴" : "已出队（剩 \(pasteQueue.count)）",
            message: item.previewLine,
            systemImage: "arrow.up.doc"
        )
    }
}
