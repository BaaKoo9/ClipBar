import AppKit
import Foundation

/// 把历史条目写回系统剪贴板，以及可选的自动粘贴。
public final class PasteService {
    public static let shared = PasteService()

    private let pasteboard = NSPasteboard.general

    private init() {}

    /// 把历史条目写回系统剪贴板；返回内容 hash（供监听器忽略，避免自记）。
    @discardableResult
    public func writeToPasteboard(_ item: ClipboardItem) -> String? {
        pasteboard.clearContents()
        switch item.kind {
        case .text, .link:
            guard let text = item.text else { return nil }
            pasteboard.setString(text, forType: .string)
            if let rtfPath = item.rtfPath,
               let rtfData = try? Data(contentsOf: URL(fileURLWithPath: rtfPath)) {
                pasteboard.setData(rtfData, forType: .rtf)
            }
            return Hashing.sha256Hex(text)

        case .image:
            guard let path = item.originalImagePath,
                  let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let image = NSImage(data: data) else { return nil }
            let png = image.pngData() ?? data
            pasteboard.setData(png, forType: .png)
            if let tiff = image.tiffRepresentation {
                pasteboard.setData(tiff, forType: .tiff)
            }
            return Hashing.sha256Hex(png)

        case .file:
            let urls = item.filePaths.map { URL(fileURLWithPath: $0) } as [NSURL]
            pasteboard.writeObjects(urls)
            return Hashing.sha256Hex(filePaths: item.filePaths)
        }
    }

    /// 模拟 ⌘C：把当前选中内容复制到剪贴板（入队复制前置）。
    public static func injectCommandC() {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: true)
        down?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: false)
        up?.flags = .maskCommand
        up?.post(tap: .cghidEventTap)
    }

    /// 模拟 ⌘V 注入粘贴（需要辅助功能权限）。
    public static func injectCommandV() {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        down?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        up?.flags = .maskCommand
        up?.post(tap: .cghidEventTap)
    }

    /// 当前进程是否拥有辅助功能权限（自动粘贴需要）。
    public static var hasAccessibilityPermission: Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }
}

extension NSImage {
    /// 统一的 PNG 编码（回填与规范化 hash 用同一份数据）。
    public func pngData() -> Data? {
        guard let tiff = tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
