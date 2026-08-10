import AppKit
import Foundation
import UniformTypeIdentifiers

/// 监听系统剪贴板变化，提取内容并写入历史。
@MainActor
public final class ClipboardMonitor {
    public static let shared = ClipboardMonitor()

    private let pasteboard = NSPasteboard.general
    private var lastChangeCount: Int
    private var timer: Timer?

    /// 自己写回剪贴板的内容 hash，避免把回填操作再次记入历史。
    private var lastWrittenHash: String?

    /// 最近一次以图片入库的时刻：用于吞掉微信等随后追加的「图片文件」条目。
    private var lastImageIngestAt: CFAbsoluteTime = 0

    private static let jpegType = NSPasteboard.PasteboardType("public.jpeg")
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "tif", "tiff", "bmp", "heic", "heif"
    ]

    private init() {
        lastChangeCount = pasteboard.changeCount
    }

    public func start() {
        guard timer == nil else { return }
        lastChangeCount = pasteboard.changeCount
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
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
        let sourceBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if let bundleID = sourceBundleID,
           AppSettings.shared.ignoredApps.contains(bundleID) {
            return
        }

        process(items, sourceAppBundleID: sourceBundleID)
    }

    private func process(_ items: [NSPasteboardItem], sourceAppBundleID: String?) {
        // 1. 位图优先：截图工具 / 微信等常同时提供文件引用与图片数据，只保留图片。
        if let imageData = bitmapImageData() {
            ingestImageData(imageData, sourceAppBundleID: sourceAppBundleID)
            return
        }

        // 2. 文件引用
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            // 纯图片文件（微信聊天图常见）：按图片入库，不另出「文件」卡片
            if urls.allSatisfy(Self.isImageFileURL) {
                // 刚入库过图片时，跳过紧随其后的同内容文件变更，避免双条目
                if CFAbsoluteTimeGetCurrent() - lastImageIngestAt < 1.2 {
                    DebugLog.write("跳过图片文件引用：距上次图片入库 <1.2s")
                    return
                }
                lastImageIngestAt = CFAbsoluteTimeGetCurrent()
                let ignoredHash = lastWrittenHash
                let source = sourceAppBundleID
                DispatchQueue.global(qos: .userInitiated).async {
                    guard let data = try? Data(contentsOf: urls[0]) else { return }
                    Self.persistAndUpsertImage(
                        data,
                        sourceAppBundleID: source,
                        ignoredHash: ignoredHash
                    )
                }
                return
            }

            let paths = urls.map(\.path)
            let hash = Hashing.sha256Hex(filePaths: paths)
            guard hash != lastWrittenHash else { return }
            // 刚记过图片时，不要把图片路径再记成文件
            if CFAbsoluteTimeGetCurrent() - lastImageIngestAt < 1.2,
               paths.allSatisfy({ Self.isImagePath($0) }) {
                DebugLog.write("跳过文件入库：疑似图片附属引用")
                return
            }
            ClipboardStore.shared.upsert(NewClipboardItem(
                kind: .file,
                text: paths.joined(separator: "\n"),
                filePaths: paths,
                hash: hash,
                sourceAppBundleID: sourceAppBundleID
            ))
            return
        }

        // 3. 文本（含链接），带格式时同时保存 RTF
        if let text = plainText(from: items), !text.isEmpty {
            let hash = Hashing.sha256Hex(text)
            guard hash != lastWrittenHash else { return }
            let kind: ClipboardItem.Kind = text.isLikelyURL ? .link : .text
            var rtfPath: String?
            if let rtfData = pasteboard.data(forType: .rtf), !rtfData.isEmpty {
                rtfPath = saveRTF(data: rtfData, hash: hash)
            }
            ClipboardStore.shared.upsert(NewClipboardItem(
                kind: kind,
                text: text,
                rtfPath: rtfPath,
                hash: hash,
                sourceAppBundleID: sourceAppBundleID
            ))
        }
    }

    private func bitmapImageData() -> Data? {
        pasteboard.data(forType: .png)
            ?? pasteboard.data(forType: .tiff)
            ?? pasteboard.data(forType: Self.jpegType)
    }

    private func ingestImageData(
        _ imageData: Data,
        sourceAppBundleID: String?,
        ignoredHash: String? = nil
    ) {
        let ignored = ignoredHash ?? lastWrittenHash
        lastImageIngestAt = CFAbsoluteTimeGetCurrent()
        let source = sourceAppBundleID
        DispatchQueue.global(qos: .userInitiated).async {
            Self.persistAndUpsertImage(imageData, sourceAppBundleID: source, ignoredHash: ignored)
        }
    }

    private static nonisolated func persistAndUpsertImage(
        _ imageData: Data,
        sourceAppBundleID: String?,
        ignoredHash: String?
    ) {
        guard let image = NSImage(data: imageData) else { return }
        let canonicalData = image.pngData() ?? imageData
        let hash = Hashing.sha256Hex(canonicalData)
        guard hash != ignoredHash else { return }
        let (originalPath, thumbPath) = persistImage(data: canonicalData, hash: hash)
        guard originalPath != nil else { return }
        ClipboardStore.shared.upsert(NewClipboardItem(
            kind: .image,
            imagePath: thumbPath,
            originalImagePath: originalPath,
            hash: hash,
            sourceAppBundleID: sourceAppBundleID
        ))
        // 清掉短时间内误记的「图片文件」条目（微信常见：先 file-url 后 bitmap）
        ClipboardStore.shared.deleteRecentUnpinnedImageFiles(withinSeconds: 3)
    }

    private static func isImageFileURL(_ url: URL) -> Bool {
        isImagePath(url.path)
    }

    private static func isImagePath(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        if imageExtensions.contains(ext) { return true }
        if let type = UTType(filenameExtension: ext), type.conforms(to: .image) {
            return true
        }
        return false
    }

    private func saveRTF(data: Data, hash: String) -> String? {
        let url = ClipboardStore.defaultRTFDirectory().appendingPathComponent("\(hash).rtf")
        do {
            try data.write(to: url)
            return url.path
        } catch {
            print("保存 RTF 失败: \(error)")
            return nil
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

    /// 原图与缩略图落盘（调用方需保证在后台线程）。
    private static nonisolated func persistImage(data: Data, hash: String) -> (String?, String?) {
        let directory = ClipboardStore.defaultImagesDirectory()
        let originalURL = directory.appendingPathComponent("\(hash).data")
        let thumbURL = directory.appendingPathComponent("\(hash)_thumb.jpg")
        do {
            try data.write(to: originalURL)
            let thumbData = makeThumbnail(from: data, maxDimension: 512)
            try thumbData?.write(to: thumbURL)
            return (originalURL.path, thumbURL.path)
        } catch {
            DebugLog.write("保存图片失败: \(error)")
            return (nil, nil)
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
