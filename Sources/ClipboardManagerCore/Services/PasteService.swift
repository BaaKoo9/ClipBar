import AppKit
import Foundation

/// 呼出面板前捕获的粘贴目标，包含前台进程及其当前输入焦点。
public final class PasteTarget {
    public let pid: pid_t
    fileprivate let focusedElement: AXUIElement?

    fileprivate init(pid: pid_t, focusedElement: AXUIElement?) {
        self.pid = pid
        self.focusedElement = focusedElement
    }
}

/// 粘贴焦点交接的稳定期策略，区分可恢复焦点与真正缺失焦点的场景。
public enum PasteHandoffPolicy {
    public static func settleDelay(
        hasCapturedFocus: Bool,
        didRestoreFocus: Bool
    ) -> TimeInterval {
        if didRestoreFocus {
            return 0.012
        }
        return hasCapturedFocus ? 0.020 : 0.045
    }
}

/// 把历史条目写回系统剪贴板，以及可选的自动粘贴。
public final class PasteService {
    public static let shared = PasteService()

    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

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

    /// 在 ClipBar 抢占前台前记录目标输入控件，粘贴前可恢复光标位置。
    public static func captureTarget(pid: pid_t?) -> PasteTarget? {
        guard let pid else { return nil }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.03)
        let startedAt = CFAbsoluteTimeGetCurrent()
        let focusLookup = focusedElement(pid: pid, application: application)
        let focusedElement = focusLookup.element
        if let focusedElement {
            AXUIElementSetMessagingTimeout(focusedElement, 0.02)
        }
        let elapsed = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1_000)
        DebugLog.write(
            "捕获粘贴焦点 pid=\(pid) focused=\(focusedElement != nil) " +
            "source=\(focusLookup.source) appResult=\(focusLookup.applicationResult.rawValue) " +
            "systemResult=\(focusLookup.systemResult?.rawValue ?? 0) elapsed=\(elapsed)ms"
        )
        return PasteTarget(pid: pid, focusedElement: focusedElement)
    }

    /// 激活指定进程（注入前确保目标在前台并拿到键盘焦点）。
    @discardableResult
    public static func activateApp(pid: pid_t) -> String? {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        app.activate(options: [])
        return app.localizedName
    }

    /// 激活目标 App，待其真正取得前台焦点后立刻注入 ⌘V。
    ///
    /// 用轮询探测取代固定等待：常见情况 10–40ms 即可完成注入，
    /// `maxWait` 只在目标迟迟不激活时兜底。
    public static func activateAndPaste(pid: pid_t?, maxWait: TimeInterval = 0.35) {
        let target = pid.map { PasteTarget(pid: $0, focusedElement: nil) }
        activateAndPaste(target: target, maxWait: maxWait)
    }

    /// 恢复呼出面板前的输入控件焦点，并在目标真正回到前台后注入 ⌘V。
    public static func activateAndPaste(target: PasteTarget?, maxWait: TimeInterval = 0.35) {
        guard let target,
              let app = NSRunningApplication(processIdentifier: target.pid) else {
            DebugLog.write("注入 ⌘V：无目标 App，系统级注入")
            injectCommandV()
            return
        }
        let pid = target.pid
        DebugLog.write("注入 ⌘V：pid=\(pid) app=\(app.localizedName ?? "未知")")
        app.activate(options: [])

        let handoffStartedAt = CFAbsoluteTimeGetCurrent()
        let deadline = handoffStartedAt + maxWait
        var didPrepareFocus = false
        var didRestoreFocus = false
        func waitForFocus() {
            let now = CFAbsoluteTimeGetCurrent()
            let selfFront = NSRunningApplication.current.isActive
            let targetIsFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
            let targetIsReady = app.isActive && targetIsFrontmost && !selfFront
            if targetIsReady {
                if !didPrepareFocus {
                    didRestoreFocus = restoreFocus(target.focusedElement)
                    didPrepareFocus = true
                }

                let hasCapturedFocus = target.focusedElement != nil
                let settle = PasteHandoffPolicy.settleDelay(
                    hasCapturedFocus: hasCapturedFocus,
                    didRestoreFocus: didRestoreFocus
                )
                DispatchQueue.main.asyncAfter(deadline: .now() + settle) {
                    let targetStillFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
                    let selfIsFrontmost = NSRunningApplication.current.isActive
                    let targetIsStillReady = app.isActive && targetStillFrontmost && !selfIsFrontmost
                    if !targetIsStillReady && CFAbsoluteTimeGetCurrent() < deadline {
                        didPrepareFocus = false
                        app.activate(options: [])
                        DispatchQueue.main.asyncAfter(
                            deadline: .now() + focusPollInterval,
                            execute: waitForFocus
                        )
                        return
                    }
                    injectCommandV(to: pid)
                    let elapsed = Int((CFAbsoluteTimeGetCurrent() - handoffStartedAt) * 1_000)
                    DebugLog.write(
                        "注入 ⌘V 完成 active=\(app.isActive) front=\(targetStillFrontmost) " +
                        "selfFront=\(selfIsFrontmost) " +
                        "focusCaptured=\(hasCapturedFocus) focusRestored=\(didRestoreFocus) " +
                        "elapsed=\(elapsed)ms"
                    )
                }
                return
            }
            // 目标迟迟无法激活时保留定向注入兜底，避免误粘贴到其他进程。
            if now >= deadline {
                injectCommandV(to: pid)
                let elapsed = Int((now - handoffStartedAt) * 1_000)
                DebugLog.write(
                    "注入 ⌘V 超时兜底 active=\(app.isActive) front=\(targetIsFrontmost) " +
                    "selfFront=\(selfFront) elapsed=\(elapsed)ms"
                )
                return
            }
            if !app.isActive || !targetIsFrontmost {
                app.activate(options: [])
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + focusPollInterval, execute: waitForFocus)
        }
        waitForFocus()
    }

    private static let focusPollInterval: TimeInterval = 0.006

    private struct FocusLookup {
        let element: AXUIElement?
        let source: String
        let applicationResult: AXError
        let systemResult: AXError?
    }

    private static func focusedElement(pid: pid_t, application: AXUIElement) -> FocusLookup {
        let applicationLookup = copyFocusedElement(from: application)
        if let element = applicationLookup.element {
            return FocusLookup(
                element: element,
                source: "application",
                applicationResult: applicationLookup.result,
                systemResult: nil
            )
        }

        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.03)
        let systemLookup = copyFocusedElement(from: systemWide)
        guard let element = systemLookup.element else {
            return FocusLookup(
                element: nil,
                source: "none",
                applicationResult: applicationLookup.result,
                systemResult: systemLookup.result
            )
        }

        var focusedPID: pid_t = 0
        let pidResult = AXUIElementGetPid(element, &focusedPID)
        guard pidResult == .success, focusedPID == pid else {
            return FocusLookup(
                element: nil,
                source: "other-process",
                applicationResult: applicationLookup.result,
                systemResult: systemLookup.result
            )
        }
        return FocusLookup(
            element: element,
            source: "system",
            applicationResult: applicationLookup.result,
            systemResult: systemLookup.result
        )
    }

    private static func copyFocusedElement(from root: AXUIElement) -> (element: AXUIElement?, result: AXError) {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            root,
            kAXFocusedUIElementAttribute as CFString,
            &value
        )
        guard result == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return (nil, result)
        }
        return ((value as! AXUIElement), result)
    }

    private static func restoreFocus(_ focusedElement: AXUIElement?) -> Bool {
        guard let focusedElement else { return false }
        let result = AXUIElementSetAttributeValue(
            focusedElement,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        )
        return result == .success
    }

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
