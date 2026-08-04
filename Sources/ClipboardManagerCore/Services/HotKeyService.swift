import AppKit
import Carbon
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

private func carbonFire(tag: UInt32) {
    DispatchQueue.main.async {
        HotKeyService.shared.fire(tag: tag)
    }
}

// MARK: - 服务

/// 全局快捷键服务：Carbon（无需权限）+ NSEvent 全局监听（输入监控权限）双轨，
/// 任一通道触发都有效，并按 150ms 去重。
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
    private let lock = NSLock()

    private var lastFireTag: UInt32 = 0
    private var lastFireDate = Date.distantPast

    private init() {
        installCarbonEventHandler()
        lastListeningAvailable = Self.isListeningAvailable
        startPermissionWatcher()
    }

    /// 是否已获得输入监控权限。
    public static var isListeningAvailable: Bool {
        CGPreflightListenEventAccess()
    }

    /// 主动请求输入监控权限（弹出系统授权框）。
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
            DebugLog.write("Carbon 注册成功 tag=\(tag) key=\(keyCode) mod=\(modifiers)")
        } else {
            DebugLog.write("Carbon 注册失败 tag=\(tag) key=\(keyCode) mod=\(modifiers) status=\(status)")
        }

        // 全局监听通道
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

    // MARK: - NSEvent 全局监听

    public func rebuildMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        guard !registrations.isEmpty, Self.isListeningAvailable else { return }

        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.monitorHandle(event)
        }
        DebugLog.write("全局监听已挂载")
    }

    private func monitorHandle(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let carbonFlags = Self.carbonModifiers(from: flags)
        let keyCode = Int(event.keyCode)

        // 只关注带修饰键的组合，避免普通打字刷日志
        if carbonFlags != 0 {
            DebugLog.write("收到按键 key=\(keyCode) mod=\(carbonFlags)")
        }

        lock.lock()
        let matches = registrations.values.filter {
            $0.keyCode == keyCode && $0.modifiers == carbonFlags
        }
        lock.unlock()

        for registration in matches {
            fire(tag: registrationsTag(for: registration) ?? 0)
        }
    }

    private func registrationsTag(for target: Registration) -> UInt32? {
        lock.lock()
        defer { lock.unlock() }
        for (tag, registration) in registrations where registration.keyCode == target.keyCode && registration.modifiers == target.modifiers {
            return tag
        }
        return nil
    }

    // MARK: - 触发与去重

    func fire(tag: UInt32) {
        let now = Date()
        if tag == lastFireTag, now.timeIntervalSince(lastFireDate) < 0.15 {
            return
        }
        lastFireTag = tag
        lastFireDate = now

        DebugLog.write("热键命中 tag=\(tag)")
        lock.lock()
        let handler = registrations[tag]?.handler
        lock.unlock()
        handler?()
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
        let available = Self.isListeningAvailable
        guard available != lastListeningAvailable else { return }
        lastListeningAvailable = available
        DebugLog.write("输入监控权限变化：\(available)")
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
                carbonFire(tag: hotKeyID.id)
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

    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt {
        var value: UInt = 0
        if flags.contains(.control) { value |= 4096 }
        if flags.contains(.option) { value |= 2048 }
        if flags.contains(.shift) { value |= 512 }
        if flags.contains(.command) { value |= 256 }
        return value
    }
}
