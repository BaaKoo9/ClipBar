import AppKit
import Foundation

/// 监听系统剪贴板变化，提取内容并写入历史。
@MainActor
public final class ClipboardMonitor {
    public static let shared = ClipboardMonitor()

    private let pasteboard = NSPasteboard.general
    private var lastChangeCount: Int
    private var timer: Timer?

    /// 自己写回剪贴板的内容 hash，避免把回填操作再次记入历史。
    private var lastWrittenHash: String?

    private init() {
        lastChangeCount = pasteboard.changeCount
    }

    public func start() {
        guard timer == nil else { return }
        lastChangeCount = pasteboard.changeCount
        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// 写回剪贴板后调用，让监听器跳过这条内容。
    public func ignore(hash: String) {
        lastWrittenHash = hash
    }

    private func poll() {
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count

        guard let items = pasteboard.pasteboardItems, !items.isEmpty else { return }

        // 忽略设置中指定的 App（例如密码管理器）。
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           let bundleID = frontmost.bundleIdentifier,
           AppSettings.shared.ignoredApps.contains(bundleID) {
            return
        }

        process(items)
    }

    private func process(_ items: [NSPasteboardItem]) {
        // 1. 文件引用
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            let paths = urls.map(\.path)
            let hash = Hashing.sha256Hex(filePaths: paths)
            guard hash != lastWrittenHash else { return }
            ClipboardStore.shared.upsert(NewClipboardItem(
                kind: .file,
                text: paths.joined(separator: "\n"),
                filePaths: paths,
                hash: hash
            ))
            return
        }

        // 2. 图片
        if let imageData = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            let hash = Hashing.sha256Hex(imageData)
            guard hash != lastWrittenHash else { return }
            saveImage(data: imageData, hash: hash) { originalPath, thumbPath in
                ClipboardStore.shared.upsert(NewClipboardItem(
                    kind: .image,
                    imagePath: thumbPath,
                    originalImagePath: originalPath,
                    hash: hash
                ))
            }
            return
        }

        // 3. 文本（含链接）
        if let text = plainText(from: items), !text.isEmpty {
            let hash = Hashing.sha256Hex(text)
            guard hash != lastWrittenHash else { return }
            let kind: ClipboardItem.Kind = text.isLikelyURL ? .link : .text
            ClipboardStore.shared.upsert(NewClipboardItem(
                kind: kind,
                text: text,
                hash: hash
            ))
        }
    }

    private func plainText(from items: [NSPasteboardItem]) -> String? {
        if let string = pasteboard.string(forType: .string) {
            return string
        }
        // 富文本兜底：RTF/RTFD 转纯文本
        if let rtfData = pasteboard.data(forType: .rtf) {
            if let attr = NSAttributedString(rtf: rtfData, documentAttributes: nil) {
                return attr.string
            }
        }
        return nil
    }

    private func saveImage(data: Data, hash: String, completion: @escaping (String?, String?) -> Void) {
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
                print("保存图片失败: \(error)")
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
}

private extension String {
    var isLikelyURL: Bool {
        if hasPrefix("http://") || hasPrefix("https://") { return true }
        guard contains("://"), !contains(" ") else { return false }
        return URL(string: self) != nil
    }
}
