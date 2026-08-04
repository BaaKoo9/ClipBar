import AppKit
import Carbon
import CoreGraphics
import Foundation

// MARK: - Carbon 文件级状态（C 回调不能捕获类型上下文）

private var carbonHotKeyHandlers: [UInt32: (() -> Void)] = [:]
private var carbonHotKeyRefs: [UInt32: EventHotKeyRef] = [:]
private var carbonEventHandlerRef: EventHandlerRef?

private let hotKeyEventClass: OSType = 0x6B657962 // 'keyb'
private let hotKeyPressedKind: UInt32 = 1
private let hotKeyTypeID: OSType = 0x686B6964 // 'hkid'
private let hotKeyParamName: UInt32 = 0x6469726F // 'diro'
private let hotKeySignature: OSType = 0x434D484B // 'CMHK'

// MARK: - CGEventTap 文件级状态

private var eventTap: CFMachPort?
private var eventTapSource: CFRunLoopSource?

private let tapCallback: CGEventTapCallBack = { _, type, event, _ in
    guard type == .keyDown else {
        return Unmanaged.passUnretained(event)
    }
    let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
    let carbonFlags = HotKeyService.carbonModifiers(from: event.flags)
    if let tag = HotKeyService.shared.matchedTag(keyCode: keyCode, modifiers: carbonFlags) {
        HotKeyService.shared.fire(tag: tag)
        return nil // 消费事件，避免透传给前台 App
    }
    return Unmanaged.passUnretained(event)
}

// MARK: - 服务

/// 全局快捷键服务：CGEventTap（辅助功能权限，最可靠）+ Carbon + NSEvent 监听，三通道去重。
public final class HotKeyService {
    public static let shared = HotKeyService()

    private struct Registration {
        let keyCode: Int
        let modifiers: UInt
        let handler: () -> Void
    }

    private var registrations: [UInt32: Registration] = [:]
    private var monitor: Any?
    private var permissionTimer: Timer?
    private var lastListeningAvailable = false
    private var lastAccessibilityAvailable = false
    private let lock = NSLock()

    private var lastFireTag: UInt32 = 0
    private var lastFireDate = Date.distantPast

    private init() {
        installCarbonEventHandler()
        installEventTap()
        startPermissionWatcher()
    }

    /// 是否拥有辅助功能权限（CGEventTap 需要）。
    public static var isAccessibilityAvailable: Bool {
        AXIsProcessTrusted()
    }

    /// 主动请求辅助功能权限（弹出系统授权框）。
    public static func requestAccessibilityAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    /// 是否拥有输入监控权限（NSEvent 监听需要）。
    public static var isListeningAvailable: Bool {
        CGPreflightListenEventAccess()
    }

    @discardableResult
    public static func requestListeningAccess() -> Bool {
        CGRequestListenEventAccess()
    }

    // MARK: - 注册

