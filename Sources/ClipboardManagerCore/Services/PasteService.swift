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
            // 兼容改名后的旧路径；原图优先，缩略图兜底
            guard let path = AppPaths.resolveExistingPath(item.originalImagePath)
                    ?? AppPaths.resolveExistingPath(item.imagePath),
                  let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  !data.isEmpty else { return nil }

            // 已是 PNG 则直接写回，避免二次编码失败导致「粘贴不上」
            let isPNG = data.count >= 8 && data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
            if isPNG {
                pasteboard.setData(data, forType: .png)
            }
            if let image = NSImage(data: data) {
                if !isPNG, let png = image.pngData() {
                    pasteboard.setData(png, forType: .png)
                } else if !isPNG {
                    pasteboard.setData(data, forType: .png)
                }
                if let tiff = image.tiffRepresentation {
                    pasteboard.setData(tiff, forType: .tiff)
                }
            } else if !isPNG {
                pasteboard.setData(data, forType: .png)
            }
            return Hashing.sha256Hex(data)

        case .file:
            let urls = item.filePaths.map { URL(fileURLWithPath: $0) } as [NSURL]
            pasteboard.writeObjects(urls)
            return Hashing.sha256Hex(filePaths: item.filePaths)
        }
    }

    /// 当前前台 App 的进程 ID（用于定向注入）。
    public static func frontmostPID() -> pid_t? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    /// 激活指定进程（注入前确保目标在前台并拿到键盘焦点）。
    @discardableResult
    public static func activateApp(pid: pid_t) -> String? {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        app.activate(options: [.activateIgnoringOtherApps])
        return app.localizedName
    }

    /// 激活目标 App，待其真正取得前台焦点后立刻注入 ⌘V。
    ///
    /// 用轮询探测取代固定等待：常见情况 10–40ms 即可完成注入，
    /// `maxWait` 只在目标迟迟不激活时兜底。
    public static func activateAndPaste(pid: pid_t?, maxWait: TimeInterval = 0.35) {
        guard let pid, let app = NSRunningApplication(processIdentifier: pid) else {
            DebugLog.write("注入 ⌘V：无目标 App，系统级注入")
            injectCommandV()
            return
        }
        DebugLog.write("注入 ⌘V：pid=\(pid) app=\(app.localizedName ?? "未知")")
        app.activate(options: [.activateIgnoringOtherApps])

        let deadline = CFAbsoluteTimeGetCurrent() + maxWait
        func waitForFocus() {
            let selfFront = NSRunningApplication.current.isActive
            // 目标已前台且我们已让出时立刻注入；超时则兜底注入
            if (app.isActive && !selfFront) || CFAbsoluteTimeGetCurrent() >= deadline {
                let settle = (app.isActive && !selfFront) ? focusSettleDelay : focusSettleDelay * 2
                DispatchQueue.main.asyncAfter(deadline: .now() + settle) {
                    injectCommandV(to: pid)
                    DebugLog.write(
                        "注入 ⌘V 完成 active=\(app.isActive) selfFront=\(NSRunningApplication.current.isActive)"
                    )
                }
                return
            }
            if !app.isActive {
                app.activate(options: [.activateIgnoringOtherApps])
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + focusPollInterval, execute: waitForFocus)
        }
        waitForFocus()
    }

    private static let focusPollInterval: TimeInterval = 0.006
    private static let focusSettleDelay: TimeInterval = 0.02

    /// 定向注入 ⌘C 到指定进程。
    public static func injectCommandC(to pid: pid_t) {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: true)
        down?.flags = .maskCommand
        down?.postToPid(pid)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: false)
        up?.flags = .maskCommand
        up?.postToPid(pid)
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

    /// 定向注入 ⌘V 到指定进程（面板关闭后最可靠）。
    public static func injectCommandV(to pid: pid_t) {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        down?.flags = .maskCommand
        down?.postToPid(pid)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        up?.flags = .maskCommand
        up?.postToPid(pid)
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