    @discardableResult
    public func register(
        tag: UInt32,
        keyCode: Int,
        modifiers: UInt,
        handler: @escaping () -> Void
    ) -> Bool {
        lock.lock()
        registrations[tag] = Registration(keyCode: keyCode, modifiers: modifiers, handler: handler)
        lock.unlock()

        // Carbon 通道
        unregisterCarbon(tag: tag)
        var hotKeyID = EventHotKeyID(signature: hotKeySignature, id: tag)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(keyCode),
            UInt32(modifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr {
            carbonHotKeyRefs[tag] = ref
            carbonHotKeyHandlers[tag] = handler
        } else {
            DebugLog.write("Carbon 注册失败 tag=\(tag) status=\(status)")
        }

        rebuildMonitor()
        return true
    }

    public func unregister(tag: UInt32) {
        lock.lock()
        registrations.removeValue(forKey: tag)
        lock.unlock()
        unregisterCarbon(tag: tag)
    }

    public static func unregisterAll() {
        shared.unregisterAll()
    }

    private func unregisterAll() {
        lock.lock()
        registrations.removeAll()
        lock.unlock()
        for tag in Array(carbonHotKeyRefs.keys) {
            unregisterCarbon(tag: tag)
        }
    }

    private func unregisterCarbon(tag: UInt32) {
        if let ref = carbonHotKeyRefs.removeValue(forKey: tag) {
            UnregisterEventHotKey(ref)
        }
        carbonHotKeyHandlers.removeValue(forKey: tag)
    }

    // MARK: - 匹配

    func matchedTag(keyCode: Int, modifiers: UInt) -> UInt32? {
        lock.lock()
        defer { lock.unlock() }
        for (tag, registration) in registrations
        where registration.keyCode == keyCode && registration.modifiers == modifiers {
            return tag
        }
        return nil
    }

    // MARK: - 触发（线程安全，统一回主线程）

    func fire(tag: UInt32) {
        let now = Date()
        lock.lock()
        if tag == lastFireTag, now.timeIntervalSince(lastFireDate) < 0.15 {
            lock.unlock()
            return
        }
        lastFireTag = tag
        lastFireDate = now
        let handler = registrations[tag]?.handler
        lock.unlock()

        guard let handler else { return }
        DebugLog.write("热键命中 tag=\(tag)")
        DispatchQueue.main.async {
            handler()
        }
    }

    // MARK: - NSEvent 监听（输入监控权限）

    public func rebuildMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        guard !registrations.isEmpty, Self.isListeningAvailable else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.monitorHandle(event)
        }
    }

    private func monitorHandle(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let carbonFlags = Self.carbonModifiers(from: flags)
        let keyCode = Int(event.keyCode)
        if let tag = matchedTag(keyCode: keyCode, modifiers: carbonFlags) {
            fire(tag: tag)
        }
    }

    // MARK: - CGEventTap

    private func installEventTap() {
        // 先移除旧 tap，避免重复
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
        }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: tapCallback,
            userInfo: nil
        ) else {
            DebugLog.write("CGEventTap 创建失败")
            return
        }
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        DebugLog.write("CGEventTap 已启用")
    }

    // MARK: - 权限监控

    private func startPermissionWatcher() {
        let timer = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkPermissionChange() }
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer
    }

    private func checkPermissionChange() {
        let accessibility = Self.isAccessibilityAvailable
        if accessibility != lastAccessibilityAvailable {
            lastAccessibilityAvailable = accessibility
            DebugLog.write("辅助功能权限变化：\(accessibility)")
            if accessibility {
                installEventTap()
            }
        }

        let listening = Self.isListeningAvailable
        guard listening != lastListeningAvailable else { return }
        lastListeningAvailable = listening
        DebugLog.write("输入监控权限变化：\(listening)")
        rebuildMonitor()
    }

    // MARK: - Carbon 事件处理器

    private func installCarbonEventHandler() {
        var eventType = EventTypeSpec(
            eventClass: hotKeyEventClass,
            eventKind: hotKeyPressedKind
        )
        let callback: EventHandlerUPP = { _, event, _ in
            guard let event else { return noErr }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(hotKeyParamName),
                EventParamType(hotKeyTypeID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            if status == noErr, hotKeyID.signature == hotKeySignature {
                HotKeyService.shared.fire(tag: hotKeyID.id)
            }
            return noErr
        }
        InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventType,
            nil,
            &carbonEventHandlerRef
        )
    }

    // MARK: - 修饰键转换

    static func carbonModifiers(from flags: CGEventFlags) -> UInt {
        var value: UInt = 0
        if flags.contains(.maskControl) { value |= 4096 }
        if flags.contains(.maskAlternate) { value |= 2048 }
        if flags.contains(.maskShift) { value |= 512 }
        if flags.contains(.maskCommand) { value |= 256 }
        return value
    }

    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt {
        var value: UInt = 0
        if flags.contains(.control) { value |= 4096 }
        if flags.contains(.option) { value |= 2048 }
        if flags.contains(.shift) { value |= 512 }
        if flags.contains(.command) { value |= 256 }
        return value
    }
}
